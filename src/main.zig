const std = @import("std");
const args = @import("args.zig");
const geometry = @import("geometry.zig");
const native = @import("native.zig");
const c = native.c;
const Runtime = @import("runtime.zig").Runtime;
const Pointer = @import("pointer.zig").Pointer;
const motion = @import("motion.zig");
const Aura = @import("aura.zig").Aura;
const operations = @import("operations.zig");
const sessions = @import("sessions.zig");
const Keyboard = @import("keyboard.zig").Keyboard;

const help =
    \\deskctl 0.3.0 — computer use for Hyprland (Zig 0.16, Linux)
    \\
    \\All commands accept --session NAME (default host). Input REQUIRES it.
    \\JSON output; events emits NDJSON. No MCP server or AI model.
    \\
    \\Observe and inspect:
    \\  doctor | state | monitors | windows | workspaces | sessions
    \\  observe [--monitor NAME] [--scale 0.1..2] [--backend auto|helper]
    \\  accessibility [--window ADDRESS] [--depth 5] [--limit 100] [--timeout-ms 5000]
    \\  wait stable [--pixels] [--monitor NAME] [--stable-ms 300] [--timeout-ms 5000]
    \\  wait window --class CLASS [--timeout-ms 5000]
    \\  wait focus --window ADDRESS | wait workspace --workspace NUMBER
    \\  events [--limit 100] [--timeout-ms 5000]
    \\  logs [--limit 100]
    \\  gc [--older-than-ms 300000] [--dry-run]
    \\
    \\Input (shared human cursor/focus ONLY in host; disabled until enable):
    \\  enable [--indicator none|outline] | stop
    \\  focus ADDRESS | workspace NUMBER
    \\  move --frame ID --x X --y Y
    \\  click|doubleclick --frame ID --x X --y Y [--button left|right|middle]
    \\  drag --frame ID --x X --y Y --to-x X --to-y Y [--duration-ms 500]
    \\  scroll --frame ID --x X --y Y [--dy STEPS] [--dx STEPS] [--duration-ms 500]
    \\  type --window ADDRESS --text TEXT [--backend auto|native|helper]
    \\  key CHORD --window ADDRESS [--backend auto|native|helper]
    \\
    \\Managed sessions (input isolation, NOT filesystem/credential sandboxing):
    \\  session create NAME [--nested] [--lua]
    \\    [--headless-bridge /absolute/trusted.so] Experimental, new headless only
    \\  session inspect NAME
    \\  session destroy NAME       Closes tracked apps; retains profiles and logs
    \\  launch --session NAME -- PROGRAM ARGUMENTS...
    \\
    \\Input accepts --dry-run. Coordinates are screenshot pixels, not desktop pixels.
    \\Pointer approach is smooth (auto 200..600ms); --move-duration-ms 50..10000
    \\overrides it for move/click/doubleclick/scroll/drag. Use 0 for instant approach.
    \\Drag --duration-ms controls the separate, smooth button-held segment.
    \\Scroll is progressive; --duration-ms 0 restores discrete wheel input.
    \\Outline requires the optional Hyprland plugin, never auto-loaded.
    \\Pointer actions show a blue, click-through halo; --no-aura disables it.
    \\Frames expire after 30s or layout/focus changes. Observe again after each action.
    \\Type/key require the exact focused window. Example chord: ctrl+shift+Return.
    \\SIGINT/SIGTERM/stop cancel input; native devices release owned keys/buttons.
    \\Headless needs compatible GPU buffers. --nested opens a compositor preview.
    \\
;

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
const Client = struct {
    address: []const u8,
    at: [2]i32,
    size: [2]i32,
    workspace: geometry.Workspace,
    monitor: i64 = -1,
    mapped: bool = true,
    hidden: bool = false,
    floating: bool = false,
    pinned: bool = false,
    fullscreen: i64 = 0,
    xwayland: bool = false,
    pid: i64 = 0,
    class: []const u8 = "",
};
const Snapshot = struct {
    monitors: []geometry.Monitor,
    clients: []Client,
    active: []const u8,
    revision: []const u8,
};

