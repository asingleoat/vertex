//! Recovering an index array from a triangle soup, by exact equality.
//!
//! A soup repeats a vertex once per face that uses it. Formats that store one,
//! STL among them, write the same bits every time: the coordinates come from
//! one value in the exporter's mesh and are written unchanged for each facet,
//! so the copies are identical to the last bit and matching them exactly
//! recovers the connectivity the exporter had. No tolerance is involved and
//! none should be; see `STYLE.md` §3a.
//!
//! Welding is the different operation of merging vertices that are merely
//! close, which needs a tolerance, a spatial structure, and a decision about
//! what to do with the normals it changes. Nothing here approximates it, and a
//! soup whose copies are not bit-identical, as one produced by recomputing
//! coordinates per face would be, is left as it is rather than half-merged.
//!
//! The one canonicalization made is that negative zero is matched with positive
//! zero and stored as positive. They are the same point, so this introduces no
//! tolerance, and without it a file that wrote both for one corner would come
//! back with a crack along it.
const std = @import("std");
const layout = @import("layout.zig");

const Vec3 = layout.Vec3;

/// The mesh type `indexSoup` returns. Its `vertices` hold exactly the points
/// its `faces` name, in order of first appearance.
pub const Mesh = @import("mesh.zig").Mesh;

/// Converts a triangle soup into an indexed mesh, collapsing bit-identical
/// vertices and discarding degenerate faces.
///
/// A face is degenerate when two of its three vertices are the same point. Such
/// a face encloses no area: it draws nothing, adds nothing to a volume, and
/// bounds nothing, while every operation that walks connectivity has to
/// special-case it. Exported STL carries them in quantity, so they are dropped
/// here rather than left for each consumer to notice. The test is exact — two
/// vertices are the same point or they are not — so no tolerance enters, and a
/// face whose three vertices are distinct but collinear is kept, that being a
/// judgement no exact predicate can make.
///
/// The result holds only the vertices its surviving faces name; a vertex that
/// nothing references, including one that only a dropped face did, does not
/// appear. `faces` may name any vertex in `vertices`, the soup's consecutive
/// triples being the usual case but not a requirement.
pub fn indexSoup(
    gpa: std.mem.Allocator,
    vertices: []const Vec3,
    faces: []const [3]u32,
) std.mem.Allocator.Error!Mesh {
    // Each surviving face contributes at most three new vertices, and no more
    // than the input held in any case.
    const ceiling = @min(vertices.len, 3 * faces.len);
    var unique = try gpa.alloc(Vec3, ceiling);
    errdefer gpa.free(unique);
    var out_faces = try gpa.alloc([3]u32, faces.len);
    errdefer gpa.free(out_faces);

    var interner = try Interner.init(gpa, ceiling, unique);
    defer interner.deinit(gpa);

    var written: usize = 0;
    for (faces) |face| {
        const a = canonical(vertices[face[0]]);
        const b = canonical(vertices[face[1]]);
        const c = canonical(vertices[face[2]]);
        if (identical(a, b) or identical(b, c) or identical(c, a)) continue;
        out_faces[written] = .{ interner.intern(a), interner.intern(b), interner.intern(c) };
        written += 1;
    }

    // Shrinking in place is the usual outcome, which leaves both arrays where
    // they were written rather than copying them again.
    unique = try gpa.realloc(unique, interner.count);
    out_faces = try gpa.realloc(out_faces, written);
    return .{ .vertices = unique, .faces = out_faces };
}

