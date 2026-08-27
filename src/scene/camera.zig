//! Cameras and the matrix arithmetic behind them.
//!
//! `Orbit` is a turntable for three-dimensional geometry, looking at a target
//! from a distance and an orientation. `Ortho2D` is a plane view for
//! two-dimensional geometry, panning and zooming without perspective. The viewer
//! selects between them, and either can be driven directly.
//!
//! Both are values. Each holds a pose, allocates nothing, and produces matrices
//! on demand. The viewer stores the pose across a rebuild to restore the view.
//!
//! Matrices are column-major `[16]f32`, as the shaders take them as a uniform.
//! The projections produce OpenGL-style clip space with depth in [-1, 1].
const std = @import("std");
const geometry = @import("../geometry/geometry.zig");
const layout = @import("../geometry/layout.zig");

const Vec3 = layout.Vec3;
const Aabb = geometry.current.Aabb;

/// A 4x4 transform in column-major order, laid out exactly as the shaders
/// consume it, so a `Mat4` can be handed to a uniform without conversion.
pub const Mat4 = extern struct {
    m: [16]f32,

    /// The identity transform.
    pub const identity: Mat4 = .{ .m = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    } };

    /// Returns `a * b`, applying `b` first.
    ///
    /// O(1).
    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var result: Mat4 = .{ .m = @splat(0) };
        for (0..4) |column| {
            for (0..4) |row| {
                var value: f32 = 0;
                for (0..4) |k| value += a.m[k * 4 + row] * b.m[column * 4 + k];
                result.m[column * 4 + row] = value;
            }
        }
        return result;
    }

    /// Builds a right-handed perspective projection with a vertical field of
    /// view of `fovy_rad`.
    ///
    /// Depth maps to [-1, 1]. `aspect` and `near` must be positive and `far`
    /// greater than `near`. Depth precision falls as the ratio between `near`
    /// and `far` grows, so `Orbit` derives both from its current distance
    /// instead of fixing them.
    ///
    /// O(1).
    pub fn perspective(fovy_rad: f32, aspect: f32, near: f32, far: f32) Mat4 {
        std.debug.assert(fovy_rad > 0 and fovy_rad < std.math.pi);
        std.debug.assert(aspect > 0 and near > 0 and far > near);
        const f = 1.0 / @tan(fovy_rad * 0.5);
        return .{ .m = .{
            f / aspect, 0, 0,                               0,
            0,          f, 0,                               0,
            0,          0, (far + near) / (near - far),     -1,
            0,          0, (2 * far * near) / (near - far), 0,
        } };
    }

    /// Builds a right-handed orthographic projection of the given box, with
    /// depth mapping to [-1, 1]. Used for two-dimensional scenes, where
    /// perspective would only distort the geometry being examined.
    ///
    /// O(1).
    pub fn ortho(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4 {
        std.debug.assert(right != left and top != bottom and far != near);
        return .{ .m = .{
            2 / (right - left),               0,                                0,                            0,
            0,                                2 / (top - bottom),               0,                            0,
            0,                                0,                                -2 / (far - near),            0,
            -(right + left) / (right - left), -(top + bottom) / (top - bottom), -(far + near) / (far - near), 1,
        } };
    }

    /// Builds the view transform for a camera at `eye_position` looking at
    /// `target`, with `up_hint` giving the roll. The hint must not be parallel
    /// to the direction of view; `Orbit` clamps its pitch to keep it from
    /// becoming so.
    ///
    /// O(1).
    pub fn lookAt(eye_position: Vec3, target: Vec3, up_hint: Vec3) Mat4 {
        const forward = target.sub(eye_position).normalize();
        const right = forward.cross(up_hint).normalize();
        const up = right.cross(forward);
        std.debug.assert(forward.length() > 0 and right.length() > 0);
        return .{ .m = .{
            right.x,                  up.x,                  -forward.x,                0,
            right.y,                  up.y,                  -forward.y,                0,
            right.z,                  up.z,                  -forward.z,                0,
            -right.dot(eye_position), -up.dot(eye_position), forward.dot(eye_position), 1,
        } };
    }

    /// Transforms a point and divides through by w, giving normalized device
    /// coordinates when `matrix` is a view-projection. This is how the viewer
    /// projects a vertex to find what the cursor is near.
    ///
    /// O(1).
    pub fn transformPoint(matrix: Mat4, point: Vec3) Vec3 {
        const x = matrix.m[0] * point.x + matrix.m[4] * point.y + matrix.m[8] * point.z + matrix.m[12];
        const y = matrix.m[1] * point.x + matrix.m[5] * point.y + matrix.m[9] * point.z + matrix.m[13];
        const z = matrix.m[2] * point.x + matrix.m[6] * point.y + matrix.m[10] * point.z + matrix.m[14];
        const w = matrix.m[3] * point.x + matrix.m[7] * point.y + matrix.m[11] * point.z + matrix.m[15];
        if (w == 0) return .init(x, y, z);
        return .init(x / w, y / w, z / w);
    }
};

