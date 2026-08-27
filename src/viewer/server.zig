//! The socket server: the only place another process reaches the viewer, and
//! the only thread boundary in the program.
//!
//! A listener thread accepts one connection at a time and reads frames from it,
//! decoding each header to know how much payload to wait for. Complete frames
//! are pushed onto an `Inbox`, which the render thread drains once per frame.
//! Nothing else crosses between the two threads, and the inbox owns what it
//! holds until the render thread takes it.
//!
//! Payloads arrive one of two ways. An ordinary frame is read into an aligned
//! allocation that the scene later copies out of. A frame that carries
//! descriptors instead has its shared regions mapped here, on this thread, and
//! the mapping is handed to the render thread to register with the scene, after
//! which blobs point into it directly. Which path a frame takes is a flag in
//! its header; see `protocol.Flags`.
const std = @import("std");
const vertex = @import("vertex");

const protocol = vertex.internal.protocol;
const platform = vertex.internal.platform;

const InboxItem = struct {
    header: protocol.Header,
    payload: []align(protocol.section_alignment) u8,
    fds: [7]i32 = @splat(-1),
    mappings: [7]?[]align(std.heap.page_size_min) u8 = @splat(null),
    fd_count: u8 = 0,
    huge_mapping_count: u8 = 0,
};

/// Mutex-protected double buffer shared only by the socket producer and render
/// consumer. List storage is owned by the inbox; drained payloads are owned by
/// the caller until `consume` is called.
pub const Inbox = struct {
    /// One complete wire frame. The consumer owns `payload` plus every fd and
    /// mapping prefix entry, and must unmap/close them after scene adoption.
    pub const Item = InboxItem;

    /// Parsed header plus one newly allocated 16-aligned payload buffer. The
    /// caller owns `payload` and must free it with the allocator passed below.
    pub const Payload = struct {
        header: protocol.Header,
        payload: []align(protocol.section_alignment) u8,
    };

    /// Header validation, payload cap, or allocation errors. Failures transfer
    /// no ownership and retain no borrowed header bytes.
    pub const PayloadError = protocol.DecodeError || std.mem.Allocator.Error || error{
        PayloadTooLarge,
        ExternalPayload,
    };

    /// Parses `header_bytes`, enforces `max_payload`, optionally rejects
    /// external sections, and allocates the caller-owned 16-aligned payload.
    ///
    /// The cap exists because the length is taken from the wire before any of
    /// the payload has arrived, so a header wrong about it would otherwise name
    /// an allocation of up to 4 GiB. A truncated stream, a client mid-rebuild
    /// and a protocol version mismatch all produce one. A caller that rejects a frame this
    /// way should pass the same bytes to `reportOversizePayload`, which says
    /// what was dropped and why.
    pub fn allocatePayload(
        gpa: std.mem.Allocator,
        header_bytes: []const u8,
        allow_external: bool,
        max_payload: usize,
    ) PayloadError!Payload {
        const header = try protocol.decodeHeader(header_bytes);
        if (header.len > max_payload) return error.PayloadTooLarge;
        if (!allow_external and protocol.Flags.fromInt(header.flags).external) return error.ExternalPayload;
        return .{
            .header = header,
            .payload = try gpa.alignedAlloc(u8, .@"16", header.len),
        };
    }

    /// Logs the frame `allocatePayload` refused for exceeding `max_payload`.
    ///
    /// It names the message kind, both sizes, and whether the frame carried its
    /// sections inline, which is the distinction that usually explains the
    /// size: an external frame holds only section references and stays small
    /// whatever the geometry, so an oversized inline frame means the sketch
    /// sent the bytes down the socket rather than through shared memory.
    ///
    /// Reporting is separate from `allocatePayload` because only the caller
    /// knows whether a rejected frame is worth a line: the socket path drops
    /// the connection over it, a test exercising the cap does not.
    /// `header_bytes` is whatever was handed to `allocatePayload`; a length
    /// that failed the cap decoded successfully to reach it.
    pub fn reportOversizePayload(header_bytes: []const u8, max_payload: usize) void {
        const header = protocol.decodeHeader(header_bytes) catch return;
        const kind: protocol.Kind = @fromBackingInt(@intCast(header.kind));
        const flags = protocol.Flags.fromInt(header.flags);
        std.log.err(
            "dropping the connection: a {s} message carries {d} bytes ({d:.1} MiB), " ++
                "over the {d} byte ({d:.1} MiB) limit. {s} " ++
                "The limit itself is VERTEX_MAX_PAYLOAD_MB=<megabytes>.",
            .{
                std.enums.tagName(protocol.Kind, kind) orelse "unrecognised",
                header.len,
                mebibytes(header.len),
                max_payload,
                mebibytes(max_payload),
                if (flags.external)
                    "Its sections are shared, so the length is a fault in the header rather than a large mesh."
                else
                    "Its sections are inline, which is what an ordinary allocation produces: a buffer from " ++
                        "Connection.sharedPositions, sharedScalars, sharedVectors or sharedBytes is sent by " ++
                        "reference and does not count against this limit.",
            },
        );
    }

    fn mebibytes(bytes: usize) f64 {
        return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
    }

    mutex: std.Io.Mutex = .init,
    front: std.ArrayList(Item) = .empty,
    back: std.ArrayList(Item) = .empty,

    /// Appends one owned item to the producer buffer. On success ownership of
    /// its payload, fds, and mappings transfers to the inbox; list growth is
    /// the only allocation.
    pub fn push(self: *Inbox, gpa: std.mem.Allocator, io: std.Io, item: Item) std.mem.Allocator.Error!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.back.ensureUnusedCapacity(gpa, 1);
        self.back.appendAssumeCapacity(item);
    }

    /// Swaps the producer and consumer lists while holding the mutex only for
    /// the swap. The returned slice borrows the inbox until the next `drain`.
    pub fn drain(self: *Inbox, io: std.Io) []Item {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.front.clearRetainingCapacity();
        std.mem.swap(std.ArrayList(Item), &self.front, &self.back);
        return self.front.items;
    }

    /// Marks the current drained list consumed without releasing item storage.
    /// The caller must free each payload and dispose every mapping/fd first.
    pub fn consume(self: *Inbox) void {
        self.front.clearRetainingCapacity();
    }

    /// Frees list backing storage but not payloads. Both lists must be empty.
    pub fn deinit(self: *Inbox, gpa: std.mem.Allocator) void {
        std.debug.assert(self.front.items.len == 0);
        std.debug.assert(self.back.items.len == 0);
        self.front.deinit(gpa);
        self.back.deinit(gpa);
        self.* = undefined;
    }
};

