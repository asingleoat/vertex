//! GPU residency regression: many small versions, paced so the viewer draws
//! each one. Before the residency cap this exhausted sokol's buffer pool.
const std = @import("std");
const vertex = @import("vertex");

pub fn main(init: std.process.Init) !void {
    var conn = try vertex.connect(init, .{ .name = "churn" });
    defer conn.close();

    var grid = try vertex.fixtures.current.grid(init.gpa, 20, 20, 2.0);
    defer grid.deinit(init.gpa);
    const update = try vertex.layout.Positions.alloc(init.gpa, grid.positions.len());
    defer update.free(init.gpa);
    const values = try init.gpa.alloc(f32, grid.positions.len());
    defer init.gpa.free(values);

    try conn.mesh("grid", grid.positions.toConst(), grid.faces, .{});
    const steps: u32 = 400;
    var step: u32 = 0;
    while (step < steps) : (step += 1) {
        const phase = @as(f32, @floatFromInt(step)) * 0.05;
        var i: u32 = 0;
        while (i < grid.positions.len()) : (i += 1) {
            const base = grid.positions.get(i);
            const z = 0.1 * @sin(6.0 * base.x + phase);
            update.set(i, .init(base.x, base.y, z));
            values[i] = z;
        }
        try conn.meshPositions("grid", update.toConst());
        try conn.scalar("grid", "z", .vertex, values);
        try conn.step();
        // Pace so the viewer renders (and uploads) most versions.
        try std.Io.sleep(init.io, .{ .nanoseconds = 3 * std.time.ns_per_ms }, .awake);
    }
    try conn.finish();
}
