//! Talking to the viewer: open a connection, describe geometry, step frames.
//!
//! This is one of the two modules a sketch imports; the other is `shapes.zig`,
//! which is the pure vocabulary for the data you pass in here. Everything in
//! this module is an *edge*: it opens sockets, maps shared memory and reads the
//! environment. The message ordering it enforces is pure and lives in
//! `../client/session.zig`.
//!
//! The shape of a sketch:
//!
//! ```zig
//! var vx = try vertex.connect(init, .{ .name = "my-experiment" });
//! defer vx.close();
//! try vx.mesh("surface", positions, faces, .{});
//! try vx.step();                  // frame boundary
//! try vx.finish();
//! ```
//!
//! Nothing you pass is retained: every call borrows its slices only until it
//! returns, and none of them allocate. Structures are keyed by name — sending
//! the same name again replaces its geometry and adds a scrubbable version,
//! while the viewer keeps your per-name view settings across runs.
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

/// The sink-agnostic message sequencer. `Connection` is one wrapped around a
/// socket; a stepping sketch (`steps/*.zig`) is handed a `Session` directly,
/// because the viewer already owns the transport in that mode. Same calls,
/// same ordering rules, no socket of its own.
pub const Session = session_mod.Session;

/// Where a quantity attaches to its structure: `.vertex` (one value per
/// vertex), `.face` (one per triangle) or `.point` (one per point). Passing a
/// count that does not match the target is an error, not a silent stretch.
pub const Target = protocol.Target;

/// Severity of a `log` line, shown in the viewer's console: `.info`, `.warn`
/// or `.err`.
pub const LogLevel = protocol.LogLevel;

/// Per-registration options. `dim` is `.d3` by default; pass `.d2` for planar
/// work and the viewer switches to an orthographic pan/zoom camera once every
/// live structure is 2D.
pub const GeometryOptions = session_mod.GeometryOptions;

/// Errors any message call can return: `Finished` once the run has ended,
/// `NameTooLong`, `TooManyElements`, `TextTooLong`, plus whatever the
/// underlying socket write reports.
pub const Error = session_mod.Error;

/// Errors from `connect`: everything in `Error` plus socket path resolution
/// and connection failures. With `.optional = true` these degrade to a
/// disconnected no-op connection instead.
pub const ConnectError = transport.ConnectError;

/// Errors from requesting a shared buffer: `Unsupported` where the platform
/// has no shared memory, `NotConnected`, `TooManyShared` (eight outstanding is
/// the cap), `InvalidSharedLength`.
pub const SharedError = transport.SharedError;

/// One writable shared mapping owned by its connection until a message
/// consumes it. Prefer `sharedPositions`/`sharedScalars`/`sharedVectors`,
/// which hand you a typed view over the same memory.
pub const Shared = transport.Shared;

/// How to open a connection.
///
/// `name` labels this run in the viewer and is the only required field.
/// `optional = true` turns a missing viewer into a no-op connection instead of
/// an error, so a sketch still runs headless — check `isConnected` if you care.
/// `socket_path` overrides where to look, ahead of `$VERTEX_SOCK` and the
/// default; `huge_pages` overrides the shared-buffer page preference. Every
/// slice is borrowed for the duration of `connect` only.
pub const ConnectOptions = struct {
    name: []const u8,
    optional: bool = false,
    socket_path: ?[]const u8 = null,
    huge_pages: ?bool = null,
};

