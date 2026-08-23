//! vertex — pure core (geometry, protocol, scene) plus the client library.
//! Viewer edges (sokol, imgui, sockets server) live in src/viewer/ and import this module.
pub const build_options = @import("build_options");
pub const layout = @import("geometry/layout.zig");
pub const geometry = @import("geometry/geometry.zig");
pub const fixtures = @import("geometry/fixtures.zig");
pub const testutil = @import("testutil.zig");
pub const protocol = @import("protocol/protocol.zig");
pub const scene = @import("scene/scene.zig");
pub const camera = @import("scene/camera.zig");
pub const client = @import("client/client.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
