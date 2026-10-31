const std = @import("std");
const native = @import("../platform/native.zig");
const c = native.c;
const Runtime = @import("runtime.zig").Runtime;
const NestedHost = @import("runtime.zig").NestedHost;
const Args = @import("../cli/args.zig").Args;
const valid_name = @import("../cli/args.zig").valid_name;
const ipc = @import("../platform/ipc.zig");
const child_process = @import("../platform/child_process.zig");
const eq = @import("../core/text.zig").eq;

pub const Process = struct { pid: c_int, start: []const u8 };
pub const Session = struct {
    schema: u32 = 1,
    name: []const u8,
    compositor: Process,
    bus: Process,
    runtime: []const u8,
    instance: []const u8,
    display: []const u8,
    dbus: []const u8,
    directory: []const u8,
    nested: bool,
    destroyed: bool = false,
    registry: ?Process = null,
    headless_bridge: ?[]const u8 = null,
};

const profile_kinds = [_][]const u8{ "CONFIG", "CACHE", "DATA", "STATE" };

/// Creates `path` (0700, owned by us) or fails if it is unsafe.
fn ensure_directory(runtime: *Runtime, path: []const u8) !void {
    var scoped = runtime.with_directory(path);
    try scoped.prepare();
}

fn root(runtime: *Runtime) ![]const u8 {
    const runtime_directory = runtime.env.get("XDG_RUNTIME_DIR").?;
    const path = try std.fmt.allocPrint(
        runtime.allocator,
        "{s}/hyprhand-sessions",
        .{runtime_directory},
    );
    try ensure_directory(runtime, path);
    return path;
}

fn named(runtime: *Runtime, name: []const u8) ![]const u8 {
    if (!valid_name(name)) return error.InvalidSessionName;
    if (eq(name, "host")) return error.InvalidSessionName;
    return std.fmt.allocPrint(runtime.allocator, "{s}/{s}", .{ try root(runtime), name });
}

/// Point the XDG_*_HOME variables of `env` at per-session profile directories.
fn export_profiles(
    runtime: *Runtime,
    env: *std.process.Environ.Map,
    session_directory: []const u8,
) !void {
    for (profile_kinds) |kind| {
        const path = try std.fmt.allocPrint(
            runtime.allocator,
            "{s}/profile-{s}",
            .{ session_directory, kind },
        );
        try ensure_directory(runtime, path);
        const variable = try std.fmt.allocPrint(runtime.allocator, "XDG_{s}_HOME", .{kind});
        try env.put(variable, path);
    }
}

const ProcStat = struct { start: u64, parent: c_int, state: u8, uid: c.uid_t };

fn process_stat(pid: c_int) !ProcStat {
    if (pid <= 1) return error.InvalidProcessIdentity;
    var path_buffer: [64]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buffer, "/proc/{d}/stat", .{pid}, 0);
    const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return error.ProcessNotFound;
    defer _ = c.close(fd);
    var file_stat: c.struct_stat = undefined;
    if (c.fstat(fd, &file_stat) < 0) return error.InvalidProcessIdentity;

    var buffer: [8192]u8 = undefined;
    const bytes_read = c.read(fd, &buffer, buffer.len);
    if (bytes_read <= 0) return error.InvalidProcessIdentity;
    const data = buffer[0..@intCast(bytes_read)];
    // The command name is parenthesised and may contain spaces; parse after it.
    const end = std.mem.lastIndexOfScalar(u8, data, ')') orelse return error.InvalidProcessIdentity;
    var fields = std.mem.tokenizeScalar(u8, data[end + 1 ..], ' ');
    const state = fields.next() orelse return error.InvalidProcessIdentity;
    if (state.len != 1) return error.InvalidProcessIdentity;
    if (state[0] == 'Z') return error.ProcessNotFound;
    if (state[0] == 'X') return error.ProcessNotFound;
    if (state[0] == 'x') return error.ProcessNotFound;
    const parent_field = fields.next() orelse return error.InvalidProcessIdentity;
    const parent = try std.fmt.parseInt(c_int, parent_field, 10);
    // Fields 5 (pgrp) through 21 (itrealvalue) precede starttime (field 22).
    for (0..17) |_| _ = fields.next() orelse return error.InvalidProcessIdentity;
    const start_field = fields.next() orelse return error.InvalidProcessIdentity;
    const start = try std.fmt.parseInt(u64, start_field, 10);

    return .{ .start = start, .parent = parent, .state = state[0], .uid = file_stat.st_uid };
}

fn start_time(runtime: *Runtime, pid: c_int) ![]const u8 {
    return std.fmt.allocPrint(runtime.allocator, "{d}", .{(try process_stat(pid)).start});
}

/// True when the PID still refers to the process recorded in the metadata.
fn alive(process: Process) bool {
    const actual = process_stat(process.pid) catch return false;
    const expected = std.fmt.parseInt(u64, process.start, 10) catch return false;
    return actual.start == expected;
}

fn running(session: Session) bool {
    return !session.destroyed and alive(session.compositor) and alive(session.bus);
}

/// Whether a session can take commands, and if not, why. Emitted as JSON.
pub const Health = enum {
    running,
    destroyed,
    /// The compositor or its bus is gone (crash, kill, logout).
    exited,
    /// Nested only: the host window was closed. Hyprland keeps running on a
    /// zero-size fallback output, so the process alone looks healthy.
    window_closed,
    /// The processes are alive but the compositor did not answer IPC.
    unresponsive,

    /// What `running` reports: commands are routed to the session.
    pub fn usable(self: Health) bool {
        return self == .running or self == .unresponsive;
    }
};

