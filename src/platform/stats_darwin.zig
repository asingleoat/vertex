//! Allocation-free Darwin process instrumentation.
const std = @import("std");

/// Returns this process's cumulative minor page-fault count without allocation.
///
/// O(1).
pub fn minorFaults() u64 {
    const faults = std.posix.getrusage(std.c.rusage.SELF).minflt;
    return if (faults > 0) @intCast(faults) else 0;
}

/// Always zero, because macOS has no hugetlbfs and so no huge-page residency
/// to report.
///
/// O(1).
pub fn hugetlbKb() u64 {
    return 0;
}
