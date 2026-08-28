# Maintenance

Obligations that recur, and that this project has already let slip once each.
The rules themselves live in `STYLE.md` and `DESIGN.md`; this is the list of
what to do and when, so that the doing is not left to memory.

Each item says what triggers it, because an unconditional checklist is one
nobody runs.

## When adding a public function

- **State its asymptotic complexity** as the last paragraph of its doc comment,
  naming the quantity it is measured in (`STYLE.md` §3b). Say what the bound
  depends on when that is not the input size, and whose the cost is when it is a
  dependency's.
- **Verify the label against the code, not its shape.** Four labels written from
  the shape of `scene.zig` were wrong: `versionAt` and `hasExactVersion` are
  linear scans that look like lookups, `memoryStats` counts on demand what looks
  maintained, and `enforceBudget` rescans per removal.
- **Give it a `checkAllAllocationFailures` test** if it allocates and is core
  (`STYLE.md` §5).

## When adding an operation to a hot path

- **Add a `bench/` entry** (`STYLE.md` §6). Coverage is checked by reading, so
  it decays quietly.
- **Re-run the baseline** with `zig build bench-baseline` and commit the new
  numbers, so the ratchet knows what the operation cost on the day it was
  written.
- **Check against it** with `zig build bench-check`, which fails on anything
  more than fifteen per cent slower. `BENCH_TOLERANCE` overrides the fraction,
  and `scripts/bench-check.py` lists the two benchmarks whose own noise puts
  them above it.

## When adding a dependency or a link requirement

- **Wire it in twice.** `build.zig` builds the `vertex` module once for the
  library and again per benchmark; a link requirement added only to the first
  leaves `zig build bench` broken, which is how the benchmarks stopped
  compiling and stayed that way unnoticed.

## When editing a shader

- **Regenerate with `zig build shaders`.** The generated `.zig` is checked in,
  and nothing rebuilds it automatically.

## When establishing a platform fact

- **Record it in the portability table** in `DESIGN.md`, whether it worked or
  not. The table is the reason the macOS port did not have to be rediscovered.

## Before calling a change done

- `nix develop -c zig build test` for each of `-Dvertex_layout=aos3`, `aos4` and
  `soa`. The default layout alone hides accessor bugs.
- `nix develop -c zig fmt --check src/ sketches/ bench/ steps/ build.zig`.
- `nix develop -c zig build -Drelease`, which is the build users get and the
  only one that compiles the stepping libraries.
- `nix develop -c zig build bench` if anything on a measured path moved.

## Periodically

- **Revisit the deferred decisions** under "Planned" in `DESIGN.md`. Each names
  the trigger that should bring it back: a second instantiation for the numeric
  parameterization, a mesh past `u32` for the index width, and the picking
  rewrite whenever the GPU readback next gets in the way.
- **Check the benchmark noise floor** has not drifted. The figures the harness
  records were measured over four runs of the whole suite; a threshold set
  against them is only as good as they are.
- **Leave the deliberate gaps alone, or close them knowingly.** Nothing in
  `src/viewer/render` or `src/platform` is benchmarked: their cost is a GPU
  driver's and a kernel's, and a gate on them would report on the machine
  rather than on this code. That is a decision, not an omission.