fn snapshot(rt: *Runtime, scope: ?[]const u8) !Snapshot {
    const monitors = try rt.json([]geometry.Monitor, try rt.query("monitors"));
    const clients = try rt.json([]Client, try rt.query("clients"));
    const active = try rt.json(struct { address: []const u8 = "" }, try rt.query("activewindow"));
    var layers = try rt.json(std.json.Value, try rt.query("layers"));
    var relevant: std.ArrayList(Client) = .empty;
    if (scope) |name| {
        var target: ?geometry.Monitor = null;
        for (monitors) |m| if (eq(m.name, name)) {
            target = m;
            break;
        };
        const monitor = target orelse return error.MonitorNotFound;
        const rect = try monitor.rect();
        // A floating window may cross an output boundary. Keep intersecting
        // clients as well as all clients assigned to the captured output.
        for (clients) |client| {
            const intersects = @as(f64, @floatFromInt(client.at[0])) < rect.x + rect.width and
                @as(f64, @floatFromInt(client.at[1])) < rect.y + rect.height and
                @as(f64, @floatFromInt(@as(i64, client.at[0]) + client.size[0])) > rect.x and
                @as(f64, @floatFromInt(@as(i64, client.at[1]) + client.size[1])) > rect.y;
            if (client.monitor == monitor.id or intersects) try relevant.append(rt.a, client);
        }
        if (layers != .object) return error.InvalidLayerState;
        layers = layers.object.get(name) orelse .null;
    } else try relevant.appendSlice(rt.a, clients);
    const normalized = try rt.a.dupe(geometry.Monitor, monitors);
    for (normalized) |*m| m.focused = false;
    const data = try std.json.Stringify.valueAlloc(rt.a, .{ .scope = scope, .monitors = normalized, .clients = relevant.items, .active = active.address, .layers = layers }, .{});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return .{ .monitors = monitors, .clients = clients, .active = active.address, .revision = try rt.a.dupe(u8, &std.fmt.bytesToHex(digest, .lower)) };
}

fn monitorByName(s: Snapshot, name: ?[]const u8) !geometry.Monitor {
    for (s.monitors) |m| {
        if (if (name) |n| eq(n, m.name) else m.focused) {
            if (m.disabled or !m.dpmsStatus) return error.MonitorUnavailable;
            return m;
        }
    }
    return error.MonitorNotFound;
}

