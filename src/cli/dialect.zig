//! Provider dialects for computer-use models. `hyprhand dialect NAME` reads a
//! model's native action calls on stdin, runs them through the normal input
//! path, and prints the provider's native results. This module only parses
//! calls into operations and shapes results; it touches no desktop.
//!
//! - `anthropic`: `tool_use` blocks of the `computer_toolset_20260801` toolset
//!   (the action is the block's `name`), answered with `tool_result` blocks
//!   that echo `toolset_name`. Coordinates are screenshot pixels.
//! - `openai`: `computer_call` items with an `actions` array, answered with
//!   `computer_call_output` items carrying a screenshot. Screenshot pixels.
//! - `gemini`: `computer_use` function calls, answered with `function_result`
//!   items. Coordinates are normalized to 0-999 of the screenshot.
const std = @import("std");
const eq = @import("../core/text.zig").eq;
const buttons = @import("../input/buttons.zig");

pub const Dialect = @import("args.zig").DialectName;

/// How call coordinates relate to the last screenshot's pixels.
pub const Space = enum { pixels, normalized };

pub const Operation = union(enum) {
    screenshot,
    /// A box of the last screenshot, in its space; never changes that space.
    zoom: [4]f64,
    click: struct { at: ?[2]f64, button: u32, count: u32, mods: ?[]const u8 },
    drag: struct { from: [2]f64, to: [2]f64, mods: ?[]const u8 },
    move: [2]f64,
    scroll: struct { at: ?[2]f64, dx: i32, dy: i32, mods: ?[]const u8 },
    type_text: struct { text: []const u8, enter: bool },
    key: struct { chord: []const u8, repeat: u32 },
    wait_ms: u32,
    cursor_position,
    /// A call hyprhand cannot perform; it fails without sending anything.
    unsupported: []const u8,
};

pub const Call = struct {
    id: []const u8,
    name: []const u8,
    operation: Operation,
    /// Gemini: the model asked for the user's confirmation first.
    needs_confirmation: bool = false,
    /// OpenAI: index of the `computer_call` this action belongs to.
    group: usize = 0,
};

pub fn space(dialect: Dialect) Space {
    return if (dialect == .gemini) .normalized else .pixels;
}

const Value = std.json.Value;

fn field(object: std.json.ObjectMap, name: []const u8) ?Value {
    return object.get(name);
}

fn string(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn number(value: Value) ?f64 {
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => null,
    };
}

fn number_field(object: std.json.ObjectMap, name: []const u8) ?f64 {
    return number(object.get(name) orelse return null);
}

fn pair(value: ?Value) ?[2]f64 {
    const array = value orelse return null;
    if (array != .array or array.array.items.len != 2) return null;
    const x = number(array.array.items[0]) orelse return null;
    const y = number(array.array.items[1]) orelse return null;
    return .{ x, y };
}

fn xy(object: std.json.ObjectMap) ?[2]f64 {
    const x = number_field(object, "x") orelse return null;
    const y = number_field(object, "y") orelse return null;
    return .{ x, y };
}

// --------------------------------------------------------------- parsing ---

/// Parses the calls of one model turn.
pub fn parse(allocator: std.mem.Allocator, dialect: Dialect, input: []const u8) ![]Call {
    const parsed = std.json.parseFromSliceLeaky(Value, allocator, input, .{}) catch
        return error.InvalidDialectInput;
    const items: []const Value = switch (parsed) {
        .array => |array| array.items,
        .object => &.{parsed},
        else => return error.InvalidDialectInput,
    };
    var calls: std.ArrayList(Call) = .empty;
    for (items, 0..) |item, group| {
        if (item != .object) return error.InvalidDialectInput;
        switch (dialect) {
            .anthropic => if (try parse_anthropic(allocator, item.object)) |call| {
                try calls.append(allocator, call);
            },
            .openai => try parse_openai(allocator, item.object, group, &calls),
            .gemini => if (try parse_gemini(allocator, item.object)) |call| {
                try calls.append(allocator, call);
            },
        }
    }
    if (calls.items.len == 0) return error.InvalidDialectInput;
    return calls.toOwnedSlice(allocator);
}

