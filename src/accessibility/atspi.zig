//! Zig views of the AT-SPI bridge shared by the tree and action workers.
//! Every string is copied into the caller's allocator before the C side frees
//! it, and every node returned to a caller is owned by that caller.
const std = @import("std");
const assert = std.debug.assert;
const eq = @import("../core/text.zig").eq;
const refs = @import("refs.zig");
pub const c = @import("accessibility_c");

pub const Node = *c.DeskNode;
pub const Rect = struct { x: i32, y: i32, width: i32, height: i32 };

const name_limit = 4096;
const description_limit = 1024;
const id_limit = 256;

pub const Info = struct {
    role: []const u8,
    name: ?[]const u8,
    description: ?[]const u8,
    accessible_id: ?[]const u8,
    pid: u32,
    protected: bool,
    states: u32,
    interfaces: u32,
    action_count: u32,
    /// As the application reports it; on Wayland often relative to the
    /// window or simply 0,0.
    screen: ?Rect,
    /// Relative to the element's toplevel window.
    window: ?Rect,

    pub fn has_state(self: Info, bit: c_uint) bool {
        return self.states & bit != 0;
    }

    pub fn has_interface(self: Info, bit: c_uint) bool {
        return self.interfaces & bit != 0;
    }

    pub fn identity(self: Info) refs.Identity {
        return .{
            .role = self.role,
            .name = self.name,
            .accessible_id = self.accessible_id,
            .description = self.description,
        };
    }

    /// Elements a person operates: refs are minted for these.
    pub fn operable(self: Info) bool {
        if (refs.interactive_role(self.role)) return true;
        if (self.has_state(c.DESK_STATE_FOCUSABLE)) return true;
        return self.has_state(c.DESK_STATE_EDITABLE);
    }
};

/// Copies a C string, at most `limit` bytes; empty strings become null.
fn copy(allocator: std.mem.Allocator, value: [*c]const u8, limit: usize) !?[]const u8 {
    if (value == null) return null;
    const span = std.mem.span(value);
    if (span.len == 0) return null;
    // Cut on a UTF-8 boundary so the copy stays valid text.
    var length = @min(limit, span.len);
    while (length > 0 and length < span.len and (span[length] & 0xC0) == 0x80) length -= 1;
    return try allocator.dupe(u8, span[0..length]);
}

fn rect(present: c_int, value: c.DeskRect) ?Rect {
    if (present == 0) return null;
    return .{ .x = value.x, .y = value.y, .width = value.width, .height = value.height };
}

pub fn info(allocator: std.mem.Allocator, node: Node) !Info {
    var raw: c.DeskInfo = undefined;
    c.desk_a11y_info(node, &raw);
    defer c.desk_a11y_info_free(&raw);
    return .{
        .role = (try copy(allocator, raw.role, name_limit)) orelse "unknown",
        .name = try copy(allocator, raw.name, name_limit),
        .description = try copy(allocator, raw.description, description_limit),
        .accessible_id = try copy(allocator, raw.accessible_id, id_limit),
        .pid = raw.pid,
        .protected = raw.protected_value != 0,
        .states = raw.states,
        .interfaces = raw.interfaces,
        .action_count = @intCast(@max(raw.action_count, 0)),
        .screen = rect(raw.has_bounds, raw.bounds),
        .window = rect(raw.has_window_bounds, raw.window_bounds),
    };
}

/// The application with this process ID, or null. The caller unrefs it.
pub fn application(desktop: Node, pid: u32) ?Node {
    const count = c.desk_a11y_count(desktop);
    var index: c_int = 0;
    while (index < count) : (index += 1) {
        const app = c.desk_a11y_child(desktop, index) orelse continue;
        if (c.desk_a11y_pid(app) == pid) return app;
        c.desk_a11y_unref(app);
    }
    return null;
}

const toplevel_roles = [_][]const u8{ "frame", "window", "dialog", "alert", "file chooser" };

fn toplevel_role(role: []const u8) bool {
    for (toplevel_roles) |candidate| {
        if (eq(candidate, role)) return true;
    }
    return false;
}

pub const Toplevel = struct { node: Node, index: u32 };

/// The application's toplevel for a compositor window: the one whose name is
/// the window title, or the only toplevel when no name matches. The caller
/// unrefs the node.
pub fn toplevel(allocator: std.mem.Allocator, app: Node, title: []const u8) !Toplevel {
    var by_title: ?Toplevel = null;
    var only: ?Toplevel = null;
    var titled: u32 = 0;
    var toplevels: u32 = 0;
    errdefer for ([_]?Toplevel{ by_title, only }) |kept| {
        if (kept) |found| c.desk_a11y_unref(found.node);
    };

    const count = c.desk_a11y_count(app);
    var index: c_int = 0;
    while (index < count) : (index += 1) {
        const node = c.desk_a11y_child(app, index) orelse continue;
        const details = try info(allocator, node);
        if (!toplevel_role(details.role)) {
            c.desk_a11y_unref(node);
            continue;
        }
        toplevels += 1;
        const candidate = Toplevel{ .node = node, .index = @intCast(index) };
        const matches = eq(details.name orelse "", title);
        if (matches) titled += 1;
        if (matches and by_title == null) {
            by_title = candidate;
        } else if (only == null) {
            only = candidate;
        } else {
            c.desk_a11y_unref(node);
        }
    }
    if (titled == 1) {
        if (only) |unused| c.desk_a11y_unref(unused.node);
        return by_title.?;
    }
    if (titled == 0 and toplevels == 1) return only.?;
    if (toplevels == 0) return error.AccessibilityWindowNotFound;
    return error.AccessibilityWindowAmbiguous;
}

