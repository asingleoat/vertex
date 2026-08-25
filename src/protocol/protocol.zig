//! Allocation-free, zero-copy vertex wire protocol.
//!
//! Frames use native endianness because both peers are the same build. `len`
//! counts payload bytes after the eight-byte frame header. String fields are
//! contiguous after their fixed head. Each following binary section begins at
//! a payload-relative multiple of 16; its preceding gap contains zero bytes.
//! Frames with any external section instead place one `SectionRef` per binary
//! section after the strings at a 16-byte boundary, followed by only the inline
//! sections. External offsets address 64-byte-aligned fd mappings.
//!
//! ```text
//! struct/head         bytes  byte offsets and fields
//! Header                  8  0:len u32, 4:kind u16, 6:flags u16
//! HelloHead               8  0:magic [4]u8, 4:version u16, 6:name_len u16
//! BeginFrameHead          8  0:index u32, 4:label_len u16, 6:_pad u16
//! MeshHead               12  0:vertex_count u32, 4:face_count u32,
//!                            8:name_len u16, 10:dim u8, 11:_pad u8
//! MeshPositionsHead       8  0:vertex_count u32, 4:name_len u16, 6:_pad u16
//! PointsHead              8  0:count u32, 4:name_len u16, 6:dim u8, 7:_pad u8
//! LinesHead              12  0:vertex_count u32, 4:segment_count u32,
//!                            8:name_len u16, 10:dim u8, 11:_pad u8
//! ScalarQuantityHead     12  0:count u32, 4:structure_len u16, 6:name_len u16,
//!                            8:target u8, 9:_pad [3]u8
//! VectorQuantityHead     12  same field layout as ScalarQuantityHead
//! LogHead                 8  0:text_len u32, 4:level u8, 5:_pad [3]u8
//!
//! kind              head bytes  payload after head
//! hello                    8     name[name_len]
//! begin_run                0     -
//! begin_frame              8     label[label_len]
//! end_frame                0     -
//! end_run                  0     -
//! mesh                    12     name | align16 | Positions(vertex_count)
//!                                | align16 | [3]u32[face_count]
//! mesh_positions           8     name | align16 | Positions(vertex_count)
//! points                    8     name | align16 | Positions(count)
//! lines                    12     name | align16 | Positions(vertex_count)
//!                                | align16 | [2]u32[segment_count]
//! scalar_quantity         12     structure + name | align16 | f32[count]
//! vector_quantity         12     structure + name | align16 | Positions(count)
//! log                       8     text[text_len]
//! ```
const std = @import("std");
const layout = @import("../geometry/layout.zig");

// ---------------------------------------------------------------------------
// constants / types

/// Protocol compatibility version. The value owns no memory, and access allocates nothing.
pub const version: u16 = 2;

/// Handshake magic. The value owns no memory, and access allocates nothing.
pub const magic: [4]u8 = "VTXP".*;

/// Maximum accepted source, structure, and quantity name length. The constant
/// owns no memory and allocates nothing.
pub const max_name_len = 255;

/// Payload-relative alignment of binary sections. The constant owns no memory, and encoding allocates nothing.
/// Sections start at multiples of 16 from the payload start so that a payload
/// placed in 16-aligned memory yields SIMD-aligned views; `decode` itself only
/// needs `payload_alignment`.
pub const section_alignment = 16;

/// Minimum alignment `decode` requires of a borrowed payload buffer. The
/// constant owns no memory and allocates nothing; it covers every element type
/// that appears in a section (`f32`, `u32`, `Positions.Elem`).
pub const payload_alignment = @max(@alignOf(u32), @alignOf(f32), @alignOf(layout.Positions.Elem));

/// Wire message tag. Values own no memory; unknown v2 tags are rejected without allocation.
pub const Kind = enum(u16) {
    hello = 1,
    begin_run,
    begin_frame,
    end_frame,
    end_run,
    mesh,
    mesh_positions,
    points,
    lines,
    scalar_quantity,
    vector_quantity,
    log,
    _,
};

/// Geometric dimensionality carried by geometry messages. Values own no memory
/// and allocate nothing.
pub const Dim = enum(u8) { d2 = 2, d3 = 3 };

/// Quantity attachment target. Values own no memory and allocate nothing.
pub const Target = enum(u8) { vertex = 0, face = 1, point = 2 };

/// Log severity. Values own no memory and allocate nothing.
pub const LogLevel = enum(u8) { info, warn, err };

/// Borrowed encoder input for one binary section. Inline bytes must outlive
/// the write; an external reference owns neither its mapping nor its fd. The
/// union itself allocates nothing.
pub const Section = union(enum) {
    @"inline": []const u8,
    external: External,

    /// Location of bytes inside one fd-backed mapping; owns no memory and allocates nothing.
    pub const External = struct {
        fd_index: u32,
        offset: u64,
        len: u64,
    };
};

/// Maximum binary sections per message. The constant owns no memory and allocates nothing.
pub const max_sections = 2;

/// Errors returned by total, allocation-free frame decoding. The error set
/// owns no memory.
pub const DecodeError = error{
    Truncated,
    BadLength,
    BadMagic,
    VersionMismatch,
    UnknownKind,
    BadEnum,
    NameTooLong,
    Misaligned,
    MissingMapping,
};

/// Decoded hello payload. `name` borrows the payload buffer; no allocation occurs.
pub const Hello = struct { name: []const u8 };

/// Decoded frame marker. `label` borrows the payload buffer; no allocation occurs.
pub const BeginFrame = struct {
    index: u32,
    label: []const u8,
};

/// Decoded mesh. Every view borrows the payload buffer; no allocation occurs.
pub const Mesh = struct {
    name: []const u8,
    dim: Dim,
    positions: layout.Positions.Const,
    faces: []const [3]u32,
};

/// Decoded topology-preserving mesh update. All views borrow the payload buffer; no allocation occurs.
pub const MeshPositions = struct {
    name: []const u8,
    positions: layout.Positions.Const,
};

/// Decoded point set. Every view borrows the payload buffer; no allocation occurs.
pub const Points = struct {
    name: []const u8,
    dim: Dim,
    positions: layout.Positions.Const,
};

/// Decoded line set. Every view borrows the payload buffer; no allocation occurs.
pub const Lines = struct {
    name: []const u8,
    dim: Dim,
    positions: layout.Positions.Const,
    segments: []const [2]u32,
};

/// Decoded scalar quantity. Every slice borrows the payload buffer; no allocation occurs.
pub const ScalarQuantity = struct {
    structure: []const u8,
    name: []const u8,
    target: Target,
    values: []const f32,
};

/// Decoded vector quantity. Every view borrows the payload buffer; no allocation occurs.
pub const VectorQuantity = struct {
    structure: []const u8,
    name: []const u8,
    target: Target,
    vectors: layout.Positions.Const,
};

/// Decoded log entry. `text` borrows the payload buffer; no allocation occurs.
pub const Log = struct {
    level: LogLevel,
    text: []const u8,
};

/// Decoded message whose slices borrow the supplied payload or mapping buffers; no allocation occurs.
pub const Message = union(Kind) {
    hello: Hello,
    begin_run: void,
    begin_frame: BeginFrame,
    end_frame: void,
    end_run: void,
    mesh: Mesh,
    mesh_positions: MeshPositions,
    points: Points,
    lines: Lines,
    scalar_quantity: ScalarQuantity,
    vector_quantity: VectorQuantity,
    log: Log,
};

// ---------------------------------------------------------------------------
// heads

/// Eight-byte frame header. `flags` uses `Flags`; the value is copied into or
/// out of caller-owned bytes, owns no memory, and allocates nothing.
pub const Header = extern struct {
    len: u32,
    kind: u16,
    flags: u16 = 0,
};

