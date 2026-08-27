//! Procedural geometry: meshes and point sets generated from a few parameters
//! rather than loaded from a file.
//!
//! One call yields a surface of a known shape and size, with no asset to check
//! in and no I/O. Every generator is deterministic: the same arguments produce
//! the same geometry down to the vertex order, so a test can assert exact counts
//! and a sketch produces the same scene on every run.
//!
//! Each generator allocates from an explicit allocator and transfers ownership
//! to the caller, which releases a `Mesh` with `deinit` and a bare stream with
//! `free`.
const std = @import("std");
const layout = @import("layout.zig");

const Vec3 = layout.Vec3;

/// Returns the fixture generators specialized for vertex layout `l`.
///
/// Ordinary code uses `current`, the instantiation for this build, while a
/// benchmark uses this to build the same fixture in every layout. Everything returned is
/// owned by the caller.
///
/// O(1) at compile time.
pub fn Fixtures(comptime l: layout.Layout) type {
    return struct {
        /// The vertex stream type these generators produce, which is
        /// `PositionsOf(l)`.
        pub const P = layout.PositionsOf(l);

        /// A generated mesh: a vertex stream and the triangles indexing it,
        /// owning both.
        /// ---
        /// `positions` is writable, so a caller can displace the vertices in
        /// place and send the result again rather than regenerating. `faces`
        /// holds three vertex indices per triangle, wound counter-clockwise.
        /// Release the whole thing with `deinit` and the allocator it was built
        /// with.
        pub const Mesh = struct {
            positions: P.Mut,
            faces: [][3]u32,

            /// Frees the positions and the faces. Pass the allocator the mesh
            /// was generated with.
            ///
            /// O(1).
            pub fn deinit(self: Mesh, gpa: std.mem.Allocator) void {
                self.positions.free(gpa);
                gpa.free(self.faces);
            }
        };

        /// Generates a flat rectangular grid in the XY plane, triangulated.
        ///
        /// The grid spans `size` in both x and y, is centred on the origin and
        /// lies at z = 0. It has `nx` by `ny` quads, so `(nx+1)·(ny+1)` vertices
        /// and `2·nx·ny` triangles, wound counter-clockwise as seen from +Z.
        /// Vertices are in row-major order, so the vertex at column x and row y
        /// has index `y * (nx + 1) + x`. Setting a height field or applying a
        /// parameterization uses that mapping.
        ///
        /// Allocates the positions and the faces from `gpa`; the caller owns the
        /// returned mesh and releases it with `deinit`. Height fields, parameter
        /// domains and cloth simulations all start from this surface.
        ///
        /// O(nx·ny), which is the size of what it returns.
        pub fn grid(
            gpa: std.mem.Allocator,
            nx: u32,
            ny: u32,
            size: f32,
        ) std.mem.Allocator.Error!Mesh {
            const vertex_count_wide = (@as(u64, nx) + 1) * (@as(u64, ny) + 1);
            const face_count_wide = @as(u64, 2) * nx * ny;
            std.debug.assert(vertex_count_wide <= std.math.maxInt(u32));
            std.debug.assert(face_count_wide <= std.math.maxInt(usize));
            const vertex_count: u32 = @intCast(vertex_count_wide);
            const face_count: usize = @intCast(face_count_wide);

            const positions = try P.alloc(gpa, vertex_count);
            errdefer positions.free(gpa);
            const faces = try gpa.alloc([3]u32, face_count);
            errdefer gpa.free(faces);

            const half = size * 0.5;
            var y: u32 = 0;
            while (y <= ny) : (y += 1) {
                const fy = if (ny == 0) @as(f32, 0.5) else @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(ny));
                var x: u32 = 0;
                while (x <= nx) : (x += 1) {
                    const fx = if (nx == 0) @as(f32, 0.5) else @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(nx));
                    const index: u32 = y * (nx + 1) + x;
                    positions.set(index, .init(size * fx - half, size * fy - half, 0));
                }
            }

            const row = nx + 1;
            var face_index: usize = 0;
            y = 0;
            while (y < ny) : (y += 1) {
                var x: u32 = 0;
                while (x < nx) : (x += 1) {
                    const a = y * row + x;
                    const b = a + 1;
                    const c = a + row;
                    const d = c + 1;
                    faces[face_index] = .{ a, b, d };
                    faces[face_index + 1] = .{ a, d, c };
                    face_index += 2;
                }
            }
            std.debug.assert(face_index == faces.len);
            return .{ .positions = positions, .faces = faces };
        }

        /// Generates a sphere of the given `radius` by subdividing an
        /// icosahedron `subdivisions` times and projecting each vertex onto the
        /// sphere.
        ///
        /// The result has `20·4^subdivisions` triangles: 1,280 at three
        /// subdivisions and 81,920 at six. It has no poles and no seam, unlike a
        /// latitude-longitude sphere, and its triangles are close to equilateral
        /// everywhere, so a kernel that misbehaves on degenerate or uneven
        /// triangles still fails on it. It is the default test surface.
        ///
        /// Allocates the positions and the faces from `gpa`; the caller owns the
        /// returned mesh and releases it with `deinit`. A midpoint table gives
        /// an edge shared by two faces one vertex rather than two, and the
        /// table is freed before returning.
        ///
        /// an expected-constant lookup per split edge.
        ///
        /// O(4^s) in `subdivisions`, which is the size of what it returns, with
        /// an expected-constant lookup per split edge.
        pub fn icosphere(
            gpa: std.mem.Allocator,
            subdivisions: u32,
            radius: f32,
        ) std.mem.Allocator.Error!Mesh {
            // A u32-indexed icosphere can represent at most fourteen levels.
            std.debug.assert(subdivisions <= 14);
            var scale: u64 = 1;
            var level: u32 = 0;
            while (level < subdivisions) : (level += 1) scale *= 4;
            const vertex_count_wide = 10 * scale + 2;
            const face_count_wide = 20 * scale;
            std.debug.assert(vertex_count_wide <= std.math.maxInt(u32));
            std.debug.assert(face_count_wide <= std.math.maxInt(usize));
            const vertex_count: u32 = @intCast(vertex_count_wide);
            const face_count: usize = @intCast(face_count_wide);

            const positions = try P.alloc(gpa, vertex_count);
            errdefer positions.free(gpa);
            const faces = try gpa.alloc([3]u32, face_count);
            errdefer gpa.free(faces);

            const phi: f32 = (1.0 + @sqrt(@as(f32, 5.0))) * 0.5;
            const base_positions = [_]Vec3{
                .init(-1, phi, 0), .init(1, phi, 0), .init(-1, -phi, 0), .init(1, -phi, 0),
                .init(0, -1, phi), .init(0, 1, phi), .init(0, -1, -phi), .init(0, 1, -phi),
                .init(phi, 0, -1), .init(phi, 0, 1), .init(-phi, 0, -1), .init(-phi, 0, 1),
            };
            var base_index: u32 = 0;
            while (base_index < base_positions.len) : (base_index += 1) {
                positions.set(base_index, base_positions[base_index]);
            }

            const base_faces = [_][3]u32{
                .{ 0, 11, 5 }, .{ 0, 5, 1 },  .{ 0, 1, 7 },   .{ 0, 7, 10 }, .{ 0, 10, 11 },
                .{ 1, 5, 9 },  .{ 5, 11, 4 }, .{ 11, 10, 2 }, .{ 10, 7, 6 }, .{ 7, 1, 8 },
                .{ 3, 9, 4 },  .{ 3, 4, 2 },  .{ 3, 2, 6 },   .{ 3, 6, 8 },  .{ 3, 8, 9 },
                .{ 4, 9, 5 },  .{ 2, 4, 11 }, .{ 6, 2, 10 },  .{ 8, 6, 7 },  .{ 9, 8, 1 },
            };
            for (base_faces, 0..) |face, i| faces[i] = face;

            var midpoints: std.AutoHashMapUnmanaged(u64, u32) = .empty;
            defer midpoints.deinit(gpa);
            var next_vertex: u32 = base_positions.len;
            var old_face_count: usize = base_faces.len;
            level = 0;
            while (level < subdivisions) : (level += 1) {
                midpoints.clearRetainingCapacity();
                const old_edge_count = old_face_count * 3 / 2;
                std.debug.assert(old_edge_count <= std.math.maxInt(u32));
                try midpoints.ensureTotalCapacity(gpa, @intCast(old_edge_count));

                var i = old_face_count;
                while (i > 0) {
                    i -= 1;
                    const face = faces[i];
                    const ab = midpoint(positions, &midpoints, face[0], face[1], &next_vertex);
                    const bc = midpoint(positions, &midpoints, face[1], face[2], &next_vertex);
                    const ca = midpoint(positions, &midpoints, face[2], face[0], &next_vertex);
                    const dst = i * 4;
                    faces[dst] = .{ face[0], ab, ca };
                    faces[dst + 1] = .{ face[1], bc, ab };
                    faces[dst + 2] = .{ face[2], ca, bc };
                    faces[dst + 3] = .{ ab, bc, ca };
                }
                old_face_count *= 4;
            }

            std.debug.assert(next_vertex == vertex_count);
            std.debug.assert(old_face_count == faces.len);
            var vertex: u32 = 0;
            while (vertex < vertex_count) : (vertex += 1) {
                positions.set(vertex, positions.get(vertex).normalize().scale(radius));
            }
            return .{ .positions = positions, .faces = faces };
        }

        /// Generates `n` points distributed uniformly in the axis-aligned cube
        /// spanning `-extent` to `+extent` on every axis.
        ///
        /// The placement depends only on `seed`, so a given seed always produces
        /// the same points in the same order. Allocates from `gpa` and returns a
        /// stream the caller owns and releases with `free`.
        ///
        /// This is a point cloud for exercising point rendering, picking and
        /// spatial structures. Note that the distribution is uniform in the cube
        /// and not in the inscribed ball, so it is denser toward the corners
        /// when interpreted radially.
        ///
        /// O(n).
        pub fn randomPoints(
            gpa: std.mem.Allocator,
            n: u32,
            seed: u64,
            extent: f32,
        ) std.mem.Allocator.Error!P.Mut {
            const positions = try P.alloc(gpa, n);
            var prng = std.Random.DefaultPrng.init(seed);
            const random = prng.random();
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                positions.set(i, .init(
                    (random.float(f32) * 2 - 1) * extent,
                    (random.float(f32) * 2 - 1) * extent,
                    (random.float(f32) * 2 - 1) * extent,
                ));
            }
            return positions;
        }

        fn midpoint(
            positions: P.Mut,
            midpoints: *std.AutoHashMapUnmanaged(u64, u32),
            a: u32,
            b: u32,
            next_vertex: *u32,
        ) u32 {
            const low = @min(a, b);
            const high = @max(a, b);
            const key = (@as(u64, low) << 32) | high;
            const result = midpoints.getOrPutAssumeCapacity(key);
            if (result.found_existing) return result.value_ptr.*;

            const index = next_vertex.*;
            next_vertex.* += 1;
            const position = positions.get(a).add(positions.get(b)).scale(0.5);
            positions.set(index, position);
            result.value_ptr.* = index;
            return index;
        }
    };
}

