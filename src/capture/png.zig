//! Minimal PNG reading and writing for captures: 8-bit RGB and RGBA,
//! non-interlaced, as grim writes them. Enough to compare two frames and to
//! draw marks on one; not a general PNG library.
const std = @import("std");
const assert = std.debug.assert;
const flate = std.compress.flate;

/// Decoded pixels, always RGBA with 8 bits per channel, rows top to bottom.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn at(image: Image, x: u32, y: u32) []u8 {
        assert(x < image.width);
        assert(y < image.height);
        const offset = (@as(usize, y) * image.width + x) * 4;
        return image.pixels[offset..][0..4];
    }
};

/// The largest image either function accepts: 16384 × 16384 pixels.
const pixels_max = 16384 * 16384;
const signature = "\x89PNG\r\n\x1a\n";

const Header = struct { width: u32, height: u32, channels: u32 };

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Image {
    if (bytes.len < signature.len) return error.InvalidPng;
    if (!std.mem.eql(u8, bytes[0..signature.len], signature)) return error.InvalidPng;
    var header: ?Header = null;
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(allocator);

    var offset: usize = signature.len;
    while (offset + 12 <= bytes.len) {
        const length = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        const kind = bytes[offset + 4 ..][0..4];
        if (length > bytes.len - offset - 12) return error.InvalidPng;
        const data = bytes[offset + 8 ..][0..length];
        offset += 12 + length;
        if (std.mem.eql(u8, kind, "IHDR")) header = try decode_header(data);
        if (std.mem.eql(u8, kind, "IDAT")) try compressed.appendSlice(allocator, data);
        if (std.mem.eql(u8, kind, "IEND")) break;
    }
    const info = header orelse return error.InvalidPng;
    return decode_pixels(allocator, info, compressed.items);
}

fn decode_header(data: []const u8) !Header {
    if (data.len != 13) return error.InvalidPng;
    const width = std.mem.readInt(u32, data[0..4], .big);
    const height = std.mem.readInt(u32, data[4..8], .big);
    if (width == 0 or height == 0) return error.InvalidPng;
    if (@as(u64, width) * height > pixels_max) return error.UnsupportedPng;
    if (data[8] != 8) return error.UnsupportedPng;
    // Compression 0, filter method 0, no interlacing.
    if (data[10] != 0 or data[11] != 0 or data[12] != 0) return error.UnsupportedPng;
    const channels: u32 = switch (data[9]) {
        2 => 3,
        6 => 4,
        else => return error.UnsupportedPng,
    };
    return .{ .width = width, .height = height, .channels = channels };
}

fn decode_pixels(allocator: std.mem.Allocator, info: Header, compressed: []const u8) !Image {
    const stride = @as(usize, info.width) * info.channels;
    const raw = try allocator.alloc(u8, (stride + 1) * info.height);
    defer allocator.free(raw);
    var input: std.Io.Reader = .fixed(compressed);
    var inflate: flate.Decompress = .init(&input, .zlib, &.{});
    var output: std.Io.Writer = .fixed(raw);
    const length = inflate.reader.streamRemaining(&output) catch return error.InvalidPng;
    if (length != raw.len) return error.InvalidPng;

    try unfilter(raw, stride, info.height, info.channels);
    const pixels = try allocator.alloc(u8, @as(usize, info.width) * info.height * 4);
    for (0..info.height) |row| {
        const line = raw[row * (stride + 1) + 1 ..][0..stride];
        for (0..info.width) |column| {
            const source = line[column * info.channels ..][0..info.channels];
            const target = pixels[(row * info.width + column) * 4 ..][0..4];
            @memcpy(target[0..3], source[0..3]);
            target[3] = if (info.channels == 4) source[3] else 255;
        }
    }
    return .{ .width = info.width, .height = info.height, .pixels = pixels };
}

