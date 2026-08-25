//! Client interface to the viewer: connection setup, geometry registration
//! and frame boundaries.
//!
//! A sketch imports this module together with `shapes.zig`, which defines the
//! data types the calls here accept. This module is an effectful edge: it opens
//! the socket, maps shared memory and reads the environment. The message
//! ordering it relies on is implemented in `../client/session.zig`, which is
//! pure.
//!
//! A minimal sketch:
//!
//! ```zig
//! var vx = try vertex.connect(init, .{ .name = "my-experiment" });
//! defer vx.close();
//! try vx.mesh("surface", positions, faces, .{});
//! try vx.step();
//! try vx.finish();
//! ```
//!
//! No call retains its arguments: each borrows its slices until it returns, and
//! none allocate. Structures are identified by name. Registering an existing
//! name replaces that structure's geometry and appends a version to the
//! timeline, while the viewer's per-name display settings persist across runs.
const std = @import("std");
const layout = @import("../geometry/layout.zig");
const platform = @import("../platform/platform.zig");
const protocol = @import("../protocol/protocol.zig");
const session_mod = @import("../client/session.zig");
const transport = @import("../client/transport.zig");

const SocketSink = transport.SocketSink;
const SharedTracker = transport.SharedTracker;
const Sink = session_mod.Sink;
const State = session_mod.State;
const noopSink = transport.noopSink;
const resolveSocketPath = transport.resolveSocketPath;
const resolveHugePages = transport.resolveHugePages;
const validateName = session_mod.validateName;

/// Sequences messages to a borrowed sink, independent of the transport
/// underneath it. A `Connection` is a `Session` wrapped around a socket. A
/// stepping sketch in `steps/*.zig` receives a `Session` directly, because the
/// viewer owns the transport in that mode. The calls and the ordering rules are
/// the same in both cases.
pub const Session = session_mod.Session;

/// Selects what a quantity attaches to: `.vertex` for one value per vertex,
/// `.face` for one per triangle, or `.point` for one per point. A value count
/// that does not match the target is rejected rather than resampled.
pub const Target = protocol.Target;

/// Severity of a line sent with `log`, displayed in the viewer's console:
/// `.info`, `.warn` or `.err`.
pub const LogLevel = protocol.LogLevel;

/// Options accepted when registering a structure. `dim` defaults to `.d3`;
/// passing `.d2` marks the structure as planar, and the viewer selects an
/// orthographic camera once every live structure is two-dimensional.
pub const GeometryOptions = session_mod.GeometryOptions;

/// Errors returned by any message call: `Finished` once the run has ended,
/// `NameTooLong`, `TooManyElements` and `TextTooLong` from argument validation,
/// together with the errors the underlying socket write can report.
pub const Error = session_mod.Error;

/// Errors returned by `connect`: those in `Error`, together with socket path
/// resolution and connection failures. When `.optional` is set, these produce a
/// disconnected connection instead of an error.
pub const ConnectError = transport.ConnectError;

/// Errors returned when requesting a shared buffer: `Unsupported` on platforms
/// without shared memory, `NotConnected`, `TooManyShared` once eight buffers are
/// outstanding, and `InvalidSharedLength`.
pub const SharedError = transport.SharedError;

/// A writable shared mapping, owned by its connection until a message consumes
/// it. `sharedPositions`, `sharedScalars` and `sharedVectors` return typed views
/// over the same memory and are usually more convenient.
pub const Shared = transport.Shared;

/// Options for opening a connection.
/// ---
/// `name` labels the run in the viewer and is the only required field. Setting
/// `optional` makes a missing viewer produce a disconnected connection rather
/// than an error, so that the sketch still runs without one; `isConnected`
/// reports which occurred. `socket_path` overrides the socket location, taking
/// precedence over `$VERTEX_SOCK` and the default path, and `huge_pages`
/// overrides the page-size preference for shared buffers. Every slice is
/// borrowed for the duration of `connect`.
pub const ConnectOptions = struct {
    name: []const u8,
    optional: bool = false,
    socket_path: ?[]const u8 = null,
    huge_pages: ?bool = null,
};

