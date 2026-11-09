//! `accessibility`: a bounded AT-SPI walk in a disposable worker. With
//! `--window`, the walk covers that window's toplevel only, reports bounds in
//! desktop coordinates, and mints refs that `act` resolves again later.
const std = @import("std");
const assert = std.debug.assert;
const native = @import("../platform/native.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const Args = @import("../cli/args.zig").Args;
const accessibility_depth_max = @import("../cli/args.zig").accessibility_depth_max;
const geometry = @import("../core/geometry.zig");
const observation = @import("../capture/observation.zig");
const atspi = @import("atspi.zig");
const refs = @import("refs.zig");
const c = atspi.c;

const Bounds = atspi.Rect;
/// Text values longer than this are cut in reports; refs never store values.
const value_limit_chars = 256;

/// One element as the worker reports it to the parent.
const Node = struct {
    id: usize,
    parent: ?usize,
    depth: u32,
    pid: u32,
    role: []const u8,
    name: ?[]const u8,
    protected: bool,
    focused: bool,
    states: []const []const u8,
    /// Editable text or a range value, cut to `value_limit_chars`.
    value: ?[]const u8 = null,
    /// Desktop coordinates with `--window`; otherwise as the application
    /// reports them (`atspi-screen-unverified`).
    bounds: ?Bounds,
    /// The N of the node's ref; null when it is not operable.
    ref_index: ?u32 = null,
    path: []const u32,
};

/// The window a `--window` walk is scoped to.
const Scope = struct {
    origin: [2]i32,
    title: []const u8,
    pid: u32,
};

const Walker = struct {
    runtime: *Runtime,
    arguments: Args,
    deadline: i64,
    scope: ?Scope = null,
    nodes: std.ArrayList(Node) = .empty,
    identities: std.ArrayList(refs.Identity) = .empty,
    refs_minted: u32 = 0,
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

        const root_frame = try self.visit(root, null, 0, &.{}) orelse return;
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
            const path = try self.child_path(top.id, @intCast(index));
            const child_frame = self.visit(child, top.id, top.depth + 1, path) catch |err| {
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

    fn child_path(self: *Walker, parent: usize, index: u32) ![]const u32 {
        const parent_path = self.nodes.items[parent].path;
        assert(parent_path.len < refs.path_max);
        const path = try self.runtime.allocator.alloc(u32, parent_path.len + 1);
        @memcpy(path[0..parent_path.len], parent_path);
        path[parent_path.len] = index;
        return path;
    }

    /// Records `item` and returns its frame when its children should be
    /// visited next, or null when the walk stops at this node.
    fn visit(
        self: *Walker,
        item: *c.DeskNode,
        parent: ?usize,
        depth: u32,
        path: []const u32,
    ) !?Frame {
        if (self.exhausted()) {
            self.truncated = true;
            return null;
        }
        try native.check_cancelled();

        const node = try self.record(item, parent, depth, path);
        // Password fields: report that they exist, never what is inside them.
        if (node.protected) return null;

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

    fn record(
        self: *Walker,
        item: *c.DeskNode,
        parent: ?usize,
        depth: u32,
        path: []const u32,
    ) !Node {
        const allocator = self.runtime.allocator;
        const details = try atspi.info(allocator, item);
        // Refs exist only inside one window, and never for its toplevel itself.
        const mints_ref = self.scope != null and path.len > 0 and details.operable();
        var node = Node{
            .id = self.nodes.items.len,
            .parent = parent,
            .depth = depth,
            .pid = details.pid,
            .role = details.role,
            .name = details.name,
            .protected = details.protected,
            .focused = details.has_state(c.DESK_STATE_FOCUSED),
            .states = try atspi.state_names(allocator, details),
            .value = if (details.protected) null else try node_value(allocator, item, details),
            .bounds = self.node_bounds(details),
            .path = path,
        };
        if (mints_ref) {
            self.refs_minted += 1;
            node.ref_index = self.refs_minted;
        }
        try self.nodes.append(allocator, node);
        if (self.scope != null) {
            const identity = try atspi.stable_identity(allocator, item, details);
            try self.identities.append(allocator, identity);
            // An unnamed row shows its child's text: report it as the name.
            if (node.name == null and !node.protected) {
                self.nodes.items[node.id].name = identity.name;
                node.name = identity.name;
            }
        }
        return node;
    }

    fn node_bounds(self: *const Walker, details: atspi.Info) ?Bounds {
        const scope = self.scope orelse return details.screen;
        const local = details.window orelse return null;
        return .{
            .x = scope.origin[0] + local.x,
            .y = scope.origin[1] + local.y,
            .width = local.width,
            .height = local.height,
        };
    }

    /// True once the walk has collected its node limit or passed its deadline.
    fn exhausted(self: *const Walker) bool {
        if (self.nodes.items.len >= self.arguments.limit) return true;
        if (native.now_ms() >= self.deadline) return true;
        return false;
    }

    /// The entries a snapshot stores for this walk's refs.
    fn entries(self: *Walker) ![]refs.Entry {
        const allocator = self.runtime.allocator;
        const twins = try refs.count_twins(allocator, self.identities.items);
        var result: std.ArrayList(refs.Entry) = .empty;
        for (self.nodes.items, self.identities.items, twins) |node, identity, count| {
            const index = node.ref_index orelse continue;
            try result.append(allocator, .{
                .index = index,
                .path = node.path,
                .identity = identity,
                .twins = count,
                .protected = node.protected,
            });
        }
        return result.toOwnedSlice(allocator);
    }
};

/// Editable text or a range value, for operable elements only.
fn node_value(
    allocator: std.mem.Allocator,
    item: *c.DeskNode,
    details: atspi.Info,
) !?[]const u8 {
    if (!details.operable()) return null;
    if (details.has_interface(c.DESK_IFACE_VALUE)) {
        const range = atspi.range_value(item) orelse return null;
        return try std.fmt.allocPrint(allocator, "{d}", .{range.current});
    }
    const textual = details.has_interface(c.DESK_IFACE_TEXT) and
        (details.has_state(c.DESK_STATE_EDITABLE) or atspi.mutable_role(details.role));
    if (!textual) return null;
    return atspi.text(allocator, item, value_limit_chars);
}

/// What the worker prints for the parent.
const Report = struct {
    ok: bool,
    nodes: []const Node,
    truncated: bool,
    coordinate_space: []const u8,
    /// The window address of a `--window` walk.
    window: ?[]const u8 = null,
    pid: ?u32 = null,
    entries: []const refs.Entry = &.{},
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

    var walker = Walker{
        .runtime = runtime,
        .arguments = arguments,
        .deadline = native.now_ms() + arguments.timeout_ms,
    };
    if (arguments.window) |address| {
        try walk_window(runtime, &walker, desktop, address);
    } else {
        try walk_desktop(&walker, desktop);
    }

    try runtime.unlocked();
    const truncated = walker.truncated or native.now_ms() >= walker.deadline;
    try runtime.emit(Report{
        .ok = true,
        .nodes = walker.nodes.items,
        .truncated = truncated,
        .coordinate_space = if (walker.scope == null)
            "atspi-screen-unverified"
        else
            "desktop-logical",
        .window = arguments.window,
        .pid = if (walker.scope) |scope| scope.pid else null,
        .entries = if (walker.scope != null) try walker.entries() else &.{},
    });
}

fn walk_desktop(walker: *Walker, desktop: *c.DeskNode) !void {
    const count = c.desk_a11y_count(desktop);
    var index: c_int = 0;
    while (index < count and native.now_ms() < walker.deadline) : (index += 1) {
        const app = c.desk_a11y_child(desktop, index) orelse continue;
        defer c.desk_a11y_unref(app);
        try walker.walk(app);
    }
}

fn walk_window(
    runtime: *Runtime,
    walker: *Walker,
    desktop: *c.DeskNode,
    address: []const u8,
) !void {
    const client = try find_client(runtime, address);
    if (client.pid <= 0) return error.WindowNotFound;
    const pid: u32 = @intCast(client.pid);
    const app = atspi.application(desktop, pid) orelse return error.AccessibilityWindowNotFound;
    defer c.desk_a11y_unref(app);
    const top = try atspi.toplevel(runtime.allocator, app, client.title);
    defer c.desk_a11y_unref(top.node);

    walker.scope = .{ .origin = client.at, .title = client.title, .pid = pid };
    try walker.walk(top.node);
}

pub fn find_client(runtime: *Runtime, address: []const u8) !observation.Client {
    const clients = try runtime.query_json([]observation.Client, "clients");
    for (clients) |client| {
        if (std.mem.eql(u8, client.address, address)) return client;
    }
    return error.WindowNotFound;
}

/// One element as `accessibility` reports it to the agent.
const OutputNode = struct {
    id: usize,
    parent: ?usize,
    depth: u32,
    pid: u32,
    role: []const u8,
    name: ?[]const u8,
    protected: bool,
    focused: bool,
    states: []const []const u8,
    value: ?[]const u8,
    bounds: ?Bounds,
    ref: ?[]const u8,
    /// The center of `bounds` as a pixel of `--frame`, ready for `click`.
    frame_point: ?geometry.Point,
};

pub fn tree(runtime: *Runtime, arguments: Args) !void {
    try native.check_cancelled();
    const frame: ?geometry.Frame = if (arguments.frame) |frame_id|
        try observation.load_frame(runtime, frame_id)
    else
        null;
    const report = try run_worker(runtime, arguments);

    const snapshot_id: ?[]const u8 = if (report.entries.len > 0)
        try store_snapshot(runtime, report)
    else
        null;
    var nodes: std.ArrayList(OutputNode) = .empty;
    for (report.nodes) |node| {
        if (arguments.interactive and node.ref_index == null) continue;
        try nodes.append(runtime.allocator, try output_node(runtime, node, snapshot_id, frame));
    }
    try runtime.emit(.{
        .ok = true,
        .session_id = runtime.session_id,
        .accessibility = .{
            .nodes = nodes.items,
            .truncated = report.truncated,
            .coordinate_space = report.coordinate_space,
            .snapshot = snapshot_id,
            .read_only = true,
        },
    });
}

fn output_node(
    runtime: *Runtime,
    node: Node,
    snapshot_id: ?[]const u8,
    frame: ?geometry.Frame,
) !OutputNode {
    var ref: ?[]const u8 = null;
    if (snapshot_id) |id| {
        if (node.ref_index) |index| ref = try refs.Ref.format(runtime.allocator, id, index);
    }
    return .{
        .id = node.id,
        .parent = node.parent,
        .depth = node.depth,
        .pid = node.pid,
        .role = node.role,
        .name = node.name,
        .protected = node.protected,
        .focused = node.focused,
        .states = node.states,
        .value = node.value,
        .bounds = node.bounds,
        .ref = ref,
        .frame_point = frame_point(frame, node.bounds),
    };
}

fn frame_point(frame: ?geometry.Frame, bounds: ?Bounds) ?geometry.Point {
    const target = frame orelse return null;
    const box = bounds orelse return null;
    if (box.width <= 0 or box.height <= 0) return null;
    return target.pixel(.{
        .x = box.x + @divFloor(box.width, 2),
        .y = box.y + @divFloor(box.height, 2),
    });
}

/// Writes the snapshot of a `--window` walk and returns its new ID.
fn store_snapshot(runtime: *Runtime, report: Report) ![]const u8 {
    const token = try runtime.random_token();
    const id = token[0..refs.snapshot_id_length];
    const snapshot = refs.Snapshot{
        .id = id,
        .session_id = runtime.session_id,
        .instance = runtime.instance,
        .window = report.window.?,
        .pid = report.pid.?,
        .created_monotonic_ms = native.now_ms(),
        .complete = !report.truncated,
        .entries = report.entries,
    };
    const encoded = try std.json.Stringify.valueAlloc(runtime.allocator, snapshot, .{});
    const path = try runtime.state_path(try refs.file_name(runtime.allocator, id));
    try std.Io.Dir.cwd().writeFile(runtime.io, .{
        .sub_path = path,
        .data = encoded,
        .flags = .{ .exclusive = true },
    });
    return id;
}

pub fn load_snapshot(runtime: *Runtime, ref: refs.Ref) !refs.Snapshot {
    const path = try runtime.state_path(try refs.file_name(runtime.allocator, &ref.snapshot));
    const data = runtime.read_file(path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.SnapshotNotFound,
        else => return err,
    };
    const snapshot = try runtime.parse_json(refs.Snapshot, data);
    if (snapshot.schema_version != 1) return error.SnapshotNotFound;
    if (!std.mem.eql(u8, snapshot.id, &ref.snapshot)) return error.SnapshotNotFound;
    if (!std.mem.eql(u8, snapshot.session_id, runtime.session_id)) return error.SessionMismatch;
    if (!std.mem.eql(u8, snapshot.instance, runtime.instance)) return error.SessionMismatch;
    const age = native.now_ms() - snapshot.created_monotonic_ms;
    if (age < 0 or age > refs.snapshot_max_age_ms) return error.SnapshotExpired;
    return snapshot;
}

fn run_worker(runtime: *Runtime, arguments: Args) !Report {
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
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{
            .duration = .{
                .raw = .fromMilliseconds(arguments.timeout_ms + 1000),
                .clock = .awake,
            },
        },
    });
    try native.check_cancelled();
    return worker_report(runtime, result.term, result.stdout);
}

/// The worker's report, or the error it reported.
fn worker_report(runtime: *Runtime, term: std.process.Child.Term, stdout: []const u8) !Report {
    // A crashed worker leaves no JSON to parse.
    switch (term) {
        .exited => |code| if (code != 0) return worker_error(runtime, stdout),
        else => return error.AccessibilityUnavailable,
    }
    return runtime.parse_json(Report, stdout);
}

/// Window errors the worker reports are passed on; anything else means the
/// accessibility bus did not answer.
fn worker_error(runtime: *Runtime, stdout: []const u8) anyerror {
    const Failure = struct { err: struct { code: []const u8 } };
    const failure = runtime.parse_json(Failure, stdout) catch return error.AccessibilityUnavailable;
    const passed = [_]anyerror{
        error.WindowNotFound,
        error.AccessibilityWindowNotFound,
        error.AccessibilityWindowAmbiguous,
    };
    for (passed) |err| {
        if (std.mem.eql(u8, failure.err.code, @errorName(err))) return err;
    }
    return error.AccessibilityUnavailable;
}
