//! Minimal benchmark timing and reporting shared by `bench/*.zig`.
const std = @import("std");

/// Owns the single-threaded std.Io implementation used by benchmark clocks.
pub const Io = struct {
    threaded: std.Io.Threaded = .init_single_threaded,

    /// Returns an I/O interface borrowing this state; no allocation is performed.
    pub fn get(self: *Io) std.Io {
        return self.threaded.io();
    }
};

/// Describes the operation count and label used for throughput reporting.
pub const Throughput = struct {
    elements: u64,
    unit: []const u8,
};

/// Warms `operation`, times each invocation, and prints min/median nanoseconds.
/// Timing samples use a fixed stack buffer, so this helper never allocates.
pub fn bench(
    io: std.Io,
    name: []const u8,
    layout_tag: []const u8,
    n: u64,
    iters: usize,
    throughput: Throughput,
    context: anytype,
    comptime operation: anytype,
) void {
    const max_samples = 64;
    std.debug.assert(iters > 0 and iters <= max_samples);

    for (0..2) |_| std.mem.doNotOptimizeAway(operation(context));

    var storage: [max_samples]u64 = undefined;
    const samples = storage[0..iters];
    for (samples) |*sample| {
        const start = std.Io.Clock.awake.now(io);
        const result = operation(context);
        const elapsed: i96 = start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
        std.mem.doNotOptimizeAway(result);
        sample.* = @intCast(elapsed);
    }

    var minimum = samples[0];
    for (samples[1..]) |sample| minimum = @min(minimum, sample);
    std.mem.sort(u64, samples, {}, comptime std.sort.asc(u64));
    const middle = samples.len / 2;
    const median = if (samples.len % 2 == 1)
        samples[middle]
    else
        samples[middle - 1] / 2 + samples[middle] / 2;
    const rate = if (median == 0)
        std.math.maxInt(u64)
    else
        throughput.elements * std.time.ns_per_s / median;

    std.debug.print(
        "{s} layout={s} n={d} min={d} med={d} {s}={d}\n",
        .{ name, layout_tag, n, minimum, median, throughput.unit, rate },
    );
}
