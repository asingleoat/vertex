//! The scene: everything the viewer knows about the geometry it is displaying.
//!
//! A scene holds named structures. A structure is a mesh, a point cloud or a
//! line set, identified by the name a sketch registered it under, holding a
//! chronological list of versions. A version is one snapshot of that
//! structure's geometry, tagged with the run and frame it arrived in, holding
//! references into a reference-counted blob store rather than copies.
//! Registering a mesh under an existing name appends a version. A
//! positions-only update appends a version sharing the previous one's topology
//! blob. The timeline costs memory in proportion to what changed per frame, and
//! scrubbing it rebinds existing GPU buffers without uploading.
//!
//! Identity is the interned name. Viewer state is keyed by the same name, so
//! the display settings for "surface" are untouched when a new run replaces the
//! geometry behind it.
//!
//! The module is pure. It performs no I/O, holds no globals and touches neither
//! sokol nor the socket. Its only memory comes from the allocator passed to
//! `init`. Its inputs are decoded
//! `protocol.Message` values, and its outputs are mutations to its own storage
//! and lists of blob indices the render edge drains. Blob bytes are either copied
//! into scene-owned storage or, on the zero-copy path, adopted as views into a
//! mapping the edge owns; see `Blob` and `Mapping`.
//!
//! Nothing allocates except where an allocator appears in the signature. The
//! notes below therefore concern ownership and lifetime.
const std = @import("std");
const layout = @import("../geometry/layout.zig");
const protocol = @import("../protocol/protocol.zig");

// ---------------------------------------------------------------------------
// types / handles

const StringTable = std.HashMapUnmanaged(
    u32,
    void,
    std.hash_map.StringIndexContext,
    std.hash_map.default_max_load_percentage,
);

/// Identifies a structure. Stable for as long as that structure exists, so it
/// is what edge code holds between frames rather than a pointer.
pub const StructureIndex = enum(u32) { none = std.math.maxInt(u32), _ };

/// Identifies a blob. The render edge uses it to index its own parallel array
/// of GPU buffers, which is how edge state attaches to scene entities.
pub const BlobIndex = enum(u32) { none = std.math.maxInt(u32), _ };

/// Identifies a registered shared mapping, with `.none` meaning that a blob's
/// bytes are scene-owned rather than a view into someone else's memory.
pub const MappingIndex = enum(u32) { none = std.math.maxInt(u32), _ };

/// Identifies an interned string, as a byte offset into one shared buffer.
/// ---
/// Names are interned once, on first registration, so comparing two structures'
/// names is comparing two integers. A `[]const u8` obtained from `string` is
/// invalidated by interning anything else, which may move the buffer. Hold the
/// index, not the slice.
pub const StringIndex = enum(u32) { none = std.math.maxInt(u32), _ };

/// What a structure is: a triangle mesh, a point cloud or a set of line
/// segments. It is fixed when the structure is first registered; registering the
/// same name as a different kind replaces its history rather than appending.
pub const Kind = enum(u8) { mesh, points, lines };

/// Whether a quantity holds one `f32` per element or one vector per element.
pub const QuantityKind = enum(u8) { scalar, vector };

/// The live-blob limit. The value owns no memory and changing it allocates
/// nothing; a lowered byte budget takes effect on the next apply or on an
/// explicit call to `Scene.enforceBudget`. Only the current run is retained, so
/// beginning a new run frees the previous run's versions.
pub const Retention = struct {
    budget_bytes: usize = 2 * 1024 * 1024 * 1024,
};

/// A snapshot of what the scene currently costs: live blob bytes and count,
/// retained versions, and versions evicted since the run began. The viewer
/// displays these and the smoke tests assert on them.
pub const MemoryStats = struct {
    blob_bytes: usize,
    mapped_bytes: usize,
    blob_count: u32,
    versions: u32,
    evicted_versions: u32,
};

/// How a structure is displayed, keyed by name rather than by structure. A new
/// run replaces geometry and leaves these settings in force, so visibility,
/// colormap and sizes survive a rebuild.
pub const UiState = struct {
    visible: bool = true,
    wireframe: bool = false,
    active_quantity: StringIndex = .none,
    point_size: f32 = 4,
    line_width: f32 = 1.5,
    colormap: @import("colormap.zig").Colormap = .viridis,
    vector_scale: f32 = 1.0,
};

/// One snapshot of a structure's geometry, tagged with the run and frame it
/// arrived in.
/// ---
/// It holds references rather than data: a positions blob, an optional topology
/// blob, and a range of quantity references in the structure's side array. Two
/// versions that differ only in vertex positions share one topology blob, so a
/// positions-only update stores and uploads only the new positions. The
/// references are owned by the containing structure until the version is
/// dropped.
pub const Version = struct {
    run: u32,
    frame: u32,
    positions: BlobIndex,
    topology: BlobIndex,
    quantity_start: u32,
    quantity_len: u32,
};

/// One named field attached to a version: which name, what kind, what it
/// attaches to, how many values, and the blob holding them. These live
/// contiguously in a per-structure side array, addressed by the range a
/// `Version` records.
pub const QuantityRef = struct {
    name: StringIndex,
    blob: BlobIndex,
    count: u32,
    _reserved: u32 = 0,
    target: protocol.Target,
    kind: QuantityKind,
};

/// A named renderable and its history: the interned name, what kind it is, how
/// many dimensions it claims, every version so far, and the side array those
/// versions address for their quantities.
/// ---
/// A structure with no versions has been discarded by a run that did not
/// register it. Its slot and `UiState` remain, and registering the name again
/// restores it.
/// The arrays are owned by the scene and released by `Scene.deinit`.
pub const Structure = struct {
    versions: std.ArrayList(Version) = .empty,
    quantity_refs: std.ArrayList(QuantityRef) = .empty,
    ui: UiState = .{},
    name: StringIndex,
    kind: Kind,
    dim: protocol.Dim,
    touched: bool = false,
};

/// A reference-counted run of bytes: the positions, topology or quantity values
/// that versions point at.
/// ---
/// Two versions referring to the same topology hold one blob between them, which
/// is freed when the last reference goes. The bytes are either scene-owned,
/// allocated 64-byte aligned, with `mapping` set to `.none`, or a view into a
/// registered mapping, in which case the blob holds a reference on that mapping
/// until its own last release.
pub const Blob = struct {
    bytes: []align(layout.blob_alignment.toByteUnits()) const u8,
    refcount: u32,
    mapping: MappingIndex,
};

/// A shared memory region that the edge has mapped and the scene may point
/// into.
/// ---
/// The socket thread maps a descriptor the client sent and registers the region
/// here, and blobs then adopt slices of it as views instead of copying. The scene
/// never unmaps or closes anything. It counts references and, when a mapping
/// reaches zero, queues its index in `released_mappings` for the edge. Ownership
/// remains with the edge.
pub const Mapping = struct {
    bytes: []align(layout.blob_alignment.toByteUnits()) const u8,
    fd: i32,
    refcount: u32,
};

/// One line in the viewer's console, with its text interned in the scene.
pub const LogEntry = struct {
    level: protocol.LogLevel,
    text: StringIndex,
};

/// The ways applying a message can fail.
/// ---
/// Out of memory is reported without leaving the scene inconsistent or leaking.
/// Every other error describes a message that is well-formed but not applicable,
/// such as a quantity naming a structure that does not exist or a positions
/// update whose vertex count disagrees with the mesh it names; the scene is
/// unchanged in those cases.
pub const ApplyError = std.mem.Allocator.Error || error{
    UnknownStructure,
    KindMismatch,
    CountMismatch,
    NoRunActive,
};

/// How many console lines the scene retains. Beyond this the oldest entry is
/// dropped and the array does not grow further. The interned text of a dropped
/// entry stays in the string buffer, because interning is append-only.
pub const max_log_entries: usize = 1024;

const empty_blob_storage: [0]u8 align(layout.blob_alignment.toByteUnits()) = .{};
const empty_mapping_storage: [0]u8 align(layout.blob_alignment.toByteUnits()) = .{};

const EvictionCandidate = struct {
    structure: StructureIndex,
    version: u32,
};

const QuantityReplacement = struct {
    offset: u32,
    value: QuantityRef,
};

fn indexOf(index: anytype) usize {
    return @backingInt(index);
}

fn emptyBlobBytes() []align(layout.blob_alignment.toByteUnits()) const u8 {
    return empty_blob_storage[0..];
}

fn emptyMappingBytes() []align(layout.blob_alignment.toByteUnits()) const u8 {
    return empty_mapping_storage[0..];
}

