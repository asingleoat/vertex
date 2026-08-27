//! Drawing line sets, and deriving the wireframes of meshes.
//!
//! Each segment is an instanced quad expanded to a constant pixel width in the
//! vertex shader. Hardware line width is limited and inconsistent across
//! backends. The same pipeline draws mesh wireframes, whose unique edges are
//! extracted on the CPU and cached per blob. Extracting edges avoids
//! duplicating vertices for barycentric shading, and the per-blob cache is
//! shared by two versions with the same topology.
const std = @import("std");
const vertex = @import("vertex");
const sg = @import("sokol").gfx;

const common = @import("common.zig");
const line_shader = @import("../shaders/lines.zig");
const BlobIndex = vertex.internal.scene.BlobIndex;
const Mat4 = vertex.internal.camera.Mat4;
const Scene = vertex.internal.scene.Scene;
const StructureIndex = vertex.internal.scene.StructureIndex;
const Vec3 = vertex.internal.layout.Vec3;

const Key = struct {
    positions: BlobIndex,
    topology: BlobIndex,
};

/// Borrowed draw description for a cached expanded-line instance buffer.
/// The owning line renderer retains the GPU handle and no allocation occurs.
pub const DrawEntry = struct {
    buffer: sg.Buffer,
    count: u32,
    /// Frame in which this entry was last drawn (residency trimming).
    last_used: u64 = 0,
};

const Entry = DrawEntry;

// This is deliberately not a Positions stream: endpoints are render-edge
// derived instance data and are always interleaved p0.xyz/p1.xyz.
const Instance = extern struct {
    p0: Vec3,
    p1: Vec3,
};

comptime {
    std.debug.assert(@sizeOf(Instance) == 24);
}

