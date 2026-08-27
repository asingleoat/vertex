//! Mesh booleans, the second seam between this project's geometry and Manifold.
//!
//! `triangulate.zig` is the other one, and `manifold_shim.cpp` holds the whole
//! of the C++ side of both. The two are separate modules because the seam is
//! drawn per operation: writing a triangulator here would leave booleans
//! untouched, and the reverse.
//!
//! Unlike triangulation, nothing is converted at this boundary. Manifold's
//! `MeshGL` holds `f32` vertex properties and `u32` triangle indices, which at
//! three properties per vertex is `Mesh` exactly, so the vertices cross as they
//! are. What the boundary does cost is two copies, one in and one out: Manifold
//! keeps its own storage and sizes a result only by computing it.
const std = @import("std");
const layout = @import("layout.zig");
const mesh_mod = @import("mesh.zig");

const Vec3 = layout.Vec3;
const Mesh = mesh_mod.Mesh;

/// Which boolean to perform, named as Manifold names them.
pub const Op = enum(c_int) {
    /// Everything inside either operand. The union.
    add = 0,
    /// Everything inside the first and outside the second. The difference,
    /// which is the one operation of the three that is not commutative.
    subtract = 1,
    /// Everything inside both. The intersection.
    intersect = 2,
};

/// Failure of a boolean.
///
/// `NotManifold` and its neighbours are Manifold's own verdict on an input or a
/// result, reported through its status rather than thrown, and they are the
/// usual failures: a boolean needs each operand to be a closed, oriented
/// surface, which a mesh straight out of `stl` import may well not be.
/// `Rejected` covers the remaining verdicts, and `Threw` an exception the shim
/// caught, which is not a route any input is known to reach.
pub const Error = error{
    NotManifold,
    NonFiniteVertex,
    ResultTooLarge,
    Rejected,
    Threw,
    OutOfMemory,
};

/// Performs one boolean and returns the resulting mesh.
///
/// Each operand must be a closed, oriented surface; `polygon.boundaryLoops`
/// reporting no loops is the test for the first half of that, and
/// `indexing.indexSoup` is what a mesh from a file needs before it can be
/// either. An operand that is not gives `error.NotManifold` rather than a
/// misleading result.
///
/// The result owns its arrays and is a closed surface in turn, so booleans
/// compose. It carries no relationship to the operands' vertex numbering:
/// Manifold rebuilds the surface, and a vertex that survives untouched may
/// still land at a different index.
///
/// Subtraction is the one operation here that depends on argument order, and
/// deliberately so: rather than nudge coincident geometry until both orders
/// agree, Manifold gives the two operands different roles and stays exact. See
/// `STYLE.md` §3a.
pub fn apply(gpa: std.mem.Allocator, a: Mesh, b: Mesh, op: Op) Error!Mesh {
    var handle: ?*anyopaque = null;
    var vertex_count: usize = 0;
    var triangle_count: usize = 0;
    var detail: c_int = 0;

    const status = vertexBooleanBegin(
        @ptrCast(a.vertices.ptr),
        a.vertices.len,
        @ptrCast(a.faces.ptr),
        a.faces.len,
        @ptrCast(b.vertices.ptr),
        b.vertices.len,
        @ptrCast(b.faces.ptr),
        b.faces.len,
        @backingInt(op),
        &handle,
        &vertex_count,
        &triangle_count,
        &detail,
    );
    switch (status) {
        ok => {},
        threw => return error.Threw,
        out_of_memory => return error.OutOfMemory,
        rejected => return switch (detail) {
            manifold_non_finite_vertex => error.NonFiniteVertex,
            manifold_not_manifold => error.NotManifold,
            manifold_result_too_large => error.ResultTooLarge,
            else => error.Rejected,
        },
        else => return error.Rejected,
    }
    defer vertexBooleanRelease(handle);

    const vertices = try gpa.alloc(Vec3, vertex_count);
    errdefer gpa.free(vertices);
    const faces = try gpa.alloc([3]u32, triangle_count);
    errdefer gpa.free(faces);
    vertexBooleanTake(handle, @ptrCast(vertices.ptr), @ptrCast(faces.ptr));
    return .{ .vertices = vertices, .faces = faces };
}

/// The status codes `manifold_shim.cpp` returns, and the `ManifoldError`
/// values it passes back as `detail`.
const ok = 0;
const threw = 1;
const out_of_memory = 2;
const rejected = 3;
const manifold_non_finite_vertex = 1;
const manifold_not_manifold = 2;
const manifold_result_too_large = 12;

