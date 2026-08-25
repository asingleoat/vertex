//! Allocation-free Darwin SCM_RIGHTS transport.
//!
//! The mechanism is the same as on Linux, but three details differ and each
//! would fail silently if the Linux implementation were copied unchanged.
//! `CMSG_ALIGN` is `__DARWIN_ALIGN32`, so control data aligns to four bytes
//! rather than to `sizeof(size_t)`, and the Linux arithmetic computes incorrect
//! lengths and offsets. There is no `MSG_NOSIGNAL`, so the socket is given
//! `SO_NOSIGPIPE` instead and a send to a departed viewer returns `EPIPE`
//! rather than terminating the process. There is no `MSG_CMSG_CLOEXEC`, so
//! received descriptors are marked close-on-exec individually.
const std = @import("std");
const platform = @import("platform.zig");

const max_parts = 64;
const max_handles = 64;

/// Whether this build can pass handles over a socket. When it is false, a
/// caller that needs only the bytes reads them with an ordinary read; ownership
/// rules are unaffected either way.
pub const supported = true;

/// Errors from one allocation-free sendmsg or recvmsg operation. On receive
/// errors, the implementation closes any handles it already extracted.
pub const Error = error{
    Unsupported,
    TooManyParts,
    TooManyHandles,
    SendFailed,
    RecvFailed,
    BadControl,
};

/// Result of one recvmsg call. Handles occupy `handles_out[0..handle_count]`
/// and transfer to the caller even when `control_truncated` is true.
pub const Received = struct {
    bytes: usize,
    handle_count: usize,
    control_truncated: bool,
};

/// Sends borrowed byte parts and handles in one sendmsg with SCM_RIGHTS. The
/// call allocates nothing and retains no input ownership.
pub fn sendWithHandles(
    socket: platform.Handle,
    parts: []const []const u8,
    handles: []const platform.Handle,
) Error!usize {
    if (parts.len > max_parts) return error.TooManyParts;
    if (handles.len > max_handles) return error.TooManyHandles;

    // Darwin's equivalent of MSG_NOSIGNAL is a socket option rather than a
    // per-message flag, so it is set here. The call is idempotent and
    // inexpensive relative to the sendmsg it guards, and this path runs once
    // per message carrying a shared section, not once per byte.
    suppressSigpipe(socket);

    var iovecs: [max_parts]std.posix.iovec_const = undefined;
    for (parts, 0..) |part, i| iovecs[i] = .{ .base = part.ptr, .len = part.len };

    var control: [cmsgSpace(max_handles * @sizeOf(platform.Handle))]u8 align(@alignOf(std.c.cmsghdr)) = @splat(0);
    const control_len = if (handles.len == 0) 0 else cmsgSpace(handles.len * @sizeOf(platform.Handle));
    if (handles.len != 0) {
        const header: *std.c.cmsghdr = @ptrCast(&control);
        const data_len = handles.len * @sizeOf(platform.Handle);
        header.* = .{
            .len = @intCast(cmsgLen(data_len)),
            .level = std.c.SOL.SOCKET,
            .type = std.c.SCM.RIGHTS,
        };
        const data_start = cmsgAlign(@sizeOf(std.c.cmsghdr));
        const handle_data: [*]platform.Handle = @ptrCast(@alignCast(control[data_start..].ptr));
        @memcpy(handle_data[0..handles.len], handles);
    }

    const msg: std.c.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iovecs,
        .iovlen = @intCast(parts.len),
        .control = if (control_len == 0) null else &control,
        .controllen = @intCast(control_len),
        .flags = 0,
    };
    while (true) {
        const rc = std.c.sendmsg(socket, &msg, 0);
        if (rc >= 0) return @intCast(rc);
        switch (std.posix.errno(rc)) {
            .INTR => continue,
            else => return error.SendFailed,
        }
    }
}

