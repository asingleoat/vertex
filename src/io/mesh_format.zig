//! Reading and writing the mesh format, this project's own container for a
//! simplicial complex.
//!
//! Every function here works on byte slices, not files: decoding takes the
//! bytes of a file and encoding produces them. The caller reads and writes,
//! which keeps this module pure, lets a large file be mapped rather than
//! copied, and makes the whole format testable without a filesystem.
//! `mesh_file.zig` is the edge that opens paths.
//!
//! A file is a 128-byte header, a metadata region, the vertex array, and then
//! four index arrays, one per simplex degree. Every section begins at a
//! 64-byte boundary and is padded to the next one with zeros, so a section's
//! offset follows from the counts ahead of it by arithmetic and a mapped file
//! can be cast to the element type of any section without copying. The header
//! gives the byte length of the whole file and the length of every section, so
//! a reader allocates once from the first 128 bytes and reaches any section
//! directly.
//!
//! The format stores a simplicial complex rather than a mesh. The vertex array
//! is storage for every degree, and each index array names which of those
//! vertices form simplices of that degree, so a point cloud, an edge graph, a
//! triangle mesh and a tetrahedral mesh are the same file with different
//! sections populated. Closure is not required and not written: a triangle mesh
//! declares its triangles alone, and its edges and vertices are implied. See
//! `geometry/complex.zig` for the type this decodes to.
//!
//! Nothing derivable from the positions and the connectivity is stored. There
//! are no normals, no tangents, no adjacency and no bounding box, because
//! recomputing any of them costs what reading them costs and storing them adds
//! a second copy that can disagree with the first. Whatever a producer wants to
//! record anyway belongs in the metadata region, which is advisory and which no
//! reader is required to interpret.
//!
//! Every scalar in a file is little-endian. Coordinates are `f32` or `f64`
//! according to a header flag, and indices are `u32`. The flag reserved for
//! `u64` indices is defined and refused: widening them is the deferred change
//! recorded under "Planned" in `DESIGN.md`, and this decoder cannot represent
//! the result until the core does.
//!
//! Performance notes are on the individual functions. Decoding a file whose
//! coordinates are `f32` and whose `dim` is 3 is one bulk copy per section on a
//! little-endian host, the file's layout being this project's `Vec3` and `u32`
//! arrays exactly. The narrowing and widening paths are element-wise.
const std = @import("std");
const builtin = @import("builtin");
const layout = @import("../geometry/layout.zig");
const complex_mod = @import("../geometry/complex.zig");

const Vec3 = layout.Vec3;
const native_endian = builtin.cpu.arch.endian();

/// The complex type `decode` returns, which is the one the rest of the library
/// builds with. See `geometry/complex.zig`.
pub const Complex = complex_mod.Complex;

/// The eight bytes a file begins with.
/// ---
/// `MESH` names the format and is readable in the first column of a hex dump.
/// The four bytes after it detect a transfer that mangled the file rather than
/// moved it. `0x8F` lies in the UTF-8 continuation range, so no byte sequence
/// beginning with it is valid text and a seven-bit-clean path that strips the
/// high bit is caught. The `\r\n` and the `\n` that follows it are caught by
/// any translation in either direction, which is the failure a version control
/// system or a file transfer introduces when it treats the file as text.
///
/// The magic identifies a file and nothing more. What establishes that a file
/// is well-formed is the structural agreement `readHeader` checks: the section
/// lengths derived from the counts must sum to `total_bytes`, and the bytes
/// must be at least that long.
pub const magic = "MESH\x8F\r\n\n";

/// The format version this module reads and writes.
/// ---
/// Version 0 carries no compatibility promise. The shape of the header is still
/// moving, and a reader is entitled to reject every version but its own, which
/// is what `readHeader` does. Version 1 is cut when the format stops changing.
pub const version = 0;

/// The size of `Header`, and the offset of the first section in a version 0
/// file.
pub const header_size = 128;

/// The boundary every section begins on, and the multiple every section's
/// length is padded to.
/// ---
/// Sixty-four bytes matches the alignment the scene store gives its blobs, so a
/// section of a mapped file can be handed to the same code paths as an
/// allocated one. It also divides the stride of every element the format holds,
/// which lets a reader cast a section to its element type rather than copy it.
pub const section_alignment = 64;