fn observe(rt: *Runtime, opt: args.Args) !void {
    if (eq(opt.backend, "native")) return error.NativeCaptureUnavailable;
    operations.collect(rt, opt, false) catch |err| switch (err) {
        error.ControlBusy => {},
        else => return err,
    };
    try rt.prepare();
    try rt.validateDisplay();
    try rt.unlocked();
    const monitor_name = opt.monitor orelse blk: {
        const monitors = try rt.json([]geometry.Monitor, try rt.query("monitors"));
        for (monitors) |m| if (m.focused) break :blk m.name;
        return error.MonitorNotFound;
    };
    const before = try snapshot(rt, monitor_name);
    const monitor = try monitorByName(before, monitor_name);
    const rect = try monitor.rect();
    const frame_id = try rt.id();
    const image_path = try rt.path(try std.fmt.allocPrint(rt.a, "{s}.png", .{frame_id}));
    errdefer _ = c.unlink(image_path);
    const started = native.nowMs();
    const unix_ms = @as(i64, @intCast(c.time(null))) * 1000;
    const scale = try std.fmt.allocPrint(rt.a, "{d}", .{opt.scale});
    try rt.run(&.{ "grim", "-t", "png", "-s", scale, "-o", monitor.name, image_path }, null, false);
    try rt.unlocked();
    const after = try snapshot(rt, monitor_name);
    if (!eq(before.revision, after.revision)) return error.StaleObservation;
    // Read only the PNG header, without decoding or allocating the image.
    const fd = c.open(image_path, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
    if (fd < 0) return error.InvalidScreenshot;
    defer _ = c.close(fd);
    var header: [24]u8 = undefined;
    if (c.read(fd, &header, header.len) != header.len) return error.InvalidScreenshot;
    const size = try geometry.pngSize(&header);
    const frame = geometry.Frame{
        .session_id = rt.session_id,
        .instance = rt.instance,
        .wayland_display = rt.display,
        .frame_id = frame_id,
        .captured_at_unix_ms = unix_ms,
        .captured_at_monotonic_ms = started,
        .monitor_id = monitor.name,
        .workspace_id = monitor.activeWorkspace.id,
        .image_path = image_path,
        .image_width = size.width,
        .image_height = size.height,
        .logical = rect,
        .layout_revision = after.revision,
    };
    const metadata_path = try rt.path(try std.fmt.allocPrint(rt.a, "{s}.json", .{frame_id}));
    const encoded = try std.json.Stringify.valueAlloc(rt.a, frame, .{});
    try std.Io.Dir.cwd().writeFile(rt.io, .{ .sub_path = metadata_path, .data = encoded, .flags = .{ .exclusive = true } });
    try rt.emit(.{ .ok = true, .frame = frame, .capture_duration_ms = native.nowMs() - started });
}

fn loadFrame(rt: *Runtime, frame_id: []const u8) !geometry.Frame {
    if (frame_id.len != 32) return error.InvalidFrameId;
    for (frame_id) |ch| if (!std.ascii.isHex(ch)) return error.InvalidFrameId;
    const data = rt.read(try rt.path(try std.fmt.allocPrint(rt.a, "{s}.json", .{frame_id})), 16384) catch |err| switch (err) {
        error.FileNotFound => return error.FrameNotFound,
        else => return err,
    };
    const frame = try rt.json(geometry.Frame, data);
    if (!eq(frame.frame_id, frame_id)) return error.InvalidFrameId;
    if (!eq(frame.session_id, rt.session_id)) return error.SessionMismatch;
    return frame;
}

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

fn scroll(rt: *Runtime, pointer: *Pointer, point: geometry.Point, dx: i32, dy: i32, ms: u32) !void {
    const active = try rt.json(struct { address: []const u8 = "" }, try rt.query("activewindow"));
    rt.target_window = active.address;
    defer rt.target_window = null;
    const clients = try rt.json([]Client, try rt.query("clients"));
    for (clients) |client| {
        if (!eq(client.address, active.address) or !client.xwayland) continue;
        // XWayland does not consistently translate virtual Wayland axis events.
        // XTEST wheel buttons are used only inside the verified focused client.
        if (point.x < client.at[0] or point.y < client.at[1] or
            @as(i64, point.x) >= @as(i64, client.at[0]) + client.size[0] or
            @as(i64, point.y) >= @as(i64, client.at[1]) + client.size[1]) return error.WindowNotFocused;
        _ = try x11Keyboard(rt, client.address);
        if (ms != 0) {
            var driver = ScrollDriver{ .rt = rt, .pointer = pointer, .point = point, .x11 = true };
            return @import("scroll.zig").run(&driver, .{ .x = dx, .y = dy }, ms);
        }
        for ([_]i32{ dy, dx }, 0..) |amount, axis| {
            if (amount == 0) continue;
            const button: u8 = if (axis == 0) (if (amount > 0) 5 else 4) else (if (amount > 0) 7 else 6);
            try rt.run(&.{ "xdotool", "click", "--repeat", try std.fmt.allocPrint(rt.a, "{d}", .{@abs(amount)}), "--delay", "0", try std.fmt.allocPrint(rt.a, "{d}", .{button}) }, null, true);
        }
        return;
    }
    if (ms == 0) return pointer.scroll(dx, dy);
    var driver = ScrollDriver{ .rt = rt, .pointer = pointer, .point = point };
    defer pointer.endScroll(dx, dy);
    try @import("scroll.zig").run(&driver, .{ .x = dx * 15 * 256, .y = dy * 15 * 256 }, ms);
}

const ScrollDriver = struct {
    rt: *Runtime,
    pointer: *Pointer,
    point: geometry.Point,
    x11: bool = false,
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
        if (!self.x11) return self.pointer.scrollContinuous(delta.x, delta.y);
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
    pub fn now(_: *@This()) i64 {
        return native.nowMs();
    }
    pub fn pause(self: *@This(), ms: u32) !void {
        try self.rt.pause(ms);
    }
    pub fn move(self: *@This(), p: geometry.Point) !void {
        // Each sample preserves the existing stop/signal/session-lock guards.
        try self.rt.dispatch("movecursor", try std.fmt.allocPrint(self.rt.a, "{d} {d}", .{ p.x, p.y }));
        try self.pointer.refreshPosition();
        const actual = try self.rt.json(geometry.Point, try self.rt.query("cursorpos"));
        if (@abs(@as(i64, actual.x) - p.x) > 1 or @abs(@as(i64, actual.y) - p.y) > 1) return error.CursorPositionMismatch;
        if (self.aura) |aura| try aura.place(actual);
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
    if (opt.frame) |id| {
        frame = try loadFrame(rt, id);
        const s = try snapshot(rt, frame.?.monitor_id);
        try frame.?.validate(rt.instance, rt.display, s.revision, native.nowMs());
        point = try frame.?.point(opt.x.?, opt.y.?);
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
        try frame.?.validate(rt.instance, rt.display, (try snapshot(rt, frame.?.monitor_id)).revision, native.nowMs());
        const start = try rt.json(geometry.Point, try rt.query("cursorpos"));
        var driver = MotionDriver{ .rt = rt, .pointer = &pointer };
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
            .scroll => try scroll(rt, &pointer, p, opt.dx, opt.dy, opt.duration_ms),
            .move => {},
            else => unreachable,
        }
        // A stationary click otherwise ends before a single display refresh.
        // This remains part of the cancelable action, not a background daemon.
        const aura_elapsed = native.nowMs() - aura_started;
        if (driver.aura != null and aura_elapsed < 100)
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
    try rt.emit(.{ .ok = true, .action = @tagName(opt.command), .session_id = rt.session_id, .status = "sent", .desktop_point = point });
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
        const state = try snapshot(&scratch, opt.monitor);
        var satisfied = false;
        if (eq(condition, "stable")) {
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hash.update(state.revision);
            if (opt.pixels) {
                const monitor = try monitorByName(state, opt.monitor);
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
    const enabled = blk: {
        _ = rt.token() catch break :blk false;
        break :blk true;
    };
    try rt.emit(.{ .ok = true, .version = "0.3.0", .hyprland = version, .config_provider = status.configProvider, .session_id = rt.session_id, .instance = rt.instance, .wayland_display = rt.display, .display_matches = display_matches, .dependencies = .{ .grim = grim, .wtype = wtype, .xdotool = xdotool }, .capabilities = .{ .state = true, .capture = grim and display_matches, .virtual_pointer = pointer_available and display_matches, .virtual_keyboard = keyboard_available and display_matches, .text_helper_installed = wtype, .dispatch = eq(status.configProvider, "hyprlang") or eq(status.configProvider, "lua"), .managed_sessions = true, .accessibility = true }, .control_enabled = enabled, .shared_cursor = eq(rt.session_id, "host"), .state_directory = rt.directory });
}

fn execute(init: std.process.Init, opt: args.Args) !void {
    var rt = try Runtime.init(init);
    if (opt.command == .session) return sessions.command(&rt, opt);
    if (opt.command == .sessions) return sessions.list(&rt);
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
        .observe => try observe(&rt, opt),
        .enable => try rt.enable(opt.indicator),
        .stop => try rt.stop(),
        .wait => try waitFor(&rt, opt),
        .events => try operations.events(&rt, opt),
        .logs => try operations.logs(&rt, opt),
        .gc => try operations.collect(&rt, opt, true),
        .accessibility => try @import("accessibility.zig").tree(&rt, opt),
        ._a11y => try @import("accessibility.zig").worker(&rt, opt),
        ._cursor_probe => try @import("cursor_capture.zig").probe(&rt),
        else => return error.CommandNotImplemented,
    }
}

fn report(init: std.process.Init, err: anyerror) void {
    const hint: []const u8 = switch (err) {
        error.ControlStopped => "Input is disabled. Run deskctl enable to enable it.",
        error.StaleObservation => "The frame expired or desktop layout/focus changed. Observe again.",
        error.WindowNotFocused => "Focus the target window first, then verify it before typing.",
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
        std.Io.File.stdout().writeStreamingAll(init.io, "deskctl 0.3.0\n") catch {};
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
    _ = @import("geometry.zig");
    _ = @import("args.zig");
    _ = @import("operations.zig");
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
    std.testing.refAllDecls(@import("scroll.zig"));
    std.testing.refAllDecls(@import("aura.zig"));
    std.testing.refAllDecls(@import("cursor_capture.zig"));
}