/// The scene itself: the structures, their versions, the blob store those
/// versions point into, the registered mappings, the interned strings and the
/// console log.
/// ---
/// A viewer holds one. Messages go in through `apply`, which is the only way its
/// contents change; the render edge then reads through `versionAt`,
/// `positionsOf`, `facesOf` and their neighbours, and drains `new_blobs` and
/// `freed_blobs` to keep its GPU buffers in step. Every allocation uses the
/// allocator given to `init`, and `deinit` releases all of it, after the edge
/// has taken back the mappings it owns.
pub const Scene = struct {
    gpa: std.mem.Allocator,
    strings: std.ArrayList(u8) = .empty,
    string_table: StringTable = .empty,
    structures: std.MultiArrayList(Structure) = .empty,
    by_name: std.AutoHashMapUnmanaged(StringIndex, StructureIndex) = .empty,
    blobs: std.MultiArrayList(Blob) = .empty,
    blob_free: std.ArrayList(BlobIndex) = .empty,
    new_blobs: std.ArrayList(BlobIndex) = .empty,
    freed_blobs: std.ArrayList(BlobIndex) = .empty,
    mappings: std.MultiArrayList(Mapping) = .empty,
    mapping_free: std.ArrayList(MappingIndex) = .empty,
    released_mappings: std.ArrayList(MappingIndex) = .empty,
    frame_labels: std.ArrayList(StringIndex) = .empty,
    log: std.ArrayList(LogEntry) = .empty,
    retention: Retention = .{},
    run: u32 = 0,
    frame: u32 = 0,
    run_active: bool = false,
    source_name: StringIndex = .none,
    live_blobs: u32 = 0,
    live_mappings: u32 = 0,
    blob_bytes: usize = 0,
    evicted_versions: u32 = 0,
    decimation_level: u8 = 1,

    // -----------------------------------------------------------------------
    // Scene lifecycle

    /// Returns an empty scene. Nothing is allocated until the first message is
    /// applied. `gpa` must stay valid until `deinit`.
    ///
    /// O(1).
    pub fn init(gpa: std.mem.Allocator) Scene {
        return .{ .gpa = gpa };
    }

    /// Frees everything the scene owns.
    ///
    /// The edge must first call `takeAllMappings` and unmap and close what it
    /// receives, because the scene borrows those regions and cannot release
    /// them. Every view and index obtained from the scene is invalid
    /// afterwards.
    ///
    /// O(n) in the structures, versions and blobs held.
    pub fn deinit(self: *Scene) void {
        std.debug.assert(self.live_mappings == 0);
        var structures = self.structures.slice();
        const versions = structures.items(.versions);
        const quantity_refs = structures.items(.quantity_refs);
        for (versions, quantity_refs) |*version_list, *quantity_list| {
            version_list.deinit(self.gpa);
            quantity_list.deinit(self.gpa);
        }

        var blobs = self.blobs.slice();
        const bytes = blobs.items(.bytes);
        const refcounts = blobs.items(.refcount);
        const blob_mappings = blobs.items(.mapping);
        for (bytes, refcounts, blob_mappings) |blob_bytes, refcount, mapping| {
            if (refcount != 0 and mapping == .none) self.gpa.free(blob_bytes);
        }

        self.released_mappings.deinit(self.gpa);
        self.mapping_free.deinit(self.gpa);
        self.mappings.deinit(self.gpa);
        self.log.deinit(self.gpa);
        self.frame_labels.deinit(self.gpa);
        self.freed_blobs.deinit(self.gpa);
        self.new_blobs.deinit(self.gpa);
        self.blob_free.deinit(self.gpa);
        self.blobs.deinit(self.gpa);
        self.by_name.deinit(self.gpa);
        self.structures.deinit(self.gpa);
        self.string_table.deinit(self.gpa);
        self.strings.deinit(self.gpa);
        self.* = undefined;
    }

    // -----------------------------------------------------------------------
    // apply + per-message handlers

    /// Applies one decoded message, and is the only way a scene changes.
    ///
    /// Geometry messages register or update a structure and append a version;
    /// quantity messages attach a field to a structure that already exists; the
    /// run and frame messages advance the lifecycle that versions are tagged
    /// with. What a message means is described in `protocol.Kind`.
    ///
    /// Slices that lie inside a registered mapping are adopted as
    /// reference-counted views, so the zero-copy path stores nothing new;
    /// everything else is copied into scene-owned storage before this returns,
    /// so the caller's payload can be reused immediately. On any error the scene
    /// is left unchanged.
    ///
    /// lookup by name.
    ///
    /// O(n) in the message's sections, which are copied into blobs, plus a
    /// lookup by name and whatever eviction the budget then forces.
    pub fn apply(self: *Scene, message: protocol.Message) ApplyError!void {
        switch (message) {
            .hello => |hello| {
                self.source_name = try self.intern(hello.name);
                return;
            },
            .begin_run => {
                // Frame 0 is implicit on the wire (no begin_frame(0) is sent),
                // so it must exist in frame_labels for frameCount/scrubbing.
                try self.frame_labels.ensureTotalCapacity(self.gpa, 1);
                self.run +%= 1;
                self.frame = 0;
                self.frame_labels.clearRetainingCapacity();
                self.frame_labels.appendAssumeCapacity(.none);
                self.run_active = true;
                self.evicted_versions = 0;
                self.decimation_level = 1;
                self.releaseExpiredRuns();
                var structures = self.structures.slice();
                @memset(structures.items(.touched), false);
                return;
            },
            else => {},
        }

        if (!self.run_active) return error.NoRunActive;
        const created_blob = switch (message) {
            .hello, .begin_run => unreachable,
            .begin_frame => |begin| blk: {
                try self.beginFrame(begin.index, begin.label);
                break :blk false;
            },
            .end_frame => false,
            .end_run => blk: {
                self.endRun();
                break :blk false;
            },
            .mesh => |mesh| blk: {
                try self.registerGeometry(
                    mesh.name,
                    .mesh,
                    mesh.dim,
                    mesh.positions,
                    std.mem.sliceAsBytes(mesh.faces),
                );
                break :blk true;
            },
            .mesh_positions => |update| blk: {
                try self.updateMeshPositions(update);
                break :blk true;
            },
            .points => |points| blk: {
                try self.registerGeometry(
                    points.name,
                    .points,
                    points.dim,
                    points.positions,
                    null,
                );
                break :blk true;
            },
            .lines => |lines| blk: {
                try self.registerGeometry(
                    lines.name,
                    .lines,
                    lines.dim,
                    lines.positions,
                    std.mem.sliceAsBytes(lines.segments),
                );
                break :blk true;
            },
            .scalar_quantity => |quantity| blk: {
                try self.putQuantity(
                    quantity.structure,
                    quantity.name,
                    quantity.target,
                    .scalar,
                    @intCast(quantity.values.len),
                    std.mem.sliceAsBytes(quantity.values),
                );
                break :blk true;
            },
            .vector_quantity => |quantity| blk: {
                try self.putQuantity(
                    quantity.structure,
                    quantity.name,
                    quantity.target,
                    .vector,
                    quantity.vectors.len(),
                    quantity.vectors.bytes(),
                );
                break :blk true;
            },
            .log => |entry| blk: {
                try self.appendLog(entry);
                break :blk false;
            },
        };
        if (created_blob) self.enforceBudget();
    }

    fn beginFrame(self: *Scene, frame: u32, label_text: []const u8) std.mem.Allocator.Error!void {
        const label = try self.intern(label_text);
        const needed: usize = @as(usize, frame) + 1;
        if (needed > self.frame_labels.items.len) {
            const additional = needed - self.frame_labels.items.len;
            try self.frame_labels.ensureUnusedCapacity(self.gpa, additional);
            for (0..additional) |_| self.frame_labels.appendAssumeCapacity(.none);
        }
        self.frame_labels.items[frame] = label;
        self.frame = frame;
    }

    /// Ends the run, discarding every structure that the run did not register.
    ///
    /// `versionAt` returns null for a structure with no versions, so it is
    /// neither drawn nor listed. Its slot and `UiState` remain keyed by name, so
    /// registering that name again restores the structure with its previous
    /// viewer settings.
    fn endRun(self: *Scene) void {
        var structure_i: usize = 0;
        while (structure_i < self.structures.len) : (structure_i += 1) {
            if (self.structures.slice().items(.touched)[structure_i]) continue;
            self.releaseAllVersions(@fromBackingInt(@intCast(structure_i)));
        }
        self.run_active = false;
    }

    /// Releases every version of `structure_index` and frees the blobs they
    /// hold. The structure retains its slot, its name binding and its
    /// `UiState`.
    fn releaseAllVersions(self: *Scene, structure_index: StructureIndex) void {
        const i = indexOf(structure_index);
        var structures = self.structures.slice();
        const versions = &structures.items(.versions)[i];
        const quantity_list = &structures.items(.quantity_refs)[i];
        const removed_count = versions.items.len;
        for (versions.items) |version| self.releaseVersion(structure_index, version);
        versions.clearRetainingCapacity();
        quantity_list.clearRetainingCapacity();
        self.evicted_versions +|= @intCast(removed_count);
    }

    fn registerGeometry(
        self: *Scene,
        name_text: []const u8,
        kind: Kind,
        dim: protocol.Dim,
        positions: layout.Positions.Const,
        topology_bytes: ?[]const u8,
    ) std.mem.Allocator.Error!void {
        const name = try self.intern(name_text);
        const blob_count: usize = if (topology_bytes == null) 1 else 2;
        var created_structure = false;
        const structure_index = self.by_name.get(name) orelse blk: {
            try self.structures.ensureTotalCapacity(self.gpa, self.structures.len + 1);
            try self.by_name.ensureUnusedCapacity(self.gpa, 1);
            const new_index: StructureIndex = @fromBackingInt(@intCast(@as(u32, @intCast(self.structures.len))));
            self.structures.appendAssumeCapacity(.{ .name = name, .kind = kind, .dim = dim });
            self.by_name.putAssumeCapacityNoClobber(name, new_index);
            created_structure = true;
            break :blk new_index;
        };
        errdefer if (created_structure) self.discardCreatedStructure(structure_index);

        const i = indexOf(structure_index);
        var structures = self.structures.slice();
        const version_list = &structures.items(.versions)[i];
        const quantity_list = &structures.items(.quantity_refs)[i];
        try version_list.ensureUnusedCapacity(self.gpa, 1);
        try self.reserveBlobCreates(blob_count);

        const position_blob = try self.createBlobAssumeReserved(positions.bytes());
        errdefer self.discardCreatedBlob(position_blob);
        const topology_blob = if (topology_bytes) |bytes|
            try self.createBlobAssumeReserved(bytes)
        else
            BlobIndex.none;

        const replace_history = version_list.items.len != 0 and
            (structures.items(.kind)[i] != kind or structures.items(.dim)[i] != dim);
        self.appendVersionAssumeCapacity(
            structure_index,
            position_blob,
            topology_blob,
            @intCast(quantity_list.items.len),
            0,
        );
        if (replace_history) self.collapseToLatest(structure_index);
        self.releaseExpiredVersions(structure_index);

        structures = self.structures.slice();
        structures.items(.kind)[i] = kind;
        structures.items(.dim)[i] = dim;
        structures.items(.touched)[i] = true;
    }

    fn discardCreatedStructure(self: *Scene, structure_index: StructureIndex) void {
        std.debug.assert(indexOf(structure_index) == self.structures.len - 1);
        var structure = self.structures.pop().?;
        std.debug.assert(structure.versions.items.len == 0);
        std.debug.assert(structure.quantity_refs.items.len == 0);
        std.debug.assert(self.by_name.remove(structure.name));
        structure.versions.deinit(self.gpa);
        structure.quantity_refs.deinit(self.gpa);
    }

    fn appendVersionAssumeCapacity(
        self: *Scene,
        structure_index: StructureIndex,
        positions: BlobIndex,
        topology: BlobIndex,
        quantity_start: u32,
        quantity_len: u32,
    ) void {
        var structures = self.structures.slice();
        structures.items(.versions)[indexOf(structure_index)].appendAssumeCapacity(.{
            .run = self.run,
            .frame = self.frame,
            .positions = positions,
            .topology = topology,
            .quantity_start = quantity_start,
            .quantity_len = quantity_len,
        });
    }

    fn inheritQuantityRefsAssumeCapacity(
        self: *Scene,
        structure_index: StructureIndex,
        previous: Version,
        replacement: ?QuantityReplacement,
    ) u32 {
        var structures = self.structures.slice();
        const quantity_list = &structures.items(.quantity_refs)[indexOf(structure_index)];
        const quantity_start: u32 = @intCast(quantity_list.items.len);
        const previous_start: usize = previous.quantity_start;
        const previous_end = previous_start + previous.quantity_len;
        for (quantity_list.items[previous_start..previous_end], 0..) |quantity, offset| {
            if (replacement) |item| {
                if (offset == item.offset) {
                    quantity_list.appendAssumeCapacity(item.value);
                    continue;
                }
            }
            self.retainBlob(quantity.blob);
            quantity_list.appendAssumeCapacity(quantity);
        }
        return quantity_start;
    }

    fn updateMeshPositions(self: *Scene, update: protocol.MeshPositions) ApplyError!void {
        const structure_index = self.find(update.name) orelse return error.UnknownStructure;
        const i = indexOf(structure_index);
        var structures = self.structures.slice();
        if (structures.items(.kind)[i] != .mesh) return error.KindMismatch;
        const version_list = &structures.items(.versions)[i];
        if (version_list.items.len == 0) return error.UnknownStructure;
        const previous = version_list.items[version_list.items.len - 1];
        if (self.positionsOf(previous).len() != update.positions.len()) return error.CountMismatch;

        const quantity_list = &structures.items(.quantity_refs)[i];
        try version_list.ensureUnusedCapacity(self.gpa, 1);
        try quantity_list.ensureUnusedCapacity(self.gpa, previous.quantity_len);
        try self.reserveBlobCreates(1);

        const position_blob = try self.createBlobAssumeReserved(update.positions.bytes());
        self.retainBlob(previous.topology);
        const quantity_start = self.inheritQuantityRefsAssumeCapacity(structure_index, previous, null);
        self.appendVersionAssumeCapacity(
            structure_index,
            position_blob,
            previous.topology,
            quantity_start,
            previous.quantity_len,
        );
        self.releaseExpiredVersions(structure_index);
        structures = self.structures.slice();
        structures.items(.touched)[i] = true;
    }

    fn putQuantity(
        self: *Scene,
        structure_name: []const u8,
        quantity_name: []const u8,
        target: protocol.Target,
        kind: QuantityKind,
        count: u32,
        bytes: []const u8,
    ) ApplyError!void {
        const structure_index = self.find(structure_name) orelse return error.UnknownStructure;
        const i = indexOf(structure_index);
        var structures = self.structures.slice();
        const version_list = &structures.items(.versions)[i];
        if (version_list.items.len == 0) return error.UnknownStructure;
        const previous = version_list.items[version_list.items.len - 1];
        const expected_count = self.expectedCount(structure_index, previous, target) orelse
            return error.CountMismatch;
        if (count != expected_count) return error.CountMismatch;

        const name = try self.intern(quantity_name);
        structures = self.structures.slice();
        const quantity_list = &structures.items(.quantity_refs)[i];
        const old_refs = self.quantities(structure_index, previous);
        var replace_index: ?usize = null;
        for (old_refs, 0..) |quantity, offset| {
            if (quantity.name == name) {
                replace_index = @as(usize, previous.quantity_start) + offset;
                break;
            }
        }

        const new_ref: QuantityRef = .{
            .name = name,
            .blob = undefined,
            .count = count,
            .target = target,
            .kind = kind,
        };
        if (previous.run == self.run and previous.frame == self.frame) {
            if (replace_index == null) try quantity_list.ensureUnusedCapacity(self.gpa, 1);
            try self.reserveBlobCreates(1);
            const blob = try self.createBlobAssumeReserved(bytes);
            if (replace_index) |quantity_index| {
                const old_blob = quantity_list.items[quantity_index].blob;
                quantity_list.items[quantity_index] = new_ref;
                quantity_list.items[quantity_index].blob = blob;
                self.releaseBlob(old_blob);
            } else {
                std.debug.assert(@as(usize, previous.quantity_start) + previous.quantity_len == quantity_list.items.len);
                var appended = new_ref;
                appended.blob = blob;
                quantity_list.appendAssumeCapacity(appended);
                version_list.items[version_list.items.len - 1].quantity_len += 1;
            }
        } else {
            const additional = old_refs.len + @intFromBool(replace_index == null);
            try version_list.ensureUnusedCapacity(self.gpa, 1);
            try quantity_list.ensureUnusedCapacity(self.gpa, additional);
            try self.reserveBlobCreates(1);
            const blob = try self.createBlobAssumeReserved(bytes);

            self.retainBlob(previous.positions);
            if (previous.topology != .none) self.retainBlob(previous.topology);
            const replacement: ?QuantityReplacement = if (replace_index) |old_index| blk: {
                var value = new_ref;
                value.blob = blob;
                break :blk .{
                    .offset = @intCast(old_index - @as(usize, previous.quantity_start)),
                    .value = value,
                };
            } else null;
            const quantity_start = self.inheritQuantityRefsAssumeCapacity(
                structure_index,
                previous,
                replacement,
            );
            if (replacement == null) {
                structures = self.structures.slice();
                var appended = new_ref;
                appended.blob = blob;
                structures.items(.quantity_refs)[i].appendAssumeCapacity(appended);
            }
            self.appendVersionAssumeCapacity(
                structure_index,
                previous.positions,
                previous.topology,
                quantity_start,
                @intCast(additional),
            );
        }
        self.releaseExpiredVersions(structure_index);

        structures = self.structures.slice();
        if (structures.items(.ui)[i].active_quantity == .none) {
            structures.items(.ui)[i].active_quantity = name;
        }
        structures.items(.touched)[i] = true;
    }

    fn appendLog(self: *Scene, entry: protocol.Log) std.mem.Allocator.Error!void {
        const text = try self.intern(entry.text);
        if (self.log.items.len < max_log_entries) {
            try self.log.ensureUnusedCapacity(self.gpa, 1);
            self.log.appendAssumeCapacity(.{ .level = entry.level, .text = text });
            return;
        }
        std.mem.copyForwards(LogEntry, self.log.items[0 .. max_log_entries - 1], self.log.items[1..]);
        self.log.items[max_log_entries - 1] = .{ .level = entry.level, .text = text };
    }

    fn expectedCount(
        self: *const Scene,
        structure_index: StructureIndex,
        version: Version,
        target: protocol.Target,
    ) ?u32 {
        if (target == .face) {
            const structures = self.structures.slice();
            if (structures.items(.kind)[indexOf(structure_index)] != .mesh) return null;
            return @intCast(self.facesOf(version).len);
        }
        return self.positionsOf(version).len();
    }

    // -----------------------------------------------------------------------
    // retention & budget

    /// Enforces the configured byte budget by progressively decimating the
    /// current run's history. Only the current run is retained, so there are
    /// never versions from an earlier run to release first. The operation
    /// allocates nothing; released ranges in the quantity side array remain as
    /// unused holes.
    ///
    /// frame order.
    ///
    /// O(r·v) in the versions held and the number it removes: each removal
    /// scans for its candidate, and the scan repeats at up to sixteen
    /// decimation levels before giving up.
    pub fn enforceBudget(self: *Scene) void {
        while (self.blob_bytes > self.retention.budget_bytes) {
            var candidate = self.findDecimationCandidate();
            while (candidate == null and self.decimation_level < 16) {
                self.decimation_level += 1;
                candidate = self.findDecimationCandidate();
            }
            if (candidate == null) return;
            self.removeVersion(candidate.?.structure, candidate.?.version);
        }
    }

    fn collapseToLatest(self: *Scene, structure_index: StructureIndex) void {
        const i = indexOf(structure_index);
        var structures = self.structures.slice();
        const versions = &structures.items(.versions)[i];
        const quantity_list = &structures.items(.quantity_refs)[i];
        std.debug.assert(versions.items.len > 0);
        const latest = versions.items[versions.items.len - 1];

        const removed_count = versions.items.len - 1;
        for (versions.items[0..removed_count]) |version| self.releaseVersion(structure_index, version);
        const start: usize = latest.quantity_start;
        const len: usize = latest.quantity_len;
        std.mem.copyForwards(QuantityRef, quantity_list.items[0..len], quantity_list.items[start .. start + len]);
        quantity_list.items.len = len;
        versions.items[0] = latest;
        versions.items[0].quantity_start = 0;
        versions.items.len = 1;
        self.evicted_versions +|= @intCast(removed_count);
    }

    fn releaseVersion(self: *Scene, structure_index: StructureIndex, version: Version) void {
        self.releaseBlob(version.positions);
        if (version.topology != .none) self.releaseBlob(version.topology);
        for (self.quantities(structure_index, version)) |quantity| self.releaseBlob(quantity.blob);
    }

    fn releaseExpiredRuns(self: *Scene) void {
        var structure_i: usize = 0;
        while (structure_i < self.structures.len) : (structure_i += 1) {
            const structure_index: StructureIndex = @fromBackingInt(@intCast(structure_i));
            self.releaseExpiredVersions(structure_index);
        }
    }

    /// Drops every version left over from an earlier run. Only the current run
    /// is retained, so a rebuild never leaves the previous run's geometry in the
    /// scene. The most recent version survives until the current run replaces
    /// it.
    fn releaseExpiredVersions(self: *Scene, structure_index: StructureIndex) void {
        if (self.run < 1) return;
        const last_expired_run = self.run - 1;
        while (true) {
            const structures = self.structures.slice();
            const versions = structures.items(.versions)[indexOf(structure_index)].items;
            if (versions.len <= 1) return;
            var expired: ?u32 = null;
            for (versions, 0..) |version, version_i| {
                if (version.run <= last_expired_run) {
                    expired = @intCast(version_i);
                    break;
                }
            }
            if (expired) |version_i| {
                self.removeVersion(structure_index, version_i);
            } else return;
        }
    }

    fn findDecimationCandidate(self: *const Scene) ?EvictionCandidate {
        const stride = @as(u32, 1) << @intCast(self.decimation_level);
        const structures = self.structures.slice();
        const version_lists = structures.items(.versions);
        var best: ?EvictionCandidate = null;
        for (version_lists, 0..) |version_list, structure_i| {
            if (version_list.items.len <= 1) continue;
            for (version_list.items[0 .. version_list.items.len - 1], 0..) |version, version_i| {
                if (version.run != self.run or version.frame == 0 or version.frame % stride == 0) continue;
                const candidate: EvictionCandidate = .{
                    .structure = @fromBackingInt(@intCast(structure_i)),
                    .version = @intCast(version_i),
                };
                if (best) |current| {
                    const current_versions = version_lists[indexOf(current.structure)].items;
                    if (version.frame >= current_versions[current.version].frame) continue;
                }
                best = candidate;
            }
        }
        return best;
    }

    fn removeVersion(self: *Scene, structure_index: StructureIndex, version_index: u32) void {
        const structure_i = indexOf(structure_index);
        var structures = self.structures.slice();
        const versions = &structures.items(.versions)[structure_i];
        const version_i: usize = version_index;
        std.debug.assert(version_i < versions.items.len);
        const removed = versions.items[version_i];
        self.releaseVersion(structure_index, removed);
        std.mem.copyForwards(
            Version,
            versions.items[version_i .. versions.items.len - 1],
            versions.items[version_i + 1 ..],
        );
        versions.items.len -= 1;
        self.evicted_versions +|= 1;
    }

    // -----------------------------------------------------------------------
    // blob store

    /// Creates a blob holding `bytes` and returns its index, with one
    /// reference already held by the caller.
    ///
    /// Bytes that lie inside a registered mapping are adopted as a view, taking
    /// a reference on that mapping; anything else is copied into scene-owned
    /// storage aligned to 64 bytes. Either way the new index is queued in
    /// `new_blobs`, which is how the render edge learns it has a buffer to
    /// upload.
    ///
    /// mapping.
    ///
    /// O(n) in the bytes stored, or O(1) for a blob that views a registered
    /// mapping rather than copying.
    pub fn createBlob(self: *Scene, bytes: []const u8) std.mem.Allocator.Error!BlobIndex {
        try self.reserveBlobCreates(1);
        return self.createBlobAssumeReserved(bytes);
    }

    /// Takes another reference to a live blob. Every version pointing at a blob
    /// holds one reference, so several versions can share one blob.
    ///
    /// O(1).
    pub fn retainBlob(self: *Scene, blob_index: BlobIndex) void {
        std.debug.assert(blob_index != .none);
        var blobs = self.blobs.slice();
        const refcount = &blobs.items(.refcount)[indexOf(blob_index)];
        std.debug.assert(refcount.* > 0);
        refcount.* += 1;
    }

    /// Drops one reference to a blob.
    ///
    /// At zero, scene-owned bytes are freed, while a view releases its
    /// reference on the mapping and may queue that mapping for the edge to
    /// unmap. The index goes onto the free list for reuse and onto
    /// `freed_blobs`, which the render edge drains to destroy the matching GPU
    /// buffer.
    ///
    /// O(1) amortized, freeing the bytes when the last reference goes.
    pub fn releaseBlob(self: *Scene, blob_index: BlobIndex) void {
        std.debug.assert(blob_index != .none);
        var blobs = self.blobs.slice();
        const i = indexOf(blob_index);
        const refcount = &blobs.items(.refcount)[i];
        std.debug.assert(refcount.* > 0);
        refcount.* -= 1;
        if (refcount.* != 0) return;

        self.blob_bytes -= blobs.items(.bytes)[i].len;
        const mapping_index = blobs.items(.mapping)[i];
        if (mapping_index == .none) {
            self.gpa.free(blobs.items(.bytes)[i]);
        } else {
            var mappings = self.mappings.slice();
            const mapping_refcount = &mappings.items(.refcount)[indexOf(mapping_index)];
            std.debug.assert(mapping_refcount.* > 0);
            mapping_refcount.* -= 1;
            if (mapping_refcount.* == 0) self.queueMappingRelease(mapping_index);
        }
        blobs.items(.bytes)[i] = emptyBlobBytes();
        blobs.items(.mapping)[i] = .none;
        var pending = self.new_blobs.items.len;
        while (pending > 0) {
            pending -= 1;
            if (self.new_blobs.items[pending] != blob_index) continue;
            std.mem.copyForwards(
                BlobIndex,
                self.new_blobs.items[pending .. self.new_blobs.items.len - 1],
                self.new_blobs.items[pending + 1 ..],
            );
            self.new_blobs.items.len -= 1;
            break;
        }
        self.blob_free.appendAssumeCapacity(blob_index);
        self.freed_blobs.appendAssumeCapacity(blob_index);
        self.live_blobs -= 1;
    }

    /// The bytes of a live blob, aligned to 64 bytes. The view is valid until
    /// that blob's last reference is released or the scene is deinitialized.
    ///
    /// O(1).
    pub fn blobBytes(self: *const Scene, blob_index: BlobIndex) []align(layout.blob_alignment.toByteUnits()) const u8 {
        std.debug.assert(blob_index != .none);
        const blobs = self.blobs.slice();
        const i = indexOf(blob_index);
        std.debug.assert(blobs.items(.refcount)[i] > 0);
        return blobs.items(.bytes)[i];
    }

    fn reserveBlobCreates(self: *Scene, count: usize) std.mem.Allocator.Error!void {
        const free_count = self.blob_free.items.len;
        const new_slots = count -| free_count;
        try self.blobs.ensureTotalCapacity(self.gpa, self.blobs.len + new_slots);
        try self.new_blobs.ensureUnusedCapacity(self.gpa, count);
        try self.blob_free.ensureTotalCapacity(self.gpa, self.blobs.len + new_slots);
        try self.freed_blobs.ensureUnusedCapacity(self.gpa, @as(usize, self.live_blobs) + count);
    }

    fn createBlobAssumeReserved(self: *Scene, bytes: []const u8) std.mem.Allocator.Error!BlobIndex {
        const mapping_index = self.mappingContaining(bytes) orelse .none;
        const stored: []align(layout.blob_alignment.toByteUnits()) const u8 = if (mapping_index == .none) blk: {
            const owned = try self.gpa.alignedAlloc(u8, layout.blob_alignment, bytes.len);
            @memcpy(owned, bytes);
            break :blk owned;
        } else blk: {
            std.debug.assert(@intFromPtr(bytes.ptr) % layout.blob_alignment.toByteUnits() == 0);
            var mappings = self.mappings.slice();
            mappings.items(.refcount)[indexOf(mapping_index)] += 1;
            break :blk @alignCast(bytes);
        };

        const blob_index = if (self.blob_free.pop()) |free_index| blk: {
            var blobs = self.blobs.slice();
            const i = indexOf(free_index);
            std.debug.assert(blobs.items(.refcount)[i] == 0);
            blobs.items(.bytes)[i] = stored;
            blobs.items(.refcount)[i] = 1;
            blobs.items(.mapping)[i] = mapping_index;
            break :blk free_index;
        } else blk: {
            const new_index: BlobIndex = @fromBackingInt(@intCast(@as(u32, @intCast(self.blobs.len))));
            self.blobs.appendAssumeCapacity(.{
                .bytes = stored,
                .refcount = 1,
                .mapping = mapping_index,
            });
            break :blk new_index;
        };
        self.new_blobs.appendAssumeCapacity(blob_index);
        self.live_blobs += 1;
        self.blob_bytes += stored.len;
        return blob_index;
    }

    fn discardCreatedBlob(self: *Scene, blob_index: BlobIndex) void {
        const queued = self.new_blobs.pop().?;
        std.debug.assert(queued == blob_index);
        var blobs = self.blobs.slice();
        const i = indexOf(blob_index);
        std.debug.assert(blobs.items(.refcount)[i] == 1);
        self.blob_bytes -= blobs.items(.bytes)[i].len;
        const mapping_index = blobs.items(.mapping)[i];
        if (mapping_index == .none) {
            self.gpa.free(blobs.items(.bytes)[i]);
        } else {
            var mappings = self.mappings.slice();
            const refcount = &mappings.items(.refcount)[indexOf(mapping_index)];
            std.debug.assert(refcount.* > 0);
            refcount.* -= 1;
            if (refcount.* == 0) self.queueMappingRelease(mapping_index);
        }
        blobs.items(.bytes)[i] = emptyBlobBytes();
        blobs.items(.refcount)[i] = 0;
        blobs.items(.mapping)[i] = .none;
        self.blob_free.appendAssumeCapacity(blob_index);
        self.live_blobs -= 1;
    }

    // -----------------------------------------------------------------------
    // mappings

    /// Registers a shared region the edge has mapped, for blobs to adopt slices
    /// of instead of copying.
    ///
    /// The scene borrows the bytes and the descriptor and never closes either;
    /// it starts the mapping at zero references, which rise as blobs adopt it.
    /// Registration reserves the queue space that every future release of this
    /// mapping will need, so releasing can never fail for want of memory.
    ///
    /// O(1) amortized.
    pub fn registerMapping(
        self: *Scene,
        bytes: []align(layout.blob_alignment.toByteUnits()) const u8,
        fd: i32,
    ) std.mem.Allocator.Error!MappingIndex {
        const new_slots = @intFromBool(self.mapping_free.items.len == 0);
        try self.mappings.ensureTotalCapacity(self.gpa, self.mappings.len + new_slots);
        try self.mapping_free.ensureTotalCapacity(self.gpa, self.mappings.len + new_slots);
        try self.released_mappings.ensureUnusedCapacity(self.gpa, @as(usize, self.live_mappings) + 1);

        const mapping_index = if (self.mapping_free.pop()) |free_index| blk: {
            var mappings = self.mappings.slice();
            const i = indexOf(free_index);
            std.debug.assert(mappings.items(.fd)[i] == -1);
            mappings.items(.bytes)[i] = bytes;
            mappings.items(.fd)[i] = fd;
            mappings.items(.refcount)[i] = 0;
            break :blk free_index;
        } else blk: {
            const new_index: MappingIndex = @fromBackingInt(@intCast(@as(u32, @intCast(self.mappings.len))));
            self.mappings.appendAssumeCapacity(.{ .bytes = bytes, .fd = fd, .refcount = 0 });
            break :blk new_index;
        };
        self.live_mappings += 1;
        return mapping_index;
    }

    /// The bytes of a registered mapping, borrowed from the edge and valid
    /// until the edge forgets that mapping.
    ///
    /// O(1).
    pub fn mappingBytes(
        self: *const Scene,
        mapping_index: MappingIndex,
    ) []align(layout.blob_alignment.toByteUnits()) const u8 {
        std.debug.assert(mapping_index != .none);
        const mappings = self.mappings.slice();
        const i = indexOf(mapping_index);
        std.debug.assert(mappings.items(.fd)[i] >= 0);
        return mappings.items(.bytes)[i];
    }

    /// The record for a registered mapping, copied out. The edge still owns the
    /// region and must not unmap or close it before calling `forgetMapping`.
    ///
    /// O(1).
    pub fn mappingValue(self: *const Scene, mapping_index: MappingIndex) Mapping {
        std.debug.assert(mapping_index != .none);
        const mappings = self.mappings.slice();
        const i = indexOf(mapping_index);
        std.debug.assert(mappings.items(.fd)[i] >= 0);
        return .{
            .bytes = mappings.items(.bytes)[i],
            .fd = mappings.items(.fd)[i],
            .refcount = mappings.items(.refcount)[i],
        };
    }

    /// Queues every mapping no blob still refers to, in registration order, for
    /// the edge to unmap and close. The space was reserved at registration, so
    /// this cannot fail.
    ///
    /// O(m·b) in the mappings registered and the blobs, each mapping being
    /// checked against the blobs that could view it.
    pub fn releaseUnreferencedMappings(self: *Scene) void {
        const mappings = self.mappings.slice();
        const fds = mappings.items(.fd);
        const refcounts = mappings.items(.refcount);
        for (fds, refcounts, 0..) |fd, refcount, i| {
            if (fd < 0 or refcount != 0) continue;
            self.queueMappingRelease(@fromBackingInt(@intCast(i)));
        }
    }

    /// Drops a mapping the edge has finished unmapping and closing, returning
    /// its slot for reuse. Call it only after the region has been unmapped, as
    /// any view into it is invalid from this point.
    ///
    /// O(m) in the mappings registered.
    pub fn forgetMapping(self: *Scene, mapping_index: MappingIndex) void {
        std.debug.assert(mapping_index != .none);
        var mappings = self.mappings.slice();
        const i = indexOf(mapping_index);
        std.debug.assert(mappings.items(.fd)[i] >= 0);
        std.debug.assert(mappings.items(.refcount)[i] == 0);

        var found = false;
        for (self.released_mappings.items, 0..) |queued, queued_i| {
            if (queued != mapping_index) continue;
            std.mem.copyForwards(
                MappingIndex,
                self.released_mappings.items[queued_i .. self.released_mappings.items.len - 1],
                self.released_mappings.items[queued_i + 1 ..],
            );
            self.released_mappings.items.len -= 1;
            found = true;
            break;
        }
        std.debug.assert(found);
        mappings.items(.bytes)[i] = emptyMappingBytes();
        mappings.items(.fd)[i] = -1;
        self.mapping_free.appendAssumeCapacity(mapping_index);
        self.live_mappings -= 1;
    }

    /// Hands back every mapping still registered, for the edge to unmap and
    /// close.
    ///
    /// Required before `deinit`, because the scene cannot release these regions
    /// itself. `out` is caller-owned, and the scene's allocator is used only to
    /// reserve its capacity.
    ///
    /// O(1): ownership moves, nothing is copied.
    pub fn takeAllMappings(self: *Scene, out: *std.ArrayList(Mapping)) std.mem.Allocator.Error!void {
        try out.ensureUnusedCapacity(self.gpa, self.live_mappings);
        var mappings = self.mappings.slice();
        const bytes = mappings.items(.bytes);
        const fds = mappings.items(.fd);
        const refcounts = mappings.items(.refcount);
        for (bytes, fds, refcounts) |mapping_bytes, fd, refcount| {
            if (fd < 0) continue;
            out.appendAssumeCapacity(.{ .bytes = mapping_bytes, .fd = fd, .refcount = refcount });
        }
        for (fds, bytes) |*fd, *mapping_bytes| {
            if (fd.* < 0) continue;
            fd.* = -1;
            mapping_bytes.* = emptyMappingBytes();
        }
        self.released_mappings.clearRetainingCapacity();
        self.live_mappings = 0;
    }

    fn mappingContaining(self: *const Scene, section: []const u8) ?MappingIndex {
        const section_start = @intFromPtr(section.ptr);
        const section_end = std.math.add(usize, section_start, section.len) catch return null;
        const mappings = self.mappings.slice();
        for (mappings.items(.bytes), mappings.items(.fd), 0..) |mapping_bytes, fd, i| {
            if (fd < 0) continue;
            const mapping_start = @intFromPtr(mapping_bytes.ptr);
            const mapping_end = std.math.add(usize, mapping_start, mapping_bytes.len) catch continue;
            if (section_start >= mapping_start and section_end <= mapping_end) {
                return @fromBackingInt(@intCast(i));
            }
        }
        return null;
    }

    fn queueMappingRelease(self: *Scene, mapping_index: MappingIndex) void {
        for (self.released_mappings.items) |queued| {
            if (queued == mapping_index) return;
        }
        self.released_mappings.appendAssumeCapacity(mapping_index);
    }

    // -----------------------------------------------------------------------
    // queries

    /// Looks up a structure by name, returning null if no structure has ever
    /// been registered under it. The index stays valid for that structure's
    /// lifetime, including across runs that do not register it.
    ///
    /// O(k) in the name's length, which is hashed and scanned; O(1) expected in
    /// the number of structures.
    pub fn find(self: *const Scene, name: []const u8) ?StructureIndex {
        if (std.mem.findScalar(u8, name, 0) != null) return null;
        const raw = self.string_table.getKeyAdapted(name, std.hash_map.StringIndexAdapter{
            .bytes = &self.strings,
        }) orelse return null;
        return self.by_name.get(@fromBackingInt(@intCast(raw)));
    }

    /// Returns the version of `structure_index` that frame `frame` should
    /// display, or null if the structure had not appeared by then.
    ///
    /// Frames are deltas, so this is the latest version at or before `frame`
    /// rather than one recorded for it. A structure registered once and never
    /// updated displays that version for the rest of the run. A structure with
    /// no version in the current run falls back to the last one retained from
    /// the previous run, so geometry stays on screen between a rebuild and the
    /// first message of the new run.
    ///
    /// frame.
    ///
    /// O(v) in that structure's versions, scanned backwards. Not a binary
    /// search: the run has to be checked as well as the frame, and the versions
    /// of an earlier run sit behind those of this one.
    pub fn versionAt(self: *const Scene, structure_index: StructureIndex, frame: u32) ?u32 {
        const structures = self.structures.slice();
        const versions = structures.items(.versions)[indexOf(structure_index)].items;
        var has_current_run = false;
        var i = versions.len;
        while (i > 0) {
            i -= 1;
            const version = versions[i];
            if (version.run != self.run) continue;
            has_current_run = true;
            if (version.frame <= frame) return @intCast(i);
        }
        if (has_current_run or versions.len == 0) return null;
        return @intCast(versions.len - 1);
    }

    /// Whether a version was recorded at `frame`, rather than an earlier
    /// version being displayed there. The UI uses this to mark that a scrubbed
    /// frame shows older geometry.
    ///
    /// O(v) in that structure's versions.
    pub fn hasExactVersion(self: *const Scene, structure_index: StructureIndex, frame: u32) bool {
        const structures = self.structures.slice();
        const versions = structures.items(.versions)[indexOf(structure_index)].items;
        for (versions) |version| {
            if (version.run == self.run and version.frame == frame) return true;
        }
        return false;
    }

    /// The number of frames in the current run. Frame 0 is implicit, so this is
    /// 1 immediately after a run begins, and it bounds the timeline scrubber.
    ///
    /// O(1).
    pub fn frameCount(self: *const Scene) u32 {
        return @intCast(self.frame_labels.items.len);
    }

    /// Samples what the scene currently costs, by scanning the version arrays.
    /// See `MemoryStats`.
    ///
    /// O(s + v + b) in the structures, versions and blobs: the version count
    /// and the mapped bytes are counted on demand rather than maintained.
    pub fn memoryStats(self: *const Scene) MemoryStats {
        var version_count: usize = 0;
        const structures = self.structures.slice();
        for (structures.items(.versions)) |versions| version_count += versions.items.len;
        var mapped_bytes: usize = 0;
        const blobs = self.blobs.slice();
        for (blobs.items(.bytes), blobs.items(.refcount), blobs.items(.mapping)) |bytes, refcount, mapping| {
            if (refcount != 0 and mapping != .none) mapped_bytes += bytes.len;
        }
        std.debug.assert(version_count <= std.math.maxInt(u32));
        return .{
            .blob_bytes = self.blob_bytes,
            .mapped_bytes = mapped_bytes,
            .blob_count = self.live_blobs,
            .versions = @intCast(version_count),
            .evicted_versions = self.evicted_versions,
        };
    }

    /// The text of an interned string, with `.none` mapping to the empty
    /// string. The view is invalidated by interning anything else.
    ///
    /// O(1).
    pub fn string(self: *const Scene, string_index: StringIndex) []const u8 {
        if (string_index == .none) return "";
        return std.mem.sliceTo(self.strings.items[indexOf(string_index)..], 0);
    }

    /// The vertex positions of a version, as a view over its blob. Nothing is
    /// copied; the view is valid while that version's blobs are.
    ///
    /// O(1).
    pub fn positionsOf(self: *const Scene, version: Version) layout.Positions.Const {
        return layout.Positions.Const.fromBytes(self.blobBytes(version.positions));
    }

    /// The triangles of a mesh version, as a view over its topology blob. Empty
    /// for a version with no topology.
    ///
    /// O(1).
    pub fn facesOf(self: *const Scene, version: Version) []const [3]u32 {
        if (version.topology == .none) return &.{};
        return std.mem.bytesAsSlice([3]u32, self.blobBytes(version.topology));
    }

    /// The segments of a line-set version, as a view over its topology blob.
    ///
    /// O(1).
    pub fn segmentsOf(self: *const Scene, version: Version) []const [2]u32 {
        if (version.topology == .none) return &.{};
        return std.mem.bytesAsSlice([2]u32, self.blobBytes(version.topology));
    }

    /// The quantities attached to a version, as a slice of the structure's side
    /// array. Applying another message may move that array, so do not hold this
    /// across an `apply`.
    ///
    /// O(1).
    pub fn quantities(self: *const Scene, structure_index: StructureIndex, version: Version) []const QuantityRef {
        const structures = self.structures.slice();
        const refs = structures.items(.quantity_refs)[indexOf(structure_index)].items;
        const start: usize = version.quantity_start;
        return refs[start .. start + version.quantity_len];
    }

    fn intern(self: *Scene, text: []const u8) std.mem.Allocator.Error!StringIndex {
        std.debug.assert(std.mem.findScalar(u8, text, 0) == null);
        const adapter = std.hash_map.StringIndexAdapter{ .bytes = &self.strings };
        if (self.string_table.getKeyAdapted(text, adapter)) |raw| return @fromBackingInt(@intCast(raw));

        if (self.strings.items.len > std.math.maxInt(u32) - text.len - 1) return error.OutOfMemory;
        try self.strings.ensureUnusedCapacity(self.gpa, text.len + 1);
        try self.string_table.ensureUnusedCapacityContext(
            self.gpa,
            1,
            .{ .bytes = &self.strings },
        );
        const raw: u32 = @intCast(self.strings.items.len);
        self.strings.appendSliceAssumeCapacity(text);
        self.strings.appendAssumeCapacity(0);
        const result = self.string_table.getOrPutAssumeCapacityAdapted(text, adapter);
        std.debug.assert(!result.found_existing);
        result.key_ptr.* = raw;
        return @fromBackingInt(@intCast(raw));
    }
};

