const std = @import("std");
const native = @import("../platform/native.zig");
const c = native.c;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const Args = @import("../cli/args.zig").Args;
const sessions = @import("../runtime/sessions.zig");
const geometry = @import("../core/geometry.zig");
const ipc = @import("../platform/ipc.zig");
const protocol = @import("protocol.zig");

fn monitor(rt: *Runtime, name: ?[]const u8) !geometry.Monitor {
    for (try rt.json([]geometry.Monitor, try rt.query("monitors"))) |m| {
        if (if (name) |n| std.mem.eql(u8, m.name, n) else m.focused) {
            if (m.disabled or !m.dpmsStatus) return error.MonitorUnavailable;
            _ = try m.rect();
            return m;
        }
    }
    return error.MonitorNotFound;
}

fn rule(rt: *Runtime, id: []const u8, key: []const u8, value: []const u8) !void {
    const response = try ipc.request(rt.a, rt.socket, try std.fmt.allocPrint(rt.a, "/keyword windowrule[{s}]:{s} {s}", .{ id, key, value }));
    if (!std.mem.eql(u8, std.mem.trim(u8, response, " \r\n"), "ok")) return error.PreviewWindowRuleFailed;
}

fn disableRule(rt: *Runtime, id: []const u8, lua: bool) void {
    // SIGTERM cancels normal IPC, but must not skip our own rule teardown.
    // Give cleanup a separate, short budget even if the compositor is stuck.
    const command = (if (lua)
        std.fmt.allocPrint(rt.a, "/eval if _G['{s}'] then _G['{s}']:set_enabled(false); _G['{s}']=nil end", .{ id, id, id })
    else
        std.fmt.allocPrint(rt.a, "/keyword windowrule[{s}]:enable 0", .{id})) catch return;
    _ = ipc.requestWithOptions(rt.a, rt.socket, command, .{ .timeout_ms = 250, .cancellable = false }) catch {};
}

fn stopViewer(rt: *Runtime, child: *std.process.Child, pidfd: c_int) !void {
    // The pidfd belongs only to our unreaped viewer, never a user's app.
    if (c.syscall(c.SYS_pidfd_send_signal, pidfd, c.SIGTERM, @as(?*anyopaque, null), @as(c_uint, 0)) < 0 and c.__errno_location().* != c.ESRCH)
        return error.ProcessMonitorFailed;
    const deadline = native.nowMs() + 750;
    while (native.nowMs() < deadline) {
        var pfd = c.struct_pollfd{ .fd = pidfd, .events = c.POLLIN, .revents = 0 };
        const ready = c.poll(&pfd, 1, 25);
        if (ready < 0 and c.__errno_location().* != c.EINTR) return error.ProcessMonitorFailed;
        if (ready > 0) {
            _ = try child.wait(rt.io);
            return;
        }
    }
    // A viewer ignoring TERM must not strand its parent or the window rules.
    @import("../platform/child_process.zig").terminate(child, rt.io);
}

