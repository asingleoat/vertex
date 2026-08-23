//! Allocation-free, zero-copy vertex wire protocol.
//!
//! Frames use native endianness because both peers are the same build. `len`
//! counts payload bytes after the eight-byte frame header. String fields are
//! contiguous after their fixed head. Each following binary section begins at
//! a payload-relative multiple of 16; its preceding gap contains zero bytes.
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

/// Protocol compatibility version. This module borrows all input and allocates nothing.
pub const version: u16 = 1;

/// Handshake magic. This module borrows all input and allocates nothing.
pub const magic: [4]u8 = "VTXP".*;

/// Maximum byte length accepted for source, structure, and quantity names.
pub const max_name_len = 255;

/// Payload-relative alignment of binary sections; encoding allocates nothing.
/// Sections start at multiples of 16 from the payload start so that a payload
/// placed in 16-aligned memory yields SIMD-aligned views; `decode` itself only
/// needs `payload_alignment`.
pub const section_alignment = 16;

/// Minimum alignment `decode` requires of a payload buffer: enough for every
/// element type that appears in a section (f32, u32, Positions.Elem).
pub const payload_alignment = @max(@alignOf(u32), @alignOf(f32), @alignOf(layout.Positions.Elem));

/// Wire message tag. Values outside the named v1 set are rejected without allocation.
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

/// Geometric dimensionality carried by geometry messages; no memory is owned.
pub const Dim = enum(u8) { d2 = 2, d3 = 3 };

/// Quantity attachment target; no memory is owned.
pub const Target = enum(u8) { vertex = 0, face = 1, point = 2 };

/// Log severity; no memory is owned.
pub const LogLevel = enum(u8) { info, warn, err };

/// Eight-byte frame header. It is copied into or out of caller-owned bytes.
pub const Header = extern struct {
    len: u32,
    kind: u16,
    flags: u16 = 0,
};

/// Eight-byte fixed head for `hello`; no memory is owned.
pub const HelloHead = extern struct {
    magic: [4]u8,
    version: u16,
    name_len: u16,
};

/// Eight-byte fixed head for `begin_frame`; no memory is owned.
pub const BeginFrameHead = extern struct {
    index: u32,
    label_len: u16,
    _pad: u16,
};

/// Twelve-byte fixed head for `mesh`; no memory is owned.
pub const MeshHead = extern struct {
    vertex_count: u32,
    face_count: u32,
    name_len: u16,
    dim: u8,
    _pad: u8,
};

/// Eight-byte fixed head for `mesh_positions`; no memory is owned.
pub const MeshPositionsHead = extern struct {
    vertex_count: u32,
    name_len: u16,
    _pad: u16,
};

/// Eight-byte fixed head for `points`; no memory is owned.
pub const PointsHead = extern struct {
    count: u32,
    name_len: u16,
    dim: u8,
    _pad: u8,
};

/// Twelve-byte fixed head for `lines`; no memory is owned.
pub const LinesHead = extern struct {
    vertex_count: u32,
    segment_count: u32,
    name_len: u16,
    dim: u8,
    _pad: u8,
};

/// Twelve-byte fixed head for `scalar_quantity`; no memory is owned.
pub const ScalarQuantityHead = extern struct {
    count: u32,
    structure_len: u16,
    name_len: u16,
    target: u8,
    _pad: [3]u8,
};

/// Twelve-byte fixed head for `vector_quantity`; no memory is owned.
pub const VectorQuantityHead = extern struct {
    count: u32,
    structure_len: u16,
    name_len: u16,
    target: u8,
    _pad: [3]u8,
};

/// Eight-byte fixed head for `log`; no memory is owned.
pub const LogHead = extern struct {
    text_len: u32,
    level: u8,
    _pad: [3]u8,
};

