//! Reading and writing STL files.
//!
//! This is the edge over `stl.zig`, which is pure and works on byte slices.
//! Everything here touches the filesystem: it opens the path, reads or writes
//! the whole file, and hands the geometry on. A caller that already has the
//! bytes, from a mapping or a network, should use `stl.zig` directly.
//!
//! Reading returns an indexed mesh rather than the triangle soup the format
//! stores, because a soup is not a surface: `indexSoup` collapses the
//! bit-identical copies STL writes and drops the degenerate facets exporters
//! leave behind. `readSoup` is there for a caller that wants the file's own
//! form untouched.
const std = @import("std");
const stl = @import("stl.zig");
const indexing = @import("../geometry/indexing.zig");
const mesh_mod = @import("../geometry/mesh.zig");

const Mesh = mesh_mod.Mesh;

/// Failure of a read: opening or reading the file, decoding it, or allocating
/// the result.
pub const ReadError = std.Io.Dir.ReadFileAllocError || stl.Error;

/// Failure of a write: encoding the mesh, or creating and writing the file.
pub const WriteError = std.Io.Dir.WriteFileError || stl.Error;

/// Reads an STL file and returns it as an indexed mesh.
///
/// The form is detected from the file's contents, so binary and ASCII both
/// work, including the binary files whose comment begins with `solid`. The
/// facets are then indexed: bit-identical vertices are collapsed, recovering
/// the connectivity the exporter had, and degenerate facets are dropped. The
/// caller owns the result and releases it with `deinit` and the same allocator.
///
/// `dir` is where `path` is resolved, `.cwd()` being the usual choice. The file
/// is read whole; one too large for memory fails with `error.OutOfMemory`. A
/// caller wanting to bound the read for a reason of its own calls
/// `readFileAlloc` and `stl.decode` itself, which is the two lines this
/// composes.
///
/// O(n) in the file size, plus the indexing, which is expected linear; see
/// `indexing.indexSoup`.
pub fn read(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) ReadError!Mesh {
    const soup = try readSoup(gpa, io, dir, path);
    defer soup.deinit(gpa);
    return indexing.indexSoup(gpa, soup.vertices, soup.faces);
}

/// Reads an STL file and returns it as the triangle soup the format stores,
/// with three vertices per facet and no shared connectivity.
///
/// Use this to see a file as it is, to count what `read` would drop, or to hold
/// per-facet data alongside the facets. Anything treating the result as a
/// surface wants `read` instead.
///
/// O(n) in the file size for a binary file; see `stl.decode` for the ASCII one.
pub fn readSoup(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) ReadError!Mesh {
    const bytes = try dir.readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    return stl.decode(gpa, bytes);
}

/// Options for `write`.
pub const WriteOptions = struct {
    /// Which form to write. Binary is about a quarter the size and far quicker
    /// to read back.
    format: stl.Format = .binary,
    /// The solid's name, which the ASCII form carries in its opening and
    /// closing keywords and the binary form in its 80-byte comment.
    name: []const u8 = "vertex",
};

/// Writes a mesh to an STL file, creating or truncating it.
///
/// Facet normals are computed from the winding, the format having no way to
/// store the mesh's own. A mesh with shared vertices is expanded to the
/// triangle soup the format requires, so what is written is larger than what is
/// held and reading it back needs `read` to index it again.
///
/// O(n) in the face count.
pub fn write(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    mesh: Mesh,
    options: WriteOptions,
) WriteError!void {
    switch (options.format) {
        .binary => {
            const bytes = try gpa.alloc(u8, stl.binarySize(@intCast(mesh.faces.len)));
            defer gpa.free(bytes);
            try stl.encodeBinary(mesh.vertices, mesh.faces, null, options.name, bytes);
            try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
        },
        .ascii => {
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(gpa);
            try stl.encodeAscii(gpa, options.name, mesh.vertices, mesh.faces, null, &text);
            try dir.writeFile(io, .{ .sub_path = path, .data = text.items });
        },
    }
}

const testing = std.testing;

test "a mesh survives a write and a read in both forms" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var vertices = [_]@import("../geometry/layout.zig").Vec3{
        .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0), .init(0, 0, 1),
    };
    var faces = [_][3]u32{ .{ 0, 2, 1 }, .{ 0, 1, 3 }, .{ 1, 2, 3 }, .{ 2, 0, 3 } };
    const source: Mesh = .{ .vertices = &vertices, .faces = &faces };

    for ([_]stl.Format{ .binary, .ascii }) |format| {
        const name = if (format == .binary) "solid.stl" else "solid-ascii.stl";
        try write(testing.allocator, testing.io, tmp.dir, name, source, .{ .format = format });

        const soup = try readSoup(testing.allocator, testing.io, tmp.dir, name);
        defer soup.deinit(testing.allocator);
        try testing.expectEqual(4, soup.faces.len);
        try testing.expectEqual(12, soup.vertices.len);

        const indexed = try read(testing.allocator, testing.io, tmp.dir, name);
        defer indexed.deinit(testing.allocator);
        try testing.expectEqual(4, indexed.faces.len);
        try testing.expectEqual(4, indexed.vertices.len);
        for (indexed.faces, faces) |got, want| {
            for (got, want) |g, w| try testing.expect(indexed.vertices[g].eql(vertices[w]));
        }
    }
}

test "a missing file is an error rather than a panic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectError(
        error.FileNotFound,
        read(testing.allocator, testing.io, tmp.dir, "absent.stl"),
    );
}

test "a file that is not STL is reported" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "this is not a mesh" });
    try testing.expectError(
        error.NotStl,
        read(testing.allocator, testing.io, tmp.dir, "notes.txt"),
    );
}