/// One `tool_use` block of the computer toolset; other blocks are ignored.
fn parse_anthropic(allocator: std.mem.Allocator, block: std.json.ObjectMap) !?Call {
    if (!eq(string(block, "type") orelse "", "tool_use")) return null;
    if (!eq(string(block, "toolset_name") orelse "", "computer")) return null;
    const name = string(block, "name") orelse return error.InvalidDialectInput;
    const id = string(block, "id") orelse return error.InvalidDialectInput;
    const empty = std.json.ObjectMap.empty;
    const input_value = block.get("input");
    const input = object_or(input_value, empty);
    const operation = try anthropic_operation(allocator, name, input);
    return .{ .id = id, .name = name, .operation = operation };
}

fn anthropic_operation(
    allocator: std.mem.Allocator,
    name: []const u8,
    input: std.json.ObjectMap,
) !Operation {
    const mods = string(input, "text");
    const at = pair(field(input, "coordinate"));
    const clicks = [_]struct { name: []const u8, button: u32, count: u32 }{
        .{ .name = "left_click", .button = buttons.left, .count = 1 },
        .{ .name = "right_click", .button = buttons.right, .count = 1 },
        .{ .name = "middle_click", .button = buttons.middle, .count = 1 },
        .{ .name = "double_click", .button = buttons.left, .count = 2 },
        .{ .name = "triple_click", .button = buttons.left, .count = 3 },
    };
    for (clicks) |click| {
        if (eq(name, click.name)) {
            return .{ .click = .{
                .at = at,
                .button = click.button,
                .count = click.count,
                .mods = mods,
            } };
        }
    }
    if (eq(name, "screenshot")) return .screenshot;
    if (eq(name, "cursor_position")) return .cursor_position;
    if (eq(name, "zoom")) {
        const region = field(input, "region") orelse return error.InvalidDialectInput;
        if (region != .array or region.array.items.len != 4) return error.InvalidDialectInput;
        var box: [4]f64 = undefined;
        for (region.array.items, &box) |item, *corner| {
            corner.* = number(item) orelse return error.InvalidDialectInput;
        }
        return .{ .zoom = box };
    }
    if (eq(name, "left_click_drag")) {
        const from = pair(field(input, "start_coordinate")) orelse return error.InvalidDialectInput;
        const to = at orelse return error.InvalidDialectInput;
        return .{ .drag = .{ .from = from, .to = to, .mods = mods } };
    }
    if (eq(name, "mouse_move")) return .{ .move = at orelse return error.InvalidDialectInput };
    if (eq(name, "scroll")) return anthropic_scroll(input, at, mods);
    if (eq(name, "type")) {
        const text = string(input, "text") orelse return error.InvalidDialectInput;
        return .{ .type_text = .{ .text = text, .enter = false } };
    }
    if (eq(name, "key")) {
        const text = string(input, "text") orelse return error.InvalidDialectInput;
        const repeat = number_field(input, "repeat") orelse 1;
        const chord = try normalize_chord(allocator, text, '+');
        return .{ .key = .{ .chord = chord, .repeat = clamp_repeat(repeat) } };
    }
    if (eq(name, "wait")) {
        return .{ .wait_ms = seconds_to_ms(number_field(input, "duration") orelse 1) };
    }
    if (eq(name, "left_mouse_down") or eq(name, "left_mouse_up")) {
        return .{
            .unsupported = "hyprhand releases every button when a command ends; " ++
                "use left_click_drag",
        };
    }
    if (eq(name, "hold_key")) {
        return .{ .unsupported = "hyprhand releases every key when a command ends; use key" };
    }
    return .{ .unsupported = "unknown computer toolset member" };
}

fn anthropic_scroll(input: std.json.ObjectMap, at: ?[2]f64, mods: ?[]const u8) !Operation {
    const direction = string(input, "scroll_direction") orelse return error.InvalidDialectInput;
    const requested = number_field(input, "scroll_amount") orelse 3;
    const amount: i32 = @intFromFloat(std.math.clamp(requested, 1, 100));
    const delta = try direction_delta(direction, amount);
    return .{ .scroll = .{ .at = at, .dx = delta[0], .dy = delta[1], .mods = mods } };
}

