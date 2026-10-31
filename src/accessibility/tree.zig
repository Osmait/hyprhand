const std = @import("std");
const native = @import("../platform/native.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const Args = @import("../cli/args.zig").Args;
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
    fn visit(self: *Walker, item: *c.DeskNode, parent: ?usize, depth: u32) anyerror!void {
        if (self.nodes.items.len >= self.arguments.limit or native.now_ms() >= self.deadline) {
            self.truncated = true;
            return;
        }
        try native.check_cancelled();
        var info: c.DeskInfo = undefined;
        c.desk_a11y_info(item, &info);
        defer c.desk_a11y_info_free(&info);
        const protected = info.protected_value != 0;
        const a = self.runtime.allocator;
        const node = Node{
            .id = self.nodes.items.len,
            .parent = parent,
            .depth = depth,
            .pid = info.pid,
            .role = (try c_string(a, info.role, std.math.maxInt(usize))) orelse "unknown",
            .name = try c_string(a, info.name, max_name_bytes),
            .protected = protected,
            .focused = info.focused != 0,
            .bounds = if (info.has_bounds != 0) .{ .x = info.bounds.x, .y = info.bounds.y, .width = info.bounds.width, .height = info.bounds.height } else null,
        };
        try self.nodes.append(self.runtime.allocator, node);
        if (protected) return;
        const count = c.desk_a11y_count(item);
        if (depth >= self.arguments.depth) {
            if (count > 0) self.truncated = true;
            return;
        }
        var i: c_int = 0;
        while (i < count) : (i += 1) {
            if (self.nodes.items.len >= self.arguments.limit or native.now_ms() >= self.deadline) {
                self.truncated = true;
                break;
            }
            const child = c.desk_a11y_child(item, i) orelse continue;
            defer c.desk_a11y_unref(child);
            try self.visit(child, node.id, depth + 1);
        }
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
        const clients = try runtime.query_json([]struct { address: []const u8, pid: i64 }, "clients");
        for (clients) |client| if (std.mem.eql(u8, client.address, address) and client.pid > 0) {
            target_pid = @intCast(client.pid);
            break;
        };
        if (target_pid == null) return error.WindowNotFound;
    }
    var walker = Walker{ .runtime = runtime, .arguments = arguments, .deadline = native.now_ms() + arguments.timeout_ms };
    const count = c.desk_a11y_count(desktop);
    var index: c_int = 0;
    while (index < count and native.now_ms() < walker.deadline) : (index += 1) {
        const app = c.desk_a11y_child(desktop, index) orelse continue;
        defer c.desk_a11y_unref(app);
        if (target_pid) |pid| if (c.desk_a11y_pid(app) != pid) continue;
        try walker.visit(app, null, 0);
    }
    try runtime.unlocked();
    try runtime.emit(.{ .ok = true, .nodes = walker.nodes.items, .truncated = walker.truncated or native.now_ms() >= walker.deadline, .coordinate_space = "atspi-screen-unverified", .read_only = true });
}

pub fn tree(runtime: *Runtime, arguments: Args) !void {
    try native.check_cancelled();
    const a = runtime.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "/proc/self/exe", "_a11y" });
    try argv.appendSlice(a, &.{ "--timeout-ms", try std.fmt.allocPrint(a, "{d}", .{arguments.timeout_ms}) });
    try argv.appendSlice(a, &.{ "--limit", try std.fmt.allocPrint(a, "{d}", .{arguments.limit}) });
    try argv.appendSlice(a, &.{ "--depth", try std.fmt.allocPrint(a, "{d}", .{arguments.depth}) });
    if (arguments.window) |window| try argv.appendSlice(a, &.{ "--window", window });
    // No --session: the worker inherits this (already routed) environment, so
    // its own Runtime.init lands on the same compositor as "host".
    const result = try std.process.run(a, runtime.io, .{
        .argv = argv.items,
        .environ_map = runtime.env,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(arguments.timeout_ms + 1000), .clock = .awake } },
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
