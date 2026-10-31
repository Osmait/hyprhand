//! Human takeover stream from the GTK viewer to its `_preview_input` worker.
//! Records have a fixed size per tag. The worker validates every byte: the
//! stream crosses a process boundary, so nothing here asserts on its input.
//! Keys travel as single key events (code and resolved symbol), never as text.
const std = @import("std");

/// The largest record; the worker never buffers a partial record beyond it.
pub const record_size_max = 10;
/// Normalized frame positions span 0..position_max on each axis.
pub const position_max = std.math.maxInt(u16);
/// XKB keymaps (format v1) end at key code 255, which is evdev code 247.
pub const keycode_max = 247;
/// The largest valid XKB keysym.
pub const keysym_max = 0x1fffffff;
/// One wheel detent in high-resolution wheel units.
pub const wheel_detent = 120;
/// Bounds per record. Real devices report far less; larger values are corrupt.
pub const wheel_delta_max = 64 * wheel_detent;
pub const surface_delta_max = 4096 * 256;

/// The viewer reports which byte follows the worker's setup and shutdown.
pub const Reply = enum(u8) {
    /// Agent control is revoked and the devices exist; forwarding is live.
    ready = 'R',
    /// The human returned control and agent control was enabled again.
    returned_enabled = 'E',
    /// The human returned control; agent control stays stopped.
    returned_stopped = 'S',
};

pub const PointerButton = enum(u8) {
    left = 1,
    middle = 2,
    right = 3,
    back = 8,
    forward = 9,

    /// Linux input event codes (BTN_LEFT, BTN_MIDDLE, ...).
    pub fn code(self: PointerButton) u32 {
        return switch (self) {
            .left => 0x110,
            .right => 0x111,
            .middle => 0x112,
            .back => 0x113,
            .forward => 0x114,
        };
    }
};

/// Wheel deltas are in 1/120 detents; surface deltas are wl_fixed pixels.
pub const ScrollUnit = enum(u8) { wheel = 0, surface = 1 };

/// A position inside the captured frame, independent of viewer size.
pub const Position = struct { x: u16, y: u16 };

pub const Key = struct {
    /// The host's evdev code (XKB key code minus 8): identifies the physical
    /// key, so a release matches its press even if modifiers changed between.
    keycode: u16,
    /// The symbol the host resolved for this key: layout, Shift, AltGr, Caps
    /// Lock and dead keys are already applied by the human's own keyboard.
    keysym: u32,
    pressed: bool,
};

pub const Event = union(enum) {
    motion: Position,
    button: struct { button: PointerButton, pressed: bool },
    scroll: struct { unit: ScrollUnit, dx: i32, dy: i32 },
    scroll_stop,
    key: Key,
    /// The viewer lost focus: release every held key and button.
    release_all,
    /// The human pressed Return. EOF without it ends without re-enabling.
    finish,
};

const Tag = enum(u8) {
    motion = 'M',
    button = 'B',
    scroll = 'S',
    scroll_stop = 'T',
    key = 'K',
    release_all = 'A',
    finish = 'Q',

    fn size(self: Tag) usize {
        return switch (self) {
            .motion => 5,
            .button => 3,
            .scroll => 10,
            .key => 8,
            .scroll_stop, .release_all, .finish => 1,
        };
    }
};

pub fn encode(event: Event, buffer: *[record_size_max]u8) []const u8 {
    const tag: Tag = switch (event) {
        inline else => |_, name| @field(Tag, @tagName(name)),
    };
    buffer[0] = @backingInt(tag);
    switch (event) {
        .motion => |position| {
            std.mem.writeInt(u16, buffer[1..3], position.x, .little);
            std.mem.writeInt(u16, buffer[3..5], position.y, .little);
        },
        .button => |button| {
            buffer[1] = @backingInt(button.button);
            buffer[2] = @intFromBool(button.pressed);
        },
        .scroll => |scroll| {
            buffer[1] = @backingInt(scroll.unit);
            std.mem.writeInt(i32, buffer[2..6], scroll.dx, .little);
            std.mem.writeInt(i32, buffer[6..10], scroll.dy, .little);
        },
        .key => |key| {
            std.mem.writeInt(u16, buffer[1..3], key.keycode, .little);
            std.mem.writeInt(u32, buffer[3..7], key.keysym, .little);
            buffer[7] = @intFromBool(key.pressed);
        },
        .scroll_stop, .release_all, .finish => {},
    }
    return buffer[0..tag.size()];
}

