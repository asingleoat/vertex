# vertex — coding practice & style

Companion to `DESIGN.md`. `DESIGN.md` says *what* we build; this says *how*.
The target is the metal: contiguous memory, predictable access, no hidden
allocation, no pointer chasing, and a core that can be tested and benchmarked
without a window or a socket.

## 0. The four rules

1. **Index, don't point.** Entities live in flat arrays and are referenced by
   typed `u32` index. Pointer-linked structures are banned.
2. **Allocate deliberately.** Every allocation is visible (explicit `Allocator`
   parameter), owned by a store, and reused. Hot paths are allocation-free in
   steady state.
3. **Layout is a type.** Vertex streams are accessed only through named
   accessors on a build-selected `Positions` type, so a layout change is one
   build option and every kernel recompiles to the new offsets. Records are SoA
   via `MultiArrayList`. Field order and sizes are asserted in tests.
4. **Pure core, effectful edges.** If it can be tested without sokol, imgui, a
   socket, a thread, or the clock, it is core and lives in a core module.

## 1. Programming without pointers

Following Andrew Kelley's "Programming Without Pointers" / "Practical DOD".

- **Typed handles.** Indices are non-exhaustive enums, never bare integers, so
  a `BlobIndex` cannot be passed where a `StructureIndex` is expected:
  ```zig
  pub const StructureIndex = enum(u32) { none = std.math.maxInt(u32), _ };
  pub const BlobIndex      = enum(u32) { none = std.math.maxInt(u32), _ };
  ```
  The `none` sentinel replaces `?*T` at zero size cost. Use `.none`, not
  `?Index`, in stored fields.
- **One owner, flat arrays.** `Scene` owns `structures`, `versions`, `blobs` as
  `MultiArrayList`/`ArrayListUnmanaged`. Nothing is individually heap-allocated.
  No linked lists, no pointer trees, no `*T` stored inside long-lived structs.
- **Variable-length per-entity data** lives in a shared side array with
  `(start, len)` ranges — Zig-compiler `extra_data` style. Example: a version's
  quantity list is a range into `Scene.quantity_refs`.
- **Strings are interned.** One `bytes: ArrayListUnmanaged(u8)` plus a
  `StringIndex`; dedup via `std.hash_map.StringIndexContext`. Structure and
  quantity names are interned once on first registration.
- **Stable references are indices.** Never hold a pointer or slice across a
  call that may grow the list it came from. Hold the index, re-slice after.
- **Pointers that are fine:** slices (fat pointers to contiguous data — that is
  the whole point), `*Self`/`*const Self` method receivers, out-parameters, and
  the FFI boundary (sokol, cimgui). Keep FFI pointers inside edge modules.
- **Free lists over compaction.** Freed blob/structure slots go on a free list
  (`ArrayListUnmanaged(BlobIndex)`) and are reused; arrays never shrink during a
  session. Indices stay valid for the lifetime of the entity, full stop.

## 2. Memory allocation

- **Explicit allocators.** Any function that may allocate takes
  `gpa: std.mem.Allocator` (long-lived) and/or `scratch: std.mem.Allocator`
  (temporaries) as leading parameters. No global allocators, no hidden
  allocation in helpers. Use unmanaged containers exclusively.
- **Ownership is a `deinit`.** A struct that owns memory has
  `deinit(self, gpa)`; what it owns is exactly what it frees. Data crossing the
  edge→core boundary is copied into store-owned memory at the edge (client lib
  copies caller slices into its send buffer; viewer decode copies payloads into
  blobs). Inside the core, slices are borrowed, never retained.
- **Reserve, then assume.** The "preallocated buffer with fallback resizing"
  pattern is literally:
  ```zig
  try list.ensureUnusedCapacity(gpa, n);   // one fallible call, may grow
  for (items) |it| list.appendAssumeCapacity(f(it));   // n infallible appends
  ```
  Count first, reserve once, fill without checks. Never `append` in a loop
  when `n` is knowable.
- **Retain capacity.** Long-lived working buffers use `clearRetainingCapacity`;
  per-frame/per-message temporaries use an arena reset with
  `.retain_capacity`. Steady-state hot paths (queue drain, message decode,
  derived-data computation, render submission) must perform zero allocations;
  growth is the fallback on a new high-water mark, not the norm. A test that
  runs a hot path twice and asserts the allocator saw no calls the second time
  is the enforcement mechanism (see §5).
- **Scratch arenas.** The viewer owns one per-frame arena; the decoder owns a
  per-message arena; benchmarks and tests own their own. Pass `scratch`
  explicitly — a function that needs temporaries says so in its signature.
- **Never per-element.** No allocation inside a loop over vertices, faces,
  messages, or structures. If you find one, hoist a buffer to the owner.
- **OOM is an error, not a panic.** Propagate `error.OutOfMemory`. `catch
  unreachable` is permitted only immediately after an `ensure*Capacity` that
  covers it, and `assumeCapacity` variants are preferred over that.
- **Alignment.** Blob payloads are allocated with `alignedAlloc` at 64 bytes so
  `@Vector` loads over the flat `f32` view and future GPU staging are aligned.

