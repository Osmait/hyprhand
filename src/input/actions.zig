const std = @import("std");
const assert = std.debug.assert;
const args = @import("../cli/args.zig");
const geometry = @import("../core/geometry.zig");
const eq = @import("../core/text.zig").eq;
const native = @import("../platform/native.zig");
const c = native.c;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const ActionGuard = @import("../runtime/runtime.zig").ActionGuard;
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
const delivery = @import("../runtime/delivery.zig");
const semantic = @import("../accessibility/semantic.zig");

fn validate_address(address: []const u8) !void {
    if (address.len < 3) return error.InvalidWindowAddress;
    if (address.len > 18) return error.InvalidWindowAddress;
    if (!std.mem.startsWith(u8, address, "0x")) return error.InvalidWindowAddress;
    for (address[2..]) |character| {
        if (!std.ascii.isHex(character)) return error.InvalidWindowAddress;
    }
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

    if (require_focus) {
        const active = try runtime.active_window();
        if (!eq(active, address)) return error.WindowNotFocused;
    }
}

/// wtype argv: press modifiers in order, tap the key, release in reverse.
fn key_args(allocator: std.mem.Allocator, chord: []const u8) ![]const []const u8 {
    const parsed = try Chord.parse(allocator, chord);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, "wtype");
    for (parsed.modifier_slice()) |index| {
        try argv.appendSlice(allocator, &.{ "-M", keyboard.modifiers[index].alias });
    }
    try argv.appendSlice(allocator, &.{ "-k", parsed.key_name });
    var i = parsed.count;
    while (i > 0) {
        i -= 1;
        try argv.appendSlice(allocator, &.{ "-m", keyboard.modifiers[parsed.mods[i]].alias });
    }
    return argv.toOwnedSlice(allocator);
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
        const timeout_ms = try native.remaining_ms(3000);
        const result = try std.process.run(runtime.allocator, runtime.io, .{
            .argv = &.{ "xdotool", "getwindowfocus", "getwindowpid" },
            .environ_map = runtime.env,
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(4096),
            .timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } },
        });
        switch (result.term) {
            .exited => |code| if (code != 0) {
                return error.X11TargetMismatch;
            },
            else => return error.X11TargetMismatch,
        }

        const focused_pid_text = std.mem.trim(u8, result.stdout, " \r\n");
        const focused_pid = std.fmt.parseInt(i64, focused_pid_text, 10) catch
            return error.X11TargetMismatch;
        if (client.pid <= 0) return error.X11TargetMismatch;
        if (focused_pid != client.pid) return error.X11TargetMismatch;
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
        delivery.mark_sent();
        const repeat_text = try std.fmt.allocPrint(runtime.allocator, "{d}", .{@abs(step.amount)});
        const button_text = try std.fmt.allocPrint(runtime.allocator, "{d}", .{button});
        try runtime.run_helper(
            &.{ "xdotool", "click", "--repeat", repeat_text, "--delay", "0", button_text },
            null,
            true,
        );
    }
}

fn scroll(
    runtime: *Runtime,
    pointer: *Pointer,
    point: geometry.Point,
    dx: i32,
    dy: i32,
    duration_ms: u32,
    mode: args.ScrollMode,
) !void {
    const active = try runtime.active_window();
    // Scrolling goes to whatever is focused under the cursor right now.
    runtime.action.?.target_window = active;
    const wheel = mode == .wheel or (mode == .auto and duration_ms == 0);

    const clients = try runtime.query_json([]Client, "clients");
    for (clients) |client| {
        if (!eq(client.address, active)) continue;
        if (!client.xwayland) continue;
        if (mode == .continuous) return error.ContinuousScrollUnavailable;
        // XWayland does not consistently translate virtual Wayland axis events.
        // XTEST wheel buttons are used only inside the verified focused client.
        if (!client.contains(point)) return error.WindowNotFocused;
        _ = try x11_keyboard(runtime, client.address);
        if (duration_ms == 0) return x11_wheel(runtime, dx, dy);
        var driver = ScrollDriver{
            .runtime = runtime,
            .pointer = pointer,
            .point = point,
            .x11 = true,
        };
        return scroll_pacing.run(&driver, .{ .x = dx, .y = dy }, duration_ms);
    }

    if (wheel and duration_ms == 0) return pointer.scroll(dx, dy);
    var driver = ScrollDriver{
        .runtime = runtime,
        .pointer = pointer,
        .point = point,
        .wheel = wheel,
    };
    // Wheel detents are independent steps, not a continuous gesture. Sending
    // axis_stop for them can flush a spurious surface-distance event in GTK.
    defer if (!wheel) pointer.end_scroll(dx, dy);
    const unit: i32 = if (wheel) 1 else pointer_device.wheel_detent_units;
    try scroll_pacing.run(&driver, .{ .x = dx * unit, .y = dy * unit }, duration_ms);
}

