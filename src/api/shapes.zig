//! The geometry vocabulary: the types you build data in, and the kernels and
//! fixtures that produce it.
//!
//! This is one of the two modules a sketch imports; the other is `sketch.zig`,
//! which sends what you build here to the viewer. Everything in this module is
//! **pure**: given the same inputs it produces the same outputs, it touches no
//! socket, window, clock or global, and every function that can allocate takes
//! the allocator as its first argument. That is what makes it safe to call from
//! anywhere in a sketch, and testable without a viewer running.
//!
//! Two conventions run through all of it:
//!
//! * **You own what you allocate.** A function that allocates says so and hands
//!   ownership back; free it with the matching `free`/`deinit` and the same
//!   allocator. Nothing here retains a slice you passed in.
//! * **Positions are a type, not a convention.** Vertex streams are never bare
//!   `[]f32`. They travel as `Positions`, whose memory layout is chosen once at
//!   build time (`-Dvertex_layout=aos3|aos4|soa`) and which every kernel and the
//!   wire format derive from. Use the named accessors and a layout change costs
//!   you nothing.
const std = @import("std");
const layout = @import("../geometry/layout.zig");
const geometry = @import("../geometry/geometry.zig");
const fixtures = @import("../geometry/fixtures.zig");

/// A point or direction in 3-space, and the arithmetic to combine them.
///
/// A plain value type: 12 bytes, copied freely, owning nothing. Build one with
/// `Vec3.init(x, y, z)` or the `.zero` constant, and combine with `add`, `sub`,
/// `scale`, `dot`, `cross`, `length`, `normalize`, `min`, `max`, `eql`.
/// 2D sketches use it too, leaving `z` at 0 and passing `.{ .dim = .d2 }` when
/// they register the structure.
pub const Vec3 = layout.Vec3;

/// A vertex stream: `n` positions in the layout this build selected.
///
/// The single type every geometry call speaks. It is a view over bytes plus a
/// length, not a container — copying a `Positions` copies the view, not the
/// data. Two flavours exist: `Positions.Mut` (what `alloc` returns, what you
/// write through) and `Positions.Const` (what you pass to the viewer and to
/// kernels); go from one to the other with `toConst`.
///
/// Allocating and filling one:
///
/// ```zig
/// const p = try Positions.alloc(gpa, 3);   // you own it
/// defer p.free(gpa);
/// p.setAll(&.{ .init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0) });
/// p.set(2, .init(0, 2, 0));                // or one at a time
/// ```
///
/// Reading: `get(i)` for a whole `Vec3`, `x(i)`/`y(i)`/`z(i)` for one
/// component, `len()` for the count, `bytes()` for the raw stream. Indices are
/// `u32`, and the accessors are `inline` — they compile to the same code as
/// hand-written indexing, whichever layout is selected.
///
/// `fromSlice` wraps memory you already hold (a stack array, say) without
/// copying; the `Positions` is then valid exactly as long as that memory is.
pub const Positions = layout.Positions;

/// Which memory layout this build selected for `Positions`: `.aos3` (default,
/// 12-byte packed), `.aos4` (16-byte, `@Vector`-castable) or `.soa` (three
/// component arrays). Read it if a kernel you write wants a layout-specific
/// fast path; ignore it otherwise, because the accessors already hide it.
pub const vertex_layout = layout.layout;

/// An axis-aligned bounding box, with `center`, `extent`, `radius` and
/// `isEmpty`. Returned by `bounds`; owns nothing.
pub const Aabb = geometry.current.Aabb;

/// Computes the axis-aligned bounds of a vertex stream.
///
/// Takes the positions to measure; returns an `Aabb` by value, `.empty` for an
/// empty stream. Allocates nothing and reads nothing but the stream. Use it to
/// frame a result, normalise a model to unit size, or size a spatial grid.
pub const bounds = geometry.current.bounds;

/// Computes one geometric normal per triangle.
///
/// `positions` and `faces` are read; `out` receives one `Vec3` per face and
/// must already be `faces.len` long — the caller owns it, and this call
/// allocates nothing. Normals follow the winding order (counter-clockwise is
/// front-facing) and are normalised. Send the result as a face-target vector
/// quantity, or feed it into your own shading.
pub const faceNormals = geometry.current.faceNormals;

/// Computes one smooth normal per vertex, area-weighted across incident faces.
///
/// `positions` and `faces` are read; `out` receives one `Vec3` per vertex and
/// must already be `positions.len()` long — the caller owns it, and this call
/// allocates nothing. This is what you want for smooth shading, or as a
/// direction field to displace a surface along.
pub const vertexNormals = geometry.current.vertexNormals;

/// Extracts the unique undirected edges of a triangle mesh.
///
/// Allocates the edge array from `gpa` and hands you ownership — free it with
/// the same allocator. Each edge appears once regardless of how many faces
/// share it, which is what a wireframe or a graph algorithm wants. Cost is
/// proportional to the face count.
pub const uniqueEdges = geometry.current.uniqueEdges;

/// A generated mesh: `positions` and `faces` together, owning both.
///
/// Returned by the fixture builders below. Release it with
/// `mesh.deinit(gpa)`, passing the allocator it was built with. Its
/// `positions` field is a `Positions.Mut`, so you can displace the vertices in
/// place and re-send them.
pub const Mesh = fixtures.current.Mesh;

/// Builds a flat `nx` by `ny` quad grid triangulated into a mesh, spanning
/// `size` in x and y and centred on the origin.
///
/// Allocates positions and faces from `gpa`; you own the returned `Mesh` and
/// release it with `deinit`. The starting point for height fields, parameter
/// domains, cloth and anything else that wants a regular sheet.
pub const grid = fixtures.current.grid;

/// Builds a unit-ish icosphere of `radius`, subdivided `subdivisions` times.
///
/// Allocates positions and faces from `gpa`; you own the returned `Mesh` and
/// release it with `deinit`. Triangle count grows as 20·4^subdivisions, so 3
/// gives 1,280 faces and 6 gives 81,920 — a well-conditioned test surface with
/// no poles or seams.
pub const icosphere = fixtures.current.icosphere;

/// Builds `n` points pseudo-randomly placed in the ball of radius `extent`,
/// deterministically from `seed`.
///
/// Allocates from `gpa` and returns a `Positions.Mut` you own — free it with
/// `positions.free(gpa)`. Deterministic by construction, so a sketch that uses
/// it produces the same scene on every run and diffs cleanly against itself.
pub const randomPoints = fixtures.current.randomPoints;

test {
    std.testing.refAllDecls(@This());
}
