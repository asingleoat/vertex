//! Turning sokol_app events into camera movement and selection.
//!
//! Holds both cameras and the current mode, and routes each event to the one in
//! use. Dragging orbits or pans, the scroll wheel dollies or zooms, `F` fits the
//! scene and the number keys switch mode. Every drag moves the surface under the
//! cursor with the cursor, on both axes and in both cameras.
//!
//! It also decides what the cursor is over. A hover is resolved to a `pick.Hit`
//! each frame the mouse has moved, and a click without a drag pins that hit as
//! the selection. The inspector displays the pinned selection.
const vertex = @import("vertex");
const sokol = @import("sokol");
const ig = @import("cimgui");

const pick = @import("pick.zig");
const ui = @import("ui.zig");
const sapp = sokol.app;
const Aabb = vertex.internal.geometry.current.Aabb;
const Scene = vertex.internal.scene.Scene;

/// Owns camera and pointer interaction state while borrowing scene/timeline
/// controls at stable addresses. Construction and event handling allocate nothing.
pub const Input = struct {
    scene: *const Scene,
    scrub: *u32,
    follow_latest: *bool,
    orbit: vertex.internal.camera.Orbit = .default,
    ortho: vertex.internal.camera.Ortho2D = .{},
    camera_mode: ui.CameraMode = .orbit,
    fitted_once: bool = false,
    frame0_fitted: bool = false,
    camera_touched: bool = false,
    hover: ?pick.Hit = null,
    selection: ?ui.Selection = null,
    mouse_position: [2]f32 = .{ 0, 0 },
    left_press_position: [2]f32 = .{ 0, 0 },
    mouse_inside: bool = false,
    /// Hover picking waits for a real MOUSE_MOVE: on entry the OS may report a
    /// pointer position before imgui has one.
    mouse_moved: bool = false,
    left_pressed_in_viewport: bool = false,
    left_dragged: bool = false,
    pending_pin: bool = false,

    /// Creates a controller borrowing the scene and timeline controls. The
    /// caller must keep all three at stable addresses for the controller lifetime.
    pub fn init(scene: *const Scene, scrub: *u32, follow_latest: *bool) Input {
        return .{ .scene = scene, .scrub = scrub, .follow_latest = follow_latest };
    }

    /// Handles one borrowed Sokol event after imgui has observed it. Mouse
    /// capture, tracking, camera motion, and all key bindings allocate nothing.
    pub fn event(self: *Input, ev: sapp.Event) void {
        const mouse_event = isMouseEvent(ev.type);
        const wants_mouse = mouse_event and ig.igGetIO().*.WantCaptureMouse;
        if (mouse_event) self.trackMouse(ev, wants_mouse);
        if (wants_mouse) return;
        switch (ev.type) {
            .MOUSE_MOVE => self.handleMouseMove(ev),
            .MOUSE_SCROLL => self.handleScroll(ev),
            .KEY_DOWN => if (!ev.key_repeat) self.handleKey(ev.key_code),
            else => {},
        }
    }

    /// Fits the active camera to visible geometry at the selected frame.
    /// Scene data is borrowed and no allocation occurs.
    pub fn fitCamera(self: *Input) void {
        const bounds = self.visibleBounds();
        switch (self.camera_mode) {
            .orbit => self.orbit.fit(bounds),
            .ortho_2d => self.ortho.fit(bounds),
        }
    }

    /// Returns true when the borrowed scene is non-empty and entirely 2D.
    /// The scene is only inspected and no allocation occurs.
    pub fn allStructures2d(self: *const Input) bool {
        if (self.scene.structures.len == 0) return false;
        const structures = self.scene.structures.slice();
        for (structures.items(.dim)) |dim| {
            if (dim != .d2) return false;
        }
        return true;
    }

    /// Computes the active camera view-projection matrix without allocation.
    pub fn viewProj(self: *const Input, aspect: f32) vertex.internal.camera.Mat4 {
        return switch (self.camera_mode) {
            .orbit => self.orbit.viewProj(aspect),
            .ortho_2d => self.ortho.viewProj(aspect),
        };
    }

    fn trackMouse(self: *Input, ev: sapp.Event, wants_mouse: bool) void {
        switch (ev.type) {
            .MOUSE_ENTER => {
                self.mouse_inside = true;
                self.mouse_position = .{ ev.mouse_x, ev.mouse_y };
            },
            .MOUSE_LEAVE => {
                self.mouse_inside = false;
                self.left_pressed_in_viewport = false;
            },
            .MOUSE_MOVE => {
                self.mouse_moved = true;
                self.mouse_position = .{ ev.mouse_x, ev.mouse_y };
                if (self.left_pressed_in_viewport) {
                    const dx = ev.mouse_x - self.left_press_position[0];
                    const dy = ev.mouse_y - self.left_press_position[1];
                    if (dx * dx + dy * dy > 9) self.left_dragged = true;
                }
            },
            .MOUSE_DOWN => if (ev.mouse_button == .LEFT) {
                self.mouse_position = .{ ev.mouse_x, ev.mouse_y };
                self.left_pressed_in_viewport = self.mouse_inside and !wants_mouse;
                self.left_press_position = self.mouse_position;
                self.left_dragged = false;
            },
            .MOUSE_UP => if (ev.mouse_button == .LEFT) {
                self.mouse_position = .{ ev.mouse_x, ev.mouse_y };
                if (self.left_pressed_in_viewport and !self.left_dragged and self.mouse_inside and !wants_mouse) {
                    self.pending_pin = true;
                }
                self.left_pressed_in_viewport = false;
                self.left_dragged = false;
            },
            else => {},
        }
    }

    fn visibleBounds(self: *const Input) Aabb {
        var result: Aabb = .empty;
        const structures = self.scene.structures.slice();
        const ui_states = structures.items(.ui);
        for (ui_states, 0..) |ui_state, i| {
            if (!ui_state.visible) continue;
            const structure_index: vertex.internal.scene.StructureIndex = @fromBackingInt(@intCast(i));
            const version_index = self.scene.versionAt(structure_index, self.scrub.*) orelse continue;
            const versions = structures.items(.versions)[i].items;
            const bounds = vertex.internal.geometry.current.bounds(self.scene.positionsOf(versions[version_index]));
            if (bounds.isEmpty()) continue;
            result.min = result.min.min(bounds.min);
            result.max = result.max.max(bounds.max);
        }
        return result;
    }

    fn handleMouseMove(self: *Input, ev: sapp.Event) void {
        const left = ev.modifiers & sapp.modifier_lmb != 0;
        const middle = ev.modifiers & sapp.modifier_mmb != 0;
        const shift = ev.modifiers & sapp.modifier_shift != 0;
        const pan = middle or (shift and left);
        const viewport_height = @max(sapp.heightf(), 1);
        switch (self.camera_mode) {
            .orbit => {
                if (pan) {
                    self.camera_touched = true;
                    self.orbit.pan(ev.mouse_dx, ev.mouse_dy, viewport_height);
                } else if (left) {
                    self.camera_touched = true;
                    // Both axes follow the cursor, as if the scene were a
                    // trackball under it: dragging down rotates the front of
                    // the model downwards and brings its top into view. This
                    // matches the sign both pan operations already use for
                    // `dy`.
                    self.orbit.rotate(-ev.mouse_dx * 0.01, ev.mouse_dy * 0.01);
                }
            },
            .ortho_2d => if (pan) {
                self.camera_touched = true;
                self.ortho.pan(ev.mouse_dx, ev.mouse_dy, viewport_height);
            },
        }
    }

    fn handleScroll(self: *Input, ev: sapp.Event) void {
        switch (self.camera_mode) {
            .orbit => {
                self.camera_touched = true;
                self.orbit.dolly(ev.scroll_y);
            },
            .ortho_2d => {
                const width = @max(sapp.widthf(), 1);
                const height = @max(sapp.heightf(), 1);
                const cursor_ndc = [2]f32{
                    2 * ev.mouse_x / width - 1,
                    1 - 2 * ev.mouse_y / height,
                };
                self.camera_touched = true;
                self.ortho.zoomAt(@exp(-ev.scroll_y * 0.1), cursor_ndc);
            },
        }
    }

    fn handleKey(self: *Input, key: sapp.Keycode) void {
        switch (key) {
            .F => self.fitCamera(),
            ._2 => self.camera_mode = .ortho_2d,
            ._3 => self.camera_mode = .orbit,
            .SPACE => self.follow_latest.* = !self.follow_latest.*,
            .LEFT => {
                self.follow_latest.* = false;
                self.scrub.* -|= 1;
            },
            .RIGHT => {
                self.follow_latest.* = false;
                self.scrub.* = @min(self.scrub.* +| 1, self.scene.frameCount() -| 1);
            },
            else => {},
        }
    }
};

fn isMouseEvent(event_type: sapp.EventType) bool {
    return switch (event_type) {
        .MOUSE_DOWN, .MOUSE_UP, .MOUSE_SCROLL, .MOUSE_MOVE, .MOUSE_ENTER, .MOUSE_LEAVE => true,
        else => false,
    };
}
