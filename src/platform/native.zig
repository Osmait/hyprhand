pub const c = @import("native_c");

const std = @import("std");

var cancelled = std.atomic.Value(bool).init(false);
// One CLI command runs per process. Child cleanup deliberately does not consult
// this budget, so deadline expiry cannot suppress release/reaping.
var command_deadline: ?i64 = null;
var deadline_error: anyerror = error.CommandTimeout;

pub fn limit_command(duration_ms: u32, timeout_error: anyerror) void {
    command_deadline = now_ms() + duration_ms;
    deadline_error = timeout_error;
}

pub fn clear_command_limit() void {
    command_deadline = null;
}

pub fn remaining_ms(limit_ms: u32) !u32 {
    try check_cancelled();
    const deadline = command_deadline orelse return limit_ms;
    return @intCast(@max(1, @min(limit_ms, deadline - now_ms())));
}
fn on_signal(_: c_int) callconv(.c) void {
    cancelled.store(true, .monotonic);
}
pub fn signals() void {
    _ = c.signal(c.SIGINT, on_signal);
    _ = c.signal(c.SIGTERM, on_signal);
}
pub fn check_cancelled() !void {
    if (cancelled.load(.monotonic)) return error.Cancelled;
    if (command_deadline) |deadline| {
        if (now_ms() >= deadline) return deadline_error;
    }
}

pub fn now_ms() i64 {
    var time: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &time);
    return time.tv_sec * 1000 + @divTrunc(time.tv_nsec, 1_000_000);
}

/// Wayland event timestamps are 32-bit milliseconds; wrapping is expected.
pub fn timestamp_ms() u32 {
    return @truncate(@as(u64, @intCast(now_ms())));
}

pub fn sleep_ms(duration_ms: u32) void {
    var remaining = c.struct_timespec{
        .tv_sec = @intCast(duration_ms / 1000),
        .tv_nsec = @as(c_long, duration_ms % 1000) * 1_000_000,
    };
    while (c.nanosleep(&remaining, &remaining) < 0 and errno() == c.EINTR) {}
}

pub fn errno() c_int {
    return c.__errno_location().*;
}

pub fn clear_errno() void {
    c.__errno_location().* = 0;
}

/// Next directory entry name, or null at the end. Distinguishes end-of-stream
/// from a failed readdir, which the raw C API only reports through errno.
pub fn next_entry(directory: *c.DIR) !?[]const u8 {
    clear_errno();
    const entry = c.readdir(directory) orelse {
        if (errno() != 0) return error.ProcessScanFailed;
        return null;
    };
    return std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
}
