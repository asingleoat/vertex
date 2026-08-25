//! Synchronous client API and transport seam.
//!
//! `Session` sends semantic protocol messages through a borrowed `Sink`.
//! `Connection` is the convenient socket-owning variant returned by `connect`.
//! Calls borrow all slices only for their duration and allocate nothing.
const std = @import("std");
const builtin = @import("builtin");
const layout = @import("../geometry/layout.zig");
const platform = @import("../platform/platform.zig");
const protocol = @import("../protocol/protocol.zig");

/// Errors a sink may return while synchronously delivering one borrowed
/// message. No error owns memory and delivery allocates nothing in `SocketSink`.
pub const SendError = std.Io.net.Stream.Writer.Error || platform.fdpass.Error || error{
    ShortWrite,
    MisalignedShared,
    SharedConsumed,
};

/// Errors while creating a connection-owned shared buffer. On success the
/// connection owns both fd and mapping until a send consumes them or close.
pub const SharedError = platform.shm.Error || error{
    Finished,
    NotConnected,
    TooManyShared,
    InvalidSharedLength,
    SharedTooLarge,
};

/// Errors from client state validation or synchronous message delivery. No
/// error owns memory, and client operations allocate nothing.
pub const Error = SendError || error{
    Finished,
    FrameIndexOverflow,
    LabelTooLong,
    NameTooLong,
    TooManyElements,
    TextTooLong,
};

/// One writable shared mapping owned by its connection until sent. `len` is
/// the requested logical byte count; `map` includes rounded trailing bytes and
/// `huge` records whether hugetlb pages were actually obtained.
pub const Shared = struct {
    fd: platform.Handle,
    map: []align(std.heap.page_size_min) u8,
    len: usize,
    huge: bool,
};

const max_outstanding_shared = 8;
const max_consumed_ranges = 8;

const ConsumedRange = struct {
    start: usize,
    len: usize,
};

