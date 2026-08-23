//! Unix-domain socket listener and the viewer's single thread boundary.
const std = @import("std");
const vertex = @import("vertex");

const protocol = vertex.protocol;

const InboxItem = struct {
    header: protocol.Header,
    payload: []align(protocol.section_alignment) u8,
};

/// Mutex-protected double buffer shared only by the socket producer and render
/// consumer. List storage is owned by the inbox; drained payloads are owned by
/// the caller until `consume` is called.
pub const Inbox = struct {
    /// One complete wire frame. `payload` is owned by the inbox consumer and
    /// was allocated with the allocator passed to `Server.init`.
    pub const Item = InboxItem;

    mutex: std.Io.Mutex = .init,
    front: std.ArrayList(Item) = .empty,
    back: std.ArrayList(Item) = .empty,

    /// Appends one owned item to the producer buffer. On success ownership of
    /// `item.payload` transfers to the inbox; only list growth allocates.
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

    /// Marks the current drained list consumed without freeing its payloads.
    /// The caller must free every payload first; this operation never allocates.
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
pub const StartError = std.Io.net.UnixAddress.InitError ||
    std.Io.net.UnixAddress.ListenError ||
    std.Io.Dir.DeleteFileError ||
    std.Thread.SpawnError;

/// Owns the listener thread, socket path, and inbox. The caller must keep the
/// value at a stable address from `start` through `stop`.
pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    inbox: Inbox = .{},
    connected: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    path_storage: [std.Io.net.UnixAddress.max_len]u8 = undefined,
    path_len: usize = 0,
    listener: ?std.Io.net.Server = null,
    thread: ?std.Thread = null,
    stopped: bool = false,

    /// Initializes an unstarted server without allocating. `gpa` must be
    /// thread-safe and remain valid through `stop`.
    pub fn init(gpa: std.mem.Allocator, io: std.Io) Server {
        return .{ .gpa = gpa, .io = io };
    }

    /// Resolves the environment-selected socket, removes a stale entry, binds,
    /// and spawns the accept thread. The environment is borrowed for this call.
    pub fn start(self: *Server, environ: std.process.Environ) StartError!void {
        std.debug.assert(self.thread == null and self.listener == null);
        self.path_len = try resolvePath(environ, &self.path_storage);
        const path = self.socketPath();
        const address = try std.Io.net.UnixAddress.init(path);
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

    /// Stops and joins the listener, discards queued payloads, removes the
    /// socket file, and frees inbox storage. It is safe to call once after any
    /// `start` outcome and performs no long-held inbox lock.
    pub fn stop(self: *Server) void {
        if (self.stopped) return;
        self.stopped = true;
        self.stopping.store(true, .release);

        if (self.thread) |thread| {
            // Wake a thread blocked in accept. A short-lived local connection is
            // more reliable than closing a descriptor from another thread.
            if (std.Io.net.UnixAddress.init(self.socketPath())) |address| {
                if (address.connect(self.io)) |stream| stream.close(self.io) else |_| {}
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
        for (pending) |item| self.gpa.free(item.payload);
        self.inbox.consume();
        self.inbox.deinit(self.gpa);

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
        var reader = stream.reader(self.io, &read_buffer);

        while (!self.stopping.load(.acquire)) {
            var header_bytes: [@sizeOf(protocol.Header)]u8 = undefined;
            try reader.interface.readSliceAll(&header_bytes);
            const header = @as(*align(1) const protocol.Header, @ptrCast(&header_bytes)).*;
            // A corrupt header must not drive allocation size; 256 MiB is far
            // beyond any real payload (a 1M-vertex mesh is ~12 MB).
            if (header.len > 256 * 1024 * 1024) return error.PayloadTooLarge;
            const payload = try self.gpa.alignedAlloc(u8, .@"16", header.len);
            errdefer self.gpa.free(payload);
            try reader.interface.readSliceAll(payload);
            try self.inbox.push(self.gpa, self.io, .{ .header = header, .payload = payload });
        }
    }
};

fn threadMain(server: *Server) void {
    server.run();
}

fn resolvePath(environ: std.process.Environ, storage: *[std.Io.net.UnixAddress.max_len]u8) error{NameTooLong}!usize {
    if (std.process.Environ.getPosix(environ, "VERTEX_SOCK")) |path| {
        if (path.len != 0) {
            if (path.len > storage.len) return error.NameTooLong;
            @memcpy(storage[0..path.len], path);
            return path.len;
        }
    }
    if (std.process.Environ.getPosix(environ, "XDG_RUNTIME_DIR")) |runtime_dir| {
        if (runtime_dir.len != 0) {
            const suffix = "/vertex.sock";
            if (runtime_dir.len + suffix.len > storage.len) return error.NameTooLong;
            @memcpy(storage[0..runtime_dir.len], runtime_dir);
            @memcpy(storage[runtime_dir.len..][0..suffix.len], suffix);
            return runtime_dir.len + suffix.len;
        }
    }
    const fallback = "/tmp/vertex.sock";
    @memcpy(storage[0..fallback.len], fallback);
    return fallback.len;
}

fn deleteIfPresent(io: std.Io, path: []const u8) std.Io.Dir.DeleteFileError!void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

const testing = std.testing;
const empty_payload: [0]u8 align(protocol.section_alignment) = .{};

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
    var counting: vertex.testutil.CountingAllocator = .{ .child = testing.allocator };
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
