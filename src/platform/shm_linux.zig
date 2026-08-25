//! Linux memfd-backed shared-memory regions with optional hugetlb pages.
const std = @import("std");
const platform = @import("platform.zig");
const procfs = @import("procfs_linux.zig");

const linux = std.os.linux;
const mfd_hugetlb: u32 = if (@hasDecl(linux.MFD, "HUGETLB")) linux.MFD.HUGETLB else 0x4;
const mfd_huge_shift: u5 = if (@hasDecl(linux.MFD, "HUGE_SHIFT")) linux.MFD.HUGE_SHIFT else 26;
const mfd_huge_2mb: u32 = if (@hasDecl(linux.MFD, "HUGE_2MB")) linux.MFD.HUGE_2MB else @as(u32, 21) << mfd_huge_shift;
const hugetlbfs_magic: usize = 0x958458f6;

/// Whether this build can create shared regions at all. Callers gate the
/// zero-copy path on it rather than on `builtin.os.tag`, so a port turns the
/// path on by flipping one constant.
pub const supported = true;

/// Errors from creating or mapping a region. Failed calls leave no mapping or
/// handle owned by the caller.
pub const Error = std.posix.MemFdCreateError || std.Io.File.SetLengthError ||
    std.Io.File.LengthError || std.posix.MMapError || error{
    Unsupported,
    InvalidLength,
    SharedTooLarge,
};

/// One mapped file region. The caller owns `map`; a region returned by
/// `create` also gives it ownership of `handle`, while `mapReadOnly` leaves the
/// already-owned handle with its caller. Unmap each map and close each handle
/// exactly once.
pub const Region = struct {
    handle: platform.Handle,
    map: []align(std.heap.page_size_min) u8,
    huge: bool,
};

/// Shared-memory creation preference. Enabling huge pages only requests them;
/// creation transparently falls back to ordinary pages without allocation.
pub const CreateOptions = struct {
    huge_pages: bool,
};

/// Size of the hugetlb page class requested by `create`.
pub const huge_page_size: usize = 2 * 1024 * 1024;

/// Creates and maps a writable memfd. The caller owns the returned mapping and
/// handle and must call `unmap` and `close`; no allocator is used. Large huge
/// requests fall back silently when the kernel cannot provide hugetlb pages.
/// After a failed hugetlb attempt (no contiguous 2 MiB pages obtainable right
/// now), skip this many subsequent huge attempts so a fragmented machine never
/// pays the failed-attempt cost on every buffer.
const huge_failure_cooldown: u32 = 8;
var huge_cooldown = std.atomic.Value(u32).init(0);

pub fn create(len: usize, options: CreateOptions) Error!Region {
    if (len == 0) return error.InvalidLength;
    if (options.huge_pages and len >= huge_page_size) {
        const remaining = huge_cooldown.load(.monotonic);
        if (remaining > 0) {
            huge_cooldown.store(remaining - 1, .monotonic);
        } else if (try createHuge(len)) |region| {
            return region;
        } else {
            huge_cooldown.store(huge_failure_cooldown, .monotonic);
        }
    }
    return createOrdinary(len);
}

/// True when the kernel is configured to hand out 2 MiB hugetlb pages at all
/// (`vm.nr_overcommit_hugepages` or `vm.nr_hugepages` nonzero). Allocation
/// can still fail transiently on a fragmented machine; `create` handles that
/// by falling back, so this is only for the misconfiguration notice.
pub fn hugePagesConfigured() bool {
    var buffer: [64]u8 = undefined;
    inline for (.{ "/proc/sys/vm/nr_overcommit_hugepages", "/proc/sys/vm/nr_hugepages" }) |path| {
        if (procfs.readProc(path, &buffer)) |bytes| {
            if ((procfs.parseUnsigned(bytes) orelse 0) > 0) return true;
        }
    }
    return false;
}

/// Maps the complete caller-owned memfd read-only. The returned mapping is
/// caller-owned and must be passed to `unmap`; the input handle remains owned
/// by the caller and must be closed separately. No allocator is used.
pub fn mapReadOnly(handle: platform.Handle, options: CreateOptions) Error!Region {
    _ = options;
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    const size = try file.length(std.Io.Threaded.global_single_threaded.io());
    if (size == 0) return error.InvalidLength;
    if (size > std.math.maxInt(usize)) return error.SharedTooLarge;
    const map = try std.posix.mmap(
        null,
        @intCast(size),
        .{ .READ = true },
        .{ .TYPE = .SHARED, .POPULATE = true },
        handle,
        0,
    );
    return .{
        .handle = handle,
        .map = map,
        .huge = size % huge_page_size == 0 and isHugetlbfs(handle),
    };
}

/// Unmaps `region.map` without closing `region.handle`; this function allocates
/// nothing and consumes the mapping ownership only.
pub fn unmap(region: Region) void {
    std.posix.munmap(region.map);
}

