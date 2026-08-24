//! Persistent Sokol viewer process and render-thread orchestration.
const std = @import("std");
const vertex = @import("vertex");
const sokol = @import("sokol");
const ig = @import("cimgui");

const server_mod = @import("server.zig");
const stepper_mod = @import("stepper.zig");
const mesh_render = @import("render/mesh.zig");
const pick = @import("pick.zig");
const ui = @import("ui.zig");

const sapp = sokol.app;
const sg = sokol.gfx;
const sglue = sokol.glue;
const simgui = sokol.imgui;
const slog = sokol.log;
const Scene = vertex.scene.Scene;
const Aabb = vertex.geometry.current.Aabb;
const mebibyte: usize = 1024 * 1024;
const default_retention: vertex.scene.Retention = .{};

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
    server: server_mod.Server = undefined,
    stepper: stepper_mod.Stepper = undefined,
    renderer: mesh_render.Renderer = undefined,
    picker: pick.Picker = undefined,
    orbit: vertex.camera.Orbit = .default,
    ortho: vertex.camera.Ortho2D = .{},
    camera_mode: ui.CameraMode = .orbit,
    scrub: u32 = 0,
    follow_latest: bool = true,
    compare_previous_run: bool = false,
    fitted_once: bool = false,
    /// Frame 0 of the current run is complete (a begin_frame(>=1) or end_run
    /// was applied); the camera refits once to the whole initial scene unless
    /// the user has already moved it. Fit-on-first-data alone depends on how
    /// many structures happened to arrive before the first draw.
    frame0_complete: bool = false,
    frame0_fitted: bool = false,
    camera_touched: bool = false,
    rendered_frames: u64 = 0,
    exit_after_frames: ?u64 = null,
    hover: ?pick.Hit = null,
    selection: ?ui.Selection = null,
    probe: ?Probe = null,
    mouse_position: [2]f32 = .{ 0, 0 },
    left_press_position: [2]f32 = .{ 0, 0 },
    mouse_inside: bool = false,
    /// Hover picking waits for a real MOUSE_MOVE: on entry the OS may report a
    /// pointer position (e.g. screen centre) before imgui has one, which would
    /// show a tooltip at the wrong place.
    mouse_moved: bool = false,
    left_pressed_in_viewport: bool = false,
    left_dragged: bool = false,
    pending_pin: bool = false,
    initial_memory_budget: usize = default_retention.budget_bytes,
    huge_pages: bool = true,
    ingest_messages: u64 = 0,
    ingest_bytes: u64 = 0,
    ingest_mapped_bytes: u64 = 0,
    ingest_ns: u128 = 0,
    mapping_cleanup: std.ArrayList(vertex.scene.Mapping) = .empty,
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
    state = .{
        .gpa = init.gpa,
        .io = init.io,
        .environ = init.minimal.environ,
    };
    if (std.process.Environ.getPosix(init.minimal.environ, "VERTEX_EXIT_AFTER_FRAMES")) |value| {
        if (value.len != 0) {
            state.exit_after_frames = std.fmt.parseInt(u64, value, 10) catch |err| blk: {
                std.log.warn("ignoring invalid VERTEX_EXIT_AFTER_FRAMES: {s}", .{@errorName(err)});
                break :blk null;
            };
        }
    }
    if (std.process.Environ.getPosix(init.minimal.environ, "VERTEX_PICK_PROBE")) |value| {
        state.probe = parseProbe(value) orelse blk: {
            std.log.warn("ignoring invalid VERTEX_PICK_PROBE; expected x,y unsigned framebuffer pixels", .{});
            break :blk null;
        };
    }
    if (std.process.Environ.getPosix(init.minimal.environ, "VERTEX_MEMORY_BUDGET_MB")) |value| {
        if (value.len != 0) {
            const budget_mb = std.fmt.parseInt(usize, value, 10) catch |err| blk: {
                std.log.warn("ignoring invalid VERTEX_MEMORY_BUDGET_MB: {s}", .{@errorName(err)});
                break :blk null;
            };
            if (budget_mb) |mb| {
                if (mb <= std.math.maxInt(usize) / mebibyte) {
                    state.initial_memory_budget = mb * mebibyte;
                } else {
                    std.log.warn("ignoring VERTEX_MEMORY_BUDGET_MB that exceeds addressable memory", .{});
                }
            }
        }
    }
    if (std.process.Environ.getPosix(init.minimal.environ, "VERTEX_SHARED_HUGE")) |value| {
        state.huge_pages = !std.mem.eql(u8, value, "0");
    }
    if (std.process.Environ.getPosix(init.minimal.environ, "VERTEX_STEP_LIB")) |value| {
        state.report_stepper = value.len != 0;
    }
    if (state.huge_pages and !vertex.platform.shm.hugePagesConfigured()) {
        vertex.platform.shm.warnIfHugeUnavailable("viewer startup");
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

fn initCallback() callconv(.c) void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
        // Retained timeline versions each own GPU buffers until residency
        // trimming (render/mesh.zig) evicts them; give the pools headroom.
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
    if (std.process.Environ.getPosix(state.environ, "VERTEX_STEP_LIB")) |path| {
        if (path.len != 0) {
            state.stepper.setInputPath(path) catch |err| {
                std.log.err("could not use VERTEX_STEP_LIB: {s}", .{@errorName(err)});
                sapp.quit();
                return;
            };
            state.stepper.requestLoad(path) catch |err| {
                std.log.err("could not queue VERTEX_STEP_LIB: {s}", .{@errorName(err)});
                sapp.quit();
                return;
            };
            if (std.process.Environ.getPosix(state.environ, "VERTEX_STEP_AUTORUN")) |autorun| {
                if (std.process.Environ.getPosix(state.environ, "VERTEX_STEP_PACE")) |pace| {
                    if (std.mem.eql(u8, pace, "frame")) state.stepper.setPaceMode(.frame);
                    if (std.mem.eql(u8, pace, "rate")) state.stepper.setPaceMode(.rate);
                    if (std.mem.eql(u8, pace, "max")) state.stepper.setPaceMode(.max);
                }
                if (std.mem.eql(u8, autorun, "1")) state.stepper.requestRun() catch |err| {
                    std.log.err("could not queue VERTEX_STEP_AUTORUN: {s}", .{@errorName(err)});
                    sapp.quit();
                    return;
                };
            }
        }
    }

    state.renderer = mesh_render.Renderer.init(state.gpa);
    state.renderer_ready = true;
    state.picker = pick.Picker.init();
    state.picker_ready = true;
    state.orbit = .default;
}

