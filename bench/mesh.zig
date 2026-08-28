//! Benchmark for the mesh-building operations: lofting, capping, boundary
//! recovery, triangulation, booleans and extrusion.
//!
//! These are the operations a sketch spends its time in between generating a
//! profile and sending a solid, and several of them were written without a
//! benchmark to their name.
const std = @import("std");
const vertex = @import("vertex");
const harness = @import("lib/harness.zig");

const Vec3 = vertex.Vec3;
const Mesh = vertex.internal.mesh.Mesh;
const polyline = vertex.internal.polyline;
const polygon = vertex.internal.polygon;
const solids = vertex.internal.solids;
const boolean = vertex.internal.boolean;
const triangulate = vertex.internal.triangulate;

pub fn main() !void {
    var io_state: harness.Io = .{};
    const io = io_state.get();
    const gpa = std.heap.smp_allocator;

    for ([_]u32{ 64, 1024, 4096 }) |n| {
        const bottom = try polyline.circle(gpa, 1, n);
        defer bottom.deinit(gpa);
        const top = try bottom.clone(gpa);
        defer top.deinit(gpa);
        vertex.internal.mesh.translate(top.vertices, .init(0, 0, 2));

        var loft_context: Loft = .{ .gpa = gpa, .bottom = bottom, .top = top };
        harness.bench(io, "polyline/loft", "-", n, .{ .elements = n, .unit = "segments/s" }, &loft_context, Loft.run);

        const wall = try polyline.loft(gpa, bottom, top, 0, false);
        defer wall.deinit(gpa);

        var boundary_context: Boundary = .{ .gpa = gpa, .mesh = wall };
        harness.bench(io, "polygon/boundaryLoops", "-", n, .{ .elements = wall.faces.len, .unit = "faces/s" }, &boundary_context, Boundary.run);

        for ([_]polygon.Strategy{ .general, .fan, .hierarchical, .centroid }) |strategy| {
            var cap_context: Cap = .{ .gpa = gpa, .mesh = wall, .strategy = strategy };
            harness.bench(io, b: {
                break :b switch (strategy) {
                    .general => "polygon/capBoundaries general",
                    .fan => "polygon/capBoundaries fan",
                    .hierarchical => "polygon/capBoundaries hierarchical",
                    .centroid => "polygon/capBoundaries centroid",
                };
            }, "-", n, .{ .elements = n, .unit = "ring verts/s" }, &cap_context, Cap.run);
        }

        var extrude_context: Extrude = .{ .gpa = gpa, .profile = bottom };
        harness.bench(io, "solids/extrude", "-", n, .{ .elements = n, .unit = "profile verts/s" }, &extrude_context, Extrude.run);

        // One ring triangulated on its own, which is the seam without the
        // surrounding sweep and cap bookkeeping.
        const points = try gpa.alloc([2]f64, n);
        defer gpa.free(points);
        for (points, bottom.vertices) |*p, v| p.* = .{ v.x, v.y };
        const scratch = try gpa.alloc([3]u32, triangulate.triangleCount(n));
        defer gpa.free(scratch);
        var tri_context: Triangulate = .{ .points = points, .out = scratch };
        harness.bench(io, "triangulate/simplePolygon", "-", n, .{ .elements = n, .unit = "verts/s" }, &tri_context, Triangulate.run);
    }

    // The seam converts f32 to f64, so what reaches Manifold is exact but
    // quantised: the values lie on the f32 grid. Past about twelve thousand
    // points on a unit circle that grid is coarser than the ring's own detail,
    // consecutive points become collinear where the circle is not, and the
    // triangulator falls off a cliff. Measured at 16384 the rounded ring costs
    // three hundred times the exact one, which is what the deferred
    // parameterization over numeric types would recover.
    {
        const n: u32 = 16384;
        const out = try gpa.alloc([3]u32, triangulate.triangleCount(n));
        defer gpa.free(out);

        const exact = try gpa.alloc([2]f64, n);
        defer gpa.free(exact);
        for (exact, 0..) |*point, i| {
            const turns = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
            const theta = turns * std.math.tau;
            point.* = .{ @cos(theta), @sin(theta) };
        }
        var exact_context: Triangulate = .{ .points = exact, .out = out };
        harness.bench(io, "triangulate/ring computed in f64", "-", n, .{ .elements = n, .unit = "verts/s" }, &exact_context, Triangulate.run);

        const ring = try polyline.circle(gpa, 1, n);
        defer ring.deinit(gpa);
        const rounded = try gpa.alloc([2]f64, n);
        defer gpa.free(rounded);
        for (rounded, ring.vertices) |*point, v| point.* = .{ v.x, v.y };
        var rounded_context: Triangulate = .{ .points = rounded, .out = out };
        harness.bench(io, "triangulate/ring rounded through f32", "-", n, .{ .elements = n, .unit = "verts/s" }, &rounded_context, Triangulate.run);
    }

    for ([_]u32{ 32, 256, 2048 }) |n| {
        const a = try solids.cylinder(gpa, 1, 2, n);
        defer a.deinit(gpa);
        const b = try solids.cylinder(gpa, 0.6, 4, n);
        defer b.deinit(gpa);
        vertex.internal.mesh.translate(b.vertices, .init(0, 0, -1));

        var context: Boolean = .{ .gpa = gpa, .a = a, .b = b };
        harness.bench(io, "boolean/subtract", "-", n, .{ .elements = a.faces.len + b.faces.len, .unit = "faces/s" }, &context, Boolean.run);
    }
}

