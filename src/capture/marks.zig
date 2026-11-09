//! Set-of-marks: numbered boxes drawn over the operable elements of a window
//! capture. The marks are stored in the frame, so `click --mark N` aims at
//! exactly what the agent saw, through the same frame validation as any
//! pointer coordinate.
const std = @import("std");
const geometry = @import("../core/geometry.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const args = @import("../cli/args.zig");
const tree = @import("../accessibility/tree.zig");
const png = @import("png.zig");

/// One mark as the agent reads it next to the marked image.
pub const Legend = struct {
    mark: u32,
    ref: ?[]const u8,
    role: []const u8,
    name: ?[]const u8,
    states: []const []const u8,
    x: u32,
    y: u32,
};

pub const Marked = struct {
    marks: []const geometry.Mark,
    legend: []const Legend,
    image_path: []const u8,
    snapshot: ?[]const u8,
};

/// Elements smaller than this, in image pixels, are not marked: their label
/// would hide them.
const mark_size_min = 4;

/// Reads the window's operable elements, draws a numbered box over each one
/// inside the frame, and writes the marked image beside the frame's own.
pub fn apply(runtime: *Runtime, frame: geometry.Frame, window: []const u8) !Marked {
    const reading = try tree.read(runtime, .{
        .command = .accessibility,
        .session = runtime.session_id,
        .window = window,
        .interactive = true,
        .depth = 20,
        .limit = 1000,
    }, frame);
    const bytes = try runtime.read_file(frame.image_path, 256 * 1024 * 1024);
    const image = try png.decode(runtime.allocator, bytes);

    var marks: std.ArrayList(geometry.Mark) = .empty;
    var legend: std.ArrayList(Legend) = .empty;
    var outlines: std.ArrayList(png.Box) = .empty;
    for (reading.nodes) |node| {
        const bounds = node.bounds orelse continue;
        const box = frame.pixel_box(bounds.x, bounds.y, bounds.width, bounds.height) orelse
            continue;
        if (box.width < mark_size_min or box.height < mark_size_min) continue;
        const index: u32 = @intCast(marks.items.len + 1);
        const point = target_point(node, box);
        const outline = png.Box{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };
        png.draw_outline(image, outline);
        try outlines.append(runtime.allocator, outline);
        try marks.append(runtime.allocator, .{
            .index = index,
            .x = point[0],
            .y = point[1],
            .ref = node.ref,
        });
        try legend.append(runtime.allocator, .{
            .mark = index,
            .ref = node.ref,
            .role = node.role,
            .name = node.name,
            .states = node.states,
            .x = point[0],
            .y = point[1],
        });
    }
    // Labels last, so no outline crosses a number.
    const scale = label_scale(outlines.items);
    const labels = try place_labels(runtime.allocator, image, outlines.items, scale);
    for (labels, 0..) |label, index| png.draw_label(image, label, @intCast(index + 1), scale);
    const image_path = try write_marked(runtime, frame, image);
    return .{
        .marks = marks.items,
        .legend = legend.items,
        .image_path = image_path,
        .snapshot = reading.snapshot,
    };
}

/// Full-size labels need controls at least this tall, in image pixels; a
/// downscaled capture gets smaller labels so they do not bury the controls.
const full_label_height_min = 20;

fn label_scale(outlines: []const png.Box) u32 {
    if (outlines.len == 0) return png.font_scale_max;
    var short: usize = 0;
    for (outlines) |outline| {
        if (outline.height < full_label_height_min) short += 1;
    }
    return if (short * 2 > outlines.len) 1 else png.font_scale_max;
}

/// Where each mark's label goes: the first candidate spot inside the image that
/// covers neither an earlier label nor another control, else the one that
/// covers least. Candidates prefer leaving the control's start visible:
/// above its left corner, inside its top-right corner, above its right corner,
/// below its left corner, left of it, and finally inside its top-left corner.
fn place_labels(
    allocator: std.mem.Allocator,
    image: png.Image,
    outlines: []const png.Box,
    scale: u32,
) ![]png.Box {
    const labels = try allocator.alloc(png.Box, outlines.len);
    for (outlines, 0..) |box, index| {
        const size = png.label_size(@intCast(index + 1), scale);
        const candidates = label_candidates(box, size);
        var best: ?png.Box = null;
        var best_cost: u64 = std.math.maxInt(u64);
        for (candidates) |candidate_or_null| {
            const candidate = candidate_or_null orelse continue;
            if (candidate.x + candidate.width > image.width) continue;
            if (candidate.y + candidate.height > image.height) continue;
            const cost = label_cost(candidate, index, outlines, labels[0..index]);
            if (cost < best_cost) {
                best = candidate;
                best_cost = cost;
            }
            if (cost == 0) break;
        }
        labels[index] = best orelse at(box.x, box.y, size).?;
    }
    return labels;
}

fn label_candidates(box: png.Box, size: [2]u32) [6]?png.Box {
    const width = size[0];
    const height = size[1];
    const right = box.x + box.width;
    const right_x = if (right >= width) right - width else box.x;
    const above: ?u32 = if (box.y >= height) box.y - height else null;
    const left: ?u32 = if (box.x >= width) box.x - width else null;
    return .{
        at(box.x, above, size),
        at(right_x, box.y, size),
        at(right_x, above, size),
        at(box.x, box.y + box.height, size),
        if (left) |x| at(x, box.y, size) else null,
        at(box.x, box.y, size),
    };
}

fn at(x: u32, y: ?u32, size: [2]u32) ?png.Box {
    const top = y orelse return null;
    return .{ .x = x, .y = top, .width = size[0], .height = size[1] };
}

/// Covered area: other controls count once, earlier labels four times
/// (a hidden number is worse than a covered border).
fn label_cost(
    candidate: png.Box,
    own: usize,
    outlines: []const png.Box,
    placed: []const png.Box,
) u64 {
    var cost: u64 = 0;
    for (outlines, 0..) |outline, index| {
        if (index != own) cost += overlap(candidate, outline);
    }
    for (placed) |label| cost += 4 * overlap(candidate, label);
    return cost;
}

fn overlap(a: png.Box, b: png.Box) u64 {
    const left = @max(a.x, b.x);
    const top = @max(a.y, b.y);
    const right = @min(a.x + a.width, b.x + b.width);
    const bottom = @min(a.y + a.height, b.y + b.height);
    if (right <= left or bottom <= top) return 0;
    return @as(u64, right - left) * (bottom - top);
}

/// The element's centre when it lies in the frame, otherwise its box's centre.
fn target_point(node: tree.OutputNode, box: geometry.PixelBox) [2]u32 {
    if (node.frame_point) |point| {
        const inside_x = point.x >= box.x and point.x < box.x + box.width;
        const inside_y = point.y >= box.y and point.y < box.y + box.height;
        if (inside_x and inside_y) return .{ @intCast(point.x), @intCast(point.y) };
    }
    return .{ box.x + box.width / 2, box.y + box.height / 2 };
}

fn write_marked(runtime: *Runtime, frame: geometry.Frame, image: png.Image) ![]const u8 {
    const name = try std.fmt.allocPrint(runtime.allocator, "{s}.marks.png", .{frame.frame_id});
    const path = try runtime.state_path(name);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{
        .sub_path = path,
        .data = try png.encode(runtime.allocator, image),
        .flags = .{ .exclusive = true },
    });
    return path;
}

