const std = @import("std");
const args = @import("cli/args.zig");
const geometry = @import("core/geometry.zig");
const native = @import("platform/native.zig");
const c = native.c;
const Runtime = @import("runtime/runtime.zig").Runtime;
const Pointer = @import("input/pointer.zig").Pointer;
const motion = @import("input/motion.zig");
const Aura = @import("input/aura.zig").Aura;
const operations = @import("runtime/operations.zig");
const sessions = @import("runtime/sessions.zig");
const preview = @import("preview/controller.zig");
const Keyboard = @import("input/keyboard.zig").Keyboard;

const help = @import("cli/help.zig").text;

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
const observation = @import("capture/observation.zig");
const Client = observation.Client;

fn validateAddress(address: []const u8) !void {
    if (!std.mem.startsWith(u8, address, "0x") or address.len < 3 or address.len > 18) return error.InvalidWindowAddress;
    for (address[2..]) |ch| if (!std.ascii.isHex(ch)) return error.InvalidWindowAddress;
}

fn checkWindow(rt: *Runtime, address: []const u8, require_focus: bool) !void {
    try validateAddress(address);
    const clients = try rt.json([]Client, try rt.query("clients"));
    var found = false;
    for (clients) |client| {
        if (eq(client.address, address) and client.mapped and !client.hidden) {
            found = true;
            break;
        }
    }
    if (!found) return error.WindowNotFound;
    if (require_focus) {
        const active = try rt.json(struct { address: []const u8 = "" }, try rt.query("activewindow"));
        if (!eq(active.address, address)) return error.WindowNotFocused;
    }
}

fn keyArgs(a: std.mem.Allocator, chord: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(a, "wtype");
    var parts = std.mem.splitScalar(u8, chord, '+');
    var mods: std.ArrayList([]const u8) = .empty;
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidKeyChord;
        if (parts.peek() != null) {
            const mod = if (eq(part, "super")) "logo" else part;
            if (!eq(mod, "ctrl") and !eq(mod, "shift") and !eq(mod, "alt") and !eq(mod, "logo") and !eq(mod, "altgr")) return error.InvalidKeyChord;
            for (mods.items) |existing| if (eq(existing, mod)) return error.InvalidKeyChord;
            try mods.append(a, mod);
            try out.appendSlice(a, &.{ "-M", mod });
        } else {
            for (part) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return error.InvalidKeyChord;
            if (c.xkb_keysym_from_name(try a.dupeZ(u8, part), c.XKB_KEYSYM_CASE_INSENSITIVE) == 0) return error.InvalidKeyChord;
            try out.appendSlice(a, &.{ "-k", part });
        }
    }
    var i = mods.items.len;
    while (i > 0) {
        i -= 1;
        try out.appendSlice(a, &.{ "-m", mods.items[i] });
    }
    return out.toOwnedSlice(a);
}

