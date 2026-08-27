//! Geometry vocabulary: the types a sketch builds data in, together with the
//! kernels and fixtures that produce it.
//!
//! A sketch, meaning a program written against this library, imports this
//! module together with `sketch.zig`, which sends the results to the viewer. This module is pure: the same inputs produce the same
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
//!
//! Each declaration below is re-exported from the module that defines it, and
//! the full documentation lives at that definition. The summaries here say what
//! each one is for and when to reach for it.
const std = @import("std");
const layout = @import("../geometry/layout.zig");
const geometry = @import("../geometry/geometry.zig");
const fixtures = @import("../geometry/fixtures.zig");
const polygon = @import("../geometry/polygon.zig");
const mesh = @import("../geometry/mesh.zig");
const polyline = @import("../geometry/polyline.zig");

/// A point or direction in three dimensions, and the value type every stream
/// accessor takes and returns. Construct one with `Vec3.init(x, y, z)` or
/// `Vec3.zero`.
/// Two-dimensional sketches use it with `z` left at zero.
pub const Vec3 = layout.Vec3;

/// The coordinates of `n` vertices: the type every geometry call and every
/// message takes. It is a view rather than a container, so the caller owns the
/// memory behind it.
/// ---
/// ```zig
/// const p = try Positions.alloc(gpa, 3);
/// defer p.free(gpa);
/// p.setAll(&.{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0) });
/// ```
pub const Positions = layout.Positions;

/// The vertex layout this build selected. A kernel that wants a
/// layout-specific fast path branches on it at compile time; nothing else needs
/// it.
pub const vertex_layout = layout.layout;

/// An axis-aligned bounding box, with `center`, `extent`, `radius` and
/// `isEmpty`. Returned by `bounds`.
pub const Aabb = geometry.current.Aabb;

/// Computes the axis-aligned bounds of a vertex stream, for framing a result,
/// normalising a model or sizing a spatial structure.
pub const bounds = geometry.current.bounds;

/// Computes one unit normal per triangle into a caller-owned `out` of length
/// `faces.len`. Use it for flat shading and face-target vector quantities.
pub const faceNormals = geometry.current.faceNormals;

/// Computes one area-weighted unit normal per vertex into a caller-owned `out`
/// of length `positions.len()`. Use it for smooth shading and as a direction
/// field for displacement.
pub const vertexNormals = geometry.current.vertexNormals;

/// Collects the unique undirected edges of a triangle mesh into a caller-owned
/// list, which it clears and refills. Use it for wireframes and for walking a
/// mesh's connectivity.
pub const uniqueEdges = geometry.current.uniqueEdges;

/// The boundary of a triangle mesh as oriented loops of vertex indices,
/// returned by `boundaryLoops` and released with `deinit`.
pub const Loops = polygon.Loops;

/// Recovers the boundary of a triangle mesh: the edges used by exactly one
/// triangle, chained into loops in the direction the mesh traverses them. Use
/// it to find open edges, to test whether a mesh is closed, or to drive
/// `capBoundaries`.
pub const boundaryLoops = polygon.boundaryLoops;

/// Triangulates every boundary loop of a mesh and appends the faces, closing
/// it. Use it to cap a lofted or extruded surface. The mesh is passed as
/// growable lists of `Vec3` and triangles, since one strategy adds a vertex.
pub const capBoundaries = polygon.capBoundaries;

/// How `capBoundaries` triangulates a loop, which states what the caller knows
/// about its shape. The default handles any simple polygon; the others are
/// closed forms for a convex loop, of which `.centroid` gives the best
/// triangles on a circle.
pub const CapStrategy = polygon.Strategy;

/// Options for `capBoundaries`: the strategy and the coincidence tolerance.
pub const CapOptions = polygon.CapOptions;

/// A triangle mesh under construction, owning plain slices of vertices and
/// triangles. This is what `loft`, `indexSoup` and `stl.decode` return, and
/// what the geometry operations build with; a `Positions` stream is made from
/// one only when it is sent.
pub const Mesh = mesh.Mesh;

/// Moves every vertex by an offset, in place. Connectivity is unaffected, so it
/// applies to the vertex array of any geometric type.
pub const translate = mesh.translate;

/// A sequence of vertices joined by segments, owning both. The segments are the
/// polyline; the vertices are the table their ends index.
pub const Polyline = polyline.Polyline;

/// Generates a closed regular polygon inscribed in a circle in the z = 0 plane,
/// wound counter-clockwise about +z.
pub const circle = polyline.circle;

