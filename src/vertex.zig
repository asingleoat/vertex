//! vertex — a geometry playground you drive from a sketch.
//!
//! An index, not an API. Two modules are what a sketch actually reads, and both
//! are written to be read top to bottom:
//!
//! * `shapes` — **pure**. The geometry vocabulary: `Positions`, `Vec3`, the
//!   kernels (`bounds`, `vertexNormals`, `uniqueEdges`) and the fixtures
//!   (`icosphere`, `grid`, `randomPoints`).
//! * `sketch` — **the edge**. Talking to the viewer: `connect`, the
//!   `Connection` you hold, and every message you can send it.
//!
//! Their names are re-exported here so a sketch can write `vertex.connect` and
//! `vertex.Positions` without qualifying, but the documentation lives in those
//! two files and they are the ones to open.
//!
//! Everything else is library code, reachable through `internal`. Nothing is
//! off-limits — read it, change it, take it apart. It sits behind a namespace
//! only so that what a sketch needs is not buried in what it does not.
const std = @import("std");

/// Pure geometry vocabulary. See `api/shapes.zig`.
pub const shapes = @import("api/shapes.zig");
/// The viewer conversation. See `api/sketch.zig`.
pub const sketch = @import("api/sketch.zig");

// ---- the sketch-facing surface, flattened for convenience ----

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
/// A generated mesh owning its positions and faces; see `shapes.Mesh`.
pub const Mesh = shapes.Mesh;

/// Exports a stepping sketch's C ABI for viewer-driven stepping; see
/// `client/dylib.zig`. Used only by `steps/*.zig`.
pub const dylib = @import("client/dylib.zig");

/// Library internals. Pure modules and the edges that implement them, kept out
/// of the sketch-facing surface but not out of reach.
pub const internal = struct {
    /// Pure: vertex memory layouts and the `Positions` machinery.
    pub const layout = @import("geometry/layout.zig");
    /// Pure: geometry kernels, parameterized by layout.
    pub const geometry = @import("geometry/geometry.zig");
    /// Pure: procedural meshes and point sets, parameterized by layout.
    pub const fixtures = @import("geometry/fixtures.zig");
    /// Pure: the wire format — message types, encode and decode.
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
    // Reaching every namespace is what pulls each file's tests into the test
    // binary; `internal` needs its own walk because referencing the struct
    // does not analyze the modules behind its declarations.
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(internal);
    _ = shapes;
    _ = sketch;
}
