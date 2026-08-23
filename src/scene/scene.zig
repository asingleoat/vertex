//! Pure, allocation-explicit scene storage for decoded protocol messages.
//!
//! Structure identity is its interned name. Viewer-owned UI state therefore
//! survives runs while geometry versions and refcounted, 64-byte-aligned blobs
//! remain entirely inside this module.
const std = @import("std");
const layout = @import("../geometry/layout.zig");
const protocol = @import("../protocol/protocol.zig");

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

/// Byte offset of a NUL-terminated entry in `Scene.strings`; borrowed string
/// views are invalidated when the scene interns another string.
pub const StringIndex = enum(u32) { none = std.math.maxInt(u32), _ };

/// Renderable structure kind; this value owns no memory and never allocates.
pub const Kind = enum(u8) { mesh, points, lines };

/// Quantity payload kind; this value owns no memory and never allocates.
pub const QuantityKind = enum(u8) { scalar, vector };

/// Persistent per-name viewer state. It owns no memory and never allocates.
pub const UiState = struct {
    visible: bool = true,
    wireframe: bool = false,
    active_quantity: StringIndex = .none,
    point_size: f32 = 4,
    line_width: f32 = 1.5,
    colormap: @import("colormap.zig").Colormap = .viridis,
    vector_scale: f32 = 1.0,
};

/// One chronological geometry snapshot. Blob references are owned by the
/// containing structure until that version is dropped or the scene is deinitialized.
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

/// Refcounted, scene-owned blob. `bytes` is freed exactly once when its
/// refcount reaches zero or the owning scene is deinitialized.
pub const Blob = struct {
    bytes: []align(layout.blob_alignment.toByteUnits()) u8,
    refcount: u32,
};

/// Interned log entry. Text storage is owned by the containing scene.
pub const LogEntry = struct {
    level: protocol.LogLevel,
    text: StringIndex,
};

/// Errors from applying a decoded message. OOM is reported without leaking;
/// all other errors describe protocol messages that cannot mutate this scene.
pub const ApplyError = std.mem.Allocator.Error || error{
    UnknownStructure,
    KindMismatch,
    CountMismatch,
    NoRunActive,
};

/// Maximum retained log entries. Interned text remains scene-owned even after
/// an old entry is evicted; the entry array does not grow beyond this cap.
pub const max_log_entries: usize = 1024;