/// Receives bytes and every SCM_RIGHTS cmsg into caller storage. Returned
/// handles transfer to the caller even when control data was truncated; the
/// call allocates nothing and retains no buffers.
pub fn recvWithHandles(
    socket: platform.Handle,
    buffer: []u8,
    handles_out: []platform.Handle,
) Error!Received {
    var control: [cmsgSpace(max_handles * @sizeOf(platform.Handle))]u8 align(@alignOf(std.c.cmsghdr)) = @splat(0);
    const handle_capacity = @min(handles_out.len, max_handles);
    const control_len = if (handle_capacity == 0) 0 else cmsgSpace(handle_capacity * @sizeOf(platform.Handle));
    var iovec: std.posix.iovec = .{ .base = buffer.ptr, .len = buffer.len };
    var msg: std.c.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iovec),
        .iovlen = 1,
        .control = if (control_len == 0) null else &control,
        .controllen = @intCast(control_len),
        .flags = 0,
    };

    const bytes = while (true) {
        const rc = recvmsg(socket, &msg, 0);
        if (rc >= 0) break @as(usize, @intCast(rc));
        switch (std.posix.errno(rc)) {
            .INTR => continue,
            else => return error.RecvFailed,
        }
    };

    var handle_count: usize = 0;
    var truncated = msg.flags & std.c.MSG.CTRUNC != 0;
    var offset: usize = 0;
    while (offset + @sizeOf(std.c.cmsghdr) <= msg.controllen) {
        const header = @as(*align(1) const std.c.cmsghdr, @ptrCast(control[offset..].ptr)).*;
        const header_len = cmsgAlign(@sizeOf(std.c.cmsghdr));
        if (header.len < header_len or header.len > msg.controllen - offset) {
            closeHandles(handles_out[0..handle_count]);
            return error.BadControl;
        }
        if (header.level == std.c.SOL.SOCKET and header.type == std.c.SCM.RIGHTS) {
            const data_len = header.len - header_len;
            if (data_len % @sizeOf(platform.Handle) != 0) {
                closeHandles(handles_out[0..handle_count]);
                return error.BadControl;
            }
            const count = data_len / @sizeOf(platform.Handle);
            const data = control[offset + header_len ..][0..data_len];
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const handle = @as(*align(1) const platform.Handle, @ptrCast(data[i * @sizeOf(platform.Handle) ..].ptr)).*;
                if (handle_count < handles_out.len) {
                    // Without MSG_CMSG_CLOEXEC each descriptor is marked
                    // individually. A failure here is ignored rather than
                    // costing the handle: its only consequence is that the
                    // descriptor would survive an exec, which this program
                    // does not perform.
                    _ = std.c.fcntl(handle, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
                    handles_out[handle_count] = handle;
                    handle_count += 1;
                } else {
                    std.Io.Threaded.closeFd(handle);
                    truncated = true;
                }
            }
        }
        offset += cmsgAlign(header.len);
    }

    return .{
        .bytes = bytes,
        .handle_count = handle_count,
        .control_truncated = truncated,
    };
}

/// Implements `__DARWIN_ALIGN32`: control data aligns to four bytes here, where
/// Linux aligns to `sizeof(size_t)`.
fn cmsgAlign(len: usize) usize {
    return std.mem.alignForward(usize, len, @sizeOf(u32));
}

fn cmsgLen(data_len: usize) usize {
    return cmsgAlign(@sizeOf(std.c.cmsghdr)) + data_len;
}

fn cmsgSpace(data_len: usize) usize {
    return cmsgAlign(@sizeOf(std.c.cmsghdr)) + cmsgAlign(data_len);
}

fn closeHandles(handles: []const platform.Handle) void {
    for (handles) |handle| std.Io.Threaded.closeFd(handle);
}

/// Sets `SO_NOSIGPIPE` on a best-effort basis. A socket that rejects the option
/// still sends correctly, but risks `SIGPIPE` if the peer has gone, which is the
/// existing behaviour of every other write in the program.
fn suppressSigpipe(socket: platform.Handle) void {
    const on: c_int = 1;
    _ = std.c.setsockopt(
        socket,
        std.c.SOL.SOCKET,
        std.c.SO.NOSIGPIPE,
        @ptrCast(&on),
        @sizeOf(c_int),
    );
}

/// `std.c` declares `recvmsg` without exporting it.
extern "c" fn recvmsg(socket: platform.Handle, msg: *std.c.msghdr, flags: u32) isize;
