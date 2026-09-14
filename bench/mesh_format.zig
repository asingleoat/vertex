//! Mesh format read and write benchmark, over a complex large enough to leave
//! cache.
//!
//! Throughput is reported in vertices per second for the whole file, since a
//! file holds simplices of four degrees and no one of them is the quantity the
//! cost scales in. Two measurements matter and are taken separately. The narrow
//! path, `f32` coordinates with a `dim` of 3, is one bulk copy per section, and
//! should run at memory bandwidth: the file's layout is this project's `Vec3`
//! and `u32` arrays exactly, so decoding copies and validates and does nothing
//! else. The wide path narrows an `f64` per coordinate and is element-wise,
//! which is the cost of the precision rather than of the format.
//!
//! The index validation that decoding performs is part of the narrow figure. It
//! is a scan over data the copy has just touched, and separating it would
//! measure a decode nobody runs.
//!
//! The two paths are closer together than the per-coordinate work suggests,
//! because a complex with all four sections populated spends most of its bytes
//! on indices rather than on positions. The sphere below is 19 per cent
//! positions, so widening them grows the file by a fifth rather than by a
//! third and moves the decode by about that much.
const std = @import("std");
const vertex = @import("vertex");
const harness = @import("lib/harness.zig");

const Vec3 = vertex.Vec3;
const mesh_format = vertex.internal.mesh_format;
const complex_mod = vertex.internal.complex;
const Complex = complex_mod.Complex;

pub fn main() !void {
    var io_state: harness.Io = .{};
    const io = io_state.get();
    const gpa = std.heap.page_allocator;

    // Subdivision 6 is 81920 facets over 40962 vertices, a few megabytes of
    // file. The edges and points are there so that every section is populated
    // and the per-section overhead is part of the measurement.
    const source = try vertex.internal.fixtures.current.icosphere(gpa, 6, 1);
    defer source.deinit(gpa);

    const vertices = try gpa.alloc(Vec3, source.positions.len());
    defer gpa.free(vertices);
    for (vertices, 0..) |*v, i| v.* = source.positions.toConst().get(@intCast(i));

    var edge_list: std.ArrayList([2]u32) = .empty;
    defer edge_list.deinit(gpa);
    try vertex.internal.geometry.current.uniqueEdges(gpa, source.faces, &edge_list);
    const edges = edge_list.items;

    const points = try gpa.alloc(u32, vertices.len);
    defer gpa.free(points);
    for (points, 0..) |*p, i| p.* = @intCast(i);

    const complex: Complex = .{
        .vertices = vertices,
        .points = points,
        .edges = edges,
        .triangles = source.faces,
        .tetrahedra = &.{},
    };

    const narrow = try gpa.alloc(u8, try mesh_format.encodedSize(complex, 0, .{}));
    defer gpa.free(narrow);
    try mesh_format.encode(complex, "", .{}, narrow);

    const wide_options: mesh_format.EncodeOptions = .{ .wide_coordinates = true };
    const wide = try gpa.alloc(u8, try mesh_format.encodedSize(complex, 0, wide_options));
    defer gpa.free(wide);
    try mesh_format.encode(complex, "", wide_options, wide);

    const n: u64 = vertices.len;
    std.debug.print(
        "mesh_format: {d} vertices, {d} points, {d} edges, {d} triangles; " ++
            "narrow {d} bytes, wide {d} bytes ({d:.1}x)\n",
        .{
            n,
            points.len,
            edges.len,
            source.faces.len,
            narrow.len,
            wide.len,
            @as(f64, @floatFromInt(wide.len)) / @as(f64, @floatFromInt(narrow.len)),
        },
    );

    const out_vertices = try gpa.alloc(Vec3, vertices.len);
    defer gpa.free(out_vertices);
    const out_points = try gpa.alloc(u32, points.len);
    defer gpa.free(out_points);
    const out_edges = try gpa.alloc([2]u32, edges.len);
    defer gpa.free(out_edges);
    const out_triangles = try gpa.alloc([3]u32, source.faces.len);
    defer gpa.free(out_triangles);
    const out: Complex = .{
        .vertices = out_vertices,
        .points = out_points,
        .edges = out_edges,
        .triangles = out_triangles,
        .tetrahedra = &.{},
    };

    const throughput: harness.Throughput = .{ .elements = n, .unit = "verts/s" };

    var decode_narrow: DecodeInto = .{ .bytes = narrow, .out = out };
    harness.bench(io, "mesh_format/decode", "-", n, throughput, &decode_narrow, DecodeInto.run);

    var decode_wide: DecodeInto = .{ .bytes = wide, .out = out };
    harness.bench(io, "mesh_format/decodeWide", "-", n, throughput, &decode_wide, DecodeInto.run);

    var encode_narrow: Encode = .{ .complex = complex, .options = .{}, .out = narrow };
    harness.bench(io, "mesh_format/encode", "-", n, throughput, &encode_narrow, Encode.run);

    var encode_wide: Encode = .{ .complex = complex, .options = wide_options, .out = wide };
    harness.bench(io, "mesh_format/encodeWide", "-", n, throughput, &encode_wide, Encode.run);

    var decode_alloc: Decode = .{ .gpa = gpa, .bytes = narrow };
    harness.bench(io, "mesh_format/decodeAlloc", "-", n, throughput, &decode_alloc, Decode.run);
}

const DecodeInto = struct {
    bytes: []const u8,
    out: Complex,

    fn run(self: *DecodeInto) usize {
        mesh_format.decodeInto(self.bytes, self.out) catch return 0;
        return self.out.vertices.len;
    }
};

const Decode = struct {
    gpa: std.mem.Allocator,
    bytes: []const u8,

    fn run(self: *Decode) usize {
        const complex = mesh_format.decode(self.gpa, self.bytes) catch return 0;
        defer complex.deinit(self.gpa);
        return complex.vertices.len;
    }
};

const Encode = struct {
    complex: Complex,
    options: mesh_format.EncodeOptions,
    out: []u8,

    fn run(self: *Encode) usize {
        mesh_format.encode(self.complex, "", self.options, self.out) catch return 0;
        return self.out.len;
    }
};
