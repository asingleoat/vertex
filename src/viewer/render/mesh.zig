//! Unified viewer renderer and sole owner of scene blob notification draining.
const std = @import("std");
const vertex = @import("vertex");
const sg = @import("sokol").gfx;

const common = @import("common.zig");
const line_render = @import("lines.zig");
const point_render = @import("points.zig");
const vector_render = @import("vectors.zig");
const mesh_shader = @import("../shaders/mesh.zig");
const mesh_soa_shader = @import("../shaders/mesh_soa.zig");
const scalar_shader = @import("../shaders/mesh_scalar.zig");
const scalar_soa_shader = @import("../shaders/mesh_scalar_soa.zig");
const Mat4 = vertex.camera.Mat4;
const Positions = vertex.layout.Positions;
const Scene = vertex.scene.Scene;
const StructureIndex = vertex.scene.StructureIndex;

/// Owns all M2 renderer modules plus the sole per-BlobIndex GPU mirror. CPU
/// allocations use the allocator supplied to `init`.
pub const Renderer = struct {
    gpu: common.Gpu,
    mesh_shader: sg.Shader,
    mesh_scalar_shader: sg.Shader,
    mesh_pipeline: sg.Pipeline,
    mesh_scalar_pipeline: sg.Pipeline,
    points: point_render.Renderer,
    lines: line_render.Renderer,
    vectors: vector_render.Renderer,

    /// Creates every immutable renderer pipeline. The returned renderer owns
    /// all Sokol handles and must be released before `sg.shutdown`.
    pub fn init(gpa: std.mem.Allocator) Renderer {
        const shader = sg.makeShader(switch (vertex.layout.layout) {
            .aos3, .aos4 => mesh_shader.meshShaderDesc(sg.queryBackend()),
            .soa => mesh_soa_shader.meshSoaShaderDesc(sg.queryBackend()),
        });
        const scalar = sg.makeShader(switch (vertex.layout.layout) {
            .aos3, .aos4 => scalar_shader.meshScalarShaderDesc(sg.queryBackend()),
            .soa => scalar_soa_shader.meshScalarSoaShaderDesc(sg.queryBackend()),
        });
        var mesh_desc = baseMeshPipeline(shader, "vertex mesh pipeline");
        var scalar_desc = baseMeshPipeline(scalar, "vertex scalar mesh pipeline");
        configurePositions(&mesh_desc);
        configurePositions(&scalar_desc);
        const value_buffer = switch (vertex.layout.layout) {
            .aos3, .aos4 => 1,
            .soa => 3,
        };
        scalar_desc.layout.buffers[value_buffer].stride = @sizeOf(f32);
        scalar_desc.layout.attrs[
            switch (vertex.layout.layout) {
                .aos3, .aos4 => scalar_shader.ATTR_mesh_scalar_value,
                .soa => scalar_soa_shader.ATTR_mesh_scalar_soa_value,
            }
        ] = .{ .buffer_index = value_buffer, .format = .FLOAT };
        return .{
            .gpu = common.Gpu.init(gpa),
            .mesh_shader = shader,
            .mesh_scalar_shader = scalar,
            .mesh_pipeline = sg.makePipeline(mesh_desc),
            .mesh_scalar_pipeline = sg.makePipeline(scalar_desc),
            .points = point_render.Renderer.init(),
            .lines = line_render.Renderer.init(gpa),
            .vectors = vector_render.Renderer.init(gpa),
        };
    }

    /// Processes freed scene blobs before new blobs, notifies each derived
    /// cache, then clears both scene lists. This is the only notification drain.
    pub fn sync(self: *Renderer, scene: *Scene) std.mem.Allocator.Error!void {
        try self.gpu.ensureSceneCapacity(scene);
        for (scene.freed_blobs.items) |blob_index| {
            self.lines.evictBlob(blob_index);
            self.vectors.evictBlob(blob_index);
            self.gpu.releaseBlob(blob_index);
        }
        for (scene.new_blobs.items) |blob_index| {
            std.debug.assert(common.indexOf(blob_index) < self.gpu.blob_gpu.items.len);
        }
        scene.freed_blobs.clearRetainingCapacity();
        scene.new_blobs.clearRetainingCapacity();
    }

    /// Draws one solid mesh version. A selected vertex scalar quantity chooses
    /// the scalar pipeline; face quantities deliberately fall back to plain mesh.
    pub fn draw(
        self: *Renderer,
        scene: *const Scene,
        structure_index: StructureIndex,
        version_index: u32,
        vp: Mat4,
        color: [4]f32,
    ) std.mem.Allocator.Error!void {
        const structure_i = common.indexOf(structure_index);
        const structures = scene.structures.slice();
        std.debug.assert(structures.items(.kind)[structure_i] == .mesh);
        const version = structures.items(.versions)[structure_i].items[version_index];
        const faces = scene.facesOf(version);
        if (faces.len == 0) return;
        const positions = scene.positionsOf(version);

        var bindings: sg.Bindings = .{
            .index_buffer = self.gpu.bufferFor(scene, version.topology, .index),
        };
        bindPositions(&bindings, self.gpu.bufferFor(scene, version.positions, .vertex), positions.len());
        var draw_color = color;
        if (structures.items(.stale)[structure_i]) dim(&draw_color);

        const active = common.activeQuantity(scene, structure_index, version);
        const use_scalar = if (active) |quantity|
            quantity.kind == .scalar and quantity.target == .vertex and
                quantity.count == positions.len()
        else
            false;
        if (use_scalar) {
            const quantity = active.?;
            const value_buffer = switch (vertex.layout.layout) {
                .aos3, .aos4 => 1,
                .soa => 3,
            };
            bindings.vertex_buffers[value_buffer] = self.gpu.bufferFor(scene, quantity.blob, .vertex);
            bindings.views[scalarViewSlot()] = self.gpu.colormapView(structures.items(.ui)[structure_i].colormap);
            bindings.samplers[scalarSamplerSlot()] = self.gpu.sampler;
            sg.applyPipeline(self.mesh_scalar_pipeline);
            sg.applyBindings(bindings);
            applyScalarUniforms(vp, draw_color, try self.gpu.scalarRange(scene, quantity.blob));
        } else {
            sg.applyPipeline(self.mesh_pipeline);
            sg.applyBindings(bindings);
            applyPlainUniforms(vp, draw_color);
        }
        std.debug.assert(faces.len <= std.math.maxInt(u32) / 3);
        sg.draw(0, @intCast(faces.len * 3), 1);
    }

    /// Draws a mesh wireframe overlay through the shared thick-line module.
    /// A derived-cache miss may allocate through the renderer allocator.
    pub fn drawWireframe(
        self: *Renderer,
        scene: *const Scene,
        structure_index: StructureIndex,
        version_index: u32,
        vp: Mat4,
        viewport: [2]f32,
        color: [4]f32,
    ) std.mem.Allocator.Error!void {
        return self.lines.drawWireframe(scene, structure_index, version_index, vp, viewport, color);
    }

    /// Draws one line structure. A derived-cache miss may allocate through the
    /// renderer allocator; all returned GPU state remains renderer-owned.
    pub fn drawLines(
        self: *Renderer,
        scene: *const Scene,
        structure_index: StructureIndex,
        version_index: u32,
        vp: Mat4,
        viewport: [2]f32,
        color: [4]f32,
    ) std.mem.Allocator.Error!void {
        return self.lines.drawLines(scene, structure_index, version_index, vp, viewport, color);
    }

    /// Draws the active vector quantity for a structure. A derived-cache miss
    /// may allocate; non-vector and unsupported-target selections draw nothing.
    pub fn drawVectors(
        self: *Renderer,
        scene: *const Scene,
        structure_index: StructureIndex,
        version_index: u32,
        vp: Mat4,
        color: [4]f32,
    ) std.mem.Allocator.Error!void {
        return self.vectors.draw(scene, structure_index, version_index, vp, color);
    }

    /// Draws one point structure using scene-blob position/scalar buffers. A
    /// first scalar-range lookup may allocate through the renderer allocator.
    pub fn drawPoints(
        self: *Renderer,
        scene: *const Scene,
        structure_index: StructureIndex,
        version_index: u32,
        vp: Mat4,
        viewport: [2]f32,
        color: [4]f32,
    ) std.mem.Allocator.Error!void {
        return self.points.draw(&self.gpu, scene, structure_index, version_index, vp, viewport, color);
    }

    /// Destroys every owned renderer and shared GPU resource, then frees all
    /// retained CPU cache capacity.
    pub fn deinit(self: *Renderer) void {
        self.vectors.deinit();
        self.lines.deinit();
        self.points.deinit();
        sg.destroyPipeline(self.mesh_scalar_pipeline);
        sg.destroyPipeline(self.mesh_pipeline);
        sg.destroyShader(self.mesh_scalar_shader);
        sg.destroyShader(self.mesh_shader);
        self.gpu.deinit();
        self.* = undefined;
    }
};

