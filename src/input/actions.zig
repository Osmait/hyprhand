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

fn validateAddress(address: []const u8) !void {
    if (!std.mem.startsWith(u8, address, "0x") or address.len < 3 or address.len > 18) return error.InvalidWindowAddress;
    for (address[2..]) |ch| if (!std.ascii.isHex(ch)) return error.InvalidWindowAddress;
}

fn checkWindow(rt: *Runtime, address: []const u8, require_focus: bool) !void {
    try validateAddress(address);
    const clients = try rt.queryJson([]Client, "clients");
    var found = false;
    for (clients) |client| {
        if (eq(client.address, address) and client.mapped and !client.hidden) {
            found = true;
            break;
        }
    }
    if (!found) return error.WindowNotFound;
    if (require_focus and !eq(try rt.activeWindow(), address)) return error.WindowNotFocused;
}

/// wtype argv: press modifiers in order, tap the key, release in reverse.
fn keyArgs(a: std.mem.Allocator, chord: []const u8) ![]const []const u8 {
    const parsed = try Chord.parse(a, chord);
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(a, "wtype");
    for (parsed.modifierSlice()) |index| try out.appendSlice(a, &.{ "-M", keyboard.modifiers[index].alias });
    try out.appendSlice(a, &.{ "-k", parsed.key_name });
    var i = parsed.count;
    while (i > 0) {
        i -= 1;
        try out.appendSlice(a, &.{ "-m", keyboard.modifiers[parsed.mods[i]].alias });
    }
    return out.toOwnedSlice(a);
}

/// xdotool spelling of the same chord, e.g. "ctrl+super+Return".
fn x11Chord(a: std.mem.Allocator, chord: []const u8) ![]const u8 {
    const parsed = try Chord.parse(a, chord);
    var result: std.ArrayList(u8) = .empty;
    for (parsed.modifierSlice()) |index| {
        try result.appendSlice(a, keyboard.modifiers[index].x11);
        try result.append(a, '+');
    }
    try result.appendSlice(a, parsed.key_name);
    return result.toOwnedSlice(a);
}

