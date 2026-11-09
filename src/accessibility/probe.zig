//! Which control would an input activate? A disposable worker answers for
//! the confirmation gate: the control under a desktop point (pointer clicks),
//! or the focused control (Return and space). It reports the nearest ancestor
//! that activates something, since a click usually lands on a button's label.
const std = @import("std");
const native = @import("../platform/native.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const Args = @import("../cli/args.zig").Args;
const refs = @import("refs.zig");
const atspi = @import("atspi.zig");
const tree = @import("tree.zig");
const gate = @import("../runtime/gate.zig");
const c = atspi.c;

pub const Answer = struct {
    ok: bool = true,
    role: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

/// How far a focused-element search walks before giving up.
const focus_search_limit = 3000;
/// How many ancestors are checked for an activating control.
const ancestors_max = 8;

/// `_a11y_probe --window W [--x X --y Y]`: the control under a desktop point
/// of the window, or the focused one.
pub fn worker(runtime: *Runtime, arguments: Args) !void {
    try runtime.validate_display();
    if (c.desk_a11y_init() != 0) return error.AccessibilityUnavailable;
    defer c.desk_a11y_exit();
    const desktop = c.desk_a11y_desktop() orelse return error.AccessibilityUnavailable;
    defer c.desk_a11y_unref(desktop);

    const client = try tree.find_client(runtime, arguments.window.?);
    if (client.pid <= 0) return error.WindowNotFound;
    const app = atspi.application(desktop, @intCast(client.pid)) orelse
        return runtime.emit(Answer{});
    defer c.desk_a11y_unref(app);
    const top = atspi.toplevel(runtime.allocator, app, client.title) catch
        return runtime.emit(Answer{});
    defer c.desk_a11y_unref(top.node);

    const hit = if (arguments.x) |desktop_x| at_point: {
        const window_x: i32 = @intFromFloat(desktop_x - @as(f64, @floatFromInt(client.at[0])));
        const window_y: i32 = @intFromFloat(arguments.y.? - @as(f64, @floatFromInt(client.at[1])));
        break :at_point deepest_at(top.node, window_x, window_y);
    } else focused(top.node);
    const node = hit orelse return runtime.emit(Answer{});
    defer c.desk_a11y_unref(node);
    try runtime.emit(try activating_ancestor(runtime.allocator, node));
}

/// Descends through the children at a window point to the deepest one.
fn deepest_at(top: atspi.Node, x: i32, y: i32) ?atspi.Node {
    var current: atspi.Node = c.desk_a11y_ref(top).?;
    for (0..refs.path_max) |_| {
        const child = c.desk_a11y_child_at_point(current, x, y) orelse break;
        if (child == current) {
            c.desk_a11y_unref(child);
            break;
        }
        c.desk_a11y_unref(current);
        current = child;
    }
    if (current == top) {
        c.desk_a11y_unref(current);
        return null;
    }
    return current;
}

/// The focused element below `top`, by a bounded depth-first search.
fn focused(top: atspi.Node) ?atspi.Node {
    const Level = struct { node: atspi.Node, next: c_int, count: c_int };
    var stack: [refs.path_max + 1]Level = undefined;
    var height: usize = 1;
    stack[0] = .{ .node = top, .next = 0, .count = c.desk_a11y_count(top) };
    defer if (height > 1) for (stack[1..height]) |level| c.desk_a11y_unref(level.node);
    var visited: u32 = 0;
    while (height > 0 and visited < focus_search_limit) {
        const level = &stack[height - 1];
        if (level.next >= level.count) {
            if (height > 1) c.desk_a11y_unref(level.node);
            height -= 1;
            continue;
        }
        const child = c.desk_a11y_child(level.node, level.next) orelse {
            level.next += 1;
            continue;
        };
        level.next += 1;
        visited += 1;
        if (c.desk_a11y_states(child) & c.DESK_STATE_FOCUSED != 0) return child;
        if (height == stack.len) {
            c.desk_a11y_unref(child);
            continue;
        }
        stack[height] = .{ .node = child, .next = 0, .count = c.desk_a11y_count(child) };
        height += 1;
    }
    return null;
}

/// The control a person would say they activated: the nearest ancestor the
/// gate classifies, otherwise the nearest operable one (a click usually lands
/// on a button's label), otherwise the node itself.
fn activating_ancestor(allocator: std.mem.Allocator, start: atspi.Node) !Answer {
    var operable: ?Answer = null;
    var current: atspi.Node = c.desk_a11y_ref(start).?;
    defer c.desk_a11y_unref(current);
    var own: ?Answer = null;
    for (0..ancestors_max) |_| {
        const details = try atspi.info(allocator, current);
        const identity = try atspi.stable_identity(allocator, current, details);
        const answer = Answer{ .role = details.role, .name = identity.name orelse "" };
        if (own == null) own = answer;
        if (gate.classify(details.role, answer.name.?) != null) return answer;
        if (operable == null and details.operable()) operable = answer;
        const parent = c.desk_a11y_parent(current) orelse break;
        c.desk_a11y_unref(current);
        current = parent;
    }
    return operable orelse own orelse .{};
}

/// Runs the worker for a window and returns its answer; failures to read the
/// tree return an empty answer, so an inaccessible application is not gated.
pub fn probe(runtime: *Runtime, window: []const u8, point: ?[2]i32) !Answer {
    const allocator = runtime.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ "/proc/self/exe", "_a11y_probe", "--window", window });
    if (point) |desktop| {
        try argv.appendSlice(allocator, &.{
            "--x", try std.fmt.allocPrint(allocator, "{d}", .{desktop[0]}),
            "--y", try std.fmt.allocPrint(allocator, "{d}", .{desktop[1]}),
        });
    }
    const captured = runtime.run_capture(argv.items, "", false, 4000) catch return .{};
    if (!captured.succeeded) return .{};
    return runtime.parse_json(Answer, captured.stdout) catch .{};
}
