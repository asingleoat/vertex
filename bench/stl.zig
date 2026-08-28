//! STL read and write benchmark, over a mesh large enough to leave cache.
//!
//! Throughput is reported in facets per second. The binary path should run at
//! memory bandwidth, since it is one 36-byte copy per facet; the ASCII path is
//! bounded by decimal conversion and runs orders of magnitude slower, which is
//! the measurement that justifies preferring the binary form.
const std = @import("std");
const vertex = @import("vertex");
const harness = @import("lib/harness.zig");

const Vec3 = vertex.Vec3;
const stl = vertex.internal.stl;

pub fn main() !void {
    var io_state: harness.Io = .{};
    const io = io_state.get();
    const gpa = std.heap.page_allocator;

    // Subdivision 5 is 20480 facets; 6 is 81920, around 4 MB of binary STL.
    const source = try vertex.internal.fixtures.current.icosphere(gpa, 6, 1);
    defer source.deinit(gpa);

    const vertices = try gpa.alloc(Vec3, source.positions.len());
    defer gpa.free(vertices);
    for (vertices, 0..) |*v, i| v.* = source.positions.toConst().get(@intCast(i));

    const binary = try gpa.alloc(u8, stl.binarySize(@intCast(source.faces.len)));
    defer gpa.free(binary);
    try stl.encodeBinary(vertices, source.faces, null, "bench", binary);

    var ascii: std.ArrayList(u8) = .empty;
    defer ascii.deinit(gpa);
    try stl.encodeAscii(gpa, "bench", vertices, source.faces, null, &ascii);

    const facets: u64 = source.faces.len;
    std.debug.print(
        "stl: {d} facets, binary {d} bytes, ascii {d} bytes ({d:.1}x)\n",
        .{
            facets,
            binary.len,
            ascii.items.len,
            @as(f64, @floatFromInt(ascii.items.len)) / @as(f64, @floatFromInt(binary.len)),
        },
    );

    const out_vertices = try gpa.alloc(Vec3, 3 * source.faces.len);
    defer gpa.free(out_vertices);
    const out_faces = try gpa.alloc([3]u32, source.faces.len);
    defer gpa.free(out_faces);

    var decode_binary: DecodeBinary = .{ .bytes = binary, .vertices = out_vertices, .faces = out_faces };
    harness.bench(io, "stl/decodeBinary", "-", facets, .{ .elements = facets, .unit = "facets/s" }, &decode_binary, DecodeBinary.run);

    var encode_binary: EncodeBinary = .{ .vertices = vertices, .faces = source.faces, .out = binary };
    harness.bench(io, "stl/encodeBinary", "-", facets, .{ .elements = facets, .unit = "facets/s" }, &encode_binary, EncodeBinary.run);

    var decode_ascii: DecodeAscii = .{ .gpa = gpa, .bytes = ascii.items };
    harness.bench(io, "stl/decodeAscii", "-", facets, .{ .elements = facets, .unit = "facets/s" }, &decode_ascii, DecodeAscii.run);

    var encode_ascii: EncodeAscii = .{ .gpa = gpa, .vertices = vertices, .faces = source.faces };
    harness.bench(io, "stl/encodeAscii", "-", facets, .{ .elements = facets, .unit = "facets/s" }, &encode_ascii, EncodeAscii.run);

    // Recovering the index array is what an imported mesh needs before it is a
    // surface, and it runs over three vertices per facet.
    try stl.decodeBinary(binary, out_vertices, out_faces, null);
    const soup_vertices: u64 = out_vertices.len;
    var index_soup: IndexSoup = .{ .gpa = gpa, .vertices = out_vertices, .faces = out_faces };
    harness.bench(io, "indexing/indexSoup", "-", soup_vertices, .{ .elements = soup_vertices, .unit = "verts/s" }, &index_soup, IndexSoup.run);

    const indexed = try vertex.internal.indexing.indexSoup(gpa, out_vertices, out_faces);
    defer indexed.deinit(gpa);
    std.debug.print(
        "indexing: {d} soup vertices to {d} unique ({d:.1}x)\n",
        .{
            soup_vertices,
            indexed.vertices.len,
            @as(f64, @floatFromInt(soup_vertices)) / @as(f64, @floatFromInt(indexed.vertices.len)),
        },
    );
}

const IndexSoup = struct {
    gpa: std.mem.Allocator,
    vertices: []const Vec3,
    faces: []const [3]u32,

    fn run(self: *IndexSoup) usize {
        const mesh = vertex.internal.indexing.indexSoup(self.gpa, self.vertices, self.faces) catch return 0;
        defer mesh.deinit(self.gpa);
        return mesh.vertices.len;
    }
};

const DecodeBinary = struct {
    bytes: []const u8,
    vertices: []Vec3,
    faces: [][3]u32,

    fn run(self: *DecodeBinary) usize {
        stl.decodeBinary(self.bytes, self.vertices, self.faces, null) catch return 0;
        return self.faces.len;
    }
};

const EncodeBinary = struct {
    vertices: []const Vec3,
    faces: []const [3]u32,
    out: []u8,

    fn run(self: *EncodeBinary) usize {
        stl.encodeBinary(self.vertices, self.faces, null, "bench", self.out) catch return 0;
        return self.out.len;
    }
};

const DecodeAscii = struct {
    gpa: std.mem.Allocator,
    bytes: []const u8,

    fn run(self: *DecodeAscii) usize {
        const mesh = stl.decode(self.gpa, self.bytes) catch return 0;
        defer mesh.deinit(self.gpa);
        return mesh.faces.len;
    }
};

const EncodeAscii = struct {
    gpa: std.mem.Allocator,
    vertices: []const Vec3,
    faces: []const [3]u32,

    fn run(self: *EncodeAscii) usize {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        stl.encodeAscii(self.gpa, "bench", self.vertices, self.faces, null, &out) catch return 0;
        return out.items.len;
    }
};
