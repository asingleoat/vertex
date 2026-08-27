//! Polygon operations over a triangle mesh: recovering its boundary and
//! filling that boundary with faces.
//!
//! Everything here except the triangulation inside `capBoundaries` is pure and
//! allocates only through the allocator it is given. That one call goes to
//! `triangulate.zig`, the seam to Manifold; see "Polygon triangulation and
//! caps" in DESIGN.md.
//!
//! These operations take vertices as `[]const Vec3` rather than as `Positions`,
//! and so are not parameterized by vertex layout as `geometry.zig` and
//! `fixtures.zig` are. They work on geometry under construction, which this
//! project computes in plain slices of vectors and converts to a stream only
//! when sending it; nothing here reads a stream, and `capBoundaries` grows the
//! vertex list, which a stream view cannot do.
const std = @import("std");
const layout = @import("layout.zig");
const triangulate = @import("triangulate.zig");

const Vec3 = layout.Vec3;

/// Failure of `boundaryLoops`, and part of `CapError`.
///
/// `NonManifoldBoundary` covers three conditions that leave the boundary
/// without an unambiguous traversal: an edge shared by three or more triangles,
/// a vertex with more than one outgoing boundary edge, and a chain of boundary
/// edges that does not close. Each is reported rather than resolved
/// arbitrarily.
pub const BoundaryError = error{
    NonManifoldBoundary,
    OutOfMemory,
};

/// Failure of `capBoundaries`: everything `boundaryLoops` reports, plus
/// everything the triangulator reports about one loop.
pub const CapError = BoundaryError || triangulate.Error;

/// The boundary of a triangle mesh, as closed loops of vertex indices.
/// ---
/// The loops are stored end to end in `vertices` and delimited by `starts`,
/// which holds one more entry than there are loops. Each loop lists its
/// vertices once, in the direction the mesh traverses them, and does not repeat
/// the first vertex at the end.
///
/// Returned by `boundaryLoops`, which the caller releases with `deinit` and the
/// same allocator.
pub const Loops = struct {
    vertices: []u32,
    starts: []u32,

    /// Loops with no vertices, which `boundaryLoops` returns for a closed mesh.
    /// Owns nothing, so `deinit` on it is still correct.
    pub const empty: Loops = .{ .vertices = &.{}, .starts = &.{} };

    /// The number of loops, which is zero for a closed mesh.
    pub fn count(self: Loops) usize {
        return if (self.starts.len == 0) 0 else self.starts.len - 1;
    }

    /// The vertices of loop `i`, in traversal order. The slice aliases
    /// `vertices` and is valid until `deinit`.
    pub fn get(self: Loops, i: usize) []const u32 {
        return self.vertices[self.starts[i]..self.starts[i + 1]];
    }

    /// The length of the longest loop, which is what a caller sizing a per-loop
    /// scratch buffer needs. Zero when there are no loops.
    pub fn longest(self: Loops) usize {
        var most: usize = 0;
        var i: usize = 0;
        while (i < self.count()) : (i += 1) most = @max(most, self.get(i).len);
        return most;
    }

    pub fn deinit(self: Loops, gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.starts);
    }
};

/// Recovers the boundary of a triangle mesh as oriented loops.
///
/// A boundary edge is one used by exactly one triangle. Each is recorded in the
/// direction that triangle traverses it, and the edges are chained into loops,
/// so a loop's direction is the mesh's own and a face closing it must wind the
/// other way.
///
/// `vertex_count` bounds the indices in `faces` and sizes an internal table.
/// A degenerate triangle, one naming a vertex twice, is skipped entirely: it
/// encloses no area, so it neither opens a boundary nor closes one. The result
/// is owned by the caller. Nothing is retained.
pub fn boundaryLoops(
    gpa: std.mem.Allocator,
    vertex_count: u32,
    faces: []const [3]u32,
) BoundaryError!Loops {
    if (faces.len == 0) return .empty;

    // Every directed edge of every triangle, sorted so that the two uses of a
    // shared edge become adjacent whichever way each runs.
    const halves = try gpa.alloc([2]u32, faces.len * 3);
    defer gpa.free(halves);
    var written: usize = 0;
    for (faces) |face| {
        // A face naming a vertex twice has no area, so it bounds nothing and
        // contributes no half-edges at all. Dropping only its collapsed edge
        // would leave the other two, which run in opposite directions along one
        // line and pair with each other, taking a real edge from two uses to
        // four and making a sound mesh look non-manifold. Exported STL carries
        // these in quantity.
        if (face[0] == face[1] or face[1] == face[2] or face[2] == face[0]) continue;
        for (0..3) |k| {
            halves[written] = .{ face[k], face[(k + 1) % 3] };
            written += 1;
        }
    }
    const used = halves[0..written];
    std.mem.sort([2]u32, used, {}, undirectedLessThan);

    // One use is a boundary edge and two are an interior edge. More is an edge
    // shared by three or more triangles, around which the surface has no
    // consistent inside.
    var boundary: std.ArrayList([2]u32) = .empty;
    defer boundary.deinit(gpa);
    var i: usize = 0;
    while (i < used.len) {
        var j = i + 1;
        while (j < used.len and undirectedEqual(used[i], used[j])) j += 1;
        if (j - i > 2) return error.NonManifoldBoundary;
        if (j - i == 1) try boundary.append(gpa, used[i]);
        i = j;
    }
    return chain(gpa, vertex_count, boundary.items);
}

