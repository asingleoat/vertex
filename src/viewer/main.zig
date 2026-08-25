//! The viewer process: startup, the frame loop, and the state they share.
//!
//! This is the outermost edge. It owns the window through sokol_app, the scene,
//! the renderer, the socket server and the stepper, and it runs the frame
//! callback that ties them together: drain whatever the socket thread has
//! staged, apply it to the scene, let the renderer catch up with the blobs that
//! changed, draw, then draw the UI over it.
//!
//! Everything with a lifetime longer than a frame lives in one file-scope
//! `state`, the only global in the program. sokol_app's callbacks are C
//! function pointers with no context argument.
//!
//! Several environment variables exist for headless use, and the smoke tests
//! depend on them: `VERTEX_EXIT_AFTER_FRAMES` stops the viewer after a fixed
//! number of frames, `VERTEX_PICK_PROBE` issues one pick at given coordinates,
//! `VERTEX_MEMORY_BUDGET_MB` sets the retention budget, and the `VERTEX_STEP_*`
//! variables drive dylib mode. The statistics lines printed on exit are what
//! those tests assert against.
const std = @import("std");
const vertex = @import("vertex");
const sokol = @import("sokol");
const ig = @import("cimgui");

const ingest_mod = @import("ingest.zig");
const input_mod = @import("input.zig");
const server_mod = @import("server.zig");
const stepper_mod = @import("stepper.zig");
const scene_pass = @import("scene_pass.zig");
const mesh_render = @import("render/mesh.zig");
const pick = @import("pick.zig");
const ui = @import("ui.zig");

const sapp = sokol.app;
const sg = sokol.gfx;
const sglue = sokol.glue;
const simgui = sokol.imgui;
const slog = sokol.log;
const Scene = vertex.internal.scene.Scene;
const mebibyte: usize = 1024 * 1024;
const default_retention: vertex.internal.scene.Retention = .{};

const Probe = struct {
    pixel: [2]u32,
    last_hit: ?pick.Hit = null,
};

const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    scene: Scene = undefined,
    inbox: server_mod.Inbox = .{},
    ingest: ingest_mod.Ingest = undefined,
    input: input_mod.Input = undefined,
    server: server_mod.Server = undefined,
    stepper: stepper_mod.Stepper = undefined,
    renderer: mesh_render.Renderer = undefined,
    picker: pick.Picker = undefined,
    scrub: u32 = 0,
    follow_latest: bool = true,
    rendered_frames: u64 = 0,
    exit_after_frames: ?u64 = null,
    probe: ?Probe = null,
    initial_memory_budget: usize = default_retention.budget_bytes,
    huge_pages: bool = true,
    sg_ready: bool = false,
    imgui_ready: bool = false,
    scene_ready: bool = false,
    server_ready: bool = false,
    stepper_ready: bool = false,
    inbox_ready: bool = false,
    renderer_ready: bool = false,
    picker_ready: bool = false,
    report_stepper: bool = false,
};

// Sokol's C callbacks carry no Zig context. This is the documented single
// global exception; every helper and edge below otherwise receives `*State`.
var state: State = undefined;

/// Starts the persistent viewer. Process startup owns and leak-checks `init.gpa`;
/// all viewer allocations are released by the Sokol cleanup callback.
pub fn main(init: std.process.Init) !void {
    state = .{ .gpa = init.gpa, .io = init.io, .environ = init.minimal.environ };
    configureEnvironment(init.minimal.environ);
    if (state.huge_pages and !vertex.internal.platform.shm.hugePagesConfigured()) {
        vertex.internal.platform.shm.warnIfHugeUnavailable("viewer startup");
    }
    sapp.run(.{
        .init_cb = initCallback,
        .frame_cb = frameCallback,
        .cleanup_cb = cleanupCallback,
        .event_cb = eventCallback,
        .width = 1280,
        .height = 720,
        .window_title = "vertex",
        .logger = .{ .func = slog.func },
    });
}