/// Wheel steps along a named direction: up and left are negative.
fn direction_delta(direction: []const u8, steps: i32) ![2]i32 {
    if (eq(direction, "up")) return .{ 0, -steps };
    if (eq(direction, "down")) return .{ 0, steps };
    if (eq(direction, "left")) return .{ -steps, 0 };
    if (eq(direction, "right")) return .{ steps, 0 };
    return error.InvalidDialectInput;
}

fn object_or(value: ?Value, fallback: std.json.ObjectMap) std.json.ObjectMap {
    const present = value orelse return fallback;
    return if (present == .object) present.object else fallback;
}

/// One `computer_call` item: each of its actions becomes a call.
fn parse_openai(
    allocator: std.mem.Allocator,
    item: std.json.ObjectMap,
    group: usize,
    calls: *std.ArrayList(Call),
) !void {
    if (!eq(string(item, "type") orelse "", "computer_call")) return;
    const id = string(item, "call_id") orelse return error.InvalidDialectInput;
    const actions = field(item, "actions") orelse field(item, "action") orelse
        return error.InvalidDialectInput;
    const list: []const Value = switch (actions) {
        .array => |array| array.items,
        .object => &.{actions},
        else => return error.InvalidDialectInput,
    };
    for (list) |action| {
        if (action != .object) return error.InvalidDialectInput;
        const kind = string(action.object, "type") orelse return error.InvalidDialectInput;
        try calls.append(allocator, .{
            .id = id,
            .name = kind,
            .group = group,
            .operation = try openai_operation(allocator, kind, action.object),
        });
    }
}

/// Pixels of scroll distance per wheel step.
const pixels_per_wheel_step = 100;

fn wheel_steps(pixels: f64) i32 {
    if (pixels == 0) return 0;
    const steps = @max(1, @round(@abs(pixels) / pixels_per_wheel_step));
    const bounded: i32 = @intFromFloat(@min(steps, 100));
    return if (pixels < 0) -bounded else bounded;
}

fn openai_operation(
    allocator: std.mem.Allocator,
    kind: []const u8,
    action: std.json.ObjectMap,
) !Operation {
    const at = xy(action);
    if (eq(kind, "screenshot")) return .screenshot;
    if (eq(kind, "click") or eq(kind, "double_click")) {
        const name = string(action, "button") orelse "left";
        const button = if (eq(name, "wheel")) buttons.middle else buttons.from_name(name) orelse
            return .{ .unsupported = "unknown mouse button" };
        const mods = try keys_chord(allocator, field(action, "keys"));
        const count: u32 = if (eq(kind, "double_click")) 2 else 1;
        return .{ .click = .{
            .at = at orelse return error.InvalidDialectInput,
            .button = button,
            .count = count,
            .mods = mods,
        } };
    }
    if (eq(kind, "move")) return .{ .move = at orelse return error.InvalidDialectInput };
    if (eq(kind, "drag")) {
        const path = field(action, "path") orelse return error.InvalidDialectInput;
        if (path != .array or path.array.items.len < 2) return error.InvalidDialectInput;
        const first = path.array.items[0];
        const last = path.array.items[path.array.items.len - 1];
        if (first != .object or last != .object) return error.InvalidDialectInput;
        const from = xy(first.object) orelse return error.InvalidDialectInput;
        const to = xy(last.object) orelse return error.InvalidDialectInput;
        return .{ .drag = .{ .from = from, .to = to, .mods = null } };
    }
    if (eq(kind, "scroll")) {
        return .{ .scroll = .{
            .at = at,
            .dx = wheel_steps(number_field(action, "scroll_x") orelse 0),
            .dy = wheel_steps(number_field(action, "scroll_y") orelse 0),
            .mods = try keys_chord(allocator, field(action, "keys")),
        } };
    }
    if (eq(kind, "keypress")) {
        const chord = try keys_chord(allocator, field(action, "keys")) orelse
            return error.InvalidDialectInput;
        return .{ .key = .{ .chord = chord, .repeat = 1 } };
    }
    if (eq(kind, "type")) {
        const text = string(action, "text") orelse return error.InvalidDialectInput;
        return .{ .type_text = .{ .text = text, .enter = false } };
    }
    if (eq(kind, "wait")) {
        const duration = std.math.clamp(number_field(action, "ms") orelse 1000, 0, 300_000);
        return .{ .wait_ms = @intFromFloat(duration) };
    }
    return .{ .unsupported = "unknown computer action" };
}