/// Chains directed edges into the closed loops they form.
///
/// Every vertex an edge leaves must be left by exactly one, and every chain
/// must return to where it started; either failing is `NonManifoldBoundary`,
/// since a vertex with two ways out has no unambiguous traversal and a chain
/// that runs out is a path rather than a loop. `vertex_count` bounds the
/// indices and sizes an internal table.
///
/// This is what `boundaryLoops` does with the edges it finds, and what
/// `polyline.loops` does with a polyline's segments, which are already the
/// edges in question.
pub fn chain(
    gpa: std.mem.Allocator,
    vertex_count: u32,
    edges: []const [2]u32,
) BoundaryError!Loops {
    if (edges.len == 0) return .empty;

    // next[v] is the vertex following v, so a walk needs no search.
    const next = try gpa.alloc(u32, vertex_count);
    defer gpa.free(next);
    @memset(next, no_vertex);
    for (edges) |edge| {
        if (next[edge[0]] != no_vertex) return error.NonManifoldBoundary;
        next[edge[0]] = edge[1];
    }

    // Walking consumes each entry, so a vertex still present in `next` is one
    // no earlier loop has reached. Every edge is consumed exactly once, which
    // is the capacity reserved here.
    var vertices = try std.ArrayList(u32).initCapacity(gpa, edges.len);
    errdefer vertices.deinit(gpa);
    var starts = try std.ArrayList(u32).initCapacity(gpa, 2);
    errdefer starts.deinit(gpa);
    starts.appendAssumeCapacity(0);

    for (edges) |edge| {
        const first = edge[0];
        if (next[first] == no_vertex) continue;
        var v = first;
        while (true) {
            const following = next[v];
            // A chain that runs out before returning to its start is a path
            // rather than a loop, which a closed surface's boundary cannot be.
            if (following == no_vertex) return error.NonManifoldBoundary;
            next[v] = no_vertex;
            vertices.appendAssumeCapacity(v);
            v = following;
            if (v == first) break;
        }
        try starts.append(gpa, @intCast(vertices.items.len));
    }

    // Taken one at a time: once a list has given up its memory its own errdefer
    // covers nothing, so the slice needs one of its own.
    const owned_vertices = try vertices.toOwnedSlice(gpa);
    errdefer gpa.free(owned_vertices);
    const owned_starts = try starts.toOwnedSlice(gpa);
    return .{ .vertices = owned_vertices, .starts = owned_starts };
}

/// How `capBoundaries` triangulates one boundary loop.
/// ---
/// The choice states what the caller knows about the loop's shape, which the
/// cap cannot cheaply test for. A strategy applied to a loop it does not suit
/// produces a cap that is wrong rather than merely poor.
///
/// The differences are exact for a ring of `n` vertices spaced evenly on a
/// circle. The inscribed angle theorem gives a triangle whose vertices are
/// `k1`, `k2` and `k3` steps apart the angles `ki*pi/n`, so any triangle using
/// a ring edge has an angle of `pi/n`, and since `n` edges are spread over
/// `n - 2` triangles, no triangulation of the ring alone beats that. Only
/// `.centroid`, which adds a vertex, escapes it.
///
/// No strategy is best on every axis. Measured over both caps of a 32-sided
/// prism of unit radius, where `pi/n` is 5.63 degrees:
///
///     strategy      smallest  largest  worst R/2r  valence  box area
///     general           5.63   168.75        52.2        6     49.95
///     fan               5.63   168.75        52.2       33     95.76
///     hierarchical      5.63   168.75        52.2       12     43.61
///     centroid         11.25    84.38         2.8       32     53.49
///
/// `R/2r` is circumradius over twice inradius, which is 1 for an equilateral
/// triangle and grows without bound on a sliver. `valence` is the highest
/// number of faces at one vertex. `box area` is the summed surface area of the
/// axis-aligned box round each cap face, the quantity a bounding-volume
/// hierarchy's cost heuristic integrates.
///
/// The two tests named for this table check the angles and the cost columns.
/// `.centroid` alone escapes the sliver and is the choice for a cap a solver
/// reads or a subdivision refines. It pays for that with a vertex of valence
/// `n`, a cost to anything that walks the one-ring, decimates or remeshes, and
/// with wedges that each run a full radius and so have wide bounding boxes.
/// `.hierarchical` is the cheapest for spatial queries and keeps valence
/// bounded, which suits a cap that is rendered, picked or edited.
pub const Strategy = enum {
    /// General polygon triangulation, through `triangulate.zig`. Handles any
    /// simple polygon, convex or not, and adds no vertex. This is the default
    /// and the only choice for a loop whose shape is unknown.
    ///
    /// It gives no quality guarantee on a ring: the points of a circle are
    /// cocircular, so every triangulation of them is Delaunay, and what comes
    /// back is the triangulator's tie-breaking rather than a best choice. That
    /// tie-break is respectable on the cost columns above but is Manifold's to
    /// change.
    general,

    /// A fan from the loop's first vertex, `n - 2` triangles and no vertex
    /// added. Correct only for a convex loop, and the cheapest thing that is.
    ///
    /// It is the worst choice on every column of the table above: every one of
    /// its triangles uses a ring edge and so carries the `pi/n` angle, its
    /// apex reaches valence `n`, and its spokes each run a full radius.
    fan,

    /// Recursive halving: the loop is split at its midpoint and each half
    /// again, `n - 2` triangles and no vertex added. Correct only for a convex
    /// loop.
    ///
    /// This is the best a cap can do without adding a vertex. On a ring it is
    /// still held to the `pi/n` floor by the `n/2` ears of its first level, but
    /// those ears span three adjacent ring vertices and so are small, which is
    /// why it has the lowest box area of the four. Each level above doubles its
    /// smallest angle, where `.fan` leaves every triangle on the floor.
    hierarchical,

    /// A fan from a new vertex at the loop's centroid: `n` triangles, one
    /// vertex added. Correct for a loop that is star-shaped about its own
    /// centroid, which every convex loop is.
    ///
    /// On a ring its triangles are congruent, with apex `2*pi/n` and base
    /// angles `pi/2 - pi/n`, so the smallest angle is twice the floor the
    /// others are held to and the largest is under a right angle rather than a
    /// sliver approaching `pi`. The new vertex lies in the loop's fitted plane,
    /// which for a non-planar loop is not on the loop itself, and it carries
    /// valence `n`.
    centroid,
};

