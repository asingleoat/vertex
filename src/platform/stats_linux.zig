//! Allocation-free Linux process instrumentation.
const std = @import("std");

/// Returns this process's cumulative minor page-fault count without allocation.
pub fn minorFaults() u64 {
    const faults = std.posix.getrusage(std.os.linux.rusage.SELF).minflt;
    return if (faults > 0) @intCast(faults) else 0;
}

/// Returns `HugetlbPages` from `/proc/self/status` in KiB. Missing, truncated,
/// or malformed proc data yields zero; the fixed-buffer sample allocates none.
pub fn hugetlbKb() u64 {
    var buffer: [16 * 1024]u8 = undefined;
    const bytes = readProc("/proc/self/status", &buffer) orelse return 0;
    const label = "HugetlbPages:";
    const label_start = std.mem.indexOf(u8, bytes, label) orelse return 0;
    const tail = bytes[label_start + label.len ..];
    var start: usize = 0;
    while (start < tail.len and std.ascii.isWhitespace(tail[start])) : (start += 1) {}
    var end = start;
    while (end < tail.len and std.ascii.isDigit(tail[end])) : (end += 1) {}
    if (end == start) return 0;
    return std.fmt.parseInt(u64, tail[start..end], 10) catch 0;
}

fn readProc(path: []const u8, buffer: []u8) ?[]const u8 {
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