/// Collapses bit-identical vertices, writing the survivors and the mapping that
/// reaches them, without regard to any faces.
///
/// `unique` and `remap` must both hold `vertices.len` entries, which is the
/// worst case of every vertex being distinct. The survivors are written to the
/// front of `unique` in order of first appearance, `remap[i]` is where vertex
/// `i` went, and the number of survivors is returned. This is the operation
/// beneath `indexSoup`, for a caller that wants the mapping rather than a mesh.
pub fn exactIndex(
    gpa: std.mem.Allocator,
    vertices: []const Vec3,
    unique: []Vec3,
    remap: []u32,
) std.mem.Allocator.Error!u32 {
    std.debug.assert(unique.len >= vertices.len);
    std.debug.assert(remap.len >= vertices.len);
    if (vertices.len == 0) return 0;

    var interner = try Interner.init(gpa, vertices.len, unique);
    defer interner.deinit(gpa);
    for (vertices, 0..) |v, i| remap[i] = interner.intern(canonical(v));
    return interner.count;
}

/// An open-addressed table mapping a vertex to its position in a dense array.
/// ---
/// Slots hold dense indices and are probed linearly. The capacity is twice the
/// most vertices that can arrive, rounded up to a power of two, so the load
/// factor stays at or below one half and probing stays short. The dense array
/// belongs to the caller; the table writes each new vertex into it.
const Interner = struct {
    slots: []u32,
    unique: []Vec3,
    count: u32 = 0,

    const empty_slot = std.math.maxInt(u32);

    fn init(gpa: std.mem.Allocator, ceiling: usize, unique: []Vec3) std.mem.Allocator.Error!Interner {
        const capacity = std.math.ceilPowerOfTwoAssert(usize, @max(16, ceiling * 2));
        const slots = try gpa.alloc(u32, capacity);
        @memset(slots, empty_slot);
        return .{ .slots = slots, .unique = unique };
    }

    fn deinit(self: *Interner, gpa: std.mem.Allocator) void {
        gpa.free(self.slots);
        self.* = undefined;
    }

    /// Returns the dense index of `v`, adding it if this is its first
    /// appearance. `v` must have been through `canonical`.
    fn intern(self: *Interner, v: Vec3) u32 {
        const mask = self.slots.len - 1;
        var slot = hash(v) & mask;
        while (true) {
            const occupant = self.slots[slot];
            if (occupant == empty_slot) {
                self.slots[slot] = self.count;
                self.unique[self.count] = v;
                self.count += 1;
                return self.count - 1;
            }
            if (identical(self.unique[occupant], v)) return occupant;
            slot = (slot + 1) & mask;
        }
    }
};

/// Replaces negative zero with positive zero, leaving every other value alone.
/// `-0.0 == 0.0` is true, so the comparison costs one test per component and
/// the two spellings of the origin hash and compare alike.
inline fn canonical(v: Vec3) Vec3 {
    return .{
        .x = if (v.x == 0) 0 else v.x,
        .y = if (v.y == 0) 0 else v.y,
        .z = if (v.z == 0) 0 else v.z,
    };
}

/// Compares two vertices bit for bit rather than numerically, so that a NaN
/// matches the identical NaN. Only vertices that `canonical` has passed through
/// reach this.
inline fn identical(a: Vec3, b: Vec3) bool {
    const ax: u32 = @bitCast(a.x);
    const ay: u32 = @bitCast(a.y);
    const az: u32 = @bitCast(a.z);
    const bx: u32 = @bitCast(b.x);
    const by: u32 = @bitCast(b.y);
    const bz: u32 = @bitCast(b.z);
    return ax == bx and ay == by and az == bz;
}

/// Mixes the three component bit patterns into a table index.
///
/// Multiply-xor rather than a byte-wise hash: the input is three known words,
/// so there is nothing to loop over, and the final avalanche spreads the low
/// bits that a coordinate grid would otherwise leave equal.
inline fn hash(v: Vec3) usize {
    const x: u64 = @as(u32, @bitCast(v.x));
    const y: u64 = @as(u32, @bitCast(v.y));
    const z: u64 = @as(u32, @bitCast(v.z));
    var h: u64 = x *% 0x9E3779B97F4A7C15;
    h ^= y *% 0xC2B2AE3D27D4EB4F;
    h ^= z *% 0x165667B19E3779F9;
    h ^= h >> 29;
    h *%= 0xBF58476D1CE4E5B9;
    h ^= h >> 32;
    return @intCast(h & std.math.maxInt(usize));
}

