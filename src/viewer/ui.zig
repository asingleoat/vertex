//! Plain Dear ImGui panels for scene state and viewer controls.
const std = @import("std");
const vertex = @import("vertex");
const ig = @import("cimgui");

const pick = @import("pick.zig");
const stepper_mod = @import("stepper.zig");
const Mat4 = vertex.camera.Mat4;
const Positions = vertex.layout.Positions;
const Scene = vertex.scene.Scene;
const StructureIndex = vertex.scene.StructureIndex;

/// Camera mode selected by UI and keyboard controls. The value owns no memory.
pub const CameraMode = enum { orbit, ortho_2d };

/// Persistent pinned hit plus its original top-left framebuffer cursor. The
/// value owns no memory; inspector details are resolved against each displayed version.
pub const Selection = struct {
    hit: pick.Hit,
    cursor: [2]f32,
};

/// Draws all viewer panels and mutates only viewer UI state. It allocates nothing,
/// borrows every argument for the call, and returns whether Fit was pressed.
pub fn draw(
    scene: *Scene,
    scrub: *u32,
    follow_latest: *bool,
    compare_previous_run: *bool,
    camera_mode: *CameraMode,
    socket_path: []const u8,
    connected: bool,
    fps: f64,
    hover: ?pick.Hit,
    selection: *?Selection,
    stepper: *stepper_mod.Stepper,
    view_proj: Mat4,
    viewport: [2]f32,
    cursor: [2]f32,
) bool {
    if (selection.*) |selected| {
        if (!hitValid(scene, scrub.*, selected.hit)) selection.* = null;
    }
    drawStructures(scene, scrub.*, follow_latest.*, selection, view_proj, viewport);
    const fit_requested = drawTimeline(
        scene,
        scrub,
        follow_latest,
        compare_previous_run,
        camera_mode,
        socket_path,
        connected,
        fps,
    );
    drawLog(scene);
    drawStepper(stepper);
    drawHoverTooltip(scene, scrub.*, hover, view_proj, viewport, cursor);
    return fit_requested;
}

fn drawStepper(stepper: *stepper_mod.Stepper) void {
    if (ig.igBegin("Stepper", null, ig.ImGuiWindowFlags_None)) {
        const input = stepper.inputBuffer();
        _ = ig.igInputText("Library", input.ptr, input.len, ig.ImGuiInputTextFlags_None);

        if (ig.igButton("Load...")) stepper.requestLoad(stepper.inputPath()) catch |err| {
            std.log.warn("could not queue stepper load: {s}", .{@errorName(err)});
        };
        ig.igSameLine();
        if (ig.igButton("Reload")) stepper.requestReload() catch |err| {
            std.log.warn("could not queue stepper reload: {s}", .{@errorName(err)});
        };
        ig.igSameLine();
        if (ig.igButton("Unload")) stepper.requestUnload() catch |err| {
            std.log.warn("could not queue stepper unload: {s}", .{@errorName(err)});
        };

        if (ig.igButton("Step")) stepper.requestStep(1) catch |err| {
            std.log.warn("could not queue stepper step: {s}", .{@errorName(err)});
        };
        ig.igSameLine();
        if (ig.igButton("Run")) stepper.requestRun() catch |err| {
            std.log.warn("could not queue stepper run: {s}", .{@errorName(err)});
        };
        ig.igSameLine();
        if (ig.igButton("Pause")) stepper.requestPause() catch |err| {
            std.log.warn("could not queue stepper pause: {s}", .{@errorName(err)});
        };
        ig.igSameLine();
        if (ig.igButton("Reset")) stepper.requestReset() catch |err| {
            std.log.warn("could not queue stepper reset: {s}", .{@errorName(err)});
        };

        const pace = stepper.paceMode();
        ig.igText("Run pace:");
        ig.igSameLine();
        if (ig.igRadioButton("Frame", pace == .frame)) stepper.setPaceMode(.frame);
        ig.igSameLine();
        if (ig.igRadioButton("Rate", pace == .rate)) stepper.setPaceMode(.rate);
        ig.igSameLine();
        if (ig.igRadioButton("Max", pace == .max)) stepper.setPaceMode(.max);
        if (ig.igIsItemHovered(0)) ig.igSetTooltip("Frame: one step per rendered frame. Rate: steps/s below. Max: free-wheel until the sketch finishes, errors, or Pause; scrub the timeline afterwards.");
        if (pace == .rate) {
            var rate = stepper.maxStepsPerSecond();
            if (ig.igDragFloatEx(
                "Steps/s",
                &rate,
                1,
                1,
                10000,
                "%.0f",
                ig.ImGuiSliderFlags_AlwaysClamp,
            )) stepper.setMaxStepsPerSecond(rate);
        }
        _ = ig.igCheckbox("Auto-reload", stepper.autoReloadPtr());

        const snapshot = stepper.snapshot();
        var buffer: [256]u8 = undefined;
        const status = std.fmt.bufPrint(
            &buffer,
            "state={s}  steps={d}  last={d:.3} ms  generation={d}  ABI={s}",
            .{
                @tagName(snapshot.status),
                snapshot.steps,
                @as(f64, @floatFromInt(snapshot.last_step_ns)) / 1_000_000.0,
                snapshot.generation,
                if (snapshot.abi_ok) "ok" else "not checked",
            },
        ) catch "stepper status unavailable";
        text(status);
        text("In-process mode (?)");
        if (ig.igBeginItemTooltip()) {
            text("Crash isolation is lost: a sketch crash also crashes the viewer.");
            ig.igEndTooltip();
        }
    }
    ig.igEnd();
}