/// Failure of any decode or encode.
/// ---
/// `NotMeshFile` means the bytes do not begin with `magic`. `UnsupportedVersion`
/// means they do but declare a version this module does not read.
/// `Unsupported` means the file is well-formed but declares something this
/// build cannot represent, which today is `u64` indices or a vertex count past
/// `u32`. `Truncated` means the bytes end before the header's `total_bytes`.
/// `Malformed` covers a header that disagrees with itself: a `dim` that is
/// neither 2 nor 3, a section arithmetic that overflows, a `total_bytes` that
/// is not the sum of the sections, or an index that addresses no vertex.
/// `WrongSize` means a caller's slice does not match the count the header
/// declares.
pub const Error = error{
    NotMeshFile,
    UnsupportedVersion,
    Unsupported,
    Truncated,
    Malformed,
    WrongSize,
    OutOfMemory,
};

/// The header's flag word.
/// ---
/// Reserved bits are written zero and ignored on read. A reader that meets one
/// set does not reject the file, because the version field is what states
/// compatibility and a flag that changed the meaning of the geometry would have
/// come with a version bump.
pub const Flags = packed struct(u64) {
    /// Coordinates in the file are `f64` rather than `f32`. `decode` narrows
    /// them to the `f32` the core holds.
    wide_coordinates: bool = false,
    /// Indices in the file are `u64` rather than `u32`. Reserved: a version 0
    /// writer writes zero, and `readHeader` refuses a file that sets it.
    wide_indices: bool = false,
    _reserved: u62 = 0,
};

/// The fixed 128 bytes at the head of a file.
/// ---
/// The fields are little-endian on disk and are read and written one at a time
/// by `readHeader` and `writeHeader`, so a big-endian host reads the same file.
/// This declaration is the layout of record: a test asserts its size and the
/// offset of every field.
///
/// `header_bytes` is where the first section begins, rounded up to
/// `section_alignment`. It is 128 in every version 0 file and exists so that a
/// later version can add fields to the reserved space without moving the
/// geometry.
pub const Header = extern struct {
    magic: [8]u8,
    version: u16,
    header_bytes: u16,
    reserved0: u32 = 0,
    flags: Flags,
    vertex_count: u64,
    /// The number of simplices of each degree, indexed by degree: index 0 is
    /// the standalone points, 1 the edges, 2 the triangles and 3 the
    /// tetrahedra.
    simplex_counts: [4]u64,
    metadata_bytes: u64,
    total_bytes: u64,
    /// The number of coordinates per vertex, 2 or 3.
    dim: u8,
    reserved1: [47]u8 = @splat(0),
};

/// The offset and length of one section, in bytes, both measured from the start
/// of the file.
pub const Span = struct {
    offset: u64,
    len: u64,

    /// The bytes of this section within a whole file.
    ///
    /// The caller must have established that `bytes` is at least
    /// `Header.total_bytes` long, which `readHeader` does.
    ///
    /// O(1).
    pub fn of(self: Span, bytes: []const u8) []const u8 {
        return bytes[@intCast(self.offset)..][0..@intCast(self.len)];
    }
};

/// Where every section of a file begins and how long it is.
pub const Sections = struct {
    metadata: Span,
    positions: Span,
    /// Indexed by simplex degree, as `Header.simplex_counts` is.
    simplices: [4]Span,
    /// The byte length of the whole file, which is the end of the last section
    /// including its padding.
    total: u64,
};

/// The number of bytes one coordinate occupies in a file with these flags.
///
/// O(1).
pub fn coordinateSize(flags: Flags) u64 {
    return if (flags.wide_coordinates) 8 else 4;
}

/// The number of bytes one index occupies in a file with these flags.
///
/// O(1).
pub fn indexSize(flags: Flags) u64 {
    return if (flags.wide_indices) 8 else 4;
}

/// Computes the layout of a file from its header, without reading its body.
///
/// This is the arithmetic that makes the header sufficient: the caller learns
/// the total byte length before any of the body has arrived, and reaches any
/// section by offset rather than by scanning. Every product and sum is checked,
/// because the counts come from a file and a header claiming absurd ones would
/// otherwise wrap.
///
/// The `total` this returns is what a well-formed header's `total_bytes` field
/// equals; `readHeader` compares them and returns `Malformed` when they differ.
///
/// O(1).
pub fn sections(head: Header) Error!Sections {
    var cursor = try alignUp(head.header_bytes);

    const metadata_span = try advance(&cursor, head.metadata_bytes);

    const coordinates = try mul(head.vertex_count, @as(u64, head.dim));
    const positions = try advance(&cursor, try mul(coordinates, coordinateSize(head.flags)));

    var simplices: [4]Span = undefined;
    for (&simplices, head.simplex_counts, 0..) |*span, count, degree| {
        const entries = try mul(count, degree + 1);
        span.* = try advance(&cursor, try mul(entries, indexSize(head.flags)));
    }

    return .{
        .metadata = metadata_span,
        .positions = positions,
        .simplices = simplices,
        .total = cursor,
    };
}

