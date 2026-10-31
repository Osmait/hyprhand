const std = @import("std");
const native = @import("native.zig");
const c = native.c;

const max_reply_bytes = 16 * 1024 * 1024;
pub const Options = struct {
    timeout_ms: u32 = 3000,
    // Only bounded teardown may ignore an already-received cancellation.
    cancellable: bool = true,
};

fn ready(fd: c_int, events: c_short, deadline: i64, cancellable: bool) !bool {
    while (true) {
        if (cancellable) try native.check_cancelled();
        const remaining = deadline - native.now_ms();
        if (remaining <= 0) return false;
        var poll_descriptor = c.struct_pollfd{ .fd = fd, .events = events, .revents = 0 };
        const result = c.poll(&poll_descriptor, 1, @intCast(@min(50, remaining)));
        if (result < 0) {
            if (native.errno() == c.EINTR) continue;
            return error.IpcPollFailed;
        }
        // HUP/ERR also wake the caller so recv/send can report EOF or failure.
        if (result > 0) return true;
    }
}

pub fn connect(path: []const u8) !c_int {
    return connect_until(path, native.now_ms() + 3000, true);
}

fn connect_until(path: []const u8, deadline: i64, cancellable: bool) !c_int {
    if (cancellable) try native.check_cancelled();
    var address = std.mem.zeroes(c.struct_sockaddr_un);
    if (path.len >= address.sun_path.len) return error.SocketPathTooLong;
    if (path.len == 0) return error.InvalidSocketPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidSocketPath;

    address.sun_family = c.AF_UNIX;
    @memcpy(@as([*]u8, @ptrCast(&address.sun_path))[0..path.len], path);
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);

    const connected = c.connect(
        fd,
        .{ .__sockaddr__ = @ptrCast(&address) },
        @sizeOf(@TypeOf(address)),
    );
    if (connected < 0) {
        // AF_UNIX EAGAIN (full backlog) is not an in-progress connection.
        if (native.errno() != c.EINPROGRESS) return error.HyprlandUnavailable;
        if (!try ready(fd, c.POLLOUT, deadline, cancellable)) return error.HyprlandUnavailable;
        var socket_error: c_int = 0;
        var length: c.socklen_t = @sizeOf(c_int);
        const queried = c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &socket_error, &length);
        if (queried < 0) return error.HyprlandUnavailable;
        if (socket_error != 0) return error.HyprlandUnavailable;
    }
    return fd;
}

pub fn request(allocator: std.mem.Allocator, path: []const u8, command: []const u8) ![]const u8 {
    return request_with_options(allocator, path, command, .{});
}

pub fn request_with_options(
    allocator: std.mem.Allocator,
    path: []const u8,
    command: []const u8,
    options: Options,
) ![]const u8 {
    // One monotonic budget for connect, send and the entire reply. A peer
    // trickling bytes must not keep refreshing a per-read timeout forever.
    const started_ms = native.now_ms();
    const budget_ms = if (options.cancellable)
        try native.remaining_ms(options.timeout_ms)
    else
        options.timeout_ms;
    const deadline = started_ms + budget_ms;
    const fd = try connect_until(path, deadline, options.cancellable);
    defer _ = c.close(fd);

    var sent: usize = 0;
    while (sent < command.len) {
        if (!try ready(fd, c.POLLOUT, deadline, options.cancellable)) return error.IpcWriteFailed;
        const written = c.send(fd, command.ptr + sent, command.len - sent, c.MSG_NOSIGNAL);
        if (written < 0 and native.errno() == c.EINTR) continue;
        if (written < 0 and native.errno() == c.EAGAIN) continue;
        if (written <= 0) return error.IpcWriteFailed;
        sent += @intCast(written);
    }

    var reply: std.ArrayList(u8) = .empty;
    errdefer reply.deinit(allocator);
    var buffer: [8192]u8 = undefined;
    while (true) {
        if (!try ready(fd, c.POLLIN, deadline, options.cancellable)) return error.IpcReadTimeout;
        const count = c.read(fd, &buffer, buffer.len);
        if (count < 0 and native.errno() == c.EINTR) continue;
        if (count < 0 and native.errno() == c.EAGAIN) continue;
        if (count < 0) return error.IpcReadFailed;
        if (count == 0) break;
        const size: usize = @intCast(count);
        if (reply.items.len + size > max_reply_bytes) return error.ReplyTooLarge;
        try reply.appendSlice(allocator, buffer[0..size]);
    }

    if (reply.items.len == 0) return error.EmptyReply;
    return reply.toOwnedSlice(allocator);
}
