//! Allocation-free Darwin process instrumentation.
const std = @import("std");

/// Returns this process's cumulative minor page-fault count without allocation.
pub fn minorFaults() u64 {
    const faults = std.posix.getrusage(std.c.rusage.SELF).minflt;
    return if (faults > 0) @intCast(faults) else 0;
}

/// Always zero: macOS has no hugetlbfs and no huge-page residency to report.
pub fn hugetlbKb() u64 {
    return 0;
}