/// Owns line pipelines plus immutable derived endpoint caches keyed by source
/// blob pairs. All CPU allocations use the allocator supplied to `init`.
pub const Renderer = struct {
    gpa: std.mem.Allocator,
    shader: sg.Shader,
    pipeline: sg.Pipeline,
    biased_pipeline: sg.Pipeline,
    line_cache: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    frame: u64 = 0,
    wire_cache: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    scratch_edges: std.ArrayList([2]u32) = .empty,

    /// Creates line GPU state without CPU allocation. The result owns all
    /// derived buffers and must be released before `sg.shutdown`.
    ///
    /// O(1).
    pub fn init(gpa: std.mem.Allocator) Renderer {
        const shader = sg.makeShader(line_shader.linesShaderDesc(sg.queryBackend()));
        var desc = pipelineDesc(shader, false);
        var biased_desc = pipelineDesc(shader, true);
        configureLayout(&desc);
        configureLayout(&biased_desc);
        return .{
            .gpa = gpa,
            .shader = shader,
            .pipeline = sg.makePipeline(desc),
            .biased_pipeline = sg.makePipeline(biased_desc),
        };
    }

    /// Evicts every derived entry whose position or topology key names a freed
    /// scene blob. The operation allocates nothing.
    ///
    /// O(1).
    pub fn beginFrame(self: *Renderer, frame: u64) void {
        self.frame = frame;
    }

    /// Destroys cached instance buffers not drawn this frame once a cache
    /// holds more than `cap` entries (see common.Gpu.trimResidency).
    ///
    /// O(r) in the resident entries.
    pub fn trim(self: *Renderer, cap: u32) u32 {
        return common.trimStale(Key, Entry, &self.line_cache, self.frame, cap) +
            common.trimStale(Key, Entry, &self.wire_cache, self.frame, cap);
    }

    /// O(r) in the resident entries.
    pub fn evictBlob(self: *Renderer, blob_index: BlobIndex) void {
        evictFrom(&self.line_cache, blob_index);
        evictFrom(&self.wire_cache, blob_index);
    }

    /// Draws one line structure through an immutable endpoint buffer. A cache
    /// miss performs one exact-size temporary allocation and may grow the map.
    ///
    /// O(1) draw calls over geometry already resident, plus O(n) on the frame
    /// that uploads it.
    pub fn drawLines(
        self: *Renderer,
        scene: *const Scene,
        structure_index: StructureIndex,
        version_index: u32,
        vp: Mat4,
        viewport: [2]f32,
        color: [4]f32,
    ) std.mem.Allocator.Error!void {
        const structure_i = common.indexOf(structure_index);
        const structures = scene.structures.slice();
        std.debug.assert(structures.items(.kind)[structure_i] == .lines);
        const version = structures.items(.versions)[structure_i].items[version_index];
        const key: Key = .{ .positions = version.positions, .topology = version.topology };
        const entry = try self.lineEntry(scene, key, version) orelse return;
        const draw_color = color;
        self.drawEntry(entry, vp, viewport, structures.items(.ui)[structure_i].line_width, draw_color, false);
    }

    /// Returns the same derived endpoint buffer used by the color line pass.
    /// A cache miss may allocate through the renderer allocator; the result is borrowed.
    ///
    /// O(r) in the resident entries.
    pub fn entryForPick(
        self: *Renderer,
        scene: *const Scene,
        structure_index: StructureIndex,
        version_index: u32,
    ) std.mem.Allocator.Error!?DrawEntry {
        const structure_i = common.indexOf(structure_index);
        const structures = scene.structures.slice();
        std.debug.assert(structures.items(.kind)[structure_i] == .lines);
        const version = structures.items(.versions)[structure_i].items[version_index];
        return self.lineEntry(
            scene,
            .{ .positions = version.positions, .topology = version.topology },
            version,
        );
    }

    /// Draws a mesh's unique edges after the solid pass with depth bias. A
    /// cache miss reuses the edge scratch list and creates immutable endpoints.
    ///
    /// O(1) draw calls, plus O(f log f) on the frame that first extracts the
    /// unique edges.
    pub fn drawWireframe(
        self: *Renderer,
        scene: *const Scene,
        structure_index: StructureIndex,
        version_index: u32,
        vp: Mat4,
        viewport: [2]f32,
        color: [4]f32,
    ) std.mem.Allocator.Error!void {
        const structure_i = common.indexOf(structure_index);
        const structures = scene.structures.slice();
        std.debug.assert(structures.items(.kind)[structure_i] == .mesh);
        const ui_state = structures.items(.ui)[structure_i];
        if (!ui_state.wireframe) return;
        const version = structures.items(.versions)[structure_i].items[version_index];
        const key: Key = .{ .positions = version.positions, .topology = version.topology };
        const entry = try self.wireEntry(scene, key, version) orelse return;
        const draw_color = color;
        self.drawEntry(entry, vp, viewport, ui_state.line_width, draw_color, true);
    }

    /// Destroys pipelines, shaders, every derived buffer, and all retained CPU
    /// cache capacity using the allocator supplied to `init`.
    ///
    /// O(r) in the resident entries.
    pub fn deinit(self: *Renderer) void {
        destroyEntries(&self.line_cache);
        destroyEntries(&self.wire_cache);
        self.scratch_edges.deinit(self.gpa);
        self.line_cache.deinit(self.gpa);
        self.wire_cache.deinit(self.gpa);
        sg.destroyPipeline(self.biased_pipeline);
        sg.destroyPipeline(self.pipeline);
        sg.destroyShader(self.shader);
        self.* = undefined;
    }

    fn lineEntry(self: *Renderer, scene: *const Scene, key: Key, version: vertex.internal.scene.Version) std.mem.Allocator.Error!?Entry {
        if (self.line_cache.getPtr(key)) |entry| {
            entry.last_used = self.frame;
            return entry.*;
        }
        const segments = scene.segmentsOf(version);
        if (segments.len == 0) return null;
        const positions = scene.positionsOf(version);
        const instances = try self.gpa.alloc(Instance, segments.len);
        defer self.gpa.free(instances);
        for (segments, instances) |segment, *instance| {
            std.debug.assert(segment[0] < positions.len());
            std.debug.assert(segment[1] < positions.len());
            instance.* = .{ .p0 = positions.get(segment[0]), .p1 = positions.get(segment[1]) };
        }
        try self.line_cache.ensureUnusedCapacity(self.gpa, 1);
        const entry = makeEntry(instances, self.frame);
        self.line_cache.putAssumeCapacityNoClobber(key, entry);
        return entry;
    }

    fn wireEntry(self: *Renderer, scene: *const Scene, key: Key, version: vertex.internal.scene.Version) std.mem.Allocator.Error!?Entry {
        if (self.wire_cache.getPtr(key)) |entry| {
            entry.last_used = self.frame;
            return entry.*;
        }
        try vertex.internal.geometry.current.uniqueEdges(self.gpa, scene.facesOf(version), &self.scratch_edges);
        if (self.scratch_edges.items.len == 0) return null;
        const positions = scene.positionsOf(version);
        const instances = try self.gpa.alloc(Instance, self.scratch_edges.items.len);
        defer self.gpa.free(instances);
        for (self.scratch_edges.items, instances) |edge, *instance| {
            std.debug.assert(edge[0] < positions.len());
            std.debug.assert(edge[1] < positions.len());
            instance.* = .{ .p0 = positions.get(edge[0]), .p1 = positions.get(edge[1]) };
        }
        try self.wire_cache.ensureUnusedCapacity(self.gpa, 1);
        const entry = makeEntry(instances, self.frame);
        self.wire_cache.putAssumeCapacityNoClobber(key, entry);
        return entry;
    }

    fn drawEntry(self: *Renderer, entry: Entry, vp: Mat4, viewport: [2]f32, width: f32, color: [4]f32, biased: bool) void {
        const params: line_shader.VsParams = .{
            .mvp = vp.m,
            .viewport_size_line_width_pad = .{ viewport[0], viewport[1], width, 0 },
            .color = color,
        };
        var bindings: sg.Bindings = .{};
        bindings.vertex_buffers[0] = entry.buffer;
        sg.applyPipeline(if (biased) self.biased_pipeline else self.pipeline);
        sg.applyBindings(bindings);
        sg.applyUniforms(line_shader.UB_vs_params, .{ .ptr = &params, .size = @sizeOf(line_shader.VsParams) });
        sg.draw(0, 4, @intCast(entry.count));
    }
};

