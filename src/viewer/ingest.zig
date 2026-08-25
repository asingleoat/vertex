//! Render-thread inbox draining and mapped-payload ownership cleanup.
const std = @import("std");
const vertex = @import("vertex");

const server_mod = @import("server.zig");
const Scene = vertex.internal.scene.Scene;

/// Owns ingest counters and mapping-cleanup capacity while borrowing the
/// process allocator, I/O implementation, inbox, and scene at stable addresses.
pub const Ingest = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    inbox: *server_mod.Inbox,
    scene: *Scene,
    messages: u64 = 0,
    bytes: u64 = 0,
    mapped_bytes: u64 = 0,
    apply_ns: u128 = 0,
    mapping_cleanup: std.ArrayList(vertex.internal.scene.Mapping) = .empty,
    frame0_complete: bool = false,
    began_run: bool = false,

    /// Creates an ingest edge without allocating. Every borrowed dependency
    /// must remain at a stable address until `deinit`.
    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        inbox: *server_mod.Inbox,
        scene: *Scene,
    ) Ingest {
        return .{ .gpa = gpa, .io = io, .inbox = inbox, .scene = scene };
    }

    /// Drains and applies every queued message. Payload and mapping ownership
    /// is consumed here; retained cleanup capacity remains owned by `self`.
    pub fn drain(self: *Ingest) bool {
        self.began_run = false;
        var saw_geometry = false;
        const items = self.inbox.drain(self.io);
        for (items) |item| {
            self.messages +|= 1;
            self.bytes +|= @intCast(item.payload.len);
            var registered: usize = 0;
            defer {
                self.scene.releaseUnreferencedMappings();
                self.drainReleasedMappings();
                disposeItemMappingsFrom(item, registered);
                self.gpa.free(item.payload);
            }
            const message: ?vertex.internal.protocol.Message = blk: {
                const started = std.Io.Clock.awake.now(self.io);
                defer {
                    const elapsed: i96 = started.durationTo(std.Io.Clock.awake.now(self.io)).toNanoseconds();
                    if (elapsed > 0) self.apply_ns +|= @intCast(elapsed);
                }
                self.mapping_cleanup.ensureTotalCapacity(
                    self.gpa,
                    self.scene.mappings.len + item.fd_count,
                ) catch |err| {
                    std.log.warn("discarding viewer message after mapping cleanup reserve failed: {s}", .{@errorName(err)});
                    break :blk null;
                };
                var mappings: [7][]align(64) const u8 = undefined;
                while (registered < item.fd_count) : (registered += 1) {
                    const mapping = item.mappings[registered] orelse {
                        std.log.warn("discarding viewer message with a missing fd mapping", .{});
                        break :blk null;
                    };
                    const mapping_index = self.scene.registerMapping(
                        @alignCast(mapping),
                        item.fds[registered],
                    ) catch |err| {
                        std.log.warn("discarding viewer message after mapping registration failed: {s}", .{@errorName(err)});
                        break :blk null;
                    };
                    mappings[registered] = self.scene.mappingBytes(mapping_index);
                }
                const decoded = vertex.internal.protocol.decode(
                    item.header,
                    item.payload,
                    mappings[0..registered],
                ) catch |err| {
                    std.log.warn("discarding invalid viewer message: {s}", .{@errorName(err)});
                    break :blk null;
                };
                self.mapped_bytes +|= decodedMappedBytes(decoded, item);
                switch (decoded) {
                    .begin_run => {
                        self.frame0_complete = false;
                        self.began_run = true;
                    },
                    .begin_frame => |begin| if (begin.index >= 1) {
                        self.frame0_complete = true;
                    },
                    .end_run => self.frame0_complete = true,
                    else => {},
                }
                self.scene.apply(decoded) catch |err| {
                    std.log.warn("discarding inapplicable viewer message: {s}", .{@errorName(err)});
                    break :blk null;
                };
                break :blk decoded;
            };
            if (message) |applied| {
                switch (applied) {
                    .mesh, .points, .lines => saw_geometry = true,
                    else => {},
                }
            }
        }
        self.inbox.consume();
        return saw_geometry;
    }

    /// Releases every scene-retained mapping and the cleanup list allocation.
    /// Call before deinitializing the borrowed scene.
    pub fn deinit(self: *Ingest) void {
        self.scene.takeAllMappings(&self.mapping_cleanup) catch unreachable;
        for (self.mapping_cleanup.items) |mapping| disposeMapping(mapping);
        self.mapping_cleanup.deinit(self.gpa);
        self.* = undefined;
    }

    fn drainReleasedMappings(self: *Ingest) void {
        while (self.scene.released_mappings.items.len != 0) {
            const mapping_index = self.scene.released_mappings.items[0];
            const mapping = self.scene.mappingValue(mapping_index);
            disposeMapping(mapping);
            self.scene.forgetMapping(mapping_index);
        }
    }
};