fn health(runtime: *Runtime, session: Session) Health {
    if (session.destroyed) return .destroyed;
    if (!running(session)) return .exited;
    if (!session.nested) return .running;
    return health_nested_output(runtime, session);
}

/// A nested compositor renders to a "WAYLAND-N" output backed by its host
/// window; closing that window removes the output.
fn health_nested_output(runtime: *Runtime, session: Session) Health {
    const Monitor = struct { name: []const u8, width: u32 = 0, height: u32 = 0 };
    const socket = Runtime.socket_path(runtime.allocator, session.runtime, session.instance) catch
        return .unresponsive;
    const reply = ipc.request_with_options(
        runtime.allocator,
        socket,
        "j/monitors",
        .{ .timeout_ms = 1000 },
    ) catch return .unresponsive;
    const monitors = runtime.parse_json([]Monitor, reply) catch return .unresponsive;
    for (monitors) |monitor| {
        const host_output = std.mem.startsWith(u8, monitor.name, "WAYLAND-");
        if (host_output and monitor.width > 0 and monitor.height > 0) return .running;
    }
    return .window_closed;
}

const Tracked = struct {
    pid: c_int,
    start: u64,
    fd: c_int,
    needs_resume: bool = false,

    fn exited(self: Tracked) bool {
        var poll_fd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
        return c.poll(&poll_fd, 1, 0) > 0 and (poll_fd.revents & c.POLLIN) != 0;
    }

    fn signal(self: Tracked, signal_number: c_int) !void {
        const result = c.syscall(
            c.SYS_pidfd_send_signal,
            self.fd,
            signal_number,
            @as(?*anyopaque, null),
            @as(c_uint, 0),
        );
        if (result < 0 and native.errno() != c.ESRCH) return error.SessionStopFailed;
    }

    fn stat(self: Tracked) ?ProcStat {
        if (self.exited()) return null;
        const current = process_stat(self.pid) catch return null;
        if (current.start != self.start) return null;
        if (current.uid != c.getuid()) return null;
        return current;
    }

    fn freeze(self: *Tracked) !void {
        const current = self.stat() orelse return;
        if (stopped(current.state)) return;
        // Restore processes we stopped if collection fails partway through.
        self.needs_resume = true;
        try self.signal(c.SIGSTOP);
        const deadline = native.now_ms() + 500;
        while (native.now_ms() < deadline) {
            const actual = self.stat() orelse return;
            if (stopped(actual.state)) return;
            native.sleep_ms(5);
        }
        // Still running: uninterruptible sleep (D) in a driver or file system,
        // typically after its compositor or GPU went away. The pending SIGSTOP
        // is delivered before it runs user code again, so it cannot fork an
        // untracked child meanwhile. Failing here used to abort `destroy`
        // with ProcessStopTimeout and leave every process of the session alive.
    }

    /// Group stop (T) or a tracer's stop (t, e.g. a crash reporter attached
    /// to a crashing browser process): neither runs code until resumed.
    fn stopped(state: u8) bool {
        return state == 'T' or state == 't';
    }
};

fn track(
    allocator: std.mem.Allocator,
    tree: *std.ArrayList(Tracked),
    pid: c_int,
    start: u64,
    parent: ?Tracked,
) !void {
    for (tree.items) |item| if (item.pid == pid and item.start == start) return;
    if (pid <= 1) return error.UnsafeProcessTarget;
    if (pid == c.getpid()) return error.UnsafeProcessTarget;
    if (tree.items.len >= 4096) return error.ProcessTreeTooLarge;

    const fd: c_int = @intCast(c.syscall(c.SYS_pidfd_open, pid, @as(c_uint, 0)));
    if (fd < 0) {
        if (native.errno() == c.ESRCH) return;
        return error.ProcessMonitorFailed;
    }
    var retained = false;
    defer if (!retained) {
        _ = c.close(fd);
    };
    const item = Tracked{ .pid = pid, .start = start, .fd = fd };
    const actual = item.stat() orelse return;
    if (parent) |parent_tracked| {
        // Both identities must still exist and the edge must still be true
        // after opening the pidfd. A recycled PID is never a signal target.
        if (actual.parent != parent_tracked.pid) return;
        if (parent_tracked.stat() == null) return;
    }

    try tree.append(allocator, item);
    retained = true;
}

fn collect_tree(allocator: std.mem.Allocator, tree: *std.ArrayList(Tracked)) !void {
    var index: usize = 0;
    while (index < tree.items.len) : (index += 1) {
        try tree.items[index].freeze();
        const parent = tree.items[index];
        if (parent.stat() == null) continue;
        // Scan PPIDs, including children created by non-leader threads. No
        // process-group, environment, executable-name, or UID-wide kills.
        const proc_directory = c.opendir("/proc") orelse return error.ProcessScanFailed;
        defer _ = c.closedir(proc_directory);
        while (try native.next_entry(proc_directory)) |name| {
            const pid = std.fmt.parseInt(c_int, name, 10) catch continue;
            const stat = process_stat(pid) catch continue;
            if (stat.parent != parent.pid) continue;
            if (stat.uid != c.getuid()) continue;
            try track(allocator, tree, pid, stat.start, parent);
        }
    }
}

fn wait_tree(tree: []const Tracked, timeout_ms: i64) bool {
    const deadline = native.now_ms() + timeout_ms;
    while (true) {
        var all_exited = true;
        for (tree) |item| if (!item.exited()) {
            all_exited = false;
            break;
        };
        if (all_exited) return true;
        if (native.now_ms() >= deadline) return false;
        native.sleep_ms(10);
    }
}