/// Reads and validates the header of a file.
///
/// Only the first 128 bytes are read, so a caller streaming a file calls this
/// on the header alone, takes `total_bytes` from the result, allocates once and
/// then reads the body. The body is not consulted and its length is not
/// checked: `decode`, `decodeInto` and `metadata` are what require the bytes to
/// be as long as `total_bytes`, and they accept a longer buffer so that a
/// mapping larger than the file is usable.
///
/// Returns `NotMeshFile` when the bytes do not begin with `magic`,
/// `UnsupportedVersion` for any version but this module's, `Unsupported` for a
/// file this build cannot represent, `Truncated` when there are fewer than 128
/// bytes to read, and `Malformed` when the header disagrees with itself.
///
/// O(1): at most the first 128 bytes are read.
pub fn readHeader(bytes: []const u8) Error!Header {
    if (bytes.len < magic.len) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.NotMeshFile;
    if (bytes.len < header_size) return error.Truncated;

    var head: Header = .{
        .magic = bytes[0..8].*,
        .version = std.mem.readInt(u16, bytes[8..10], .little),
        .header_bytes = std.mem.readInt(u16, bytes[10..12], .little),
        .flags = @bitCast(std.mem.readInt(u64, bytes[16..24], .little)),
        .vertex_count = std.mem.readInt(u64, bytes[24..32], .little),
        .simplex_counts = undefined,
        .metadata_bytes = std.mem.readInt(u64, bytes[64..72], .little),
        .total_bytes = std.mem.readInt(u64, bytes[72..80], .little),
        .dim = bytes[80],
    };
    for (&head.simplex_counts, 0..) |*count, i| {
        count.* = std.mem.readInt(u64, bytes[32 + 8 * i ..][0..8], .little);
    }

    if (head.version != version) return error.UnsupportedVersion;
    if (head.header_bytes < header_size) return error.Malformed;
    if (head.dim != 2 and head.dim != 3) return error.Malformed;
    if (head.flags.wide_indices) return error.Unsupported;
    if (head.vertex_count > std.math.maxInt(u32)) return error.Unsupported;

    const computed = try sections(head);
    if (computed.total != head.total_bytes) return error.Malformed;
    return head;
}

/// Reads the header and establishes that `bytes` holds the whole file.
///
/// This is `readHeader` plus the length check the decoders need. Bytes past
/// `total_bytes` are ignored, so a mapping larger than the file is accepted.
///
/// O(1).
fn readWholeHeader(bytes: []const u8) Error!Header {
    const head = try readHeader(bytes);
    if (bytes.len < head.total_bytes) return error.Truncated;
    return head;
}

/// The metadata region of a file, as a view into `bytes`.
///
/// The region is uninterpreted. Nothing in this module reads it, and a producer
/// may put anything there; what a consumer does with it is between the two of
/// them. The result borrows `bytes` and is valid for as long as they are.
///
/// O(1) beyond the header validation.
pub fn metadata(bytes: []const u8) Error![]const u8 {
    const head = try readWholeHeader(bytes);
    const layout_of = try sections(head);
    return layout_of.metadata.of(bytes);
}

/// Decodes a file into caller-provided storage, allocating nothing.
///
/// Every array of `out` must be exactly as long as the header declares, which
/// `readHeader` reports, and `out.vertices` exactly `vertex_count` entries.
/// A file whose `dim` is 2 fills `z` with zero, and one whose coordinates are
/// `f64` is narrowed to the `f32` the core holds.
///
/// Indices are checked against the vertex count as they are copied, and an
/// index addressing no vertex is `Malformed`. The check catches a mistake, a
/// truncated write or a file edited by hand, rather than defending against
/// anything; see the threat model in `DESIGN.md`.
///
/// The common file decodes by bulk copy. Coordinates that are `f32` with a
/// `dim` of 3 are this project's `Vec3` byte for byte, and `u32` indices are
/// its index arrays byte for byte, so on a little-endian host each section is
/// one `@memcpy` followed by a scan for the largest index. The other
/// combinations are element-wise.
///
/// O(n + s) in the vertex count and the total simplex count.
pub fn decodeInto(bytes: []const u8, out: Complex) Error!void {
    const head = try readWholeHeader(bytes);
    const layout_of = try sections(head);

    if (out.vertices.len != head.vertex_count) return error.WrongSize;
    if (out.points.len != head.simplex_counts[0]) return error.WrongSize;
    if (out.edges.len != head.simplex_counts[1]) return error.WrongSize;
    if (out.triangles.len != head.simplex_counts[2]) return error.WrongSize;
    if (out.tetrahedra.len != head.simplex_counts[3]) return error.WrongSize;

    readPositions(layout_of.positions.of(bytes), head, out.vertices);

    const limit: u32 = @intCast(head.vertex_count);
    try readPoints(layout_of.simplices[0].of(bytes), out.points, limit);
    try readSimplices(2, layout_of.simplices[1].of(bytes), out.edges, limit);
    try readSimplices(3, layout_of.simplices[2].of(bytes), out.triangles, limit);
    try readSimplices(4, layout_of.simplices[3].of(bytes), out.tetrahedra, limit);
}

