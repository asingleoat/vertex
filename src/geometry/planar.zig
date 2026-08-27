//! Operations on regions of the plane: offsetting a closed curve, and the
//! booleans between two of them.
//!
//! Both are Clipper2 underneath, reached through Manifold's `CrossSection`, and
//! both take and return a `Polyline`. A polyline is a vertex array and a
//! segment array, so several disjoint rings are as ordinary a value as one and
//! nothing new is needed to carry a result that splits, merges, or comes back
//! with a hole in it. Rings are read under the non-zero fill rule, which is
//! what makes a clockwise ring inside a counter-clockwise one a hole rather
//! than a second island.
//!
//! This is the third seam to Manifold, alongside `triangulate.zig` and
//! `boolean.zig`, with `manifold_shim.cpp` holding the C++ side of all of them.
//! Offsetting is the operation least worth writing here: moving each vertex
//! along its angle bisector is correct only while the result does not touch
//! itself, and a curve offset far enough inward will collapse, split or vanish.
//! Clipper2 resolves those cases instead of producing a self-intersecting
//! ring.
const std = @import("std");
const layout = @import("layout.zig");
const polyline_mod = @import("polyline.zig");
const polygon = @import("polygon.zig");
const boolean_mod = @import("boolean.zig");

const Vec3 = layout.Vec3;
const Polyline = polyline_mod.Polyline;

/// How a convex corner is filled when the boundary moves outward, which is
/// where an offset has a choice to make: the two edges either side no longer
/// meet, and something has to join them.
pub const Join = enum(c_int) {
    /// Cuts the corner off square, at `delta` from the original vertex.
    square = 0,
    /// Follows the arc a true offset traces, approximated by
    /// `circular_segments` segments. This is the offset in the strict sense,
    /// every point of the result being exactly `delta` from the input.
    round = 1,
    /// Extends both edges until they meet, which keeps a sharp corner sharp but
    /// runs away as the corner gets sharper; `miter_limit` is where it is cut.
    miter = 2,
    /// Cuts straight across between the two offset edges, which is the least
    /// the corner can be filled with.
    bevel = 3,
};

/// Options for `offset`.
pub const OffsetOptions = struct {
    /// How convex corners are filled. The default traces the true offset.
    join: Join = .round,
    /// How far a miter may extend, as a multiple of `delta`. Used only by
    /// `.miter`; Clipper2's own default is 2.
    miter_limit: f64 = 2,
    /// How finely a round join is approximated, over a full circle. Zero leaves
    /// the choice to Manifold's quality setting. Used only by `.round`.
    circular_segments: c_int = 0,
};

/// Failure of a planar operation.
///
/// `NotClosed` comes from this side: the profile's segments must chain into
/// closed rings, since a curve with an end has no inside to move away from.
/// `Threw` is an exception the shim caught.
pub const Error = error{
    NotClosed,
    Threw,
    OutOfMemory,
};

/// Moves a closed profile's boundary by `delta`, outward when positive.
///
/// The profile is treated as lying in the z = 0 plane: its z is ignored and the
/// result's is zero. A profile elsewhere is rotated in and out by the caller.
///
/// Rings are read under the non-zero fill rule, so a clockwise ring inside a
/// counter-clockwise one is a hole and moves the other way, as a hole should.
/// The result is a `Polyline` like the input and may hold a different number of
/// rings than it: offsetting outward merges rings that grow into each other,
/// and offsetting inward splits a waisted shape and can empty it entirely,
/// which yields a polyline with no segments rather than an error.
///
/// The caller owns the result.
pub fn offset(
    gpa: std.mem.Allocator,
    profile: Polyline,
    delta: f32,
    options: OffsetOptions,
) Error!Polyline {
    const rings = try ringsOf(gpa, profile);
    defer rings.deinit(gpa);
    if (rings.count() == 0) return .empty;

    const flat = try flatten(gpa, profile, rings);
    defer flat.deinit(gpa);

    var handle: ?*anyopaque = null;
    var point_count: usize = 0;
    var loop_count: usize = 0;
    const status = vertexOffsetBegin(
        @ptrCast(flat.xy.ptr),
        flat.lengths.ptr,
        flat.lengths.len,
        delta,
        @backingInt(options.join),
        options.miter_limit,
        options.circular_segments,
        &handle,
        &point_count,
        &loop_count,
    );
    switch (status) {
        ok => {},
        threw => return error.Threw,
        else => return error.OutOfMemory,
    }
    defer vertexPolygonsRelease(handle);
    if (point_count == 0) return .empty;
    return rebuild(gpa, handle, point_count, loop_count);
}

