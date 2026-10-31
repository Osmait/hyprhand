const std = @import("std");
const args = @import("../cli/args.zig");
const geometry = @import("../core/geometry.zig");
const eq = @import("../core/text.zig").eq;
const native = @import("../platform/native.zig");
const c = native.c;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const sessions = @import("../runtime/sessions.zig");
const observation = @import("../capture/observation.zig");
const Client = observation.Client;
const buttons = @import("buttons.zig");
const keyboard = @import("keyboard.zig");
const Keyboard = keyboard.Keyboard;
const Chord = keyboard.Chord;
const pointer_device = @import("pointer.zig");
const Pointer = pointer_device.Pointer;
const motion = @import("motion.zig");
const scroll_pacing = @import("scroll.zig");
const Aura = @import("aura.zig").Aura;

fn validate_address(address: []const u8) !void {
    if (!std.mem.startsWith(u8, address, "0x") or address.len < 3 or address.len > 18) return error.InvalidWindowAddress;
    for (address[2..]) |ch| if (!std.ascii.isHex(ch)) return error.InvalidWindowAddress;
}

fn check_window(runtime: *Runtime, address: []const u8, require_focus: bool) !void {
    try validate_address(address);
    const clients = try runtime.query_json([]Client, "clients");
    var found = false;
    for (clients) |client| {
        if (eq(client.address, address) and client.mapped and !client.hidden) {
            found = true;
            break;
        }
    }
    if (!found) return error.WindowNotFound;
    if (require_focus and !eq(try runtime.active_window(), address)) return error.WindowNotFocused;
}

/// wtype argv: press modifiers in order, tap the key, release in reverse.
fn key_args(allocator: std.mem.Allocator, chord: []const u8) ![]const []const u8 {
    const parsed = try Chord.parse(allocator, chord);
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(allocator, "wtype");
    for (parsed.modifier_slice()) |index| try out.appendSlice(allocator, &.{ "-M", keyboard.modifiers[index].alias });
    try out.appendSlice(allocator, &.{ "-k", parsed.key_name });
    var i = parsed.count;
    while (i > 0) {
        i -= 1;
        try out.appendSlice(allocator, &.{ "-m", keyboard.modifiers[parsed.mods[i]].alias });
    }
    return out.toOwnedSlice(allocator);
}

/// xdotool spelling of the same chord, e.g. "ctrl+super+Return".
fn x11_chord(allocator: std.mem.Allocator, chord: []const u8) ![]const u8 {
    const parsed = try Chord.parse(allocator, chord);
    var result: std.ArrayList(u8) = .empty;
    for (parsed.modifier_slice()) |index| {
        try result.appendSlice(allocator, keyboard.modifiers[index].x11);
        try result.append(allocator, '+');
    }
    try result.appendSlice(allocator, parsed.key_name);
    return result.toOwnedSlice(allocator);
}

fn x11_keyboard(runtime: *Runtime, address: []const u8) !bool {
    const clients = try runtime.query_json([]Client, "clients");
    for (clients) |client| {
        if (!eq(client.address, address)) continue;
        if (!client.xwayland) return false;
        if (!try runtime.executable("xdotool")) return error.XWaylandHelperMissing;
        // DISPLAY can point at another X server. Check its focused PID first.
        const result = try std.process.run(runtime.allocator, runtime.io, .{
            .argv = &.{ "xdotool", "getwindowfocus", "getwindowpid" },
            .environ_map = runtime.env,
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(4096),
            .timeout = .{ .duration = .{ .raw = .fromMilliseconds(try native.remaining_ms(3000)), .clock = .awake } },
        });
        switch (result.term) {
            .exited => |code| if (code != 0) {
                return error.X11TargetMismatch;
            },
            else => return error.X11TargetMismatch,
        }
        const pid = std.fmt.parseInt(i64, std.mem.trim(u8, result.stdout, " \r\n"), 10) catch return error.X11TargetMismatch;
        if (client.pid <= 0 or pid != client.pid) return error.X11TargetMismatch;
        return true;
    }
    return error.WindowNotFound;
}

/// XTEST wheel clicks for XWayland clients: vertical first, then horizontal.
fn x11_wheel(runtime: *Runtime, dx: i32, dy: i32) !void {
    const steps = [_]struct { amount: i32, positive: u8, negative: u8 }{
        .{ .amount = dy, .positive = buttons.x11.wheel_down, .negative = buttons.x11.wheel_up },
        .{ .amount = dx, .positive = buttons.x11.wheel_right, .negative = buttons.x11.wheel_left },
    };
    for (steps) |step| {
        if (step.amount == 0) continue;
        const button = if (step.amount > 0) step.positive else step.negative;
        const repeat = try std.fmt.allocPrint(runtime.allocator, "{d}", .{@abs(step.amount)});
        const button_text = try std.fmt.allocPrint(runtime.allocator, "{d}", .{button});
        try runtime.run_helper(&.{ "xdotool", "click", "--repeat", repeat, "--delay", "0", button_text }, null, true);
    }
}