/// A live connection to the viewer — the object a sketch holds and calls.
///
/// **How to hold it.** `connect` returns one by value; keep it in a `var` and
/// `defer vx.close()` immediately, so an early error still releases the socket
/// and any shared buffers. End a successful run with `finish`, which closes
/// too, making the `defer` a harmless second call. It owns its socket and up
/// to eight outstanding shared mappings and nothing else; it is not thread-safe
/// and is not meant to be copied once used.
///
/// **What the calls do.** Each one encodes a message and writes it to the
/// socket before returning — synchronous, allocation-free, and borrowing your
/// slices only for the duration of the call. There is no queue to flush and
/// nothing to keep alive afterwards. Registering a structure under a name that
/// already exists replaces its geometry and adds a version to the timeline;
/// viewer-side state keyed by that name (visibility, colormap, sizes) survives.
///
/// **When it is not connected** (`.optional = true` and no viewer), every call
/// is a successful no-op, so a sketch needs no branches.
pub const Connection = struct {
    socket: ?SocketSink,
    state: State,
    shared_tracker: SharedTracker = .{},

    /// Whether a viewer is actually on the other end.
    ///
    /// Only interesting with `.optional = true`, where a missing viewer yields
    /// a connection whose calls all succeed and do nothing. Use it to skip
    /// expensive work you would only do to visualise. Borrows `self`.
    pub fn isConnected(self: *const Connection) bool {
        return self.socket != null;
    }

    /// Requests a `len`-byte buffer that the viewer will read without a copy.
    ///
    /// The zero-copy path: instead of filling your own memory and having the
    /// bytes copied through the socket, you fill memory that both processes
    /// map, and only a descriptor crosses. Worth it for large, per-frame
    /// payloads — a million-vertex update sends in microseconds instead of
    /// milliseconds — and not worth the ceremony for small ones.
    ///
    /// **How to hold it.** The connection owns the buffer until the message
    /// that sends it succeeds, which consumes it; unsent buffers are released
    /// by `finish`/`close`. Never reuse one after sending: the viewer retains
    /// versions, so the memory is still being read. Ask for a fresh buffer per
    /// message. At most eight may be outstanding at once.
    ///
    /// Returns `error.Unsupported` where the platform has no shared memory, in
    /// which case fill your own slice and send it normally — the wire result is
    /// identical, only slower. Prefer the typed helpers below.
    pub fn sharedBytes(self: *Connection, len: usize) SharedError!Shared {
        if (!platform.shm.supported) return error.Unsupported;
        if (self.state.finished) return error.Finished;
        if (self.socket == null) return error.NotConnected;
        return self.shared_tracker.create(len);
    }

    /// A shared buffer sized and typed for `n` positions.
    ///
    /// Fill it exactly like an allocated `Positions.Mut` (`set`, `setAll`),
    /// then pass `.toConst()` to `mesh` or `meshPositions`. The view is dead
    /// the moment that send succeeds. See `sharedBytes` for the ownership
    /// rules and the `error.Unsupported` fallback.
    pub fn sharedPositions(self: *Connection, n: u32) SharedError!layout.Positions.Mut {
        const shared = try self.sharedBytes(layout.Positions.byteSize(n));
        return layout.Positions.fromBytes(shared.map[0..shared.len]);
    }

    /// A shared buffer sized for `n` `f32` scalars.
    ///
    /// Fill the slice, then hand it to `scalar`. Pass the whole slice: a
    /// subslice is not 64-byte aligned and is rejected with
    /// `error.MisalignedShared`. Dead once the send succeeds; see
    /// `sharedBytes`.
    pub fn sharedScalars(self: *Connection, n: u32) SharedError![]f32 {
        const shared = try self.sharedBytes(@as(usize, n) * @sizeOf(f32));
        return std.mem.bytesAsSlice(
            f32,
            @as([]align(@alignOf(f32)) u8, @alignCast(shared.map[0..shared.len])),
        );
    }

    /// A shared buffer sized and typed for `n` vectors, for `vector`.
    ///
    /// Identical to `sharedPositions` — vectors travel in the same layout as
    /// positions — and named separately so call sites read as what they mean.
    pub fn sharedVectors(self: *Connection, n: u32) SharedError!layout.Positions.Mut {
        return self.sharedPositions(n);
    }

    /// How many shared buffers this connection actually got huge pages for.
    ///
    /// Diagnostic, for benchmarks that want to report what the kernel granted
    /// rather than what was asked for. Always 0 where huge pages do not exist.
    /// Borrows `self`.
    pub fn sharedHugeRegions(self: *const Connection) u64 {
        return self.shared_tracker.huge_regions;
    }

    /// Registers a triangle mesh under `name`, replacing any previous geometry.
    ///
    /// `positions` is the vertex stream; `faces` indexes into it, three `u32`
    /// per triangle, counter-clockwise for a front face. `options.dim` selects
    /// 3D (default) or 2D. Both slices are read and released by the time the
    /// call returns.
    ///
    /// Use this whenever the *topology* is new — first registration, a remesh,
    /// a decimation. If only the vertices moved, `meshPositions` is much
    /// cheaper. Every call adds a version you can scrub back to.
    pub fn mesh(
        self: *Connection,
        name: []const u8,
        positions: layout.Positions.Const,
        faces: []const [3]u32,
        options: GeometryOptions,
    ) Error!void {
        return self.state.mesh(self.currentSink(), name, positions, faces, options);
    }

    /// Updates the vertices of an existing mesh, keeping its triangles.
    ///
    /// The cheap per-frame update: smoothing, relaxation, flows,
    /// parameterisation — anything that moves points without changing how they
    /// connect. The new version shares the previous version's index buffer, so
    /// only the positions are stored and uploaded.
    ///
    /// `positions` must have the same vertex count as the registered mesh, and
    /// `name` must already exist. Borrowed for the call only.
    pub fn meshPositions(self: *Connection, name: []const u8, positions: layout.Positions.Const) Error!void {
        return self.state.meshPositions(self.currentSink(), name, positions);
    }

    /// Registers a point cloud under `name`, replacing any previous geometry.
    ///
    /// Points are drawn as screen-space sprites of a size you control in the
    /// viewer, so they stay legible at any zoom. `options.dim` selects 3D or
    /// 2D. Borrowed for the call only.
    pub fn points(
        self: *Connection,
        name: []const u8,
        positions: layout.Positions.Const,
        options: GeometryOptions,
    ) Error!void {
        return self.state.points(self.currentSink(), name, positions, options);
    }

    /// Registers a line set under `name`, replacing any previous geometry.
    ///
    /// `segments` indexes into `positions`, two `u32` per segment. This one
    /// primitive covers polylines, edge sets, graphs, trajectories and normals
    /// drawn as sticks — anything made of straight pieces. Lines are drawn at a
    /// constant pixel width. Borrowed for the call only.
    pub fn lines(
        self: *Connection,
        name: []const u8,
        positions: layout.Positions.Const,
        segments: []const [2]u32,
        options: GeometryOptions,
    ) Error!void {
        return self.state.lines(self.currentSink(), name, positions, segments, options);
    }

    /// Attaches a named scalar field to an existing structure.
    ///
    /// One `f32` per element of `target`: per vertex, per face, or per point.
    /// The viewer maps it through a colormap you pick per structure, so this is
    /// how curvature, error, area, temperature or any other per-element number
    /// becomes something you can see. `values.len` must match the count that
    /// `target` implies.
    ///
    /// A structure can carry several; you switch between them in the viewer.
    /// Re-sending the same quantity name replaces it. Borrowed for the call.
    pub fn scalar(
        self: *Connection,
        structure: []const u8,
        name: []const u8,
        target: protocol.Target,
        values: []const f32,
    ) Error!void {
        return self.state.scalar(self.currentSink(), structure, name, target, values);
    }

    /// Attaches a named vector field to an existing structure.
    ///
    /// One `Vec3` per element of `target`, drawn as arrows scaled in the
    /// viewer: normals, gradients, velocities, forces. `vectors.len()` must
    /// match the count that `target` implies. Re-sending the same name replaces
    /// it. Borrowed for the call.
    pub fn vector(
        self: *Connection,
        structure: []const u8,
        name: []const u8,
        target: protocol.Target,
        vectors: layout.Positions.Const,
    ) Error!void {
        return self.state.vector(self.currentSink(), structure, name, target, vectors);
    }

    /// Writes a line to the viewer's console at `level`.
    ///
    /// For the running commentary a sketch would otherwise print to a terminal
    /// you are not looking at — iteration counts, convergence, "this input was
    /// degenerate". `message` is borrowed for the call.
    pub fn log(self: *Connection, level: protocol.LogLevel, message: []const u8) Error!void {
        return self.state.log(self.currentSink(), level, message);
    }

    /// Ends the current frame and opens the next one.
    ///
    /// This is what makes the timeline: everything sent since the last `step`
    /// belongs to one frame, and the viewer's scrubber moves between them.
    /// Call it at the bottom of your iteration loop. Structures you do not
    /// re-send simply persist into the next frame, so a static mesh costs
    /// nothing per step.
    pub fn step(self: *Connection) Error!void {
        return self.state.step(self.currentSink(), "");
    }

    /// Like `step`, but names the frame you are about to open.
    ///
    /// The label shows on the scrubber — "iteration 12", "after collapse" —
    /// which is worth it when the frames are not interchangeable. Borrowed for
    /// the call.
    pub fn stepLabeled(self: *Connection, label: []const u8) Error!void {
        return self.state.step(self.currentSink(), label);
    }

    /// Ends the run cleanly and closes the connection.
    ///
    /// Sends the frame and run terminators, then releases any unsent shared
    /// buffers and the socket. The viewer keeps everything this run registered
    /// and discards anything it did not — so a run that stops naming a
    /// structure removes it. Safe to call once and then have `defer close()`
    /// run harmlessly after.
    pub fn finish(self: *Connection) Error!void {
        defer self.close();
        return self.state.finish(self.currentSink());
    }

    /// Drops the connection without ending the run.
    ///
    /// The `defer` partner to `connect`: it releases unsent shared buffers and
    /// the socket, and is safe to call repeatedly and after `finish`. Because
    /// no run terminator is sent, the viewer keeps the last frame as it stood —
    /// which is what you want when a sketch dies partway and you would rather
    /// look at how far it got.
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

/// Opens a connection to the viewer. The first line of nearly every sketch.
///
/// Takes the `std.process.Init` your `main` was handed, and `options` (only
/// `.name` is required). Returns a `Connection` you own — hold it in a `var`
/// and `defer vx.close()` on the next line.
///
/// The socket is found in this order: `options.socket_path`, then
/// `$VERTEX_SOCK`, then `$XDG_RUNTIME_DIR/vertex.sock`, then
/// `/tmp/vertex.sock`. A missing viewer is an error unless you pass
/// `.optional = true`, which yields a connection whose calls all quietly
/// succeed. Sends the run's opening messages before returning, so the viewer
/// shows the run as live from this moment.
pub fn connect(init: std.process.Init, options: ConnectOptions) ConnectError!Connection {
    return connectWith(init.io, init.minimal.environ, options);
}

/// `connect` with the I/O implementation and environment passed explicitly.
///
/// For tests and for callers that are not a process `main`. Identical
/// behaviour and ownership otherwise.
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
