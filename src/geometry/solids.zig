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
const triangulate = @import("triangulate.zig");

const Placement = mesh_mod.Placement;

const Vec3 = layout.Vec3;
const Mesh = mesh_mod.Mesh;

/// Failure of a solid: allocation, or the triangulation of a cap.
pub const Error = polygon.CapError || error{NotClosed};

/// Extrudes a closed two-dimensional profile into a solid.
///
/// The profile lies in a plane and its segments must chain into closed rings;
/// `displacement` is how far and in what direction it is swept. The result is
/// closed and wound outward, so it is a boolean operand directly.
///
/// Holes are preserved. A profile with a clockwise ring inside a
/// counter-clockwise one, which is what `planar.boolean` returns when a region
/// is subtracted from the middle of another, extrudes to a solid with a
/// passage through it: the hole's wall is swept like any other ring, and the
/// two caps are triangulated from all the rings together so that neither
/// covers it. This is why the extrusion does not go through `sweep` and
/// `capBoundaries`, which see one loop at a time and would fill the hole in.
///
/// The profile is read as lying in the z = 0 plane, since that is where a
/// planar operation leaves one; its z is ignored for the purpose of
/// triangulating the caps, though the vertices themselves are used as given.
pub fn extrude(
    gpa: std.mem.Allocator,
    profile: polyline.Polyline,
    displacement: Vec3,
) Error!Mesh {
    const rings = polyline.loops(gpa, profile) catch |err| switch (err) {
        error.NonManifoldBoundary => return error.NotClosed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer rings.deinit(gpa);
    if (rings.count() == 0) return .empty;

    // The rings laid end to end are both the vertex order of the result and the
    // index space the triangulation returns, so the caps need no remapping.
    const ring_count = rings.count();
    const points = rings.vertices.len;
    const lengths = try gpa.alloc(u32, ring_count);
    defer gpa.free(lengths);
    const flat = try gpa.alloc([2]f64, points);
    defer gpa.free(flat);
    var written: usize = 0;
    for (0..ring_count) |i| {
        const ring = rings.get(i);
        lengths[i] = @intCast(ring.len);
        for (ring) |index| {
            const v = profile.vertices[index];
            flat[written] = .{ v.x, v.y };
            written += 1;
        }
    }

    const cap_scratch = try gpa.alloc([3]u32, triangulate.triangleCapacity(points, ring_count));
    defer gpa.free(cap_scratch);
    const cap = try triangulate.polygon(flat, lengths, -1, cap_scratch);

    // Near vertices first, then the same again displaced, so far = near + points.
    const vertices = try gpa.alloc(Vec3, 2 * points);
    errdefer gpa.free(vertices);
    for (rings.vertices, 0..) |index, k| {
        vertices[k] = profile.vertices[index];
        vertices[points + k] = profile.vertices[index].add(displacement);
    }

    const faces = try gpa.alloc([3]u32, 2 * points + 2 * cap.len);
    errdefer gpa.free(faces);
    // Sweeping along the profile's own normal puts the far cap on the outside;
    // sweeping against it swaps which end is which, and the walls with it.
    const flip = displacement.dot(polyline.areaVector(profile)) < 0;
    var at: usize = 0;
    var base: u32 = 0;
    for (0..ring_count) |i| {
        const length: u32 = lengths[i];
        for (0..length) |k| {
            const a = base + @as(u32, @intCast(k));
            const b = base + @as(u32, @intCast((k + 1) % length));
            const a_far = a + @as(u32, @intCast(points));
            const b_far = b + @as(u32, @intCast(points));
            // A hole's ring runs the other way round, which is exactly what
            // turns its wall to face into the passage.
            faces[at] = if (flip) .{ a, b_far, b } else .{ a, b, b_far };
            faces[at + 1] = if (flip) .{ a, a_far, b_far } else .{ a, b_far, a_far };
            at += 2;
        }
        base += length;
    }
    const shift: u32 = @intCast(points);
    for (cap) |t| {
        // The near cap faces away from the sweep and the far cap along it, so
        // one of the two is the triangulation reversed.
        faces[at] = if (flip) .{ t[0], t[1], t[2] } else .{ t[0], t[2], t[1] };
        faces[at + 1] = if (flip)
            .{ t[0] + shift, t[2] + shift, t[1] + shift }
        else
            .{ t[0] + shift, t[1] + shift, t[2] + shift };
        at += 2;
    }
    return .{ .vertices = vertices, .faces = faces };
}

/// Builds a closed cylinder of `radius` and `height`, its base on the z = 0
/// plane and its axis along +z, approximated by `segment_count` sides.
///
/// The caller owns the result and places it with `mesh.translate`. This is
/// `extrude` of a `circle`, which is all it ever was.
///
/// Fewer than three segments encloses no volume and yields an empty mesh.
pub fn cylinder(
    gpa: std.mem.Allocator,
    radius: f32,
    height: f32,
    segment_count: u32,
) Error!Mesh {
    if (segment_count < 3) return .empty;
    const profile = try polyline.circle(gpa, radius, segment_count);
    defer profile.deinit(gpa);
    return extrude(gpa, profile, .init(0, 0, height));
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

test "extruding a profile with a hole leaves the hole open" {
    const gpa = testing.allocator;
    const planar = @import("planar.zig");
    const outer = try polyline.square(gpa, 4, .centered);
    defer outer.deinit(gpa);
    const inner = try polyline.square(gpa, 2, .centered);
    defer inner.deinit(gpa);
    const washer = try planar.boolean(gpa, outer, inner, .subtract);
    defer washer.deinit(gpa);

    const solid = try extrude(gpa, washer, .init(0, 0, 3));
    defer solid.deinit(gpa);

    // The volume is the region's, not the outer square's: a filled cap would
    // give 48 rather than 36, and a cap covering the hole would enclose it.
    try testing.expectApproxEqRel(@as(f64, (16 - 4) * 3), volume(solid), 1e-5);

    // Closed, so it is a boolean operand in turn.
    const loops = try polygon.boundaryLoops(gpa, @intCast(solid.vertices.len), solid.faces);
    defer loops.deinit(gpa);
    try testing.expectEqual(0, loops.count());

    // Eight vertices per end, two walls of eight quads, two caps of eight
    // triangles: a passage through the middle rather than a lid over it.
    try testing.expectEqual(16, solid.vertices.len);
    try testing.expectEqual(2 * 8 + 2 * 8, solid.faces.len);
}

test "a hole survives a boolean against the solid it passes through" {
    const gpa = testing.allocator;
    const boolean = @import("boolean.zig");
    const planar = @import("planar.zig");
    const outer = try polyline.square(gpa, 4, .centered);
    defer outer.deinit(gpa);
    const inner = try polyline.circle(gpa, 1, 48);
    defer inner.deinit(gpa);
    const washer = try planar.boolean(gpa, outer, inner, .subtract);
    defer washer.deinit(gpa);

    const solid = try extrude(gpa, washer, .init(0, 0, 2));
    defer solid.deinit(gpa);

    // A rod that fits the passage exactly removes nothing, because the passage
    // is already empty. If the extrusion had covered the hole, this would cut
    // the covered volume away and shrink the result.
    const rod = try cylinder(gpa, 1, 6, 48);
    defer rod.deinit(gpa);
    mesh_mod.translate(rod.vertices, .init(0, 0, -2));
    const cut = try boolean.apply(gpa, solid, rod, .subtract);
    defer cut.deinit(gpa);
    try testing.expectApproxEqRel(volume(solid), volume(cut), 1e-4);
}

test "extruding against the profile's own direction still winds outward" {
    const gpa = testing.allocator;
    for ([_]f32{ 3, -3 }) |height| {
        const profile = try polyline.rectangle(gpa, 2, 1, .centered);
        defer profile.deinit(gpa);
        const solid = try extrude(gpa, profile, .init(0, 0, height));
        defer solid.deinit(gpa);
        try testing.expectApproxEqRel(@as(f64, 6), volume(solid), 1e-5);
    }
}

test "extruding an open profile is reported" {
    const gpa = testing.allocator;
    const vertices = try gpa.dupe(Vec3, &.{ .init(0, 0, 0), .init(1, 0, 0), .init(2, 0, 0) });
    const segments = try gpa.dupe([2]u32, &.{ .{ 0, 1 }, .{ 1, 2 } });
    const open: polyline.Polyline = .{ .vertices = vertices, .segments = segments };
    defer open.deinit(gpa);
    try testing.expectError(error.NotClosed, extrude(gpa, open, .init(0, 0, 1)));
}

test "two separate rings extrude to two separate solids" {
    const gpa = testing.allocator;
    const planar = @import("planar.zig");
    const left = try polyline.square(gpa, 1, .centered);
    defer left.deinit(gpa);
    const right = try polyline.square(gpa, 1, .centered);
    defer right.deinit(gpa);
    mesh_mod.translate(right.vertices, .init(5, 0, 0));
    const pair = try planar.boolean(gpa, left, right, .add);
    defer pair.deinit(gpa);

    const solid = try extrude(gpa, pair, .init(0, 0, 2));
    defer solid.deinit(gpa);
    try testing.expectApproxEqRel(@as(f64, 4), volume(solid), 1e-5);
    const loops = try polygon.boundaryLoops(gpa, @intCast(solid.vertices.len), solid.faces);
    defer loops.deinit(gpa);
    try testing.expectEqual(0, loops.count());
}

fn extrudeAllocationCase(gpa: std.mem.Allocator) !void {
    const profile = try polyline.square(gpa, 2, .centered);
    defer profile.deinit(gpa);
    const solid = try extrude(gpa, profile, .init(0, 0, 1));
    defer solid.deinit(gpa);
    if (solid.faces.len == 0) return error.TestUnexpectedResult;
}

test "extrude handles every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, extrudeAllocationCase, .{});
}
