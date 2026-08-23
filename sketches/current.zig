const std = @import("std");
const vertex = @import("vertex");

/// Streams an animated icosphere and a static point set to the viewer. Every
/// allocation uses `init.gpa` and is released before returning.
pub fn main(init: std.process.Init) !void {
    var conn = try vertex.connect(init, .{ .name = "current" });
    defer conn.close();

    var sphere = try vertex.fixtures.current.icosphere(init.gpa, 3, 1.0);
    defer sphere.deinit(init.gpa);
    const displaced = try vertex.layout.Positions.alloc(init.gpa, sphere.positions.len());
    defer displaced.free(init.gpa);
    const height = try init.gpa.alloc(f32, sphere.positions.len());
    defer init.gpa.free(height);

    var vertex_index: u32 = 0;
    while (vertex_index < sphere.positions.len()) : (vertex_index += 1) {
        height[vertex_index] = sphere.positions.z(vertex_index);
    }
    try conn.mesh("sphere", sphere.positions.toConst(), sphere.faces, .{});
    try conn.scalar("sphere", "height", .vertex, height);

    const sites = try vertex.fixtures.current.randomPoints(init.gpa, 200, 0x5eed, 1.35);
    defer sites.free(init.gpa);
    try conn.points("sites", sites.toConst(), .{});

    for (0..24) |step_index| {
        const t: f32 = @as(f32, @floatFromInt(step_index)) * (2.0 * std.math.pi / 24.0);
        vertex_index = 0;
        while (vertex_index < sphere.positions.len()) : (vertex_index += 1) {
            const base = sphere.positions.get(vertex_index);
            const theta = std.math.atan2(base.y, base.x);
            const radius = 1.0 + 0.15 * @sin(4.0 * theta + t);
            displaced.set(vertex_index, base.normalize().scale(radius));
        }
        try conn.meshPositions("sphere", displaced.toConst());
        try conn.step();
    }

    try conn.log(.info, "done");
    try conn.finish();
}