/// One Gemini `computer_use` function call.
fn parse_gemini(allocator: std.mem.Allocator, call: std.json.ObjectMap) !?Call {
    const name = string(call, "name") orelse return error.InvalidDialectInput;
    const id = string(call, "id") orelse string(call, "call_id") orelse name;
    const arguments_value = field(call, "args") orelse field(call, "arguments");
    const empty = std.json.ObjectMap.empty;
    const arguments = object_or(arguments_value, empty);
    var needs_confirmation = false;
    if (field(arguments, "safety_decision")) |decision| {
        if (decision == .object) {
            const verdict = string(decision.object, "decision") orelse "";
            needs_confirmation = eq(verdict, "require_confirmation");
        }
    }
    return .{
        .id = id,
        .name = name,
        .needs_confirmation = needs_confirmation,
        .operation = try gemini_operation(allocator, name, arguments),
    };
}

fn gemini_operation(
    allocator: std.mem.Allocator,
    name: []const u8,
    arguments: std.json.ObjectMap,
) !Operation {
    const at = xy(arguments);
    const clicks = [_]struct { name: []const u8, button: u32, count: u32 }{
        .{ .name = "click", .button = buttons.left, .count = 1 },
        .{ .name = "double_click", .button = buttons.left, .count = 2 },
        .{ .name = "triple_click", .button = buttons.left, .count = 3 },
        .{ .name = "right_click", .button = buttons.right, .count = 1 },
        .{ .name = "middle_click", .button = buttons.middle, .count = 1 },
    };
    for (clicks) |click| {
        if (eq(name, click.name)) {
            return .{ .click = .{
                .at = at orelse return error.InvalidDialectInput,
                .button = click.button,
                .count = click.count,
                .mods = null,
            } };
        }
    }
    if (eq(name, "take_screenshot")) return .screenshot;
    if (eq(name, "move")) return .{ .move = at orelse return error.InvalidDialectInput };
    if (eq(name, "type")) {
        const text = string(arguments, "text") orelse return error.InvalidDialectInput;
        const enter_value = field(arguments, "press_enter");
        const enter = enter_value != null and enter_value.? == .bool and enter_value.?.bool;
        return .{ .type_text = .{ .text = text, .enter = enter } };
    }
    if (eq(name, "drag_and_drop")) {
        const from = [2]f64{
            number_field(arguments, "start_x") orelse return error.InvalidDialectInput,
            number_field(arguments, "start_y") orelse return error.InvalidDialectInput,
        };
        const to = [2]f64{
            number_field(arguments, "end_x") orelse return error.InvalidDialectInput,
            number_field(arguments, "end_y") orelse return error.InvalidDialectInput,
        };
        return .{ .drag = .{ .from = from, .to = to, .mods = null } };
    }
    if (eq(name, "wait")) {
        return .{ .wait_ms = seconds_to_ms(number_field(arguments, "seconds") orelse 1) };
    }
    if (eq(name, "press_key")) {
        const key = string(arguments, "key") orelse return error.InvalidDialectInput;
        return .{ .key = .{ .chord = try normalize_chord(allocator, key, '+'), .repeat = 1 } };
    }
    if (eq(name, "hotkey")) {
        const chord = try keys_chord(allocator, field(arguments, "keys")) orelse
            return error.InvalidDialectInput;
        return .{ .key = .{ .chord = chord, .repeat = 1 } };
    }
    if (eq(name, "scroll")) {
        const direction = string(arguments, "direction") orelse return error.InvalidDialectInput;
        const steps = wheel_steps(number_field(arguments, "magnitude_in_pixels") orelse 300);
        const delta = try direction_delta(direction, steps);
        return .{ .scroll = .{ .at = at, .dx = delta[0], .dy = delta[1], .mods = null } };
    }
    if (eq(name, "go_back")) return .{ .key = .{ .chord = "alt+Left", .repeat = 1 } };
    if (eq(name, "go_forward")) return .{ .key = .{ .chord = "alt+Right", .repeat = 1 } };
    const holds = eq(name, "mouse_down") or eq(name, "mouse_up") or
        eq(name, "key_down") or eq(name, "key_up");
    if (holds) {
        return .{ .unsupported = "hyprhand releases every button and key when a command ends" };
    }
    return .{ .unsupported = "unknown computer_use function" };
}