/// Combines two closed profiles as regions of the plane.
///
/// This is the planar counterpart of `boolean.apply`: it works on regions
/// rather than on solids, and takes the same `Op`. Both profiles lie in the
/// z = 0 plane, their z ignored and the result's zero, and both must chain into
/// closed rings.
///
/// The result may hold any number of rings and is a region rather than a simple
/// outline: subtracting a square from a larger one gives a counter-clockwise
/// outer ring and a clockwise inner one, which is a hole. `polyline.areaVector`
/// is negative for such a ring and `polyline.loops` tells them apart.
///
/// The caller owns the result.
pub fn boolean(
    gpa: std.mem.Allocator,
    a: Polyline,
    b: Polyline,
    op: boolean_mod.Op,
) Error!Polyline {
    const a_rings = try ringsOf(gpa, a);
    defer a_rings.deinit(gpa);
    const b_rings = try ringsOf(gpa, b);
    defer b_rings.deinit(gpa);
    if (a_rings.count() == 0 and b_rings.count() == 0) return .empty;

    const a_flat = try flatten(gpa, a, a_rings);
    defer a_flat.deinit(gpa);
    const b_flat = try flatten(gpa, b, b_rings);
    defer b_flat.deinit(gpa);

    var handle: ?*anyopaque = null;
    var point_count: usize = 0;
    var loop_count: usize = 0;
    const status = vertexPlanarBooleanBegin(
        @ptrCast(a_flat.xy.ptr),
        a_flat.lengths.ptr,
        a_flat.lengths.len,
        @ptrCast(b_flat.xy.ptr),
        b_flat.lengths.ptr,
        b_flat.lengths.len,
        @backingInt(op),
        &handle,
        &point_count,
        &loop_count,
    );
    switch (status) {
        ok => {},
        threw => return error.Threw,
        else => return error.OutOfMemory,
    }
    defer vertexPolygonsRelease(handle);
    if (point_count == 0) return .empty;
    return rebuild(gpa, handle, point_count, loop_count);
}

/// One polyline's rings as the C side takes them: points end to end as x, y
/// pairs, with the lengths that divide them into rings. The conversion from
/// this project's `f32` to Clipper2's `f64` happens here.
const Flat = struct {
    xy: [][2]f64,
    lengths: []u32,

    fn deinit(self: Flat, gpa: std.mem.Allocator) void {
        gpa.free(self.xy);
        gpa.free(self.lengths);
    }
};

fn flatten(
    gpa: std.mem.Allocator,
    profile: Polyline,
    rings: polygon.Loops,
) std.mem.Allocator.Error!Flat {
    const xy = try gpa.alloc([2]f64, rings.vertices.len);
    errdefer gpa.free(xy);
    const lengths = try gpa.alloc(u32, rings.count());
    errdefer gpa.free(lengths);
    var written: usize = 0;
    for (0..rings.count()) |i| {
        const ring = rings.get(i);
        lengths[i] = @intCast(ring.len);
        for (ring) |index| {
            const v = profile.vertices[index];
            xy[written] = .{ v.x, v.y };
            written += 1;
        }
    }
    return .{ .xy = xy, .lengths = lengths };
}