// ---------------------------------------------------------------------------
// tests

const testing = std.testing;

fn latestVersionValue(scene: *const Scene, structure_index: StructureIndex) Version {
    const structures = scene.structures.slice();
    const versions = structures.items(.versions)[indexOf(structure_index)].items;
    return versions[versions.len - 1];
}

fn applyMesh(scene: *Scene, name: []const u8, positions: layout.Positions.Const, faces: []const [3]u32) !void {
    try scene.apply(.{ .mesh = .{ .name = name, .dim = .d3, .positions = positions, .faces = faces } });
}

fn deinitTestSceneWithMappings(scene: *Scene) void {
    var mappings: std.ArrayList(Mapping) = .empty;
    scene.takeAllMappings(&mappings) catch unreachable;
    mappings.deinit(scene.gpa);
    scene.deinit();
}

fn expectMemoryAccounting(scene: *const Scene) !void {
    const blobs = scene.blobs.slice();
    const bytes = blobs.items(.bytes);
    const refcounts = blobs.items(.refcount);
    const mappings = blobs.items(.mapping);
    var live_bytes: usize = 0;
    var mapped_bytes: usize = 0;
    var live_count: u32 = 0;
    var version_count: u32 = 0;
    for (bytes, refcounts, mappings) |blob_bytes, refcount, mapping| {
        if (refcount == 0) continue;
        live_bytes += blob_bytes.len;
        if (mapping != .none) mapped_bytes += blob_bytes.len;
        live_count += 1;
    }
    const structures = scene.structures.slice();
    for (structures.items(.versions)) |versions| version_count += @intCast(versions.items.len);
    const stats = scene.memoryStats();
    try testing.expectEqual(live_bytes, stats.blob_bytes);
    try testing.expectEqual(mapped_bytes, stats.mapped_bytes);
    try testing.expectEqual(live_count, stats.blob_count);
    try testing.expectEqual(version_count, stats.versions);
}

