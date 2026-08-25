//! Unix socket path shortening for Linux.
//!
//! `sockaddr_un.sun_path` holds at most 108 bytes, checked on the string
//! handed to bind/connect before any path resolution. Longer paths are
//! rebased on an open directory handle: `/proc/self/fd/<fd>/<basename>` is
//! short, and the kernel resolves the directory through the fd. No `chdir`,
//! no global state. The handle lives only as long as the `Shortened` value.
const std = @import("std");
const platform = @import("platform.zig");

pub const Error = error{ NameTooLong, DirectoryUnavailable };

/// Longest socket path the kernel accepts (excluding the terminator).
pub const max_len: usize = 107;

/// A bind/connect-ready path plus the directory handle it may depend on.
/// Owned by the caller; `release` closes the handle. Do not copy after use.
pub const Shortened = struct {
    buffer: [max_len + 1]u8 = undefined,
    len: usize = 0,
    dir: ?std.Io.Dir = null,

    pub fn path(self: *const Shortened) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// Produces a path usable in a `sockaddr_un` for `original`: unchanged when
/// it fits, otherwise rebased on an opened directory handle. Allocates
/// nothing; may open one directory fd (closed by `release`).
pub fn shorten(io: std.Io, original: []const u8, out: *Shortened) Error!void {
    out.* = .{};
    if (original.len <= max_len) {
        @memcpy(out.buffer[0..original.len], original);
        out.len = original.len;
        return;
    }
    const dirname = std.fs.path.dirname(original) orelse ".";
    const basename = std.fs.path.basename(original);
    const dir = std.Io.Dir.cwd().openDir(io, dirname, .{}) catch return error.DirectoryUnavailable;
    errdefer dir.close(io);
    const written = std.fmt.bufPrint(&out.buffer, "/proc/self/fd/{d}/{s}", .{ dir.handle, basename }) catch
        return error.NameTooLong;
    if (written.len > max_len) return error.NameTooLong;
    out.len = written.len;
    out.dir = dir;
}

/// Closes the directory handle, if any. Safe to call once per `shorten`.
pub fn release(io: std.Io, shortened: *Shortened) void {
    if (shortened.dir) |dir| dir.close(io);
    shortened.dir = null;
    shortened.len = 0;
}

/// Human-readable limit note for diagnostics.
pub const limit_note = "Unix socket paths are limited to 107 bytes; vertex rebases longer paths via /proc/self/fd on Linux";

test "long socket paths bind and connect through a directory handle" {
    // platform.zig imports this file on every target for the decl-parity
    // check, which pulls this test into non-Linux test binaries too. The
    // rebasing it exercises is /proc-specific, so it can only run on Linux.
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Build a directory chain long enough to exceed the limit by itself.
    const segment = "a-deliberately-long-directory-segment-for-the-socket-path-limit-test";
    try tmp.dir.createDirPath(testing.io, segment ++ "/" ++ segment);
    var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_abs = abs_buf[0..try tmp.dir.realPath(testing.io, &abs_buf)];
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const long_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}/vertex-test.sock", .{ tmp_abs, segment, segment });
    try testing.expect(long_path.len > max_len);

    var short_bind: Shortened = .{};
    try shorten(testing.io, long_path, &short_bind);
    defer release(testing.io, &short_bind);
    try testing.expect(short_bind.path().len <= max_len);
    try testing.expect(std.mem.startsWith(u8, short_bind.path(), "/proc/self/fd/"));

    const bind_address = try std.Io.net.UnixAddress.init(short_bind.path());
    var server = try bind_address.listen(testing.io, .{});
    defer server.deinit(testing.io);

    var short_connect: Shortened = .{};
    try shorten(testing.io, long_path, &short_connect);
    defer release(testing.io, &short_connect);
    const connect_address = try std.Io.net.UnixAddress.init(short_connect.path());
    const stream = try connect_address.connect(testing.io);
    stream.close(testing.io);
    // The socket file exists at the long path, proving the rebased bind.
    const stat = try tmp.dir.statFile(testing.io, segment ++ "/" ++ segment ++ "/vertex-test.sock", .{});
    try testing.expect(stat.kind == .unix_domain_socket);
}
