//! Darwin POSIX shared-memory regions.
//!
//! There is no `memfd_create`, so a region is a `shm_open`ed object created
//! with an exclusive one-shot name that is `shm_unlink`ed immediately: the
//! descriptor keeps the object alive, nothing is left in the global namespace
//! for another process or a crash to collide with, and the handle passes over
//! the socket exactly like a memfd does. There is no huge-page class at all on
//! macOS — no hugetlbfs, no `MAP_POPULATE` — so `huge` is always false and the
//! hugetlb notice never fires.
const std = @import("std");
const platform = @import("platform.zig");

/// Whether this build can create shared regions at all. Callers gate the
/// zero-copy path on it rather than on `builtin.os.tag`.
pub const supported = true;

/// Whether a huge-page class exists on this platform at all: macOS has no hugetlbfs equivalent, so the preference can never be honoured.
/// Comptime, unlike `hugePagesConfigured`, which asks how the running kernel
/// is set up. Callers use it to avoid advertising a preference that cannot
/// apply.
pub const huge_supported = false;

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

/// Shared-memory creation preference. Huge pages do not exist on this
/// platform, so the request is accepted and ignored rather than failing.
pub const CreateOptions = struct {
    huge_pages: bool,
};

/// Size of the huge-page class the Linux implementation requests. Kept so the
/// shared API is identical; nothing here can provide it.
pub const huge_page_size: usize = 2 * 1024 * 1024;

/// `PSHMNAMLEN` is 31 on Darwin, so the generated name must stay short.
const max_name_len = 31;

/// Distinguishes concurrent regions within this process; the pid distinguishes
/// processes. Only the window between `shm_open` and `shm_unlink` can collide,
/// and `O_EXCL` turns a collision into a retry rather than a shared object.
var name_counter = std.atomic.Value(u32).init(0);
const name_attempts = 8;

/// Creates and maps a writable shared region. The caller owns the returned
/// mapping and handle and must call `unmap` and `close`; no allocator is used.
/// `options.huge_pages` is ignored: `region.huge` is always false.
pub fn create(len: usize, options: CreateOptions) Error!Region {
    _ = options;
    if (len == 0) return error.InvalidLength;
    const map_len = try roundedLength(len, std.heap.page_size_min);

    const handle = try openExclusive();
    errdefer close(handle);
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    try file.setLength(std.Io.Threaded.global_single_threaded.io(), map_len);
    const map = try std.posix.mmap(
        null,
        map_len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        handle,
        0,
    );
    return .{ .handle = handle, .map = map, .huge = false };
}

/// Maps the complete caller-owned region read-only. The returned mapping is
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
        .{ .TYPE = .SHARED },
        handle,
        0,
    );
    return .{ .handle = handle, .map = map, .huge = false };
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

/// No-op: there is no huge-page class to be misconfigured on this platform,
/// so there is nothing to advise about.
pub fn warnIfHugeUnavailable(_: []const u8) void {}

/// Always false: macOS has no hugetlbfs equivalent.
pub fn hugePagesConfigured() bool {
    return false;
}

/// Always false: macOS has no hugetlbfs equivalent.
pub fn hugePagesAvailable() bool {
    return false;
}

/// Opens a fresh shared-memory object and unlinks its name, leaving the
/// returned descriptor as its only reference. The caller owns it.
fn openExclusive() Error!platform.Handle {
    const pid: u32 = @bitCast(std.c.getpid());
    var attempt: u32 = 0;
    while (attempt < name_attempts) : (attempt += 1) {
        var name_buffer: [max_name_len + 1]u8 = undefined;
        const name = std.fmt.bufPrintSentinel(&name_buffer, "/vertex-{x}-{x}", .{
            pid,
            name_counter.fetchAdd(1, .monotonic),
        }, 0) catch return error.NameTooLong;

        const rc = shm_open(name.ptr, @bitCast(std.c.O{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .EXCL = true,
        }), 0o600);
        if (rc >= 0) {
            // The descriptor holds the object; drop the name so no other
            // process can open it and nothing survives a crash.
            _ = std.c.shm_unlink(name.ptr);
            return rc;
        }
        switch (std.posix.errno(rc)) {
            .EXIST => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.OutOfMemory,
            .NAMETOOLONG => return error.NameTooLong,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
    return error.SystemFdQuotaExceeded;
}

fn roundedLength(len: usize, alignment: usize) error{SharedTooLarge}!usize {
    const with_slack = std.math.add(usize, len, alignment - 1) catch return error.SharedTooLarge;
    return with_slack & ~(alignment - 1);
}

/// Variadic in C (the mode argument is read only when `O_CREAT` is set), so it
/// is declared here with the one signature this module uses rather than taken
/// from `std.c`, which does not expose it.
extern "c" fn shm_open(name: [*:0]const u8, oflag: c_int, mode: std.c.mode_t) platform.Handle;
