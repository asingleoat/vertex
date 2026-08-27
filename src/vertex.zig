//! Root module of the vertex library, and an index to the two modules a sketch
//! reads.
//!
//! Five terms are used throughout and are specific to this project. A *sketch*
//! is a program written against this library, which computes geometry and sends
//! it to the viewer. A *structure* is one named renderable in the viewer: a
//! triangle mesh, a point cloud or a set of line segments. A *quantity* is a
//! named field attached to a structure, holding one scalar or one vector per
//! vertex, per face or per point. A *run* is one execution of a sketch, and a
//! *frame* is one step within a run, which the viewer's timeline can move
//! between.
//!
//! `shapes` is pure and holds the geometry vocabulary: `Positions`, `Vec3`, the
//! kernels `bounds`, `vertexNormals` and `uniqueEdges`, and the fixtures
//! `icosphere`, `grid` and `randomPoints`. `sketch` is the effectful edge that
//! talks to the viewer: `connect`, the `Connection` a sketch holds, and the
//! messages it can send. Both are documented in full in their own files, which
//! are the ones to read. The names below are re-exported for use unqualified,
//! as `vertex.connect` and `vertex.Positions`.
//!
//! The remaining modules are reachable through `internal`. They are ordinary
//! library code and may be read and modified freely; the namespace exists only
//! to keep what a sketch needs separate from what it does not.
const std = @import("std");

/// Pure geometry vocabulary. See `api/shapes.zig`.
pub const shapes = @import("api/shapes.zig");
/// The viewer conversation. See `api/sketch.zig`.
pub const sketch = @import("api/sketch.zig");

// ---- the sketch-facing surface, flattened for convenience ----

/// Reads an STL file as an indexed mesh; see `sketch.readStl`.
pub const readStl = sketch.readStl;
/// Writes a mesh to an STL file; see `sketch.writeStl`.
pub const writeStl = sketch.writeStl;

/// Opens a connection to the viewer; see `sketch.connect`.
pub const connect = sketch.connect;
/// Opens a connection with explicit I/O and environment; see `sketch.connectWith`.
pub const connectWith = sketch.connectWith;
/// Options for `connect`; see `sketch.ConnectOptions`.
pub const ConnectOptions = sketch.ConnectOptions;
/// A live connection to the viewer; see `sketch.Connection`.
pub const Connection = sketch.Connection;
/// The sink-agnostic message sequencer behind `Connection`; see `sketch.Session`.
pub const Session = sketch.Session;
/// Where a quantity attaches: `.vertex`, `.face` or `.point`; see `sketch.Target`.
pub const Target = sketch.Target;
/// Severity of a `log` line; see `sketch.LogLevel`.
pub const LogLevel = sketch.LogLevel;
/// Per-structure registration options; see `sketch.GeometryOptions`.
pub const GeometryOptions = sketch.GeometryOptions;

/// A vertex stream in the build-selected layout; see `shapes.Positions`.
pub const Positions = shapes.Positions;
/// A point or direction in 3-space; see `shapes.Vec3`.
pub const Vec3 = shapes.Vec3;
/// An axis-aligned bounding box; see `shapes.Aabb`.
pub const Aabb = shapes.Aabb;
/// A triangle mesh under construction, vertices and faces; see `shapes.Mesh`.
pub const Mesh = shapes.Mesh;
/// A generated mesh holding a `Positions` stream; see `shapes.FixtureMesh`.
pub const FixtureMesh = shapes.FixtureMesh;

/// Exports a stepping sketch's C ABI for viewer-driven stepping; see
/// `client/dylib.zig`. Used only by `steps/*.zig`.
pub const dylib = @import("client/dylib.zig");

/// The library modules behind the sketch-facing surface: the pure ones and the
/// edges that implement them. Each declaration below notes which it is.
pub const internal = struct {
    /// Pure: vertex memory layouts and the `Positions` machinery.
    pub const layout = @import("geometry/layout.zig");
    /// Pure: geometry kernels, parameterized by layout.
    pub const geometry = @import("geometry/geometry.zig");
    /// Pure: procedural meshes and point sets, parameterized by layout.
    pub const fixtures = @import("geometry/fixtures.zig");
    /// Pure: the mesh under construction, and the transforms over its vertices.
    pub const mesh = @import("geometry/mesh.zig");
    /// Pure: polylines, and the surfaces lofted between them.
    pub const polyline = @import("geometry/polyline.zig");
    /// Pure: closed primitive solids, built from the operations above.
    pub const solids = @import("geometry/solids.zig");
    /// Edge: offsetting closed curves, which is Clipper2 through Manifold.
    pub const offset = @import("geometry/offset.zig");
    /// Edge: mesh booleans, which are Manifold behind a C ABI.
    pub const boolean = @import("geometry/boolean.zig");
    /// Pure: recovering an index array from a triangle soup by exact equality.
    pub const indexing = @import("geometry/indexing.zig");
    /// Pure: reading and writing STL, in both the binary and ASCII forms.
    pub const stl = @import("io/stl.zig");
    /// Edge: STL files, over the pure encoder above.
    pub const stl_file = @import("io/stl_file.zig");
    /// Pure: boundary recovery and capping of open surfaces.
    pub const polygon = @import("geometry/polygon.zig");
    /// Edge: polygon triangulation, which is Manifold behind a C ABI.
    pub const triangulate = @import("geometry/triangulate.zig");
    /// Pure: the wire format, its message types, and encode and decode.
    pub const protocol = @import("protocol/protocol.zig");
    /// Pure: the viewer's structure store, versions and timeline.
    pub const scene = @import("scene/scene.zig");
    /// Pure: colormap lookup tables.
    pub const colormap = @import("scene/colormap.zig");
    /// Pure: orbit and orthographic camera math.
    pub const camera = @import("scene/camera.zig");
    /// Pure: message ordering and validation over a `Sink`.
    pub const session = @import("client/session.zig");
    /// Edge: the socket, shared buffers and environment lookups.
    pub const transport = @import("client/transport.zig");
    /// Edge: OS services, comptime-selected per target.
    pub const platform = @import("platform/platform.zig");
    /// Test helpers shared across modules.
    pub const testutil = @import("testutil.zig");
    /// Build-time selections, chiefly the vertex layout.
    pub const build_options = @import("build_options");
};

test {
    // Referencing every namespace is what pulls each file's tests into the test
    // binary. `internal` needs a separate walk, because referencing the struct
    // itself does not analyze the modules its declarations name.
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(internal);
    _ = shapes;
    _ = sketch;
}