/// Options for `capBoundaries`.
pub const CapOptions = struct {
    /// How each loop is triangulated. Applies to every loop of the mesh.
    strategy: Strategy = .general,
    /// The distance below which the triangulator treats two points as
    /// coincident. Negative selects the triangulator's own. Used only by
    /// `.general`; the others are closed forms.
    epsilon: f64 = -1,
};

/// Triangulates every boundary loop of a mesh and appends the faces, closing
/// it.
///
/// A cap covers indices the mesh already has, so every strategy but `.centroid`
/// leaves `vertices` untouched; `.centroid` appends one vertex per loop. Either
/// way no existing vertex is moved or duplicated, and the result is closed,
/// with every edge used by exactly two triangles.
///
/// Both lists are appended to rather than cleared, so the caller passes the
/// mesh itself. `faces` is read in full before anything is appended to it. Each
/// loop is projected onto the plane of its `newellNormal` and emitted against
/// the loop's traversal direction, which orients the cap away from the surface.
/// A loop enclosing no area is skipped rather than reported: it has no cap to
/// add.
///
/// A cap chooses chords between the loop's vertices without consulting the
/// chords the mesh already has. Where the mesh spans its own boundary, as a
/// nearly flat surface does, the cap can choose one of those again and leave
/// that edge with four faces rather than two. This does not arise on a surface
/// that encloses volume, where no interior chord joins two boundary vertices in
/// the cap's plane.
///
/// On failure the mesh holds the caps appended before it, which the caller
/// discards by truncating both lists to the lengths it passed in.
pub fn capBoundaries(
    gpa: std.mem.Allocator,
    vertices: *std.ArrayList(Vec3),
    faces: *std.ArrayList([3]u32),
    options: CapOptions,
) CapError!void {
    const loops = try boundaryLoops(gpa, @intCast(vertices.items.len), faces.items);
    defer loops.deinit(gpa);
    if (loops.count() == 0) return;

    // One scratch pair sized for the longest loop serves them all.
    const longest = loops.longest();
    const points = try gpa.alloc([2]f64, longest);
    defer gpa.free(points);
    const scratch = try gpa.alloc([3]u32, triangulate.triangleCount(longest));
    defer gpa.free(scratch);

    var i: usize = 0;
    while (i < loops.count()) : (i += 1) {
        const loop = loops.get(i);
        const normal = newellNormal(vertices.items, loop);
        if (normal.eql(.zero)) continue;

        const basis = orthonormalBasis(normal);
        const origin = vertices.items[loop[0]];
        for (loop, 0..) |index, k| {
            const d = vertices.items[index].sub(origin);
            points[k] = .{ @floatCast(d.dot(basis[0])), @floatCast(d.dot(basis[1])) };
        }
        const flat = points[0..loop.len];

        // Every emission below reverses the counter-clockwise order the loop
        // runs in: that is the direction the mesh traverses its boundary, and
        // the cap must close it the other way.
        switch (options.strategy) {
            .general => {
                const tris = try triangulate.simplePolygon(
                    flat,
                    options.epsilon,
                    scratch[0..triangulate.triangleCount(loop.len)],
                );
                try faces.ensureUnusedCapacity(gpa, tris.len);
                for (tris) |t| {
                    faces.appendAssumeCapacity(.{ loop[t[2]], loop[t[1]], loop[t[0]] });
                }
            },
            .fan => {
                try faces.ensureUnusedCapacity(gpa, triangulate.triangleCount(loop.len));
                for (1..loop.len - 1) |k| {
                    faces.appendAssumeCapacity(.{ loop[0], loop[k + 1], loop[k] });
                }
            },
            .hierarchical => {
                try faces.ensureUnusedCapacity(gpa, triangulate.triangleCount(loop.len));
                halve(faces, loop, 0, loop.len - 1);
            },
            .centroid => {
                const c = polygonCentroid(flat);
                const center = origin
                    .add(basis[0].scale(@floatCast(c[0])))
                    .add(basis[1].scale(@floatCast(c[1])));
                // Appended after the projection above, which read
                // `vertices.items`, and before the faces that name it.
                const apex: u32 = @intCast(vertices.items.len);
                try vertices.append(gpa, center);
                try faces.ensureUnusedCapacity(gpa, loop.len);
                for (loop, 0..) |index, k| {
                    faces.appendAssumeCapacity(.{ apex, loop[(k + 1) % loop.len], index });
                }
            },
        }
    }
}