pub const Decoded = struct { event: Event, size: usize };

/// Decodes the first record of `bytes`. Null means more bytes are needed.
pub fn decode(bytes: []const u8) error{InvalidTakeoverEvent}!?Decoded {
    if (bytes.len == 0) return null;
    const tag = std.enums.fromInt(Tag, bytes[0]) orelse return error.InvalidTakeoverEvent;
    if (bytes.len < tag.size()) return null;

    const record = bytes[0..tag.size()];
    const event: Event = switch (tag) {
        .motion => .{ .motion = .{
            .x = std.mem.readInt(u16, record[1..3], .little),
            .y = std.mem.readInt(u16, record[3..5], .little),
        } },
        .button => .{ .button = .{
            .button = std.enums.fromInt(PointerButton, record[1]) orelse
                return error.InvalidTakeoverEvent,
            .pressed = try decode_flag(record[2]),
        } },
        .scroll => try decode_scroll(record),
        .key => try decode_key(record),
        .scroll_stop => .scroll_stop,
        .release_all => .release_all,
        .finish => .finish,
    };
    return .{ .event = event, .size = record.len };
}

fn decode_flag(byte: u8) error{InvalidTakeoverEvent}!bool {
    if (byte > 1) return error.InvalidTakeoverEvent;
    return byte == 1;
}

fn decode_scroll(record: []const u8) error{InvalidTakeoverEvent}!Event {
    const unit = std.enums.fromInt(ScrollUnit, record[1]) orelse
        return error.InvalidTakeoverEvent;
    const dx = std.mem.readInt(i32, record[2..6], .little);
    const dy = std.mem.readInt(i32, record[6..10], .little);
    const limit: u32 = switch (unit) {
        .wheel => wheel_delta_max,
        .surface => surface_delta_max,
    };
    if (@abs(dx) > limit) return error.InvalidTakeoverEvent;
    if (@abs(dy) > limit) return error.InvalidTakeoverEvent;
    return .{ .scroll = .{ .unit = unit, .dx = dx, .dy = dy } };
}

fn decode_key(record: []const u8) error{InvalidTakeoverEvent}!Event {
    const keycode = std.mem.readInt(u16, record[1..3], .little);
    if (keycode > keycode_max) return error.InvalidTakeoverEvent;
    const keysym = std.mem.readInt(u32, record[3..7], .little);
    if (keysym == 0) return error.InvalidTakeoverEvent;
    if (keysym > keysym_max) return error.InvalidTakeoverEvent;
    return .{ .key = .{
        .keycode = keycode,
        .keysym = keysym,
        .pressed = try decode_flag(record[7]),
    } };
}

pub const Letterbox = struct {
    position: Position,
    /// False in the bars around the image; the position is then clamped.
    inside: bool,
};

/// Maps viewer widget coordinates onto the frame drawn with GTK's
/// CONTENT_FIT_CONTAIN: scaled to fit, centered, letterboxed. Null when either
/// size is degenerate, so no position can be meaningful.
pub fn letterbox(
    widget_width: f64,
    widget_height: f64,
    frame_width: f64,
    frame_height: f64,
    x: f64,
    y: f64,
) ?Letterbox {
    const sizes = [_]f64{ widget_width, widget_height, frame_width, frame_height };
    for (sizes) |size| {
        if (!std.math.isFinite(size)) return null;
        if (size < 1) return null;
    }
    if (!std.math.isFinite(x)) return null;
    if (!std.math.isFinite(y)) return null;

    const scale = @min(widget_width / frame_width, widget_height / frame_height);
    const image_width = frame_width * scale;
    const image_height = frame_height * scale;
    const left = (widget_width - image_width) / 2;
    const top = (widget_height - image_height) / 2;
    const u = (x - left) / image_width;
    const v = (y - top) / image_height;
    const inside = u >= 0 and u < 1 and v >= 0 and v < 1;
    return .{ .position = .{ .x = normalize(u), .y = normalize(v) }, .inside = inside };
}

