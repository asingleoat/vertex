# vertex — architecture

A persistent geometry visualization viewer with a hot-recompile feedback loop.
Geometry code is written, saved, rebuilt and run, and its results stream to an
always-open viewer and are rendered immediately, with camera and UI state
preserved across rebuilds.

Five terms below are specific to this project. A *sketch* is a program written
against the client library, which computes geometry and sends it to the viewer.
A *structure* is one named renderable in the viewer: a triangle mesh, a point
cloud or a set of line segments. A *quantity* is a named field attached to a
structure, holding one scalar or one vector per vertex, per face or per point.
A *run* is one execution of a sketch, and a *frame* is one step within a run.
Everything else follows the standard vocabulary of graphics and geometry
processing.

## Decisions

| Area | Decision |
|---|---|
| Language | Zig, for the viewer, the client library and the protocol |
| Dependencies | A nix flake dev shell for system dependencies; `build.zig.zon` for Zig packages |
| Process model | Separate processes communicating over a Unix domain socket, behind an internal `Sink` interface, allowing a hot-loaded dylib mode to be added later |
| Renderer | sokol-gfx through sokol-zig, with sokol_app for windowing |
| Domain | Three-dimensional geometry processing with an orbit camera and two-dimensional computational geometry with an orthographic camera, both from the start |
| Renderables | Triangle meshes, point clouds, polylines and edge sets, colormapped scalar fields, and vector fields drawn as instanced arrows |
| Scene model | Named structures upserted by name across runs; per-structure viewer state such as visibility, colormap and sizes survives rebuilds; a run discards what it does not re-register |
| Timeline | Frames captured explicitly: the client calls `step()` between iterations and the viewer presents a frame scrubber |
| UI | Dear ImGui through sokol_imgui and cimgui |
| Picking | An ID-buffer pass, clicked to inspect an element index and its quantity values. Superseded by a CPU ray cast; see below |
| Geometry kernels | Written here, except polygon triangulation, which is Manifold reached through its C ABI behind a single module; see below |
| Threat model | None, and none is available: a sketch is general-purpose Zig the user wrote and compiled, running with the reach of any other program they run, so a check inside this library guards nothing that the code on the other side of it could not do directly. Limits and validation exist to catch mistakes, and are not to be written or argued for as defence |

## Components

```
vertex/
├── flake.nix                # dev shell: zig, zls, X11/GL libs, watchexec, tooling
├── build.zig
├── build.zig.zon            # sokol-zig, cimgui
├── src/
│   ├── vertex.zig             # root module: an index over api/ and internal/
│   ├── api/                   # the two modules a sketch reads
│   │   ├── shapes.zig         #   pure: Positions, Vec3, kernels, fixtures
│   │   └── sketch.zig         #   edge: connect, Connection, the messages
│   ├── geometry/              # layout.zig (Positions), geometry.zig (kernels), fixtures.zig
│   ├── io/                    # pure: stl.zig, mesh_format.zig; edges: the *_file.zig beside them
│   ├── protocol/protocol.zig  # wire format: message types, encode and decode (pure)
│   ├── scene/                 # scene.zig (structure store, versions, frames), camera.zig
│   ├── client/
│   │   ├── session.zig        # pure: Sink, Session, message ordering and validation
│   │   ├── transport.zig      # edge: socket, shared buffers, environment lookups
│   │   └── dylib.zig          # edge: the C ABI for stepping sketches
│   └── viewer/                # `vertex-view` executable: effectful edges only
│       ├── main.zig           # sokol_app entry and frame loop
│       ├── server.zig         # socket listener thread feeding a staging queue
│       ├── pick.zig           # ID-buffer pass and readback
│       ├── ui.zig             # imgui panels: structure tree, timeline, inspector
│       ├── render/            # mesh.zig, points.zig, lines.zig, vectors.zig, common.zig
│       └── shaders/           # sokol-shdc sources; generated .zig files checked in
├── bench/                     # one ReleaseFast executable per file
└── sketches/                  # experiments; each file is a runnable executable
```

One `build.zig` produces three kinds of artifact: `vertex-view`, the persistent
viewer; the `vertex` module, which sketches import; and one executable per file
in `sketches/`, discovered automatically.

## Data flow

