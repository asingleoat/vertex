//! Closed primitive solids, assembled from the polyline and polygon
//! operations.
//!
//! Each returns a `Mesh` that is closed and wound outward, which is what a
//! boolean requires of its operands. A caller wanting a variation these do not
//! offer, a different cap or an open surface, builds it from `polyline.loft`
//! and `polygon.capBoundaries` directly; that is all any of these do.
const std = @import("std");
const layout = @import("layout.zig");
const mesh_mod = @import("mesh.zig");
const polyline = @import("polyline.zig");
const polygon = @import("polygon.zig");

const Vec3 = layout.Vec3;
const Mesh = mesh_mod.Mesh;

/// Where a solid sits relative to the origin.
pub const Placement = enum {
    /// Centred on the origin, spanning half its size either side on every axis.
    centered,
    /// Its minimum corner at the origin, spanning zero to its size on every
    /// axis, so the whole solid lies in the positive octant.
    corner,
    /// Centred in x and y with its base on the z = 0 plane, which is where
    /// `cylinder` puts itself and how a part sits on a print bed.
    on_plane,
};

/// Failure of a solid: allocation, or the triangulation of a cap.
pub const Error = polygon.CapError;

/// Builds a closed cylinder of `radius` and `height`, its base on the z = 0
/// plane and its axis along +z, approximated by `segment_count` sides.
///
/// The caller owns the result and places it with `mesh.translate`. Its caps are
/// triangulated by recursive halving, which suits a solid that is rendered,
/// picked or used as a boolean operand; a caller who needs the better-shaped
/// triangles of a centre-fan cap lofts and caps it directly, which is the four
/// calls this composes.
///
/// Fewer than three segments encloses no volume and yields an empty mesh.
pub fn cylinder(
    gpa: std.mem.Allocator,
    radius: f32,
    height: f32,
    segment_count: u32,
) Error!Mesh {
    if (segment_count < 3) return .empty;

    const bottom = try polyline.circle(gpa, radius, segment_count);
    defer bottom.deinit(gpa);
    const top = try bottom.clone(gpa);
    defer top.deinit(gpa);
    mesh_mod.translate(top.vertices, .init(0, 0, height));

    const wall = try polyline.loft(gpa, bottom, top, 0, false);
    defer wall.deinit(gpa);

    var vertices: std.ArrayList(Vec3) = .empty;
    errdefer vertices.deinit(gpa);
    try vertices.appendSlice(gpa, wall.vertices);
    var faces: std.ArrayList([3]u32) = .empty;
    errdefer faces.deinit(gpa);
    try faces.appendSlice(gpa, wall.faces);
    try polygon.capBoundaries(gpa, &vertices, &faces, .{ .strategy = .hierarchical });

    const owned_vertices = try vertices.toOwnedSlice(gpa);
    errdefer gpa.free(owned_vertices);
    const owned_faces = try faces.toOwnedSlice(gpa);
    return .{ .vertices = owned_vertices, .faces = owned_faces };
}

