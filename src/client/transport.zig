//! Effectful client edge: the Unix-domain socket a sketch writes to, the
//! shared-memory buffers that can be passed through it, and the environment
//! lookups that locate the viewer. Every declaration here calls the operating
//! system. The message vocabulary it carries is pure and defined in
//! `session.zig`.
const std = @import("std");
const layout = @import("../geometry/layout.zig");
const platform = @import("../platform/platform.zig");
const protocol = @import("../protocol/protocol.zig");
const session = @import("session.zig");

const Sink = session.Sink;
const SendError = session.SendError;
const Error = session.Error;

/// Errors while creating a connection-owned shared buffer. On success the
/// connection owns both fd and mapping until a send consumes them or close.
pub const SharedError = platform.shm.Error || error{
    Finished,
    NotConnected,
    TooManyShared,
    InvalidSharedLength,
    SharedTooLarge,
};

/// Errors from resolving and opening the Unix-domain socket plus starting a
/// run. Connection setup allocates nothing and owns no error payload.
pub const ConnectError = platform.sockpath.Error || Error || std.Io.net.UnixAddress.InitError ||
    std.Io.net.UnixAddress.ConnectError;

/// One writable shared mapping owned by its connection until sent. `len` is
/// the requested logical byte count; `map` includes rounded trailing bytes and
/// `huge` records whether hugetlb pages were actually obtained.
pub const Shared = struct {
    fd: platform.Handle,
    map: []align(std.heap.page_size_min) u8,
    len: usize,
    huge: bool,
};

pub const max_outstanding_shared = 8;

const max_consumed_ranges = 8;

const ConsumedRange = struct {
    start: usize,
    len: usize,
};

pub const SharedTracker = struct {
    outstanding: [max_outstanding_shared]Shared = undefined,
    outstanding_len: u8 = 0,
    consumed: [max_consumed_ranges]ConsumedRange = undefined,
    consumed_len: u8 = 0,
    consumed_next: u8 = 0,
    huge_pages: bool = false,
    huge_regions: u64 = 0,

    pub fn create(self: *SharedTracker, len: usize) SharedError!Shared {
        if (len == 0) return error.InvalidSharedLength;
        if (self.outstanding_len == max_outstanding_shared) return error.TooManyShared;
        const region = try platform.shm.create(len, .{ .huge_pages = self.huge_pages });
        if (self.huge_pages and len >= platform.shm.huge_page_size and !region.huge and
            !platform.shm.hugePagesConfigured())
        {
            platform.shm.warnIfHugeUnavailable("shared buffer");
        }
        const shared: Shared = .{
            .fd = region.handle,
            .map = region.map,
            .len = len,
            .huge = region.huge,
        };
        self.outstanding[self.outstanding_len] = shared;
        self.outstanding_len += 1;
        self.huge_regions +|= @intFromBool(region.huge);
        return shared;
    }

    pub fn releaseAll(self: *SharedTracker) void {
        for (self.outstanding[0..self.outstanding_len]) |shared| {
            platform.shm.unmap(sharedRegion(shared));
            platform.shm.close(shared.fd);
        }
        self.outstanding_len = 0;
    }

    pub fn findOutstanding(self: *const SharedTracker, bytes: []const u8) ?u8 {
        if (bytes.len == 0) return null;
        const start = @intFromPtr(bytes.ptr);
        const end = std.math.add(usize, start, bytes.len) catch return null;
        for (self.outstanding[0..self.outstanding_len], 0..) |shared, i| {
            const shared_start = @intFromPtr(shared.map.ptr);
            const shared_end = shared_start + shared.len;
            if (start >= shared_start and end <= shared_end) return @intCast(i);
        }
        return null;
    }

    pub fn wasConsumed(self: *const SharedTracker, bytes: []const u8) bool {
        if (bytes.len == 0) return false;
        const start = @intFromPtr(bytes.ptr);
        const end = std.math.add(usize, start, bytes.len) catch return false;
        for (self.consumed[0..self.consumed_len]) |range| {
            if (start >= range.start and end <= range.start + range.len) return true;
        }
        return false;
    }

    pub fn consume(self: *SharedTracker, indices: []const u8) void {
        var selected: [max_outstanding_shared]bool = @splat(false);
        for (indices) |index| selected[index] = true;
        var write: usize = 0;
        for (self.outstanding[0..self.outstanding_len], 0..) |shared, i| {
            if (selected[i]) {
                self.rememberConsumed(shared);
                platform.shm.unmap(sharedRegion(shared));
                platform.shm.close(shared.fd);
            } else {
                self.outstanding[write] = shared;
                write += 1;
            }
        }
        self.outstanding_len = @intCast(write);
    }

    pub fn rememberConsumed(self: *SharedTracker, shared: Shared) void {
        const range: ConsumedRange = .{ .start = @intFromPtr(shared.map.ptr), .len = shared.len };
        if (self.consumed_len < max_consumed_ranges) {
            self.consumed[self.consumed_len] = range;
            self.consumed_len += 1;
            return;
        }
        self.consumed[self.consumed_next] = range;
        self.consumed_next = (self.consumed_next + 1) % max_consumed_ranges;
    }
};

