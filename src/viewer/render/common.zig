//! Shared Sokol resources keyed by pure-scene blob and colormap indices.
const std = @import("std");
const vertex = @import("vertex");
const sg = @import("sokol").gfx;

const BlobIndex = vertex.scene.BlobIndex;
const Colormap = vertex.colormap.Colormap;
const QuantityRef = vertex.scene.QuantityRef;
const Scene = vertex.scene.Scene;
const StructureIndex = vertex.scene.StructureIndex;

/// Resource kind used when lazily mirroring a scene blob into a GPU buffer.
pub const BufferKind = enum { vertex, index, storage };

const ColormapGpu = struct {
    image: sg.Image,
    view: sg.View,
};

/// Owns per-BlobIndex buffer/storage-view arrays, scalar ranges, colormap
/// images, and a shared sampler. CPU allocation uses the allocator supplied to `init`.
pub const Gpu = struct {
    gpa: std.mem.Allocator,
    blob_gpu: std.ArrayList(?sg.Buffer) = .empty,
    blob_storage_views: std.ArrayList(?sg.View) = .empty,
    /// Frame in which each blob's GPU buffer was last bound (parallel to blob_gpu).
    blob_last_used: std.ArrayList(u64) = .empty,
    /// Current frame number, set by `beginFrame`; stamps buffer use.
    frame: u64 = 0,
    /// Number of non-null entries in blob_gpu.
    resident: u32 = 0,
    ranges: std.AutoHashMapUnmanaged(BlobIndex, [2]f32) = .empty,
    colormaps: [4]?ColormapGpu = @splat(null),
    sampler: sg.Sampler,

    /// Creates shared GPU state without allocating CPU memory. The returned
    /// owner must be destroyed before `sg.shutdown`.
    pub fn init(gpa: std.mem.Allocator) Gpu {
        return .{
            .gpa = gpa,
            .sampler = sg.makeSampler(.{
                .min_filter = .LINEAR,
                .mag_filter = .LINEAR,
                .wrap_u = .CLAMP_TO_EDGE,
                .wrap_v = .CLAMP_TO_EDGE,
                .label = "vertex colormap sampler",
            }),
        };
    }

    /// Extends the parallel GPU array to the scene's blob-slot count. Growth
    /// may allocate through the retained allocator; no GPU upload occurs.
    pub fn ensureSceneCapacity(self: *Gpu, scene: *const Scene) std.mem.Allocator.Error!void {
        if (scene.blobs.len <= self.blob_gpu.items.len) return;
        const additional = scene.blobs.len - self.blob_gpu.items.len;
        try self.blob_gpu.ensureUnusedCapacity(self.gpa, additional);
        try self.blob_storage_views.ensureUnusedCapacity(self.gpa, additional);
        try self.blob_last_used.ensureUnusedCapacity(self.gpa, additional);
        for (0..additional) |_| {
            self.blob_gpu.appendAssumeCapacity(null);
            self.blob_storage_views.appendAssumeCapacity(null);
            self.blob_last_used.appendAssumeCapacity(0);
        }
    }

    /// Releases GPU and cached range state for one freed scene blob. It does
    /// not allocate and leaves the parallel slot ready for scene index reuse.
    pub fn releaseBlob(self: *Gpu, blob_index: BlobIndex) void {
        const i = indexOf(blob_index);
        const view_slot = &self.blob_storage_views.items[i];
        if (view_slot.*) |view| sg.destroyView(view);
        view_slot.* = null;
        const slot = &self.blob_gpu.items[i];
        if (slot.*) |buffer| {
            sg.destroyBuffer(buffer);
            self.resident -= 1;
        }
        slot.* = null;
        _ = self.ranges.remove(blob_index);
    }

    /// Marks the start of a frame; buffers bound from now on are stamped with it.
    pub fn beginFrame(self: *Gpu, frame: u64) void {
        self.frame = frame;
    }

    /// GPU residency policy: retained versions are unbounded (memory budget),
    /// sokol's buffer pool is not. When more than `cap` blob buffers are
    /// resident, destroy every one not bound this frame; they are immutable
    /// uploads of scene blobs and are recreated on demand when scrubbed back.
    /// Returns how many were destroyed. Call outside a render pass.
    pub fn trimResidency(self: *Gpu, cap: u32) u32 {
        if (self.resident <= cap) return 0;
        var destroyed: u32 = 0;
        for (self.blob_gpu.items, self.blob_storage_views.items, self.blob_last_used.items) |*slot, *view_slot, last_used| {
            const buffer = slot.* orelse continue;
            if (last_used >= self.frame) continue;
            if (view_slot.*) |view| sg.destroyView(view);
            view_slot.* = null;
            sg.destroyBuffer(buffer);
            slot.* = null;
            self.resident -= 1;
            destroyed += 1;
        }
        return destroyed;
    }

    /// Lazily returns the immutable GPU mirror of a live scene blob. The
    /// returned handle remains owned by this object and no CPU allocation occurs.
    pub fn bufferFor(self: *Gpu, scene: *const Scene, blob_index: BlobIndex, kind: BufferKind) sg.Buffer {
        std.debug.assert(blob_index != .none);
        const i = indexOf(blob_index);
        const slot = &self.blob_gpu.items[i];
        self.blob_last_used.items[i] = self.frame;
        if (slot.*) |buffer| return buffer;
        self.resident += 1;
        const bytes = scene.blobBytes(blob_index);
        std.debug.assert(bytes.len != 0);
        slot.* = sg.makeBuffer(.{
            .usage = switch (kind) {
                .vertex => .{ .vertex_buffer = true, .immutable = true },
                .index => .{ .index_buffer = true, .immutable = true },
                .storage => .{ .storage_buffer = true, .immutable = true },
            },
            .data = .{ .ptr = bytes.ptr, .size = bytes.len },
            .label = switch (kind) {
                .vertex => "vertex scene blob",
                .index => "vertex topology blob",
                .storage => "vertex scalar storage blob",
            },
        });
        return slot.*.?;
    }

    /// Lazily returns the readonly storage-buffer view for a live scene blob.
    /// The view and its buffer remain owned by this object; no CPU allocation occurs.
    pub fn storageViewFor(self: *Gpu, scene: *const Scene, blob_index: BlobIndex) sg.View {
        const slot = &self.blob_storage_views.items[indexOf(blob_index)];
        if (slot.*) |view| return view;
        const buffer = self.bufferFor(scene, blob_index, .storage);
        slot.* = sg.makeView(.{
            .storage_buffer = .{ .buffer = buffer },
            .label = "vertex scalar storage view",
        });
        return slot.*.?;
    }

    /// Returns and caches the finite range of a scalar blob. A new cache entry
    /// may allocate through the retained allocator; returned values own no memory.
    pub fn scalarRange(self: *Gpu, scene: *const Scene, blob_index: BlobIndex) std.mem.Allocator.Error![2]f32 {
        if (self.ranges.get(blob_index)) |cached| return cached;
        const result = vertex.colormap.range(scalarValues(scene, blob_index));
        try self.ranges.put(self.gpa, blob_index, result);
        return result;
    }

    /// Lazily creates and returns the sampled texture view for `cm`. The GPU
    /// owner retains it until `deinit`; this operation performs no CPU allocation.
    pub fn colormapView(self: *Gpu, cm: Colormap) sg.View {
        const i: usize = @backingInt(cm);
        if (self.colormaps[i]) |entry| return entry.view;
        const pixels = vertex.colormap.table(cm);
        const image = sg.makeImage(.{
            .width = 256,
            .height = 1,
            .pixel_format = .RGBA8,
            .data = .{ .mip_levels = blk: {
                var levels: [sg.max_mipmaps]sg.Range = @splat(.{});
                levels[0] = .{ .ptr = pixels, .size = @sizeOf(@TypeOf(pixels.*)) };
                break :blk levels;
            } },
            .label = "vertex colormap image",
        });
        const view = sg.makeView(.{
            .texture = .{ .image = image },
            .label = "vertex colormap texture view",
        });
        self.colormaps[i] = .{ .image = image, .view = view };
        return view;
    }

    /// Destroys all shared GPU handles and frees CPU caches with the allocator
    /// retained by `init`.
    pub fn deinit(self: *Gpu) void {
        for (self.blob_storage_views.items) |maybe_view| {
            if (maybe_view) |view| sg.destroyView(view);
        }
        for (self.blob_gpu.items) |maybe_buffer| {
            if (maybe_buffer) |buffer| sg.destroyBuffer(buffer);
        }
        for (self.colormaps) |maybe_entry| {
            if (maybe_entry) |entry| {
                sg.destroyView(entry.view);
                sg.destroyImage(entry.image);
            }
        }
        sg.destroySampler(self.sampler);
        self.ranges.deinit(self.gpa);
        self.blob_storage_views.deinit(self.gpa);
        self.blob_gpu.deinit(self.gpa);
        self.blob_last_used.deinit(self.gpa);
        self.* = undefined;
    }
};

/// Resolves the structure's selected quantity on `version` without allocating.
/// The returned record owns no memory and remains valid while the scene is unchanged.
pub fn activeQuantity(
    scene: *const Scene,
    structure_index: StructureIndex,
    version: vertex.scene.Version,
) ?QuantityRef {
    const structures = scene.structures.slice();
    const active = structures.items(.ui)[indexOf(structure_index)].active_quantity;
    if (active == .none) return null;
    for (scene.quantities(structure_index, version)) |quantity| {
        if (quantity.name == active) return quantity;
    }
    return null;
}

/// Returns a borrowed f32 view of a live scalar blob without allocation.
pub fn scalarValues(scene: *const Scene, blob_index: BlobIndex) []const f32 {
    return std.mem.bytesAsSlice(f32, scene.blobBytes(blob_index));
}

/// Converts any typed scene index to a slice index without allocating.
pub fn indexOf(index: anytype) usize {
    return @backingInt(index);
}