fn x11Keyboard(rt: *Runtime, address: []const u8) !bool {
    const clients = try rt.json([]Client, try rt.query("clients"));
    for (clients) |client| {
        if (!eq(client.address, address)) continue;
        if (!client.xwayland) return false;
        if (!try rt.executable("xdotool")) return error.XWaylandHelperMissing;
        // DISPLAY can point at another X server. Check its focused PID first.
        const result = try std.process.run(rt.a, rt.io, .{
            .argv = &.{ "xdotool", "getwindowfocus", "getwindowpid" },
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(4096),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } },
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

fn x11Chord(rt: *Runtime, chord: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var parts = std.mem.splitScalar(u8, chord, '+');
    while (parts.next()) |part| {
        if (result.items.len > 0) try result.append(rt.a, '+');
        try result.appendSlice(rt.a, if (eq(part, "logo")) "super" else if (eq(part, "altgr")) "ISO_Level3_Shift" else part);
    }
    return result.toOwnedSlice(rt.a);
}

fn scroll(rt: *Runtime, pointer: *Pointer, point: geometry.Point, dx: i32, dy: i32, ms: u32, mode: []const u8) !void {
    const active = try rt.json(struct { address: []const u8 = "" }, try rt.query("activewindow"));
    rt.target_window = active.address;
    const wheel = eq(mode, "wheel") or (eq(mode, "auto") and ms == 0);
    const clients = try rt.json([]Client, try rt.query("clients"));
    for (clients) |client| {
        if (!eq(client.address, active.address) or !client.xwayland) continue;
        if (eq(mode, "continuous")) return error.ContinuousScrollUnavailable;
        // XWayland does not consistently translate virtual Wayland axis events.
        // XTEST wheel buttons are used only inside the verified focused client.
        if (point.x < client.at[0] or point.y < client.at[1] or
            @as(i64, point.x) >= @as(i64, client.at[0]) + client.size[0] or
            @as(i64, point.y) >= @as(i64, client.at[1]) + client.size[1]) return error.WindowNotFocused;
        _ = try x11Keyboard(rt, client.address);
        if (ms != 0) {
            var driver = ScrollDriver{ .rt = rt, .pointer = pointer, .point = point, .x11 = true };
            return @import("input/scroll.zig").run(&driver, .{ .x = dx, .y = dy }, ms);
        }
        for ([_]i32{ dy, dx }, 0..) |amount, axis| {
            if (amount == 0) continue;
            const button: u8 = if (axis == 0) (if (amount > 0) 5 else 4) else (if (amount > 0) 7 else 6);
            try rt.run(&.{ "xdotool", "click", "--repeat", try std.fmt.allocPrint(rt.a, "{d}", .{@abs(amount)}), "--delay", "0", try std.fmt.allocPrint(rt.a, "{d}", .{button}) }, null, true);
        }
        return;
    }
    if (wheel and ms == 0) return pointer.scroll(dx, dy);
    var driver = ScrollDriver{ .rt = rt, .pointer = pointer, .point = point, .wheel = wheel };
    // Wheel detents are independent steps, not a continuous gesture. Sending
    // axis_stop for them can flush a spurious surface-distance event in GTK.
    defer if (!wheel) pointer.endScroll(dx, dy);
    const unit: i32 = if (wheel) 1 else 15 * 256;
    try @import("input/scroll.zig").run(&driver, .{ .x = dx * unit, .y = dy * unit }, ms);
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
        var scratch = self.rt.*;
        scratch.a = arena.allocator();
        const actual = try scratch.json(geometry.Point, try scratch.query("cursorpos"));
        if (@abs(@as(i64, actual.x) - self.point.x) > 1 or @abs(@as(i64, actual.y) - self.point.y) > 1) return error.CursorPositionMismatch;
        if (!self.x11) return if (self.wheel) self.pointer.scroll(delta.x, delta.y) else self.pointer.scrollContinuous(delta.x, delta.y);
        _ = try x11Keyboard(&scratch, self.rt.target_window.?);
        for ([_]i32{ delta.y, delta.x }, 0..) |amount, axis| {
            if (amount == 0) continue;
            const button: u8 = if (axis == 0) (if (amount > 0) 5 else 4) else (if (amount > 0) 7 else 6);
            try scratch.run(&.{ "xdotool", "click", "--repeat", try std.fmt.allocPrint(scratch.a, "{d}", .{@abs(amount)}), "--delay", "0", try std.fmt.allocPrint(scratch.a, "{d}", .{button}) }, null, true);
        }
    }
};

const MotionDriver = struct {
    rt: *Runtime,
    pointer: *Pointer,
    aura: ?*Aura = null,
    expected_position: ?geometry.Point = null,
    pub fn now(_: *@This()) i64 {
        return native.nowMs();
    }
    pub fn pause(self: *@This(), ms: u32) !void {
        try self.rt.pause(ms);
    }
    pub fn move(self: *@This(), p: geometry.Point) !void {
        if (self.expected_position) |expected| {
            const before = try self.rt.json(geometry.Point, try self.rt.query("cursorpos"));
            if (@abs(@as(i64, before.x) - expected.x) > 1 or @abs(@as(i64, before.y) - expected.y) > 1) return error.CursorPositionMismatch;
        }
        // Each sample preserves the existing stop/signal/session-lock guards.
        try self.rt.dispatch("movecursor", try std.fmt.allocPrint(self.rt.a, "{d} {d}", .{ p.x, p.y }));
        try self.pointer.refreshPosition();
        const actual = try self.rt.json(geometry.Point, try self.rt.query("cursorpos"));
        if (@abs(@as(i64, actual.x) - p.x) > 1 or @abs(@as(i64, actual.y) - p.y) > 1) return error.CursorPositionMismatch;
        self.expected_position = actual;
        if (self.aura) |aura| try aura.place(actual);
    }
};

const PointerGuard = struct {
    frame: geometry.Frame,
    fn check(rt: *Runtime, context: *anyopaque) !void {
        const self: *PointerGuard = @ptrCast(@alignCast(context));
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var scratch = rt.*;
        scratch.a = arena.allocator();
        const current = try observation.snapshotForAction(&scratch, self.frame.monitor_id, true);
        try self.frame.validate(rt.instance, rt.display, current.revision, native.nowMs());
    }
};

fn action(rt: *Runtime, opt: args.Args) !void {
    if (opt.command == .launch and eq(rt.session_id, "host")) return error.ManagedSessionRequired;
    const lock_fd = try rt.lock();
    defer _ = c.close(lock_fd);
    try rt.validateDisplay();
    try rt.unlocked();
    if (!opt.dry_run) rt.control_token = try rt.token();
    var point: ?geometry.Point = null;
    var frame: ?geometry.Frame = null;
    var pointer_guard: PointerGuard = undefined;
    if (opt.frame) |id| {
        frame = try observation.loadFrame(rt, id);
        const s = try observation.snapshot(rt, frame.?.monitor_id);
        try frame.?.validate(rt.instance, rt.display, s.revision, native.nowMs());
        point = try frame.?.point(opt.x.?, opt.y.?);
        if (opt.window) |window| {
            try checkWindow(rt, window, true);
            var inside = false;
            for (s.clients) |client| {
                if (!eq(client.address, window)) continue;
                const p = point.?;
                inside = p.x >= client.at[0] and p.y >= client.at[1] and
                    @as(i64, p.x) < @as(i64, client.at[0]) + client.size[0] and
                    @as(i64, p.y) < @as(i64, client.at[1]) + client.size[1];
            }
            if (!inside) return error.PointerOutsideTarget;
            rt.target_window = window;
        } else rt.target_window = s.active;
        if (opt.command == .scroll and eq(opt.scroll_mode, "continuous")) {
            for (s.clients) |client| {
                if (eq(client.address, rt.target_window.?) and client.xwayland)
                    return error.ContinuousScrollUnavailable;
            }
        }
        pointer_guard = .{ .frame = frame.? };
        if (opt.command == .drag) _ = try frame.?.point(opt.to_x.?, opt.to_y.?);
    }
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
            if (opt.text.?.len > 64 * 1024 or !std.unicode.utf8ValidateSlice(opt.text.?) or std.mem.indexOfScalar(u8, opt.text.?, 0) != null) return error.InvalidText;
        },
        .key => {
            rt.target_window = opt.window;
            try checkWindow(rt, opt.window.?, true);
            key_argv = try keyArgs(rt.a, opt.value.?);
        },
        else => {},
    }
    if (opt.dry_run) {
        try rt.emit(.{ .ok = true, .dry_run = true, .action = @tagName(opt.command), .session_id = rt.session_id, .desktop_point = point, .window = opt.window, .target = opt.value });
        return;
    }
    if (point) |p| {
        var pointer: Pointer = undefined;
        try pointer.init(try rt.displayPath());
        defer pointer.deinit();
        try pointer.create();
        pointer.runtime = rt;
        // Recheck after connecting the input device, before moving the cursor.
        try frame.?.validate(rt.instance, rt.display, (try observation.snapshot(rt, frame.?.monitor_id)).revision, native.nowMs());
        rt.extra_guard = PointerGuard.check;
        rt.guard_context = &pointer_guard;
        defer {
            rt.extra_guard = null;
            rt.guard_context = null;
        }
        const start = try rt.json(geometry.Point, try rt.query("cursorpos"));
        var driver = MotionDriver{ .rt = rt, .pointer = &pointer, .expected_position = start };
        var aura: Aura = undefined;
        const aura_started = native.nowMs();
        if (!opt.no_aura and !try rt.outlineEnabled()) {
            const monitors = try rt.json([]geometry.Monitor, try rt.query("monitors"));
            try aura.init(&pointer, monitors);
            driver.aura = &aura;
        }
        defer if (driver.aura != null) aura.deinit();
        if (driver.aura) |halo| try halo.place(start);
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
                const destination = try frame.?.point(opt.to_x.?, opt.to_y.?);
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
    } else switch (opt.command) {
        .focus => {
            try rt.dispatch("focuswindow", try std.fmt.allocPrint(rt.a, "address:{s}", .{opt.value.?}));
            try checkWindow(rt, opt.value.?, true);
        },
        .workspace => {
            try rt.dispatch("workspace", opt.value.?);
            const active = try rt.json(geometry.Workspace, try rt.query("activeworkspace"));
            if (active.id != try std.fmt.parseInt(i64, opt.value.?, 10)) return error.WorkspaceVerificationFailed;
        },
        .type => {
            try checkWindow(rt, opt.window.?, true);
            const x11 = try x11Keyboard(rt, opt.window.?);
            if (!x11 and !eq(opt.backend, "helper")) {
                var keyboard: Keyboard = undefined;
                try keyboard.init(try rt.displayPath());
                defer keyboard.deinit();
                try keyboard.create();
                try keyboard.typeText(rt, opt.text.?);
            } else {
                if (x11 and eq(opt.backend, "native")) return error.NativeX11Unavailable;
                try rt.run(if (x11) &.{ "xdotool", "type", "--delay", "12", "--file", "-" } else &.{ "wtype", "-" }, opt.text.?, true);
            }
        },
        .key => {
            try checkWindow(rt, opt.window.?, true);
            const x11 = try x11Keyboard(rt, opt.window.?);
            if (!x11 and !eq(opt.backend, "helper")) {
                var keyboard: Keyboard = undefined;
                try keyboard.init(try rt.displayPath());
                defer keyboard.deinit();
                try keyboard.create();
                try keyboard.chord(rt, opt.value.?);
            } else {
                if (x11 and eq(opt.backend, "native")) return error.NativeX11Unavailable;
                try rt.run(if (x11) &.{ "xdotool", "key", "--delay", "0", try x11Chord(rt, opt.value.?) } else key_argv.?, null, true);
            }
        },
        .launch => return sessions.launch(rt, opt),
        else => unreachable,
    }
    try rt.emit(.{ .ok = true, .action = @tagName(opt.command), .session_id = rt.session_id, .status = "sent", .desktop_point = point, .scroll_mode_requested = if (opt.command == .scroll) opt.scroll_mode else null });
}