fn applyEncoded(
    scene: *Scene,
    encoded: *protocol.Encoded,
    storage: []align(protocol.section_alignment) u8,
) !void {
    const frame = encoded.writeTo(storage);
    const header = try protocol.decodeHeader(frame);
    const payload_bytes = frame[@sizeOf(protocol.Header)..];
    const payload: []align(protocol.payload_alignment) const u8 = @alignCast(payload_bytes);
    try scene.apply(try protocol.decodeInline(header, payload));
}

test "hot scene records have fixed documented sizes" {
    try testing.expectEqual(24, @sizeOf(Version));
    try testing.expectEqual(20, @sizeOf(QuantityRef));
}

test "encoded protocol stream applies headlessly into the scene" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    const positions = try layout.Positions.alloc(testing.allocator, 3);
    defer positions.free(testing.allocator);
    positions.setAll(&.{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0) });
    const faces = [_][3]u32{.{ 0, 1, 2 }};
    const values = [_]f32{ 1, 2, 3 };
    var encoded: protocol.Encoded = undefined;
    var storage: [512]u8 align(protocol.section_alignment) = undefined;

    protocol.encodeHello(&encoded, "test-source");
    try applyEncoded(&scene, &encoded, &storage);
    protocol.encodeBeginRun(&encoded);
    try applyEncoded(&scene, &encoded, &storage);
    protocol.encodeBeginFrame(&encoded, 0, "zero");
    try applyEncoded(&scene, &encoded, &storage);
    protocol.encodeMesh(&encoded, "surface", .d3, positions.toConst(), &faces);
    try applyEncoded(&scene, &encoded, &storage);
    protocol.encodeScalarQuantity(&encoded, "surface", "height", .vertex, &values);
    try applyEncoded(&scene, &encoded, &storage);
    protocol.encodeEndFrame(&encoded);
    try applyEncoded(&scene, &encoded, &storage);
    protocol.encodeEndRun(&encoded);
    try applyEncoded(&scene, &encoded, &storage);

    try testing.expectEqualStrings("test-source", scene.string(scene.source_name));
    const structure_index = scene.find("surface").?;
    const version = latestVersionValue(&scene, structure_index);
    try testing.expectEqual(1, scene.quantities(structure_index, version).len);
    try testing.expectEqual(1, scene.frameCount());
    try testing.expect(!scene.run_active);
}