const testing = std.testing;

/// A square as two triangles in soup form: six vertices, of which the two along
/// the shared diagonal are written twice.
const soup_vertices = [_]Vec3{
    .init(0, 0, 0), .init(1, 0, 0), .init(1, 1, 0),
    .init(0, 0, 0), .init(1, 1, 0), .init(0, 1, 0),
};
const soup_faces = [_][3]u32{ .{ 0, 1, 2 }, .{ 3, 4, 5 } };

test "a soup collapses to its distinct vertices" {
    const mesh = try indexSoup(testing.allocator, &soup_vertices, &soup_faces);
    defer mesh.deinit(testing.allocator);

    try testing.expectEqual(4, mesh.vertices.len);
    try testing.expectEqual(2, mesh.faces.len);
    // Survivors keep the order of first appearance.
    try testing.expect(mesh.vertices[0].eql(.init(0, 0, 0)));
    try testing.expect(mesh.vertices[1].eql(.init(1, 0, 0)));
    try testing.expect(mesh.vertices[2].eql(.init(1, 1, 0)));
    try testing.expect(mesh.vertices[3].eql(.init(0, 1, 0)));
    try testing.expectEqual([3]u32{ 0, 1, 2 }, mesh.faces[0]);
    try testing.expectEqual([3]u32{ 0, 2, 3 }, mesh.faces[1]);
}

test "indexing gives a soup the connectivity the format threw away" {
    const polygon = @import("polygon.zig");
    // Before: the two triangles share a diagonal geometrically but no index, so
    // they are two islands. Every edge belongs to one face and the boundary is
    // two loops of three, which is the square's own outline nowhere in sight.
    {
        const loops = try polygon.boundaryLoops(testing.allocator, soup_vertices.len, &soup_faces);
        defer loops.deinit(testing.allocator);
        try testing.expectEqual(2, loops.count());
        try testing.expectEqual(3, loops.get(0).len);
        try testing.expectEqual(3, loops.get(1).len);
    }

    // After: one loop of four, the outline of the square.

    const mesh = try indexSoup(testing.allocator, &soup_vertices, &soup_faces);
    defer mesh.deinit(testing.allocator);
    const loops = try polygon.boundaryLoops(
        testing.allocator,
        @intCast(mesh.vertices.len),
        mesh.faces,
    );
    defer loops.deinit(testing.allocator);
    try testing.expectEqual(1, loops.count());
    try testing.expectEqual(4, loops.get(0).len);
}

test "coordinates that differ in the last bit are left alone" {
    // This is the line between exact indexing and welding. These two vertices
    // are as close as two distinct f32 can be and are still two vertices, so
    // the triangle they belong to survives rather than collapsing.
    const nudged = std.math.nextAfter(f32, 1.0, 2.0);
    const vertices = [_]Vec3{ .init(1, 0, 0), .init(nudged, 0, 0), .init(0, 1, 0) };
    const faces = [_][3]u32{.{ 0, 1, 2 }};
    const mesh = try indexSoup(testing.allocator, &vertices, &faces);
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(3, mesh.vertices.len);
    try testing.expectEqual(1, mesh.faces.len);
}

test "the two spellings of zero are the same point" {
    const vertices = [_]Vec3{ .init(0, -0.0, 0), .init(-0.0, 0, -0.0), .init(1, 0, 0) };
    var unique: [3]Vec3 = undefined;
    var remap: [3]u32 = undefined;
    const count = try exactIndex(testing.allocator, &vertices, &unique, &remap);
    try testing.expectEqual(2, count);
    try testing.expectEqual(remap[0], remap[1]);
    // The survivor is stored with positive zero throughout.
    try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(unique[0].y)));
    try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(unique[0].z)));
}

