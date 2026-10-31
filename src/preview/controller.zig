const std = @import("std");
const native = @import("../platform/native.zig");
const c = native.c;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const args = @import("../cli/args.zig");
const Args = args.Args;
const sessions = @import("../runtime/sessions.zig");
const geometry = @import("../core/geometry.zig");
const ipc = @import("../platform/ipc.zig");
const child_process = @import("../platform/child_process.zig");
const protocol = @import("protocol.zig");
const eq = @import("../core/text.zig").eq;

fn monitor(runtime: *Runtime, name: ?[]const u8) !geometry.Monitor {
    for (try runtime.query_json([]geometry.Monitor, "monitors")) |candidate| {
        const selected = if (name) |wanted| eq(candidate.name, wanted) else candidate.focused;
        if (selected) {
            if (candidate.disabled) return error.MonitorUnavailable;
            if (!candidate.dpmsStatus) return error.MonitorUnavailable;
            _ = try candidate.rect();
            return candidate;
        }
    }
    return error.MonitorNotFound;
}

fn rule(runtime: *Runtime, id: []const u8, key: []const u8, value: []const u8) !void {
    const request = try std.fmt.allocPrint(
        runtime.allocator,
        "/keyword windowrule[{s}]:{s} {s}",
        .{ id, key, value },
    );
    try runtime.expect_ok(request, error.PreviewWindowRuleFailed);
}

fn disable_rule(runtime: *Runtime, id: []const u8, lua: bool) void {
    // SIGTERM cancels normal IPC, but must not skip our own rule teardown.
    // Give cleanup a separate, short budget even if the compositor is stuck.
    const command = (if (lua)
        std.fmt.allocPrint(
            runtime.allocator,
            "/eval if _G['{s}'] then _G['{s}']:set_enabled(false); _G['{s}']=nil end",
            .{ id, id, id },
        )
    else
        std.fmt.allocPrint(
            runtime.allocator,
            "/keyword windowrule[{s}]:enable 0",
            .{id},
        )) catch return;
    _ = ipc.request_with_options(
        runtime.allocator,
        runtime.socket,
        command,
        .{ .timeout_ms = 250, .cancellable = false },
    ) catch {};
}

fn stop_viewer(runtime: *Runtime, child: *std.process.Child, pidfd: c_int) !void {
    // The pidfd belongs only to our unreaped viewer, never a user's app.
    const signaled = c.syscall(
        c.SYS_pidfd_send_signal,
        pidfd,
        c.SIGTERM,
        @as(?*anyopaque, null),
        @as(c_uint, 0),
    );
    if (signaled < 0 and native.errno() != c.ESRCH) return error.ProcessMonitorFailed;

    const deadline = native.now_ms() + 750;
    while (native.now_ms() < deadline) {
        var poll_descriptor = c.struct_pollfd{ .fd = pidfd, .events = c.POLLIN, .revents = 0 };
        const ready = c.poll(&poll_descriptor, 1, 25);
        if (ready < 0 and native.errno() != c.EINTR) return error.ProcessMonitorFailed;
        if (ready > 0) {
            _ = try child.wait(runtime.io);
            return;
        }
    }
    // A viewer ignoring TERM must not strand its parent or the window rules.
    child_process.terminate(child, runtime.io);
}

fn launch_rules_lua(host: *Runtime, id: []const u8, host_monitor: ?[]const u8) !void {
    // Only the internally generated decimal PID and a host monitor name that
    // exists and passed `valid_output_name` are interpolated. Session names,
    // window titles and all other external text are never Lua code.
    std.debug.assert(host_monitor == null or args.valid_output_name(host_monitor.?));
    const placement = if (host_monitor) |name|
        try std.fmt.allocPrint(host.allocator, ",monitor='{s}'", .{name})
    else
        "";
    const command = try std.fmt.allocPrint(
        host.allocator,
        "/eval _G['{s}']=hl.window_rule({{name='{s}',match={{class='^{s}$'}}," ++
            "float=true,pin=true,no_initial_focus=true,no_follow_mouse=true," ++
            "border_size=0,rounding=0,no_shadow=true," ++
            "opacity='1 override 1 override',size='640 360'{s}}})",
        .{ id, id, id, placement },
    );
    try host.expect_ok(command, error.PreviewWindowRuleFailed);
}

