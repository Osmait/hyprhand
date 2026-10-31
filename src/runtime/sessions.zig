const std = @import("std");
const native = @import("../platform/native.zig");
const c = native.c;
const Runtime = @import("runtime.zig").Runtime;
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
    const path = try std.fmt.allocPrint(runtime.allocator, "{s}/hyprhand-sessions", .{runtime.env.get("XDG_RUNTIME_DIR").?});
    try ensure_directory(runtime, path);
    return path;
}

fn named(runtime: *Runtime, name: []const u8) ![]const u8 {
    if (!valid_name(name) or eq(name, "host")) return error.InvalidSessionName;
    return std.fmt.allocPrint(runtime.allocator, "{s}/{s}", .{ try root(runtime), name });
}

/// Point the XDG_*_HOME variables of `env` at per-session profile directories.
fn export_profiles(runtime: *Runtime, env: *std.process.Environ.Map, session_directory: []const u8) !void {
    for (profile_kinds) |kind| {
        const path = try std.fmt.allocPrint(runtime.allocator, "{s}/profile-{s}", .{ session_directory, kind });
        try ensure_directory(runtime, path);
        try env.put(try std.fmt.allocPrint(runtime.allocator, "XDG_{s}_HOME", .{kind}), path);
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
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) < 0) return error.InvalidProcessIdentity;
    var buffer: [8192]u8 = undefined;
    const n = c.read(fd, &buffer, buffer.len);
    if (n <= 0) return error.InvalidProcessIdentity;
    const data = buffer[0..@intCast(n)];
    // The command name is parenthesised and may contain spaces; parse after it.
    const end = std.mem.lastIndexOfScalar(u8, data, ')') orelse return error.InvalidProcessIdentity;
    var fields = std.mem.tokenizeScalar(u8, data[end + 1 ..], ' ');
    const state = fields.next() orelse return error.InvalidProcessIdentity;
    if (state.len != 1) return error.InvalidProcessIdentity;
    if (state[0] == 'Z' or state[0] == 'X') return error.ProcessNotFound;
    const parent = try std.fmt.parseInt(c_int, fields.next() orelse return error.InvalidProcessIdentity, 10);
    // Fields 5 (pgrp) through 21 (itrealvalue) precede starttime (field 22).
    for (0..17) |_| _ = fields.next() orelse return error.InvalidProcessIdentity;
    const start = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidProcessIdentity, 10);
    return .{ .start = start, .parent = parent, .state = state[0], .uid = st.st_uid };
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

const Tracked = struct {
    pid: c_int,
    start: u64,
    fd: c_int,
    needs_resume: bool = false,

    fn exited(self: Tracked) bool {
        var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
        return c.poll(&pfd, 1, 0) > 0 and (pfd.revents & c.POLLIN) != 0;
    }

    fn signal(self: Tracked, sig: c_int) !void {
        if (c.syscall(c.SYS_pidfd_send_signal, self.fd, sig, @as(?*anyopaque, null), @as(c_uint, 0)) < 0 and native.errno() != c.ESRCH) return error.SessionStopFailed;
    }

    fn stat(self: Tracked) ?ProcStat {
        if (self.exited()) return null;
        const current = process_stat(self.pid) catch return null;
        if (current.start != self.start or current.uid != c.getuid()) return null;
        return current;
    }

    fn freeze(self: *Tracked) !void {
        const current = self.stat() orelse return;
        if (current.state == 'T') return;
        // Restore processes we stopped if collection fails partway through.
        self.needs_resume = true;
        try self.signal(c.SIGSTOP);
        const deadline = native.now_ms() + 500;
        while (native.now_ms() < deadline) {
            const actual = self.stat() orelse return;
            if (actual.state == 'T') return;
            native.sleep_ms(5);
        }
        return error.ProcessStopTimeout;
    }
};