fn sharedRegion(shared: Shared) platform.shm.Region {
    return .{ .handle = shared.fd, .map = shared.map, .huge = shared.huge };
}

/// An open Unix-domain socket sink. It owns the socket until `close`; message
/// encoding and vectored writes borrow caller data and allocate nothing.
pub const SocketSink = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    shared_tracker: ?*SharedTracker = null,
    closed: bool = false,

    /// Opens `path` as a Unix-domain stream. The returned sink owns the socket;
    /// `path` is borrowed for this call and no allocation occurs.
    pub fn connect(io: std.Io, path: []const u8) (platform.sockpath.Error || std.Io.net.UnixAddress.InitError || std.Io.net.UnixAddress.ConnectError)!SocketSink {
        // Paths longer than sockaddr_un allows are rebased on a directory
        // handle where the platform supports it (see platform.sockpath).
        var shortened: platform.sockpath.Shortened = .{};
        platform.sockpath.shorten(io, path, &shortened) catch |err| {
            std.log.err("vertex: socket path is {d} bytes; {s}: {s}", .{ path.len, platform.sockpath.limit_note, @errorName(err) });
            return err;
        };
        defer platform.sockpath.release(io, &shortened);
        const address = try std.Io.net.UnixAddress.init(shortened.path());
        return .{
            .io = io,
            .stream = try address.connect(io),
        };
    }

    /// Wraps an already-open stream. Ownership transfers to the returned sink;
    /// no allocation occurs.
    pub fn fromStream(io: std.Io, stream: std.Io.net.Stream) SocketSink {
        return .{ .io = io, .stream = stream };
    }

    /// Returns a sink borrowing `self`; it is invalid after `self` is moved or
    /// closed. Creating the interface allocates nothing.
    pub fn sink(self: *SocketSink) Sink {
        std.debug.assert(!self.closed);
        return .{ .context = self, .vtable = &socket_vtable };
    }

    /// Closes the owned socket once. It is safe to call repeatedly and allocates
    /// no memory.
    pub fn close(self: *SocketSink) void {
        if (self.closed) return;
        self.stream.close(self.io);
        self.closed = true;
    }

    fn send(self: *SocketSink, message: protocol.Message) SendError!void {
        std.debug.assert(!self.closed);
        var encoded: protocol.Encoded = undefined;
        var fds: [7]i32 = undefined;
        var fd_count: u8 = 0;
        var consumed: [protocol.max_sections]u8 = undefined;
        var consumed_count: u8 = 0;
        try self.encodeTracked(
            &encoded,
            message,
            &fds,
            &fd_count,
            &consumed,
            &consumed_count,
        );

        const source_parts = encoded.slices();
        var parts: [protocol.max_parts][]const u8 = undefined;
        @memcpy(parts[0..source_parts.len], source_parts);

        if (fd_count != 0) {
            const sent = try platform.fdpass.sendWithHandles(
                self.stream.socket.handle,
                parts[0..source_parts.len],
                fds[0..fd_count],
            );
            if (sent != encoded.totalLen()) return error.ShortWrite;
            self.shared_tracker.?.consume(consumed[0..consumed_count]);
            return;
        }

        var stream_writer = self.stream.writer(self.io, &.{});
        stream_writer.interface.writeVecAll(parts[0..source_parts.len]) catch {
            return stream_writer.err orelse error.Unexpected;
        };
    }

    fn encodeTracked(
        self: *SocketSink,
        out: *protocol.Encoded,
        message: protocol.Message,
        fds: *[7]i32,
        fd_count: *u8,
        consumed: *[protocol.max_sections]u8,
        consumed_count: *u8,
    ) SendError!void {
        switch (message) {
            .mesh => |value| {
                const positions = try self.classifySection(value.positions.bytes(), fds, fd_count, consumed, consumed_count);
                const faces = try self.classifySection(std.mem.sliceAsBytes(value.faces), fds, fd_count, consumed, consumed_count);
                protocol.encodeMeshSections(
                    out,
                    value.name,
                    value.dim,
                    value.positions.len(),
                    positions,
                    @intCast(value.faces.len),
                    faces,
                );
            },
            .mesh_positions => |value| {
                const positions = try self.classifySection(value.positions.bytes(), fds, fd_count, consumed, consumed_count);
                protocol.encodeMeshPositionsSection(out, value.name, value.positions.len(), positions);
            },
            .points => |value| {
                const positions = try self.classifySection(value.positions.bytes(), fds, fd_count, consumed, consumed_count);
                protocol.encodePointsSection(out, value.name, value.dim, value.positions.len(), positions);
            },
            .lines => |value| {
                const positions = try self.classifySection(value.positions.bytes(), fds, fd_count, consumed, consumed_count);
                const segments = try self.classifySection(std.mem.sliceAsBytes(value.segments), fds, fd_count, consumed, consumed_count);
                protocol.encodeLinesSections(
                    out,
                    value.name,
                    value.dim,
                    value.positions.len(),
                    positions,
                    @intCast(value.segments.len),
                    segments,
                );
            },
            .scalar_quantity => |value| {
                const values = try self.classifySection(std.mem.sliceAsBytes(value.values), fds, fd_count, consumed, consumed_count);
                protocol.encodeScalarQuantitySection(
                    out,
                    value.structure,
                    value.name,
                    value.target,
                    @intCast(value.values.len),
                    values,
                );
            },
            .vector_quantity => |value| {
                const vectors = try self.classifySection(value.vectors.bytes(), fds, fd_count, consumed, consumed_count);
                protocol.encodeVectorQuantitySection(
                    out,
                    value.structure,
                    value.name,
                    value.target,
                    value.vectors.len(),
                    vectors,
                );
            },
            else => session.encodeMessage(out, message),
        }
    }

    fn classifySection(
        self: *SocketSink,
        bytes: []const u8,
        fds: *[7]i32,
        fd_count: *u8,
        consumed: *[protocol.max_sections]u8,
        consumed_count: *u8,
    ) SendError!protocol.Section {
        const tracker = self.shared_tracker orelse return .{ .@"inline" = bytes };
        const outstanding_index = tracker.findOutstanding(bytes) orelse {
            if (tracker.wasConsumed(bytes)) return error.SharedConsumed;
            return .{ .@"inline" = bytes };
        };
        const shared = tracker.outstanding[outstanding_index];
        const offset = @intFromPtr(bytes.ptr) - @intFromPtr(shared.map.ptr);
        if (offset % layout.blob_alignment.toByteUnits() != 0) return error.MisalignedShared;
        std.debug.assert(fd_count.* < fds.len);
        const section_fd_index = fd_count.*;
        fds[section_fd_index] = shared.fd;
        fd_count.* += 1;
        for (consumed[0..consumed_count.*]) |existing| {
            if (existing == outstanding_index) break;
        } else {
            consumed[consumed_count.*] = outstanding_index;
            consumed_count.* += 1;
        }
        return .{ .external = .{
            .fd_index = section_fd_index,
            .offset = offset,
            .len = bytes.len,
        } };
    }
};

