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
    pub fn rect(monitor: Monitor) !Rect {
        if (!std.math.isFinite(monitor.scale)) return error.InvalidMonitorGeometry;
        if (monitor.scale <= 0) return error.InvalidMonitorGeometry;
        if (monitor.width == 0) return error.InvalidMonitorGeometry;
        if (monitor.height == 0) return error.InvalidMonitorGeometry;
        if (monitor.transform > 7) return error.InvalidMonitorGeometry;

        const rotated = monitor.transform % 2 == 1;
        const width_pixels: f64 = @floatFromInt(if (rotated) monitor.height else monitor.width);
        const height_pixels: f64 = @floatFromInt(if (rotated) monitor.width else monitor.height);
        // Hyprland rounds transformed output size / scale to logical pixels.
        return .{
            .x = @floatFromInt(monitor.x),
            .y = @floatFromInt(monitor.y),
            .width = @round(width_pixels / monitor.scale),
            .height = @round(height_pixels / monitor.scale),
        };
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

    pub fn point(frame: Frame, x: f64, y: f64) !Point {
        const image_width: f64 = @floatFromInt(frame.image_width);
        const image_height: f64 = @floatFromInt(frame.image_height);
        if (!std.math.isFinite(x)) return error.CoordinatesOutOfBounds;
        if (!std.math.isFinite(y)) return error.CoordinatesOutOfBounds;
        if (x < 0) return error.CoordinatesOutOfBounds;
        if (y < 0) return error.CoordinatesOutOfBounds;
        if (x >= image_width) return error.CoordinatesOutOfBounds;
        if (y >= image_height) return error.CoordinatesOutOfBounds;
        if (frame.image_width == 0) return error.InvalidMonitorGeometry;
        if (frame.image_height == 0) return error.InvalidMonitorGeometry;
        if (frame.logical.width <= 0) return error.InvalidMonitorGeometry;
        if (frame.logical.height <= 0) return error.InvalidMonitorGeometry;

        const global_x = @floor(frame.logical.x + x * frame.logical.width / image_width);
        const global_y = @floor(frame.logical.y + y * frame.logical.height / image_height);
        if (!std.math.isFinite(global_x)) return error.CoordinatesOutOfBounds;
        if (!std.math.isFinite(global_y)) return error.CoordinatesOutOfBounds;
        if (global_x < std.math.minInt(i32)) return error.CoordinatesOutOfBounds;
        if (global_x > std.math.maxInt(i32)) return error.CoordinatesOutOfBounds;
        if (global_y < std.math.minInt(i32)) return error.CoordinatesOutOfBounds;
        if (global_y > std.math.maxInt(i32)) return error.CoordinatesOutOfBounds;

        return .{ .x = @intFromFloat(global_x), .y = @intFromFloat(global_y) };
    }

    pub fn validate(
        frame: Frame,
        instance: []const u8,
        display: []const u8,
        revision: []const u8,
        now: i64,
    ) !void {
        if (frame.schema_version != 2) return error.StaleObservation;
        if (!std.mem.eql(u8, frame.instance, instance)) return error.SessionMismatch;
        if (!std.mem.eql(u8, frame.wayland_display, display)) return error.SessionMismatch;
        // Metadata is external input: reject negative monotonic timestamps
        // before subtraction so minInt(i64) cannot panic in ReleaseSafe.
        if (frame.captured_at_monotonic_ms < 0) return error.StaleObservation;
        if (now < frame.captured_at_monotonic_ms) return error.StaleObservation;
        if (now - frame.captured_at_monotonic_ms > 30_000) return error.StaleObservation;
        if (!std.mem.eql(u8, revision, frame.layout_revision)) return error.StaleObservation;
    }
};

pub fn png_size(header: []const u8) !struct { width: u32, height: u32 } {
    if (header.len < 24) return error.InvalidScreenshot;
    if (!std.mem.eql(u8, header[0..8], "\x89PNG\r\n\x1a\n")) return error.InvalidScreenshot;
    if (!std.mem.eql(u8, header[12..16], "IHDR")) return error.InvalidScreenshot;

    const width = std.mem.readInt(u32, header[16..20], .big);
    const height = std.mem.readInt(u32, header[20..24], .big);
    if (width == 0) return error.InvalidScreenshot;
    if (height == 0) return error.InvalidScreenshot;

    return .{ .width = width, .height = height };
}

fn fixture() Frame {
    return .{
        .instance = "abc",
        .wayland_display = "wayland-1",
        .frame_id = "f",
        .captured_at_unix_ms = 0,
        .captured_at_monotonic_ms = 1000,
        .monitor_id = "DP-1",
        .workspace_id = 1,
        .image_path = "/tmp/frame.png",
        .image_width = 1920,
        .image_height = 1080,
        .logical = .{ .x = -1280, .y = 100, .width = 1280, .height = 720 },
        .layout_revision = "one",
    };
}
test "fractional scale and negative output origins" {
    const point = try fixture().point(960, 540);
    try std.testing.expectEqual(Point{ .x = -640, .y = 460 }, point);
    try std.testing.expectError(error.CoordinatesOutOfBounds, fixture().point(1920, 0));
    try std.testing.expectError(error.CoordinatesOutOfBounds, fixture().point(-1, 0));
    try std.testing.expectError(
        error.CoordinatesOutOfBounds,
        fixture().point(std.math.nan(f64), 0),
    );
}
test "all transformed outputs use oriented logical dimensions" {
    for (0..8) |transform| {
        const monitor = Monitor{
            .id = 0,
            .name = "test",
            .width = 1600,
            .height = 900,
            .x = 4307,
            .y = 0,
            .scale = 1,
            .transform = @intCast(transform),
            .activeWorkspace = .{},
        };
        const rect = try monitor.rect();
        try std.testing.expectEqual(@as(f64, if (transform % 2 == 1) 900 else 1600), rect.width);
    }
}
test "frames expire and reject different layouts and sessions" {
    const frame = fixture();
    try frame.validate("abc", "wayland-1", "one", 1100);
    try std.testing.expectError(
        error.StaleObservation,
        frame.validate("abc", "wayland-1", "two", 1100),
    );
    try std.testing.expectError(
        error.StaleObservation,
        frame.validate("abc", "wayland-1", "one", 31001),
    );
    try std.testing.expectError(
        error.StaleObservation,
        frame.validate("abc", "wayland-1", "one", 999),
    );
    try std.testing.expectError(
        error.SessionMismatch,
        frame.validate("abc", "wayland-2", "one", 1100),
    );

    var invalid = frame;
    invalid.captured_at_monotonic_ms = std.math.minInt(i64);
    try std.testing.expectError(
        error.StaleObservation,
        invalid.validate("abc", "wayland-1", "one", 1100),
    );
}