fn waitFor(rt: *Runtime, opt: args.Args) !void {
    const condition = opt.value.?;
    if (!eq(condition, "stable") and !eq(condition, "window") and !eq(condition, "focus") and !eq(condition, "workspace")) return error.InvalidWaitCondition;
    if (eq(condition, "focus") and opt.window == null) return error.WindowRequired;
    if (eq(condition, "window") and opt.window == null and opt.class == null) return error.WindowRequired;
    if (eq(condition, "workspace") and opt.workspace_id == null) return error.InvalidWorkspace;
    try rt.prepare();
    try rt.validateDisplay();
    const started = native.nowMs();
    var last: ?[32]u8 = null;
    var stable_since = started;
    const temp = try rt.path(try std.fmt.allocPrint(rt.a, "wait-{s}.png", .{try rt.id()}));
    defer _ = c.unlink(temp);
    while (native.nowMs() - started < opt.timeout_ms) {
        try native.checkCancelled();
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var scratch = rt.*;
        scratch.a = arena.allocator();
        try scratch.unlocked();
        const state = try observation.snapshot(&scratch, opt.monitor);
        var satisfied = false;
        if (eq(condition, "stable")) {
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hash.update(state.revision);
            if (opt.pixels) {
                const monitor = try observation.monitorByName(state, opt.monitor);
                try scratch.run(&.{ "grim", "-o", monitor.name, temp }, null, false);
                hash.update(try scratch.read(temp, 64 * 1024 * 1024));
            }
            const digest = hash.finalResult();
            if (last == null or !std.mem.eql(u8, &last.?, &digest)) stable_since = native.nowMs();
            last = digest;
            satisfied = native.nowMs() - stable_since >= opt.stable_ms;
        } else if (eq(condition, "focus")) {
            satisfied = eq(state.active, opt.window.?);
        } else if (eq(condition, "window")) {
            for (state.clients) |client| {
                if (!client.mapped or client.hidden) continue;
                if (opt.window) |address| if (!eq(client.address, address)) continue;
                if (opt.class) |class| if (!eq(client.class, class)) continue;
                satisfied = true;
                break;
            }
        } else {
            const active = try scratch.json(geometry.Workspace, try scratch.query("activeworkspace"));
            satisfied = active.id == opt.workspace_id.?;
        }
        if (satisfied and native.nowMs() - started < opt.timeout_ms) {
            try rt.emit(.{ .ok = true, .session_id = rt.session_id, .condition = condition, .elapsed_ms = native.nowMs() - started, .pixels = opt.pixels });
            return;
        }
        try rt.pause(50);
    }
    return error.WaitTimeout;
}