fn launch_rules_hyprlang(host: *Runtime, id: []const u8, host_monitor: ?[]const u8) !void {
    const class_match = try std.fmt.allocPrint(host.allocator, "^{s}$", .{id});
    try rule(host, id, "match:class", class_match);
    try rule(host, id, "float", "on");
    try rule(host, id, "pin", "on");
    try rule(host, id, "no_initial_focus", "on");
    try rule(host, id, "no_follow_mouse", "on");
    try rule(host, id, "border_size", "0");
    try rule(host, id, "rounding", "0");
    try rule(host, id, "no_shadow", "on");
    try rule(host, id, "opacity", "1 override 1 override");
    try rule(host, id, "size", "640 360");
    if (host_monitor) |name| try rule(host, id, "monitor", name);
    try rule(host, id, "enable", "1");
}

fn launch_require_host_monitor(host: *Runtime, name: []const u8) !void {
    _ = monitor(host, name) catch |err| switch (err) {
        error.MonitorNotFound => return error.HostMonitorNotFound,
        else => return err,
    };
}

/// Resolves the CLI's own path into `executable` and the viewer next to it.
fn launch_helper_paths(
    host: *Runtime,
    executable: *[4096]u8,
) !struct { cli: []const u8, helper: [:0]u8 } {
    const count = c.readlink("/proc/self/exe", executable, executable.len);
    if (count <= 0) return error.PreviewHelperMissing;
    if (count == executable.len) return error.PreviewHelperMissing;

    const cli = executable[0..@intCast(count)];
    const helper = try std.fmt.allocPrintSentinel(
        host.allocator,
        "{s}/hyprhand-pip",
        .{std.fs.path.dirname(cli).?},
        0,
    );
    if (c.access(helper, c.X_OK) != 0) return error.PreviewHelperMissing;
    return .{ .cli = cli, .helper = helper };
}

