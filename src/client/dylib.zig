//! Self-consistent C ABI for viewer-driven stepping sketches.
//!
//! A `DirectSink` only supports inline messages. Shared memfd buffers remain a
//! socket-only `Connection` API; `Session` deliberately has no shared-buffer
//! methods, because it can target any sink.
const std = @import("std");
const client = @import("session.zig");
const protocol = @import("../protocol/protocol.zig");

/// Self-consistency version for the stepping-library ABI. Bump this whenever
/// `Host`, `Part`, or any exported function signature changes.
pub const abi_version: u32 = 1;

/// One borrowed scatter/gather part passed synchronously to the viewer. The
/// sketch retains ownership and the host must copy it before returning.
pub const Part = extern struct {
    ptr: [*]const u8,
    len: usize,
};

/// Borrowed callbacks and source name supplied by the viewer. The viewer owns
/// the host and name for the complete lifetime of the sketch instance.
pub const Host = extern struct {
    ctx: ?*anyopaque,
    send: *const fn (ctx: ?*anyopaque, parts: [*]const Part, count: usize) callconv(.c) u8,
    log: *const fn (ctx: ?*anyopaque, level: u8, text: [*]const u8, len: usize) callconv(.c) void,
    name: [*:0]const u8,
};

/// Allocation-free direct transport over a borrowed host. Messages are encoded
/// into stack-owned `Encoded` storage; shared buffers are intentionally absent.
pub const DirectSink = struct {
    host: *const Host,

    /// Returns a sink borrowing this stable-address `DirectSink`. The returned
    /// value is invalid once the direct sink or its host is destroyed.
    pub fn sink(self: *DirectSink) client.Sink {
        return .{ .context = self, .vtable = &vtable };
    }

    fn send(self: *DirectSink, message: protocol.Message) client.SendError!void {
        var encoded: protocol.Encoded = undefined;
        client.encodeMessage(&encoded, message);
        const slices = encoded.slices();
        var parts: [protocol.max_parts]Part = undefined;
        for (slices, parts[0..slices.len]) |slice, *part| {
            part.* = .{ .ptr = slice.ptr, .len = slice.len };
        }
        if (self.host.send(self.host.ctx, &parts, slices.len) != 0) return error.ShortWrite;
    }

    const vtable: client.Sink.VTable = .{ .send = struct {
        fn send(context: ?*anyopaque, message: protocol.Message) client.SendError!void {
            const direct: *DirectSink = @ptrCast(@alignCast(context.?));
            return direct.send(message);
        }
    }.send };
};

