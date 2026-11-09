//! Accessibility refs: `@<snapshot>:e<N>` names one element of one
//! accessibility snapshot. A ref stores where the element was (its child
//! path from the window's toplevel) and what it was (its identity). A later
//! semantic action follows the path, checks the identity, and fails closed
//! when the element is gone (`StaleRef`) or cannot be told apart from another
//! (`AmbiguousTarget`). Position and value are never part of the identity.
const std = @import("std");
const assert = std.debug.assert;
const eq = @import("../core/text.zig").eq;

/// Snapshot IDs are eight lowercase hexadecimal digits.
pub const snapshot_id_length = 8;
/// Snapshots older than this are refused; the GC removes them later.
pub const snapshot_max_age_ms = 5 * 60 * 1000;
/// The deepest path a ref may hold; matches the deepest walk.
pub const path_max = 32;

pub const Identity = struct {
    role: []const u8,
    name: ?[]const u8 = null,
    accessible_id: ?[]const u8 = null,
    description: ?[]const u8 = null,

    /// Equal roles, and equal names, IDs and descriptions where an empty
    /// value counts as absent.
    pub fn eql(a: Identity, b: Identity) bool {
        if (!eq(a.role, b.role)) return false;
        if (!same_text(a.name, b.name)) return false;
        if (!same_text(a.accessible_id, b.accessible_id)) return false;
        return same_text(a.description, b.description);
    }
};

fn same_text(a: ?[]const u8, b: ?[]const u8) bool {
    const left = a orelse "";
    const right = b orelse "";
    return eq(left, right);
}

/// One element a ref can name.
pub const Entry = struct {
    /// The N of `eN`, from 1.
    index: u32,
    /// Child indices from the window's toplevel to the element.
    path: []const u32,
    identity: Identity,
    /// Elements of the same snapshot with an equal identity, this one included.
    twins: u32,
    /// Password fields: semantic writes are refused.
    protected: bool = false,
};

pub const Snapshot = struct {
    schema_version: u32 = 1,
    id: []const u8,
    session_id: []const u8,
    instance: []const u8,
    /// The Hyprland window address the snapshot was taken of.
    window: []const u8,
    pid: u32,
    created_monotonic_ms: i64,
    /// False when the walk stopped at its node, depth or time limit: twins
    /// outside the walked part were not counted.
    complete: bool,
    entries: []const Entry,

    pub fn entry(self: Snapshot, index: u32) ?Entry {
        for (self.entries) |candidate| {
            if (candidate.index == index) return candidate;
        }
        return null;
    }
};

pub const Ref = struct {
    snapshot: [snapshot_id_length]u8,
    index: u32,

    /// Parses "@1a2b3c4d:e12". A bare "e12" or "@e12" names no snapshot and
    /// is rejected: refs from different snapshots must never be confused.
    pub fn parse(text: []const u8) !Ref {
        const prefix_length = 1 + snapshot_id_length + 2;
        if (text.len <= prefix_length) return error.InvalidRef;
        if (text.len > prefix_length + 9) return error.InvalidRef;
        if (text[0] != '@') return error.InvalidRef;
        const id = text[1 .. 1 + snapshot_id_length];
        for (id) |character| {
            const lower_letter = character >= 'a' and character <= 'f';
            const lower_hex = std.ascii.isDigit(character) or lower_letter;
            if (!lower_hex) return error.InvalidRef;
        }
        if (!eq(text[1 + snapshot_id_length .. prefix_length], ":e")) return error.InvalidRef;
        const digits = text[prefix_length..];
        if (digits[0] == '0') return error.InvalidRef;
        const index = std.fmt.parseInt(u32, digits, 10) catch return error.InvalidRef;
        assert(index >= 1);

        var result = Ref{ .snapshot = undefined, .index = index };
        @memcpy(&result.snapshot, id);
        return result;
    }

    pub fn format(allocator: std.mem.Allocator, snapshot_id: []const u8, index: u32) ![]u8 {
        assert(snapshot_id.len == snapshot_id_length);
        assert(index >= 1);
        return std.fmt.allocPrint(allocator, "@{s}:e{d}", .{ snapshot_id, index });
    }
};