/// Errors which can occur while resolving, cleaning, binding, or spawning the
/// listener. No error owns memory.
pub const StartError = vertex.internal.platform.sockpath.Error || std.Io.net.UnixAddress.InitError ||
    std.Io.net.UnixAddress.ListenError ||
    std.Io.Dir.DeleteFileError ||
    std.Thread.SpawnError;

/// Owns the listener thread and socket path while borrowing a shared inbox.
/// The caller must keep both values at stable addresses from `start` to `stop`.
/// The default cap on one message payload, which `VERTEX_MAX_PAYLOAD_MB`
/// overrides. Large geometry travels through shared memory, where the payload
/// holds only section references, so a frame anywhere near this size is one
/// whose sections were sent inline.
pub const default_max_payload: usize = 256 * 1024 * 1024;

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    inbox: *Inbox,
    connected: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    path_storage: [std.Io.Dir.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    listener: ?std.Io.net.Server = null,
    thread: ?std.Thread = null,
    stopped: bool = false,
    huge_pages: bool,
    /// The largest message payload this viewer will allocate for. Set from
    /// `VERTEX_MAX_PAYLOAD_MB` at startup; see `Inbox.allocatePayload`.
    max_payload: usize = default_max_payload,
    first_ingest_minflt: ?u64 = null,
    received_huge_mappings: u64 = 0,

    /// Initializes an unstarted server without allocating. `gpa` must be
    /// thread-safe and remain valid through `stop`; `huge_pages` is retained as
    /// the mapping/reporting preference for every accepted connection.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, huge_pages: bool, inbox: *Inbox) Server {
        return .{ .gpa = gpa, .io = io, .huge_pages = huge_pages, .inbox = inbox };
    }

    /// Resolves the environment-selected socket, removes a stale entry, binds,
    /// and spawns the accept thread. The environment is borrowed for this call.
    pub fn start(self: *Server, environ: std.process.Environ) StartError!void {
        std.debug.assert(self.thread == null and self.listener == null);
        self.path_len = (try vertex.internal.transport.resolveSocketPath(environ, null, &self.path_storage)).len;
        const path = self.socketPath();
        var shortened: vertex.internal.platform.sockpath.Shortened = .{};
        vertex.internal.platform.sockpath.shorten(self.io, path, &shortened) catch |err| {
            std.log.err("viewer socket path is {d} bytes; {s}: {s}", .{ path.len, vertex.internal.platform.sockpath.limit_note, @errorName(err) });
            return err;
        };
        defer vertex.internal.platform.sockpath.release(self.io, &shortened);
        const address = try std.Io.net.UnixAddress.init(shortened.path());
        if (!address.isAbstract()) try deleteIfPresent(self.io, path);

        self.listener = try address.listen(self.io, .{});
        errdefer {
            self.listener.?.deinit(self.io);
            self.listener = null;
            if (!address.isAbstract()) deleteIfPresent(self.io, path) catch {};
        }
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    /// Returns the borrowed resolved socket path. It remains valid until the
    /// server value is destroyed and no allocation occurs.
    pub fn socketPath(self: *const Server) []const u8 {
        return self.path_storage[0..self.path_len];
    }

    /// Returns the minor-fault sample taken at the first successful recvmsg.
    /// Call after `stop` joins the server thread; sampling and access allocate
    /// nothing and the returned value owns no state.
    pub fn firstIngestMinorFaults(self: *const Server) ?u64 {
        return self.first_ingest_minflt;
    }

    /// Returns how many successfully mapped received handles were hugetlbfs
    /// regions. Call after `stop` joins the server thread; access allocates
    /// nothing and the returned counter owns no state.
    pub fn hugeMappingsReceived(self: *const Server) u64 {
        return self.received_huge_mappings;
    }

    /// Stops and joins the listener, discards queued payloads, removes the
    /// socket file, and discards queued payloads. The caller retains and later
    /// deinitializes the shared inbox. It is safe after any `start` outcome.
    pub fn stop(self: *Server) void {
        if (self.stopped) return;
        self.stopped = true;
        self.stopping.store(true, .release);

        if (self.thread) |thread| {
            // Wake a thread blocked in accept. A short-lived local connection is
            // more reliable than closing a descriptor from another thread.
            var shortened: vertex.internal.platform.sockpath.Shortened = .{};
            if (vertex.internal.platform.sockpath.shorten(self.io, self.socketPath(), &shortened)) {
                defer vertex.internal.platform.sockpath.release(self.io, &shortened);
                if (std.Io.net.UnixAddress.init(shortened.path())) |address| {
                    if (address.connect(self.io)) |stream| stream.close(self.io) else |_| {}
                } else |_| {}
            } else |_| {}
            thread.join();
            self.thread = null;
        }
        if (self.listener) |*listener| {
            listener.deinit(self.io);
            self.listener = null;
        }
        self.connected.store(false, .release);

        const pending = self.inbox.drain(self.io);
        for (pending) |item| disposeItem(self.gpa, item);
        self.inbox.consume();
        if (self.path_len != 0) deleteIfPresent(self.io, self.socketPath()) catch |err| {
            std.log.warn("could not unlink viewer socket '{s}': {s}", .{ self.socketPath(), @errorName(err) });
        };
    }

    fn run(self: *Server) void {
        while (!self.stopping.load(.acquire)) {
            const stream = self.listener.?.accept(self.io) catch |err| {
                if (!self.stopping.load(.acquire)) {
                    std.log.err("viewer socket accept failed: {s}", .{@errorName(err)});
                }
                return;
            };
            if (self.stopping.load(.acquire)) {
                stream.close(self.io);
                return;
            }

            self.connected.store(true, .release);
            self.serve(stream) catch |err| {
                if (!self.stopping.load(.acquire) and err != error.EndOfStream) {
                    std.log.warn("viewer client disconnected after read error: {s}", .{@errorName(err)});
                }
            };
            self.connected.store(false, .release);
        }
    }

    fn serve(self: *Server, stream: std.Io.net.Stream) !void {
        defer stream.close(self.io);
        var read_buffer: [64 * 1024]u8 = undefined;
        var header_bytes: [@sizeOf(protocol.Header)]u8 = undefined;
        var header_len: usize = 0;
        var header: ?protocol.Header = null;
        var payload: ?[]align(protocol.section_alignment) u8 = null;
        var payload_len: usize = 0;
        var fd_fifo: [28]i32 = undefined;
        var fd_len: usize = 0;
        defer {
            if (payload) |bytes| self.gpa.free(bytes);
            closeFds(fd_fifo[0..fd_len]);
        }

        while (!self.stopping.load(.acquire)) {
            var received_handles: [28]platform.Handle = undefined;
            const received = if (platform.fdpass.supported) try platform.fdpass.recvWithHandles(
                stream.socket.handle,
                &read_buffer,
                &received_handles,
            ) else read: {
                // Without handle passing a client cannot send a shared
                // section, so an ordinary readv sees the whole stream. Reading
                // through recvWithHandles here would return
                // `error.Unsupported`, which would disable ingest entirely,
                // including the inline path.
                var data: [1][]u8 = .{&read_buffer};
                break :read platform.fdpass.Received{
                    .bytes = try stream.read(self.io, &data),
                    .handle_count = 0,
                    .control_truncated = false,
                };
            };
            if (received.bytes == 0) return error.EndOfStream;
            if (self.first_ingest_minflt == null) self.first_ingest_minflt = platform.stats.minorFaults();
            if (fd_len + received.handle_count > fd_fifo.len) {
                closeFds(received_handles[0..received.handle_count]);
                return error.TooManyFds;
            }
            @memcpy(fd_fifo[fd_len..][0..received.handle_count], received_handles[0..received.handle_count]);
            fd_len += received.handle_count;
            if (received.control_truncated) return error.ControlTruncated;

            var cursor: usize = 0;
            while (cursor < received.bytes) {
                if (header == null) {
                    const copied = @min(header_bytes.len - header_len, received.bytes - cursor);
                    @memcpy(header_bytes[header_len..][0..copied], read_buffer[cursor..][0..copied]);
                    header_len += copied;
                    cursor += copied;
                    if (header_len != header_bytes.len) continue;

                    const allocated = Inbox.allocatePayload(
                        self.gpa,
                        &header_bytes,
                        true,
                        self.max_payload,
                    ) catch |err| {
                        if (err == error.PayloadTooLarge) {
                            Inbox.reportOversizePayload(&header_bytes, self.max_payload);
                        }
                        return err;
                    };
                    payload = allocated.payload;
                    header = allocated.header;
                    payload_len = 0;
                }

                const active_header = header.?;
                const active_payload = payload.?;
                const copied = @min(active_payload.len - payload_len, received.bytes - cursor);
                @memcpy(active_payload[payload_len..][0..copied], read_buffer[cursor..][0..copied]);
                payload_len += copied;
                cursor += copied;
                if (payload_len != active_payload.len) continue;

                const flags = protocol.Flags.fromInt(active_header.flags);
                if (flags.fd_count > fd_len) return error.MissingFds;
                const frame_fd_count: usize = flags.fd_count;
                var frame_fds: [7]i32 = undefined;
                @memcpy(frame_fds[0..frame_fd_count], fd_fifo[0..frame_fd_count]);
                std.mem.copyForwards(
                    i32,
                    fd_fifo[0 .. fd_len - frame_fd_count],
                    fd_fifo[frame_fd_count..fd_len],
                );
                fd_len -= frame_fd_count;

                const item = mapItem(self.huge_pages, active_header, active_payload, frame_fds[0..frame_fd_count]) catch |err| {
                    self.gpa.free(active_payload);
                    std.log.warn("dropping viewer frame after fd mapping error: {s}", .{@errorName(err)});
                    header = null;
                    payload = null;
                    header_len = 0;
                    payload_len = 0;
                    continue;
                };
                payload = null;
                self.received_huge_mappings +|= item.huge_mapping_count;
                self.inbox.push(self.gpa, self.io, item) catch |err| {
                    disposeItem(self.gpa, item);
                    return err;
                };
                header = null;
                header_len = 0;
                payload_len = 0;
            }
        }
    }
};