fn baseMeshPipeline(shader: sg.Shader, label: [*c]const u8) sg.PipelineDesc {
    return .{
        .shader = shader,
        .depth = .{ .compare = .LESS_EQUAL, .write_enabled = true },
        .index_type = .UINT32,
        .cull_mode = .NONE,
        .label = label,
    };
}

fn configurePositions(desc: *sg.PipelineDesc) void {
    switch (vertex.layout.layout) {
        .aos3, .aos4 => {
            desc.layout.buffers[0].stride = @intCast(Positions.stride);
            desc.layout.attrs[0] = .{
                .buffer_index = 0,
                .offset = @intCast(@offsetOf(Positions.Elem, "x")),
                .format = .FLOAT3,
            };
        },
        .soa => inline for (0..3) |i| {
            desc.layout.buffers[i].stride = @sizeOf(f32);
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

fn applyPlainUniforms(vp: Mat4, color: [4]f32) void {
    switch (vertex.layout.layout) {
        .aos3, .aos4 => {
            const vs: mesh_shader.VsParams = .{ .mvp = vp.m, .model = Mat4.identity.m };
            const fs: mesh_shader.FsParams = .{ .color = color, .light_dir = .{ 0.4, 0.8, 0.6, 0 } };
            sg.applyUniforms(mesh_shader.UB_vs_params, .{ .ptr = &vs, .size = @sizeOf(mesh_shader.VsParams) });
            sg.applyUniforms(mesh_shader.UB_fs_params, .{ .ptr = &fs, .size = @sizeOf(mesh_shader.FsParams) });
        },
        .soa => {
            const vs: mesh_soa_shader.VsParams = .{ .mvp = vp.m, .model = Mat4.identity.m };
            const fs: mesh_soa_shader.FsParams = .{ .color = color, .light_dir = .{ 0.4, 0.8, 0.6, 0 } };
            sg.applyUniforms(mesh_soa_shader.UB_vs_params, .{ .ptr = &vs, .size = @sizeOf(mesh_soa_shader.VsParams) });
            sg.applyUniforms(mesh_soa_shader.UB_fs_params, .{ .ptr = &fs, .size = @sizeOf(mesh_soa_shader.FsParams) });
        },
    }
}

fn applyScalarUniforms(vp: Mat4, color: [4]f32, value_range: [2]f32) void {
    switch (vertex.layout.layout) {
        .aos3, .aos4 => {
            const vs: scalar_shader.VsParams = .{ .mvp = vp.m, .model = Mat4.identity.m };
            const fs: scalar_shader.FsParams = .{
                .color = color,
                .light_dir = .{ 0.4, 0.8, 0.6, 0 },
                .value_range = value_range,
            };
            sg.applyUniforms(scalar_shader.UB_vs_params, .{ .ptr = &vs, .size = @sizeOf(scalar_shader.VsParams) });
            sg.applyUniforms(scalar_shader.UB_fs_params, .{ .ptr = &fs, .size = @sizeOf(scalar_shader.FsParams) });
        },
        .soa => {
            const vs: scalar_soa_shader.VsParams = .{ .mvp = vp.m, .model = Mat4.identity.m };
            const fs: scalar_soa_shader.FsParams = .{
                .color = color,
                .light_dir = .{ 0.4, 0.8, 0.6, 0 },
                .value_range = value_range,
            };
            sg.applyUniforms(scalar_soa_shader.UB_vs_params, .{ .ptr = &vs, .size = @sizeOf(scalar_soa_shader.VsParams) });
            sg.applyUniforms(scalar_soa_shader.UB_fs_params, .{ .ptr = &fs, .size = @sizeOf(scalar_soa_shader.FsParams) });
        },
    }
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
