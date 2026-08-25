//! Fixed-buffer Linux procfs reads and unsigned-field parsing.
const std = @import("std");

/// Reads `path` into caller-owned `buffer` and returns its initialized prefix.
/// The slice borrows `buffer`; failures return null and no allocation occurs.
pub fn readProc(path: []const u8, buffer: []u8) ?[]const u8 {
    const handle = std.posix.openat(std.posix.AT.FDCWD, path, .{ .CLOEXEC = true }, 0) catch return null;
    defer std.Io.Threaded.closeFd(handle);
    var len: usize = 0;
    while (len < buffer.len) {
        const read_len = std.posix.read(handle, buffer[len..]) catch return null;
        if (read_len == 0) break;
        len += read_len;
    }
    return buffer[0..len];
}

/// Parses the first decimal unsigned integer after leading whitespace.
/// The input is borrowed, malformed data returns null, and no allocation occurs.
pub fn parseUnsigned(bytes: []const u8) ?u64 {
    var start: usize = 0;
    while (start < bytes.len and std.ascii.isWhitespace(bytes[start])) : (start += 1) {}
    var end = start;
    while (end < bytes.len and std.ascii.isDigit(bytes[end])) : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(u64, bytes[start..end], 10) catch null;
}

/// Finds `label` and parses the following unsigned integer without allocation.
/// Both inputs are borrowed and missing or malformed fields return null.
pub fn parseLabeledUnsigned(bytes: []const u8, label: []const u8) ?u64 {
    const start = std.mem.indexOf(u8, bytes, label) orelse return null;
    return parseUnsigned(bytes[start + label.len ..]);
}