fn track(allocator: std.mem.Allocator, tree: *std.ArrayList(Tracked), pid: c_int, start: u64, parent: ?Tracked) !void {
    for (tree.items) |item| if (item.pid == pid and item.start == start) return;
    if (pid <= 1 or pid == c.getpid()) return error.UnsafeProcessTarget;
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
    if (parent) |p| {
        // Both identities must still exist and the edge must still be true
        // after opening the pidfd. A recycled PID is never a signal target.
        if (actual.parent != p.pid or p.stat() == null) return;
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
        const proc = c.opendir("/proc") orelse return error.ProcessScanFailed;
        defer _ = c.closedir(proc);
        while (try native.next_entry(proc)) |name| {
            const pid = std.fmt.parseInt(c_int, name, 10) catch continue;
            const stat = process_stat(pid) catch continue;
            if (stat.parent == parent.pid and stat.uid == c.getuid()) try track(allocator, tree, pid, stat.start, parent);
        }
    }
}

fn wait_tree(tree: []const Tracked, timeout: i64) bool {
    const deadline = native.now_ms() + timeout;
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
        try track(runtime.allocator, &tree, process.pid, try std.fmt.parseInt(u64, process.start, 10), null);
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
    if (!wait_tree(tree.items, 1500)) return error.SessionStopTimeout;
}

fn terminate(runtime: *Runtime, process: Process) !void {
    try terminate_tree(runtime, &.{process});
}

/// Starts a detached daemon in its own process group, logging to `output`.
fn spawn(runtime: *Runtime, env: *const std.process.Environ.Map, argv: []const []const u8, output: []const u8) !Process {
    const fd = c.open(try runtime.allocator.dupeSentinel(u8, output, 0), c.O_WRONLY | c.O_APPEND | c.O_CREAT | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
    if (fd < 0) return error.SessionLogFailed;
    defer _ = c.close(fd);
    const log_file: std.process.SpawnOptions.StdIo = .{ .file = .{ .handle = fd, .flags = .{ .nonblocking = false } } };
    var child = try std.process.spawn(runtime.io, .{ .argv = argv, .environ_map = env, .pgid = 0, .stdin = .ignore, .stdout = log_file, .stderr = log_file });
    errdefer child_process.terminate(&child, runtime.io);
    return .{ .pid = child.id.?, .start = try start_time(runtime, child.id.?) };
}

fn save(runtime: *Runtime, session: Session) !void {
    const path = try std.fmt.allocPrintSentinel(runtime.allocator, "{s}/session.json", .{session.directory}, 0);
    const tmp = try std.fmt.allocPrintSentinel(runtime.allocator, "{s}/metadata-{s}.tmp", .{ session.directory, try runtime.random_token() }, 0);
    defer _ = c.unlink(tmp);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = tmp, .data = try std.json.Stringify.valueAlloc(runtime.allocator, session, .{}), .flags = .{ .exclusive = true } });
    if (c.rename(tmp, path) < 0) return error.StateWriteFailed;
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
    const dir = try named(runtime, name);
    var st: c.struct_stat = undefined;
    if (c.lstat(try runtime.allocator.dupeSentinel(u8, dir, 0), &st) < 0) return error.SessionNotFound;
    try ensure_directory(runtime, dir);
    const data = runtime.read_file(try std.fmt.allocPrint(runtime.allocator, "{s}/session.json", .{dir}), 16384) catch return error.SessionNotFound;
    const session = try runtime.parse_json(Session, data);
    if (session.schema != 1 or !eq(session.name, name) or !eq(session.directory, dir)) return error.InvalidSessionMetadata;
    if (!try valid_runtime_directory(runtime, session.runtime)) return error.InvalidSessionMetadata;
    if (std.mem.indexOfScalar(u8, session.instance, '/') != null or std.mem.indexOfScalar(u8, session.display, '/') != null) return error.InvalidSessionMetadata;
    return session;
}

