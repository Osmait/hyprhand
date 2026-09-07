pub const c = @cImport({
    // glibc 2.44's fortify inline wrappers use GCC-only diagnostics that
    // translate-c cannot import. Use libc declarations here; Zig callers
    // retain ReleaseSafe bounds/overflow checks. Native libraries are unchanged.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/file.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/random.h");
    @cInclude("sys/prctl.h");
    @cInclude("poll.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("time.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("signal.h");
    @cInclude("dirent.h");
    @cInclude("wayland-client.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("virtual-pointer.h");
    @cInclude("virtual-keyboard.h");
    @cInclude("layer-shell.h");
    @cInclude("ext-image-copy-capture-v1.h");
    @cInclude("ext-image-capture-source-v1.h");
});

var cancelled = @import("std").atomic.Value(bool).init(false);
// One CLI command runs per process. Child cleanup deliberately does not consult
// this budget, so deadline expiry cannot suppress release/reaping.
var command_deadline: ?i64 = null;
var deadline_error: anyerror = error.CommandTimeout;

pub fn limitCommand(ms: u32, err: anyerror) void {
    command_deadline = nowMs() + ms;
    deadline_error = err;
}

pub fn remainingMs(cap: u32) !u32 {
    try checkCancelled();
    const end = command_deadline orelse return cap;
    return @intCast(@max(1, @min(cap, end - nowMs())));
}
fn onSignal(_: c_int) callconv(.c) void {
    cancelled.store(true, .monotonic);
}
pub fn signals() void {
    _ = c.signal(c.SIGINT, onSignal);
    _ = c.signal(c.SIGTERM, onSignal);
}
pub fn checkCancelled() !void {
    if (cancelled.load(.monotonic)) return error.Cancelled;
    if (command_deadline) |end| if (nowMs() >= end) return deadline_error;
}

pub fn nowMs() i64 {
    var t: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000 + @divTrunc(t.tv_nsec, 1_000_000);
}

pub fn sleepMs(ms: u32) void {
    var t = c.struct_timespec{ .tv_sec = @intCast(ms / 1000), .tv_nsec = @as(c_long, ms % 1000) * 1_000_000 };
    while (c.nanosleep(&t, &t) < 0 and c.__errno_location().* == c.EINTR) {}
}