test "upsert keeps UI state and drops the previous run's geometry" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    const positions = try layout.Positions.alloc(testing.allocator, 3);
    defer positions.free(testing.allocator);
    positions.setAll(&.{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0) });
    const faces = [_][3]u32{.{ 0, 1, 2 }};

    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "surface", positions.toConst(), &faces);
    const structure_index = scene.find("surface").?;
    var structures = scene.structures.slice();
    structures.items(.ui)[indexOf(structure_index)].visible = false;
    try scene.apply(.{ .end_run = {} });
    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "surface", positions.toConst(), &faces);

    structures = scene.structures.slice();
    // Only the current run's versions survive, but the per-name viewer state
    // persists.
    const version_list = structures.items(.versions)[indexOf(structure_index)].items;
    try testing.expectEqual(1, version_list.len);
    try testing.expectEqual(scene.run, version_list[0].run);
    try testing.expect(!structures.items(.ui)[indexOf(structure_index)].visible);
}

test "mesh positions share topology and quantities survive across versions" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    const positions = try layout.Positions.alloc(testing.allocator, 3);
    defer positions.free(testing.allocator);
    positions.setAll(&.{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0) });
    const faces = [_][3]u32{.{ 0, 1, 2 }};
    const values = [_]f32{ 1, 2, 3 };
    const replacement_values = [_]f32{ 3, 2, 1 };

    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "surface", positions.toConst(), &faces);
    const structure_index = scene.find("surface").?;
    try scene.apply(.{ .scalar_quantity = .{
        .structure = "surface",
        .name = "height",
        .target = .vertex,
        .values = &values,
    } });
    var structures = scene.structures.slice();
    try testing.expectEqual(1, structures.items(.versions)[indexOf(structure_index)].items.len);
    const first = latestVersionValue(&scene, structure_index);
    const first_quantity_blob = scene.quantities(structure_index, first)[0].blob;
    try scene.apply(.{ .scalar_quantity = .{
        .structure = "surface",
        .name = "height",
        .target = .vertex,
        .values = &replacement_values,
    } });
    structures = scene.structures.slice();
    try testing.expectEqual(1, structures.items(.versions)[indexOf(structure_index)].items.len);
    const replaced = latestVersionValue(&scene, structure_index);
    const quantity_blob = scene.quantities(structure_index, replaced)[0].blob;
    try testing.expect(quantity_blob != first_quantity_blob);
    var blobs = scene.blobs.slice();
    try testing.expectEqual(0, blobs.items(.refcount)[indexOf(first_quantity_blob)]);
    for (scene.new_blobs.items) |blob| try testing.expect(blob != first_quantity_blob);

    try scene.apply(.{ .begin_frame = .{ .index = 1, .label = "one" } });
    try scene.apply(.{ .mesh_positions = .{ .name = "surface", .positions = positions.toConst() } });
    const second = latestVersionValue(&scene, structure_index);
    try testing.expectEqual(first.topology, second.topology);
    try testing.expectEqual(quantity_blob, scene.quantities(structure_index, second)[0].blob);
    blobs = scene.blobs.slice();
    try testing.expectEqual(2, blobs.items(.refcount)[indexOf(first.topology)]);
    try testing.expectEqual(2, blobs.items(.refcount)[indexOf(quantity_blob)]);
}