/// Bit layout of `Header.flags`; conversion to/from the wire integer is a
/// bit-cast. Values own no memory and allocate nothing.
pub const Flags = packed struct(u16) {
    external: bool = false,
    fd_count: u3 = 0,
    _pad: u12 = 0,

    /// Returns a non-owning flags value from native-endian bits without allocation.
    pub fn fromInt(raw: u16) Flags {
        return @bitCast(raw);
    }

    /// Returns native-endian bits by value without ownership transfer or allocation.
    pub fn toInt(self: Flags) u16 {
        return @bitCast(self);
    }
};

/// One allocation-free binary-section descriptor in an external frame. The
/// descriptor owns no memory: external data borrows the mapping selected by
/// `fd_index`, while inline data remains in the frame.
pub const SectionRef = extern struct {
    source: u32,
    fd_index: u32,
    offset: u64,
    len: u64,
};

/// Eight-byte fixed head for `hello`; the record owns no memory and allocates nothing.
pub const HelloHead = extern struct {
    magic: [4]u8,
    version: u16,
    name_len: u16,
};

/// Eight-byte fixed head for `begin_frame`; the record owns no memory and allocates nothing.
pub const BeginFrameHead = extern struct {
    index: u32,
    label_len: u16,
    _pad: u16,
};

/// Twelve-byte fixed head for `mesh`; the record owns no memory and allocates nothing.
pub const MeshHead = extern struct {
    vertex_count: u32,
    face_count: u32,
    name_len: u16,
    dim: u8,
    _pad: u8,
};

/// Eight-byte fixed head for `mesh_positions`; the record owns no memory and allocates nothing.
pub const MeshPositionsHead = extern struct {
    vertex_count: u32,
    name_len: u16,
    _pad: u16,
};

/// Eight-byte fixed head for `points`; the record owns no memory and allocates nothing.
pub const PointsHead = extern struct {
    count: u32,
    name_len: u16,
    dim: u8,
    _pad: u8,
};

/// Twelve-byte fixed head for `lines`; the record owns no memory and allocates nothing.
pub const LinesHead = extern struct {
    vertex_count: u32,
    segment_count: u32,
    name_len: u16,
    dim: u8,
    _pad: u8,
};

/// Twelve-byte fixed head for `scalar_quantity`; the record owns no memory and allocates nothing.
pub const ScalarQuantityHead = extern struct {
    count: u32,
    structure_len: u16,
    name_len: u16,
    target: u8,
    _pad: [3]u8,
};

/// Twelve-byte fixed head for `vector_quantity`; the record owns no memory and allocates nothing.
pub const VectorQuantityHead = extern struct {
    count: u32,
    structure_len: u16,
    name_len: u16,
    target: u8,
    _pad: [3]u8,
};

/// Eight-byte fixed head for `log`; the record owns no memory and allocates nothing.
pub const LogHead = extern struct {
    text_len: u32,
    level: u8,
    _pad: [3]u8,
};

// ---------------------------------------------------------------------------
// encode

/// Maximum header, head, padding, and caller-owned slices in an encoding. The
/// constant owns no memory and allocates nothing.
pub const max_parts = 12;

/// Largest fixed payload head in bytes. The constant owns no memory; encoding
/// stores the head inline without allocation.
pub const max_head_size = 12;

const zero_padding: [section_alignment - 1]u8 align(section_alignment) = @splat(0);

/// Borrowing scatter/gather encoding. Header and head storage are owned inline;
/// variable slices remain caller-owned and must outlive the write. `slices()`
/// installs self-referential header/head/descriptor views, so `Encoded` must not be
/// moved or copied after `slices()` (or `writeTo()`) is called. No method allocates.
pub const Encoded = struct {
    header: Header,
    head: [max_head_size]u8 align(8),
    descriptors: [max_sections]SectionRef,
    parts: [max_parts][]const u8,
    part_count: u8,
    descriptor_count: u8,
    descriptor_part: u8,

    /// Returns borrowed writev slices in wire order without allocation. The
    /// returned list and its inline header/head slices are invalidated by moving
    /// or copying this `Encoded`.
    pub fn slices(self: *Encoded) []const []const u8 {
        self.parts[0] = std.mem.asBytes(&self.header);
        const head_len = encodedHeadLen(self.header.kind);
        if (head_len != 0) self.parts[1] = self.head[0..head_len];
        if (self.descriptor_count != 0) {
            self.parts[self.descriptor_part] = std.mem.sliceAsBytes(self.descriptors[0..self.descriptor_count]);
        }
        return self.parts[0..self.part_count];
    }

    /// Returns the complete frame byte count without allocation.
    pub fn totalLen(self: *const Encoded) usize {
        return @sizeOf(Header) + @as(usize, self.header.len);
    }

    /// Concatenates into caller-owned, 16-aligned `buf` without allocation and
    /// returns the initialized prefix. `buf` must be at least `totalLen()` bytes.
    pub fn writeTo(self: *Encoded, buf: []align(section_alignment) u8) []align(section_alignment) u8 {
        std.debug.assert(buf.len >= self.totalLen());
        var offset: usize = 0;
        for (self.slices()) |part| {
            @memcpy(buf[offset..][0..part.len], part);
            offset += part.len;
        }
        std.debug.assert(offset == self.totalLen());
        return buf[0..offset];
    }
};

/// Writes caller-owned `out`, borrowing `name` through the write. Asserts the
/// name limit and allocates nothing.
pub fn encodeHello(out: *Encoded, name: []const u8) void {
    assertName(name);
    initHead(out, .hello, HelloHead{
        .magic = magic,
        .version = version,
        .name_len = @intCast(name.len),
    });
    addPart(out, name);
}

/// Writes an empty begin-run frame into caller-owned `out` without allocation.
pub fn encodeBeginRun(out: *Encoded) void {
    initEmpty(out, .begin_run);
}

/// Writes caller-owned `out`, borrowing `label` through the write and allocating nothing.
pub fn encodeBeginFrame(out: *Encoded, index: u32, label: []const u8) void {
    std.debug.assert(label.len <= std.math.maxInt(u16));
    initHead(out, .begin_frame, BeginFrameHead{
        .index = index,
        .label_len = @intCast(label.len),
        ._pad = 0,
    });
    addPart(out, label);
}

/// Writes an empty end-frame marker into caller-owned `out` without allocation.
pub fn encodeEndFrame(out: *Encoded) void {
    initEmpty(out, .end_frame);
}

/// Writes an empty end-run marker into caller-owned `out` without allocation.
pub fn encodeEndRun(out: *Encoded) void {
    initEmpty(out, .end_run);
}

/// Writes caller-owned `out`, borrowing every mesh section through the write
/// and allocating nothing.
pub fn encodeMesh(
    out: *Encoded,
    name: []const u8,
    dim: Dim,
    positions: layout.Positions.Const,
    faces: []const [3]u32,
) void {
    std.debug.assert(faces.len <= std.math.maxInt(u32));
    encodeMeshSections(
        out,
        name,
        dim,
        positions.len(),
        inlineSection(positions.bytes()),
        @intCast(faces.len),
        inlineSection(std.mem.sliceAsBytes(faces)),
    );
}

/// Writes caller-owned `out` with independently inline or external mesh
/// sections. Every input is borrowed through the write and no allocation occurs.
pub fn encodeMeshSections(
    out: *Encoded,
    name: []const u8,
    dim: Dim,
    vertex_count: u32,
    positions: Section,
    face_count: u32,
    faces: Section,
) void {
    assertName(name);
    initHead(out, .mesh, MeshHead{
        .vertex_count = vertex_count,
        .face_count = face_count,
        .name_len = @intCast(name.len),
        .dim = @backingInt(dim),
        ._pad = 0,
    });
    addPart(out, name);
    addSections(out, &.{ positions, faces }, &.{
        layout.Positions.byteSize(vertex_count),
        @as(usize, face_count) * @sizeOf([3]u32),
    });
}