fn drawStructures(
    scene: *Scene,
    scrub: u32,
    follow_latest: bool,
    selection: *?Selection,
    view_proj: Mat4,
    viewport: [2]f32,
) void {
    if (ig.igBegin("Structures", null, ig.ImGuiWindowFlags_None)) {
        var structures = scene.structures.slice();
        const names = structures.items(.name);
        const kinds = structures.items(.kind);
        const ui_states = structures.items(.ui);
        const stale = structures.items(.stale);
        const versions = structures.items(.versions);
        for (names, kinds, ui_states, stale, versions, 0..) |name_index, kind, *ui_state, is_stale, version_list, i| {
            ig.igPushIDInt(@intCast(i));
            defer ig.igPopID();
            const name = scene.string(name_index);
            _ = ig.igCheckbox(name.ptr, &ui_state.visible);
            ig.igSameLine();

            const structure_index: StructureIndex = @fromBackingInt(@intCast(i));
            var vertex_count: u32 = 0;
            var face_count: usize = 0;
            var segment_count: usize = 0;
            var displayed_version: ?vertex.scene.Version = null;
            if (scene.versionAt(structure_index, scrub)) |version_index| {
                const version = version_list.items[version_index];
                displayed_version = version;
                vertex_count = scene.positionsOf(version).len();
                if (kind == .mesh) face_count = scene.facesOf(version).len;
                if (kind == .lines) segment_count = scene.segmentsOf(version).len;
            }

            var buffer: [256]u8 = undefined;
            var frame_buffer: [64]u8 = undefined;
            const frame_note = if (!follow_latest and !scene.hasExactVersion(structure_index, scrub))
                if (displayed_version) |version|
                    std.fmt.bufPrint(&frame_buffer, " (showing frame {d})", .{version.frame}) catch ""
                else
                    ""
            else
                "";
            const detail = switch (kind) {
                .mesh => std.fmt.bufPrint(
                    &buffer,
                    "mesh  vertices={d} faces={d}{s}{s}",
                    .{ vertex_count, face_count, if (is_stale) "  [stale]" else "", frame_note },
                ),
                .points => std.fmt.bufPrint(
                    &buffer,
                    "points  vertices={d}{s}{s}",
                    .{ vertex_count, if (is_stale) "  [stale]" else "", frame_note },
                ),
                .lines => std.fmt.bufPrint(
                    &buffer,
                    "lines  vertices={d} segments={d}{s}{s}",
                    .{ vertex_count, segment_count, if (is_stale) "  [stale]" else "", frame_note },
                ),
            } catch "structure summary too long";
            text(detail);

            ig.igIndent();
            if (displayed_version) |version| {
                drawQuantityControls(scene, structure_index, version, ui_state);
            }
            switch (kind) {
                .mesh => {
                    _ = ig.igCheckbox("Wireframe", &ui_state.wireframe);
                    _ = ig.igSliderFloat("Line width", &ui_state.line_width, 0.5, 8.0);
                },
                .points => _ = ig.igSliderFloat("Point size", &ui_state.point_size, 1.0, 16.0),
                .lines => _ = ig.igSliderFloat("Line width", &ui_state.line_width, 0.5, 8.0),
            }
            _ = ig.igCheckbox("Ghost", &ui_state.ghost);
            ig.igUnindent();
            ig.igSeparator();
        }
        drawSelection(scene, scrub, selection, view_proj, viewport);
    }
    ig.igEnd();
}