fn seconds_to_ms(seconds: f64) u32 {
    return @intFromFloat(std.math.clamp(seconds, 0, 300) * 1000);
}

fn clamp_repeat(repeat: f64) u32 {
    return @intFromFloat(std.math.clamp(repeat, 1, 100));
}

// ------------------------------------------------------------------ keys ---

/// Provider key names to the XKB names and modifier spellings hyprhand uses.
const key_aliases = [_][2][]const u8{
    .{ "enter", "Return" },       .{ "return", "Return" },       .{ "esc", "Escape" },
    .{ "escape", "Escape" },      .{ "backspace", "BackSpace" }, .{ "del", "Delete" },
    .{ "delete", "Delete" },      .{ "tab", "Tab" },             .{ "space", "space" },
    .{ "arrowup", "Up" },         .{ "arrowdown", "Down" },      .{ "arrowleft", "Left" },
    .{ "arrowright", "Right" },   .{ "up", "Up" },               .{ "down", "Down" },
    .{ "left", "Left" },          .{ "right", "Right" },         .{ "pageup", "Page_Up" },
    .{ "pagedown", "Page_Down" }, .{ "page_up", "Page_Up" },     .{ "page_down", "Page_Down" },
    .{ "home", "Home" },          .{ "end", "End" },             .{ "insert", "Insert" },
    .{ "ctrl", "ctrl" },          .{ "control", "ctrl" },        .{ "alt", "alt" },
    .{ "option", "alt" },         .{ "shift", "shift" },         .{ "super", "super" },
    .{ "meta", "super" },         .{ "cmd", "super" },           .{ "command", "super" },
    .{ "win", "super" },          .{ "altgr", "altgr" },
};

fn key_name(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " ");
    if (trimmed.len == 0) return error.InvalidDialectInput;
    var buffer: [32]u8 = undefined;
    if (trimmed.len <= buffer.len) {
        const lower = std.ascii.lowerString(buffer[0..trimmed.len], trimmed);
        for (key_aliases) |alias| {
            if (eq(alias[0], lower)) return alias[1];
        }
    }
    // A single letter stays lowercase so a chord does not imply Shift.
    if (trimmed.len == 1 and std.ascii.isAlphabetic(trimmed[0])) {
        return allocator.dupe(u8, &.{std.ascii.toLower(trimmed[0])});
    }
    return allocator.dupe(u8, trimmed);
}

/// "ctrl+s", "CTRL+SHIFT+T" and similar to hyprhand's chord spelling.
pub fn normalize_chord(allocator: std.mem.Allocator, chord: []const u8, separator: u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, chord, separator);
    while (iterator.next()) |part| try parts.append(allocator, try key_name(allocator, part));
    return std.mem.join(allocator, "+", parts.items);
}

/// A JSON list of key names (OpenAI `keys`, Gemini `hotkey.keys`) as one chord.
fn keys_chord(allocator: std.mem.Allocator, keys: ?Value) !?[]const u8 {
    const list = keys orelse return null;
    if (list == .null) return null;
    if (list != .array) return error.InvalidDialectInput;
    if (list.array.items.len == 0) return null;
    var parts: std.ArrayList([]const u8) = .empty;
    for (list.array.items) |item| {
        if (item != .string) return error.InvalidDialectInput;
        try parts.append(allocator, try key_name(allocator, item.string));
    }
    return @as(?[]const u8, try std.mem.join(allocator, "+", parts.items));
}