/// Writes caller-owned `out`, borrowing replacement positions through the
/// write and allocating nothing.
pub fn encodeMeshPositions(out: *Encoded, name: []const u8, positions: layout.Positions.Const) void {
    encodeMeshPositionsSection(out, name, positions.len(), inlineSection(positions.bytes()));
}

/// Writes caller-owned `out` from an inline or external positions section. The
/// section is borrowed through the write and no allocation occurs.
pub fn encodeMeshPositionsSection(out: *Encoded, name: []const u8, vertex_count: u32, positions: Section) void {
    assertName(name);
    initHead(out, .mesh_positions, MeshPositionsHead{
        .vertex_count = vertex_count,
        .name_len = @intCast(name.len),
        ._pad = 0,
    });
    addPart(out, name);
    addSections(out, &.{positions}, &.{layout.Positions.byteSize(vertex_count)});
}

/// Writes caller-owned `out`, borrowing the point-set inputs through the write
/// and allocating nothing.
pub fn encodePoints(out: *Encoded, name: []const u8, dim: Dim, positions: layout.Positions.Const) void {
    encodePointsSection(out, name, dim, positions.len(), inlineSection(positions.bytes()));
}

/// Writes caller-owned `out` from an inline or external positions section. The
/// section is borrowed through the write and no allocation occurs.
pub fn encodePointsSection(out: *Encoded, name: []const u8, dim: Dim, count: u32, positions: Section) void {
    assertName(name);
    initHead(out, .points, PointsHead{
        .count = count,
        .name_len = @intCast(name.len),
        .dim = @backingInt(dim),
        ._pad = 0,
    });
    addPart(out, name);
    addSections(out, &.{positions}, &.{layout.Positions.byteSize(count)});
}

/// Writes caller-owned `out`, borrowing every line-set section through the
/// write and allocating nothing.
pub fn encodeLines(
    out: *Encoded,
    name: []const u8,
    dim: Dim,
    positions: layout.Positions.Const,
    segments: []const [2]u32,
) void {
    std.debug.assert(segments.len <= std.math.maxInt(u32));
    encodeLinesSections(
        out,
        name,
        dim,
        positions.len(),
        inlineSection(positions.bytes()),
        @intCast(segments.len),
        inlineSection(std.mem.sliceAsBytes(segments)),
    );
}

/// Writes caller-owned `out` with independently inline or external line-set
/// sections. Every input is borrowed through the write and no allocation occurs.
pub fn encodeLinesSections(
    out: *Encoded,
    name: []const u8,
    dim: Dim,
    vertex_count: u32,
    positions: Section,
    segment_count: u32,
    segments: Section,
) void {
    assertName(name);
    initHead(out, .lines, LinesHead{
        .vertex_count = vertex_count,
        .segment_count = segment_count,
        .name_len = @intCast(name.len),
        .dim = @backingInt(dim),
        ._pad = 0,
    });
    addPart(out, name);
    addSections(out, &.{ positions, segments }, &.{
        layout.Positions.byteSize(vertex_count),
        @as(usize, segment_count) * @sizeOf([2]u32),
    });
}

/// Writes caller-owned `out`, borrowing scalar strings and values through the
/// write and allocating nothing.
pub fn encodeScalarQuantity(
    out: *Encoded,
    structure: []const u8,
    name: []const u8,
    target: Target,
    values: []const f32,
) void {
    std.debug.assert(values.len <= std.math.maxInt(u32));
    encodeScalarQuantitySection(
        out,
        structure,
        name,
        target,
        @intCast(values.len),
        inlineSection(std.mem.sliceAsBytes(values)),
    );
}

/// Writes caller-owned `out` from inline or external scalar values. Every
/// input is borrowed through the write and no allocation occurs.
pub fn encodeScalarQuantitySection(
    out: *Encoded,
    structure: []const u8,
    name: []const u8,
    target: Target,
    count: u32,
    values: Section,
) void {
    assertName(structure);
    assertName(name);
    initHead(out, .scalar_quantity, ScalarQuantityHead{
        .count = count,
        .structure_len = @intCast(structure.len),
        .name_len = @intCast(name.len),
        .target = @backingInt(target),
        ._pad = @splat(0),
    });
    addPart(out, structure);
    addPart(out, name);
    addSections(out, &.{values}, &.{@as(usize, count) * @sizeOf(f32)});
}

/// Writes caller-owned `out`, borrowing vector strings and bytes through the
/// write and allocating nothing.
pub fn encodeVectorQuantity(
    out: *Encoded,
    structure: []const u8,
    name: []const u8,
    target: Target,
    vectors: layout.Positions.Const,
) void {
    encodeVectorQuantitySection(
        out,
        structure,
        name,
        target,
        vectors.len(),
        inlineSection(vectors.bytes()),
    );
}

/// Writes caller-owned `out` from inline or external vector positions. Every
/// input is borrowed through the write and no allocation occurs.
pub fn encodeVectorQuantitySection(
    out: *Encoded,
    structure: []const u8,
    name: []const u8,
    target: Target,
    count: u32,
    vectors: Section,
) void {
    assertName(structure);
    assertName(name);
    initHead(out, .vector_quantity, VectorQuantityHead{
        .count = count,
        .structure_len = @intCast(structure.len),
        .name_len = @intCast(name.len),
        .target = @backingInt(target),
        ._pad = @splat(0),
    });
    addPart(out, structure);
    addPart(out, name);
    addSections(out, &.{vectors}, &.{layout.Positions.byteSize(count)});
}

/// Writes caller-owned `out`, borrowing the log string through the write and
/// allocating nothing.
pub fn encodeLog(out: *Encoded, level: LogLevel, text: []const u8) void {
    std.debug.assert(text.len <= std.math.maxInt(u32));
    initHead(out, .log, LogHead{
        .text_len = @intCast(text.len),
        .level = @backingInt(level),
        ._pad = @splat(0),
    });
    addPart(out, text);
}

// ---------------------------------------------------------------------------
// decode

/// Parses the first eight caller-owned bytes without allocation.
pub fn decodeHeader(bytes: []const u8) DecodeError!Header {
    if (bytes.len < @sizeOf(Header)) return error.Truncated;
    return readValue(Header, bytes[0..@sizeOf(Header)]);
}

/// Decodes one exact payload without allocation. Inline views borrow `payload`;
/// external views borrow `mappings`. The caller keeps both alive while using
/// the returned message.
pub fn decode(
    header: Header,
    payload: []align(payload_alignment) const u8,
    mappings: []const []align(layout.blob_alignment.toByteUnits()) const u8,
) DecodeError!Message {
    const declared_len: usize = header.len;
    if (payload.len < declared_len) return error.Truncated;
    if (payload.len != declared_len) return error.BadLength;

    const flags = Flags.fromInt(header.flags);
    const external = flags.external;
    if (external and mappings.len < flags.fd_count) return error.MissingMapping;
    const frame_mappings = if (external) mappings[0..flags.fd_count] else mappings;

    return switch (try decodeKind(header.kind)) {
        .hello => .{ .hello = try decodeHello(payload) },
        .begin_run => blk: {
            try expectEmpty(payload);
            break :blk .{ .begin_run = {} };
        },
        .begin_frame => .{ .begin_frame = try decodeBeginFrame(payload) },
        .end_frame => blk: {
            try expectEmpty(payload);
            break :blk .{ .end_frame = {} };
        },
        .end_run => blk: {
            try expectEmpty(payload);
            break :blk .{ .end_run = {} };
        },
        .mesh => .{ .mesh = try decodeMesh(payload, frame_mappings, external) },
        .mesh_positions => .{ .mesh_positions = try decodeMeshPositions(payload, frame_mappings, external) },
        .points => .{ .points = try decodePoints(payload, frame_mappings, external) },
        .lines => .{ .lines = try decodeLines(payload, frame_mappings, external) },
        .scalar_quantity => .{ .scalar_quantity = try decodeScalarQuantity(payload, frame_mappings, external) },
        .vector_quantity => .{ .vector_quantity = try decodeVectorQuantity(payload, frame_mappings, external) },
        .log => .{ .log = try decodeLog(payload) },
        _ => unreachable,
    };
}

