//! Pure, allocation-explicit scene storage for decoded protocol messages.
//!
//! Structure identity is its interned name. Viewer-owned UI state therefore
//! survives runs while geometry versions and refcounted, 64-byte-aligned blobs
//! remain entirely inside this module.
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

/// Typed index into `Scene.structures`; it owns no memory and never allocates.
pub const StructureIndex = enum(u32) { none = std.math.maxInt(u32), _ };

/// Typed index into `Scene.blobs`; it owns no memory and never allocates.
pub const BlobIndex = enum(u32) { none = std.math.maxInt(u32), _ };

/// Typed index into `Scene.mappings`; it owns no memory, never allocates, and
/// `.none` marks allocator-owned blob bytes.
pub const MappingIndex = enum(u32) { none = std.math.maxInt(u32), _ };

/// Byte offset of a NUL-terminated entry in `Scene.strings`; borrowed string
/// views are invalidated when the scene interns another string. The index owns
/// no memory and never allocates.
pub const StringIndex = enum(u32) { none = std.math.maxInt(u32), _ };

/// Renderable structure kind; this value owns no memory and never allocates.
pub const Kind = enum(u8) { mesh, points, lines };

/// Quantity payload kind; this value owns no memory and never allocates.
pub const QuantityKind = enum(u8) { scalar, vector };

/// Run-history and live-blob limits. The value owns no memory and changing it
/// allocates nothing; a lowered byte budget is enforced on the next apply or an
/// explicit `Scene.enforceBudget` call.
pub const Retention = struct {
    max_runs: u8 = 2,
    budget_bytes: usize = 2 * 1024 * 1024 * 1024,
};

/// Allocation-free snapshot of live blob/version accounting. The returned
/// value owns no memory.
pub const MemoryStats = struct {
    blob_bytes: usize,
    mapped_bytes: usize,
    blob_count: u32,
    versions: u32,
    evicted_versions: u32,
};

/// Persistent per-name viewer state. It owns no memory and never allocates.
pub const UiState = struct {
    visible: bool = true,
    wireframe: bool = false,
    ghost: bool = true,
    active_quantity: StringIndex = .none,
    point_size: f32 = 4,
    line_width: f32 = 1.5,
    colormap: @import("colormap.zig").Colormap = .viridis,
    vector_scale: f32 = 1.0,
};

/// One chronological geometry snapshot. The record allocates nothing; blob
/// references are owned by the containing structure until that version is
/// dropped or the scene is deinitialized.
pub const Version = struct {
    run: u32,
    frame: u32,
    positions: BlobIndex,
    topology: BlobIndex,
    quantity_start: u32,
    quantity_len: u32,
};

/// One quantity attachment in a version-owned side-array range. Its blob
/// reference is owned by that version; the record itself never allocates.
pub const QuantityRef = struct {
    name: StringIndex,
    blob: BlobIndex,
    count: u32,
    _reserved: u32 = 0,
    target: protocol.Target,
    kind: QuantityKind,
};

/// One named renderable. Its unmanaged version and quantity arrays are owned
/// by `Scene` and are released by `Scene.deinit`.
pub const Structure = struct {
    versions: std.ArrayList(Version) = .empty,
    quantity_refs: std.ArrayList(QuantityRef) = .empty,
    ui: UiState = .{},
    name: StringIndex,
    kind: Kind,
    dim: protocol.Dim,
    stale: bool = false,
    touched: bool = false,
};

/// Refcounted blob view. The record allocates nothing. Allocator-owned bytes
/// use `mapping = .none`; mapped bytes borrow their registered mapping until
/// the final blob release.
pub const Blob = struct {
    bytes: []align(layout.blob_alignment.toByteUnits()) const u8,
    refcount: u32,
    mapping: MappingIndex,
};

/// One edge-owned fd mapping registered with the pure scene. The record
/// allocates nothing; the scene borrows `bytes` and `fd`, and the edge
/// unmaps/closes them after their index is released.
pub const Mapping = struct {
    bytes: []align(layout.blob_alignment.toByteUnits()) const u8,
    fd: i32,
    refcount: u32,
};