fn drawQuantityControls(
    scene: *const Scene,
    structure_index: StructureIndex,
    version: vertex.scene.Version,
    ui_state: *vertex.scene.UiState,
) void {
    const quantities = scene.quantities(structure_index, version);
    var active: ?vertex.scene.QuantityRef = null;
    for (quantities) |quantity| {
        if (quantity.name == ui_state.active_quantity) {
            active = quantity;
            break;
        }
    }

    var preview_buffer: [320]u8 = undefined;
    const preview = if (active) |quantity|
        quantityLabel(scene, quantity, &preview_buffer)
    else
        "(none)";
    if (ig.igBeginCombo("Quantity", preview.ptr, ig.ImGuiComboFlags_None)) {
        if (ig.igSelectableEx(
            "(none)",
            ui_state.active_quantity == .none,
            ig.ImGuiSelectableFlags_None,
            .{ .x = 0, .y = 0 },
        )) {
            ui_state.active_quantity = .none;
            active = null;
        }
        for (quantities) |quantity| {
            var label_buffer: [320]u8 = undefined;
            const label = quantityLabel(scene, quantity, &label_buffer);
            const selected = quantity.name == ui_state.active_quantity;
            if (ig.igSelectableEx(label.ptr, selected, ig.ImGuiSelectableFlags_None, .{ .x = 0, .y = 0 })) {
                ui_state.active_quantity = quantity.name;
                active = quantity;
            }
            if (selected) ig.igSetItemDefaultFocus();
        }
        ig.igEndCombo();
    }

    const scalar_active = if (active) |quantity| quantity.kind == .scalar else false;
    ig.igBeginDisabled(!scalar_active);
    const colormap_names = [_][*:0]const u8{ "viridis", "turbo", "coolwarm", "plasma" };
    if (ig.igBeginCombo("Colormap", colormap_names[@backingInt(ui_state.colormap)], ig.ImGuiComboFlags_None)) {
        inline for (std.enums.values(vertex.colormap.Colormap), 0..) |cm, cm_i| {
            const selected = cm == ui_state.colormap;
            if (ig.igSelectableEx(
                colormap_names[cm_i],
                selected,
                ig.ImGuiSelectableFlags_None,
                .{ .x = 0, .y = 0 },
            )) ui_state.colormap = cm;
            if (selected) ig.igSetItemDefaultFocus();
        }
        ig.igEndCombo();
    }
    ig.igEndDisabled();

    if (active) |quantity| switch (quantity.kind) {
        .scalar => {
            const values = std.mem.bytesAsSlice(f32, scene.blobBytes(quantity.blob));
            const value_range = vertex.colormap.range(values);
            var buffer: [128]u8 = undefined;
            const readout = std.fmt.bufPrint(
                &buffer,
                "range [{d:.5}, {d:.5}]",
                .{ value_range[0], value_range[1] },
            ) catch "range unavailable";
            text(readout);
        },
        .vector => _ = ig.igSliderFloatEx(
            "Vector scale",
            &ui_state.vector_scale,
            0.1,
            10.0,
            "%.3f",
            ig.ImGuiSliderFlags_Logarithmic,
        ),
    };
}

fn quantityLabel(
    scene: *const Scene,
    quantity: vertex.scene.QuantityRef,
    buffer: *[320]u8,
) [:0]const u8 {
    const name = scene.string(quantity.name);
    const available = buffer[0 .. buffer.len - 1];
    const label = std.fmt.bufPrint(available, "{s}", .{name}) catch {
        const fallback = "quantity name too long";
        @memcpy(buffer[0..fallback.len], fallback);
        buffer[fallback.len] = 0;
        return buffer[0..fallback.len :0];
    };
    buffer[label.len] = 0;
    return buffer[0..label.len :0];
}

