//! Reading and writing STL, in both the binary and the ASCII form.
//!
//! Every function here works on byte slices, not files: decoding takes the
//! bytes of a file and encoding produces them. The caller reads and writes,
//! which keeps this module pure, lets a large file be mapped rather than
//! copied, and makes the whole format testable without a filesystem.
//!
//! STL stores a triangle soup. Each facet carries its three vertices in full,
//! so a file of `n` facets decodes to `3n` vertices and `n` faces indexing them
//! in order, and a vertex shared by several facets appears once per facet. This
//! is the representation the format has, not a choice made here. Decoding
//! reproduces it rather than interpreting it, which keeps the read a copy.
//!
//! The copies are bit-identical, the exporter having written one value
//! unchanged for each facet that touches it, so `indexing.indexSoup` recovers
//! the original connectivity exactly and no tolerance enters anywhere. Run it
//! on anything imported that will be treated as a surface: until then every
//! edge belongs to one triangle and each facet is its own island.
//!
//! Reading and writing are therefore not an identity on arbitrary input, and
//! should not be. A file carrying degenerate facets, or the same point written
//! as two, is normalized on the way in, so what goes back out differs from what
//! came in. It differs once. A second pass over the written file reproduces it
//! byte for byte, so the path reaches a fixed point after one application, and
//! a well-formed file is already at that fixed point and survives unchanged.
//! What is preserved exactly, in every case, is the geometry: the vertex bytes
//! of a facet make the trip untouched.
//!
//! The facet normal STL stores is unreliable in practice, being zero or wrong
//! in many files. Decoding returns it only when asked, and encoding computes it
//! from the winding when the caller does not supply one.
//!
//! Performance notes are on the individual functions. The binary path is a
//! bulk copy per facet and the ASCII path is dominated by float conversion.
//! Both are straight-line scalar code; the record stride that would have to be
//! dealt with to vectorize either is described on `decodeBinary`.
const std = @import("std");
const builtin = @import("builtin");
const layout = @import("../geometry/layout.zig");
const mesh_mod = @import("../geometry/mesh.zig");

const Vec3 = layout.Vec3;
const native_endian = builtin.cpu.arch.endian();

/// The two forms of the format. They describe the same geometry; binary is
/// about six times smaller and much faster to read.
pub const Format = enum { binary, ascii };

/// Failure of any decode.
///
/// `Truncated` means the bytes end inside a record the header promised.
/// `NotStl` means the bytes are neither form. `Malformed` covers an ASCII file
/// whose keywords or numbers do not parse. `WrongSize` means a caller's output
/// slice does not match the triangle count the file declares.
pub const Error = error{
    Truncated,
    NotStl,
    Malformed,
    WrongSize,
    OutOfMemory,
};

/// The fixed 80-byte comment at the head of a binary file, followed by the
/// facet count.
pub const binary_header_size = 84;

/// One binary facet: a normal, three vertices, and a two-byte attribute field
/// that is almost always zero and is preserved by neither decode nor encode.
pub const binary_record_size = 50;

/// The mesh type `decode` returns, which is the one the rest of the library
/// builds with. A decoded file holds `3 * faces.len` vertices and faces
/// indexing them in order, as the format's triangle soup requires.
pub const Mesh = mesh_mod.Mesh;

/// Reports which form `bytes` holds, or null when it is neither.
///
/// The leading keyword is not sufficient: some writers put the word `solid`
/// into the binary file's 80-byte comment, and a file that begins that way and
/// is then read as ASCII yields nothing. The test used here is arithmetic
/// instead. A binary file is exactly `84 + 50n` bytes for the `n` its header
/// declares, which a text file matches only by coincidence, so the length is
/// checked first and the keyword consulted only when it does not fit.
/// Allocates nothing and reads at most the first 84 bytes.
pub fn detect(bytes: []const u8) ?Format {
    if (bytes.len >= binary_header_size) {
        const declared = std.mem.readInt(u32, bytes[80..84], .little);
        if (binarySize(declared) == bytes.len) return .binary;
    }
    var i: usize = 0;
    while (i < bytes.len and isSpace(bytes[i])) i += 1;
    if (std.mem.startsWith(u8, bytes[i..], "solid")) return .ascii;
    return null;
}