/// Interned log entry. The record allocates nothing; text storage is owned by
/// the containing scene.
pub const LogEntry = struct {
    level: protocol.LogLevel,
    text: StringIndex,
};

/// Errors from applying a decoded message. The error set owns no memory and
/// allocates nothing. OOM is reported without leaking; all other errors
/// describe protocol messages that cannot mutate this scene.
pub const ApplyError = std.mem.Allocator.Error || error{
    UnknownStructure,
    KindMismatch,
    CountMismatch,
    NoRunActive,
};

/// Maximum retained log entries. The constant owns no memory and allocates
/// nothing. Interned text remains scene-owned even after an old entry is
/// evicted; the entry array does not grow beyond this cap.
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

/// Owns all scene strings, structures, versions, blobs, notifications, and
/// logs. Every allocation uses the allocator supplied to `init`.
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
    previous_frame_count: u32 = 0,
    run_active: bool = false,
    source_name: StringIndex = .none,
    live_blobs: u32 = 0,
    live_mappings: u32 = 0,
    blob_bytes: usize = 0,
    evicted_versions: u32 = 0,
    decimation_level: u8 = 1,

    // -----------------------------------------------------------------------
    // Scene lifecycle

    /// Initializes an empty scene without allocating. The caller must keep
    /// `gpa` valid until `deinit`.
    pub fn init(gpa: std.mem.Allocator) Scene {
        return .{ .gpa = gpa };
    }

    /// Frees every allocation owned by the scene with the allocator retained
    /// by `init`. The edge must first call `takeAllMappings`, then unmap and
    /// close every returned mapping. Borrowed views and indices become invalid.
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

    /// Applies one decoded message. Slices inside registered mappings become
    /// refcounted views; all other retained slices are copied into scene-owned
    /// storage. Only allocation and semantic errors are returned.
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
                self.previous_frame_count = self.frameCount();
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

    fn endRun(self: *Scene) void {
        var structures = self.structures.slice();
        const stale = structures.items(.stale);
        const touched = structures.items(.touched);
        for (stale, touched) |*is_stale, was_touched| {
            if (!was_touched) is_stale.* = true;
        }
        self.run_active = false;
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
        structures.items(.stale)[i] = false;
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
        structures.items(.stale)[i] = false;
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
        structures.items(.stale)[i] = false;
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

    /// Enforces the configured byte budget by releasing old-run versions first,
    /// then progressively decimating current-run history. The operation allocates
    /// nothing; released quantity side-array ranges remain as harmless holes.
    pub fn enforceBudget(self: *Scene) void {
        while (self.blob_bytes > self.retention.budget_bytes) {
            if (self.findOldRunCandidate()) |candidate| {
                self.removeVersion(candidate.structure, candidate.version);
                continue;
            }

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

    fn releaseExpiredVersions(self: *Scene, structure_index: StructureIndex) void {
        const retained_runs: u32 = self.retention.max_runs;
        if (self.run < retained_runs) return;
        const last_expired_run = self.run - retained_runs;
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

    fn findOldRunCandidate(self: *const Scene) ?EvictionCandidate {
        const structures = self.structures.slice();
        const version_lists = structures.items(.versions);
        var best: ?EvictionCandidate = null;
        for (version_lists, 0..) |version_list, structure_i| {
            if (version_list.items.len == 1) continue;
            for (version_list.items, 0..) |version, version_i| {
                if (version.run >= self.run) continue;
                const candidate: EvictionCandidate = .{
                    .structure = @fromBackingInt(@intCast(structure_i)),
                    .version = @intCast(version_i),
                };
                if (best) |current| {
                    const current_versions = version_lists[indexOf(current.structure)].items;
                    const current_version = current_versions[current.version];
                    if (version.run > current_version.run or
                        (version.run == current_version.run and version.frame >= current_version.frame)) continue;
                }
                best = candidate;
            }
        }
        return best;
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

    /// Creates a 64-byte-aligned, refcount-one blob and queues its index in
    /// `new_blobs`. Registered mapping slices are adopted without allocation;
    /// all other bytes are copied into scene-owned storage.
    pub fn createBlob(self: *Scene, bytes: []const u8) std.mem.Allocator.Error!BlobIndex {
        try self.reserveBlobCreates(1);
        return self.createBlobAssumeReserved(bytes);
    }

    /// Adds one owning reference to a live blob without allocation.
    pub fn retainBlob(self: *Scene, blob_index: BlobIndex) void {
        std.debug.assert(blob_index != .none);
        var blobs = self.blobs.slice();
        const refcount = &blobs.items(.refcount)[indexOf(blob_index)];
        std.debug.assert(refcount.* > 0);
        refcount.* += 1;
    }

    /// Releases one owning reference without allocating. At zero, owned bytes
    /// are freed; mapped bytes decrement their mapping and may queue its release.
    /// The blob index is queued in both `blob_free` and `freed_blobs`.
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

    /// Returns immutable scene-owned blob bytes without allocation. The view
    /// remains valid until the blob's final `releaseBlob` or scene deinit.
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

    /// Registers an edge-owned mapping with refcount zero. The scene borrows
    /// `bytes` and `fd`; registration reserves every future release-queue push.
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

    /// Returns the borrowed bytes of a registered mapping without allocation.
    /// The view remains valid until the edge forgets the mapping index.
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

    /// Returns one registered mapping record by value without allocation. The
    /// record remains edge-owned and must not be closed before `forgetMapping`.
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

    /// Queues every registered zero-ref mapping in registration-index order.
    /// `registerMapping` pre-reserves this operation, so it never allocates.
    pub fn releaseUnreferencedMappings(self: *Scene) void {
        const mappings = self.mappings.slice();
        const fds = mappings.items(.fd);
        const refcounts = mappings.items(.refcount);
        for (fds, refcounts, 0..) |fd, refcount, i| {
            if (fd < 0 or refcount != 0) continue;
            self.queueMappingRelease(@fromBackingInt(@intCast(i)));
        }
    }

    /// Forgets a zero-ref mapping after the edge has unmapped its bytes and
    /// closed its fd. The slot is returned to the free list without allocation.
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

    /// Moves every still-registered mapping into caller-owned `out`, using the
    /// scene allocator only to reserve output capacity. The edge then owns all
    /// returned fds/mappings and must unmap and close them before `deinit`.
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

    /// Finds a structure by borrowed name without allocation. The returned
    /// index remains stable for the lifetime of that structure.
    pub fn find(self: *const Scene, name: []const u8) ?StructureIndex {
        if (std.mem.findScalar(u8, name, 0) != null) return null;
        const raw = self.string_table.getKeyAdapted(name, std.hash_map.StringIndexAdapter{
            .bytes = &self.strings,
        }) orelse return null;
        return self.by_name.get(@fromBackingInt(@intCast(raw)));
    }

    /// Selects the latest current-run version at or before `frame` without
    /// allocating. A structure with no current-run versions falls back to its
    /// last retained previous-run version; one first registered later returns null.
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

    /// Selects the latest version in exactly `run` at or before `frame` without
    /// allocating. No version from another run is used as a fallback.
    pub fn versionAtRun(self: *const Scene, structure_index: StructureIndex, run: u32, frame: u32) ?u32 {
        const structures = self.structures.slice();
        const versions = structures.items(.versions)[indexOf(structure_index)].items;
        var i = versions.len;
        while (i > 0) {
            i -= 1;
            const version = versions[i];
            if (version.run == run and version.frame <= frame) return @intCast(i);
        }
        return null;
    }

    /// Reports whether the current run has a version at exactly `frame` for
    /// `structure_index`. The lookup borrows scene state and never allocates.
    pub fn hasExactVersion(self: *const Scene, structure_index: StructureIndex, frame: u32) bool {
        const structures = self.structures.slice();
        const versions = structures.items(.versions)[indexOf(structure_index)].items;
        for (versions) |version| {
            if (version.run == self.run and version.frame == frame) return true;
        }
        return false;
    }

    /// Returns the number of frames in the current run (frame 0 is implicit,
    /// so this is 1 right after begin_run); borrows scene state, never allocates.
    pub fn frameCount(self: *const Scene) u32 {
        return @intCast(self.frame_labels.items.len);
    }

    /// Returns the known frame count for the current or immediately previous
    /// run without allocating. Older and future runs return zero.
    pub fn frameCountOfRun(self: *const Scene, run: u32) u32 {
        if (run == self.run) return self.frameCount();
        if (self.run > 1 and run == self.run - 1) return self.previous_frame_count;
        return 0;
    }

    /// Returns live blob bytes/count, retained version count, and evictions
    /// since the current run began. It scans flat version arrays without allocation.
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

    /// Returns a borrowed interned string without allocation. The `.none`
    /// sentinel maps to an empty string; other views invalidate on interning.
    pub fn string(self: *const Scene, string_index: StringIndex) []const u8 {
        if (string_index == .none) return "";
        return std.mem.sliceTo(self.strings.items[indexOf(string_index)..], 0);
    }

    /// Returns a zero-copy positions view over a live scene-owned blob. The
    /// view borrows the scene and never allocates.
    pub fn positionsOf(self: *const Scene, version: Version) layout.Positions.Const {
        return layout.Positions.Const.fromBytes(self.blobBytes(version.positions));
    }

    /// Returns a zero-copy face view over a version's topology blob. The view
    /// borrows the scene and never allocates.
    pub fn facesOf(self: *const Scene, version: Version) []const [3]u32 {
        if (version.topology == .none) return &.{};
        return std.mem.bytesAsSlice([3]u32, self.blobBytes(version.topology));
    }

    /// Returns a zero-copy segment view over a version's topology blob. The
    /// view borrows the scene and never allocates.
    pub fn segmentsOf(self: *const Scene, version: Version) []const [2]u32 {
        if (version.topology == .none) return &.{};
        return std.mem.bytesAsSlice([2]u32, self.blobBytes(version.topology));
    }

    /// Returns the immutable quantity range owned by `version`. The returned
    /// slice borrows a structure side array and is invalidated by later applies.
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

test "upsert keeps UI and retains comparable previous-run geometry" {
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
    try testing.expectEqual(2, structures.items(.versions)[indexOf(structure_index)].items.len);
    try testing.expect(scene.versionAtRun(structure_index, 1, 0) != null);
    try testing.expect(scene.versionAtRun(structure_index, 2, 0) != null);
    try testing.expect(!structures.items(.ui)[indexOf(structure_index)].visible);
    try testing.expect(!structures.items(.stale)[indexOf(structure_index)]);
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

test "quantity errors staleness and timeline selection" {
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
    const structures = scene.structures.slice();
    try testing.expect(structures.items(.stale)[indexOf(surface)]);
    try testing.expect(structures.items(.stale)[indexOf(late)]);
    try testing.expect(scene.versionAt(surface, 0) != null);
    try testing.expectError(error.NoRunActive, scene.apply(.{ .end_frame = {} }));
    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "surface", positions.toConst(), &faces);
    const refreshed = scene.structures.slice();
    try testing.expect(!refreshed.items(.stale)[indexOf(surface)]);
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

test "budget evicts previous-run versions before current-run decimation" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    const positions = try layout.Positions.alloc(testing.allocator, 3);
    defer positions.free(testing.allocator);
    const faces = [_][3]u32{.{ 0, 1, 2 }};

    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "surface", positions.toConst(), &faces);
    const surface = scene.find("surface").?;
    try scene.apply(.{ .begin_frame = .{ .index = 1, .label = "" } });
    try scene.apply(.{ .mesh_positions = .{ .name = "surface", .positions = positions.toConst() } });
    try scene.apply(.{ .end_run = {} });
    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "surface", positions.toConst(), &faces);

    scene.retention.budget_bytes = scene.blob_bytes - 1;
    scene.enforceBudget();
    try testing.expect(scene.versionAtRun(surface, 1, 0) == null);
    try testing.expect(scene.versionAtRun(surface, 1, 1) != null);
    try testing.expect(scene.hasExactVersion(surface, 0));
    try testing.expectEqual(@as(u8, 1), scene.decimation_level);
    try testing.expectEqual(@as(u32, 1), scene.evicted_versions);
    try expectMemoryAccounting(&scene);
}

test "max_runs retains run two and drops run one when run three begins" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    const positions = try layout.Positions.alloc(testing.allocator, 3);
    defer positions.free(testing.allocator);
    const faces = [_][3]u32{.{ 0, 1, 2 }};
    scene.retention.max_runs = 2;

    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "surface", positions.toConst(), &faces);
    const surface = scene.find("surface").?;
    try scene.apply(.{ .begin_frame = .{ .index = 1, .label = "run-one" } });
    try scene.apply(.{ .mesh_positions = .{ .name = "surface", .positions = positions.toConst() } });
    try scene.apply(.{ .end_run = {} });

    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "surface", positions.toConst(), &faces);
    try scene.apply(.{ .begin_frame = .{ .index = 1, .label = "run-two" } });
    try scene.apply(.{ .mesh_positions = .{ .name = "surface", .positions = positions.toConst() } });
    try scene.apply(.{ .end_run = {} });
    try scene.apply(.{ .begin_run = {} });

    try testing.expect(scene.versionAtRun(surface, 1, 1) == null);
    try testing.expect(scene.versionAtRun(surface, 2, 0) != null);
    try testing.expect(scene.versionAtRun(surface, 2, 1) != null);
    try testing.expectEqual(@as(u32, 1), scene.frameCountOfRun(3));
    try testing.expectEqual(@as(u32, 2), scene.frameCountOfRun(2));
    try testing.expectEqual(@as(u32, 0), scene.frameCountOfRun(1));
    try expectMemoryAccounting(&scene);
}