```
sketches/current.zig ──(zig build --watch)──► rebuilt exe runs
        │  vx.connect() / vx.mesh() / vx.step() / vx.finish()
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

The transport is a Unix domain socket at `$XDG_RUNTIME_DIR/vertex.sock`, which
`VERTEX_SOCK` overrides. `sockaddr_un` limits the address string to 108 bytes,
104 on Darwin and the BSDs, before any path resolution. `platform.sockpath`
rebases longer paths on an open directory handle as
`/proc/self/fd/<fd>/<basename>` on Linux and rejects them elsewhere with a
message naming the limit; both the viewer's bind and the client's connect go
through it.

A frame is `[u32 len][u16 kind][u16 flags][payload]`, an eight-byte header in
native endianness. Variable sections within a payload begin at 16-byte offsets,
making a decoded payload's slices usable directly. The handshake is the
magic `VTXP`, which doubles as an endianness check, followed by a `u16`
protocol version, currently 2. The viewer accepts only a client reporting the
identical version.

Stream payloads are the in-memory blob bytes verbatim. The wire format derives
from the build-selected `Positions` type, so neither end converts anything for
any layout; see `STYLE.md` §3. The version number is the only compatibility
check, and a change to either the message shapes or the vertex layout bumps
it. The format is language-agnostic in that a Python or C++ client is a
serializer emitting the viewer's layout, but it is not layout-agnostic.

Messages:

- `Hello { version, source_name }`
- `BeginRun` — starts a generation and releases the previous run's versions
- `BeginFrame { index, label? }` — frame 0 is implicit after `BeginRun`; the
  client's `step()` sends `EndFrame` followed by `BeginFrame(n+1)`
- `Mesh { name, dim: 2|3, positions: Positions bytes, indices: [u32×3] }`
- `MeshPositions { name, positions }` — a topology-preserving update whose new
  version reuses the previous version's index buffer
- `Points { name, dim, positions }`
- `Lines { name, dim, positions, segments: [u32×2] }` — polylines and edge sets
- `ScalarQuantity { structure, name, target: vertex|face|point, values: [f32] }`
- `VectorQuantity { structure, name, target, vectors: Positions bytes }`
- `Log { level, text }` — echoed in the viewer's console panel
- `EndFrame`, `EndRun`

### Semantics

Structures are upserted by name. Registering one replaces its geometry, while
viewer-side state keyed by that name — visibility, active quantity, colormap and
sizes — persists.

Frames are deltas. A structure registered in frame *k* persists into later
frames until it is registered again, and scrubbing to frame *t* shows each
structure's latest version at or before *t*. Meshes that evolve are therefore
first-class: registering under the same name on every `step()` makes each
registration a version the scrubber can reach. Three cost tiers follow from
this. A static structure is registered once and costs nothing per frame. A
structure whose positions evolve while its topology is fixed, as in smoothing,
relaxation, flows and parameterization, sends `MeshPositions` per frame, which
stores and uploads only the position blob and shares the topology. A structure
whose topology evolves, as in edge collapses, remeshing and booleans, sends a
full `Mesh` per frame, which costs O(steps × mesh size) and is bounded by the
eviction policy.

A run owns the scene. At `EndRun`, every structure the run did not register is
discarded: its versions are released, and it is neither drawn nor listed. Its
slot and its per-name `UiState` remain, so registering that name again restores
the structure with its previous viewer settings.

### Copies on the path

Protocol version 2 has two payload modes.

In the inline mode the client-to-kernel path is already free of copies:
`writev` reads the caller's slices directly. The viewer's socket thread reads
each payload into one 16-byte-aligned allocation, `protocol.decode` returns
views into it, and `Scene.apply` copies the sections into 64-byte-aligned
blobs.

That allocation is sized from the header before any of the payload has arrived,
so a header wrong about the length names it. A truncated stream, a client caught
mid-rebuild and a protocol version mismatch all produce one, and all of them are
mistakes rather than anything to defend against. It is capped at 256 MiB, which
`VERTEX_MAX_PAYLOAD_MB` overrides, and a frame over the cap is dropped with the
connection after a line naming the kind, both sizes and whether the sections
were inline. Which mode a section takes is not a size threshold: a section is
external exactly when its bytes lie in a shared buffer the connection handed
out, so geometry from an ordinary allocator travels inline however large it is,
and only inline frames can reach the cap.

In the shared mode the sketch asks the connection for buffers that are
themselves memory-mapped file descriptors, through `conn.sharedPositions(n)`,
`sharedScalars` and `sharedVectors`, fills them in place and sends as usual. The
section is described by a `SectionRef` giving a descriptor index, a 64-byte
aligned offset and a length, and the descriptor accompanies the frame header in
a single `sendmsg` with `SCM_RIGHTS`. The viewer's socket thread maps the
descriptor read-only, the render thread registers the mapping with the scene,
and `Scene.apply` adopts sections inside a registered mapping as views rather
than copies, so nothing is copied between the sketch's write and the GPU
upload. Mappings are reference-counted by the blobs that view them, and only the
edge unmaps and closes them, through `released_mappings`. A shared buffer is
consumed by the send that carries it. The viewer retains versions, so reuse is
impossible, and a fresh buffer is requested per message.

On Linux, shared buffers of 2 MiB or more are created with
`MFD_HUGETLB | MFD_HUGE_2MB`. hugetlbfs reserves or fails at `mmap`, which makes
the fallback to an ordinary memfd clean, and a failed attempt starts a
cooldown of eight buffers. This is enabled by default and disabled by
`VERTEX_SHARED_HUGE=0`. The kernel must permit huge pages through either
`vm.nr_overcommit_hugepages`, which reserves nothing while idle, or
`vm.nr_hugepages`; when neither is set, both the sketch and the viewer print a
single notice naming the sysctl. Transparent huge pages for shmem were
considered and rejected: they require the equally non-default
`shmem_enabled=advise` and are best-effort rather than reserve-or-fail.

Measured on Linux (2026-08-24, `sketches/stress.zig`, 40 updates of 1M vertices
or 12 MB each, llvmpipe viewer), per step and excluding the sketch's own fill:
the inline mode sends in 6.8 ms, decodes and applies in 5.4 ms and moves 517 MB
through the socket; the shared mode with 4 KiB pages creates and populates in
about 5 ms, sends in 0.45 ms, applies in 0.43 ms and takes 117k minor faults
over the run; the shared mode with hugetlb creates and populates in about 2 ms,
the residual being the kernel's zero-fill, sends in 0.03 ms, applies in 0.43 ms
and takes 244 minor faults. Inline remains the default for ordinary slices.

The same run on aarch64-darwin (M1 Pro, Metal viewer, 2026-08-24), as totals
over the 40 steps: the inline mode sends in 348.3 ms, applies in 62.7 ms and
moves 517 MB through the socket; the shared mode sends in 3.8 ms, applies in
6.6 ms, moves 36 MB through the socket and reports
`mapped_bytes=480960480`. Sending is 92 times faster, 8.7 ms per step against
0.095, which is quicker than the Linux 4 KiB shared path despite the absence of
huge pages to fall back on. Buffer creation costs about 1.2 ms per 12 MB.

All platform-specific code lives in `src/platform/`.

## Client library

```zig
const vertex = @import("vertex");

