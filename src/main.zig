const std = @import("std");
const args = @import("cli/args.zig");
const help = @import("cli/help.zig").text;
const version = @import("version.zig");
const eq = @import("core/text.zig").eq;
const native = @import("platform/native.zig");
const c = native.c;
const Runtime = @import("runtime/runtime.zig").Runtime;
const ConfigProvider = @import("runtime/runtime.zig").ConfigProvider;
const operations = @import("runtime/operations.zig");
const sessions = @import("runtime/sessions.zig");
const wait = @import("runtime/wait.zig");
const actions = @import("input/actions.zig");
const Pointer = @import("input/pointer.zig").Pointer;
const Keyboard = @import("input/keyboard.zig").Keyboard;
const observation = @import("capture/observation.zig");
const cursor_capture = @import("capture/cursor_capture.zig");
const accessibility = @import("accessibility/tree.zig");
const preview = @import("preview/controller.zig");
const takeover = @import("preview/takeover.zig");

/// Read-only prerequisite and protocol probes. Nothing here sends input,
/// captures, or starts a compositor.
const Doctor = struct {
    display_matches: bool,
    pointer_available: bool,
    keyboard_available: bool,
    grim: bool,
    wtype: bool,
    wl_copy: bool,
    xdotool: bool,
    hyprland: bool,
    dbus_daemon: bool,
    registry: bool,
    bus_configured: bool,
    pidfd_available: bool,
    xkb_data: bool,
    enabled: bool,

    fn probe(runtime: *Runtime) !Doctor {
        var pointer: Pointer = undefined;
        const pointer_available = blk: {
            pointer.init(try runtime.display_path()) catch break :blk false;
            pointer.deinit();
            break :blk true;
        };

        var keyboard: Keyboard = undefined;
        const keyboard_available = blk: {
            keyboard.init(try runtime.display_path()) catch break :blk false;
            keyboard.deinit();
            break :blk true;
        };

        const pidfd: c_int = @intCast(
            c.syscall(c.SYS_pidfd_open, c.getpid(), @as(c_uint, 0)),
        );
        if (pidfd >= 0) _ = c.close(pidfd);

        return .{
            .display_matches = if (runtime.validate_display()) true else |_| false,
            .pointer_available = pointer_available,
            .keyboard_available = keyboard_available,
            .grim = try runtime.executable("grim"),
            .wtype = try runtime.executable("wtype"),
            .wl_copy = try runtime.executable("wl-copy"),
            .xdotool = try runtime.executable("xdotool"),
            .hyprland = try runtime.executable("Hyprland"),
            .dbus_daemon = try runtime.executable("dbus-daemon"),
            .registry = c.access("/usr/lib/at-spi2-registryd", c.X_OK) == 0 or
                c.access("/usr/libexec/at-spi2-registryd", c.X_OK) == 0,
            .bus_configured = if (runtime.env.get("DBUS_SESSION_BUS_ADDRESS")) |address|
                address.len != 0
            else
                false,
            .pidfd_available = pidfd >= 0,
            .xkb_data = host_keymap_compiles(),
            .enabled = if (runtime.token()) |_| true else |_| false,
        };
    }

    /// The `dependencies` object of the doctor report; field names are output.
    const Dependencies = struct {
        grim: bool,
        wtype: bool,
        wl_copy: bool,
        xdotool: bool,
        Hyprland: bool,
        dbus_daemon: bool,
        at_spi_registry: bool,
        dbus_address_configured: bool,
        xkb_data: bool,
        pidfd: bool,
    };

    fn dependencies(self: Doctor) Dependencies {
        return .{
            .grim = self.grim,
            .wtype = self.wtype,
            .wl_copy = self.wl_copy,
            .xdotool = self.xdotool,
            .Hyprland = self.hyprland,
            .dbus_daemon = self.dbus_daemon,
            .at_spi_registry = self.registry,
            .dbus_address_configured = self.bus_configured,
            .xkb_data = self.xkb_data,
            .pidfd = self.pidfd_available,
        };
    }

    fn host_keymap_compiles() bool {
        const context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return false;
        defer c.xkb_context_unref(context);

        const keymap = c.xkb_keymap_new_from_names(
            context,
            null,
            c.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse return false;
        c.xkb_keymap_unref(keymap);
        return true;
    }
};

const doctor_accessibility_note =
    "Bus configuration does not prove AT-SPI service availability or application support.";
const doctor_verification_note =
    "Read-only prerequisite/protocol probes; no input, capture, accessibility request " ++
    "or compositor startup performed. operation_verified=false means not tested, " ++
    "not a demonstrated failure.";

fn doctor(runtime: *Runtime) !void {
    const hyprland_version = try runtime.query_json(std.json.Value, "version");
    const provider = try runtime.config_provider_name();
    const provider_supported = std.meta.stringToEnum(ConfigProvider, provider) != null;
    const probe = try Doctor.probe(runtime);

    const capture = probe.grim and probe.display_matches;
    const managed_sessions = probe.hyprland and probe.dbus_daemon and
        probe.pidfd_available and probe.display_matches;

    try runtime.emit(.{
        .ok = true,
        .version = version.string,
        .hyprland = hyprland_version,
        .config_provider = provider,
        .session_id = runtime.session_id,
        .instance = runtime.instance,
        .wayland_display = runtime.display,
        .display_matches = probe.display_matches,
        .dependencies = probe.dependencies(),
        .capabilities = .{
            .state = true,
            .capture = capture,
            .virtual_pointer = probe.pointer_available and probe.display_matches,
            .virtual_keyboard = probe.keyboard_available and probe.display_matches,
            .text_helper_installed = probe.wtype,
            // The clipboard backend never touches the host clipboard.
            .clipboard_paste = probe.wl_copy and !runtime.is_host(),
            .dispatch = provider_supported,
            .managed_sessions = managed_sessions,
            .accessibility = probe.bus_configured,
        },
        .checks = .{
            .capture = .{
                .implemented = true,
                .prerequisites_available = capture,
                .operation_verified = false,
            },
            .managed_sessions = .{
                .implemented = true,
                .prerequisites_available = managed_sessions,
                .operation_verified = false,
                .headless_gpu_verified = false,
            },
            .accessibility = .{
                .implemented = true,
                .prerequisites_available = probe.bus_configured,
                .operation_verified = false,
                .note = doctor_accessibility_note,
            },
            .input = .{
                .pointer_protocol_available = probe.pointer_available,
                .keyboard_protocol_available = probe.keyboard_available,
                .operation_verified = false,
            },
        },
        .verification_note = doctor_verification_note,
        .control_enabled = probe.enabled,
        .shared_cursor = runtime.is_host(),
        .state_directory = runtime.directory,
    });
}

fn state(runtime: *Runtime) !void {
    try runtime.emit(.{
        .ok = true,
        .session_id = runtime.session_id,
        .monitors = try runtime.query_json(std.json.Value, "monitors"),
        .windows = try runtime.query_json(std.json.Value, "clients"),
        .workspaces = try runtime.query_json(std.json.Value, "workspaces"),
        .active_window = try runtime.query_json(std.json.Value, "activewindow"),
        .cursor = try runtime.query_json(std.json.Value, "cursorpos"),
        .control_enabled = try state_control_enabled(runtime),
        .human_takeover = try runtime.takeover_active(),
    });
}

fn state_control_enabled(runtime: *Runtime) !bool {
    _ = runtime.token() catch |err| switch (err) {
        error.ControlStopped => return false,
        else => return err,
    };
    return true;
}

/// Runs one mutating command with an audit-log entry before and after it.
fn audited(runtime: *Runtime, arguments: args.Args) !void {
    const action = @tagName(arguments.command);
    try operations.log(runtime, action, if (arguments.dry_run) "dry_run" else "started");

    actions.run(runtime, arguments) catch |err| {
        operations.log(runtime, action, @errorName(err)) catch {};
        return err;
    };

    operations.log(runtime, action, "completed") catch {};
}

fn execute(init: std.process.Init, arguments: args.Args) !void {
    execute_limit_command(arguments);
    if (arguments.is_preview_worker()) try execute_follow_parent();

    var runtime = try Runtime.init(init);
    switch (arguments.command) {
        .session => return sessions.command(&runtime, arguments),
        .sessions => return sessions.list(&runtime),
        .preview => return preview.launch(&runtime, arguments),
        ._preview_stream => return preview.stream(&runtime, arguments),
        ._preview_input => return takeover.run(&runtime, arguments),
        else => {},
    }

    try sessions.route(&runtime, arguments.session);
    execute_routed(&runtime, arguments) catch |err| {
        return sessions.explain_failure(&runtime, err);
    };
}

fn execute_routed(runtime: *Runtime, arguments: args.Args) !void {
    if (arguments.mutates()) return audited(runtime, arguments);

    switch (arguments.command) {
        .doctor => try doctor(runtime),
        .state => try state(runtime),
        .monitors => try execute_query(runtime, "monitors"),
        .windows => try execute_query(runtime, "clients"),
        .workspaces => try execute_query(runtime, "workspaces"),
        .observe => try observation.observe_with_retry(runtime, arguments),
        .enable => try runtime.enable(arguments.indicator == .outline),
        .stop => try runtime.stop(),
        .wait => try wait.run(runtime, arguments),
        .events => try operations.events(runtime, arguments),
        .logs => try operations.logs(runtime, arguments),
        .gc => try operations.collect(runtime, arguments, true),
        .accessibility => try accessibility.tree(runtime, arguments),
        ._a11y => try accessibility.worker(runtime, arguments),
        ._cursor_probe => try cursor_capture.probe(runtime),
        ._preview_frame, ._preview_stop => try preview.worker(runtime, arguments),
        else => return error.CommandNotImplemented,
    }
}

fn execute_limit_command(arguments: args.Args) void {
    // Long-lived viewers/events and session lifecycle use their own budgets.
    // Ordinary composite commands share one budget across all IPC and helpers.
    switch (arguments.command) {
        .wait => native.limit_command(arguments.timeout_ms, error.WaitTimeout),
        .doctor,
        .state,
        .monitors,
        .windows,
        .workspaces,
        .observe,
        => native.limit_command(10_000, error.CommandTimeout),
        .type => native.limit_command(300_000, error.CommandTimeout),
        .focus,
        .workspace,
        .key,
        .move,
        .click,
        .doubleclick,
        .drag,
        .scroll,
        => native.limit_command(30_000, error.CommandTimeout),
        ._preview_frame => native.limit_command(2000, error.HelperTimeout),
        else => {},
    }
}

fn execute_follow_parent() !void {
    // If a viewer is killed unexpectedly, cancel its worker and let the
    // existing child cleanup reap grim. No detached capture loop remains.
    const unused: c_ulong = 0;
    if (c.prctl(c.PR_SET_PDEATHSIG, c.SIGTERM, unused, unused, unused) < 0) {
        return error.Cancelled;
    }
    // A viewer that exited before the death signal was armed left us adopted by init.
    if (c.getppid() == 1) return error.Cancelled;
}

fn execute_query(runtime: *Runtime, command: []const u8) !void {
    try runtime.emit(.{
        .ok = true,
        .session_id = runtime.session_id,
        .data = try runtime.query_json(std.json.Value, command),
    });
}

/// Hints for control that a human holds through the preview's takeover.
fn hint_takeover(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ControlStopped => "Input is disabled. If state reports human_takeover, a human " ++
            "controls the session from the preview: wait until it is false. " ++
            "Otherwise run hyprhand enable --session NAME; launch, focus and workspace " ++
            "count as input.",
        error.HumanTakeoverActive => "A human took over this session from the preview. " ++
            "Wait until hyprhand state reports human_takeover false; Return re-enables control.",
        error.TakeoverBusy => "Another preview already holds a takeover of this session.",
        error.TakeoverParentRejected => "Takeover input is reserved for the hyprhand-pip viewer " ++
            "beside this binary. Agents use enable and the guarded input commands.",
        else => null,
    };
}

