const std = @import("std");
const vertex = @import("vertex");

/// Streams a million-vertex topology once, then sends forty wave updates.
/// `VERTEX_STRESS_SHARED=1` fills a fresh consumed memfd mapping per update;
/// the default reuses the fixture allocation through the inline protocol path.
pub fn main(init: std.process.Init) !void {
    var conn = try vertex.connect(init, .{ .name = "stress" });
    defer conn.close();

    var grid = try vertex.shapes.grid(init.gpa, 1000, 1000, 2.0);
    defer grid.deinit(init.gpa);
    try conn.mesh("grid", grid.positions.toConst(), grid.faces, .{});
    const shared_mode = if (std.process.Environ.getPosix(init.minimal.environ, "VERTEX_STRESS_SHARED")) |value|
        std.mem.eql(u8, value, "1")
    else
        false;
    // Mirrors the connection's resolution: off where the platform has no
    // huge-page class, otherwise absent means on (with fallback).
    const huge_pages = vertex.internal.platform.shm.huge_supported and
        if (std.process.Environ.getPosix(init.minimal.environ, "VERTEX_SHARED_HUGE")) |value|
            !std.mem.eql(u8, value, "0")
        else
            true;

    const step_count: u32 = 40;
    var send_ns: i96 = 0;
    var prep_ns: i96 = 0; // buffer acquisition (memfd + populate in shared mode) + fill
    var step_index: u32 = 0;
    const minflt_start = vertex.internal.platform.stats.minorFaults();
    while (step_index < step_count) : (step_index += 1) {
        const phase = @as(f32, @floatFromInt(step_index)) * (2.0 * std.math.pi / @as(f32, @floatFromInt(step_count)));
        const prep_started = std.Io.Clock.awake.now(init.io);
        const update = if (shared_mode)
            try conn.sharedPositions(grid.positions.len())
        else
            grid.positions;
        var vertex_index: u32 = 0;
        while (vertex_index < grid.positions.len()) : (vertex_index += 1) {
            const base = grid.positions.get(vertex_index);
            update.set(
                vertex_index,
                .init(base.x, base.y, 0.12 * @sin(10.0 * base.x - phase) * @cos(4.0 * base.y)),
            );
        }

        const started = std.Io.Clock.awake.now(init.io);
        prep_ns += prep_started.durationTo(started).toNanoseconds();
        try conn.meshPositions("grid", update.toConst());
        send_ns += started.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds();
        try conn.step();
    }

    const sent_bytes = @as(u64, grid.positions.toConst().bytes().len) * step_count;
    const seconds = @as(f64, @floatFromInt(@max(send_ns, 1))) / 1_000_000_000.0;
    const mib = @as(f64, @floatFromInt(sent_bytes)) / (1024.0 * 1024.0);
    const minflt = vertex.internal.platform.stats.minorFaults() -| minflt_start;
    std.debug.print(
        "vertex-stress: mode={s} mesh_positions steps={d} prep_ms={d:.1} send_ms={d:.1} send_throughput={d:.1} MB/s minflt={d} hugetlb_kb={d} huge={s} huge_regions={d}\n",
        .{
            if (shared_mode) "shared" else "inline",
            step_count,
            @as(f64, @floatFromInt(prep_ns)) / 1_000_000.0,
            seconds * 1000.0,
            mib / seconds,
            minflt,
            vertex.internal.platform.stats.hugetlbKb(),
            if (huge_pages) "on" else "off",
            conn.sharedHugeRegions(),
        },
    );
    try conn.finish();
}