fn doctor(rt: *Runtime) !void {
    const version = try rt.json(std.json.Value, try rt.query("version"));
    const status = try rt.json(struct { configProvider: []const u8 }, try rt.query("status"));
    const display_matches = blk: {
        rt.validateDisplay() catch break :blk false;
        break :blk true;
    };
    var pointer: Pointer = undefined;
    const pointer_available = blk: {
        pointer.init(try rt.displayPath()) catch break :blk false;
        pointer.deinit();
        break :blk true;
    };
    var keyboard: Keyboard = undefined;
    const keyboard_available = blk: {
        keyboard.init(try rt.displayPath()) catch break :blk false;
        keyboard.deinit();
        break :blk true;
    };
    const grim = try rt.executable("grim");
    const wtype = try rt.executable("wtype");
    const xdotool = try rt.executable("xdotool");
    const hyprland = try rt.executable("Hyprland");
    const dbus_daemon = try rt.executable("dbus-daemon");
    const registry = c.access("/usr/lib/at-spi2-registryd", c.X_OK) == 0 or c.access("/usr/libexec/at-spi2-registryd", c.X_OK) == 0;
    const bus_configured = if (rt.env.get("DBUS_SESSION_BUS_ADDRESS")) |address| address.len != 0 else false;
    const pidfd: c_int = @intCast(c.syscall(c.SYS_pidfd_open, c.getpid(), @as(c_uint, 0)));
    const pidfd_available = pidfd >= 0;
    if (pidfd >= 0) _ = c.close(pidfd);
    const xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
    const xkb_data = blk: {
        if (xkb_context == null) break :blk false;
        defer c.xkb_context_unref(xkb_context);
        const map = c.xkb_keymap_new_from_names(xkb_context, null, c.XKB_KEYMAP_COMPILE_NO_FLAGS);
        if (map == null) break :blk false;
        c.xkb_keymap_unref(map);
        break :blk true;
    };
    const enabled = blk: {
        _ = rt.token() catch break :blk false;
        break :blk true;
    };
    try rt.emit(.{
        .ok = true,
        .version = "0.4.0",
        .hyprland = version,
        .config_provider = status.configProvider,
        .session_id = rt.session_id,
        .instance = rt.instance,
        .wayland_display = rt.display,
        .display_matches = display_matches,
        .dependencies = .{ .grim = grim, .wtype = wtype, .xdotool = xdotool, .Hyprland = hyprland, .dbus_daemon = dbus_daemon, .at_spi_registry = registry, .dbus_address_configured = bus_configured, .xkb_data = xkb_data, .pidfd = pidfd_available },
        .capabilities = .{ .state = true, .capture = grim and display_matches, .virtual_pointer = pointer_available and display_matches, .virtual_keyboard = keyboard_available and display_matches, .text_helper_installed = wtype, .dispatch = eq(status.configProvider, "hyprlang") or eq(status.configProvider, "lua"), .managed_sessions = hyprland and dbus_daemon and pidfd_available and display_matches, .accessibility = bus_configured },
        .checks = .{
            .capture = .{ .implemented = true, .prerequisites_available = grim and display_matches, .operation_verified = false },
            .managed_sessions = .{ .implemented = true, .prerequisites_available = hyprland and dbus_daemon and pidfd_available and display_matches, .operation_verified = false, .headless_gpu_verified = false },
            .accessibility = .{ .implemented = true, .prerequisites_available = bus_configured, .operation_verified = false, .note = "Bus configuration does not prove AT-SPI service availability or application support." },
            .input = .{ .pointer_protocol_available = pointer_available, .keyboard_protocol_available = keyboard_available, .operation_verified = false },
        },
        .verification_note = "Read-only prerequisite/protocol probes; no input, capture, accessibility request or compositor startup performed. operation_verified=false means not tested, not a demonstrated failure.",
        .control_enabled = enabled,
        .shared_cursor = eq(rt.session_id, "host"),
        .state_directory = rt.directory,
    });
}

