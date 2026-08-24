const std = @import("std");
const vertex = @import("vertex");

/// Streams animated mesh scalars/vectors plus static points and lines. Every
/// allocation uses `init.gpa`, is reused across steps, and is freed on return.
pub fn main(init: std.process.Init) !void {
    var conn = try vertex.connect(init, .{ .name = "current" });
    defer conn.close();

    var sphere = try vertex.fixtures.current.icosphere(init.gpa, 3, 1.0);
    defer sphere.deinit(init.gpa);
    const displaced = try vertex.layout.Positions.alloc(init.gpa, sphere.positions.len());
    defer displaced.free(init.gpa);
    const height = try init.gpa.alloc(f32, sphere.positions.len());
    defer init.gpa.free(height);
    const face_area = try init.gpa.alloc(f32, sphere.faces.len);
    defer init.gpa.free(face_area);
    const normal_values = try init.gpa.alloc(vertex.layout.Vec3, sphere.positions.len());
    defer init.gpa.free(normal_values);
    const normals = try vertex.layout.Positions.alloc(init.gpa, sphere.positions.len());
    defer normals.free(init.gpa);

    var vertex_index: u32 = 0;
    while (vertex_index < sphere.positions.len()) : (vertex_index += 1) {
        height[vertex_index] = sphere.positions.z(vertex_index);
    }
    vertex.geometry.current.vertexNormals(sphere.positions.toConst(), sphere.faces, normal_values);
    normals.setAll(normal_values);
    faceAreas(sphere.positions.toConst(), sphere.faces, face_area);
    try conn.mesh("sphere", sphere.positions.toConst(), sphere.faces, .{});
    try conn.scalar("sphere", "height", .vertex, height);
    try conn.scalar("sphere", "face_area", .face, face_area);
    try conn.vector("sphere", "normal", .vertex, normals.toConst());

    const sites = try vertex.fixtures.current.randomPoints(init.gpa, 200, 0x5eed, 1.35);
    defer sites.free(init.gpa);
    const site_distance = try init.gpa.alloc(f32, sites.len());
    defer init.gpa.free(site_distance);
    vertex_index = 0;
    while (vertex_index < sites.len()) : (vertex_index += 1) {
        site_distance[vertex_index] = sites.get(vertex_index).length();
    }
    try conn.points("sites", sites.toConst(), .{});
    try conn.scalar("sites", "dist", .point, site_distance);

    const path_vertex_count: u32 = 65;
    const path = try vertex.layout.Positions.alloc(init.gpa, path_vertex_count);
    defer path.free(init.gpa);
    const path_segments = try init.gpa.alloc([2]u32, path_vertex_count - 1);
    defer init.gpa.free(path_segments);
    vertex_index = 0;
    while (vertex_index < path_vertex_count) : (vertex_index += 1) {
        const t = @as(f32, @floatFromInt(vertex_index)) /
            @as(f32, @floatFromInt(path_vertex_count - 1));
        const angle = t * 6.0 * std.math.pi;
        path.set(vertex_index, .init(0.72 * @cos(angle), 0.72 * @sin(angle), 2.4 * t - 1.2));
        if (vertex_index + 1 < path_vertex_count) {
            path_segments[vertex_index] = .{ vertex_index, vertex_index + 1 };
        }
    }
    try conn.lines("path", path.toConst(), path_segments, .{});

    // A compact orientation frame keeps the smoke scene at the documented
    // four structures and makes 3D camera motion immediately legible.
    const axes = try vertex.layout.Positions.alloc(init.gpa, 4);
    defer axes.free(init.gpa);
    axes.setAll(&.{
        .zero,
        .init(1.5, 0, 0),
        .init(0, 1.5, 0),
        .init(0, 0, 1.5),
    });
    const axis_segments = [_][2]u32{ .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 } };
    try conn.lines("axes", axes.toConst(), &axis_segments, .{});

    for (0..24) |step_index| {
        const t: f32 = @as(f32, @floatFromInt(step_index)) * (2.0 * std.math.pi / 24.0);
        vertex_index = 0;
        while (vertex_index < sphere.positions.len()) : (vertex_index += 1) {
            const base = sphere.positions.get(vertex_index);
            const theta = std.math.atan2(base.y, base.x);
            const radius = 1.0 + 0.15 * @sin(4.0 * theta + t);
            displaced.set(vertex_index, base.normalize().scale(radius));
        }
        vertex.geometry.current.vertexNormals(displaced.toConst(), sphere.faces, normal_values);
        normals.setAll(normal_values);
        faceAreas(displaced.toConst(), sphere.faces, face_area);
        try conn.meshPositions("sphere", displaced.toConst());
        try conn.scalar("sphere", "face_area", .face, face_area);
        try conn.vector("sphere", "normal", .vertex, normals.toConst());
        try conn.step();
    }

    try conn.log(.info, "done");
    try conn.finish();
}

fn faceAreas(
    positions: vertex.layout.Positions.Const,
    faces: []const [3]u32,
    areas: []f32,
) void {
    std.debug.assert(faces.len == areas.len);
    for (faces, areas) |face, *area| {
        const a = positions.get(face[0]);
        const b = positions.get(face[1]);
        const c = positions.get(face[2]);
        area.* = 0.5 * b.sub(a).cross(c.sub(a)).length();
    }
}
