//! The simplicial complex, and the views that relate it to a triangle mesh.
//!
//! A `Complex` is a vertex array together with four index arrays, one per
//! simplex degree. The vertex array is storage shared by every degree, and each
//! index array names which of those vertices form simplices of that degree:
//! `points` single vertices, `edges` pairs, `triangles` triples and
//! `tetrahedra` quadruples.
//!
//! `mesh.zig` holds `Mesh`, which is what the rest of the library builds with
//! and carries triangles alone. A complex is what `io/mesh_format.zig` reads
//! and writes, and a mesh is the case where only `triangles` is populated.
//! `asMesh` and `fromMesh` convert between the two without allocating.
const std = @import("std");
const layout = @import("layout.zig");
const mesh_mod = @import("mesh.zig");

const Vec3 = layout.Vec3;
const Mesh = mesh_mod.Mesh;

/// A simplicial complex owning its vertices and its four index arrays.
/// ---
/// Every entry of every index array addresses `vertices`, and that is the only
/// invariant imposed. Closure is not required: a triangle mesh has `triangles`
/// populated and `edges` and `points` empty, and its edges and vertices are
/// implied rather than written. A vertex that no simplex of any degree
/// references is permitted, since the vertex array is storage rather than a
/// statement about which points are part of the complex.
///
/// Released with `deinit` and the allocator that produced it.
pub const Complex = struct {
    vertices: []Vec3,
    /// 0-simplices: the vertices the complex names as standalone points.
    points: []u32,
    /// 1-simplices.
    edges: [][2]u32,
    /// 2-simplices.
    triangles: [][3]u32,
    /// 3-simplices.
    tetrahedra: [][4]u32,

    /// A complex owning nothing, which `deinit` accepts.
    pub const empty: Complex = .{
        .vertices = &.{},
        .points = &.{},
        .edges = &.{},
        .triangles = &.{},
        .tetrahedra = &.{},
    };

    /// O(1).
    pub fn deinit(self: Complex, gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.points);
        gpa.free(self.edges);
        gpa.free(self.triangles);
        gpa.free(self.tetrahedra);
    }

    /// The total number of simplices across all four degrees.
    ///
    /// O(1).
    pub fn simplexCount(self: Complex) usize {
        return self.points.len + self.edges.len + self.triangles.len + self.tetrahedra.len;
    }

    /// A `Mesh` viewing this complex's vertices and triangles.
    ///
    /// The result borrows both arrays and owns neither, so the caller must not
    /// call `Mesh.deinit` on it and must not use it after the complex is
    /// released. Simplices of the other three degrees are dropped from the
    /// view; a caller that needs them must read them from the complex.
    ///
    /// O(1).
    pub fn asMesh(self: Complex) Mesh {
        return .{ .vertices = self.vertices, .faces = self.triangles };
    }
};

/// A `Complex` viewing a mesh's vertices and faces as its 2-simplices.
///
/// The result borrows both arrays and owns neither, so the caller must not call
/// `Complex.deinit` on it. This is what passes a mesh to `mesh_format.encode`,
/// which takes a complex.
///
/// O(1).
pub fn fromMesh(mesh: Mesh) Complex {
    return .{
        .vertices = mesh.vertices,
        .points = &.{},
        .edges = &.{},
        .triangles = mesh.faces,
        .tetrahedra = &.{},
    };
}

/// Reports whether every index of every degree addresses a vertex that exists.
///
/// This is the invariant `Complex` states and the one a decoder checks against
/// a file. It catches a mistake rather than defending against an adversary; see
/// the threat model in `DESIGN.md`.
///
/// O(s) in the total simplex count.
pub fn indicesInRange(self: Complex) bool {
    const limit: u32 = std.math.cast(u32, self.vertices.len) orelse return false;
    for (self.points) |i| if (i >= limit) return false;
    for (self.edges) |e| for (e) |i| if (i >= limit) return false;
    for (self.triangles) |t| for (t) |i| if (i >= limit) return false;
    for (self.tetrahedra) |t| for (t) |i| if (i >= limit) return false;
    return true;
}

const testing = std.testing;

test "an empty complex owns nothing" {
    const c: Complex = .empty;
    c.deinit(testing.allocator);
    try testing.expectEqual(0, c.vertices.len);
    try testing.expectEqual(0, c.simplexCount());
}

test "a mesh and a complex view each other without allocating" {
    var vertices = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0) };
    var faces = [_][3]u32{.{ 0, 1, 2 }};
    const mesh: Mesh = .{ .vertices = &vertices, .faces = &faces };

    const c = fromMesh(mesh);
    try testing.expectEqual(1, c.simplexCount());
    try testing.expectEqual(0, c.points.len);

    const back = c.asMesh();
    try testing.expectEqual(mesh.vertices.ptr, back.vertices.ptr);
    try testing.expectEqual(mesh.faces.ptr, back.faces.ptr);
}

test "an index past the vertex array is out of range" {
    var vertices = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0) };
    var good = [_][2]u32{.{ 0, 1 }};
    var bad = [_][2]u32{.{ 0, 2 }};

    var c: Complex = .empty;
    c.vertices = &vertices;
    c.edges = &good;
    try testing.expect(indicesInRange(c));

    c.edges = &bad;
    try testing.expect(!indicesInRange(c));
}

test "a vertex no simplex references is in range" {
    var vertices = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(2, 0, 0) };
    var points = [_]u32{0};
    var c: Complex = .empty;
    c.vertices = &vertices;
    c.points = &points;
    try testing.expect(indicesInRange(c));
    try testing.expectEqual(1, c.simplexCount());
}