fn normalize(fraction: f64) u16 {
    const clamped = std.math.clamp(fraction, 0, 1);
    return @intFromFloat(@round(clamped * position_max));
}

/// A rectangle in compositor layout pixels.
pub const Area = struct { x: f64, y: f64, width: f64, height: f64 };

/// Arguments for zwlr_virtual_pointer_v1.motion_absolute.
pub const AbsoluteMotion = struct { x: u32, y: u32, x_extent: u32, y_extent: u32 };

/// Sub-pixel steps per layout pixel in absolute motion.
const absolute_steps = 8;

/// Hyprland maps an unbound virtual pointer's absolute motion over the bounding
/// box of all monitors (`layout`). Places `position` on `monitor` within it.
pub fn absolute_motion(
    monitor: Area,
    layout: Area,
    position: Position,
) error{InvalidMonitorGeometry}!AbsoluteMotion {
    const outside = monitor.x < layout.x or monitor.y < layout.y or
        monitor.x + monitor.width > layout.x + layout.width or
        monitor.y + monitor.height > layout.y + layout.height;
    if (outside) return error.InvalidMonitorGeometry;
    if (monitor.width < 1) return error.InvalidMonitorGeometry;
    if (monitor.height < 1) return error.InvalidMonitorGeometry;
    // Extents stay far inside u32 for any real layout.
    if (layout.width > 1 << 20) return error.InvalidMonitorGeometry;
    if (layout.height > 1 << 20) return error.InvalidMonitorGeometry;

    const x_extent = layout.width * absolute_steps;
    const y_extent = layout.height * absolute_steps;
    const u = @as(f64, @floatFromInt(position.x)) / position_max;
    const v = @as(f64, @floatFromInt(position.y)) / position_max;
    // The last step of the monitor, never the next monitor's first pixel.
    const x = (monitor.x - layout.x + u * monitor.width) * absolute_steps;
    const y = (monitor.y - layout.y + v * monitor.height) * absolute_steps;
    const x_last = (monitor.x - layout.x + monitor.width) * absolute_steps - 1;
    const y_last = (monitor.y - layout.y + monitor.height) * absolute_steps - 1;
    return .{
        .x = @intFromFloat(@min(@round(x), x_last)),
        .y = @intFromFloat(@min(@round(y), y_last)),
        .x_extent = @intFromFloat(@round(x_extent)),
        .y_extent = @intFromFloat(@round(y_extent)),
    };
}

test "takeover records round-trip at their fixed sizes" {
    const events = [_]Event{
        .{ .motion = .{ .x = 0, .y = position_max } },
        .{ .button = .{ .button = .forward, .pressed = true } },
        .{ .scroll = .{ .unit = .surface, .dx = -surface_delta_max, .dy = 77 } },
        .scroll_stop,
        .{ .key = .{
            .keycode = 30,
            .pressed = true,
            .keysym = 0x1000000 + 0xe9,
        } },
        .release_all,
        .finish,
    };
    var stream: [events.len * record_size_max]u8 = undefined;
    var length: usize = 0;
    for (events) |event| {
        var buffer: [record_size_max]u8 = undefined;
        const record = encode(event, &buffer);
        @memcpy(stream[length..][0..record.len], record);
        length += record.len;
    }

    var offset: usize = 0;
    for (events) |expected| {
        // Every strict prefix of a record asks for more bytes, never guesses.
        const decoded = (try decode(stream[offset..length])).?;
        for (1..decoded.size) |prefix| {
            try std.testing.expect(try decode(stream[offset..][0..prefix]) == null);
        }
        try std.testing.expectEqualDeep(expected, decoded.event);
        offset += decoded.size;
    }
    try std.testing.expectEqual(length, offset);
    try std.testing.expect(try decode(stream[length..length]) == null);
}