/// Triangulates the part of `loop` from `lo` to `hi` closed by the chord
/// between them, by splitting it at the middle and recursing on each half.
///
/// Emits `hi - lo - 1` triangles, which the caller has reserved, and recurses
/// to a depth of `log2(hi - lo)`. Splitting at the middle is what keeps the two
/// arcs either side of each triangle equal, which on a ring is what its two
/// smaller angles are proportional to.
fn halve(faces: *std.ArrayList([3]u32), loop: []const u32, lo: usize, hi: usize) void {
    if (hi - lo < 2) return;
    const mid = lo + (hi - lo) / 2;
    faces.appendAssumeCapacity(.{ loop[lo], loop[hi], loop[mid] });
    halve(faces, loop, lo, mid);
    halve(faces, loop, mid, hi);
}

/// Computes the normal of a possibly non-planar loop by Newell's method,
/// normalized.
///
/// The result is the area-weighted average of the loop's normal, which is
/// defined where a cross product of two edges is not: it does not depend on a
/// choice of vertices and does not vanish on a loop with collinear spans. The
/// loop winds counter-clockwise about it.
///
/// Returns `Vec3.zero` when the loop encloses no area, as for fewer than three
/// vertices or a set of collinear ones. Allocates nothing.
pub fn newellNormal(vertices: []const Vec3, loop: []const u32) Vec3 {
    if (loop.len < 3) return .zero;
    var n: Vec3 = .zero;
    for (loop, 0..) |index, k| {
        const a = vertices[index];
        const b = vertices[loop[(k + 1) % loop.len]];
        n.x += (a.y - b.y) * (a.z + b.z);
        n.y += (a.z - b.z) * (a.x + b.x);
        n.z += (a.x - b.x) * (a.y + b.y);
    }
    const length = n.length();
    return if (length == 0) .zero else n.scale(1 / length);
}

/// Returns two unit vectors spanning the plane through the origin with unit
/// normal `n`, ordered so that their cross product is `n`.
///
/// This is the branch-free construction of Duff et al., "Building an
/// Orthonormal Basis, Revisited" (2017), which stays well conditioned for every
/// `n` including one near the negative z axis, where the obvious construction
/// loses precision. Allocates nothing.
pub fn orthonormalBasis(n: Vec3) [2]Vec3 {
    const sign = std.math.copysign(@as(f32, 1), n.z);
    const a = -1 / (sign + n.z);
    const b = n.x * n.y * a;
    return .{
        .init(1 + sign * n.x * n.x * a, sign * b, -sign * n.x),
        .init(b, sign + n.y * n.y * a, -n.y),
    };
}

/// Returns the area centroid of a simple polygon, which for a loop that is
/// star-shaped about it is a point every vertex can see.
///
/// Falls back to the mean of the vertices when the signed area is zero, which
/// for a loop of any extent means its points are collinear. Allocates nothing.
fn polygonCentroid(points: []const [2]f64) [2]f64 {
    var twice_area: f64 = 0;
    var cx: f64 = 0;
    var cy: f64 = 0;
    for (points, 0..) |p, k| {
        const q = points[(k + 1) % points.len];
        const cross = p[0] * q[1] - q[0] * p[1];
        twice_area += cross;
        cx += (p[0] + q[0]) * cross;
        cy += (p[1] + q[1]) * cross;
    }
    if (twice_area == 0) {
        var mean: [2]f64 = .{ 0, 0 };
        for (points) |p| {
            mean[0] += p[0];
            mean[1] += p[1];
        }
        const n: f64 = @floatFromInt(points.len);
        return .{ mean[0] / n, mean[1] / n };
    }
    return .{ cx / (3 * twice_area), cy / (3 * twice_area) };
}

