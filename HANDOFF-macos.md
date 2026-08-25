# The macOS port

Written on the Linux machine at the end of the first development stretch and
completed on 2026-08-25. `git log --oneline` records the reasoning behind each
change.

## State

Everything on the original design ladder is built and verified on Linux:

- The viewer, on sokol-gfx with GL 4.3 and Dear ImGui; the socket client
  library; wire protocol version 2; the scene store with its delta timeline;
  the memory budget with decimation; meshes, points, lines and vectors with
  scalar colormaps, wireframes, picking and an inspector, including
  face-target scalars.
- Zero-copy shared-memory payloads, using memfd and `SCM_RIGHTS`, with hugetlbfs
  where the kernel allows it. Forty updates of one million vertices take 16 ms
  of client time.
- Dylib mode: viewer-driven stepping with hot reload, from `steps/*.zig` to
  `libstep-<name>.so`, with Frame, Rate and Max pacing.
- The platform layer in `src/platform/`, selected per operating system at
  compile time, with `*_unsupported.zig` stubs that compile everywhere and
  degrade to the inline path.
- 69 tests across the three vertex layouts, selected by
  `-Dvertex_layout=aos3|aos4|soa`, and headless end-to-end tests in
  `scripts/smoke.sh`.

The same is now true on aarch64-darwin, with two exceptions recorded under
"What is left" below.

The toolchain is zig master, `0.17.0-dev.1857`, pinned by `flake.lock` through
`mitchellh/zig-overlay`; zls comes from the `zigtools/zls` flake; sokol-zig and
dcimgui are on their master branches. Everything comes from nix: use
`nix develop` and the paths it resolves rather than `/nix/store` paths directly.

## Working agreements

- Commit in logical chunks, each with a message recording the decision and the
  verification performed. The history is the design log.
- Track bleeding-edge Zig through nix, as new as sokol-zig and dcimgui support.
  Known quirks of master: `@bitCast` to or from an extern struct is rejected, so
  build the value field by field or read it through `*align(1) const T`;
  `OptimizeMode` is lowercase; fetched packages live in `zig-pkg/`; the
  configure phase is cached, and `build.zig` poisons that cache so that new
  sketches are discovered; `-Drelease` selects ReleaseFast and a plain
  `zig build` is Debug.
- Optimize paths that are known to be wasteful even when they are not the
  bottleneck. Measure to decide priority and to verify the result, never to
  dismiss the question, and present before and after numbers.
- Tests must earn their place. Keep contracts, regressions, ABI and format
  pins, and checks of out-of-memory behaviour, leaks and steady-state
  allocation; remove scaffolding. Pin measured quantities exactly, as a ratchet
  rather than a ceiling, so that the cost of a change is visible when it is made
  and the pin moves deliberately.
- Keep the core pure and the effects at the edges, per `STYLE.md` §4: no
  operating-system or sokol call outside `src/platform/` and the viewer edge
  modules, and no effects in scene, protocol or geometry. This applies to file
  organization as well as to individual functions: a module is either pure or an
  edge, and an edge imports pure modules rather than the reverse.
- If delegating to Codex, write a self-contained brief covering the task, the
  definition of done, the scope, the verification loop and the output contract.
  The sandbox may be unable to reach the nix daemon, in which case
  `nix print-dev-env > devenv.sh` and have it source that. Re-verify everything,
  and review for test-gaming and scope creep.
- Tim's global git configuration sets `worktree.useRelativePaths`, which the
  libgit2 that nix uses cannot read, so pass
  `git worktree add --no-relative-paths`.

## The port

**Step 0, the toolchain and pure core.** Completed 2026-08-24.
`nix develop -c zig build test` reports 34 of 34 steps and 66 of 69 tests, with
three skipped, on each of `aos3`, `aos4` and `soa`. Every fact is in the
portability table in `DESIGN.md`; two were expensive to find.

The glibc pin fired on macOS. `flake.nix` gated it on the existence of
`$NIX_CC/nix-support/dynamic-linker`, but the nixpkgs Darwin cc wrapper ships
that file too, holding `/usr/lib/dyld`, so the target was pinned to
`aarch64-native-gnu` with a glibc version parsed out of `libSystem-B`. Both the
hook and `resolveTarget` are now gated on Linux.