/// Decodes an inline frame without allocation. This is equivalent to `decode`
/// with no mappings; non-external frames ignore mappings by protocol.
pub fn decodeInline(header: Header, payload: []align(payload_alignment) const u8) DecodeError!Message {
    return decode(header, payload, &.{});
}

fn decodeHello(payload: []align(payload_alignment) const u8) DecodeError!Hello {
    const head = try readHead(HelloHead, payload);
    if (!std.mem.eql(u8, &magic, &head.magic)) return error.BadMagic;
    if (head.version != version) return error.VersionMismatch;
    try checkNameLen(head.name_len);
    const end = try exactEnd(@sizeOf(HelloHead), head.name_len, payload.len);
    return .{ .name = payload[@sizeOf(HelloHead)..end] };
}

fn decodeBeginFrame(payload: []align(payload_alignment) const u8) DecodeError!BeginFrame {
    const head = try readHead(BeginFrameHead, payload);
    const end = try exactEnd(@sizeOf(BeginFrameHead), head.label_len, payload.len);
    return .{ .index = head.index, .label = payload[@sizeOf(BeginFrameHead)..end] };
}

fn decodeMesh(
    payload: []align(payload_alignment) const u8,
    mappings: []const []align(layout.blob_alignment.toByteUnits()) const u8,
    external: bool,
) DecodeError!Mesh {
    const head = try readHead(MeshHead, payload);
    try checkNameLen(head.name_len);
    const dim = try decodeDim(head.dim);
    const name_end = try checkedEnd(@sizeOf(MeshHead), head.name_len, payload.len);
    const positions_len = try countBytes(head.vertex_count, layout.Positions.bytes_per_vertex);
    const faces_len = try countBytes(head.face_count, @sizeOf([3]u32));
    var sections: [max_sections][]align(payload_alignment) const u8 = undefined;
    try decodeSections(payload, mappings, external, name_end, &.{ positions_len, faces_len }, sections[0..2]);
    return .{
        .name = payload[@sizeOf(MeshHead)..name_end],
        .dim = dim,
        .positions = layout.Positions.Const.fromBytes(sections[0]),
        .faces = bytesAsSlice([3]u32, sections[1]),
    };
}

fn decodeMeshPositions(
    payload: []align(payload_alignment) const u8,
    mappings: []const []align(layout.blob_alignment.toByteUnits()) const u8,
    external: bool,
) DecodeError!MeshPositions {
    const head = try readHead(MeshPositionsHead, payload);
    try checkNameLen(head.name_len);
    const name_end = try checkedEnd(@sizeOf(MeshPositionsHead), head.name_len, payload.len);
    const positions_len = try countBytes(head.vertex_count, layout.Positions.bytes_per_vertex);
    var sections: [1][]align(payload_alignment) const u8 = undefined;
    try decodeSections(payload, mappings, external, name_end, &.{positions_len}, &sections);
    return .{
        .name = payload[@sizeOf(MeshPositionsHead)..name_end],
        .positions = layout.Positions.Const.fromBytes(sections[0]),
    };
}

fn decodePoints(
    payload: []align(payload_alignment) const u8,
    mappings: []const []align(layout.blob_alignment.toByteUnits()) const u8,
    external: bool,
) DecodeError!Points {
    const head = try readHead(PointsHead, payload);
    try checkNameLen(head.name_len);
    const dim = try decodeDim(head.dim);
    const name_end = try checkedEnd(@sizeOf(PointsHead), head.name_len, payload.len);
    const positions_len = try countBytes(head.count, layout.Positions.bytes_per_vertex);
    var sections: [1][]align(payload_alignment) const u8 = undefined;
    try decodeSections(payload, mappings, external, name_end, &.{positions_len}, &sections);
    return .{
        .name = payload[@sizeOf(PointsHead)..name_end],
        .dim = dim,
        .positions = layout.Positions.Const.fromBytes(sections[0]),
    };
}

fn decodeLines(
    payload: []align(payload_alignment) const u8,
    mappings: []const []align(layout.blob_alignment.toByteUnits()) const u8,
    external: bool,
) DecodeError!Lines {
    const head = try readHead(LinesHead, payload);
    try checkNameLen(head.name_len);
    const dim = try decodeDim(head.dim);
    const name_end = try checkedEnd(@sizeOf(LinesHead), head.name_len, payload.len);
    const positions_len = try countBytes(head.vertex_count, layout.Positions.bytes_per_vertex);
    const segments_len = try countBytes(head.segment_count, @sizeOf([2]u32));
    var sections: [max_sections][]align(payload_alignment) const u8 = undefined;
    try decodeSections(payload, mappings, external, name_end, &.{ positions_len, segments_len }, sections[0..2]);
    return .{
        .name = payload[@sizeOf(LinesHead)..name_end],
        .dim = dim,
        .positions = layout.Positions.Const.fromBytes(sections[0]),
        .segments = bytesAsSlice([2]u32, sections[1]),
    };
}

fn decodeScalarQuantity(
    payload: []align(payload_alignment) const u8,
    mappings: []const []align(layout.blob_alignment.toByteUnits()) const u8,
    external: bool,
) DecodeError!ScalarQuantity {
    const head = try readHead(ScalarQuantityHead, payload);
    try checkNameLen(head.structure_len);
    try checkNameLen(head.name_len);
    const target = try decodeTarget(head.target);
    const structure_end = try checkedEnd(@sizeOf(ScalarQuantityHead), head.structure_len, payload.len);
    const name_end = try checkedEnd(structure_end, head.name_len, payload.len);
    const values_len = try countBytes(head.count, @sizeOf(f32));
    var sections: [1][]align(payload_alignment) const u8 = undefined;
    try decodeSections(payload, mappings, external, name_end, &.{values_len}, &sections);
    return .{
        .structure = payload[@sizeOf(ScalarQuantityHead)..structure_end],
        .name = payload[structure_end..name_end],
        .target = target,
        .values = bytesAsSlice(f32, sections[0]),
    };
}

fn decodeVectorQuantity(
    payload: []align(payload_alignment) const u8,
    mappings: []const []align(layout.blob_alignment.toByteUnits()) const u8,
    external: bool,
) DecodeError!VectorQuantity {
    const head = try readHead(VectorQuantityHead, payload);
    try checkNameLen(head.structure_len);
    try checkNameLen(head.name_len);
    const target = try decodeTarget(head.target);
    const structure_end = try checkedEnd(@sizeOf(VectorQuantityHead), head.structure_len, payload.len);
    const name_end = try checkedEnd(structure_end, head.name_len, payload.len);
    const vectors_len = try countBytes(head.count, layout.Positions.bytes_per_vertex);
    var sections: [1][]align(payload_alignment) const u8 = undefined;
    try decodeSections(payload, mappings, external, name_end, &.{vectors_len}, &sections);
    return .{
        .structure = payload[@sizeOf(VectorQuantityHead)..structure_end],
        .name = payload[structure_end..name_end],
        .target = target,
        .vectors = layout.Positions.Const.fromBytes(sections[0]),
    };
}

fn decodeLog(payload: []align(payload_alignment) const u8) DecodeError!Log {
    const head = try readHead(LogHead, payload);
    const level = try decodeLogLevel(head.level);
    const end = try exactEnd(@sizeOf(LogHead), head.text_len, payload.len);
    return .{ .level = level, .text = payload[@sizeOf(LogHead)..end] };
}