/// Reverses the per-row PNG filters in place, leaving each row's filter byte.
fn unfilter(raw: []u8, stride: usize, height: u32, bpp: u32) !void {
    for (0..height) |row| {
        const start = row * (stride + 1);
        const filter = raw[start];
        const line = raw[start + 1 ..][0..stride];
        const previous: ?[]const u8 = if (row == 0) null else raw[start - stride ..][0..stride];
        for (line, 0..) |*byte, index| {
            const left: u8 = if (index >= bpp) line[index - bpp] else 0;
            const up: u8 = if (previous) |above| above[index] else 0;
            const up_left: u8 = if (previous != null and index >= bpp)
                previous.?[index - bpp]
            else
                0;
            byte.* +%= switch (filter) {
                0 => 0,
                1 => left,
                2 => up,
                3 => @intCast((@as(u16, left) + up) / 2),
                4 => paeth(left, up, up_left),
                else => return error.InvalidPng,
            };
        }
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// An RGBA PNG of the image; rows use the Sub filter, which suits screenshots.
pub fn encode(allocator: std.mem.Allocator, image: Image) ![]u8 {
    assert(image.pixels.len == @as(usize, image.width) * image.height * 4);
    const stride = @as(usize, image.width) * 4;
    const raw = try allocator.alloc(u8, (stride + 1) * image.height);
    defer allocator.free(raw);
    for (0..image.height) |row| {
        const line = image.pixels[row * stride ..][0..stride];
        const target = raw[row * (stride + 1) ..][0 .. stride + 1];
        target[0] = 1;
        for (line, 0..) |byte, index| {
            const left: u8 = if (index >= 4) line[index - 4] else 0;
            target[index + 1] = byte -% left;
        }
    }

    var deflated: std.Io.Writer.Allocating = try .initCapacity(allocator, raw.len / 4 + 64);
    defer deflated.deinit();
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);
    var compress = try flate.Compress.init(&deflated.writer, window, .zlib, .fastest);
    try compress.writer.writeAll(raw);
    try compress.finish();

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], image.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], image.height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    try chunk(allocator, &output, "IHDR", &ihdr);
    try chunk(allocator, &output, "IDAT", deflated.written());
    try chunk(allocator, &output, "IEND", "");
    return output.toOwnedSlice(allocator);
}

fn chunk(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    kind: *const [4]u8,
    data: []const u8,
) !void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(data.len), .big);
    try output.appendSlice(allocator, &length);
    try output.appendSlice(allocator, kind);
    try output.appendSlice(allocator, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, crc.final(), .big);
    try output.appendSlice(allocator, &checksum);
}

// ------------------------------------------------------------------ diff ---

pub const Box = struct { x: u32, y: u32, width: u32, height: u32 };

pub const Diff = struct {
    /// Pixels whose largest channel difference exceeds `channel_tolerance`.
    changed_pixels: u64,
    /// The smallest box holding every changed pixel, in image pixels.
    box: ?Box,
    /// The change is a thin box no longer than a line of text: a blinking
    /// text cursor or a one-pixel focus line rather than new content.
    cursor_like: bool,
};

/// Rendering noise below this difference per channel is ignored.
const channel_tolerance = 16;
/// The thickest and longest change still treated as a text cursor.
const cursor_thickness_max = 3;
const cursor_length_max = 64;

