//! Cleanup for directly owned, unreaped std.process children only.
const std = @import("std");
const native = @import("native.zig");
const c = native.c;

pub fn terminate(child: *std.process.Child, io: std.Io) void {
    const pid = child.id orelse return;
    // An unreaped direct child cannot have its PID reused. Never call this
    // with session metadata or externally supplied PIDs.
    const fd: c_int = @intCast(c.syscall(c.SYS_pidfd_open, pid, @as(c_uint, 0)));
    defer if (fd >= 0) {
        _ = c.close(fd);
    };
    _ = c.kill(pid, c.SIGTERM);
    const deadline = native.nowMs() + 250;
    while (fd >= 0 and native.nowMs() < deadline) {
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        const ready = c.poll(&pfd, 1, 25);
        if (ready > 0) {
            child.kill(io);
            return;
        }
        if (ready < 0 and native.errno() != c.EINTR) break;
    }
    // Zig 0.16's POSIX Child.kill sends TERM and waits indefinitely. Escalate
    // explicitly first, then let Zig reap and clear its child/pipe ownership.
    _ = c.kill(pid, c.SIGKILL);
    child.kill(io);
}
