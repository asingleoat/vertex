//! Geometry kernel benchmark over all supported layouts and grid sizes.
const std = @import("std");
const vertex = @import("vertex");
const harness = @import("lib/harness.zig");

const Vec3 = vertex.Vec3;
const all_layouts = [_]vertex.layout.Layout{ .aos3, .aos4, .soa };

/// Runs every geometry kernel over roughly 1K, 100K, and 1M vertices.
pub fn main() !void {
    var io_state: harness.Io = .{};
    const io = io_state.get();
    inline for (all_layouts) |l| {
        try benchLayout(l, io);
    }
}

fn benchLayout(comptime l: vertex.layout.Layout, io: std.Io) !void {
    const grids = [_][2]u32{
        .{ 31, 31 },
        .{ 315, 315 },
        .{ 999, 999 },
    };
    for (grids) |grid| try benchGrid(l, io, grid[0], grid[1]);
}

fn benchGrid(comptime l: vertex.layout.Layout, io: std.Io, nx: u32, ny: u32) !void {
    const F = vertex.fixtures.Fixtures(l);
    const gpa = std.heap.page_allocator;
    var mesh = try F.grid(gpa, nx, ny, 10);
    defer mesh.deinit(gpa);

    const face_normals = try gpa.alloc(Vec3, mesh.faces.len);
    defer gpa.free(face_normals);
    const vertex_normals = try gpa.alloc(Vec3, mesh.positions.len());
    defer gpa.free(vertex_normals);
    var edges: std.ArrayList([2]u32) = .empty;
    defer edges.deinit(gpa);
    try edges.ensureTotalCapacity(gpa, mesh.faces.len * 3);

    const vertex_count: u64 = mesh.positions.len();
    const face_count: u64 = mesh.faces.len;
    const iters = iterationCount(vertex_count);
    const layout_tag = @tagName(l);

    var bounds_context: BoundsContext(l) = .{ .positions = mesh.positions.toConst() };
    harness.bench(
        io,
        "geometry/bounds",
        layout_tag,
        vertex_count,
        iters,
        .{ .elements = vertex_count, .unit = "verts/s" },
        &bounds_context,
        BoundsContext(l).run,
    );

    var face_context: FaceNormalsContext(l) = .{
        .positions = mesh.positions.toConst(),
        .faces = mesh.faces,
        .out = face_normals,
    };
    harness.bench(
        io,
        "geometry/faceNormals",
        layout_tag,
        vertex_count,
        iters,
        .{ .elements = face_count, .unit = "faces/s" },
        &face_context,
        FaceNormalsContext(l).run,
    );

    var vertex_context: VertexNormalsContext(l) = .{
        .positions = mesh.positions.toConst(),
        .faces = mesh.faces,
        .out = vertex_normals,
    };
    harness.bench(
        io,
        "geometry/vertexNormals",
        layout_tag,
        vertex_count,
        iters,
        .{ .elements = vertex_count, .unit = "verts/s" },
        &vertex_context,
        VertexNormalsContext(l).run,
    );

    var edges_context: UniqueEdgesContext(l) = .{
        .gpa = gpa,
        .faces = mesh.faces,
        .out = &edges,
    };
    harness.bench(
        io,
        "geometry/uniqueEdges",
        layout_tag,
        vertex_count,
        iters,
        .{ .elements = face_count, .unit = "faces/s" },
        &edges_context,
        UniqueEdgesContext(l).run,
    );
}

fn iterationCount(vertex_count: u64) usize {
    if (vertex_count <= 2_000) return 20;
    if (vertex_count <= 200_000) return 4;
    return 1;
}

fn BoundsContext(comptime l: vertex.layout.Layout) type {
    const G = vertex.geometry.Geometry(l);
    return struct {
        positions: G.P.Const,

        fn run(self: *@This()) u32 {
            return @bitCast(G.bounds(self.positions).min.x);
        }
    };
}

fn FaceNormalsContext(comptime l: vertex.layout.Layout) type {
    const G = vertex.geometry.Geometry(l);
    return struct {
        positions: G.P.Const,
        faces: []const [3]u32,
        out: []Vec3,

        fn run(self: *@This()) u32 {
            G.faceNormals(self.positions, self.faces, self.out);
            return @bitCast(self.out[0].z);
        }
    };
}

fn VertexNormalsContext(comptime l: vertex.layout.Layout) type {
    const G = vertex.geometry.Geometry(l);
    return struct {
        positions: G.P.Const,
        faces: []const [3]u32,
        out: []Vec3,

        fn run(self: *@This()) u32 {
            G.vertexNormals(self.positions, self.faces, self.out);
            return @bitCast(self.out[0].z);
        }
    };
}

fn UniqueEdgesContext(comptime l: vertex.layout.Layout) type {
    const G = vertex.geometry.Geometry(l);
    return struct {
        gpa: std.mem.Allocator,
        faces: []const [3]u32,
        out: *std.ArrayList([2]u32),

        fn run(self: *@This()) usize {
            G.uniqueEdges(self.gpa, self.faces, self.out) catch unreachable;
            return self.out.items.len;
        }
    };
}