/// A connection to the viewer, owning the socket and any shared buffers taken
/// from it.
/// ---
/// `connect` returns a `Connection` by value. The caller should store it in a
/// `var` and defer `close`, so that an early error still releases the socket and
/// any unsent shared buffers. `finish` ends the run and closes the connection,
/// after which the deferred `close` has no further effect. A connection owns its
/// socket and at most eight outstanding shared mappings, is not thread-safe, and
/// should not be copied once in use.
/// ---
/// Each message call encodes one message and writes it to the socket before
/// returning. The calls are synchronous, allocate nothing, and borrow their
/// arguments only for the duration of the call, so there is no queue to flush
/// and nothing to keep alive afterwards. Registering a structure under an
/// existing name replaces its geometry and appends a version to the timeline;
/// the viewer's display state for that name, such as visibility, colormap and
/// sizes, is preserved.
/// ---
/// A connection opened with `.optional` set when no viewer is listening is not
/// connected. Every call on it succeeds and does nothing, so a sketch needs no
/// separate code path.
pub const Connection = struct {
    socket: ?SocketSink,
    state: State,
    shared_tracker: SharedTracker = .{},

    /// Reports whether a viewer is listening on the other end.
    ///
    /// This is only meaningful for a connection opened with `.optional` set,
    /// where a missing viewer produces a connection whose calls succeed and do
    /// nothing. A sketch can use it to skip work performed only for display.
    /// Borrows `self` and allocates nothing.
    pub fn isConnected(self: *const Connection) bool {
        return self.socket != null;
    }

    /// Returns a `len`-byte buffer that the viewer reads without copying it.
    ///
    /// The buffer is shared memory mapped into both processes, so sending it
    /// transfers a descriptor rather than the contents. For a million-vertex
    /// update sent every frame this reduces the send from milliseconds to
    /// microseconds. For a small payload the saving is below the cost of
    /// requesting the buffer.
    ///
    /// The connection owns the buffer until the message that sends it succeeds,
    /// which consumes it; unsent buffers are released by `finish` and `close`. A
    /// buffer must not be reused after it has been sent, because the viewer
    /// retains the version that refers to it. The caller should request one
    /// buffer per message, and at most eight may be outstanding at a time.
    ///
    /// Returns `error.Unsupported` on platforms without shared memory. The
    /// caller should then fill an ordinary slice and send it as usual, which
    /// produces the same result over the wire at a higher cost. The typed
    /// functions below are usually more convenient than this one.
    pub fn sharedBytes(self: *Connection, len: usize) SharedError!Shared {
        if (!platform.shm.supported) return error.Unsupported;
        if (self.state.finished) return error.Finished;
        if (self.socket == null) return error.NotConnected;
        return self.shared_tracker.create(len);
    }

    /// Returns a shared buffer sized and typed for `n` positions.
    ///
    /// The caller fills it as it would an allocated `Positions.Mut`, using `set`
    /// and `setAll`, then passes `toConst()` to `mesh` or `meshPositions`. The
    /// view becomes invalid once that send succeeds. See `sharedBytes` for the
    /// ownership rules and for the fallback when shared memory is unsupported.
    pub fn sharedPositions(self: *Connection, n: u32) SharedError!layout.Positions.Mut {
        const shared = try self.sharedBytes(layout.Positions.byteSize(n));
        return layout.Positions.fromBytes(shared.map[0..shared.len]);
    }

    /// Returns a shared buffer sized for `n` `f32` scalars.
    ///
    /// The caller fills the slice and passes it to `scalar`. The whole slice
    /// must be passed, because a subslice is not 64-byte aligned and is rejected
    /// with `error.MisalignedShared`. The slice becomes invalid once the send
    /// succeeds; see `sharedBytes`.
    pub fn sharedScalars(self: *Connection, n: u32) SharedError![]f32 {
        const shared = try self.sharedBytes(@as(usize, n) * @sizeOf(f32));
        return std.mem.bytesAsSlice(
            f32,
            @as([]align(@alignOf(f32)) u8, @alignCast(shared.map[0..shared.len])),
        );
    }

    /// Returns a shared buffer sized and typed for `n` vectors, for use with
    /// `vector`.
    ///
    /// Vectors use the same layout as positions, so this is equivalent to
    /// `sharedPositions`. It exists under its own name so that call sites state
    /// which of the two they mean.
    pub fn sharedVectors(self: *Connection, n: u32) SharedError!layout.Positions.Mut {
        return self.sharedPositions(n);
    }

    /// Returns how many of this connection's shared buffers were backed by huge
    /// pages, which may be fewer than were requested. Benchmarks report this
    /// figure. It is zero on platforms without huge pages. Borrows `self` and
    /// allocates nothing.
    pub fn sharedHugeRegions(self: *const Connection) u64 {
        return self.shared_tracker.huge_regions;
    }

    /// Registers a triangle mesh under `name`, replacing any geometry
    /// previously registered under that name.
    ///
    /// `positions` is the vertex stream and `faces` indexes into it, three `u32`
    /// per triangle, wound counter-clockwise when seen from the front.
    /// `options.dim` selects three or two dimensions. Both slices are borrowed
    /// only until the call returns.
    ///
    /// Use this when the topology is new: an initial registration, a remesh or
    /// a decimation. When only the vertex positions have changed,
    /// `meshPositions` is considerably cheaper. Each call appends a version the
    /// viewer's timeline can return to.
    pub fn mesh(
        self: *Connection,
        name: []const u8,
        positions: layout.Positions.Const,
        faces: []const [3]u32,
        options: GeometryOptions,
    ) Error!void {
        return self.state.mesh(self.currentSink(), name, positions, faces, options);
    }

    /// Updates the vertex positions of an existing mesh, leaving its triangles
    /// unchanged.
    ///
    /// This is the inexpensive per-frame update, suited to smoothing,
    /// relaxation, flows and parameterisation, where points move but their
    /// connectivity does not. The new version shares the previous version's
    /// index buffer, so only the positions are stored and uploaded.
    ///
    /// `name` must already be registered and `positions` must have the same
    /// vertex count as the registered mesh. The slice is borrowed only until the
    /// call returns.
    pub fn meshPositions(self: *Connection, name: []const u8, positions: layout.Positions.Const) Error!void {
        return self.state.meshPositions(self.currentSink(), name, positions);
    }

    /// Registers a point cloud under `name`, replacing any geometry previously
    /// registered under that name.
    ///
    /// Points are drawn as screen-space sprites whose size is controlled in the
    /// viewer, so they remain visible at any zoom level. `options.dim` selects
    /// three or two dimensions. The slice is borrowed only until the call
    /// returns.
    pub fn points(
        self: *Connection,
        name: []const u8,
        positions: layout.Positions.Const,
        options: GeometryOptions,
    ) Error!void {
        return self.state.points(self.currentSink(), name, positions, options);
    }

    /// Registers a set of line segments under `name`, replacing any geometry
    /// previously registered under that name.
    ///
    /// `segments` indexes into `positions`, two `u32` per segment. The same
    /// primitive represents polylines, edge sets, graphs and trajectories.
    /// Segments are drawn at a constant width in pixels. Both slices are
    /// borrowed only until the call returns.
    pub fn lines(
        self: *Connection,
        name: []const u8,
        positions: layout.Positions.Const,
        segments: []const [2]u32,
        options: GeometryOptions,
    ) Error!void {
        return self.state.lines(self.currentSink(), name, positions, segments, options);
    }

    /// Attaches a named scalar field to an already registered structure.
    ///
    /// `values` holds one `f32` per element of `target`, that is per vertex, per
    /// face or per point, and its length must match the count that `target`
    /// implies. The viewer maps the values through a colormap selected per
    /// structure, which is how per-element quantities such as curvature, error,
    /// area or temperature are displayed.
    ///
    /// A structure may carry several quantities, and the viewer selects between
    /// them. Sending the same quantity name again replaces it. The slice is
    /// borrowed only until the call returns.
    pub fn scalar(
        self: *Connection,
        structure: []const u8,
        name: []const u8,
        target: protocol.Target,
        values: []const f32,
    ) Error!void {
        return self.state.scalar(self.currentSink(), structure, name, target, values);
    }

    /// Attaches a named vector field to an already registered structure.
    ///
    /// `vectors` holds one `Vec3` per element of `target`, and its length must
    /// match the count that `target` implies. The viewer draws each vector as an
    /// arrow, at a scale selected per structure. Sending the same quantity name
    /// again replaces it. The stream is borrowed only until the call returns.
    pub fn vector(
        self: *Connection,
        structure: []const u8,
        name: []const u8,
        target: protocol.Target,
        vectors: layout.Positions.Const,
    ) Error!void {
        return self.state.vector(self.currentSink(), structure, name, target, vectors);
    }

    /// Writes one line to the viewer's console at the given severity.
    ///
    /// This carries the commentary a sketch would otherwise print to a terminal,
    /// such as iteration counts, convergence measurements or notes about
    /// degenerate input. `message` is borrowed only until the call returns.
    pub fn log(self: *Connection, level: protocol.LogLevel, message: []const u8) Error!void {
        return self.state.log(self.currentSink(), level, message);
    }

    /// Ends the current frame and opens the next one.
    ///
    /// Frames divide a run into the states the viewer's timeline moves between:
    /// everything sent since the previous `step` belongs to one frame. A sketch
    /// normally calls this at the end of each iteration. Structures that are not
    /// sent again persist into the following frame, so a structure that does not
    /// change costs nothing per step.
    pub fn step(self: *Connection) Error!void {
        return self.state.step(self.currentSink(), "");
    }

    /// Ends the current frame and opens the next one, giving it a label.
    ///
    /// The label is shown on the viewer's timeline, which is useful when the
    /// frames represent distinct stages rather than repetitions of one step.
    /// `label` is borrowed only until the call returns.
    pub fn stepLabeled(self: *Connection, label: []const u8) Error!void {
        return self.state.step(self.currentSink(), label);
    }

    /// Ends the run and closes the connection.
    ///
    /// Sends the frame and run terminators, then releases any unsent shared
    /// buffers and the socket. The viewer retains everything the run registered
    /// and discards any structure it did not, so a run that stops registering a
    /// name removes that structure. A deferred `close` after this call has no
    /// further effect.
    pub fn finish(self: *Connection) Error!void {
        defer self.close();
        return self.state.finish(self.currentSink());
    }

    /// Releases the connection without ending the run.
    ///
    /// Releases any unsent shared buffers and the socket. It may be called
    /// repeatedly and after `finish`, so a `defer` placed immediately after
    /// `connect` is safe. No run terminator is sent, so the viewer retains the
    /// last frame and a sketch that fails partway leaves its progress on
    /// screen.
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

/// Opens a connection to the viewer, using the I/O implementation and
/// environment supplied by process startup.
///
/// `init` is the `std.process.Init` passed to `main`; of `options`, only `name`
/// is required. Returns a `Connection` that the caller owns and should store in
/// a `var` with a deferred `close`.
///
/// The socket path is resolved in this order: `options.socket_path`,
/// `$VERTEX_SOCK`, `$XDG_RUNTIME_DIR/vertex.sock`, and finally
/// `/tmp/vertex.sock`. A viewer that is not listening is an error unless
/// `options.optional` is set, in which case the returned connection is
/// disconnected and its calls do nothing. The opening messages of the run are
/// sent before this function returns, so the viewer shows the run as active
/// from that point.
pub fn connect(init: std.process.Init, options: ConnectOptions) ConnectError!Connection {
    return connectWith(init.io, init.minimal.environ, options);
}

/// Opens a connection with the I/O implementation and environment passed
/// explicitly, for tests and for callers that are not a process `main`.
/// Behaviour and ownership are otherwise identical to `connect`.
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

fn disconnectedConnection(huge_pages: bool) Connection {
    return .{
        .socket = null,
        .state = .{},
        .shared_tracker = .{ .huge_pages = huge_pages },
    };
}

const testing = std.testing;

const LiveServer = struct {
    server: *std.Io.net.Server,
    kinds: [16]protocol.Kind = undefined,
    len: u32 = 0,
    mesh_vertex_count: u32 = 0,
    saw_external_positions: bool = false,
    positions_match: bool = false,
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
            const received = if (platform.fdpass.supported) try platform.fdpass.recvWithHandles(
                stream.socket.handle,
                pending[pending_len..],
                &received_handles,
            ) else read: {
                // No handle passing means no shared sections to receive, so a
                // plain readv sees the whole stream.
                var data: [1][]u8 = .{pending[pending_len..]};
                break :read platform.fdpass.Received{
                    .bytes = try stream.read(io, &data),
                    .handle_count = 0,
                    .control_truncated = false,
                };
            };
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
        if (message == .mesh_positions) {
            if (protocol.Flags.fromInt(header.flags).external) self.saw_external_positions = true;
            var expected_storage: [layout.Positions.byteSize(3)]u8 align(64) = undefined;
            const expected = layout.Positions.fromBytes(&expected_storage);
            expected.setAll(&.{ .init(3, 4, 5), .init(6, 7, 8), .init(9, 10, 11) });
            self.positions_match = std.mem.eql(
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
    // A real socket file, not a Linux abstract name: macOS has no abstract
    // namespace. The path is relative to the test runner's cwd so it stays far
    // inside the `sockaddr_un` limit (107 bytes on Linux, 104 on Darwin).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buf,
        ".zig-cache/tmp/{s}/live-{s}.sock",
        .{ &tmp.sub_path, @tagName(layout.layout) },
    );
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
    // The positions update travels zero-copy where shared memory exists and
    // inline from caller memory where it does not; the frame sequence the
    // server sees is the same either way.
    const updated: [3]layout.Vec3 = .{ .init(3, 4, 5), .init(6, 7, 8), .init(9, 10, 11) };
    if (platform.shm.supported) {
        const shared = try connection.sharedPositions(3);
        shared.setAll(&updated);
        try connection.meshPositions("tri", shared.toConst());
        try testing.expectError(error.SharedConsumed, connection.meshPositions("tri", shared.toConst()));
        const scalars = try connection.sharedScalars(4);
        try testing.expectError(error.MisalignedShared, connection.scalar("tri", "bad", .vertex, scalars[1..]));
    } else {
        try testing.expectError(error.Unsupported, connection.sharedPositions(3));
        var update_data: [elem_count]layout.Positions.Elem = undefined;
        const update = layout.Positions.fromSlice(&update_data);
        update.setAll(&updated);
        try connection.meshPositions("tri", update.toConst());
    }
    try connection.step();
    try connection.log(.info, "hi");
    try connection.finish();
    thread.join();

    try testing.expect(!live.failed);
    const expected = [_]protocol.Kind{ .hello, .begin_run, .mesh, .mesh_positions, .end_frame, .begin_frame, .log, .end_frame, .end_run };
    try testing.expectEqualSlices(protocol.Kind, &expected, live.kinds[0..live.len]);
    try testing.expectEqual(@as(u32, 3), live.mesh_vertex_count);
    // A ratchet, not a tolerance: the day a platform gains shared memory the
    // zero-copy flag must appear on the frame without touching this test.
    try testing.expectEqual(platform.shm.supported, live.saw_external_positions);
    try testing.expect(live.positions_match);
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

    // Point at a path that cannot have a listener. Resolving to the real
    // default (`/tmp/vertex.sock`) made this assert that nobody is running a
    // viewer — which is false exactly when vertex is being used as intended,
    // since the viewer is meant to stay up for days.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var absent_buf: [64]u8 = undefined;
    const absent = try std.fmt.bufPrint(
        &absent_buf,
        ".zig-cache/tmp/{s}/absent.sock",
        .{&tmp.sub_path},
    );
    var connection = try connectWith(testing.io, .empty, .{
        .name = "optional",
        .optional = true,
        .socket_path = absent,
    });
    try testing.expect(!connection.isConnected());
    try connection.step();
    try connection.finish();
    try testing.expectError(error.Finished, connection.log(.info, "after finish"));
}

test "connection shared buffer tracker rejects more than eight outstanding" {
    if (!platform.shm.supported) return error.SkipZigTest;
    var tracker: SharedTracker = .{};
    defer tracker.releaseAll();
    for (0..transport.max_outstanding_shared) |_| _ = try tracker.create(64);
    try testing.expectError(error.TooManyShared, tracker.create(64));
}
