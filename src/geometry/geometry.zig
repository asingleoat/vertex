//! Geometry kernels: the computations over a vertex stream and its topology
//! that the viewer and sketches share.
//!
//! Each kernel takes a `Positions` view and, where it needs connectivity, a
//! slice of triangles, and writes its result into a buffer the caller provides.
//! None of them allocate, with the single exception of `uniqueEdges`, which
//! takes an explicit allocator for the list it fills. They hold no state
//! between calls and depend on nothing outside their arguments, so they can be
//! called from anywhere and tested without a viewer.
//!
//! The kernels are parameterized by vertex layout and instantiated once as
//! `current` for the build-selected one. Ordinary code calls
//! `geometry.current.bounds(...)` and never names a layout.
const std = @import("std");
const layout = @import("layout.zig");

const Vec3 = layout.Vec3;

/// Returns the geometry kernels specialized for vertex layout `l`.
///
/// Ordinary code uses `current`, the instantiation for this build. This
/// function exists so that `bench/` can run all three layouts against the same
/// inputs, which is how a layout is chosen. A kernel may switch on `l` at
/// compile time to take a planar fast path, with the accessor path as the
/// always-correct fallback.
pub fn Geometry(comptime l: layout.Layout) type {
    return struct {
        /// The vertex stream type these kernels accept, which is
        /// `PositionsOf(l)`. `P.Const` is the read-only view they take.
        pub const P = layout.PositionsOf(l);

        /// An axis-aligned bounding box, given by its minimum and maximum
        /// corners.
        /// ---
        /// Returned by `bounds` and used to frame a scene, normalise a model to
        /// a known size, or size a spatial structure. It is a value that owns
        /// nothing; `center`, `extent`, `radius` and `isEmpty` derive the
        /// quantities usually wanted from it.
        pub const Aabb = extern struct {
            min: Vec3,
            max: Vec3,

            /// Bounds containing no points, with the corners inverted so that
            /// expanding them by any point yields that point. This is the identity
            /// for accumulation and what `bounds` returns for an empty stream.
            pub const empty: Aabb = .{
                .min = .init(std.math.inf(f32), std.math.inf(f32), std.math.inf(f32)),
                .max = .init(-std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32)),
            };

            /// Returns the midpoint of these bounds without allocating.
            pub fn center(a: Aabb) Vec3 {
                return a.min.add(a.max).scale(0.5);
            }

            /// Returns the full side lengths of these bounds without allocating.
            pub fn extent(a: Aabb) Vec3 {
                return a.max.sub(a.min);
            }

            /// Returns the half-diagonal length of these bounds without allocating.
            pub fn radius(a: Aabb) f32 {
                return a.extent().scale(0.5).length();
            }

            /// Reports whether these bounds contain no points; never allocates.
            pub fn isEmpty(a: Aabb) bool {
                return a.min.x > a.max.x or a.min.y > a.max.y or a.min.z > a.max.z;
            }
        };

        /// Computes the axis-aligned bounding box of a vertex stream.
        ///
        /// Reads `positions` once and returns the bounds by value, or
        /// `Aabb.empty` when the stream has no vertices. Allocates nothing.
        /// In the `.soa` layout it takes the planar component runs directly.
        pub fn bounds(positions: P.Const) Aabb {
            if (positions.len() == 0) return .empty;

            switch (l) {
                .soa => {
                    const xs = positions.xs();
                    const ys = positions.ys();
                    const zs = positions.zs();
                    var min_x = std.math.inf(f32);
                    var min_y = std.math.inf(f32);
                    var min_z = std.math.inf(f32);
                    var max_x = -std.math.inf(f32);
                    var max_y = -std.math.inf(f32);
                    var max_z = -std.math.inf(f32);
                    for (xs) |x| {
                        min_x = @min(min_x, x);
                        max_x = @max(max_x, x);
                    }
                    for (ys) |y| {
                        min_y = @min(min_y, y);
                        max_y = @max(max_y, y);
                    }
                    for (zs) |z| {
                        min_z = @min(min_z, z);
                        max_z = @max(max_z, z);
                    }
                    return .{
                        .min = .init(min_x, min_y, min_z),
                        .max = .init(max_x, max_y, max_z),
                    };
                },
                .aos3, .aos4 => {
                    var result: Aabb = .empty;
                    var i: u32 = 0;
                    while (i < positions.len()) : (i += 1) {
                        const p = positions.get(i);
                        result.min = result.min.min(p);
                        result.max = result.max.max(p);
                    }
                    return result;
                },
            }
        }

        /// Computes one unit normal per triangle, the geometric normal of its
        /// plane.
        ///
        /// `out` is caller-owned and must have exactly `faces.len` elements;
        /// this function allocates nothing. The direction follows the winding
        /// order, counter-clockwise being front-facing, so reversing a triangle
        /// reverses its normal. A degenerate triangle, whose vertices are
        /// collinear or coincident, yields a zero vector rather than a NaN.
        ///
        /// Use these for flat shading, for face-target vector quantities, and
        /// wherever a per-triangle direction is wanted. For shading that should
        /// look smooth across shared edges, use `vertexNormals` instead.
        pub fn faceNormals(positions: P.Const, faces: []const [3]u32, out: []Vec3) void {
            std.debug.assert(out.len == faces.len);
            const vertex_count = positions.len();
            for (faces, out) |face, *normal| {
                std.debug.assert(face[0] < vertex_count);
                std.debug.assert(face[1] < vertex_count);
                std.debug.assert(face[2] < vertex_count);
                const a = positions.get(face[0]);
                const b = positions.get(face[1]);
                const c = positions.get(face[2]);
                normal.* = b.sub(a).cross(c.sub(a)).normalize();
            }
        }

        /// Computes one unit normal per vertex by summing the normals of the
        /// incident triangles, weighted by their area.
        ///
        /// `out` is caller-owned, must have exactly `positions.len()` elements
        /// and is zero-filled before accumulation; this function allocates
        /// nothing. The weighting is implicit: the cross product of two triangle
        /// edges has a magnitude proportional to that triangle's area, so
        /// summing the unnormalized cross products weights each contribution
        /// correctly, and the sums are normalized at the end.
        ///
        /// A vertex whose incident faces cancel out, or one with no incident
        /// faces at all, yields a zero vector. Use these for smooth shading and
        /// as the direction field for displacing a surface along its normals.
        pub fn vertexNormals(positions: P.Const, faces: []const [3]u32, out: []Vec3) void {
            std.debug.assert(out.len == positions.len());
            @memset(out, Vec3.zero);

            const vertex_count = positions.len();
            for (faces) |face| {
                std.debug.assert(face[0] < vertex_count);
                std.debug.assert(face[1] < vertex_count);
                std.debug.assert(face[2] < vertex_count);
                const a = positions.get(face[0]);
                const b = positions.get(face[1]);
                const c = positions.get(face[2]);
                const weighted = b.sub(a).cross(c.sub(a));
                out[face[0]] = out[face[0]].add(weighted);
                out[face[1]] = out[face[1]].add(weighted);
                out[face[2]] = out[face[2]].add(weighted);
            }
            for (out) |*normal| normal.* = normal.normalize();
        }

        /// Collects the unique undirected edges of a triangle mesh into `out`.
        ///
        /// `out` is a caller-owned list that this function clears and refills;
        /// it keeps whatever capacity the list already has and makes exactly one
        /// capacity request through `gpa`, sized for three edges per face, which
        /// is why repeated calls on a warm list do not allocate at all. The
        /// caller continues to own and eventually free the list.
        ///
        /// Each edge is canonical, meaning its lower vertex index comes first,
        /// and the result is sorted and deduplicated, so an edge shared by two
        /// triangles appears once. That is what a wireframe needs, and what any
        /// traversal over a mesh's connectivity graph needs.
        ///
        /// The cost is dominated by sorting three entries per face.
        pub fn uniqueEdges(
            gpa: std.mem.Allocator,
            faces: []const [3]u32,
            out: *std.ArrayList([2]u32),
        ) std.mem.Allocator.Error!void {
            out.clearRetainingCapacity();
            try out.ensureTotalCapacity(gpa, faces.len * 3);
            for (faces) |face| {
                out.appendAssumeCapacity(canonicalEdge(face[0], face[1]));
                out.appendAssumeCapacity(canonicalEdge(face[1], face[2]));
                out.appendAssumeCapacity(canonicalEdge(face[2], face[0]));
            }

            std.mem.sort([2]u32, out.items, {}, edgeLessThan);
            if (out.items.len == 0) return;

            var write: usize = 1;
            for (out.items[1..]) |edge| {
                if (!edgeEqual(out.items[write - 1], edge)) {
                    out.items[write] = edge;
                    write += 1;
                }
            }
            out.items = out.items[0..write];
        }

        fn canonicalEdge(a: u32, b: u32) [2]u32 {
            return if (a < b) .{ a, b } else .{ b, a };
        }

        fn edgeLessThan(_: void, a: [2]u32, b: [2]u32) bool {
            return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
        }

        fn edgeEqual(a: [2]u32, b: [2]u32) bool {
            return a[0] == b[0] and a[1] == b[1];
        }
    };
}

