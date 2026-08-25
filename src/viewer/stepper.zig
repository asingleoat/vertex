//! Worker-thread owner for viewer-driven stepping libraries.
//!
//! Stepping runs in the viewer process, so an algorithm crash also crashes the
//! viewer; this mode intentionally gives up the socket mode's crash isolation.
const std = @import("std");
const builtin = @import("builtin");
const vertex = @import("vertex");
const server = @import("server.zig");

const protocol = vertex.internal.protocol;
const dylib = vertex.dylib;
const max_path_bytes = std.Io.Dir.max_path_bytes;
const mailbox_capacity = 16;

/// Shared queue type borrowed by `Stepper`; its caller owns and deinitializes
/// the queue after every producer has stopped.
pub const Inbox = server.Inbox;

const AbiVersionFn = *const fn () callconv(.c) u32;
const InitFn = *const fn (host: *const dylib.Host) callconv(.c) ?*anyopaque;
const StepFn = *const fn (instance: *anyopaque) callconv(.c) u8;
const DeinitFn = *const fn (instance: *anyopaque) callconv(.c) u8;

const Functions = struct {
    init: InitFn,
    step: StepFn,
    deinit: DeinitFn,
};

const Path = struct {
    bytes: [max_path_bytes]u8 = undefined,
    len: usize = 0,

    fn init(value: []const u8) error{PathTooLong}!Path {
        if (value.len > max_path_bytes) return error.PathTooLong;
        var result: Path = .{};
        @memcpy(result.bytes[0..value.len], value);
        result.len = value.len;
        return result;
    }

    fn slice(self: *const Path) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Command = union(enum) {
    load: Path,
    reload,
    reset,
    step: u32,
    run,
    pause,
    unload,
    quit,
};

/// Worker status published atomically to the render thread. Values own no
/// memory and inspection never blocks.
pub const Status = enum(u8) {
    unloaded,
    loaded,
    idle,
    running,
    finished,
    errored,
};

/// Coherent-enough UI sample of independent atomic counters. The fields own no
/// memory; a worker transition may occur between individual sampled values.
pub const Snapshot = struct {
    status: Status,
    steps: u64,
    last_step_ns: u64,
    generation: u64,
    reloads: u64,
    leaks: u64,
    abi_ok: bool,
};

/// Errors while starting the worker or queueing a render-thread command. They
/// own no payload and leave all caller-owned path bytes untouched.
pub const Error = std.Thread.SpawnError || error{ PathTooLong, MailboxFull };

/// Owns one worker, every copied library file, and every intentionally retained
/// `DynLib` mapping. Mappings are never closed because unloading Zig or C TLS,
/// atexit handlers, and global state is unsafe; their demand-paged resident
/// cost is small relative to scene data. `deinit` unlinks all owned copies after
/// the worker joins, while process exit eventually reclaims the mappings.
pub const Stepper = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    inbox: *server.Inbox,
    host: dylib.Host,
    thread: ?std.Thread = null,

    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    commands: [mailbox_capacity]Command = undefined,
    command_read: usize = 0,
    command_count: usize = 0,

    published_status: std.atomic.Value(u8) = .init(@backingInt(Status.unloaded)),
    published_steps: std.atomic.Value(u64) = .init(0),
    published_last_step_ns: std.atomic.Value(u64) = .init(0),
    published_generation: std.atomic.Value(u64) = .init(0),
    published_reloads: std.atomic.Value(u64) = .init(0),
    published_leaks: std.atomic.Value(u64) = .init(0),
    published_abi_ok: std.atomic.Value(bool) = .init(false),
    published_rate_bits: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 0))),
    /// How Run paces steps; read by the worker, written by the UI/env.
    published_pace: std.atomic.Value(u8) = .init(@backingInt(PaceMode.frame)),
    /// Frame-paced Run: the render thread grants at most one credit per
    /// rendered frame (under `mutex`); the worker consumes one per step.
    frame_credits: u32 = 0,

    input_path: [max_path_bytes + 1]u8 = @splat(0),
    watch_path: Path = .{},
    watch_mtime: ?std.Io.Timestamp = null,
    last_poll: ?std.Io.Timestamp = null,
    auto_reload: bool = true,

    copy_dir: Path,
    source_path: Path = .{},
    host_name: [protocol.max_name_len:0]u8 = @splat(0),
    libraries: std.ArrayList(std.DynLib) = .empty,
    copied_paths: std.ArrayList(Path) = .empty,
    functions: ?Functions = null,
    instance: ?*anyopaque = null,
    next_generation: u64 = 1,
    manual_steps: u32 = 0,

    /// Initializes `self` at its final stable address and spawns its worker.
    /// The inbox and allocator are borrowed until `deinit`; no library is loaded.
    pub fn init(
        self: *Stepper,
        gpa: std.mem.Allocator,
        io: std.Io,
        inbox: *server.Inbox,
        environ: std.process.Environ,
    ) Error!void {
        const runtime_dir = std.process.Environ.getPosix(environ, "XDG_RUNTIME_DIR") orelse "/tmp";
        self.* = .{
            .gpa = gpa,
            .io = io,
            .inbox = inbox,
            .host = undefined,
            .copy_dir = try Path.init(if (runtime_dir.len == 0) "/tmp" else runtime_dir),
        };
        setHostName(self, "stepper");
        self.host = .{
            .ctx = self,
            .send = hostSend,
            .log = hostLog,
            .name = &self.host_name,
        };
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    /// Requests worker termination, joins it, removes every copied file best
    /// effort, and releases bookkeeping. Library mappings remain intentionally
    /// resident and are reclaimed only by process exit.
    pub fn deinit(self: *Stepper) void {
        self.mutex.lockUncancelable(self.io);
        self.command_read = 0;
        self.command_count = 1;
        self.commands[0] = .quit;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;

        for (self.copied_paths.items) |path| {
            std.Io.Dir.cwd().deleteFile(self.io, path.slice()) catch |err| switch (err) {
                error.FileNotFound => {},
                else => std.log.warn("could not remove copied step library '{s}': {s}", .{ path.slice(), @errorName(err) }),
            };
        }
        self.copied_paths.deinit(self.gpa);
        // Deliberately deinitialize only the handle list, never DynLib.close.
        self.libraries.deinit(self.gpa);
    }

    /// Copies `path` into the editable UI field. No ownership is retained from
    /// the caller; an overlong path is rejected without changing the field.
    pub fn setInputPath(self: *Stepper, path: []const u8) error{PathTooLong}!void {
        if (path.len > max_path_bytes) return error.PathTooLong;
        @memset(&self.input_path, 0);
        @memcpy(self.input_path[0..path.len], path);
    }

    /// Returns the mutable, NUL-terminated UI input storage owned by `self`.
    /// The render thread is its sole caller and no allocation occurs.
    pub fn inputBuffer(self: *Stepper) []u8 {
        return &self.input_path;
    }

    /// Returns the currently typed path, borrowed until the next input edit.
    pub fn inputPath(self: *const Stepper) []const u8 {
        return self.input_path[0..(std.mem.indexOfScalar(u8, &self.input_path, 0) orelse self.input_path.len)];
    }

    /// Queues a load of caller-borrowed `path` after copying it into the fixed
    /// mailbox and updates the render-thread auto-reload watch path.
    pub fn requestLoad(self: *Stepper, path: []const u8) Error!void {
        const owned = try Path.init(path);
        try self.enqueue(.{ .load = owned });
        self.watch_path = owned;
        self.watch_mtime = self.statWatchMtime();
    }

    /// Queues a reload of the current source path without allocation.
    pub fn requestReload(self: *Stepper) Error!void {
        try self.enqueue(.reload);
    }

    /// Queues creation of a fresh instance from the current mapping.
    pub fn requestReset(self: *Stepper) Error!void {
        try self.enqueue(.reset);
    }

    /// Queues `count` manual steps. Zero is accepted as a no-op command.
    pub fn requestStep(self: *Stepper, count: u32) Error!void {
        try self.enqueue(.{ .step = count });
    }

    /// Queues continuous execution of the current instance.
    pub fn requestRun(self: *Stepper) Error!void {
        try self.enqueue(.run);
    }

    /// Queues a pause, retaining the current instance and timeline.
    pub fn requestPause(self: *Stepper) Error!void {
        try self.enqueue(.pause);
    }

    /// Queues instance destruction while intentionally retaining all mappings.
    pub fn requestUnload(self: *Stepper) Error!void {
        try self.enqueue(.unload);
    }

    /// Samples all UI-facing atomics without blocking or allocation.
    pub fn snapshot(self: *const Stepper) Snapshot {
        return .{
            .status = @fromBackingInt(@intCast(self.published_status.load(.acquire))),
            .steps = self.published_steps.load(.acquire),
            .last_step_ns = self.published_last_step_ns.load(.acquire),
            .generation = self.published_generation.load(.acquire),
            .reloads = self.published_reloads.load(.acquire),
            .leaks = self.published_leaks.load(.acquire),
            .abi_ok = self.published_abi_ok.load(.acquire),
        };
    }

    /// Run pacing. `frame`: one step per rendered frame (watch the algorithm);
    /// `rate`: `maxStepsPerSecond` steps per second; `max`: free-wheel until
    /// the sketch finishes, errors, or is paused — the batch mode whose output
    /// is then scrubbed on the timeline.
    pub const PaceMode = enum(u8) { frame, rate, max };

    pub fn paceMode(self: *const Stepper) PaceMode {
        return @fromBackingInt(@intCast(self.published_pace.load(.acquire)));
    }

    /// Publishes the pace mode; wakes the worker so a mode change takes effect
    /// immediately (a frame-paced worker may be waiting for a credit).
    pub fn setPaceMode(self: *Stepper, mode: PaceMode) void {
        self.published_pace.store(@backingInt(mode), .release);
        self.mutex.lockUncancelable(self.io);
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
    }

    /// Called once per rendered frame by the render thread: grants a step
    /// credit to a frame-paced running worker. Cheap when idle (one
    /// uncontended lock).
    pub fn frameTick(self: *Stepper) void {
        if (self.status() != .running or self.paceMode() != .frame) return;
        self.mutex.lockUncancelable(self.io);
        if (self.frame_credits == 0) {
            self.frame_credits = 1;
            self.condition.signal(self.io);
        }
        self.mutex.unlock(self.io);
    }

    /// Returns the current worker pacing limit. Zero means unlimited and no
    /// synchronization beyond one atomic load occurs.
    pub fn maxStepsPerSecond(self: *const Stepper) f32 {
        return @bitCast(self.published_rate_bits.load(.acquire));
    }

    /// Atomically publishes a nonnegative worker pacing limit. NaN and negative
    /// values are normalized to zero; no allocation occurs.
    pub fn setMaxStepsPerSecond(self: *Stepper, value: f32) void {
        const normalized = if (std.math.isFinite(value) and value > 0) value else 0;
        self.published_rate_bits.store(@bitCast(normalized), .release);
    }

    /// Returns the render-thread-owned auto-reload setting for direct UI edits.
    pub fn autoReloadPtr(self: *Stepper) *bool {
        return &self.auto_reload;
    }

    /// Polls source mtime at most every 250 ms and queues one reload after a
    /// change. File errors are ignored so an atomic rebuild can finish first.
    pub fn pollAutoReload(self: *Stepper) void {
        if (!self.auto_reload or self.watch_path.len == 0) return;
        const current_status = self.snapshot().status;
        if (current_status == .unloaded) return;
        const now = std.Io.Clock.awake.now(self.io);
        if (self.last_poll) |last| {
            if (last.durationTo(now).toNanoseconds() < 250 * std.time.ns_per_ms) return;
        }
        self.last_poll = now;
        const mtime = self.statWatchMtime() orelse return;
        if (self.watch_mtime) |old| {
            if (mtime.nanoseconds == old.nanoseconds) return;
        }
        self.watch_mtime = mtime;
        self.requestReload() catch |err| {
            std.log.warn("could not queue automatic step-library reload: {s}", .{@errorName(err)});
        };
    }

    fn statWatchMtime(self: *Stepper) ?std.Io.Timestamp {
        if (self.watch_path.len == 0) return null;
        const stat = std.Io.Dir.cwd().statFile(self.io, self.watch_path.slice(), .{}) catch return null;
        return stat.mtime;
    }

    fn enqueue(self: *Stepper, command: Command) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.command_count == mailbox_capacity) return error.MailboxFull;
        const write = (self.command_read + self.command_count) % mailbox_capacity;
        self.commands[write] = command;
        self.command_count += 1;
        self.condition.signal(self.io);
    }

    fn runWorker(self: *Stepper) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.command_count == 0 and self.manual_steps == 0 and
                (self.status() != .running or
                    (self.paceMode() == .frame and self.frame_credits == 0)))
            {
                self.condition.waitUncancelable(self.io, &self.mutex);
            }
            const frame_paced = self.command_count == 0 and self.manual_steps == 0 and
                self.status() == .running and self.paceMode() == .frame;
            if (frame_paced) self.frame_credits = 0;
            const command: ?Command = if (self.command_count != 0) blk: {
                const value = self.commands[self.command_read];
                self.command_read = (self.command_read + 1) % mailbox_capacity;
                self.command_count -= 1;
                break :blk value;
            } else null;
            self.mutex.unlock(self.io);

            if (command) |value| {
                switch (value) {
                    .quit => {
                        self.deinitCurrent();
                        return;
                    },
                    else => self.handleCommand(value),
                }
                continue;
            }
            if (self.manual_steps != 0) {
                self.manual_steps -= 1;
                _ = self.executeOne(false);
                continue;
            }
            if (self.status() == .running) _ = self.executeOne(!frame_paced);
        }
    }

    fn handleCommand(self: *Stepper, command: Command) void {
        switch (command) {
            .load => |path| {
                self.deinitCurrent();
                self.functions = null;
                self.source_path = path;
                _ = self.loadCurrent(false);
            },
            .reload => {
                if (self.source_path.len == 0) return;
                // A sketch that was running OR had run to completion re-runs
                // after a reload: the developer saved a change to see it play.
                // Only a never-started or explicitly paused sketch stays idle.
                const resume_running = self.status() == .running or self.status() == .finished;
                self.deinitCurrent();
                self.functions = null;
                if (self.loadCurrent(true) and resume_running) self.setStatus(.running);
            },
            .reset => {
                self.deinitCurrent();
                if (self.functions) |functions| {
                    self.setStatus(.loaded);
                    self.instance = functions.init(&self.host);
                    if (self.instance != null) {
                        self.published_steps.store(0, .release);
                        self.published_last_step_ns.store(0, .release);
                        self.setStatus(.idle);
                    } else self.setStatus(.errored);
                }
            },
            .step => |count| {
                if (self.instance != null and self.status() != .finished and self.status() != .errored) {
                    self.setStatus(.idle);
                    self.manual_steps +|= count;
                }
            },
            .run => if (self.instance != null and self.status() != .finished and self.status() != .errored) {
                self.manual_steps = 0;
                self.setStatus(.running);
            },
            .pause => if (self.instance != null and self.status() == .running) self.setStatus(.idle),
            .unload => {
                self.manual_steps = 0;
                self.deinitCurrent();
                self.functions = null;
                self.published_abi_ok.store(false, .release);
                self.setStatus(.unloaded);
            },
            .quit => unreachable,
        }
    }

    fn loadCurrent(self: *Stepper, is_reload: bool) bool {
        self.setStatus(.loaded);
        self.published_abi_ok.store(false, .release);
        self.libraries.ensureUnusedCapacity(self.gpa, 1) catch |err| {
            self.logError("stepper library bookkeeping allocation failed", @errorName(err));
            self.setStatus(.errored);
            return false;
        };
        self.copied_paths.ensureUnusedCapacity(self.gpa, 1) catch |err| {
            self.logError("stepper copied-path allocation failed", @errorName(err));
            self.setStatus(.errored);
            return false;
        };

        var copied_buffer: [max_path_bytes]u8 = undefined;
        const generation = self.next_generation;
        self.next_generation +|= 1;
        const copied_slice = std.fmt.bufPrint(
            &copied_buffer,
            // `dlopen` does not care about the suffix, but everything a
            // developer points at these copies does.
            "{s}/vertex-step-{d}-{d}" ++ builtin.target.os.tag.dynamicLibSuffix(),
            .{ self.copy_dir.slice(), std.c.getpid(), generation },
        ) catch {
            self.pushLog(.err, "stepper copied-library path is too long");
            self.setStatus(.errored);
            return false;
        };
        const copied = Path.init(copied_slice) catch unreachable;
        std.Io.Dir.copyFile(
            std.Io.Dir.cwd(),
            self.source_path.slice(),
            std.Io.Dir.cwd(),
            copied.slice(),
            self.io,
            .{ .replace = true },
        ) catch |err| {
            self.logError("stepper library copy failed", @errorName(err));
            self.setStatus(.errored);
            return false;
        };
        var library = std.DynLib.open(copied.slice()) catch |err| {
            std.Io.Dir.cwd().deleteFile(self.io, copied.slice()) catch {};
            self.logError("stepper dlopen failed", @errorName(err));
            self.setStatus(.errored);
            return false;
        };
        self.libraries.appendAssumeCapacity(library);
        self.copied_paths.appendAssumeCapacity(copied);
        self.published_generation.store(generation, .release);

        const get_version = library.lookup(AbiVersionFn, "vertex_abi_version") orelse {
            self.pushLog(.err, "stepper library is missing vertex_abi_version");
            self.setStatus(.errored);
            return false;
        };
        if (get_version() != dylib.abi_version) {
            var buffer: [160]u8 = undefined;
            const message = std.fmt.bufPrint(
                &buffer,
                "stepper ABI mismatch: viewer={d} library={d}",
                .{ dylib.abi_version, get_version() },
            ) catch "stepper ABI mismatch";
            self.pushLog(.err, message);
            self.setStatus(.errored);
            return false;
        }
        const functions: Functions = .{
            .init = library.lookup(InitFn, "vertex_init") orelse {
                self.pushLog(.err, "stepper library is missing vertex_init");
                self.setStatus(.errored);
                return false;
            },
            .step = library.lookup(StepFn, "vertex_step") orelse {
                self.pushLog(.err, "stepper library is missing vertex_step");
                self.setStatus(.errored);
                return false;
            },
            .deinit = library.lookup(DeinitFn, "vertex_deinit") orelse {
                self.pushLog(.err, "stepper library is missing vertex_deinit");
                self.setStatus(.errored);
                return false;
            },
        };
        self.functions = functions;
        self.published_abi_ok.store(true, .release);
        setHostName(self, std.fs.path.basename(self.source_path.slice()));
        self.instance = functions.init(&self.host);
        if (self.instance == null) {
            self.setStatus(.errored);
            return false;
        }
        self.published_steps.store(0, .release);
        self.published_last_step_ns.store(0, .release);
        self.setStatus(.idle);
        if (is_reload) _ = self.published_reloads.fetchAdd(1, .acq_rel);
        return true;
    }

    fn executeOne(self: *Stepper, paced: bool) bool {
        const instance = self.instance orelse return false;
        const functions = self.functions orelse return false;
        const started = std.Io.Clock.awake.now(self.io);
        const result = functions.step(instance);
        const elapsed = started.durationTo(std.Io.Clock.awake.now(self.io)).toNanoseconds();
        const elapsed_u64: u64 = if (elapsed <= 0) 0 else @intCast(@min(elapsed, std.math.maxInt(u64)));
        self.published_last_step_ns.store(elapsed_u64, .release);
        if (result != 2) _ = self.published_steps.fetchAdd(1, .acq_rel);
        switch (result) {
            0 => {
                self.manual_steps = 0;
                self.setStatus(.finished);
            },
            1 => {},
            else => {
                self.manual_steps = 0;
                self.setStatus(.errored);
            },
        }
        if (paced and result == 1) self.pace(elapsed_u64);
        return result == 1;
    }

    fn pace(self: *Stepper, elapsed_ns: u64) void {
        if (self.paceMode() != .rate) return;
        const rate = self.maxStepsPerSecond();
        if (rate <= 0) return;
        const target: u64 = @intFromFloat(@as(f64, @floatFromInt(std.time.ns_per_s)) / @as(f64, rate));
        if (target <= elapsed_ns) return;
        std.Io.sleep(self.io, .fromNanoseconds(@intCast(target - elapsed_ns)), .awake) catch {};
    }

    fn deinitCurrent(self: *Stepper) void {
        const instance = self.instance orelse return;
        self.instance = null;
        if (self.functions.?.deinit(instance) != 0) {
            _ = self.published_leaks.fetchAdd(1, .acq_rel);
            self.pushLog(.err, "stepper sketch leaked memory");
        }
    }

    fn status(self: *const Stepper) Status {
        return @fromBackingInt(@intCast(self.published_status.load(.acquire)));
    }

    fn setStatus(self: *Stepper, value: Status) void {
        self.published_status.store(@backingInt(value), .release);
    }

    fn logError(self: *Stepper, prefix: []const u8, error_name: []const u8) void {
        var buffer: [320]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "{s}: {s}", .{ prefix, error_name }) catch prefix;
        self.pushLog(.err, message);
    }

    fn pushLog(self: *Stepper, level: protocol.LogLevel, message: []const u8) void {
        var encoded: protocol.Encoded = undefined;
        vertex.internal.session.encodeMessage(&encoded, .{ .log = .{ .level = level, .text = message } });
        const slices = encoded.slices();
        if (enqueueSlices(self, slices) != 0) {
            std.log.warn("could not enqueue stepper log: {s}", .{message});
        }
    }
};