/// Marks a vertex with no outgoing boundary edge, either because it has none or
/// because a walk has already consumed it.
const no_vertex = std.math.maxInt(u32);

fn undirectedLessThan(_: void, a: [2]u32, b: [2]u32) bool {
    const a_lo = @min(a[0], a[1]);
    const b_lo = @min(b[0], b[1]);
    if (a_lo != b_lo) return a_lo < b_lo;
    return @max(a[0], a[1]) < @max(b[0], b[1]);
}

fn undirectedEqual(a: [2]u32, b: [2]u32) bool {
    return @min(a[0], a[1]) == @min(b[0], b[1]) and
        @max(a[0], a[1]) == @max(b[0], b[1]);
}

const testing = std.testing;
const all_strategies = [_]Strategy{ .general, .fan, .hierarchical, .centroid };

/// A square in the z = 0 plane, wound counter-clockwise about +z, as two
/// triangles. Its boundary is one loop of four vertices.
const quad_positions = [_]Vec3{
    .init(0, 0, 0), .init(1, 0, 0), .init(1, 1, 0), .init(0, 1, 0),
};
const quad_faces = [_][3]u32{ .{ 0, 1, 2 }, .{ 0, 2, 3 } };

const Mesh = struct {
    vertices: std.ArrayList(Vec3),
    faces: std.ArrayList([3]u32),

    fn deinit(self: *Mesh, gpa: std.mem.Allocator) void {
        self.vertices.deinit(gpa);
        self.faces.deinit(gpa);
    }
};

/// Builds the side wall of a prism of `sides` sides, as a ring of unit radius
/// at z = 0 and the same ring at z = `height`, wound to face outward.
fn prismWall(gpa: std.mem.Allocator, sides: u32, height: f32) !Mesh {
    var vertices: std.ArrayList(Vec3) = .empty;
    errdefer vertices.deinit(gpa);
    var faces: std.ArrayList([3]u32) = .empty;
    errdefer faces.deinit(gpa);

    try vertices.ensureTotalCapacity(gpa, 2 * sides);
    for (0..2) |ring| {
        for (0..sides) |k| {
            const turns = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(sides));
            const theta = turns * std.math.tau;
            const z: f32 = if (ring == 0) 0 else height;
            vertices.appendAssumeCapacity(.init(@cos(theta), @sin(theta), z));
        }
    }
    try faces.ensureTotalCapacity(gpa, 2 * sides);
    for (0..sides) |k| {
        const a0: u32 = @intCast(k);
        const a1: u32 = @intCast((k + 1) % sides);
        faces.appendAssumeCapacity(.{ a0, a1, sides + a1 });
        faces.appendAssumeCapacity(.{ a0, sides + a1, sides + a0 });
    }
    return .{ .vertices = vertices, .faces = faces };
}

/// The volume a closed mesh encloses, by the divergence theorem. Positive
/// exactly when its faces wind outward.
fn signedVolume(vertices: []const Vec3, faces: []const [3]u32) f64 {
    var volume: f64 = 0;
    for (faces) |face| {
        const a = vertices[face[0]];
        const b = vertices[face[1]];
        const c = vertices[face[2]];
        volume += @as(f64, a.dot(b.cross(c))) / 6;
    }
    return volume;
}

/// The smallest and largest angle over a set of faces, in radians.
fn angleRange(vertices: []const Vec3, faces: []const [3]u32) [2]f32 {
    var range: [2]f32 = .{ std.math.pi, 0 };
    for (faces) |face| {
        for (0..3) |k| {
            const at = vertices[face[k]];
            const u = vertices[face[(k + 1) % 3]].sub(at).normalize();
            const v = vertices[face[(k + 2) % 3]].sub(at).normalize();
            const angle = std.math.acos(std.math.clamp(u.dot(v), -1, 1));
            range[0] = @min(range[0], angle);
            range[1] = @max(range[1], angle);
        }
    }
    return range;
}

test "a closed mesh has no boundary" {
    // A tetrahedron: four triangles, every edge shared by two of them.
    const faces = [_][3]u32{ .{ 0, 2, 1 }, .{ 0, 1, 3 }, .{ 1, 2, 3 }, .{ 2, 0, 3 } };
    const loops = try boundaryLoops(testing.allocator, 4, &faces);
    defer loops.deinit(testing.allocator);
    try testing.expectEqual(0, loops.count());
}

test "an open mesh yields one loop in traversal order" {
    const loops = try boundaryLoops(testing.allocator, 4, &quad_faces);
    defer loops.deinit(testing.allocator);
    try testing.expectEqual(1, loops.count());

    const loop = loops.get(0);
    try testing.expectEqual(4, loop.len);
    // The loop runs the way the faces do, which for these two triangles is
    // 0, 1, 2, 3. Any rotation of that is the same loop.
    const start = std.mem.indexOfScalar(u32, loop, 0).?;
    for (0..4) |k| try testing.expectEqual(@as(u32, @intCast(k)), loop[(start + k) % 4]);
}