/// The geometry kernels for the layout this build selected. This is the
/// instantiation ordinary code calls, as `geometry.current.bounds(...)`.
pub const current = Geometry(layout.layout);

const testing = std.testing;
const all_layouts = [_]layout.Layout{ .aos3, .aos4, .soa };

fn UniqueEdgesAllocationCase(comptime l: layout.Layout) type {
    return struct {
        fn run(gpa: std.mem.Allocator) !void {
            const G = Geometry(l);
            var edges: std.ArrayList([2]u32) = .empty;
            defer edges.deinit(gpa);
            try G.uniqueEdges(gpa, &.{ .{ 0, 1, 2 }, .{ 2, 1, 3 } }, &edges);
        }
    };
}

test "Aabb is exactly two compact Vec3 values" {
    inline for (all_layouts) |l| {
        try testing.expectEqual(24, @sizeOf(Geometry(l).Aabb));
    }
}

test "grid bounds normals and unique edges in every layout" {
    inline for (all_layouts) |l| {
        const F = @import("fixtures.zig").Fixtures(l);
        const G = Geometry(l);
        var mesh = try F.grid(testing.allocator, 3, 2, 4);
        defer mesh.deinit(testing.allocator);

        const box = G.bounds(mesh.positions.toConst());
        try testing.expect(box.min.eql(.init(-2, -2, 0)));
        try testing.expect(box.max.eql(.init(2, 2, 0)));

        const normals = try testing.allocator.alloc(Vec3, mesh.faces.len);
        defer testing.allocator.free(normals);
        G.faceNormals(mesh.positions.toConst(), mesh.faces, normals);
        for (normals) |normal| try testing.expect(normal.eql(.init(0, 0, 1)));

        var edges: std.ArrayList([2]u32) = .empty;
        defer edges.deinit(testing.allocator);
        try G.uniqueEdges(testing.allocator, mesh.faces, &edges);
        try testing.expectEqual(@as(usize, 3 * (2 + 1) + 2 * (3 + 1) + 3 * 2), edges.items.len);
        for (edges.items, 0..) |edge, i| {
            try testing.expect(edge[0] < edge[1]);
            if (i > 0) try testing.expect(G.edgeLessThan({}, edges.items[i - 1], edge));
        }
    }
}

