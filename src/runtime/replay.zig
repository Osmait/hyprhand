//! `replay NAME`: resolves each journal step on the live desktop and builds
//! the command that repeats it. Windows are found by class (and title when
//! several share it), elements by role and name, which must be unique; pointer
//! steps get a fresh frame and aim at the element's centre, or at the recorded
//! point relative to the window when no element was recorded and the window
//! still has its recorded size. Nothing here sends input.
const std = @import("std");
const args = @import("../cli/args.zig");
const eq = @import("../core/text.zig").eq;
const Runtime = @import("runtime.zig").Runtime;
const geometry = @import("../core/geometry.zig");
const observation = @import("../capture/observation.zig");
const tree = @import("../accessibility/tree.zig");
const journal = @import("journal.zig");

/// A step ready to run: an optional focus first, then the action.
pub const Resolved = struct {
    focus_first: ?[]const u8 = null,
    action: args.Args,
    window: ?[]const u8 = null,
    ref: ?[]const u8 = null,
    point: ?[2]u32 = null,
};

pub fn resolve(runtime: *Runtime, step: journal.Step, session: []const u8) !Resolved {
    var action = args.Args{ .command = step.command, .session = session, .explicit_session = true };
    const window: ?[]const u8 = if (step.window) |recorded|
        try find_window(runtime, recorded)
    else
        null;
    var resolved = Resolved{ .action = action, .window = window };
    switch (step.command) {
        .focus => action.focus_window = window orelse return error.ReplayWindowNotFound,
        .workspace => action.workspace_target = step.workspace orelse return error.InvalidJournal,
        .launch => action.program = step.program,
        .type, .key => try resolve_keyboard(step, window, &action, &resolved),
        .act => try resolve_act(runtime, step, window, &action, &resolved),
        .click, .doubleclick, .move, .scroll, .drag => {
            try resolve_pointer(runtime, step, window, &action, &resolved);
        },
        else => return error.InvalidJournal,
    }
    resolved.action = action;
    return resolved;
}

fn resolve_keyboard(
    step: journal.Step,
    window: ?[]const u8,
    action: *args.Args,
    resolved: *Resolved,
) !void {
    const address = window orelse return error.ReplayWindowNotFound;
    action.window = address;
    action.backend = step.backend;
    resolved.focus_first = address;
    if (step.command == .key) {
        action.key_chord = step.chord orelse return error.InvalidJournal;
        action.key_repeat = step.key_repeat;
        return;
    }
    if (step.secret) return error.ReplaySecretStep;
    action.text = step.text orelse return error.ReplaySecretStep;
}

fn resolve_act(
    runtime: *Runtime,
    step: journal.Step,
    window: ?[]const u8,
    action: *args.Args,
    resolved: *Resolved,
) !void {
    const address = window orelse return error.ReplayWindowNotFound;
    const element = step.element orelse return error.InvalidJournal;
    const node = try find_element(runtime, address, element, null);
    action.act_verb = step.verb orelse return error.InvalidJournal;
    action.ref = node.ref orelse return error.ReplayElementNotFound;
    action.text = step.text;
    if (step.verb.? == .@"set-value" and step.text == null) return error.ReplaySecretStep;
    resolved.ref = action.ref;
}

fn resolve_pointer(
    runtime: *Runtime,
    step: journal.Step,
    window: ?[]const u8,
    action: *args.Args,
    resolved: *Resolved,
) !void {
    const address = window orelse return error.ReplayWindowNotFound;
    const frame = try observation.observe_frame(runtime, .{
        .command = .observe,
        .session = action.session,
        .explicit_session = true,
        .window = address,
    });
    const target = if (step.element) |element| element_point: {
        const node = try find_element(runtime, address, element, frame);
        const point = node.frame_point orelse return error.ReplayElementNotFound;
        break :element_point [2]u32{ @intCast(point.x), @intCast(point.y) };
    } else try relative_point(runtime, step, address, frame, step.point);
    action.frame = frame.frame_id;
    action.x = @floatFromInt(target[0]);
    action.y = @floatFromInt(target[1]);
    action.button = step.button;
    action.click_count = step.click_count;
    action.mods = step.mods;
    action.dx = step.dx;
    action.dy = step.dy;
    action.scroll_mode = step.scroll_mode;
    action.duration_ms = step.duration_ms;
    if (step.command == .drag) {
        const destination = try relative_point(runtime, step, address, frame, step.to_point);
        action.to_x = @floatFromInt(destination[0]);
        action.to_y = @floatFromInt(destination[1]);
    }
    resolved.point = target;
}

/// A point recorded relative to the window, mapped into a fresh frame. Only
/// while the window keeps its recorded size: a resized layout moves controls.
fn relative_point(
    runtime: *Runtime,
    step: journal.Step,
    address: []const u8,
    frame: geometry.Frame,
    recorded: ?[2]i32,
) ![2]u32 {
    const offset = recorded orelse return error.InvalidJournal;
    const client = try tree.find_client(runtime, address);
    const size = step.window_size orelse return error.ReplayLayoutChanged;
    if (size[0] != client.size[0] or size[1] != client.size[1]) return error.ReplayLayoutChanged;
    const desktop = geometry.Point{ .x = client.at[0] + offset[0], .y = client.at[1] + offset[1] };
    const pixel = frame.pixel(desktop) orelse return error.ReplayLayoutChanged;
    return .{ @intCast(pixel.x), @intCast(pixel.y) };
}

/// The window with the recorded class: the only one, or the only one that
/// also has the recorded title.
fn find_window(runtime: *Runtime, recorded: journal.WindowRef) ![]const u8 {
    const clients = try runtime.query_json([]observation.Client, "clients");
    var by_class: ?[]const u8 = null;
    var class_count: usize = 0;
    var by_title: ?[]const u8 = null;
    var title_count: usize = 0;
    for (clients) |client| {
        if (!eq(client.class, recorded.class)) continue;
        if (!client.mapped or client.hidden) continue;
        class_count += 1;
        by_class = client.address;
        if (eq(client.title, recorded.title)) {
            title_count += 1;
            by_title = client.address;
        }
    }
    if (class_count == 1) return by_class.?;
    if (title_count == 1) return by_title.?;
    if (class_count == 0) return error.ReplayWindowNotFound;
    return error.ReplayWindowAmbiguous;
}

/// The window's only operable element with the recorded role and name.
fn find_element(
    runtime: *Runtime,
    address: []const u8,
    element: journal.Element,
    frame: ?geometry.Frame,
) !tree.OutputNode {
    const reading = try tree.read(runtime, .{
        .command = .accessibility,
        .session = runtime.session_id,
        .window = address,
        .interactive = true,
        .depth = 20,
        .limit = 1000,
    }, frame);
    var found: ?tree.OutputNode = null;
    for (reading.nodes) |node| {
        if (!eq(node.role, element.role)) continue;
        if (!eq(node.name orelse "", element.name)) continue;
        if (found != null) return error.ReplayElementAmbiguous;
        found = node;
    }
    return found orelse error.ReplayElementNotFound;
}
