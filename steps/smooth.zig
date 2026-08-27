//! Viewer-driven umbrella-Laplacian smoothing of a reproducibly noisy sphere.
const std = @import("std");
const vertex = @import("vertex");

const subdivisions: u32 = 3;
const sphere_radius: f32 = 1.0;
const noise_amplitude: f32 = 0.15;
const noise_seed: u64 = 0x5eed_5eed;
const smoothing_lambda: f32 = 0.5;
const smoothing_steps: u32 = 60;

const Positions = vertex.Positions;

/// Owned smoothing state. `deinit` releases every allocation through the same
/// allocator that `init` received; position access is layout-independent.
pub const State = struct {
    sphere: vertex.shapes.FixtureMesh,
    next_positions: Positions.Mut,
    edges: std.ArrayList([2]u32),
    neighbor_offsets: []u32,
    neighbors: []u32,
    displacement: []f32,
    iteration: u32 = 0,
};

/// Allocates the noisy mesh, unique edges, one flat CSR adjacency, scratch
/// positions, and scalar storage, then registers the initial frame.
pub fn init(gpa: std.mem.Allocator, session: *vertex.Session) !State {
    var sphere = try vertex.shapes.icosphere(gpa, subdivisions, sphere_radius);
    errdefer sphere.deinit(gpa);

    var prng = std.Random.DefaultPrng.init(noise_seed);
    const random = prng.random();
    var vertex_index: u32 = 0;
    while (vertex_index < sphere.positions.len()) : (vertex_index += 1) {
        const radius = sphere_radius + (random.float(f32) * 2 - 1) * noise_amplitude;
        sphere.positions.set(vertex_index, sphere.positions.get(vertex_index).normalize().scale(radius));
    }

    var edges: std.ArrayList([2]u32) = .empty;
    errdefer edges.deinit(gpa);
    try vertex.shapes.uniqueEdges(gpa, sphere.faces, &edges);

    const vertex_count = sphere.positions.len();
    const counts = try gpa.alloc(u32, vertex_count);
    defer gpa.free(counts);
    @memset(counts, 0);
    for (edges.items) |edge| {
        counts[edge[0]] += 1;
        counts[edge[1]] += 1;
    }

    const neighbor_offsets = try gpa.alloc(u32, @as(usize, vertex_count) + 1);
    errdefer gpa.free(neighbor_offsets);
    neighbor_offsets[0] = 0;
    vertex_index = 0;
    while (vertex_index < vertex_count) : (vertex_index += 1) {
        neighbor_offsets[vertex_index + 1] = neighbor_offsets[vertex_index] + counts[vertex_index];
        counts[vertex_index] = neighbor_offsets[vertex_index];
    }
    std.debug.assert(neighbor_offsets[vertex_count] == edges.items.len * 2);

    const neighbors = try gpa.alloc(u32, neighbor_offsets[vertex_count]);
    errdefer gpa.free(neighbors);
    for (edges.items) |edge| {
        neighbors[counts[edge[0]]] = edge[1];
        counts[edge[0]] += 1;
        neighbors[counts[edge[1]]] = edge[0];
        counts[edge[1]] += 1;
    }

    const next_positions = try Positions.alloc(gpa, vertex_count);
    errdefer next_positions.free(gpa);
    const displacement = try gpa.alloc(f32, vertex_count);
    errdefer gpa.free(displacement);
    updateDisplacement(sphere.positions.toConst(), displacement);

    try session.mesh("sphere", sphere.positions.toConst(), sphere.faces, .{});
    try session.scalar("sphere", "displacement", .vertex, displacement);
    return .{
        .sphere = sphere,
        .next_positions = next_positions,
        .edges = edges,
        .neighbor_offsets = neighbor_offsets,
        .neighbors = neighbors,
        .displacement = displacement,
    };
}

/// Performs one allocation-free umbrella-Laplacian pass, sends the changed
/// positions and displacement scalar, and returns false after exactly 60 calls.
pub fn step(state: *State, _: std.mem.Allocator, session: *vertex.Session) !bool {
    std.debug.assert(state.iteration < smoothing_steps);
    var vertex_index: u32 = 0;
    while (vertex_index < state.sphere.positions.len()) : (vertex_index += 1) {
        const begin = state.neighbor_offsets[vertex_index];
        const end = state.neighbor_offsets[vertex_index + 1];
        std.debug.assert(begin < end);
        var sum = vertex.Vec3.zero;
        for (state.neighbors[begin..end]) |neighbor| {
            sum = sum.add(state.sphere.positions.get(neighbor));
        }
        const degree: f32 = @floatFromInt(end - begin);
        const current = state.sphere.positions.get(vertex_index);
        const average = sum.scale(1.0 / degree);
        state.next_positions.set(
            vertex_index,
            current.add(average.sub(current).scale(smoothing_lambda)),
        );
    }
    std.mem.swap(Positions.Mut, &state.sphere.positions, &state.next_positions);
    updateDisplacement(state.sphere.positions.toConst(), state.displacement);
    try session.meshPositions("sphere", state.sphere.positions.toConst());
    try session.scalar("sphere", "displacement", .vertex, state.displacement);
    state.iteration += 1;
    return state.iteration < smoothing_steps;
}

/// Frees every buffer owned by `state`; it performs no allocation.
pub fn deinit(state: *State, gpa: std.mem.Allocator) void {
    gpa.free(state.displacement);
    state.next_positions.free(gpa);
    gpa.free(state.neighbors);
    gpa.free(state.neighbor_offsets);
    state.edges.deinit(gpa);
    state.sphere.deinit(gpa);
}

fn updateDisplacement(positions: Positions.Const, displacement: []f32) void {
    std.debug.assert(positions.len() == displacement.len);
    var vertex_index: u32 = 0;
    while (vertex_index < positions.len()) : (vertex_index += 1) {
        displacement[vertex_index] = positions.get(vertex_index).length() - sphere_radius;
    }
}

comptime {
    vertex.dylib.exportSketch(@This());
}
