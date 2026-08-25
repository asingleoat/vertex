# Handoff: the macOS port

Written 2026-08-24 on the Linux machine at the end of the first development
stretch, for a fresh session on a Mac. Read `CLAUDE.md`, `DESIGN.md`,
`STYLE.md`, then this file; `git log --oneline` is the narrative of every
decision (each commit message says what was decided and why).

## 1. Where the project stands

Everything on the original design ladder is built and verified on Linux:

- Viewer (sokol-gfx GL 4.3 + Dear ImGui), socket client library, wire
  protocol v2, scene store with delta timeline, retention/A-B ghosting,
  memory budget with decimation, points/lines/vectors/meshes with scalar
  colormaps, wireframe, picking + inspector, face-target scalars.
- Zero-copy shared-memory payloads (memfd + `SCM_RIGHTS`, hugetlbfs when
  the kernel allows), measured: 40 × 1M-vertex updates in 16 ms client-side.
- Dylib mode: viewer-driven stepping with hot reload (`steps/*.zig` →
  `libstep-<name>.so`, Frame/Rate/Max pacing).
- Platform layer `src/platform/` (comptime per OS) with `*_unsupported.zig`
  stubs that compile everywhere and degrade to the inline path.
- 69 tests across three vertex layouts (`-Dvertex_layout=aos3|aos4|soa`),
  headless smokes in `scripts/smoke.sh` (Xvfb; see §5 for the Mac story).

Toolchain: zig master (`0.17.0-dev.1857` pinned by `flake.lock` via
`mitchellh/zig-overlay`), zls from the `zigtools/zls` flake, sokol-zig and
dcimgui on their master branches. Everything comes from nix; never use
`/nix/store` paths directly — go through `nix develop` and tool-resolved
paths.

## 2. Working agreements (these do not travel in Claude's memory — re-read)

- **Commit logical chunks as you go**, each with a message that records the
  decision and the verification performed. History is the design log.
- **Bleeding-edge Zig via nix**, as new as sokol-zig/dcimgui support. Known
  master quirks: no `@bitCast` to/from extern structs (build field-by-field
  or read via `*align(1) const T`), lowercase `OptimizeMode`, fetched
  packages in project-local `zig-pkg/`, the configure phase is cached
  (`build.zig` poisons it so new sketches are discovered), `-Drelease` gives
  ReleaseSafe and a plain `zig build` is Debug.
- **Optimize known-wasteful paths even when they are not the bottleneck**;
  measure to prioritise and verify, never to dismiss. Present before/after.
- **Tests must earn their keep**: keep contracts, regressions, ABI/format
  pins, OOM/leak/steady-state checks; prune scaffolding. **Pin measured
  performance quantities exactly** (a ratchet, not a ceiling) so a change's
  cost is visible the moment it is made and the pin is moved deliberately.
- **Pure core, effectful edges** (STYLE.md §4): no OS/sokol calls outside
  `src/platform/` and the viewer edge modules; scene/protocol/geometry stay
  pure. Layout is a type (`Positions`), index-not-pointer, reserve-then-assume.
- If delegating to Codex: write self-contained briefs (task, definition of
  done, scope box, verification loop, output contract); the sandbox may not
  reach the nix daemon — `nix print-dev-env > devenv.sh` and have it source
  that; re-verify everything yourself; review for test-gaming and scope
  creep. On Linux the harness reaped background tasks a few minutes after a
  turn ended — detach long runs (`setsid nohup … &`) and poll a log file.
- Tim's global git config sets `worktree.useRelativePaths`; nix's libgit2
  cannot read that extension, so `git worktree add --no-relative-paths`.

## 3. Prep done on Linux (Step 0 has now tested it on a Mac — see §4)

- `flake.nix` lists `aarch64-darwin`; the dev shell gates Linux-only inputs
  (glibc headers, X11/GL/ALSA libs, `gdb`, `xvfb-run`) behind
  `hostPlatform.isLinux`; the `sokol-shdc` derivation picks the `osx_arm64`
  binary (hash prefetched) — ✅ it runs. (`x86_64-darwin` was dropped:
  nixpkgs 26.11 no longer supports it.) The glibc pin hook was *not*
  gated — the assumption below was wrong.