fn decodeSections(
    payload: []align(payload_alignment) const u8,
    mappings: []const []align(layout.blob_alignment.toByteUnits()) const u8,
    external: bool,
    strings_end: usize,
    expected_lens: []const usize,
    out: [][]align(payload_alignment) const u8,
) DecodeError!void {
    std.debug.assert(expected_lens.len == out.len);
    std.debug.assert(expected_lens.len <= max_sections);

    var inline_cursor = strings_end;
    var references: [max_sections]SectionRef = undefined;
    if (external) {
        const descriptors_start = try alignedStart(strings_end, payload.len);
        const descriptors_len = std.math.mul(usize, expected_lens.len, @sizeOf(SectionRef)) catch
            return error.BadLength;
        inline_cursor = try checkedEnd(descriptors_start, descriptors_len, payload.len);
        for (references[0..expected_lens.len], 0..) |*reference, i| {
            const start = descriptors_start + i * @sizeOf(SectionRef);
            reference.* = readValue(SectionRef, payload[start .. start + @sizeOf(SectionRef)]);
        }
    }

    for (expected_lens, out, 0..) |expected_len, *section_out, i| {
        if (!external) {
            const start = try alignedStart(inline_cursor, payload.len);
            const end = try checkedEnd(start, expected_len, payload.len);
            section_out.* = @alignCast(payload[start..end]);
            inline_cursor = end;
            continue;
        }

        const reference = references[i];
        if (reference.len != expected_len) return error.BadLength;
        switch (reference.source) {
            0 => {
                const start = try alignedStart(inline_cursor, payload.len);
                const end = try checkedEnd(start, expected_len, payload.len);
                section_out.* = @alignCast(payload[start..end]);
                inline_cursor = end;
            },
            1 => {
                if (reference.offset % layout.blob_alignment.toByteUnits() != 0) return error.Misaligned;
                if (reference.fd_index >= mappings.len) return error.MissingMapping;
                const mapping = mappings[reference.fd_index];
                const mapping_len: u64 = mapping.len;
                const end_u64 = std.math.add(u64, reference.offset, reference.len) catch
                    return error.BadLength;
                if (end_u64 > mapping_len) return error.BadLength;
                const start: usize = @intCast(reference.offset);
                const end: usize = @intCast(end_u64);
                section_out.* = @alignCast(mapping[start..end]);
            },
            else => return error.BadLength,
        }
    }
    if (inline_cursor != payload.len) return error.BadLength;
}

// ---------------------------------------------------------------------------
// helpers

fn inlineSection(bytes: []const u8) Section {
    return .{ .@"inline" = bytes };
}

fn readHead(comptime T: type, payload: []const u8) DecodeError!T {
    if (payload.len < @sizeOf(T)) return error.BadLength;
    return readValue(T, payload[0..@sizeOf(T)]);
}

fn readValue(comptime T: type, bytes: []const u8) T {
    std.debug.assert(bytes.len == @sizeOf(T));
    return @as(*align(1) const T, @ptrCast(bytes.ptr)).*;
}

fn decodeKind(raw: u16) DecodeError!Kind {
    return switch (raw) {
        1 => .hello,
        2 => .begin_run,
        3 => .begin_frame,
        4 => .end_frame,
        5 => .end_run,
        6 => .mesh,
        7 => .mesh_positions,
        8 => .points,
        9 => .lines,
        10 => .scalar_quantity,
        11 => .vector_quantity,
        12 => .log,
        else => error.UnknownKind,
    };
}

fn decodeDim(raw: u8) DecodeError!Dim {
    return switch (raw) {
        2 => .d2,
        3 => .d3,
        else => error.BadEnum,
    };
}

fn decodeTarget(raw: u8) DecodeError!Target {
    return switch (raw) {
        0 => .vertex,
        1 => .face,
        2 => .point,
        else => error.BadEnum,
    };
}

fn decodeLogLevel(raw: u8) DecodeError!LogLevel {
    return switch (raw) {
        0 => .info,
        1 => .warn,
        2 => .err,
        else => error.BadEnum,
    };
}

fn expectEmpty(payload: []const u8) DecodeError!void {
    if (payload.len != 0) return error.BadLength;
}

fn checkNameLen(len: u16) DecodeError!void {
    if (len > max_name_len) return error.NameTooLong;
}

fn exactEnd(start: usize, len: anytype, payload_len: usize) DecodeError!usize {
    const end = try checkedEnd(start, @as(usize, len), payload_len);
    if (end != payload_len) return error.BadLength;
    return end;
}

fn checkedEnd(start: usize, len: usize, payload_len: usize) DecodeError!usize {
    const end = std.math.add(usize, start, len) catch return error.BadLength;
    if (end > payload_len) return error.BadLength;
    return end;
}

fn alignedStart(offset: usize, payload_len: usize) DecodeError!usize {
    const with_slack = std.math.add(usize, offset, section_alignment - 1) catch return error.BadLength;
    const aligned = with_slack & ~@as(usize, section_alignment - 1);
    if (aligned > payload_len) return error.BadLength;
    return aligned;
}

fn countBytes(count: u32, elem_size: usize) DecodeError!usize {
    return std.math.mul(usize, @as(usize, count), elem_size) catch error.BadLength;
}

fn bytesAsSlice(comptime T: type, bytes: []const u8) []const T {
    return std.mem.bytesAsSlice(T, @as([]align(@alignOf(T)) const u8, @alignCast(bytes)));
}

fn initEmpty(out: *Encoded, kind: Kind) void {
    out.* = .{
        .header = .{ .len = 0, .kind = @backingInt(kind) },
        .head = undefined,
        .descriptors = undefined,
        .parts = undefined,
        .part_count = 1,
        .descriptor_count = 0,
        .descriptor_part = 0,
    };
}

fn initHead(out: *Encoded, kind: Kind, head: anytype) void {
    const head_bytes = std.mem.asBytes(&head);
    std.debug.assert(head_bytes.len <= max_head_size);
    out.* = .{
        .header = .{ .len = @intCast(head_bytes.len), .kind = @backingInt(kind) },
        .head = undefined,
        .descriptors = undefined,
        .parts = undefined,
        .part_count = 2,
        .descriptor_count = 0,
        .descriptor_part = 0,
    };
    @memcpy(out.head[0..head_bytes.len], head_bytes);
}

fn encodedHeadLen(raw_kind: u16) u8 {
    return switch (raw_kind) {
        @backingInt(Kind.hello) => @sizeOf(HelloHead),
        @backingInt(Kind.begin_frame) => @sizeOf(BeginFrameHead),
        @backingInt(Kind.mesh) => @sizeOf(MeshHead),
        @backingInt(Kind.mesh_positions) => @sizeOf(MeshPositionsHead),
        @backingInt(Kind.points) => @sizeOf(PointsHead),
        @backingInt(Kind.lines) => @sizeOf(LinesHead),
        @backingInt(Kind.scalar_quantity) => @sizeOf(ScalarQuantityHead),
        @backingInt(Kind.vector_quantity) => @sizeOf(VectorQuantityHead),
        @backingInt(Kind.log) => @sizeOf(LogHead),
        else => 0,
    };
}

fn assertName(name: []const u8) void {
    std.debug.assert(name.len <= max_name_len);
}

fn addPart(out: *Encoded, bytes: []const u8) void {
    std.debug.assert(out.part_count < max_parts);
    const next_len = @as(usize, out.header.len) + bytes.len;
    std.debug.assert(next_len <= std.math.maxInt(u32));
    out.parts[out.part_count] = bytes;
    out.part_count += 1;
    out.header.len = @intCast(next_len);
}

fn alignPayload(out: *Encoded) void {
    const remainder = out.header.len % section_alignment;
    const padding_len: u32 = if (remainder == 0) 0 else section_alignment - remainder;
    if (padding_len != 0) addPart(out, zero_padding[0..padding_len]);
}

