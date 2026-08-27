//! The triangle mesh under construction, and the transforms that apply to it.
//!
//! `Mesh` is the shape geometry takes while it is being built: plain slices of
//! `Vec3` and of triangles, rather than the `Positions` stream the wire format
//! and the viewer use. Everything between a generator and a send works in this
//! form, and `Positions.alloc` followed by `setAll` is the single point at which
//! it becomes a stream. `fixtures.Mesh` is the other representation, holding a
//! stream directly, and is what the layout-parameterized generators return.
const std = @import("std");
const layout = @import("layout.zig");

const Vec3 = layout.Vec3;

/// Where a generated shape sits relative to the origin.
pub const Placement = enum {
    /// Centred on the origin, spanning half its size either side on every axis.
    centered,
    /// Its minimum corner at the origin, spanning zero to its size on every
    /// axis, so the whole solid lies in the positive octant.
    corner,
    /// Centred in x and y with its base on the z = 0 plane, which is where
    /// `cylinder` puts itself and how a part sits on a print bed. A flat shape
    /// has no height to raise, so for one this and `.centered` coincide.
    on_plane,
};

/// A triangle mesh owning its vertices and its faces.
/// ---
/// `faces` indexes `vertices`; no other invariant is imposed, so a mesh may be
/// a triangle soup, an indexed surface, open, closed, or any of these in parts.
/// The operations that need more than this say so: `polygon.boundaryLoops`
/// requires an unambiguous boundary, and `indexing.indexSoup` is what turns a
/// soup into a surface.
///
/// Released with `deinit` and the allocator that produced it.
pub const Mesh = struct {
    vertices: []Vec3,
    faces: [][3]u32,

    /// A mesh owning nothing, which `deinit` accepts.
    pub const empty: Mesh = .{ .vertices = &.{}, .faces = &.{} };

    /// O(1).
    pub fn deinit(self: Mesh, gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.faces);
    }
};

/// Moves every vertex by `offset`. Connectivity is unaffected, so this applies
/// to the vertex array of any geometric type.
///
/// O(n) in the vertex count.
pub fn translate(vertices: []Vec3, offset: Vec3) void {
    for (vertices) |*v| v.* = v.add(offset);
}

const testing = std.testing;

test "translate moves every vertex and nothing else" {
    var vertices = [_]Vec3{ .init(1, 2, 3), .init(-1, 0, 0) };
    translate(&vertices, .init(0, 0, 5));
    try testing.expect(vertices[0].eql(.init(1, 2, 8)));
    try testing.expect(vertices[1].eql(.init(-1, 0, 5)));
}

test "an empty mesh owns nothing" {
    const m: Mesh = .empty;
    m.deinit(testing.allocator);
    try testing.expectEqual(0, m.vertices.len);
    try testing.expectEqual(0, m.faces.len);
}
