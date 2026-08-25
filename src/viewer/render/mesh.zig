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
const face_scalar_shader = @import("../shaders/mesh_face_scalar.zig");
const face_scalar_soa_shader = @import("../shaders/mesh_face_scalar_soa.zig");
const Mat4 = vertex.camera.Mat4;
const Scene = vertex.scene.Scene;
const StructureIndex = vertex.scene.StructureIndex;

/// Owns all M2 renderer modules plus the sole per-BlobIndex GPU mirror. CPU
/// allocations use the allocator supplied to `init`.
pub const Renderer = struct {
    gpu: common.Gpu,
    mesh_shader: sg.Shader,
    mesh_scalar_shader: sg.Shader,
    mesh_face_scalar_shader: sg.Shader,
    mesh_pipeline: sg.Pipeline,
    mesh_scalar_pipeline: sg.Pipeline,
    mesh_face_scalar_pipeline: sg.Pipeline,
    face_scalars: bool,
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
        // Face-target scalars read the quantity blob by `gl_PrimitiveID`, which
        // has no MSL translation below 2.2 and so no source in a Metal desc
        // (see build.zig's `isGlOnlyShader`). Ask the generated artifact rather
        // than naming a backend: regenerate with a shdc that can emit it and
        // the feature turns itself back on.
        const face_scalar_shader_desc = switch (vertex.layout.layout) {
            .aos3, .aos4 => face_scalar_shader.meshFaceScalarShaderDesc(sg.queryBackend()),
            .soa => face_scalar_soa_shader.meshFaceScalarSoaShaderDesc(sg.queryBackend()),
        };
        const face_scalars = face_scalar_shader_desc.vertex_func.source != null;
        if (!face_scalars) std.log.info(
            "face-target scalars are unavailable on this backend; they render as plain meshes",
            .{},
        );
        const face_scalar = if (face_scalars) sg.makeShader(face_scalar_shader_desc) else sg.Shader{};
        var mesh_desc = baseMeshPipeline(shader, "vertex mesh pipeline");
        var scalar_desc = baseMeshPipeline(scalar, "vertex scalar mesh pipeline");
        var face_scalar_desc = baseMeshPipeline(face_scalar, "vertex face scalar mesh pipeline");
        common.configurePositions(&mesh_desc, false);
        common.configurePositions(&scalar_desc, false);
        common.configurePositions(&face_scalar_desc, false);
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
            .mesh_face_scalar_shader = face_scalar,
            .mesh_pipeline = sg.makePipeline(mesh_desc),
            .mesh_scalar_pipeline = sg.makePipeline(scalar_desc),
            .mesh_face_scalar_pipeline = if (face_scalars) sg.makePipeline(face_scalar_desc) else sg.Pipeline{},
            .face_scalars = face_scalars,
            .points = point_render.Renderer.init(),
            .lines = line_render.Renderer.init(gpa),
            .vectors = vector_render.Renderer.init(gpa),
        };
    }

    /// Processes freed scene blobs before new blobs, notifies each derived
    /// cache, then clears both scene lists. This is the only notification drain.
    /// Blob buffers resident on the GPU before trimming kicks in. Well under
    /// the sokol buffer pool (1024) while leaving room for scrubbing.
    pub const residency_cap: u32 = 512;
    /// Derived instance buffers (lines, wireframes, vectors) per cache.
    pub const derived_cap: u32 = 128;

    /// Marks the frame for residency stamping; call before any draw.
    pub fn beginFrame(self: *Renderer, frame: u64) void {
        self.gpu.beginFrame(frame);
        self.lines.beginFrame(frame);
        self.vectors.beginFrame(frame);
    }

    /// Enforces GPU residency caps; call after the frame's passes are committed.
    pub fn trimResidency(self: *Renderer) u32 {
        return self.gpu.trimResidency(residency_cap) + self.lines.trim(derived_cap) + self.vectors.trim(derived_cap);
    }

    pub fn sync(self: *Renderer, scene: *Scene) std.mem.Allocator.Error!void {
        try self.gpu.ensureSceneCapacity(scene);
        for (scene.freed_blobs.items) |blob_index| {
            self.lines.evictBlob(blob_index);
            self.vectors.evictBlob(blob_index);
        }
        for (scene.freed_blobs.items) |blob_index| {
            self.gpu.releaseBlob(blob_index);
        }
        for (scene.new_blobs.items) |blob_index| {
            std.debug.assert(common.indexOf(blob_index) < self.gpu.blob_gpu.items.len);
        }
        scene.freed_blobs.clearRetainingCapacity();
        scene.new_blobs.clearRetainingCapacity();
    }

    /// Draws one solid mesh version. Selected vertex and face scalar quantities
    /// choose attribute and primitive-indexed storage-buffer pipelines respectively.
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
        common.bindPositions(&bindings, self.gpu.bufferFor(scene, version.positions, .vertex), positions.len());
        const draw_color = color;

        const active = common.activeQuantity(scene, structure_index, version);
        const use_vertex_scalar = if (active) |quantity|
            quantity.kind == .scalar and quantity.target == .vertex and
                quantity.count == positions.len()
        else
            false;
        const use_face_scalar = if (active) |quantity|
            self.face_scalars and quantity.kind == .scalar and quantity.target == .face and
                quantity.count == faces.len
        else
            false;
        if (use_vertex_scalar) {
            const quantity = active.?;
            const value_buffer = switch (vertex.layout.layout) {
                .aos3, .aos4 => 1,
                .soa => 3,
            };
            bindings.vertex_buffers[value_buffer] = self.gpu.bufferFor(scene, quantity.blob, .vertex);
            bindings.views[common.scalarViewSlot(scalar_shader, scalar_soa_shader)] = self.gpu.colormapView(structures.items(.ui)[structure_i].colormap);
            bindings.samplers[common.scalarSamplerSlot(scalar_shader, scalar_soa_shader)] = self.gpu.sampler;
            sg.applyPipeline(self.mesh_scalar_pipeline);
            sg.applyBindings(bindings);
            applyScalarUniforms(vp, draw_color, try self.gpu.scalarRange(scene, quantity.blob));
        } else if (use_face_scalar) {
            const quantity = active.?;
            bindings.views[faceScalarStorageSlot()] = self.gpu.storageViewFor(scene, quantity.blob);
            bindings.views[faceScalarViewSlot()] = self.gpu.colormapView(structures.items(.ui)[structure_i].colormap);
            bindings.samplers[faceScalarSamplerSlot()] = self.gpu.sampler;
            sg.applyPipeline(self.mesh_face_scalar_pipeline);
            sg.applyBindings(bindings);
            applyFaceScalarUniforms(vp, draw_color, try self.gpu.scalarRange(scene, quantity.blob));
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
        if (self.face_scalars) sg.destroyPipeline(self.mesh_face_scalar_pipeline);
        sg.destroyPipeline(self.mesh_scalar_pipeline);
        sg.destroyPipeline(self.mesh_pipeline);
        if (self.face_scalars) sg.destroyShader(self.mesh_face_scalar_shader);
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

fn applyFaceScalarUniforms(vp: Mat4, color: [4]f32, value_range: [2]f32) void {
    switch (vertex.layout.layout) {
        .aos3, .aos4 => {
            const vs: face_scalar_shader.VsParams = .{ .mvp = vp.m, .model = Mat4.identity.m };
            const fs: face_scalar_shader.FsParams = .{
                .color = color,
                .light_dir = .{ 0.4, 0.8, 0.6, 0 },
                .value_range = value_range,
            };
            sg.applyUniforms(face_scalar_shader.UB_vs_params, .{ .ptr = &vs, .size = @sizeOf(face_scalar_shader.VsParams) });
            sg.applyUniforms(face_scalar_shader.UB_fs_params, .{ .ptr = &fs, .size = @sizeOf(face_scalar_shader.FsParams) });
        },
        .soa => {
            const vs: face_scalar_soa_shader.VsParams = .{ .mvp = vp.m, .model = Mat4.identity.m };
            const fs: face_scalar_soa_shader.FsParams = .{
                .color = color,
                .light_dir = .{ 0.4, 0.8, 0.6, 0 },
                .value_range = value_range,
            };
            sg.applyUniforms(face_scalar_soa_shader.UB_vs_params, .{ .ptr = &vs, .size = @sizeOf(face_scalar_soa_shader.VsParams) });
            sg.applyUniforms(face_scalar_soa_shader.UB_fs_params, .{ .ptr = &fs, .size = @sizeOf(face_scalar_soa_shader.FsParams) });
        },
    }
}

fn faceScalarStorageSlot() usize {
    return switch (vertex.layout.layout) {
        .aos3, .aos4 => face_scalar_shader.VIEW_face_values,
        .soa => face_scalar_soa_shader.VIEW_face_values,
    };
}

fn faceScalarViewSlot() usize {
    return switch (vertex.layout.layout) {
        .aos3, .aos4 => face_scalar_shader.VIEW_cmap_tex,
        .soa => face_scalar_soa_shader.VIEW_cmap_tex,
    };
}

fn faceScalarSamplerSlot() usize {
    return switch (vertex.layout.layout) {
        .aos3, .aos4 => face_scalar_shader.SMP_cmap_smp,
        .soa => face_scalar_soa_shader.SMP_cmap_smp,
    };
}

comptime {
    std.debug.assert(@sizeOf(face_scalar_shader.ScalarItem) == @sizeOf(f32));
    std.debug.assert(@sizeOf(face_scalar_soa_shader.ScalarItem) == @sizeOf(f32));
}