// --------------------------------------------------------------- results ---

/// What one call produced, for shaping the native result.
pub const Outcome = struct {
    ok: bool,
    /// Text for the model: "OK", a cursor position, or an error description.
    text: []const u8,
    /// Base64 PNG for screenshot and zoom.
    image: ?[]const u8 = null,
    executed: bool = true,
};

pub const not_executed_text = "Not executed: an earlier computer action in this turn failed.";

const AnthropicImage = struct {
    type: []const u8 = "image",
    source: struct {
        type: []const u8 = "base64",
        media_type: []const u8 = "image/png",
        data: []const u8,
    },
};

pub fn anthropic_results(
    allocator: std.mem.Allocator,
    calls: []const Call,
    outcomes: []const Outcome,
) !Value {
    var results = std.json.Array.init(allocator);
    for (calls, outcomes) |call, outcome| {
        var block: std.json.ObjectMap = .empty;
        try block.put(allocator, "type", .{ .string = "tool_result" });
        try block.put(allocator, "tool_use_id", .{ .string = call.id });
        try block.put(allocator, "toolset_name", .{ .string = "computer" });
        if (!outcome.ok) try block.put(allocator, "is_error", .{ .bool = true });
        if (outcome.image) |data| {
            const image = AnthropicImage{ .source = .{ .data = data } };
            try block.put(allocator, "content", try to_value(allocator, &[_]AnthropicImage{image}));
        } else {
            try block.put(allocator, "content", .{ .string = outcome.text });
        }
        try results.append(.{ .object = block });
    }
    return .{ .array = results };
}

/// One `computer_call_output` per `computer_call`, each with the screenshot
/// taken after the whole turn.
pub fn openai_results(
    allocator: std.mem.Allocator,
    calls: []const Call,
    screenshot: []const u8,
) !Value {
    var results = std.json.Array.init(allocator);
    var previous: ?[]const u8 = null;
    for (calls) |call| {
        if (previous != null and eq(previous.?, call.id)) continue;
        previous = call.id;
        const url = try std.fmt.allocPrint(allocator, "data:image/png;base64,{s}", .{screenshot});
        try results.append(try to_value(allocator, .{
            .type = "computer_call_output",
            .call_id = call.id,
            .output = .{ .type = "computer_screenshot", .image_url = url, .detail = "original" },
        }));
    }
    return .{ .array = results };
}

/// One `function_result` per call; the last carries the screenshot taken
/// after the turn. `confirmed` adds `safety_acknowledgement` where the model
/// asked for confirmation.
pub fn gemini_results(
    allocator: std.mem.Allocator,
    calls: []const Call,
    outcomes: []const Outcome,
    screenshot: ?[]const u8,
    confirmed: bool,
) !Value {
    var results = std.json.Array.init(allocator);
    for (calls, outcomes, 0..) |call, outcome, index| {
        var payload: std.json.ObjectMap = .empty;
        try payload.put(allocator, "url", .{ .string = "" });
        if (!outcome.ok) try payload.put(allocator, "error", .{ .string = outcome.text });
        if (call.needs_confirmation and confirmed) {
            try payload.put(allocator, "safety_acknowledgement", .{ .bool = true });
        }
        const text = try std.json.Stringify.valueAlloc(allocator, Value{ .object = payload }, .{});
        var parts = std.json.Array.init(allocator);
        try parts.append(try to_value(allocator, .{ .type = "text", .text = text }));
        const last = index + 1 == calls.len;
        if (last) {
            if (screenshot) |data| {
                const image = .{ .type = "image", .data = data, .mime_type = "image/png" };
                try parts.append(try to_value(allocator, image));
            }
        }
        var result: std.json.ObjectMap = .empty;
        try result.put(allocator, "type", .{ .string = "function_result" });
        try result.put(allocator, "name", .{ .string = call.name });
        try result.put(allocator, "call_id", .{ .string = call.id });
        try result.put(allocator, "result", .{ .array = parts });
        try results.append(.{ .object = result });
    }
    return .{ .array = results };
}