fn pipelineDesc(shader: sg.Shader, biased: bool) sg.PipelineDesc {
    return .{
        .shader = shader,
        .depth = .{
            .compare = .LESS_EQUAL,
            .write_enabled = !biased,
            .bias = if (biased) -1.0 else 0,
            .bias_slope_scale = if (biased) -1.0 else 0,
        },
        .primitive_type = .TRIANGLE_STRIP,
        .cull_mode = .NONE,
        .label = if (biased) "vertex biased wire pipeline" else "vertex lines pipeline",
    };
}

fn configureLayout(desc: *sg.PipelineDesc) void {
    desc.layout.buffers[0] = .{ .stride = @sizeOf(Instance), .step_func = .PER_INSTANCE };
    desc.layout.attrs[line_shader.ATTR_lines_p0] = .{
        .buffer_index = 0,
        .offset = @offsetOf(Instance, "p0"),
        .format = .FLOAT3,
    };
    desc.layout.attrs[line_shader.ATTR_lines_p1] = .{
        .buffer_index = 0,
        .offset = @offsetOf(Instance, "p1"),
        .format = .FLOAT3,
    };
}

fn makeEntry(instances: []const Instance, frame: u64) Entry {
    std.debug.assert(instances.len <= std.math.maxInt(u32));
    return .{
        .buffer = sg.makeBuffer(.{
            .usage = .{ .vertex_buffer = true, .immutable = true },
            .data = .{ .ptr = instances.ptr, .size = std.mem.sliceAsBytes(instances).len },
            .label = "vertex expanded line instances",
        }),
        .count = @intCast(instances.len),
        .last_used = frame,
    };
}

fn evictFrom(map: *std.AutoHashMapUnmanaged(Key, Entry), blob_index: BlobIndex) void {
    while (findMatching(map, blob_index)) |key| {
        const removed = map.fetchRemove(key).?;
        sg.destroyBuffer(removed.value.buffer);
    }
}

fn findMatching(map: *std.AutoHashMapUnmanaged(Key, Entry), blob_index: BlobIndex) ?Key {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.positions == blob_index or key.topology == blob_index) return key;
    }
    return null;
}

fn destroyEntries(map: *std.AutoHashMapUnmanaged(Key, Entry)) void {
    var iterator = map.valueIterator();
    while (iterator.next()) |entry| sg.destroyBuffer(entry.buffer);
}