/// The number of facets a binary file declares, read from its header.
///
/// This is `O(1)`, so a caller sizes its output exactly before decoding rather
/// than growing a list. Returns `Truncated` when the bytes are shorter than the
/// header, or shorter than the facets the header promises.
pub fn binaryTriangleCount(bytes: []const u8) Error!u32 {
    if (bytes.len < binary_header_size) return error.Truncated;
    const declared = std.mem.readInt(u32, bytes[80..84], .little);
    if (bytes.len < binarySize(declared)) return error.Truncated;
    return declared;
}

/// The exact byte length of a binary file holding `triangle_count` facets.
pub fn binarySize(triangle_count: u32) usize {
    return binary_header_size + @as(usize, triangle_count) * binary_record_size;
}

/// Decodes a binary file into caller-provided storage, allocating nothing.
///
/// `vertices` must hold `3n` entries and `faces` exactly `n`, for the `n` that
/// `binaryTriangleCount` reports, and `normals` either `n` or null. Vertices
/// are written in file order and `faces` is filled with consecutive triples,
/// which is the identity indexing a triangle soup has.
///
/// The inner loop is one 36-byte copy per facet. `Vec3` is a 12-byte `extern
/// struct`, so a facet's three vertices are 36 contiguous bytes in the file and
/// 36 contiguous bytes in the output, and on a little-endian host the copy
/// needs no conversion. Vectorizing this is not a matter of widening the copy:
/// the 50-byte record stride is coprime with every useful vector width, so a
/// SIMD version would load spans of records and shuffle the wanted lanes into
/// place, which is worth doing only once this shows up in a profile against the
/// cost of getting the bytes into memory at all.
pub fn decodeBinary(
    bytes: []const u8,
    vertices: []Vec3,
    faces: [][3]u32,
    normals: ?[]Vec3,
) Error!void {
    const count = try binaryTriangleCount(bytes);
    if (faces.len != count) return error.WrongSize;
    if (vertices.len != 3 * @as(usize, count)) return error.WrongSize;
    if (normals) |n| if (n.len != count) return error.WrongSize;

    const vertex_bytes = std.mem.sliceAsBytes(vertices);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const record = bytes[binary_header_size + @as(usize, i) * binary_record_size ..];
        @memcpy(vertex_bytes[@as(usize, i) * 36 ..][0..36], record[12..48]);
        if (normals) |n| @memcpy(std.mem.asBytes(&n[i]), record[0..12]);
        const base = 3 * i;
        faces[i] = .{ base, base + 1, base + 2 };
    }

    if (native_endian != .little) {
        byteSwap(vertices);
        if (normals) |n| byteSwap(n);
    }
}

/// Decodes either form, allocating the result.
///
/// Detects the form with `detect` and dispatches. The caller owns the returned
/// mesh. For the binary form this allocates exactly once for each array,
/// because the count is known before any parsing; for the ASCII form the arrays
/// grow from an estimate, since the count is only known once the file has been
/// read through.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Mesh {
    return switch (detect(bytes) orelse return error.NotStl) {
        .binary => blk: {
            const count = try binaryTriangleCount(bytes);
            const vertices = try gpa.alloc(Vec3, 3 * @as(usize, count));
            errdefer gpa.free(vertices);
            const faces = try gpa.alloc([3]u32, count);
            errdefer gpa.free(faces);
            try decodeBinary(bytes, vertices, faces, null);
            break :blk .{ .vertices = vertices, .faces = faces };
        },
        .ascii => decodeAscii(gpa, bytes, null),
    };
}

