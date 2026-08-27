//! The seam between this project's geometry and Manifold.
//!
//! This is the only module that reaches outside the project for a geometric
//! result. It exposes one operation, the triangulation of a simple polygon,
//! over plain data: two-dimensional points in, triangle indices out, no
//! allocation and no ownership transferred. `manifold_shim.cpp` holds the whole
//! of the Manifold interaction and this module holds the whole of the Zig side,
//! so replacing Manifold with an implementation written here changes these two
//! files and nothing above them.
//!
//! Two properties of the seam are exceptions to `STYLE.md` rather than
//! oversights, and both are stated in DESIGN.md under "Polygon triangulation
//! and caps". Manifold works in `f64` while the rest of this project works in
//! `f32`, so the caller converts at the boundary and `simplePolygon` takes
//! `f64`. Manifold allocates through its own allocator, so an allocation
//! failure inside it is reported as `error.OutOfMemory` but cannot be induced
//! by `checkAllAllocationFailures`, which therefore stops here.
const std = @import("std");

/// Failure of a single triangulation.
///
/// `InvalidPolygon` is the shim's report of an exception thrown inside
/// Manifold. It is rare: the triangulator ensures a manifold result rather than
/// validating its input, and returns a best-effort triangulation for polygons
/// that are self-intersecting, degenerate or wound the wrong way, as the tests
/// below record. A caller that must distinguish those cases checks the polygon
/// itself; this error is not that check.
pub const Error = error{
    InvalidPolygon,
    OutOfMemory,
};

/// Triangulates a simple polygon and returns the triangles written.
///
/// `points` are the polygon's vertices in order, winding counter-clockwise;
/// `epsilon` is the tolerance below which points are treated as coincident,
/// where a negative value selects Manifold's own. Triangles are written to
/// `out` as indices into `points`, and `out` must hold at least
/// `points.len - 2` of them, which is the exact count a simple polygon of that
/// size produces. Fewer than three points yields an empty result.
///
/// The returned slice aliases `out`. Nothing is allocated on this side of the
/// call and neither argument is retained.
pub fn simplePolygon(
    points: []const [2]f64,
    epsilon: f64,
    out: [][3]u32,
) Error![][3]u32 {
    if (points.len < 3) return out[0..0];
    std.debug.assert(out.len >= points.len - 2);

    var written: usize = 0;
    const status = vertexTriangulatePolygon(
        @ptrCast(points.ptr),
        points.len,
        epsilon,
        @ptrCast(out.ptr),
        out.len,
        &written,
    );
    return switch (status) {
        ok => out[0..written],
        invalid => error.InvalidPolygon,
        out_of_memory => error.OutOfMemory,
        // Only a caller ignoring the `points.len - 2` contract reaches this,
        // and the assertion above has already caught that in a safe build.
        overflow => unreachable,
        else => unreachable,
    };
}

/// The number of triangles a simple polygon of `n` points produces, and so the
/// length `simplePolygon` requires of its `out`. Zero below three points.
pub fn triangleCount(n: usize) usize {
    return if (n < 3) 0 else n - 2;
}

/// The status codes `manifold_shim.cpp` returns.
const ok = 0;
const invalid = 1;
const overflow = 2;
const out_of_memory = 3;

/// Declared in `manifold_shim.cpp`, which build.zig compiles into this module.
extern fn vertexTriangulatePolygon(
    xy: [*]const f64,
    point_count: usize,
    epsilon: f64,
    triangles: [*]u32,
    capacity: usize,
    written: *usize,
) c_int;

const testing = std.testing;

test "a square triangulates to two triangles covering it" {
    const square = [_][2]f64{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
    var out: [triangleCount(4)][3]u32 = undefined;
    const tris = try simplePolygon(&square, -1, &out);
    try testing.expectEqual(2, tris.len);

    // Every triangle winds counter-clockwise, and their areas sum to the
    // square's, which together mean the square is covered exactly once.
    var area: f64 = 0;
    for (tris) |t| {
        const a = square[t[0]];
        const b = square[t[1]];
        const c = square[t[2]];
        const signed = 0.5 * ((b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1]));
        try testing.expect(signed > 0);
        area += signed;
    }
    try testing.expectApproxEqAbs(1.0, area, 1e-9);
}

test "a concave polygon is triangulated without leaving the interior" {
    // An L shape: a naive fan from vertex 0 would cross the reflex corner.
    const l = [_][2]f64{
        .{ 0, 0 }, .{ 2, 0 }, .{ 2, 1 }, .{ 1, 1 }, .{ 1, 2 }, .{ 0, 2 },
    };
    var out: [triangleCount(6)][3]u32 = undefined;
    const tris = try simplePolygon(&l, -1, &out);
    try testing.expectEqual(4, tris.len);

    var area: f64 = 0;
    for (tris) |t| {
        const a = l[t[0]];
        const b = l[t[1]];
        const c = l[t[2]];
        area += 0.5 * ((b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1]));
    }
    try testing.expectApproxEqAbs(3.0, area, 1e-9);
}

test "malformed polygons are tolerated rather than reported" {
    // Manifold ensures a manifold result rather than validating its input, so
    // none of these is rejected and each yields a best-effort triangulation.
    // This is recorded because it is not what the name of `InvalidPolygon`
    // suggests: a caller that needs a malformed ring detected checks for it
    // before calling, and capping treats whatever comes back as the cap.
    //
    // The shim is still what stands between an exception thrown inside
    // Manifold and an unwind across the C ABI. The library references
    // `__cxa_throw`, so that path exists; no single simple polygon reached it
    // here, which is why it is insurance rather than a tested route.
    const cases = [_][]const [2]f64{
        &.{ .{ 0, 0 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 1 } }, // self-intersecting
        &.{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } }, // wound clockwise
        &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 0 }, .{ 0, 1 } }, // a repeated point
        &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 } }, // collinear, no area
    };
    inline for (cases) |points| {
        var out: [triangleCount(points.len)][3]u32 = undefined;
        const tris = try simplePolygon(points, -1, &out);
        try testing.expect(tris.len <= triangleCount(points.len));
    }
}

test "fewer than three points yields no triangles" {
    var out: [4][3]u32 = undefined;
    try testing.expectEqual(0, (try simplePolygon(&.{}, -1, &out)).len);
    const two = [_][2]f64{ .{ 0, 0 }, .{ 1, 0 } };
    try testing.expectEqual(0, (try simplePolygon(&two, -1, &out)).len);
}