zig 0.17.0-dev.1857 skips Darwin SDK detection entirely when either
`NIX_CFLAGS_COMPILE` or `NIX_LDFLAGS` is set; either alone is sufficient. Every
`-framework` then fails with `searched paths:  none`. The Darwin branch of the
shell hook unsets both, and `DEVELOPER_DIR` and `SDKROOT` from the apple-sdk
setup hook keep `xcrun` pointed at the pinned SDK. If frameworks go missing
again, check those two variables first.

The three failing tests were Linux-only by construction and went as predicted:
the abstract socket became a file under `std.testing.tmpDir`, and the
`/proc`-rebasing and shared-memory tests skip. Capability is now a
`pub const supported` on the platform module rather than a comparison against
`builtin.os.tag`, so step 2 enabled the zero-copy path by writing the module
with no operating-system checks left to find outside `src/platform/`.

**Step 1, the viewer on Metal with the inline path.** Completed 2026-08-24.
`sketch-current` over the socket prints
`vertex-view: structures=4 frames=25 blobs=83` for both `aos3` and `soa`, with
no sokol error and no leak report, and a screenshot confirms that meshes,
points, lines and the ImGui panels render.

`build.zig` passes `.gl = !target.isDarwin()` and publishes
`build_options.gl_backend`, after which sokol-zig's `auto` backend resolves to
Metal. Note that `addOptions` creates a new module on each call and two modules
cannot share a source file, so the options module is created once and imported
everywhere.

Shaders are generated with `-l glsl430:metal_macos`, one checked-in file per
shader carrying both backends. Regenerating added only the Metal branch and left
every GLCORE line unchanged, so Linux needs no verification beyond a build.

`gl_PrimitiveID` does not translate. MSL requires version 2.2 for it and
SPIRV-Cross rejects anything below that, and sokol-shdc exposes no flag for the
MSL version; this was checked against the pinned binary and against
sokol-tools-bin master, so it is an upstream limitation rather than a stale pin.
`mesh_face_scalar{,_soa}` and `pick_mesh{,_soa}` are listed as GL-only in
`build.zig`, through `isGlOnlyShader`, so that `zig build shaders` remains
reproducible. Face-target scalars fall back to the plain mesh pipeline, and the
renderer decides by asking the generated descriptor whether this backend has a
source, so a later shader compiler re-enables the feature without a code change.
Restoring it sooner requires either a shdc built with MSL 2.2 or replacing
`primitive_id` with a per-vertex face index, which costs vertex duplication.

Picking is disabled at compile time, with `pick.Picker` selecting
`DisabledPicker`. This is load-bearing rather than cosmetic: a Metal build does
not link OpenGL, so the GL externs must not be analyzed at all.

**Step 2, the platform layer for darwin.** Completed 2026-08-24.
`sketches/stress.zig` in shared mode reports `mapped_bytes=480960480`, the
figure the Linux smoke test pins, and sending collapses from 348.3 ms to 3.8 ms
over the 40 steps, a factor of 92; viewer apply falls from 62.7 ms to 6.6 ms and
the socket carries 36 MB rather than 517 MB. Skipped tests fell from three to
one, the remaining one being the `/proc`-rebasing test, and the live socket
round trip now asserts the zero-copy flag here.

Two things not to copy from the Linux files. `fdpass_darwin.zig` is not a
transliteration: `CMSG_ALIGN` is `__DARWIN_ALIGN32`, four bytes rather than
`sizeof(size_t)`, and `cmsghdr` is 12 bytes rather than 16, so the Linux cmsg
arithmetic computes incorrect lengths silently. There is no `MSG_NOSIGNAL`, so
set `SO_NOSIGPIPE` on the socket, and no `MSG_CMSG_CLOEXEC`, so mark each
received descriptor. `std.c` declares `recvmsg` without exporting it, so the
module declares its own extern. `shm_darwin.zig` names each object and unlinks
it immediately, so that the descriptor is its only reference and a crash leaves
nothing behind; `O_EXCL` makes a name collision a retry.

`getrusage` alone was sufficient for `stats`, so `task_info` was not needed.
`sockpath` keeps the rejection path, since there is no `/proc` to rebase on and
no demand for an alternative. Huge pages became the compile-time
`shm.huge_supported`, because the viewer, the client and the stress sketch were
otherwise reporting `huge=on` on a platform with no huge-page class.