/// Decodes an ASCII file, allocating the result and optionally the normals.
///
/// The parser reads a line at a time and dispatches on its first word, taking
/// `vertex` and `facet normal` and ignoring `solid`, `outer loop`, `endloop`,
/// `endfacet` and `endsolid`. Line structure is what makes ignoring them safe:
/// a solid's name is the remainder of its line and may be any text at all,
/// including the word `vertex`, and a parser scanning a flat token stream would
/// read such a name as the start of a coordinate triple. Real files vary in
/// indentation, line endings and whether the closing keywords repeat the name,
/// and none of that changes the geometry. A file whose vertex count is not a
/// multiple of three is `Malformed`, as is a number that does not parse.
///
/// The cost here is `parseFloat`, called nine times per facet, against which
/// the tokenizer is minor. Sizing is by estimate: an ASCII facet runs to
/// roughly 200 bytes, so the arrays are reserved from the file length and grow
/// only if that estimate is low.
pub fn decodeAscii(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    normals_out: ?*std.ArrayList(Vec3),
) Error!Mesh {
    const estimate = bytes.len / ascii_bytes_per_facet_estimate;

    var vertices: std.ArrayList(Vec3) = .empty;
    errdefer vertices.deinit(gpa);
    try vertices.ensureTotalCapacity(gpa, 3 * estimate);
    if (normals_out) |n| try n.ensureTotalCapacity(gpa, estimate);

    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
    while (lines.next()) |line| {
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        const keyword = tokens.next() orelse continue;
        if (std.mem.eql(u8, keyword, "vertex")) {
            try vertices.append(gpa, try parseVec3(&tokens));
        } else if (std.mem.eql(u8, keyword, "facet")) {
            // `facet normal x y z`. The numbers are parsed either way, so a
            // caller that does not want them still validates the line.
            const next = tokens.next() orelse return error.Malformed;
            if (!std.mem.eql(u8, next, "normal")) return error.Malformed;
            const normal = try parseVec3(&tokens);
            if (normals_out) |n| try n.append(gpa, normal);
        }
        // Every other line, `solid` and `endsolid` among them, is ignored
        // whole. That is what lets a name contain a keyword.
    }

    if (vertices.items.len % 3 != 0) return error.Malformed;
    const count = vertices.items.len / 3;
    const faces = try gpa.alloc([3]u32, count);
    errdefer gpa.free(faces);
    for (faces, 0..) |*face, i| {
        const base: u32 = @intCast(3 * i);
        face.* = .{ base, base + 1, base + 2 };
    }
    return .{ .vertices = try vertices.toOwnedSlice(gpa), .faces = faces };
}

/// Encodes a binary file into caller-provided storage, allocating nothing.
///
/// `out` must be exactly `binarySize(faces.len)` bytes. `normals` is either one
/// per face or null, in which case each facet's normal is computed from its
/// winding. The 80-byte comment is filled with `header`, truncated or
/// zero-padded to fit, and the two-byte attribute field of every facet is
/// zeroed.
///
/// A `header` beginning with `solid` is accepted but should be avoided: it
/// leaves the file's first five bytes indistinguishable from the ASCII form,
/// which readers less careful than `detect` take at face value.
pub fn encodeBinary(
    vertices: []const Vec3,
    faces: []const [3]u32,
    normals: ?[]const Vec3,
    header: []const u8,
    out: []u8,
) Error!void {
    if (out.len != binarySize(@intCast(faces.len))) return error.WrongSize;
    if (normals) |n| if (n.len != faces.len) return error.WrongSize;

    @memset(out[0..80], 0);
    const copied = @min(header.len, 80);
    @memcpy(out[0..copied], header[0..copied]);
    std.mem.writeInt(u32, out[80..84], @intCast(faces.len), .little);

    for (faces, 0..) |face, i| {
        const record = out[binary_header_size + i * binary_record_size ..][0..binary_record_size];
        const a = vertices[face[0]];
        const b = vertices[face[1]];
        const c = vertices[face[2]];
        const normal = if (normals) |n| n[i] else faceNormal(a, b, c);
        writeVec3(record[0..12], normal);
        writeVec3(record[12..24], a);
        writeVec3(record[24..36], b);
        writeVec3(record[36..48], c);
        record[48] = 0;
        record[49] = 0;
    }
}