/// The GTK process inherits the HOST environment. Only short-lived workers
/// route to the source, and each one checks the originally selected instance.
pub fn launch(host: *Runtime, arguments: Args) !void {
    var source = host.*;
    try sessions.route(&source, arguments.session);
    if (eq(source.instance, host.instance)) return error.PreviewManagedSessionRequired;
    try source.unlocked();
    const output = try monitor(&source, arguments.monitor);
    try host.validate_display();
    try host.unlocked();
    // Fail before any window rule exists if the requested host monitor is absent.
    if (arguments.host_monitor) |name| try launch_require_host_monitor(host, name);
    const provider = try host.config_provider() orelse return error.UnsupportedConfigProvider;
    const lua = provider == .lua;

    var executable: [4096]u8 = undefined;
    const paths = try launch_helper_paths(host, &executable);

    const id = try std.fmt.allocPrint(host.allocator, "hyprhand-pip-{d}", .{c.getpid()});
    // Set the match before any effects. Disable on exit, including partial
    // setup failure. No configuration files, reload, or unrelated rules touched.
    defer disable_rule(host, id, lua);
    if (lua) {
        try launch_rules_lua(host, id, arguments.host_monitor);
    } else {
        try launch_rules_hyprlang(host, id, arguments.host_monitor);
    }

    var environment = try host.env.clone(host.allocator);
    try environment.put("GDK_BACKEND", "wayland");
    // GTK uses this per-process application class; no shared global settings.
    try environment.put("HYPRHAND_PIP_APP_ID", id);
    const fps = try std.fmt.allocPrint(host.allocator, "{d}", .{arguments.fps});
    var child = try std.process.spawn(host.io, .{
        .argv = &.{ paths.helper, paths.cli, arguments.session, source.instance, output.name, fps },
        .environ_map = &environment,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child_process.terminate(&child, host.io);
    const pidfd: c_int = @intCast(c.syscall(c.SYS_pidfd_open, child.id.?, @as(c_uint, 0)));
    if (pidfd < 0) return error.ProcessMonitorFailed;
    defer _ = c.close(pidfd);

    try host.emit(.{
        .ok = true,
        .event = "preview_started",
        .session_id = arguments.session,
        .pid = child.id.?,
        .read_only = true,
        .fps = arguments.fps,
    });
    while (true) {
        native.check_cancelled() catch {
            try stop_viewer(host, &child, pidfd);
            return;
        };
        var poll_descriptor = c.struct_pollfd{ .fd = pidfd, .events = c.POLLIN, .revents = 0 };
        const ready = c.poll(&poll_descriptor, 1, 50);
        if (ready < 0 and native.errno() != c.EINTR) return error.ProcessMonitorFailed;
        if (ready > 0) break;
    }

    const termination = try child.wait(host.io);
    if (termination != .exited) return error.PreviewViewerFailed;
    if (termination.exited != 0) return error.PreviewViewerFailed;
}

fn capture(runtime: *Runtime, argv: []const []const u8) ![]const u8 {
    var pipe: [2]c_int = undefined;
    if (c.pipe2(&pipe, c.O_CLOEXEC) < 0) return error.PreviewBufferFailed;
    defer _ = c.close(pipe[0]);
    defer if (pipe[1] >= 0) {
        _ = c.close(pipe[1]);
    };
    if (c.fcntl(pipe[0], c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) return error.PreviewBufferFailed;

    var child = try std.process.spawn(runtime.io, .{
        .argv = argv,
        .environ_map = runtime.env,
        .stdin = .ignore,
        .stdout = .{ .file = .{ .handle = pipe[1], .flags = .{ .nonblocking = false } } },
        .stderr = .ignore,
    });
    defer child_process.terminate(&child, runtime.io);
    _ = c.close(pipe[1]);
    pipe[1] = -1;
    const pidfd: c_int = @intCast(c.syscall(c.SYS_pidfd_open, child.id.?, @as(c_uint, 0)));
    if (pidfd < 0) return error.ProcessMonitorFailed;
    defer _ = c.close(pidfd);

    const deadline = native.now_ms() + 1500;
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(runtime.allocator);
    // Drain incrementally with a hard cap, instead of allowing a helper to
    // grow a memfd arbitrarily before validating its final size.
    while (true) {
        try native.check_cancelled();
        if (native.now_ms() >= deadline) return error.HelperTimeout;
        var chunk: [8192]u8 = undefined;
        const count = c.read(pipe[0], &chunk, chunk.len);
        if (count == 0) break;
        if (count > 0) {
            const size: usize = @intCast(count);
            if (size > protocol.max_bytes - bytes.items.len) return error.InvalidScreenshot;
            try bytes.appendSlice(runtime.allocator, chunk[0..size]);
            continue;
        }
        if (native.errno() == c.EINTR) continue;
        if (native.errno() != c.EAGAIN) return error.PreviewBufferFailed;
        var readable = c.struct_pollfd{ .fd = pipe[0], .events = c.POLLIN, .revents = 0 };
        const polled = c.poll(&readable, 1, 25);
        if (polled < 0 and native.errno() != c.EINTR) return error.PreviewBufferFailed;
    }
    while (true) {
        try native.check_cancelled();
        if (native.now_ms() >= deadline) return error.HelperTimeout;
        var poll_descriptor = c.struct_pollfd{ .fd = pidfd, .events = c.POLLIN, .revents = 0 };
        const ready = c.poll(&poll_descriptor, 1, 25);
        if (ready < 0 and native.errno() != c.EINTR) return error.ProcessMonitorFailed;
        if (ready > 0) break;
    }

    const termination = try child.wait(runtime.io);
    if (termination != .exited) return error.HelperFailed;
    if (termination.exited != 0) return error.HelperFailed;
    return bytes.toOwnedSlice(runtime.allocator);
}

const Frame = struct { header: [protocol.header_len]u8, png: []const u8 };

fn require_expected_session(runtime: *Runtime, arguments: Args) !void {
    if (runtime.is_host()) return error.PreviewManagedSessionRequired;
    if (!eq(runtime.instance, arguments.expected_instance.?)) return error.PreviewIdentityMismatch;
}

fn frame(runtime: *Runtime, arguments: Args) !Frame {
    try require_expected_session(runtime, arguments);
    try runtime.prepare();
    try runtime.validate_display();
    try runtime.unlocked();
    const output = try monitor(runtime, arguments.monitor);
    const rect = try output.rect();
    const scale = @min(1.0, @min(960.0 / rect.width, 540.0 / rect.height));

    const started = native.now_ms();
    const scale_text = try std.fmt.allocPrint(runtime.allocator, "{d}", .{scale});
    const png = try capture(runtime, &.{
        "grim", "-c", "-t", "png", "-l", "1", "-s", scale_text, "-o", output.name, "-",
    });
    try runtime.unlocked();
    try protocol.validate_png(png);

    const enabled = if (runtime.token()) |_| true else |token_error| switch (token_error) {
        error.ControlStopped => false,
        else => return token_error,
    };
    return .{ .header = protocol.header(started, enabled), .png = png };
}

pub fn worker(runtime: *Runtime, arguments: Args) !void {
    if (arguments.command == ._preview_stop) {
        try require_expected_session(runtime, arguments);
        return runtime.stop();
    }
    const result = try frame(runtime, arguments);
    try std.Io.File.stdout().writeStreamingAll(runtime.io, &result.header);
    try std.Io.File.stdout().writeStreamingAll(runtime.io, result.png);
}

fn write_stream(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try native.check_cancelled();
        const written = c.write(c.STDOUT_FILENO, bytes.ptr + offset, bytes.len - offset);
        if (written > 0) {
            offset += @intCast(written);
            continue;
        }
        if (written < 0 and native.errno() == c.EINTR) continue;
        if (written >= 0) return error.PreviewStreamClosed;
        if (native.errno() != c.EAGAIN) return error.PreviewStreamClosed;

        var poll_descriptor = c.struct_pollfd{
            .fd = c.STDOUT_FILENO,
            .events = c.POLLOUT,
            .revents = 0,
        };
        const polled = c.poll(&poll_descriptor, 1, 25);
        if (polled < 0 and native.errno() != c.EINTR) return error.PreviewStreamClosed;
    }
}

/// Demand-driven, one bounded response per 'F'. No unsolicited capture queue.
/// Re-route from the original owner environment each frame so a replaced or
/// destroyed session never inherits a persistent worker's authorization.
pub fn stream(owner: *Runtime, arguments: Args) !void {
    if (eq(arguments.session, "host")) return error.PreviewManagedSessionRequired;
    const flags = c.fcntl(c.STDOUT_FILENO, c.F_GETFL);
    if (flags < 0) return error.PreviewBufferFailed;
    if (c.fcntl(c.STDOUT_FILENO, c.F_SETFL, flags | c.O_NONBLOCK) < 0) {
        return error.PreviewBufferFailed;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    while (true) {
        native.clear_command_limit();
        const idle_deadline = native.now_ms() + 30_000;
        while (true) {
            try native.check_cancelled();
            if (native.now_ms() >= idle_deadline) return;
            var poll_descriptor = c.struct_pollfd{
                .fd = c.STDIN_FILENO,
                .events = c.POLLIN,
                .revents = 0,
            };
            const ready = c.poll(&poll_descriptor, 1, 50);
            if (ready < 0 and native.errno() != c.EINTR) return error.PreviewStreamClosed;
            if (ready <= 0) continue;

            var request: u8 = 0;
            const count = c.read(c.STDIN_FILENO, &request, 1);
            if (count < 0 and native.errno() == c.EINTR) continue;
            if (count == 0) return;
            if (count != 1) return error.InvalidPreviewRequest;
            if (request != 'F') return error.InvalidPreviewRequest;
            break;
        }

        native.limit_command(2000, error.HelperTimeout);
        defer _ = arena.reset(.{ .retain_with_limit = 4 * 1024 * 1024 });
        var source = owner.scratch(arena.allocator());
        try sessions.route(&source, arguments.session);
        const result = try frame(&source, arguments);
        // Recheck identity after capture as well, before publishing any bytes.
        var current = owner.scratch(arena.allocator());
        try sessions.route(&current, arguments.session);
        if (!eq(current.instance, arguments.expected_instance.?)) {
            return error.PreviewIdentityMismatch;
        }

        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(result.header.len + result.png.len), .little);
        try write_stream(&length);
        try write_stream(&result.header);
        try write_stream(result.png);
    }
}