pub fn main(init: std.process.Init) !void {
    var vx = try vertex.connect(init, .{ .name = "hull-experiment" });
    defer vx.close();

    try vx.mesh("input", positions, faces, .{});
    try vx.scalar("input", "curvature", .vertex, k);

    for (0..iters) |_| {
        relax(&sites);
        try vx.points("sites", sites, .{ .dim = .d2 });

        smooth(&positions);                          // topology fixed:
        try vx.meshPositions("input", positions);    //   positions-only update

        try vx.step();                               // frame boundary
    }
    try vx.finish();
}
```

The API takes slices and writes them synchronously with `writev` from caller
memory, so nothing is copied and no lifetime is coupled: the call returns once
the kernel holds the bytes. `connect` fails loudly by default, and
`.optional = true` degrades it to a no-op connection, and the sketch runs
without a viewer.

The API is defined against a `Sink` vtable carrying `protocol.Message` values.
`SocketSink` encodes and writes them; `DirectSink` hands the same messages to
`Scene.apply` in-process for the dylib mode, which is why that mode requires no
change to sketch code and none to the protocol.

Two modules make up the surface a sketch reads. `api/shapes.zig` is pure and
holds the geometry vocabulary; `api/sketch.zig` is the edge that opens the
socket and sends messages. `vertex.zig` re-exports both for convenience and
places the remaining modules under `internal`, which states intent rather than
imposing a restriction.

## Polygon triangulation and caps

Decided 2026-08-26, while building the loft. Capping a lofted surface requires
general polygon triangulation, which is the first piece of geometry this project
takes from outside rather than writing.

Manifold is the choice. nixpkgs carries 3.5.2 under Apache-2.0 and installs
`libmanifoldc` with `manifold/manifoldc.h` already built, so the flake gains a
dependency and `build.zig` a link line, with no vendored source and no CMake. Its
C API constructs every object into a buffer the caller sizes with
`manifold_*_size()` and owns, which is the allocation discipline of `STYLE.md` §2
expressed at the boundary, and its triangulator takes an epsilon, which distinct
indices at coincident coordinates require. The alternatives were libtess2, which
matches §2 more literally through an injectable allocator but is unpackaged and
minimally maintained; CDT, which produces better triangles but exposes no C API;
and Shewchuk's Triangle, whose licence excludes commercial use. The deciding
argument is not triangulation. Booleans are anticipated under "Wire protocol"
above as a topology-evolving operation, and Manifold is the kernel that makes
them tractable.

The `epsilon` this seam exposes is Manifold's, not a tolerance chosen here.
`STYLE.md` §3a records why geometry code should not carry one, and the fact that
this one is borrowed from a dependency rather than invented is part of the case
for being able to replace it.

The seam is three modules over one C++ file. `geometry/triangulate.zig` takes
projected points and returns triangle indices; `geometry/boolean.zig` takes two
closed meshes and returns their union, difference or intersection;
`geometry/planar.zig` does the same for regions of the plane and also offsets
one, both being Clipper2 reached through Manifold's `CrossSection`. All three go
through `geometry/manifold_shim.cpp`, and nothing else names `manifoldc.h`. They
are separate modules because the seam is drawn per operation: writing any one of
them here would leave the others untouched.

A planar operation takes and returns a `Polyline`, which needs nothing added to
carry the result: a polyline is a vertex array and a segment array, so several
disjoint rings are as ordinary a value as one. Rings are read under the non-zero
fill rule, which makes a clockwise ring inside a counter-clockwise one a hole,
and `polyline.areaVector` is negative for such a ring. Holes survive into three
dimensions: `triangulate.polygon` passes a whole set of rings to
`manifold_triangulate`, and `solids.extrude` triangulates a profile's rings
together for both caps while sweeping each ring's wall separately, so a region
with a hole becomes a solid with a passage rather than one with a lid over it.
A hole's ring runs the opposite way round, which is exactly what turns its wall
to face into the passage, so no case analysis is needed for it.

`polygon.capBoundaries` is the other capping path and still sees one loop at a
time, which is right for what it does: it recovers loops from an arbitrary
surface, where deciding which of them are holes of which would need a
coplanarity test, and coplanarity of two independently computed loops is not an
exact question. `solids.extrude` avoids it by never asking: a planar profile's
rings are coplanar by construction.

Offsetting is the operation that is hardest to do naively. Moving
each vertex along its angle bisector is correct only while the result does not
touch itself, and a curve offset far enough inward will collapse, split or
vanish; Clipper2 resolves those cases rather than returning a self-intersecting
ring. Its `join`, `miter_limit` and `circular_segments` are geometric parameters
rather than tolerances: how a convex corner is filled, how far a miter may run
before it is cut, and how finely an arc is approximated are all questions an
offset genuinely has to answer. Everything above it is pure and `f32`. Replacing
Manifold, whole or one operation at a time, is a matter of reimplementing that
signature, and the seam is drawn per operation for that reason.

Booleans cross the boundary without conversion. Manifold's `MeshGL` holds `f32`
vertex properties and `u32` triangle indices, which at three properties per
vertex is this project's `Mesh` exactly. What that boundary costs instead is two
copies, one in and one out, Manifold keeping its own storage and sizing a result
only by computing it. It reports a bad operand through `manifold_status` rather
than by throwing, so an open or self-intersecting mesh comes back as
`error.NotManifold` rather than as a plausible wrong answer.

The `f32` this project works in has a measured cost at the triangulation seam,
and the mechanism is exact rather than vague. Converting to `f64` loses nothing;
what it produces is a set of values on the `f32` grid. A ring of vertices on a
unit circle stays strictly convex on that grid up to about twelve thousand
points and acquires its first exactly-collinear triple at sixteen thousand. One
such triple is enough: Manifold's triangulator leaves its fast path and takes
three hundred and fifty times as long, and a second and an eighth cost nothing
further, so it is a switch rather than a slope. Measured at 16384 points, a ring
computed in `f64` triangulates in 2.1 ms and the same ring rounded through `f32`
in 703 ms.

Two things follow. `bench/mesh.zig` keeps both rings as a pair, so the change
under "Planned" has a number to be judged against. And capping a ring that dense
wants `.hierarchical` or `.centroid`, which are closed forms written here and a
thousand times faster there than `.general`.

Three properties of the triangulation seam are recorded because they are
exceptions rather than oversights. `ManifoldVec2` is `double`, so that boundary
converts `f32` to `f64` and back; the cost is proportional to the ring rather than to the mesh.
Manifold allocates internally through its own allocator, so an allocation
failure inside it is neither observable nor recoverable, and
`checkAllAllocationFailures` stops at the seam. `manifold_triangulate` is not
exception-safe: `manifold::Triangulate` rethrows `geometryErr` on invalid input
and the C binding wraps it in no handler, so a throw would unwind across the C
ABI. A shim compiled with the project catches and returns a status, which
restores an error value at the boundary.

That last one is insurance rather than a handled route, and the distinction
matters to callers. Manifold ensures a manifold result rather than validating
its input: a ring that self-intersects, repeats a point, encloses no area or
winds the wrong way comes back as a best-effort triangulation, not as an error,
as the tests in `triangulate.zig` record. Detecting a malformed ring is the
caller's to do before the call. The shipped library does reference `__cxa_throw`,
so the throw path exists and the shim is worth its one file.

Manifold reaches every consumer of the `vertex` module, which now links libc,
libc++ and `libmanifoldc`: the viewer, sketches and the stepping libraries all
carry the dependency. The prefix comes from MANIFOLD_PREFIX, exported by the dev
shell on both platforms, because NIX_CFLAGS_COMPILE is unset on darwin to
restore zig's SDK detection and ZIG_SEARCH_PREFIXES is exported only on linux.

A cap adds faces over indices the ring already carries, which leaves the surface
closed and manifold, and manifoldness is what Manifold requires of its own
inputs. It may add an interior vertex but never duplicates a boundary one: the
`.centroid` strategy places a vertex at the middle of each loop and fans from
it, which on a ring is the only way to beat the `pi/n` smallest angle that
bounds every triangulation of the ring alone. `Strategy` in `polygon.zig`
records the measurements. Caps therefore attach to a surface
rather than to the polylines it was lofted from, and the boundary is recovered
from the faces as the edges used by exactly one triangle, chained into loops.
The single adjacent triangle traverses each boundary edge in one direction and
the cap traverses it in the other, so winding follows from topology; the Newell
normal of the loop is needed only to choose the projection plane. Reading the
boundary from the constructed surface also accounts for dropped degenerate
triangles without a special case: an apex contributes no boundary edges, so a
cone yields one loop and takes one cap.

## Mesh files

A third form is this project's own. `.stl64` is the binary form with a `u64`
facet count and an `f64` in place of every `f32`, and a comment required to
begin with `STL64`; a file is read as one only when both that magic and the
`88 + 98n` length agree. It exists because the narrow form discards coordinates
the geometry was carrying, and because that rounding is not free even where the
precision is not wanted, as the triangulation cliff above shows. Writing one
from geometry that is itself `f32` gains nothing until the core is `f64`.

STL is read and written by `io/stl.zig`, which is pure: every function
takes or produces byte slices and the caller does the file I/O, so a large file
can be mapped rather than copied and the whole format is testable without a
filesystem.

Both forms are supported. Which one a file holds is decided arithmetically
rather than by its leading keyword, because some writers put the word `solid`
into the binary form's 80-byte comment: a binary file is exactly `84 + 50n`
bytes for the `n` its header declares, and the keyword is consulted only when
that does not fit.

The binary path allocates nothing and knows its size in advance, since the facet
count is in the header. Its inner loop is one 36-byte copy per facet, `Vec3`
being a 12-byte `extern struct`, so a facet's three vertices are contiguous in
both the file and the output. Measured over 81920 facets: 611M facets per second
decoding and 328M encoding, against 1.5M and 2.5M for the ASCII form, which is
also 4.1 times larger. Vectorizing the binary path is not a matter of widening
the copy, the 50-byte record stride being coprime with every useful vector
width; a SIMD version would load spans of records and shuffle.

STL stores a triangle soup, so a file of `n` facets decodes to `3n` vertices and
no shared connectivity: every edge is used by one triangle and each facet is its
own island. Recovering the index array is exact and belongs to
`geometry/indexing.zig`, which returns the same `Mesh` as everything else that
builds geometry: `geometry/mesh.zig` holds that type, plain slices of vertices
and triangles, and `Positions.alloc` followed by `setAll` is the one place it
becomes a stream. The copies a soup holds are identical to the last bit,
the exporter having written one value unchanged for each facet that touches it,
so `indexSoup` matches them bitwise and reproduces the connectivity the exporter
had. No tolerance is involved.

That is not welding. Welding merges vertices that are merely close, and needs a
tolerance, a spatial structure and a decision about the normals it changes.
`indexSoup` leaves two coordinates differing in their last bit as two vertices,
which is the line between the two operations. It does discard degenerate faces,
those naming one point twice, because that test is exact and such a face draws
nothing, bounds nothing and adds nothing to a volume while every operation that
walks connectivity has to special-case it. 3DBenchy carries 552 of them in
225706 facets.

Reading and writing are therefore not an identity on arbitrary input, which is
the intent rather than a shortfall. A malformed file is normalized on the way
in, so what is written back is not the file that was read: the benchy goes in
with 225706 facets and comes back with 225154. It differs once. A second pass
reproduces the first written file byte for byte, so the path reaches a fixed
point after one application, and a well-formed file is already at that fixed
point. The geometry itself is preserved exactly throughout: over the benchy's
225706 facets, none differs from the source in its vertex bytes. A face whose three vertices are distinct but collinear is kept:
it has no area either, but saying so needs a predicate on coordinates that no
exact test provides. It is a single pass with linear
probing over a table of `u32` slots at a load factor of one half, and runs at
228M vertices per second; a sphere of 81920 facets goes from 245760 soup
vertices to the 40962 it was exported from, exactly. Its one canonicalization is that
negative zero matches positive zero, since they are the same point; without it a
file that wrote both for one corner would come back with a crack along it.

## The mesh format

STL carries a triangle soup and nothing else. The formats that carry more are
either text, branded to a tool, or general enough that reading one is a project.
This is the format written here, `.mesh`, and it holds a simplicial complex: a
vertex array and four index arrays, one per degree, so a point cloud, an edge
graph, a triangle mesh and a tetrahedral mesh are the same file with different
sections populated. It is version 0 and carries no compatibility promise; a
reader accepts its own version and nothing else, and version 1 is cut when the
shape stops moving.

A file is a 128-byte header, a metadata region, the vertex array and then the
four index arrays. Every section begins on a 64-byte boundary and is padded to
the next one with zeros, which is the alignment the scene store gives its blobs
and divides the stride of every element the format holds, so a section of a
mapped file can be cast to its element type rather than copied. The header gives
the length of every section and of the whole file, so a reader takes 128 bytes,
learns `total_bytes`, allocates once and reads the rest, and reaches any section
by arithmetic rather than by scanning. `total_bytes` is derivable from the
counts and stored anyway: the disagreement between the two is a free check on a
file that was truncated or edited.

Every scalar is little-endian, which is what x86-64, AArch64 and RISC-V are. The
header's `flags` is a `u64` whose first bit selects `f64` coordinates over
`f32`; `dim` is 2 or 3, since planar geometry is first-class here and a column
of zeros is a third of a planar file. Reserved bits are written zero and ignored
on read, the version field being what states compatibility. The second flag bit
is reserved for `u64` indices and is refused rather than misread, which is why
`vertex_count` and the four simplex counts are already `u64`: widening the
indices then needs no change to the header, and a count is not bounded by the
index width in any case, as a point cloud past 2^32 points shows. See "Index
width becomes a parameter" under "Planned".

Separate arrays per degree rather than one flat array with a tag per simplex. A
degree-k array is a dense `[k+1]u32` record array of fixed stride, so a mapped
file casts straight to `[][3]u32` and reaches a GPU index buffer with nothing
between; a tagged array has to be scanned and compacted first, which is the pass
a format of this shape exists to avoid. What this closes off is non-simplicial
cells, quads and general polygons and hexes, which need a flat array with an
offset array beside it and are a different format.

Closure is neither required nor written. A triangle mesh declares its triangles,
and its edges and vertices are implied; a file that listed them would be stating
the same fact twice. The vertex array is storage shared by every degree, so a
vertex no simplex references is legal and no compaction happens on write. What
the 0-simplex array names is which vertices the complex holds as standalone
points, which is not the vertex array and is usually shorter than it.

Nothing derivable is stored. There are no normals, no tangents, no adjacency and
no bounding box, because recomputing any of them costs what reading them costs
and storing them adds a second copy that can disagree with the first. Vertex
normals are the clearest case: every consumer already has the code and has an
opinion about the weighting, so a stored normal carrying a foreign convention is
worse than none. The rule is that a file holds what the sketch computed and not
what a reader can recompute. Whatever a producer wants to record anyway belongs
in the metadata region, which is uninterpreted, advisory, and placed before the
geometry so that everything descriptive arrives ahead of the bulk and the
geometry is one contiguous run ending at the last byte.

The magic is `MESH\x8F\r\n\n`. `MESH` is readable in the first column of a hex
dump and is unclaimed at offset zero in `file`'s database, which is the closest
thing to a registry; the four bytes after it detect a transfer that mangled the
file rather than moved it, `0x8F` being invalid as a UTF-8 leading byte and the
line endings being what a text-mode transfer or a version control system
rewrites. It identifies a file and nothing more. What establishes that a file is
well-formed is the arithmetic: the sections derived from the counts must sum to
`total_bytes`, and every index must address a vertex that exists. Both checks
catch a mistake rather than defend against anything, as the threat model above
requires.

`io/mesh_format.zig` is pure and works on byte slices; `io/mesh_file.zig` is the
edge that opens paths, and `geometry/complex.zig` holds the `Complex` the format
decodes to, with `asMesh` and `fromMesh` relating it to the triangle `Mesh` the
rest of the library builds with. Decoding a file whose coordinates are `f32`
with a `dim` of 3 is one bulk copy per section, the layout being this project's
`Vec3` and `u32` arrays exactly, followed by the index scan. Measured over an
icosphere of 40962 vertices, 40962 points, 122880 edges and 81920 triangles, a
2.6 MB file: 171 microseconds to decode into caller storage and 65 to encode,
which is 240M and 630M vertices per second. Widening the coordinates to `f64`
costs 5 per cent of the decode and a fifth of the file rather than a third,
positions being 19 per cent of a file with all four sections populated.

## Viewer internals

### Threading

sokol_app owns the render thread. One socket thread per connection performs
blocking reads, decodes complete structure updates and pushes them onto a
mutex-protected staging queue. The frame callback drains the queue, coalesces
multiple updates to the same structure, sokol permitting only one
`sg_update_buffer` per buffer per frame, and uploads them.

### Scene store

Versions are tuples of references into a reference-counted blob store rather
than owned copies:

```
Structure { name, kind, dim, versions: []Version }   // no versions ⇒ discarded, slot and UiState kept
Version   { run: u32, frame: u32,
            positions: BlobRef, topology: ?BlobRef, quantities: {name: BlobRef} }