const SharedTracker = struct {
    outstanding: [max_outstanding_shared]Shared = undefined,
    outstanding_len: u8 = 0,
    consumed: [max_consumed_ranges]ConsumedRange = undefined,
    consumed_len: u8 = 0,
    consumed_next: u8 = 0,
    huge_pages: bool = false,
    huge_regions: u64 = 0,

    fn create(self: *SharedTracker, len: usize) SharedError!Shared {
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

    fn releaseAll(self: *SharedTracker) void {
        for (self.outstanding[0..self.outstanding_len]) |shared| {
            platform.shm.unmap(sharedRegion(shared));
            platform.shm.close(shared.fd);
        }
        self.outstanding_len = 0;
    }

    fn findOutstanding(self: *const SharedTracker, bytes: []const u8) ?u8 {
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

    fn wasConsumed(self: *const SharedTracker, bytes: []const u8) bool {
        if (bytes.len == 0) return false;
        const start = @intFromPtr(bytes.ptr);
        const end = std.math.add(usize, start, bytes.len) catch return false;
        for (self.consumed[0..self.consumed_len]) |range| {
            if (start >= range.start and end <= range.start + range.len) return true;
        }
        return false;
    }

    fn consume(self: *SharedTracker, indices: []const u8) void {
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

    fn rememberConsumed(self: *SharedTracker, shared: Shared) void {
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

/// Errors from resolving and opening the Unix-domain socket plus starting a
/// run. Connection setup allocates nothing and owns no error payload.
pub const ConnectError = platform.sockpath.Error || Error || std.Io.net.UnixAddress.InitError ||
    std.Io.net.UnixAddress.ConnectError;

/// Options for a new client run. All slices are borrowed only during
/// `connect`; no option is retained and connection setup allocates nothing.
pub const ConnectOptions = struct {
    name: []const u8,
    optional: bool = false,
    socket_path: ?[]const u8 = null,
    huge_pages: ?bool = null,
};

/// Dimension option shared by meshes, points, and lines. It owns no memory
/// and causes no allocation.
pub const GeometryOptions = struct {
    dim: protocol.Dim = .d3,
};

/// A borrowed, type-erased destination for semantic protocol messages.
/// The implementor owns `context`; `send` is synchronous and allocates nothing.
pub const Sink = struct {
    context: ?*anyopaque,
    vtable: *const VTable,

    /// Operations supplied by a sink implementor. The table owns no memory;
    /// `send` borrows the message and every slice within it for the call only.
    pub const VTable = struct {
        send: *const fn (context: ?*anyopaque, message: protocol.Message) SendError!void,
    };

    /// Delivers one borrowed semantic message synchronously without allocation.
    pub fn send(self: Sink, message: protocol.Message) SendError!void {
        return self.vtable.send(self.context, message);
    }
};

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
            else => encodeMessage(out, message),
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

/// A protocol session over a caller-owned sink. The session borrows the sink
/// for its lifetime, owns no heap memory, and allocates nothing.
pub const Session = struct {
    destination: Sink,
    state: State,

    /// Sends hello and begin-run to `destination`. The returned session borrows
    /// the sink, retains no input slices, and allocates nothing.
    pub fn init(destination: Sink, name: []const u8) Error!Session {
        try validateName(name);
        try destination.send(.{ .hello = .{ .name = name } });
        try destination.send(.{ .begin_run = {} });
        return .{ .destination = destination, .state = .{} };
    }

    /// Synchronously sends a mesh. Inputs remain caller-owned and are borrowed
    /// only until this allocation-free call returns.
    pub fn mesh(
        self: *Session,
        name: []const u8,
        positions: layout.Positions.Const,
        faces: []const [3]u32,
        options: GeometryOptions,
    ) Error!void {
        return self.state.mesh(self.destination, name, positions, faces, options);
    }

    /// Synchronously sends topology-preserving mesh positions. Inputs remain
    /// caller-owned and are borrowed only for this allocation-free call.
    pub fn meshPositions(self: *Session, name: []const u8, positions: layout.Positions.Const) Error!void {
        return self.state.meshPositions(self.destination, name, positions);
    }

    /// Synchronously sends a point set. Inputs remain caller-owned and are
    /// borrowed only until this allocation-free call returns.
    pub fn points(
        self: *Session,
        name: []const u8,
        positions: layout.Positions.Const,
        options: GeometryOptions,
    ) Error!void {
        return self.state.points(self.destination, name, positions, options);
    }

    /// Synchronously sends line vertices and segments. Inputs remain
    /// caller-owned and are borrowed only for this allocation-free call.
    pub fn lines(
        self: *Session,
        name: []const u8,
        positions: layout.Positions.Const,
        segments: []const [2]u32,
        options: GeometryOptions,
    ) Error!void {
        return self.state.lines(self.destination, name, positions, segments, options);
    }

    /// Synchronously sends a scalar quantity. All slices remain caller-owned,
    /// are borrowed only for the call, and no allocation occurs.
    pub fn scalar(
        self: *Session,
        structure: []const u8,
        name: []const u8,
        target: protocol.Target,
        values: []const f32,
    ) Error!void {
        return self.state.scalar(self.destination, structure, name, target, values);
    }

    /// Synchronously sends a vector quantity. All inputs remain caller-owned,
    /// are borrowed only for the call, and no allocation occurs.
    pub fn vector(
        self: *Session,
        structure: []const u8,
        name: []const u8,
        target: protocol.Target,
        vectors: layout.Positions.Const,
    ) Error!void {
        return self.state.vector(self.destination, structure, name, target, vectors);
    }

    /// Synchronously sends a log entry, borrowing `message` for this
    /// allocation-free call only.
    pub fn log(self: *Session, level: protocol.LogLevel, message: []const u8) Error!void {
        return self.state.log(self.destination, level, message);
    }

    /// Ends the current frame and begins the next unlabeled frame. The session
    /// owns no frame storage and allocates nothing.
    pub fn step(self: *Session) Error!void {
        return self.state.step(self.destination, "");
    }

    /// Ends the current frame and begins the next frame with borrowed `label`.
    /// The label is not retained and no allocation occurs.
    pub fn stepLabeled(self: *Session, label: []const u8) Error!void {
        return self.state.step(self.destination, label);
    }

    /// Ends the active frame and run. The borrowed sink remains caller-owned;
    /// repeated calls are harmless and no allocation occurs.
    pub fn finish(self: *Session) Error!void {
        return self.state.finish(self.destination);
    }
};

/// A socket-owning client session returned by `connect`. It owns the socket and
/// up to eight outstanding memfd mappings; `finish` or `close` releases both.
/// Message calls allocate no general-purpose memory.
pub const Connection = struct {
    socket: ?SocketSink,
    state: State,
    shared_tracker: SharedTracker = .{},

    /// Reports whether optional connection setup produced a live socket. This
    /// inspection borrows `self` and allocates nothing.
    pub fn isConnected(self: *const Connection) bool {
        return self.socket != null;
    }

    /// Creates a fresh writable shared mapping. The connection owns it until
    /// one successful message consumes it; unsent mappings are released by
    /// `finish`/`close`. Request a fresh buffer for every message because the
    /// viewer retains versions, so reuse is impossible by construction.
    pub fn sharedBytes(self: *Connection, len: usize) SharedError!Shared {
        if (builtin.os.tag != .linux) return error.Unsupported;
        if (self.state.finished) return error.Finished;
        if (self.socket == null) return error.NotConnected;
        return self.shared_tracker.create(len);
    }

    /// Creates shared storage for `n` positions without allocator use. The
    /// returned view is invalid after the message that sends it succeeds.
    pub fn sharedPositions(self: *Connection, n: u32) SharedError!layout.Positions.Mut {
        const shared = try self.sharedBytes(layout.Positions.byteSize(n));
        return layout.Positions.fromBytes(shared.map[0..shared.len]);
    }

    /// Creates shared storage for `n` scalars without allocator use. The
    /// returned slice is invalid after the message that sends it succeeds.
    pub fn sharedScalars(self: *Connection, n: u32) SharedError![]f32 {
        const shared = try self.sharedBytes(@as(usize, n) * @sizeOf(f32));
        return std.mem.bytesAsSlice(
            f32,
            @as([]align(@alignOf(f32)) u8, @alignCast(shared.map[0..shared.len])),
        );
    }

    /// Creates shared storage for `n` vectors without allocator use. The
    /// returned view is invalid after the message that sends it succeeds.
    pub fn sharedVectors(self: *Connection, n: u32) SharedError!layout.Positions.Mut {
        return self.sharedPositions(n);
    }

    /// Returns how many connection-owned shared regions actually used hugetlb
    /// pages. Sampling the tracker allocates nothing and does not alter ownership.
    pub fn sharedHugeRegions(self: *const Connection) u64 {
        return self.shared_tracker.huge_regions;
    }

    /// Synchronously sends a mesh when connected. Inputs remain caller-owned
    /// and are borrowed only for this allocation-free call.
    pub fn mesh(
        self: *Connection,
        name: []const u8,
        positions: layout.Positions.Const,
        faces: []const [3]u32,
        options: GeometryOptions,
    ) Error!void {
        return self.state.mesh(self.currentSink(), name, positions, faces, options);
    }

    /// Synchronously sends topology-preserving mesh positions when connected.
    /// Inputs remain caller-owned and no allocation occurs.
    pub fn meshPositions(self: *Connection, name: []const u8, positions: layout.Positions.Const) Error!void {
        return self.state.meshPositions(self.currentSink(), name, positions);
    }

    /// Synchronously sends a point set when connected. Inputs remain
    /// caller-owned and no allocation occurs.
    pub fn points(
        self: *Connection,
        name: []const u8,
        positions: layout.Positions.Const,
        options: GeometryOptions,
    ) Error!void {
        return self.state.points(self.currentSink(), name, positions, options);
    }

    /// Synchronously sends line vertices and segments when connected. Inputs
    /// remain caller-owned and no allocation occurs.
    pub fn lines(
        self: *Connection,
        name: []const u8,
        positions: layout.Positions.Const,
        segments: []const [2]u32,
        options: GeometryOptions,
    ) Error!void {
        return self.state.lines(self.currentSink(), name, positions, segments, options);
    }

    /// Synchronously sends a scalar quantity when connected. Inputs remain
    /// caller-owned and no allocation occurs.
    pub fn scalar(
        self: *Connection,
        structure: []const u8,
        name: []const u8,
        target: protocol.Target,
        values: []const f32,
    ) Error!void {
        return self.state.scalar(self.currentSink(), structure, name, target, values);
    }

    /// Synchronously sends a vector quantity when connected. Inputs remain
    /// caller-owned and no allocation occurs.
    pub fn vector(
        self: *Connection,
        structure: []const u8,
        name: []const u8,
        target: protocol.Target,
        vectors: layout.Positions.Const,
    ) Error!void {
        return self.state.vector(self.currentSink(), structure, name, target, vectors);
    }

    /// Synchronously sends a log entry when connected, borrowing `message` only
    /// for this allocation-free call.
    pub fn log(self: *Connection, level: protocol.LogLevel, message: []const u8) Error!void {
        return self.state.log(self.currentSink(), level, message);
    }

    /// Ends the current frame and begins the next unlabeled frame. Optional
    /// disconnected sessions remain no-ops and no allocation occurs.
    pub fn step(self: *Connection) Error!void {
        return self.state.step(self.currentSink(), "");
    }

    /// Ends the current frame and begins the next frame with borrowed `label`.
    /// Optional disconnected sessions remain no-ops and no allocation occurs.
    pub fn stepLabeled(self: *Connection, label: []const u8) Error!void {
        return self.state.step(self.currentSink(), label);
    }

    /// Ends the active frame and run, then releases unsent shared mappings and
    /// closes the owned socket. Repeated calls are harmless; no gpa is used.
    pub fn finish(self: *Connection) Error!void {
        defer self.close();
        return self.state.finish(self.currentSink());
    }

    /// Releases every unsent shared mapping and closes the socket without
    /// sending terminators. It is safe to call repeatedly and uses no gpa.
    pub fn close(self: *Connection) void {
        if (self.socket) |*socket| {
            self.shared_tracker.releaseAll();
            socket.close();
        } else std.debug.assert(self.shared_tracker.outstanding_len == 0);
        self.socket = null;
        self.state.finished = true;
        self.state.frame_open = false;
    }

    fn currentSink(self: *Connection) Sink {
        if (self.socket) |*socket| {
            socket.shared_tracker = &self.shared_tracker;
            return socket.sink();
        }
        return noopSink();
    }
};

/// Connects with the default I/O and environment supplied by Zig process
/// startup. The returned connection owns its socket and allocates nothing.
pub fn connect(init: std.process.Init, options: ConnectOptions) ConnectError!Connection {
    return connectWith(init.io, init.minimal.environ, options);
}

/// Connects using explicit I/O and environment dependencies. The returned
/// connection owns its socket, borrows no options, and allocates nothing.
pub fn connectWith(io: std.Io, environ: std.process.Environ, options: ConnectOptions) ConnectError!Connection {
    try validateName(options.name);
    const huge_pages = resolveHugePages(environ, options.huge_pages);

    var path_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = resolveSocketPath(environ, options.socket_path, &path_storage) catch |err| {
        if (options.optional) return disconnectedConnection(huge_pages);
        return err;
    };
    var socket = SocketSink.connect(io, path) catch |err| {
        if (options.optional) return disconnectedConnection(huge_pages);
        return err;
    };
    errdefer socket.close();

    const destination = socket.sink();
    destination.send(.{ .hello = .{ .name = options.name } }) catch |err| {
        if (options.optional) {
            socket.close();
            return disconnectedConnection(huge_pages);
        }
        return err;
    };
    destination.send(.{ .begin_run = {} }) catch |err| {
        if (options.optional) {
            socket.close();
            return disconnectedConnection(huge_pages);
        }
        return err;
    };
    return .{
        .socket = socket,
        .state = .{},
        .shared_tracker = .{ .huge_pages = huge_pages },
    };
}

const State = struct {
    frame_index: u32 = 0,
    frame_open: bool = true,
    finished: bool = false,

    fn mesh(
        self: *State,
        destination: Sink,
        name: []const u8,
        positions: layout.Positions.Const,
        faces: []const [3]u32,
        options: GeometryOptions,
    ) Error!void {
        try self.ensureActive();
        try validateName(name);
        try validateCount(faces.len);
        return destination.send(.{ .mesh = .{
            .name = name,
            .dim = options.dim,
            .positions = positions,
            .faces = faces,
        } });
    }

    fn meshPositions(
        self: *State,
        destination: Sink,
        name: []const u8,
        positions: layout.Positions.Const,
    ) Error!void {
        try self.ensureActive();
        try validateName(name);
        return destination.send(.{ .mesh_positions = .{ .name = name, .positions = positions } });
    }

    fn points(
        self: *State,
        destination: Sink,
        name: []const u8,
        positions: layout.Positions.Const,
        options: GeometryOptions,
    ) Error!void {
        try self.ensureActive();
        try validateName(name);
        return destination.send(.{ .points = .{
            .name = name,
            .dim = options.dim,
            .positions = positions,
        } });
    }

    fn lines(
        self: *State,
        destination: Sink,
        name: []const u8,
        positions: layout.Positions.Const,
        segments: []const [2]u32,
        options: GeometryOptions,
    ) Error!void {
        try self.ensureActive();
        try validateName(name);
        try validateCount(segments.len);
        return destination.send(.{ .lines = .{
            .name = name,
            .dim = options.dim,
            .positions = positions,
            .segments = segments,
        } });
    }

    fn scalar(
        self: *State,
        destination: Sink,
        structure: []const u8,
        name: []const u8,
        target: protocol.Target,
        values: []const f32,
    ) Error!void {
        try self.ensureActive();
        try validateName(structure);
        try validateName(name);
        try validateCount(values.len);
        return destination.send(.{ .scalar_quantity = .{
            .structure = structure,
            .name = name,
            .target = target,
            .values = values,
        } });
    }

    fn vector(
        self: *State,
        destination: Sink,
        structure: []const u8,
        name: []const u8,
        target: protocol.Target,
        vectors: layout.Positions.Const,
    ) Error!void {
        try self.ensureActive();
        try validateName(structure);
        try validateName(name);
        return destination.send(.{ .vector_quantity = .{
            .structure = structure,
            .name = name,
            .target = target,
            .vectors = vectors,
        } });
    }

    fn log(self: *State, destination: Sink, level: protocol.LogLevel, message: []const u8) Error!void {
        try self.ensureActive();
        if (message.len > std.math.maxInt(u32)) return error.TextTooLong;
        return destination.send(.{ .log = .{ .level = level, .text = message } });
    }

    fn step(self: *State, destination: Sink, label: []const u8) Error!void {
        try self.ensureActive();
        if (label.len > std.math.maxInt(u16)) return error.LabelTooLong;
        if (self.frame_index == std.math.maxInt(u32)) return error.FrameIndexOverflow;

        try destination.send(.{ .end_frame = {} });
        self.frame_open = false;
        const next = self.frame_index + 1;
        try destination.send(.{ .begin_frame = .{ .index = next, .label = label } });
        self.frame_index = next;
        self.frame_open = true;
    }

    fn finish(self: *State, destination: Sink) Error!void {
        if (self.finished) return;
        self.finished = true;

        var first_error: ?Error = null;
        if (self.frame_open) {
            destination.send(.{ .end_frame = {} }) catch |err| {
                first_error = err;
            };
            self.frame_open = false;
        }
        destination.send(.{ .end_run = {} }) catch |err| {
            if (first_error == null) first_error = err;
        };
        if (first_error) |err| return err;
    }

    fn ensureActive(self: *const State) Error!void {
        if (self.finished or !self.frame_open) return error.Finished;
    }
};

/// Encodes one borrowed semantic message into caller-owned scatter/gather
/// storage. The output borrows all message slices and no allocation occurs.
pub fn encodeMessage(out: *protocol.Encoded, message: protocol.Message) void {
    switch (message) {
        .hello => |value| protocol.encodeHello(out, value.name),
        .begin_run => protocol.encodeBeginRun(out),
        .begin_frame => |value| protocol.encodeBeginFrame(out, value.index, value.label),
        .end_frame => protocol.encodeEndFrame(out),
        .end_run => protocol.encodeEndRun(out),
        .mesh => |value| protocol.encodeMesh(out, value.name, value.dim, value.positions, value.faces),
        .mesh_positions => |value| protocol.encodeMeshPositions(out, value.name, value.positions),
        .points => |value| protocol.encodePoints(out, value.name, value.dim, value.positions),
        .lines => |value| protocol.encodeLines(out, value.name, value.dim, value.positions, value.segments),
        .scalar_quantity => |value| protocol.encodeScalarQuantity(
            out,
            value.structure,
            value.name,
            value.target,
            value.values,
        ),
        .vector_quantity => |value| protocol.encodeVectorQuantity(
            out,
            value.structure,
            value.name,
            value.target,
            value.vectors,
        ),
        .log => |value| protocol.encodeLog(out, value.level, value.text),
    }
}

fn validateName(name: []const u8) Error!void {
    if (name.len > protocol.max_name_len) return error.NameTooLong;
}

fn validateCount(count: usize) Error!void {
    if (count > std.math.maxInt(u32)) return error.TooManyElements;
}

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

fn resolveHugePages(environ: std.process.Environ, explicit: ?bool) bool {
    if (explicit) |enabled| return enabled;
    // Default on: hugetlbfs is tried and silently falls back (with a one-time
    // notice) when the kernel has no huge pages configured.
    const value = std.process.Environ.getPosix(environ, "VERTEX_SHARED_HUGE") orelse return true;
    return !std.mem.eql(u8, value, "0");
}

fn disconnectedConnection(huge_pages: bool) Connection {
    return .{
        .socket = null,
        .state = .{},
        .shared_tracker = .{ .huge_pages = huge_pages },
    };
}

fn noopSink() Sink {
    return .{ .context = null, .vtable = &noop_vtable };
}

const noop_vtable: Sink.VTable = .{ .send = struct {
    fn send(_: ?*anyopaque, _: protocol.Message) SendError!void {}
}.send };

// ---------------------------------------------------------------------------
// tests

const testing = std.testing;

const Recorder = struct {
    kinds: [32]protocol.Kind = undefined,
    len: u32 = 0,
    last_frame_index: u32 = 0,
    last_label: []const u8 = "",
    saw_d2: bool = false,
    saw_scalar_values: []const f32 = &.{},

    fn sink(self: *Recorder) Sink {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: Sink.VTable = .{ .send = send };

    fn send(context: ?*anyopaque, message: protocol.Message) SendError!void {
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        self.kinds[self.len] = std.meta.activeTag(message);
        self.len += 1;
        switch (message) {
            .begin_frame => |value| {
                self.last_frame_index = value.index;
                self.last_label = value.label;
            },
            .points => |value| self.saw_d2 = value.dim == .d2,
            .scalar_quantity => |value| self.saw_scalar_values = value.values,
            else => {},
        }
    }
};

test "session emits every semantic message and frame lifecycle in order" {
    var recorder: Recorder = .{};
    var session = try Session.init(recorder.sink(), "source");

    const elem_count = if (layout.layout == .soa) 9 else 3;
    var position_data: [elem_count]layout.Positions.Elem = undefined;
    const positions = layout.Positions.fromSlice(&position_data);
    positions.setAll(&.{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0) });
    const constant_positions = positions.toConst();
    const faces = [_][3]u32{.{ 0, 1, 2 }};
    const segments = [_][2]u32{.{ 0, 1 }};
    const values = [_]f32{ 1, 2, 3 };

    try session.mesh("mesh", constant_positions, &faces, .{});
    try session.meshPositions("mesh", constant_positions);
    try session.points("points", constant_positions, .{ .dim = .d2 });
    try session.lines("lines", constant_positions, &segments, .{});
    try session.scalar("mesh", "temperature", .vertex, &values);
    try session.vector("mesh", "velocity", .vertex, constant_positions);
    try session.log(.info, "hello");
    try session.stepLabeled("iteration 1");
    try session.finish();
    try session.finish();

    try testing.expectEqualSlices(protocol.Kind, &.{
        .hello,
        .begin_run,
        .mesh,
        .mesh_positions,
        .points,
        .lines,
        .scalar_quantity,
        .vector_quantity,
        .log,
        .end_frame,
        .begin_frame,
        .end_frame,
        .end_run,
    }, recorder.kinds[0..recorder.len]);
    try testing.expectEqual(1, recorder.last_frame_index);
    try testing.expectEqualStrings("iteration 1", recorder.last_label);
    try testing.expect(recorder.saw_d2);
    try testing.expectEqualSlices(f32, &values, recorder.saw_scalar_values);
    try testing.expectError(error.Finished, session.step());
}

test "session validates input before calling its sink" {
    var recorder: Recorder = .{};
    var session = try Session.init(recorder.sink(), "source");
    defer session.finish() catch {};
    const before = recorder.len;

    var long_name: [protocol.max_name_len + 1]u8 = undefined;
    @memset(&long_name, 'x');
    try testing.expectError(
        error.NameTooLong,
        session.points(&long_name, layout.Positions.Const.empty, .{}),
    );
    try testing.expectEqual(before, recorder.len);
}

test "socket sink semantic encoding produces one exact frame without allocation" {
    var expected: protocol.Encoded = undefined;
    protocol.encodeLog(&expected, .warn, "socket message");
    var expected_bytes: [128]u8 align(protocol.section_alignment) = undefined;
    const expected_frame = expected.writeTo(&expected_bytes);

    var actual: protocol.Encoded = undefined;
    encodeMessage(&actual, .{ .log = .{ .level = .warn, .text = "socket message" } });
    var actual_bytes: [128]u8 align(protocol.section_alignment) = undefined;
    const actual_frame = actual.writeTo(&actual_bytes);
    try testing.expectEqualSlices(u8, expected_frame, actual_frame);
}

test "socket path precedence and optional disconnected sessions" {
    const first = "VERTEX_SOCK=/tmp/override.sock";
    const second = "XDG_RUNTIME_DIR=/run/user/1000";
    const entries = [_:null]?[*:0]const u8{ first, second };
    const environ: std.process.Environ = .{ .block = .{ .slice = &entries } };
    var storage: [std.Io.Dir.max_path_bytes]u8 = undefined;

    try testing.expectEqualStrings(
        "/tmp/explicit.sock",
        try resolveSocketPath(environ, "/tmp/explicit.sock", &storage),
    );
    try testing.expectEqualStrings(
        "/tmp/override.sock",
        try resolveSocketPath(environ, null, &storage),
    );

    const runtime_entry = "XDG_RUNTIME_DIR=/run/user/1000";
    const runtime_entries = [_:null]?[*:0]const u8{runtime_entry};
    const runtime_environ: std.process.Environ = .{ .block = .{ .slice = &runtime_entries } };
    try testing.expectEqualStrings(
        "/run/user/1000/vertex.sock",
        try resolveSocketPath(runtime_environ, null, &storage),
    );
    try testing.expectEqualStrings(
        "/tmp/vertex.sock",
        try resolveSocketPath(.empty, null, &storage),
    );

    var connection = try connectWith(testing.io, .empty, .{
        .name = "optional",
        .optional = true,
    });
    try testing.expect(!connection.isConnected());
    try connection.step();
    try connection.finish();
    try testing.expectError(error.Finished, connection.log(.info, "after finish"));
}

const LiveServer = struct {
    server: *std.Io.net.Server,
    kinds: [16]protocol.Kind = undefined,
    len: u32 = 0,
    mesh_vertex_count: u32 = 0,
    saw_external_positions: bool = false,
    external_positions_match: bool = false,
    failed: bool = false,

    /// Accepts one connection and decodes frames until EOF, recording kinds.
    fn run(self: *LiveServer) void {
        self.serve() catch {
            self.failed = true;
        };
    }

    fn serve(self: *LiveServer) !void {
        const io = testing.io;
        var stream = try self.server.accept(io);
        defer stream.close(io);
        var pending: [8192]u8 align(protocol.section_alignment) = undefined;
        var pending_len: usize = 0;
        var fd_fifo: [16]i32 = undefined;
        var fd_len: usize = 0;
        defer closeHandleSlice(fd_fifo[0..fd_len]);

        while (true) {
            var received_handles: [16]platform.Handle = undefined;
            const received = try platform.fdpass.recvWithHandles(
                stream.socket.handle,
                pending[pending_len..],
                &received_handles,
            );
            if (received.bytes == 0) {
                if (pending_len != 0 or fd_len != 0) return error.Truncated;
                return;
            }
            if (fd_len + received.handle_count > fd_fifo.len) {
                closeHandleSlice(received_handles[0..received.handle_count]);
                return error.TooManyFds;
            }
            @memcpy(fd_fifo[fd_len..][0..received.handle_count], received_handles[0..received.handle_count]);
            fd_len += received.handle_count;
            if (received.control_truncated) return error.ControlTruncated;
            pending_len += received.bytes;

            var consumed_bytes: usize = 0;
            while (pending_len - consumed_bytes >= @sizeOf(protocol.Header)) {
                const frame = pending[consumed_bytes..pending_len];
                const header = try protocol.decodeHeader(frame);
                const frame_len = @sizeOf(protocol.Header) + @as(usize, header.len);
                if (frame_len > pending.len) return error.PayloadTooLarge;
                if (frame.len < frame_len) break;
                const flags = protocol.Flags.fromInt(header.flags);
                if (flags.fd_count > fd_len) break;
                var payload_storage: [8192]u8 align(protocol.section_alignment) = undefined;
                @memcpy(payload_storage[0..header.len], frame[@sizeOf(protocol.Header)..frame_len]);
                const payload: []align(protocol.payload_alignment) const u8 = payload_storage[0..header.len];
                const used_fds: usize = flags.fd_count;
                var frame_fds: [7]i32 = undefined;
                @memcpy(frame_fds[0..used_fds], fd_fifo[0..used_fds]);
                std.mem.copyForwards(i32, fd_fifo[0 .. fd_len - used_fds], fd_fifo[used_fds..fd_len]);
                fd_len -= used_fds;
                try self.processFrame(header, payload, frame_fds[0..used_fds]);
                consumed_bytes += frame_len;
            }
            if (consumed_bytes != 0) {
                std.mem.copyForwards(u8, pending[0 .. pending_len - consumed_bytes], pending[consumed_bytes..pending_len]);
                pending_len -= consumed_bytes;
            }
        }
    }

    fn processFrame(
        self: *LiveServer,
        header: protocol.Header,
        payload: []align(protocol.payload_alignment) const u8,
        fds: []const i32,
    ) !void {
        var mapped: [7]?platform.shm.Region = @splat(null);
        var mappings: [7][]align(64) const u8 = undefined;
        defer {
            for (mapped[0..fds.len], fds) |mapping, fd| {
                if (mapping) |region| platform.shm.unmap(region);
                platform.shm.close(fd);
            }
        }
        for (fds, 0..) |fd, i| {
            const region = try platform.shm.mapReadOnly(fd, .{ .huge_pages = true });
            mapped[i] = region;
            mappings[i] = @alignCast(region.map);
        }

        const message = try protocol.decode(header, payload, mappings[0..fds.len]);
        self.kinds[self.len] = std.meta.activeTag(message);
        self.len += 1;
        if (message == .mesh) self.mesh_vertex_count = message.mesh.positions.len();
        if (message == .mesh_positions and protocol.Flags.fromInt(header.flags).external) {
            self.saw_external_positions = true;
            var expected_storage: [layout.Positions.byteSize(3)]u8 align(64) = undefined;
            const expected = layout.Positions.fromBytes(&expected_storage);
            expected.setAll(&.{ .init(3, 4, 5), .init(6, 7, 8), .init(9, 10, 11) });
            self.external_positions_match = std.mem.eql(
                u8,
                expected.toConst().bytes(),
                message.mesh_positions.positions.bytes(),
            );
        }
    }
};

fn closeHandleSlice(handles: []const platform.Handle) void {
    for (handles) |handle| platform.shm.close(handle);
}

test "live unix socket round-trip delivers the frame sequence" {
    // Linux abstract socket: no filesystem path to create or clean up.
    const path = "\x00vertex-client-test-" ++ @tagName(layout.layout);
    const address = try std.Io.net.UnixAddress.init(path);
    var server = try address.listen(testing.io, .{});
    defer server.deinit(testing.io);

    var live: LiveServer = .{ .server = &server };
    const thread = try std.Thread.spawn(.{}, LiveServer.run, .{&live});

    var connection = try connectWith(testing.io, .empty, .{ .name = "live", .socket_path = path });
    const elem_count = if (layout.layout == .soa) 9 else 3;
    var position_data: [elem_count]layout.Positions.Elem = undefined;
    const positions = layout.Positions.fromSlice(&position_data);
    positions.setAll(&.{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0) });
    try connection.mesh("tri", positions.toConst(), &.{.{ 0, 1, 2 }}, .{});
    const shared = try connection.sharedPositions(3);
    shared.setAll(&.{ .init(3, 4, 5), .init(6, 7, 8), .init(9, 10, 11) });
    try connection.meshPositions("tri", shared.toConst());
    try testing.expectError(error.SharedConsumed, connection.meshPositions("tri", shared.toConst()));
    const scalars = try connection.sharedScalars(4);
    try testing.expectError(error.MisalignedShared, connection.scalar("tri", "bad", .vertex, scalars[1..]));
    try connection.step();
    try connection.log(.info, "hi");
    try connection.finish();
    thread.join();

    try testing.expect(!live.failed);
    const expected = [_]protocol.Kind{ .hello, .begin_run, .mesh, .mesh_positions, .end_frame, .begin_frame, .log, .end_frame, .end_run };
    try testing.expectEqualSlices(protocol.Kind, &expected, live.kinds[0..live.len]);
    try testing.expectEqual(@as(u32, 3), live.mesh_vertex_count);
    try testing.expect(live.saw_external_positions);
    try testing.expect(live.external_positions_match);
}

test "connection shared buffer tracker rejects more than eight outstanding" {
    var tracker: SharedTracker = .{};
    defer tracker.releaseAll();
    for (0..max_outstanding_shared) |_| _ = try tracker.create(64);
    try testing.expectError(error.TooManyShared, tracker.create(64));
}