/// Returns the concrete ABI wrapper for `Sketch`. The returned functions own
/// every live instance created by `init`; callers must eventually pass it to
/// `deinit`, and must keep the host callbacks alive until then.
pub fn Exports(comptime Sketch: type) type {
    return struct {
        const DebugAllocator = std.heap.DebugAllocator(.{ .enable_memory_limit = true });

        const Instance = struct {
            allocator: DebugAllocator,
            direct: DirectSink,
            session: client.Session,
            state: Sketch.State,
        };

        /// Returns the compile-time ABI version without allocation.
        pub fn version() callconv(.c) u32 {
            return abi_version;
        }

        /// Creates and owns one leak-checked sketch instance. Null reports an
        /// initialization failure through the borrowed host log callback.
        pub fn init(host: *const Host) callconv(.c) ?*anyopaque {
            const instance = std.heap.page_allocator.create(Instance) catch |err| {
                logError(host, "vertex_init allocation failed", @errorName(err));
                return null;
            };
            instance.* = .{
                .allocator = .init,
                .direct = .{ .host = host },
                .session = undefined,
                .state = undefined,
            };
            const gpa = instance.allocator.allocator();
            instance.session = client.Session.init(instance.direct.sink(), std.mem.span(host.name)) catch |err| {
                logError(host, "vertex_init session failed", @errorName(err));
                finishFailedInit(instance, false);
                return null;
            };
            instance.state = Sketch.init(gpa, &instance.session) catch |err| {
                logError(host, "vertex_init sketch failed", @errorName(err));
                finishFailedInit(instance, true);
                return null;
            };
            return instance;
        }

        /// Executes one algorithm step. Returns 1 to continue, 0 when finished,
        /// and 2 after reporting a sketch or frame-boundary error to the host.
        pub fn step(instance_ptr: *anyopaque) callconv(.c) u8 {
            const instance: *Instance = @ptrCast(@alignCast(instance_ptr));
            const keep_going = Sketch.step(
                &instance.state,
                instance.allocator.allocator(),
                &instance.session,
            ) catch |err| {
                logError(instance.direct.host, "vertex_step sketch failed", @errorName(err));
                return 2;
            };
            instance.session.step() catch |err| {
                logError(instance.direct.host, "vertex_step frame boundary failed", @errorName(err));
                return 2;
            };
            return @intFromBool(keep_going);
        }

        /// Ends the run and destroys the owned instance. Returns 1 when its
        /// internal DebugAllocator reports leaks, otherwise 0.
        pub fn deinit(instance_ptr: *anyopaque) callconv(.c) u8 {
            const instance: *Instance = @ptrCast(@alignCast(instance_ptr));
            const host = instance.direct.host;
            const gpa = instance.allocator.allocator();
            Sketch.deinit(&instance.state, gpa);
            instance.session.finish() catch |err| {
                logError(host, "vertex_deinit finish failed", @errorName(err));
            };
            const leaked = finishAllocator(&instance.allocator);
            std.heap.page_allocator.destroy(instance);
            return @intFromBool(leaked);
        }

        fn finishFailedInit(instance: *Instance, session_started: bool) void {
            if (session_started) instance.session.finish() catch {};
            const host = instance.direct.host;
            if (finishAllocator(&instance.allocator)) {
                logText(host, 2, "vertex_init leaked memory while unwinding");
            }
            std.heap.page_allocator.destroy(instance);
        }

        fn finishAllocator(allocator: *DebugAllocator) bool {
            // DebugAllocator's exact outstanding-byte accounting gives the
            // leak result without emitting a second, non-host log stream.
            const leaked = allocator.total_requested_bytes != 0;
            allocator.deinitWithoutLeakChecks();
            return leaked;
        }
    };
}

/// Exports the four stable C symbols for `Sketch`. Calling this at comptime
/// allocates no runtime state; tests can call `Exports(Sketch)` directly.
pub fn exportSketch(comptime Sketch: type) void {
    const E = Exports(Sketch);
    @export(&E.version, .{ .name = "vertex_abi_version" });
    @export(&E.init, .{ .name = "vertex_init" });
    @export(&E.step, .{ .name = "vertex_step" });
    @export(&E.deinit, .{ .name = "vertex_deinit" });
}

fn logError(host: *const Host, prefix: []const u8, error_name: []const u8) void {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{s}: {s}", .{ prefix, error_name }) catch prefix;
    logText(host, 2, text);
}

fn logText(host: *const Host, level: u8, text: []const u8) void {
    host.log(host.ctx, level, text.ptr, text.len);
}

const testing = std.testing;
const layout = @import("../geometry/layout.zig");

const Fake = struct {
    kinds: [32]protocol.Kind = undefined,
    kind_count: usize = 0,
    log_count: usize = 0,
    decode_failed: bool = false,

    fn host(self: *Fake) Host {
        return .{
            .ctx = self,
            .send = send,
            .log = log,
            .name = "test-sketch",
        };
    }

    fn send(ctx: ?*anyopaque, parts: [*]const Part, count: usize) callconv(.c) u8 {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        if (count == 0 or parts[0].len != @sizeOf(protocol.Header)) {
            self.decode_failed = true;
            return 1;
        }
        const header_bytes = parts[0].ptr[0..parts[0].len];
        const header = protocol.decodeHeader(header_bytes) catch {
            self.decode_failed = true;
            return 1;
        };
        var payload: [4096]u8 align(protocol.section_alignment) = undefined;
        if (header.len > payload.len) {
            self.decode_failed = true;
            return 1;
        }
        var offset: usize = 0;
        for (parts[1..count]) |part| {
            if (offset + part.len > header.len) {
                self.decode_failed = true;
                return 1;
            }
            @memcpy(payload[offset..][0..part.len], part.ptr[0..part.len]);
            offset += part.len;
        }
        if (offset != header.len) {
            self.decode_failed = true;
            return 1;
        }
        _ = protocol.decodeInline(header, payload[0..header.len]) catch {
            self.decode_failed = true;
            return 1;
        };
        self.kinds[self.kind_count] = @fromBackingInt(@intCast(header.kind));
        self.kind_count += 1;
        return 0;
    }

    fn log(ctx: ?*anyopaque, _: u8, _: [*]const u8, _: usize) callconv(.c) void {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        self.log_count += 1;
    }
};

