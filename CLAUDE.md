# vertex

A persistent geometry visualization viewer with a hot-recompile loop, in Zig.
A *sketch* is a program written against the client library; a *structure* is one
named renderable in the viewer; a *quantity* is a named field attached to a
structure; a *run* is one execution of a sketch and a *frame* one step within
it. `DESIGN.md` defines these once and they are used throughout.

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
- `MAINTENANCE.md` — what to do and when: the recurring obligations that come
  with adding a function, an operation on a hot path, a dependency or a shader,
  and what to run before calling a change done.

Comments and documentation are plain technical English: full sentences,
established terminology, and a statement of behaviour, arguments, return value,
intended use and ownership. They address "the caller" rather than the reader,
and are as long as the subject requires and no longer. Documentation lives at
the definition, and a doc comment on a value declaration separates paragraphs
with `/// ---` rather than an empty `///` line, which autodoc treats as the end
of the comment. See `STYLE.md` §8.

The development environment is a nix flake dev shell. Use `nix develop` for zig,
zls and the system libraries; nothing is installed globally.