fn expect_cursor_at(runtime: *Runtime, expected: geometry.Point) !void {
    const actual = try runtime.query_json(geometry.Point, "cursorpos");
    if (@abs(@as(i64, actual.x) - expected.x) > 1) return error.CursorPositionMismatch;
    if (@abs(@as(i64, actual.y) - expected.y) > 1) return error.CursorPositionMismatch;
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

    pub fn pause(self: *@This(), duration_ms: u32) !void {
        try self.runtime.pause(duration_ms);
    }

    pub fn emit(self: *@This(), delta: geometry.Point) !void {
        try self.runtime.guard();
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var scratch = self.runtime.scratch(arena.allocator());
        try expect_cursor_at(&scratch, self.point);

        if (!self.x11) {
            if (self.wheel) return self.pointer.scroll(delta.x, delta.y);
            return self.pointer.scroll_continuous(delta.x, delta.y);
        }
        _ = try x11_keyboard(&scratch, self.runtime.action.?.target_window.?);
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

    pub fn pause(self: *@This(), duration_ms: u32) !void {
        try self.runtime.pause(duration_ms);
    }

    pub fn move(self: *@This(), point: geometry.Point) !void {
        defer _ = self.arena.reset(.{ .retain_with_limit = 64 * 1024 });
        var scratch = self.runtime.scratch(self.arena.allocator());
        if (self.expected_position) |expected| try expect_cursor_at(&scratch, expected);

        // Each sample preserves the existing stop/signal/session-lock guards.
        try scratch.dispatch(.{ .move_cursor = .{ .x = point.x, .y = point.y } });
        try self.pointer.refresh_position();

        const actual = try scratch.query_json(geometry.Point, "cursorpos");
        if (@abs(@as(i64, actual.x) - point.x) > 1) return error.CursorPositionMismatch;
        if (@abs(@as(i64, actual.y) - point.y) > 1) return error.CursorPositionMismatch;
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
        try self.frame.validate(
            runtime.instance,
            runtime.display,
            current.revision,
            native.now_ms(),
        );
    }
};

/// Everything a pointer action needs before it may touch the cursor.
const PointerTarget = struct {
    frame: geometry.Frame,
    point: geometry.Point,
    /// `--window` when given, otherwise the window focused when resolved.
    window: []const u8,
    guard: PointerGuard,
    /// `--mods`: modifier keys held while the button or wheel acts.
    modifiers: ?keyboard.ModifierSet = null,
};

/// Parses `--mods` and refuses targets the virtual keyboard cannot reach:
/// XWayland clients take keyboard input through XTEST, not this device.
fn resolve_modifiers(
    arguments: args.Args,
    clients: []const Client,
    window: []const u8,
    point: geometry.Point,
) !?keyboard.ModifierSet {
    const value = arguments.mods orelse return null;
    const set = try keyboard.ModifierSet.parse(value);
    for (clients) |client| {
        if (!client.xwayland) continue;
        const targeted = eq(client.address, window) or client.contains(point);
        if (targeted) return error.ModifiersUnavailableForX11;
    }
    return set;
}

/// Modifier keys held down for the duration of one pointer action.
const HeldModifiers = struct {
    device: Keyboard = undefined,
    active: bool = false,

    fn press(self: *HeldModifiers, runtime: *Runtime, set: keyboard.ModifierSet) !void {
        assert(!self.active);
        try self.device.init(try runtime.display_path());
        self.active = true;
        try self.device.create();
        try self.device.hold_modifiers(runtime, set);
    }

    /// Releases every held modifier; safe to call when nothing was pressed.
    fn release(self: *HeldModifiers) void {
        if (!self.active) return;
        self.device.deinit();
        self.active = false;
    }
};

fn resolve_pointer_target(
    runtime: *Runtime,
    arguments: args.Args,
    frame_id: []const u8,
) !PointerTarget {
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
    }
    const target_window = arguments.window orelse snapshot.active;

    const continuous_scroll = arguments.command == .scroll and
        arguments.scroll_mode == .continuous;
    if (continuous_scroll) {
        for (snapshot.clients) |client| {
            if (!eq(client.address, target_window)) continue;
            if (client.xwayland) return error.ContinuousScrollUnavailable;
        }
    }
    if (arguments.command == .drag) _ = try frame.point(arguments.to_x.?, arguments.to_y.?);

    return .{
        .frame = frame,
        .point = point,
        .window = target_window,
        .guard = .{ .frame = frame },
        .modifiers = try resolve_modifiers(arguments, snapshot.clients, target_window, point),
    };
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

    const action = runtime.action.?;
    assert(action.frame_check == null);
    action.frame_check = .{ .context = &target.guard, .check = PointerGuard.check };
    defer action.frame_check = null;

    const start = try runtime.query_json(geometry.Point, "cursorpos");
    var driver = MotionDriver{
        .runtime = runtime,
        .pointer = &pointer,
        .expected_position = start,
    };
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

    const approach_ms = arguments.move_duration_ms orelse motion.duration(start, target.point);
    try motion.run(&driver, start, target.point, approach_ms);
    try runtime.guard();
    try runtime.unlocked();
    var held = HeldModifiers{};
    defer held.release();
    if (target.modifiers) |set| try held.press(runtime, set);
    switch (arguments.command) {
        .click => try click_repeated(runtime, &pointer, arguments.button, arguments.click_count),
        .doubleclick => try click_repeated(runtime, &pointer, arguments.button, 2),
        .drag => {
            const destination = try target.frame.point(arguments.to_x.?, arguments.to_y.?);
            try pointer.press(arguments.button);
            defer pointer.release();
            try motion.run(&driver, target.point, destination, arguments.duration_ms);
        },
        .scroll => try scroll(
            runtime,
            &pointer,
            target.point,
            arguments.dx,
            arguments.dy,
            arguments.duration_ms,
            arguments.scroll_mode,
        ),
        .move => {},
        else => unreachable,
    }

    // Keep stationary move feedback visible; do not revalidate after a
    // completed click that intentionally changed application focus/layout.
    const aura_elapsed = native.now_ms() - aura_started;
    const hold_feedback = arguments.command == .move and driver.aura != null and aura_elapsed < 100;
    if (hold_feedback) try runtime.pause(@intCast(100 - aura_elapsed));
}

