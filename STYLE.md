# vertex — coding practice and style

A companion to `DESIGN.md`, which describes what the project builds; this file
describes how it is written. The aims are contiguous memory, predictable access
patterns, no hidden allocation, no pointer chasing, and a core that can be
tested and benchmarked without a window or a socket.

## 0. Four rules

1. Entities live in flat arrays and are referenced by typed `u32` index.
   Pointer-linked structures are not used.
2. Every allocation is visible, passed an explicit `Allocator`, owned by a
   store and reused. Hot paths allocate nothing in steady state.
3. Vertex streams are reached only through the named accessors of a
   build-selected `Positions` type, so changing the layout is one build option
   and every kernel recompiles against the new offsets. Records are
   struct-of-arrays through `MultiArrayList`. Field order and sizes are
   asserted in tests.
4. Code that can be tested without sokol, cimgui, a socket, a thread or the
   clock belongs in a core module. Everything else is an edge.

## 1. Programming without pointers

The approach follows Andrew Kelley's "Programming Without Pointers" and
"Practical DOD".

- Indices are non-exhaustive enums rather than bare integers, so that a
  `BlobIndex` cannot be passed where a `StructureIndex` is expected:
  ```zig
  pub const StructureIndex = enum(u32) { none = std.math.maxInt(u32), _ };
  pub const BlobIndex      = enum(u32) { none = std.math.maxInt(u32), _ };
  ```
  The `none` sentinel replaces `?*T` at no cost in size. Stored fields use
  `.none` rather than `?Index`.
- `Scene` owns `structures`, `versions` and `blobs` as `MultiArrayList` or
  `ArrayListUnmanaged`. Nothing is individually heap-allocated, and no linked
  list, pointer tree or `*T` is stored inside a long-lived struct.
- Variable-length per-entity data lives in a shared side array addressed by a
  `(start, len)` range, in the style of the Zig compiler's `extra_data`. A
  version's quantity list, for example, is a range into `Scene.quantity_refs`.
- Strings are interned into one `bytes: ArrayListUnmanaged(u8)` addressed by a
  `StringIndex`, deduplicated through `std.hash_map.StringIndexContext`.
  Structure and quantity names are interned once, on first registration.
- A pointer or slice is never held across a call that may grow the list it came
  from. Hold the index and take a fresh slice afterwards.
- Four uses of pointers are permitted: slices, which are fat pointers to
  contiguous data; `*Self` and `*const Self` receivers; out-parameters; and the
  FFI boundary with sokol and cimgui. FFI pointers stay inside edge modules.
- Freed blob and structure slots go on a free list, an
  `ArrayListUnmanaged(BlobIndex)`, and are reused; the arrays never shrink
  during a session. An index remains valid for the lifetime of its entity.

## 2. Memory allocation

- Any function that may allocate takes `gpa: std.mem.Allocator` for long-lived
  memory, `scratch: std.mem.Allocator` for temporaries, or both, as its leading
  parameters. There are no global allocators and no hidden allocation in
  helpers. Containers are unmanaged.
- A struct that owns memory has `deinit(self, gpa)` and frees exactly what it
  owns. Data crossing from an edge into the core is copied into store-owned
  memory at the edge: the client library copies caller slices into its send
  buffer, and viewer decoding copies payloads into blobs. Within the core,
  slices are borrowed and never retained.
- Reserve capacity once, then fill without further checks:
  ```zig
  try list.ensureUnusedCapacity(gpa, n);   // one fallible call, may grow
  for (items) |it| list.appendAssumeCapacity(f(it));   // n infallible appends
  ```
  Count first and reserve once. Do not `append` in a loop when `n` is known in
  advance.
- Long-lived working buffers use `clearRetainingCapacity`. Per-frame and
  per-message temporaries use an arena reset with `.retain_capacity`.
  Steady-state hot paths, meaning queue drain, message decode, derived-data
  computation and render submission, must perform no allocation at all; growth
  happens only at a new high-water mark. The enforcement mechanism is a test
  that runs a hot path twice and asserts the allocator saw no calls on the
  second run; see §5.
- The viewer owns one arena per frame and the decoder one per message;
  benchmarks and tests own their own. `scratch` is passed explicitly, so that a
  function needing temporaries says so in its signature.