/// Builds a closed rectangular prism with the given side lengths, wound
/// outward.
///
/// `size` gives the extent along x, y and z; each must be non-negative, and a
/// zero one yields a flat solid enclosing no volume rather than an error.
/// `placement` says where it sits, which saves the caller the `translate` that
/// would otherwise follow every call.
///
/// The eight corners and twelve triangles are written out directly. There is
/// nothing to loft or cap: a box has a closed form, and going through the
/// general path would cost an allocation for each polyline, a boundary walk and
/// two triangulations to arrive at the same twelve faces.
pub fn box(
    gpa: std.mem.Allocator,
    size: Vec3,
    placement: Placement,
) std.mem.Allocator.Error!Mesh {
    std.debug.assert(size.x >= 0 and size.y >= 0 and size.z >= 0);

    const min: Vec3 = switch (placement) {
        .centered => size.scale(-0.5),
        .corner => .zero,
        .on_plane => .init(-size.x / 2, -size.y / 2, 0),
    };
    const max = min.add(size);

    const vertices = try gpa.dupe(Vec3, &.{
        .init(min.x, min.y, min.z), .init(max.x, min.y, min.z),
        .init(max.x, max.y, min.z), .init(min.x, max.y, min.z),
        .init(min.x, min.y, max.z), .init(max.x, min.y, max.z),
        .init(max.x, max.y, max.z), .init(min.x, max.y, max.z),
    });
    errdefer gpa.free(vertices);

    // Corners 0 to 3 run counter-clockwise about +z on the low face and 4 to 7
    // the same on the high one, so the low face reverses that order to point
    // away and the high face keeps it. The four sides follow from the same two
    // rings.
    const faces = try gpa.dupe([3]u32, &.{
        .{ 0, 3, 2 }, .{ 0, 2, 1 }, // -z
        .{ 4, 5, 6 }, .{ 4, 6, 7 }, // +z
        .{ 0, 1, 5 }, .{ 0, 5, 4 }, // -y
        .{ 2, 3, 7 }, .{ 2, 7, 6 }, // +y
        .{ 0, 4, 7 }, .{ 0, 7, 3 }, // -x
        .{ 1, 2, 6 }, .{ 1, 6, 5 }, // +x
    });
    return .{ .vertices = vertices, .faces = faces };
}

const testing = std.testing;

/// The volume a closed mesh encloses, positive when its faces wind outward.
fn volume(m: Mesh) f64 {
    var total: f64 = 0;
    for (m.faces) |face| {
        const a = m.vertices[face[0]];
        const b = m.vertices[face[1]];
        const c = m.vertices[face[2]];
        total += @as(f64, a.dot(b.cross(c))) / 6;
    }
    return total;
}

test "a cylinder is closed and encloses the volume of its prism" {
    const sides = 16;
    const solid = try cylinder(testing.allocator, 2, 3, sides);
    defer solid.deinit(testing.allocator);

    const loops = try polygon.boundaryLoops(
        testing.allocator,
        @intCast(solid.vertices.len),
        solid.faces,
    );
    defer loops.deinit(testing.allocator);
    try testing.expectEqual(0, loops.count());

    // A regular polygon of n sides inscribed in r has area n·r²·sin(2π/n)/2,
    // and the sign is positive only if the faces wind outward.
    const area = sides * 4.0 * @sin(std.math.tau / @as(f64, sides)) / 2;
    try testing.expectApproxEqRel(area * 3.0, volume(solid), 1e-5);
}

test "a cylinder sits on the z = 0 plane along +z" {
    const solid = try cylinder(testing.allocator, 1, 5, 8);
    defer solid.deinit(testing.allocator);
    var lowest: f32 = std.math.floatMax(f32);
    var highest: f32 = -std.math.floatMax(f32);
    for (solid.vertices) |v| {
        lowest = @min(lowest, v.z);
        highest = @max(highest, v.z);
        try testing.expect(v.length() <= @sqrt(@as(f32, 1 + 25)) + 1e-5);
    }
    try testing.expectApproxEqAbs(@as(f32, 0), lowest, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 5), highest, 1e-6);
}

test "a cylinder is an operand a boolean accepts" {
    const boolean = @import("boolean.zig");
    const outer = try cylinder(testing.allocator, 1, 2, 32);
    defer outer.deinit(testing.allocator);
    const bore = try cylinder(testing.allocator, 0.5, 4, 32);
    defer bore.deinit(testing.allocator);
    mesh_mod.translate(bore.vertices, .init(0, 0, -1));

    const tube = try boolean.apply(testing.allocator, outer, bore, .subtract);
    defer tube.deinit(testing.allocator);
    try testing.expectApproxEqRel(volume(outer) * (1 - 0.25), volume(tube), 1e-4);
}

test "too few segments encloses nothing" {
    for ([_]u32{ 0, 1, 2 }) |sides| {
        const degenerate = try cylinder(testing.allocator, 1, 1, sides);
        defer degenerate.deinit(testing.allocator);
        try testing.expectEqual(0, degenerate.faces.len);
    }
}