fn frameCallback() callconv(.c) void {
    if (!state.scene_ready or !state.renderer_ready or !state.stepper_ready) {
        finishCiFrame(&state);
        return;
    }

    if (state.stepper_ready) {
        state.stepper.pollAutoReload();
        state.stepper.frameTick();
    }
    const saw_first_geometry = drainInbox(&state);
    if (state.follow_latest) state.scrub = state.scene.frameCount() -| 1;
    if (!state.fitted_once and saw_first_geometry) {
        if (allStructures2d(&state.scene)) state.camera_mode = .ortho_2d;
        fitCamera(&state);
        state.fitted_once = true;
    }
    if (state.frame0_complete and !state.frame0_fitted) {
        if (!state.camera_touched) fitCamera(&state);
        state.frame0_fitted = true;
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
    const aspect = width / height;
    const vp = switch (state.camera_mode) {
        .orbit => state.orbit.viewProj(aspect),
        .ortho_2d => state.ortho.viewProj(aspect),
    };

    state.hover = null;
    if (renderer_synced and state.picker_ready and hasDisplayedGeometry(&state.scene, state.scrub)) {
        if (state.probe) |*probe| {
            if (pick.query(
                &state.picker,
                &state.renderer,
                &state.scene,
                state.scrub,
                vp,
                .{ width_i, height_i },
                probe.pixel,
            )) |hit| probe.last_hit = hit;
        } else if (state.mouse_inside and state.mouse_moved and !ig.igGetIO().*.WantCaptureMouse) {
            if (framebufferPixel(state.mouse_position, .{ width_i, height_i })) |pixel| {
                state.hover = pick.query(
                    &state.picker,
                    &state.renderer,
                    &state.scene,
                    state.scrub,
                    vp,
                    .{ width_i, height_i },
                    pixel,
                );
            }
        }
    }
    if (state.pending_pin) {
        if (state.hover) |hit| {
            state.selection = .{ .hit = hit, .cursor = state.mouse_position };
        }
        state.pending_pin = false;
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

    if (renderer_synced) drawScene(&state, vp, .{ width, height }) catch |err| {
        std.log.err("renderer draw failed: {s}", .{@errorName(err)});
    };

    simgui.newFrame(.{
        .width = sapp.width(),
        .height = sapp.height(),
        .delta_time = sapp.frameDuration(),
        .dpi_scale = sapp.dpiScale(),
    });
    const frame_duration = sapp.frameDuration();
    const fps = if (frame_duration > 0) 1.0 / frame_duration else 0;
    if (ui.draw(
        &state.scene,
        &state.scrub,
        &state.follow_latest,
        &state.compare_previous_run,
        &state.camera_mode,
        state.server.socketPath(),
        state.server.connected.load(.acquire),
        fps,
        state.hover,
        &state.selection,
        &state.stepper,
        vp,
        .{ width, height },
        state.mouse_position,
    )) fitCamera(&state);
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
    if (state.report_stepper) if (stepper_snapshot) |snapshot| {
        std.debug.print(
            "vertex-view: stepper steps={d} state={s} reloads={d} leaks={d}\n",
            .{ snapshot.steps, @tagName(snapshot.status), snapshot.reloads, snapshot.leaks },
        );
    };
    if (state.picker_ready) {
        state.picker.deinit();
        state.picker_ready = false;
    }
    if (state.renderer_ready) {
        state.renderer.deinit();
        state.renderer_ready = false;
    }
    if (state.scene_ready) {
        const exit_minflt = vertex.platform.stats.minorFaults();
        std.debug.print(
            "vertex-view: structures={d} frames={d} blobs={d}\n",
            .{ state.scene.structures.len, state.scene.frameCount(), state.scene.live_blobs },
        );
        std.debug.print(
            "vertex-view: ingest messages={d} bytes={d} mapped_bytes={d} apply_ms={d:.1} minflt={d} hugetlb_kb={d} huge={s} huge_available={} huge_mappings={d}\n",
            .{
                state.ingest_messages,
                state.ingest_bytes,
                state.ingest_mapped_bytes,
                @as(f64, @floatFromInt(state.ingest_ns)) / 1_000_000.0,
                exit_minflt -| (state.server.firstIngestMinorFaults() orelse exit_minflt),
                vertex.platform.stats.hugetlbKb(),
                if (state.huge_pages) "on" else "off",
                vertex.platform.shm.hugePagesAvailable(),
                state.server.hugeMappingsReceived(),
            },
        );
        if (state.probe) |probe| {
            if (probe.last_hit) |hit| {
                const structures = state.scene.structures.slice();
                const structure_i: usize = @backingInt(hit.structure);
                if (structure_i < state.scene.structures.len) {
                    std.debug.print(
                        "vertex-view: probe structure={s} kind={s} element={d}\n",
                        .{
                            state.scene.string(structures.items(.name)[structure_i]),
                            @tagName(hit.kind),
                            hit.element,
                        },
                    );
                } else {
                    std.debug.print("vertex-view: probe miss\n", .{});
                }
            } else {
                std.debug.print("vertex-view: probe miss\n", .{});
            }
        }
        state.scene.takeAllMappings(&state.mapping_cleanup) catch unreachable;
        for (state.mapping_cleanup.items) |mapping| disposeMapping(mapping);
        state.mapping_cleanup.deinit(state.gpa);
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

fn eventCallback(event_ptr: [*c]const sapp.Event) callconv(.c) void {
    const event = event_ptr.*;
    _ = simgui.handleEvent(event);

    const wants_mouse = isMouseEvent(event.type) and ig.igGetIO().*.WantCaptureMouse;
    if (isMouseEvent(event.type)) trackMouse(&state, event, wants_mouse);
    if (wants_mouse) return;
    switch (event.type) {
        .MOUSE_MOVE => handleMouseMove(&state, event),
        .MOUSE_SCROLL => handleScroll(&state, event),
        .KEY_DOWN => if (!event.key_repeat) handleKey(&state, event.key_code),
        else => {},
    }
}

fn trackMouse(s: *State, event: sapp.Event, wants_mouse: bool) void {
    switch (event.type) {
        .MOUSE_ENTER => {
            s.mouse_inside = true;
            s.mouse_position = .{ event.mouse_x, event.mouse_y };
        },
        .MOUSE_LEAVE => {
            s.mouse_inside = false;
            s.left_pressed_in_viewport = false;
        },
        .MOUSE_MOVE => {
            s.mouse_moved = true;
            s.mouse_position = .{ event.mouse_x, event.mouse_y };
            if (s.left_pressed_in_viewport) {
                const dx = event.mouse_x - s.left_press_position[0];
                const dy = event.mouse_y - s.left_press_position[1];
                if (dx * dx + dy * dy > 9) s.left_dragged = true;
            }
        },
        .MOUSE_DOWN => if (event.mouse_button == .LEFT) {
            s.mouse_position = .{ event.mouse_x, event.mouse_y };
            s.left_pressed_in_viewport = s.mouse_inside and !wants_mouse;
            s.left_press_position = s.mouse_position;
            s.left_dragged = false;
        },
        .MOUSE_UP => if (event.mouse_button == .LEFT) {
            s.mouse_position = .{ event.mouse_x, event.mouse_y };
            if (s.left_pressed_in_viewport and !s.left_dragged and s.mouse_inside and !wants_mouse) {
                s.pending_pin = true;
            }
            s.left_pressed_in_viewport = false;
            s.left_dragged = false;
        },
        else => {},
    }
}

fn drainInbox(s: *State) bool {
    var saw_geometry = false;
    const items = s.inbox.drain(s.io);
    for (items) |item| {
        s.ingest_messages +|= 1;
        s.ingest_bytes +|= @intCast(item.payload.len);
        var registered: usize = 0;
        defer {
            s.scene.releaseUnreferencedMappings();
            drainReleasedMappings(s);
            disposeItemMappingsFrom(item, registered);
            s.gpa.free(item.payload);
        }
        const message: ?vertex.protocol.Message = blk: {
            const started = std.Io.Clock.awake.now(s.io);
            defer {
                const elapsed: i96 = started.durationTo(std.Io.Clock.awake.now(s.io)).toNanoseconds();
                if (elapsed > 0) s.ingest_ns +|= @intCast(elapsed);
            }
            s.mapping_cleanup.ensureTotalCapacity(s.gpa, s.scene.mappings.len + item.fd_count) catch |err| {
                std.log.warn("discarding viewer message after mapping cleanup reserve failed: {s}", .{@errorName(err)});
                break :blk null;
            };
            var mappings: [7][]align(64) const u8 = undefined;
            while (registered < item.fd_count) : (registered += 1) {
                const mapping = item.mappings[registered] orelse {
                    std.log.warn("discarding viewer message with a missing fd mapping", .{});
                    break :blk null;
                };
                const mapping_index = s.scene.registerMapping(@alignCast(mapping), item.fds[registered]) catch |err| {
                    std.log.warn("discarding viewer message after mapping registration failed: {s}", .{@errorName(err)});
                    break :blk null;
                };
                mappings[registered] = s.scene.mappingBytes(mapping_index);
            }
            const decoded = vertex.protocol.decode(item.header, item.payload, mappings[0..registered]) catch |err| {
                std.log.warn("discarding invalid viewer message: {s}", .{@errorName(err)});
                break :blk null;
            };
            s.ingest_mapped_bytes +|= decodedMappedBytes(decoded, item);
            switch (decoded) {
                .begin_run => {
                    s.frame0_complete = false;
                    s.frame0_fitted = false;
                },
                .begin_frame => |begin| if (begin.index >= 1) {
                    s.frame0_complete = true;
                },
                .end_run => s.frame0_complete = true,
                else => {},
            }
            s.scene.apply(decoded) catch |err| {
                std.log.warn("discarding inapplicable viewer message: {s}", .{@errorName(err)});
                break :blk null;
            };
            break :blk decoded;
        };
        if (message) |applied| {
            switch (applied) {
                .mesh, .points, .lines => saw_geometry = true,
                else => {},
            }
        }
    }
    s.inbox.consume();
    return saw_geometry;
}

fn decodedMappedBytes(message: vertex.protocol.Message, item: server_mod.Inbox.Item) u64 {
    var total: u64 = 0;
    switch (message) {
        .mesh => |value| {
            total +|= mappedSectionBytes(value.positions.bytes(), item);
            total +|= mappedSectionBytes(std.mem.sliceAsBytes(value.faces), item);
        },
        .mesh_positions => |value| total +|= mappedSectionBytes(value.positions.bytes(), item),
        .points => |value| total +|= mappedSectionBytes(value.positions.bytes(), item),
        .lines => |value| {
            total +|= mappedSectionBytes(value.positions.bytes(), item);
            total +|= mappedSectionBytes(std.mem.sliceAsBytes(value.segments), item);
        },
        .scalar_quantity => |value| total +|= mappedSectionBytes(std.mem.sliceAsBytes(value.values), item),
        .vector_quantity => |value| total +|= mappedSectionBytes(value.vectors.bytes(), item),
        else => {},
    }
    return total;
}

fn mappedSectionBytes(section: []const u8, item: server_mod.Inbox.Item) u64 {
    const section_start = @intFromPtr(section.ptr);
    const section_end = std.math.add(usize, section_start, section.len) catch return 0;
    for (item.mappings[0..item.fd_count]) |optional_mapping| {
        const mapping = optional_mapping orelse continue;
        const mapping_start = @intFromPtr(mapping.ptr);
        const mapping_end = mapping_start + mapping.len;
        if (section_start >= mapping_start and section_end <= mapping_end) return @intCast(section.len);
    }
    return 0;
}

fn drainReleasedMappings(s: *State) void {
    while (s.scene.released_mappings.items.len != 0) {
        const mapping_index = s.scene.released_mappings.items[0];
        const mapping = s.scene.mappingValue(mapping_index);
        disposeMapping(mapping);
        s.scene.forgetMapping(mapping_index);
    }
}

fn disposeItemMappingsFrom(item: server_mod.Inbox.Item, start: usize) void {
    for (item.mappings[start..item.fd_count], item.fds[start..item.fd_count]) |mapping, fd| {
        if (mapping) |bytes| vertex.platform.shm.unmap(.{ .handle = fd, .map = bytes, .huge = false });
        vertex.platform.shm.close(fd);
    }
}

fn disposeMapping(mapping: vertex.scene.Mapping) void {
    vertex.platform.shm.unmap(.{
        .handle = mapping.fd,
        .map = @alignCast(@constCast(mapping.bytes)),
        .huge = false,
    });
    vertex.platform.shm.close(mapping.fd);
}

fn drawScene(s: *State, vp: vertex.camera.Mat4, viewport: [2]f32) std.mem.Allocator.Error!void {
    const structures = s.scene.structures.slice();
    const ui_states = structures.items(.ui);
    const kinds = structures.items(.kind);
    const versions = structures.items(.versions);

    // Solid meshes establish depth before every overlay and primitive pass.
    for (ui_states, kinds, versions, 0..) |ui_state, kind, version_list, i| {
        if (!ui_state.visible or kind != .mesh) continue;
        const structure_index: vertex.scene.StructureIndex = @fromBackingInt(@intCast(i));
        const version_index = s.scene.versionAt(structure_index, s.scrub) orelse continue;
        std.debug.assert(version_index < version_list.items.len);
        try s.renderer.draw(&s.scene, structure_index, version_index, vp, .{ 0.72, 0.78, 0.86, 1.0 });
    }
    // Previous-run ghosts are depth-tested overlays: meshes use only the
    // biased wire cache, while lines and smaller points use their plain paths.
    if (s.compare_previous_run and s.scene.run > 1) {
        const previous_run = s.scene.run - 1;
        for (ui_states, kinds, versions, 0..) |ui_state, kind, version_list, i| {
            if (!ui_state.visible or !ui_state.ghost) continue;
            const structure_index: vertex.scene.StructureIndex = @fromBackingInt(@intCast(i));
            const version_index = s.scene.versionAtRun(structure_index, previous_run, s.scrub) orelse continue;
            std.debug.assert(version_index < version_list.items.len);
            switch (kind) {
                .mesh => try s.renderer.drawGhostWireframe(
                    &s.scene,
                    structure_index,
                    version_index,
                    vp,
                    viewport,
                    .{ 0.92, 0.18, 0.72, 1.0 },
                ),
                .lines => try s.renderer.drawGhostLines(
                    &s.scene,
                    structure_index,
                    version_index,
                    vp,
                    viewport,
                    .{ 0.55, 0.14, 0.43, 1.0 },
                ),
                .points => s.renderer.drawGhostPoints(
                    &s.scene,
                    structure_index,
                    version_index,
                    vp,
                    viewport,
                    .{ 0.55, 0.14, 0.43, 1.0 },
                ),
            }
        }
    }
    for (ui_states, kinds, versions, 0..) |ui_state, kind, version_list, i| {
        if (!ui_state.visible or kind != .mesh or !ui_state.wireframe) continue;
        const structure_index: vertex.scene.StructureIndex = @fromBackingInt(@intCast(i));
        const version_index = s.scene.versionAt(structure_index, s.scrub) orelse continue;
        std.debug.assert(version_index < version_list.items.len);
        try s.renderer.drawWireframe(
            &s.scene,
            structure_index,
            version_index,
            vp,
            viewport,
            .{ 0.12, 0.15, 0.20, 1.0 },
        );
    }
    for (ui_states, kinds, versions, 0..) |ui_state, kind, version_list, i| {
        if (!ui_state.visible or kind != .lines) continue;
        const structure_index: vertex.scene.StructureIndex = @fromBackingInt(@intCast(i));
        const version_index = s.scene.versionAt(structure_index, s.scrub) orelse continue;
        std.debug.assert(version_index < version_list.items.len);
        try s.renderer.drawLines(
            &s.scene,
            structure_index,
            version_index,
            vp,
            viewport,
            .{ 0.96, 0.55, 0.18, 1.0 },
        );
    }
    for (ui_states, versions, 0..) |ui_state, version_list, i| {
        if (!ui_state.visible) continue;
        const structure_index: vertex.scene.StructureIndex = @fromBackingInt(@intCast(i));
        const version_index = s.scene.versionAt(structure_index, s.scrub) orelse continue;
        std.debug.assert(version_index < version_list.items.len);
        try s.renderer.drawVectors(
            &s.scene,
            structure_index,
            version_index,
            vp,
            .{ 0.96, 0.28, 0.22, 1.0 },
        );
    }
    for (ui_states, kinds, versions, 0..) |ui_state, kind, version_list, i| {
        if (!ui_state.visible or kind != .points) continue;
        const structure_index: vertex.scene.StructureIndex = @fromBackingInt(@intCast(i));
        const version_index = s.scene.versionAt(structure_index, s.scrub) orelse continue;
        std.debug.assert(version_index < version_list.items.len);
        try s.renderer.drawPoints(
            &s.scene,
            structure_index,
            version_index,
            vp,
            viewport,
            .{ 0.25, 0.82, 0.58, 1.0 },
        );
    }
}

fn allStructures2d(scene: *const Scene) bool {
    if (scene.structures.len == 0) return false;
    const structures = scene.structures.slice();
    for (structures.items(.dim)) |dim| {
        if (dim != .d2) return false;
    }
    return true;
}

fn visibleBounds(s: *const State) Aabb {
    var result: Aabb = .empty;
    const structures = s.scene.structures.slice();
    const ui_states = structures.items(.ui);
    for (ui_states, 0..) |ui_state, i| {
        if (!ui_state.visible) continue;
        const structure_index: vertex.scene.StructureIndex = @fromBackingInt(@intCast(i));
        const version_index = s.scene.versionAt(structure_index, s.scrub) orelse continue;
        const versions = structures.items(.versions)[i].items;
        const bounds = vertex.geometry.current.bounds(s.scene.positionsOf(versions[version_index]));
        if (bounds.isEmpty()) continue;
        result.min = result.min.min(bounds.min);
        result.max = result.max.max(bounds.max);
    }
    return result;
}

fn fitCamera(s: *State) void {
    const bounds = visibleBounds(s);
    switch (s.camera_mode) {
        .orbit => s.orbit.fit(bounds),
        .ortho_2d => s.ortho.fit(bounds),
    }
}

fn handleMouseMove(s: *State, event: sapp.Event) void {
    const left = event.modifiers & sapp.modifier_lmb != 0;
    const middle = event.modifiers & sapp.modifier_mmb != 0;
    const shift = event.modifiers & sapp.modifier_shift != 0;
    const pan = middle or (shift and left);
    const viewport_height = @max(sapp.heightf(), 1);
    switch (s.camera_mode) {
        .orbit => {
            if (pan) {
                s.camera_touched = true;
                s.orbit.pan(event.mouse_dx, event.mouse_dy, viewport_height);
            } else if (left) {
                s.camera_touched = true;
                s.orbit.rotate(-event.mouse_dx * 0.01, -event.mouse_dy * 0.01);
            }
        },
        .ortho_2d => if (pan) {
            s.camera_touched = true;
            s.ortho.pan(event.mouse_dx, event.mouse_dy, viewport_height);
        },
    }
}

fn handleScroll(s: *State, event: sapp.Event) void {
    switch (s.camera_mode) {
        .orbit => {
            s.camera_touched = true;
            s.orbit.dolly(event.scroll_y);
        },
        .ortho_2d => {
            const width = @max(sapp.widthf(), 1);
            const height = @max(sapp.heightf(), 1);
            const cursor_ndc = [2]f32{
                2 * event.mouse_x / width - 1,
                1 - 2 * event.mouse_y / height,
            };
            s.camera_touched = true;
            s.ortho.zoomAt(@exp(-event.scroll_y * 0.1), cursor_ndc);
        },
    }
}

fn handleKey(s: *State, key: sapp.Keycode) void {
    switch (key) {
        .F => fitCamera(s),
        ._2 => s.camera_mode = .ortho_2d,
        ._3 => s.camera_mode = .orbit,
        .SPACE => s.follow_latest = !s.follow_latest,
        .LEFT => {
            s.follow_latest = false;
            s.scrub -|= 1;
        },
        .RIGHT => {
            s.follow_latest = false;
            s.scrub = @min(s.scrub +| 1, s.scene.frameCount() -| 1);
        },
        else => {},
    }
}

fn isMouseEvent(event_type: sapp.EventType) bool {
    return switch (event_type) {
        .MOUSE_DOWN, .MOUSE_UP, .MOUSE_SCROLL, .MOUSE_MOVE, .MOUSE_ENTER, .MOUSE_LEAVE => true,
        else => false,
    };
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
    return .{
        @intFromFloat(@floor(position[0])),
        @intFromFloat(@floor(position[1])),
    };
}

fn hasDisplayedGeometry(scene: *const Scene, scrub: u32) bool {
    const structures = scene.structures.slice();
    for (structures.items(.versions), 0..) |_, i| {
        const structure_index: vertex.scene.StructureIndex = @fromBackingInt(@intCast(i));
        if (scene.versionAt(structure_index, scrub) != null) return true;
    }
    return false;
}

fn finishCiFrame(s: *State) void {
    s.rendered_frames += 1;
    if (s.exit_after_frames) |limit| {
        if (s.rendered_frames >= limit) sapp.quit();
    }
}

test {
    _ = server_mod;
    _ = stepper_mod;
}