fn execute(init: std.process.Init, opt: args.Args) !void {
    if (opt.command == ._preview_frame or opt.command == ._preview_stop) {
        // If a viewer is killed unexpectedly, cancel its worker and let the
        // existing child cleanup reap grim. No detached capture loop remains.
        if (c.prctl(c.PR_SET_PDEATHSIG, c.SIGTERM, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) < 0 or c.getppid() == 1) return error.Cancelled;
    }
    var rt = try Runtime.init(init);
    if (opt.command == .session) return sessions.command(&rt, opt);
    if (opt.command == .sessions) return sessions.list(&rt);
    if (opt.command == .preview) return preview.launch(&rt, opt);
    try sessions.route(&rt, opt.session);
    if (opt.mutates()) {
        try operations.log(&rt, @tagName(opt.command), if (opt.dry_run) "dry_run" else "started");
        action(&rt, opt) catch |err| {
            operations.log(&rt, @tagName(opt.command), @errorName(err)) catch {};
            return err;
        };
        operations.log(&rt, @tagName(opt.command), "completed") catch {};
        return;
    }
    switch (opt.command) {
        .doctor => try doctor(&rt),
        .state => try rt.emit(.{ .ok = true, .session_id = rt.session_id, .monitors = try rt.json(std.json.Value, try rt.query("monitors")), .windows = try rt.json(std.json.Value, try rt.query("clients")), .workspaces = try rt.json(std.json.Value, try rt.query("workspaces")), .active_window = try rt.json(std.json.Value, try rt.query("activewindow")), .cursor = try rt.json(std.json.Value, try rt.query("cursorpos")) }),
        .monitors, .windows, .workspaces => {
            const name = switch (opt.command) {
                .windows => "clients",
                .monitors => "monitors",
                else => "workspaces",
            };
            try rt.emit(.{ .ok = true, .session_id = rt.session_id, .data = try rt.json(std.json.Value, try rt.query(name)) });
        },
        .sessions => try rt.emit(.{ .ok = true, .sessions = .{.{ .id = "host", .instance = rt.instance, .wayland_display = rt.display, .shared_cursor = eq(rt.session_id, "host") }} }),
        .observe => try observation.observe(&rt, opt),
        .enable => try rt.enable(opt.indicator),
        .stop => try rt.stop(),
        .wait => try waitFor(&rt, opt),
        .events => try operations.events(&rt, opt),
        .logs => try operations.logs(&rt, opt),
        .gc => try operations.collect(&rt, opt, true),
        .accessibility => try @import("accessibility/tree.zig").tree(&rt, opt),
        ._a11y => try @import("accessibility/tree.zig").worker(&rt, opt),
        ._cursor_probe => try @import("capture/cursor_capture.zig").probe(&rt),
        ._preview_frame, ._preview_stop => try preview.worker(&rt, opt),
        else => return error.CommandNotImplemented,
    }
}