- ~~`build.zig`'s target pinning only acts when `ZIG_DYNAMIC_LINKER` is set,
  so it is inert on macOS.~~ Wrong: the darwin cc wrapper publishes
  `nix-support/dynamic-linker` too, so the hook exported it and the pin
  fired. Both the hook and `resolveTarget` are Linux-gated now (§4 Step 0).
  The zig `overrideAttrs` patch (maker `--dynamic-linker` dangling-slice
  bug) is harmless on macOS, as expected.

## 4. The port, in order (each step has a done-criterion; stop and think if one fails)

**Step 0 — toolchain and pure core.** ✅ (2026-08-24) `nix develop -c zig
build test`: 34/34 steps, 66/69 tests, 3 skipped, on `-Dvertex_layout=aos3`,
`aos4` and `soa`. Every fact is in DESIGN.md's portability table; the two
that cost the most to find:

- The glibc pin fired here. `flake.nix` gated it on `$NIX_CC/nix-support/
  dynamic-linker` existing, but nixpkgs' *darwin* cc wrapper ships that file
  too (holding `/usr/lib/dyld`), so the target got pinned to
  `aarch64-native-gnu` with a glibc version parsed out of `libSystem-B`.
  Now gated on `hostPlatform.isLinux`, and `resolveTarget` refuses to pin
  unless the host is Linux.
- zig 0.17.0-dev.1857 **skips darwin SDK detection entirely when
  `NIX_CFLAGS_COMPILE` or `NIX_LDFLAGS` is set** (either alone suffices),
  after which every `-framework` fails with `searched paths:  none`. The
  darwin branch of the shell hook unsets both; `DEVELOPER_DIR`/`SDKROOT`
  from the `apple-sdk` setup hook keep `xcrun` pointed at the pinned SDK.
  If frameworks ever go missing again, check those two variables first.

The tests went as predicted (abstract socket → a file under
`std.testing.tmpDir`; the `/proc`-rebasing and shared-memory tests skip),
with one addition: capability is now a `pub const supported` on the platform
module rather than an `os.tag` comparison, so Step 2 switches the zero-copy
path on by writing `shm_darwin.zig`/`fdpass_darwin.zig` — there is no OS
check left outside `src/platform/` to find.

**Carry into Step 1:** `src/viewer/server.zig:245` reads the socket through
`platform.fdpass.recvWithHandles`, which is `error.Unsupported` here, so the
viewer cannot ingest a single byte until that call takes the same
`platform.fdpass.supported` branch the test's LiveServer now takes
(`client.zig`, ~line 1124) — or until Step 2 lands a real darwin fdpass.
Also confirmed while there: `sokol-shdc` (osx_arm64) runs straight from the
nix store, so the Gatekeeper worry in §5 is a non-issue, and the default
socket path resolves to `/tmp/vertex.sock` — do **not** switch it to
`$TMPDIR`, which `nix develop` makes per-shell.

**Step 1 — viewer on Metal, inline path.** ✅ (2026-08-24) `sketch-current`
over the socket prints `vertex-view: structures=4 frames=25 blobs=83` on
`-Dvertex_layout=aos3` and `=soa`, no sokol error, no leak report; a
screenshot confirms mesh, points, lines and the ImGui panels rendering.

- Backend: `build.zig` passes `.gl = !target.isDarwin()` and publishes
  `build_options.gl_backend`; sokol-zig's `auto` then resolves to Metal.
  Watch out — `addOptions` mints a *new* module per call and two modules
  cannot share a source file, so the options module is created once and
  imported everywhere.
- Shaders: `-l glsl430:metal_macos`, one checked-in file per shader for
  both backends. Regenerating added only Metal; every GLCORE line is
  unchanged, so Linux needs no re-verification beyond a build.
