//! Planar boolean and offset benchmark, over arrangements chosen to separate
//! what the cost actually depends on.
//!
//! A sweep-line clipper's work is not a function of the input size alone, so
//! size, crossing count and arrangement are varied against each other. Two
//! convex rings meet at two points however many vertices they have, which
//! isolates the size term. A row of overlapping squares against a row offset
//! from it holds the crossings proportional to the size, and is then laid out
//! three ways with everything else held equal: all in one band, in one band
//! with the squares nudged apart in y, and strung along a diagonal.
//!
//! What the three show is that the driver is neither the vertex count nor the
//! crossing count but the number of edges live at one position of the sweep.
//! Along a diagonal, where a couple of squares overlap in y at a time, the cost
//! is linear. In a band, where every square overlaps every other in y, it is
//! quadratic, at the same size and the same number of crossings. Nudging the
//! squares apart in y does not help, which rules out coincident scanlines as
//! the cause; it only defers the growth until the overlap saturates.
const std = @import("std");
const vertex = @import("vertex");
const harness = @import("lib/harness.zig");

const Vec3 = vertex.Vec3;
const Polyline = vertex.internal.polyline.Polyline;
const planar = vertex.internal.planar;

pub fn main() !void {
    var io_state: harness.Io = .{};
    const io = io_state.get();
    const gpa = std.heap.page_allocator;

    for ([_]u32{ 64, 256, 1024, 4096, 16384 }) |n| {
        const a = try vertex.internal.polyline.circle(gpa, 1, n);
        defer a.deinit(gpa);
        const b = try vertex.internal.polyline.circle(gpa, 1, n);
        defer b.deinit(gpa);
        vertex.internal.mesh.translate(b.vertices, .init(0.5, 0, 0));

        var context: Boolean = .{ .gpa = gpa, .a = a, .b = b };
        harness.bench(io, "planar/boolean two rings", "-", n, .{ .elements = n, .unit = "verts/s" }, &context, Boolean.run);
    }

    for ([_]struct { label: []const u8, stagger: f32 }{
        .{ .label = "planar/boolean crossings in one band", .stagger = 0 },
        .{ .label = "planar/boolean crossings in one band, nudged", .stagger = 0.001 },
        .{ .label = "planar/boolean crossings along a diagonal", .stagger = 2 },
    }) |arrangement| {
        for ([_]u32{ 16, 64, 256, 1024, 4096 }) |m| {
            const a = try squareRow(gpa, m, 0, arrangement.stagger);
            defer a.deinit(gpa);
            const b = try squareRow(gpa, m, 0.5, arrangement.stagger);
            defer b.deinit(gpa);

            const n = 4 * m;
            var context: Boolean = .{ .gpa = gpa, .a = a, .b = b };
            harness.bench(io, arrangement.label, "-", n, .{ .elements = n, .unit = "verts/s" }, &context, Boolean.run);
        }
    }

    for ([_]u32{ 64, 256, 1024, 4096, 16384 }) |n| {
        const a = try vertex.internal.polyline.circle(gpa, 1, n);
        defer a.deinit(gpa);
        var context: Offset = .{ .gpa = gpa, .profile = a };
        harness.bench(io, "planar/offset one ring", "-", n, .{ .elements = n, .unit = "verts/s" }, &context, Offset.run);
    }
}

/// `m` unit squares two units apart, shifted along x by `shift`, each square of
/// one set overlapping one of the other so that the intersections grow with the
/// input rather than staying at two.
///
/// `stagger` spreads them along y as well as x. At zero they lie in one
/// horizontal band, so every edge is live at once in a sweep that advances
/// through y; at two they are strung along a diagonal and only a couple are
/// live at a time. The two are the same size and the same number of crossings,
/// and differ only in that.
fn squareRow(gpa: std.mem.Allocator, m: u32, shift: f32, stagger: f32) !Polyline {
    const vertices = try gpa.alloc(Vec3, 4 * m);
    errdefer gpa.free(vertices);
    const segments = try gpa.alloc([2]u32, 4 * m);
    errdefer gpa.free(segments);
    for (0..m) |i| {
        const x = @as(f32, @floatFromInt(i)) * 2 + shift;
        const y = @as(f32, @floatFromInt(i)) * stagger;
        const base: u32 = @intCast(4 * i);
        vertices[base + 0] = .init(x, y, 0);
        vertices[base + 1] = .init(x + 1, y, 0);
        vertices[base + 2] = .init(x + 1, y + 1, 0);
        vertices[base + 3] = .init(x, y + 1, 0);
        for (0..4) |k| {
            segments[base + k] = .{ base + @as(u32, @intCast(k)), base + @as(u32, @intCast((k + 1) % 4)) };
        }
    }
    return .{ .vertices = vertices, .segments = segments };
}

const Boolean = struct {
    gpa: std.mem.Allocator,
    a: Polyline,
    b: Polyline,

    fn run(self: *Boolean) usize {
        const result = planar.boolean(self.gpa, self.a, self.b, .add) catch return 0;
        defer result.deinit(self.gpa);
        return result.segments.len;
    }
};

const Offset = struct {
    gpa: std.mem.Allocator,
    profile: Polyline,

    fn run(self: *Offset) usize {
        const result = planar.offset(self.gpa, self.profile, 0.1, .{ .join = .miter }) catch return 0;
        defer result.deinit(self.gpa);
        return result.segments.len;
    }
};
