const std = @import("std");
const assert = std.debug.assert;

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

pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    /// The overlap of two rectangles, or null when they do not overlap.
    pub fn intersection(a: Rect, b: Rect) ?Rect {
        const left = @max(a.x, b.x);
        const top = @max(a.y, b.y);
        const right = @min(a.x + a.width, b.x + b.width);
        const bottom = @min(a.y + a.height, b.y + b.height);
        if (right <= left) return null;
        if (bottom <= top) return null;
        return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
    }

    /// The smallest rectangle of whole logical pixels that covers `rect`.
    pub fn whole_pixels(rect: Rect) Rect {
        const left = @floor(rect.x);
        const top = @floor(rect.y);
        return .{
            .x = left,
            .y = top,
            .width = @ceil(rect.x + rect.width) - left,
            .height = @ceil(rect.y + rect.height) - top,
        };
    }
};
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
    /// The grim scale factor: image pixels per logical pixel.
    capture_scale: f64 = 1,
    /// The window `observe --window` cropped to, if any.
    window: ?[]const u8 = null,
    /// SHA-256 of the image file, lowercase hex; compared by `observe --since`.
    image_sha256: []const u8 = "",

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

    /// The logical desktop box covering the frame pixels between two corners,
    /// given in either order. Both corner pixels are inside the box.
    pub fn box(frame: Frame, x0: f64, y0: f64, x1: f64, y1: f64) !Rect {
        const first = try frame.point(@min(x0, x1), @min(y0, y1));
        const last = try frame.point(@max(x0, x1), @max(y0, y1));
        assert(last.x >= first.x);
        assert(last.y >= first.y);

        return .{
            .x = @floatFromInt(first.x),
            .y = @floatFromInt(first.y),
            .width = @floatFromInt(@as(i64, last.x) - first.x + 1),
            .height = @floatFromInt(@as(i64, last.y) - first.y + 1),
        };
    }

    /// The frame pixel that shows the desktop point, or null outside the frame.
    /// At a capture scale of 1 or more it inverts `point`: `point(pixel(p))`
    /// is `p`. A downscaled frame returns the pixel that contains `p`.
    pub fn pixel(frame: Frame, desktop: Point) ?Point {
        if (frame.image_width == 0) return null;
        if (frame.image_height == 0) return null;
        if (frame.logical.width <= 0) return null;
        if (frame.logical.height <= 0) return null;

        const image_width: f64 = @floatFromInt(frame.image_width);
        const image_height: f64 = @floatFromInt(frame.image_height);
        const offset_x = @as(f64, @floatFromInt(desktop.x)) - frame.logical.x;
        const offset_y = @as(f64, @floatFromInt(desktop.y)) - frame.logical.y;
        const x = pixel_axis(offset_x, image_width / frame.logical.width);
        const y = pixel_axis(offset_y, image_height / frame.logical.height);
        if (x < 0) return null;
        if (y < 0) return null;
        if (x >= image_width) return null;
        if (y >= image_height) return null;
        return .{ .x = @intFromFloat(x), .y = @intFromFloat(y) };
    }

    /// One axis of `pixel`. When a logical pixel spans several image pixels,
    /// the first of them is the one `point` maps back (it floors); otherwise
    /// the image pixel containing the offset is the only candidate.
    fn pixel_axis(offset: f64, pixels_per_logical: f64) f64 {
        if (pixels_per_logical >= 1) return @ceil(offset * pixels_per_logical);
        return @floor(offset * pixels_per_logical);
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
test "frame boxes cover both corner pixels in either order" {
    const frame = fixture();
    const box = try frame.box(1919, 1079, 960, 540);
    try std.testing.expectEqual(Rect{ .x = -640, .y = 460, .width = 640, .height = 360 }, box);
    try std.testing.expectEqual(box, try frame.box(960, 540, 1919, 1079));
    try std.testing.expectError(error.CoordinatesOutOfBounds, frame.box(0, 0, 1920, 10));
}
test "pixel inverts point at every capture scale" {
    var frame = fixture();
    for ([_]u32{ 1280, 1600, 1920, 2560 }) |image_width| {
        frame.image_width = image_width;
        frame.image_height = image_width * 9 / 16;
        var desktop_x: i32 = -1280;
        while (desktop_x < 0) : (desktop_x += 37) {
            const desktop = Point{ .x = desktop_x, .y = 101 };
            const image = frame.pixel(desktop).?;
            const mapped = try frame.point(@floatFromInt(image.x), @floatFromInt(image.y));
            try std.testing.expectEqual(desktop, mapped);
        }
    }
    frame.image_width = 640;
    frame.image_height = 360;
    try std.testing.expectEqual(Point{ .x = 1, .y = 0 }, frame.pixel(.{ .x = -1277, .y = 100 }).?);
    try std.testing.expectEqual(@as(?Point, null), frame.pixel(.{ .x = 0, .y = 100 }));
    try std.testing.expectEqual(@as(?Point, null), frame.pixel(.{ .x = -1281, .y = 100 }));
}
test "rectangles intersect and widen to whole pixels" {
    const output = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const window = Rect{ .x = 1800, .y = -20, .width = 400, .height = 300 };
    try std.testing.expectEqual(
        Rect{ .x = 1800, .y = 0, .width = 120, .height = 280 },
        Rect.intersection(window, output).?,
    );
    const outside = Rect{ .x = 1920, .y = 0, .width = 10, .height = 10 };
    try std.testing.expectEqual(@as(?Rect, null), Rect.intersection(outside, output));
    const fractional = Rect{ .x = 10.5, .y = 2.25, .width = 4, .height = 1 };
    try std.testing.expectEqual(
        Rect{ .x = 10, .y = 2, .width = 5, .height = 2 },
        fractional.whole_pixels(),
    );
}