- **`gl_PrimitiveID` does not translate.** MSL needs 2.2 for it and
  SPIRV-Cross refuses below that; sokol-shdc has no MSL version flag —
  checked against the pinned binary *and* sokol-tools-bin master, so it is
  upstream, not a stale pin. `mesh_face_scalar{,_soa}` and
  `pick_mesh{,_soa}` are listed GL-only in `build.zig` (`isGlOnlyShader`) so
  `zig build shaders` stays reproducible. Face-target scalars fall back to
  the plain mesh pipeline; the renderer decides by asking the generated desc
  whether this backend has a source, so a future shdc turns the feature back
  on by itself. If you want face scalars on Metal sooner, the options are a
  shdc built with MSL 2.2 or replacing `primitive_id` with a per-vertex face
  index (which costs vertex duplication — weigh it against §2's layout rules).
- Picking is comptime-disabled (`pick.Picker` selects `DisabledPicker`).
  This is load-bearing, not cosmetic: a Metal build does not link OpenGL, so
  the GL externs must not be analyzed at all.

**Still open from Step 1, for whoever does Step 3:** the `VERTEX_PICK_PROBE`
path is untested here. Retina reports a 2× framebuffer, and the expected
face (693 on a 1400×900 Xvfb) is display-dependent — re-pin per platform, or
fix the window size and dpi scale for the smoke.

**Step 2 — platform layer for darwin (restore zero-copy).** ✅ (2026-08-24)
`sketches/stress.zig` in shared mode reports `mapped_bytes=480960480`, the
figure the Linux smoke pins, and send collapses from 348.3 ms to 3.8 ms over
the 40 steps (92×; viewer apply 62.7 → 6.6 ms; 517 MB → 36 MB through the
socket). Test skips went 3 → 1: only the `/proc`-rebasing sockpath test is
left, and the live socket round-trip now asserts the zero-copy flag *here*
because of the ratchet added in Step 0.

Two things not to copy blindly from the Linux files if you touch them:

- `fdpass_darwin.zig` is not a transliteration. `CMSG_ALIGN` is
  `__DARWIN_ALIGN32` — 4 bytes, not `sizeof(size_t)` — and `cmsghdr` is 12
  bytes not 16, so Linux's cmsg arithmetic computes wrong lengths *silently*.
  There is no `MSG_NOSIGNAL` (set `SO_NOSIGPIPE` on the socket) and no
  `MSG_CMSG_CLOEXEC` (mark each received fd). `std.c` declares `recvmsg` but
  does not export it, so the module declares its own extern.
- `shm_darwin.zig` names each object, then `shm_unlink`s it immediately so
  the descriptor is its only reference — otherwise a crash leaves objects in
  a global namespace. `O_EXCL` makes a name collision a retry.

`stats`: `getrusage` was enough; `task_info` is not needed, because `stats`
only exposes minor faults and hugetlb KiB. `sockpath` keeps the rejection
path (`sockpath_unsupported`, 103 bytes) — no `/proc` to rebase on and no
demand for it yet. Huge pages are now the comptime `shm.huge_supported`
rather than something inferred, because the viewer, the client and the
stress sketch were all advertising `huge=on` on a platform that has no
huge-page class.

**Step 3 — picking: superseded, and deliberately last.** Do *not* write a
Metal readback. Decided 2026-08-24 (rationale in DESIGN.md, "Picking,
decided 2026-08-24"): picking becomes a **CPU ray cast in the pure core**,
which needs no readback on any backend and deletes the GL escape hatch, the
four `pick_*` shaders and the `RG32UI` target.

Two things to know before starting it. The synchronous Metal readback this
step used to describe cannot work — sokol creates one command buffer per
frame, `enqueue`s it at the first `beginPass`, commits it at `sg.commit()`
and never exposes it, so a mid-frame blit + `waitUntilCompleted` waits behind
a command buffer that has not been committed. And hover picking today
re-renders every visible structure per mouse move, so the CPU version starts
from a low bar; brute force first, measure, then a per-blob BVH cached like
the derived edge lists.

It is sequenced after Steps 2, 4 and 5 because it is a redesign of a working
feature, not a port step. Owes before/after numbers and a check that a CPU
hit agrees with a GL hit on the same scene. The retina/dpi question below
belongs to it.

**Step 4 — dylib mode.** ✅ (2026-08-24) Worked essentially unchanged:
`zig build step` already names the artifact `libstep-<name>.dylib`,
`std.DynLib` is `dlopen`, and macOS raises no code-signing objection to
`dlopen`ing the viewer's copy. Only the copied-library path's hardcoded
`.so` needed fixing. `stepper steps=60 state=finished reloads=0 leaks=0`
with `structures=1 frames=61 blobs=123`, and an edit + rebuild mid-session
gives `reloads=1` with the previous run retained (`blobs=246`).

If you test reload by hand: a rebuild with no source *content* change does
not reload, on any platform. The stepper polls the installed artifact's
mtime and zig's install step skips the copy when the artifact is
byte-identical, so `touch` + rebuild leaves mtime alone. Edit something.

**Step 5 — smokes on a Mac.** ✅ (2026-08-24) SMOKE OK in ~46 s, every
scenario and every assertion, leak checks included. Four windows appear and
close — there is no Xvfb. All platform differences are one block at the top
of `scripts/smoke.sh`: the viewer wrapper, the step-library suffix, the
frame caps (smaller here because vsync paces frames where llvmpipe does
not), and the pick probe, which is asserted to *miss* while picking is
disabled so the path is still exercised and the assertion must be revisited
deliberately when the CPU ray cast lands. §5's worry about the build-summary
wording was unfounded: `" debug native"` appears for darwin targets too.

Fill in one row of DESIGN.md's portability table per step; update the
table and this file as facts replace guesses.

## 4b. What is left

The port is done: Steps 0, 1, 2, 4 and 5 are all ✅ and the smokes pass. The
one feature not working on macOS is **picking**, deliberately — see Step 3
above. Face-target scalars are also off, blocked upstream on MSL 2.2
(Step 1); they come back for free if sokol-shdc ever gains the flag.

## 5. Things that will bite

- `std.Io.Threaded` on Darwin (kqueue path) is untested by us; the socket
  server and stepper use `std.Io.Mutex`/`Condition` — watch for surprises.
- `MAP_POPULATE`, `memfd_create`, hugetlbfs, abstract sockets, `/proc`:
  all Linux-only; every use is inside `src/platform/*_linux.zig` or a test.
- The hugetlb notice and `VERTEX_SHARED_HUGE` are meaningless on macOS; the
  stubs report `huge=off` — do not emit the notice there.
- ~~sokol-shdc darwin binary is unsigned; Gatekeeper may quarantine it~~ —
  checked 2026-08-24: the `osx_arm64` binary runs from the nix store as-is
  (`sokol-shdc --help` exits 0). Nothing to do.
- `scripts/smoke.sh` greps `" debug native"` in the build summary to insist
  on a Debug build; the summary wording may differ for darwin targets.

## 6. Commands

```
nix develop                                   # toolchain + libs
zig build test --summary all [-Dvertex_layout=aos4|soa]
zig build run-viewer                          # terminal 1
zig build run-sketch --watch [-Dsketch=NAME]  # terminal 2 (socket mode)
zig build step -Dsketch=smooth --watch        # dylib mode library
zig build shaders                             # regenerate shader bindings
zig build bench                               # ReleaseFast benchmarks
nix develop -c scripts/smoke.sh               # headless end-to-end (Linux)
```

## 7. Suggested opening prompt for the macOS session

> We're porting vertex to macOS. Read CLAUDE.md, DESIGN.md, STYLE.md and
> HANDOFF-macos.md, then start with Step 0 of the handoff: get
> `nix develop -c zig build test` green on this Mac, fixing the flake and
> the Linux-only tests as described. Commit logical chunks as you go; keep
> the pure core untouched unless a real gap forces it, and record every
> macOS fact you establish in the portability table.
