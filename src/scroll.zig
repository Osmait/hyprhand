const std = @import("std");
const motion = @import("motion.zig");
const Point = @import("geometry.zig").Point;

/// Ease cumulative distance, then emit only the difference. This preserves
/// signed totals (including sub-pixel remainders) despite scheduler delays.
pub fn run(driver: anytype, total: Point, ms: u32) !void {
    if (total.x == 0 and total.y == 0) return;
    if (ms == 0) return driver.emit(total);
    const start = driver.now();
    var sent = Point{ .x = 0, .y = 0 };
    while (true) {
        const elapsed = @max(0, driver.now() - start);
        if (elapsed < ms) try driver.pause(@intCast(@min(16, ms - elapsed)));
        const t = @min(1, @as(f64, @floatFromInt(@max(0, driver.now() - start))) / @as(f64, @floatFromInt(ms)));
        const next = motion.point(.{ .x = 0, .y = 0 }, total, t);
        const delta = Point{ .x = next.x - sent.x, .y = next.y - sent.y };
        if (delta.x != 0 or delta.y != 0) try driver.emit(delta);
        sent = next;
        if (t >= 1) break;
    }
}

const Fake = struct {
    clock: i64 = 0,
    cost: i64 = 0,
    cancel_at: i64 = 100000,
    sum: Point = .{ .x = 0, .y = 0 },
    count: usize = 0,
    pub fn now(self: *@This()) i64 {
        return self.clock;
    }
    pub fn pause(self: *@This(), ms: u32) !void {
        self.clock += ms;
        if (self.clock >= self.cancel_at) return error.ControlStopped;
    }
    pub fn emit(self: *@This(), delta: Point) !void {
        if (self.clock >= self.cancel_at) return error.ControlStopped;
        self.sum.x += delta.x;
        self.sum.y += delta.y;
        self.count += 1;
        self.clock += self.cost;
    }
};

test "scroll conserves signed fixed-point distances and finishes on time" {
    const total = Point{ .x = -3 * 15 * 256, .y = 7 * 15 * 256 };
    var f = Fake{};
    try run(&f, total, 500);
    try std.testing.expectEqual(total, f.sum);
    try std.testing.expectEqual(@as(i64, 500), f.clock);
    try std.testing.expect(f.count >= 20);
    var slow = Fake{ .cost = 40 };
    try run(&slow, total, 500);
    try std.testing.expectEqual(total, slow.sum);
    try std.testing.expect(slow.clock <= 580);
    try std.testing.expect(slow.count < f.count);
}

test "scroll handles zero, instant, discrete fallback and cancellation" {
    var zero = Fake{};
    try run(&zero, .{ .x = 0, .y = 0 }, 500);
    try std.testing.expectEqual(@as(usize, 0), zero.count);
    var instant = Fake{};
    try run(&instant, .{ .x = -2, .y = 3 }, 0);
    try std.testing.expectEqual(@as(usize, 1), instant.count);
    var wheel = Fake{};
    try run(&wheel, .{ .x = -2, .y = 3 }, 500);
    try std.testing.expectEqual(instant.sum, wheel.sum);
    var cancelled = Fake{ .cancel_at = 160 };
    try std.testing.expectError(error.ControlStopped, run(&cancelled, .{ .x = 0, .y = 38400 }, 500));
    try std.testing.expect(cancelled.sum.y > 0 and cancelled.sum.y < 38400);
}
