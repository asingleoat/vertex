//! Benchmark timing and reporting shared by `bench/*.zig`.
//!
//! The figure a run reports is the minimum time one call took, and it is chosen
//! to be compared against a previous run rather than admired on its own: a
//! ratchet needs a number whose movement means a change in the code and not a
//! change in the weather. Two things make that possible here.
//!
//! Each sample repeats the operation enough times to be worth timing. A clock
//! reading has a granularity, and an operation that runs in nanoseconds cannot
//! be measured against it at all; repeating until a sample lasts a fifth of a
//! millisecond puts every measurement far enough above the tick that the tick
//! stops mattering. The reported time is the sample divided by the repeat
//! count.
//!
//! The number of samples is then chosen from what one call costs, so that a
//! cheap operation is sampled many times and an expensive one is not sampled
//! until the run takes minutes. The minimum over those samples is what is
//! reported: it is the sample least disturbed by everything else on the
//! machine, and unlike a mean or a median it does not drift with load.
//!
//! Times are reported in picoseconds. The unit is not a claim about the clock,
//! which is nowhere near that fine; it is so that dividing a sample by its
//! repeat count does not throw away a tenth of the value of an operation that
//! runs in single-digit nanoseconds.
//! Measured over four runs of the whole suite on an idle machine, the spread
//! between the fastest and slowest reading of the same measurement is 3.6 per
//! cent at the median and 7.5 per cent at the ninetieth percentile. Two
//! benchmarks sit well outside that and should not be gated on until they are
//! understood: `protocol/encode` moves by a quarter at every size, and
//! `planar/boolean crossings in one band` by a fifth at its largest, where it
//! runs for two thirds of a second and so gets the minimum five samples.
//!
//! The drift is per-benchmark rather than machine-wide: the median ratio
//! between whole runs is between 0.9995 and 1.0073, so normalising a run
//! against itself buys nothing.

const std = @import("std");

/// Owns the single-threaded std.Io implementation used by benchmark clocks.
pub const Io = struct {
    threaded: std.Io.Threaded = .init_single_threaded,

    /// Returns an I/O interface borrowing this state; no allocation is
    /// performed.
    ///
    /// O(1).
    pub fn get(self: *Io) std.Io {
        return self.threaded.io();
    }
};

/// Describes the operation count and label used for throughput reporting.
pub const Throughput = struct {
    elements: u64,
    unit: []const u8,
};

/// How long one sample should last. Well above any clock granularity, and short
/// enough that a cheap operation still gets many samples.
const target_sample_ns: u64 = 200_000;

/// Roughly how long one benchmark may take in total. An operation slower than
/// this gets the minimum number of samples rather than overrunning it.
const budget_ns: u64 = 50 * std.time.ns_per_ms;

const min_samples = 5;
const max_samples = 32;

/// Times `operation` and prints one measurement line.
///
/// `n` is the size of the input and `throughput` says what to divide by to get
/// a rate. Neither affects the timing; both are reported so that a reader can
/// compare sizes without doing arithmetic.
///
/// The repeat count and the number of samples are worked out from what one call
/// costs, so a caller states what it is measuring and not how hard to measure
/// it. Allocates nothing: the samples live in a fixed stack buffer.
pub fn bench(
    io: std.Io,
    name: []const u8,
    layout_tag: []const u8,
    n: u64,
    throughput: Throughput,
    context: anytype,
    comptime operation: anytype,
) void {
    // Warm up, and take the fastest of those as the estimate the rest is sized
    // from. The fastest rather than the last because the first call or two pay
    // for cold caches and a cold branch predictor, and sizing from those would
    // repeat too few times to lift the sample clear of the clock.
    var estimate: u64 = std.math.maxInt(u64);
    for (0..3) |_| {
        const start = std.Io.Clock.awake.now(io);
        std.mem.doNotOptimizeAway(operation(context));
        const elapsed: i96 = start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
        estimate = @min(estimate, @as(u64, @intCast(@max(elapsed, 1))));
    }

    const repeat: u64 = @max(1, target_sample_ns / estimate);
    const per_sample = repeat * estimate;
    const samples: usize = @intCast(std.math.clamp(
        budget_ns / @max(per_sample, 1),
        min_samples,
        max_samples,
    ));

    // Kept in picoseconds. An operation of a few nanoseconds divided by its
    // repeat count loses a tenth of its value to integer truncation if the
    // division is done in nanoseconds, which shows up as a benchmark that
    // wanders by ten per cent while doing exactly the same work.
    var storage: [max_samples]u64 = undefined;
    for (storage[0..samples]) |*sample| {
        const start = std.Io.Clock.awake.now(io);
        for (0..repeat) |_| std.mem.doNotOptimizeAway(operation(context));
        const elapsed: i96 = start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
        sample.* = @as(u64, @intCast(elapsed)) * 1000 / repeat;
    }

    var picoseconds = storage[0];
    for (storage[1..samples]) |sample| picoseconds = @min(picoseconds, sample);
    const rate = if (picoseconds == 0)
        std.math.maxInt(u64)
    else
        throughput.elements * std.time.ns_per_s * 1000 / picoseconds;

    std.debug.print(
        "{s} layout={s} n={d} ps={d} repeat={d} samples={d} {s}={d}\n",
        .{ name, layout_tag, n, picoseconds, repeat, samples, throughput.unit, rate },
    );
}