- No allocation occurs inside a loop over vertices, faces, messages or
  structures. Hoist the buffer to the owner instead.
- Out of memory is propagated as `error.OutOfMemory`, never a panic. `catch
  unreachable` is permitted only immediately after an `ensure*Capacity` that
  covers it, and the `assumeCapacity` variants are preferred to that.
- Blob payloads are allocated with `alignedAlloc` at 64 bytes, so that
  `@Vector` loads over the flat `f32` view and later GPU staging are aligned.

## 3. Data layout

- Anything iterated field-wise, such as structures, versions, blobs and UI
  state, is a `std.MultiArrayList`. Loops take `.items(.field)` slices, calling
  `.slice()` once and indexing it rather than calling `.items(...)` inside the
  loop.
- Vertex positions and vectors are never a raw `[]f32` with stride arithmetic,
  and never a `[][3]f32` indexed by number. The element is an `extern struct`
  with named fields and the stream is a type selected once at build time:
  ```zig
  pub const Vec3 = extern struct { x: f32, y: f32, z: f32 };              // 12 B, compact
  pub const Vec3Padded = extern struct { x: f32, y: f32, z: f32, w: f32 = 0 }; // 16 B, @Vector-castable

  pub const Layout = enum { aos3, aos4, soa };
  pub fn PositionsOf(comptime layout: Layout) type { ... }   // same API for every layout:
      // len() u32, get(i) Vec3, set(i, Vec3), plus layout-specific extras (soa: xs()/ys()/zs())
  pub const Positions = PositionsOf(build_options.vertex_layout);  // default .aos3
  ```
  Consumers use `p.x`, `get(i)` and `set(i, v)` and nothing else. The accessors
  are `inline`, so the generated code matches hand-written indexing. Changing
  `build_options.vertex_layout` recompiles every kernel against the new offsets
  and stride and requires no other change. The default is `.aos3`, the most
  compact, which suits straight-line scalar code because more vertices fit in a
  cache line. `.aos4`, with a 16-byte stride that `@bitCast`s to
  `@Vector(4, f32)`, and `.soa` exist to be measured rather than assumed.
- Geometry kernels are layout-parameterized namespaces:
  `pub fn Geometry(comptime layout: Layout) type { return struct { ... }; }`,
  with the canonical instantiation
  `pub const geometry = Geometry(build_options.vertex_layout);`. Ordinary code
  calls `geometry.computeNormals(...)`, which is monomorphic and requires no
  generics at the call site, while `bench/` instantiates `Geometry(.aos3)`,
  `Geometry(.aos4)` and `Geometry(.soa)` side by side on the same inputs. A
  kernel stays layout-agnostic where it can and specializes where measurement
  justifies it, switching on the layout at compile time to take a planar fast
  path with the accessor path as the fallback.
- The wire format derives from the type. Both ends belong to this project, so
  the payload for a stream is the blob bytes themselves: `Positions.bytes()` on
  the client and `Positions.fromBytes()` in the viewer define serialization and
  memory layout at once, in native endianness, with no conversion for any
  layout. Compatibility rests on the protocol version alone, identical versions
  talking and anything else being rejected, so a layout change bumps the version
  as any other wire change does. There is no per-field validation. The client
  sends the header from a stack buffer and the payload by `writev` directly from
  caller memory, so nothing is copied on the client side. A client written in
  another language must speak the viewer's layout: the protocol is
  language-agnostic but not layout-agnostic.
- The GPU layout derives from the type as well. sokol vertex strides and
  attribute offsets come from `@sizeOf(Positions.Elem)` and `@offsetOf`, so the
  array-of-structures variants reach the GPU unchanged, while `.soa` binds one
  vertex buffer per component. The render edge is the only place that switches
  on the layout.
- Other streams are plain slices: triangles are `[]const [3]u32` and segments
  `[]const [2]u32`, since topology is consumed positionally and has no layout
  variant, and scalar quantities are `[]const f32`.
- Indices are `u32` rather than `usize`. This halves the memory spent on
  indices, and four billion elements is the ceiling in any case. Conversion
  happens at the slice-indexing site through a small helper, so that `@intCast`
  does not appear in loop bodies.
