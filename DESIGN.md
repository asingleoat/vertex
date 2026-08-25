# vertex — architecture

A persistent geometry visualization viewer with a hot-recompile feedback loop.
Write geometry code → save → rebuild+run → results stream to the always-open
viewer → immediately rendered with full camera control and UI state intact.

## Decisions (settled 2026-08-23)

| Area | Decision |
|---|---|
| Language | Zig (viewer, client lib, protocol) |
| Dependencies | Nix flake dev shell for system deps; `build.zig.zon` for Zig packages |
| Process model | Separate processes + Unix domain socket IPC; internal `Sink` interface so a hot-loaded-dylib mode can be added later |
| Renderer | sokol-gfx via sokol-zig (sokol_app for windowing) |
| Domain | Both 3D geometry processing (orbit camera) and 2D computational geometry (ortho pan/zoom) from day one |
| Renderables | Triangle meshes, point clouds, polylines/edge sets, scalar fields (colormapped), vector fields (instanced arrows) |
| Scene model | Named structures, upsert-by-name across runs; per-structure viewer state (visibility, colormap, sizes) survives recompiles; a run discards what it does not re-register |
| Timeline | Step capture in v1 — client calls `step()` between iterations, viewer gets a frame scrubber |
| UI | Dear ImGui via sokol_imgui + cimgui |
| Picking | v1 — ID-buffer pass, click to inspect element index + quantity values |

## Components

```
vertex/
├── flake.nix                # dev shell: zig, zls, X11/GL libs, watchexec, tooling
├── build.zig
├── build.zig.zon            # sokol-zig, cimgui
├── src/
│   ├── vertex.zig             # root of the `vertex` module (pure core + client)
│   ├── geometry/              # layout.zig (Positions), geometry.zig (kernels), fixtures.zig
│   ├── protocol/protocol.zig  # wire format: message types, encode/decode (pure)
│   ├── scene/                 # scene.zig (structure store, versions, frames), camera.zig
│   ├── client/client.zig      # client lib your geometry code imports (Sink + socket)
│   └── viewer/                # `vertex-view` exe: the effectful edges only
│       ├── main.zig           # sokol_app entry, frame loop
│       ├── server.zig         # socket listener thread → staging queue
│       ├── pick.zig           # ID-buffer pass + readback
│       ├── ui.zig             # imgui panels: structure tree, timeline, inspector
│       ├── render/            # mesh.zig, points.zig, lines.zig, vectors.zig, colormap.zig
│       └── shaders/           # sokol-shdc sources; generated .zig checked in
├── bench/                     # one ReleaseFast exe per file; helpers in bench/lib/
└── sketches/                  # your experiments; each file = runnable exe (run-sketch)
```

Three artifacts from one `build.zig`:
- **`vertex-view`** — the persistent viewer.
- **`vertex` module** — client library, imported by sketches.
- **sketch executables** — one per file in `sketches/`, auto-discovered by `build.zig`.

## Data flow

```
sketches/current.zig ──(zig build --watch)──► rebuilt exe runs
        │  vx.connect() / vx.mesh() / vx.step() / s.finish()
        ▼
$XDG_RUNTIME_DIR/vertex.sock  (framed binary protocol)
        ▼
viewer socket thread ── parse ──► staging queue (mutex)
        ▼ drained once per frame on render thread
scene store (named structures, versioned per frame)
        ▼ GPU upload on change
sokol-gfx passes: solid → edges/lines → points → vectors → [pick pass] → imgui
```

## Wire protocol