const socket_vtable: Sink.VTable = .{ .send = struct {
    fn send(context: ?*anyopaque, message: protocol.Message) SendError!void {
        const socket: *SocketSink = @ptrCast(@alignCast(context.?));
        return socket.send(message);
    }
}.send };

/// Resolves explicit, `VERTEX_SOCK`, runtime-dir, then `/tmp` precedence into
/// caller-owned storage. The returned slice borrows `storage` and no allocation occurs.
pub fn resolveSocketPath(
    environ: std.process.Environ,
    explicit_path: ?[]const u8,
    storage: *[std.Io.Dir.max_path_bytes]u8,
) error{NameTooLong}![]const u8 {
    // Length against sockaddr_un is enforced at connect time by
    // platform.sockpath, which can rebase long paths; only the storage
    // buffer bounds the path here.
    if (explicit_path) |path| {
        return copySocketPath(path, storage);
    }
    if (std.process.Environ.getPosix(environ, "VERTEX_SOCK")) |path| {
        if (path.len != 0) {
            return copySocketPath(path, storage);
        }
    }

    if (std.process.Environ.getPosix(environ, "XDG_RUNTIME_DIR")) |runtime_dir| {
        if (runtime_dir.len != 0) {
            const suffix = "/vertex.sock";
            if (runtime_dir.len + suffix.len > storage.len) return error.NameTooLong;
            @memcpy(storage[0..runtime_dir.len], runtime_dir);
            @memcpy(storage[runtime_dir.len..][0..suffix.len], suffix);
            return storage[0 .. runtime_dir.len + suffix.len];
        }
    }
    return copySocketPath("/tmp/vertex.sock", storage);
}

