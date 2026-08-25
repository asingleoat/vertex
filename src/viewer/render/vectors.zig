//! Instanced vector-field arrows derived from position and quantity blobs.
const std = @import("std");
const vertex = @import("vertex");
const sg = @import("sokol").gfx;

const common = @import("common.zig");
const vector_shader = @import("../shaders/vectors.zig");
const BlobIndex = vertex.internal.scene.BlobIndex;
const Mat4 = vertex.internal.camera.Mat4;
const Positions = vertex.internal.layout.Positions;
const Scene = vertex.internal.scene.Scene;
const StructureIndex = vertex.internal.scene.StructureIndex;
const Vec3 = vertex.internal.layout.Vec3;

const Key = struct {
    positions: BlobIndex,
    vectors: BlobIndex,
};

const Entry = struct {
    buffer: sg.Buffer,
    count: u32,
    /// Frame in which this entry was last drawn (residency trimming).
    last_used: u64 = 0,
};

// Like expanded line endpoints, these base/direction pairs are derived
// render-edge data rather than a Positions stream and stay interleaved.
const Instance = extern struct {
    base: Vec3,
    dir: Vec3,
};

comptime {
    std.debug.assert(@sizeOf(Instance) == 24);
}

const arrow_vertices = makeArrowVertices();

/// Owns the static unit-arrow mesh, vector pipeline, and immutable derived
/// instance buffers keyed by position/vector blob pairs.
pub const Renderer = struct {
    gpa: std.mem.Allocator,
    shader: sg.Shader,
    pipeline: sg.Pipeline,
    arrow_buffer: sg.Buffer,
    cache: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    frame: u64 = 0,

    /// Creates vector GPU state without CPU allocation. The returned owner
    /// must be destroyed before `sg.shutdown`.
    pub fn init(gpa: std.mem.Allocator) Renderer {
        const shader = sg.makeShader(vector_shader.vectorsShaderDesc(sg.queryBackend()));
        var desc: sg.PipelineDesc = .{
            .shader = shader,
            .depth = .{ .compare = .LESS_EQUAL, .write_enabled = true },
            .cull_mode = .NONE,
            .label = "vertex vectors pipeline",
        };
        desc.layout.buffers[0].stride = @sizeOf(Vec3);
        desc.layout.attrs[vector_shader.ATTR_vectors_unit_position] = .{
            .buffer_index = 0,
            .format = .FLOAT3,
        };
        desc.layout.buffers[1] = .{ .stride = @sizeOf(Instance), .step_func = .PER_INSTANCE };
        desc.layout.attrs[vector_shader.ATTR_vectors_base] = .{
            .buffer_index = 1,
            .offset = @offsetOf(Instance, "base"),
            .format = .FLOAT3,
        };
        desc.layout.attrs[vector_shader.ATTR_vectors_dir] = .{
            .buffer_index = 1,
            .offset = @offsetOf(Instance, "dir"),
            .format = .FLOAT3,
        };
        return .{
            .gpa = gpa,
            .shader = shader,
            .pipeline = sg.makePipeline(desc),
            .arrow_buffer = sg.makeBuffer(.{
                .usage = .{ .vertex_buffer = true, .immutable = true },
                .data = .{ .ptr = &arrow_vertices, .size = @sizeOf(@TypeOf(arrow_vertices)) },
                .label = "vertex unit arrow mesh",
            }),
        };
    }

    /// Evicts cached instances that depend on a freed scene blob without
    /// allocating.
    pub fn beginFrame(self: *Renderer, frame: u64) void {
        self.frame = frame;
    }

    /// Destroys cached arrow-instance buffers not drawn this frame once the
    /// cache holds more than `cap` entries (see common.Gpu.trimResidency).
    pub fn trim(self: *Renderer, cap: u32) u32 {
        return common.trimStale(Key, Entry, &self.cache, self.frame, cap);
    }

    pub fn evictBlob(self: *Renderer, blob_index: BlobIndex) void {
        while (self.findMatching(blob_index)) |key| {
            const removed = self.cache.fetchRemove(key).?;
            sg.destroyBuffer(removed.value.buffer);
        }
    }

    /// Draws the selected vertex/point vector quantity for one structure. A
    /// cache miss allocates one exact-size temporary instance slice.
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
        const version = structures.items(.versions)[structure_i].items[version_index];
        const quantity = common.activeQuantity(scene, structure_index, version) orelse return;
        if (quantity.kind != .vector or
            (quantity.target != .vertex and quantity.target != .point)) return;
        const positions = scene.positionsOf(version);
        if (positions.len() == 0 or quantity.count != positions.len()) return;

        const key: Key = .{ .positions = version.positions, .vectors = quantity.blob };
        const entry = try self.entryFor(scene, key, positions) orelse return;
        const bounds = vertex.internal.geometry.current.bounds(positions);
        if (bounds.isEmpty()) return;
        // A stable scene-scale heuristic: the UI multiplier scales 15% of the
        // bounds radius, divided by the cube root of the sample count.
        const density = std.math.cbrt(@as(f32, @floatFromInt(positions.len())));
        const scale = structures.items(.ui)[structure_i].vector_scale *
            0.15 * bounds.radius() / @max(density, 1.0);
        if (!(scale > 0) or !std.math.isFinite(scale)) return;

        const draw_color = color;
        const vs: vector_shader.VsParams = .{
            .mvp = vp.m,
            .scale_factor_pad = .{ scale, 0, 0, 0 },
            .color = draw_color,
        };
        const fs: vector_shader.FsParams = .{ .light_dir = .{ 0.4, 0.8, 0.6, 0 } };
        var bindings: sg.Bindings = .{};
        bindings.vertex_buffers[0] = self.arrow_buffer;
        bindings.vertex_buffers[1] = entry.buffer;
        sg.applyPipeline(self.pipeline);
        sg.applyBindings(bindings);
        sg.applyUniforms(vector_shader.UB_vs_params, .{ .ptr = &vs, .size = @sizeOf(vector_shader.VsParams) });
        sg.applyUniforms(vector_shader.UB_fs_params, .{ .ptr = &fs, .size = @sizeOf(vector_shader.FsParams) });
        sg.draw(0, arrow_vertices.len, @intCast(entry.count));
    }

    /// Destroys static and derived GPU buffers, pipeline/shader handles, and
    /// frees the cache with the allocator retained by `init`.
    pub fn deinit(self: *Renderer) void {
        var iterator = self.cache.valueIterator();
        while (iterator.next()) |entry| sg.destroyBuffer(entry.buffer);
        self.cache.deinit(self.gpa);
        sg.destroyBuffer(self.arrow_buffer);
        sg.destroyPipeline(self.pipeline);
        sg.destroyShader(self.shader);
        self.* = undefined;
    }

    fn entryFor(self: *Renderer, scene: *const Scene, key: Key, positions: Positions.Const) std.mem.Allocator.Error!?Entry {
        if (self.cache.getPtr(key)) |entry| {
            entry.last_used = self.frame;
            return entry.*;
        }
        const vectors = Positions.Const.fromBytes(scene.blobBytes(key.vectors));
        if (vectors.len() != positions.len() or positions.len() == 0) return null;
        const instances = try self.gpa.alloc(Instance, positions.len());
        defer self.gpa.free(instances);
        var i: u32 = 0;
        while (i < positions.len()) : (i += 1) {
            instances[i] = .{ .base = positions.get(i), .dir = vectors.get(i) };
        }
        try self.cache.ensureUnusedCapacity(self.gpa, 1);
        const entry: Entry = .{
            .buffer = sg.makeBuffer(.{
                .usage = .{ .vertex_buffer = true, .immutable = true },
                .data = .{ .ptr = instances.ptr, .size = std.mem.sliceAsBytes(instances).len },
                .label = "vertex expanded vector instances",
            }),
            .count = positions.len(),
            .last_used = self.frame,
        };
        self.cache.putAssumeCapacityNoClobber(key, entry);
        return entry;
    }

    fn findMatching(self: *Renderer, blob_index: BlobIndex) ?Key {
        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            if (key.positions == blob_index or key.vectors == blob_index) return key;
        }
        return null;
    }
};