const Loft = struct {
    gpa: std.mem.Allocator,
    bottom: polyline.Polyline,
    top: polyline.Polyline,

    fn run(self: *Loft) usize {
        const m = polyline.loft(self.gpa, self.bottom, self.top, 0, false) catch return 0;
        defer m.deinit(self.gpa);
        return m.faces.len;
    }
};

const Boundary = struct {
    gpa: std.mem.Allocator,
    mesh: Mesh,

    fn run(self: *Boundary) usize {
        const loops = polygon.boundaryLoops(self.gpa, @intCast(self.mesh.vertices.len), self.mesh.faces) catch return 0;
        defer loops.deinit(self.gpa);
        return loops.count();
    }
};

const Cap = struct {
    gpa: std.mem.Allocator,
    mesh: Mesh,
    strategy: polygon.Strategy,

    fn run(self: *Cap) usize {
        var vertices: std.ArrayList(Vec3) = .empty;
        defer vertices.deinit(self.gpa);
        var faces: std.ArrayList([3]u32) = .empty;
        defer faces.deinit(self.gpa);
        vertices.appendSlice(self.gpa, self.mesh.vertices) catch return 0;
        faces.appendSlice(self.gpa, self.mesh.faces) catch return 0;
        polygon.capBoundaries(self.gpa, &vertices, &faces, .{ .strategy = self.strategy }) catch return 0;
        return faces.items.len;
    }
};

const Extrude = struct {
    gpa: std.mem.Allocator,
    profile: polyline.Polyline,

    fn run(self: *Extrude) usize {
        const m = solids.extrude(self.gpa, self.profile, .init(0, 0, 2)) catch return 0;
        defer m.deinit(self.gpa);
        return m.faces.len;
    }
};

const Triangulate = struct {
    points: []const [2]f64,
    out: [][3]u32,

    fn run(self: *Triangulate) usize {
        const tris = triangulate.simplePolygon(self.points, -1, self.out) catch return 0;
        return tris.len;
    }
};

const Boolean = struct {
    gpa: std.mem.Allocator,
    a: Mesh,
    b: Mesh,

    fn run(self: *Boolean) usize {
        const m = boolean.apply(self.gpa, self.a, self.b, .subtract) catch return 0;
        defer m.deinit(self.gpa);
        return m.faces.len;
    }
};
