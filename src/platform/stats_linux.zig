//! Allocation-free Linux process instrumentation.
const std = @import("std");
const procfs = @import("procfs_linux.zig");

/// Returns this process's cumulative minor page-fault count without allocation.
pub fn minorFaults() u64 {
    const faults = std.posix.getrusage(std.os.linux.rusage.SELF).minflt;
    return if (faults > 0) @intCast(faults) else 0;
}

/// Returns `HugetlbPages` from `/proc/self/status` in KiB. Missing, truncated,
/// or malformed proc data yields zero; the fixed-buffer sample allocates none.
pub fn hugetlbKb() u64 {
    var buffer: [16 * 1024]u8 = undefined;
    const bytes = procfs.readProc("/proc/self/status", &buffer) orelse return 0;
    return procfs.parseLabeledUnsigned(bytes, "HugetlbPages:") orelse 0;
}
