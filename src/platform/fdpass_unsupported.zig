//! Descriptor-passing stubs for targets without a vertex implementation.
const platform = @import("platform.zig");

/// Errors matching the supported descriptor-passing implementation. Stub calls
/// return only `error.Unsupported` and never transfer ownership.
pub const Error = error{
    Unsupported,
    TooManyParts,
    TooManyHandles,
    SendFailed,
    RecvFailed,
    BadControl,
};

/// Placeholder receive result. Unsupported calls never return a value or
/// transfer handles to the caller.
pub const Received = struct {
    bytes: usize,
    handle_count: usize,
    control_truncated: bool,
};

/// Returns `error.Unsupported` without allocating or taking handle ownership.
pub fn sendWithHandles(
    _: platform.Handle,
    _: []const []const u8,
    _: []const platform.Handle,
) Error!usize {
    return error.Unsupported;
}

/// Returns `error.Unsupported` without allocating or modifying output storage.
pub fn recvWithHandles(
    _: platform.Handle,
    _: []u8,
    _: []platform.Handle,
) Error!Received {
    return error.Unsupported;
}