test "takeover decoding rejects unknown tags, flags, codes and oversized deltas" {
    const invalid = [_][]const u8{
        "X",
        "\x00",
        "B\x04\x01",
        "B\x01\x02",
        "K\xf8\x00\x61\x00\x00\x00\x01",
        "K\x1e\x00\x61\x00\x00\x00\x02",
        "K\x1e\x00\x00\x00\x00\x00\x01",
        "K\x1e\x00\x00\x00\x00\x20\x01",
        "S\x02\x00\x00\x00\x00\x00\x00\x00\x00",
        "S\x00\x01\x1e\x00\x00\x00\x00\x00\x00",
        "S\x01\x00\x00\x00\x00\x00\x00\x00\x80",
    };
    for (invalid) |record| {
        try std.testing.expectError(error.InvalidTakeoverEvent, decode(record));
    }
    // The wheel limit is inclusive; one more unit is corrupt.
    var buffer: [record_size_max]u8 = undefined;
    const wheel_limit: Event = .{ .scroll = .{ .unit = .wheel, .dx = 0, .dy = wheel_delta_max } };
    const limit = encode(wheel_limit, &buffer);
    try std.testing.expect(try decode(limit) != null);
    std.mem.writeInt(i32, buffer[6..10], wheel_delta_max + 1, .little);
    try std.testing.expectError(error.InvalidTakeoverEvent, decode(buffer[0..10]));
}

test "letterbox maps centered images and clamps the bars" {
    // A 16:9 frame in a square widget: bars above and below the image.
    const center = letterbox(400, 400, 960, 540, 200, 200).?;
    try std.testing.expect(center.inside);
    try std.testing.expectEqual(@as(u16, 32768), center.position.x);
    try std.testing.expectEqual(@as(u16, 32768), center.position.y);

    const top_left = letterbox(400, 400, 960, 540, 0, 87.5).?;
    try std.testing.expect(top_left.inside);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, top_left.position);

    const bar = letterbox(400, 400, 960, 540, 100, 20).?;
    try std.testing.expect(!bar.inside);
    try std.testing.expectEqual(@as(u16, 0), bar.position.y);
    try std.testing.expectEqual(@as(u16, 16384), bar.position.x);

    // A wide widget: bars left and right; the right edge is outside.
    const right = letterbox(1000, 270, 960, 540, 740, 135).?;
    try std.testing.expect(!right.inside);
    try std.testing.expectEqual(@as(u16, position_max), right.position.x);
    const scaled_up = letterbox(1920, 1080, 960, 540, 480, 270).?;
    try std.testing.expectEqual(@as(u16, 16384), scaled_up.position.x);

    try std.testing.expect(letterbox(0, 360, 960, 540, 1, 1) == null);
    try std.testing.expect(letterbox(640, 360, 960, std.math.nan(f64), 1, 1) == null);
    try std.testing.expect(letterbox(640, 360, 960, 540, std.math.inf(f64), 1) == null);
}

test "absolute motion places positions on the chosen monitor of the layout" {
    const left = Area{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const right = Area{ .x = 1920, .y = 0, .width = 1280, .height = 720 };
    const layout = Area{ .x = 0, .y = 0, .width = 3200, .height = 1080 };

    const origin = try absolute_motion(right, layout, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(AbsoluteMotion{
        .x = 1920 * 8,
        .y = 0,
        .x_extent = 3200 * 8,
        .y_extent = 1080 * 8,
    }, origin);
    const middle = try absolute_motion(left, left, .{ .x = 32768, .y = 32768 });
    try std.testing.expectEqual(@as(u32, 960 * 8), middle.x);
    try std.testing.expectEqual(@as(u32, 540 * 8), middle.y);

    const corner = try absolute_motion(left, layout, .{ .x = position_max, .y = position_max });
    try std.testing.expectEqual(@as(u32, 1920 * 8 - 1), corner.x);
    try std.testing.expectEqual(@as(u32, 1080 * 8 - 1), corner.y);

    const shifted = Area{ .x = -1280, .y = 0, .width = 1280, .height = 720 };
    const negative_layout = Area{ .x = -1280, .y = 0, .width = 3200, .height = 1080 };
    const start = try absolute_motion(shifted, negative_layout, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(@as(u32, 0), start.x);
    try std.testing.expectError(
        error.InvalidMonitorGeometry,
        absolute_motion(right, left, .{ .x = 0, .y = 0 }),
    );
}