const TestSketch = struct {
    const P = layout.Positions;

    /// Test-owned position storage released by `deinit`.
    pub const State = struct {
        positions: P.Mut,
        count: u8 = 0,
    };

    /// Allocates one point and sends the test's initial structure.
    pub fn init(gpa: std.mem.Allocator, session: *client.Session) !State {
        const positions = try P.alloc(gpa, 1);
        errdefer positions.free(gpa);
        positions.set(0, .init(1, 2, 3));
        try session.points("point", positions.toConst(), .{});
        return .{ .positions = positions };
    }

    /// Advances the fixed three-step test without allocation.
    pub fn step(state: *State, _: std.mem.Allocator, _: *client.Session) !bool {
        state.count += 1;
        return state.count < 3;
    }

    /// Frees the position allocation owned by the test state.
    pub fn deinit(state: *State, gpa: std.mem.Allocator) void {
        state.positions.free(gpa);
    }
};

const ErrorSketch = struct {
    /// Empty error-path state owning no memory.
    pub const State = struct {};

    /// Returns an allocation-free empty state.
    pub fn init(_: std.mem.Allocator, _: *client.Session) !State {
        return .{};
    }

    /// Always returns the intentional test error without allocation.
    pub fn step(_: *State, _: std.mem.Allocator, _: *client.Session) !bool {
        return error.Intentional;
    }

    /// Releases nothing, because the state owns no memory.
    pub fn deinit(_: *State, _: std.mem.Allocator) void {}
};

const LeakSketch = struct {
    /// Test state deliberately retaining one allocation.
    pub const State = struct { leaked: []u8 };

    /// Allocates the byte intentionally left live by `deinit`.
    pub fn init(gpa: std.mem.Allocator, _: *client.Session) !State {
        return .{ .leaked = try gpa.alloc(u8, 1) };
    }

    /// Finishes immediately without allocation.
    pub fn step(_: *State, _: std.mem.Allocator, _: *client.Session) !bool {
        return false;
    }

    /// Deliberately leaves the test allocation live for leak detection.
    pub fn deinit(_: *State, _: std.mem.Allocator) void {}
};

test "direct exports deliver init three steps and deinit in wire order" {
    var fake: Fake = .{};
    const host = fake.host();
    const E = Exports(TestSketch);
    try testing.expectEqual(abi_version, E.version());
    const instance = E.init(&host) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u8, 1), E.step(instance));
    try testing.expectEqual(@as(u8, 1), E.step(instance));
    try testing.expectEqual(@as(u8, 0), E.step(instance));
    try testing.expectEqual(@as(u8, 0), E.deinit(instance));
    const expected = [_]protocol.Kind{
        .hello,
        .begin_run,
        .points,
        .end_frame,
        .begin_frame,
        .end_frame,
        .begin_frame,
        .end_frame,
        .begin_frame,
        .end_frame,
        .end_run,
    };
    try testing.expect(!fake.decode_failed);
    try testing.expectEqualSlices(protocol.Kind, &expected, fake.kinds[0..fake.kind_count]);
}

test "direct exports report step errors through host log" {
    var fake: Fake = .{};
    const host = fake.host();
    const E = Exports(ErrorSketch);
    const instance = E.init(&host) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u8, 2), E.step(instance));
    try testing.expect(fake.log_count != 0);
    try testing.expectEqual(@as(u8, 0), E.deinit(instance));
}

test "direct exports report DebugAllocator leaks" {
    var fake: Fake = .{};
    const host = fake.host();
    const E = Exports(LeakSketch);
    const instance = E.init(&host) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u8, 1), E.deinit(instance));
}
