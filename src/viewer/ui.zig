//! Plain Dear ImGui panels for scene state and viewer controls.
const std = @import("std");
const vertex = @import("vertex");
const ig = @import("cimgui");

const Scene = vertex.scene.Scene;
const StructureIndex = vertex.scene.StructureIndex;

/// Camera mode selected by UI and keyboard controls. The value owns no memory.
pub const CameraMode = enum { orbit, ortho_2d };

/// Draws all viewer panels and mutates only viewer UI state. It allocates nothing,
/// borrows every argument for the call, and returns whether Fit was pressed.
pub fn draw(
    scene: *Scene,
    scrub: *u32,
    follow_latest: *bool,
    camera_mode: *CameraMode,
    socket_path: []const u8,
    connected: bool,
    fps: f64,
) bool {
    drawStructures(scene, scrub.*);
    const fit_requested = drawTimeline(
        scene,
        scrub,
        follow_latest,
        camera_mode,
        socket_path,
        connected,
        fps,
    );
    drawLog(scene);
    return fit_requested;
}

fn drawStructures(scene: *Scene, scrub: u32) void {
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
            const detail = switch (kind) {
                .mesh => std.fmt.bufPrint(
                    &buffer,
                    "mesh  vertices={d} faces={d}{s}",
                    .{ vertex_count, face_count, if (is_stale) "  [stale]" else "" },
                ),
                .points => std.fmt.bufPrint(
                    &buffer,
                    "points  vertices={d}{s}",
                    .{ vertex_count, if (is_stale) "  [stale]" else "" },
                ),
                .lines => std.fmt.bufPrint(
                    &buffer,
                    "lines  vertices={d} segments={d}{s}",
                    .{ vertex_count, segment_count, if (is_stale) "  [stale]" else "" },
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
            ig.igUnindent();
            ig.igSeparator();
        }
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
    const suffix: []const u8 = if (quantity.target == .face) " (faces — not rendered yet)" else "";
    const available = buffer[0 .. buffer.len - 1];
    const label = std.fmt.bufPrint(available, "{s}{s}", .{ name, suffix }) catch {
        const fallback = "quantity name too long";
        @memcpy(buffer[0..fallback.len], fallback);
        buffer[fallback.len] = 0;
        return buffer[0..fallback.len :0];
    };
    buffer[label.len] = 0;
    return buffer[0..label.len :0];
}

fn drawTimeline(
    scene: *const Scene,
    scrub: *u32,
    follow_latest: *bool,
    camera_mode: *CameraMode,
    socket_path: []const u8,
    connected: bool,
    fps: f64,
) bool {
    var fit_requested = false;
    if (ig.igBegin("Timeline", null, ig.ImGuiWindowFlags_None)) {
        _ = ig.igCheckbox("Follow latest", follow_latest);
        const frame_count = scene.frameCount();
        const maximum_u32 = frame_count -| 1;
        const maximum: c_int = @intCast(@min(maximum_u32, @as(u32, std.math.maxInt(c_int))));
        var selected: c_int = @intCast(@min(scrub.*, @as(u32, @intCast(maximum))));
        if (ig.igSliderInt("Frame", &selected, 0, maximum)) {
            scrub.* = @intCast(selected);
            follow_latest.* = false;
        }

        ig.igSeparator();
        if (ig.igRadioButton("Orbit", camera_mode.* == .orbit)) camera_mode.* = .orbit;
        ig.igSameLine();
        if (ig.igRadioButton("Ortho2D", camera_mode.* == .ortho_2d)) camera_mode.* = .ortho_2d;
        ig.igSameLine();
        fit_requested = ig.igButton("Fit");

        ig.igSeparator();
        var buffer: [384]u8 = undefined;
        const status = std.fmt.bufPrint(
            &buffer,
            "socket={s}  connected={s}  run #{d}  frames={d}  fps={d:.1}",
            .{ socket_path, if (connected) "yes" else "no", scene.run, frame_count, fps },
        ) catch "status line too long";
        text(status);
    }
    ig.igEnd();
    return fit_requested;
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