extern fn vertexBooleanBegin(
    a_vertices: [*]const f32,
    a_vertex_count: usize,
    a_triangles: [*]const u32,
    a_triangle_count: usize,
    b_vertices: [*]const f32,
    b_vertex_count: usize,
    b_triangles: [*]const u32,
    b_triangle_count: usize,
    op: c_int,
    handle: *?*anyopaque,
    vertex_count: *usize,
    triangle_count: *usize,
    detail: *c_int,
) c_int;
extern fn vertexBooleanTake(handle: ?*anyopaque, vertices: [*]f32, triangles: [*]u32) void;
extern fn vertexBooleanRelease(handle: ?*anyopaque) void;

comptime {
    // The vertices cross the boundary as they are, which needs `Vec3` to be
    // three floats and nothing else.
    std.debug.assert(@sizeOf(Vec3) == 3 * @sizeOf(f32));
}

const testing = std.testing;

/// An axis-aligned box as a closed, outward-wound surface, which is the shape
/// of input a boolean requires.
fn box(gpa: std.mem.Allocator, min: Vec3, max: Vec3) !Mesh {
    const vertices = try gpa.dupe(Vec3, &.{
        .init(min.x, min.y, min.z), .init(max.x, min.y, min.z),
        .init(max.x, max.y, min.z), .init(min.x, max.y, min.z),
        .init(min.x, min.y, max.z), .init(max.x, min.y, max.z),
        .init(max.x, max.y, max.z), .init(min.x, max.y, max.z),
    });
    errdefer gpa.free(vertices);
    const faces = try gpa.dupe([3]u32, &.{
        .{ 0, 3, 2 }, .{ 0, 2, 1 }, // -z
        .{ 4, 5, 6 }, .{ 4, 6, 7 }, // +z
        .{ 0, 1, 5 }, .{ 0, 5, 4 }, // -y
        .{ 2, 3, 7 }, .{ 2, 7, 6 }, // +y
        .{ 0, 4, 7 }, .{ 0, 7, 3 }, // -x
        .{ 1, 2, 6 }, .{ 1, 6, 5 }, // +x
    });
    return .{ .vertices = vertices, .faces = faces };
}

/// The volume a closed mesh encloses, positive when its faces wind outward.
fn volume(m: Mesh) f64 {
    var total: f64 = 0;
    for (m.faces) |face| {
        const a = m.vertices[face[0]];
        const b = m.vertices[face[1]];
        const c = m.vertices[face[2]];
        total += @as(f64, a.dot(b.cross(c))) / 6;
    }
    return total;
}

test "the test box is closed and encloses its volume" {
    const polygon = @import("polygon.zig");
    const unit = try box(testing.allocator, .init(0, 0, 0), .init(1, 2, 4));
    defer unit.deinit(testing.allocator);

    const loops = try polygon.boundaryLoops(testing.allocator, @intCast(unit.vertices.len), unit.faces);
    defer loops.deinit(testing.allocator);
    try testing.expectEqual(0, loops.count());
    try testing.expectApproxEqRel(8.0, volume(unit), 1e-6);
}

test "the three operations agree with the volumes they should produce" {
    // Two unit cubes overlapping in an eighth of their volume.
    const a = try box(testing.allocator, .init(0, 0, 0), .init(1, 1, 1));
    defer a.deinit(testing.allocator);
    const b = try box(testing.allocator, .init(0.5, 0.5, 0.5), .init(1.5, 1.5, 1.5));
    defer b.deinit(testing.allocator);

    const overlap = 0.125;
    const cases = [_]struct { op: Op, want: f64 }{
        .{ .op = .add, .want = 2 - overlap },
        .{ .op = .subtract, .want = 1 - overlap },
        .{ .op = .intersect, .want = overlap },
    };
    for (cases) |case| {
        const result = try apply(testing.allocator, a, b, case.op);
        defer result.deinit(testing.allocator);
        try testing.expectApproxEqRel(case.want, volume(result), 1e-5);
    }
}