test "expired stale placeholder is released once a current replacement exists" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    const positions = try layout.Positions.alloc(testing.allocator, 3);
    defer positions.free(testing.allocator);
    const faces = [_][3]u32{.{ 0, 1, 2 }};
    scene.retention.max_runs = 1;

    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "surface", positions.toConst(), &faces);
    const surface = scene.find("surface").?;
    try scene.apply(.{ .end_run = {} });
    try scene.apply(.{ .begin_run = {} });
    try testing.expect(scene.versionAtRun(surface, 1, 0) != null);
    try applyMesh(&scene, "surface", positions.toConst(), &faces);
    try testing.expect(scene.versionAtRun(surface, 1, 0) == null);
    try testing.expectEqual(@as(usize, 1), scene.structures.slice().items(.versions)[indexOf(surface)].items.len);
    try expectMemoryAccounting(&scene);
}

test "stale structure keeps its last version under budget pressure" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    const positions = try layout.Positions.alloc(testing.allocator, 3);
    defer positions.free(testing.allocator);
    const faces = [_][3]u32{.{ 0, 1, 2 }};

    try scene.apply(.{ .begin_run = {} });
    try applyMesh(&scene, "stale", positions.toConst(), &faces);
    try applyMesh(&scene, "active", positions.toConst(), &faces);
    const stale = scene.find("stale").?;
    const stale_blob = latestVersionValue(&scene, stale).positions;
    try scene.apply(.{ .end_run = {} });
    try scene.apply(.{ .begin_run = {} });
    scene.retention.budget_bytes = 0;
    try applyMesh(&scene, "active", positions.toConst(), &faces);

    const stale_versions = scene.structures.slice().items(.versions)[indexOf(stale)].items;
    try testing.expectEqual(@as(usize, 1), stale_versions.len);
    try testing.expect(scene.versionAt(stale, 0) != null);
    try testing.expect(scene.blobs.slice().items(.refcount)[indexOf(stale_blob)] > 0);
    try testing.expect(scene.blob_bytes > scene.retention.budget_bytes);
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

test "per-version scene overhead beyond blob bytes stays within a fixed envelope" {
    // The retention model assumes a version costs its blob bytes plus a
    // small fixed record. A hidden per-version container (list, map) would
    // pass every other test and silently multiply timeline memory; this pins
    // the overhead in bytes using the debug allocator's live accounting.
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
    const per_version = overhead / versions;
    // Measured 68 bytes on 2026-08-24 (Version record + Blob record + list
    // growth slack). The envelope leaves room for slack, not for new
    // per-version records; if this trips, look for a container per version.
    if (per_version > 128) {
        std.debug.print("scene per-version overhead: {d} bytes ({d} versions)\n", .{ per_version, versions });
        return error.PerVersionOverheadExceeded;
    }
}
