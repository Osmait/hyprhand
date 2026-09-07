const std = @import("std");

pub const Cadence = struct {
    interval_ms: i64,
    unchanged: u32 = 0,

    pub fn completed(self: *Cadence, started: i64, finished: i64, changed: bool) i64 {
        self.unchanged = if (changed) 0 else self.unchanged +| 1;
        const idle_ms: i64 = if (self.unchanged >= 30) 1000 else if (self.unchanged >= 10) 400 else 0;
        // Backpressure leaves headroom when capture itself exceeds the target
        // period. Timers are wakeups, not a source of queued capture work.
        const cost = @max(0, finished - started);
        const period = @max(@max(self.interval_ms, idle_ms), cost + @divTrunc(cost, 4));
        return @max(finished, started + period);
    }
};

test "cadence bounds idle age, leaves slow-capture headroom and resumes on change" {
    var cadence = Cadence{ .interval_ms = 67 };
    try std.testing.expectEqual(@as(i64, 125), cadence.completed(0, 100, true));
    for (0..30) |_| _ = cadence.completed(0, 20, false);
    try std.testing.expectEqual(@as(i64, 1000), cadence.completed(0, 20, false));
    try std.testing.expectEqual(@as(i64, 67), cadence.completed(0, 20, true));
}