fn makeArrowVertices() [96]Vec3 {
    @setEvalBranchQuota(5_000);
    const segments = 8;
    const tau: f32 = 2.0 * std.math.pi;
    var vertices: [96]Vec3 = undefined;
    var write: usize = 0;
    for (0..segments) |i| {
        const a0 = tau * @as(f32, @floatFromInt(i)) / segments;
        const a1 = tau * @as(f32, @floatFromInt(i + 1)) / segments;
        const b0 = Vec3.init(0.03 * @cos(a0), 0.03 * @sin(a0), 0);
        const b1 = Vec3.init(0.03 * @cos(a1), 0.03 * @sin(a1), 0);
        const t0 = Vec3.init(b0.x, b0.y, 0.75);
        const t1 = Vec3.init(b1.x, b1.y, 0.75);
        vertices[write..][0..6].* = .{ b0, b1, t0, t0, b1, t1 };
        write += 6;
    }
    for (0..segments) |i| {
        const a0 = tau * @as(f32, @floatFromInt(i)) / segments;
        const a1 = tau * @as(f32, @floatFromInt(i + 1)) / segments;
        vertices[write..][0..3].* = .{
            Vec3.zero,
            Vec3.init(0.03 * @cos(a1), 0.03 * @sin(a1), 0),
            Vec3.init(0.03 * @cos(a0), 0.03 * @sin(a0), 0),
        };
        write += 3;
    }
    for (0..segments) |i| {
        const a0 = tau * @as(f32, @floatFromInt(i)) / segments;
        const a1 = tau * @as(f32, @floatFromInt(i + 1)) / segments;
        vertices[write..][0..3].* = .{
            Vec3.init(0.09 * @cos(a0), 0.09 * @sin(a0), 0.75),
            Vec3.init(0.09 * @cos(a1), 0.09 * @sin(a1), 0.75),
            Vec3.init(0, 0, 1),
        };
        write += 3;
    }
    std.debug.assert(write == vertices.len);
    return vertices;
}