/// The rings of `profile`, or `NotClosed` if its segments do not chain into
/// closed loops.
fn ringsOf(gpa: std.mem.Allocator, profile: Polyline) Error!polygon.Loops {
    return polyline_mod.loops(gpa, profile) catch |err| switch (err) {
        error.NonManifoldBoundary => error.NotClosed,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Rebuilds a polyline from the points and ring lengths the C side reports.
fn rebuild(
    gpa: std.mem.Allocator,
    handle: ?*anyopaque,
    point_count: usize,
    loop_count: usize,
) std.mem.Allocator.Error!Polyline {
    const out_xy = try gpa.alloc([2]f64, point_count);
    defer gpa.free(out_xy);
    const out_lengths = try gpa.alloc(u32, loop_count);
    defer gpa.free(out_lengths);
    vertexPolygonsTake(handle, @ptrCast(out_xy.ptr), out_lengths.ptr);

    const vertices = try gpa.alloc(Vec3, point_count);
    errdefer gpa.free(vertices);
    for (vertices, out_xy) |*v, point| {
        v.* = .init(@floatCast(point[0]), @floatCast(point[1]), 0);
    }
    const segments = try gpa.alloc([2]u32, point_count);
    errdefer gpa.free(segments);
    var base: u32 = 0;
    var at: usize = 0;
    for (out_lengths) |length| {
        for (0..length) |k| {
            const from = base + @as(u32, @intCast(k));
            segments[at] = .{ from, base + @as(u32, @intCast((k + 1) % length)) };
            at += 1;
        }
        base += length;
    }
    return .{ .vertices = vertices, .segments = segments };
}

/// The status codes `manifold_shim.cpp` returns.
const ok = 0;
const threw = 1;

extern fn vertexOffsetBegin(
    xy: [*]const f64,
    loop_lengths: [*]const u32,
    loop_count: usize,
    delta: f64,
    join: c_int,
    miter_limit: f64,
    circular_segments: c_int,
    handle: *?*anyopaque,
    point_count: *usize,
    out_loop_count: *usize,
) c_int;
extern fn vertexPlanarBooleanBegin(
    a_xy: [*]const f64,
    a_lengths: [*]const u32,
    a_count: usize,
    b_xy: [*]const f64,
    b_lengths: [*]const u32,
    b_count: usize,
    op: c_int,
    handle: *?*anyopaque,
    point_count: *usize,
    loop_count: *usize,
) c_int;
extern fn vertexPolygonsTake(handle: ?*anyopaque, xy: [*]f64, loop_lengths: [*]u32) void;
extern fn vertexPolygonsRelease(handle: ?*anyopaque) void;

const testing = std.testing;

/// The area a closed polyline encloses, signed positive for counter-clockwise.
fn area(profile: Polyline) f64 {
    return @as(f64, polyline_mod.areaVector(profile).z);
}

test "offsetting a square outward grows it by the distance on every side" {
    const profile = try polyline_mod.square(testing.allocator, 4, .centered);
    defer profile.deinit(testing.allocator);

    // A miter carries each corner to where the two offset edges meet, so a
    // right angle offset by one gives exactly a 6 by 6. The default limit of 2
    // is well clear of the ratio a right angle needs, which is the square
    // root of two.
    const mitered = try offset(testing.allocator, profile, 1, .{ .join = .miter });
    defer mitered.deinit(testing.allocator);
    try testing.expectApproxEqRel(@as(f64, 36), area(mitered), 1e-4);

    // A square join cuts each corner off at `delta` from the original vertex,
    // which removes an isoceles triangle with legs of 2 - sqrt(2).
    const chamfered = try offset(testing.allocator, profile, 1, .{ .join = .square });
    defer chamfered.deinit(testing.allocator);
    const leg: f64 = 2 - @sqrt(2.0);
    try testing.expectApproxEqRel(36.0 - 2 * leg * leg, area(chamfered), 1e-4);
}

test "a round join traces the true offset, corners included" {
    const profile = try polyline_mod.square(testing.allocator, 4, .centered);
    defer profile.deinit(testing.allocator);
    const grown = try offset(testing.allocator, profile, 1, .{ .join = .round, .circular_segments = 256 });
    defer grown.deinit(testing.allocator);

    // The offset of a square by r is the square, four r-wide slabs along its
    // sides, and four quarter-discs at its corners.
    const expected = 16 + 4 * 4 * 1 + std.math.pi * 1;
    try testing.expectApproxEqRel(expected, area(grown), 1e-3);
}

test "offsetting inward shrinks, and far enough inward empties" {
    const profile = try polyline_mod.square(testing.allocator, 4, .centered);
    defer profile.deinit(testing.allocator);

    const shrunk = try offset(testing.allocator, profile, -1, .{ .join = .square });
    defer shrunk.deinit(testing.allocator);
    try testing.expectApproxEqRel(@as(f64, 4), area(shrunk), 1e-4);

    // Past half the width there is nothing left, which is a result rather than
    // a failure.
    const gone = try offset(testing.allocator, profile, -3, .{ .join = .square });
    defer gone.deinit(testing.allocator);
    try testing.expectEqual(0, gone.segments.len);
}

test "the result is a closed polyline, so it can be offset again" {
    const profile = try polyline_mod.circle(testing.allocator, 1, 32);
    defer profile.deinit(testing.allocator);
    const once = try offset(testing.allocator, profile, 0.5, .{ .circular_segments = 128 });
    defer once.deinit(testing.allocator);
    const twice = try offset(testing.allocator, once, 0.5, .{ .circular_segments = 128 });
    defer twice.deinit(testing.allocator);

    const rings = try polyline_mod.loops(testing.allocator, twice);
    defer rings.deinit(testing.allocator);
    try testing.expectEqual(1, rings.count());
    // A disc of radius 1 offset by a half twice is a disc of radius 2.
    try testing.expectApproxEqRel(std.math.pi * 4, area(twice), 1e-2);
}

test "two rings that grow into each other merge" {
    const gpa = testing.allocator;
    const left = try polyline_mod.circle(gpa, 1, 64);
    defer left.deinit(gpa);
    const right = try polyline_mod.circle(gpa, 1, 64);
    defer right.deinit(gpa);
    @import("mesh.zig").translate(right.vertices, .init(3, 0, 0));

    // One polyline holding both rings, which needs no new type: a polyline is
    // its segments, and nothing says they form a single cycle.
    var vertices: std.ArrayList(Vec3) = .empty;
    defer vertices.deinit(gpa);
    try vertices.appendSlice(gpa, left.vertices);
    try vertices.appendSlice(gpa, right.vertices);
    var segments: std.ArrayList([2]u32) = .empty;
    defer segments.deinit(gpa);
    try segments.appendSlice(gpa, left.segments);
    const shift: u32 = @intCast(left.vertices.len);
    for (right.segments) |s| try segments.append(gpa, .{ s[0] + shift, s[1] + shift });
    const pair: Polyline = .{ .vertices = vertices.items, .segments = segments.items };

    const apart = try offset(gpa, pair, 0.4, .{ .circular_segments = 64 });
    defer apart.deinit(gpa);
    const apart_rings = try polyline_mod.loops(gpa, apart);
    defer apart_rings.deinit(gpa);
    try testing.expectEqual(2, apart_rings.count());

    // Grown by more than half the gap, the two become one.
    const merged = try offset(gpa, pair, 0.6, .{ .circular_segments = 64 });
    defer merged.deinit(gpa);
    const merged_rings = try polyline_mod.loops(gpa, merged);
    defer merged_rings.deinit(gpa);
    try testing.expectEqual(1, merged_rings.count());
}

test "an open profile is reported rather than offset" {
    const vertices = try testing.allocator.dupe(Vec3, &.{
        .init(0, 0, 0), .init(1, 0, 0), .init(2, 0, 0),
    });
    const segments = try testing.allocator.dupe([2]u32, &.{ .{ 0, 1 }, .{ 1, 2 } });
    const open: Polyline = .{ .vertices = vertices, .segments = segments };
    defer open.deinit(testing.allocator);
    try testing.expectError(error.NotClosed, offset(testing.allocator, open, 1, .{}));
}

test "an empty profile offsets to nothing" {
    const empty = try offset(testing.allocator, .empty, 1, .{});
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(0, empty.segments.len);
}

fn offsetAllocationCase(gpa: std.mem.Allocator) !void {
    const profile = try polyline_mod.square(gpa, 2, .centered);
    defer profile.deinit(gpa);
    const grown = try offset(gpa, profile, 0.5, .{ .join = .square });
    defer grown.deinit(gpa);
    if (grown.segments.len == 0) return error.TestUnexpectedResult;
}

test "offset handles every allocation failure it can see" {
    try testing.checkAllAllocationFailures(testing.allocator, offsetAllocationCase, .{});
}

test "planar booleans agree with the areas they should produce" {
    const gpa = testing.allocator;
    const a = try polyline_mod.square(gpa, 2, .corner);
    defer a.deinit(gpa);
    const b = try polyline_mod.square(gpa, 2, .corner);
    defer b.deinit(gpa);
    @import("mesh.zig").translate(b.vertices, .init(1, 1, 0));

    const overlap = 1.0;
    const cases = [_]struct { op: boolean_mod.Op, want: f64 }{
        .{ .op = .add, .want = 8 - overlap },
        .{ .op = .subtract, .want = 4 - overlap },
        .{ .op = .intersect, .want = overlap },
    };
    for (cases) |case| {
        const result = try boolean(gpa, a, b, case.op);
        defer result.deinit(gpa);
        try testing.expectApproxEqRel(case.want, area(result), 1e-5);
    }
}

test "subtracting an interior region leaves a hole" {
    const gpa = testing.allocator;
    const outer = try polyline_mod.square(gpa, 4, .centered);
    defer outer.deinit(gpa);
    const inner = try polyline_mod.square(gpa, 2, .centered);
    defer inner.deinit(gpa);

    const ring = try boolean(gpa, outer, inner, .subtract);
    defer ring.deinit(gpa);

    // Two rings, and the signed areas say which is which: the hole is wound the
    // other way, so the total is the region's area rather than the sum.
    const rings = try polyline_mod.loops(gpa, ring);
    defer rings.deinit(gpa);
    try testing.expectEqual(2, rings.count());
    try testing.expectApproxEqRel(@as(f64, 16 - 4), area(ring), 1e-5);
}

test "a result is a profile in turn, so planar operations compose" {
    const gpa = testing.allocator;
    const a = try polyline_mod.square(gpa, 4, .centered);
    defer a.deinit(gpa);
    const b = try polyline_mod.square(gpa, 2, .centered);
    defer b.deinit(gpa);

    const ring = try boolean(gpa, a, b, .subtract);
    defer ring.deinit(gpa);
    // Offsetting a region with a hole moves both boundaries into the material.
    const thinner = try offset(gpa, ring, -0.25, .{ .join = .miter });
    defer thinner.deinit(gpa);
    try testing.expectApproxEqRel(@as(f64, 3.5 * 3.5 - 2.5 * 2.5), area(thinner), 1e-4);

    // Adding the 2 by 2 back covers part of the 2.5 by 2.5 hole but not all of
    // it, so the region gains exactly the square's area.
    const again = try boolean(gpa, thinner, b, .add);
    defer again.deinit(gpa);
    try testing.expectApproxEqRel(@as(f64, 3.5 * 3.5 - 2.5 * 2.5 + 2 * 2), area(again), 1e-4);
}

test "disjoint profiles are handled by every operation" {
    const gpa = testing.allocator;
    const a = try polyline_mod.square(gpa, 1, .corner);
    defer a.deinit(gpa);
    const b = try polyline_mod.square(gpa, 1, .corner);
    defer b.deinit(gpa);
    @import("mesh.zig").translate(b.vertices, .init(5, 0, 0));

    const joined = try boolean(gpa, a, b, .add);
    defer joined.deinit(gpa);
    try testing.expectApproxEqRel(@as(f64, 2), area(joined), 1e-5);

    const shared = try boolean(gpa, a, b, .intersect);
    defer shared.deinit(gpa);
    try testing.expectEqual(0, shared.segments.len);
}

test "an open profile is reported rather than combined" {
    const gpa = testing.allocator;
    const closed = try polyline_mod.square(gpa, 1, .corner);
    defer closed.deinit(gpa);
    const vertices = try gpa.dupe(Vec3, &.{ .init(0, 0, 0), .init(1, 0, 0), .init(2, 0, 0) });
    const segments = try gpa.dupe([2]u32, &.{ .{ 0, 1 }, .{ 1, 2 } });
    const open: Polyline = .{ .vertices = vertices, .segments = segments };
    defer open.deinit(gpa);

    try testing.expectError(error.NotClosed, boolean(gpa, closed, open, .add));
    try testing.expectError(error.NotClosed, boolean(gpa, open, closed, .add));
}

fn planarBooleanAllocationCase(gpa: std.mem.Allocator) !void {
    const a = try polyline_mod.square(gpa, 2, .corner);
    defer a.deinit(gpa);
    const b = try polyline_mod.square(gpa, 2, .centered);
    defer b.deinit(gpa);
    const result = try boolean(gpa, a, b, .add);
    defer result.deinit(gpa);
    if (result.segments.len == 0) return error.TestUnexpectedResult;
}

test "boolean handles every allocation failure it can see" {
    try testing.checkAllAllocationFailures(testing.allocator, planarBooleanAllocationCase, .{});
}