/// A turntable camera. Its pose is a target point, a distance from that target,
/// and a yaw and pitch about it.
/// ---
/// `rotate` moves the eye around the target, `pan` moves the target across the
/// view plane, and `dolly` moves the eye toward or away from it. All three
/// scale their effect with the current distance, so a drag moves the geometry
/// under the cursor by the same amount at any zoom level. `fit` frames a
/// bounding box.
/// ---
/// The pose is the entire state, so storing and restoring it reproduces the
/// view exactly. The clip planes are not part of it and are computed per
/// projection; see `clipPlanes`.
pub const Orbit = struct {
    target: Vec3,
    distance: f32,
    yaw: f32,
    pitch: f32,
    fovy: f32 = 0.8,
    /// The radius of the scene last fitted, or zero before any fit. The clip
    /// planes are derived from it and from `distance` rather than stored, so no
    /// camera movement can leave them out of date.
    extent: f32 = 0,

    /// The starting pose: looking down the negative Z axis at the origin from a
    /// distance of five, used before any data has arrived to fit.
    pub const default: Orbit = .{
        .target = .zero,
        .distance = 5,
        .yaw = 0,
        .pitch = 0,
    };

    /// The position of the eye in world space, derived from the target,
    /// distance, yaw and pitch.
    ///
    /// O(1).
    pub fn eye(self: Orbit) Vec3 {
        const cos_pitch = @cos(self.pitch);
        const offset = Vec3.init(
            cos_pitch * @sin(self.yaw),
            @sin(self.pitch),
            cos_pitch * @cos(self.yaw),
        );
        return self.target.add(offset.scale(self.distance));
    }

    /// The view transform for the current pose.
    ///
    /// O(1).
    pub fn view(self: Orbit) Mat4 {
        return .lookAt(self.eye(), self.target, .init(0, 1, 0));
    }

    /// Returns the near and far clip distances for the current pose.
    ///
    /// Both derive from `distance`, so dollying cannot move the scene outside
    /// the frustum. Planes computed once at fit time clip the scene as soon as
    /// the camera leaves that pose: the near plane removes the model on
    /// approach, the far plane on retreat. The near distance is a thousandth of
    /// the orbit distance, permitting a close approach to a surface. The far
    /// distance always exceeds the extent of the scene, and exceeds the target
    /// distance by at least the orbit distance when the scene is small.
    fn clipPlanes(self: Orbit) struct { near: f32, far: f32 } {
        return .{
            .near = @max(self.distance * 1e-3, 1e-5),
            .far = self.distance + @max(self.extent * 1.2, self.distance),
        };
    }

    /// Returns the allocation-free perspective projection for `aspect`.
    ///
    /// O(1).
    pub fn proj(self: Orbit, aspect: f32) Mat4 {
        const planes = self.clipPlanes();
        return .perspective(self.fovy, aspect, planes.near, planes.far);
    }

    /// Returns `projection * view` without allocating.
    ///
    /// O(1).
    pub fn viewProj(self: Orbit, aspect: f32) Mat4 {
        return self.proj(aspect).mul(self.view());
    }

    /// Applies turntable rotation without allocating and clamps pitch away
    /// from the world-up singularity.
    ///
    /// O(1).
    pub fn rotate(self: *Orbit, dx: f32, dy: f32) void {
        self.yaw += dx;
        const limit: f32 = std.math.pi / 2.0 - 1e-4;
        self.pitch = std.math.clamp(self.pitch + dy, -limit, limit);
    }

    /// Pans in screen space without allocating. Deltas are pixels and scale
    /// with distance so dragging remains stable across dolly levels.
    ///
    /// O(1).
    pub fn pan(self: *Orbit, dx: f32, dy: f32, viewport_height: f32) void {
        std.debug.assert(viewport_height > 0);
        const forward = self.target.sub(self.eye()).normalize();
        const right = forward.cross(.init(0, 1, 0)).normalize();
        const up = right.cross(forward);
        const world_per_pixel = 2 * self.distance * @tan(self.fovy * 0.5) / viewport_height;
        self.target = self.target
            .add(right.scale(-dx * world_per_pixel))
            .add(up.scale(dy * world_per_pixel));
    }

    /// Applies exponential scroll dolly without allocating. Positive scroll
    /// moves toward the target while preserving a positive distance.
    ///
    /// O(1).
    pub fn dolly(self: *Orbit, scroll: f32) void {
        self.distance = @max(1e-4, self.distance * @exp(-scroll * 0.1));
    }

    /// Fits a bounding sphere around `aabb` into a square frustum without
    /// allocating. Empty bounds restore `default`.
    ///
    /// O(1): it takes bounds already computed rather than the points behind
    /// them.
    pub fn fit(self: *Orbit, aabb: Aabb) void {
        if (aabb.isEmpty()) {
            self.* = default;
            return;
        }
        self.target = aabb.center();
        const radius = aabb.radius();
        self.extent = radius;
        self.distance = if (radius > 0)
            @max(1e-4, radius * 1.05 / @sin(self.fovy * 0.5))
        else
            1;
    }
};

