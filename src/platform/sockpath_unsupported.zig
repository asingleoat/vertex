//! Unix socket path handling without a `/proc/self/fd` rebase: paths must
//! fit the platform's `sun_path` directly (104 bytes on Darwin/BSD, 108 on
//! Linux-like systems); longer ones are rejected with `NameTooLong`.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");

pub const Error = error{ NameTooLong, DirectoryUnavailable };

pub const max_len: usize = if (builtin.os.tag.isDarwin() or builtin.os.tag.isBSD()) 103 else 107;

pub const Shortened = struct {
    buffer: [max_len + 1]u8 = undefined,
    len: usize = 0,
    dir: ?std.Io.Dir = null,

    /// O(k) in the path's length.
    pub fn path(self: *const Shortened) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// O(k) in the path's length.
pub fn shorten(_: std.Io, original: []const u8, out: *Shortened) Error!void {
    out.* = .{};
    if (original.len > max_len) return error.NameTooLong;
    @memcpy(out.buffer[0..original.len], original);
    out.len = original.len;
}

/// O(1).
pub fn release(_: std.Io, shortened: *Shortened) void {
    shortened.len = 0;
}

pub const limit_note = "Unix socket paths are limited by sockaddr_un on this platform; choose a shorter socket path";