fn x11Keyboard(rt: *Runtime, address: []const u8) !bool {
    const clients = try rt.queryJson([]Client, "clients");
    for (clients) |client| {
        if (!eq(client.address, address)) continue;
        if (!client.xwayland) return false;
        if (!try rt.executable("xdotool")) return error.XWaylandHelperMissing;
        // DISPLAY can point at another X server. Check its focused PID first.
        const result = try std.process.run(rt.allocator, rt.io, .{
            .argv = &.{ "xdotool", "getwindowfocus", "getwindowpid" },
            .environ_map = rt.env,
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(4096),
            .timeout = .{ .duration = .{ .raw = .fromMilliseconds(try native.remainingMs(3000)), .clock = .awake } },
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
fn x11Wheel(rt: *Runtime, dx: i32, dy: i32) !void {
    const steps = [_]struct { amount: i32, positive: u8, negative: u8 }{
        .{ .amount = dy, .positive = buttons.x11.wheel_down, .negative = buttons.x11.wheel_up },
        .{ .amount = dx, .positive = buttons.x11.wheel_right, .negative = buttons.x11.wheel_left },
    };
    for (steps) |step| {
        if (step.amount == 0) continue;
        const button = if (step.amount > 0) step.positive else step.negative;
        const repeat = try std.fmt.allocPrint(rt.allocator, "{d}", .{@abs(step.amount)});
        const button_text = try std.fmt.allocPrint(rt.allocator, "{d}", .{button});
        try rt.runHelper(&.{ "xdotool", "click", "--repeat", repeat, "--delay", "0", button_text }, null, true);
    }
}

fn scroll(rt: *Runtime, pointer: *Pointer, point: geometry.Point, dx: i32, dy: i32, ms: u32, mode: []const u8) !void {
    const active = try rt.activeWindow();
    rt.target_window = active;
    const wheel = eq(mode, "wheel") or (eq(mode, "auto") and ms == 0);
    const clients = try rt.queryJson([]Client, "clients");
    for (clients) |client| {
        if (!eq(client.address, active) or !client.xwayland) continue;
        if (eq(mode, "continuous")) return error.ContinuousScrollUnavailable;
        // XWayland does not consistently translate virtual Wayland axis events.
        // XTEST wheel buttons are used only inside the verified focused client.
        if (!client.contains(point)) return error.WindowNotFocused;
        _ = try x11Keyboard(rt, client.address);
        if (ms == 0) return x11Wheel(rt, dx, dy);
        var driver = ScrollDriver{ .rt = rt, .pointer = pointer, .point = point, .x11 = true };
        return scroll_pacing.run(&driver, .{ .x = dx, .y = dy }, ms);
    }
    if (wheel and ms == 0) return pointer.scroll(dx, dy);
    var driver = ScrollDriver{ .rt = rt, .pointer = pointer, .point = point, .wheel = wheel };
    // Wheel detents are independent steps, not a continuous gesture. Sending
    // axis_stop for them can flush a spurious surface-distance event in GTK.
    defer if (!wheel) pointer.endScroll(dx, dy);
    const unit: i32 = if (wheel) 1 else pointer_device.wheel_detent_units;
    try scroll_pacing.run(&driver, .{ .x = dx * unit, .y = dy * unit }, ms);
}

fn expectCursorAt(rt: *Runtime, expected: geometry.Point) !void {
    const actual = try rt.queryJson(geometry.Point, "cursorpos");
    if (@abs(@as(i64, actual.x) - expected.x) > 1 or @abs(@as(i64, actual.y) - expected.y) > 1) return error.CursorPositionMismatch;
}

const ScrollDriver = struct {
    rt: *Runtime,
    pointer: *Pointer,
    point: geometry.Point,
    x11: bool = false,
    wheel: bool = false,
    pub fn now(_: *@This()) i64 {
        return native.nowMs();
    }
    pub fn pause(self: *@This(), ms: u32) !void {
        try self.rt.pause(ms);
    }
    pub fn emit(self: *@This(), delta: geometry.Point) !void {
        try self.rt.guard();
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var scratch = self.rt.scratch(arena.allocator());
        try expectCursorAt(&scratch, self.point);
        if (!self.x11) return if (self.wheel) self.pointer.scroll(delta.x, delta.y) else self.pointer.scrollContinuous(delta.x, delta.y);
        _ = try x11Keyboard(&scratch, self.rt.target_window.?);
        try x11Wheel(&scratch, delta.x, delta.y);
    }
};

const MotionDriver = struct {
    rt: *Runtime,
    pointer: *Pointer,
    aura: ?*Aura = null,
    expected_position: ?geometry.Point = null,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    pub fn now(_: *@This()) i64 {
        return native.nowMs();
    }
    pub fn pause(self: *@This(), ms: u32) !void {
        try self.rt.pause(ms);
    }
    pub fn move(self: *@This(), p: geometry.Point) !void {
        defer _ = self.arena.reset(.{ .retain_with_limit = 64 * 1024 });
        var scratch = self.rt.scratch(self.arena.allocator());
        if (self.expected_position) |expected| try expectCursorAt(&scratch, expected);
        // Each sample preserves the existing stop/signal/session-lock guards.
        try scratch.dispatch("movecursor", try std.fmt.allocPrint(scratch.allocator, "{d} {d}", .{ p.x, p.y }));
        try self.pointer.refreshPosition();
        const actual = try scratch.queryJson(geometry.Point, "cursorpos");
        if (@abs(@as(i64, actual.x) - p.x) > 1 or @abs(@as(i64, actual.y) - p.y) > 1) return error.CursorPositionMismatch;
        self.expected_position = actual;
        if (self.aura) |aura| try aura.place(actual);
    }
};

const PointerGuard = struct {
    frame: geometry.Frame,
    fn check(rt: *Runtime, context: *anyopaque) !void {
        const self: *PointerGuard = @ptrCast(@alignCast(context));
        // Runtime.guard supplies scratch storage scoped to this check.
        const current = try observation.snapshotForAction(rt, self.frame.monitor_id, true);
        try self.frame.validate(rt.instance, rt.display, current.revision, native.nowMs());
    }
};

/// Everything a pointer action needs before it may touch the cursor.
const PointerTarget = struct {
    frame: geometry.Frame,
    point: geometry.Point,
    guard: PointerGuard,
};

fn resolvePointerTarget(rt: *Runtime, opt: args.Args, frame_id: []const u8) !PointerTarget {
    const frame = try observation.loadFrame(rt, frame_id);
    const snapshot = try observation.snapshot(rt, frame.monitor_id);
    try frame.validate(rt.instance, rt.display, snapshot.revision, native.nowMs());
    const point = try frame.point(opt.x.?, opt.y.?);
    if (opt.window) |window| {
        try checkWindow(rt, window, true);
        var inside = false;
        for (snapshot.clients) |client| {
            if (eq(client.address, window)) inside = client.contains(point);
        }
        if (!inside) return error.PointerOutsideTarget;
        rt.target_window = window;
    } else rt.target_window = snapshot.active;
    if (opt.command == .scroll and eq(opt.scroll_mode, "continuous")) {
        for (snapshot.clients) |client| {
            if (eq(client.address, rt.target_window.?) and client.xwayland) return error.ContinuousScrollUnavailable;
        }
    }
    if (opt.command == .drag) _ = try frame.point(opt.to_x.?, opt.to_y.?);
    return .{ .frame = frame, .point = point, .guard = .{ .frame = frame } };
}

fn runPointerAction(rt: *Runtime, opt: args.Args, target: *PointerTarget) !void {
    var pointer: Pointer = undefined;
    try pointer.init(try rt.displayPath());
    defer pointer.deinit();
    try pointer.create();
    pointer.connection.runtime = rt;
    // Recheck after connecting the input device, before moving the cursor.
    const revision = (try observation.snapshot(rt, target.frame.monitor_id)).revision;
    try target.frame.validate(rt.instance, rt.display, revision, native.nowMs());
    rt.extra_guard = PointerGuard.check;
    rt.guard_context = &target.guard;
    defer {
        rt.extra_guard = null;
        rt.guard_context = null;
    }
    const start = try rt.queryJson(geometry.Point, "cursorpos");
    var driver = MotionDriver{ .rt = rt, .pointer = &pointer, .expected_position = start };
    defer driver.arena.deinit();
    var aura: Aura = undefined;
    const aura_started = native.nowMs();
    if (!opt.no_aura and !try rt.outlineEnabled()) {
        const monitors = try rt.queryJson([]geometry.Monitor, "monitors");
        try aura.init(&pointer.connection, monitors);
        driver.aura = &aura;
    }
    defer if (driver.aura != null) aura.deinit();
    if (driver.aura) |halo| try halo.place(start);
    const p = target.point;
    try motion.run(&driver, start, p, opt.move_duration_ms orelse motion.duration(start, p));
    try rt.guard();
    try rt.unlocked();
    switch (opt.command) {
        .click => try pointer.click(opt.button),
        .doubleclick => {
            try pointer.click(opt.button);
            try rt.pause(80);
            try pointer.click(opt.button);
        },
        .drag => {
            const destination = try target.frame.point(opt.to_x.?, opt.to_y.?);
            try pointer.press(opt.button);
            defer pointer.release();
            try motion.run(&driver, p, destination, opt.duration_ms);
        },
        .scroll => try scroll(rt, &pointer, p, opt.dx, opt.dy, opt.duration_ms, opt.scroll_mode),
        .move => {},
        else => unreachable,
    }
    // Keep stationary move feedback visible; do not revalidate after a
    // completed click that intentionally changed application focus/layout.
    const aura_elapsed = native.nowMs() - aura_started;
    if (opt.command == .move and driver.aura != null and aura_elapsed < 100)
        try rt.pause(@intCast(100 - aura_elapsed));
}

fn typeText(rt: *Runtime, opt: args.Args) !void {
    const x11 = try x11Keyboard(rt, opt.window.?);
    if (!x11 and !eq(opt.backend, "helper")) {
        var device: Keyboard = undefined;
        try device.init(try rt.displayPath());
        defer device.deinit();
        try device.create();
        return device.typeText(rt, opt.text.?);
    }
    if (x11 and eq(opt.backend, "native")) return error.NativeX11Unavailable;
    const argv: []const []const u8 = if (x11) &.{ "xdotool", "type", "--delay", "12", "--file", "-" } else &.{ "wtype", "-" };
    try rt.runHelper(argv, opt.text.?, true);
}

fn pressChord(rt: *Runtime, opt: args.Args, wtype_argv: []const []const u8) !void {
    const x11 = try x11Keyboard(rt, opt.window.?);
    if (!x11 and !eq(opt.backend, "helper")) {
        var device: Keyboard = undefined;
        try device.init(try rt.displayPath());
        defer device.deinit();
        try device.create();
        return device.chord(rt, opt.value.?);
    }
    if (x11 and eq(opt.backend, "native")) return error.NativeX11Unavailable;
    const argv: []const []const u8 = if (x11) &.{ "xdotool", "key", "--delay", "0", try x11Chord(rt.allocator, opt.value.?) } else wtype_argv;
    try rt.runHelper(argv, null, true);
}

pub fn run(rt: *Runtime, opt: args.Args) !void {
    var guard_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer guard_arena.deinit();
    rt.guard_arena = &guard_arena;
    defer rt.guard_arena = null;
    if (opt.command == .launch and rt.isHost()) return error.ManagedSessionRequired;
    const lock_fd = try rt.lock();
    defer _ = c.close(lock_fd);
    try rt.validateDisplay();
    try rt.unlocked();
    if (!opt.dry_run) rt.control_token = try rt.token();
    var target: ?PointerTarget = if (opt.frame) |id| try resolvePointerTarget(rt, opt, id) else null;
    const point: ?geometry.Point = if (target) |t| t.point else null;
    // Validate every argument before the dry-run report and before any input.
    var key_argv: ?[]const []const u8 = null;
    switch (opt.command) {
        .focus => try checkWindow(rt, opt.value.?, false),
        .workspace => {
            const number = std.fmt.parseInt(u32, opt.value.?, 10) catch return error.InvalidWorkspace;
            if (number == 0 or number > std.math.maxInt(i32)) return error.InvalidWorkspace;
        },
        .type => {
            rt.target_window = opt.window;
            try checkWindow(rt, opt.window.?, true);
            const text = opt.text.?;
            if (text.len > 64 * 1024 or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidText;
        },
        .key => {
            rt.target_window = opt.window;
            try checkWindow(rt, opt.window.?, true);
            key_argv = try keyArgs(rt.allocator, opt.value.?);
        },
        else => {},
    }
    if (opt.dry_run) {
        try rt.emit(.{ .ok = true, .dry_run = true, .action = @tagName(opt.command), .session_id = rt.session_id, .desktop_point = point, .window = opt.window, .target = opt.value });
        return;
    }
    if (target) |*t| {
        try runPointerAction(rt, opt, t);
    } else switch (opt.command) {
        .focus => {
            try rt.dispatch("focuswindow", try std.fmt.allocPrint(rt.allocator, "address:{s}", .{opt.value.?}));
            try checkWindow(rt, opt.value.?, true);
        },
        .workspace => {
            try rt.dispatch("workspace", opt.value.?);
            const active = try rt.queryJson(geometry.Workspace, "activeworkspace");
            if (active.id != try std.fmt.parseInt(i64, opt.value.?, 10)) return error.WorkspaceVerificationFailed;
        },
        .type => try typeText(rt, opt),
        .key => try pressChord(rt, opt, key_argv.?),
        .launch => return sessions.launch(rt, opt),
        else => unreachable,
    }
    try rt.emit(.{
        .ok = true,
        .action = @tagName(opt.command),
        .session_id = rt.session_id,
        .status = "sent",
        .desktop_point = point,
        .scroll_mode_requested = if (opt.command == .scroll) opt.scroll_mode else null,
    });
}

test "key chords emit explicit modifier releases and reject malformed input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try keyArgs(arena.allocator(), "ctrl+shift+Return");
    try std.testing.expectEqualStrings("-m", argv[7]);
    try std.testing.expectEqualStrings("shift", argv[8]);
    try std.testing.expectEqualStrings("ctrl+super+Return", try x11Chord(arena.allocator(), "ctrl+logo+Return"));
    try std.testing.expectEqualStrings("ISO_Level3_Shift+e", try x11Chord(arena.allocator(), "altgr+e"));
    try std.testing.expectError(error.InvalidKeyChord, keyArgs(arena.allocator(), "ctrl++"));
    try std.testing.expectError(error.InvalidKeyChord, keyArgs(arena.allocator(), "ctrl+ctrl+a"));
    try std.testing.expectError(error.InvalidWindowAddress, validateAddress("0x123,exec,evil"));
}
