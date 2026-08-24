//! Instanced screen-space point rendering over scene-owned position blobs.
const std = @import("std");
const vertex = @import("vertex");
const sg = @import("sokol").gfx;

const common = @import("common.zig");
const points_shader = @import("../shaders/points.zig");
const points_soa_shader = @import("../shaders/points_soa.zig");
const scalar_shader = @import("../shaders/points_scalar.zig");
const scalar_soa_shader = @import("../shaders/points_scalar_soa.zig");
const Mat4 = vertex.camera.Mat4;
const Positions = vertex.layout.Positions;
const Scene = vertex.scene.Scene;
const StructureIndex = vertex.scene.StructureIndex;

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
        const shader = sg.makeShader(switch (vertex.layout.layout) {
            .aos3, .aos4 => points_shader.pointsShaderDesc(sg.queryBackend()),
            .soa => points_soa_shader.pointsSoaShaderDesc(sg.queryBackend()),
        });
        const scalar = sg.makeShader(switch (vertex.layout.layout) {
            .aos3, .aos4 => scalar_shader.pointsScalarShaderDesc(sg.queryBackend()),
            .soa => scalar_soa_shader.pointsScalarSoaShaderDesc(sg.queryBackend()),
        });
        var plain_desc = basePipeline(shader, "vertex points pipeline");
        var scalar_desc = basePipeline(scalar, "vertex scalar points pipeline");
        configurePositions(&plain_desc);
        configurePositions(&scalar_desc);
        const value_buffer = switch (vertex.layout.layout) {
            .aos3, .aos4 => 1,
            .soa => 3,
        };
        scalar_desc.layout.buffers[value_buffer] = .{
            .stride = @sizeOf(f32),
            .step_func = .PER_INSTANCE,
        };
        scalar_desc.layout.attrs[
            switch (vertex.layout.layout) {
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

        var draw_color = color;
        if (structures.items(.stale)[structure_i]) dim(&draw_color);
        const ui_state = structures.items(.ui)[structure_i];
        var bindings: sg.Bindings = .{};
        bindPositions(&bindings, gpu.bufferFor(scene, version.positions, .vertex), positions.len());

        const active = common.activeQuantity(scene, structure_index, version);
        const scalar = if (active) |quantity|
            quantity.kind == .scalar and
                (quantity.target == .vertex or quantity.target == .point) and
                quantity.count == positions.len()
        else
            false;
        if (scalar) {
            const quantity = active.?;
            const value_buffer = switch (vertex.layout.layout) {
                .aos3, .aos4 => 1,
                .soa => 3,
            };
            bindings.vertex_buffers[value_buffer] = gpu.bufferFor(scene, quantity.blob, .vertex);
            bindings.views[scalarViewSlot()] = gpu.colormapView(ui_state.colormap);
            bindings.samplers[scalarSamplerSlot()] = gpu.sampler;
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

    /// Draws one previous-run point version with the plain pipeline at a
    /// reduced size. It borrows all state and performs no CPU allocation.
    pub fn drawGhost(
        self: *Renderer,
        gpu: *common.Gpu,
        scene: *const Scene,
        structure_index: StructureIndex,
        version_index: u32,
        vp: Mat4,
        viewport: [2]f32,
        color: [4]f32,
    ) void {
        const structure_i = common.indexOf(structure_index);
        const structures = scene.structures.slice();
        std.debug.assert(structures.items(.kind)[structure_i] == .points);
        const version = structures.items(.versions)[structure_i].items[version_index];
        const positions = scene.positionsOf(version);
        if (positions.len() == 0) return;

        var bindings: sg.Bindings = .{};
        bindPositions(&bindings, gpu.bufferFor(scene, version.positions, .vertex), positions.len());
        sg.applyPipeline(self.pipeline);
        sg.applyBindings(bindings);
        applyPlainUniforms(
            vp,
            viewport,
            structures.items(.ui)[structure_i].point_size * 0.65,
            color,
        );
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

fn configurePositions(desc: *sg.PipelineDesc) void {
    switch (vertex.layout.layout) {
        .aos3, .aos4 => {
            desc.layout.buffers[0] = .{
                .stride = @intCast(Positions.stride),
                .step_func = .PER_INSTANCE,
            };
            desc.layout.attrs[0] = .{
                .buffer_index = 0,
                .offset = @intCast(@offsetOf(Positions.Elem, "x")),
                .format = .FLOAT3,
            };
        },
        .soa => inline for (0..3) |i| {
            desc.layout.buffers[i] = .{ .stride = @sizeOf(f32), .step_func = .PER_INSTANCE };
            desc.layout.attrs[i] = .{ .buffer_index = i, .format = .FLOAT };
        },
    }
}

fn bindPositions(bindings: *sg.Bindings, buffer: sg.Buffer, count: u32) void {
    switch (vertex.layout.layout) {
        .aos3, .aos4 => bindings.vertex_buffers[0] = buffer,
        .soa => {
            const component_bytes = @as(u64, count) * @sizeOf(f32);
            std.debug.assert(component_bytes * 2 <= std.math.maxInt(i32));
            inline for (0..3) |i| bindings.vertex_buffers[i] = buffer;
            bindings.vertex_buffer_offsets[1] = @intCast(component_bytes);
            bindings.vertex_buffer_offsets[2] = @intCast(component_bytes * 2);
        },
    }
}

fn applyPlainUniforms(vp: Mat4, viewport: [2]f32, point_size: f32, color: [4]f32) void {
    switch (vertex.layout.layout) {
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
    switch (vertex.layout.layout) {
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

fn scalarViewSlot() usize {
    return switch (vertex.layout.layout) {
        .aos3, .aos4 => scalar_shader.VIEW_cmap_tex,
        .soa => scalar_soa_shader.VIEW_cmap_tex,
    };
}

fn scalarSamplerSlot() usize {
    return switch (vertex.layout.layout) {
        .aos3, .aos4 => scalar_shader.SMP_cmap_smp,
        .soa => scalar_soa_shader.SMP_cmap_smp,
    };
}

fn dim(color: *[4]f32) void {
    color[0] *= 0.45;
    color[1] *= 0.45;
    color[2] *= 0.45;
}