test "a result is closed, so booleans compose" {
    const polygon = @import("polygon.zig");
    const a = try box(testing.allocator, .init(0, 0, 0), .init(2, 2, 2));
    defer a.deinit(testing.allocator);
    const b = try box(testing.allocator, .init(0.5, 0.5, -1), .init(1.5, 1.5, 3));
    defer b.deinit(testing.allocator);

    // A block with a square hole bored through it. The bore is 1 by 1 by 4, of
    // which the 1 by 1 by 2 inside the block is what it removes.
    const bored = try apply(testing.allocator, a, b, .subtract);
    defer bored.deinit(testing.allocator);
    try testing.expectApproxEqRel(8.0 - 2.0, volume(bored), 1e-5);

    const loops = try polygon.boundaryLoops(testing.allocator, @intCast(bored.vertices.len), bored.faces);
    defer loops.deinit(testing.allocator);
    try testing.expectEqual(0, loops.count());

    // And it is still an operand.
    const again = try apply(testing.allocator, bored, b, .subtract);
    defer again.deinit(testing.allocator);
    try testing.expectApproxEqRel(volume(bored), volume(again), 1e-5);
}

test "subtraction depends on the order of its operands" {
    const a = try box(testing.allocator, .init(0, 0, 0), .init(1, 1, 1));
    defer a.deinit(testing.allocator);
    const b = try box(testing.allocator, .init(0.5, 0, 0), .init(2, 1, 1));
    defer b.deinit(testing.allocator);

    const forward = try apply(testing.allocator, a, b, .subtract);
    defer forward.deinit(testing.allocator);
    const backward = try apply(testing.allocator, b, a, .subtract);
    defer backward.deinit(testing.allocator);
    try testing.expectApproxEqRel(0.5, volume(forward), 1e-5);
    try testing.expectApproxEqRel(1.0, volume(backward), 1e-5);
}

test "disjoint operands are handled by every operation" {
    const a = try box(testing.allocator, .init(0, 0, 0), .init(1, 1, 1));
    defer a.deinit(testing.allocator);
    const b = try box(testing.allocator, .init(5, 5, 5), .init(6, 6, 6));
    defer b.deinit(testing.allocator);

    const joined = try apply(testing.allocator, a, b, .add);
    defer joined.deinit(testing.allocator);
    try testing.expectApproxEqRel(2.0, volume(joined), 1e-5);

    const cut = try apply(testing.allocator, a, b, .subtract);
    defer cut.deinit(testing.allocator);
    try testing.expectApproxEqRel(1.0, volume(cut), 1e-5);

    const shared = try apply(testing.allocator, a, b, .intersect);
    defer shared.deinit(testing.allocator);
    try testing.expectEqual(0, shared.faces.len);
    try testing.expectEqual(0, shared.vertices.len);
}

test "an open operand is reported rather than guessed at" {
    const a = try box(testing.allocator, .init(0, 0, 0), .init(1, 1, 1));
    defer a.deinit(testing.allocator);

    // The same box with one face missing, which is a surface with a hole in it
    // and has no inside for a boolean to reason about. The full mesh is what
    // owns the arrays; the open one is a view onto them.
    const full = try box(testing.allocator, .init(0, 0, 0), .init(1, 1, 1));
    defer full.deinit(testing.allocator);
    const open: Mesh = .{
        .vertices = full.vertices,
        .faces = full.faces[0 .. full.faces.len - 1],
    };

    try testing.expectError(error.NotManifold, apply(testing.allocator, a, open, .add));
    try testing.expectError(error.NotManifold, apply(testing.allocator, open, a, .subtract));
}

test "a non-finite vertex is reported" {
    const a = try box(testing.allocator, .init(0, 0, 0), .init(1, 1, 1));
    defer a.deinit(testing.allocator);
    const broken = try box(testing.allocator, .init(0, 0, 0), .init(1, 1, 1));
    defer broken.deinit(testing.allocator);
    broken.vertices[0] = .init(std.math.nan(f32), 0, 0);

    try testing.expectError(error.NonFiniteVertex, apply(testing.allocator, a, broken, .add));
}

fn booleanAllocationCase(gpa: std.mem.Allocator) !void {
    const a = try box(gpa, .init(0, 0, 0), .init(1, 1, 1));
    defer a.deinit(gpa);
    const b = try box(gpa, .init(0.5, 0.5, 0.5), .init(1.5, 1.5, 1.5));
    defer b.deinit(gpa);
    const result = try apply(gpa, a, b, .add);
    defer result.deinit(gpa);
    if (result.faces.len == 0) return error.TestUnexpectedResult;
}

test "apply handles every allocation failure it can see" {
    // Manifold's own allocations are not reachable from here; see the module
    // comment on triangulate.zig.
    try testing.checkAllAllocationFailures(testing.allocator, booleanAllocationCase, .{});
}