/// Managed-session lifecycle hints, kept apart from the general table.
fn hint_session(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NestedWindowHidden => "The nested session's window is not shown on the host " ++
            "(another workspace, hidden or screen off), so its compositor renders nothing. " ++
            "Ask the user to move it to a visible workspace; hyprhand never moves it. " ++
            "Inspect state before retrying; partial input may have been delivered.",
        error.NestedWindowClosed => "The nested session's host window was closed; its " ++
            "compositor has no output left. Run hyprhand session destroy NAME, then create it.",
        error.SessionDead => "A session with this name died (compositor exited or nested " ++
            "window closed) but still holds processes. Run hyprhand session destroy NAME first.",
        error.SessionExists => "A running session already uses this name. " ++
            "Use it, or destroy it first.",
        error.SessionNotRunning => "The session is destroyed or its compositor exited. " ++
            "Check hyprhand sessions; destroy and recreate it.",
        error.SessionStopTimeout => "Some session processes did not exit after SIGKILL " ++
            "(uninterruptible sleep). Run hyprhand session destroy NAME again.",
        else => null,
    };
}

fn hint(err: anyerror) []const u8 {
    if (hint_takeover(err)) |text| return text;
    if (hint_session(err)) |text| return text;
    return switch (err) {
        error.PreviewHelperMissing => "Build the optional viewer with zig build pip; " ++
            "keep hyprhand-pip beside hyprhand.",
        error.PreviewManagedSessionRequired => "Preview requires an explicit managed session, " ++
            "never host.",
        error.PreviewIdentityMismatch => "The original preview session ended or changed. " ++
            "Close the viewer and explicitly open a new one.",
        error.StaleObservation => "The frame expired or desktop layout/focus changed. " ++
            "Observe again.",
        error.WindowNotFocused => "Focus the target window first, then verify it before typing.",
        error.CursorPositionMismatch => "Cursor diverged from the expected path: " ++
            "human movement, pointer locking/recentering or compositor constraints " ++
            "are possible. Input was aborted; observe again. No safety tolerance was relaxed.",
        error.PointerOutsideTarget => "The pointer start/click coordinate is outside --window. " ++
            "Observe the target window and choose coordinates inside it.",
        error.InvalidScrollMode => "Use --scroll-mode auto, wheel or continuous. " ++
            "Duration controls pacing separately.",
        error.ContinuousScrollUnavailable => "XWayland fallback only supports wheel events. " ++
            "Choose --scroll-mode wheel (optionally paced). " ++
            "No continuous-to-wheel substitution was performed.",
        error.SessionRequired => "Input commands require an explicit --session NAME.",
        error.WaitTimeout => "The requested condition did not become true before its deadline.",
        error.CommandTimeout => "The command exceeded its shared time budget. " ++
            "Inspect state before retrying; partial input may have been delivered.",
        error.Cancelled => "Action cancelled. Native owned inputs were released.",
        error.NativeCaptureUnavailable => "Capture uses grim in this release. " ++
            "Use --backend helper or auto.",
        error.AuraUnavailable,
        error.AuraBufferUnavailable,
        error.AuraGeometryUnsupported,
        => "The cursor halo is unavailable on this output/compositor. " ++
            "Inspect state; use --no-aura explicitly to run without the indicator.",
        error.CursorCaptureUnavailable,
        error.CursorCaptureUnsupported,
        => "The compositor did not provide a usable cursor capture session. " ++
            "No theme or desktop configuration was changed.",
        error.ClipboardHelperMissing => "--backend clipboard needs wl-copy " ++
            "(wl-clipboard). Install it or use --backend auto. Nothing was typed.",
        error.ClipboardManagedSessionRequired => "--backend clipboard requires a managed " ++
            "--session; the host clipboard belongs to the human.",
        error.XWaylandHelperMissing => "This is an XWayland window. " ++
            "Install xdotool for X11 keyboard input.",
        error.X11TargetMismatch => "The focused X11 window does not match the requested " ++
            "Hyprland client. Check DISPLAY and focus.",
        else => hint_setup(err),
    };
}

