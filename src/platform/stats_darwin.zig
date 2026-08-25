//! Allocation-free Darwin process instrumentation.
const std = @import("std");

/// Returns this process's cumulative minor page-fault count without allocation.
pub fn minorFaults() u64 {
    const faults = std.posix.getrusage(std.c.rusage.SELF).minflt;
    return if (faults > 0) @intCast(faults) else 0;
}

/// Always zero: macOS has no hugetlbfs, so there is no huge-page residency to
/// account for. Sampling allocates nothing.
pub fn hugetlbKb() u64 {
    return 0;
}
