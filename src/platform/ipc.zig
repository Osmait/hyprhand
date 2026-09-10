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
        if (cancellable) try native.checkCancelled();
        const remaining = deadline - native.nowMs();
        if (remaining <= 0) return false;
        var pfd = c.struct_pollfd{ .fd = fd, .events = events, .revents = 0 };
        const result = c.poll(&pfd, 1, @intCast(@min(50, remaining)));
        if (result < 0) {
            if (native.errno() == c.EINTR) continue;
            return error.IpcPollFailed;
        }
        // HUP/ERR also wake the caller so recv/send can report EOF or failure.
        if (result > 0) return true;
    }
}

pub fn connect(path: []const u8) !c_int {
    return connectUntil(path, native.nowMs() + 3000, true);
}

fn connectUntil(path: []const u8, deadline: i64, cancellable: bool) !c_int {
    if (cancellable) try native.checkCancelled();
    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    if (path.len >= addr.sun_path.len) return error.SocketPathTooLong;
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidSocketPath;
    addr.sun_family = c.AF_UNIX;
    @memcpy(@as([*]u8, @ptrCast(&addr.sun_path))[0..path.len], path);
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    if (c.connect(fd, .{ .__sockaddr__ = @ptrCast(&addr) }, @sizeOf(@TypeOf(addr))) < 0) {
        // AF_UNIX EAGAIN (full backlog) is not an in-progress connection.
        if (native.errno() != c.EINPROGRESS) return error.HyprlandUnavailable;
        if (!try ready(fd, c.POLLOUT, deadline, cancellable)) return error.HyprlandUnavailable;
        var socket_error: c_int = 0;
        var length: c.socklen_t = @sizeOf(c_int);
        if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &socket_error, &length) < 0 or socket_error != 0) return error.HyprlandUnavailable;
    }
    return fd;
}

pub fn request(a: std.mem.Allocator, path: []const u8, command: []const u8) ![]const u8 {
    return requestWithOptions(a, path, command, .{});
}

pub fn requestWithOptions(a: std.mem.Allocator, path: []const u8, command: []const u8, options: Options) ![]const u8 {
    // One monotonic budget for connect, send and the entire reply. A peer
    // trickling bytes must not keep refreshing a per-read timeout forever.
    const deadline = native.nowMs() + if (options.cancellable) try native.remainingMs(options.timeout_ms) else options.timeout_ms;
    const fd = try connectUntil(path, deadline, options.cancellable);
    defer _ = c.close(fd);
    var sent: usize = 0;
    while (sent < command.len) {
        if (!try ready(fd, c.POLLOUT, deadline, options.cancellable)) return error.IpcWriteFailed;
        const n = c.send(fd, command.ptr + sent, command.len - sent, c.MSG_NOSIGNAL);
        if (n < 0 and (native.errno() == c.EINTR or native.errno() == c.EAGAIN)) continue;
        if (n <= 0) return error.IpcWriteFailed;
        sent += @intCast(n);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [8192]u8 = undefined;
    while (true) {
        if (!try ready(fd, c.POLLIN, deadline, options.cancellable)) return error.IpcReadTimeout;
        const n = c.read(fd, &buf, buf.len);
        if (n < 0 and (native.errno() == c.EINTR or native.errno() == c.EAGAIN)) continue;
        if (n < 0) return error.IpcReadFailed;
        if (n == 0) break;
        if (out.items.len + @as(usize, @intCast(n)) > max_reply_bytes) return error.ReplyTooLarge;
        try out.appendSlice(a, buf[0..@intCast(n)]);
    }
    if (out.items.len == 0) return error.EmptyReply;
    return out.toOwnedSlice(a);
}
