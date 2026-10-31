const std = @import("std");
const assert = std.debug.assert;
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
    const result = Point{
        .x = coordinate(from.x, to.x, eased),
        .y = coordinate(from.y, to.y, eased),
    };
    assert(between(result.x, from.x, to.x));
    assert(between(result.y, from.y, to.y));
    return result;
}

fn between(value: i32, bound_a: i32, bound_b: i32) bool {
    return value >= @min(bound_a, bound_b) and value <= @max(bound_a, bound_b);
}

fn coordinate(from: i32, to: i32, t: f64) i32 {
    const from_float: f64 = @floatFromInt(from);
    const to_float: f64 = @floatFromInt(to);
    return @intFromFloat(@round(from_float + (to_float - from_float) * t));
}

/// Driver pause/move must check cancellation. Monotonic wall time determines
/// progress: slow dispatches skip obsolete steps rather than queueing bursts.
pub fn run(driver: anytype, from: Point, to: Point, duration_ms: u32) !void {
    if (duration_ms == 0 or std.meta.eql(from, to)) {
        try driver.move(to);
        return;
    }

    const start = driver.now();
    while (true) {
        const elapsed_ms = @max(0, driver.now() - start);
        if (elapsed_ms < duration_ms) {
            try driver.pause(@intCast(@min(16, duration_ms - elapsed_ms)));
        }

        const sample_ms: f64 = @floatFromInt(@max(0, driver.now() - start));
        const progress = @min(1, sample_ms / @as(f64, @floatFromInt(duration_ms)));
        const sample = point(from, to, progress);
        try driver.move(sample);

        if (progress >= 1) {
            // The last sample is the destination itself, never an approximation.
            assert(std.meta.eql(sample, to));
            break;
        }
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
    fn pause(self: *@This(), duration_ms: u32) !void {
        self.clock += duration_ms;
        if (self.clock >= self.cancel_at) return error.ControlStopped;
    }
    fn move(self: *@This(), target: Point) !void {
        if (self.clock >= self.cancel_at) return error.ControlStopped;
        self.points[self.count] = target;
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
        const sample = point(from, to, @as(f64, @floatFromInt(step)) / 100);
        try std.testing.expect(sample.x >= previous.x);
        try std.testing.expect(sample.y <= previous.y);
        previous = sample;
    }

    const origin = Point{ .x = 0, .y = 0 };
    const target = Point{ .x = 1000, .y = 0 };
    try std.testing.expect(point(origin, target, 0.1).x < 100);
    try std.testing.expect(point(origin, target, 0.9).x > 900);
    try std.testing.expectEqual(@as(i32, 500), point(origin, target, 0.5).x);
    try std.testing.expectEqual(@as(u32, 0), duration(origin, origin));
    try std.testing.expectEqual(@as(u32, 450), duration(origin, target));
    try std.testing.expectEqual(@as(u32, 600), duration(from, to));
}

test "motion pacing, exact arrival and instant/stationary paths" {
    const from = Point{ .x = -100, .y = 50 };
    const to = Point{ .x = 900, .y = 550 };
    var driver = FakeDriver{};
    try run(&driver, from, to, 500);
    try std.testing.expectEqual(@as(usize, 32), driver.count);
    try std.testing.expectEqual(@as(i64, 500), driver.clock);
    try std.testing.expectEqual(to, driver.points[driver.count - 1]);

    var instant = FakeDriver{};
    try run(&instant, from, to, 0);
    try std.testing.expectEqual(@as(usize, 1), instant.count);
    try std.testing.expectEqual(to, instant.points[0]);

    var stationary = FakeDriver{};
    try run(&stationary, from, from, 500);
    try std.testing.expectEqual(@as(i64, 0), stationary.clock);
}

test "motion cancellation never sends the final point; slow drivers do not accumulate duration" {
    const origin = Point{ .x = 0, .y = 0 };
    const target = Point{ .x = 1000, .y = 0 };
    var cancelled = FakeDriver{ .cancel_at = 100 };
    try std.testing.expectError(error.ControlStopped, run(&cancelled, origin, target, 500));
    try std.testing.expect(cancelled.count > 0);
    try std.testing.expect(cancelled.points[cancelled.count - 1].x < target.x);

    var slow = FakeDriver{ .overhead = 30 };
    try run(&slow, origin, target, 500);
    try std.testing.expect(slow.clock <= 560);
    try std.testing.expect(slow.count < 32);
    try std.testing.expectEqual(target, slow.points[slow.count - 1]);
}
