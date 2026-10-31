const std = @import("std");
const assert = std.debug.assert;
const native = @import("../platform/native.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const Args = @import("../cli/args.zig").Args;
const accessibility_depth_max = @import("../cli/args.zig").accessibility_depth_max;
const c = @import("accessibility_c");
const Bounds = struct { x: i32, y: i32, width: i32, height: i32 };
const Node = struct {
    id: usize,
    parent: ?usize,
    depth: u32,
    pid: u32,
    role: []const u8,
    name: ?[]const u8,
    protected: bool,
    focused: bool,
    bounds: ?Bounds,
};
const max_name_bytes = 4096;

fn c_string(allocator: std.mem.Allocator, value: [*c]const u8, limit: usize) !?[]const u8 {
    if (value == null) return null;
    const span = std.mem.span(value);
    return try allocator.dupe(u8, span[0..@min(limit, span.len)]);
}
const Walker = struct {
    runtime: *Runtime,
    arguments: Args,
    deadline: i64,
    nodes: std.ArrayList(Node) = .empty,
    truncated: bool = false,

    /// A node whose children are still being visited. `owned` children hold
    /// a reference the walk must release; the root belongs to the caller.
    const Frame = struct {
        item: *c.DeskNode,
        id: usize,
        depth: u32,
        children_count: c_int,
        child_next: c_int = 0,
        owned: bool,
    };

    /// Depth-first, parents before children, with an explicit stack: the
    /// depth limit bounds the stack, so the walk needs no recursion.
    fn walk(self: *Walker, root: *c.DeskNode) !void {
        assert(self.arguments.depth <= accessibility_depth_max);
        var stack: [accessibility_depth_max + 1]Frame = undefined;
        var height: usize = 0;
        errdefer for (stack[0..height]) |frame| {
            if (frame.owned) c.desk_a11y_unref(frame.item);
        };

        const root_frame = try self.visit(root, null, 0) orelse return;
        stack[0] = root_frame;
        stack[0].owned = false;
        height = 1;

        while (height > 0) {
            const top = &stack[height - 1];
            if (top.child_next < top.children_count and self.exhausted()) {
                self.truncated = true;
                top.child_next = top.children_count;
            }
            if (top.child_next == top.children_count) {
                if (top.owned) c.desk_a11y_unref(top.item);
                height -= 1;
                continue;
            }

            const index = top.child_next;
            top.child_next += 1;
            const child = c.desk_a11y_child(top.item, index) orelse continue;
            const child_frame = self.visit(child, top.id, top.depth + 1) catch |err| {
                c.desk_a11y_unref(child);
                return err;
            };
            if (child_frame) |frame| {
                assert(height < stack.len);
                stack[height] = frame;
                height += 1;
            } else {
                c.desk_a11y_unref(child);
            }
        }
    }

    /// Records `item` and returns its frame when its children should be
    /// visited next, or null when the walk stops at this node.
    fn visit(self: *Walker, item: *c.DeskNode, parent: ?usize, depth: u32) !?Frame {
        if (self.exhausted()) {
            self.truncated = true;
            return null;
        }
        try native.check_cancelled();

        var info: c.DeskInfo = undefined;
        c.desk_a11y_info(item, &info);
        defer c.desk_a11y_info_free(&info);
        const protected = info.protected_value != 0;
        const allocator = self.runtime.allocator;
        const node = Node{
            .id = self.nodes.items.len,
            .parent = parent,
            .depth = depth,
            .pid = info.pid,
            .role = (try c_string(allocator, info.role, std.math.maxInt(usize))) orelse "unknown",
            .name = try c_string(allocator, info.name, max_name_bytes),
            .protected = protected,
            .focused = info.focused != 0,
            .bounds = if (info.has_bounds != 0) .{
                .x = info.bounds.x,
                .y = info.bounds.y,
                .width = info.bounds.width,
                .height = info.bounds.height,
            } else null,
        };
        try self.nodes.append(self.runtime.allocator, node);
        // Password fields: report that they exist, never what is inside them.
        if (protected) return null;

        const children_count = c.desk_a11y_count(item);
        if (depth >= self.arguments.depth) {
            if (children_count > 0) self.truncated = true;
            return null;
        }
        return .{
            .item = item,
            .id = node.id,
            .depth = depth,
            .children_count = @max(children_count, 0),
            .owned = true,
        };
    }

    /// True once the walk has collected its node limit or passed its deadline.
    fn exhausted(self: *const Walker) bool {
        if (self.nodes.items.len >= self.arguments.limit) return true;
        if (native.now_ms() >= self.deadline) return true;
        return false;
    }
};

// Runs only in a disposable subprocess: libatspi and broken applications may
// block despite per-call D-Bus deadlines. The parent enforces a hard timeout.
pub fn worker(runtime: *Runtime, arguments: Args) !void {
    try runtime.validate_display();
    try runtime.unlocked();
    if (c.desk_a11y_init() != 0) return error.AccessibilityUnavailable;
    defer c.desk_a11y_exit();
    const desktop = c.desk_a11y_desktop() orelse return error.AccessibilityUnavailable;
    defer c.desk_a11y_unref(desktop);

    var target_pid: ?u32 = null;
    if (arguments.window) |address| {
        const Client = struct { address: []const u8, pid: i64 };
        const clients = try runtime.query_json([]Client, "clients");
        for (clients) |client| {
            if (!std.mem.eql(u8, client.address, address)) continue;
            if (client.pid <= 0) continue;
            target_pid = @intCast(client.pid);
            break;
        }
        if (target_pid == null) return error.WindowNotFound;
    }

    var walker = Walker{
        .runtime = runtime,
        .arguments = arguments,
        .deadline = native.now_ms() + arguments.timeout_ms,
    };
    const count = c.desk_a11y_count(desktop);
    var index: c_int = 0;
    while (index < count and native.now_ms() < walker.deadline) : (index += 1) {
        const app = c.desk_a11y_child(desktop, index) orelse continue;
        defer c.desk_a11y_unref(app);
        if (target_pid) |pid| if (c.desk_a11y_pid(app) != pid) continue;
        try walker.walk(app);
    }

    try runtime.unlocked();
    try runtime.emit(.{
        .ok = true,
        .nodes = walker.nodes.items,
        .truncated = walker.truncated or native.now_ms() >= walker.deadline,
        .coordinate_space = "atspi-screen-unverified",
        .read_only = true,
    });
}

pub fn tree(runtime: *Runtime, arguments: Args) !void {
    try native.check_cancelled();

    const allocator = runtime.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ "/proc/self/exe", "_a11y" });
    try argv.appendSlice(allocator, &.{
        "--timeout-ms",
        try std.fmt.allocPrint(allocator, "{d}", .{arguments.timeout_ms}),
    });
    try argv.appendSlice(allocator, &.{
        "--limit",
        try std.fmt.allocPrint(allocator, "{d}", .{arguments.limit}),
    });
    try argv.appendSlice(allocator, &.{
        "--depth",
        try std.fmt.allocPrint(allocator, "{d}", .{arguments.depth}),
    });
    if (arguments.window) |window| try argv.appendSlice(allocator, &.{ "--window", window });

    // No --session: the worker inherits this (already routed) environment, so
    // its own Runtime.init lands on the same compositor as "host".
    const result = try std.process.run(allocator, runtime.io, .{
        .argv = argv.items,
        .environ_map = runtime.env,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{
            .duration = .{
                .raw = .fromMilliseconds(arguments.timeout_ms + 1000),
                .clock = .awake,
            },
        },
    });
    try native.check_cancelled();

    // Check the exit status first: a crashed worker leaves no JSON to parse.
    switch (result.term) {
        .exited => |code| if (code != 0) return error.AccessibilityUnavailable,
        else => return error.AccessibilityUnavailable,
    }
    const response = try runtime.parse_json(std.json.Value, result.stdout);
    try runtime.emit(.{ .ok = true, .session_id = runtime.session_id, .accessibility = response });
}