/// Hints for installation, session lifecycle and optional components.
fn hint_setup(err: anyerror) []const u8 {
    return switch (err) {
        error.UnsupportedConfigProvider => "Dispatch supports Hyprlang and Lua providers only.",
        error.FileNotFound => "A helper or required file is missing. " ++
            "Check hyprhand doctor and install grim/wtype.",
        error.ControlBusy => "Another hyprhand input action is running.",
        error.LogBusy => "Another hyprhand command is writing the audit log. Retry.",
        error.InvalidHeadlessBridge => "Use an absolute, trusted regular library path " ++
            "without spaces/colons, not writable by other users, " ++
            "only with session create (not --nested).",
        error.OutlinePluginUnavailable => "The optional hyprhand-outline plugin is not loaded " ++
            "or rejected activation. Input remains disabled. No plugin was auto-loaded.",
        error.OutlineRequiresHyprlang => "The experimental outline dispatcher currently " ++
            "requires Hyprlang. Input remains disabled.",
        error.HeadlessRenderUnavailable => "Headless GPU buffers failed (seen on NVIDIA). " ++
            "Build the format bridge (scripts/install.sh --with-bridge) and pass " ++
            "--headless-bridge PATH, or use --nested. See compositor.log; " ++
            "the failed compositor was stopped.",
        error.ProgramNotFound => "The program is not in the session PATH. Check its " ++
            "executable name (for example brave, not brave-browser).",
        error.MonitorNotFound => "--monitor names a monitor of the selected session " ++
            "(hyprhand monitors --session NAME). Place a preview with --host-monitor.",
        error.HostMonitorNotFound => "No host monitor has that name. " ++
            "List them with hyprhand monitors --session host.",
        error.InvalidMonitorName => "Use a monitor connector name such as DP-1 or HDMI-A-1.",
        error.SessionStartupFailed,
        error.SessionStartupTimeout,
        error.SessionConfigInvalid,
        => "Managed session failed and its processes were stopped. " ++
            "Inspect compositor.log in the named session directory.",
        else => "Run hyprhand --help for usage. No task outcome has been verified.",
    };
}