**Step 3, picking.** Superseded. Do not write a Metal readback. As decided on
2026-08-24, and recorded in `DESIGN.md` under "Picking: a CPU ray cast rather
than an ID buffer", picking becomes a CPU ray cast in the pure core, which needs
no readback on any backend and removes the GL escape hatch, the four `pick_*`
shaders and the `RG32UI` target.

Two things to know before starting it. The synchronous Metal readback this step
used to describe cannot work: sokol creates one command buffer per frame,
enqueues it at the first `beginPass`, commits it at `sg.commit()` and never
exposes it, so a mid-frame blit followed by `waitUntilCompleted` waits on a
command buffer queued behind an uncommitted one. And hover picking currently
re-renders every visible structure on every mouse movement, so the CPU
implementation starts from a low bar: implement brute force first, measure, then
add a per-blob BVH cached as the derived edge lists are.

It is sequenced after steps 2, 4 and 5 because it is a redesign of a working
feature rather than a port step. It owes before and after numbers and a check
that a CPU hit agrees with a GL hit on the same scene. The retina and dpi
question below belongs to it.

**Step 4, dylib mode.** Completed 2026-08-24, essentially unchanged.
`zig build step` already names the artifact `libstep-<name>.dylib`,
`std.DynLib` is `dlopen`, and macOS raises no code-signing objection to
`dlopen`ing the viewer's copy. Only the copied library path's hardcoded `.so`
needed fixing. The result is `stepper steps=60 state=finished reloads=0 leaks=0`
with `structures=1 frames=61 blobs=123`, and an edit followed by a rebuild
mid-session gives `reloads=1` with the previous run retained.

When testing reload by hand, note that a rebuild producing an identical artifact
does not reload, on any platform: the stepper polls the installed artifact's
mtime, and zig's install step skips the copy when the artifact is unchanged, so
touching a source and rebuilding leaves the mtime alone. Edit something.

**Step 5, the smoke tests.** Completed 2026-08-24. The suite passes in about 46
seconds, with every scenario and assertion including the leak checks. Four
windows appear and close, since there is no Xvfb. Every platform difference is
in one block at the top of `scripts/smoke.sh`: the viewer wrapper, the step
library suffix, the frame caps, which are smaller because vsync paces frames
where llvmpipe does not, and the pick probe, which is asserted to miss while
picking is disabled, so that the path is still exercised and the assertion has
to be revisited deliberately. The concern that the build summary might word
Debug builds differently on Darwin was unfounded: `" debug native"` appears
there too.

## What is left

The port is complete. Two features do not work on macOS.

Picking is disabled deliberately, pending the CPU ray cast described above.

Face-target scalars are blocked upstream on MSL 2.2. They render as plain meshes
and will work again if sokol-shdc gains a flag for the MSL version.

## Things that will bite

- `std.Io.Threaded` on Darwin, which uses kqueue, is not otherwise exercised by
  this project. The socket server and the stepper use `std.Io.Mutex` and
  `std.Io.Condition`.
- `MAP_POPULATE`, `memfd_create`, hugetlbfs, abstract sockets and `/proc` are
  Linux-only. Every use is inside a `src/platform/*_linux.zig` file or a test.
- The hugetlb notice and `VERTEX_SHARED_HUGE` have no meaning on macOS. The
  darwin module reports `huge=off` and never prints the notice.
- `-fincremental` is Linux-only. On macOS, `zig build --watch -fincremental`
  rebuilds once and then panics with "nothing to watch" from
  `Maker/Watch/FsEvents.zig`; plain `--watch` works indefinitely.

## Commands

```
nix develop                                   # toolchain and libraries
zig build test --summary all [-Dvertex_layout=aos4|soa]
zig build run-viewer                          # terminal 1
zig build run-sketch --watch [-Dsketch=NAME]  # terminal 2, socket mode
zig build step -Dsketch=smooth --watch        # dylib mode library
zig build shaders                             # regenerate shader bindings
zig build docs                                # HTML documentation in zig-out/docs
zig build bench                               # ReleaseFast benchmarks
nix develop -c scripts/smoke.sh               # headless end-to-end tests
```
