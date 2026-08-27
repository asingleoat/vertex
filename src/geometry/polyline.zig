//! Polylines, and the surfaces built by lofting between them.
const std = @import("std");
const layout = @import("layout.zig");
const mesh_mod = @import("mesh.zig");

const Vec3 = layout.Vec3;
const Mesh = mesh_mod.Mesh;

/// A sequence of vertices joined by segments, owning both.
/// ---
/// The segments are the polyline: they may be listed in any order and may name
/// the vertices in any order, so `segments.len` rather than `vertices.len` is
/// its length. The vertex array is a lookup table giving coordinates to each end
/// of each segment, and may hold entries no segment names.
///
/// A polyline is closed when its segments form one cycle and open when they form
/// a path; nothing in the type distinguishes the two, and the operations that
/// care determine it from the segments. A segment naming one vertex twice is
/// degenerate and encloses nothing.
///
/// Released with `deinit` and the allocator that produced it.
pub const Polyline = struct {
    vertices: []Vec3,
    segments: [][2]u32,

    /// A polyline owning nothing, which `deinit` accepts.
    pub const empty: Polyline = .{ .vertices = &.{}, .segments = &.{} };

    pub fn deinit(self: Polyline, gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.segments);
    }

    /// Returns an independent copy, which is how a second polyline is derived
    /// from one already computed rather than generated again.
    pub fn clone(self: Polyline, gpa: std.mem.Allocator) std.mem.Allocator.Error!Polyline {
        const vertices = try gpa.dupe(Vec3, self.vertices);
        errdefer gpa.free(vertices);
        const segments = try gpa.dupe([2]u32, self.segments);
        return .{ .vertices = vertices, .segments = segments };
    }
};

/// Generates a closed regular polygon of `num_segments` sides, inscribed in a
/// circle of `radius` in the z = 0 plane, wound counter-clockwise about +z.
///
/// The first vertex is at angle zero, on the +x axis. Fewer than three segments
/// yields a polyline with no area, which is not an error. The caller owns the
/// result.
pub fn circle(
    gpa: std.mem.Allocator,
    radius: f32,
    num_segments: u32,
) std.mem.Allocator.Error!Polyline {
    const vertices = try gpa.alloc(Vec3, num_segments);
    errdefer gpa.free(vertices);
    const segments = try gpa.alloc([2]u32, num_segments);
    errdefer gpa.free(segments);

    var i: u32 = 0;
    while (i < num_segments) : (i += 1) {
        const turns = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(num_segments));
        const theta = turns * std.math.tau;
        vertices[i] = .init(radius * @cos(theta), radius * @sin(theta), 0);
        segments[i] = .{ i, (i + 1) % num_segments };
    }
    return .{ .vertices = vertices, .segments = segments };
}

/// Builds the triangulated surface spanning two polylines.
///
/// Traversal is over segments rather than over vertices, so a closed polyline
/// may be lofted to an open one. Segment `s` of `bottom` is paired with segment
/// `(s + offset)` of `top`, wrapping, and each pair spans a quad cut into two
/// triangles. `flip` reverses the winding of both. A segment whose endpoints are
/// the same index collapses its triangle, which is how an apex is expressed; its
/// partner still contributes, so the surface has no hole there.
///
/// The result owns its vertices and its faces. Vertices the surface does not
/// refer to are dropped, but coordinates are never merged: a vertex shared by
/// both inputs appears twice, with independent connectivity.
pub fn loft(
    gpa: std.mem.Allocator,
    bottom: Polyline,
    top: Polyline,
    offset: usize,
    flip: bool,
) std.mem.Allocator.Error!Mesh {
    // Equal segment counts are required for now. The traversal below is the
    // general one and covers min(bottom, top), so allowing a partial loft is a
    // matter of deleting this assertion.
    std.debug.assert(bottom.segments.len == top.segments.len);
    const count = @min(bottom.segments.len, top.segments.len);
    const off = offset % top.segments.len;
    const base: u32 = @intCast(bottom.vertices.len);

    // Count the surviving triangles.
    var face_count: usize = 0;
    var s: usize = 0;
    while (s < count) : (s += 1) {
        const lo = bottom.segments[s];
        const hi = top.segments[(s + off) % top.segments.len];
        if (lo[0] != lo[1]) face_count += 1;
        if (hi[0] != hi[1]) face_count += 1;
    }

    // Emit them in the combined index space: bottom vertex i is i, top vertex
    // j is base + j.
    const faces = try gpa.alloc([3]u32, face_count);
    errdefer gpa.free(faces);
    var written: usize = 0;
    s = 0;
    while (s < count) : (s += 1) {
        const lo = bottom.segments[s];
        const hi = top.segments[(s + off) % top.segments.len];
        const a0 = lo[0];
        const a1 = lo[1];
        const b0 = base + hi[0];
        const b1 = base + hi[1];
        if (a0 != a1) {
            faces[written] = if (flip) .{ a0, b1, a1 } else .{ a0, a1, b1 };
            written += 1;
        }
        if (b0 != b1) {
            faces[written] = if (flip) .{ a0, b0, b1 } else .{ a0, b1, b0 };
            written += 1;
        }
    }

    // Assign dense indices in order of first use by a surviving face. Building
    // the table from the faces rather than from the segments is what leaves a
    // collapsed quad costing nothing: no face names its vertices, so they never
    // reach the output.
    const table = try gpa.alloc(u32, bottom.vertices.len + top.vertices.len);
    defer gpa.free(table);
    @memset(table, unused);
    var kept: u32 = 0;
    for (faces) |face| {
        for (face) |e| {
            if (table[e] == unused) {
                table[e] = kept;
                kept += 1;
            }
        }
    }

    // Gather the vertices those indices name, and rewrite the faces.
    const vertices = try gpa.alloc(Vec3, kept);
    errdefer gpa.free(vertices);
    for (table, 0..) |dense, i| {
        if (dense == unused) continue;
        vertices[dense] = if (i < bottom.vertices.len)
            bottom.vertices[i]
        else
            top.vertices[i - bottom.vertices.len];
    }
    for (faces) |*face| {
        for (face) |*e| e.* = table[e.*];
    }

    return .{ .vertices = vertices, .faces = faces };
}