/// Decodes a file, allocating the result.
///
/// The caller owns the returned complex and releases it with `deinit` and the
/// same allocator. Each of the five arrays is allocated exactly once at its
/// final size, the counts being in the header, so nothing grows.
///
/// The metadata region is not part of the result. Read it with `metadata`,
/// which returns a view into the same bytes.
///
/// O(n + s) in the vertex count and the total simplex count; allocates the
/// result.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Complex {
    const head = try readWholeHeader(bytes);

    const vertices = try gpa.alloc(Vec3, @intCast(head.vertex_count));
    errdefer gpa.free(vertices);
    const points = try gpa.alloc(u32, @intCast(head.simplex_counts[0]));
    errdefer gpa.free(points);
    const edges = try gpa.alloc([2]u32, @intCast(head.simplex_counts[1]));
    errdefer gpa.free(edges);
    const triangles = try gpa.alloc([3]u32, @intCast(head.simplex_counts[2]));
    errdefer gpa.free(triangles);
    const tetrahedra = try gpa.alloc([4]u32, @intCast(head.simplex_counts[3]));
    errdefer gpa.free(tetrahedra);

    const out: Complex = .{
        .vertices = vertices,
        .points = points,
        .edges = edges,
        .triangles = triangles,
        .tetrahedra = tetrahedra,
    };
    try decodeInto(bytes, out);
    return out;
}

/// Options for `encode` and `encodedSize`.
pub const EncodeOptions = struct {
    /// Write coordinates as `f64` rather than `f32`. The core holds `f32`, so
    /// this widens rather than recovers: it costs a third of the file and gains
    /// nothing until the core is `f64`. See "Planned" in `DESIGN.md`.
    wide_coordinates: bool = false,
    /// The number of coordinates to write per vertex, 2 or 3. Writing 2
    /// discards every `z`, which is what a planar complex wants and what a
    /// spatial one must not ask for.
    dim: u8 = 3,
};

/// The header a file holding this complex and this metadata would have.
///
/// `total_bytes` is filled in, so this is also how `encodedSize` and `encode`
/// agree on the layout without computing it twice.
///
/// O(1).
pub fn headerFor(complex: Complex, metadata_len: usize, options: EncodeOptions) Error!Header {
    if (options.dim != 2 and options.dim != 3) return error.Malformed;
    var head: Header = .{
        .magic = magic[0..8].*,
        .version = version,
        .header_bytes = header_size,
        .flags = .{ .wide_coordinates = options.wide_coordinates },
        .vertex_count = complex.vertices.len,
        .simplex_counts = .{
            complex.points.len,
            complex.edges.len,
            complex.triangles.len,
            complex.tetrahedra.len,
        },
        .metadata_bytes = metadata_len,
        .total_bytes = 0,
        .dim = options.dim,
    };
    head.total_bytes = (try sections(head)).total;
    return head;
}

/// The exact byte length of the file `encode` would write.
///
/// O(1).
pub fn encodedSize(complex: Complex, metadata_len: usize, options: EncodeOptions) Error!usize {
    return @intCast((try headerFor(complex, metadata_len, options)).total_bytes);
}

/// Encodes a complex into caller-provided storage, allocating nothing.
///
/// `out` must be exactly `encodedSize(complex, meta.len, options)` bytes.
/// `meta` is written verbatim into the metadata region and is not interpreted.
/// Padding is zeroed, so two files holding the same complex and the same
/// metadata are byte for byte identical and a hash of the file is stable.
///
/// Every index of `complex` must address a vertex that exists. This is asserted
/// rather than returned as an error, the input being in-process data the caller
/// built; `complex.indicesInRange` is the check to run on anything less certain.
///
/// O(n + s) in the vertex count and the total simplex count.
pub fn encode(
    complex: Complex,
    meta: []const u8,
    options: EncodeOptions,
    out: []u8,
) Error!void {
    const head = try headerFor(complex, meta.len, options);
    if (out.len != head.total_bytes) return error.WrongSize;
    std.debug.assert(complex_mod.indicesInRange(complex));

    const layout_of = try sections(head);
    writeHeader(head, out[0..header_size]);
    @memset(out[header_size..@intCast(layout_of.metadata.offset)], 0);

    @memcpy(out[@intCast(layout_of.metadata.offset)..][0..meta.len], meta);
    zeroPadding(out, layout_of.metadata);

    writePositions(out[@intCast(layout_of.positions.offset)..][0..@intCast(layout_of.positions.len)], head, complex.vertices);
    zeroPadding(out, layout_of.positions);

    writePoints(out, layout_of.simplices[0], complex.points);
    writeSimplices(2, out, layout_of.simplices[1], complex.edges);
    writeSimplices(3, out, layout_of.simplices[2], complex.triangles);
    writeSimplices(4, out, layout_of.simplices[3], complex.tetrahedra);
}