test "icosphere normals topology and radius in every layout" {
    inline for (all_layouts) |l| {
        const F = @import("fixtures.zig").Fixtures(l);
        const G = Geometry(l);
        var mesh = try F.icosphere(testing.allocator, 2, 2.5);
        defer mesh.deinit(testing.allocator);

        const normals = try testing.allocator.alloc(Vec3, mesh.positions.len());
        defer testing.allocator.free(normals);
        G.vertexNormals(mesh.positions.toConst(), mesh.faces, normals);
        // Area-weighted normals of a subdivided icosahedron deviate from the
        // radial direction by up to ~1.8e-2 at two subdivisions (the triangles
        // around the twelve original vertices are noticeably unequal); this is
        // a property of the fixture, not a kernel error.
        var i: u32 = 0;
        while (i < mesh.positions.len()) : (i += 1) {
            const normal = normals[i];
            const position = mesh.positions.get(i);
            const expected = position.normalize();
            try testing.expect(normal.sub(expected).length() < 2.5e-2);
            try testing.expectApproxEqAbs(@as(f32, 2.5), position.length(), 1e-5);
        }

        var edges: std.ArrayList([2]u32) = .empty;
        defer edges.deinit(testing.allocator);
        try G.uniqueEdges(testing.allocator, mesh.faces, &edges);
        const v: usize = mesh.positions.len();
        const f = mesh.faces.len;
        try testing.expectEqual(v + f - 2, edges.items.len);
        try testing.expectEqual(3 * f / 2, edges.items.len);
    }
}

