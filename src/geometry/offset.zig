//! Offsetting closed curves, the third seam between this project's geometry and
//! Manifold.
//!
//! `triangulate.zig` and `boolean.zig` are the others, and
//! `manifold_shim.cpp` holds the C++ side of all three. They are separate
//! modules because the seam is drawn per operation: writing any one of them
//! here would leave the other two untouched.
//!
//! Offsetting is Clipper2 underneath, reached through Manifold's
//! `CrossSection`. It is the one operation of the three that is genuinely hard
//! to do naively: moving each vertex along its angle bisector is correct only
//! while the result does not touch itself, and a curve offset far enough inward
//! will collapse, split, or vanish. Clipper2 resolves those cases instead of
//! producing a self-intersecting ring.
const std = @import("std");
const layout = @import("layout.zig");
const polyline_mod = @import("polyline.zig");

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

/// Options for `apply`.
pub const Options = struct {
    /// How convex corners are filled. The default traces the true offset.
    join: Join = .round,
    /// How far a miter may extend, as a multiple of `delta`. Used only by
    /// `.miter`; Clipper2's own default is 2.
    miter_limit: f64 = 2,
    /// How finely a round join is approximated, over a full circle. Zero leaves
    /// the choice to Manifold's quality setting. Used only by `.round`.
    circular_segments: c_int = 0,
};

/// Failure of an offset.
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
pub fn apply(
    gpa: std.mem.Allocator,
    profile: Polyline,
    delta: f32,
    options: Options,
) Error!Polyline {
    const rings = polyline_mod.loops(gpa, profile) catch |err| switch (err) {
        error.NonManifoldBoundary => return error.NotClosed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer rings.deinit(gpa);
    if (rings.count() == 0) return .empty;

    // Flattened to the pairs of doubles the C side takes, which is also the
    // conversion from this project's f32 to Clipper2's f64.
    const xy = try gpa.alloc([2]f64, rings.vertices.len);
    defer gpa.free(xy);
    const lengths = try gpa.alloc(u32, rings.count());
    defer gpa.free(lengths);
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

    var handle: ?*anyopaque = null;
    var point_count: usize = 0;
    var loop_count: usize = 0;
    const status = vertexOffsetBegin(
        @ptrCast(xy.ptr),
        lengths.ptr,
        lengths.len,
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
    defer vertexOffsetRelease(handle);
    if (point_count == 0) return .empty;

    const out_xy = try gpa.alloc([2]f64, point_count);
    defer gpa.free(out_xy);
    const out_lengths = try gpa.alloc(u32, loop_count);
    defer gpa.free(out_lengths);
    vertexOffsetTake(handle, @ptrCast(out_xy.ptr), out_lengths.ptr);

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
extern fn vertexOffsetTake(handle: ?*anyopaque, xy: [*]f64, loop_lengths: [*]u32) void;
extern fn vertexOffsetRelease(handle: ?*anyopaque) void;

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
    const mitered = try apply(testing.allocator, profile, 1, .{ .join = .miter });
    defer mitered.deinit(testing.allocator);
    try testing.expectApproxEqRel(@as(f64, 36), area(mitered), 1e-4);

    // A square join cuts each corner off at `delta` from the original vertex,
    // which removes an isoceles triangle with legs of 2 - sqrt(2).
    const chamfered = try apply(testing.allocator, profile, 1, .{ .join = .square });
    defer chamfered.deinit(testing.allocator);
    const leg: f64 = 2 - @sqrt(2.0);
    try testing.expectApproxEqRel(36.0 - 2 * leg * leg, area(chamfered), 1e-4);
}

test "a round join traces the true offset, corners included" {
    const profile = try polyline_mod.square(testing.allocator, 4, .centered);
    defer profile.deinit(testing.allocator);
    const grown = try apply(testing.allocator, profile, 1, .{ .join = .round, .circular_segments = 256 });
    defer grown.deinit(testing.allocator);

    // The offset of a square by r is the square, four r-wide slabs along its
    // sides, and four quarter-discs at its corners.
    const expected = 16 + 4 * 4 * 1 + std.math.pi * 1;
    try testing.expectApproxEqRel(expected, area(grown), 1e-3);
}

test "offsetting inward shrinks, and far enough inward empties" {
    const profile = try polyline_mod.square(testing.allocator, 4, .centered);
    defer profile.deinit(testing.allocator);

    const shrunk = try apply(testing.allocator, profile, -1, .{ .join = .square });
    defer shrunk.deinit(testing.allocator);
    try testing.expectApproxEqRel(@as(f64, 4), area(shrunk), 1e-4);

    // Past half the width there is nothing left, which is a result rather than
    // a failure.
    const gone = try apply(testing.allocator, profile, -3, .{ .join = .square });
    defer gone.deinit(testing.allocator);
    try testing.expectEqual(0, gone.segments.len);
}

test "the result is a closed polyline, so it can be offset again" {
    const profile = try polyline_mod.circle(testing.allocator, 1, 32);
    defer profile.deinit(testing.allocator);
    const once = try apply(testing.allocator, profile, 0.5, .{ .circular_segments = 128 });
    defer once.deinit(testing.allocator);
    const twice = try apply(testing.allocator, once, 0.5, .{ .circular_segments = 128 });
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

    const apart = try apply(gpa, pair, 0.4, .{ .circular_segments = 64 });
    defer apart.deinit(gpa);
    const apart_rings = try polyline_mod.loops(gpa, apart);
    defer apart_rings.deinit(gpa);
    try testing.expectEqual(2, apart_rings.count());

    // Grown by more than half the gap, the two become one.
    const merged = try apply(gpa, pair, 0.6, .{ .circular_segments = 64 });
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
    try testing.expectError(error.NotClosed, apply(testing.allocator, open, 1, .{}));
}

test "an empty profile offsets to nothing" {
    const empty = try apply(testing.allocator, .empty, 1, .{});
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(0, empty.segments.len);
}

fn offsetAllocationCase(gpa: std.mem.Allocator) !void {
    const profile = try polyline_mod.square(gpa, 2, .centered);
    defer profile.deinit(gpa);
    const grown = try apply(gpa, profile, 0.5, .{ .join = .square });
    defer grown.deinit(gpa);
    if (grown.segments.len == 0) return error.TestUnexpectedResult;
}

test "apply handles every allocation failure it can see" {
    try testing.checkAllAllocationFailures(testing.allocator, offsetAllocationCase, .{});
}