/// Writes a header into the first 128 bytes of `out`, little-endian.
///
/// O(1).
pub fn writeHeader(head: Header, out: *[header_size]u8) void {
    @memset(out, 0);
    @memcpy(out[0..8], &head.magic);
    std.mem.writeInt(u16, out[8..10], head.version, .little);
    std.mem.writeInt(u16, out[10..12], head.header_bytes, .little);
    std.mem.writeInt(u64, out[16..24], @bitCast(head.flags), .little);
    std.mem.writeInt(u64, out[24..32], head.vertex_count, .little);
    for (head.simplex_counts, 0..) |count, i| {
        std.mem.writeInt(u64, out[32 + 8 * i ..][0..8], count, .little);
    }
    std.mem.writeInt(u64, out[64..72], head.metadata_bytes, .little);
    std.mem.writeInt(u64, out[72..80], head.total_bytes, .little);
    out[80] = head.dim;
}

// ---- internals ----

fn alignUp(n: u64) Error!u64 {
    const rem = n % section_alignment;
    if (rem == 0) return n;
    return std.math.add(u64, n, section_alignment - rem) catch error.Malformed;
}

fn mul(a: u64, b: u64) Error!u64 {
    return std.math.mul(u64, a, b) catch error.Malformed;
}

fn advance(cursor: *u64, len: u64) Error!Span {
    const span: Span = .{ .offset = cursor.*, .len = len };
    const end = std.math.add(u64, cursor.*, len) catch return error.Malformed;
    cursor.* = try alignUp(end);
    return span;
}

fn zeroPadding(out: []u8, span: Span) void {
    const end: usize = @intCast(span.offset + span.len);
    const padded: usize = @intCast(alignUp(span.offset + span.len) catch unreachable);
    @memset(out[end..padded], 0);
}

fn readCoordinate(bytes: []const u8, wide: bool) f32 {
    if (wide) {
        const wide_bits = std.mem.readInt(u64, bytes[0..8], .little);
        return @floatCast(@as(f64, @bitCast(wide_bits)));
    }
    return @bitCast(std.mem.readInt(u32, bytes[0..4], .little));
}

fn writeCoordinate(out: []u8, value: f32, wide: bool) void {
    if (wide) {
        std.mem.writeInt(u64, out[0..8], @bitCast(@as(f64, value)), .little);
    } else {
        std.mem.writeInt(u32, out[0..4], @bitCast(value), .little);
    }
}

fn readPositions(bytes: []const u8, head: Header, out: []Vec3) void {
    if (!head.flags.wide_coordinates and head.dim == 3 and native_endian == .little) {
        @memcpy(std.mem.sliceAsBytes(out), bytes);
        return;
    }
    const stride: usize = @intCast(coordinateSize(head.flags));
    const wide = head.flags.wide_coordinates;
    for (out, 0..) |*v, i| {
        const record = bytes[i * head.dim * stride ..];
        v.* = .{
            .x = readCoordinate(record[0..], wide),
            .y = readCoordinate(record[stride..], wide),
            .z = if (head.dim == 3) readCoordinate(record[2 * stride ..], wide) else 0,
        };
    }
}

fn writePositions(out: []u8, head: Header, vertices: []const Vec3) void {
    if (!head.flags.wide_coordinates and head.dim == 3 and native_endian == .little) {
        @memcpy(out, std.mem.sliceAsBytes(vertices));
        return;
    }
    const stride: usize = @intCast(coordinateSize(head.flags));
    const wide = head.flags.wide_coordinates;
    for (vertices, 0..) |v, i| {
        const record = out[i * head.dim * stride ..];
        writeCoordinate(record[0..], v.x, wide);
        writeCoordinate(record[stride..], v.y, wide);
        if (head.dim == 3) writeCoordinate(record[2 * stride ..], v.z, wide);
    }
}

