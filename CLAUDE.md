# vertex

A persistent geometry visualization viewer with a hot-recompile loop, in Zig.

Read before writing code:

- `DESIGN.md` — architecture, wire protocol, scene model, portability and
  milestones.
- `STYLE.md` — coding rules. In summary:
  1. Entities live in flat arrays addressed by typed `enum(u32)` handles; no
     pointer-linked structures.
  2. Allocators are explicit; reserve capacity and then append without checks;
     hot paths allocate nothing in steady state.
  3. Vertex data is reached only through the named accessors of `Positions`,
     which defaults to `.aos3` with `.aos4` and `.soa` available for
     measurement; records are `MultiArrayList`; hot structs assert their size;
     indices are `u32`.
  4. The core — `protocol`, `scene`, `camera`, `geometry/*` — is pure, and the
     edges — `server`, `main`, `ui`, `render/*` — hold the effects. This governs
     which module a declaration belongs in, not only how it is written.
  5. Every allocating core function has a `checkAllAllocationFailures` test, and
     every hot path has an entry in `bench/`.
- `HANDOFF-macos.md` — the state of the macOS port and what remains.

Comments and documentation are plain technical English: full sentences,
established terminology, and a statement of behaviour, arguments, return value,
intended use and ownership. They address "the caller" rather than the reader.

The development environment is a nix flake dev shell. Use `nix develop` for zig,
zls and the system libraries; nothing is installed globally.
