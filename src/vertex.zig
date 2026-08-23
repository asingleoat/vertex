//! vertex — pure core (geometry, protocol, scene) plus the client library.
//! Viewer edges (sokol, imgui, sockets server) live in src/viewer/ and import this module.
pub const build_options = @import("build_options");
pub const layout = @import("geometry/layout.zig");
pub const geometry = @import("geometry/geometry.zig");
pub const fixtures = @import("geometry/fixtures.zig");
pub const testutil = @import("testutil.zig");
pub const protocol = @import("protocol/protocol.zig");
pub const scene = @import("scene/scene.zig");
pub const client = @import("client/client.zig");

/// Opens a socket-owning client connection without allocating; see `client.connect`.
pub const connect = client.connect;
/// Opens a socket-owning client with explicit I/O dependencies and no allocation.
pub const connectWith = client.connectWith;
/// Options borrowed during allocation-free client connection setup.
pub const ConnectOptions = client.ConnectOptions;
/// A socket-owning, allocation-free client session.
pub const Connection = client.Connection;
/// A semantic sink interface that borrows its implementation and allocates nothing.
pub const Sink = client.Sink;
/// A session borrowing a semantic sink; all operations are synchronous and allocation-free.
pub const Session = client.Session;

test {
    @import("std").testing.refAllDecls(@This());
}