/// Clicks `count` times, close enough together for a double or triple click.
fn click_repeated(runtime: *Runtime, pointer: *Pointer, button: u32, count: u32) !void {
    assert(count >= 1);
    assert(count <= args.click_count_max);
    for (0..count) |index| {
        if (index > 0) try runtime.pause(click_gap_ms);
        try pointer.click(button);
    }
}

/// Well inside every toolkit's double-click interval (GTK and Qt: 400 ms).
const click_gap_ms = 80;
/// Between repeated key taps: fast, yet each tap is a separate key event.
const key_repeat_gap_ms = 25;

/// How keyboard input reaches the target window.
const KeyboardRoute = enum {
    /// Our own zwp_virtual_keyboard_v1 device.
    native,
    /// The wtype helper, for Wayland clients when `--backend helper` is asked for.
    wtype,
    /// XTEST through xdotool. XWayland clients need it: the virtual keyboard
    /// protocol does not reach them reliably.
    xdotool,
};

fn keyboard_route(runtime: *Runtime, arguments: args.Args) !KeyboardRoute {
    const x11 = try x11_keyboard(runtime, arguments.window.?);
    if (x11) {
        if (arguments.backend == .native) return error.NativeX11Unavailable;
        return .xdotool;
    }
    if (arguments.backend == .helper) return .wtype;
    // `--backend clipboard` pastes with a native ctrl+v chord.
    return .native;
}

fn type_text(runtime: *Runtime, arguments: args.Args) !void {
    if (arguments.backend == .clipboard) return paste_text(runtime, arguments);

    const text = arguments.text.?;
    switch (try keyboard_route(runtime, arguments)) {
        .native => {
            var device: Keyboard = undefined;
            try device.init(try runtime.display_path());
            defer device.deinit();
            try device.create();
            try device.type_text(runtime, text);
        },
        .wtype => try runtime.run_helper(&.{ "wtype", "-" }, text, true),
        .xdotool => {
            const argv = &.{ "xdotool", "type", "--delay", "12", "--file", "-" };
            try runtime.run_helper(argv, text, true);
        },
    }
}

/// wl-copy reads the text from stdin, never argv, which every local process can
/// read. The text stays on the session clipboard after a successful paste:
/// `--paste-once` is consumed by Chromium before it inserts anything (Brave
/// pasted nothing), and `wl-copy --clear` right after ctrl+v races the target,
/// which fetches the data asynchronously (Brave pasted 2 of 10 times).
const clipboard_copy_argv = [_][]const u8{ "wl-copy", "--type", "text/plain;charset=utf-8" };
const clipboard_clear_argv = [_][]const u8{ "wl-copy", "--clear" };