test "degenerate faces are dropped, and vertices only they held with them" {
    // The quad's two triangles, plus a face collapsed onto vertex 4, which
    // nothing else names. Both the face and that vertex should be gone.
    const vertices = [_]Vec3{
        .init(0, 0, 0), .init(1, 0, 0), .init(1, 1, 0),
        .init(0, 1, 0), .init(5, 5, 5),
    };
    const faces = [_][3]u32{ .{ 0, 1, 2 }, .{ 0, 2, 3 }, .{ 4, 4, 0 } };
    const mesh = try indexSoup(testing.allocator, &vertices, &faces);
    defer mesh.deinit(testing.allocator);

    try testing.expectEqual(2, mesh.faces.len);
    try testing.expectEqual(faces.len - 1, mesh.faces.len);
    try testing.expectEqual(4, mesh.vertices.len);
    for (mesh.vertices) |v| try testing.expect(!v.eql(.init(5, 5, 5)));
}

test "a face degenerate only after indexing is dropped too" {
    // Its three indices are distinct, so nothing in the soup marks it; two of
    // them name the same point, which only exact matching reveals.
    const vertices = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 0, 0) };
    const faces = [_][3]u32{.{ 0, 1, 2 }};
    const mesh = try indexSoup(testing.allocator, &vertices, &faces);
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(0, mesh.faces.len);
    try testing.expectEqual(0, mesh.vertices.len);
}

test "a face with three distinct but collinear vertices is kept" {
    // It has no area either, but saying so needs a predicate on coordinates
    // that no exact test provides; see STYLE.md 3a.
    const vertices = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(2, 0, 0) };
    const faces = [_][3]u32{.{ 0, 1, 2 }};
    const mesh = try indexSoup(testing.allocator, &vertices, &faces);
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(faces.len, mesh.faces.len);
}

test "a mesh with nothing to collapse is unchanged" {
    const vertices = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0) };
    const faces = [_][3]u32{.{ 0, 1, 2 }};
    const mesh = try indexSoup(testing.allocator, &vertices, &faces);
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(3, mesh.vertices.len);
    try testing.expectEqual([3]u32{ 0, 1, 2 }, mesh.faces[0]);
}

test "empty input" {
    const mesh = try indexSoup(testing.allocator, &.{}, &.{});
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(0, mesh.vertices.len);
    try testing.expectEqual(0, mesh.faces.len);
}

test "the probe table survives many collisions" {
    // A grid of coordinates whose low bits repeat, which a hash without a final
    // avalanche would pile into a few slots.
    const side = 40;
    var vertices: [side * side]Vec3 = undefined;
    for (0..side) |y| for (0..side) |x| {
        vertices[y * side + x] = .init(@floatFromInt(x), @floatFromInt(y), 0);
    };
    const doubled = try testing.allocator.alloc(Vec3, vertices.len * 2);
    defer testing.allocator.free(doubled);
    @memcpy(doubled[0..vertices.len], &vertices);
    @memcpy(doubled[vertices.len..], &vertices);

    const remap = try testing.allocator.alloc(u32, doubled.len);
    defer testing.allocator.free(remap);
    const unique = try testing.allocator.alloc(Vec3, doubled.len);
    defer testing.allocator.free(unique);
    const count = try exactIndex(testing.allocator, doubled, unique, remap);
    try testing.expectEqual(side * side, count);
    // The second copy maps onto the first, vertex for vertex.
    for (0..vertices.len) |i| try testing.expectEqual(remap[i], remap[i + vertices.len]);
}

fn indexSoupAllocationCase(gpa: std.mem.Allocator) !void {
    const mesh = try indexSoup(gpa, &soup_vertices, &soup_faces);
    defer mesh.deinit(gpa);
    if (mesh.vertices.len != 4) return error.TestUnexpectedResult;
}

test "indexSoup handles every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, indexSoupAllocationCase, .{});
}