/// Errors returned by total, allocation-free frame decoding.
pub const DecodeError = error{
    Truncated,
    BadLength,
    BadMagic,
    VersionMismatch,
    UnknownKind,
    BadEnum,
    NameTooLong,
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

/// Decoded topology-preserving mesh update; all views borrow the payload buffer.
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

/// Decoded message whose slices borrow the supplied payload buffer; no allocation occurs.
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

/// Parses the first eight caller-owned bytes without allocation.
pub fn decodeHeader(bytes: []const u8) DecodeError!Header {
    if (bytes.len < @sizeOf(Header)) return error.Truncated;
    return readValue(Header, bytes[0..@sizeOf(Header)]);
}

/// Decodes one exact payload without allocation. Returned views borrow `payload`.
/// A buffer shorter than `header.len` is `Truncated`; all other shape mismatches
/// are `BadLength`.
pub fn decode(header: Header, payload: []align(payload_alignment) const u8) DecodeError!Message {
    const declared_len: usize = header.len;
    if (payload.len < declared_len) return error.Truncated;
    if (payload.len != declared_len) return error.BadLength;

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
        .mesh => .{ .mesh = try decodeMesh(payload) },
        .mesh_positions => .{ .mesh_positions = try decodeMeshPositions(payload) },
        .points => .{ .points = try decodePoints(payload) },
        .lines => .{ .lines = try decodeLines(payload) },
        .scalar_quantity => .{ .scalar_quantity = try decodeScalarQuantity(payload) },
        .vector_quantity => .{ .vector_quantity = try decodeVectorQuantity(payload) },
        .log => .{ .log = try decodeLog(payload) },
        _ => unreachable,
    };
}

/// Maximum number of header, head, padding, and caller-owned slices in an encoding.
pub const max_parts = 8;

/// Largest fixed payload head in bytes; encoding stores it inline without allocation.
pub const max_head_size = 12;

const zero_padding: [section_alignment - 1]u8 align(section_alignment) = @splat(0);