fn cylinderAllocationCase(gpa: std.mem.Allocator) !void {
    const solid = try cylinder(gpa, 1, 2, 6);
    defer solid.deinit(gpa);
    if (solid.faces.len == 0) return error.TestUnexpectedResult;
}

test "cylinder handles every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, cylinderAllocationCase, .{});
}

/// The axis-aligned bounds of a mesh, as minimum and maximum corners.
fn extent(m: Mesh) [2]Vec3 {
    var lo = m.vertices[0];
    var hi = m.vertices[0];
    for (m.vertices[1..]) |v| {
        lo = lo.min(v);
        hi = hi.max(v);
    }
    return .{ lo, hi };
}

test "a box is closed and encloses the product of its sides" {
    for ([_]Placement{ .centered, .corner, .on_plane }) |placement| {
        const solid = try box(testing.allocator, .init(1, 2, 4), placement);
        defer solid.deinit(testing.allocator);

        try testing.expectEqual(8, solid.vertices.len);
        try testing.expectEqual(12, solid.faces.len);
        try testing.expectApproxEqRel(8.0, volume(solid), 1e-6);

        const loops = try polygon.boundaryLoops(
            testing.allocator,
            @intCast(solid.vertices.len),
            solid.faces,
        );
        defer loops.deinit(testing.allocator);
        try testing.expectEqual(0, loops.count());
    }
}

test "each placement puts the box where it says" {
    const size: Vec3 = .init(1, 2, 4);

    const centered = try box(testing.allocator, size, .centered);
    defer centered.deinit(testing.allocator);
    try testing.expect(extent(centered)[0].eql(.init(-0.5, -1, -2)));
    try testing.expect(extent(centered)[1].eql(.init(0.5, 1, 2)));

    const cornered = try box(testing.allocator, size, .corner);
    defer cornered.deinit(testing.allocator);
    try testing.expect(extent(cornered)[0].eql(.zero));
    try testing.expect(extent(cornered)[1].eql(size));

    // The same convention as `cylinder`: centred in x and y, base on z = 0.
    const standing = try box(testing.allocator, size, .on_plane);
    defer standing.deinit(testing.allocator);
    try testing.expect(extent(standing)[0].eql(.init(-0.5, -1, 0)));
    try testing.expect(extent(standing)[1].eql(.init(0.5, 1, 4)));
}

test "a flat box encloses nothing but is still closed" {
    const flat = try box(testing.allocator, .init(2, 3, 0), .corner);
    defer flat.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f64, 0), volume(flat), 1e-9);
    const loops = try polygon.boundaryLoops(
        testing.allocator,
        @intCast(flat.vertices.len),
        flat.faces,
    );
    defer loops.deinit(testing.allocator);
    try testing.expectEqual(0, loops.count());
}

test "a box is an operand a boolean accepts" {
    const boolean = @import("boolean.zig");
    const block = try box(testing.allocator, .init(2, 2, 2), .centered);
    defer block.deinit(testing.allocator);
    const bore = try cylinder(testing.allocator, 0.5, 4, 48);
    defer bore.deinit(testing.allocator);
    mesh_mod.translate(bore.vertices, .init(0, 0, -2));

    const drilled = try boolean.apply(testing.allocator, block, bore, .subtract);
    defer drilled.deinit(testing.allocator);
    // A 48-gon is a hair under a circle, so the hole removes a hair under πr²h.
    try testing.expectApproxEqRel(8.0 - std.math.pi * 0.25 * 2.0, volume(drilled), 2e-3);
}

fn boxAllocationCase(gpa: std.mem.Allocator) !void {
    const solid = try box(gpa, .init(1, 1, 1), .corner);
    defer solid.deinit(gpa);
    if (solid.faces.len != 12) return error.TestUnexpectedResult;
}

test "box handles every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, boxAllocationCase, .{});
}