/// Refuses to target this process or any of its ancestors, whatever the
/// session metadata claims. An ancestor we cannot read (exited, zombie) ends
/// the walk: it cannot be the live process `alive` just confirmed.
fn reject_ancestor(pid: c_int) !void {
    var ancestor = c.getpid();
    while (ancestor > 1) {
        if (ancestor == pid) return error.UnsafeProcessTarget;
        ancestor = (process_stat(ancestor) catch break).parent;
    }
}

fn terminate_tree(runtime: *Runtime, roots: []const Process) !void {
    var tree: std.ArrayList(Tracked) = .empty;
    defer {
        for (tree.items) |item| {
            if (item.needs_resume) item.signal(c.SIGCONT) catch {};
            _ = c.close(item.fd);
        }
        tree.deinit(runtime.allocator);
    }
    for (roots) |process| {
        if (!alive(process)) continue;
        try reject_ancestor(process.pid);
        const start = try std.fmt.parseInt(u64, process.start, 10);
        try track(runtime.allocator, &tree, process.pid, start, null);
    }

    // Freeze and pin all roots and descendants before any parent can exit in
    // response to TERM and orphan children. Holding pidfds protects escalation.
    try collect_tree(runtime.allocator, &tree);
    var index = tree.items.len;
    while (index > 0) {
        index -= 1;
        try tree.items[index].signal(c.SIGTERM);
        try tree.items[index].signal(c.SIGCONT);
        tree.items[index].needs_resume = false;
    }
    if (wait_tree(tree.items, 1500)) return;

    // Also capture children forked during graceful shutdown when a validated
    // parent is still alive. Already-reparented, unrecorded daemons cannot be
    // safely attributed here; full containment requires a persistent supervisor.
    try collect_tree(runtime.allocator, &tree);
    index = tree.items.len;
    while (index > 0) {
        index -= 1;
        try tree.items[index].signal(c.SIGKILL);
    }
    // A killed process in uninterruptible sleep exits only when its system
    // call returns; give GPU drivers a few seconds.
    if (!wait_tree(tree.items, 5000)) return error.SessionStopTimeout;
}

fn terminate(runtime: *Runtime, process: Process) !void {
    try terminate_tree(runtime, &.{process});
}

/// Starts a detached daemon in its own process group, logging to `output`.
fn spawn(
    runtime: *Runtime,
    env: *const std.process.Environ.Map,
    argv: []const []const u8,
    output: []const u8,
) !Process {
    const fd = c.open(
        try runtime.allocator.dupeSentinel(u8, output, 0),
        c.O_WRONLY | c.O_APPEND | c.O_CREAT | c.O_CLOEXEC | c.O_NOFOLLOW,
        @as(c_uint, 0o600),
    );
    if (fd < 0) return error.SessionLogFailed;
    defer _ = c.close(fd);

    const log_file: std.process.SpawnOptions.StdIo = .{
        .file = .{ .handle = fd, .flags = .{ .nonblocking = false } },
    };
    var child = try std.process.spawn(runtime.io, .{
        .argv = argv,
        .environ_map = env,
        .pgid = 0,
        .stdin = .ignore,
        .stdout = log_file,
        .stderr = log_file,
    });
    errdefer child_process.terminate(&child, runtime.io);
    return .{ .pid = child.id.?, .start = try start_time(runtime, child.id.?) };
}

fn save(runtime: *Runtime, session: Session) !void {
    const path = try std.fmt.allocPrintSentinel(
        runtime.allocator,
        "{s}/session.json",
        .{session.directory},
        0,
    );
    const temporary_path = try std.fmt.allocPrintSentinel(
        runtime.allocator,
        "{s}/metadata-{s}.tmp",
        .{ session.directory, try runtime.random_token() },
        0,
    );
    defer _ = c.unlink(temporary_path);

    try std.Io.Dir.cwd().writeFile(runtime.io, .{
        .sub_path = temporary_path,
        .data = try std.json.Stringify.valueAlloc(runtime.allocator, session, .{}),
        .flags = .{ .exclusive = true },
    });
    if (c.rename(temporary_path, path) < 0) return error.StateWriteFailed;
}

/// A session runtime directory is `$XDG_RUNTIME_DIR/d<8 hex>`; older
/// releases used the `dc-` prefix. Anything else in metadata is rejected.
fn valid_runtime_directory(runtime: *Runtime, runtime_directory: []const u8) !bool {
    const base = runtime.env.get("XDG_RUNTIME_DIR").?;
    // Longest prefix first: "d" would otherwise also match a "dc-" directory.
    for ([_][]const u8{ "dc-", "d" }) |prefix| {
        const expected = try std.fmt.allocPrint(runtime.allocator, "{s}/{s}", .{ base, prefix });
        if (!std.mem.startsWith(u8, runtime_directory, expected)) continue;
        const suffix = runtime_directory[expected.len..];
        return suffix.len == 8 and std.mem.indexOfScalar(u8, suffix, '/') == null;
    }
    return false;
}

pub fn load(runtime: *Runtime, name: []const u8) !Session {
    const directory = try named(runtime, name);
    var directory_stat: c.struct_stat = undefined;
    const directory_path = try runtime.allocator.dupeSentinel(u8, directory, 0);
    if (c.lstat(directory_path, &directory_stat) < 0) return error.SessionNotFound;
    try ensure_directory(runtime, directory);

    const metadata_path = try std.fmt.allocPrint(
        runtime.allocator,
        "{s}/session.json",
        .{directory},
    );
    const data = runtime.read_file(metadata_path, 16384) catch return error.SessionNotFound;
    const session = try runtime.parse_json(Session, data);
    if (session.schema != 1) return error.InvalidSessionMetadata;
    if (!eq(session.name, name)) return error.InvalidSessionMetadata;
    if (!eq(session.directory, directory)) return error.InvalidSessionMetadata;
    const runtime_valid = try valid_runtime_directory(runtime, session.runtime);
    if (!runtime_valid) return error.InvalidSessionMetadata;
    if (std.mem.indexOfScalar(u8, session.instance, '/') != null) {
        return error.InvalidSessionMetadata;
    }
    if (std.mem.indexOfScalar(u8, session.display, '/') != null) {
        return error.InvalidSessionMetadata;
    }
    return session;
}