fn addSections(out: *Encoded, sections: []const Section, expected_lens: []const usize) void {
    std.debug.assert(sections.len == expected_lens.len);
    std.debug.assert(sections.len <= max_sections);

    var has_external = false;
    var fd_count: u32 = 0;
    for (sections, expected_lens) |section, expected_len| switch (section) {
        .@"inline" => |bytes| std.debug.assert(bytes.len == expected_len),
        .external => |reference| {
            std.debug.assert(reference.len == expected_len);
            std.debug.assert(reference.fd_index < 7);
            has_external = true;
            fd_count = @max(fd_count, reference.fd_index + 1);
        },
    };

    if (!has_external) {
        for (sections) |section| {
            alignPayload(out);
            addPart(out, section.@"inline");
        }
        return;
    }

    out.header.flags = (Flags{
        .external = true,
        .fd_count = @intCast(fd_count),
    }).toInt();
    for (sections, 0..) |section, i| {
        out.descriptors[i] = switch (section) {
            .@"inline" => |bytes| .{
                .source = 0,
                .fd_index = 0,
                .offset = 0,
                .len = bytes.len,
            },
            .external => |reference| .{
                .source = 1,
                .fd_index = reference.fd_index,
                .offset = reference.offset,
                .len = reference.len,
            },
        };
    }

    alignPayload(out);
    std.debug.assert(out.part_count < max_parts);
    out.descriptor_count = @intCast(sections.len);
    out.descriptor_part = out.part_count;
    out.parts[out.part_count] = &.{};
    out.part_count += 1;
    const descriptor_len = sections.len * @sizeOf(SectionRef);
    const next_len = @as(usize, out.header.len) + descriptor_len;
    std.debug.assert(next_len <= std.math.maxInt(u32));
    out.header.len = @intCast(next_len);

    for (sections) |section| switch (section) {
        .@"inline" => |bytes| {
            alignPayload(out);
            addPart(out, bytes);
        },
        .external => {},
    };
}

// ---------------------------------------------------------------------------
// tests

const testing = std.testing;
const test_capacity = 4096;

test "wire heads have documented sizes and safe alignment" {
    try testing.expectEqual(8, @sizeOf(Header));
    try testing.expectEqual(2, @sizeOf(Flags));
    try testing.expectEqual(24, @sizeOf(SectionRef));
    try testing.expectEqual(8, @alignOf(SectionRef));
    try testing.expectEqual(8, @sizeOf(HelloHead));
    try testing.expectEqual(8, @sizeOf(BeginFrameHead));
    try testing.expectEqual(12, @sizeOf(MeshHead));
    try testing.expectEqual(8, @sizeOf(MeshPositionsHead));
    try testing.expectEqual(8, @sizeOf(PointsHead));
    try testing.expectEqual(12, @sizeOf(LinesHead));
    try testing.expectEqual(12, @sizeOf(ScalarQuantityHead));
    try testing.expectEqual(12, @sizeOf(VectorQuantityHead));
    try testing.expectEqual(8, @sizeOf(LogHead));

    inline for (.{
        Header,
        HelloHead,
        BeginFrameHead,
        MeshHead,
        MeshPositionsHead,
        PointsHead,
        LinesHead,
        ScalarQuantityHead,
        VectorQuantityHead,
        LogHead,
    }) |T| try testing.expect(@alignOf(T) <= 8);
}

test "external descriptors are aligned and mixed sections round-trip from mappings" {
    var mapping: [1024]u8 align(64) = @splat(0);
    const position_offset = 64;
    const position_len = layout.Positions.byteSize(4);
    const positions = layout.Positions.fromBytes(mapping[position_offset .. position_offset + position_len]);
    positions.setAll(&.{
        .init(1, 2, 3),
        .init(4, 5, 6),
        .init(7, 8, 9),
        .init(10, 11, 12),
    });
    const faces = [_][3]u32{.{ 0, 1, 2 }};
    const segments = [_][2]u32{.{ 2, 3 }};
    const values_offset = 256;
    const values_bytes = mapping[values_offset .. values_offset + 4 * @sizeOf(f32)];
    const mapped_values = std.mem.bytesAsSlice(f32, @as([]align(@alignOf(f32)) u8, @alignCast(values_bytes)));
    const values = [_]f32{ 0.25, 0.5, 0.75, 1.0 };
    @memcpy(mapped_values, &values);
    const mappings = [_][]align(64) const u8{&mapping};

    var encoded: Encoded = undefined;
    var frame_storage: [test_capacity]u8 align(section_alignment) = undefined;
    var payload_storage: [test_capacity]u8 align(section_alignment) = undefined;

    encodeMeshSections(
        &encoded,
        "surface",
        .d3,
        4,
        .{ .external = .{ .fd_index = 0, .offset = position_offset, .len = position_len } },
        1,
        .{ .@"inline" = std.mem.sliceAsBytes(&faces) },
    );
    const mesh_frame = encoded.writeTo(&frame_storage);
    const mesh_header = try decodeHeader(mesh_frame);
    const flags = Flags.fromInt(mesh_header.flags);
    try testing.expect(flags.external);
    try testing.expectEqual(@as(u3, 1), flags.fd_count);
    const descriptor_start = try alignedStart(@sizeOf(MeshHead) + "surface".len, mesh_header.len);
    try testing.expectEqual(@as(usize, 0), descriptor_start % section_alignment);
    const first_ref = readValue(
        SectionRef,
        mesh_frame[@sizeOf(Header) + descriptor_start ..][0..@sizeOf(SectionRef)],
    );
    try testing.expectEqual(@as(u32, 1), first_ref.source);
    try testing.expectEqual(@as(u64, position_offset), first_ref.offset);
    copyPayload(mesh_frame, &payload_storage);
    switch (try decode(mesh_header, payload_storage[0..mesh_header.len], &mappings)) {
        .mesh => |message| {
            try expectPositions(positions.toConst(), message.positions);
            try testing.expectEqualSlices([3]u32, &faces, message.faces);
            try testing.expectEqual(
                @intFromPtr(mapping[position_offset..].ptr),
                @intFromPtr(message.positions.bytes().ptr),
            );
            try expectBorrowedAligned(&payload_storage, std.mem.sliceAsBytes(message.faces));
        },
        else => return error.TestUnexpectedResult,
    }

    encodeMeshPositionsSection(
        &encoded,
        "surface",
        4,
        .{ .external = .{ .fd_index = 0, .offset = position_offset, .len = position_len } },
    );
    try expectExternalPositionsRoundTrip(&encoded, &frame_storage, &payload_storage, &mappings, positions.toConst(), .mesh_positions);

    encodePointsSection(
        &encoded,
        "samples",
        .d3,
        4,
        .{ .external = .{ .fd_index = 0, .offset = position_offset, .len = position_len } },
    );
    try expectExternalPositionsRoundTrip(&encoded, &frame_storage, &payload_storage, &mappings, positions.toConst(), .points);

    encodeLinesSections(
        &encoded,
        "edges",
        .d3,
        4,
        .{ .external = .{ .fd_index = 0, .offset = position_offset, .len = position_len } },
        1,
        .{ .@"inline" = std.mem.sliceAsBytes(&segments) },
    );
    const lines_frame = encoded.writeTo(&frame_storage);
    const lines_header = try decodeHeader(lines_frame);
    copyPayload(lines_frame, &payload_storage);
    switch (try decode(lines_header, payload_storage[0..lines_header.len], &mappings)) {
        .lines => |message| {
            try expectPositions(positions.toConst(), message.positions);
            try testing.expectEqualSlices([2]u32, &segments, message.segments);
        },
        else => return error.TestUnexpectedResult,
    }

    encodeScalarQuantitySection(
        &encoded,
        "surface",
        "height",
        .vertex,
        4,
        .{ .external = .{ .fd_index = 0, .offset = values_offset, .len = values_bytes.len } },
    );
    const scalar_frame = encoded.writeTo(&frame_storage);
    const scalar_header = try decodeHeader(scalar_frame);
    copyPayload(scalar_frame, &payload_storage);
    switch (try decode(scalar_header, payload_storage[0..scalar_header.len], &mappings)) {
        .scalar_quantity => |message| {
            try testing.expectEqualSlices(f32, mapped_values, message.values);
            try testing.expectEqual(@intFromPtr(values_bytes.ptr), @intFromPtr(message.values.ptr));
        },
        else => return error.TestUnexpectedResult,
    }

    encodeVectorQuantitySection(
        &encoded,
        "surface",
        "velocity",
        .vertex,
        4,
        .{ .external = .{ .fd_index = 0, .offset = position_offset, .len = position_len } },
    );
    try expectExternalPositionsRoundTrip(&encoded, &frame_storage, &payload_storage, &mappings, positions.toConst(), .vector_quantity);
}