/// Retarget `runtime` at a managed session: environment, IPC socket and state
/// directory all move to that session's compositor.
pub fn route(runtime: *Runtime, name: []const u8) !void {
    if (eq(name, "host")) return;
    const session = try load(runtime, name);
    if (!running(session)) return error.SessionNotRunning;
    const env = try runtime.allocator.create(std.process.Environ.Map);
    env.* = try runtime.env.clone(runtime.allocator);
    try env.put("XDG_RUNTIME_DIR", session.runtime);
    try env.put("WAYLAND_DISPLAY", session.display);
    try env.put("HYPRLAND_INSTANCE_SIGNATURE", session.instance);
    try env.put("DBUS_SESSION_BUS_ADDRESS", session.dbus);
    _ = env.swapRemove("DISPLAY");
    if (session.registry != null) try env.put("AT_SPI_BUS_ADDRESS", session.dbus) else _ = env.swapRemove("AT_SPI_BUS_ADDRESS");
    try env.put("GDK_BACKEND", "wayland");
    try env.put("QT_QPA_PLATFORM", "wayland");
    try env.put("MOZ_ENABLE_WAYLAND", "1");
    try export_profiles(runtime, env, session.directory);
    runtime.env = env;
    runtime.session_id = name;
    runtime.session_directory = session.directory;
    runtime.instance = session.instance;
    runtime.display = session.display;
    runtime.socket = try Runtime.socket_path(runtime.allocator, session.runtime, session.instance);
    runtime.directory = try Runtime.state_directory(runtime.allocator, session.runtime, session.instance);
    // Never call setenv: libc can invalidate Zig's startup environment block.
    // Native Wayland gets an absolute socket; children get this explicit map.
    try runtime.validate_display();
}

fn validate_headless_bridge(runtime: *Runtime, path: []const u8) !void {
    var st: c.struct_stat = undefined;
    if (c.lstat(try runtime.allocator.dupeSentinel(u8, path, 0), &st) != 0) return error.InvalidHeadlessBridge;
    const regular = (st.st_mode & c.S_IFMT) == c.S_IFREG;
    const trusted_owner = st.st_uid == c.getuid() or st.st_uid == 0;
    const group_or_world_writable = (st.st_mode & 0o022) != 0;
    if (!regular or !trusted_owner or group_or_world_writable) return error.InvalidHeadlessBridge;
}

/// Minimal compositor configuration: one hidden (or, nested, visible) Wayland
/// output plus the headless output agents render to. Animations and XWayland off.
fn compositor_config(allocator: std.mem.Allocator, lua: bool, nested: bool) ![]const u8 {
    if (lua) {
        return std.fmt.allocPrint(allocator,
            \\hl.monitor({{output='WAYLAND-1',mode='1280x720@60',position='0x0',scale=1,disabled={s}}})
            \\hl.monitor({{output='HEADLESS-1',mode='1280x720@60',position='0x0',scale=1}})
            \\hl.config({{animations={{enabled=false}},xwayland={{enabled=false}},misc={{disable_hyprland_logo=true,disable_splash_rendering=true}}}})
            \\
        , .{if (nested) "false" else "true"});
    }
    return std.fmt.allocPrint(allocator,
        \\monitor = WAYLAND-1,{s}
        \\monitor = HEADLESS-1,1280x720@60,0x0,1
        \\animations:enabled = false
        \\xwayland:enabled = false
        \\misc:disable_hyprland_logo = true
        \\misc:disable_splash_rendering = true
        \\
    , .{if (nested) "1280x720@60,0x0,1" else "disable"});
}

const Discovered = struct { instance: []const u8, display: []const u8 };