/// Compares two images of the same size; null when the sizes differ.
pub fn diff(before: Image, after: Image) ?Diff {
    if (before.width != after.width or before.height != after.height) return null;
    var changed: u64 = 0;
    var left: u32 = std.math.maxInt(u32);
    var top: u32 = std.math.maxInt(u32);
    var right: u32 = 0;
    var bottom: u32 = 0;
    for (0..before.height) |row| {
        for (0..before.width) |column| {
            const offset = (row * before.width + column) * 4;
            const a = before.pixels[offset..][0..3];
            const b = after.pixels[offset..][0..3];
            var delta: u8 = 0;
            for (a, b) |x, y| delta = @max(delta, if (x > y) x - y else y - x);
            if (delta <= channel_tolerance) continue;
            changed += 1;
            left = @min(left, @as(u32, @intCast(column)));
            right = @max(right, @as(u32, @intCast(column)));
            top = @min(top, @as(u32, @intCast(row)));
            bottom = @max(bottom, @as(u32, @intCast(row)));
        }
    }
    if (changed == 0) return .{ .changed_pixels = 0, .box = null, .cursor_like = false };
    const box = Box{ .x = left, .y = top, .width = right - left + 1, .height = bottom - top + 1 };
    const thin = @min(box.width, box.height) <= cursor_thickness_max;
    const short = @max(box.width, box.height) <= cursor_length_max;
    return .{ .changed_pixels = changed, .box = box, .cursor_like = thin and short };
}

// ----------------------------------------------------------------- marks ---

/// 5 × 7 bitmaps of the digits 0-9, one byte per row, high bits on the left.
const digits = [10][7]u8{
    .{ 0x70, 0x88, 0x98, 0xA8, 0xC8, 0x88, 0x70 },
    .{ 0x20, 0x60, 0x20, 0x20, 0x20, 0x20, 0x70 },
    .{ 0x70, 0x88, 0x08, 0x10, 0x20, 0x40, 0xF8 },
    .{ 0xF8, 0x10, 0x20, 0x10, 0x08, 0x88, 0x70 },
    .{ 0x10, 0x30, 0x50, 0x90, 0xF8, 0x10, 0x10 },
    .{ 0xF8, 0x80, 0xF0, 0x08, 0x08, 0x88, 0x70 },
    .{ 0x30, 0x40, 0x80, 0xF0, 0x88, 0x88, 0x70 },
    .{ 0xF8, 0x08, 0x10, 0x20, 0x40, 0x40, 0x40 },
    .{ 0x70, 0x88, 0x88, 0x70, 0x88, 0x88, 0x70 },
    .{ 0x70, 0x88, 0x88, 0x78, 0x08, 0x10, 0x60 },
};
const mark_color = [4]u8{ 230, 0, 160, 255 };
const label_text = [4]u8{ 255, 255, 255, 255 };
/// Font pixels per glyph pixel: 2 for ordinary controls, 1 when the controls
/// are so small (a downscaled capture) that larger labels would cover them.
pub const font_scale_max = 2;

fn fill(image: Image, box: Box, color: [4]u8) void {
    const right = @min(image.width, box.x +| box.width);
    const bottom = @min(image.height, box.y +| box.height);
    var y = box.y;
    while (y < bottom) : (y += 1) {
        var x = box.x;
        while (x < right) : (x += 1) @memcpy(image.at(x, y), &color);
    }
}

/// Outlines `box` in the mark colour.
pub fn draw_outline(image: Image, box: Box) void {
    const thickness = 2;
    fill(image, .{ .x = box.x, .y = box.y, .width = box.width, .height = thickness }, mark_color);
    fill(image, .{
        .x = box.x,
        .y = box.y +| (box.height -| thickness),
        .width = box.width,
        .height = thickness,
    }, mark_color);
    fill(image, .{ .x = box.x, .y = box.y, .width = thickness, .height = box.height }, mark_color);
    fill(image, .{
        .x = box.x +| (box.width -| thickness),
        .y = box.y,
        .width = thickness,
        .height = box.height,
    }, mark_color);
}

/// The size of the label for `number` at `scale`.
pub fn label_size(number: u32, scale: u32) [2]u32 {
    const digits_count = std.fmt.count("{d}", .{number});
    const width = digits_count * 6 * scale + 2 * scale;
    return .{ @intCast(width), 9 * scale };
}