fn decodedMappedBytes(message: vertex.internal.protocol.Message, item: server_mod.Inbox.Item) u64 {
    var total: u64 = 0;
    switch (message) {
        .mesh => |value| {
            total +|= mappedSectionBytes(value.positions.bytes(), item);
            total +|= mappedSectionBytes(std.mem.sliceAsBytes(value.faces), item);
        },
        .mesh_positions => |value| total +|= mappedSectionBytes(value.positions.bytes(), item),
        .points => |value| total +|= mappedSectionBytes(value.positions.bytes(), item),
        .lines => |value| {
            total +|= mappedSectionBytes(value.positions.bytes(), item);
            total +|= mappedSectionBytes(std.mem.sliceAsBytes(value.segments), item);
        },
        .scalar_quantity => |value| total +|= mappedSectionBytes(std.mem.sliceAsBytes(value.values), item),
        .vector_quantity => |value| total +|= mappedSectionBytes(value.vectors.bytes(), item),
        else => {},
    }
    return total;
}

fn mappedSectionBytes(section: []const u8, item: server_mod.Inbox.Item) u64 {
    const section_start = @intFromPtr(section.ptr);
    const section_end = std.math.add(usize, section_start, section.len) catch return 0;
    for (item.mappings[0..item.fd_count]) |optional_mapping| {
        const mapping = optional_mapping orelse continue;
        const mapping_start = @intFromPtr(mapping.ptr);
        const mapping_end = mapping_start + mapping.len;
        if (section_start >= mapping_start and section_end <= mapping_end) return @intCast(section.len);
    }
    return 0;
}

fn disposeItemMappingsFrom(item: server_mod.Inbox.Item, start: usize) void {
    for (item.mappings[start..item.fd_count], item.fds[start..item.fd_count]) |mapping, fd| {
        if (mapping) |mapping_bytes| vertex.internal.platform.shm.unmap(.{
            .handle = fd,
            .map = mapping_bytes,
            .huge = false,
        });
        vertex.internal.platform.shm.close(fd);
    }
}

fn disposeMapping(mapping: vertex.internal.scene.Mapping) void {
    vertex.internal.platform.shm.unmap(.{
        .handle = mapping.fd,
        .map = @alignCast(@constCast(mapping.bytes)),
        .huge = false,
    });
    vertex.internal.platform.shm.close(mapping.fd);
}

const testing = std.testing;

fn pushEncoded(gpa: std.mem.Allocator, io: std.Io, inbox: *server_mod.Inbox, encoded: *vertex.internal.protocol.Encoded) !void {
    // Mirrors the socket server: exact-size, 16-aligned payload owned by the item.
    var frame: [4096]u8 align(vertex.internal.protocol.section_alignment) = undefined;
    const bytes = encoded.writeTo(&frame);
    const header = try vertex.internal.protocol.decodeHeader(bytes);
    const payload = try gpa.alignedAlloc(u8, .@"16", header.len);
    @memcpy(payload, bytes[@sizeOf(vertex.internal.protocol.Header)..][0..header.len]);
    try inbox.push(gpa, io, .{ .header = header, .payload = payload });
}