/// Retarget `runtime` at a managed session: environment, IPC socket and state
/// directory all move to that session's compositor.
pub fn route(runtime: *Runtime, name: []const u8) !void {
    if (eq(name, "host")) return;
    const session = try load(runtime, name);
    switch (health(runtime, session)) {
        // Commands against an unresponsive compositor fail with their own
        // IPC error; refusing them here would hide which request hung.
        .running, .unresponsive => {},
        .window_closed => return error.NestedWindowClosed,
        .destroyed, .exited => return error.SessionNotRunning,
    }
    if (session.nested) {
        // Recorded before retargeting: `runtime.socket` is still the host's.
        runtime.nested_host = .{
            .socket = runtime.socket,
            .compositor_pid = session.compositor.pid,
        };
    }

    const env = try runtime.allocator.create(std.process.Environ.Map);
    env.* = try runtime.env.clone(runtime.allocator);
    try env.put("XDG_RUNTIME_DIR", session.runtime);
    try env.put("WAYLAND_DISPLAY", session.display);
    try env.put("HYPRLAND_INSTANCE_SIGNATURE", session.instance);
    try env.put("DBUS_SESSION_BUS_ADDRESS", session.dbus);
    _ = env.swapRemove("DISPLAY");
    if (session.registry != null) {
        try env.put("AT_SPI_BUS_ADDRESS", session.dbus);
    } else {
        _ = env.swapRemove("AT_SPI_BUS_ADDRESS");
    }
    try env.put("GDK_BACKEND", "wayland");
    try env.put("QT_QPA_PLATFORM", "wayland");
    try env.put("MOZ_ENABLE_WAYLAND", "1");
    try export_profiles(runtime, env, session.directory);

    runtime.env = env;
    runtime.session_id = name;
    runtime.session_directory = session.directory;
    runtime.instance = session.instance;
    runtime.display = session.display;
    runtime.socket = try Runtime.socket_path(
        runtime.allocator,
        session.runtime,
        session.instance,
    );
    runtime.directory = try Runtime.state_directory(
        runtime.allocator,
        session.runtime,
        session.instance,
    );
    // Never call setenv: libc can invalidate Zig's startup environment block.
    // Native Wayland gets an absolute socket; children get this explicit map.
    try runtime.validate_display();
}

const HostWorkspace = struct { id: i64 = 0 };

/// Bounded on its own: it also runs after the command's budget expired.
fn host_query(runtime: *Runtime, host: NestedHost, request: []const u8) ![]const u8 {
    const options: ipc.Options = .{ .timeout_ms = 1000, .cancellable = false };
    return ipc.request_with_options(runtime.allocator, host.socket, request, options);
}

/// Hyprland sends no frame callbacks to a window on a workspace no monitor
/// shows, so a nested compositor there renders nothing and screen captures
/// wait forever. Fails with NestedWindowHidden (window exists, not shown) or
/// NestedWindowClosed (no host window). Never moves the user's window.
pub fn check_nested_window(runtime: *Runtime) !void {
    const host = runtime.nested_host orelse return;
    const Client = struct {
        pid: i64 = 0,
        mapped: bool = true,
        hidden: bool = false,
        workspace: HostWorkspace = .{},
    };
    const clients = try runtime.parse_json([]Client, try host_query(runtime, host, "j/clients"));
    for (clients) |client| {
        if (client.pid != host.compositor_pid) continue;
        if (!client.mapped) return error.NestedWindowHidden;
        if (client.hidden) return error.NestedWindowHidden;
        const shown = try check_nested_window_shown(runtime, host, client.workspace.id);
        if (!shown) return error.NestedWindowHidden;
        return;
    }
    return error.NestedWindowClosed;
}

fn check_nested_window_shown(runtime: *Runtime, host: NestedHost, workspace_id: i64) !bool {
    const Monitor = struct {
        activeWorkspace: HostWorkspace = .{},
        specialWorkspace: HostWorkspace = .{},
        dpmsStatus: bool = true,
        disabled: bool = false,
    };
    const reply = try host_query(runtime, host, "j/monitors");
    const monitors = try runtime.parse_json([]Monitor, reply);
    for (monitors) |monitor| {
        if (monitor.disabled) continue;
        if (!monitor.dpmsStatus) continue;
        if (monitor.activeWorkspace.id == workspace_id) return true;
        // A shown special workspace has a non-zero (negative) id.
        if (monitor.specialWorkspace.id == workspace_id) return true;
    }
    return false;
}

/// A capture or wait that timed out in a nested session usually means the
/// host hid its window. Name that cause instead of the generic timeout.
pub fn explain_failure(runtime: *Runtime, failure: anyerror) anyerror {
    if (runtime.nested_host == null) return failure;
    const timed_out = failure == error.CommandTimeout or
        failure == error.WaitTimeout or
        failure == error.HelperTimeout;
    if (!timed_out) return failure;

    native.clear_command_limit();
    check_nested_window(runtime) catch |cause| switch (cause) {
        error.NestedWindowHidden, error.NestedWindowClosed => return cause,
        else => return failure,
    };
    return failure;
}

