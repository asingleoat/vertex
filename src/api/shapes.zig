//! Geometry vocabulary: the types a sketch builds data in, together with the
//! kernels and fixtures that produce it.
//!
//! A sketch imports this module together with `sketch.zig`, which sends the
//! results to the viewer. This module is pure: the same inputs produce the same
//! outputs, no socket, window, clock or global is involved, and every function
//! that allocates takes the allocator as its first argument. It can therefore be
//! called from anywhere in a sketch and tested without a viewer.
//!
//! Two conventions apply throughout. The caller owns what these functions
//! allocate and releases it with the matching `free` or `deinit` and the same
//! allocator; no function here retains a slice passed to it. Vertex streams are
//! always the `Positions` type rather than a bare `[]f32`; its memory layout is
//! selected once at build time with `-Dvertex_layout=aos3|aos4|soa`, and the
//! kernels and the wire format both derive from that choice, so code written
//! against the named accessors is unaffected by it.
const std = @import("std");
const layout = @import("../geometry/layout.zig");
const geometry = @import("../geometry/geometry.zig");
const fixtures = @import("../geometry/fixtures.zig");

/// A point or direction in three dimensions, with the usual arithmetic.
///
/// A value type of twelve bytes that owns nothing and is copied freely.
/// `Vec3.init(x, y, z)` and the `zero` constant construct one; `add`, `sub`,
/// `scale`, `dot`, `cross`, `length`, `normalize`, `min`, `max` and `eql`
/// combine them. Two-dimensional sketches use the same type, leaving `z` at
/// zero and passing `.{ .dim = .d2 }` when registering the structure.
pub const Vec3 = layout.Vec3;

/// A vertex stream: `n` positions in the layout selected at build time.
///
/// Every geometry call accepts or returns this type. It is a view over bytes
/// together with a length rather than a container, so copying a `Positions`
/// copies the view and not the data. `Positions.Mut` is returned by `alloc` and
/// is writable; `Positions.Const` is what the viewer and the kernels accept.
/// `toConst` converts between them.
///
/// ```zig
/// const p = try Positions.alloc(gpa, 3);
/// defer p.free(gpa);
/// p.setAll(&.{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0) });
/// p.set(2, .init(0, 2, 0));
/// ```
///
/// `get(i)` returns one `Vec3`; `x(i)`, `y(i)` and `z(i)` return single
/// components; `len()` returns the count and `bytes()` the underlying stream.
/// Indices are `u32`. The accessors are `inline` and compile to the same code as
/// direct indexing in every layout.
///
/// `fromSlice` wraps memory the caller already holds, such as a stack array,
/// without copying it; the resulting `Positions` is valid for as long as that
/// memory is.
pub const Positions = layout.Positions;

/// The memory layout selected for `Positions` at build time: `.aos3`, the
/// default, packed into twelve bytes; `.aos4`, sixteen bytes and castable to
/// `@Vector`; or `.soa`, three separate component arrays. A kernel that wants a
/// layout-specific fast path can branch on it at compile time. Other code does
/// not need it, because the accessors are independent of the layout.
pub const vertex_layout = layout.layout;

/// An axis-aligned bounding box, providing `center`, `extent`, `radius` and
/// `isEmpty`. Returned by `bounds` and owns nothing.
pub const Aabb = geometry.current.Aabb;

/// Computes the axis-aligned bounds of a vertex stream.
///
/// Returns an `Aabb` by value, or `Aabb.empty` when the stream is empty. Reads
/// only the stream and allocates nothing. Typical uses are framing a result,
/// normalising a model to unit size and sizing a spatial grid.
pub const bounds = geometry.current.bounds;

/// Computes one geometric normal per triangle.
///
/// Reads `positions` and `faces` and writes one `Vec3` per face into `out`,
/// which the caller owns and which must already have length `faces.len`. This
/// function allocates nothing. The normals are unit length and follow the
/// winding order, counter-clockwise being front-facing. The result can be sent
/// as a face-target vector quantity or used for shading.
pub const faceNormals = geometry.current.faceNormals;

/// Computes one smooth normal per vertex, weighted by the area of the incident
/// faces.
///
/// Reads `positions` and `faces` and writes one `Vec3` per vertex into `out`,
/// which the caller owns and which must already have length `positions.len()`.
/// This function allocates nothing. The result suits smooth shading and serves
/// as a direction field for displacing a surface.
pub const vertexNormals = geometry.current.vertexNormals;

/// Extracts the unique undirected edges of a triangle mesh.
///
/// Allocates the edge array from `gpa` and transfers ownership to the caller,
/// which must free it with the same allocator. Each edge appears once however
/// many faces share it, as a wireframe or a graph algorithm requires. The cost
/// is proportional to the face count.
pub const uniqueEdges = geometry.current.uniqueEdges;

/// A generated mesh holding both its `positions` and its `faces`.
///
/// Returned by the fixture functions below and released with `deinit`, passing
/// the allocator it was built with. Its `positions` field is a `Positions.Mut`,
/// so the vertices can be displaced in place and sent again.
pub const Mesh = fixtures.current.Mesh;

/// Builds a flat `nx` by `ny` quad grid, triangulated into a mesh, spanning
/// `size` in x and y and centred on the origin.
///
/// Allocates the positions and faces from `gpa` and transfers ownership of the
/// returned `Mesh` to the caller, which releases it with `deinit`. It is a
/// convenient starting point for height fields, parameter domains and cloth.
pub const grid = fixtures.current.grid;

/// Builds an icosphere of the given `radius`, subdivided `subdivisions` times.
///
/// Allocates the positions and faces from `gpa` and transfers ownership of the
/// returned `Mesh` to the caller, which releases it with `deinit`. The triangle
/// count is 20·4^subdivisions, so three subdivisions give 1,280 faces and six
/// give 81,920. The result is a well-conditioned test surface with no poles or
/// seams.
pub const icosphere = fixtures.current.icosphere;

/// Builds `n` points placed pseudo-randomly in the ball of radius `extent`,
/// determined entirely by `seed`.
///
/// Allocates from `gpa` and returns a `Positions.Mut` that the caller owns and
/// frees with `free`. Because the placement depends only on the seed, a sketch
/// using this function produces the same scene on every run.
pub const randomPoints = fixtures.current.randomPoints;

test {
    std.testing.refAllDecls(@This());
}
