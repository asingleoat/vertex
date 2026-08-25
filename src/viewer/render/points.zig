//! Instanced screen-space point rendering over scene-owned position blobs.
const std = @import("std");
const vertex = @import("vertex");
const sg = @import("sokol").gfx;

const common = @import("common.zig");
const points_shader = @import("../shaders/points.zig");
const points_soa_shader = @import("../shaders/points_soa.zig");
const scalar_shader = @import("../shaders/points_scalar.zig");
const scalar_soa_shader = @import("../shaders/points_scalar_soa.zig");
const Mat4 = vertex.internal.camera.Mat4;
const Scene = vertex.internal.scene.Scene;
const StructureIndex = vertex.internal.scene.StructureIndex;

/// Owns point shader and pipeline handles. Position and scalar buffers remain
/// owned by the shared per-blob GPU mirror supplied to `draw`.
pub const Renderer = struct {
    shader: sg.Shader,
    scalar_shader: sg.Shader,
    pipeline: sg.Pipeline,
    scalar_pipeline: sg.Pipeline,

    /// Creates immutable point pipelines without CPU allocation. The result
    /// owns its Sokol handles until `deinit`.
    pub fn init() Renderer {
        const shader = sg.makeShader(switch (vertex.internal.layout.layout) {
            .aos3, .aos4 => points_shader.pointsShaderDesc(sg.queryBackend()),
            .soa => points_soa_shader.pointsSoaShaderDesc(sg.queryBackend()),
        });
        const scalar = sg.makeShader(switch (vertex.internal.layout.layout) {
            .aos3, .aos4 => scalar_shader.pointsScalarShaderDesc(sg.queryBackend()),
            .soa => scalar_soa_shader.pointsScalarSoaShaderDesc(sg.queryBackend()),
        });
        var plain_desc = basePipeline(shader, "vertex points pipeline");
        var scalar_desc = basePipeline(scalar, "vertex scalar points pipeline");
        common.configurePositions(&plain_desc, true);
        common.configurePositions(&scalar_desc, true);
        const value_buffer = switch (vertex.internal.layout.layout) {
            .aos3, .aos4 => 1,
            .soa => 3,
        };
        scalar_desc.layout.buffers[value_buffer] = .{
            .stride = @sizeOf(f32),
            .step_func = .PER_INSTANCE,
        };
        scalar_desc.layout.attrs[
            switch (vertex.internal.layout.layout) {
                .aos3, .aos4 => scalar_shader.ATTR_points_scalar_value,
                .soa => scalar_soa_shader.ATTR_points_scalar_soa_value,
            }
        ] = .{ .buffer_index = value_buffer, .format = .FLOAT };
        return .{
            .shader = shader,
            .scalar_shader = scalar,
            .pipeline = sg.makePipeline(plain_desc),
            .scalar_pipeline = sg.makePipeline(scalar_desc),
        };
    }

    /// Draws one point structure. The operation borrows scene and shared GPU
    /// state; only a first scalar-range lookup may allocate through `gpu`.
    pub fn draw(
        self: *Renderer,
        gpu: *common.Gpu,
        scene: *const Scene,
        structure_index: StructureIndex,
        version_index: u32,
        vp: Mat4,
        viewport: [2]f32,
        color: [4]f32,
    ) std.mem.Allocator.Error!void {
        const structure_i = common.indexOf(structure_index);
        const structures = scene.structures.slice();
        std.debug.assert(structures.items(.kind)[structure_i] == .points);
        const version = structures.items(.versions)[structure_i].items[version_index];
        const positions = scene.positionsOf(version);
        if (positions.len() == 0) return;

        const draw_color = color;
        const ui_state = structures.items(.ui)[structure_i];
        var bindings: sg.Bindings = .{};
        common.bindPositions(&bindings, gpu.bufferFor(scene, version.positions, .vertex), positions.len());

        const active = common.activeQuantity(scene, structure_index, version);
        const scalar = if (active) |quantity|
            quantity.kind == .scalar and
                (quantity.target == .vertex or quantity.target == .point) and
                quantity.count == positions.len()
        else
            false;
        if (scalar) {
            const quantity = active.?;
            const value_buffer = switch (vertex.internal.layout.layout) {
                .aos3, .aos4 => 1,
                .soa => 3,
            };
            bindings.vertex_buffers[value_buffer] = gpu.bufferFor(scene, quantity.blob, .vertex);
            bindings.views[common.scalarViewSlot(scalar_shader, scalar_soa_shader)] = gpu.colormapView(ui_state.colormap);
            bindings.samplers[common.scalarSamplerSlot(scalar_shader, scalar_soa_shader)] = gpu.sampler;
            sg.applyPipeline(self.scalar_pipeline);
            sg.applyBindings(bindings);
            applyScalarUniforms(vp, viewport, ui_state.point_size, draw_color, try gpu.scalarRange(scene, quantity.blob));
        } else {
            sg.applyPipeline(self.pipeline);
            sg.applyBindings(bindings);
            applyPlainUniforms(vp, viewport, ui_state.point_size, draw_color);
        }
        sg.draw(0, 4, @intCast(positions.len()));
    }

    /// Destroys every point pipeline and shader handle; no CPU memory is owned.
    pub fn deinit(self: *Renderer) void {
        sg.destroyPipeline(self.scalar_pipeline);
        sg.destroyPipeline(self.pipeline);
        sg.destroyShader(self.scalar_shader);
        sg.destroyShader(self.shader);
        self.* = undefined;
    }
};