fn scroll(runtime: *Runtime, pointer: *Pointer, point: geometry.Point, dx: i32, dy: i32, ms: u32, mode: []const u8) !void {
    const active = try runtime.active_window();
    runtime.target_window = active;
    const wheel = eq(mode, "wheel") or (eq(mode, "auto") and ms == 0);
    const clients = try runtime.query_json([]Client, "clients");
    for (clients) |client| {
        if (!eq(client.address, active) or !client.xwayland) continue;
        if (eq(mode, "continuous")) return error.ContinuousScrollUnavailable;
        // XWayland does not consistently translate virtual Wayland axis events.
        // XTEST wheel buttons are used only inside the verified focused client.
        if (!client.contains(point)) return error.WindowNotFocused;
        _ = try x11_keyboard(runtime, client.address);
        if (ms == 0) return x11_wheel(runtime, dx, dy);
        var driver = ScrollDriver{ .runtime = runtime, .pointer = pointer, .point = point, .x11 = true };
        return scroll_pacing.run(&driver, .{ .x = dx, .y = dy }, ms);
    }
    if (wheel and ms == 0) return pointer.scroll(dx, dy);
    var driver = ScrollDriver{ .runtime = runtime, .pointer = pointer, .point = point, .wheel = wheel };
    // Wheel detents are independent steps, not a continuous gesture. Sending
    // axis_stop for them can flush a spurious surface-distance event in GTK.
    defer if (!wheel) pointer.end_scroll(dx, dy);
    const unit: i32 = if (wheel) 1 else pointer_device.wheel_detent_units;
    try scroll_pacing.run(&driver, .{ .x = dx * unit, .y = dy * unit }, ms);
}

fn expect_cursor_at(runtime: *Runtime, expected: geometry.Point) !void {
    const actual = try runtime.query_json(geometry.Point, "cursorpos");
    if (@abs(@as(i64, actual.x) - expected.x) > 1 or @abs(@as(i64, actual.y) - expected.y) > 1) return error.CursorPositionMismatch;
}

const ScrollDriver = struct {
    runtime: *Runtime,
    pointer: *Pointer,
    point: geometry.Point,
    x11: bool = false,
    wheel: bool = false,
    pub fn now(_: *@This()) i64 {
        return native.now_ms();
    }
    pub fn pause(self: *@This(), ms: u32) !void {
        try self.runtime.pause(ms);
    }
    pub fn emit(self: *@This(), delta: geometry.Point) !void {
        try self.runtime.guard();
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var scratch = self.runtime.scratch(arena.allocator());
        try expect_cursor_at(&scratch, self.point);
        if (!self.x11) return if (self.wheel) self.pointer.scroll(delta.x, delta.y) else self.pointer.scroll_continuous(delta.x, delta.y);
        _ = try x11_keyboard(&scratch, self.runtime.target_window.?);
        try x11_wheel(&scratch, delta.x, delta.y);
    }
};

const MotionDriver = struct {
    runtime: *Runtime,
    pointer: *Pointer,
    aura: ?*Aura = null,
    expected_position: ?geometry.Point = null,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    pub fn now(_: *@This()) i64 {
        return native.now_ms();
    }
    pub fn pause(self: *@This(), ms: u32) !void {
        try self.runtime.pause(ms);
    }
    pub fn move(self: *@This(), p: geometry.Point) !void {
        defer _ = self.arena.reset(.{ .retain_with_limit = 64 * 1024 });
        var scratch = self.runtime.scratch(self.arena.allocator());
        if (self.expected_position) |expected| try expect_cursor_at(&scratch, expected);
        // Each sample preserves the existing stop/signal/session-lock guards.
        try scratch.dispatch("movecursor", try std.fmt.allocPrint(scratch.allocator, "{d} {d}", .{ p.x, p.y }));
        try self.pointer.refresh_position();
        const actual = try scratch.query_json(geometry.Point, "cursorpos");
        if (@abs(@as(i64, actual.x) - p.x) > 1 or @abs(@as(i64, actual.y) - p.y) > 1) return error.CursorPositionMismatch;
        self.expected_position = actual;
        if (self.aura) |aura| try aura.place(actual);
    }
};