/// `--backend clipboard`: copy the text into the managed session's Wayland
/// clipboard, then paste it with ctrl+v through the normal guarded chord path.
fn paste_text(runtime: *Runtime, arguments: args.Args) !void {
    // Argument validation rejects host: this is never the human's clipboard.
    assert(!runtime.is_host());
    var helper = try paste_text_runtime(runtime);
    try helper.run_helper_stderr(&clipboard_copy_argv, arguments.text.?, true, .ignore);
    // A failed chord almost always stopped before ctrl+v reached the target;
    // do not leave the text waiting on the clipboard.
    errdefer helper.run_helper_stderr(&clipboard_clear_argv, null, false, .ignore) catch {};

    const chord = "ctrl+v";
    try press_chord(runtime, arguments, chord, try key_args(runtime.allocator, chord), 1);
}

/// A runtime for wl-copy that can only reach the session display: an inherited
/// WAYLAND_SOCKET would take precedence over the session's WAYLAND_DISPLAY.
fn paste_text_runtime(runtime: *Runtime) !Runtime {
    const environment = try runtime.allocator.create(std.process.Environ.Map);
    environment.* = try runtime.env.clone(runtime.allocator);
    _ = environment.swapRemove("WAYLAND_SOCKET");

    var helper = runtime.*;
    helper.env = environment;
    return helper;
}

/// Taps the chord `repeat` times on the target window's keyboard route.
fn press_chord(
    runtime: *Runtime,
    arguments: args.Args,
    chord: []const u8,
    wtype_argv: []const []const u8,
    repeat: u32,
) !void {
    assert(repeat >= 1);
    switch (try keyboard_route(runtime, arguments)) {
        .native => {
            var device: Keyboard = undefined;
            try device.init(try runtime.display_path());
            defer device.deinit();
            try device.create();
            try device.chord(runtime, chord, repeat, key_repeat_gap_ms);
        },
        .wtype => for (0..repeat) |tap| {
            if (tap > 0) try runtime.pause(key_repeat_gap_ms);
            try runtime.run_helper(wtype_argv, null, true);
        },
        .xdotool => {
            const x11_spelling = try x11_chord(runtime.allocator, chord);
            const repeat_text = try std.fmt.allocPrint(runtime.allocator, "{d}", .{repeat});
            const delay_text = try std.fmt.allocPrint(
                runtime.allocator,
                "{d}",
                .{key_repeat_gap_ms},
            );
            const argv = &.{
                "xdotool", "key",      "--repeat",   repeat_text,
                "--delay", delay_text, x11_spelling,
            };
            try runtime.run_helper(argv, null, true);
        },
    }
}

pub fn run(runtime: *Runtime, arguments: args.Args) !void {
    if (arguments.command == .launch and runtime.is_host()) return error.ManagedSessionRequired;

    const lock_fd = try runtime.lock();
    defer _ = c.close(lock_fd);
    try runtime.validate_display();
    try runtime.unlocked();

    // A dry run sends no input, so it has no guard: any guard call fails.
    var action: ?ActionGuard = null;
    if (!arguments.dry_run) action = .{ .control_token = try runtime.token() };
    defer if (action) |*guard| guard.deinit();
    runtime.action = if (action) |*guard| guard else null;
    defer runtime.action = null;
    // Semantic actions resolve their own target and report their own dry run.
    if (arguments.command == .act) return semantic.run(runtime, arguments);

    var target: ?PointerTarget = if (arguments.frame) |frame_id|
        try resolve_pointer_target(runtime, arguments, frame_id)
    else
        null;
    const point: ?geometry.Point = if (target) |pointer_target| pointer_target.point else null;
    const pointer_window = if (target) |pointer_target| pointer_target.window else null;
    const validated = try run_validate(runtime, arguments, pointer_window);

    if (arguments.dry_run) {
        try runtime.emit(.{
            .ok = true,
            .dry_run = true,
            .action = @tagName(arguments.command),
            .session_id = runtime.session_id,
            .desktop_point = point,
            .window = arguments.window,
            .target = arguments.target(),
            .modifiers = arguments.mods,
        });
        return;
    }

    // Pointer devices mark delivery at the first button or wheel event, so an
    // approach that aborts reports nothing delivered. Other commands act at once.
    if (target) |*pointer_target| {
        try run_pointer_action(runtime, arguments, pointer_target);
    } else {
        delivery.mark_sent();
        // launch reports the started process itself.
        if (arguments.command == .launch) return sessions.launch(runtime, arguments);
        try run_other_action(runtime, arguments, validated);
    }
    delivery.set(.delivered_unverified);

    try runtime.emit(.{
        .ok = true,
        .action = @tagName(arguments.command),
        .session_id = runtime.session_id,
        .status = "sent",
        .disposition = delivery.disposition(),
        .desktop_point = point,
        .scroll_mode_requested = if (arguments.command == .scroll) arguments.scroll_mode else null,
        .modifiers = arguments.mods,
        .click_count = if (arguments.command == .click) arguments.click_count else null,
        .repeat = if (arguments.command == .key) arguments.key_repeat else null,
    });
}