fn mapItem(
    huge_pages: bool,
    header: protocol.Header,
    payload: []align(protocol.section_alignment) u8,
    fds: []const i32,
) !Inbox.Item {
    var item: Inbox.Item = .{ .header = header, .payload = payload };
    item.fd_count = @intCast(fds.len);
    @memcpy(item.fds[0..fds.len], fds);
    errdefer {
        for (item.mappings[0..fds.len], fds) |mapping, fd| {
            if (mapping) |bytes| platform.shm.unmap(.{ .handle = fd, .map = bytes, .huge = false });
            platform.shm.close(fd);
        }
    }
    for (fds, 0..) |fd, i| {
        const region = try platform.shm.mapReadOnly(fd, .{ .huge_pages = huge_pages });
        item.mappings[i] = region.map;
        item.huge_mapping_count +|= @intFromBool(region.huge);
    }
    return item;
}

fn disposeItem(gpa: std.mem.Allocator, item: Inbox.Item) void {
    for (item.mappings[0..item.fd_count], item.fds[0..item.fd_count]) |mapping, fd| {
        if (mapping) |bytes| platform.shm.unmap(.{ .handle = fd, .map = bytes, .huge = false });
        platform.shm.close(fd);
    }
    gpa.free(item.payload);
}

fn closeFds(fds: []const platform.Handle) void {
    for (fds) |fd| platform.shm.close(fd);
}