Blob      { refcount, bytes: []align(64) u8 }        // positions in the build-selected Positions layout
render/: blob_gpu: ArrayListUnmanaged(sg.Buffer) indexed by BlobIndex   // edge-owned parallel array
UiState   (keyed by name, survives runs) { visible, active_quantity, colormap, wireframe, sizes }
```

The core scene store never touches sokol. The render edge keeps a parallel array
of GPU buffers indexed by `BlobIndex` and drains a core-maintained list of newly
created blob indices each frame; see `STYLE.md` §4.

A full `Mesh` registration replaces every reference. `MeshPositions` replaces
only the positions reference and shares the topology blob with the previous
version, and re-sending a quantity replaces only that quantity's reference.
Scrubbing the timeline binds a different combination of already-uploaded GPU
buffers and uploads nothing. The memory cost of the timeline is therefore
proportional to what changed per step, and derived data such as unique edge
lists and arrow instances is cached per blob rather than per version. The fixed
cost of a version beyond its blob bytes is 68 bytes, measured 2026-08-24 and
comprising the `Version` record, its blob record and list slack; a test pins it
below 128; a per-version container cannot be introduced unnoticed.

### GPU residency

Retained versions are bounded only by the memory budget, but sokol's buffer pool
is finite at 1024 slots, fixed at `sg.setup`. Every blob buffer and derived
instance buffer is stamped with the frame in which it was last bound. After each
frame, if more than `residency_cap`, currently 512, blob buffers or
`derived_cap`, currently 128, cache entries are resident, those not used in that
frame are destroyed. They are immutable uploads of scene data and are recreated
on demand when the timeline is scrubbed back to them. `sketches/churn.zig`, which
sends 400 paced versions, is the regression for this; it exhausted the pool
before the policy existed.

### Rendering

- The mesh solid pass shades flat from screen-space derivatives,
  `normalize(cross(dFdx(p), dFdy(p)))`, which needs neither normals nor
  duplicated vertices. Smooth shading is used when the client supplies normals.
- Counter-clockwise winding is front-facing, matching the outward-normal
  convention geometry is built to. The mesh pipelines set `face_winding` to
  `.CCW` explicitly, since sokol-gfx defaults to clockwise. Nothing is culled:
  back faces are drawn tinted toward red instead, which shows reversed winding
  and marks the inside of an open surface. The derivative normal above carries
  no winding information, so `gl_FrontFacing` is the only signal available.
- The wireframe is a CPU-extracted unique edge list drawn through the thick-line
  pipeline with a depth offset, which avoids both barycentric vertex duplication
  and unreliable GL line widths.
- Scalar quantities are a vertex attribute sampled through one-dimensional
  colormap lookup textures, with viridis, turbo and coolwarm embedded.
- Points are instanced screen-space quads with a round sprite in the fragment
  shader, which is portable in a way `gl_PointSize` is not.
- Lines are instanced screen-space quads, one per segment, at constant pixel
  width.
- Vectors are an instanced low-poly arrow mesh with a per-element transform.
- Picking renders an offscreen pass writing `(structure_id, element_id)` to an
  integer target. sokol-gfx has no readback API, so this uses a direct
  `glReadPixels` escape hatch isolated in `pick.zig`. That escape hatch is to be
  removed; see the next section.

### Picking: a CPU ray cast rather than an ID buffer

Decided 2026-08-24, while porting. The readback escape hatch would otherwise
cost one implementation per backend.

The synchronous form does not port. sokol's Metal backend creates one
`MTLCommandBuffer` per frame, enqueues it at the first `beginPass` and commits
it at `sg.commit()`, and exposes the device, the queue and the encoders but not
that command buffer. A blit committed mid-frame is therefore queued behind a
command buffer that has not been committed, so `waitUntilCompleted` cannot
return. Any GPU readback here must be asynchronous, fencing after `sg.commit()`
and reading the result a frame later, and the same holds for D3D11. That is
three escape hatches, one of them a restructuring of the pick call path.

Nothing about picking needs the GPU. Scene blobs are already CPU memory, and a
ray cast covers every case: ray-triangle intersection for meshes, the distance
from the cursor to a projected point against `point_size` for points, the
distance from the cursor to a projected segment against `line_width` for lines,
and the nearest `t` across kinds, which is what the depth test was computing. It
is more precise than an ID buffer, not less: it does not quantize to pixels.

It is also core code, so it can be tested: `geometry/` with
`checkAllAllocationFailures` and a `bench/` entry, per `STYLE.md` §5 and §6,
rather than GPU behaviour observable only by running a window.

It is likely to be faster than the current implementation. Hover picking
re-renders every visible structure through the pick pipelines on every mouse
movement, which is full vertex processing of the scene per motion event. A BVH
cached per positions blob, invalidated exactly as the derived edge-list cache
is, reduces that to a logarithmic query.

The plan is to implement brute force first and measure, then add the per-blob
BVH when the measurements require it; `sketches/stress.zig` is roughly two
million triangles, far beyond what brute force can serve for hover. Landing it
removes the GL externs in `pick.zig`, the four `pick_*` shaders and the `RG32UI`
target. It is sequenced after the platform layer and the smoke tests, being a
redesign of a working feature rather than a port step. It requires before and
after numbers and a check that a CPU hit agrees with a GL hit on the same
scene.

### Camera

Three-dimensional scenes use a turntable orbit camera with pan and dolly;
two-dimensional scenes use an orthographic camera panning and zooming under the
cursor. The mode is selected automatically when every live structure has
`dim=2`, and can be overridden in the UI. The pose persists across runs, and the
scene is fitted on `F` and on the first data received.

### UI panels

A structure tree with visibility checkboxes, a quantity selector, a colormap
combo, a wireframe toggle and size sliders; a timeline scrubber with play and
frame labels; a status bar showing the connection, counts and frame rate; a log
console; and a pick inspector tooltip.

## Hot-recompile loop

Build modes are divided by who is building. Writing sketches and running the
viewer uses `zig build -Drelease`, which selects ReleaseFast. Sketch geometry is
real computation and the surrounding tool must not slow it. Working
on vertex itself uses Debug or ReleaseSafe. On zig master a plain `zig build` is
Debug, in which the viewer runs on a leak-checking `DebugAllocator`, and
`-Doptimize=ReleaseSafe` retains the bounds, overflow and assertion checks that
a core addressed by `u32` indices into flat arrays depends on. Benchmarks are
always ReleaseFast.

Verification is `zig build test`, run for each layout through `-Dvertex_layout`,
together with `nix develop -c scripts/smoke.sh`. The smoke script drives the
viewer through the socket sketches, the churn regression, the stepper autorun
and the shared-memory stress, asserting the deterministic statistics lines and
the absence of sokol errors and allocator leak reports. It runs headless under
Xvfb on Linux; macOS has no Xvfb, so it runs on the real display, where four
windows appear and close, with the same assertions, in about 46 seconds.

The working loop is two terminals: `zig build run-viewer`, which stays up for
days, and `zig build run-sketch --watch`, with `-Dsketch=<name>` selecting a
sketch and `current` as the default. The run step re-executes on every save, and
the executable connects, streams and exits. `-fincremental` is Linux-only: on
macOS the build runner's FSEvents watcher panics with "nothing to watch" after
one rebuild. `watchexec` is in the dev shell as a fallback.

Sketches and benchmarks are discovered by listing `sketches/` and `bench/`. Zig
master caches the configure phase; `build.zig` declares the directories through
`dependOnDirectory` and poisons that cache until the maker implements directory
mode, which is an upstream TODO. New files are therefore always picked up.

`zig build docs` emits zig's autodoc for the `vertex` module into
`zig-out/docs`. The page fetches `sources.tar`, so it generally needs serving
over HTTP rather than opening from the file system.

## Nix

`flake.nix` takes Zig master, 0.17-dev, from `mitchellh/zig-overlay` and zls
from the `zigtools/zls` flake, both locked in `flake.lock`. sokol-zig and dcimgui
track zig master, so those dependencies stay on their master branches.

The dev shell provides the system libraries sokol needs on Linux — `libX11`,
`libXi`, `libXcursor` and `libGL` — along with `pkg-config`, `watchexec`, `gdb`
and optionally `renderdoc`.

Zig packages are declared in `build.zig.zon`, which splits responsibilities: nix
owns the toolchain and the C and system libraries, and Zig's package manager owns
the Zig dependencies. A reproducible `nix build` package would use either the
deps-hash approach, `zig build --fetch` with a fixed-output derivation, or
zig2nix.

Four points of friction with NixOS are accepted and mitigated. sokol-shdc is
distributed as a prebuilt binary, so the flake wraps it with `autoPatchelfHook`
as `packages.sokol-shdc`, pinned to the commit sokol-zig references; the
generated shader `.zig` files under `src/viewer/shaders/` are checked in and
`zig build shaders` regenerates them. For system libraries and libc headers, zig
reads `NIX_CFLAGS_COMPILE` and `NIX_LDFLAGS` from the dev shell, and `glibc.dev`
is listed explicitly: the external translate-c implementation that dcimgui uses
does not go through the cc wrapper. sokol_app's Linux backend is
X11 and GLX, so the viewer runs under XWayland on a Wayland session, which is
acceptable for a development tool. Zig master packages are fetched into a
project-local `zig-pkg/`, which is gitignored.

## Portability

Everything platform-specific lives behind `vertex.platform`, selected at compile
time on `builtin.os.tag`, with `*_unsupported.zig` stubs that compile everywhere
and return `error.Unsupported`, leaving the inline path as the fallback. The
remainder lives in a viewer edge module with a documented backend assumption.

The macOS cells marked ✅ are facts established on aarch64-darwin, macOS 26.5.2,
M1 Pro, on 2026-08-24 while porting the viewer. The toolchain, Metal rendering,
the zero-copy path, dylib stepping and the smoke tests all run there. Only the
❌ row is outstanding.

| Concern | Linux (now) | macOS | Windows |
|---|---|---|---|
| Toolchain | zig from `zig-overlay`, glibc pinned to the shell's through `ZIG_DYNAMIC_LINKER` | ✅ the same zig with no pin. The pin must be gated on Linux: the nixpkgs Darwin cc wrapper also ships `nix-support/dynamic-linker`, holding `/usr/lib/dyld`, which otherwise forces `abi=gnu` | — |
| SDK and frameworks | n/a | ✅ zig 0.17.0-dev.1857 skips its Darwin SDK detection, `xcrun --sdk macosx --show-sdk-path`, whenever `NIX_CFLAGS_COMPILE` or `NIX_LDFLAGS` is set, and then finds no framework at all, reporting `searched paths:  none`. The dev shell unsets both, leaving `DEVELOPER_DIR` and `SDKROOT`, from nixpkgs `apple-sdk` 14.4, to pin the SDK | Windows SDK through zig's own headers |
| Shared memory (`platform.shm`) | `memfd_create` and `mmap`, with hugetlbfs through `MFD_HUGETLB` and a fallback | ✅ `shm_open` under an exclusive single-use name, unlinked immediately, leaving the descriptor as the only reference, then `ftruncate` and `mmap`. There is no `MAP_POPULATE` and no huge-page class, so `huge` is always false and the notice never prints. About 1.2 ms per 12 MB buffer, covering open, truncate, map and first touch | `CreateFileMapping` and `MapViewOfFile`; large pages require `SeLockMemoryPrivilege` |
| Handle passing (`platform.fdpass`) | `SCM_RIGHTS` over the Unix socket | ✅ `SCM_RIGHTS` through `std.c` `sendmsg` and `recvmsg`, but not a copy of the Linux implementation: `CMSG_ALIGN` is `__DARWIN_ALIGN32`, four bytes rather than `sizeof(size_t)`, and `cmsghdr` is 12 bytes rather than 16. There is no `MSG_NOSIGNAL`, so the socket takes `SO_NOSIGPIPE`, and no `MSG_CMSG_CLOEXEC`, so each received descriptor is marked individually | no descriptor passing: `DuplicateHandle` into the viewer process, which requires its pid, or a named mapping |
| Receiving without handle passing | `recvmsg` always | ✅ no longer required here, fdpass having landed, but the `platform.fdpass.supported` branch remains. Without it `recvWithHandles` returns `error.Unsupported` and a receiver cannot read the socket at all, the inline path included | required permanently: Windows never passes handles this way |
| Transport | Unix domain socket through `std.Io.net` | ✅ the same; `std.Io.net` binds, connects and accepts on the kqueue `Threaded` backend | `AF_UNIX` has existed since Windows 10 1803; `std.Io.net` support is unverified |
| Abstract sockets | `"\0name"`, with no file to clean up | ✅ none: Darwin has no abstract namespace, and a real file is bound instead | none |
| Windowing and GPU | sokol_app with X11 and GL 4.3 | ✅ sokol_app with Cocoa and Metal, selected by passing `.gl = false` to sokol-zig, whose `auto` resolves to Metal on Darwin. The frameworks are `AppKit`, `QuartzCore`, `Metal` and `AudioToolbox`. Meshes, points, lines and ImGui all render | sokol_app with Win32 and D3D11 |
| Dylib stepping | `libstep-<name>.so`, `dlopen` of a copy | ✅ unchanged: `zig build step` names the artifact `libstep-<name>.dylib`, `std.DynLib` is `dlopen`, and macOS raises no code-signing objection to `dlopen`ing the viewer's copy. Only the copied path's suffix was hardcoded | `.dll` through `LoadLibrary`; the never-unload policy still applies |
| Headless smoke tests | `xvfb-run` with llvmpipe | ✅ no Xvfb exists, so they run on the real display. The frame caps are smaller: vsync paces frames where llvmpipe does not | no Xvfb either; a hidden window or WARP |
| Shaders | `sokol-shdc -l glsl430` | ✅ `-l glsl430:metal_macos`. One checked-in file per shader carries both backends, is identical from either operating system, and its GLCORE branch is unchanged by the addition of Metal. The `osx_arm64` sokol-shdc runs directly from the nix store, with no Gatekeeper quarantine | add `hlsl5` |
| Pick readback (`pick.zig`) | raw `glReadPixels` inside the pass, to be removed once picking moves to a CPU ray cast | ✅ picking is disabled meanwhile: `pick.Picker` selects a disabled implementation at compile time. This is required, not tidiness: a Metal build does not link OpenGL, so the GL externs must not be analyzed. ✅ a synchronous Metal readback is impossible. sokol commits its only frame command buffer at `sg.commit()` and does not expose it, so a mid-frame `waitUntilCompleted` waits on a command buffer queued behind an uncommitted one | the same: no readback needed |
| Face scalars | GL 4.3 SSBO indexed by `gl_PrimitiveID` | ❌ blocked: `gl_PrimitiveID` in a fragment shader requires MSL 2.2 and SPIRV-Cross rejects anything below it, reporting `PrimitiveId on macOS requires MSL 2.2`. sokol-shdc exposes no MSL version flag, in the pinned build or in master, as checked on 2026-08-24. `mesh_face_scalar{,_soa}` and `pick_mesh{,_soa}` remain GL-only, and the renderer tests the generated descriptor for a source and falls back to the plain mesh pipeline. Resolving it requires a shader compiler that sets MSL 2.2, or replacing `primitive_id` with a per-vertex face index at the cost of vertex duplication | D3D11 `StructuredBuffer` with `SV_PrimitiveID` |
| Socket path | `$XDG_RUNTIME_DIR/vertex.sock` | ✅ `/tmp/vertex.sock`, the existing fallback. `XDG_RUNTIME_DIR` is unset and `$TMPDIR` is per `nix develop` shell, of the form `/tmp/nix-shell.XXXXXX/nix-shell.YYYYYY`, which would place viewer and sketch on different sockets | `\\.\pipe` or an `AF_UNIX` path in a temporary directory |
| `sun_path` limit | 107 usable bytes; longer paths rebased through `/proc/self/fd/<fd>` | ✅ `sun_path` is `char[104]` in the SDK's `sys/un.h`, so 103 are usable, and there is no `/proc` to rebase on, so longer paths are rejected with the limit named | 107 usable, no rebasing |
| Measurement (`platform.stats`) | `getrusage` and `/proc/self/status` | ✅ `getrusage` alone. `task_info` is unnecessary: `stats` exposes only minor faults and hugetlb kilobytes, and the latter is always zero here. Whether a huge-page class exists is the compile-time `shm.huge_supported`, so the viewer, the client and the sketch all report `huge=off` rather than a preference that cannot be honoured | `GetProcessMemoryInfo` |

Three rules keep this inexpensive. No `std.os.linux` call and no raw GL call
appears outside `src/platform/*` and `pick.zig`. The scene and the protocol see
handles only as opaque `platform.Handle` values. A port proceeds one row of this
table at a time, with the inline payload path working before shared memory does.
Whether a capability exists is a `pub const supported` on the platform module,
such as `platform.shm.supported` and `platform.fdpass.supported`, kept in step by
the declaration-parity test; callers branch on that and never on
`builtin.os.tag`, so a port enables a path by writing the module.

## Dylib mode: viewer-driven stepping

Chosen 2026-08-24 over a push mode, which would have removed only the socket hop
that the shared-memory path had already made insignificant, at the cost of crash
isolation.

A stepping sketch lives in `steps/<name>.zig`:

```zig
pub const State = struct { ... };
pub fn init(gpa: std.mem.Allocator, session: *vertex.Session) !State;  // register initial structures
pub fn step(state: *State, gpa: std.mem.Allocator, session: *vertex.Session) !bool; // false = finished
pub fn deinit(state: *State, gpa: std.mem.Allocator) void;
comptime { vertex.dylib.exportSketch(@This()); }
```

`zig build step -Dsketch=<name> --watch` builds `zig-out/lib/libstep-<name>.so`,
or `.dylib` on macOS. `exportSketch` generates the C ABI surface —
`vertex_abi_version`, `vertex_init`, `vertex_step` and `vertex_deinit`. The
viewer and the library are always built from the same tree, so that ABI need
only be self-consistent and version-checked.

The data path reuses everything else. A `DirectSink` encodes with the wire
protocol and hands the byte parts to a host callback; the viewer copies them into
the same `Inbox` the socket server feeds. Decoding, the scene, the timeline,
retention and picking are unchanged. Shared buffers belong to `Connection` and
are socket-mode only, so the in-process path copies inline.

A worker thread owns the library and runs `vertex_step`, and each viewer-driven
step is one timeline frame. The controls are Load, Reload, Unload, Step, Run,
Pause and Reset. Run has three paces: Frame, the default, which runs one step per
rendered frame, showing every step; Rate, which runs N steps per second;
and Max, which runs freely until the sketch's own stop condition, an error or
Pause, and suits generating frames quickly and scrubbing them afterwards. Step
runs exactly one step, unpaced. The render thread never calls into the library;
frame pacing is a credit the render thread grants once per frame.
`VERTEX_STEP_PACE=frame|rate|max` selects the pace for headless use.

Every Reset or reload starts a new run: `init` sends hello and begin_run, which
releases the previous run's versions. The viewer shows the algorithm that was
just built.

The viewer polls the library's mtime about four times a second, copies a new
build to a unique path and `dlopen`s it. Libraries are never `dlclose`d.
Unloading risks problems with thread-local storage, atexit handlers and global
state, and the leaked mapping is small. A mismatched `vertex_abi_version` refuses
the load. A sketch that was running, or that had finished, runs again after a
reload, on the assumption that the change was saved in order to watch it; one
that was never started or is paused stays idle. Note that a rebuild which
produces an identical artifact does not reload: the poll compares mtime, and the
install step skips an unchanged copy.

Each instance receives its own leak-checking `DebugAllocator`. `vertex_deinit`
reports leaks and the viewer logs them, and a failing step pauses with the error
in the log.

This mode has no crash isolation: a fault in the sketch takes the viewer with
it. Socket mode remains the default and is the appropriate choice for batch
runs.

`VERTEX_STEP_LIB=<path>` loads a library at startup and `VERTEX_STEP_AUTORUN=1`
starts it running. The exit statistics line gains
`stepper steps=… state=… reloads=… leaks=…` for headless checks.

## Milestones

- M1, the first end-to-end path, completed 2026-08-23: flake and `build.zig`; a
  viewer with imgui, orbit and orthographic cameras, a socket server and mesh
  rendering in all layouts, with a timeline and the run lifecycle; a client
  streaming an animated icosphere. Verified end to end headless under Xvfb with
  llvmpipe and through `--watch`. Points and lines appeared as UI entries only.
- M2, the remaining renderables and scalar colormaps, completed 2026-08-23:
  points as instanced round sprites, lines and polylines as instanced
  screen-space quads, vector quantities as instanced arrows, and vertex-target
  scalar quantities through compile-time colormap tables — viridis, turbo,
  coolwarm and plasma — on meshes and points; a wireframe overlay from
  CPU-extracted unique edges with depth bias; per-structure UI controls for
  quantity and colormap selection, sizes and wireframe; and automatic detection
  of two-dimensional scenes on the first fit.
- M3, picking and inspection, completed 2026-08-23: the ID-buffer pass, GL
  readback, an inspector tooltip showing the element index and its quantity
  values, and face-target scalar rendering, which needs the same per-primitive
  plumbing.
- M4, retention and budget, completed 2026-08-24: a memory budget, set by
  `VERTEX_MEMORY_BUDGET_MB` or a UI drag, enforced by decimating the current
  run's frames, taking odd frames first, then every fourth, and never a
  structure's latest version or frame 0; memory and eviction readouts; ingest
  statistics on exit; and `sketches/stress.zig`. The memfd zero-copy path landed
  the same day.
- The macOS port, completed 2026-08-25: the dev shell, Metal rendering, the
  darwin platform layer restoring zero-copy, dylib stepping and the smoke tests.
  Picking and face-target scalars are the two features not working there; see
  the portability table.

## Planned

Three changes are decided but deferred.

**Picking becomes a CPU ray cast**, replacing the ID-buffer pass and its GPU
readback. The reasoning and the plan are under "Picking: a CPU ray cast rather
than an ID buffer" above.

**Numeric types become parameters.** Every definition that depends on a numeric
type should be parameterized over it, in the style of `PositionsOf(layout)` and
`Geometry(layout)`. Today `Vec3` is `f32` and so is every kernel, every blob and
the wire format. Rendering needs no more than `f32`, but robust predicates such
as orientation and in-circle tests, and coordinates at CAD scale, exceed a
24-bit mantissa, and an intermediate value computed for those purposes should be
able to hold `f64`.

This is no longer only a question of precision at CAD scale, and it is no longer
waiting on a second instantiation to justify it. The triangulation seam has a
measured three-hundred-and-fifty-fold cliff on a ring of sixteen thousand points
which exists only because the coordinates were rounded to `f32` first: at that
density the grid introduces a collinear triple that the geometry does not have,
and one is enough. See "Polygon triangulation and caps".

The intended end state is `f64` throughout the core, narrowed to `f32` at the
two places that require it: the vertex stream on its way to the GPU, which takes
no more, and the narrow STL form. `io/stl.zig` already carries `.binary64` for
the case where narrowing is not wanted.

The conversion point already exists and is one call. Intermediate geometry is
computed in plain slices of vectors, and reaches the viewer through
`Positions.alloc` followed by `setAll`, which is where a narrowing conversion
from `f64` to `f32` belongs. Nothing downstream of the wire is affected, since
the GPU takes `f32` in any case.

The work is a `Vec3Of(T)` with its arithmetic, `PositionsOf` gaining a scalar
parameter alongside its layout parameter, and the kernels following. It is
deferred until a second instantiation exists to validate the abstraction rather
than assume it.

**Index width becomes a parameter**, in the same manner and for the same reason.
Vertex indices are `u32` throughout: `[3]u32` faces, `[2]u32` segments, the count
`Positions.len` returns, and the `vertex_count`, `face_count` and
`segment_count` fields of every protocol head. A mesh of more than 2^32 vertices
cannot be expressed, and `STYLE.md` §3 records that ceiling as an assumption
rather than a law.

Two families of index exist and only one of them grows. `StructureIndex` and
`BlobIndex` count structures and blobs, of which a scene holds thousands, and
they stay `enum(u32)` per §1. It is the vertex indices that reach the ceiling, so
the parameter belongs on the geometry types, the topology slices and the protocol
heads, and not on the handle types.

Widening the core is separable from drawing the result. sokol's `index_type` is
`UINT16` or `UINT32`, as is every graphics API beneath it, so a mesh past 2^32
vertices is not one draw call whatever the core holds. The renderer would
partition it into sub-meshes and remap each to local `u32` indices, which is the
larger half of the work and is why this sits behind the numeric change. The
shared-memory path needs nothing: `SectionRef` already carries `offset` and `len`
as `u64`.

Memory bounds this long before the index type does. 2^32 vertices is 51 GB of
positions in `.aos3` before any topology, and a mesh that size reaches the viewer
through shared buffers in any case, since `Header.len` is a `u32` and caps an
inline payload at 4 GiB. Widening the counts in the heads is a protocol version
bump.