/// Persistent orthographic 2D camera. It owns no memory and every operation
/// is allocation-free.
pub const Ortho2D = struct {
    center: [2]f32 = .{ 0, 0 },
    half_height: f32 = 1,

    /// Returns an allocation-free orthographic view-projection for `aspect`.
    ///
    /// O(1).
    pub fn viewProj(self: Ortho2D, aspect: f32) Mat4 {
        std.debug.assert(aspect > 0 and self.half_height > 0);
        const half_width = self.half_height * aspect;
        return .ortho(
            self.center[0] - half_width,
            self.center[0] + half_width,
            self.center[1] - self.half_height,
            self.center[1] + self.half_height,
            -1,
            1,
        );
    }

    /// Pans by screen-pixel deltas without allocating. Positive screen Y is
    /// downward, so it moves the world center in the opposite Y direction.
    ///
    /// O(1).
    pub fn pan(self: *Ortho2D, dx: f32, dy: f32, viewport_height: f32) void {
        std.debug.assert(viewport_height > 0);
        const world_per_pixel = 2 * self.half_height / viewport_height;
        self.center[0] -= dx * world_per_pixel;
        self.center[1] += dy * world_per_pixel;
    }

    /// Multiplies the zoom scale while keeping the NDC cursor's world point
    /// fixed. This operation owns no memory and never allocates.
    ///
    /// O(1).
    pub fn zoomAt(self: *Ortho2D, factor: f32, cursor_ndc: [2]f32) void {
        std.debug.assert(factor > 0);
        const old_half_height = self.half_height;
        const new_half_height = @max(1e-6, old_half_height * factor);
        const shift = old_half_height - new_half_height;
        self.center[0] += cursor_ndc[0] * shift;
        self.center[1] += cursor_ndc[1] * shift;
        self.half_height = new_half_height;
    }

    /// Fits XY bounds into a square viewport without allocating. Empty bounds
    /// restore the default center and scale.
    ///
    /// O(1): it takes bounds already computed rather than the points behind
    /// them.
    pub fn fit(self: *Ortho2D, aabb: Aabb) void {
        if (aabb.isEmpty()) {
            self.* = .{};
            return;
        }
        const center = aabb.center();
        const extent = aabb.extent();
        self.center = .{ center.x, center.y };
        self.half_height = @max(1e-6, @max(extent.x, extent.y) * 0.5 * 1.05);
    }
};