/// Marks a vertex that no surviving face refers to.
const unused = std.math.maxInt(u32);

const testing = std.testing;

/// The volume a closed mesh encloses, positive when its faces wind outward.
fn signedVolume(m: Mesh) f64 {
    var volume: f64 = 0;
    for (m.faces) |face| {
        const a = m.vertices[face[0]];
        const b = m.vertices[face[1]];
        const c = m.vertices[face[2]];
        volume += @as(f64, a.dot(b.cross(c))) / 6;
    }
    return volume;
}

test "circle is closed, regular, and wound counter-clockwise" {
    const sides = 8;
    const outline = try circle(testing.allocator, 2, sides);
    defer outline.deinit(testing.allocator);

    try testing.expectEqual(sides, outline.vertices.len);
    try testing.expectEqual(sides, outline.segments.len);
    for (outline.vertices) |v| {
        try testing.expectApproxEqAbs(@as(f32, 2), v.length(), 1e-5);
        try testing.expectEqual(@as(f32, 0), v.z);
    }
    // Each segment leads to the next vertex, and the last closes the ring.
    for (outline.segments, 0..) |segment, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), segment[0]);
        try testing.expectEqual(@as(u32, @intCast((i + 1) % sides)), segment[1]);
    }
    // Counter-clockwise about +z: the first turn is to the left.
    const turn = outline.vertices[1].sub(outline.vertices[0])
        .cross(outline.vertices[2].sub(outline.vertices[1]));
    try testing.expect(turn.z > 0);
}

test "lofting two rings gives an open tube wound outward" {
    const sides = 8;
    const height = 2.0;
    const bottom = try circle(testing.allocator, 1, sides);
    defer bottom.deinit(testing.allocator);
    const top = try bottom.clone(testing.allocator);
    defer top.deinit(testing.allocator);
    mesh_mod.translate(top.vertices, .init(0, 0, height));

    const wall = try loft(testing.allocator, bottom, top, 0, false);
    defer wall.deinit(testing.allocator);

    try testing.expectEqual(2 * sides, wall.vertices.len);
    try testing.expectEqual(2 * sides, wall.faces.len);
    // Every face points away from the axis.
    for (wall.faces) |face| {
        const a = wall.vertices[face[0]];
        const b = wall.vertices[face[1]];
        const c = wall.vertices[face[2]];
        const normal = b.sub(a).cross(c.sub(a));
        const radial: Vec3 = .init((a.x + b.x + c.x) / 3, (a.y + b.y + c.y) / 3, 0);
        try testing.expect(normal.dot(radial) > 0);
    }
}

test "flip reverses every triangle" {
    const bottom = try circle(testing.allocator, 1, 6);
    defer bottom.deinit(testing.allocator);
    const top = try bottom.clone(testing.allocator);
    defer top.deinit(testing.allocator);
    mesh_mod.translate(top.vertices, .init(0, 0, 1));

    const outward = try loft(testing.allocator, bottom, top, 0, false);
    defer outward.deinit(testing.allocator);
    const inward = try loft(testing.allocator, bottom, top, 0, true);
    defer inward.deinit(testing.allocator);

    // Compared by position rather than by index: the dense numbering follows
    // first use, which flipping changes, so the indices are not the subject.
    try testing.expectEqual(outward.faces.len, inward.faces.len);
    for (outward.faces, inward.faces) |out, in| {
        try testing.expect(outward.vertices[out[0]].eql(inward.vertices[in[0]]));
        try testing.expect(outward.vertices[out[1]].eql(inward.vertices[in[2]]));
        try testing.expect(outward.vertices[out[2]].eql(inward.vertices[in[1]]));
    }
}