/// Encodes an ASCII file, appending to `out`.
///
/// `name` names the solid, in the opening and closing keywords. `normals` is
/// either one per face or null, in which case each facet's normal is computed
/// from its winding. `out` is appended to rather than cleared.
///
/// Numbers are written with `{d}`, which produces the shortest decimal that
/// reads back as the same `f32`, so a file written here and read back gives the
/// identical mesh. Each facet is formatted into a stack buffer and appended in
/// one piece, which keeps the per-facet cost to one bounds check.
pub fn encodeAscii(
    gpa: std.mem.Allocator,
    name: []const u8,
    vertices: []const Vec3,
    faces: []const [3]u32,
    normals: ?[]const Vec3,
    out: *std.ArrayList(u8),
) Error!void {
    if (normals) |n| if (n.len != faces.len) return error.WrongSize;

    // Nine shortest-round-trip f32s and the keywords around them fit well
    // inside this; the widest an f32 prints is 17 characters.
    var scratch: [512]u8 = undefined;
    try out.ensureUnusedCapacity(gpa, name.len * 2 + 20 + faces.len * 180);
    try out.print(gpa, "solid {s}\n", .{name});

    for (faces, 0..) |face, i| {
        const a = vertices[face[0]];
        const b = vertices[face[1]];
        const c = vertices[face[2]];
        const n = if (normals) |m| m[i] else faceNormal(a, b, c);
        const text = std.fmt.bufPrint(
            &scratch,
            "facet normal {d} {d} {d}\n outer loop\n  vertex {d} {d} {d}\n  vertex {d} {d} {d}\n" ++
                "  vertex {d} {d} {d}\n endloop\nendfacet\n",
            .{ n.x, n.y, n.z, a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z },
        ) catch return error.Malformed;
        try out.appendSlice(gpa, text);
    }
    try out.print(gpa, "endsolid {s}\n", .{name});
}

/// Roughly the bytes one facet occupies in the ASCII form, used only to size
/// the arrays `decodeAscii` fills. A low estimate costs a reallocation, a high
/// one costs memory, and neither changes the result.
const ascii_bytes_per_facet_estimate = 200;

/// The unit normal of a triangle wound counter-clockwise, or zero for a
/// degenerate one, matching what `geometry.faceNormals` computes.
fn faceNormal(a: Vec3, b: Vec3, c: Vec3) Vec3 {
    const n = b.sub(a).cross(c.sub(a));
    const length = n.length();
    return if (length == 0) .zero else n.scale(1 / length);
}

fn parseVec3(tokens: *std.mem.TokenIterator(u8, .any)) Error!Vec3 {
    var v: [3]f32 = undefined;
    for (&v) |*component| {
        const token = tokens.next() orelse return error.Malformed;
        component.* = std.fmt.parseFloat(f32, token) catch return error.Malformed;
    }
    return .init(v[0], v[1], v[2]);
}

fn writeVec3(out: *[12]u8, v: Vec3) void {
    std.mem.writeInt(u32, out[0..4], @bitCast(v.x), .little);
    std.mem.writeInt(u32, out[4..8], @bitCast(v.y), .little);
    std.mem.writeInt(u32, out[8..12], @bitCast(v.z), .little);
}

/// Reverses the byte order of every component in place, for a host that is not
/// little-endian. STL is little-endian regardless of where it is read.
fn byteSwap(values: []Vec3) void {
    for (values) |*v| {
        v.x = @bitCast(@byteSwap(@as(u32, @bitCast(v.x))));
        v.y = @bitCast(@byteSwap(@as(u32, @bitCast(v.y))));
        v.z = @bitCast(@byteSwap(@as(u32, @bitCast(v.z))));
    }
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

const testing = std.testing;

/// Two triangles sharing an edge geometrically but not by index, which is how
/// STL stores them and so what a round trip must reproduce exactly.
const sample_vertices = [_]Vec3{
    .init(0, 0, 0),           .init(1, 0, 0),  .init(1, 1, 0),
    .init(0, 0, 0),           .init(1, 1, 0),  .init(0, 1, 0),
    .init(-1.5, 2.25, 0.125), .init(3, 0, -1), .init(0, 0.5, 7),
};
const sample_faces = [_][3]u32{ .{ 0, 1, 2 }, .{ 3, 4, 5 }, .{ 6, 7, 8 } };

fn encodeSampleBinary(gpa: std.mem.Allocator, header: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, binarySize(sample_faces.len));
    errdefer gpa.free(out);
    try encodeBinary(&sample_vertices, &sample_faces, null, header, out);
    return out;
}

fn expectSample(mesh: Mesh) !void {
    try testing.expectEqual(sample_faces.len, mesh.faces.len);
    try testing.expectEqual(3 * sample_faces.len, mesh.vertices.len);
    for (mesh.faces, 0..) |face, i| {
        const base: u32 = @intCast(3 * i);
        try testing.expectEqual([3]u32{ base, base + 1, base + 2 }, face);
        for (face, sample_faces[i]) |got, want| {
            try testing.expect(mesh.vertices[got].eql(sample_vertices[want]));
        }
    }
}