/// Borrowing scatter/gather encoding. Header and head storage are owned inline;
/// variable slices remain caller-owned and must outlive the write. `slices()`
/// installs self-referential header/head views, so the `Encoded` must not be
/// moved or copied after `slices()` (or `writeTo()`) is called. No method allocates.
pub const Encoded = struct {
    header: Header,
    head: [max_head_size]u8 align(8),
    parts: [max_parts][]const u8,
    part_count: u8,

    /// Returns borrowed writev slices in wire order without allocation. The
    /// returned list and its inline header/head slices are invalidated by moving
    /// or copying this `Encoded`.
    pub fn slices(self: *Encoded) []const []const u8 {
        self.parts[0] = std.mem.asBytes(&self.header);
        const head_len = encodedHeadLen(self.header.kind);
        if (head_len != 0) self.parts[1] = self.head[0..head_len];
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

/// Encodes a hello borrowing `name`; asserts the name limit and allocates nothing.
pub fn encodeHello(out: *Encoded, name: []const u8) void {
    assertName(name);
    initHead(out, .hello, HelloHead{
        .magic = magic,
        .version = version,
        .name_len = @intCast(name.len),
    });
    addPart(out, name);
}

/// Encodes an empty begin-run frame without allocation.
pub fn encodeBeginRun(out: *Encoded) void {
    initEmpty(out, .begin_run);
}

/// Encodes a frame marker borrowing `label`; it allocates nothing.
pub fn encodeBeginFrame(out: *Encoded, index: u32, label: []const u8) void {
    std.debug.assert(label.len <= std.math.maxInt(u16));
    initHead(out, .begin_frame, BeginFrameHead{
        .index = index,
        .label_len = @intCast(label.len),
        ._pad = 0,
    });
    addPart(out, label);
}

/// Encodes an empty end-frame marker without allocation.
pub fn encodeEndFrame(out: *Encoded) void {
    initEmpty(out, .end_frame);
}

/// Encodes an empty end-run marker without allocation.
pub fn encodeEndRun(out: *Encoded) void {
    initEmpty(out, .end_run);
}

/// Encodes a mesh by borrowing every variable section; it allocates nothing.
pub fn encodeMesh(
    out: *Encoded,
    name: []const u8,
    dim: Dim,
    positions: layout.Positions.Const,
    faces: []const [3]u32,
) void {
    assertName(name);
    std.debug.assert(faces.len <= std.math.maxInt(u32));
    initHead(out, .mesh, MeshHead{
        .vertex_count = positions.len(),
        .face_count = @intCast(faces.len),
        .name_len = @intCast(name.len),
        .dim = @backingInt(dim),
        ._pad = 0,
    });
    addPart(out, name);
    alignPayload(out);
    addPart(out, positions.bytes());
    alignPayload(out);
    addPart(out, std.mem.sliceAsBytes(faces));
}

/// Encodes borrowed replacement positions without allocation.
pub fn encodeMeshPositions(out: *Encoded, name: []const u8, positions: layout.Positions.Const) void {
    assertName(name);
    initHead(out, .mesh_positions, MeshPositionsHead{
        .vertex_count = positions.len(),
        .name_len = @intCast(name.len),
        ._pad = 0,
    });
    addPart(out, name);
    alignPayload(out);
    addPart(out, positions.bytes());
}

/// Encodes a point set by borrowing all variable sections; it allocates nothing.
pub fn encodePoints(out: *Encoded, name: []const u8, dim: Dim, positions: layout.Positions.Const) void {
    assertName(name);
    initHead(out, .points, PointsHead{
        .count = positions.len(),
        .name_len = @intCast(name.len),
        .dim = @backingInt(dim),
        ._pad = 0,
    });
    addPart(out, name);
    alignPayload(out);
    addPart(out, positions.bytes());
}

/// Encodes a line set by borrowing every variable section; it allocates nothing.
pub fn encodeLines(
    out: *Encoded,
    name: []const u8,
    dim: Dim,
    positions: layout.Positions.Const,
    segments: []const [2]u32,
) void {
    assertName(name);
    std.debug.assert(segments.len <= std.math.maxInt(u32));
    initHead(out, .lines, LinesHead{
        .vertex_count = positions.len(),
        .segment_count = @intCast(segments.len),
        .name_len = @intCast(name.len),
        .dim = @backingInt(dim),
        ._pad = 0,
    });
    addPart(out, name);
    alignPayload(out);
    addPart(out, positions.bytes());
    alignPayload(out);
    addPart(out, std.mem.sliceAsBytes(segments));
}

/// Encodes a scalar quantity by borrowing strings and values; it allocates nothing.
pub fn encodeScalarQuantity(
    out: *Encoded,
    structure: []const u8,
    name: []const u8,
    target: Target,
    values: []const f32,
) void {
    assertName(structure);
    assertName(name);
    std.debug.assert(values.len <= std.math.maxInt(u32));
    initHead(out, .scalar_quantity, ScalarQuantityHead{
        .count = @intCast(values.len),
        .structure_len = @intCast(structure.len),
        .name_len = @intCast(name.len),
        .target = @backingInt(target),
        ._pad = @splat(0),
    });
    addPart(out, structure);
    addPart(out, name);
    alignPayload(out);
    addPart(out, std.mem.sliceAsBytes(values));
}

/// Encodes a vector quantity by borrowing strings and vector bytes; it allocates nothing.
pub fn encodeVectorQuantity(
    out: *Encoded,
    structure: []const u8,
    name: []const u8,
    target: Target,
    vectors: layout.Positions.Const,
) void {
    assertName(structure);
    assertName(name);
    initHead(out, .vector_quantity, VectorQuantityHead{
        .count = vectors.len(),
        .structure_len = @intCast(structure.len),
        .name_len = @intCast(name.len),
        .target = @backingInt(target),
        ._pad = @splat(0),
    });
    addPart(out, structure);
    addPart(out, name);
    alignPayload(out);
    addPart(out, vectors.bytes());
}

/// Encodes a borrowed log string without allocation.
pub fn encodeLog(out: *Encoded, level: LogLevel, text: []const u8) void {
    std.debug.assert(text.len <= std.math.maxInt(u32));
    initHead(out, .log, LogHead{
        .text_len = @intCast(text.len),
        .level = @backingInt(level),
        ._pad = @splat(0),
    });
    addPart(out, text);
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

fn decodeMesh(payload: []align(payload_alignment) const u8) DecodeError!Mesh {
    const head = try readHead(MeshHead, payload);
    try checkNameLen(head.name_len);
    const dim = try decodeDim(head.dim);
    const name_end = try checkedEnd(@sizeOf(MeshHead), head.name_len, payload.len);
    const positions_start = try alignedStart(name_end, payload.len);
    const positions_len = try countBytes(head.vertex_count, layout.Positions.bytes_per_vertex);
    const positions_end = try checkedEnd(positions_start, positions_len, payload.len);
    const faces_start = try alignedStart(positions_end, payload.len);
    const faces_len = try countBytes(head.face_count, @sizeOf([3]u32));
    const faces_end = try checkedEnd(faces_start, faces_len, payload.len);
    if (faces_end != payload.len) return error.BadLength;

    const positions_bytes = payload[positions_start..positions_end];
    const face_bytes = payload[faces_start..faces_end];
    return .{
        .name = payload[@sizeOf(MeshHead)..name_end],
        .dim = dim,
        .positions = layout.Positions.Const.fromBytes(positions_bytes),
        .faces = bytesAsSlice([3]u32, face_bytes),
    };
}

fn decodeMeshPositions(payload: []align(payload_alignment) const u8) DecodeError!MeshPositions {
    const head = try readHead(MeshPositionsHead, payload);
    try checkNameLen(head.name_len);
    const name_end = try checkedEnd(@sizeOf(MeshPositionsHead), head.name_len, payload.len);
    const positions_start = try alignedStart(name_end, payload.len);
    const positions_len = try countBytes(head.vertex_count, layout.Positions.bytes_per_vertex);
    const positions_end = try checkedEnd(positions_start, positions_len, payload.len);
    if (positions_end != payload.len) return error.BadLength;
    return .{
        .name = payload[@sizeOf(MeshPositionsHead)..name_end],
        .positions = layout.Positions.Const.fromBytes(payload[positions_start..positions_end]),
    };
}

fn decodePoints(payload: []align(payload_alignment) const u8) DecodeError!Points {
    const head = try readHead(PointsHead, payload);
    try checkNameLen(head.name_len);
    const dim = try decodeDim(head.dim);
    const name_end = try checkedEnd(@sizeOf(PointsHead), head.name_len, payload.len);
    const positions_start = try alignedStart(name_end, payload.len);
    const positions_len = try countBytes(head.count, layout.Positions.bytes_per_vertex);
    const positions_end = try checkedEnd(positions_start, positions_len, payload.len);
    if (positions_end != payload.len) return error.BadLength;
    return .{
        .name = payload[@sizeOf(PointsHead)..name_end],
        .dim = dim,
        .positions = layout.Positions.Const.fromBytes(payload[positions_start..positions_end]),
    };
}

fn decodeLines(payload: []align(payload_alignment) const u8) DecodeError!Lines {
    const head = try readHead(LinesHead, payload);
    try checkNameLen(head.name_len);
    const dim = try decodeDim(head.dim);
    const name_end = try checkedEnd(@sizeOf(LinesHead), head.name_len, payload.len);
    const positions_start = try alignedStart(name_end, payload.len);
    const positions_len = try countBytes(head.vertex_count, layout.Positions.bytes_per_vertex);
    const positions_end = try checkedEnd(positions_start, positions_len, payload.len);
    const segments_start = try alignedStart(positions_end, payload.len);
    const segments_len = try countBytes(head.segment_count, @sizeOf([2]u32));
    const segments_end = try checkedEnd(segments_start, segments_len, payload.len);
    if (segments_end != payload.len) return error.BadLength;
    return .{
        .name = payload[@sizeOf(LinesHead)..name_end],
        .dim = dim,
        .positions = layout.Positions.Const.fromBytes(payload[positions_start..positions_end]),
        .segments = bytesAsSlice([2]u32, payload[segments_start..segments_end]),
    };
}

fn decodeScalarQuantity(payload: []align(payload_alignment) const u8) DecodeError!ScalarQuantity {
    const head = try readHead(ScalarQuantityHead, payload);
    try checkNameLen(head.structure_len);
    try checkNameLen(head.name_len);
    const target = try decodeTarget(head.target);
    const structure_end = try checkedEnd(@sizeOf(ScalarQuantityHead), head.structure_len, payload.len);
    const name_end = try checkedEnd(structure_end, head.name_len, payload.len);
    const values_start = try alignedStart(name_end, payload.len);
    const values_len = try countBytes(head.count, @sizeOf(f32));
    const values_end = try checkedEnd(values_start, values_len, payload.len);
    if (values_end != payload.len) return error.BadLength;
    return .{
        .structure = payload[@sizeOf(ScalarQuantityHead)..structure_end],
        .name = payload[structure_end..name_end],
        .target = target,
        .values = bytesAsSlice(f32, payload[values_start..values_end]),
    };
}

fn decodeVectorQuantity(payload: []align(payload_alignment) const u8) DecodeError!VectorQuantity {
    const head = try readHead(VectorQuantityHead, payload);
    try checkNameLen(head.structure_len);
    try checkNameLen(head.name_len);
    const target = try decodeTarget(head.target);
    const structure_end = try checkedEnd(@sizeOf(VectorQuantityHead), head.structure_len, payload.len);
    const name_end = try checkedEnd(structure_end, head.name_len, payload.len);
    const vectors_start = try alignedStart(name_end, payload.len);
    const vectors_len = try countBytes(head.count, layout.Positions.bytes_per_vertex);
    const vectors_end = try checkedEnd(vectors_start, vectors_len, payload.len);
    if (vectors_end != payload.len) return error.BadLength;
    return .{
        .structure = payload[@sizeOf(VectorQuantityHead)..structure_end],
        .name = payload[structure_end..name_end],
        .target = target,
        .vectors = layout.Positions.Const.fromBytes(payload[vectors_start..vectors_end]),
    };
}

fn decodeLog(payload: []align(payload_alignment) const u8) DecodeError!Log {
    const head = try readHead(LogHead, payload);
    const level = try decodeLogLevel(head.level);
    const end = try exactEnd(@sizeOf(LogHead), head.text_len, payload.len);
    return .{ .level = level, .text = payload[@sizeOf(LogHead)..end] };
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
        .parts = undefined,
        .part_count = 1,
    };
}

fn initHead(out: *Encoded, kind: Kind, head: anytype) void {
    const head_bytes = std.mem.asBytes(&head);
    std.debug.assert(head_bytes.len <= max_head_size);
    out.* = .{
        .header = .{ .len = @intCast(head_bytes.len), .kind = @backingInt(kind) },
        .head = undefined,
        .parts = undefined,
        .part_count = 2,
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

// ---------------------------------------------------------------------------
// tests

const testing = std.testing;
const test_capacity = 4096;

test "wire heads have documented sizes and safe alignment" {
    try testing.expectEqual(8, @sizeOf(Header));
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
    try testing.expectError(error.BadMagic, decode(header, payload[0..header.len]));

    copyPayload(hello_frame, &payload);
    var hello_head = readValue(HelloHead, payload[0..@sizeOf(HelloHead)]);
    hello_head.version +%= 1;
    @memcpy(payload[0..@sizeOf(HelloHead)], std.mem.asBytes(&hello_head));
    try testing.expectError(error.VersionMismatch, decode(header, payload[0..header.len]));

    header = .{ .len = 0, .kind = 999 };
    try testing.expectError(error.UnknownKind, decode(header, payload[0..0]));

    var positions_storage: [layout.Positions.byteSize(1)]u8 align(64) = @splat(0);
    const positions = layout.Positions.fromBytes(&positions_storage).toConst();
    encodePoints(&encoded, "p", .d3, positions);
    const points_frame = encoded.writeTo(&frame);
    copyPayload(points_frame, &payload);
    header = try decodeHeader(points_frame);
    payload[@offsetOf(PointsHead, "dim")] = 7;
    try testing.expectError(error.BadEnum, decode(header, payload[0..header.len]));
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
        const result = decode(header, payload_storage[0..available]);
        if (result) |_| return error.TestUnexpectedResult else |err| switch (err) {
            error.Truncated, error.BadLength => {},
            else => return err,
        }
    }

    const header = try decodeHeader(frame);
    copyPayload(frame, &payload_storage);
    payload_storage[header.len] = 0;
    try testing.expectError(error.BadLength, decode(header, payload_storage[0 .. header.len + 1]));
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
        _ = decode(header, payload[0..payload_len]) catch continue;
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
    return decode(header, payload_storage[0..header.len]);
}

fn copyPayload(frame: []const u8, payload: []align(section_alignment) u8) void {
    std.debug.assert(frame.len >= @sizeOf(Header));
    const payload_len = frame.len - @sizeOf(Header);
    std.debug.assert(payload.len >= payload_len);
    @memcpy(payload[0..payload_len], frame[@sizeOf(Header)..]);
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
