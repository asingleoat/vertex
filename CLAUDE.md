# vertex

Persistent geometry visualization viewer with a hot-recompile loop, in Zig.

Read before writing code:
- `HANDOFF-macos.md` — if you are on macOS: project state, working agreements, and the ordered port plan.
- `DESIGN.md` — architecture, protocol, scene model, milestones.
- `STYLE.md` — coding rules. Non-negotiable summary:
  1. Index, don't point: typed `enum(u32)` handles into flat arrays; no pointer-linked structures.
  2. Explicit allocators; reserve-then-assumeCapacity; hot paths allocate nothing in steady state.
  3. Layout is a type: vertex data only via `Positions` named accessors (default `.aos3`, `.aos4`/`.soa` benchable), `MultiArrayList` records, size-asserted structs, `u32` indices.
  4. Pure core (`protocol`, `scene`, `camera`, `geometry/*`) / effectful edges (`server`, `main`, `ui`, `render/*`).
  5. Every allocating core function has a `checkAllAllocationFailures` test; hot paths have a `bench/` entry.

Environment: NixOS. Use the flake dev shell (`nix develop`) for zig/zls/system libs; no global installs.