/// The snapshot file name inside the state directory: "<id>.a11y".
pub fn file_name(allocator: std.mem.Allocator, snapshot_id: []const u8) ![]u8 {
    assert(snapshot_id.len == snapshot_id_length);
    return std.fmt.allocPrint(allocator, "{s}.a11y", .{snapshot_id});
}

/// Counts, for each identity, how many identities in `all` equal it.
pub fn count_twins(allocator: std.mem.Allocator, all: []const Identity) ![]u32 {
    var totals = std.StringHashMap(u32).init(allocator);
    defer totals.deinit();
    const keys = try allocator.alloc([]const u8, all.len);
    defer allocator.free(keys);
    for (all, keys) |identity, *key| {
        key.* = try identity_key(allocator, identity);
        const slot = try totals.getOrPut(key.*);
        slot.value_ptr.* = if (slot.found_existing) slot.value_ptr.* + 1 else 1;
    }
    const counts = try allocator.alloc(u32, all.len);
    for (keys, counts) |key, *count| {
        count.* = totals.get(key).?;
        assert(count.* >= 1);
    }
    for (keys) |key| allocator.free(key);
    return counts;
}

/// A byte string equal for exactly the identities `eql` calls equal.
fn identity_key(allocator: std.mem.Allocator, identity: Identity) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\x00{s}\x00{s}\x00{s}", .{
        identity.role,
        identity.name orelse "",
        identity.accessible_id orelse "",
        identity.description orelse "",
    });
}

/// Roles that a person operates rather than reads. Elements with these roles,
/// or that are focusable or editable, receive refs.
const interactive_roles = [_][]const u8{
    "push button",     "button",           "toggle button", "check box",
    "radio button",    "combo box",        "menu item",     "check menu item",
    "radio menu item", "page tab",         "link",          "entry",
    "text",            "password text",    "spin button",   "slider",
    "list item",       "table cell",       "tree item",     "switch",
    "scroll bar",      "push button menu", "menu",          "tree table",
    "list box",        "toggle switch",    "dial",
};

pub fn interactive_role(role: []const u8) bool {
    for (interactive_roles) |candidate| {
        if (eq(candidate, role)) return true;
    }
    return false;
}

test "refs name a snapshot and an element, nothing else" {
    const ref = try Ref.parse("@1a2b3c4d:e12");
    try std.testing.expectEqualStrings("1a2b3c4d", &ref.snapshot);
    try std.testing.expectEqual(@as(u32, 12), ref.index);
    const invalid = [_][]const u8{
        "e12",           "@e12",          "@1a2b3c4d:e",  "@1a2b3c4d:e0",
        "@1A2B3C4D:e1",  "@1a2b3c4:e1",   "@1a2b3c4d:x1", "@1a2b3c4d:e01",
        "@1a2b3c4d:e-1", "@1a2b3c4d:e1 ", "1a2b3c4d:e1",  "@1a2b3c4d:e99999999999",
    };
    for (invalid) |text| try std.testing.expectError(error.InvalidRef, Ref.parse(text));

    const formatted = try Ref.format(std.testing.allocator, "1a2b3c4d", 7);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("@1a2b3c4d:e7", formatted);
}

test "identity ignores position and treats empty text as absent" {
    const button = Identity{ .role = "push button", .name = "Save" };
    const described = Identity{ .role = "push button", .name = "Save", .description = "" };
    try std.testing.expect(button.eql(described));
    try std.testing.expect(!button.eql(.{ .role = "push button", .name = "Cancel" }));
    try std.testing.expect(!button.eql(.{ .role = "link", .name = "Save" }));
    const with_id = Identity{ .role = "push button", .name = "Save", .accessible_id = "a" };
    try std.testing.expect(!button.eql(with_id));

    const identities = [_]Identity{ button, .{ .role = "push button", .name = "Cancel" }, button };
    const counts = try count_twins(std.testing.allocator, &identities);
    defer std.testing.allocator.free(counts);
    try std.testing.expectEqualSlices(u32, &.{ 2, 1, 2 }, counts);
}
