//! Plain Dear ImGui panels for scene state and viewer controls.
const std = @import("std");
const vertex = @import("vertex");
const ig = @import("cimgui");

const pick = @import("pick.zig");
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
    camera_mode: *CameraMode,
    socket_path: []const u8,
    connected: bool,
    fps: f64,
    hover: ?pick.Hit,
    selection: *?Selection,
    view_proj: Mat4,
    viewport: [2]f32,
    cursor: [2]f32,
) bool {
    if (selection.*) |selected| {
        if (!hitValid(scene, scrub.*, selected.hit)) selection.* = null;
    }
    drawStructures(scene, scrub.*, selection, view_proj, viewport);
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
    drawHoverTooltip(scene, scrub.*, hover, view_proj, viewport, cursor);
    return fit_requested;
}

fn drawStructures(
    scene: *Scene,
    scrub: u32,
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