/// The fixture generators for the layout this build selected. This is the
/// instantiation ordinary code calls, as `fixtures.current.icosphere(...)`.
pub const current = Fixtures(layout.layout);

const testing = std.testing;
const all_layouts = [_]layout.Layout{ .aos3, .aos4, .soa };

fn AllocationCases(comptime l: layout.Layout) type {
    return struct {
        const F = Fixtures(l);

        fn grid(gpa: std.mem.Allocator) !void {
            var mesh = try F.grid(gpa, 3, 2, 4);
            defer mesh.deinit(gpa);
        }

        fn icosphere(gpa: std.mem.Allocator) !void {
            var mesh = try F.icosphere(gpa, 2, 1);
            defer mesh.deinit(gpa);
        }

        fn randomPoints(gpa: std.mem.Allocator) !void {
            const positions = try F.randomPoints(gpa, 17, 1234, 3);
            defer positions.free(gpa);
        }
    };
}

test "procedural fixtures handle every allocation failure in every layout" {
    inline for (all_layouts) |l| {
        const Cases = AllocationCases(l);
        try testing.checkAllAllocationFailures(testing.allocator, Cases.grid, .{});
        try testing.checkAllAllocationFailures(testing.allocator, Cases.icosphere, .{});
        try testing.checkAllAllocationFailures(testing.allocator, Cases.randomPoints, .{});
    }
}
