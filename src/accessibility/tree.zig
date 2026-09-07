const std = @import("std");
const native = @import("../platform/native.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const Args = @import("../cli/args.zig").Args;
const c = @cImport({
    @cInclude("accessibility.h");
});
const Node = struct { id: usize, parent: ?usize, depth: u32, pid: u32, role: []const u8, name: ?[]const u8, protected: bool, focused: bool, bounds: ?struct { x: i32, y: i32, width: i32, height: i32 } };
const Walker = struct {
    rt: *Runtime,
    opt: Args,
    deadline: i64,
    nodes: std.ArrayList(Node) = .empty,
    truncated: bool = false,
    fn visit(self: *Walker, item: *c.DeskNode, parent: ?usize, depth: u32) anyerror!void {
        if (self.nodes.items.len >= self.opt.limit or native.nowMs() >= self.deadline) {
            self.truncated = true;
            return;
        }
        try native.checkCancelled();
        var info: c.DeskInfo = undefined;
        c.desk_a11y_info(item, &info);
        defer c.desk_a11y_info_free(&info);
        const protected = info.protected_value != 0;
        const raw_name = info.name;
        const raw_role = info.role;
        const node = Node{ .id = self.nodes.items.len, .parent = parent, .depth = depth, .pid = info.pid, .role = if (raw_role != null) try self.rt.a.dupe(u8, std.mem.span(raw_role)) else "unknown", .name = if (raw_name != null) try self.rt.a.dupe(u8, std.mem.span(raw_name)[0..@min(4096, std.mem.len(raw_name))]) else null, .protected = protected, .focused = info.focused != 0, .bounds = if (info.has_bounds != 0) .{ .x = info.bounds.x, .y = info.bounds.y, .width = info.bounds.width, .height = info.bounds.height } else null };
        try self.nodes.append(self.rt.a, node);
        if (protected) return;
        const count = c.desk_a11y_count(item);
        if (depth >= self.opt.depth) {
            if (count > 0) self.truncated = true;
            return;
        }
        var i: c_int = 0;
        while (i < count) : (i += 1) {
            if (self.nodes.items.len >= self.opt.limit or native.nowMs() >= self.deadline) {
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
pub fn worker(rt: *Runtime, opt: Args) !void {
    try rt.validateDisplay();
    try rt.unlocked();
    if (c.desk_a11y_init() != 0) return error.AccessibilityUnavailable;
    defer c.desk_a11y_exit();
    const desktop = c.desk_a11y_desktop() orelse return error.AccessibilityUnavailable;
    defer c.desk_a11y_unref(desktop);
    var target_pid: ?u32 = null;
    if (opt.window) |address| {
        const clients = try rt.json([]struct { address: []const u8, pid: i64 }, try rt.query("clients"));
        for (clients) |client| if (std.mem.eql(u8, client.address, address) and client.pid > 0) {
            target_pid = @intCast(client.pid);
            break;
        };
        if (target_pid == null) return error.WindowNotFound;
    }
    var walker = Walker{ .rt = rt, .opt = opt, .deadline = native.nowMs() + opt.timeout_ms };
    const count = c.desk_a11y_count(desktop);
    var index: c_int = 0;
    while (index < count and native.nowMs() < walker.deadline) : (index += 1) {
        const app = c.desk_a11y_child(desktop, index) orelse continue;
        defer c.desk_a11y_unref(app);
        if (target_pid) |pid| if (c.desk_a11y_pid(app) != pid) continue;
        try walker.visit(app, null, 0);
    }
    try rt.unlocked();
    try rt.emit(.{ .ok = true, .nodes = walker.nodes.items, .truncated = walker.truncated or native.nowMs() >= walker.deadline, .coordinate_space = "atspi-screen-unverified", .read_only = true });
}

pub fn tree(rt: *Runtime, opt: Args) !void {
    try native.checkCancelled();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(rt.a, &.{ "/proc/self/exe", "_a11y", "--timeout-ms", try std.fmt.allocPrint(rt.a, "{d}", .{opt.timeout_ms}), "--limit", try std.fmt.allocPrint(rt.a, "{d}", .{opt.limit}), "--depth", try std.fmt.allocPrint(rt.a, "{d}", .{opt.depth}) });
    if (opt.window) |window| try argv.appendSlice(rt.a, &.{ "--window", window });
    const result = try std.process.run(rt.a, rt.io, .{ .argv = argv.items, .environ_map = rt.env, .stdout_limit = .limited(16 * 1024 * 1024), .stderr_limit = .limited(64 * 1024), .timeout = .{ .duration = .{ .raw = .fromMilliseconds(opt.timeout_ms + 1000), .clock = .awake } } });
    try native.checkCancelled();
    const response = try rt.json(std.json.Value, result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.AccessibilityUnavailable,
        else => return error.AccessibilityUnavailable,
    }
    try rt.emit(.{ .ok = true, .session_id = rt.session_id, .accessibility = response });
}
