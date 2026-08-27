//! Pure client core: the messages a sketch can send to the viewer, and the
//! order in which they are valid.
//!
//! `Session` converts method calls into `protocol.Message` values and passes
//! each to a borrowed `Sink`. It performs no I/O of its own; the effect belongs
//! to whichever sink is supplied, `transport.zig` for a socket or `dylib.zig`
//! for the in-process path. This module therefore allocates nothing and can be
//! tested with a recording sink.
const std = @import("std");
const layout = @import("../geometry/layout.zig");
// Only for the error set a socket sink can return; no OS call is made here.
const platform = @import("../platform/platform.zig");
const protocol = @import("../protocol/protocol.zig");

/// Errors a sink may return while delivering one message. These report
/// transport failures: a socket write that failed or was short, or a shared
/// section that cannot be sent. Problems with the message itself are reported
/// by `Error`.
pub const SendError = std.Io.net.Stream.Writer.Error || platform.fdpass.Error || error{
    ShortWrite,
    MisalignedShared,
    SharedConsumed,
};

/// Everything a message call can return: the transport failures in `SendError`,
/// plus the argument and ordering checks made before anything is sent.
/// `Finished` means the run has already ended; the rest report an argument the
/// protocol cannot express.
pub const Error = SendError || error{
    Finished,
    FrameIndexOverflow,
    LabelTooLong,
    NameTooLong,
    TooManyElements,
    TextTooLong,
};

/// Options accepted when registering a mesh, a point cloud or a line set.
/// `dim` marks a structure as planar, which the viewer uses to choose an
/// orthographic camera once every live structure is two-dimensional.
pub const GeometryOptions = struct {
    dim: protocol.Dim = .d3,
};

/// Where a session sends its messages: a type-erased destination that accepts
/// one `protocol.Message` at a time.
/// ---
/// The same sketch code therefore runs over a socket or inside the viewer.
/// `SocketSink` in `transport.zig` encodes each message and writes it, and
/// `DirectSink` in `dylib.zig` encodes it and hands the bytes to the viewer
/// in-process. A test supplies a sink that records what it is given, which is
/// how the message sequencing is tested without I/O.
/// ---
/// The implementation owns whatever `context` points at; `send` is synchronous
/// and borrows the message and its slices for the duration of the call.
pub const Sink = struct {
    context: ?*anyopaque,
    vtable: *const VTable,

    /// The operations a sink must provide, which is delivery and nothing
    /// else.
    pub const VTable = struct {
        send: *const fn (context: ?*anyopaque, message: protocol.Message) SendError!void,
    };

    /// Delivers one message, returning once the sink has taken it.
    ///
    /// O(1) in the geometry, which the parts refer to rather than copy; what
    /// the sink then does with them is its own cost.
    pub fn send(self: Sink, message: protocol.Message) SendError!void {
        return self.vtable.send(self.context, message);
    }
};

