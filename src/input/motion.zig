const std = @import("std");
const Point = @import("../core/geometry.zig").Point;

pub fn duration(from: Point, to: Point) u32 {
    const dx = @as(f64, @floatFromInt(to.x)) - @as(f64, @floatFromInt(from.x));
    const dy = @as(f64, @floatFromInt(to.y)) - @as(f64, @floatFromInt(from.y));
    if (dx == 0 and dy == 0) return 0;
    return @intFromFloat(@min(600, 200 + @sqrt(dx * dx + dy * dy) * 0.25));
}

pub fn point(from: Point, to: Point, progress: f64) Point {
    const t = std.math.clamp(progress, 0, 1);
    // Minimum-jerk interpolation: zero velocity and acceleration at both ends.
    const eased = std.math.clamp(t * t * t * (10 + t * (-15 + 6 * t)), 0, 1);
    return .{ .x = coordinate(from.x, to.x, eased), .y = coordinate(from.y, to.y, eased) };
}

fn coordinate(from: i32, to: i32, t: f64) i32 {
    const a: f64 = @floatFromInt(from);
    const b: f64 = @floatFromInt(to);
    return @intFromFloat(@round(a + (b - a) * t));
}

/// Driver pause/move must check cancellation. Monotonic wall time determines
/// progress: slow dispatches skip obsolete steps rather than queueing bursts.
pub fn run(driver: anytype, from: Point, to: Point, ms: u32) !void {
    if (ms == 0 or std.meta.eql(from, to)) {
        try driver.move(to);
        return;
    }
    const start = driver.now();
    while (true) {
        const elapsed = @max(0, driver.now() - start);
        if (elapsed < ms) try driver.pause(@intCast(@min(16, ms - elapsed)));
        const progress = @min(1, @as(f64, @floatFromInt(@max(0, driver.now() - start))) / @as(f64, @floatFromInt(ms)));
        try driver.move(point(from, to, progress));
        if (progress >= 1) break;
    }
}

const FakeDriver = struct {
    clock: i64 = 0,
    overhead: i64 = 0,
    cancel_at: i64 = std.math.maxInt(i64),
    points: [1000]Point = undefined,
    count: usize = 0,
    fn now(self: *@This()) i64 {
        return self.clock;
    }
    fn pause(self: *@This(), ms: u32) !void {
        self.clock += ms;
        if (self.clock >= self.cancel_at) return error.ControlStopped;
    }
    fn move(self: *@This(), p: Point) !void {
        if (self.clock >= self.cancel_at) return error.ControlStopped;
        self.points[self.count] = p;
        self.count += 1;
        self.clock += self.overhead;
    }
};

test "smooth motion endpoints, monotonicity, negative and extreme coordinates" {
    const from = Point{ .x = std.math.minInt(i32), .y = std.math.maxInt(i32) };
    const to = Point{ .x = std.math.maxInt(i32), .y = std.math.minInt(i32) };
    try std.testing.expectEqual(from, point(from, to, 0));
    try std.testing.expectEqual(to, point(from, to, 1));
    var previous = from;
    for (1..101) |step| {
        const p = point(from, to, @as(f64, @floatFromInt(step)) / 100);
        try std.testing.expect(p.x >= previous.x and p.y <= previous.y);
        previous = p;
    }
    const a = Point{ .x = 0, .y = 0 };
    const b = Point{ .x = 1000, .y = 0 };
    try std.testing.expect(point(a, b, 0.1).x < 100);
    try std.testing.expect(point(a, b, 0.9).x > 900);
    try std.testing.expectEqual(@as(i32, 500), point(a, b, 0.5).x);
    try std.testing.expectEqual(@as(u32, 0), duration(a, a));
    try std.testing.expectEqual(@as(u32, 450), duration(a, b));
    try std.testing.expectEqual(@as(u32, 600), duration(from, to));
}

test "motion pacing, exact arrival and instant/stationary paths" {
    const a = Point{ .x = -100, .y = 50 };
    const b = Point{ .x = 900, .y = 550 };
    var driver = FakeDriver{};
    try run(&driver, a, b, 500);
    try std.testing.expectEqual(@as(usize, 32), driver.count);
    try std.testing.expectEqual(@as(i64, 500), driver.clock);
    try std.testing.expectEqual(b, driver.points[driver.count - 1]);
    var instant = FakeDriver{};
    try run(&instant, a, b, 0);
    try std.testing.expectEqual(@as(usize, 1), instant.count);
    try std.testing.expectEqual(b, instant.points[0]);
    var stationary = FakeDriver{};
    try run(&stationary, a, a, 500);
    try std.testing.expectEqual(@as(i64, 0), stationary.clock);
}

test "motion cancellation never sends the final point; slow drivers do not accumulate duration" {
    const a = Point{ .x = 0, .y = 0 };
    const b = Point{ .x = 1000, .y = 0 };
    var cancelled = FakeDriver{ .cancel_at = 100 };
    try std.testing.expectError(error.ControlStopped, run(&cancelled, a, b, 500));
    try std.testing.expect(cancelled.count > 0);
    try std.testing.expect(cancelled.points[cancelled.count - 1].x < b.x);
    var slow = FakeDriver{ .overhead = 30 };
    try run(&slow, a, b, 500);
    try std.testing.expect(slow.clock <= 560);
    try std.testing.expect(slow.count < 32);
    try std.testing.expectEqual(b, slow.points[slow.count - 1]);
}