/// Draws `number` in white on a filled label at `label`.
pub fn draw_label(image: Image, label: Box, number: u32, scale: u32) void {
    var buffer: [10]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch unreachable;
    fill(image, label, mark_color);
    for (text, 0..) |character, position| {
        const glyph = digits[character - '0'];
        const origin_x = label.x + scale + @as(u32, @intCast(position * 6 * scale));
        draw_glyph(image, glyph, origin_x, label.y + scale, scale);
    }
}

fn draw_glyph(image: Image, glyph: [7]u8, origin_x: u32, origin_y: u32, scale: u32) void {
    for (glyph, 0..) |bits, row| {
        for (0..5) |column| {
            const on = (bits >> @intCast(7 - column)) & 1 == 1;
            if (!on) continue;
            fill(image, .{
                .x = origin_x + @as(u32, @intCast(column * scale)),
                .y = origin_y + @as(u32, @intCast(row * scale)),
                .width = scale,
                .height = scale,
            }, label_text);
        }
    }
}

test "encode and decode round-trip RGBA pixels" {
    const allocator = std.testing.allocator;
    var pixels: [6 * 5 * 4]u8 = undefined;
    for (&pixels, 0..) |*byte, index| byte.* = @intCast((index * 37) % 251);
    const image = Image{ .width = 6, .height = 5, .pixels = &pixels };
    const encoded = try encode(allocator, image);
    defer allocator.free(encoded);
    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded.pixels);
    try std.testing.expectEqual(@as(u32, 6), decoded.width);
    try std.testing.expectEqualSlices(u8, &pixels, decoded.pixels);
}

test "diff finds the changed box and recognises a text cursor" {
    const allocator = std.testing.allocator;
    const size = 40 * 30 * 4;
    const before = Image{ .width = 40, .height = 30, .pixels = try allocator.alloc(u8, size) };
    defer allocator.free(before.pixels);
    const after = Image{ .width = 40, .height = 30, .pixels = try allocator.alloc(u8, size) };
    defer allocator.free(after.pixels);
    @memset(before.pixels, 200);
    @memcpy(after.pixels, before.pixels);
    try std.testing.expectEqual(@as(u64, 0), diff(before, after).?.changed_pixels);

    // A two-pixel-wide, 18-pixel-tall caret.
    fill(after, .{ .x = 10, .y = 5, .width = 2, .height = 18 }, .{ 0, 0, 0, 255 });
    const caret = diff(before, after).?;
    try std.testing.expectEqual(@as(u64, 36), caret.changed_pixels);
    try std.testing.expectEqual(Box{ .x = 10, .y = 5, .width = 2, .height = 18 }, caret.box.?);
    try std.testing.expect(caret.cursor_like);

    // A filled checkbox is content, not a cursor.
    fill(after, .{ .x = 20, .y = 10, .width = 12, .height = 12 }, .{ 0, 0, 0, 255 });
    try std.testing.expect(!diff(before, after).?.cursor_like);
    const other = Image{ .width = 30, .height = 40, .pixels = before.pixels };
    try std.testing.expectEqual(@as(?Diff, null), diff(before, other));
}

test "marks draw an outline and a numbered label" {
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(u8, 60 * 40 * 4);
    const image = Image{ .width = 60, .height = 40, .pixels = pixels };
    defer allocator.free(image.pixels);
    @memset(image.pixels, 0);
    draw_outline(image, .{ .x = 50, .y = 30, .width = 30, .height = 30 });
    try std.testing.expectEqualSlices(u8, &mark_color, image.at(51, 30));
    try std.testing.expectEqual([2]u32{ 28, 18 }, label_size(12, 2));
    try std.testing.expectEqual([2]u32{ 8, 9 }, label_size(7, 1));
    draw_label(image, .{ .x = 0, .y = 0, .width = 28, .height = 18 }, 12, 2);
    try std.testing.expectEqualSlices(u8, &mark_color, image.at(0, 0));
    try std.testing.expectEqualSlices(u8, &label_text, image.at(6, 2));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, image.at(30, 10));
}
