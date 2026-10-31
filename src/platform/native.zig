pub const c = @import("native_c");

const std = @import("std");

var cancelled = std.atomic.Value(bool).init(false);
// One CLI command runs per process. Child cleanup deliberately does not consult
// this budget, so deadline expiry cannot suppress release/reaping.
var command_deadline: ?i64 = null;
var deadline_error: anyerror = error.CommandTimeout;

pub fn limitCommand(ms: u32, err: anyerror) void {
    command_deadline = nowMs() + ms;
    deadline_error = err;
}

pub fn clearCommandLimit() void {
    command_deadline = null;
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

/// Wayland event timestamps are 32-bit milliseconds; wrapping is expected.
pub fn timestampMs() u32 {
    return @truncate(@as(u64, @intCast(nowMs())));
}

pub fn sleepMs(ms: u32) void {
    var t = c.struct_timespec{ .tv_sec = @intCast(ms / 1000), .tv_nsec = @as(c_long, ms % 1000) * 1_000_000 };
    while (c.nanosleep(&t, &t) < 0 and errno() == c.EINTR) {}
}

pub fn errno() c_int {
    return c.__errno_location().*;
}

pub fn clearErrno() void {
    c.__errno_location().* = 0;
}

/// Next directory entry name, or null at the end. Distinguishes end-of-stream
/// from a failed readdir, which the raw C API only reports through errno.
pub fn nextEntry(dir: *c.DIR) !?[]const u8 {
    clearErrno();
    const entry = c.readdir(dir) orelse {
        if (errno() != 0) return error.ProcessScanFailed;
        return null;
    };
    return std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
}