fn validate_headless_bridge(runtime: *Runtime, path: []const u8) !void {
    var bridge_stat: c.struct_stat = undefined;
    const bridge_path = try runtime.allocator.dupeSentinel(u8, path, 0);
    if (c.lstat(bridge_path, &bridge_stat) != 0) return error.InvalidHeadlessBridge;

    const regular = (bridge_stat.st_mode & c.S_IFMT) == c.S_IFREG;
    const trusted_owner = bridge_stat.st_uid == c.getuid() or bridge_stat.st_uid == 0;
    const group_or_world_writable = (bridge_stat.st_mode & 0o022) != 0;
    if (!regular) return error.InvalidHeadlessBridge;
    if (!trusted_owner) return error.InvalidHeadlessBridge;
    if (group_or_world_writable) return error.InvalidHeadlessBridge;
}

const compositor_config_lua =
    "hl.monitor({{output='WAYLAND-1',mode='1280x720@60',position='0x0',scale=1," ++
    "disabled={s}}})\n" ++
    "hl.monitor({{output='HEADLESS-1',mode='1280x720@60',position='0x0',scale=1}})\n" ++
    "hl.config({{animations={{enabled=false}},xwayland={{enabled=false}}," ++
    "misc={{disable_hyprland_logo=true,disable_splash_rendering=true}}}})\n";

const compositor_config_hyprlang =
    \\monitor = WAYLAND-1,{s}
    \\monitor = HEADLESS-1,1280x720@60,0x0,1
    \\animations:enabled = false
    \\xwayland:enabled = false
    \\misc:disable_hyprland_logo = true
    \\misc:disable_splash_rendering = true
    \\
;

/// Minimal compositor configuration: one hidden (or, nested, visible) Wayland
/// output plus the headless output agents render to. Animations and XWayland off.
fn compositor_config(allocator: std.mem.Allocator, lua: bool, nested: bool) ![]const u8 {
    if (lua) {
        const disabled = if (nested) "false" else "true";
        return std.fmt.allocPrint(allocator, compositor_config_lua, .{disabled});
    }
    const wayland_output = if (nested) "1280x720@60,0x0,1" else "disable";
    return std.fmt.allocPrint(allocator, compositor_config_hyprlang, .{wayland_output});
}

const Discovered = struct { instance: []const u8, display: []const u8 };

/// Finds the instance directory whose lock file names `compositor`, once its
/// IPC socket answers. Scans with a scratch arena; results are copied out.
fn discover_instance(
    runtime: *Runtime,
    runtime_directory: []const u8,
    compositor: Process,
) !Discovered {
    const hypr_path = try std.fmt.allocPrint(runtime.allocator, "{s}/hypr", .{runtime_directory});
    const hypr_directory = try runtime.allocator.dupeSentinel(u8, hypr_path, 0);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const deadline = native.now_ms() + 10_000;
    while (native.now_ms() < deadline) {
        try native.check_cancelled();
        if (!alive(compositor)) return error.SessionStartupFailed;
        defer _ = arena.reset(.retain_capacity);
        var scratch = runtime.scratch(arena.allocator());
        if (c.opendir(hypr_directory)) |directory_stream| {
            defer _ = c.closedir(directory_stream);
            while (try native.next_entry(directory_stream)) |name| {
                if (name[0] == '.') continue;
                const lock_path = try std.fmt.allocPrint(
                    scratch.allocator,
                    "{s}/hypr/{s}/hyprland.lock",
                    .{ runtime_directory, name },
                );
                const data = scratch.read_file(lock_path, 4096) catch continue;
                var lines = std.mem.tokenizeAny(u8, data, "\r\n");
                const pid_line = lines.next() orelse continue;
                const pid = std.fmt.parseInt(c_int, pid_line, 10) catch continue;
                if (pid != compositor.pid) continue;
                const display = lines.next() orelse continue;
                const socket = try Runtime.socket_path(scratch.allocator, runtime_directory, name);
                _ = ipc.request(scratch.allocator, socket, "j/version") catch continue;
                return .{
                    .instance = try runtime.allocator.dupe(u8, name),
                    .display = try runtime.allocator.dupe(u8, display),
                };
            }
        }
        native.sleep_ms(50);
    }
    return error.SessionStartupTimeout;
}

/// Waits until the fresh compositor reports at least one output with a
/// non-zero mode, which is the moment rendering can start.
fn wait_for_usable_output(runtime: *Runtime, socket: []const u8) !bool {
    const Monitor = struct { width: u32, height: u32 };
    for (0..30) |_| {
        const reply = try ipc.request(runtime.allocator, socket, "j/monitors");
        const monitors = try runtime.parse_json([]Monitor, reply);
        for (monitors) |monitor| if (monitor.width > 0 and monitor.height > 0) return true;
        native.sleep_ms(50);
    }
    return false;
}