fn setHostName(self: *Stepper, value: []const u8) void {
    const len = @min(value.len, protocol.max_name_len);
    @memset(&self.host_name, 0);
    @memcpy(self.host_name[0..len], value[0..len]);
}

fn hostSend(ctx: ?*anyopaque, parts: [*]const dylib.Part, count: usize) callconv(.c) u8 {
    const self: *Stepper = @ptrCast(@alignCast(ctx.?));
    if (count == 0 or count > protocol.max_parts) return 1;
    var slices: [protocol.max_parts][]const u8 = undefined;
    for (parts[0..count], slices[0..count]) |part, *slice| slice.* = part.ptr[0..part.len];
    return enqueueSlices(self, slices[0..count]);
}

fn hostLog(ctx: ?*anyopaque, level: u8, text_ptr: [*]const u8, len: usize) callconv(.c) void {
    const self: *Stepper = @ptrCast(@alignCast(ctx.?));
    const severity: protocol.LogLevel = switch (level) {
        0 => .info,
        1 => .warn,
        else => .err,
    };
    self.pushLog(severity, text_ptr[0..len]);
}

fn enqueueSlices(self: *Stepper, slices: []const []const u8) u8 {
    std.debug.assert(slices.len != 0);
    std.debug.assert(slices[0].len == @sizeOf(protocol.Header));
    const allocated = server.Inbox.allocatePayload(self.gpa, slices[0], false) catch return 1;
    const header = allocated.header;
    const payload = allocated.payload;
    var offset: usize = 0;
    for (slices[1..]) |slice| {
        if (slice.len > payload.len -| offset) {
            self.gpa.free(payload);
            return 1;
        }
        @memcpy(payload[offset..][0..slice.len], slice);
        offset += slice.len;
    }
    if (offset != payload.len) {
        self.gpa.free(payload);
        return 1;
    }
    self.inbox.push(self.gpa, self.io, .{ .header = header, .payload = payload }) catch {
        self.gpa.free(payload);
        return 1;
    };
    return 0;
}

