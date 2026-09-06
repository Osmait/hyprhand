const std = @import("std");

pub const Workspace = struct { id: i64 = 0, name: []const u8 = "" };
pub const Monitor = struct {
    id: i64,
    name: []const u8,
    width: u32,
    height: u32,
    x: i32,
    y: i32,
    scale: f64,
    transform: u32,
    activeWorkspace: Workspace,
    specialWorkspace: Workspace = .{},
    focused: bool = false,
    disabled: bool = false,
    dpmsStatus: bool = true,
    pub fn rect(m: Monitor) !Rect {
        if (!std.math.isFinite(m.scale) or m.scale <= 0 or m.width == 0 or m.height == 0 or m.transform > 7)
            return error.InvalidMonitorGeometry;
        const rotated = m.transform % 2 == 1;
        // Hyprland rounds transformed output size / scale to logical pixels.
        return .{ .x = @floatFromInt(m.x), .y = @floatFromInt(m.y), .width = @round(@as(f64, @floatFromInt(if (rotated) m.height else m.width)) / m.scale), .height = @round(@as(f64, @floatFromInt(if (rotated) m.width else m.height)) / m.scale) };
    }
};

pub const Rect = struct { x: f64, y: f64, width: f64, height: f64 };
pub const Point = struct { x: i32, y: i32 };
pub const Frame = struct {
    schema_version: u32 = 2,
    session_id: []const u8 = "host",
    instance: []const u8,
    wayland_display: []const u8,
    frame_id: []const u8,
    captured_at_unix_ms: i64,
    captured_at_monotonic_ms: i64,
    max_age_ms: i64 = 30_000,
    monitor_id: []const u8,
    workspace_id: i64,
    image_path: []const u8,
    image_width: u32,
    image_height: u32,
    logical: Rect,
    layout_revision: []const u8,

    pub fn point(f: Frame, x: f64, y: f64) !Point {
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or x < 0 or y < 0 or x >= @as(f64, @floatFromInt(f.image_width)) or y >= @as(f64, @floatFromInt(f.image_height)))
            return error.CoordinatesOutOfBounds;
        if (f.image_width == 0 or f.image_height == 0 or f.logical.width <= 0 or f.logical.height <= 0)
            return error.InvalidMonitorGeometry;
        const gx = @floor(f.logical.x + x * f.logical.width / @as(f64, @floatFromInt(f.image_width)));
        const gy = @floor(f.logical.y + y * f.logical.height / @as(f64, @floatFromInt(f.image_height)));
        if (!std.math.isFinite(gx) or !std.math.isFinite(gy) or gx < std.math.minInt(i32) or gx > std.math.maxInt(i32) or gy < std.math.minInt(i32) or gy > std.math.maxInt(i32)) return error.CoordinatesOutOfBounds;
        return .{ .x = @intFromFloat(gx), .y = @intFromFloat(gy) };
    }

    pub fn validate(f: Frame, instance: []const u8, display: []const u8, revision: []const u8, now: i64) !void {
        if (f.schema_version != 2) return error.StaleObservation;
        if (!std.mem.eql(u8, f.instance, instance) or !std.mem.eql(u8, f.wayland_display, display)) return error.SessionMismatch;
        if (now < f.captured_at_monotonic_ms or now - f.captured_at_monotonic_ms > 30_000 or !std.mem.eql(u8, revision, f.layout_revision)) return error.StaleObservation;
    }
};

pub fn pngSize(header: []const u8) !struct { width: u32, height: u32 } {
    if (header.len < 24 or !std.mem.eql(u8, header[0..8], "\x89PNG\r\n\x1a\n") or !std.mem.eql(u8, header[12..16], "IHDR")) return error.InvalidScreenshot;
    const width = std.mem.readInt(u32, header[16..20], .big);
    const height = std.mem.readInt(u32, header[20..24], .big);
    if (width == 0 or height == 0) return error.InvalidScreenshot;
    return .{ .width = width, .height = height };
}

fn fixture() Frame {
    return .{ .instance = "abc", .wayland_display = "wayland-1", .frame_id = "f", .captured_at_unix_ms = 0, .captured_at_monotonic_ms = 1000, .monitor_id = "DP-1", .workspace_id = 1, .image_path = "/tmp/frame.png", .image_width = 1920, .image_height = 1080, .logical = .{ .x = -1280, .y = 100, .width = 1280, .height = 720 }, .layout_revision = "one" };
}
test "fractional scale and negative output origins" {
    const p = try fixture().point(960, 540);
    try std.testing.expectEqual(Point{ .x = -640, .y = 460 }, p);
    try std.testing.expectError(error.CoordinatesOutOfBounds, fixture().point(1920, 0));
    try std.testing.expectError(error.CoordinatesOutOfBounds, fixture().point(-1, 0));
    try std.testing.expectError(error.CoordinatesOutOfBounds, fixture().point(std.math.nan(f64), 0));
}
test "all transformed outputs use oriented logical dimensions" {
    for (0..8) |transform| {
        const m = Monitor{ .id = 0, .name = "test", .width = 1600, .height = 900, .x = 4307, .y = 0, .scale = 1, .transform = @intCast(transform), .activeWorkspace = .{} };
        const rect = try m.rect();
        try std.testing.expectEqual(@as(f64, if (transform % 2 == 1) 900 else 1600), rect.width);
    }
}
test "frames expire and reject different layouts and sessions" {
    const f = fixture();
    try f.validate("abc", "wayland-1", "one", 1100);
    try std.testing.expectError(error.StaleObservation, f.validate("abc", "wayland-1", "two", 1100));
    try std.testing.expectError(error.StaleObservation, f.validate("abc", "wayland-1", "one", 31001));
    try std.testing.expectError(error.StaleObservation, f.validate("abc", "wayland-1", "one", 999));
    try std.testing.expectError(error.SessionMismatch, f.validate("abc", "wayland-2", "one", 1100));
}
