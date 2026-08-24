const std = @import("std");
const vertex = @import("vertex");

const protocol = vertex.protocol;
const layout = vertex.layout;
const sample_count = 21;

const Stats = struct {
    min_ns: u64,
    median_ns: u64,
};

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    inline for ([_]u32{ 1_000, 100_000, 1_000_000 }) |n| {
        try benchmarkSize(gpa, io, n);
    }
}

fn benchmarkSize(gpa: std.mem.Allocator, io: std.Io, n: u32) !void {
    const positions = try layout.Positions.alloc(gpa, n);
    defer positions.free(gpa);
    fillGrid(positions);

    const face_count = @as(usize, n) * 2;
    const faces = try gpa.alloc([3]u32, face_count);
    defer gpa.free(faces);
    fillFaces(n, faces);

    var encoded: protocol.Encoded = undefined;
    protocol.encodeMesh(&encoded, "grid", .d3, positions.toConst(), faces);
    const frame_storage = try gpa.alignedAlloc(u8, .@"16", encoded.totalLen());
    defer gpa.free(frame_storage);
    const payload_storage = try gpa.alignedAlloc(u8, .@"16", encoded.header.len);
    defer gpa.free(payload_storage);

    const frame = encoded.writeTo(frame_storage);
    @memcpy(payload_storage, frame[@sizeOf(protocol.Header)..]);
    const header = try protocol.decodeHeader(frame);
    _ = try protocol.decodeInline(header, payload_storage);

    const encode_iterations: u32 = switch (n) {
        1_000 => 200,
        100_000 => 8,
        else => 2,
    };
    const decode_iterations: u32 = switch (n) {
        1_000 => 20_000,
        100_000 => 10_000,
        else => 5_000,
    };

    const encode_stats = try measureEncode(
        io,
        &encoded,
        frame_storage,
        positions.toConst(),
        faces,
        encode_iterations,
    );
    const decode_stats = try measureDecode(io, frame, payload_storage, decode_iterations);
    report("encode", n, encoded.totalLen(), encode_stats);
    report("decode", n, null, decode_stats);
}

fn fillGrid(positions: layout.Positions.Mut) void {
    for (0..positions.len()) |i| {
        const index: u32 = @intCast(i);
        const column = index % 1_000;
        const row = index / 1_000;
        positions.set(index, .init(
            @floatFromInt(column),
            @floatFromInt(row),
            @as(f32, @floatFromInt((column + row) % 29)) * 0.03125,
        ));
    }
}

fn fillFaces(vertex_count: u32, faces: [][3]u32) void {
    var prng = std.Random.DefaultPrng.init(0x91_72_b4_c3 ^ vertex_count);
    const random = prng.random();
    for (faces) |*face| {
        face.* = .{
            random.uintLessThan(u32, vertex_count),
            random.uintLessThan(u32, vertex_count),
            random.uintLessThan(u32, vertex_count),
        };
    }
}

fn measureEncode(
    io: std.Io,
    encoded: *protocol.Encoded,
    frame_storage: []align(protocol.section_alignment) u8,
    positions: layout.Positions.Const,
    faces: []const [3]u32,
    iterations: u32,
) !Stats {
    for (0..3) |_| {
        protocol.encodeMesh(encoded, "grid", .d3, positions, faces);
        const frame = encoded.writeTo(frame_storage);
        std.mem.doNotOptimizeAway(frame.ptr);
    }

    var samples: [sample_count]u64 = undefined;
    for (&samples) |*sample| {
        const t0 = std.Io.Clock.awake.now(io);
        for (0..iterations) |_| {
            protocol.encodeMesh(encoded, "grid", .d3, positions, faces);
            const frame = encoded.writeTo(frame_storage);
            std.mem.doNotOptimizeAway(frame.ptr);
            std.mem.doNotOptimizeAway(frame[frame.len - 1]);
        }
        const elapsed: i96 = t0.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
        sample.* = @intCast(@divTrunc(elapsed, iterations));
    }
    return summarize(&samples);
}

fn measureDecode(
    io: std.Io,
    frame: []const u8,
    payload: []align(protocol.payload_alignment) const u8,
    iterations: u32,
) !Stats {
    for (0..3) |_| {
        const header = try protocol.decodeHeader(frame);
        const message = try protocol.decodeInline(header, payload);
        std.mem.doNotOptimizeAway(message.mesh.positions.bytes().ptr);
    }

    var samples: [sample_count]u64 = undefined;
    for (&samples) |*sample| {
        const t0 = std.Io.Clock.awake.now(io);
        for (0..iterations) |_| {
            const header = try protocol.decodeHeader(frame);
            const message = try protocol.decodeInline(header, payload);
            std.mem.doNotOptimizeAway(message.mesh.positions.bytes().ptr);
            std.mem.doNotOptimizeAway(message.mesh.faces.ptr);
        }
        const elapsed: i96 = t0.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
        sample.* = @intCast(@divTrunc(elapsed, iterations));
    }
    return summarize(&samples);
}

fn summarize(samples: *[sample_count]u64) Stats {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return .{
        .min_ns = samples[0],
        .median_ns = samples[samples.len / 2],
    };
}

/// `byte_count` null: the operation is O(1) (decode is a zero-copy view), so
/// throughput in bytes would be meaningless; report time only.
fn report(op: []const u8, n: u32, byte_count: ?usize, stats: Stats) void {
    if (byte_count) |bytes| {
        const gb_per_second = @as(f64, @floatFromInt(bytes)) /
            @as(f64, @floatFromInt(@max(stats.min_ns, 1)));
        std.debug.print(
            "protocol/{s} layout={s} n={d} min={d} med={d} {d:.3}GB/s\n",
            .{ op, @tagName(layout.layout), n, stats.min_ns, stats.median_ns, gb_per_second },
        );
    } else {
        std.debug.print(
            "protocol/{s} layout={s} n={d} min={d} med={d} (O(1) view)\n",
            .{ op, @tagName(layout.layout), n, stats.min_ns, stats.median_ns },
        );
    }
}