/// Finds the instance directory whose lock file names `compositor`, once its
/// IPC socket answers. Scans with a scratch arena; results are copied out.
fn discover_instance(runtime: *Runtime, runtime_directory: []const u8, compositor: Process) !Discovered {
    const hypr = try runtime.allocator.dupeSentinel(u8, try std.fmt.allocPrint(runtime.allocator, "{s}/hypr", .{runtime_directory}), 0);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const end = native.now_ms() + 10_000;
    while (native.now_ms() < end) {
        try native.check_cancelled();
        if (!alive(compositor)) return error.SessionStartupFailed;
        defer _ = arena.reset(.retain_capacity);
        var scratch = runtime.scratch(arena.allocator());
        if (c.opendir(hypr)) |dir| {
            defer _ = c.closedir(dir);
            while (try native.next_entry(dir)) |name| {
                if (name[0] == '.') continue;
                const lock = try std.fmt.allocPrint(scratch.allocator, "{s}/hypr/{s}/hyprland.lock", .{ runtime_directory, name });
                const data = scratch.read_file(lock, 4096) catch continue;
                var lines = std.mem.tokenizeAny(u8, data, "\r\n");
                const pid = std.fmt.parseInt(c_int, lines.next() orelse continue, 10) catch continue;
                if (pid != compositor.pid) continue;
                const display = lines.next() orelse continue;
                const socket = try Runtime.socket_path(scratch.allocator, runtime_directory, name);
                _ = ipc.request(scratch.allocator, socket, "j/version") catch continue;
                return .{ .instance = try runtime.allocator.dupe(u8, name), .display = try runtime.allocator.dupe(u8, display) };
            }
        }
        native.sleep_ms(50);
    }
    return error.SessionStartupTimeout;
}

/// Waits until the fresh compositor reports at least one output with a
/// non-zero mode, which is the moment rendering can start.
fn wait_for_usable_output(runtime: *Runtime, socket: []const u8) !bool {
    for (0..30) |_| {
        const monitors = try runtime.parse_json([]struct { width: u32, height: u32 }, try ipc.request(runtime.allocator, socket, "j/monitors"));
        for (monitors) |monitor| if (monitor.width > 0 and monitor.height > 0) return true;
        native.sleep_ms(50);
    }
    return false;
}

