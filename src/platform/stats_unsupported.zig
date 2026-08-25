//! Process-instrumentation stubs for unsupported targets.

/// Always zero, because minor-fault sampling is unsupported here.
pub fn minorFaults() u64 {
    return 0;
}

/// Always zero, because hugetlb accounting is unsupported here.
pub fn hugetlbKb() u64 {
    return 0;
}