- Hot structs assert their size. Fields are ordered from largest to smallest and
  flags are collected into a `packed struct(u8)`. Every hot record has a test of
  the form `try std.testing.expectEqual(24, @sizeOf(Version));`, so that a
  layout regression fails the build rather than passing unnoticed.
- Wire structs are `extern struct` with explicit little-endian fields, so header
  parsing is a `bytesAsValue` rather than a field-by-field read. They contain no
  padding holes, and a test asserts `@sizeOf` equals the documented byte count.
- Where variants differ greatly in size, use an enum tag with the payload in a
  side array rather than a tagged union holding the largest variant inline.

## 4. Pure core, effectful edges

- The core modules are `protocol`, `scene`, `camera` and `geometry/*`, the last
  covering normals, edge extraction, bounding boxes, colormap tables and pick-ID
  encoding. They import none of sokol, cimgui, `std.net`, `std.Thread`,
  `std.time` or `std.fs`, and hold no globals. Their inputs are slices and
  allocators; their outputs are written to caller-provided buffers or applied as
  mutations to a store.
- The edge modules are `server.zig` for the socket thread, `main.zig` for the
  sokol callbacks, `ui.zig` for cimgui and `render/*` for buffer creation and
  draw calls. They are thin glue that translates bytes into core calls and core
  results into GPU or UI calls. No geometry mathematics appears in an edge
  module.
- Purity here means the absence of hidden state and hidden effects rather than
  immutability. `fn computeNormals(positions, indices, out: [][3]f32) void`
  qualifies: it is deterministic, effect-free and allocation-free.
- GPU handles live at the edge. The `Scene` blob store knows nothing of sokol;
  the render edge keeps a parallel `ArrayListUnmanaged(sg.Buffer)` indexed by
  `BlobIndex`, together with an upload queue of the blob indices the core
  reports as new. Parallel arrays indexed the same way are how edge state
  attaches to core entities without pointers.
- The handoff from the socket thread through the staging queue to the render
  thread is the only cross-thread contract in the program; everything else is
  single-threaded. The queue owns its memory and decoded batches are handed over
  whole.
- Module boundaries declare narrow error sets, such as
  `pub const DecodeError = error{ Truncated, BadMagic, ... }`. `anyerror` does
  not appear. Edges translate errors into log output; the core never logs.

## 5. Testability

- Tests live in-file as `test` blocks and `zig build test` runs all of them.
- Tests use `std.testing.allocator`, which detects leaks, so a single leaked
  byte fails the test.
- `std.testing.checkAllAllocationFailures` is required for every core function
  that allocates. It re-runs the function with each allocation failing in turn
  and verifies that no path leaks. Allocating code is structured so that its
  work is a single function taking `(allocator, args...)`, which makes this
  straightforward.
- Steady-state allocation is tested by wrapping `std.testing.allocator` in a
  counting allocator, either a `std.mem.Allocator` vtable shim or
  `std.heap.DebugAllocator` statistics, running a hot path twice and asserting
  no allocation on the second run.
- The protocol has round-trip tests: encoding then decoding must reproduce the
  input exactly, and truncated or corrupted input must return an error rather
  than panic. Use `std.testing.fuzz` on the decoder where the toolchain supports
  it.
- Because `Scene` and `protocol` are pure, a complete test of the form "the
  client sends these messages, the scene then contains this" needs no window.
- Fixtures are procedural — grid meshes, icospheres and point sets from a seeded
  `std.Random.DefaultPrng` — rather than checked-in files.
- Assert every invariant with `std.debug.assert`: indices in range, capacities
  ensured, refcounts non-zero. These vanish in `ReleaseFast`, which is what a
  user gets from `-Drelease`, so they are a development instrument rather than a
  runtime guarantee. Develop and verify in Debug or `ReleaseSafe`, where the
  asserts and the bounds and overflow checks are live, because in the released
  mode a bad index is undefined behaviour rather than a panic.

## 6. Benchmarkability

- `zig build bench` builds each file in `bench/` in `ReleaseFast`, one per hot
  path: decode, normals, edge extraction, scene drain and colormap mapping.