## 3. Data layout

- **Records → SoA.** `std.MultiArrayList` for anything iterated field-wise
  (structures, versions, blobs, UI state). Loops take `.items(.field)` slices.
  Use `.slice()` once and index it; do not call `.items(...)` inside the loop.
- **Vertex layout is a type, not a convention.** Vertex positions/vectors are
  never raw `[]f32` with stride arithmetic and never `[][3]f32` indexed by
  number. The element is an `extern struct` with named fields, and the stream
  is a type selected once at build time:
  ```zig
  pub const Vec3 = extern struct { x: f32, y: f32, z: f32 };              // 12 B, compact
  pub const Vec3Padded = extern struct { x: f32, y: f32, z: f32, w: f32 = 0 }; // 16 B, @Vector-castable

  pub const Layout = enum { aos3, aos4, soa };
  pub fn PositionsOf(comptime layout: Layout) type { ... }   // same API for every layout:
      // len() u32, get(i) Vec3, set(i, Vec3), plus layout-specific extras (soa: xs()/ys()/zs())
  pub const Positions = PositionsOf(build_options.vertex_layout);  // default .aos3
  ```
  Consumers use `p.x`/`get(i)`/`set(i, v)` — named accessors only, `inline fn`
  so the machine code is identical to hand-indexing. Changing
  `build_options.vertex_layout` recompiles every kernel with the new offsets and
  stride; nothing else changes. Default is `.aos3`: the most compact, best for
  straight-line SISD code because more vertices fit a cache line. `.aos4`
  (16 B stride, `@bitCast` to `@Vector(4, f32)`) and `.soa` exist to be
  benchmarked, not assumed.
- **Kernels are layout-parameterized namespaces.** Geometry code lives in
  `pub fn Geometry(comptime layout: Layout) type { return struct { ... }; }` with
  the canonical instantiation `pub const geometry = Geometry(build_options.vertex_layout);`.
  Normal code calls `geometry.computeNormals(...)` — monomorphic, no generics at
  call sites. `bench/` instantiates `Geometry(.aos3)`, `Geometry(.aos4)`,
  `Geometry(.soa)` side by side on the same inputs. Agnostic as far as possible,
  specialized where measured: a kernel may `switch (layout)` at comptime to take
  a planar fast path, with the accessor path as the always-correct fallback.
- **The wire format derives from the type.** We own both ends, so the wire
  payload for a stream *is* the blob bytes: `Positions.bytes()` on the client
  and `Positions.fromBytes()` in the viewer define serialization and memory
  layout simultaneously, native endianness, no conversion for any layout.
  Compatibility is the protocol version number alone — identical versions
  talk, anything else is rejected — so a layout change bumps the version like
  any other wire change. No per-field validation. The client sends the header
  from a stack buffer and the payload via `writev` straight from caller memory
  — zero copies client-side; the viewer's one copy into a 64-byte-aligned blob
  is the socket's unavoidable cost (memfd path removes it later). A foreign-
  language client must speak the viewer's layout; the protocol is
  language-agnostic, not layout-agnostic.
- **GPU layout derives from the type.** sokol vertex strides and attribute
  offsets come from `@sizeOf(Positions.Elem)` / `@offsetOf`, so AoS variants
  flow to the GPU untouched; `.soa` binds one vertex buffer per component
  (render edge `switch (layout)` — the only place that cares).
- **Other streams:** triangles `[]const [3]u32` and segments `[]const [2]u32`
  (topology is consumed positionally by design and has no layout variant);
  scalar quantities `[]const f32` (single component, layout-free).
- **`u32` indices everywhere.** Not `usize`. Halves index memory and 4 G
  elements is the ceiling regardless. Convert at the slice-indexing site via a
  tiny helper; `@intCast` does not appear in loop bodies.
- **Hot structs are size-asserted.** Order fields largest → smallest; flags go
  in a `packed struct(u8)`. Every hot record has a test:
  `try std.testing.expectEqual(24, @sizeOf(Version));` Layout regressions
  must be loud.
- **Wire structs are `extern struct`** with explicit little-endian fields, so
  header parsing is a `bytesAsValue`, not a field-by-field read. No padding
  holes in wire structs — assert `@sizeOf` equals the documented byte count.
- **Tagged data.** Enum tags with payload in side arrays, not tagged unions
  holding the largest variant inline, when variants differ greatly in size.

## 4. Pure core, effectful edges

- **Core modules:** `protocol`, `scene`, `camera`, `geometry/*` (normals, edge
  extraction, bounding boxes, colormap LUTs, pick-ID encode/decode). Zero
  imports of sokol, cimgui, `std.net`, `std.Thread`, `std.time`, `std.fs`.
  No globals. Inputs are slices + allocators; outputs go to caller-provided
  buffers or returned store mutations.
- **Edge modules:** `server.zig` (socket thread), `main.zig` (sokol callbacks),
  `ui.zig` (imgui), `render/*` (buffer creation, draw calls). Thin glue:
  translate bytes ↔ core calls, core results ↔ GPU/UI calls. No geometry math
  in an edge module.