/// Copies the 0-simplex array, which is a flat `[]u32` rather than an array of
/// tuples, and checks every index against `limit`.
fn readPoints(bytes: []const u8, out: []u32, limit: u32) Error!void {
    if (native_endian == .little) {
        @memcpy(std.mem.sliceAsBytes(out), bytes);
    } else {
        for (out, 0..) |*value, i| {
            value.* = std.mem.readInt(u32, bytes[4 * i ..][0..4], .little);
        }
    }
    for (out) |value| if (value >= limit) return error.Malformed;
}

/// Copies an index array of degree `arity - 1`, whose elements are `[arity]u32`
/// tuples, and checks every index against `limit`.
fn readSimplices(
    comptime arity: usize,
    bytes: []const u8,
    out: [][arity]u32,
    limit: u32,
) Error!void {
    if (native_endian == .little) {
        @memcpy(std.mem.sliceAsBytes(out), bytes);
    } else {
        for (out, 0..) |*tuple, i| {
            for (tuple, 0..) |*value, k| {
                value.* = std.mem.readInt(u32, bytes[4 * (arity * i + k) ..][0..4], .little);
            }
        }
    }
    for (out) |tuple| for (tuple) |value| if (value >= limit) return error.Malformed;
}

fn writePoints(out: []u8, span: Span, values: []const u32) void {
    const region = out[@intCast(span.offset)..][0..@intCast(span.len)];
    if (native_endian == .little) {
        @memcpy(region, std.mem.sliceAsBytes(values));
    } else {
        for (values, 0..) |value, i| std.mem.writeInt(u32, region[4 * i ..][0..4], value, .little);
    }
    zeroPadding(out, span);
}

fn writeSimplices(
    comptime arity: usize,
    out: []u8,
    span: Span,
    values: []const [arity]u32,
) void {
    const region = out[@intCast(span.offset)..][0..@intCast(span.len)];
    if (native_endian == .little) {
        @memcpy(region, std.mem.sliceAsBytes(values));
    } else {
        for (values, 0..) |tuple, i| {
            for (tuple, 0..) |value, k| {
                std.mem.writeInt(u32, region[4 * (arity * i + k) ..][0..4], value, .little);
            }
        }
    }
    zeroPadding(out, span);
}

const testing = std.testing;

test "the header is the documented size and shape" {
    try testing.expectEqual(header_size, @sizeOf(Header));
    try testing.expectEqual(8, @sizeOf(Flags));
    try testing.expectEqual(0, @offsetOf(Header, "magic"));
    try testing.expectEqual(8, @offsetOf(Header, "version"));
    try testing.expectEqual(10, @offsetOf(Header, "header_bytes"));
    try testing.expectEqual(16, @offsetOf(Header, "flags"));
    try testing.expectEqual(24, @offsetOf(Header, "vertex_count"));
    try testing.expectEqual(32, @offsetOf(Header, "simplex_counts"));
    try testing.expectEqual(64, @offsetOf(Header, "metadata_bytes"));
    try testing.expectEqual(72, @offsetOf(Header, "total_bytes"));
    try testing.expectEqual(80, @offsetOf(Header, "dim"));
    try testing.expectEqual(8, magic.len);
}

fn sampleComplex() Complex {
    const S = struct {
        var vertices = [_]Vec3{
            .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0), .init(0, 0, 1), .init(2, 2, 2),
        };
        var points = [_]u32{ 4, 0 };
        var edges = [_][2]u32{ .{ 0, 1 }, .{ 1, 2 } };
        var triangles = [_][3]u32{ .{ 0, 2, 1 }, .{ 0, 1, 3 } };
        var tetrahedra = [_][4]u32{.{ 0, 1, 2, 3 }};
    };
    return .{
        .vertices = &S.vertices,
        .points = &S.points,
        .edges = &S.edges,
        .triangles = &S.triangles,
        .tetrahedra = &S.tetrahedra,
    };
}

fn expectSameComplex(want: Complex, got: Complex) !void {
    try testing.expectEqual(want.vertices.len, got.vertices.len);
    for (want.vertices, got.vertices) |a, b| try testing.expect(a.eql(b));
    try testing.expectEqualSlices(u32, want.points, got.points);
    try testing.expectEqualSlices([2]u32, want.edges, got.edges);
    try testing.expectEqualSlices([3]u32, want.triangles, got.triangles);
    try testing.expectEqualSlices([4]u32, want.tetrahedra, got.tetrahedra);
}

fn encodeAlloc(
    gpa: std.mem.Allocator,
    complex: Complex,
    meta: []const u8,
    options: EncodeOptions,
) ![]u8 {
    const bytes = try gpa.alloc(u8, try encodedSize(complex, meta.len, options));
    errdefer gpa.free(bytes);
    try encode(complex, meta, options, bytes);
    return bytes;
}