/// The GTK process inherits the HOST environment. Only short-lived workers
/// route to the source, and each one checks the originally selected instance.
pub fn launch(host: *Runtime, opt: Args) !void {
    var source = host.*;
    try sessions.route(&source, opt.session);
    if (std.mem.eql(u8, source.instance, host.instance)) return error.PreviewManagedSessionRequired;
    try source.unlocked();
    const output = try monitor(&source, opt.monitor);
    try host.validateDisplay();
    try host.unlocked();
    const status = try host.json(struct { configProvider: []const u8 }, try host.query("status"));
    const lua = std.mem.eql(u8, status.configProvider, "lua");
    if (!lua and !std.mem.eql(u8, status.configProvider, "hyprlang")) return error.UnsupportedConfigProvider;

    var executable: [4096]u8 = undefined;
    const count = c.readlink("/proc/self/exe", &executable, executable.len);
    if (count <= 0 or count == executable.len) return error.PreviewHelperMissing;
    const cli = executable[0..@intCast(count)];
    const helper = try std.fmt.allocPrintSentinel(host.a, "{s}/hyprhand-pip", .{std.fs.path.dirname(cli).?}, 0);
    if (c.access(helper, c.X_OK) != 0) return error.PreviewHelperMissing;
    const id = try std.fmt.allocPrint(host.a, "hyprhand-pip-{d}", .{c.getpid()});
    // Set the match before any effects. Disable on exit, including partial
    // setup failure. No configuration files, reload, or unrelated rules touched.
    defer disableRule(host, id, lua);
    if (lua) {
        // Only the internally generated decimal PID is interpolated. Session
        // names, window titles and all other external text are never Lua code.
        const command = try std.fmt.allocPrint(host.a, "/eval _G['{s}']=hl.window_rule({{name='{s}',match={{class='^{s}$'}},float=true,pin=true,no_initial_focus=true,no_follow_mouse=true,border_size=0,rounding=0,no_shadow=true,opacity='1 override 1 override',size='640 360'}})", .{ id, id, id });
        const reply = try ipc.request(host.a, host.socket, command);
        if (!std.mem.eql(u8, std.mem.trim(u8, reply, " \r\n"), "ok")) return error.PreviewWindowRuleFailed;
    } else {
        try rule(host, id, "match:class", try std.fmt.allocPrint(host.a, "^{s}$", .{id}));
        try rule(host, id, "float", "on");
        try rule(host, id, "pin", "on");
        try rule(host, id, "no_initial_focus", "on");
        try rule(host, id, "no_follow_mouse", "on");
        try rule(host, id, "border_size", "0");
        try rule(host, id, "rounding", "0");
        try rule(host, id, "no_shadow", "on");
        try rule(host, id, "opacity", "1 override 1 override");
        try rule(host, id, "size", "640 360");
        try rule(host, id, "enable", "1");
    }

    var env = try host.env.clone(host.a);
    try env.put("GDK_BACKEND", "wayland");
    // GTK uses this per-process application class; no shared global settings.
    try env.put("HYPRHAND_PIP_APP_ID", id);
    var child = try std.process.spawn(host.io, .{
        .argv = &.{ helper, cli, opt.session, source.instance, output.name, try std.fmt.allocPrint(host.a, "{d}", .{opt.fps}) },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer @import("../platform/child_process.zig").terminate(&child, host.io);
    const pidfd: c_int = @intCast(c.syscall(c.SYS_pidfd_open, child.id.?, @as(c_uint, 0)));
    if (pidfd < 0) return error.ProcessMonitorFailed;
    defer _ = c.close(pidfd);
    try host.emit(.{ .ok = true, .event = "preview_started", .session_id = opt.session, .pid = child.id.?, .read_only = true, .fps = opt.fps });
    while (true) {
        native.checkCancelled() catch {
            try stopViewer(host, &child, pidfd);
            return;
        };
        var pfd = c.struct_pollfd{ .fd = pidfd, .events = c.POLLIN, .revents = 0 };
        const ready = c.poll(&pfd, 1, 50);
        if (ready < 0 and c.__errno_location().* != c.EINTR) return error.ProcessMonitorFailed;
        if (ready > 0) break;
    }
    const term = try child.wait(host.io);
    if (term != .exited or term.exited != 0) return error.PreviewViewerFailed;
}

fn capture(rt: *Runtime, argv: []const []const u8) ![]const u8 {
    var pipe: [2]c_int = undefined;
    if (c.pipe2(&pipe, c.O_CLOEXEC) < 0) return error.PreviewBufferFailed;
    defer _ = c.close(pipe[0]);
    defer if (pipe[1] >= 0) {
        _ = c.close(pipe[1]);
    };
    if (c.fcntl(pipe[0], c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) return error.PreviewBufferFailed;
    var child = try std.process.spawn(rt.io, .{
        .argv = argv,
        .environ_map = rt.env,
        .stdin = .ignore,
        .stdout = .{ .file = .{ .handle = pipe[1], .flags = .{ .nonblocking = false } } },
        .stderr = .ignore,
    });
    defer @import("../platform/child_process.zig").terminate(&child, rt.io);
    _ = c.close(pipe[1]);
    pipe[1] = -1;
    const pidfd: c_int = @intCast(c.syscall(c.SYS_pidfd_open, child.id.?, @as(c_uint, 0)));
    if (pidfd < 0) return error.ProcessMonitorFailed;
    defer _ = c.close(pidfd);
    const deadline = native.nowMs() + 1500;
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(rt.a);
    // Drain incrementally with a hard cap, instead of allowing a helper to
    // grow a memfd arbitrarily before validating its final size.
    while (true) {
        try native.checkCancelled();
        if (native.nowMs() >= deadline) return error.HelperTimeout;
        var chunk: [8192]u8 = undefined;
        const count = c.read(pipe[0], &chunk, chunk.len);
        if (count == 0) break;
        if (count > 0) {
            const size: usize = @intCast(count);
            if (size > protocol.max_bytes - bytes.items.len) return error.InvalidScreenshot;
            try bytes.appendSlice(rt.a, chunk[0..size]);
            continue;
        }
        if (c.__errno_location().* == c.EINTR) continue;
        if (c.__errno_location().* != c.EAGAIN) return error.PreviewBufferFailed;
        var readable = c.struct_pollfd{ .fd = pipe[0], .events = c.POLLIN, .revents = 0 };
        if (c.poll(&readable, 1, 25) < 0 and c.__errno_location().* != c.EINTR) return error.PreviewBufferFailed;
    }
    while (true) {
        try native.checkCancelled();
        if (native.nowMs() >= deadline) return error.HelperTimeout;
        var pfd = c.struct_pollfd{ .fd = pidfd, .events = c.POLLIN, .revents = 0 };
        const ready = c.poll(&pfd, 1, 25);
        if (ready < 0 and c.__errno_location().* != c.EINTR) return error.ProcessMonitorFailed;
        if (ready > 0) break;
    }
    const term = try child.wait(rt.io);
    if (term != .exited or term.exited != 0) return error.HelperFailed;
    return bytes.toOwnedSlice(rt.a);
}

const Frame = struct { header: [protocol.header_len]u8, png: []const u8 };

fn frame(rt: *Runtime, opt: Args) !Frame {
    if (std.mem.eql(u8, rt.session_id, "host")) return error.PreviewManagedSessionRequired;
    if (!std.mem.eql(u8, rt.instance, opt.expected_instance.?)) return error.PreviewIdentityMismatch;
    try rt.prepare();
    try rt.validateDisplay();
    try rt.unlocked();
    const output = try monitor(rt, opt.monitor);
    const rect = try output.rect();
    const scale = @min(1.0, @min(960.0 / rect.width, 540.0 / rect.height));
    const started = native.nowMs();
    const png = try capture(rt, &.{ "grim", "-c", "-t", "png", "-l", "1", "-s", try std.fmt.allocPrint(rt.a, "{d}", .{scale}), "-o", output.name, "-" });
    try rt.unlocked();
    try protocol.validatePng(png);
    const enabled = if (rt.token()) |_| true else |err| switch (err) {
        error.ControlStopped => false,
        else => return err,
    };
    return .{ .header = protocol.header(started, enabled), .png = png };
}

pub fn worker(rt: *Runtime, opt: Args) !void {
    if (opt.command == ._preview_stop) {
        if (std.mem.eql(u8, rt.session_id, "host")) return error.PreviewManagedSessionRequired;
        if (!std.mem.eql(u8, rt.instance, opt.expected_instance.?)) return error.PreviewIdentityMismatch;
        return rt.stop();
    }
    const result = try frame(rt, opt);
    try std.Io.File.stdout().writeStreamingAll(rt.io, &result.header);
    try std.Io.File.stdout().writeStreamingAll(rt.io, result.png);
}

fn writeStream(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try native.checkCancelled();
        const n = c.write(c.STDOUT_FILENO, bytes.ptr + offset, bytes.len - offset);
        if (n > 0) {
            offset += @intCast(n);
            continue;
        }
        if (n < 0 and c.__errno_location().* == c.EINTR) continue;
        if (n >= 0 or c.__errno_location().* != c.EAGAIN) return error.PreviewStreamClosed;
        var pfd = c.struct_pollfd{ .fd = c.STDOUT_FILENO, .events = c.POLLOUT, .revents = 0 };
        if (c.poll(&pfd, 1, 25) < 0 and c.__errno_location().* != c.EINTR) return error.PreviewStreamClosed;
    }
}

/// Demand-driven, one bounded response per 'F'. No unsolicited capture queue.
/// Re-route from the original owner environment each frame so a replaced or
/// destroyed session never inherits a persistent worker's authorization.
pub fn stream(owner: *Runtime, opt: Args) !void {
    if (std.mem.eql(u8, opt.session, "host")) return error.PreviewManagedSessionRequired;
    const flags = c.fcntl(c.STDOUT_FILENO, c.F_GETFL);
    if (flags < 0 or c.fcntl(c.STDOUT_FILENO, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.PreviewBufferFailed;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    while (true) {
        native.clearCommandLimit();
        const idle_deadline = native.nowMs() + 30_000;
        while (true) {
            try native.checkCancelled();
            if (native.nowMs() >= idle_deadline) return;
            var pfd = c.struct_pollfd{ .fd = c.STDIN_FILENO, .events = c.POLLIN, .revents = 0 };
            const ready = c.poll(&pfd, 1, 50);
            if (ready < 0 and c.__errno_location().* != c.EINTR) return error.PreviewStreamClosed;
            if (ready <= 0) continue;
            var request: u8 = 0;
            const n = c.read(c.STDIN_FILENO, &request, 1);
            if (n < 0 and c.__errno_location().* == c.EINTR) continue;
            if (n == 0) return;
            if (n != 1 or request != 'F') return error.InvalidPreviewRequest;
            break;
        }
        native.limitCommand(2000, error.HelperTimeout);
        defer _ = arena.reset(.{ .retain_with_limit = 4 * 1024 * 1024 });
        var source = owner.*;
        source.a = arena.allocator();
        try sessions.route(&source, opt.session);
        const result = try frame(&source, opt);
        // Recheck identity after capture as well, before publishing any bytes.
        var current = owner.*;
        current.a = arena.allocator();
        try sessions.route(&current, opt.session);
        if (!std.mem.eql(u8, current.instance, opt.expected_instance.?)) return error.PreviewIdentityMismatch;
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(result.header.len + result.png.len), .little);
        try writeStream(&length);
        try writeStream(&result.header);
        try writeStream(result.png);
    }
}