- Each benchmark warms up, runs N timed iterations with `std.time.Timer`, calls
  `std.mem.doNotOptimizeAway` on the results, and reports nanoseconds per
  operation together with a domain throughput such as vertices or megabytes per
  second. Sizes are swept over 1e3, 1e5 and 1e6 elements.
- Purity is what makes this inexpensive: every hot path is a function over
  slices with a caller-provided scratch buffer, so a benchmark is a loop.
- A change that touches a hot path records before and after numbers in its
  commit message.

## 7. SIMD and GPU

Neither is used yet, but the code is shaped so that both remain available.

- Write scalar loops over flat slices, with no early exits and no per-element
  callbacks. That shape vectorizes with `@Vector` as a local change later, and
  is also the shape a compute shader requires.
- Kernels take arrays and produce arrays. The core exposes no iterator or
  visitor API over elements.
- A SIMD experiment begins by benchmarking `Geometry(.aos4)`, which `@bitCast`s
  to `@Vector(4, f32)`, and `Geometry(.soa)` against the default. A layout is
  adopted only on numbers from `zig build bench` measured over the full path
  from encoding through the socket, blob store and kernel to the GPU. The
  padding bytes of `.aos4` travel the wire, and that bandwidth is part of its
  cost. Kernels written against the accessor API need no change to take part.
- Blobs are aligned to 64 bytes as described in §2, and scratch buffers may pad
  counts to multiples of eight.
- Prefer `@select` or arithmetic masks to data-dependent branches inside
  kernels, where doing so costs no clarity.

## 8. Zig conventions

- The Zig version is pinned by the flake, and `zig fmt` cleanliness is a
  condition of the build.
- Naming follows `std`: `TitleCase` for types, `camelCase` for functions,
  `snake_case` for fields, variables and files.
- `comptime` is for tables, such as colormap lookup tables baked at compile
  time. `anytype` appears only in small generic numeric helpers, never in a
  public core API.
- Every `pub` declaration in a core module carries a doc comment stating
  ownership and allocation behaviour: who owns the output, whether the function
  allocates, and which allocator it uses.
- Doc comments and code comments are written in plain technical English, in full
  sentences, using established terminology. They describe behaviour, arguments,
  return values, intended use and how the caller should hold the result, and
  they address "the caller" rather than the reader. Their length follows how
  much there is to explain: a paragraph or several for a type or function a
  reader must understand, a sentence for a mechanical accessor.
- State a fact directly rather than approaching it. "The same representation is
  used in memory, on the wire and on the GPU, so no destination requires a
  conversion" says what an enumeration of the parts that agree on it does not,
  in a third of the words. Constructions like "which is what makes", "this is
  the one to use when" and lists that exist for their rhythm are all signs of
  the fact being circled rather than stated.
- Say what a thing is and what a caller must do, in ordinary declarative
  sentences. Avoid the emphatic devices that stand in for saying it: "X and
  nothing else" followed by a colon and three illustrations, an aside between em
  dashes, or a definition given as a list of parts. "A `Positions` value provides
  a stream of vertex coordinates. Any additional structure, such as connectivity
  information, must be carried alongside it" needs none of them.
- A doc comment on a value declaration must contain no empty `///` line.
  Separate its paragraphs with `/// ---`, which renders as a horizontal rule.
  Autodoc renders such a declaration with its "short" form, which stops at the
  first zero-length doc line, so an empty line silently hides everything below
  it; a separator of three or more `-`, `_` or `*` is a thematic break and does
  not. A line of `///` followed by a space would also work, being non-empty to
  autodoc and blank to the markdown parser, but `zig fmt` strips the trailing
  space and turns it back into the truncating form, so the rendered docs would
  lose half of every comment the next time anyone formatted the file. Functions, containers and module headers are rendered in full and may use
  empty lines as ordinary paragraph breaks.
- The definition site carries the documentation. A re-export summarises what the
  declaration is for and when to reach for it, because the generated docs follow
  a linkified identifier to where it is defined.
- `-Drelease` selects `ReleaseFast`, which is what a user writing sketches gets
  and what benchmarks always use. Build the viewer in Debug or `ReleaseSafe`
  when working on vertex itself.