fn create(runtime: *Runtime, arguments: Args) !void {
    const directory = try named(runtime, arguments.session_name.?);
    try ensure_directory(runtime, directory);
    var scoped = runtime.with_directory(directory);
    const lock = try scoped.lock();
    defer _ = c.close(lock);
    try create_check_existing(runtime, arguments.session_name.?);

    try runtime.validate_display();
    if (arguments.headless_bridge) |path| try validate_headless_bridge(runtime, path);
    // Hyprland 0.57+ only reads Lua configs. Follow the host's provider so the
    // child compositor (same installed binary) accepts its generated config.
    const lua = arguments.lua or try runtime.config_provider() == .lua;

    const runtime_directory = try create_runtime_directory(runtime);
    const dbus = try std.fmt.allocPrint(
        runtime.allocator,
        "unix:path={s}/bus",
        .{runtime_directory},
    );
    const env = try create_environment(runtime, runtime_directory, directory, dbus);

    const bus = try create_bus_start(runtime, &scoped, &env, dbus);
    errdefer terminate(runtime, bus) catch {};
    try create_bus_wait(runtime, runtime_directory);

    const registry = try create_registry_start(runtime, &scoped, &env);
    errdefer if (registry) |process| {
        terminate(runtime, process) catch {};
    };

    const compositor = try create_compositor_start(runtime, &scoped, &env, arguments, lua);
    errdefer terminate(runtime, compositor) catch {};
    const discovered = try discover_instance(runtime, runtime_directory, compositor);
    const socket = try Runtime.socket_path(
        runtime.allocator,
        runtime_directory,
        discovered.instance,
    );
    if (!arguments.nested) try create_headless_output(runtime, socket, lua);
    try create_compositor_ready(runtime, socket, arguments.nested);

    const session = Session{
        .name = arguments.session_name.?,
        .compositor = compositor,
        .bus = bus,
        .runtime = runtime_directory,
        .instance = discovered.instance,
        .display = discovered.display,
        .dbus = dbus,
        .directory = directory,
        .nested = arguments.nested,
        .registry = registry,
        .headless_bridge = arguments.headless_bridge,
    };
    if (!running(session)) return error.SessionStartupFailed;
    try save(runtime, session);

    try runtime.emit(.{
        .ok = true,
        .session = session,
        .shared_cursor = false,
        .filesystem_sandbox = false,
        .control_enabled = false,
    });
}

/// A name is free once its session was destroyed. A session that died on its
/// own still owns processes (bus, registry, applications) that only `destroy`
/// may stop, so it is reported rather than silently reaped.
fn create_check_existing(runtime: *Runtime, name: []const u8) !void {
    const existing = load(runtime, name) catch |err| switch (err) {
        error.SessionNotFound => return,
        else => return err,
    };
    switch (health(runtime, existing)) {
        .destroyed => {},
        .running, .unresponsive => return error.SessionExists,
        .exited, .window_closed => return error.SessionDead,
    }
}

fn create_runtime_directory(runtime: *Runtime) ![]const u8 {
    const runtime_directory = try std.fmt.allocPrint(
        runtime.allocator,
        "{s}/d{s}",
        .{ runtime.env.get("XDG_RUNTIME_DIR").?, (try runtime.random_token())[0..8] },
    );
    const runtime_directory_path = try runtime.allocator.dupeSentinel(u8, runtime_directory, 0);
    if (c.mkdir(runtime_directory_path, 0o700) != 0) return error.RuntimeDirectoryCollision;
    try ensure_directory(runtime, runtime_directory);
    return runtime_directory;
}

fn create_environment(
    runtime: *Runtime,
    runtime_directory: []const u8,
    session_directory: []const u8,
    dbus: []const u8,
) !std.process.Environ.Map {
    var env = try runtime.env.clone(runtime.allocator);
    // Experimental injection is scoped to the compositor, never its bus.
    _ = env.swapRemove("LD_PRELOAD");
    _ = env.swapRemove("HYPRLAND_INSTANCE_SIGNATURE");
    _ = env.swapRemove("DISPLAY");
    _ = env.swapRemove("AT_SPI_BUS_ADDRESS");
    const host_display = try std.fmt.allocPrint(
        runtime.allocator,
        "{s}/{s}",
        .{ runtime.env.get("XDG_RUNTIME_DIR").?, std.fs.path.basename(runtime.display) },
    );
    try env.put("WAYLAND_DISPLAY", host_display);
    try env.put("XDG_RUNTIME_DIR", runtime_directory);
    try export_profiles(runtime, &env, session_directory);
    // An invalid libseat backend prevents physical-seat/DRM acquisition. The
    // Wayland backend supplies the render allocator, even in hidden mode.
    try env.put("LIBSEAT_BACKEND", "hyprhand-disabled");
    try env.put("HYPRLAND_NO_SD_VARS", "1");
    try env.put("HYPRLAND_NO_SD_NOTIFY", "1");
    try env.put("DBUS_SESSION_BUS_ADDRESS", dbus);
    try env.put("AT_SPI_BUS_ADDRESS", dbus);
    return env;
}

const bus_config_format =
    "<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>" ++
    "<auth>EXTERNAL</auth><policy context=\"default\"><allow user=\"{d}\"/>" ++
    "<allow send_destination=\"*\"/><allow receive_sender=\"*\"/><allow own=\"*\"/>" ++
    "</policy></busconfig>";

fn create_bus_start(
    runtime: *Runtime,
    scoped: *Runtime,
    env: *const std.process.Environ.Map,
    dbus: []const u8,
) !Process {
    const bus_config = try scoped.state_path("bus.conf");
    // Do not activate the user's systemd/portal services from this bus.
    const bus_xml = try std.fmt.allocPrint(runtime.allocator, bus_config_format, .{c.getuid()});
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = bus_config, .data = bus_xml });
    const bus_argv = [_][]const u8{
        "dbus-daemon",
        try std.fmt.allocPrint(runtime.allocator, "--config-file={s}", .{bus_config}),
        "--nofork",
        try std.fmt.allocPrint(runtime.allocator, "--address={s}", .{dbus}),
    };
    return spawn(runtime, env, &bus_argv, try scoped.state_path("dbus.log"));
}