fn configureEnvironment(environ: std.process.Environ) void {
    if (std.process.Environ.getPosix(environ, "VERTEX_EXIT_AFTER_FRAMES")) |value| if (value.len != 0) {
        state.exit_after_frames = std.fmt.parseInt(u64, value, 10) catch |err| blk: {
            std.log.warn("ignoring invalid VERTEX_EXIT_AFTER_FRAMES: {s}", .{@errorName(err)});
            break :blk null;
        };
    };
    if (std.process.Environ.getPosix(environ, "VERTEX_PICK_PROBE")) |value| {
        state.probe = parseProbe(value) orelse blk: {
            std.log.warn("ignoring invalid VERTEX_PICK_PROBE; expected x,y unsigned framebuffer pixels", .{});
            break :blk null;
        };
    }
    if (std.process.Environ.getPosix(environ, "VERTEX_MEMORY_BUDGET_MB")) |value| if (value.len != 0) {
        const budget_mb = std.fmt.parseInt(usize, value, 10) catch |err| blk: {
            std.log.warn("ignoring invalid VERTEX_MEMORY_BUDGET_MB: {s}", .{@errorName(err)});
            break :blk null;
        };
        if (budget_mb) |mb| {
            if (mb <= std.math.maxInt(usize) / mebibyte) {
                state.initial_memory_budget = mb * mebibyte;
            } else std.log.warn("ignoring VERTEX_MEMORY_BUDGET_MB that exceeds addressable memory", .{});
        }
    };
    if (std.process.Environ.getPosix(environ, "VERTEX_SHARED_HUGE")) |value| {
        state.huge_pages = !std.mem.eql(u8, value, "0");
    }
    // This is a preference about how shared mappings are backed. Where no
    // huge-page class exists, or no shared memory at all, it is reported and
    // carried as off rather than advertising a setting the platform cannot
    // honour.
    if (!vertex.internal.platform.shm.huge_supported) state.huge_pages = false;
    if (std.process.Environ.getPosix(environ, "VERTEX_STEP_LIB")) |value| {
        state.report_stepper = value.len != 0;
    }
}

fn initCallback() callconv(.c) void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
        .buffer_pool_size = 1024,
        .view_pool_size = 1024,
    });
    state.sg_ready = true;
    simgui.setup(.{ .logger = .{ .func = slog.func } });
    state.imgui_ready = true;
    state.scene = Scene.init(state.gpa);
    state.scene.retention.budget_bytes = state.initial_memory_budget;
    state.scene_ready = true;
    state.inbox_ready = true;
    state.ingest = ingest_mod.Ingest.init(state.gpa, state.io, &state.inbox, &state.scene);
    state.input = input_mod.Input.init(&state.scene, &state.scrub, &state.follow_latest);
    state.server = server_mod.Server.init(state.gpa, state.io, state.huge_pages, &state.inbox);
    state.server_ready = true;
    state.server.start(state.environ) catch |err| {
        std.log.err("could not start vertex viewer socket: {s}", .{@errorName(err)});
        sapp.quit();
        return;
    };
    state.stepper.init(state.gpa, state.io, &state.inbox, state.environ) catch |err| {
        std.log.err("could not start vertex stepper worker: {s}", .{@errorName(err)});
        sapp.quit();
        return;
    };
    state.stepper_ready = true;
    if (!configureStepper()) return;
    state.renderer = mesh_render.Renderer.init(state.gpa);
    state.renderer_ready = true;
    state.picker = pick.Picker.init();
    state.picker_ready = true;
}

fn configureStepper() bool {
    const path = std.process.Environ.getPosix(state.environ, "VERTEX_STEP_LIB") orelse return true;
    if (path.len == 0) return true;
    state.stepper.setInputPath(path) catch |err| return stepperStartupError("use VERTEX_STEP_LIB", @errorName(err));
    state.stepper.requestLoad(path) catch |err| return stepperStartupError("queue VERTEX_STEP_LIB", @errorName(err));
    const autorun = std.process.Environ.getPosix(state.environ, "VERTEX_STEP_AUTORUN") orelse return true;
    if (std.process.Environ.getPosix(state.environ, "VERTEX_STEP_PACE")) |pace| {
        if (std.mem.eql(u8, pace, "frame")) state.stepper.setPaceMode(.frame);
        if (std.mem.eql(u8, pace, "rate")) state.stepper.setPaceMode(.rate);
        if (std.mem.eql(u8, pace, "max")) state.stepper.setPaceMode(.max);
    }
    if (std.mem.eql(u8, autorun, "1")) state.stepper.requestRun() catch |err| {
        return stepperStartupError("queue VERTEX_STEP_AUTORUN", @errorName(err));
    };
    return true;
}

