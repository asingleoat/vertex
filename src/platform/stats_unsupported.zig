//! Process-instrumentation stubs for unsupported targets.

/// Returns zero without allocation because minor-fault sampling is unsupported.
pub fn minorFaults() u64 {
    return 0;
}

/// Returns zero without allocation because hugetlb accounting is unsupported.
pub fn hugetlbKb() u64 {
    return 0;
}