/// The frame pixel of mark `index`, or `MarkNotFound`.
pub fn point_of(frame: geometry.Frame, index: u32) ![2]f64 {
    for (frame.marks) |mark| {
        if (mark.index == index) return .{ @floatFromInt(mark.x), @floatFromInt(mark.y) };
    }
    return error.MarkNotFound;
}

test "labels of tightly stacked controls stay visible and apart" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // Thirteen full-width rows 12 pixels tall with 4-pixel gaps, the first at
    // the image's top edge: a window captured at --max-edge 800.
    var outlines: [13]png.Box = undefined;
    for (&outlines, 0..) |*outline, index| {
        outline.* = .{ .x = 8, .y = @intCast(2 + index * 16), .width = 780, .height = 12 };
    }
    const image = png.Image{ .width = 800, .height = 440, .pixels = &.{} };
    const scale = label_scale(&outlines);
    try std.testing.expectEqual(@as(u32, 1), scale);
    const labels = try place_labels(allocator, image, &outlines, scale);
    for (labels, 0..) |label, index| {
        try std.testing.expect(label.x + label.width <= image.width);
        try std.testing.expect(label.y + label.height <= image.height);
        // The control's left end, where its text starts, stays uncovered.
        try std.testing.expectEqual(@as(u64, 0), overlap(label, .{
            .x = outlines[index].x + 2,
            .y = outlines[index].y + 2,
            .width = 100,
            .height = 8,
        }));
        for (labels[0..index]) |earlier| {
            try std.testing.expectEqual(@as(u64, 0), overlap(label, earlier));
        }
    }
    // Ordinary controls keep full-size labels above their corner.
    const roomy = [_]png.Box{.{ .x = 40, .y = 60, .width = 120, .height = 32 }};
    try std.testing.expectEqual(@as(u32, 2), label_scale(&roomy));
    const above = try place_labels(allocator, image, &roomy, 2);
    try std.testing.expectEqual(png.Box{ .x = 40, .y = 42, .width = 16, .height = 18 }, above[0]);
}
