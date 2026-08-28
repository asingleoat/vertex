//! Wire protocol encode and decode benchmark, over all three vertex layouts.
//!
//! Encoding copies the payload; decoding does not, being a view over bytes
//! already in memory, so the two are reported in different units and only the
//! first has a meaningful rate.
const std = @import("std");
const vertex = @import("vertex");
const harness = @import("lib/harness.zig");

const protocol = vertex.internal.protocol;
const layout = vertex.internal.layout;

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    var io_state: harness.Io = .{};
    const io = io_state.get();

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

    const tag = @tagName(layout.layout);
    var encode_context: Encode = .{
        .encoded = &encoded,
        .frame_storage = frame_storage,
        .positions = positions.toConst(),
        .faces = faces,
    };
    harness.bench(io, "protocol/encode", tag, n, .{ .elements = frame.len, .unit = "bytes/s" }, &encode_context, Encode.run);

    var decode_context: Decode = .{ .frame = frame, .payload = payload_storage };
    harness.bench(io, "protocol/decode", tag, n, .{ .elements = 1, .unit = "views/s" }, &decode_context, Decode.run);
}

const Encode = struct {
    encoded: *protocol.Encoded,
    frame_storage: []align(protocol.section_alignment) u8,
    positions: layout.Positions.Const,
    faces: []const [3]u32,

    fn run(self: *Encode) usize {
        protocol.encodeMesh(self.encoded, "grid", .d3, self.positions, self.faces);
        const frame = self.encoded.writeTo(self.frame_storage);
        std.mem.doNotOptimizeAway(frame[frame.len - 1]);
        return frame.len;
    }
};

const Decode = struct {
    frame: []const u8,
    payload: []align(protocol.payload_alignment) const u8,

    fn run(self: *Decode) usize {
        const header = protocol.decodeHeader(self.frame) catch return 0;
        const message = protocol.decodeInline(header, self.payload) catch return 0;
        std.mem.doNotOptimizeAway(message.mesh.positions.bytes().ptr);
        std.mem.doNotOptimizeAway(message.mesh.faces.ptr);
        return message.mesh.faces.len;
    }
};

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