test "degenerate triangles contribute no boundary edges" {
    // The quad, plus a triangle collapsed onto a segment of its own.
    const faces = quad_faces ++ [_][3]u32{.{ 4, 5, 5 }};
    const loops = try boundaryLoops(testing.allocator, 6, &faces);
    defer loops.deinit(testing.allocator);
    try testing.expectEqual(1, loops.count());
    try testing.expectEqual(4, loops.get(0).len);
}

test "a degenerate triangle lying along a real edge leaves it manifold" {
    // The case that matters, and the one exported STL is full of: the collapsed
    // face sits on the quad's own edge 0-1. Keeping its two surviving
    // half-edges would take that edge to four uses and report the whole mesh
    // non-manifold.
    const faces = quad_faces ++ [_][3]u32{.{ 0, 1, 1 }};
    const loops = try boundaryLoops(testing.allocator, 4, &faces);
    defer loops.deinit(testing.allocator);
    try testing.expectEqual(1, loops.count());
    try testing.expectEqual(4, loops.get(0).len);

    // The same face given the other way round, and one collapsed to a point.
    const reversed = quad_faces ++ [_][3]u32{ .{ 1, 0, 0 }, .{ 2, 2, 2 } };
    const also = try boundaryLoops(testing.allocator, 4, &reversed);
    defer also.deinit(testing.allocator);
    try testing.expectEqual(1, also.count());
    try testing.expectEqual(4, also.get(0).len);
}

test "two disjoint sheets yield two loops" {
    const faces = quad_faces ++ [_][3]u32{ .{ 4, 5, 6 }, .{ 4, 6, 7 } };
    const loops = try boundaryLoops(testing.allocator, 8, &faces);
    defer loops.deinit(testing.allocator);
    try testing.expectEqual(2, loops.count());
    try testing.expectEqual(4, loops.get(0).len);
    try testing.expectEqual(4, loops.get(1).len);
}

test "a pinched boundary is reported rather than resolved" {
    // Two triangles meeting only at vertex 0, which then has two outgoing
    // boundary edges.
    const faces = [_][3]u32{ .{ 0, 1, 2 }, .{ 0, 3, 4 } };
    try testing.expectError(
        error.NonManifoldBoundary,
        boundaryLoops(testing.allocator, 5, &faces),
    );
}

test "an edge shared by three triangles is reported" {
    const faces = [_][3]u32{ .{ 0, 1, 2 }, .{ 0, 1, 3 }, .{ 0, 1, 4 } };
    try testing.expectError(
        error.NonManifoldBoundary,
        boundaryLoops(testing.allocator, 5, &faces),
    );
}

test "newellNormal recovers the plane of a loop" {
    const loop = [_]u32{ 0, 1, 2, 3 };
    const n = newellNormal(&quad_positions, &loop);
    try testing.expectApproxEqAbs(@as(f32, 0), n.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), n.y, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), n.z, 1e-6);

    // Reversing the loop reverses the normal.
    const reversed = [_]u32{ 3, 2, 1, 0 };
    try testing.expectApproxEqAbs(@as(f32, -1), newellNormal(&quad_positions, &reversed).z, 1e-6);
}

test "newellNormal is zero on a loop enclosing no area" {
    const collinear = [_]Vec3{ .init(0, 0, 0), .init(1, 0, 0), .init(2, 0, 0) };
    const loop = [_]u32{ 0, 1, 2 };
    try testing.expect(newellNormal(&collinear, &loop).eql(.zero));
}

test "orthonormalBasis spans the plane of its normal" {
    const normals = [_]Vec3{
        .init(0, 0, 1),  .init(0, 0, -1),                     .init(1, 0, 0),
        .init(0, -1, 0), .init(0.267261, 0.534522, 0.801784),
    };
    for (normals) |n| {
        const basis = orthonormalBasis(n);
        try testing.expectApproxEqAbs(@as(f32, 1), basis[0].length(), 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 1), basis[1].length(), 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 0), basis[0].dot(basis[1]), 1e-5);
        const w = basis[0].cross(basis[1]);
        try testing.expectApproxEqAbs(n.x, w.x, 1e-5);
        try testing.expectApproxEqAbs(n.y, w.y, 1e-5);
        try testing.expectApproxEqAbs(n.z, w.z, 1e-5);
    }
}

test "polygonCentroid finds the centre of a square" {
    const square = [_][2]f64{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } };
    const c = polygonCentroid(&square);
    try testing.expectApproxEqAbs(1.0, c[0], 1e-12);
    try testing.expectApproxEqAbs(1.0, c[1], 1e-12);
}