/// Generates a closed rectangle in the z = 0 plane, wound counter-clockwise.
pub const rectangle = polyline.rectangle;

/// Generates a closed square in the z = 0 plane. `rectangle` with equal sides.
pub const square = polyline.square;

/// Sweeps a polyline along a displacement, which is the linear extrusion of a
/// two-dimensional profile. Produces the wall; `capBoundaries` closes it.
pub const extrude = polyline.extrude;

/// The area vector of a closed polyline: its magnitude the area enclosed, its
/// direction the normal its winding gives. Zero for one enclosing no area.
pub const areaVector = polyline.areaVector;

/// Builds the triangulated surface spanning two polylines, pairing their
/// segments. Use it for tubes, cones, extrusions and ribbons.
pub const loft = polyline.loft;

/// Builds a closed cylinder standing on the z = 0 plane, wound outward and
/// ready to use as a boolean operand. Place it with `translate`.
pub const cylinder = @import("../geometry/solids.zig").cylinder;

/// Builds a closed rectangular prism from three side lengths, wound outward.
/// `Placement` says whether it is centred on the origin, has its minimum corner
/// there, or stands on the z = 0 plane.
pub const box = @import("../geometry/solids.zig").box;

/// Where a generated shape sits relative to the origin: `.centered`,
/// `.corner` or `.on_plane`.
pub const Placement = mesh.Placement;

/// Offsetting closed curves, outward or inward.
/// ---
/// `offset.apply(gpa, profile, delta, .{})`. The profile lies in the z = 0
/// plane and its rings must be closed. The result may hold a different number
/// of rings: growing merges them, shrinking splits or empties them.
pub const offset = @import("../geometry/offset.zig");

/// Mesh booleans: union, difference and intersection over closed surfaces.
/// ---
/// `boolean.apply(gpa, a, b, .subtract)` and its two siblings. Each operand
/// must be a closed, oriented surface, which `boundaryLoops` reporting no loops
/// tests for and `indexSoup` is what a mesh from a file needs first. The result
/// is closed in turn, so booleans compose.
pub const boolean = @import("../geometry/boolean.zig");

/// Recovers an index array from a triangle soup by exact equality, which is
/// what a mesh imported from STL needs before it is treated as a surface. This
/// is not welding: vertices that merely lie close together are left alone.
pub const indexSoup = @import("../geometry/indexing.zig").indexSoup;

/// Reading and writing STL, in both the binary and the ASCII form.
/// ---
/// Every function takes or produces byte slices rather than files, so the
/// caller does the reading and writing and a large file can be mapped rather
/// than copied. `stl.decode` detects the form and returns a mesh; `encodeBinary`
/// and `encodeAscii` produce one. STL stores a triangle soup, so a decoded mesh
/// has three vertices per facet and no shared connectivity.
/// ---
/// ```zig
/// const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "part.stl", gpa, .unlimited);
/// defer gpa.free(bytes);
/// const mesh = try vertex.shapes.stl.decode(gpa, bytes);
/// defer mesh.deinit(gpa);
/// ```
pub const stl = @import("../io/stl.zig");

/// Computes the normal of a possibly non-planar loop by Newell's method. Use it
/// for the plane of a polygon, where a cross product of two edges is not
/// defined or is ill-conditioned.
pub const newellNormal = polygon.newellNormal;

/// A generated mesh holding a `Positions` stream rather than a slice of
/// vertices, returned by the generators below and released with `deinit`.
/// ---
/// The generators are parameterized by vertex layout and build the stream
/// directly, which is what lets `bench/` run all three layouts over the same
/// inputs. Everything else builds a `Mesh` and converts once, at the send.
pub const FixtureMesh = fixtures.current.Mesh;

/// Generates a flat `nx` by `ny` triangulated grid in the XY plane, spanning
/// `size` and centred on the origin. The starting surface for height fields,
/// parameter domains and cloth.
pub const grid = fixtures.current.grid;

/// Generates a sphere of the given `radius` with `20·4^subdivisions`
/// near-equilateral triangles and no poles or seams. The default test surface.
pub const icosphere = fixtures.current.icosphere;

/// Generates `n` points uniformly within the cube spanning `-extent` to
/// `+extent`, determined entirely by `seed`. Returns a stream the caller frees
/// with `free`.
pub const randomPoints = fixtures.current.randomPoints;

test {
    std.testing.refAllDecls(@This());
}