/// Follows a non-empty `path` from `root`. Returns null when a step no longer
/// exists. The caller unrefs the result; `root` stays the caller's.
pub fn follow(root: Node, path: []const u32) ?Node {
    assert(path.len >= 1);
    assert(path.len <= refs.path_max);
    var current: ?Node = null;
    for (path) |index| {
        const parent = current orelse root;
        const next = c.desk_a11y_child(parent, @intCast(index));
        if (current) |owned| c.desk_a11y_unref(owned);
        current = next orelse return null;
    }
    return current;
}

/// Lowercased action names, in the order `do_action` indexes them.
pub fn action_names(allocator: std.mem.Allocator, node: Node, count: u32) ![]const []const u8 {
    const names = try allocator.alloc([]const u8, @min(count, 32));
    for (names, 0..) |*name, index| {
        const raw = c.desk_a11y_action_name(node, @intCast(index));
        defer c.desk_a11y_free(raw);
        const value = (try copy(allocator, raw, 64)) orelse "";
        name.* = try std.ascii.allocLowerString(allocator, value);
    }
    return names;
}

/// The element's text, at most `limit_chars` characters, or null.
pub fn text(allocator: std.mem.Allocator, node: Node, limit_chars: u32) !?[]const u8 {
    const raw = c.desk_a11y_text(node, @intCast(limit_chars));
    defer c.desk_a11y_free(raw);
    if (raw == null) return null;
    return try allocator.dupe(u8, std.mem.span(raw));
}

pub fn toolkit(allocator: std.mem.Allocator, node: Node) !?[]const u8 {
    const raw = c.desk_a11y_toolkit(node);
    defer c.desk_a11y_free(raw);
    return copy(allocator, raw, 64);
}

pub const Value = struct { current: f64, minimum: f64, maximum: f64, increment: f64 };

pub fn range_value(node: Node) ?Value {
    var result: Value = undefined;
    const present = c.desk_a11y_value(
        node,
        &result.current,
        &result.minimum,
        &result.maximum,
        &result.increment,
    );
    if (present == 0) return null;
    return result;
}

/// Human-readable states worth an agent's attention, in a fixed order.
pub fn state_names(allocator: std.mem.Allocator, details: Info) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const notable = [_]struct { bit: c_uint, name: []const u8 }{
        .{ .bit = c.DESK_STATE_FOCUSED, .name = "focused" },
        .{ .bit = c.DESK_STATE_CHECKED, .name = "checked" },
        .{ .bit = c.DESK_STATE_INDETERMINATE, .name = "indeterminate" },
        .{ .bit = c.DESK_STATE_PRESSED, .name = "pressed" },
        .{ .bit = c.DESK_STATE_EXPANDED, .name = "expanded" },
        .{ .bit = c.DESK_STATE_SELECTED, .name = "selected" },
        .{ .bit = c.DESK_STATE_EDITABLE, .name = "editable" },
        .{ .bit = c.DESK_STATE_READ_ONLY, .name = "read_only" },
    };
    for (notable) |state| {
        if (details.has_state(state.bit)) try names.append(allocator, state.name);
    }
    const collapsed = details.has_state(c.DESK_STATE_EXPANDABLE) and
        !details.has_state(c.DESK_STATE_EXPANDED);
    if (collapsed) try names.append(allocator, "collapsed");
    // GTK 4 reports SENSITIVE without ENABLED for usable widgets.
    const usable = details.has_state(c.DESK_STATE_ENABLED) or
        details.has_state(c.DESK_STATE_SENSITIVE);
    if (details.operable() and !usable) try names.append(allocator, "disabled");
    return names.toOwnedSlice(allocator);
}

/// Roles whose name some toolkits set to the current value. Such a name is
/// left out of the identity, or every edit would make the element's ref stale.
const mutable_roles = [_][]const u8{ "entry", "text", "combo box", "spin button" };

pub fn mutable_role(role: []const u8) bool {
    for (mutable_roles) |candidate| {
        if (eq(candidate, role)) return true;
    }
    return false;
}

/// Roles whose elements toolkits often leave unnamed while a child shows the
/// text (GTK 4 list rows). Such an element is named after that child.
const labelled_by_child_roles = [_][]const u8{
    "list item", "table cell", "tree item", "page tab", "menu item", "push button", "button",
};

/// The name of the first child that has one, looking two levels down.
fn child_name(allocator: std.mem.Allocator, node: Node) !?[]const u8 {
    const count = @min(c.desk_a11y_count(node), 8);
    var index: c_int = 0;
    while (index < count) : (index += 1) {
        const child = c.desk_a11y_child(node, index) orelse continue;
        defer c.desk_a11y_unref(child);
        const details = try info(allocator, child);
        if (details.name) |name| return name;
        const grandchild = c.desk_a11y_child(child, 0) orelse continue;
        defer c.desk_a11y_unref(grandchild);
        if ((try info(allocator, grandchild)).name) |name| return name;
    }
    return null;
}

/// The identity a ref records and later checks.
pub fn stable_identity(allocator: std.mem.Allocator, node: Node, details: Info) !refs.Identity {
    var identity = details.identity();
    if (identity.name == null and !details.protected) {
        for (labelled_by_child_roles) |role| {
            if (eq(role, details.role)) identity.name = try child_name(allocator, node);
        }
    }
    if (!mutable_role(details.role)) return identity;
    const name = identity.name orelse return identity;
    const current = (try text(allocator, node, name_limit)) orelse return identity;
    if (eq(name, current)) identity.name = null;
    return identity;
}