test "sizes match the format" {
    try testing.expectEqual(84, binary_header_size);
    try testing.expectEqual(50, binary_record_size);
    try testing.expectEqual(84, binarySize(0));
    try testing.expectEqual(84 + 50 * 3, binarySize(3));
    // The bulk copy in decodeBinary depends on this.
    try testing.expectEqual(12, @sizeOf(Vec3));
}

test "a binary file round trips exactly" {
    const bytes = try encodeSampleBinary(testing.allocator, "vertex test");
    defer testing.allocator.free(bytes);

    try testing.expectEqual(Format.binary, detect(bytes).?);
    try testing.expectEqual(sample_faces.len, try binaryTriangleCount(bytes));

    const mesh = try decode(testing.allocator, bytes);
    defer mesh.deinit(testing.allocator);
    try expectSample(mesh);
}

test "an ASCII file round trips exactly" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try encodeAscii(testing.allocator, "sample", &sample_vertices, &sample_faces, null, &text);

    try testing.expect(std.mem.startsWith(u8, text.items, "solid sample\n"));
    try testing.expect(std.mem.endsWith(u8, text.items, "endsolid sample\n"));
    try testing.expectEqual(Format.ascii, detect(text.items).?);

    const mesh = try decode(testing.allocator, text.items);
    defer mesh.deinit(testing.allocator);
    try expectSample(mesh);
}

test "the two forms decode to the same mesh" {
    const bytes = try encodeSampleBinary(testing.allocator, "");
    defer testing.allocator.free(bytes);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try encodeAscii(testing.allocator, "s", &sample_vertices, &sample_faces, null, &text);

    const from_binary = try decode(testing.allocator, bytes);
    defer from_binary.deinit(testing.allocator);
    const from_ascii = try decode(testing.allocator, text.items);
    defer from_ascii.deinit(testing.allocator);

    try testing.expectEqualSlices([3]u32, from_binary.faces, from_ascii.faces);
    for (from_binary.vertices, from_ascii.vertices) |a, b| try testing.expect(a.eql(b));
}

test "a binary file whose comment begins with solid is still binary" {
    // Some writers put the word into the 80-byte comment. Detection by keyword
    // alone would read this as ASCII and find nothing in it.
    const bytes = try encodeSampleBinary(testing.allocator, "solid produced by another tool");
    defer testing.allocator.free(bytes);
    try testing.expectEqual(Format.binary, detect(bytes).?);

    const mesh = try decode(testing.allocator, bytes);
    defer mesh.deinit(testing.allocator);
    try expectSample(mesh);
}

test "stored normals are returned when asked and computed when absent" {
    const normals = [_]Vec3{ .init(0, 0, 1), .init(0, 0, 1), .init(0.25, -0.5, 0.75) };
    const bytes = try testing.allocator.alloc(u8, binarySize(sample_faces.len));
    defer testing.allocator.free(bytes);
    try encodeBinary(&sample_vertices, &sample_faces, &normals, "", bytes);

    const vertices = try testing.allocator.alloc(Vec3, 3 * sample_faces.len);
    defer testing.allocator.free(vertices);
    const faces = try testing.allocator.alloc([3]u32, sample_faces.len);
    defer testing.allocator.free(faces);
    const read_back = try testing.allocator.alloc(Vec3, sample_faces.len);
    defer testing.allocator.free(read_back);
    try decodeBinary(bytes, vertices, faces, read_back);
    for (read_back, normals) |got, want| try testing.expect(got.eql(want));

    // With no normals supplied, each facet gets the normal of its winding. The
    // first two faces lie in z = 0 wound counter-clockwise about +z.
    const computed = try encodeSampleBinary(testing.allocator, "");
    defer testing.allocator.free(computed);
    try decodeBinary(computed, vertices, faces, read_back);
    try testing.expect(read_back[0].eql(.init(0, 0, 1)));
    try testing.expect(read_back[1].eql(.init(0, 0, 1)));
}