fn create_bus_wait(runtime: *Runtime, runtime_directory: []const u8) !void {
    const bus_path = try std.fmt.allocPrintSentinel(
        runtime.allocator,
        "{s}/bus",
        .{runtime_directory},
        0,
    );
    for (0..100) |_| {
        if (c.access(bus_path, c.F_OK) == 0) break;
        native.sleep_ms(10);
    }
    if (c.access(bus_path, c.F_OK) != 0) return error.SessionBusUnavailable;
}

fn create_registry_start(
    runtime: *Runtime,
    scoped: *Runtime,
    env: *const std.process.Environ.Map,
) !?Process {
    const programs = [_][:0]const u8{
        "/usr/lib/at-spi2-registryd",
        "/usr/libexec/at-spi2-registryd",
    };
    for (programs) |program| {
        if (c.access(program, c.X_OK) == 0) {
            const log_path = try scoped.state_path("accessibility.log");
            return try spawn(runtime, env, &.{program}, log_path);
        }
    }
    return null;
}

fn create_compositor_start(
    runtime: *Runtime,
    scoped: *Runtime,
    env: *const std.process.Environ.Map,
    arguments: Args,
    lua: bool,
) !Process {
    const config = try scoped.state_path(if (lua) "hyprland.lua" else "hyprland.conf");
    try std.Io.Dir.cwd().writeFile(runtime.io, .{
        .sub_path = config,
        .data = try compositor_config(runtime.allocator, lua, arguments.nested),
    });

    var compositor_env = try env.clone(runtime.allocator);
    if (arguments.headless_bridge) |path| try compositor_env.put("LD_PRELOAD", path);
    const log_path = try scoped.state_path("compositor.log");
    return spawn(runtime, &compositor_env, &.{ "Hyprland", "--config", config }, log_path);
}

fn create_headless_output(runtime: *Runtime, socket: []const u8, lua: bool) !void {
    const reply = try ipc.request(runtime.allocator, socket, "/output create headless HEADLESS-1");
    if (!eq(std.mem.trim(u8, reply, " \r\n"), "ok")) return error.HeadlessOutputFailed;
    // Reapply after output creation: the headless backend initially advertises
    // only its default mode and can report zero geometry until configured.
    const command_text = if (lua)
        "/eval hl.monitor({output='HEADLESS-1',mode='1920x1080@60',position='0x0',scale=1})"
    else
        "/keyword monitor HEADLESS-1,1920x1080@60,0x0,1";
    _ = try ipc.request(runtime.allocator, socket, command_text);
}

fn create_compositor_ready(runtime: *Runtime, socket: []const u8, nested: bool) !void {
    const config_errors_reply = try ipc.request(runtime.allocator, socket, "j/configerrors");
    const config_errors = try runtime.parse_json([][]const u8, config_errors_reply);
    for (config_errors) |config_error| {
        if (std.mem.trim(u8, config_error, " \r\n").len != 0) return error.SessionConfigInvalid;
    }

    const output_usable = try wait_for_usable_output(runtime, socket);
    if (!output_usable) {
        if (nested) return error.NestedRenderUnavailable;
        return error.HeadlessRenderUnavailable;
    }

    // Dismiss only this fresh compositor's startup notice (animated progress
    // bar for direct Hyprland launch). No applications have been launched yet.
    _ = try ipc.request(runtime.allocator, socket, "/dismissnotify -1");
}

/// Every process launched into the session, plus its compositor, registry
/// and bus: the roots whose trees `destroy` terminates.
fn session_roots(runtime: *Runtime, session: Session) !std.ArrayList(Process) {
    var roots: std.ArrayList(Process) = .empty;
    errdefer roots.deinit(runtime.allocator);
    var scoped = runtime.with_directory(session.directory);
    const directory = try runtime.allocator.dupeSentinel(u8, session.directory, 0);
    const directory_stream = c.opendir(directory) orelse return error.StateDirectoryFailed;
    defer _ = c.closedir(directory_stream);
    while (try native.next_entry(directory_stream)) |name| {
        if (!std.mem.startsWith(u8, name, "app-")) continue;
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        const record = try runtime.read_file(try scoped.state_path(name), 4096);
        try roots.append(runtime.allocator, try runtime.parse_json(Process, record));
    }

    try roots.append(runtime.allocator, session.compositor);
    if (session.registry) |registry| try roots.append(runtime.allocator, registry);
    try roots.append(runtime.allocator, session.bus);
    return roots;
}

pub fn command(runtime: *Runtime, arguments: Args) !void {
    const name = arguments.session_name.?;
    switch (arguments.session_verb.?) {
        .create => return create(runtime, arguments),
        .inspect => {
            const session = try load(runtime, name);
            const state = health(runtime, session);
            return runtime.emit(.{
                .ok = true,
                .session = session,
                .running = state.usable(),
                .health = state,
                .filesystem_sandbox = false,
            });
        },
        .destroy => return command_destroy(runtime, name),
    }
}

fn command_destroy(runtime: *Runtime, name: []const u8) !void {
    var session = try load(runtime, name);

    var scoped = runtime.with_directory(session.directory);
    const lock = try scoped.lock();
    defer _ = c.close(lock);
    // Creation and launch share this lock; metadata loaded before acquiring it
    // may refer to an earlier incarnation of the same session name.
    session = try load(runtime, name);
    if (!session.destroyed) {
        var roots = try session_roots(runtime, session);
        defer roots.deinit(runtime.allocator);
        try terminate_tree(runtime, roots.items);
    }
    session.destroyed = true;
    try save(runtime, session);

    try runtime.emit(.{
        .ok = true,
        .session_id = session.name,
        .status = "destroyed",
        .profiles_and_logs_retained = session.directory,
    });
}