fn threadMain(server: *Server) void {
    server.run();
}

fn deleteIfPresent(io: std.Io, path: []const u8) std.Io.Dir.DeleteFileError!void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

const testing = std.testing;
const empty_payload: [0]u8 align(protocol.section_alignment) = .{};

/// Encodes a header naming `len` payload bytes, for the cap tests below. A
/// header's wire form is its in-memory form, which `decodeHeader` reads back
/// through an unaligned pointer.
fn headerBytes(len: u32, kind: protocol.Kind) [@sizeOf(protocol.Header)]u8 {
    const header: protocol.Header = .{ .len = len, .kind = @backingInt(kind) };
    return std.mem.toBytes(header);
}

test "allocatePayload accepts a payload at the limit and rejects one over it" {
    const limit = 4096;
    const at = headerBytes(limit, .mesh);
    const allocated = try Inbox.allocatePayload(testing.allocator, &at, true, limit);
    defer testing.allocator.free(allocated.payload);
    try testing.expectEqual(@as(usize, limit), allocated.payload.len);

    const over = headerBytes(limit + 1, .mesh);
    try testing.expectError(
        error.PayloadTooLarge,
        Inbox.allocatePayload(testing.allocator, &over, true, limit),
    );
}

test "the payload limit is what the caller passes, not a fixed size" {
    // The same frame is accepted under one limit and refused under a smaller
    // one, which is the whole of what VERTEX_MAX_PAYLOAD_MB changes.
    const bytes = headerBytes(2048, .points);
    const allocated = try Inbox.allocatePayload(testing.allocator, &bytes, true, 4096);
    defer testing.allocator.free(allocated.payload);
    try testing.expectError(
        error.PayloadTooLarge,
        Inbox.allocatePayload(testing.allocator, &bytes, true, 1024),
    );
}