/// Closes one owned handle without unmapping any associated region. It is not
/// safe to call twice for the same ownership and allocates nothing.
pub fn close(handle: platform.Handle) void {
    std.Io.Threaded.closeFd(handle);
}

/// Reports whether the configured huge-page pool can currently satisfy some
/// demand. This is informational only: `create` always tries and falls back.
/// The proc files are read on demand into fixed stack buffers without caching.
var huge_notice_shown = std.atomic.Value(bool).init(false);

/// Prints, once per process, that the kernel is not configured for hugetlb
/// pages and the sysctl that enables them. Callers gate on `hugePagesConfigured`. `context` names the caller
/// ("shared buffer", "viewer startup"). Informational only; the ordinary
/// memfd path is already in effect when this is called.
pub fn warnIfHugeUnavailable(context: []const u8) void {
    if (huge_notice_shown.swap(true, .acq_rel)) return;
    std.debug.print(
        "vertex: hugetlb pages are not configured ({s}): vm.nr_overcommit_hugepages=0 and " ++
            "vm.nr_hugepages=0, so shared buffers use 4 KiB pages. Enable 2 MiB pages on demand with: " ++
            "sudo sysctl vm.nr_overcommit_hugepages=1024 " ++
            "(NixOS: boot.kernel.sysctl.\"vm.nr_overcommit_hugepages\" = 1024;). " ++
            "Set VERTEX_SHARED_HUGE=0 to silence this.\n",
        .{context},
    );
}

pub fn hugePagesAvailable() bool {
    var overcommit_buffer: [64]u8 = undefined;
    if (procfs.readProc("/proc/sys/vm/nr_overcommit_hugepages", &overcommit_buffer)) |bytes| {
        if (procfs.parseUnsigned(bytes)) |count| {
            if (count > 0) return true;
        }
    }

    var meminfo_buffer: [16 * 1024]u8 = undefined;
    const meminfo = procfs.readProc("/proc/meminfo", &meminfo_buffer) orelse return false;
    return (procfs.parseLabeledUnsigned(meminfo, "HugePages_Free:") orelse 0) > 0;
}

fn createHuge(len: usize) Error!?Region {
    const map_len = try roundedLength(len, huge_page_size);
    const handle = std.posix.memfd_create(
        "vertex",
        linux.MFD.CLOEXEC | mfd_hugetlb | mfd_huge_2mb,
    ) catch |err| switch (err) {
        // Zig maps Linux EINVAL for memfd_create to NameTooLong; this literal
        // name is valid, so the error means the huge flags are unsupported.
        error.NameTooLong, error.SystemOutdated => return null,
        else => return err,
    };
    errdefer close(handle);
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    try file.setLength(std.Io.Threaded.global_single_threaded.io(), map_len);
    const map = std.posix.mmap(
        null,
        map_len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED, .POPULATE = true },
        handle,
        0,
    ) catch |err| switch (err) {
        error.OutOfMemory => {
            close(handle);
            return null;
        },
        else => return err,
    };
    return .{ .handle = handle, .map = map, .huge = true };
}

fn createOrdinary(len: usize) Error!Region {
    const map_len = try roundedLength(len, std.heap.page_size_min);
    const handle = try std.posix.memfd_create("vertex", linux.MFD.CLOEXEC);
    errdefer close(handle);
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    try file.setLength(std.Io.Threaded.global_single_threaded.io(), map_len);
    const map = try std.posix.mmap(
        null,
        map_len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED, .POPULATE = true },
        handle,
        0,
    );
    return .{ .handle = handle, .map = map, .huge = false };
}

fn roundedLength(len: usize, alignment: usize) error{SharedTooLarge}!usize {
    const with_slack = std.math.add(usize, len, alignment - 1) catch return error.SharedTooLarge;
    return with_slack & ~(alignment - 1);
}

fn isHugetlbfs(handle: platform.Handle) bool {
    if (comptime @hasDecl(linux, "fstatfs")) {
        return callFstatfs(@field(linux, "fstatfs"), handle);
    }
    // This pinned Zig master has no public fstatfs wrapper, so the receiver
    // conservatively reports false while creators still know the actual mode.
    return false;
}

fn callFstatfs(comptime fstatfs: anytype, handle: platform.Handle) bool {
    const function = @typeInfo(@TypeOf(fstatfs)).@"fn";
    const stat_pointer = function.params[1].type orelse return false;
    const StatFs = @typeInfo(stat_pointer).pointer.child;
    var info: StatFs = undefined;
    if (linux.errno(fstatfs(handle, &info)) != .SUCCESS) return false;
    const filesystem_type = if (@hasField(StatFs, "type"))
        @field(info, "type")
    else if (@hasField(StatFs, "f_type"))
        @field(info, "f_type")
    else
        return false;
    return @as(usize, @intCast(filesystem_type)) == hugetlbfs_magic;
}