fn basePipeline(shader: sg.Shader, label: [*c]const u8) sg.PipelineDesc {
    return .{
        .shader = shader,
        .depth = .{ .compare = .LESS_EQUAL, .write_enabled = true },
        .primitive_type = .TRIANGLE_STRIP,
        .cull_mode = .NONE,
        .label = label,
    };
}

fn applyPlainUniforms(vp: Mat4, viewport: [2]f32, point_size: f32, color: [4]f32) void {
    switch (vertex.internal.layout.layout) {
        .aos3, .aos4 => {
            const params: points_shader.VsParams = vsParams(points_shader.VsParams, vp, viewport, point_size, color);
            sg.applyUniforms(points_shader.UB_vs_params, .{ .ptr = &params, .size = @sizeOf(points_shader.VsParams) });
        },
        .soa => {
            const params: points_soa_shader.VsParams = vsParams(points_soa_shader.VsParams, vp, viewport, point_size, color);
            sg.applyUniforms(points_soa_shader.UB_vs_params, .{ .ptr = &params, .size = @sizeOf(points_soa_shader.VsParams) });
        },
    }
}

fn applyScalarUniforms(vp: Mat4, viewport: [2]f32, point_size: f32, color: [4]f32, value_range: [2]f32) void {
    switch (vertex.internal.layout.layout) {
        .aos3, .aos4 => {
            const vs: scalar_shader.VsParams = vsParams(scalar_shader.VsParams, vp, viewport, point_size, color);
            const fs: scalar_shader.FsParams = .{ .value_range = value_range };
            sg.applyUniforms(scalar_shader.UB_vs_params, .{ .ptr = &vs, .size = @sizeOf(scalar_shader.VsParams) });
            sg.applyUniforms(scalar_shader.UB_fs_params, .{ .ptr = &fs, .size = @sizeOf(scalar_shader.FsParams) });
        },
        .soa => {
            const vs: scalar_soa_shader.VsParams = vsParams(scalar_soa_shader.VsParams, vp, viewport, point_size, color);
            const fs: scalar_soa_shader.FsParams = .{ .value_range = value_range };
            sg.applyUniforms(scalar_soa_shader.UB_vs_params, .{ .ptr = &vs, .size = @sizeOf(scalar_soa_shader.VsParams) });
            sg.applyUniforms(scalar_soa_shader.UB_fs_params, .{ .ptr = &fs, .size = @sizeOf(scalar_soa_shader.FsParams) });
        },
    }
}

fn vsParams(comptime T: type, vp: Mat4, viewport: [2]f32, point_size: f32, color: [4]f32) T {
    return .{
        .mvp = vp.m,
        .viewport_size_point_size_pad = .{ viewport[0], viewport[1], point_size, 0 },
        .color = color,
    };
}