const PointerGuard = struct {
    frame: geometry.Frame,
    fn check(runtime: *Runtime, context: *anyopaque) !void {
        const self: *PointerGuard = @ptrCast(@alignCast(context));
        // Runtime.guard supplies scratch storage scoped to this check.
        const current = try observation.snapshot_for_action(runtime, self.frame.monitor_id, true);
        try self.frame.validate(runtime.instance, runtime.display, current.revision, native.now_ms());
    }
};

/// Everything a pointer action needs before it may touch the cursor.
const PointerTarget = struct {
    frame: geometry.Frame,
    point: geometry.Point,
    guard: PointerGuard,
};

fn resolve_pointer_target(runtime: *Runtime, arguments: args.Args, frame_id: []const u8) !PointerTarget {
    const frame = try observation.load_frame(runtime, frame_id);
    const snapshot = try observation.snapshot(runtime, frame.monitor_id);
    try frame.validate(runtime.instance, runtime.display, snapshot.revision, native.now_ms());
    const point = try frame.point(arguments.x.?, arguments.y.?);
    if (arguments.window) |window| {
        try check_window(runtime, window, true);
        var inside = false;
        for (snapshot.clients) |client| {
            if (eq(client.address, window)) inside = client.contains(point);
        }
        if (!inside) return error.PointerOutsideTarget;
        runtime.target_window = window;
    } else runtime.target_window = snapshot.active;
    if (arguments.command == .scroll and eq(arguments.scroll_mode, "continuous")) {
        for (snapshot.clients) |client| {
            if (eq(client.address, runtime.target_window.?) and client.xwayland) return error.ContinuousScrollUnavailable;
        }
    }
    if (arguments.command == .drag) _ = try frame.point(arguments.to_x.?, arguments.to_y.?);
    return .{ .frame = frame, .point = point, .guard = .{ .frame = frame } };
}

fn run_pointer_action(runtime: *Runtime, arguments: args.Args, target: *PointerTarget) !void {
    var pointer: Pointer = undefined;
    try pointer.init(try runtime.display_path());
    defer pointer.deinit();
    try pointer.create();
    pointer.connection.runtime = runtime;
    // Recheck after connecting the input device, before moving the cursor.
    const revision = (try observation.snapshot(runtime, target.frame.monitor_id)).revision;
    try target.frame.validate(runtime.instance, runtime.display, revision, native.now_ms());
    runtime.extra_guard = PointerGuard.check;
    runtime.guard_context = &target.guard;
    defer {
        runtime.extra_guard = null;
        runtime.guard_context = null;
    }
    const start = try runtime.query_json(geometry.Point, "cursorpos");
    var driver = MotionDriver{ .runtime = runtime, .pointer = &pointer, .expected_position = start };
    defer driver.arena.deinit();
    var aura: Aura = undefined;
    const aura_started = native.now_ms();
    if (!arguments.no_aura and !try runtime.outline_enabled()) {
        const monitors = try runtime.query_json([]geometry.Monitor, "monitors");
        try aura.init(&pointer.connection, monitors);
        driver.aura = &aura;
    }
    defer if (driver.aura != null) aura.deinit();
    if (driver.aura) |halo| try halo.place(start);
    const p = target.point;
    try motion.run(&driver, start, p, arguments.move_duration_ms orelse motion.duration(start, p));
    try runtime.guard();
    try runtime.unlocked();
    switch (arguments.command) {
        .click => try pointer.click(arguments.button),
        .doubleclick => {
            try pointer.click(arguments.button);
            try runtime.pause(80);
            try pointer.click(arguments.button);
        },
        .drag => {
            const destination = try target.frame.point(arguments.to_x.?, arguments.to_y.?);
            try pointer.press(arguments.button);
            defer pointer.release();
            try motion.run(&driver, p, destination, arguments.duration_ms);
        },
        .scroll => try scroll(runtime, &pointer, p, arguments.dx, arguments.dy, arguments.duration_ms, arguments.scroll_mode),
        .move => {},
        else => unreachable,
    }
    // Keep stationary move feedback visible; do not revalidate after a
    // completed click that intentionally changed application focus/layout.
    const aura_elapsed = native.now_ms() - aura_started;
    if (arguments.command == .move and driver.aura != null and aura_elapsed < 100)
        try runtime.pause(@intCast(100 - aura_elapsed));
}

fn type_text(runtime: *Runtime, arguments: args.Args) !void {
    const x11 = try x11_keyboard(runtime, arguments.window.?);
    if (!x11 and !eq(arguments.backend, "helper")) {
        var device: Keyboard = undefined;
        try device.init(try runtime.display_path());
        defer device.deinit();
        try device.create();
        return device.type_text(runtime, arguments.text.?);
    }
    if (x11 and eq(arguments.backend, "native")) return error.NativeX11Unavailable;
    const argv: []const []const u8 = if (x11) &.{ "xdotool", "type", "--delay", "12", "--file", "-" } else &.{ "wtype", "-" };
    try runtime.run_helper(argv, arguments.text.?, true);
}

