const std = @import("std");
const assert = std.debug.assert;
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
const geometry = @import("core/geometry.zig");
const delivery = @import("runtime/delivery.zig");
const cursor_capture = @import("capture/cursor_capture.zig");
const accessibility = @import("accessibility/tree.zig");
const semantic = @import("accessibility/semantic.zig");
const sequence_steps = @import("cli/sequence.zig");
const refs = @import("accessibility/refs.zig");
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

fn state(runtime: *Runtime, arguments: args.Args) !void {
    if (arguments.compact) return state_compact(runtime);
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

/// One window in `--compact` output: what an agent needs to pick a target.
const CompactWindow = struct {
    address: []const u8,
    class: []const u8,
    title: []const u8,
    workspace: i64,
    monitor: i64,
    at: [2]i32,
    size: [2]i32,
    floating: bool,
    fullscreen: bool,
    xwayland: bool,
    visible: bool,
};

/// One output in `--compact` output, in logical desktop coordinates.
const CompactMonitor = struct {
    id: i64,
    name: []const u8,
    logical: geometry.Rect,
    scale: f64,
    focused: bool,
    workspace: i64,
};

fn compact_windows(runtime: *Runtime) ![]CompactWindow {
    const clients = try runtime.query_json([]observation.Client, "clients");
    const windows = try runtime.allocator.alloc(CompactWindow, clients.len);
    for (clients, windows) |client, *window| {
        window.* = .{
            .address = client.address,
            .class = client.class,
            .title = client.title,
            .workspace = client.workspace.id,
            .monitor = client.monitor,
            .at = client.at,
            .size = client.size,
            .floating = client.floating,
            .fullscreen = client.fullscreen != 0,
            .xwayland = client.xwayland,
            .visible = client.mapped and !client.hidden,
        };
    }
    return windows;
}

fn compact_monitors(runtime: *Runtime) ![]CompactMonitor {
    const monitors = try runtime.query_json([]geometry.Monitor, "monitors");
    const compact = try runtime.allocator.alloc(CompactMonitor, monitors.len);
    for (monitors, compact) |monitor, *entry| {
        entry.* = .{
            .id = monitor.id,
            .name = monitor.name,
            .logical = try monitor.rect(),
            .scale = monitor.scale,
            .focused = monitor.focused,
            .workspace = monitor.activeWorkspace.id,
        };
    }
    return compact;
}

/// `state --compact`: the same facts as `state`, a fraction of the tokens.
fn state_compact(runtime: *Runtime) !void {
    try runtime.emit(.{
        .ok = true,
        .session_id = runtime.session_id,
        .monitors = try compact_monitors(runtime),
        .windows = try compact_windows(runtime),
        .active_window = try runtime.active_window(),
        .cursor = try runtime.query_json(geometry.Point, "cursorpos"),
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

/// An input command followed by its `--then` report, in one response. If the
/// action fails, the error is reported as usual and nothing is captured.
fn audited_then(runtime: *Runtime, arguments: args.Args) !void {
    if (arguments.then == .none or arguments.dry_run) return audited(runtime, arguments);
    var sink: std.ArrayList(u8) = .empty;
    runtime.output = &sink;
    audited(runtime, arguments) catch |err| {
        runtime.output = null;
        return err;
    };
    runtime.output = null;

    var action = try runtime.parse_json(std.json.Value, sink.items);
    if (action != .object) return error.InvalidThen;
    try action.object.put(runtime.allocator, "then", try then_report(runtime, arguments));
    try runtime.emit(action);
}

/// What `--then` reports after an action. A failed report never hides the
/// action's success: it is returned as `{"ok":false,"err":…}`.
fn then_report(runtime: *Runtime, arguments: args.Args) !std.json.Value {
    assert(arguments.then != .none);
    const settle_until = native.now_ms() + arguments.settle_ms;
    while (native.now_ms() < settle_until) {
        try native.check_cancelled();
        native.sleep_ms(@intCast(@min(20, settle_until - native.now_ms())));
    }
    var sink: std.ArrayList(u8) = .empty;
    runtime.output = &sink;
    defer runtime.output = null;
    const outcome = switch (arguments.then) {
        .none => unreachable,
        .state => state_compact(runtime),
        .observe => observation.observe(runtime, try then_observe_args(runtime, arguments)),
        .accessibility => accessibility.tree(runtime, try then_tree_args(runtime, arguments)),
    };
    outcome catch |err| {
        const failure = .{ .ok = false, .err = .{ .code = @errorName(err), .message = hint(err) } };
        const encoded = try std.json.Stringify.valueAlloc(runtime.allocator, failure, .{});
        return runtime.parse_json(std.json.Value, encoded);
    };
    return runtime.parse_json(std.json.Value, sink.items);
}

/// The window an action worked on, when it names one.
fn then_window(runtime: *Runtime, arguments: args.Args) ?[]const u8 {
    if (arguments.window) |window| return window;
    if (arguments.focus_window) |window| return window;
    if (arguments.command == .act) {
        const ref = refs.Ref.parse(arguments.ref.?) catch return null;
        const snapshot = accessibility.load_snapshot(runtime, ref) catch return null;
        return snapshot.window;
    }
    return null;
}

/// `--then observe`: the action's own frame scope, compared with that frame,
/// otherwise the action's window, otherwise the focused output.
fn then_observe_args(runtime: *Runtime, arguments: args.Args) !args.Args {
    var observe_args = args.Args{
        .command = .observe,
        .session = arguments.session,
        .explicit_session = true,
        .max_edge = arguments.max_edge,
    };
    if (arguments.frame) |frame_id| {
        const frame = try observation.load_frame(runtime, frame_id);
        observe_args.since = frame_id;
        if (frame.window) |window| {
            observe_args.window = window;
        } else {
            observe_args.monitor = frame.monitor_id;
        }
        return observe_args;
    }
    observe_args.window = then_window(runtime, arguments);
    return observe_args;
}

/// `--then accessibility`: the operable elements of the action's window, or
/// of the focused window.
fn then_tree_args(runtime: *Runtime, arguments: args.Args) !args.Args {
    const window = then_window(runtime, arguments) orelse try runtime.active_window();
    return .{
        .command = .accessibility,
        .session = arguments.session,
        .explicit_session = true,
        .window = window,
        .interactive = true,
        .depth = 20,
        .limit = 1000,
    };
}

/// One step of a `sequence` as reported.
const StepReport = struct {
    index: usize,
    command: []const u8,
    ok: bool,
    result: ?std.json.Value = null,
    err: ?struct { code: []const u8, message: []const u8, detail: ?[]const u8 } = null,
    disposition: delivery.Disposition,
};

/// `sequence`: validated steps, run in order until the first failure.
fn sequence(runtime: *Runtime, arguments: args.Args) !void {
    const input = try native.read_stdin(runtime.allocator, 1024 * 1024);
    const steps = try sequence_steps.parse(
        runtime.allocator,
        input,
        arguments.session,
        arguments.dry_run,
    );
    var reports: std.ArrayList(StepReport) = .empty;
    var overall: delivery.Delivery = .not_delivered;
    var failed: ?usize = null;
    for (steps, 0..) |step, index| {
        const step_report = try sequence_step(runtime, step, index);
        overall = worse(overall, step_report.disposition.delivery);
        try reports.append(runtime.allocator, step_report);
        if (!step_report.ok) {
            failed = index;
            break;
        }
    }
    delivery.set(overall);
    const last = steps[reports.items.len - 1];
    var then_args = last;
    then_args.then = arguments.then;
    then_args.settle_ms = arguments.settle_ms;
    then_args.max_edge = arguments.max_edge;
    const run_then = arguments.then != .none and !arguments.dry_run;
    try runtime.emit(.{
        .ok = failed == null,
        .session_id = runtime.session_id,
        .dry_run = arguments.dry_run,
        .steps = reports.items,
        .completed = if (failed) |index| index else steps.len,
        .not_executed = steps.len - reports.items.len,
        .failed_step = failed,
        .disposition = delivery.disposition(),
        .then = if (run_then) try then_report(runtime, then_args) else null,
    });
    if (failed != null) return error.AlreadyReported;
}

/// Runs one step with its own budget, captures its response, and turns a
/// failure into a report instead of an exit.
fn sequence_step(runtime: *Runtime, step: args.Args, index: usize) !StepReport {
    delivery.set(.not_delivered);
    delivery.set_detail(null);
    execute_limit_command(step);
    defer native.clear_command_limit();
    var sink: std.ArrayList(u8) = .empty;
    runtime.output = &sink;
    defer runtime.output = null;

    const outcome = if (step.command == .wait) wait.run(runtime, step) else audited(runtime, step);
    outcome catch |err| return .{
        .index = index,
        .command = @tagName(step.command),
        .ok = false,
        .err = .{ .code = @errorName(err), .message = hint(err), .detail = delivery.detail() },
        .disposition = delivery.disposition(),
    };
    // Waits deliver nothing; actions report delivered_unverified or better.
    return .{
        .index = index,
        .command = @tagName(step.command),
        .ok = true,
        .result = try runtime.parse_json(std.json.Value, sink.items),
        .disposition = delivery.disposition(),
    };
}

/// The less certain of two deliveries, for a sequence's overall disposition.
fn worse(a: delivery.Delivery, b: delivery.Delivery) delivery.Delivery {
    const rank = struct {
        fn of(value: delivery.Delivery) u8 {
            return switch (value) {
                .not_delivered => 0,
                .delivered_verified => 1,
                .delivered_unverified => 2,
                .delivery_uncertain => 3,
            };
        }
    };
    return if (rank.of(b) > rank.of(a)) b else a;
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
    if (arguments.mutates()) return audited_then(runtime, arguments);

    switch (arguments.command) {
        .doctor => try doctor(runtime),
        .state => try state(runtime, arguments),
        .monitors => try execute_query(runtime, "monitors"),
        .windows => if (arguments.compact)
            try runtime.emit(.{
                .ok = true,
                .session_id = runtime.session_id,
                .data = try compact_windows(runtime),
            })
        else
            try execute_query(runtime, "clients"),
        .workspaces => try execute_query(runtime, "workspaces"),
        .observe => try observation.observe_with_retry(runtime, arguments),
        .sequence => try sequence(runtime, arguments),
        .cursor => try observation.cursor(runtime, arguments),
        .enable => try runtime.enable(arguments.indicator == .outline),
        .stop => try runtime.stop(),
        .wait => try wait.run(runtime, arguments),
        .events => try operations.events(runtime, arguments),
        .logs => try operations.logs(runtime, arguments),
        .gc => try operations.collect(runtime, arguments, true),
        .accessibility => try accessibility.tree(runtime, arguments),
        ._a11y => try accessibility.worker(runtime, arguments),
        ._a11y_act => try semantic.worker(runtime),
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
        .cursor,
        => native.limit_command(10_000, error.CommandTimeout),
        .type => native.limit_command(300_000, error.CommandTimeout),
        .act => native.limit_command(30_000, error.CommandTimeout),
        ._a11y_act => native.limit_command(20_000, error.CommandTimeout),
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

/// Hints for accessibility refs and semantic actions.
fn hint_semantic(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidRef, error.RefRequired => "Use a ref such as @1a2b3c4d:e3 from " ++
            "accessibility --window ADDRESS; bare e3 names no snapshot.",
        error.SnapshotNotFound, error.SnapshotExpired, error.StaleRef => "The element " ++
            "changed or disappeared, or its snapshot is gone or older than 5 minutes. " ++
            "Run accessibility --window ADDRESS again and use a new ref. Nothing was sent.",
        error.AuthenticationPrompt => "A sign-in, polkit, keyring or permission prompt " ++
            "is in front (err.detail names it). Never answer it: ask the human to handle " ++
            "it, through the preview's Take over in a managed session. Nothing was sent.",
        error.AmbiguousTarget => "Several elements share this identity. Use the pointer " ++
            "on the element's frame_point (accessibility --frame ID) instead. Nothing was sent.",
        error.ActionNotSupported => "The element offers no semantic call for this verb. " ++
            "Use the pointer or keyboard instead, e.g. click at its frame_point.",
        error.ActionRefused => "The application refused the semantic call. " ++
            "Use the pointer or keyboard instead.",
        error.ProtectedField => "Password fields are never written semantically. " ++
            "Hand the step to the human (preview Take over).",
        error.WriteIgnored => "The application accepted the write but its text did not " ++
            "change. Use focus + type instead.",
        error.ValueMismatch => "The value changed but does not match the request: " ++
            "inspect the element before retrying.",
        error.IndeterminateState => "The control is in a mixed state; inspect it and " ++
            "use the pointer.",
        error.AccessibilityTimeout => "The application did not answer in time; the call " ++
            "may have taken effect. Inspect the element before retrying.",
        error.InvalidActVerb => "Verbs: click, focus, set-value, toggle, check, uncheck, " ++
            "expand, collapse, select, scroll-to.",
        error.UnexpectedText => "--text is only for act set-value.",
        error.AccessibilityWindowNotFound, error.AccessibilityWindowAmbiguous => "The " ++
            "window's application exposes no matching accessibility window. Start " ++
            "Chromium with --force-renderer-accessibility and Qt with QT_ACCESSIBILITY=1.",
        else => null,
    };
}

/// Hints for observation scopes and the newer input options.
fn hint_options(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidObserveRegion => "A region needs --frame ID and all of --x --y " ++
            "--to-x --to-y, in that frame's pixels.",
        error.ConflictingObserveScope => "Use one of --monitor, --window or a --frame region.",
        error.WindowNotVisible => "The window is hidden, unmapped or on a workspace that " ++
            "is not shown. Focus or show it, then observe again.",
        error.CaptureExceedsMaxEdge => "The image would exceed --max-edge; nothing was " ++
            "returned. Report this: the scale is chosen to fit.",
        error.InvalidMaxEdge => "--max-edge accepts 64..16384 pixels.",
        error.InvalidModifiers => "Use modifiers ctrl, shift, alt, super/logo and altgr, " ++
            "joined by + and each once.",
        error.ModifiersUnavailableForX11 => "XWayland windows cannot receive held " ++
            "modifiers from the virtual keyboard. Use key chords instead.",
        error.InvalidClickCount => "--count accepts 1..3.",
        error.InvalidRepeat => "--repeat accepts 1..100.",
        else => null,
    };
}

fn hint(err: anyerror) []const u8 {
    if (hint_takeover(err)) |text| return text;
    if (hint_session(err)) |text| return text;
    if (hint_semantic(err)) |text| return text;
    if (hint_options(err)) |text| return text;
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
        error.SandboxUnavailable => "--sandbox needs bubblewrap (bwrap) and unprivileged " ++
            "user namespaces. Install bubblewrap or create the session without --sandbox.",
        error.OfflineRequiresSandbox => "--offline only applies to --sandbox sessions.",
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
        .{
            .ok = false,
            .err = .{
                .code = @errorName(err),
                .message = hint(err),
                .detail = delivery.detail(),
            },
            .disposition = delivery.disposition(),
        },
        .{ .emit_null_optional_fields = false },
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
        // `sequence` reports its own failures, step by step.
        if (err == error.AlreadyReported) std.process.exit(1);
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
    _ = @import("runtime/delivery.zig");
    _ = @import("runtime/auth_guard.zig");
    _ = @import("runtime/sandbox.zig");
    _ = @import("accessibility/refs.zig");
    _ = @import("accessibility/semantic.zig");
    _ = @import("cli/sequence.zig");
    _ = @import("capture/png.zig");
}

test {
    std.testing.refAllDecls(@import("input/motion.zig"));
    std.testing.refAllDecls(@import("input/keyboard.zig"));
    std.testing.refAllDecls(sessions);
    std.testing.refAllDecls(@import("input/scroll.zig"));
    std.testing.refAllDecls(@import("input/aura.zig"));
    std.testing.refAllDecls(cursor_capture);
}