fn run_other_action(runtime: *Runtime, arguments: args.Args, validated: Validated) !void {
    switch (arguments.command) {
        .focus => try run_focus(runtime, arguments.focus_window.?),
        .workspace => try run_workspace(runtime, validated.workspace_number.?),
        .type => try type_text(runtime, arguments),
        .key => {
            const chord = arguments.key_chord.?;
            try press_chord(runtime, arguments, chord, validated.key_argv.?, arguments.key_repeat);
        },
        else => unreachable,
    }
}

/// What validation computed that execution needs again.
const Validated = struct {
    /// The wtype argv for `key`, checked before anything is sent.
    key_argv: ?[]const []const u8 = null,
    workspace_number: ?u32 = null,
};

/// Validates every argument before the dry-run report and before any input,
/// and tells the guard which window input must stay on.
fn run_validate(
    runtime: *Runtime,
    arguments: args.Args,
    pointer_window: ?[]const u8,
) !Validated {
    if (pointer_window) |window| run_guard_target(runtime, window);
    switch (arguments.command) {
        .focus => try check_window(runtime, arguments.focus_window.?, false),
        .workspace => return .{
            .workspace_number = try run_validate_workspace(arguments.workspace_target.?),
        },
        .type => {
            run_guard_target(runtime, arguments.window.?);
            try check_window(runtime, arguments.window.?, true);
            try run_validate_text(arguments.text.?);
            const clipboard = arguments.backend == .clipboard;
            if (clipboard and !try runtime.executable("wl-copy")) {
                return error.ClipboardHelperMissing;
            }
        },
        .key => {
            run_guard_target(runtime, arguments.window.?);
            try check_window(runtime, arguments.window.?, true);
            return .{ .key_argv = try key_args(runtime.allocator, arguments.key_chord.?) };
        },
        else => {},
    }
    return .{};
}

fn run_guard_target(runtime: *Runtime, window: []const u8) void {
    // A dry run has no guard to update.
    if (runtime.action) |guard| guard.target_window = window;
}

fn run_validate_workspace(value: []const u8) !u32 {
    const workspace_number = std.fmt.parseInt(u32, value, 10) catch return error.InvalidWorkspace;
    if (workspace_number == 0) return error.InvalidWorkspace;
    if (workspace_number > std.math.maxInt(i32)) return error.InvalidWorkspace;
    return workspace_number;
}

fn run_validate_text(text: []const u8) !void {
    if (text.len > 64 * 1024) return error.InvalidText;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidText;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidText;
}

fn run_focus(runtime: *Runtime, address: []const u8) !void {
    try runtime.dispatch(.{ .focus_window = address });
    try check_window(runtime, address, true);
}

fn run_workspace(runtime: *Runtime, number: u32) !void {
    try runtime.dispatch(.{ .workspace = number });
    const active = try runtime.query_json(geometry.Workspace, "activeworkspace");
    if (active.id != number) return error.WorkspaceVerificationFailed;
}

test "key chords emit explicit modifier releases and reject malformed input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try key_args(arena.allocator(), "ctrl+shift+Return");
    try std.testing.expectEqualStrings("-m", argv[7]);
    try std.testing.expectEqualStrings("shift", argv[8]);
    try std.testing.expectEqualStrings(
        "ctrl+super+Return",
        try x11_chord(arena.allocator(), "ctrl+logo+Return"),
    );
    try std.testing.expectEqualStrings(
        "ISO_Level3_Shift+e",
        try x11_chord(arena.allocator(), "altgr+e"),
    );
    try std.testing.expectError(error.InvalidKeyChord, key_args(arena.allocator(), "ctrl++"));
    try std.testing.expectError(error.InvalidKeyChord, key_args(arena.allocator(), "ctrl+ctrl+a"));
    try std.testing.expectError(error.InvalidWindowAddress, validate_address("0x123,exec,evil"));
}