test "the default limit leaves the length field far more room than it allows" {
    // `Header.len` is a u32, so a header can name close to 4 GiB. The cap is
    // what stands between a length that is wrong and an allocation of that
    // size, which is why it exists at all.
    try testing.expect(default_max_payload < std.math.maxInt(u32));
}

test "Inbox receives items pushed by another thread" {
    const n = 256;
    var inbox: Inbox = .{};
    defer inbox.deinit(testing.allocator);
    var producer_failed = std.atomic.Value(bool).init(false);
    var producer_done = std.atomic.Value(bool).init(false);

    const Producer = struct {
        fn run(queue: *Inbox, failed: *std.atomic.Value(bool), done: *std.atomic.Value(bool)) void {
            defer done.store(true, .release);
            for (0..n) |i| {
                queue.push(testing.allocator, testing.io, .{
                    .header = .{ .len = @intCast(i), .kind = @backingInt(protocol.Kind.log) },
                    .payload = @constCast(empty_payload[0..]),
                }) catch {
                    failed.store(true, .release);
                    return;
                };
            }
        }
    };

    const thread = try std.Thread.spawn(.{}, Producer.run, .{ &inbox, &producer_failed, &producer_done });
    var received: usize = 0;
    while (received < n) {
        const items = inbox.drain(testing.io);
        received += items.len;
        inbox.consume();
        if (items.len == 0 and !producer_done.load(.acquire)) std.Thread.yield() catch {};
    }
    thread.join();
    _ = inbox.drain(testing.io);
    inbox.consume();
    try testing.expect(!producer_failed.load(.acquire));
    try testing.expectEqual(n, received);
}

test "Inbox drain allocates nothing after both lists are warm" {
    const n = 32;
    var counting: vertex.internal.testutil.CountingAllocator = .{ .child = testing.allocator };
    const gpa = counting.allocator();
    var inbox: Inbox = .{};
    defer inbox.deinit(gpa);
    const item: Inbox.Item = .{
        .header = .{ .len = 0, .kind = @backingInt(protocol.Kind.end_frame) },
        .payload = @constCast(empty_payload[0..]),
    };

    for (0..n) |_| try inbox.push(gpa, testing.io, item);
    _ = inbox.drain(testing.io);
    inbox.consume();
    _ = inbox.drain(testing.io);
    inbox.consume();
    for (0..n) |_| try inbox.push(gpa, testing.io, item);

    counting.alloc_calls = 0;
    counting.resize_calls = 0;
    counting.remap_calls = 0;
    try testing.expectEqual(n, inbox.drain(testing.io).len);
    try testing.expectEqual(0, counting.alloc_calls + counting.resize_calls + counting.remap_calls);
    inbox.consume();
}