test "quantity errors, discard on an untouched run, and timeline selection" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    const positions = try layout.Positions.alloc(testing.allocator, 3);
    defer positions.free(testing.allocator);
    positions.setAll(&.{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0) });
    const faces = [_][3]u32{.{ 0, 1, 2 }};

    try scene.apply(.{ .begin_run = {} });
    try testing.expectError(error.UnknownStructure, scene.apply(.{ .mesh_positions = .{
        .name = "missing",
        .positions = positions.toConst(),
    } }));
    try applyMesh(&scene, "surface", positions.toConst(), &faces);
    try testing.expectError(error.CountMismatch, scene.apply(.{ .scalar_quantity = .{
        .structure = "surface",
        .name = "bad",
        .target = .vertex,
        .values = &.{ 1, 2 },
    } }));
    try scene.apply(.{ .begin_frame = .{ .index = 1, .label = "one" } });
    try scene.apply(.{ .points = .{ .name = "late", .dim = .d2, .positions = positions.toConst() } });
    try scene.apply(.{ .begin_frame = .{ .index = 2, .label = "two" } });
    try scene.apply(.{ .mesh_positions = .{ .name = "surface", .positions = positions.toConst() } });

    const surface = scene.find("surface").?;
    const late = scene.find("late").?;
    try testing.expect(scene.versionAt(surface, 0) != null);
    try testing.expect(scene.versionAt(surface, 1) != null);
    try testing.expect(scene.versionAt(surface, 2).? > scene.versionAt(surface, 1).?);
    try testing.expect(scene.versionAt(late, 0) == null);
    try testing.expect(scene.versionAt(late, 1) != null);
    try testing.expectEqual(3, scene.frameCount());

    try scene.apply(.{ .end_run = {} });
    try scene.apply(.{ .begin_run = {} });
    try scene.apply(.{ .end_run = {} });
    // A run that did not register them discards both: with no versions, they
    // are neither drawn nor listed.
    const structures = scene.structures.slice();
    try testing.expectEqual(0, structures.items(.versions)[indexOf(surface)].items.len);
    try testing.expectEqual(0, structures.items(.versions)[indexOf(late)].items.len);
    try testing.expect(scene.versionAt(surface, 0) == null);
    try testing.expectError(error.NoRunActive, scene.apply(.{ .end_frame = {} }));
    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "surface", positions.toConst(), &faces);
    // Registering the name again restores the structure in its original slot.
    const refreshed = scene.structures.slice();
    try testing.expectEqual(1, refreshed.items(.versions)[indexOf(surface)].items.len);
    try testing.expect(scene.versionAt(surface, 0) != null);
}

test "kind mismatch and mesh position count mismatch are rejected" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    const three = try layout.Positions.alloc(testing.allocator, 3);
    defer three.free(testing.allocator);
    const two = try layout.Positions.alloc(testing.allocator, 2);
    defer two.free(testing.allocator);

    try scene.apply(.{ .begin_run = {} });
    try scene.apply(.{ .points = .{ .name = "sites", .dim = .d2, .positions = three.toConst() } });
    try testing.expectError(error.KindMismatch, scene.apply(.{ .mesh_positions = .{
        .name = "sites",
        .positions = three.toConst(),
    } }));
    try applyMesh(&scene, "mesh", three.toConst(), &.{.{ 0, 1, 2 }});
    try testing.expectError(error.CountMismatch, scene.apply(.{ .mesh_positions = .{
        .name = "mesh",
        .positions = two.toConst(),
    } }));
}

test "blob free list reuses indices and records both notifications" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    const first = try scene.createBlob("first");
    scene.releaseBlob(first);
    const second = try scene.createBlob("second");
    try testing.expectEqual(first, second);
    try testing.expectEqual(first, scene.freed_blobs.items[0]);
    try testing.expectEqual(second, scene.new_blobs.items[scene.new_blobs.items.len - 1]);
    try testing.expectEqualStrings("second", scene.blobBytes(second));
}