test "capping a flat sheet adds the right faces, oriented away from it" {
    for (all_strategies) |strategy| {
        var vertices: std.ArrayList(Vec3) = .empty;
        defer vertices.deinit(testing.allocator);
        try vertices.appendSlice(testing.allocator, &quad_positions);
        var faces: std.ArrayList([3]u32) = .empty;
        defer faces.deinit(testing.allocator);
        try faces.appendSlice(testing.allocator, &quad_faces);

        try capBoundaries(testing.allocator, &vertices, &faces, .{ .strategy = strategy });

        // Only `.centroid` adds a vertex, and only one.
        const adds_vertex = strategy == .centroid;
        try testing.expectEqual(@as(usize, if (adds_vertex) 5 else 4), vertices.items.len);
        try testing.expectEqual(@as(usize, if (adds_vertex) 6 else 4), faces.items.len);

        // Closure is not asserted here. A sheet this flat is the degenerate
        // case for capping: the cap re-triangulates the same square, and if it
        // picks the diagonal the sheet already uses, that edge ends up with
        // four faces. The tube test below is the closure test.

        // The sheet faces +z, so its cap faces -z.
        for (faces.items[quad_faces.len..]) |face| {
            const a = vertices.items[face[0]];
            const b = vertices.items[face[1]];
            const c = vertices.items[face[2]];
            try testing.expect(b.sub(a).cross(c.sub(a)).z < 0);
        }
    }
}

test "a closed mesh gains no caps" {
    for (all_strategies) |strategy| {
        var vertices: std.ArrayList(Vec3) = .empty;
        defer vertices.deinit(testing.allocator);
        try vertices.appendSlice(testing.allocator, &.{
            .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0), .init(0, 0, 1),
        });
        var faces: std.ArrayList([3]u32) = .empty;
        defer faces.deinit(testing.allocator);
        try faces.appendSlice(testing.allocator, &.{
            .{ 0, 2, 1 }, .{ 0, 1, 3 }, .{ 1, 2, 3 }, .{ 2, 0, 3 },
        });

        try capBoundaries(testing.allocator, &vertices, &faces, .{ .strategy = strategy });
        try testing.expectEqual(4, vertices.items.len);
        try testing.expectEqual(4, faces.items.len);
    }
}

test "capping a tube closes it and orients both caps outward under every strategy" {
    const sides = 8;
    const height = 2.0;
    for (all_strategies) |strategy| {
        var mesh = try prismWall(testing.allocator, sides, height);
        defer mesh.deinit(testing.allocator);
        const wall_faces = mesh.faces.items.len;

        try capBoundaries(testing.allocator, &mesh.vertices, &mesh.faces, .{ .strategy = strategy });

        // One cap per ring: `sides - 2` triangles over existing vertices, or
        // `sides` triangles and one new vertex.
        const adds_vertex = strategy == .centroid;
        const per_cap: usize = if (adds_vertex) sides else sides - 2;
        try testing.expectEqual(wall_faces + 2 * per_cap, mesh.faces.items.len);
        try testing.expectEqual(
            @as(usize, if (adds_vertex) 2 * sides + 2 else 2 * sides),
            mesh.vertices.items.len,
        );

        const loops = try boundaryLoops(
            testing.allocator,
            @intCast(mesh.vertices.items.len),
            mesh.faces.items,
        );
        defer loops.deinit(testing.allocator);
        try testing.expectEqual(0, loops.count());

        // A regular polygon of n sides inscribed in r has area n*r^2*sin(2*pi/n)/2.
        // A cap oriented inward would subtract its prism rather than add it.
        const area = sides * @sin(std.math.tau / @as(f64, sides)) / 2;
        const volume = signedVolume(mesh.vertices.items, mesh.faces.items);
        try testing.expectApproxEqRel(area * height, volume, 1e-5);
    }
}

test "smallest and largest angle by strategy on a ring" {
    const sides = 32;
    const floor = std.math.pi / @as(f32, sides);
    var range: [all_strategies.len][2]f32 = undefined;
    for (all_strategies, 0..) |strategy, i| {
        var mesh = try prismWall(testing.allocator, sides, 2);
        defer mesh.deinit(testing.allocator);
        const wall_faces = mesh.faces.items.len;
        try capBoundaries(testing.allocator, &mesh.vertices, &mesh.faces, .{ .strategy = strategy });
        range[i] = angleRange(mesh.vertices.items, mesh.faces.items[wall_faces..]);
    }

    // No triangulation of the ring alone beats the pi/n floor, and none of the
    // three that add no vertex does. `.fan` and `.hierarchical` sit on it
    // exactly.
    try testing.expect(range[0][0] <= floor * 1.001);
    try testing.expectApproxEqRel(floor, range[1][0], 1e-4);
    try testing.expectApproxEqRel(floor, range[2][0], 1e-4);

    // `.centroid` reaches 2*pi/n, the apex angle of its congruent triangles,
    // and its largest angle is the base angle pi/2 - pi/n rather than a sliver.
    try testing.expectApproxEqRel(2 * floor, range[3][0], 1e-4);
    try testing.expectApproxEqRel(std.math.pi / 2.0 - floor, range[3][1], 1e-4);
    for (0..3) |i| try testing.expect(range[i][1] > range[3][1]);
}