fn threadMain(self: *Stepper) void {
    self.runWorker();
}

test "host send copies one inline frame into the shared inbox" {
    const testing = std.testing;
    var inbox: server.Inbox = .{};
    defer inbox.deinit(testing.allocator);
    var stepper: Stepper = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .inbox = &inbox,
        .host = undefined,
        .copy_dir = try Path.init("/tmp"),
    };

    var encoded: protocol.Encoded = undefined;
    vertex.internal.session.encodeMessage(&encoded, .{ .log = .{ .level = .info, .text = "worker" } });
    const slices = encoded.slices();
    var parts: [protocol.max_parts]dylib.Part = undefined;
    for (slices, parts[0..slices.len]) |slice, *part| {
        part.* = .{ .ptr = slice.ptr, .len = slice.len };
    }
    try testing.expectEqual(@as(u8, 0), hostSend(&stepper, &parts, slices.len));

    const items = inbox.drain(testing.io);
    try testing.expectEqual(@as(usize, 1), items.len);
    const message = try protocol.decodeInline(items[0].header, items[0].payload);
    try testing.expectEqual(protocol.LogLevel.info, message.log.level);
    try testing.expectEqualStrings("worker", message.log.text);
    testing.allocator.free(items[0].payload);
    inbox.consume();
}