test "mapped mesh positions are adopted without blob storage allocation" {
    const CountingAllocator = @import("../testutil.zig").CountingAllocator;
    var counting: CountingAllocator = .{ .child = testing.allocator };
    const gpa = counting.allocator();
    var scene = Scene.init(gpa);
    defer deinitTestSceneWithMappings(&scene);

    const owned = try layout.Positions.alloc(gpa, 3);
    defer owned.free(gpa);
    owned.setAll(&.{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0) });
    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "surface", owned.toConst(), &.{.{ 0, 1, 2 }});
    try scene.apply(.{ .mesh_positions = .{ .name = "surface", .positions = owned.toConst() } });

    var mapping: [layout.Positions.byteSize(3)]u8 align(64) = @splat(0);
    const mapped = layout.Positions.fromBytes(&mapping);
    mapped.setAll(&.{ .init(2, 0, 0), .init(0, 2, 0), .init(0, 0, 2) });
    const mapping_index = try scene.registerMapping(&mapping, 10);
    counting.alloc_calls = 0;
    counting.resize_calls = 0;
    counting.remap_calls = 0;
    try scene.apply(.{ .mesh_positions = .{ .name = "surface", .positions = mapped.toConst() } });
    try testing.expectEqual(0, counting.alloc_calls + counting.resize_calls + counting.remap_calls);

    const surface = scene.find("surface").?;
    const version = latestVersionValue(&scene, surface);
    try testing.expectEqual(@intFromPtr(mapping[0..].ptr), @intFromPtr(scene.blobBytes(version.positions).ptr));
    try testing.expectEqual(mapping_index, scene.blobs.slice().items(.mapping)[indexOf(version.positions)]);
    try testing.expectEqual(@as(u32, 1), scene.mappingValue(mapping_index).refcount);
    try testing.expectEqual(mapping.len, scene.memoryStats().mapped_bytes);
}

test "one mapping refcounts multiple versions while mesh topology remains shared" {
    var scene = Scene.init(testing.allocator);
    defer deinitTestSceneWithMappings(&scene);
    const position_len = layout.Positions.byteSize(3);
    var mapping: [128]u8 align(64) = @splat(0);
    const first_positions = layout.Positions.fromBytes(mapping[0..position_len]);
    const second_positions = layout.Positions.fromBytes(mapping[64 .. 64 + position_len]);
    const mapping_index = try scene.registerMapping(&mapping, 11);

    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "surface", first_positions.toConst(), &.{.{ 0, 1, 2 }});
    const surface = scene.find("surface").?;
    const first = latestVersionValue(&scene, surface);
    try scene.apply(.{ .begin_frame = .{ .index = 1, .label = "one" } });
    try scene.apply(.{ .mesh_positions = .{ .name = "surface", .positions = second_positions.toConst() } });
    const second = latestVersionValue(&scene, surface);

    try testing.expectEqual(first.topology, second.topology);
    try testing.expectEqual(@as(u32, 2), scene.blobs.slice().items(.refcount)[indexOf(first.topology)]);
    try testing.expectEqual(@as(u32, 2), scene.mappingValue(mapping_index).refcount);
    try testing.expectEqual(2 * position_len, scene.memoryStats().mapped_bytes);
}

test "mapping releases preserve last-reference order and slots are reusable" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    var first_mapping: [64]u8 align(64) = @splat(0);
    var second_mapping: [64]u8 align(64) = @splat(0);
    const first_index = try scene.registerMapping(&first_mapping, 12);
    const second_index = try scene.registerMapping(&second_mapping, 13);
    const first_blob = try scene.createBlob(first_mapping[0..16]);
    const second_blob = try scene.createBlob(second_mapping[0..16]);

    scene.releaseBlob(second_blob);
    scene.releaseBlob(first_blob);
    try testing.expectEqualSlices(MappingIndex, &.{ second_index, first_index }, scene.released_mappings.items);
    scene.forgetMapping(second_index);
    scene.forgetMapping(first_index);
    try testing.expectEqual(@as(u32, 0), scene.live_mappings);
    try testing.expectEqual(@as(usize, 2), scene.mapping_free.items.len);
}

test "failed apply releases an unadopted mapping" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    var mapping: [layout.Positions.byteSize(3)]u8 align(64) = @splat(0);
    const mapped = layout.Positions.fromBytes(&mapping).toConst();
    const mapping_index = try scene.registerMapping(&mapping, 14);
    try scene.apply(.{ .begin_run = {} });
    try testing.expectError(error.UnknownStructure, scene.apply(.{ .mesh_positions = .{
        .name = "missing",
        .positions = mapped,
    } }));
    scene.releaseUnreferencedMappings();
    try testing.expectEqualSlices(MappingIndex, &.{mapping_index}, scene.released_mappings.items);
    scene.forgetMapping(mapping_index);
}

test "takeAllMappings returns retained and unreferenced mappings for final edge cleanup" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    var first_mapping: [64]u8 align(64) = @splat(0);
    var second_mapping: [64]u8 align(64) = @splat(0);
    _ = try scene.registerMapping(&first_mapping, 30);
    _ = try scene.registerMapping(&second_mapping, 31);
    _ = try scene.createBlob(first_mapping[0..16]);
    var taken: std.ArrayList(Mapping) = .empty;
    defer taken.deinit(testing.allocator);
    try scene.takeAllMappings(&taken);
    try testing.expectEqual(@as(usize, 2), taken.items.len);
    try testing.expectEqual(@as(i32, 30), taken.items[0].fd);
    try testing.expectEqual(@as(u32, 1), taken.items[0].refcount);
    try testing.expectEqual(@as(i32, 31), taken.items[1].fd);
    try testing.expectEqual(@as(u32, 0), scene.live_mappings);
}

test "mapped bytes participate in budget eviction accounting" {
    var scene = Scene.init(testing.allocator);
    defer deinitTestSceneWithMappings(&scene);
    const position_len = layout.Positions.byteSize(3);
    var mapping: [256]u8 align(64) = @splat(0);
    _ = try scene.registerMapping(&mapping, 15);
    scene.retention.budget_bytes = 2 * position_len;
    try scene.apply(.{ .begin_run = {} });
    try scene.apply(.{ .points = .{
        .name = "sites",
        .dim = .d3,
        .positions = layout.Positions.fromBytes(mapping[0..position_len]).toConst(),
    } });
    try scene.apply(.{ .begin_frame = .{ .index = 1, .label = "one" } });
    try scene.apply(.{ .points = .{
        .name = "sites",
        .dim = .d3,
        .positions = layout.Positions.fromBytes(mapping[64 .. 64 + position_len]).toConst(),
    } });
    try scene.apply(.{ .begin_frame = .{ .index = 2, .label = "two" } });
    try scene.apply(.{ .points = .{
        .name = "sites",
        .dim = .d3,
        .positions = layout.Positions.fromBytes(mapping[128 .. 128 + position_len]).toConst(),
    } });
    const stats = scene.memoryStats();
    try testing.expectEqual(2 * position_len, stats.blob_bytes);
    try testing.expectEqual(stats.blob_bytes, stats.mapped_bytes);
    try testing.expectEqual(@as(u32, 1), stats.evicted_versions);
    try expectMemoryAccounting(&scene);
}

test "budget decimates odd frames first and versionAt uses the nearest kept frame" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    const positions = try layout.Positions.alloc(testing.allocator, 3);
    defer positions.free(testing.allocator);
    positions.setAll(&.{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0) });
    const faces: [10][3]u32 = @splat(.{ 0, 1, 2 });
    const topology_bytes = std.mem.sliceAsBytes(&faces).len;
    // Topology plus three position streams is about 1.5 mesh snapshots for all
    // build-selected position layouts and makes the first odd/even choice visible.
    scene.retention.budget_bytes = topology_bytes + 3 * positions.bytes().len;

    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "surface", positions.toConst(), &faces);
    const surface = scene.find("surface").?;
    try expectMemoryAccounting(&scene);
    var frame: u32 = 1;
    while (frame <= 8) : (frame += 1) {
        try scene.apply(.{ .begin_frame = .{ .index = frame, .label = "" } });
        try scene.apply(.{ .mesh_positions = .{ .name = "surface", .positions = positions.toConst() } });
        const latest = latestVersionValue(&scene, surface);
        try testing.expectEqual(frame, latest.frame);
        try testing.expectEqual(scene.run, latest.run);
        try testing.expect(scene.blob_bytes <= scene.retention.budget_bytes);
        try expectMemoryAccounting(&scene);
        if (frame == 3) {
            try testing.expect(!scene.hasExactVersion(surface, 1));
            try testing.expect(scene.hasExactVersion(surface, 2));
        }
    }

    const stats = scene.memoryStats();
    try testing.expect(stats.evicted_versions > 0);
    try testing.expect(scene.hasExactVersion(surface, 8));
    try testing.expect(!scene.hasExactVersion(surface, 6));
    const shown = scene.structures.slice().items(.versions)[indexOf(surface)].items[scene.versionAt(surface, 6).?];
    try testing.expectEqual(@as(u32, 4), shown.frame);
}

test "a new run drops every version the previous run left" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    const positions = try layout.Positions.alloc(testing.allocator, 3);
    defer positions.free(testing.allocator);
    const faces = [_][3]u32{.{ 0, 1, 2 }};

    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "surface", positions.toConst(), &faces);
    const surface = scene.find("surface").?;
    try scene.apply(.{ .begin_frame = .{ .index = 1, .label = "run-one" } });
    try scene.apply(.{ .mesh_positions = .{ .name = "surface", .positions = positions.toConst() } });
    try scene.apply(.{ .end_run = {} });
    try testing.expectEqual(2, scene.structures.slice().items(.versions)[indexOf(surface)].items.len);

    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "surface", positions.toConst(), &faces);
    try scene.apply(.{ .begin_frame = .{ .index = 1, .label = "run-two" } });
    try scene.apply(.{ .mesh_positions = .{ .name = "surface", .positions = positions.toConst() } });

    // No version from run one remains; only run two's two frames.
    const versions = scene.structures.slice().items(.versions)[indexOf(surface)].items;
    try testing.expectEqual(2, versions.len);
    for (versions) |version| try testing.expectEqual(scene.run, version.run);
    try expectMemoryAccounting(&scene);
}

test "a leftover previous-run version is released once the run replaces it" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    const positions = try layout.Positions.alloc(testing.allocator, 3);
    defer positions.free(testing.allocator);
    const faces = [_][3]u32{.{ 0, 1, 2 }};

    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "surface", positions.toConst(), &faces);
    const surface = scene.find("surface").?;
    const first_run = scene.run;
    try scene.apply(.{ .end_run = {} });
    try scene.apply(.{ .begin_run = {} });
    // The structure is still displayed between runs: frames are deltas, so the
    // last geometry stands until the new run replaces it.
    const carried = scene.structures.slice().items(.versions)[indexOf(surface)].items;
    try testing.expectEqual(1, carried.len);
    try testing.expectEqual(first_run, carried[0].run);

    try applyMesh(&scene, "surface", positions.toConst(), &faces);
    const replaced = scene.structures.slice().items(.versions)[indexOf(surface)].items;
    try testing.expectEqual(1, replaced.len);
    try testing.expectEqual(scene.run, replaced[0].run);
    try expectMemoryAccounting(&scene);
}