test "a complex of every degree round trips exactly" {
    const source = sampleComplex();
    const bytes = try encodeAlloc(testing.allocator, source, "", .{});
    defer testing.allocator.free(bytes);

    const got = try decode(testing.allocator, bytes);
    defer got.deinit(testing.allocator);
    try expectSameComplex(source, got);
}

test "every section begins on a 64-byte boundary" {
    const source = sampleComplex();
    const bytes = try encodeAlloc(testing.allocator, source, "seven!!", .{});
    defer testing.allocator.free(bytes);

    const head = try readHeader(bytes);
    const layout_of = try sections(head);
    try testing.expectEqual(0, layout_of.metadata.offset % section_alignment);
    try testing.expectEqual(0, layout_of.positions.offset % section_alignment);
    for (layout_of.simplices) |span| {
        try testing.expectEqual(0, span.offset % section_alignment);
    }
    try testing.expectEqual(bytes.len, layout_of.total);
}

test "the header alone gives the total size" {
    const source = sampleComplex();
    const bytes = try encodeAlloc(testing.allocator, source, "note", .{});
    defer testing.allocator.free(bytes);

    const head = try readHeader(bytes[0..header_size]);
    try testing.expectEqual(bytes.len, head.total_bytes);
}

test "metadata is returned verbatim and is not interpreted" {
    const source = sampleComplex();
    const note = "any bytes at all \x00\xff\x01";
    const bytes = try encodeAlloc(testing.allocator, source, note, .{});
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, note, try metadata(bytes));

    const got = try decode(testing.allocator, bytes);
    defer got.deinit(testing.allocator);
    try expectSameComplex(source, got);
}

test "wide coordinates round trip and hold the same values" {
    const source = sampleComplex();
    const narrow = try encodeAlloc(testing.allocator, source, "", .{});
    defer testing.allocator.free(narrow);
    const wide = try encodeAlloc(testing.allocator, source, "", .{ .wide_coordinates = true });
    defer testing.allocator.free(wide);

    try testing.expect(wide.len > narrow.len);

    const got = try decode(testing.allocator, wide);
    defer got.deinit(testing.allocator);
    try expectSameComplex(source, got);
}

test "a planar file drops z and reads back as zero" {
    const source = sampleComplex();
    const bytes = try encodeAlloc(testing.allocator, source, "", .{ .dim = 2 });
    defer testing.allocator.free(bytes);

    const got = try decode(testing.allocator, bytes);
    defer got.deinit(testing.allocator);
    for (got.vertices, source.vertices) |g, s| {
        try testing.expectEqual(s.x, g.x);
        try testing.expectEqual(s.y, g.y);
        try testing.expectEqual(@as(f32, 0), g.z);
    }
}

test "an empty complex is a valid file" {
    const source: Complex = .empty;
    const bytes = try encodeAlloc(testing.allocator, source, "", .{});
    defer testing.allocator.free(bytes);
    try testing.expectEqual(header_size, bytes.len);

    const got = try decode(testing.allocator, bytes);
    defer got.deinit(testing.allocator);
    try testing.expectEqual(0, got.vertices.len);
    try testing.expectEqual(0, got.simplexCount());
}

test "a triangle mesh writes no edges and no points" {
    var vertices = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0) };
    var faces = [_][3]u32{.{ 0, 1, 2 }};
    const source = complex_mod.fromMesh(.{ .vertices = &vertices, .faces = &faces });

    const bytes = try encodeAlloc(testing.allocator, source, "", .{});
    defer testing.allocator.free(bytes);

    const head = try readHeader(bytes);
    try testing.expectEqual(0, head.simplex_counts[0]);
    try testing.expectEqual(0, head.simplex_counts[1]);
    try testing.expectEqual(1, head.simplex_counts[2]);
    try testing.expectEqual(0, head.simplex_counts[3]);
}

test "bytes that are not a mesh file are reported" {
    const junk: [200]u8 = @splat('x');
    try testing.expectError(error.NotMeshFile, readHeader(&junk));
    try testing.expectError(error.Truncated, readHeader("MESH"));
}

test "a truncated file is reported rather than read past" {
    const source = sampleComplex();
    const bytes = try encodeAlloc(testing.allocator, source, "", .{});
    defer testing.allocator.free(bytes);

    try testing.expectError(error.Truncated, decode(testing.allocator, bytes[0 .. bytes.len - 1]));
    try testing.expectError(error.Truncated, decode(testing.allocator, bytes[0 .. bytes.len - 64]));
    try testing.expectError(error.Truncated, readHeader(bytes[0 .. header_size - 1]));
}