fn report(init: std.process.Init, err: anyerror) void {
    const hint: []const u8 = switch (err) {
        error.PreviewHelperMissing => "Build the optional viewer with zig build pip; keep deskctl-pip beside deskctl.",
        error.PreviewManagedSessionRequired => "Preview requires an explicit managed session, never host.",
        error.PreviewRequiresHyprlang => "This PiP version requires the host Hyprlang config provider; no window or rules were created.",
        error.PreviewIdentityMismatch => "The original preview session ended or changed. Close the viewer and explicitly open a new one.",
        error.ControlStopped => "Input is disabled. Run deskctl enable to enable it.",
        error.StaleObservation => "The frame expired or desktop layout/focus changed. Observe again.",
        error.WindowNotFocused => "Focus the target window first, then verify it before typing.",
        error.CursorPositionMismatch => "Cursor diverged from the expected path: human movement, pointer locking/recentering or compositor constraints are possible. Input was aborted; observe again. No safety tolerance was relaxed.",
        error.PointerOutsideTarget => "The pointer start/click coordinate is outside --window. Observe the target window and choose coordinates inside it.",
        error.InvalidScrollMode => "Use --scroll-mode auto, wheel or continuous. Duration controls pacing separately.",
        error.ContinuousScrollUnavailable => "XWayland fallback only supports wheel events. Choose --scroll-mode wheel (optionally paced). No continuous-to-wheel substitution was performed.",
        error.SessionRequired => "Input commands require an explicit --session NAME.",
        error.UnsupportedConfigProvider => "Dispatch supports Hyprlang and Lua providers only.",
        error.FileNotFound => "A helper or required file is missing. Check deskctl doctor and install grim/wtype.",
        error.ControlBusy => "Another deskctl input action is running.",
        error.InvalidHeadlessBridge => "Use an absolute, trusted regular library path without spaces/colons, not writable by other users, only with session create (not --nested).",
        error.OutlinePluginUnavailable => "The optional deskctl-outline plugin is not loaded or rejected activation. Input remains disabled. No plugin was auto-loaded.",
        error.OutlineRequiresHyprlang => "The experimental outline dispatcher currently requires Hyprlang. Input remains disabled.",
        error.HeadlessRenderUnavailable => "Headless GPU buffers failed. See compositor.log; try explicit --nested. The failed compositor was stopped.",
        error.SessionStartupFailed, error.SessionStartupTimeout, error.SessionConfigInvalid => "Managed session failed and its processes were stopped. Inspect compositor.log in the named session directory.",
        error.WaitTimeout => "The requested condition did not become true before its deadline.",
        error.Cancelled => "Action cancelled. Native owned inputs were released.",
        error.NativeCaptureUnavailable => "Capture uses grim in this release. Use --backend helper or auto.",
        error.AuraUnavailable, error.AuraBufferUnavailable, error.AuraGeometryUnsupported => "The cursor halo is unavailable on this output/compositor. Inspect state; use --no-aura explicitly to run without the indicator.",
        error.CursorCaptureUnavailable, error.CursorCaptureUnsupported => "The compositor did not provide a usable cursor capture session. No theme or desktop configuration was changed.",
        error.XWaylandHelperMissing => "This is an XWayland window. Install xdotool for X11 keyboard input.",
        error.X11TargetMismatch => "The focused X11 window does not match the requested Hyprland client. Check DISPLAY and focus.",
        else => "Run deskctl --help for usage. No task outcome has been verified.",
    };
    const message = std.json.Stringify.valueAlloc(init.arena.allocator(), .{ .ok = false, .err = .{ .code = @errorName(err), .message = hint } }, .{}) catch return;
    std.Io.File.stdout().writeStreamingAll(init.io, message) catch {};
    std.Io.File.stdout().writeStreamingAll(init.io, "\n") catch {};
}

