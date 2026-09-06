const std = @import("std");
const c = @import("native.zig").c;

pub fn connect(path: []const u8) !c_int {
    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    if (path.len >= addr.sun_path.len) return error.SocketPathTooLong;
    addr.sun_family = c.AF_UNIX;
    @memcpy(@as([*]u8, @ptrCast(&addr.sun_path))[0..path.len], path);
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    const timeout = c.struct_timeval{ .tv_sec = 3, .tv_usec = 0 };
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &timeout, @sizeOf(@TypeOf(timeout)));
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_SNDTIMEO, &timeout, @sizeOf(@TypeOf(timeout)));
    if (c.connect(fd, .{ .__sockaddr__ = @ptrCast(&addr) }, @sizeOf(@TypeOf(addr))) < 0) return error.HyprlandUnavailable;
    return fd;
}

pub fn request(a: std.mem.Allocator, path: []const u8, command: []const u8) ![]const u8 {
    const fd = try connect(path);
    defer _ = c.close(fd);
    var sent: usize = 0;
    while (sent < command.len) {
        const n = c.send(fd, command.ptr + sent, command.len - sent, c.MSG_NOSIGNAL);
        if (n < 0 and c.__errno_location().* == c.EINTR) continue;
        if (n <= 0) return error.IpcWriteFailed;
        sent += @intCast(n);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0 and c.__errno_location().* == c.EINTR) continue;
        if (n < 0) return error.IpcReadTimeout;
        if (n == 0) break;
        if (out.items.len + @as(usize, @intCast(n)) > 16 * 1024 * 1024) return error.ReplyTooLarge;
        try out.appendSlice(a, buf[0..@intCast(n)]);
    }
    if (out.items.len == 0) return error.EmptyReply;
    return out.toOwnedSlice(a);
}