/// The summed surface area of the axis-aligned box round each face, which is
/// the quantity a bounding-volume hierarchy's cost heuristic integrates.
fn boxArea(vertices: []const Vec3, faces: []const [3]u32) f64 {
    var total: f64 = 0;
    for (faces) |face| {
        var lo = vertices[face[0]];
        var hi = lo;
        for (face[1..]) |i| {
            lo = lo.min(vertices[i]);
            hi = hi.max(vertices[i]);
        }
        const d = hi.sub(lo);
        total += 2 * (@as(f64, d.x) * @as(f64, d.y) +
            @as(f64, d.y) * @as(f64, d.z) +
            @as(f64, d.z) * @as(f64, d.x));
    }
    return total;
}

/// The highest number of faces meeting at one vertex.
fn maxValence(gpa: std.mem.Allocator, vertex_count: usize, faces: []const [3]u32) !u32 {
    const valence = try gpa.alloc(u32, vertex_count);
    defer gpa.free(valence);
    @memset(valence, 0);
    for (faces) |face| for (face) |i| {
        valence[i] += 1;
    };
    var most: u32 = 0;
    for (valence) |v| most = @max(most, v);
    return most;
}

test "downstream cost by strategy on a ring" {
    const sides = 32;
    var valence: [all_strategies.len]u32 = undefined;
    var area: [all_strategies.len]f64 = undefined;
    for (all_strategies, 0..) |strategy, i| {
        var mesh = try prismWall(testing.allocator, sides, 2);
        defer mesh.deinit(testing.allocator);
        const wall_faces = mesh.faces.items.len;
        try capBoundaries(testing.allocator, &mesh.vertices, &mesh.faces, .{ .strategy = strategy });
        valence[i] = try maxValence(testing.allocator, mesh.vertices.items.len, mesh.faces.items);
        area[i] = boxArea(mesh.vertices.items, mesh.faces.items[wall_faces..]);
    }

    // `.fan` and `.centroid` each put a star of `sides` triangles at one
    // vertex; the other two keep valence bounded well below it.
    try testing.expect(valence[1] >= sides);
    try testing.expect(valence[3] >= sides);
    try testing.expect(valence[2] <= 16);

    // `.hierarchical` has the smallest boxes, since its ears span three
    // adjacent ring vertices, and `.fan` the largest, since every one of its
    // triangles runs the width of the ring.
    try testing.expect(area[2] < area[0]);
    try testing.expect(area[0] < area[3]);
    try testing.expect(area[3] < area[1]);

    // `.general` is Manifold's tie-break among triangulations that are all
    // Delaunay here, so this bound describes the version in use rather than any
    // guarantee. A failure means that tie-break changed, not that capping did.
    try testing.expect(valence[0] <= 8);
}

test "empty inputs" {
    const loops = try boundaryLoops(testing.allocator, 0, &.{});
    defer loops.deinit(testing.allocator);
    try testing.expectEqual(0, loops.count());
    try testing.expectEqual(0, loops.longest());

    var vertices: std.ArrayList(Vec3) = .empty;
    defer vertices.deinit(testing.allocator);
    var faces: std.ArrayList([3]u32) = .empty;
    defer faces.deinit(testing.allocator);
    try capBoundaries(testing.allocator, &vertices, &faces, .{});
    try testing.expectEqual(0, faces.items.len);
}

fn boundaryLoopsAllocationCase(gpa: std.mem.Allocator) !void {
    const faces = quad_faces ++ [_][3]u32{ .{ 4, 5, 6 }, .{ 4, 6, 7 } };
    const loops = try boundaryLoops(gpa, 8, &faces);
    defer loops.deinit(gpa);
    if (loops.count() != 2) return error.TestUnexpectedResult;
}

fn capBoundariesAllocationCase(gpa: std.mem.Allocator, strategy: Strategy) !void {
    var vertices: std.ArrayList(Vec3) = .empty;
    defer vertices.deinit(gpa);
    try vertices.appendSlice(gpa, &quad_positions);
    var faces: std.ArrayList([3]u32) = .empty;
    defer faces.deinit(gpa);
    try faces.appendSlice(gpa, &quad_faces);
    try capBoundaries(gpa, &vertices, &faces, .{ .strategy = strategy });
    if (faces.items.len <= quad_faces.len) return error.TestUnexpectedResult;
}

test "boundaryLoops handles every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, boundaryLoopsAllocationCase, .{});
}

test "capBoundaries handles every allocation failure under every strategy" {
    // Allocation inside the triangulator is not reachable from here; see the
    // module comment on triangulate.zig.
    for (all_strategies) |strategy| {
        try testing.checkAllAllocationFailures(
            testing.allocator,
            capBoundariesAllocationCase,
            .{strategy},
        );
    }
}