fn drawSelection(
    scene: *const Scene,
    scrub: u32,
    selection: *?Selection,
    view_proj: Mat4,
    viewport: [2]f32,
) void {
    const selected = selection.* orelse return;
    text("Selection");
    ig.igSameLine();
    if (ig.igSmallButton("x##selection")) {
        selection.* = null;
        return;
    }
    drawHitDetails(scene, scrub, selected.hit, view_proj, viewport, selected.cursor);
    ig.igSeparator();
}

fn drawHoverTooltip(
    scene: *const Scene,
    scrub: u32,
    hover: ?pick.Hit,
    view_proj: Mat4,
    viewport: [2]f32,
    cursor: [2]f32,
) void {
    const hit = hover orelse return;
    if (!ig.igBeginTooltip()) return;
    defer ig.igEndTooltip();
    drawHitDetails(scene, scrub, hit, view_proj, viewport, cursor);
}

fn drawHitDetails(
    scene: *const Scene,
    scrub: u32,
    hit: pick.Hit,
    view_proj: Mat4,
    viewport: [2]f32,
    cursor: [2]f32,
) void {
    const structure_i: usize = @backingInt(hit.structure);
    const structures = scene.structures.slice();
    const version_index = scene.versionAt(hit.structure, scrub) orelse return;
    const version = structures.items(.versions)[structure_i].items[version_index];

    var line_buffer: [384]u8 = undefined;
    const structure_line = std.fmt.bufPrint(
        &line_buffer,
        "{s}",
        .{scene.string(structures.items(.name)[structure_i])},
    ) catch "structure name too long";
    text(structure_line);
    const element_line = std.fmt.bufPrint(
        &line_buffer,
        "{s} {d}",
        .{ @tagName(hit.kind), hit.element },
    ) catch "element unavailable";
    text(element_line);

    var nearest: ?u32 = null;
    if (hit.kind == .face) {
        const faces = scene.facesOf(version);
        const positions = scene.positionsOf(version);
        const face = faces[hit.element];
        nearest = nearestVertexOfFace(positions, face, view_proj, viewport, cursor);
        const vertex_index = nearest.?;
        const position = positions.get(vertex_index);
        const vertex_line = std.fmt.bufPrint(
            &line_buffer,
            "nearest vertex {d}: ({d:.6}, {d:.6}, {d:.6})",
            .{ vertex_index, position.x, position.y, position.z },
        ) catch "nearest vertex unavailable";
        text(vertex_line);
    }

    const quantities = scene.quantities(hit.structure, version);
    if (quantities.len != 0) ig.igSeparator();
    for (quantities) |quantity| {
        const name = scene.string(quantity.name);
        const value_index = quantityValueIndex(hit, nearest, quantity) orelse {
            const unavailable = std.fmt.bufPrint(&line_buffer, "{s}: unavailable", .{name}) catch
                "quantity unavailable";
            text(unavailable);
            continue;
        };
        if (value_index >= quantity.count) {
            const unavailable = std.fmt.bufPrint(&line_buffer, "{s}: unavailable", .{name}) catch
                "quantity unavailable";
            text(unavailable);
            continue;
        }
        switch (quantity.kind) {
            .scalar => {
                const values = std.mem.bytesAsSlice(f32, scene.blobBytes(quantity.blob));
                const value_line = std.fmt.bufPrint(
                    &line_buffer,
                    "{s}: {d:.6}",
                    .{ name, values[value_index] },
                ) catch "scalar quantity unavailable";
                text(value_line);
            },
            .vector => {
                const vectors = Positions.Const.fromBytes(scene.blobBytes(quantity.blob));
                const value = vectors.get(value_index);
                const value_line = std.fmt.bufPrint(
                    &line_buffer,
                    "{s}: ({d:.6}, {d:.6}, {d:.6})",
                    .{ name, value.x, value.y, value.z },
                ) catch "vector quantity unavailable";
                text(value_line);
            },
        }
    }
}

fn quantityValueIndex(
    hit: pick.Hit,
    nearest: ?u32,
    quantity: vertex.scene.QuantityRef,
) ?u32 {
    return switch (hit.kind) {
        .face => switch (quantity.target) {
            .face => hit.element,
            .vertex, .point => nearest,
        },
        .point => switch (quantity.target) {
            .face => null,
            .vertex, .point => hit.element,
        },
        // The protocol has no segment-target quantity. Retained vertex/point
        // quantities are indexed by segment only when that index is in range.
        .segment => switch (quantity.target) {
            .face => null,
            .vertex, .point => hit.element,
        },
    };
}

