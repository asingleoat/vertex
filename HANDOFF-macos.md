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

## 3. Prep already done on Linux (untested on a Mac — expect to adjust)

- `flake.nix` lists `aarch64-darwin`; the dev shell gates Linux-only inputs
  (glibc headers, X11/GL/ALSA libs, `gdb`, `xvfb-run`) and the glibc pin
  hook (`ZIG_DYNAMIC_LINKER` etc.) behind `hostPlatform.isLinux`; the
  `sokol-shdc` derivation picks the `osx_arm64` binary (hash prefetched).
  `nix eval .#devShells.aarch64-darwin.default.drvPath` evaluates, that is
  all that could be checked here. (`x86_64-darwin` was dropped: nixpkgs
  26.11 no longer supports it.)
- `build.zig`'s target pinning only acts when `ZIG_DYNAMIC_LINKER` is set,
  so it is inert on macOS. The zig `overrideAttrs` patch (maker
  `--dynamic-linker` dangling-slice bug) is harmless on macOS.

## 4. The port, in order (each step has a done-criterion; stop and think if one fails)

**Step 0 — toolchain and pure core.** `nix develop -c zig build test`.
Expect friction: zig needs the macOS SDK for `-lc`/frameworks — check
`SDKROOT`/`xcrun` inside the shell (nixpkgs provides `apple-sdk`; zig's
darwin detection uses `xcrun --show-sdk-path`). Tests that are Linux-only by
construction and will need a darwin twin or a skip: the shm round trip
(`platform.zig` → `shm_linux` test), `sockpath_linux.zig`'s long-path test
(not compiled on darwin), and `client.zig`'s live socket test — it binds a
**Linux abstract socket** (`"\0name"`); macOS has no abstract namespace, so
switch it to a short filesystem path under `std.testing.tmpDir`. The shared
buffer tests (`sharedPositions`, TooManyShared) will see `error.Unsupported`
until Step 2. Done: all remaining tests green on aarch64-darwin.

**Step 1 — viewer on Metal, inline path.** sokol-zig's `auto` backend is
Metal on macOS. Shaders: extend the `shaders` build step to emit both
backends in one file (`sokol-shdc -l glsl430:metal_macos`) so Linux stays
intact; verify `gl_PrimitiveID`, storage buffers (face scalars) and the
`RG32UI` pick target translate (SPIRV-Cross → MSL). `pick.zig` calls raw GL:
gate it out on darwin at comptime first (picking disabled) so the viewer
comes up; `sketches/current.zig` over the socket must print
`vertex-view: structures=4 frames=25 blobs=83`. Retina: sokol reports a
2× framebuffer; `VERTEX_PICK_PROBE` coordinates are framebuffer pixels, and
the probe's expected face (693 on a 1400×900 Xvfb) is display-dependent —
re-pin per platform, or fix the window size and dpi scale for the smoke.

**Step 2 — platform layer for darwin (restore zero-copy).** `fdpass`:
`SCM_RIGHTS` works on macOS — port `fdpass_linux.zig` to `std.c`/posix
`sendmsg`/`recvmsg` (no `std.os.linux`). `shm`: `shm_open` + `shm_unlink`
+ `mmap` (no memfd, no `MAP_POPULATE`, no huge pages — keep `huge` false and
the notice silent). `sockpath`: `sun_path` is 104 bytes and there is no
`/proc/self/fd`; keep the rejection path, or rebase via `fchdir`-free
tricks only if a real need appears. `stats`: `getrusage` + `task_info`.
Keep the decl-parity test honest (`platform.zig`). Done: `sketches/stress.zig`
in shared mode reports `mapped_bytes=480960480` and the client-side send
time collapses as it did on Linux (§DESIGN "Copies on the path").

**Step 3 — picking on Metal.** Replace the GL readback with a Metal one:
after the pick pass, blit the `RG32UI` target's 1×1 region into a shared
`MTLBuffer` and `waitUntilCompleted`, via sokol's Metal query hooks
(`sg.mtlDevice`/`sg_mtl_query_image_info`…) and `objc_msgSend` externs.
Keep it isolated in `pick.zig` behind a comptime backend switch, mirroring
the Linux GL escape hatch. Done: the probe reports a sphere face and the
inspector tooltip shows quantity values.

**Step 4 — dylib mode.** `std.DynLib` uses `dlopen` on macOS; the stepping
library becomes `libstep-<name>.dylib` (`build.zig` names it; the viewer's
copy-to-unique-path and never-`dlclose` policy apply unchanged). Done:
`VERTEX_STEP_LIB=… VERTEX_STEP_AUTORUN=1` prints `stepper steps=60
state=finished`, and a rebuild mid-session prints `reloads=1`.

**Step 5 — smokes on a Mac.** There is no Xvfb; `scripts/smoke.sh` needs a
darwin branch that runs on the real display (the viewer already exits by
frame count via `VERTEX_EXIT_AFTER_FRAMES`). Keep the leak assertions: a
plain `zig build` is Debug and the viewer's allocator is the leak-checking
`DebugAllocator`.

Fill in one row of DESIGN.md's portability table per step; update the
table and this file as facts replace guesses.

## 5. Things that will bite

- `std.Io.Threaded` on Darwin (kqueue path) is untested by us; the socket
  server and stepper use `std.Io.Mutex`/`Condition` — watch for surprises.
- `MAP_POPULATE`, `memfd_create`, hugetlbfs, abstract sockets, `/proc`:
  all Linux-only; every use is inside `src/platform/*_linux.zig` or a test.
- The hugetlb notice and `VERTEX_SHARED_HUGE` are meaningless on macOS; the
  stubs report `huge=off` — do not emit the notice there.
- sokol-shdc darwin binary is unsigned; Gatekeeper may quarantine it — if
  `sokol-shdc` refuses to run from the nix store, `xattr -d com.apple.quarantine`
  is not possible on a read-only store; build sokol-tools from source in the
  flake instead.
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