test "a truncated binary file is reported rather than read past" {
    const bytes = try encodeSampleBinary(testing.allocator, "");
    defer testing.allocator.free(bytes);
    try testing.expectError(error.Truncated, binaryTriangleCount(bytes[0 .. bytes.len - 1]));
    try testing.expectError(error.Truncated, binaryTriangleCount(bytes[0..40]));
    // Losing the tail also costs the size test, so the remainder is neither form.
    try testing.expectEqual(@as(?Format, null), detect(bytes[0 .. bytes.len - 1]));
}

test "output slices of the wrong size are refused" {
    const bytes = try encodeSampleBinary(testing.allocator, "");
    defer testing.allocator.free(bytes);
    var vertices: [9]Vec3 = undefined;
    var faces: [3][3]u32 = undefined;
    try testing.expectError(error.WrongSize, decodeBinary(bytes, vertices[0..6], &faces, null));
    try testing.expectError(error.WrongSize, decodeBinary(bytes, &vertices, faces[0..2], null));
    var short: [8]u8 = undefined;
    try testing.expectError(
        error.WrongSize,
        encodeBinary(&sample_vertices, &sample_faces, null, "", &short),
    );
}

test "a solid may be named after a keyword" {
    // The name is the rest of the line and may be any text. A parser reading a
    // flat token stream would take this name as the start of a coordinate.
    for ([_][]const u8{ "vertex", "facet normal 1 2 3", "endsolid solid" }) |name| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(testing.allocator);
        try encodeAscii(testing.allocator, name, &sample_vertices, &sample_faces, null, &text);
        const mesh = try decode(testing.allocator, text.items);
        defer mesh.deinit(testing.allocator);
        try expectSample(mesh);
    }
}

test "malformed ASCII is reported" {
    const cases = [_][]const u8{
        "solid s\nfacet normal 0 0\n", // the normal runs out of numbers
        "solid s\nfacet nrml 0 0 1\n", // the keyword after facet is wrong
        "solid s\nvertex 0 0 0\nvertex 1 0 0\nendsolid s\n", // two vertices, not three
        "solid s\nvertex 0 0 x\n", // a number that does not parse
    };
    for (cases) |case| {
        try testing.expectError(error.Malformed, decode(testing.allocator, case));
    }
}

test "bytes that are neither form are reported" {
    try testing.expectError(error.NotStl, decode(testing.allocator, "not a mesh at all"));
    try testing.expectError(error.NotStl, decode(testing.allocator, ""));
}

test "an empty solid is valid in both forms" {
    const empty_binary = try testing.allocator.alloc(u8, binarySize(0));
    defer testing.allocator.free(empty_binary);
    try encodeBinary(&.{}, &.{}, null, "", empty_binary);
    const from_binary = try decode(testing.allocator, empty_binary);
    defer from_binary.deinit(testing.allocator);
    try testing.expectEqual(0, from_binary.faces.len);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try encodeAscii(testing.allocator, "empty", &.{}, &.{}, null, &text);
    const from_ascii = try decode(testing.allocator, text.items);
    defer from_ascii.deinit(testing.allocator);
    try testing.expectEqual(0, from_ascii.faces.len);
}

test "leading whitespace does not hide an ASCII file" {
    const text = "\n  solid s\nfacet normal 0 0 1\nouter loop\n" ++
        "vertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid s\n";
    try testing.expectEqual(Format.ascii, detect(text).?);
    const mesh = try decode(testing.allocator, text);
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(1, mesh.faces.len);
}

fn decodeBinaryAllocationCase(gpa: std.mem.Allocator) !void {
    const bytes = try encodeSampleBinary(gpa, "");
    defer gpa.free(bytes);
    const mesh = try decode(gpa, bytes);
    defer mesh.deinit(gpa);
    try expectSample(mesh);
}

fn decodeAsciiAllocationCase(gpa: std.mem.Allocator, text: []const u8) !void {
    const mesh = try decode(gpa, text);
    defer mesh.deinit(gpa);
    try expectSample(mesh);
}

fn encodeAsciiAllocationCase(gpa: std.mem.Allocator) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try encodeAscii(gpa, "s", &sample_vertices, &sample_faces, null, &out);
    if (out.items.len == 0) return error.TestUnexpectedResult;
}

test "decode handles every allocation failure in both forms" {
    try testing.checkAllAllocationFailures(testing.allocator, decodeBinaryAllocationCase, .{});

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try encodeAscii(testing.allocator, "s", &sample_vertices, &sample_faces, null, &text);
    try testing.checkAllAllocationFailures(
        testing.allocator,
        decodeAsciiAllocationCase,
        .{text.items},
    );
}