fn create(runtime: *Runtime, arguments: Args) !void {
    try runtime.validate_display();
    if (arguments.headless_bridge) |path| try validate_headless_bridge(runtime, path);
    // Hyprland 0.57+ only reads Lua configs. Follow the host's provider so the
    // child compositor (same installed binary) accepts its generated config.
    const lua = arguments.lua or eq(try runtime.config_provider(), "lua");
    const dir = try named(runtime, arguments.name.?);
    try ensure_directory(runtime, dir);
    var scoped = runtime.with_directory(dir);
    const lock = try scoped.lock();
    defer _ = c.close(lock);
    if (load(runtime, arguments.name.?)) |existing| {
        if (!existing.destroyed) return error.SessionExists;
    } else |err| if (err != error.SessionNotFound) return err;
    const runtime_directory = try std.fmt.allocPrint(runtime.allocator, "{s}/d{s}", .{ runtime.env.get("XDG_RUNTIME_DIR").?, (try runtime.random_token())[0..8] });
    if (c.mkdir(try runtime.allocator.dupeSentinel(u8, runtime_directory, 0), 0o700) != 0) return error.RuntimeDirectoryCollision;
    try ensure_directory(runtime, runtime_directory);
    var env = try runtime.env.clone(runtime.allocator);
    // Experimental injection is scoped to the compositor, never its bus.
    _ = env.swapRemove("LD_PRELOAD");
    _ = env.swapRemove("HYPRLAND_INSTANCE_SIGNATURE");
    _ = env.swapRemove("DISPLAY");
    _ = env.swapRemove("AT_SPI_BUS_ADDRESS");
    try env.put("WAYLAND_DISPLAY", try std.fmt.allocPrint(runtime.allocator, "{s}/{s}", .{ runtime.env.get("XDG_RUNTIME_DIR").?, std.fs.path.basename(runtime.display) }));
    try env.put("XDG_RUNTIME_DIR", runtime_directory);
    try export_profiles(runtime, &env, dir);
    // An invalid libseat backend prevents physical-seat/DRM acquisition. The
    // Wayland backend supplies the render allocator, even in hidden mode.
    try env.put("LIBSEAT_BACKEND", "hyprhand-disabled");
    try env.put("HYPRLAND_NO_SD_VARS", "1");
    try env.put("HYPRLAND_NO_SD_NOTIFY", "1");
    const dbus = try std.fmt.allocPrint(runtime.allocator, "unix:path={s}/bus", .{runtime_directory});
    try env.put("DBUS_SESSION_BUS_ADDRESS", dbus);
    try env.put("AT_SPI_BUS_ADDRESS", dbus);
    const bus_config = try scoped.state_path("bus.conf");
    // Do not activate the user's systemd/portal services from this bus.
    const bus_xml = try std.fmt.allocPrint(runtime.allocator, "<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen><auth>EXTERNAL</auth><policy context=\"default\"><allow user=\"{d}\"/><allow send_destination=\"*\"/><allow receive_sender=\"*\"/><allow own=\"*\"/></policy></busconfig>", .{c.getuid()});
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = bus_config, .data = bus_xml });
    const bus_argv = [_][]const u8{
        "dbus-daemon",
        try std.fmt.allocPrint(runtime.allocator, "--config-file={s}", .{bus_config}),
        "--nofork",
        try std.fmt.allocPrint(runtime.allocator, "--address={s}", .{dbus}),
    };
    const bus = try spawn(runtime, &env, &bus_argv, try scoped.state_path("dbus.log"));
    errdefer terminate(runtime, bus) catch {};
    const bus_path = try std.fmt.allocPrintSentinel(runtime.allocator, "{s}/bus", .{runtime_directory}, 0);
    for (0..100) |_| {
        if (c.access(bus_path, c.F_OK) == 0) break;
        native.sleep_ms(10);
    }
    if (c.access(bus_path, c.F_OK) != 0) return error.SessionBusUnavailable;
    var registry: ?Process = null;
    for ([_][:0]const u8{ "/usr/lib/at-spi2-registryd", "/usr/libexec/at-spi2-registryd" }) |program| {
        if (c.access(program, c.X_OK) == 0) {
            registry = try spawn(runtime, &env, &.{program}, try scoped.state_path("accessibility.log"));
            break;
        }
    }
    errdefer if (registry) |process| {
        terminate(runtime, process) catch {};
    };
    const config = try scoped.state_path(if (lua) "hyprland.lua" else "hyprland.conf");
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = config, .data = try compositor_config(runtime.allocator, lua, arguments.nested) });
    var compositor_env = try env.clone(runtime.allocator);
    if (arguments.headless_bridge) |path| try compositor_env.put("LD_PRELOAD", path);
    const compositor = try spawn(runtime, &compositor_env, &.{ "Hyprland", "--config", config }, try scoped.state_path("compositor.log"));
    errdefer terminate(runtime, compositor) catch {};
    const discovered = try discover_instance(runtime, runtime_directory, compositor);
    const socket = try Runtime.socket_path(runtime.allocator, runtime_directory, discovered.instance);
    if (!arguments.nested) {
        const reply = try ipc.request(runtime.allocator, socket, "/output create headless HEADLESS-1");
        if (!eq(std.mem.trim(u8, reply, " \r\n"), "ok")) return error.HeadlessOutputFailed;
        // Reapply after output creation: the headless backend initially advertises
        // only its default mode and can report zero geometry until configured.
        const command_text = if (lua) "/eval hl.monitor({output='HEADLESS-1',mode='1920x1080@60',position='0x0',scale=1})" else "/keyword monitor HEADLESS-1,1920x1080@60,0x0,1";
        _ = try ipc.request(runtime.allocator, socket, command_text);
    }
    const config_errors = try runtime.parse_json([][]const u8, try ipc.request(runtime.allocator, socket, "j/configerrors"));
    for (config_errors) |err| if (std.mem.trim(u8, err, " \r\n").len != 0) return error.SessionConfigInvalid;
    if (!try wait_for_usable_output(runtime, socket)) return if (arguments.nested) error.NestedRenderUnavailable else error.HeadlessRenderUnavailable;
    // Dismiss only this fresh compositor's startup notice (animated progress
    // bar for direct Hyprland launch). No applications have been launched yet.
    _ = try ipc.request(runtime.allocator, socket, "/dismissnotify -1");
    const session = Session{
        .name = arguments.name.?,
        .compositor = compositor,
        .bus = bus,
        .runtime = runtime_directory,
        .instance = discovered.instance,
        .display = discovered.display,
        .dbus = dbus,
        .directory = dir,
        .nested = arguments.nested,
        .registry = registry,
        .headless_bridge = arguments.headless_bridge,
    };
    if (!running(session)) return error.SessionStartupFailed;
    try save(runtime, session);
    try runtime.emit(.{ .ok = true, .session = session, .shared_cursor = false, .filesystem_sandbox = false, .control_enabled = false });
}