test "an offset twists the loft without changing its size" {
    const sides = 8;
    const bottom = try circle(testing.allocator, 1, sides);
    defer bottom.deinit(testing.allocator);
    const top = try bottom.clone(testing.allocator);
    defer top.deinit(testing.allocator);
    mesh_mod.translate(top.vertices, .init(0, 0, 1));

    const straight = try loft(testing.allocator, bottom, top, 0, false);
    defer straight.deinit(testing.allocator);
    const twisted = try loft(testing.allocator, bottom, top, 3, false);
    defer twisted.deinit(testing.allocator);

    try testing.expectEqual(straight.faces.len, twisted.faces.len);
    try testing.expectEqual(straight.vertices.len, twisted.vertices.len);

    // The index pattern is the same either way, first use being what numbers
    // the vertices; what the offset changes is which points those indices name.
    var differs = false;
    for (straight.faces, twisted.faces) |a, b| {
        for (a, b) |ia, ib| {
            if (!straight.vertices[ia].eql(twisted.vertices[ib])) differs = true;
        }
    }
    try testing.expect(differs);
}

test "a polyline of collapsed segments lofts to a cone" {
    const sides = 8;
    const rim = try circle(testing.allocator, 1, sides);
    defer rim.deinit(testing.allocator);
    const apex = try rim.clone(testing.allocator);
    defer apex.deinit(testing.allocator);
    // Every segment collapses onto vertex 0, which is then the apex.
    for (apex.segments) |*segment| segment.* = .{ 0, 0 };
    mesh_mod.translate(apex.vertices, .init(0, 0, 3));

    const cone = try loft(testing.allocator, apex, rim, 0, false);
    defer cone.deinit(testing.allocator);

    // One triangle per rim segment, over the apex and the rim only: the seven
    // vertices the collapsed polyline no longer names are gone.
    try testing.expectEqual(sides, cone.faces.len);
    try testing.expectEqual(sides + 1, cone.vertices.len);
}

test "two collapsed polylines loft to nothing" {
    const rim = try circle(testing.allocator, 1, 6);
    defer rim.deinit(testing.allocator);
    for (rim.segments) |*segment| segment.* = .{ 0, 0 };
    const collapsed = try loft(testing.allocator, rim, rim, 0, false);
    defer collapsed.deinit(testing.allocator);
    try testing.expectEqual(0, collapsed.faces.len);
    try testing.expectEqual(0, collapsed.vertices.len);
}

test "a capped loft encloses the volume of its prism" {
    const polygon = @import("polygon.zig");
    const sides = 8;
    const height = 2.0;
    const bottom = try circle(testing.allocator, 1, sides);
    defer bottom.deinit(testing.allocator);
    const top = try bottom.clone(testing.allocator);
    defer top.deinit(testing.allocator);
    mesh_mod.translate(top.vertices, .init(0, 0, height));

    const wall = try loft(testing.allocator, bottom, top, 0, false);
    defer wall.deinit(testing.allocator);

    var vertices: std.ArrayList(Vec3) = .empty;
    defer vertices.deinit(testing.allocator);
    try vertices.appendSlice(testing.allocator, wall.vertices);
    var faces: std.ArrayList([3]u32) = .empty;
    defer faces.deinit(testing.allocator);
    try faces.appendSlice(testing.allocator, wall.faces);
    try polygon.capBoundaries(testing.allocator, &vertices, &faces, .{ .strategy = .hierarchical });

    const solid: Mesh = .{ .vertices = vertices.items, .faces = faces.items };
    const area = sides * @sin(std.math.tau / @as(f64, sides)) / 2;
    try testing.expectApproxEqRel(area * height, signedVolume(solid), 1e-5);
}

fn loftAllocationCase(gpa: std.mem.Allocator) !void {
    const bottom = try circle(gpa, 1, 6);
    defer bottom.deinit(gpa);
    const top = try bottom.clone(gpa);
    defer top.deinit(gpa);
    const wall = try loft(gpa, bottom, top, 0, false);
    defer wall.deinit(gpa);
    if (wall.faces.len != 12) return error.TestUnexpectedResult;
}

test "circle and loft handle every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, loftAllocationCase, .{});
}