test "degenerate face normal is finite zero in every layout" {
    inline for (all_layouts) |l| {
        const P = layout.PositionsOf(l);
        const G = Geometry(l);
        const positions = try P.alloc(testing.allocator, 3);
        defer positions.free(testing.allocator);
        positions.setAll(&.{ .init(1, 2, 3), .init(1, 2, 3), .init(4, 5, 6) });
        var normals: [1]Vec3 = undefined;
        G.faceNormals(positions.toConst(), &.{.{ 0, 1, 2 }}, &normals);
        try testing.expect(normals[0].eql(Vec3.zero));
        try testing.expect(!std.math.isNan(normals[0].x));
        try testing.expect(!std.math.isNan(normals[0].y));
        try testing.expect(!std.math.isNan(normals[0].z));
    }
}

test "empty kernel inputs in every layout" {
    inline for (all_layouts) |l| {
        const G = Geometry(l);
        try testing.expect(G.bounds(G.P.Const.empty).isEmpty());
        var edges: std.ArrayList([2]u32) = .empty;
        defer edges.deinit(testing.allocator);
        try G.uniqueEdges(testing.allocator, &.{}, &edges);
        try testing.expectEqual(0, edges.items.len);
    }
}

test "uniqueEdges handles every allocation failure in every layout" {
    inline for (all_layouts) |l| {
        try testing.checkAllAllocationFailures(
            testing.allocator,
            UniqueEdgesAllocationCase(l).run,
            .{},
        );
    }
}

test "uniqueEdges makes no allocator calls at steady state in every layout" {
    inline for (all_layouts) |l| {
        const G = Geometry(l);
        const CountingAllocator = @import("../testutil.zig").CountingAllocator;
        var counting: CountingAllocator = .{ .child = testing.allocator };
        const gpa = counting.allocator();
        var edges: std.ArrayList([2]u32) = .empty;
        defer edges.deinit(gpa);
        const faces = [_][3]u32{ .{ 0, 1, 2 }, .{ 2, 1, 3 } };
        try G.uniqueEdges(gpa, &faces, &edges);

        const alloc_calls = counting.alloc_calls;
        const resize_calls = counting.resize_calls;
        const remap_calls = counting.remap_calls;
        const free_calls = counting.free_calls;
        try G.uniqueEdges(gpa, &faces, &edges);
        try testing.expectEqual(alloc_calls, counting.alloc_calls);
        try testing.expectEqual(resize_calls, counting.resize_calls);
        try testing.expectEqual(remap_calls, counting.remap_calls);
        try testing.expectEqual(free_calls, counting.free_calls);
    }
}
