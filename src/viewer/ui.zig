//! Plain Dear ImGui panels for scene state and viewer controls.
const std = @import("std");
const vertex = @import("vertex");
const ig = @import("cimgui");

const Scene = vertex.scene.Scene;
const StructureIndex = vertex.scene.StructureIndex;

/// Camera mode selected by UI and keyboard controls. The value owns no memory.
pub const CameraMode = enum { orbit, ortho_2d };

/// Draws all M1 panels and mutates only viewer UI state. It allocates nothing,
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
            const name = scene.string(name_index);
            _ = ig.igCheckbox(name.ptr, &ui_state.visible);
            ig.igSameLine();

            const structure_index: StructureIndex = @fromBackingInt(@intCast(i));
            var vertex_count: u32 = 0;
            var face_count: usize = 0;
            var segment_count: usize = 0;
            if (scene.versionAt(structure_index, scrub)) |version_index| {
                const version = version_list.items[version_index];
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
                    "points  vertices={d} faces=0  (not drawn yet){s}",
                    .{ vertex_count, if (is_stale) "  [stale]" else "" },
                ),
                .lines => std.fmt.bufPrint(
                    &buffer,
                    "lines  vertices={d} faces=0 segments={d}  (not drawn yet){s}",
                    .{ vertex_count, segment_count, if (is_stale) "  [stale]" else "" },
                ),
            } catch "structure summary too long";
            text(detail);
        }
    }
    ig.igEnd();
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