fn report(init: std.process.Init, err: anyerror) void {
    const message = std.json.Stringify.valueAlloc(
        init.arena.allocator(),
        .{ .ok = false, .err = .{ .code = @errorName(err), .message = hint(err) } },
        .{},
    ) catch return;
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

    const help_flag = argv.len == 2 and (eq(argv[1], "--help") or eq(argv[1], "-h"));
    if (argv.len == 1 or help_flag) {
        std.Io.File.stdout().writeStreamingAll(init.io, help) catch {};
        return;
    }
    if (argv.len == 2 and eq(argv[1], "--version")) {
        const version_line = "hyprhand " ++ version.string ++ "\n";
        std.Io.File.stdout().writeStreamingAll(init.io, version_line) catch {};
        return;
    }

    const arguments = args.parse(argv[1..]) catch |err| {
        report(init, err);
        std.process.exit(2);
    };
    execute(init, arguments) catch |err| {
        report(init, err);
        std.process.exit(1);
    };
}

test {
    _ = @import("core/geometry.zig");
    _ = @import("core/text.zig");
    _ = @import("cli/args.zig");
    _ = @import("runtime/operations.zig");
    _ = @import("preview/protocol.zig");
    _ = @import("preview/takeover_protocol.zig");
    _ = @import("preview/takeover.zig");
    _ = @import("preview/takeover_keys.zig");
    _ = @import("preview/cadence.zig");
    _ = @import("input/actions.zig");
    _ = @import("capture/observation.zig");
}

test {
    std.testing.refAllDecls(@import("input/motion.zig"));
    std.testing.refAllDecls(@import("input/keyboard.zig"));
    std.testing.refAllDecls(sessions);
    std.testing.refAllDecls(@import("input/scroll.zig"));
    std.testing.refAllDecls(@import("input/aura.zig"));
    std.testing.refAllDecls(cursor_capture);
}
