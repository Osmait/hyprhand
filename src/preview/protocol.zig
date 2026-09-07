const std = @import("std");
const geometry = @import("../core/geometry.zig");
pub const max_bytes = 8 * 1024 * 1024;
pub const header_len = 13;
pub const max_age_ms = 2000;

pub fn header(timestamp: i64, enabled: bool) [header_len]u8 {
    var result: [header_len]u8 = undefined;
    @memcpy(result[0..4], "DCP1");
    result[4] = @intFromBool(enabled);
    std.mem.writeInt(i64, result[5..13], timestamp, .little);
    return result;
}

pub fn validatePng(png: []const u8) !void {
    if (png.len > max_bytes) return error.InvalidScreenshot;
    const size = try geometry.pngSize(png);
    if (size.width > 1920 or size.height > 1920 or @as(u64, size.width) * size.height > 2_073_600) return error.InvalidScreenshot;
}

pub fn decode(bytes: []const u8, now: i64) !struct { png: []const u8, enabled: bool, captured_ms: i64 } {
    if (bytes.len < header_len or bytes.len > max_bytes + header_len or !std.mem.eql(u8, bytes[0..4], "DCP1") or bytes[4] > 1) return error.InvalidPreviewFrame;
    const timestamp = std.mem.readInt(i64, bytes[5..13], .little);
    if (timestamp < 0 or timestamp > now or now - timestamp > max_age_ms) return error.StalePreviewFrame;
    try validatePng(bytes[header_len..]);
    return .{ .png = bytes[header_len..], .enabled = bytes[4] == 1, .captured_ms = timestamp };
}

test "preview framing rejects stale, future, oversized and invalid frames" {
    var data: [header_len + 24]u8 = @splat(0);
    @memcpy(data[0..header_len], &header(100, true));
    @memcpy(data[header_len..][0..8], "\x89PNG\r\n\x1a\n");
    @memcpy(data[header_len..][12..16], "IHDR");
    std.mem.writeInt(u32, data[header_len..][16..20], 960, .big);
    std.mem.writeInt(u32, data[header_len..][20..24], 540, .big);
    try std.testing.expect((try decode(&data, 200)).enabled);
    try std.testing.expectError(error.StalePreviewFrame, decode(&data, 2101));
    try std.testing.expectError(error.StalePreviewFrame, decode(&data, 99));
    data[4] = 2;
    try std.testing.expectError(error.InvalidPreviewFrame, decode(&data, 200));
    data[4] = 0;
    try std.testing.expect(!(try decode(&data, 200)).enabled);
    std.mem.writeInt(u32, data[header_len..][16..20], 9999, .big);
    try std.testing.expectError(error.InvalidScreenshot, decode(&data, 200));
    try std.testing.expectError(error.InvalidPreviewFrame, decode("{\"ok\":false}", 200));
}
