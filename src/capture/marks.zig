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
    for (reading.nodes) |node| {
        const bounds = node.bounds orelse continue;
        const box = frame.pixel_box(bounds.x, bounds.y, bounds.width, bounds.height) orelse
            continue;
        if (box.width < mark_size_min or box.height < mark_size_min) continue;
        const index: u32 = @intCast(marks.items.len + 1);
        const point = target_point(node, box);
        const outline = png.Box{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };
        png.draw_mark(image, outline, index);
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
    const image_path = try write_marked(runtime, frame, image);
    return .{
        .marks = marks.items,
        .legend = legend.items,
        .image_path = image_path,
        .snapshot = reading.snapshot,
    };
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