test "encodeAscii handles every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, encodeAsciiAllocationCase, .{});
}

test "ingest normalizes once and is then a fixed point" {
    // A file that is not well formed: one vertex written twice and one facet
    // collapsed onto an edge. What comes back out is not what went in, which is
    // the point, and going round again changes nothing further.
    const gpa = testing.allocator;
    const vertices = [_]Vec3{
        .init(0, 0, 0), .init(1, 0, 0), .init(1, 1, 0),
        .init(0, 1, 0), .init(0, 0, 0), // index 4 repeats index 0
    };
    const faces = [_][3]u32{ .{ 0, 1, 2 }, .{ 4, 2, 3 }, .{ 1, 1, 2 } };

    const source = try gpa.alloc(u8, binarySize(faces.len));
    defer gpa.free(source);
    try encodeBinary(&vertices, &faces, null, "", source);

    const first = try ingest(gpa, source);
    defer first.deinit(gpa);
    try testing.expectEqual(2, first.faces.len);
    try testing.expectEqual(4, first.vertices.len);
    try testing.expectEqual(faces.len - 1, first.faces.len);

    const once = try gpa.alloc(u8, binarySize(@intCast(first.faces.len)));
    defer gpa.free(once);
    try encodeBinary(first.vertices, first.faces, null, "", once);
    // Fewer facets than went in, so the file cannot be the one it came from.
    try testing.expect(once.len < source.len);

    const second = try ingest(gpa, once);
    defer second.deinit(gpa);
    // Nothing left to drop: the second pass keeps every face it is given.
    try testing.expectEqual(first.faces.len, second.faces.len);
    try testing.expectEqual(first.vertices.len, second.vertices.len);

    const twice = try gpa.alloc(u8, binarySize(@intCast(second.faces.len)));
    defer gpa.free(twice);
    try encodeBinary(second.vertices, second.faces, null, "", twice);
    try testing.expectEqualSlices(u8, once, twice);
}

/// Decodes and recovers the index array, which is what any import does.
fn ingest(gpa: std.mem.Allocator, bytes: []const u8) !@import("../geometry/indexing.zig").Mesh {
    const soup = try decode(gpa, bytes);
    defer soup.deinit(gpa);
    return @import("../geometry/indexing.zig").indexSoup(gpa, soup.vertices, soup.faces);
}

test "an indexed mesh survives the format and comes back indexed" {
    // The premise the whole soup-to-index path rests on: an exporter writes one
    // value unchanged for every facet touching a vertex, so what comes back is
    // bit-identical and collapses to exactly the vertices that went in.
    const indexing = @import("../geometry/indexing.zig");
    const fixtures = @import("../geometry/fixtures.zig");
    const gpa = testing.allocator;

    var sphere = try fixtures.current.icosphere(gpa, 3, 1);
    defer sphere.deinit(gpa);

    const original = try gpa.alloc(Vec3, sphere.positions.len());
    defer gpa.free(original);
    for (original, 0..) |*v, i| v.* = sphere.positions.toConst().get(@intCast(i));

    const bytes = try gpa.alloc(u8, binarySize(@intCast(sphere.faces.len)));
    defer gpa.free(bytes);
    try encodeBinary(original, sphere.faces, null, "", bytes);

    const soup = try decode(gpa, bytes);
    defer soup.deinit(gpa);
    try testing.expectEqual(3 * sphere.faces.len, soup.vertices.len);

    const indexed = try indexing.indexSoup(gpa, soup.vertices, soup.faces);
    defer indexed.deinit(gpa);
    try testing.expectEqual(original.len, indexed.vertices.len);
    try testing.expectEqual(sphere.faces.len, indexed.faces.len);
    // A generated sphere has no zero-area facets, so nothing is pruned.
    try testing.expectEqual(soup.faces.len, indexed.faces.len);

    // Every face names the same three points as before, though the vertex
    // numbering follows first appearance rather than the original order.
    for (indexed.faces, sphere.faces) |got, want| {
        for (got, want) |g, w| try testing.expect(indexed.vertices[g].eql(original[w]));
    }
}