pub fn list(runtime: *Runtime) !void {
    const base = try root(runtime);
    const base_path = try runtime.allocator.dupeSentinel(u8, base, 0);
    const directory_stream = c.opendir(base_path) orelse return error.StateDirectoryFailed;
    defer _ = c.closedir(directory_stream);

    const Entry = struct {
        id: []const u8,
        running: bool,
        health: Health,
        shared_cursor: bool,
        nested: bool,
    };
    var entries: std.ArrayList(Entry) = .empty;
    try entries.append(runtime.allocator, .{
        .id = "host",
        .running = true,
        .health = .running,
        .shared_cursor = true,
        .nested = false,
    });
    while (try native.next_entry(directory_stream)) |name| {
        if (!valid_name(name)) continue;
        const session = load(runtime, name) catch continue;
        const state = health(runtime, session);
        try entries.append(runtime.allocator, .{
            .id = session.name,
            .running = state.usable(),
            .health = state,
            .shared_cursor = false,
            .nested = session.nested,
        });
    }

    try runtime.emit(.{ .ok = true, .sessions = entries.items });
}

/// Browser profiles live inside the session directory; callers may not point
/// them elsewhere and leak state across sessions.
fn browser_arguments(
    runtime: *Runtime,
    argv: *std.ArrayList([]const u8),
    program: []const u8,
    extra: []const []const u8,
    directory: []const u8,
) !void {
    const allocator = runtime.allocator;
    const chromium = std.mem.indexOf(u8, program, "brave") != null or
        std.mem.indexOf(u8, program, "chrom") != null;
    if (chromium) {
        for (extra) |argument| {
            if (std.mem.startsWith(u8, argument, "--user-data-dir")) {
                return error.ProfileOverrideDenied;
            }
        }
        const profile_option = try std.fmt.allocPrint(
            allocator,
            "--user-data-dir={s}/browser-profile",
            .{directory},
        );
        try argv.appendSlice(allocator, &.{
            profile_option,
            "--ozone-platform=wayland",
            "--no-first-run",
        });
    } else if (std.mem.indexOf(u8, program, "firefox") != null) {
        for (extra) |argument| {
            if (firefox_profile_override(argument)) return error.ProfileOverrideDenied;
        }
        const profile = try std.fmt.allocPrint(allocator, "{s}/firefox-profile", .{directory});
        try ensure_directory(runtime, profile);
        try argv.appendSlice(allocator, &.{ "--no-remote", "--profile", profile });
    }
}

pub fn launch(runtime: *Runtime, arguments: Args) !void {
    // `route` records the directory only for managed sessions; host has none.
    const directory = runtime.session_directory orelse return error.ManagedSessionRequired;
    if (arguments.dry_run) {
        return runtime.emit(.{
            .ok = true,
            .dry_run = true,
            .session_id = arguments.session,
            .action = "launch",
        });
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(runtime.allocator, arguments.program[0]);
    var scoped = runtime.with_directory(directory);
    const lock = try scoped.lock();
    defer _ = c.close(lock);
    const session_json = try runtime.read_file(try scoped.state_path("session.json"), 16384);
    const session = try runtime.parse_json(Session, session_json);
    const same_session = eq(session.name, arguments.session) and
        eq(session.directory, directory) and
        eq(session.runtime, runtime.env.get("XDG_RUNTIME_DIR").?) and
        eq(session.instance, runtime.instance);
    if (!same_session) return error.SessionNotRunning;
    if (!running(session)) return error.SessionNotRunning;

    const program_name = std.fs.path.basename(arguments.program[0]);
    const program_arguments = arguments.program[1..];
    try browser_arguments(runtime, &argv, program_name, program_arguments, directory);
    try argv.appendSlice(runtime.allocator, program_arguments);
    const log_path = try std.fmt.allocPrint(
        runtime.allocator,
        "{s}/applications.log",
        .{directory},
    );
    const process = try spawn(runtime, runtime.env, argv.items, log_path);
    errdefer terminate(runtime, process) catch {};
    const record_path = try std.fmt.allocPrint(
        runtime.allocator,
        "{s}/app-{s}.json",
        .{ directory, try runtime.random_token() },
    );
    try std.Io.Dir.cwd().writeFile(runtime.io, .{
        .sub_path = record_path,
        .data = try std.json.Stringify.valueAlloc(runtime.allocator, process, .{}),
        .flags = .{ .exclusive = true },
    });

    try runtime.emit(.{
        .ok = true,
        .session_id = arguments.session,
        .action = "launch",
        .process = process,
        .status = "started",
    });
}

fn firefox_profile_override(argument: []const u8) bool {
    if (!std.mem.startsWith(u8, argument, "-")) return false;
    const flag = std.mem.trimStart(u8, argument, "-");
    const key = flag[0 .. std.mem.indexOfScalar(u8, flag, '=') orelse flag.len];
    for ([_][]const u8{ "p", "profile", "profilemanager", "createprofile" }) |denied| {
        if (std.ascii.eqlIgnoreCase(key, denied)) return true;
    }
    return false;
}

test "Firefox profile override aliases" {
    const overrides = [_][]const u8{
        "-P",
        "--P=default",
        "-profile",
        "--profile=/tmp/shared",
        "--PROFILE",
        "-ProfileManager",
        "--CreateProfile=test",
    };
    for (overrides) |argument| {
        try std.testing.expect(firefox_profile_override(argument));
    }
    const ordinary = [_][]const u8{
        "https://example.org/profile",
        "--private-window",
        "--",
        "-",
        "--new-window",
    };
    for (ordinary) |argument| {
        try std.testing.expect(!firefox_profile_override(argument));
    }
}