fn stepperStartupError(action: []const u8, error_name: []const u8) bool {
    std.log.err("could not {s}: {s}", .{ action, error_name });
    sapp.quit();
    return false;
}

fn frameCallback() callconv(.c) void {
    if (!state.scene_ready or !state.renderer_ready or !state.stepper_ready) return finishCiFrame(&state);
    state.stepper.pollAutoReload();
    state.stepper.frameTick();
    const saw_first_geometry = state.ingest.drain();
    if (state.ingest.began_run) state.input.frame0_fitted = false;
    if (state.follow_latest) state.scrub = state.scene.frameCount() -| 1;
    if (!state.input.fitted_once and saw_first_geometry) {
        if (state.input.allStructures2d()) state.input.camera_mode = .ortho_2d;
        state.input.fitCamera();
        state.input.fitted_once = true;
    }
    if (state.ingest.frame0_complete and !state.input.frame0_fitted) {
        if (!state.input.camera_touched) state.input.fitCamera();
        state.input.frame0_fitted = true;
    }

    state.renderer.beginFrame(state.rendered_frames);
    const renderer_synced = blk: {
        state.renderer.sync(&state.scene) catch |err| {
            std.log.err("mesh renderer sync failed: {s}", .{@errorName(err)});
            break :blk false;
        };
        break :blk true;
    };
    const width_i = @max(sapp.width(), 1);
    const height_i = @max(sapp.height(), 1);
    const width: f32 = @floatFromInt(width_i);
    const height: f32 = @floatFromInt(height_i);
    const vp = state.input.viewProj(width / height);

    state.input.hover = null;
    if (renderer_synced and state.picker_ready and scene_pass.hasDisplayedGeometry(&state.scene, state.scrub)) {
        if (state.probe) |*probe| {
            if (pick.query(&state.picker, &state.renderer, &state.scene, state.scrub, vp, .{ width_i, height_i }, probe.pixel)) |hit| {
                probe.last_hit = hit;
            }
        } else if (state.input.mouse_inside and state.input.mouse_moved and !ig.igGetIO().*.WantCaptureMouse) {
            if (framebufferPixel(state.input.mouse_position, .{ width_i, height_i })) |pixel| {
                state.input.hover = pick.query(&state.picker, &state.renderer, &state.scene, state.scrub, vp, .{ width_i, height_i }, pixel);
            }
        }
    }
    if (state.input.pending_pin) {
        if (state.input.hover) |hit| state.input.selection = .{ .hit = hit, .cursor = state.input.mouse_position };
        state.input.pending_pin = false;
    }

    const pass_action: sg.PassAction = .{
        .colors = blk: {
            var colors: [sg.max_color_attachments]sg.ColorAttachmentAction = @splat(.{});
            colors[0] = .{
                .load_action = .CLEAR,
                .store_action = .STORE,
                .clear_value = .{ .r = 0.075, .g = 0.085, .b = 0.10, .a = 1 },
            };
            break :blk colors;
        },
        .depth = .{ .load_action = .CLEAR, .store_action = .DONTCARE, .clear_value = 1 },
    };
    sg.beginPass(.{ .action = pass_action, .swapchain = sglue.swapchain() });
    if (renderer_synced) scene_pass.drawScene(
        &state.renderer,
        &state.scene,
        state.scrub,
        vp,
        .{ width, height },
    ) catch |err| std.log.err("renderer draw failed: {s}", .{@errorName(err)});

    simgui.newFrame(.{
        .width = sapp.width(),
        .height = sapp.height(),
        .delta_time = sapp.frameDuration(),
        .dpi_scale = sapp.dpiScale(),
    });
    const frame_duration = sapp.frameDuration();
    if (ui.draw(
        &state.scene,
        &state.scrub,
        &state.follow_latest,
        &state.input.camera_mode,
        state.server.socketPath(),
        state.server.connected.load(.acquire),
        if (frame_duration > 0) 1.0 / frame_duration else 0,
        state.input.hover,
        &state.input.selection,
        &state.stepper,
        vp,
        .{ width, height },
        state.input.mouse_position,
    )) state.input.fitCamera();
    simgui.render();
    sg.endPass();
    sg.commit();
    _ = state.renderer.trimResidency();
    finishCiFrame(&state);
}