/// Sends messages to a sink in a valid order, and is the client API when the
/// transport belongs to someone else.
/// ---
/// A stepping sketch under `steps/` is handed one of these, because the viewer
/// owns the transport in that mode. A socket client instead holds a `Connection`, which
/// wraps a `Session` around a socket it owns. The calls and the rules are
/// identical. What each message means to the viewer is documented on
/// `Connection` in `api/sketch.zig`.
/// ---
/// The session tracks the run and frame lifecycle. `step` and `finish` emit the
/// correct boundaries, and a call after the run has ended is refused rather than
/// sent. It borrows the sink for its lifetime and allocates nothing.
pub const Session = struct {
    destination: Sink,
    state: State,

    /// Opens a run on `destination`, sending the handshake and the run marker.
    /// `name` labels the run in the viewer and is borrowed for the call.
    ///
    /// O(1).
    pub fn init(destination: Sink, name: []const u8) Error!Session {
        try validateName(name);
        try destination.send(.{ .hello = .{ .name = name } });
        try destination.send(.{ .begin_run = {} });
        return .{ .destination = destination, .state = .{} };
    }

    /// Registers a triangle mesh under `name`, replacing anything registered
    /// under it before.
    ///
    /// O(k) in the name's length, the geometry being referred to rather than
    /// copied.
    pub fn mesh(
        self: *Session,
        name: []const u8,
        positions: layout.Positions.Const,
        faces: []const [3]u32,
        options: GeometryOptions,
    ) Error!void {
        return self.state.mesh(self.destination, name, positions, faces, options);
    }

    /// Updates the vertices of an existing mesh, keeping its triangles.
    ///
    /// O(k) in the name's length; see `mesh`.
    pub fn meshPositions(self: *Session, name: []const u8, positions: layout.Positions.Const) Error!void {
        return self.state.meshPositions(self.destination, name, positions);
    }

    /// Registers a point cloud under `name`.
    ///
    /// O(k) in the name's length; see `mesh`.
    pub fn points(
        self: *Session,
        name: []const u8,
        positions: layout.Positions.Const,
        options: GeometryOptions,
    ) Error!void {
        return self.state.points(self.destination, name, positions, options);
    }

    /// Registers a set of line segments under `name`.
    ///
    /// O(k) in the name's length; see `mesh`.
    pub fn lines(
        self: *Session,
        name: []const u8,
        positions: layout.Positions.Const,
        segments: []const [2]u32,
        options: GeometryOptions,
    ) Error!void {
        return self.state.lines(self.destination, name, positions, segments, options);
    }

    /// Attaches a named scalar field to an already registered structure.
    ///
    /// O(k) in the two names' lengths; see `mesh`.
    pub fn scalar(
        self: *Session,
        structure: []const u8,
        name: []const u8,
        target: protocol.Target,
        values: []const f32,
    ) Error!void {
        return self.state.scalar(self.destination, structure, name, target, values);
    }

    /// Attaches a named vector field to an already registered structure.
    ///
    /// O(k) in the two names' lengths; see `mesh`.
    pub fn vector(
        self: *Session,
        structure: []const u8,
        name: []const u8,
        target: protocol.Target,
        vectors: layout.Positions.Const,
    ) Error!void {
        return self.state.vector(self.destination, structure, name, target, vectors);
    }

    /// Writes one line to the viewer's console.
    ///
    /// O(n) in the message length.
    pub fn log(self: *Session, level: protocol.LogLevel, message: []const u8) Error!void {
        return self.state.log(self.destination, level, message);
    }

    /// Ends the current frame and opens the next. Frames divide a run into the
    /// states the viewer's timeline moves between.
    ///
    /// O(1).
    pub fn step(self: *Session) Error!void {
        return self.state.step(self.destination, "");
    }

    /// Ends the current frame and opens the next with a label, shown on the
    /// timeline.
    ///
    /// O(n) in the label length.
    pub fn stepLabeled(self: *Session, label: []const u8) Error!void {
        return self.state.step(self.destination, label);
    }

    /// Ends the frame and the run, after which the viewer discards any
    /// structure this run did not register. Calling it again does nothing.
    ///
    /// O(1).
    pub fn finish(self: *Session) Error!void {
        return self.state.finish(self.destination);
    }
};

/// The run and frame lifecycle a session enforces: which frame is open,
/// whether one is open at all, and whether the run has finished.
/// ---
/// Every message call goes through here. The protocol's ordering rules and the
/// argument validation are applied at this point, and a malformed call is
/// refused before anything reaches the sink. `Connection` holds one of these
/// too, so both client shapes share one implementation of the rules.
pub const State = struct {
    frame_index: u32 = 0,
    frame_open: bool = true,
    finished: bool = false,

    /// O(k) in the name's length, the geometry being referred to rather than
    /// copied.
    pub fn mesh(
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

    /// O(k) in the name's length; see `mesh`.
    pub fn meshPositions(
        self: *State,
        destination: Sink,
        name: []const u8,
        positions: layout.Positions.Const,
    ) Error!void {
        try self.ensureActive();
        try validateName(name);
        return destination.send(.{ .mesh_positions = .{ .name = name, .positions = positions } });
    }

    /// O(k) in the name's length; see `mesh`.
    pub fn points(
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

    /// O(k) in the name's length; see `mesh`.
    pub fn lines(
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

    /// O(k) in the two names' lengths; see `mesh`.
    pub fn scalar(
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

    /// O(k) in the two names' lengths; see `mesh`.
    pub fn vector(
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

    /// O(n) in the message length.
    pub fn log(self: *State, destination: Sink, level: protocol.LogLevel, message: []const u8) Error!void {
        try self.ensureActive();
        if (message.len > std.math.maxInt(u32)) return error.TextTooLong;
        return destination.send(.{ .log = .{ .level = level, .text = message } });
    }

    /// O(1).
    pub fn step(self: *State, destination: Sink, label: []const u8) Error!void {
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

    /// O(1).
    pub fn finish(self: *State, destination: Sink) Error!void {
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

    /// O(1).
    pub fn ensureActive(self: *const State) Error!void {
        if (self.finished or !self.frame_open) return error.Finished;
    }
};

/// Encodes one message into `out`, dispatching to the matching `protocol`
/// encoder.
///
/// This is the inline path, in which every section is written as bytes rather
/// than referred to. `SocketSink` uses it for messages with no shared sections.
/// `DirectSink` uses it for all of them, because the in-process path passes no
/// descriptors.
///
/// O(1) in the geometry; see `send`.
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

/// O(k) in the name's length.
pub fn validateName(name: []const u8) Error!void {
    if (name.len > protocol.max_name_len) return error.NameTooLong;
}

fn validateCount(count: usize) Error!void {
    if (count > std.math.maxInt(u32)) return error.TooManyElements;
}

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
