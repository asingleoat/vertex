//! Shared-memory stubs for targets without a vertex implementation.
const std = @import("std");
const platform = @import("platform.zig");

/// Whether this build can create shared regions at all: never here, so every
/// caller falls back to the inline payload path.
pub const supported = false;

/// Whether a huge-page class exists on this platform at all: there is no shared memory here at all.
/// Comptime, unlike `hugePagesConfigured`, which asks how the running kernel
/// is set up. Callers use it to avoid advertising a preference that cannot
/// apply.
pub const huge_supported = false;

/// Errors from unsupported shared-memory operations. Failed calls never
/// transfer ownership to the caller.
pub const Error = std.posix.MemFdCreateError || std.Io.File.SetLengthError ||
    std.Io.File.LengthError || std.posix.MMapError || error{
    Unsupported,
    InvalidLength,
    SharedTooLarge,
};

/// Placeholder region matching the supported API. Unsupported calls never
/// return a live value, so it never owns a mapping or handle.
pub const Region = struct {
    handle: platform.Handle,
    map: []align(std.heap.page_size_min) u8,
    huge: bool,
};

/// Shared-memory creation preference retained for source compatibility. It
/// owns no memory and causes no allocation.
pub const CreateOptions = struct {
    huge_pages: bool,
};

/// Requested huge-page size retained for source compatibility.
pub const huge_page_size: usize = 2 * 1024 * 1024;

/// Returns `error.Unsupported` without allocating or taking ownership.
pub fn create(_: usize, _: CreateOptions) Error!Region {
    return error.Unsupported;
}

/// Returns `error.Unsupported` without allocating or taking ownership.
pub fn mapReadOnly(_: platform.Handle, _: CreateOptions) Error!Region {
    return error.Unsupported;
}

/// No-op counterpart for a region that unsupported constructors cannot create.
pub fn unmap(_: Region) void {}

/// No-op counterpart for a handle that unsupported constructors cannot create.
pub fn close(_: platform.Handle) void {}

/// Reports false without I/O because huge shared regions are unsupported.
/// No-op: huge pages are a Linux hugetlbfs feature.
pub fn warnIfHugeUnavailable(_: []const u8) void {}

/// Always false: no hugetlbfs on this platform.
pub fn hugePagesConfigured() bool {
    return false;
}

pub fn hugePagesAvailable() bool {
    return false;
}
