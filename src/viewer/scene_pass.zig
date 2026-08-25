//! The order the scene is drawn in.
//!
//! Solid meshes first, establishing depth for everything that follows, then
//! wireframe overlays, lines, vector arrows and points. The overlays require
//! depth to have been written. Points are drawn last: they are the smallest and
//! must not be hidden by an arrow over them.
//!
//! Each pass walks the same structures and skips those that are hidden or have
//! nothing to display at the current frame.
const std = @import("std");
const vertex = @import("vertex");

const mesh_render = @import("render/mesh.zig");
const Scene = vertex.internal.scene.Scene;

/// Draws the displayed scene in the established solid, wire, line, vector,
/// then point order. Inputs are borrowed; renderer cache misses may allocate.
pub fn drawScene(
    renderer: *mesh_render.Renderer,
    scene: *const Scene,
    scrub: u32,
    vp: vertex.internal.camera.Mat4,
    viewport: [2]f32,
) std.mem.Allocator.Error!void {
    const structures = scene.structures.slice();
    const ui_states = structures.items(.ui);
    const kinds = structures.items(.kind);
    const versions = structures.items(.versions);

    // Solid meshes establish depth before every overlay and primitive pass.
    for (ui_states, kinds, versions, 0..) |ui_state, kind, version_list, i| {
        if (!ui_state.visible or kind != .mesh) continue;
        const structure_index: vertex.internal.scene.StructureIndex = @fromBackingInt(@intCast(i));
        const version_index = scene.versionAt(structure_index, scrub) orelse continue;
        std.debug.assert(version_index < version_list.items.len);
        try renderer.draw(scene, structure_index, version_index, vp, .{ 0.72, 0.78, 0.86, 1.0 });
    }
    for (ui_states, kinds, versions, 0..) |ui_state, kind, version_list, i| {
        if (!ui_state.visible or kind != .mesh or !ui_state.wireframe) continue;
        const structure_index: vertex.internal.scene.StructureIndex = @fromBackingInt(@intCast(i));
        const version_index = scene.versionAt(structure_index, scrub) orelse continue;
        std.debug.assert(version_index < version_list.items.len);
        try renderer.drawWireframe(
            scene,
            structure_index,
            version_index,
            vp,
            viewport,
            .{ 0.12, 0.15, 0.20, 1.0 },
        );
    }
    for (ui_states, kinds, versions, 0..) |ui_state, kind, version_list, i| {
        if (!ui_state.visible or kind != .lines) continue;
        const structure_index: vertex.internal.scene.StructureIndex = @fromBackingInt(@intCast(i));
        const version_index = scene.versionAt(structure_index, scrub) orelse continue;
        std.debug.assert(version_index < version_list.items.len);
        try renderer.drawLines(
            scene,
            structure_index,
            version_index,
            vp,
            viewport,
            .{ 0.96, 0.55, 0.18, 1.0 },
        );
    }
    for (ui_states, versions, 0..) |ui_state, version_list, i| {
        if (!ui_state.visible) continue;
        const structure_index: vertex.internal.scene.StructureIndex = @fromBackingInt(@intCast(i));
        const version_index = scene.versionAt(structure_index, scrub) orelse continue;
        std.debug.assert(version_index < version_list.items.len);
        try renderer.drawVectors(
            scene,
            structure_index,
            version_index,
            vp,
            .{ 0.96, 0.28, 0.22, 1.0 },
        );
    }
    for (ui_states, kinds, versions, 0..) |ui_state, kind, version_list, i| {
        if (!ui_state.visible or kind != .points) continue;
        const structure_index: vertex.internal.scene.StructureIndex = @fromBackingInt(@intCast(i));
        const version_index = scene.versionAt(structure_index, scrub) orelse continue;
        std.debug.assert(version_index < version_list.items.len);
        try renderer.drawPoints(
            scene,
            structure_index,
            version_index,
            vp,
            viewport,
            .{ 0.25, 0.82, 0.58, 1.0 },
        );
    }
}

/// Returns whether any structure has a displayed version at `scrub`.
/// The scene is borrowed and the query allocates nothing.
pub fn hasDisplayedGeometry(scene: *const Scene, scrub: u32) bool {
    const structures = scene.structures.slice();
    for (structures.items(.versions), 0..) |_, i| {
        const structure_index: vertex.internal.scene.StructureIndex = @fromBackingInt(@intCast(i));
        if (scene.versionAt(structure_index, scrub) != null) return true;
    }
    return false;
}