test "external section validation rejects misalignment missing mappings and truncation" {
    var mapping: [512]u8 align(64) = @splat(0);
    const mappings = [_][]align(64) const u8{&mapping};
    const positions_len = layout.Positions.byteSize(3);
    var encoded: Encoded = undefined;
    var frame_storage: [test_capacity]u8 align(section_alignment) = undefined;
    var payload_storage: [test_capacity]u8 align(section_alignment) = undefined;

    encodeMeshPositionsSection(
        &encoded,
        "surface",
        3,
        .{ .external = .{ .fd_index = 0, .offset = 4, .len = positions_len } },
    );
    var frame = encoded.writeTo(&frame_storage);
    var header = try decodeHeader(frame);
    copyPayload(frame, &payload_storage);
    try testing.expectError(error.Misaligned, decode(header, payload_storage[0..header.len], &mappings));

    encodeMeshPositionsSection(
        &encoded,
        "surface",
        3,
        .{ .external = .{ .fd_index = 1, .offset = 64, .len = positions_len } },
    );
    frame = encoded.writeTo(&frame_storage);
    header = try decodeHeader(frame);
    copyPayload(frame, &payload_storage);
    try testing.expectError(error.MissingMapping, decode(header, payload_storage[0..header.len], &mappings));

    encodeMeshPositionsSection(
        &encoded,
        "surface",
        3,
        .{ .external = .{ .fd_index = 0, .offset = 64, .len = positions_len } },
    );
    frame = encoded.writeTo(&frame_storage);
    header = try decodeHeader(frame);
    for (0..header.len) |prefix_len| {
        @memcpy(payload_storage[0..prefix_len], frame[@sizeOf(Header)..][0..prefix_len]);
        try testing.expectError(error.Truncated, decode(header, payload_storage[0..prefix_len], &mappings));
    }
    copyPayload(frame, &payload_storage);
    _ = try decode(header, payload_storage[0..header.len], &mappings);
}