const empty_blob_storage: [0]u8 align(layout.blob_alignment.toByteUnits()) = .{};

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
    frame_labels: std.ArrayList(StringIndex) = .empty,
    log: std.ArrayList(LogEntry) = .empty,
    run: u32 = 0,
    frame: u32 = 0,
    run_active: bool = false,
    source_name: StringIndex = .none,
    live_blobs: u32 = 0,

    /// Initializes an empty scene without allocating. The caller must keep
    /// `gpa` valid until `deinit`.
    pub fn init(gpa: std.mem.Allocator) Scene {
        return .{ .gpa = gpa };
    }

    /// Frees every allocation owned by the scene with the allocator retained
    /// by `init`. Borrowed views and all typed indices become invalid.
    pub fn deinit(self: *Scene) void {
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
        for (bytes, refcounts) |blob_bytes, refcount| {
            if (refcount != 0) self.gpa.free(blob_bytes);
        }

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

    /// Applies one decoded message, copying every retained slice into
    /// scene-owned storage. Only allocation failure and semantic scene errors
    /// are returned; no effects outside this scene occur.
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
                var structures = self.structures.slice();
                @memset(structures.items(.touched), false);
                return;
            },
            else => {},
        }

        if (!self.run_active) return error.NoRunActive;
        switch (message) {
            .hello, .begin_run => unreachable,
            .begin_frame => |begin| try self.beginFrame(begin.index, begin.label),
            .end_frame => {},
            .end_run => self.endRun(),
            .mesh => |mesh| try self.registerGeometry(
                mesh.name,
                .mesh,
                mesh.dim,
                mesh.positions,
                std.mem.sliceAsBytes(mesh.faces),
            ),
            .mesh_positions => |update| try self.updateMeshPositions(update),
            .points => |points| try self.registerGeometry(
                points.name,
                .points,
                points.dim,
                points.positions,
                null,
            ),
            .lines => |lines| try self.registerGeometry(
                lines.name,
                .lines,
                lines.dim,
                lines.positions,
                std.mem.sliceAsBytes(lines.segments),
            ),
            .scalar_quantity => |quantity| try self.putQuantity(
                quantity.structure,
                quantity.name,
                quantity.target,
                .scalar,
                @intCast(quantity.values.len),
                std.mem.sliceAsBytes(quantity.values),
            ),
            .vector_quantity => |quantity| try self.putQuantity(
                quantity.structure,
                quantity.name,
                quantity.target,
                .vector,
                quantity.vectors.len(),
                quantity.vectors.bytes(),
            ),
            .log => |entry| try self.appendLog(entry),
        }
    }

    /// Copies bytes into a new 64-byte-aligned, refcount-one blob and queues
    /// its index in `new_blobs`. The scene owns the copy; a free slot is reused.
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

    /// Releases one owning reference without allocating. At zero, bytes are
    /// freed and the index is queued in both `blob_free` and `freed_blobs`.
    pub fn releaseBlob(self: *Scene, blob_index: BlobIndex) void {
        std.debug.assert(blob_index != .none);
        var blobs = self.blobs.slice();
        const i = indexOf(blob_index);
        const refcount = &blobs.items(.refcount)[i];
        std.debug.assert(refcount.* > 0);
        refcount.* -= 1;
        if (refcount.* != 0) return;

        self.gpa.free(blobs.items(.bytes)[i]);
        blobs.items(.bytes)[i] = emptyBlobBytes();
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

    /// Returns the number of frames in the current run (frame 0 is implicit,
    /// so this is 1 right after begin_run); borrows scene state, never allocates.
    pub fn frameCount(self: *const Scene) u32 {
        return @intCast(self.frame_labels.items.len);
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
        const existing = self.by_name.get(name);
        const blob_count: usize = if (topology_bytes == null) 1 else 2;

        if (existing) |structure_index| {
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
                (version_list.items[version_list.items.len - 1].run != self.run or
                    structures.items(.kind)[i] != kind or structures.items(.dim)[i] != dim);
            version_list.appendAssumeCapacity(.{
                .run = self.run,
                .frame = self.frame,
                .positions = position_blob,
                .topology = topology_blob,
                .quantity_start = @intCast(quantity_list.items.len),
                .quantity_len = 0,
            });
            if (replace_history) self.collapseToLatest(structure_index);

            structures = self.structures.slice();
            structures.items(.kind)[i] = kind;
            structures.items(.dim)[i] = dim;
            structures.items(.touched)[i] = true;
            structures.items(.stale)[i] = false;
            return;
        }

        try self.structures.ensureTotalCapacity(self.gpa, self.structures.len + 1);
        try self.by_name.ensureUnusedCapacity(self.gpa, 1);
        var structure: Structure = .{ .name = name, .kind = kind, .dim = dim, .touched = true };
        errdefer {
            structure.versions.deinit(self.gpa);
            structure.quantity_refs.deinit(self.gpa);
        }
        try structure.versions.ensureUnusedCapacity(self.gpa, 1);
        try self.reserveBlobCreates(blob_count);

        const position_blob = try self.createBlobAssumeReserved(positions.bytes());
        errdefer self.discardCreatedBlob(position_blob);
        const topology_blob = if (topology_bytes) |bytes|
            try self.createBlobAssumeReserved(bytes)
        else
            BlobIndex.none;
        structure.versions.appendAssumeCapacity(.{
            .run = self.run,
            .frame = self.frame,
            .positions = position_blob,
            .topology = topology_blob,
            .quantity_start = 0,
            .quantity_len = 0,
        });

        const structure_index: StructureIndex = @fromBackingInt(@intCast(@as(u32, @intCast(self.structures.len))));
        self.structures.appendAssumeCapacity(structure);
        self.by_name.putAssumeCapacityNoClobber(name, structure_index);
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
        const quantity_start: u32 = @intCast(quantity_list.items.len);
        const previous_start: usize = previous.quantity_start;
        const previous_end = previous_start + previous.quantity_len;
        const previous_quantities = quantity_list.items[previous_start..previous_end];
        for (previous_quantities) |quantity| {
            self.retainBlob(quantity.blob);
            quantity_list.appendAssumeCapacity(quantity);
        }
        version_list.appendAssumeCapacity(.{
            .run = self.run,
            .frame = self.frame,
            .positions = position_blob,
            .topology = previous.topology,
            .quantity_start = quantity_start,
            .quantity_len = previous.quantity_len,
        });
        if (previous.run != self.run) self.collapseToLatest(structure_index);

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
        var old_refs = self.quantities(structure_index, previous);
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

            const previous_start: usize = previous.quantity_start;
            const previous_end = previous_start + previous.quantity_len;
            old_refs = quantity_list.items[previous_start..previous_end];
            self.retainBlob(previous.positions);
            if (previous.topology != .none) self.retainBlob(previous.topology);
            const quantity_start: u32 = @intCast(quantity_list.items.len);
            var replaced = false;
            for (old_refs) |quantity| {
                if (quantity.name == name) {
                    var replacement = new_ref;
                    replacement.blob = blob;
                    quantity_list.appendAssumeCapacity(replacement);
                    replaced = true;
                } else {
                    self.retainBlob(quantity.blob);
                    quantity_list.appendAssumeCapacity(quantity);
                }
            }
            if (!replaced) {
                var appended = new_ref;
                appended.blob = blob;
                quantity_list.appendAssumeCapacity(appended);
            }
            version_list.appendAssumeCapacity(.{
                .run = self.run,
                .frame = self.frame,
                .positions = previous.positions,
                .topology = previous.topology,
                .quantity_start = quantity_start,
                .quantity_len = @intCast(additional),
            });
            if (previous.run != self.run) self.collapseToLatest(structure_index);
        }

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

    fn collapseToLatest(self: *Scene, structure_index: StructureIndex) void {
        const i = indexOf(structure_index);
        var structures = self.structures.slice();
        const versions = &structures.items(.versions)[i];
        const quantity_list = &structures.items(.quantity_refs)[i];
        std.debug.assert(versions.items.len > 0);
        const latest = versions.items[versions.items.len - 1];

        for (versions.items[0 .. versions.items.len - 1]) |version| self.releaseVersion(structure_index, version);
        const start: usize = latest.quantity_start;
        const len: usize = latest.quantity_len;
        std.mem.copyForwards(QuantityRef, quantity_list.items[0..len], quantity_list.items[start .. start + len]);
        quantity_list.items.len = len;
        versions.items[0] = latest;
        versions.items[0].quantity_start = 0;
        versions.items.len = 1;
    }

    fn releaseVersion(self: *Scene, structure_index: StructureIndex, version: Version) void {
        self.releaseBlob(version.positions);
        if (version.topology != .none) self.releaseBlob(version.topology);
        for (self.quantities(structure_index, version)) |quantity| self.releaseBlob(quantity.blob);
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

    fn reserveBlobCreates(self: *Scene, count: usize) std.mem.Allocator.Error!void {
        const free_count = self.blob_free.items.len;
        const new_slots = count -| free_count;
        try self.blobs.ensureTotalCapacity(self.gpa, self.blobs.len + new_slots);
        try self.new_blobs.ensureUnusedCapacity(self.gpa, count);
        try self.blob_free.ensureTotalCapacity(self.gpa, self.blobs.len + new_slots);
        try self.freed_blobs.ensureUnusedCapacity(self.gpa, @as(usize, self.live_blobs) + count);
    }

    fn createBlobAssumeReserved(self: *Scene, bytes: []const u8) std.mem.Allocator.Error!BlobIndex {
        const owned = try self.gpa.alignedAlloc(u8, layout.blob_alignment, bytes.len);
        @memcpy(owned, bytes);

        const blob_index = if (self.blob_free.pop()) |free_index| blk: {
            var blobs = self.blobs.slice();
            const i = indexOf(free_index);
            std.debug.assert(blobs.items(.refcount)[i] == 0);
            blobs.items(.bytes)[i] = owned;
            blobs.items(.refcount)[i] = 1;
            break :blk free_index;
        } else blk: {
            const new_index: BlobIndex = @fromBackingInt(@intCast(@as(u32, @intCast(self.blobs.len))));
            self.blobs.appendAssumeCapacity(.{ .bytes = owned, .refcount = 1 });
            break :blk new_index;
        };
        self.new_blobs.appendAssumeCapacity(blob_index);
        self.live_blobs += 1;
        return blob_index;
    }

    fn discardCreatedBlob(self: *Scene, blob_index: BlobIndex) void {
        const queued = self.new_blobs.pop().?;
        std.debug.assert(queued == blob_index);
        var blobs = self.blobs.slice();
        const i = indexOf(blob_index);
        std.debug.assert(blobs.items(.refcount)[i] == 1);
        self.gpa.free(blobs.items(.bytes)[i]);
        blobs.items(.bytes)[i] = emptyBlobBytes();
        blobs.items(.refcount)[i] = 0;
        self.blob_free.appendAssumeCapacity(blob_index);
        self.live_blobs -= 1;
    }
};

fn indexOf(index: anytype) usize {
    return @backingInt(index);
}

fn emptyBlobBytes() []align(layout.blob_alignment.toByteUnits()) u8 {
    return @constCast(empty_blob_storage[0..]);
}

const testing = std.testing;

fn latestVersionValue(scene: *const Scene, structure_index: StructureIndex) Version {
    const structures = scene.structures.slice();
    const versions = structures.items(.versions)[indexOf(structure_index)].items;
    return versions[versions.len - 1];
}

fn applyMesh(scene: *Scene, name: []const u8, positions: layout.Positions.Const, faces: []const [3]u32) !void {
    try scene.apply(.{ .mesh = .{ .name = name, .dim = .d3, .positions = positions, .faces = faces } });
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
    try scene.apply(try protocol.decode(header, payload));
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

test "upsert keeps UI while previous-run geometry is replaced" {
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
    try testing.expectEqual(1, structures.items(.versions)[indexOf(structure_index)].items.len);
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

test "log retains the newest 1024 entries" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();
    try scene.apply(.{ .begin_run = {} });
    var storage: [16]u8 = undefined;
    for (0..max_log_entries + 3) |i| {
        const text = try std.fmt.bufPrint(&storage, "entry-{d}", .{i});
        try scene.apply(.{ .log = .{ .level = .info, .text = text } });
    }
    try testing.expectEqual(max_log_entries, scene.log.items.len);
    try testing.expectEqualStrings("entry-3", scene.string(scene.log.items[0].text));
    try testing.expectEqualStrings("entry-1026", scene.string(scene.log.items[max_log_entries - 1].text));
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
    try scene.apply(.{ .begin_frame = .{ .index = 1, .label = "one" } });
    try scene.apply(.{ .mesh_positions = .{ .name = "surface", .positions = positions.toConst() } });
    try scene.apply(.{ .end_run = {} });
}

test "all allocating scene paths handle every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationFailureCase, .{});
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
