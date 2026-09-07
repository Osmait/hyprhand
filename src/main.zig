const std = @import("std");
const args = @import("cli/args.zig");
const geometry = @import("core/geometry.zig");
const native = @import("platform/native.zig");
const c = native.c;
const Runtime = @import("runtime/runtime.zig").Runtime;
const Pointer = @import("input/pointer.zig").Pointer;
const motion = @import("input/motion.zig");
const operations = @import("runtime/operations.zig");
const sessions = @import("runtime/sessions.zig");
const preview = @import("preview/controller.zig");
const Keyboard = @import("input/keyboard.zig").Keyboard;

const help = @import("cli/help.zig").text;

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
const observation = @import("capture/observation.zig");

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
    // Long-lived viewers/events and session lifecycle use their own budgets.
    // Ordinary composite commands share one budget across all IPC and helpers.
    switch (opt.command) {
        .wait => native.limitCommand(opt.timeout_ms, error.WaitTimeout),
        .doctor, .state, .monitors, .windows, .workspaces, .observe => native.limitCommand(10_000, error.CommandTimeout),
        .type => native.limitCommand(300_000, error.CommandTimeout),
        .focus, .workspace, .key, .move, .click, .doubleclick, .drag, .scroll => native.limitCommand(30_000, error.CommandTimeout),
        ._preview_frame => native.limitCommand(2000, error.HelperTimeout),
        else => {},
    }
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
        @import("input/actions.zig").run(&rt, opt) catch |err| {
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
        .wait => try @import("runtime/wait.zig").run(&rt, opt),
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
        error.CommandTimeout => "The command exceeded its shared time budget. Inspect state before retrying; partial input may have been delivered.",
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

test {
    std.testing.refAllDecls(motion);
    std.testing.refAllDecls(@import("input/keyboard.zig"));
    std.testing.refAllDecls(sessions);
    std.testing.refAllDecls(@import("input/scroll.zig"));
    std.testing.refAllDecls(@import("input/aura.zig"));
    std.testing.refAllDecls(@import("capture/cursor_capture.zig"));
}