fn copySocketPath(path: []const u8, storage: *[std.Io.Dir.max_path_bytes]u8) error{NameTooLong}![]const u8 {
    if (path.len > storage.len) return error.NameTooLong;
    @memcpy(storage[0..path.len], path);
    return storage[0..path.len];
}

pub fn resolveHugePages(environ: std.process.Environ, explicit: ?bool) bool {
    // Not a preference anyone can hold on a platform with no huge-page class.
    if (!platform.shm.huge_supported) return false;
    if (explicit) |enabled| return enabled;
    // Default on: hugetlbfs is tried and silently falls back (with a one-time
    // notice) when the kernel has no huge pages configured.
    const value = std.process.Environ.getPosix(environ, "VERTEX_SHARED_HUGE") orelse return true;
    return !std.mem.eql(u8, value, "0");
}

pub fn noopSink() Sink {
    return .{ .context = null, .vtable = &noop_vtable };
}

const noop_vtable: Sink.VTable = .{ .send = struct {
    fn send(_: ?*anyopaque, _: protocol.Message) SendError!void {}
}.send };

const testing = std.testing;

test "socket sink semantic encoding produces one exact frame without allocation" {
    var expected: protocol.Encoded = undefined;
    protocol.encodeLog(&expected, .warn, "socket message");
    var expected_bytes: [128]u8 align(protocol.section_alignment) = undefined;
    const expected_frame = expected.writeTo(&expected_bytes);

    var actual: protocol.Encoded = undefined;
    session.encodeMessage(&actual, .{ .log = .{ .level = .warn, .text = "socket message" } });
    var actual_bytes: [128]u8 align(protocol.section_alignment) = undefined;
    const actual_frame = actual.writeTo(&actual_bytes);
    try testing.expectEqualSlices(u8, expected_frame, actual_frame);
}