test "discarding an untouched structure frees the blobs it held" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    const positions = try layout.Positions.alloc(testing.allocator, 3);
    defer positions.free(testing.allocator);
    const faces = [_][3]u32{.{ 0, 1, 2 }};

    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "dropped", positions.toConst(), &faces);
    try applyMesh(&scene, "kept", positions.toConst(), &faces);
    const dropped = scene.find("dropped").?;
    const dropped_blob = latestVersionValue(&scene, dropped).positions;
    const bytes_with_both = scene.blob_bytes;
    try scene.apply(.{ .end_run = {} });

    // The second run registers only "kept", so "dropped" is discarded at
    // end_run.
    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "kept", positions.toConst(), &faces);
    try scene.apply(.{ .end_run = {} });

    try testing.expectEqual(0, scene.structures.slice().items(.versions)[indexOf(dropped)].items.len);
    try testing.expect(scene.versionAt(dropped, 0) == null);
    try testing.expectEqual(0, scene.blobs.slice().items(.refcount)[indexOf(dropped_blob)]);
    try testing.expect(scene.blob_bytes < bytes_with_both);
    try expectMemoryAccounting(&scene);
}

test "shared topology survives decimation until incompatible replacement drops its last reference" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    const positions = try layout.Positions.alloc(testing.allocator, 3);
    defer positions.free(testing.allocator);
    const faces = [_][3]u32{.{ 0, 1, 2 }};

    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "surface", positions.toConst(), &faces);
    const surface = scene.find("surface").?;
    const topology = latestVersionValue(&scene, surface).topology;
    for (1..3) |frame| {
        try scene.apply(.{ .begin_frame = .{ .index = @intCast(frame), .label = "" } });
        try scene.apply(.{ .mesh_positions = .{ .name = "surface", .positions = positions.toConst() } });
    }
    try testing.expectEqual(@as(u32, 3), scene.blobs.slice().items(.refcount)[indexOf(topology)]);
    scene.retention.budget_bytes = scene.blob_bytes - positions.bytes().len;
    scene.enforceBudget();
    try testing.expectEqual(@as(u32, 2), scene.blobs.slice().items(.refcount)[indexOf(topology)]);

    scene.retention.budget_bytes = std.math.maxInt(usize);
    try scene.apply(.{ .points = .{ .name = "surface", .dim = .d3, .positions = positions.toConst() } });
    try testing.expectEqual(@as(u32, 0), scene.blobs.slice().items(.refcount)[indexOf(topology)]);
    try testing.expect(latestVersionValue(&scene, surface).topology == .none);
    try expectMemoryAccounting(&scene);
}

test "memoryStats accounts for live blob bytes through retain and release" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    try expectMemoryAccounting(&scene);
    const first = try scene.createBlob("first");
    try expectMemoryAccounting(&scene);
    scene.retainBlob(first);
    try expectMemoryAccounting(&scene);
    const second = try scene.createBlob("a longer second blob");
    try expectMemoryAccounting(&scene);
    scene.releaseBlob(first);
    try expectMemoryAccounting(&scene);
    scene.releaseBlob(first);
    try expectMemoryAccounting(&scene);
    scene.releaseBlob(second);
    try expectMemoryAccounting(&scene);
    try testing.expectEqual(@as(usize, 0), scene.memoryStats().blob_bytes);
}

fn allocationFailureCase(gpa: std.mem.Allocator) !void {
    var scene = Scene.init(gpa);
    defer scene.deinit();
    const positions = try layout.Positions.alloc(gpa, 3);
    defer positions.free(gpa);
    positions.setAll(&.{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0) });
    const faces = [_][3]u32{.{ 0, 1, 2 }};
    const values = [_]f32{ 1, 2, 3 };

    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "surface", positions.toConst(), &faces);
    try scene.apply(.{ .mesh_positions = .{ .name = "surface", .positions = positions.toConst() } });
    try scene.apply(.{ .scalar_quantity = .{
        .structure = "surface",
        .name = "height",
        .target = .vertex,
        .values = &values,
    } });
    scene.retention.budget_bytes = scene.blob_bytes + positions.bytes().len;
    try scene.apply(.{ .begin_frame = .{ .index = 1, .label = "one" } });
    try scene.apply(.{ .mesh_positions = .{ .name = "surface", .positions = positions.toConst() } });
    try scene.apply(.{ .begin_frame = .{ .index = 2, .label = "two" } });
    try scene.apply(.{ .mesh_positions = .{ .name = "surface", .positions = positions.toConst() } });
    try testing.expect(scene.evicted_versions > 0);
    try scene.apply(.{ .end_run = {} });
}

fn mappingAllocationFailureCase(gpa: std.mem.Allocator) !void {
    var remaining: std.ArrayList(Mapping) = .empty;
    try remaining.ensureTotalCapacity(gpa, 1);
    defer remaining.deinit(gpa);
    var scene = Scene.init(gpa);
    defer {
        scene.takeAllMappings(&remaining) catch unreachable;
        scene.deinit();
    }
    var mapping: [layout.Positions.byteSize(3)]u8 align(64) = @splat(0);
    const positions = layout.Positions.fromBytes(&mapping).toConst();

    try scene.apply(.{ .begin_run = {} });
    _ = try scene.registerMapping(&mapping, 20);
    try scene.apply(.{ .mesh = .{
        .name = "mapped",
        .dim = .d3,
        .positions = positions,
        .faces = &.{.{ 0, 1, 2 }},
    } });
    try scene.apply(.{ .mesh_positions = .{ .name = "mapped", .positions = positions } });
    scene.releaseUnreferencedMappings();
}

test "all allocating scene paths handle every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationFailureCase, .{});
    try testing.checkAllAllocationFailures(testing.allocator, mappingAllocationFailureCase, .{});
}

test "steady-state updates allocate only their payload blob" {
    const CountingAllocator = @import("../testutil.zig").CountingAllocator;
    var counting: CountingAllocator = .{ .child = testing.allocator };
    const gpa = counting.allocator();
    var scene = Scene.init(gpa);
    defer scene.deinit();
    const positions = try layout.Positions.alloc(gpa, 3);
    defer positions.free(gpa);
    const faces = [_][3]u32{.{ 0, 1, 2 }};
    const values = [_]f32{ 1, 2, 3 };

    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "surface", positions.toConst(), &faces);
    try scene.apply(.{ .mesh_positions = .{ .name = "surface", .positions = positions.toConst() } });
    counting.alloc_calls = 0;
    counting.resize_calls = 0;
    counting.remap_calls = 0;
    try scene.apply(.{ .mesh_positions = .{ .name = "surface", .positions = positions.toConst() } });
    try testing.expectEqual(1, counting.alloc_calls + counting.resize_calls + counting.remap_calls);

    try scene.apply(.{ .scalar_quantity = .{
        .structure = "surface",
        .name = "height",
        .target = .vertex,
        .values = &values,
    } });
    try scene.apply(.{ .begin_frame = .{ .index = 1, .label = "one" } });
    counting.alloc_calls = 0;
    counting.resize_calls = 0;
    counting.remap_calls = 0;
    try scene.apply(.{ .scalar_quantity = .{
        .structure = "surface",
        .name = "height",
        .target = .vertex,
        .values = &values,
    } });
    try testing.expectEqual(1, counting.alloc_calls + counting.resize_calls + counting.remap_calls);
}

test "frame 0 is implicit: frameCount is 1 after begin_run and grows with begin_frame" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    try testing.expectEqual(@as(u32, 0), scene.frameCount());
    try scene.apply(.{ .begin_run = {} });
    try testing.expectEqual(@as(u32, 1), scene.frameCount());
    try scene.apply(.{ .begin_frame = .{ .index = 1, .label = "one" } });
    try testing.expectEqual(@as(u32, 2), scene.frameCount());
    try testing.expectEqualStrings("one", scene.string(scene.frame_labels.items[1]));
    try scene.apply(.{ .begin_run = {} });
    try testing.expectEqual(@as(u32, 1), scene.frameCount());
}

test "per-version scene overhead beyond blob bytes is pinned exactly" {
    // The retention model assumes a version costs its blob bytes plus a
    // small fixed record. A hidden per-version container (list, map) would
    // pass every other test and silently multiply timeline memory; this pins
    // the overhead in bytes using the debug allocator's live accounting
    // (deterministic: requested sizes, deterministic list growth).
    var debug: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const gpa = debug.allocator();
    var scene = Scene.init(gpa);
    defer scene.deinit();

    const elem_count = if (layout.layout == .soa) 9 else 3;
    var position_data: [elem_count]layout.Positions.Elem = undefined;
    const positions = layout.Positions.fromSlice(&position_data);
    positions.setAll(&.{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0) });
    const faces = [_][3]u32{.{ 0, 1, 2 }};
    var frame: [512]u8 align(protocol.section_alignment) = undefined;
    var encoded: protocol.Encoded = undefined;

    try scene.apply(.{ .begin_run = {} });
    protocol.encodeMesh(&encoded, "m", .d3, positions.toConst(), &faces);
    try applyEncoded(&scene, &encoded, &frame);
    const versions: u32 = 1000;
    const before = debug.total_requested_bytes;
    const blob_before = scene.blob_bytes;
    var i: u32 = 1;
    while (i <= versions) : (i += 1) {
        try scene.apply(.{ .begin_frame = .{ .index = i, .label = "" } });
        protocol.encodeMeshPositions(&encoded, "m", positions.toConst());
        try applyEncoded(&scene, &encoded, &frame);
    }
    const overhead = (debug.total_requested_bytes - before) - (scene.blob_bytes - blob_before);
    // Pinned exactly, on purpose: this is a ratchet, not a ceiling. A change
    // that moves it is not banned — it becomes visible at the moment it is
    // made, so the memory trade-off is evaluated and the pin updated
    // deliberately. Measured 2026-08-24; identical for aos3/aos4/soa.
    const expected_overhead: usize = 68_436;
    if (overhead != expected_overhead) {
        std.debug.print(
            "scene per-version overhead changed: {d} bytes total for {d} versions ({d} B/version), pinned {d} ({d} B/version)\n",
            .{ overhead, versions, overhead / versions, expected_overhead, expected_overhead / versions },
        );
        return error.PerVersionOverheadChanged;
    }
}
