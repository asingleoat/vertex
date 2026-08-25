//! Comptime-selected operating-system services used by vertex's effectful edges.
const std = @import("std");
const builtin = @import("builtin");

/// Shared-memory services selected for the build target. Returned regions are
/// always owned by the caller according to the selected implementation's docs.
pub const shm = switch (builtin.os.tag) {
    .linux => @import("shm_linux.zig"),
    .macos => @import("shm_darwin.zig"),
    else => @import("shm_unsupported.zig"),
};

/// Descriptor-passing services selected for the build target. Calls allocate
/// no memory and borrow all input/output buffers for their duration only.
pub const fdpass = switch (builtin.os.tag) {
    .linux => @import("fdpass_linux.zig"),
    .macos => @import("fdpass_darwin.zig"),
    else => @import("fdpass_unsupported.zig"),
};

/// Process instrumentation selected for the build target. Sampling allocates
/// no memory and unsupported targets report zero.
pub const stats = switch (builtin.os.tag) {
    .linux => @import("stats_linux.zig"),
    .macos => @import("stats_darwin.zig"),
    else => @import("stats_unsupported.zig"),
};

/// Unix socket path handling: `sockaddr_un` limits the path string; Linux
/// rebases longer paths on a directory handle, other targets reject them.
pub const sockpath = switch (builtin.os.tag) {
    .linux => @import("sockpath_linux.zig"),
    else => @import("sockpath_unsupported.zig"),
};

/// Native operating-system handle carried by shared-memory and fd-passing
/// APIs. It owns nothing by itself; ownership is documented by each operation.
pub const Handle = i32;

fn assertSameDecls(comptime supported: type, comptime unsupported: type) void {
    const supported_decls = std.meta.declarations(supported);
    const unsupported_decls = std.meta.declarations(unsupported);
    if (supported_decls.len != unsupported_decls.len) {
        @compileError("platform implementations expose different declaration counts");
    }
    for (supported_decls) |decl_name| {
        if (!@hasDecl(unsupported, decl_name)) {
            @compileError("unsupported platform implementation is missing declaration: " ++ decl_name);
        }
    }
}

test "every platform implementation exposes the same declarations" {
    comptime {
        assertSameDecls(@import("shm_linux.zig"), @import("shm_unsupported.zig"));
        assertSameDecls(@import("shm_linux.zig"), @import("shm_darwin.zig"));
        assertSameDecls(@import("fdpass_linux.zig"), @import("fdpass_unsupported.zig"));
        assertSameDecls(@import("fdpass_linux.zig"), @import("fdpass_darwin.zig"));
        assertSameDecls(@import("stats_linux.zig"), @import("stats_unsupported.zig"));
        assertSameDecls(@import("stats_linux.zig"), @import("stats_darwin.zig"));
        assertSameDecls(@import("sockpath_linux.zig"), @import("sockpath_unsupported.zig"));
    }
}

test {
    _ = sockpath;
}

test "shared regions round trip with ordinary and requested huge pages" {
    if (!shm.supported) return error.SkipZigTest;

    const cases = [_]struct { len: usize, huge_pages: bool }{
        .{ .len = std.heap.page_size_min + 17, .huge_pages = false },
        .{ .len = shm.huge_page_size, .huge_pages = true },
    };
    for (cases) |case| {
        const region = try shm.create(case.len, .{ .huge_pages = case.huge_pages });
        defer {
            shm.unmap(region);
            shm.close(region.handle);
        }
        for (region.map, 0..) |*byte, i| byte.* = @truncate(i *% 131 +% 17);

        const read_only = try shm.mapReadOnly(region.handle, .{ .huge_pages = case.huge_pages });
        defer shm.unmap(read_only);
        try std.testing.expectEqualSlices(u8, region.map, read_only.map);
        if (!case.huge_pages) try std.testing.expect(!region.huge);
    }
}