test "every message kind round-trips without copying decoded sections" {
    var positions_storage: [layout.Positions.byteSize(4)]u8 align(64) = undefined;
    const positions = layout.Positions.fromBytes(&positions_storage);
    positions.setAll(&.{
        .init(1, 2, 3),
        .init(4, 5, 6),
        .init(7, 8, 9),
        .init(10, 11, 12),
    });
    const position_view = positions.toConst();
    const faces = [_][3]u32{ .{ 0, 1, 2 }, .{ 2, 3, 0 } };
    const segments = [_][2]u32{ .{ 0, 1 }, .{ 2, 3 } };
    const values = [_]f32{ 0.25, 0.5, 0.75, 1.0 };

    var encoded: Encoded = undefined;
    var frame: [test_capacity]u8 align(section_alignment) = undefined;
    var payload: [test_capacity]u8 align(section_alignment) = undefined;

    encodeHello(&encoded, "source");
    switch (try roundTrip(&encoded, &frame, &payload)) {
        .hello => |message| try testing.expectEqualStrings("source", message.name),
        else => return error.TestUnexpectedResult,
    }

    encodeBeginRun(&encoded);
    switch (try roundTrip(&encoded, &frame, &payload)) {
        .begin_run => {},
        else => return error.TestUnexpectedResult,
    }

    encodeBeginFrame(&encoded, 42, "iteration");
    switch (try roundTrip(&encoded, &frame, &payload)) {
        .begin_frame => |message| {
            try testing.expectEqual(42, message.index);
            try testing.expectEqualStrings("iteration", message.label);
        },
        else => return error.TestUnexpectedResult,
    }

    encodeEndFrame(&encoded);
    switch (try roundTrip(&encoded, &frame, &payload)) {
        .end_frame => {},
        else => return error.TestUnexpectedResult,
    }

    encodeEndRun(&encoded);
    switch (try roundTrip(&encoded, &frame, &payload)) {
        .end_run => {},
        else => return error.TestUnexpectedResult,
    }

    encodeMesh(&encoded, "surface", .d3, position_view, &faces);
    switch (try roundTrip(&encoded, &frame, &payload)) {
        .mesh => |message| {
            try testing.expectEqualStrings("surface", message.name);
            try testing.expectEqual(Dim.d3, message.dim);
            try expectPositions(position_view, message.positions);
            try testing.expectEqualSlices([3]u32, &faces, message.faces);
            try expectBorrowedAligned(&payload, message.positions.bytes());
            try expectBorrowedAligned(&payload, std.mem.sliceAsBytes(message.faces));
        },
        else => return error.TestUnexpectedResult,
    }

    encodeMeshPositions(&encoded, "surface", position_view);
    switch (try roundTrip(&encoded, &frame, &payload)) {
        .mesh_positions => |message| {
            try testing.expectEqualStrings("surface", message.name);
            try expectPositions(position_view, message.positions);
            try expectBorrowedAligned(&payload, message.positions.bytes());
        },
        else => return error.TestUnexpectedResult,
    }

    encodePoints(&encoded, "samples", .d2, position_view);
    switch (try roundTrip(&encoded, &frame, &payload)) {
        .points => |message| {
            try testing.expectEqualStrings("samples", message.name);
            try testing.expectEqual(Dim.d2, message.dim);
            try expectPositions(position_view, message.positions);
            try expectBorrowedAligned(&payload, message.positions.bytes());
        },
        else => return error.TestUnexpectedResult,
    }

    encodeLines(&encoded, "edges", .d3, position_view, &segments);
    switch (try roundTrip(&encoded, &frame, &payload)) {
        .lines => |message| {
            try testing.expectEqualStrings("edges", message.name);
            try testing.expectEqual(Dim.d3, message.dim);
            try expectPositions(position_view, message.positions);
            try testing.expectEqualSlices([2]u32, &segments, message.segments);
            try expectBorrowedAligned(&payload, message.positions.bytes());
            try expectBorrowedAligned(&payload, std.mem.sliceAsBytes(message.segments));
        },
        else => return error.TestUnexpectedResult,
    }

    encodeScalarQuantity(&encoded, "surface", "curvature", .vertex, &values);
    switch (try roundTrip(&encoded, &frame, &payload)) {
        .scalar_quantity => |message| {
            try testing.expectEqualStrings("surface", message.structure);
            try testing.expectEqualStrings("curvature", message.name);
            try testing.expectEqual(Target.vertex, message.target);
            try testing.expectEqualSlices(f32, &values, message.values);
            try expectBorrowedAligned(&payload, std.mem.sliceAsBytes(message.values));
        },
        else => return error.TestUnexpectedResult,
    }

    encodeVectorQuantity(&encoded, "surface", "velocity", .face, position_view);
    switch (try roundTrip(&encoded, &frame, &payload)) {
        .vector_quantity => |message| {
            try testing.expectEqualStrings("surface", message.structure);
            try testing.expectEqualStrings("velocity", message.name);
            try testing.expectEqual(Target.face, message.target);
            try expectPositions(position_view, message.vectors);
            try expectBorrowedAligned(&payload, message.vectors.bytes());
        },
        else => return error.TestUnexpectedResult,
    }

    encodeLog(&encoded, .warn, "careful");
    switch (try roundTrip(&encoded, &frame, &payload)) {
        .log => |message| {
            try testing.expectEqual(LogLevel.warn, message.level);
            try testing.expectEqualStrings("careful", message.text);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "encoded slices exactly cover total length" {
    var positions_storage: [layout.Positions.byteSize(3)]u8 align(64) = @splat(0);
    const positions = layout.Positions.fromBytes(&positions_storage).toConst();
    const faces = [_][3]u32{.{ 0, 1, 2 }};
    var encoded: Encoded = undefined;
    encodeMesh(&encoded, "m", .d3, positions, &faces);
    try testing.expect(!Flags.fromInt(encoded.header.flags).external);
    try testing.expectEqual(@as(u8, 0), encoded.descriptor_count);

    var sum: usize = 0;
    const parts = encoded.slices();
    try testing.expect(parts.len <= max_parts);
    for (parts) |part| sum += part.len;
    try testing.expectEqual(encoded.totalLen(), sum);
    try testing.expectEqual(@as(usize, @sizeOf(Header)) + encoded.header.len, encoded.totalLen());
}

test "semantic header and enum errors are rejected" {
    var frame: [test_capacity]u8 align(section_alignment) = undefined;
    var payload: [test_capacity]u8 align(section_alignment) = undefined;
    var encoded: Encoded = undefined;

    encodeHello(&encoded, "source");
    const hello_frame = encoded.writeTo(&frame);
    copyPayload(hello_frame, &payload);
    var header = try decodeHeader(hello_frame);
    payload[0] = 'X';
    try testing.expectError(error.BadMagic, decodeInline(header, payload[0..header.len]));

    copyPayload(hello_frame, &payload);
    var hello_head = readValue(HelloHead, payload[0..@sizeOf(HelloHead)]);
    hello_head.version +%= 1;
    @memcpy(payload[0..@sizeOf(HelloHead)], std.mem.asBytes(&hello_head));
    try testing.expectError(error.VersionMismatch, decodeInline(header, payload[0..header.len]));

    header = .{ .len = 0, .kind = 999 };
    try testing.expectError(error.UnknownKind, decodeInline(header, payload[0..0]));

    var positions_storage: [layout.Positions.byteSize(1)]u8 align(64) = @splat(0);
    const positions = layout.Positions.fromBytes(&positions_storage).toConst();
    encodePoints(&encoded, "p", .d3, positions);
    const points_frame = encoded.writeTo(&frame);
    copyPayload(points_frame, &payload);
    header = try decodeHeader(points_frame);
    payload[@offsetOf(PointsHead, "dim")] = 7;
    try testing.expectError(error.BadEnum, decodeInline(header, payload[0..header.len]));
}

test "every mesh prefix and trailing payload are rejected safely" {
    var positions_storage: [layout.Positions.byteSize(4)]u8 align(64) = @splat(0);
    const positions = layout.Positions.fromBytes(&positions_storage).toConst();
    const faces = [_][3]u32{ .{ 0, 1, 2 }, .{ 1, 2, 3 } };
    var encoded: Encoded = undefined;
    encodeMesh(&encoded, "mesh", .d3, positions, &faces);

    var frame_storage: [test_capacity]u8 align(section_alignment) = undefined;
    const frame = encoded.writeTo(&frame_storage);
    var payload_storage: [test_capacity]u8 align(section_alignment) = undefined;

    for (0..frame.len) |prefix_len| {
        if (prefix_len < @sizeOf(Header)) {
            try testing.expectError(error.Truncated, decodeHeader(frame[0..prefix_len]));
            continue;
        }
        const header = try decodeHeader(frame[0..prefix_len]);
        const available = prefix_len - @sizeOf(Header);
        @memcpy(payload_storage[0..available], frame[@sizeOf(Header)..prefix_len]);
        const result = decodeInline(header, payload_storage[0..available]);
        if (result) |_| return error.TestUnexpectedResult else |err| switch (err) {
            error.Truncated, error.BadLength => {},
            else => return err,
        }
    }

    const header = try decodeHeader(frame);
    copyPayload(frame, &payload_storage);
    payload_storage[header.len] = 0;
    try testing.expectError(error.BadLength, decodeInline(header, payload_storage[0 .. header.len + 1]));
}

test "seeded mesh mutations never panic or read out of bounds" {
    var positions_storage: [layout.Positions.byteSize(4)]u8 align(64) = @splat(0);
    const positions = layout.Positions.fromBytes(&positions_storage).toConst();
    const faces = [_][3]u32{ .{ 0, 1, 2 }, .{ 1, 2, 3 } };
    var encoded: Encoded = undefined;
    encodeMesh(&encoded, "mesh", .d3, positions, &faces);

    var valid_storage: [test_capacity]u8 align(section_alignment) = undefined;
    const valid = encoded.writeTo(&valid_storage);
    var candidate: [test_capacity]u8 align(section_alignment) = undefined;
    var payload: [test_capacity]u8 align(section_alignment) = undefined;
    var prng = std.Random.DefaultPrng.init(0x72_a3_f1_09);
    const random = prng.random();

    for (0..20_000) |_| {
        @memcpy(candidate[0..valid.len], valid);
        const flip_count = random.intRangeAtMost(u8, 1, 4);
        for (0..flip_count) |_| {
            const index = random.uintLessThan(usize, valid.len);
            candidate[index] ^= random.int(u8) | 1;
        }

        const header = decodeHeader(candidate[0..valid.len]) catch continue;
        const payload_len = valid.len - @sizeOf(Header);
        @memcpy(payload[0..payload_len], candidate[@sizeOf(Header)..valid.len]);
        _ = decodeInline(header, payload[0..payload_len]) catch continue;
    }
}

fn roundTrip(
    encoded: *Encoded,
    frame_storage: []align(section_alignment) u8,
    payload_storage: []align(section_alignment) u8,
) DecodeError!Message {
    const frame = encoded.writeTo(frame_storage);
    const header = try decodeHeader(frame);
    copyPayload(frame, payload_storage);
    return decodeInline(header, payload_storage[0..header.len]);
}

fn copyPayload(frame: []const u8, payload: []align(section_alignment) u8) void {
    std.debug.assert(frame.len >= @sizeOf(Header));
    const payload_len = frame.len - @sizeOf(Header);
    std.debug.assert(payload.len >= payload_len);
    @memcpy(payload[0..payload_len], frame[@sizeOf(Header)..]);
}

fn expectExternalPositionsRoundTrip(
    encoded: *Encoded,
    frame_storage: []align(section_alignment) u8,
    payload_storage: []align(section_alignment) u8,
    mappings: []const []align(64) const u8,
    expected: layout.Positions.Const,
    expected_kind: Kind,
) !void {
    const frame = encoded.writeTo(frame_storage);
    const header = try decodeHeader(frame);
    copyPayload(frame, payload_storage);
    const message = try decode(header, payload_storage[0..header.len], mappings);
    const actual = switch (message) {
        .mesh_positions => |value| value.positions,
        .points => |value| value.positions,
        .vector_quantity => |value| value.vectors,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(expected_kind, std.meta.activeTag(message));
    try expectPositions(expected, actual);
    try testing.expectEqual(@intFromPtr(expected.bytes().ptr), @intFromPtr(actual.bytes().ptr));
}

fn expectPositions(expected: layout.Positions.Const, actual: layout.Positions.Const) !void {
    try testing.expectEqual(expected.len(), actual.len());
    try testing.expectEqualSlices(u8, expected.bytes(), actual.bytes());
}

fn expectBorrowedAligned(payload: []const u8, section: []const u8) !void {
    const payload_start = @intFromPtr(payload.ptr);
    const section_start = @intFromPtr(section.ptr);
    try testing.expect(section_start >= payload_start);
    try testing.expect(section_start + section.len <= payload_start + payload.len);
    try testing.expectEqual(@as(usize, 0), (section_start - payload_start) % section_alignment);
}
