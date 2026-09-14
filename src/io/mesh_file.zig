//! Reading and writing mesh format files.
//!
//! This is the edge over `mesh_format.zig`, which is pure and works on byte
//! slices. Everything here touches the filesystem: it opens the path, reads or
//! writes the whole file, and hands the geometry on. A caller that already has
//! the bytes, from a mapping or a network, should use `mesh_format.zig`
//! directly.
//!
//! Reading returns the complex the file holds and drops the metadata region,
//! which is a view into bytes this function frees. A caller that wants the
//! metadata reads the file itself and calls `mesh_format.decode` and
//! `mesh_format.metadata` over the same buffer, which is the two lines `read`
//! composes.
const std = @import("std");
const mesh_format = @import("mesh_format.zig");
const complex_mod = @import("../geometry/complex.zig");
const mesh_mod = @import("../geometry/mesh.zig");

const Complex = complex_mod.Complex;
const Mesh = mesh_mod.Mesh;

/// Failure of a read: opening or reading the file, decoding it, or allocating
/// the result.
pub const ReadError = std.Io.Dir.ReadFileAllocError || mesh_format.Error;

/// Failure of a write: encoding the complex, or creating and writing the file.
pub const WriteError = std.Io.Dir.WriteFileError || mesh_format.Error;

/// Reads a mesh format file and returns the complex it holds.
///
/// The caller owns the result and releases it with `deinit` and the same
/// allocator. `dir` is where `path` is resolved, `.cwd()` being the usual
/// choice. The file is read whole; one too large for memory fails with
/// `error.OutOfMemory`. A caller wanting to bound the read, to map the file
/// rather than copy it, or to keep the metadata calls `readFileAlloc` and
/// `mesh_format.decode` itself.
///
/// O(n + s) in the file's vertex count and total simplex count.
pub fn read(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) ReadError!Complex {
    const bytes = try dir.readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    return mesh_format.decode(gpa, bytes);
}

/// Options for `write`.
pub const WriteOptions = struct {
    /// Bytes written verbatim into the file's metadata region. Nothing in this
    /// project interprets them.
    metadata: []const u8 = &.{},
    /// How the geometry itself is written. See `mesh_format.EncodeOptions`.
    encode: mesh_format.EncodeOptions = .{},
};

/// Writes a complex to a mesh format file, creating or truncating it.
///
/// Nothing is derived and nothing is dropped: the vertices and the four index
/// arrays are written as they stand, so reading the file back reproduces the
/// complex exactly, subject to the narrowing `encode.dim` asks for. The file is
/// built whole in memory before it is written, since its size is known from the
/// counts.
///
/// O(n + s) in the vertex count and the total simplex count.
pub fn write(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    complex: Complex,
    options: WriteOptions,
) WriteError!void {
    const size = try mesh_format.encodedSize(complex, options.metadata.len, options.encode);
    const bytes = try gpa.alloc(u8, size);
    defer gpa.free(bytes);
    try mesh_format.encode(complex, options.metadata, options.encode, bytes);
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// Writes a triangle mesh to a mesh format file, as a complex holding
/// 2-simplices alone.
///
/// The edges and vertices of the mesh are implied by its triangles and are not
/// written; see `mesh_format`.
///
/// O(n + f) in the vertex count and the face count.
pub fn writeMesh(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    mesh: Mesh,
    options: WriteOptions,
) WriteError!void {
    return write(gpa, io, dir, path, complex_mod.fromMesh(mesh), options);
}

const testing = std.testing;
const Vec3 = @import("../geometry/layout.zig").Vec3;

test "a complex survives a write and a read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var vertices = [_]Vec3{
        .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0), .init(0, 0, 1),
    };
    var points = [_]u32{3};
    var edges = [_][2]u32{.{ 0, 1 }};
    var triangles = [_][3]u32{ .{ 0, 2, 1 }, .{ 0, 1, 3 } };
    var tetrahedra = [_][4]u32{.{ 0, 1, 2, 3 }};
    const source: Complex = .{
        .vertices = &vertices,
        .points = &points,
        .edges = &edges,
        .triangles = &triangles,
        .tetrahedra = &tetrahedra,
    };

    try write(testing.allocator, testing.io, tmp.dir, "solid.mesh", source, .{});

    const got = try read(testing.allocator, testing.io, tmp.dir, "solid.mesh");
    defer got.deinit(testing.allocator);

    try testing.expectEqual(4, got.vertices.len);
    for (got.vertices, source.vertices) |a, b| try testing.expect(a.eql(b));
    try testing.expectEqualSlices(u32, source.points, got.points);
    try testing.expectEqualSlices([2]u32, source.edges, got.edges);
    try testing.expectEqualSlices([3]u32, source.triangles, got.triangles);
    try testing.expectEqualSlices([4]u32, source.tetrahedra, got.tetrahedra);
}

test "a mesh written as a complex comes back as its triangles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var vertices = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0) };
    var faces = [_][3]u32{.{ 0, 1, 2 }};
    const source: Mesh = .{ .vertices = &vertices, .faces = &faces };

    try writeMesh(testing.allocator, testing.io, tmp.dir, "mesh.mesh", source, .{});

    const got = try read(testing.allocator, testing.io, tmp.dir, "mesh.mesh");
    defer got.deinit(testing.allocator);

    try testing.expectEqual(0, got.points.len);
    try testing.expectEqual(0, got.edges.len);
    try testing.expectEqualSlices([3]u32, faces[0..], got.triangles);
    try testing.expectEqual(3, got.asMesh().vertices.len);
}

test "metadata written to a file is readable from its bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source: Complex = .empty;
    try write(testing.allocator, testing.io, tmp.dir, "note.mesh", source, .{
        .metadata = "written by a test",
    });

    const bytes = try tmp.dir.readFileAlloc(testing.io, "note.mesh", testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "written by a test", try mesh_format.metadata(bytes));
}

test "a missing file is an error rather than a panic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectError(
        error.FileNotFound,
        read(testing.allocator, testing.io, tmp.dir, "absent.mesh"),
    );
}

test "a file that is not a mesh file is reported" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "this is not a complex" });
    try testing.expectError(
        error.NotMeshFile,
        read(testing.allocator, testing.io, tmp.dir, "notes.txt"),
    );
}