fn to_value(allocator: std.mem.Allocator, data: anytype) !Value {
    const encoded = try std.json.Stringify.valueAlloc(allocator, data, .{});
    return std.json.parseFromSliceLeaky(Value, allocator, encoded, .{});
}

test "anthropic toolset blocks become operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const calls = try parse(arena.allocator(), .anthropic,
        \\[{"type":"text","text":"Clicking"},
        \\ {"type":"tool_use","id":"a","name":"left_click","toolset_name":"computer",
        \\  "input":{"coordinate":[10,20],"text":"ctrl"}},
        \\ {"type":"tool_use","id":"b","name":"triple_click","toolset_name":"computer","input":{}},
        \\ {"type":"tool_use","id":"c","name":"key","toolset_name":"computer",
        \\  "input":{"text":"CTRL+Enter","repeat":3}},
        \\ {"type":"tool_use","id":"d","name":"scroll","toolset_name":"computer",
        \\  "input":{"scroll_direction":"up","scroll_amount":5}},
        \\ {"type":"tool_use","id":"e","name":"hold_key","toolset_name":"computer",
        \\  "input":{"text":"shift","duration":1}},
        \\ {"type":"tool_use","id":"f","name":"bash","input":{}}]
    );
    try std.testing.expectEqual(@as(usize, 5), calls.len);
    const click = calls[0].operation.click;
    try std.testing.expectEqual([2]f64{ 10, 20 }, click.at.?);
    try std.testing.expectEqualStrings("ctrl", click.mods.?);
    try std.testing.expectEqual(@as(u32, 3), calls[1].operation.click.count);
    try std.testing.expectEqual(@as(?[2]f64, null), calls[1].operation.click.at);
    try std.testing.expectEqualStrings("ctrl+Return", calls[2].operation.key.chord);
    try std.testing.expectEqual(@as(u32, 3), calls[2].operation.key.repeat);
    try std.testing.expectEqual(@as(i32, -5), calls[3].operation.scroll.dy);
    try std.testing.expect(calls[4].operation == .unsupported);
}

test "openai actions and gemini calls become operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const openai = try parse(allocator, .openai,
        \\{"type":"computer_call","call_id":"c1","actions":[
        \\ {"type":"click","button":"back","x":5,"y":6},
        \\ {"type":"keypress","keys":["CTRL","SHIFT","T"]},
        \\ {"type":"scroll","x":1,"y":2,"scroll_x":0,"scroll_y":-250},
        \\ {"type":"drag","path":[{"x":1,"y":1},{"x":5,"y":5},{"x":9,"y":9}]}]}
    );
    try std.testing.expectEqual(buttons.back, openai[0].operation.click.button);
    try std.testing.expectEqualStrings("ctrl+shift+t", openai[1].operation.key.chord);
    try std.testing.expectEqual(@as(i32, -3), openai[2].operation.scroll.dy);
    try std.testing.expectEqual([2]f64{ 9, 9 }, openai[3].operation.drag.to);

    const gemini = try parse(allocator, .gemini,
        \\[{"name":"type","args":{"text":"hola","press_enter":true}},
        \\ {"name":"click","id":"g2","args":{"x":500,"y":250,
        \\  "safety_decision":{"decision":"require_confirmation","explanation":"buy"}}},
        \\ {"name":"hotkey","args":{"keys":["Control","a"]}}]
    );
    try std.testing.expect(gemini[0].operation.type_text.enter);
    try std.testing.expect(gemini[1].needs_confirmation);
    try std.testing.expectEqualStrings("g2", gemini[1].id);
    try std.testing.expectEqualStrings("ctrl+a", gemini[2].operation.key.chord);
    try std.testing.expectEqual(Space.normalized, space(.gemini));
    try std.testing.expectError(error.InvalidDialectInput, parse(allocator, .gemini, "[]"));
}