test "a version this module does not read is refused" {
    const source = sampleComplex();
    const bytes = try encodeAlloc(testing.allocator, source, "", .{});
    defer testing.allocator.free(bytes);

    std.mem.writeInt(u16, bytes[8..10], 1, .little);
    try testing.expectError(error.UnsupportedVersion, readHeader(bytes));
}

test "wide indices are refused rather than misread" {
    const source = sampleComplex();
    const bytes = try encodeAlloc(testing.allocator, source, "", .{});
    defer testing.allocator.free(bytes);

    const flags: Flags = .{ .wide_indices = true };
    std.mem.writeInt(u64, bytes[16..24], @bitCast(flags), .little);
    try testing.expectError(error.Unsupported, readHeader(bytes));
}

test "a reserved flag bit is ignored rather than rejected" {
    const source = sampleComplex();
    const bytes = try encodeAlloc(testing.allocator, source, "", .{});
    defer testing.allocator.free(bytes);

    std.mem.writeInt(u64, bytes[16..24], 1 << 33, .little);
    const got = try decode(testing.allocator, bytes);
    defer got.deinit(testing.allocator);
    try expectSameComplex(source, got);
}

test "a header that disagrees with its own size is malformed" {
    const source = sampleComplex();
    const bytes = try encodeAlloc(testing.allocator, source, "", .{});
    defer testing.allocator.free(bytes);

    std.mem.writeInt(u64, bytes[72..80], bytes.len + 64, .little);
    try testing.expectError(error.Malformed, readHeader(bytes));
}

test "a dim that is neither 2 nor 3 is malformed" {
    const source = sampleComplex();
    const bytes = try encodeAlloc(testing.allocator, source, "", .{});
    defer testing.allocator.free(bytes);

    bytes[80] = 4;
    try testing.expectError(error.Malformed, readHeader(bytes));
}

test "an index addressing no vertex is malformed" {
    const source = sampleComplex();
    const bytes = try encodeAlloc(testing.allocator, source, "", .{});
    defer testing.allocator.free(bytes);

    const head = try readHeader(bytes);
    const layout_of = try sections(head);
    const edges = bytes[@intCast(layout_of.simplices[1].offset)..];
    std.mem.writeInt(u32, edges[0..4], @intCast(head.vertex_count), .little);

    try testing.expectError(error.Malformed, decode(testing.allocator, bytes));
}

test "a count past what the arithmetic can hold is malformed" {
    var head: Header = .{
        .magic = magic[0..8].*,
        .version = version,
        .header_bytes = header_size,
        .flags = .{},
        .vertex_count = 0,
        .simplex_counts = .{ std.math.maxInt(u64), 0, 0, 0 },
        .metadata_bytes = 0,
        .total_bytes = 0,
        .dim = 3,
    };
    try testing.expectError(error.Malformed, sections(head));

    head.simplex_counts = .{ 0, 0, 0, 0 };
    head.vertex_count = std.math.maxInt(u64);
    try testing.expectError(error.Malformed, sections(head));
}

test "output slices of the wrong size are refused" {
    const source = sampleComplex();
    const bytes = try encodeAlloc(testing.allocator, source, "", .{});
    defer testing.allocator.free(bytes);

    var short: Complex = .empty;
    try testing.expectError(error.WrongSize, decodeInto(bytes, short));

    short.vertices = source.vertices;
    try testing.expectError(error.WrongSize, decodeInto(bytes, short));
}

test "encode refuses an output buffer of the wrong size" {
    const source = sampleComplex();
    var buffer: [16]u8 = undefined;
    try testing.expectError(error.WrongSize, encode(source, "", .{}, &buffer));
}

test "an unusable dim is refused before anything is written" {
    const source = sampleComplex();
    try testing.expectError(error.Malformed, encodedSize(source, 0, .{ .dim = 1 }));
}

test "two encodings of the same complex are byte identical" {
    const source = sampleComplex();
    const first = try encodeAlloc(testing.allocator, source, "note", .{});
    defer testing.allocator.free(first);
    const second = try encodeAlloc(testing.allocator, source, "note", .{});
    defer testing.allocator.free(second);
    try testing.expectEqualSlices(u8, first, second);
}

test "decode handles every allocation failure" {
    const source = sampleComplex();
    const bytes = try encodeAlloc(testing.allocator, source, "note", .{});
    defer testing.allocator.free(bytes);

    const Case = struct {
        fn run(gpa: std.mem.Allocator, encoded: []const u8) !void {
            const got = try decode(gpa, encoded);
            got.deinit(gpa);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{bytes});
}