/// Every process launched into the session, plus its compositor, registry
/// and bus: the roots whose trees `destroy` terminates.
fn session_roots(runtime: *Runtime, session: Session) !std.ArrayList(Process) {
    var roots: std.ArrayList(Process) = .empty;
    errdefer roots.deinit(runtime.allocator);
    var scoped = runtime.with_directory(session.directory);
    const dir = c.opendir(try runtime.allocator.dupeSentinel(u8, session.directory, 0)) orelse return error.StateDirectoryFailed;
    defer _ = c.closedir(dir);
    while (try native.next_entry(dir)) |name| {
        if (!std.mem.startsWith(u8, name, "app-") or !std.mem.endsWith(u8, name, ".json")) continue;
        try roots.append(runtime.allocator, try runtime.parse_json(Process, try runtime.read_file(try scoped.state_path(name), 4096)));
    }
    try roots.append(runtime.allocator, session.compositor);
    if (session.registry) |registry| try roots.append(runtime.allocator, registry);
    try roots.append(runtime.allocator, session.bus);
    return roots;
}

pub fn command(runtime: *Runtime, arguments: Args) !void {
    const verb = arguments.value.?;
    if (eq(verb, "create")) return create(runtime, arguments);
    var session = try load(runtime, arguments.name.?);
    if (eq(verb, "inspect")) return runtime.emit(.{ .ok = true, .session = session, .running = running(session), .filesystem_sandbox = false });
    var scoped = runtime.with_directory(session.directory);
    const lock = try scoped.lock();
    defer _ = c.close(lock);
    // Creation and launch share this lock; metadata loaded before acquiring it
    // may refer to an earlier incarnation of the same session name.
    session = try load(runtime, arguments.name.?);
    if (!session.destroyed) {
        var roots = try session_roots(runtime, session);
        defer roots.deinit(runtime.allocator);
        try terminate_tree(runtime, roots.items);
    }
    session.destroyed = true;
    try save(runtime, session);
    try runtime.emit(.{ .ok = true, .session_id = session.name, .status = "destroyed", .profiles_and_logs_retained = session.directory });
}

pub fn list(runtime: *Runtime) !void {
    const base = try root(runtime);
    const dir = c.opendir(try runtime.allocator.dupeSentinel(u8, base, 0)) orelse return error.StateDirectoryFailed;
    defer _ = c.closedir(dir);
    const Entry = struct { id: []const u8, running: bool, shared_cursor: bool, nested: bool };
    var entries: std.ArrayList(Entry) = .empty;
    try entries.append(runtime.allocator, .{ .id = "host", .running = true, .shared_cursor = true, .nested = false });
    while (try native.next_entry(dir)) |name| {
        if (!valid_name(name)) continue;
        const session = load(runtime, name) catch continue;
        try entries.append(runtime.allocator, .{ .id = session.name, .running = running(session), .shared_cursor = false, .nested = session.nested });
    }
    try runtime.emit(.{ .ok = true, .sessions = entries.items });
}