Transport: Unix domain socket at `$XDG_RUNTIME_DIR/vertex.sock` (override via
`VERTEX_SOCK`). `sockaddr_un` caps the address string at 108 bytes (104 on
Darwin/BSD) before any path resolution; `platform.sockpath` rebases longer
paths on an open directory handle (`/proc/self/fd/<fd>/<basename>`) on
Linux, and rejects them with a message naming the limit elsewhere. Both the
viewer's bind and the client's connect go through it. Framing: `[u32 len][u16 kind][u16 flags][payload]` (8-byte
header; variable sections inside a payload start at 16-byte offsets so a
decoded payload's slices are directly usable), native endianness
(the magic doubles as an endianness check). Handshake: magic `VTXP` + `u16`
protocol version (currently 2); the viewer only talks to a client with the identical version
and rejects anything else. Stream payloads are the in-memory blob bytes
verbatim — the wire format derives from the build-selected `Positions` type,
so there is no conversion at either end for any layout (`STYLE.md` §3). The
version number is the sole compatibility contract: any change to message
shapes *or* the vertex layout bumps it. The format is language-agnostic (a
Python or C++ client is just a serializer that emits the viewer's layout), not
layout-agnostic.

Messages (v1):

- `Hello { version, source_name }`
- `BeginRun` — new generation; the previous run's versions are released
- `BeginFrame { index, label? }` — frame 0 is implicit after `BeginRun`; the
  client's `step()` sends `EndFrame` + `BeginFrame(n+1)`
- `Mesh { name, dim: 2|3, positions: Positions bytes, indices: [u32×3] }`
- `MeshPositions { name, positions }` — topology-unchanged update; new version
  reuses the previous version's index buffer (the smoothing/relaxation/flow case)
- `Points { name, dim, positions }`
- `Lines { name, dim, positions, segments: [u32×2] }` — covers polylines and edge sets
- `ScalarQuantity { structure, name, target: vertex|face|point, values: [f32] }`
- `VectorQuantity { structure, name, target, vectors: Positions bytes }`
- `Log { level, text }` — echoed in a viewer console panel
- `EndFrame`, `EndRun`

Semantics:
- **Upsert by name.** Registering a structure replaces its geometry; viewer-side
  state (visibility, active quantity, colormap, sizes) is keyed by name and persists.
- **Frames are deltas.** A structure registered in frame *k* persists into later
  frames until re-registered. Scrubbing to frame *t* shows each structure's
  latest version at-or-before *t*. Evolving meshes are first-class: re-register
  under the same name every `step()` and each registration becomes a scrubbable
  version. Three cost tiers fall out naturally:
  1. *Static* — register once, zero per-frame cost.
  2. *Positions evolve, topology fixed* (smoothing, relaxation, flows,
     parameterization iterations) — send `MeshPositions` per frame; only the
     position blob is stored/uploaded per version, topology is shared.
  3. *Topology evolves* (edge collapses, remeshing, booleans) — full `Mesh`
     per frame; inherently O(steps × mesh size), bounded by an eviction policy
     (see M5).
- **A run owns the scene.** At `EndRun`, every structure the run never
  registered is discarded: its versions are released and it stops drawing and
  listing. Its slot and per-name `UiState` remain, so registering the name
  again later restores the structure with its viewer settings. Nothing is kept
  dimmed — a leftover from the last run in the corner of the viewport is
  noise, not information. (Superseded 2026-08-25 the retain-and-dim rule and
  the A/B ghost that justified keeping the previous run at all.)
- **Copies on the path.** Two payload modes, protocol version 2:
  - *Inline*: client → kernel is zero-copy (`writev` from the caller's
    slices); the viewer's socket thread reads each payload into one
    16-byte-aligned allocation, `protocol.decode` returns views into it, and
    `Scene.apply` copies sections into 64-byte-aligned blobs.
  - *Shared (zero-copy)*: the sketch asks the connection for buffers that ARE
    memory-mapped memfds (`conn.sharedPositions(n)`, `sharedScalars`,
    `sharedVectors`), fills them in place, and sends as usual; the section is
    described by a `SectionRef` (fd index, 64-aligned offset, length) and the
    fd rides the frame header in one `sendmsg` (`SCM_RIGHTS`). The viewer's
    socket thread maps the fd read-only (`MAP_POPULATE`), the render thread
    registers the mapping with the scene, and `Scene.apply` adopts sections
    inside a registered mapping as blob *views* — no copy anywhere between the
    sketch's write and the GPU upload. Mappings are refcounted by the blobs
    that view them; the edge alone `munmap`s/`close`s via `released_mappings`.
    A shared buffer is consumed by its send (the viewer retains versions, so
    reuse is impossible by construction): request a fresh one per message.
  - *Huge pages*: shared buffers ≥ 2 MiB are created with
    `MFD_HUGETLB | MFD_HUGE_2MB` (hugetlbfs, reserve-or-fail at `mmap`, so
    the fallback to an ordinary memfd is clean; a failed attempt starts an
    8-buffer cooldown). On by default (`VERTEX_SHARED_HUGE=0` disables); the
    kernel must allow huge pages — `vm.nr_overcommit_hugepages` (on demand,
    nothing reserved while idle) or `vm.nr_hugepages` — and both sketch and
    viewer print a one-time notice with the exact sysctl when neither is set.
    THP for shmem was considered and rejected: it needs the equally
    non-default `shmem_enabled=advise` and is best-effort rather than
    reserve-or-fail.
  - Measured (2026-08-24, `sketches/stress.zig`, 40 × 1M-vertex (12 MB)
    `MeshPositions`, llvmpipe viewer), per step, excluding the sketch's own
    fill: inline — send 6.8 ms, viewer decode+apply 5.4 ms, 517 MB through
    the socket; shared 4 KiB pages — create+populate ~5 ms, send 0.45 ms,
    viewer 0.43 ms, 117k minor faults over the run; shared hugetlb — create
    +populate ~2 ms (kernel zero-fill is the residual), send 0.03 ms, viewer
    0.43 ms, 244 minor faults. Inline remains the default for ordinary
    slices; all platform-specific code lives in `src/platform/`.
  - Same run on aarch64-darwin (M1 Pro, Metal viewer, 2026-08-24), totals
    over the 40 steps: inline — send 348.3 ms, viewer apply 62.7 ms, 517 MB
    through the socket; shared — send 3.8 ms, viewer apply 6.6 ms, 36 MB
    through the socket, `mapped_bytes=480960480`. Send is 92× faster
    (8.7 → 0.095 ms/step, i.e. quicker than Linux's 4 KiB shared path
    despite having no huge pages to fall back on); buffer creation costs
    ~1.2 ms per 12 MB.

## Client library

```zig
const vx = @import("vertex");

pub fn main() !void {
    var s = try vx.connect(.{ .name = "hull-experiment" });
    defer s.finish();

    s.mesh("input", positions, faces, .{});
    s.scalar("input", "curvature", .vertex, k);

    for (0..iters) |_| {
        relax(&sites);
        s.points("sites", sites, .{ .dim = .d2 });

        smooth(&positions);                       // topology fixed:
        s.meshPositions("input", positions);      //   cheap positions-only update
        // decimate(&positions, &faces);          // topology changed:
        // s.mesh("input", positions, faces, .{}); //  full re-register, same name

        s.step(); // frame boundary → timeline
    }
}
```

Principles:
- Slices in, written synchronously via `writev` from caller memory — no copy,
  no lifetime coupling (the call returns after the kernel has the bytes).
- `connect` fails loudly by default; `.optional = true` degrades to no-op so a
  sketch still runs headless.
- The API is defined against a **`Sink` vtable** carrying `protocol.Message`
  values, with one v1 implementation (`SocketSink`, which encodes + `writev`s).
  The future dylib mode is a `DirectSink` that hands the same messages to
  `Scene.apply` in-process — same sketch code, zero serialization, zero
  protocol changes. This is the "IPC now, dylib later" seam.

## Viewer internals

**Threading.** sokol_app owns the render thread. One socket thread per
connection does blocking reads, decodes complete structure updates, and pushes
them onto a mutex-protected staging queue. The frame callback drains the queue,
coalesces multiple updates to the same structure (sokol allows only one
`sg_update_buffer` per buffer per frame), and uploads.

**Scene store.** Versions are tuples of references into a refcounted blob
store, not owned copies:

```
Structure { name, kind, dim, versions: []Version }   // no versions ⇒ discarded, slot and UiState kept
Version   { run: u32, frame: u32,
            positions: BlobRef, topology: ?BlobRef, quantities: {name: BlobRef} }
Blob      { refcount, bytes: []align(64) u8 }        // pure; positions stored in the build-selected Positions layout
render/: blob_gpu: ArrayListUnmanaged(sg.Buffer) indexed by BlobIndex   // edge-owned parallel array
UiState   (keyed by name, survives runs) { visible, active_quantity, colormap, wireframe, sizes }
```

The core scene store never touches sokol: the render edge keeps a parallel
array of GPU buffers indexed by `BlobIndex` and drains a core-maintained list
of newly created blob indices each frame (see `STYLE.md` §4).

A full `Mesh` registration replaces all refs; `MeshPositions` replaces only the
positions ref (topology blob shared with the prior version); re-sending a
quantity replaces only that quantity's ref. Scrubbing the timeline is just
binding a different combination of already-uploaded GPU buffers — no re-upload.
Timeline memory cost is therefore proportional to what actually changed per
step, and derived data (unique edge lists for wireframe, arrow instances) is
cached per-blob, not per-version. The fixed cost of a version beyond its blob
bytes is **68 bytes** (measured 2026-08-24: the `Version` record, its blob
record and list slack); a test pins it under 128 so a per-version container
cannot creep in unnoticed.

**GPU residency.** Retained versions are bounded only by the memory budget,
but sokol's buffer pool is finite (1024 slots, set at `sg.setup`). Every blob
buffer and derived instance buffer is stamped with the frame it was last
bound; after each frame, if more than `residency_cap` (512) blob buffers or
`derived_cap` (128) cache entries are resident, those not used this frame
are destroyed. They are immutable uploads of scene data and are recreated
on demand when scrubbed back. Regression: `sketches/churn.zig` (400 paced
versions) — this exhausted the pool before the policy existed.

**Rendering.**
- Mesh solid pass: flat shading from screen-space derivatives
  (`normalize(cross(dFdx(p), dFdy(p)))`) — no normals or vertex duplication
  needed; smooth shading when client supplies/requests normals.
- Wireframe: CPU-extracted unique edge list rendered through the thick-line
  pipeline with depth offset (avoids barycentric vertex duplication and
  unreliable GL line width).
- Scalar quantities: values as a vertex attribute sampled through 1D colormap
  LUT textures (viridis, turbo, coolwarm embedded).
- Points: instanced screen-space quads, round sprite in fragment shader
  (portable, unlike gl_PointSize).
- Lines: instanced screen-space quads per segment, constant pixel width.
- Vectors: instanced low-poly arrow mesh, per-element transform.
- Picking: offscreen pass writing `(structure_id, element_id)` to an integer
  target. **sokol-gfx has no readback API** — use a direct `glReadPixels`
  escape hatch, isolated in `pick.zig` (acceptable: Linux/GL backend is the
  target; revisit if ever porting). **Revisited 2026-08-24, porting: replace
  it with CPU picking** (see below). The GL path stays until that lands.

### Picking, decided 2026-08-24: ray-cast on the CPU, not an ID buffer

Porting made the readback escape hatch cost three implementations instead of
one, so the "revisit if ever porting" above came due. What settled it:

- **The synchronous shape does not port.** sokol's Metal backend creates one
  `MTLCommandBuffer` per frame, `enqueue`s it at the first `beginPass` and
  commits it at `sg.commit()`; it exposes the device, the queue and the
  encoders but *not* that command buffer. A blit committed mid-frame sits
  behind a command buffer that has not been committed yet, so
  `waitUntilCompleted` cannot return. Any GPU readback here has to be
  asynchronous (fence after `sg.commit()`, result one frame later) — and the
  same is true of D3D11. Three backends, three hatches, one of them a
  restructuring of the pick call path.
- **Nothing needs the GPU.** Scene blobs are CPU memory already. A ray cast
  gives ray-triangle for meshes, cursor-to-projected-point distance against
  `point_size` for points, cursor-to-projected-segment distance against
  `line_width` for lines, nearest `t` across kinds — which is what the depth
  test was doing. It is more precise than the ID buffer, not less: no
  rasterization quantization.
- **It is core, so it is testable.** `geometry/` code with
  `checkAllAllocationFailures` and a `bench/` entry (STYLE §5–6), instead of
  GPU behaviour that can only be checked by running a window.
- **It is plausibly faster than what we have.** Hover picking currently
  re-renders every visible structure through the pick pipelines on every
  mouse move — full vertex processing of the scene per motion event. A BVH
  cached per positions-blob (invalidated exactly like the derived edge-list
  cache) turns that into a log-time query.

Plan: brute force first, measured; add the per-blob BVH when the numbers ask
for it (`sketches/stress.zig` is ~2M triangles, far past brute force for
hover). Landing it deletes `pick.zig`'s GL externs, the four `pick_*` shaders
and the `RG32UI` target. Sequenced after the platform layer and the smokes,
because it is a redesign of a working feature rather than a port step, and it
owes before/after numbers plus a check that a CPU hit agrees with a GL hit on
the same scene.

**Camera.** Orbit (turntable) with pan/dolly for 3D; orthographic pan/zoom-under-
cursor for 2D. Mode auto-selected when all live structures are `dim=2`, manual
override in UI. Pose persists across runs; fit-to-scene on `F` and on first-ever
data only.

**UI panels.** Structure tree (visibility checkboxes, quantity selector,
colormap combo, wireframe toggle, size sliders) · timeline scrubber with play
and frame labels · status bar (connection, counts, fps) · log console · pick
inspector tooltip.

## Hot-recompile loop

- Build modes, split by who is building. **Using** vertex — writing sketches,
  leaving the viewer up — is `zig build -Drelease`, which is **ReleaseFast**:
  sketch geometry is real compute and nobody wants their own algorithm slowed
  by the tool around it. **Working on** vertex is Debug or ReleaseSafe: on zig
  master a plain `zig build` is Debug (the viewer then runs on a leak-checking
  `DebugAllocator`), and `-Doptimize=ReleaseSafe` keeps the bounds, overflow
  and `std.debug.assert` checks that a core built out of `u32` indices into
  flat arrays depends on. Benches are always ReleaseFast.
- Verification: `zig build test` (all layouts via `-Dvertex_layout`) plus
  `nix develop -c scripts/smoke.sh`, which drives the viewer through the
  socket sketches, the churn regression, the stepper autorun and the
  shared-memory stress, asserting the deterministic stat lines and the
  absence of sokol errors and allocator leak reports. Headless under Xvfb on
  Linux; on macOS there is no Xvfb, so it runs on the real display (four
  windows appear and close) — same assertions, ~46 s.
- Terminal 1: `zig build run-viewer` — stays up for days.
- Terminal 2: `zig build run-sketch --watch` (`-Dsketch=<name>`, default
  `current`) — verified: the run step re-executes on every save; the exe
  connects, streams, exits. `watchexec` is in the dev shell as a fallback.
- Sketches and benches are discovered by listing `sketches/` and `bench/`.
  Zig master caches the configure phase; `build.zig` declares the directories
  via `dependOnDirectory` and poisons the cache until the maker implements
  directory mode (a TODO upstream), so new files are always picked up.

## Nix

- `flake.nix`: Zig master (0.17-dev) from `mitchellh/zig-overlay`, zls from
  the `zigtools/zls` flake, both locked in `flake.lock`. sokol-zig and dcimgui
  track zig master, so the Zig deps stay on their master branches.
- Dev shell system deps for sokol on Linux: `libX11 libXi libXcursor libGL`
  plus `pkg-config`, `watchexec`, `gdb`, optionally `renderdoc`.
- Zig packages (sokol-zig, cimgui) via `build.zig.zon` — pragmatic split:
  nix owns the toolchain and C/system libs, Zig's package manager owns Zig
  deps. For a reproducible `nix build` package later, use the deps-hash
  approach (`zig build --fetch` + fixed-output derivation) or zig2nix.

### Known NixOS friction (accepted, with mitigations)

1. **sokol-shdc** is a prebuilt binary → the flake wraps it with
   `autoPatchelfHook` (`packages.sokol-shdc`, pinned to the commit sokol-zig
   references). Generated shader `.zig` files under `src/viewer/shaders/` are
   checked in; `zig build shaders` regenerates them.
2. **System libs / libc headers**: zig reads `NIX_CFLAGS_COMPILE`/`NIX_LDFLAGS`
   from the dev shell; `glibc.dev` is listed explicitly because the external
   translate-c (Aro) used by dcimgui does not go through the cc wrapper.
3. **Wayland**: sokol_app's Linux backend is X11/GLX → runs under XWayland.
   Fine for a dev tool; noted in case of future native-Wayland desire.
4. **Zig master packages** live in a project-local `zig-pkg/` (gitignored).

## Portability plan (Linux first, macOS/Windows later)

Everything platform-specific lives behind `vertex.platform` (comptime-selected
per `builtin.os.tag`, with `*_unsupported.zig` stubs that compile everywhere
and return `error.Unsupported` so the inline path stays the fallback) or
inside a viewer edge module with a documented backend assumption. The
touchpoints and their counterparts:

macOS cells marked ✅ are facts established on aarch64-darwin (macOS 26.5.2,
M1 Pro, 2026-08-24) porting the viewer: toolchain, Metal, zero-copy, dylib
stepping and the smokes all run there now. Only the ❌ row is outstanding.

| Concern | Linux (now) | macOS | Windows |
|---|---|---|---|
| Toolchain | zig from `zig-overlay`, glibc pinned to the shell's (`ZIG_DYNAMIC_LINKER`) | ✅ same zig, no pin: the pin must be Linux-gated because nixpkgs' *darwin* cc wrapper also ships `nix-support/dynamic-linker` (`/usr/lib/dyld`), which used to force `abi=gnu` | — |
| SDK / frameworks | n/a | ✅ zig 0.17.0-dev.1857 skips its darwin SDK detection (`xcrun --sdk macosx --show-sdk-path`) whenever `NIX_CFLAGS_COMPILE` *or* `NIX_LDFLAGS` is set, and then finds no framework at all (`searched paths:  none`); the dev shell unsets both, leaving `DEVELOPER_DIR`/`SDKROOT` (nixpkgs `apple-sdk` 14.4) to pin the SDK | Win SDK via zig's own headers |
| Shared memory (`platform.shm`) | `memfd_create` + `mmap`, hugetlbfs via `MFD_HUGETLB` with fallback | ✅ `shm_open` with an exclusive one-shot name, `shm_unlink`ed immediately so the descriptor is the only reference; `ftruncate` + `mmap`. No `MAP_POPULATE`, no huge pages: `huge` is always false and the notice never fires. ~1.2 ms per 12 MB buffer (open + truncate + map + first touch) | `CreateFileMapping`/`MapViewOfFile`; large pages need `SeLockMemoryPrivilege` |
| Handle passing (`platform.fdpass`) | `SCM_RIGHTS` over the Unix socket | ✅ `SCM_RIGHTS` via `std.c` `sendmsg`/`recvmsg`, but **not** a copy of the Linux file: `CMSG_ALIGN` is `__DARWIN_ALIGN32` (4 bytes, not `sizeof(size_t)`) and `cmsghdr` is 12 bytes not 16; no `MSG_NOSIGNAL` (use `SO_NOSIGPIPE` on the socket); no `MSG_CMSG_CLOEXEC` (mark each received fd) | no fd passing: `DuplicateHandle` into the viewer process (needs its pid) or a named mapping |
| Receiving without handle passing | `recvmsg` always | ✅ no longer needed here (fdpass landed), but the `platform.fdpass.supported` branch stays: without it a receiver cannot read the socket *at all*, inline path included, because `recvWithHandles` is `error.Unsupported` | needed permanently — Windows never passes handles this way |
| Transport | Unix domain socket via `std.Io.net` | ✅ same; `std.Io.net` binds, connects and accepts on the kqueue `Threaded` backend | `AF_UNIX` exists since Windows 10 1803; `std.Io.net` support to verify |
| Abstract sockets | `"\0name"`, no file to clean up | ✅ none — Darwin has no abstract namespace; bind a real file | none |
| Windowing / GPU | sokol_app X11 + GL 4.3 | ✅ sokol_app Cocoa + Metal, selected by passing `.gl = false` to sokol-zig (its `auto` resolves to Metal on darwin); frameworks `AppKit`, `QuartzCore`, `Metal`, `AudioToolbox`. Mesh, points, lines and ImGui all render | sokol_app Win32 + D3D11 |
| Dylib stepping | `libstep-<name>.so`, `dlopen` of a copy | ✅ unchanged: `zig build step` names it `libstep-<name>.dylib`, `std.DynLib` is `dlopen`, and macOS raises no code-signing objection to `dlopen`ing the viewer's copy. Only the copied-path suffix was hardcoded | `.dll`; `LoadLibrary`, and the never-unload policy still applies |
| Headless smokes | `xvfb-run` + llvmpipe | ✅ no Xvfb exists: run on the real display. Frame caps shrink because vsync paces frames where llvmpipe does not | no Xvfb either; a hidden window or WARP |
| Shaders | `sokol-shdc -l glsl430` | ✅ `-l glsl430:metal_macos` — one checked-in file per shader carries both backends, byte-identical from either OS, and the GLCORE branch is unchanged by adding Metal. The `osx_arm64` sokol-shdc runs straight from the nix store (no Gatekeeper quarantine) | add `hlsl5` |
| Pick readback (`pick.zig`) | raw `glReadPixels` inside the pass — **to be deleted**: picking moves to a CPU ray cast (decision above), which needs no readback on any backend | ✅ picking is off meanwhile: `pick.Picker` comptime-selects a disabled picker — required, not merely tidy, because a Metal build does not link OpenGL, so the GL externs must not be analyzed at all. ✅ a synchronous Metal readback is impossible (sokol commits its only frame command buffer at `sg.commit()` and does not expose it, so a mid-frame `waitUntilCompleted` waits on a command buffer behind an uncommitted one) | same: no readback needed |
| Face scalars | GL 4.3 SSBO by `gl_PrimitiveID` | ❌ blocked: `gl_PrimitiveID` in a fragment shader needs **MSL 2.2** and SPIRV-Cross refuses below it (`PrimitiveId on macOS requires MSL 2.2`) — sokol-shdc has no MSL version flag, in the pinned build *or* master (checked 2026-08-24). `mesh_face_scalar{,_soa}` and `pick_mesh{,_soa}` stay GL-only; the renderer asks the generated desc whether the backend has a source and falls back to the plain mesh pipeline. Fixing it means a shdc that sets MSL 2.2, or dropping `primitive_id` for a per-vertex face index (which costs vertex duplication) | D3D11 `StructuredBuffer` + `SV_PrimitiveID` |
| Socket path | `$XDG_RUNTIME_DIR/vertex.sock` | ✅ `/tmp/vertex.sock` — the existing fallback, because `XDG_RUNTIME_DIR` is unset and `$TMPDIR` is *per `nix develop` shell* (`/tmp/nix-shell.XXXXXX/nix-shell.YYYYYY`), which would put viewer and sketch on different sockets | `\\.\pipe` or a temp-dir `AF_UNIX` path |
| `sun_path` limit | 107 usable bytes, longer ones rebased via `/proc/self/fd/<fd>` | ✅ `sun_path` is `char[104]` (SDK `sys/un.h`) → 103 usable, and there is no `/proc` to rebase on, so longer paths are rejected naming the limit | 107 usable, no rebasing |
| Measurement (`platform.stats`) | `getrusage`, `/proc/self/status` | ✅ `getrusage` alone — `task_info` is unnecessary, since `stats` only exposes minor faults and hugetlb KiB and the latter is always zero here. Whether a huge-page class exists is the comptime `shm.huge_supported`, so viewer, client and sketch all report `huge=off` instead of advertising an impossible preference | `GetProcessMemoryInfo` |

Rules that keep this cheap: no `std.os.linux` or raw GL call outside
`src/platform/*` and `pick.zig`; the scene and protocol never see handles as
anything but opaque `platform.Handle` values; a port starts by filling in one
row of this table at a time, with the inline payload path working before
shared memory does. Whether a capability exists is a `pub const supported`
on the platform module (`platform.shm.supported`, `platform.fdpass.supported`)
that the decl-parity test keeps in sync — callers branch on that, never on
`builtin.os.tag`, so a port switches a path on by writing the module.

## Dylib mode — viewer-driven stepping

Chosen 2026-08-24 (over "push mode", which would only remove the socket hop
that the shared-memory path already made irrelevant, at the cost of crash
isolation). A *stepping sketch* lives in `steps/<name>.zig`:

```zig
pub const State = struct { ... };
pub fn init(gpa: std.mem.Allocator, session: *vertex.Session) !State;  // register initial structures
pub fn step(state: *State, gpa: std.mem.Allocator, session: *vertex.Session) !bool; // false = finished
pub fn deinit(state: *State, gpa: std.mem.Allocator) void;
comptime { vertex.dylib.exportSketch(@This()); }
```
`zig build step -Dsketch=<name> --watch` builds `zig-out/lib/libstep-<name>.so`.
`exportSketch` generates the C-ABI surface (`vertex_abi_version`,
`vertex_init`, `vertex_step`, `vertex_deinit`); the viewer and the library
are always built from the same tree, so the ABI only has to be
self-consistent plus a version check.

- **Data path reuses everything.** A `DirectSink` encodes with the wire
  protocol and hands byte parts to a host callback; the viewer copies them
  into the same `Inbox` the socket server feeds. Decode, scene, timeline,
  retention and picking are untouched. Shared (memfd) buffers are
  socket-mode only (`Connection`); the in-process path is inline-copy.
- **Stepping.** A worker thread owns the library and runs `vertex_step`;
  each viewer-driven step is one timeline frame. Controls: Load / Reload /
  Unload, Step / Run / Pause / Reset. Run has three paces: **Frame**
  (default — one step per rendered frame, so every step is seen), **Rate**
  (N steps/s), and **Max** (free-wheel until the sketch's own stop
  condition, an error, or Pause — the batch mode: generate the frames fast,
  then scrub them). `Step` runs exactly one step unpaced. The render thread
  never calls into the library; frame pacing is a credit the render thread
  grants once per frame. `VERTEX_STEP_PACE=frame|rate|max` for headless use.
- **Runs.** Every Reset or reload starts a new run (`init` sends hello +
  begin_run), which releases the previous run's versions: the viewer shows
  the algorithm you just built, not a palimpsest of the ones before it.
- **Hot reload.** The viewer polls the library's mtime (~4 Hz), copies the
  new build to a unique path and `dlopen`s it; libraries are never
  `dlclose`d (TLS/atexit/global-state hazards on unload — the leaked mapping
  is small). `vertex_abi_version` mismatch refuses the load. A sketch that
  was running *or had finished* re-runs after a reload (the developer saved a
  change to see it play); a never-started or paused sketch stays idle.
- **Leaks and errors.** Each instance gets its own leak-checking
  `DebugAllocator`; `vertex_deinit` reports leaks and the viewer logs them;
  a failing step pauses with the error in the log.
- **Crash isolation is lost** in this mode by construction; the socket mode
  remains the default and the safe choice for batch runs.
- Env: `VERTEX_STEP_LIB=<path>` loads at startup, `VERTEX_STEP_AUTORUN=1`
  starts running; the exit stats line gains `stepper steps=… state=…
  reloads=… leaks=…` for headless checks.

## Milestones

- **M1 — walking skeleton.** ✅ (2026-08-23) Flake + build.zig; viewer with
  imgui, orbit/ortho cameras, socket server, mesh rendering (all layouts,
  timeline, run lifecycle); client streams an animated icosphere sketch.
  Verified end-to-end headless (Xvfb/llvmpipe) and via `--watch`.
  Not in M1: points/lines draw as UI entries only.
- **M2 — all renderables + scalar colormaps.** ✅ (2026-08-23) Points (instanced round
  sprites), lines/polylines (instanced screen-space quads), vector quantities
  (instanced arrows), vertex-target scalar quantities through comptime
  colormap LUTs (viridis/turbo/coolwarm/plasma) on meshes and points,
  wireframe overlay from CPU-extracted unique edges with depth bias,
  per-structure UI controls (quantity/colormap selectors, sizes, wireframe),
  2D auto-detection on first fit.
- **M3 — picking + inspection.** ✅ (2026-08-23) ID-buffer pass, GL readback, inspector
  tooltip with element index and quantity values; face-target scalar
  rendering (needs the same per-primitive plumbing).
- **M4 — retention + budget.** ✅ (2026-08-24) Memory budget
  (`VERTEX_MEMORY_BUDGET_MB`, UI drag) enforced by decimating current-run
  frames (odd frames, then every 4th, …), never a structure's latest or
  frame 0; memory/eviction readouts; ingest statistics on exit;
  `sketches/stress.zig`. memfd zero-copy path landed the same day (see
  "Copies on the path"). Dylib mode: design note above, awaiting a decision.
  - *Retracted 2026-08-25.* This milestone also retained the previous run
    (`Retention.max_runs` = 2, `versionAtRun`, `frameCountOfRun`) behind a
    "Compare previous run" ghost pass, and dimmed structures a new run had
    not re-registered. In use the A/B compare was not reached for and the
    dimmed leftovers were a distraction, so both are gone: one run is
    retained, untouched structures are discarded, and the budget lost its
    evict-old-runs-first stage because there are no old runs to evict.