test "ingest drain allocates only the new blob per mesh_positions frame at steady state" {
    // The per-frame hot path: inbox drain -> decode -> scene apply -> mapping
    // cleanup. After warm-up, a frame of N position updates must allocate
    // exactly N blobs and nothing else (STYLE §2).
    var counting: vertex.internal.testutil.CountingAllocator = .{ .child = testing.allocator };
    const gpa = counting.allocator();
    var inbox: server_mod.Inbox = .{};
    defer inbox.deinit(gpa);
    var scene = Scene.init(gpa);
    defer scene.deinit();
    var ingest = Ingest.init(gpa, testing.io, &inbox, &scene);
    defer ingest.deinit();

    const layout = vertex.internal.layout;
    const elem_count = if (layout.layout == .soa) 9 else 3;
    var position_data: [elem_count]layout.Positions.Elem = undefined;
    const positions = layout.Positions.fromSlice(&position_data);
    positions.setAll(&.{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0) });
    const faces = [_][3]u32{.{ 0, 1, 2 }};

    var encoded: vertex.internal.protocol.Encoded = undefined;
    vertex.internal.protocol.encodeBeginRun(&encoded);
    try pushEncoded(gpa, testing.io, &inbox, &encoded);
    vertex.internal.protocol.encodeMesh(&encoded, "m", .d3, positions.toConst(), &faces);
    try pushEncoded(gpa, testing.io, &inbox, &encoded);
    try testing.expect(ingest.drain());

    // Warm up: two frames grow every list to its steady capacity.
    var frame_index: u32 = 1;
    while (frame_index <= 2) : (frame_index += 1) {
        vertex.internal.protocol.encodeBeginFrame(&encoded, frame_index, "");
        try pushEncoded(gpa, testing.io, &inbox, &encoded);
        vertex.internal.protocol.encodeMeshPositions(&encoded, "m", positions.toConst());
        try pushEncoded(gpa, testing.io, &inbox, &encoded);
        _ = ingest.drain();
    }
    // Retained versions keep growing the version list; make its capacity
    // ample so growth cannot be mistaken for a per-frame allocation.
    const updates: u32 = 8;
    var pre: [updates]void = undefined;
    _ = &pre;
    while (frame_index <= 2 + 64) : (frame_index += 1) {
        vertex.internal.protocol.encodeBeginFrame(&encoded, frame_index, "");
        try pushEncoded(gpa, testing.io, &inbox, &encoded);
        vertex.internal.protocol.encodeMeshPositions(&encoded, "m", positions.toConst());
        try pushEncoded(gpa, testing.io, &inbox, &encoded);
        _ = ingest.drain();
    }

    // Measured frame: `updates` position updates queued, then one drain.
    // Payload allocations happen in pushEncoded (the socket thread's job)
    // and are excluded by counting only inside drain.
    var k: u32 = 0;
    while (k < updates) : (k += 1) {
        vertex.internal.protocol.encodeBeginFrame(&encoded, frame_index + k, "");
        try pushEncoded(gpa, testing.io, &inbox, &encoded);
        vertex.internal.protocol.encodeMeshPositions(&encoded, "m", positions.toConst());
        try pushEncoded(gpa, testing.io, &inbox, &encoded);
    }
    const allocs_before = counting.alloc_calls;
    const resizes_before = counting.resize_calls + counting.remap_calls;
    _ = ingest.drain();
    try testing.expectEqual(@as(usize, updates), counting.alloc_calls - allocs_before);
    try testing.expectEqual(@as(usize, 0), counting.resize_calls + counting.remap_calls - resizes_before);
    try testing.expectEqual(@as(u64, 2 + 2 * 2 + 2 * 64 + 2 * updates), ingest.messages);
}
