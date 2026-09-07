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

fn disableRule(rt: *Runtime, id: []const u8) void {
    // SIGTERM cancels normal IPC, but must not skip our own rule teardown.
    // Give cleanup a separate, short budget even if the compositor is stuck.
    const command = std.fmt.allocPrint(rt.a, "/keyword windowrule[{s}]:enable 0", .{id}) catch return;
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
    if (!std.mem.eql(u8, status.configProvider, "hyprlang")) return error.PreviewRequiresHyprlang;

    var executable: [4096]u8 = undefined;
    const count = c.readlink("/proc/self/exe", &executable, executable.len);
    if (count <= 0 or count == executable.len) return error.PreviewHelperMissing;
    const cli = executable[0..@intCast(count)];
    const helper = try std.fmt.allocPrintSentinel(host.a, "{s}/deskctl-pip", .{std.fs.path.dirname(cli).?}, 0);
    if (c.access(helper, c.X_OK) != 0) return error.PreviewHelperMissing;
    const id = try std.fmt.allocPrint(host.a, "deskctl-pip-{d}", .{c.getpid()});
    // Set the match before any effects. Disable on exit, including partial
    // setup failure. No configuration files, reload, or unrelated rules touched.
    try rule(host, id, "match:class", try std.fmt.allocPrint(host.a, "^{s}$", .{id}));
    defer disableRule(host, id);
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

    var env = try host.env.clone(host.a);
    try env.put("GDK_BACKEND", "wayland");
    // GTK uses this per-process application class; no shared global settings.
    try env.put("DESKCTL_PIP_APP_ID", id);
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

fn capture(rt: *Runtime, argv: []const []const u8, fd: c_int) !void {
    var child = try std.process.spawn(rt.io, .{
        .argv = argv,
        .environ_map = rt.env,
        .stdin = .ignore,
        .stdout = .{ .file = .{ .handle = fd, .flags = .{ .nonblocking = false } } },
        .stderr = .ignore,
    });
    defer @import("../platform/child_process.zig").terminate(&child, rt.io);
    const pidfd: c_int = @intCast(c.syscall(c.SYS_pidfd_open, child.id.?, @as(c_uint, 0)));
    if (pidfd < 0) return error.ProcessMonitorFailed;
    defer _ = c.close(pidfd);
    const deadline = native.nowMs() + 1500;
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
}

pub fn worker(rt: *Runtime, opt: Args) !void {
    if (std.mem.eql(u8, rt.session_id, "host")) return error.PreviewManagedSessionRequired;
    if (!std.mem.eql(u8, rt.instance, opt.expected_instance.?)) return error.PreviewIdentityMismatch;
    if (opt.command == ._preview_stop) return rt.stop();
    try rt.prepare();
    try rt.validateDisplay();
    try rt.unlocked();
    const output = try monitor(rt, opt.monitor);
    const rect = try output.rect();
    const scale = @min(1.0, @min(960.0 / rect.width, 540.0 / rect.height));
    const fd = c.memfd_create("deskctl-preview", c.MFD_CLOEXEC);
    if (fd < 0) return error.PreviewBufferFailed;
    defer _ = c.close(fd);
    const started = native.nowMs();
    try capture(rt, &.{ "grim", "-c", "-t", "png", "-l", "1", "-s", try std.fmt.allocPrint(rt.a, "{d}", .{scale}), "-o", output.name, "-" }, fd);
    try rt.unlocked();
    const size = c.lseek(fd, 0, c.SEEK_END);
    if (size < 24 or size > protocol.max_bytes) return error.InvalidScreenshot;
    if (c.lseek(fd, 0, c.SEEK_SET) < 0) return error.PreviewBufferFailed;
    const png = try rt.a.alloc(u8, @intCast(size));
    var offset: usize = 0;
    while (offset < png.len) {
        const n = c.read(fd, png.ptr + offset, png.len - offset);
        if (n <= 0) return error.PreviewBufferFailed;
        offset += @intCast(n);
    }
    try protocol.validatePng(png);
    const enabled = if (rt.token()) |_| true else |err| switch (err) {
        error.ControlStopped => false,
        else => return err,
    };
    const header = protocol.header(started, enabled);
    try std.Io.File.stdout().writeStreamingAll(rt.io, &header);
    try std.Io.File.stdout().writeStreamingAll(rt.io, png);
}