- **Spiritually pure** means no hidden state and no hidden effects, not
  immutability. `fn computeNormals(positions, indices, out: [][3]f32) void`
  is pure in spirit: deterministic, effect-free, allocation-free.
- **GPU handles live at the edge.** The pure `Scene` blob store knows nothing
  of sokol. The render edge keeps a parallel `ArrayListUnmanaged(sg.Buffer)`
  indexed by `BlobIndex` and an upload queue of blob indices the core reports
  as new. Parallel arrays by index is the no-pointer way to attach edge state
  to core entities.
- **One thread boundary.** The socket thread → staging queue → render thread
  handoff is the only cross-thread contract in the program. Everything else is
  single-threaded by construction. The queue owns its memory; decoded batches
  are handed over whole.
- **Explicit, narrow error sets** at module boundaries
  (`pub const DecodeError = error{ Truncated, BadMagic, ... }`). `anyerror`
  never appears. Edges translate errors to logs; core never logs.

## 5. Testability

- Tests live in-file as `test` blocks; `zig build test` runs everything.
- **`std.testing.allocator` always** — it is leak-detecting, and a leaked byte
  fails the test.
- **`std.testing.checkAllAllocationFailures`** is mandatory for every core
  function that allocates. It re-runs the function failing each allocation in
  turn and verifies no leak on any OOM path. Structure allocating code so its
  work is a single function taking `(allocator, args...)` to make this trivial.
- **Steady-state allocation tests.** Wrap `std.testing.allocator` in a counting
  allocator (`std.mem.Allocator` VTable shim or `std.heap.DebugAllocator`
  stats), run a hot path twice, assert zero allocations on the second run.
- **Round-trip tests** for the protocol: encode → decode must reproduce the
  input bit-for-bit; truncated and corrupted inputs must return an error, never
  panic. Use `std.testing.fuzz` on the decoder where the toolchain supports it.
- **Headless viewer tests.** Because `Scene` and `protocol` are pure, a full
  "client sends these messages, scene now contains this" test is bytes in,
  assertions out — no window.
- **Procedural fixtures** (grid meshes, icospheres, random point sets from a
  seeded `std.Random.DefaultPrng`) over checked-in files.
- **Asserts are free.** `std.debug.assert` every invariant: indices in range,
  capacities ensured, refcounts nonzero. They vanish in `ReleaseFast`, which
  is what a *user* gets from `-Drelease` — so they are a development
  instrument, not a runtime guarantee. Develop and verify in Debug or
  `ReleaseSafe`, where they and the bounds/overflow checks are live; that is
  where a bad index has to be caught, because in the shipped mode it is
  undefined behaviour instead of a panic.

## 6. Benchmarkability

- `zig build bench` builds `bench/*.zig` in `ReleaseFast`, one file per hot
  path: decode, normals, edge extraction, scene drain, colormap mapping.
- Harness convention: warm-up, N timed iterations with `std.time.Timer`,
  `std.mem.doNotOptimizeAway` on results, report ns/op plus a domain throughput
  (verts/s, MB/s). Sizes swept over 1e3 / 1e5 / 1e6 elements.
- Purity is what makes this free: every hot path is a function over slices
  with a caller-provided scratch, so a benchmark is just a loop.
- When a change touches a hot path, paste before/after numbers into the commit
  message.

## 7. SIMD and GPU — deferred, not ignored

- Write scalar loops over flat slices with no early exits and no per-element
  callbacks. That shape vectorizes with `@Vector` later as a local change and
  is the shape a compute shader wants.
- Kernels are batch-shaped: arrays in, arrays out. Never an iterator/visitor
  API over elements in the core.
- SIMD experiments start by benchmarking `Geometry(.aos4)` (`@Vector(4, f32)`
  via `@bitCast`) and `Geometry(.soa)` against the default; a layout wins only
  with numbers from `zig build bench`, measured over the whole
  encode→socket→blob→kernel→GPU path (padding bytes travel the wire in `.aos4`;
  that bandwidth is part of the cost). Kernels written against the accessor API
  need no changes to take part.
- 64-byte aligned blobs (§2); scratch buffers may pad counts to multiples of 8.
- Branchless over clever: prefer `@select`/arithmetic masks to data-dependent
  branches inside kernels when it costs no clarity.

## 8. Zig conventions

- Zig version pinned by the flake; `zig fmt` clean is a CI condition.
- Naming per `std`: `TitleCase` types, `camelCase` functions, `snake_case`
  fields/variables/files.
- `comptime` for tables (colormap LUTs baked at compile time), not for
  cleverness. `anytype` only in small generic numeric helpers, never in public
  core APIs.
- Doc comments on every `pub` declaration in core modules state ownership and
  allocation behaviour: who owns the output, whether the function allocates,
  which allocator it uses.
- `-Drelease` is `ReleaseFast`: the mode a user writing sketches gets, and
  what benches always use. Build the viewer in Debug or `ReleaseSafe` while
  working on vertex itself.