fn press_chord(runtime: *Runtime, arguments: args.Args, wtype_argv: []const []const u8) !void {
    const x11 = try x11_keyboard(runtime, arguments.window.?);
    if (!x11 and !eq(arguments.backend, "helper")) {
        var device: Keyboard = undefined;
        try device.init(try runtime.display_path());
        defer device.deinit();
        try device.create();
        return device.chord(runtime, arguments.value.?);
    }
    if (x11 and eq(arguments.backend, "native")) return error.NativeX11Unavailable;
    const argv: []const []const u8 = if (x11) &.{ "xdotool", "key", "--delay", "0", try x11_chord(runtime.allocator, arguments.value.?) } else wtype_argv;
    try runtime.run_helper(argv, null, true);
}

pub fn run(runtime: *Runtime, arguments: args.Args) !void {
    var guard_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer guard_arena.deinit();
    runtime.guard_arena = &guard_arena;
    defer runtime.guard_arena = null;
    if (arguments.command == .launch and runtime.is_host()) return error.ManagedSessionRequired;
    const lock_fd = try runtime.lock();
    defer _ = c.close(lock_fd);
    try runtime.validate_display();
    try runtime.unlocked();
    if (!arguments.dry_run) runtime.control_token = try runtime.token();
    var target: ?PointerTarget = if (arguments.frame) |id| try resolve_pointer_target(runtime, arguments, id) else null;
    const point: ?geometry.Point = if (target) |t| t.point else null;
    // Validate every argument before the dry-run report and before any input.
    var key_argv: ?[]const []const u8 = null;
    switch (arguments.command) {
        .focus => try check_window(runtime, arguments.value.?, false),
        .workspace => {
            const number = std.fmt.parseInt(u32, arguments.value.?, 10) catch return error.InvalidWorkspace;
            if (number == 0 or number > std.math.maxInt(i32)) return error.InvalidWorkspace;
        },
        .type => {
            runtime.target_window = arguments.window;
            try check_window(runtime, arguments.window.?, true);
            const text = arguments.text.?;
            if (text.len > 64 * 1024 or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidText;
        },
        .key => {
            runtime.target_window = arguments.window;
            try check_window(runtime, arguments.window.?, true);
            key_argv = try key_args(runtime.allocator, arguments.value.?);
        },
        else => {},
    }
    if (arguments.dry_run) {
        try runtime.emit(.{ .ok = true, .dry_run = true, .action = @tagName(arguments.command), .session_id = runtime.session_id, .desktop_point = point, .window = arguments.window, .target = arguments.value });
        return;
    }
    if (target) |*t| {
        try run_pointer_action(runtime, arguments, t);
    } else switch (arguments.command) {
        .focus => {
            try runtime.dispatch("focuswindow", try std.fmt.allocPrint(runtime.allocator, "address:{s}", .{arguments.value.?}));
            try check_window(runtime, arguments.value.?, true);
        },
        .workspace => {
            try runtime.dispatch("workspace", arguments.value.?);
            const active = try runtime.query_json(geometry.Workspace, "activeworkspace");
            if (active.id != try std.fmt.parseInt(i64, arguments.value.?, 10)) return error.WorkspaceVerificationFailed;
        },
        .type => try type_text(runtime, arguments),
        .key => try press_chord(runtime, arguments, key_argv.?),
        .launch => return sessions.launch(runtime, arguments),
        else => unreachable,
    }
    try runtime.emit(.{
        .ok = true,
        .action = @tagName(arguments.command),
        .session_id = runtime.session_id,
        .status = "sent",
        .desktop_point = point,
        .scroll_mode_requested = if (arguments.command == .scroll) arguments.scroll_mode else null,
    });
}

test "key chords emit explicit modifier releases and reject malformed input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try key_args(arena.allocator(), "ctrl+shift+Return");
    try std.testing.expectEqualStrings("-m", argv[7]);
    try std.testing.expectEqualStrings("shift", argv[8]);
    try std.testing.expectEqualStrings("ctrl+super+Return", try x11_chord(arena.allocator(), "ctrl+logo+Return"));
    try std.testing.expectEqualStrings("ISO_Level3_Shift+e", try x11_chord(arena.allocator(), "altgr+e"));
    try std.testing.expectError(error.InvalidKeyChord, key_args(arena.allocator(), "ctrl++"));
    try std.testing.expectError(error.InvalidKeyChord, key_args(arena.allocator(), "ctrl+ctrl+a"));
    try std.testing.expectError(error.InvalidWindowAddress, validate_address("0x123,exec,evil"));
}