/// Browser profiles live inside the session directory; callers may not point
/// them elsewhere and leak state across sessions.
fn browser_arguments(runtime: *Runtime, argv: *std.ArrayList([]const u8), program: []const u8, extra: []const []const u8, dir: []const u8) !void {
    const a = runtime.allocator;
    if (std.mem.indexOf(u8, program, "brave") != null or std.mem.indexOf(u8, program, "chrom") != null) {
        for (extra) |arg| if (std.mem.startsWith(u8, arg, "--user-data-dir")) return error.ProfileOverrideDenied;
        try argv.appendSlice(a, &.{ try std.fmt.allocPrint(a, "--user-data-dir={s}/browser-profile", .{dir}), "--ozone-platform=wayland", "--no-first-run" });
    } else if (std.mem.indexOf(u8, program, "firefox") != null) {
        for (extra) |arg| if (firefox_profile_override(arg)) return error.ProfileOverrideDenied;
        const profile = try std.fmt.allocPrint(a, "{s}/firefox-profile", .{dir});
        try ensure_directory(runtime, profile);
        try argv.appendSlice(a, &.{ "--no-remote", "--profile", profile });
    }
}

pub fn launch(runtime: *Runtime, arguments: Args) !void {
    // `route` records the directory only for managed sessions; host has none.
    const dir = runtime.session_directory orelse return error.ManagedSessionRequired;
    if (arguments.dry_run) return runtime.emit(.{ .ok = true, .dry_run = true, .session_id = arguments.session, .action = "launch" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(runtime.allocator, arguments.program[0]);
    var scoped = runtime.with_directory(dir);
    const lock = try scoped.lock();
    defer _ = c.close(lock);
    const session = try runtime.parse_json(Session, try runtime.read_file(try scoped.state_path("session.json"), 16384));
    const same_session = eq(session.name, arguments.session) and eq(session.directory, dir) and
        eq(session.runtime, runtime.env.get("XDG_RUNTIME_DIR").?) and eq(session.instance, runtime.instance);
    if (!same_session or !running(session)) return error.SessionNotRunning;
    try browser_arguments(runtime, &argv, std.fs.path.basename(arguments.program[0]), arguments.program[1..], dir);
    try argv.appendSlice(runtime.allocator, arguments.program[1..]);
    const process = try spawn(runtime, runtime.env, argv.items, try std.fmt.allocPrint(runtime.allocator, "{s}/applications.log", .{dir}));
    errdefer terminate(runtime, process) catch {};
    const record = try std.fmt.allocPrint(runtime.allocator, "{s}/app-{s}.json", .{ dir, try runtime.random_token() });
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = record, .data = try std.json.Stringify.valueAlloc(runtime.allocator, process, .{}), .flags = .{ .exclusive = true } });
    try runtime.emit(.{ .ok = true, .session_id = arguments.session, .action = "launch", .process = process, .status = "started" });
}

fn firefox_profile_override(arg: []const u8) bool {
    if (!std.mem.startsWith(u8, arg, "-")) return false;
    const flag = std.mem.trimStart(u8, arg, "-");
    const key = flag[0 .. std.mem.indexOfScalar(u8, flag, '=') orelse flag.len];
    for ([_][]const u8{ "p", "profile", "profilemanager", "createprofile" }) |denied| {
        if (std.ascii.eqlIgnoreCase(key, denied)) return true;
    }
    return false;
}

test "Firefox profile override aliases" {
    for ([_][]const u8{ "-P", "--P=default", "-profile", "--profile=/tmp/shared", "--PROFILE", "-ProfileManager", "--CreateProfile=test" }) |arg| {
        try std.testing.expect(firefox_profile_override(arg));
    }
    for ([_][]const u8{ "https://example.org/profile", "--private-window", "--", "-", "--new-window" }) |arg| {
        try std.testing.expect(!firefox_profile_override(arg));
    }
}