fn cleanupCallback() callconv(.c) void {
    var stepper_snapshot: ?stepper_mod.Snapshot = null;
    if (state.stepper_ready) {
        state.stepper.deinit();
        stepper_snapshot = state.stepper.snapshot();
        state.stepper_ready = false;
    }
    if (state.server_ready) {
        state.server.stop();
        state.server_ready = false;
    }
    if (state.report_stepper) if (stepper_snapshot) |snapshot| std.debug.print(
        "vertex-view: stepper steps={d} state={s} reloads={d} leaks={d}\n",
        .{ snapshot.steps, @tagName(snapshot.status), snapshot.reloads, snapshot.leaks },
    );
    if (state.picker_ready) {
        state.picker.deinit();
        state.picker_ready = false;
    }
    if (state.renderer_ready) {
        state.renderer.deinit();
        state.renderer_ready = false;
    }
    if (state.scene_ready) {
        printExitStats();
        state.ingest.deinit();
        state.scene.deinit();
        state.scene_ready = false;
    }
    if (state.imgui_ready) {
        simgui.shutdown();
        state.imgui_ready = false;
    }
    if (state.sg_ready) {
        sg.shutdown();
        state.sg_ready = false;
    }
    if (state.inbox_ready) {
        state.inbox.deinit(state.gpa);
        state.inbox_ready = false;
    }
}

fn printExitStats() void {
    const exit_minflt = vertex.internal.platform.stats.minorFaults();
    std.debug.print("vertex-view: structures={d} frames={d} blobs={d}\n", .{
        state.scene.structures.len,
        state.scene.frameCount(),
        state.scene.live_blobs,
    });
    std.debug.print(
        "vertex-view: ingest messages={d} bytes={d} mapped_bytes={d} apply_ms={d:.1} minflt={d} hugetlb_kb={d} huge={s} huge_available={} huge_mappings={d}\n",
        .{
            state.ingest.messages,
            state.ingest.bytes,
            state.ingest.mapped_bytes,
            @as(f64, @floatFromInt(state.ingest.apply_ns)) / 1_000_000.0,
            exit_minflt -| (state.server.firstIngestMinorFaults() orelse exit_minflt),
            vertex.internal.platform.stats.hugetlbKb(),
            if (state.huge_pages) "on" else "off",
            vertex.internal.platform.shm.hugePagesAvailable(),
            state.server.hugeMappingsReceived(),
        },
    );
    printProbe();
}

fn printProbe() void {
    const probe = state.probe orelse return;
    const hit = probe.last_hit orelse return std.debug.print("vertex-view: probe miss\n", .{});
    const structures = state.scene.structures.slice();
    const structure_i: usize = @backingInt(hit.structure);
    if (structure_i >= state.scene.structures.len) return std.debug.print("vertex-view: probe miss\n", .{});
    std.debug.print("vertex-view: probe structure={s} kind={s} element={d}\n", .{
        state.scene.string(structures.items(.name)[structure_i]),
        @tagName(hit.kind),
        hit.element,
    });
}

fn eventCallback(event_ptr: [*c]const sapp.Event) callconv(.c) void {
    const event = event_ptr.*;
    _ = simgui.handleEvent(event);
    state.input.event(event);
}

fn parseProbe(value: []const u8) ?Probe {
    var parts = std.mem.splitScalar(u8, value, ',');
    const x_text = parts.next() orelse return null;
    const y_text = parts.next() orelse return null;
    if (x_text.len == 0 or y_text.len == 0 or parts.next() != null) return null;
    const x = std.fmt.parseInt(u32, x_text, 10) catch return null;
    const y = std.fmt.parseInt(u32, y_text, 10) catch return null;
    return .{ .pixel = .{ x, y } };
}

fn framebufferPixel(position: [2]f32, viewport: [2]i32) ?[2]u32 {
    if (!std.math.isFinite(position[0]) or !std.math.isFinite(position[1])) return null;
    if (position[0] < 0 or position[1] < 0 or
        position[0] >= @as(f32, @floatFromInt(viewport[0])) or
        position[1] >= @as(f32, @floatFromInt(viewport[1]))) return null;
    return .{ @intFromFloat(@floor(position[0])), @intFromFloat(@floor(position[1])) };
}

fn finishCiFrame(s: *State) void {
    s.rendered_frames += 1;
    if (s.exit_after_frames) |limit| if (s.rendered_frames >= limit) sapp.quit();
}

test {
    _ = server_mod;
    _ = stepper_mod;
    _ = ingest_mod;
}
