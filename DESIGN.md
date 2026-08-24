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
| Scene model | Named structures, upsert-by-name across runs; per-structure viewer state (visibility, colormap, sizes) survives recompiles; untouched structures marked stale |
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
`VERTEX_SOCK`). Framing: `[u32 len][u16 kind][u16 flags][payload]` (8-byte
header; variable sections inside a payload start at 16-byte offsets so a
decoded payload's slices are directly usable), native endianness
(the magic doubles as an endianness check). Handshake: magic `VTXP` + `u16`
protocol version; the viewer only talks to a client with the identical version
and rejects anything else. Stream payloads are the in-memory blob bytes
verbatim — the wire format derives from the build-selected `Positions` type,
so there is no conversion at either end for any layout (`STYLE.md` §3). The
version number is the sole compatibility contract: any change to message
shapes *or* the vertex layout bumps it. The format is language-agnostic (a
Python or C++ client is just a serializer that emits the viewer's layout), not
layout-agnostic.

Messages (v1):

- `Hello { version, source_name }`
- `BeginRun` — new generation; existing structures become stale-pending
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
- **Staleness.** At `EndRun`, structures not touched during the run are marked
  stale (dimmed in UI, toggleable auto-remove).
- **Copies on the path:** client → kernel is zero-copy (`writev` from the
  caller's slices); the viewer's socket thread reads each payload into one
  16-byte-aligned allocation, `protocol.decode` returns views into it, and
  `Scene.apply` copies sections into their 64-byte-aligned blobs. Measured
  (2026-08-24, `sketches/stress.zig`, 40 × 1M-vertex `MeshPositions`, aos3,
  llvmpipe viewer): client 2.0 GB/s, viewer decode+apply 2.6 GB/s (517 MB
  in 199 ms). A 60 Hz stream of 12 MB frames needs 0.7 GB/s, so the
  read-straight-into-blobs and memfd (`SCM_RIGHTS`) optimizations are
  **not warranted**; revisit only if a real workload shows ingest time.

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
Structure { name, kind, dim, versions: []Version, stale: bool }
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
cached per-blob, not per-version.

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
  target; revisit if ever porting).

**Camera.** Orbit (turntable) with pan/dolly for 3D; orthographic pan/zoom-under-
cursor for 2D. Mode auto-selected when all live structures are `dim=2`, manual
override in UI. Pose persists across runs; fit-to-scene on `F` and on first-ever
data only.

**UI panels.** Structure tree (visibility checkboxes, quantity selector,
colormap combo, wireframe toggle, size sliders) · timeline scrubber with play
and frame labels · status bar (connection, counts, fps) · log console · pick
inspector tooltip.

## Hot-recompile loop

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

## Dylib mode — design note (not built; decision pending)

The `Sink` seam makes an in-process mode possible, but there are two very
different things it could mean:

**A. Push mode.** The sketch is built as a shared library exporting
`vertex_run(sink)`; the viewer loads it on change and runs it on a worker
thread with a `DirectSink` that hands `protocol.Message` values to
`Scene.apply`. This only removes the socket hop (one syscall + one copy per
message) and *costs* crash isolation — an algorithm segfault takes the viewer
and its camera with it. Given measured socket throughput (see M4 stats), it
is not worth its downside.

**B. Viewer-driven stepping.** The sketch exports a stepping interface:
```zig
pub export fn vertex_init(gpa: *const std.mem.Allocator) ?*anyopaque;      // build initial state
pub export fn vertex_step(state: *anyopaque, sink: *const Sink) bool;      // one algorithm step; false when done
pub export fn vertex_deinit(state: *anyopaque) void;
```
The viewer gains Step / Run / Pause / Reset controls and a per-step time
budget, so an iterative algorithm can be single-stepped from the UI while
the timeline records every step. Hot reload replaces the library between
steps (new state via `vertex_init`; keeping opaque state across reloads is
unsafe once the layout of that state may have changed). Implementation
notes: never `dlclose` — load each new build under a unique path and leak
the old mapping (TLS/atexit/global-state hazards on unload are real in Zig
and C); run steps on a worker thread with the sink pushing copied messages
through the existing `Inbox` so the render thread never blocks; the socket
mode stays the default for batch runs.

B is the mode with genuine new capability (interactive stepping); it changes
how sketches are written (state + step instead of `main`), so it should be
an explicit choice rather than a background experiment.

## Milestones

- **M1 — walking skeleton.** ✅ (2026-08-23) Flake + build.zig; viewer with
  imgui, orbit/ortho cameras, socket server, mesh rendering (all layouts,
  timeline, staleness); client streams an animated icosphere sketch.
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
- **M4 — retention + budget.** ✅ (2026-08-24) Previous run retained
  (`Retention.max_runs`, default 2) with `versionAtRun` and a "Compare
  previous run" ghost pass (wireframe/dimmed); memory budget
  (`VERTEX_MEMORY_BUDGET_MB`, UI drag) enforced by evicting old-run versions
  first, then decimating current-run frames (odd frames, then every 4th,
  …), never a structure's latest or frame 0; memory/eviction readouts;
  ingest statistics on exit; `sketches/stress.zig`. memfd path closed by
  measurement (see "Copies on the path"). Dylib mode: design note above,
  awaiting a decision.