pub fn main(init: std.process.Init) void {
    _ = c.umask(0o077);
    native.signals();
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        report(init, err);
        std.process.exit(1);
    };
    if (argv.len == 1 or (argv.len == 2 and (eq(argv[1], "--help") or eq(argv[1], "-h")))) {
        std.Io.File.stdout().writeStreamingAll(init.io, help) catch {};
        return;
    }
    if (argv.len == 2 and eq(argv[1], "--version")) {
        std.Io.File.stdout().writeStreamingAll(init.io, "deskctl 0.4.0\n") catch {};
        return;
    }
    const opt = args.parse(argv[1..]) catch |err| {
        report(init, err);
        std.process.exit(2);
    };
    execute(init, opt) catch |err| {
        report(init, err);
        std.process.exit(1);
    };
}

test {
    _ = @import("core/geometry.zig");
    _ = @import("cli/args.zig");
    _ = @import("runtime/operations.zig");
    _ = @import("preview/protocol.zig");
}
test "key chords emit explicit modifier releases and reject malformed input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try keyArgs(arena.allocator(), "ctrl+shift+Return");
    try std.testing.expectEqualStrings("-m", argv[7]);
    try std.testing.expectEqualStrings("shift", argv[8]);
    try std.testing.expectError(error.InvalidKeyChord, keyArgs(arena.allocator(), "ctrl++"));
    try std.testing.expectError(error.InvalidKeyChord, keyArgs(arena.allocator(), "ctrl+ctrl+a"));
    try std.testing.expectError(error.InvalidWindowAddress, validateAddress("0x123,exec,evil"));
}

test {
    std.testing.refAllDecls(motion);
    std.testing.refAllDecls(@import("input/keyboard.zig"));
    std.testing.refAllDecls(sessions);
    std.testing.refAllDecls(@import("input/scroll.zig"));
    std.testing.refAllDecls(@import("input/aura.zig"));
    std.testing.refAllDecls(@import("capture/cursor_capture.zig"));
}
