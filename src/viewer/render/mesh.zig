//! Sokol GPU resources parallel to the pure scene blob store.
const std = @import("std");
const vertex = @import("vertex");
const sg = @import("sokol").gfx;

const mesh_shader = @import("../shaders/mesh.zig");
const mesh_soa_shader = @import("../shaders/mesh_soa.zig");
const Positions = vertex.layout.Positions;
const Mat4 = vertex.camera.Mat4;
const Scene = vertex.scene.Scene;
const StructureIndex = vertex.scene.StructureIndex;
const BlobIndex = vertex.scene.BlobIndex;

/// Owns the mesh pipeline, shader, and one optional GPU buffer slot per scene
/// blob. All CPU-side list allocation uses the allocator supplied to `init`.
pub const Renderer = struct {
    gpa: std.mem.Allocator,
    shader: sg.Shader,
    pipeline: sg.Pipeline,
    blob_gpu: std.ArrayList(?sg.Buffer) = .empty,

    /// Creates immutable mesh GPU state. The returned renderer owns all Sokol
    /// handles and must be released before `sg.shutdown`.
    pub fn init(gpa: std.mem.Allocator) Renderer {
        const shader = sg.makeShader(switch (vertex.layout.layout) {
            .aos3, .aos4 => mesh_shader.meshShaderDesc(sg.queryBackend()),
            .soa => mesh_soa_shader.meshSoaShaderDesc(sg.queryBackend()),
        });
        var pipeline_desc: sg.PipelineDesc = .{
            .shader = shader,
            .depth = .{ .compare = .LESS_EQUAL, .write_enabled = true },
            .index_type = .UINT32,
            .cull_mode = .NONE,
            .label = "vertex mesh pipeline",
        };
        switch (vertex.layout.layout) {
            .aos3, .aos4 => {
                pipeline_desc.layout.buffers[0].stride = @intCast(Positions.stride);
                pipeline_desc.layout.attrs[mesh_shader.ATTR_mesh_position] = .{
                    .buffer_index = 0,
                    .offset = @intCast(@offsetOf(Positions.Elem, "x")),
                    .format = .FLOAT3,
                };
            },
            .soa => {
                inline for (0..3) |buffer_index| {
                    pipeline_desc.layout.buffers[buffer_index].stride = @sizeOf(f32);
                }
                pipeline_desc.layout.attrs[mesh_soa_shader.ATTR_mesh_soa_px] = .{
                    .buffer_index = 0,
                    .format = .FLOAT,
                };
                pipeline_desc.layout.attrs[mesh_soa_shader.ATTR_mesh_soa_py] = .{
                    .buffer_index = 1,
                    .format = .FLOAT,
                };
                pipeline_desc.layout.attrs[mesh_soa_shader.ATTR_mesh_soa_pz] = .{
                    .buffer_index = 2,
                    .format = .FLOAT,
                };
            },
        }
        return .{
            .gpa = gpa,
            .shader = shader,
            .pipeline = sg.makePipeline(pipeline_desc),
        };
    }

    /// Mirrors scene blob-slot lifetime into the parallel GPU array and clears
    /// both scene notification lists. List growth may allocate through `gpa`;
    /// GPU upload remains lazy until a blob is first drawn.
    pub fn sync(self: *Renderer, scene: *Scene) std.mem.Allocator.Error!void {
        if (scene.blobs.len > self.blob_gpu.items.len) {
            const additional = scene.blobs.len - self.blob_gpu.items.len;
            try self.blob_gpu.ensureUnusedCapacity(self.gpa, additional);
            for (0..additional) |_| self.blob_gpu.appendAssumeCapacity(null);
        }

        for (scene.freed_blobs.items) |blob_index| {
            const gpu = &self.blob_gpu.items[indexOf(blob_index)];
            if (gpu.*) |buffer| sg.destroyBuffer(buffer);
            gpu.* = null;
        }
        for (scene.new_blobs.items) |blob_index| {
            std.debug.assert(indexOf(blob_index) < self.blob_gpu.items.len);
        }
        scene.freed_blobs.clearRetainingCapacity();
        scene.new_blobs.clearRetainingCapacity();
    }

    /// Draws one mesh version with borrowed scene data. Buffers are uploaded
    /// once on first use; the operation performs no CPU allocation. Stale
    /// structures are automatically dimmed.
    pub fn draw(
        self: *Renderer,
        scene: *const Scene,
        structure_index: StructureIndex,
        version_index: u32,
        vp: Mat4,
        color: [4]f32,
    ) void {
        const structure_i = indexOf(structure_index);
        const structures = scene.structures.slice();
        std.debug.assert(structures.items(.kind)[structure_i] == .mesh);
        const versions = structures.items(.versions)[structure_i].items;
        const version = versions[version_index];
        const faces = scene.facesOf(version);
        if (faces.len == 0) return;

        const positions = scene.positionsOf(version);
        const position_buffer = self.bufferFor(scene, version.positions, .vertex);
        const index_buffer = self.bufferFor(scene, version.topology, .index);
        var bindings: sg.Bindings = .{ .index_buffer = index_buffer };
        switch (vertex.layout.layout) {
            .aos3, .aos4 => bindings.vertex_buffers[0] = position_buffer,
            .soa => {
                const component_bytes = @as(u64, positions.len()) * @sizeOf(f32);
                std.debug.assert(component_bytes * 2 <= std.math.maxInt(i32));
                bindings.vertex_buffers[0] = position_buffer;
                bindings.vertex_buffers[1] = position_buffer;
                bindings.vertex_buffers[2] = position_buffer;
                bindings.vertex_buffer_offsets[1] = @intCast(component_bytes);
                bindings.vertex_buffer_offsets[2] = @intCast(component_bytes * 2);
            },
        }

        var draw_color = color;
        if (structures.items(.stale)[structure_i]) {
            draw_color[0] *= 0.45;
            draw_color[1] *= 0.45;
            draw_color[2] *= 0.45;
        }
        const vs_params: mesh_shader.VsParams = .{
            .mvp = vp.m,
            .model = Mat4.identity.m,
        };
        const fs_params: mesh_shader.FsParams = .{
            .color = draw_color,
            .light_dir = .{ 0.4, 0.8, 0.6, 0 },
        };

        sg.applyPipeline(self.pipeline);
        sg.applyBindings(bindings);
        sg.applyUniforms(mesh_shader.UB_vs_params, .{ .ptr = &vs_params, .size = @sizeOf(mesh_shader.VsParams) });
        sg.applyUniforms(mesh_shader.UB_fs_params, .{ .ptr = &fs_params, .size = @sizeOf(mesh_shader.FsParams) });
        std.debug.assert(faces.len <= std.math.maxInt(u32) / 3);
        sg.draw(0, @intCast(faces.len * 3), 1);
    }

    /// Destroys every owned GPU handle and frees the parallel CPU array using
    /// the allocator retained by `init`.
    pub fn deinit(self: *Renderer) void {
        for (self.blob_gpu.items) |maybe_buffer| {
            if (maybe_buffer) |buffer| sg.destroyBuffer(buffer);
        }
        self.blob_gpu.deinit(self.gpa);
        sg.destroyPipeline(self.pipeline);
        sg.destroyShader(self.shader);
        self.* = undefined;
    }

    const BufferKind = enum { vertex, index };

    fn bufferFor(self: *Renderer, scene: *const Scene, blob_index: BlobIndex, kind: BufferKind) sg.Buffer {
        std.debug.assert(blob_index != .none);
        const slot = &self.blob_gpu.items[indexOf(blob_index)];
        if (slot.*) |buffer| return buffer;
        const bytes = scene.blobBytes(blob_index);
        std.debug.assert(bytes.len != 0);
        slot.* = sg.makeBuffer(.{
            .usage = switch (kind) {
                .vertex => .{ .vertex_buffer = true, .immutable = true },
                .index => .{ .index_buffer = true, .immutable = true },
            },
            .data = .{ .ptr = bytes.ptr, .size = bytes.len },
            .label = switch (kind) {
                .vertex => "vertex positions blob",
                .index => "vertex topology blob",
            },
        });
        return slot.*.?;
    }
};

fn indexOf(index: anytype) usize {
    return @backingInt(index);
}
