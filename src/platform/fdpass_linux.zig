//! Allocation-free Linux SCM_RIGHTS transport.
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

/// Sends borrowed byte parts and handles in one sendmsg with SCM_RIGHTS and
/// MSG_NOSIGNAL. The call allocates nothing and retains no input ownership.
///
/// O(p + h) in the parts and handles described, which is the header work; the
/// bytes themselves are handed to one sendmsg.
pub fn sendWithHandles(
    socket: platform.Handle,
    parts: []const []const u8,
    handles: []const platform.Handle,
) Error!usize {
    if (parts.len > max_parts) return error.TooManyParts;
    if (handles.len > max_handles) return error.TooManyHandles;

    var iovecs: [max_parts]std.posix.iovec_const = undefined;
    for (parts, 0..) |part, i| iovecs[i] = .{ .base = part.ptr, .len = part.len };

    var control: [cmsgSpace(max_handles * @sizeOf(platform.Handle))]u8 align(@alignOf(std.os.linux.cmsghdr)) = @splat(0);
    const control_len = if (handles.len == 0) 0 else cmsgSpace(handles.len * @sizeOf(platform.Handle));
    if (handles.len != 0) {
        const header: *std.os.linux.cmsghdr = @ptrCast(&control);
        const data_len = handles.len * @sizeOf(platform.Handle);
        header.* = .{
            .len = cmsgLen(data_len),
            .level = std.os.linux.SOL.SOCKET,
            .type = std.os.linux.SCM.RIGHTS,
        };
        const data_start = cmsgAlign(@sizeOf(std.os.linux.cmsghdr));
        const handle_data: [*]platform.Handle = @ptrCast(@alignCast(control[data_start..].ptr));
        @memcpy(handle_data[0..handles.len], handles);
    }

    const msg: std.os.linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iovecs,
        .iovlen = parts.len,
        .control = if (control_len == 0) null else &control,
        .controllen = control_len,
        .flags = 0,
    };
    while (true) {
        const rc = std.os.linux.sendmsg(socket, &msg, std.os.linux.MSG.NOSIGNAL);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            else => return error.SendFailed,
        }
    }
}

/// Receives bytes and every SCM_RIGHTS cmsg into caller storage using
/// MSG_CMSG_CLOEXEC. Returned handles transfer to the caller even when control
/// data was truncated; the call allocates nothing and retains no buffers.
///
/// O(h) in the handles received, over one recvmsg.
pub fn recvWithHandles(
    socket: platform.Handle,
    buffer: []u8,
    handles_out: []platform.Handle,
) Error!Received {
    var control: [cmsgSpace(max_handles * @sizeOf(platform.Handle))]u8 align(@alignOf(std.os.linux.cmsghdr)) = @splat(0);
    const handle_capacity = @min(handles_out.len, max_handles);
    const control_len = if (handle_capacity == 0) 0 else cmsgSpace(handle_capacity * @sizeOf(platform.Handle));
    var iovec: std.posix.iovec = .{ .base = buffer.ptr, .len = buffer.len };
    var msg: std.os.linux.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iovec),
        .iovlen = 1,
        .control = if (control_len == 0) null else &control,
        .controllen = control_len,
        .flags = 0,
    };

    const bytes = while (true) {
        const rc = std.os.linux.recvmsg(socket, &msg, std.os.linux.MSG.CMSG_CLOEXEC);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => break rc,
            .INTR => continue,
            else => return error.RecvFailed,
        }
    };

    var handle_count: usize = 0;
    var truncated = msg.flags & std.os.linux.MSG.CTRUNC != 0;
    var offset: usize = 0;
    while (offset + @sizeOf(std.os.linux.cmsghdr) <= msg.controllen) {
        const header = @as(*align(1) const std.os.linux.cmsghdr, @ptrCast(control[offset..].ptr)).*;
        const header_len = cmsgAlign(@sizeOf(std.os.linux.cmsghdr));
        if (header.len < header_len or header.len > msg.controllen - offset) {
            closeHandles(handles_out[0..handle_count]);
            return error.BadControl;
        }
        if (header.level == std.os.linux.SOL.SOCKET and header.type == std.os.linux.SCM.RIGHTS) {
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

fn cmsgAlign(len: usize) usize {
    return std.mem.alignForward(usize, len, @sizeOf(usize));
}

fn cmsgLen(data_len: usize) usize {
    return cmsgAlign(@sizeOf(std.os.linux.cmsghdr)) + data_len;
}

fn cmsgSpace(data_len: usize) usize {
    return cmsgAlign(@sizeOf(std.os.linux.cmsghdr)) + cmsgAlign(data_len);
}

fn closeHandles(handles: []const platform.Handle) void {
    for (handles) |handle| std.Io.Threaded.closeFd(handle);
}
