//! Process-instrumentation stubs for unsupported targets.

/// Always zero: minor-fault sampling is unsupported here.
pub fn minorFaults() u64 {
    return 0;
}

/// Always zero: hugetlb accounting is unsupported here.
pub fn hugetlbKb() u64 {
    return 0;
}