fn hitValid(scene: *const Scene, scrub: u32, hit: pick.Hit) bool {
    const structure_i: usize = @backingInt(hit.structure);
    if (structure_i >= scene.structures.len) return false;
    const structures = scene.structures.slice();
    const expected_kind: pick.ElementKind = switch (structures.items(.kind)[structure_i]) {
        .mesh => .face,
        .points => .point,
        .lines => .segment,
    };
    if (hit.kind != expected_kind) return false;
    const version_index = scene.versionAt(hit.structure, scrub) orelse return false;
    const version = structures.items(.versions)[structure_i].items[version_index];
    const count: usize = switch (hit.kind) {
        .face => scene.facesOf(version).len,
        .point => scene.positionsOf(version).len(),
        .segment => scene.segmentsOf(version).len,
    };
    return @as(usize, hit.element) < count;
}

/// Returns the face vertex whose current top-left-origin framebuffer projection
/// is closest to `cursor`. All views are borrowed and the operation never allocates.
pub fn nearestVertexOfFace(
    positions: Positions.Const,
    face: [3]u32,
    view_proj: Mat4,
    viewport: [2]f32,
    cursor: [2]f32,
) u32 {
    var nearest = face[0];
    var nearest_distance = std.math.inf(f32);
    for (face) |vertex_index| {
        std.debug.assert(vertex_index < positions.len());
        const ndc = view_proj.transformPoint(positions.get(vertex_index));
        const screen = [2]f32{
            (ndc.x + 1) * 0.5 * viewport[0],
            (1 - ndc.y) * 0.5 * viewport[1],
        };
        const dx = screen[0] - cursor[0];
        const dy = screen[1] - cursor[1];
        const distance = dx * dx + dy * dy;
        if (distance < nearest_distance) {
            nearest = vertex_index;
            nearest_distance = distance;
        }
    }
    return nearest;
}

fn drawTimeline(
    scene: *Scene,
    scrub: *u32,
    follow_latest: *bool,
    compare_previous_run: *bool,
    camera_mode: *CameraMode,
    socket_path: []const u8,
    connected: bool,
    fps: f64,
) bool {
    var fit_requested = false;
    if (ig.igBegin("Timeline", null, ig.ImGuiWindowFlags_None)) {
        const frame_count = drawTimelineFrames(scene, scrub, follow_latest, compare_previous_run);
        drawTimelineRetention(scene);
        fit_requested = drawTimelineCamera(camera_mode);
        drawTimelineStatus(scene, socket_path, connected, fps, frame_count);
    }
    ig.igEnd();
    return fit_requested;
}

fn drawTimelineFrames(
    scene: *const Scene,
    scrub: *u32,
    follow_latest: *bool,
    compare_previous_run: *bool,
) u32 {
    _ = ig.igCheckbox("Follow latest", follow_latest);
    _ = ig.igCheckbox("Compare previous run", compare_previous_run);
    const frame_count = scene.frameCount();
    const maximum_u32 = frame_count -| 1;
    const maximum: c_int = @intCast(@min(maximum_u32, @as(u32, std.math.maxInt(c_int))));
    var selected: c_int = @intCast(@min(scrub.*, @as(u32, @intCast(maximum))));
    if (ig.igSliderInt("Frame", &selected, 0, maximum)) {
        scrub.* = @intCast(selected);
        follow_latest.* = false;
    }
    var frame_buffer: [128]u8 = undefined;
    const kept_line = std.fmt.bufPrint(
        &frame_buffer,
        "kept {d}/{d} frames",
        .{ keptFrameCount(scene), frame_count },
    ) catch "frame retention unavailable";
    text(kept_line);
    if (scene.run > 1) {
        const previous_line = std.fmt.bufPrint(
            &frame_buffer,
            "prev run: {d} frames",
            .{scene.frameCountOfRun(scene.run - 1)},
        ) catch "previous run frame count unavailable";
        text(previous_line);
    }
    return frame_count;
}