/// Runtime camera mode wrapper. It owns no memory and dispatches only to
/// allocation-free camera math.
pub const Camera = union(enum) {
    orbit: Orbit,
    ortho: Ortho2D,

    /// Returns the active mode's view-projection matrix without allocating.
    ///
    /// O(1).
    pub fn viewProj(self: Camera, aspect: f32) Mat4 {
        return switch (self) {
            .orbit => |camera| camera.viewProj(aspect),
            .ortho => |camera| camera.viewProj(aspect),
        };
    }

    /// Fits the active mode to `aabb` without allocating or changing modes.
    ///
    /// O(1): it takes bounds already computed rather than the points behind
    /// them.
    pub fn fit(self: *Camera, aabb: Aabb) void {
        switch (self.*) {
            .orbit => |*camera| camera.fit(aabb),
            .ortho => |*camera| camera.fit(aabb),
        }
    }
};

const testing = std.testing;

test "perspective maps the negative Z axis into OpenGL NDC" {
    const projection = Mat4.perspective(std.math.pi / 2.0, 1, 0.1, 100);
    const point = projection.transformPoint(.init(0, 0, -2));
    try testing.expectApproxEqAbs(@as(f32, 0), point.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), point.y, 1e-6);
    try testing.expect(point.z >= -1 and point.z <= 1);
}

test "lookAt centers its target" {
    const target = Vec3.init(1, 2, 3);
    const view = Mat4.lookAt(.init(4, 5, 7), target, .init(0, 1, 0));
    const transformed = view.transformPoint(target);
    try testing.expectApproxEqAbs(@as(f32, 0), transformed.x, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), transformed.y, 1e-5);
}

test "Orbit fit contains every unit-cube corner" {
    const bounds: Aabb = .{ .min = .init(-1, -1, -1), .max = .init(1, 1, 1) };
    var camera: Orbit = .default;
    camera.fit(bounds);
    const matrix = camera.viewProj(1);
    for ([_]f32{ -1, 1 }) |x| {
        for ([_]f32{ -1, 1 }) |y| {
            for ([_]f32{ -1, 1 }) |z| {
                const ndc = matrix.transformPoint(.init(x, y, z));
                try testing.expect(@abs(ndc.x) <= 1);
                try testing.expect(@abs(ndc.y) <= 1);
                try testing.expect(ndc.z >= -1 and ndc.z <= 1);
            }
        }
    }
}

test "Orbit clip planes keep the scene visible across the dolly range" {
    // The regression this pins: clip planes computed once by `fit` and not
    // updated by `dolly` removed the model at both ends of the range, the near
    // plane on approach and the far plane on retreat.
    const bounds: Aabb = .{ .min = .init(-1, -1, -1), .max = .init(1, 1, 1) };
    var camera: Orbit = .default;
    camera.fit(bounds);
    const fitted = camera.distance;

    const radius = bounds.radius();
    for ([_]f32{ 1e-3, 1e-2, 0.1, 0.5, 1, 2, 10, 1e3, 1e5 }) |scale| {
        camera.distance = fitted * scale;
        const planes = camera.clipPlanes();
        try testing.expect(planes.near > 0 and planes.near < planes.far);
        // The far side of the bounding sphere remains inside the frustum.
        try testing.expect(planes.far > camera.distance + radius);
        // Outside the sphere the near face must also remain visible. Inside
        // it there is no near face to preserve, so any positive near distance
        // is acceptable.
        if (camera.distance > radius) {
            try testing.expect(planes.near < camera.distance - radius);
        }
    }
}

test "Ortho2D zoomAt preserves the cursor world point" {
    var camera: Ortho2D = .{ .center = .{ 2, -3 }, .half_height = 4 };
    const cursor = [2]f32{ 0.25, -0.5 };
    const before = [2]f32{
        camera.center[0] + cursor[0] * camera.half_height,
        camera.center[1] + cursor[1] * camera.half_height,
    };
    camera.zoomAt(0.4, cursor);
    const after = [2]f32{
        camera.center[0] + cursor[0] * camera.half_height,
        camera.center[1] + cursor[1] * camera.half_height,
    };
    try testing.expectApproxEqAbs(before[0], after[0], 1e-5);
    try testing.expectApproxEqAbs(before[1], after[1], 1e-5);
}

test "Orbit rotation clamps pitch" {
    var camera: Orbit = .default;
    camera.rotate(0, 100);
    try testing.expect(camera.pitch < std.math.pi / 2.0);
    camera.rotate(0, -200);
    try testing.expect(camera.pitch > -std.math.pi / 2.0);
}