fn drawTimelineRetention(scene: *Scene) void {
    const mebibyte: f32 = 1024 * 1024;
    const old_budget = scene.retention.budget_bytes;
    var budget_mb = @as(f32, @floatFromInt(old_budget)) / mebibyte;
    if (ig.igDragFloatEx(
        "Memory budget (MB)",
        &budget_mb,
        1.0,
        1.0,
        65536.0,
        "%.0f",
        ig.ImGuiSliderFlags_AlwaysClamp,
    )) {
        scene.retention.budget_bytes = @intFromFloat(budget_mb * mebibyte);
        if (scene.retention.budget_bytes < old_budget) scene.enforceBudget();
    }
}

fn drawTimelineCamera(camera_mode: *CameraMode) bool {
    ig.igSeparator();
    if (ig.igRadioButton("Orbit", camera_mode.* == .orbit)) camera_mode.* = .orbit;
    ig.igSameLine();
    if (ig.igRadioButton("Ortho2D", camera_mode.* == .ortho_2d)) camera_mode.* = .ortho_2d;
    ig.igSameLine();
    return ig.igButton("Fit");
}

fn drawTimelineStatus(
    scene: *const Scene,
    socket_path: []const u8,
    connected: bool,
    fps: f64,
    frame_count: u32,
) void {
    ig.igSeparator();
    var buffer: [512]u8 = undefined;
    const memory = scene.memoryStats();
    const status = if (memory.evicted_versions == 0)
        std.fmt.bufPrint(
            &buffer,
            "socket={s}  connected={s}  run #{d}  frames={d}  fps={d:.1}  memory {d:.1} MB / {d:.1} MB",
            .{
                socket_path,
                if (connected) "yes" else "no",
                scene.run,
                frame_count,
                fps,
                @as(f64, @floatFromInt(memory.blob_bytes)) / (1024.0 * 1024.0),
                @as(f64, @floatFromInt(scene.retention.budget_bytes)) / (1024.0 * 1024.0),
            },
        )
    else
        std.fmt.bufPrint(
            &buffer,
            "socket={s}  connected={s}  run #{d}  frames={d}  fps={d:.1}  memory {d:.1} MB / {d:.1} MB  evicted {d}",
            .{
                socket_path,
                if (connected) "yes" else "no",
                scene.run,
                frame_count,
                fps,
                @as(f64, @floatFromInt(memory.blob_bytes)) / (1024.0 * 1024.0),
                @as(f64, @floatFromInt(scene.retention.budget_bytes)) / (1024.0 * 1024.0),
                memory.evicted_versions,
            },
        );
    text(status catch "status line too long");
}

fn keptFrameCount(scene: *const Scene) u32 {
    var kept: u32 = 0;
    var frame: u32 = 0;
    while (frame < scene.frameCount()) : (frame += 1) {
        var structures = scene.structures.slice();
        for (structures.items(.versions), 0..) |_, structure_i| {
            const structure_index: StructureIndex = @fromBackingInt(@intCast(structure_i));
            if (scene.hasExactVersion(structure_index, frame)) {
                kept += 1;
                break;
            }
        }
    }
    return kept;
}

fn drawLog(scene: *const Scene) void {
    if (ig.igBegin("Log", null, ig.ImGuiWindowFlags_None)) {
        for (scene.log.items) |entry| {
            const prefix = switch (entry.level) {
                .info => "[info] ",
                .warn => "[warn] ",
                .err => "[error] ",
            };
            text(prefix);
            ig.igSameLine();
            text(scene.string(entry.text));
        }
    }
    ig.igEnd();
}

fn text(value: []const u8) void {
    ig.igTextUnformattedEx(value.ptr, value.ptr + value.len);
}

test "nearest vertex of face uses top-left framebuffer projection" {
    const positions = try Positions.alloc(std.testing.allocator, 3);
    defer positions.free(std.testing.allocator);
    positions.setAll(&.{
        .init(-0.8, -0.8, 0),
        .init(0.8, -0.8, 0),
        .init(0, 0.8, 0),
    });
    try std.testing.expectEqual(
        @as(u32, 2),
        nearestVertexOfFace(
            positions.toConst(),
            .{ 0, 1, 2 },
            .identity,
            .{ 200, 200 },
            .{ 105, 18 },
        ),
    );
}
