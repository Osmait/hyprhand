const std = @import("std");
const native = @import("../platform/native.zig");
const c = native.c;
const Runtime = @import("runtime.zig").Runtime;
const Args = @import("../cli/args.zig").Args;
const validName = @import("../cli/args.zig").validName;
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
fn ensureDirectory(rt: *Runtime, path: []const u8) !void {
    var scoped = rt.withDirectory(path);
    try scoped.prepare();
}

fn root(rt: *Runtime) ![]const u8 {
    const path = try std.fmt.allocPrint(rt.allocator, "{s}/hyprhand-sessions", .{rt.env.get("XDG_RUNTIME_DIR").?});
    try ensureDirectory(rt, path);
    return path;
}

fn named(rt: *Runtime, name: []const u8) ![]const u8 {
    if (!validName(name) or eq(name, "host")) return error.InvalidSessionName;
    return std.fmt.allocPrint(rt.allocator, "{s}/{s}", .{ try root(rt), name });
}

/// Point the XDG_*_HOME variables of `env` at per-session profile directories.
fn exportProfiles(rt: *Runtime, env: *std.process.Environ.Map, session_directory: []const u8) !void {
    for (profile_kinds) |kind| {
        const path = try std.fmt.allocPrint(rt.allocator, "{s}/profile-{s}", .{ session_directory, kind });
        try ensureDirectory(rt, path);
        try env.put(try std.fmt.allocPrint(rt.allocator, "XDG_{s}_HOME", .{kind}), path);
    }
}

const ProcStat = struct { start: u64, parent: c_int, state: u8, uid: c.uid_t };

fn processStat(pid: c_int) !ProcStat {
    if (pid <= 1) return error.InvalidProcessIdentity;
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/stat", .{pid});
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

fn startTime(rt: *Runtime, pid: c_int) ![]const u8 {
    return std.fmt.allocPrint(rt.allocator, "{d}", .{(try processStat(pid)).start});
}

/// True when the PID still refers to the process recorded in the metadata.
fn alive(process: Process) bool {
    const actual = processStat(process.pid) catch return false;
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
        const current = processStat(self.pid) catch return null;
        if (current.start != self.start or current.uid != c.getuid()) return null;
        return current;
    }

    fn freeze(self: *Tracked) !void {
        const current = self.stat() orelse return;
        if (current.state == 'T') return;
        // Restore processes we stopped if collection fails partway through.
        self.needs_resume = true;
        try self.signal(c.SIGSTOP);
        const deadline = native.nowMs() + 500;
        while (native.nowMs() < deadline) {
            const actual = self.stat() orelse return;
            if (actual.state == 'T') return;
            native.sleepMs(5);
        }
        return error.ProcessStopTimeout;
    }
};

fn track(a: std.mem.Allocator, tree: *std.ArrayList(Tracked), pid: c_int, start: u64, parent: ?Tracked) !void {
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
    try tree.append(a, item);
    retained = true;
}

fn collectTree(a: std.mem.Allocator, tree: *std.ArrayList(Tracked)) !void {
    var index: usize = 0;
    while (index < tree.items.len) : (index += 1) {
        try tree.items[index].freeze();
        const parent = tree.items[index];
        if (parent.stat() == null) continue;
        // Scan PPIDs, including children created by non-leader threads. No
        // process-group, environment, executable-name, or UID-wide kills.
        const proc = c.opendir("/proc") orelse return error.ProcessScanFailed;
        defer _ = c.closedir(proc);
        while (try native.nextEntry(proc)) |name| {
            const pid = std.fmt.parseInt(c_int, name, 10) catch continue;
            const stat = processStat(pid) catch continue;
            if (stat.parent == parent.pid and stat.uid == c.getuid()) try track(a, tree, pid, stat.start, parent);
        }
    }
}

fn waitTree(tree: []const Tracked, timeout: i64) bool {
    const deadline = native.nowMs() + timeout;
    while (true) {
        var all_exited = true;
        for (tree) |item| if (!item.exited()) {
            all_exited = false;
            break;
        };
        if (all_exited) return true;
        if (native.nowMs() >= deadline) return false;
        native.sleepMs(10);
    }
}

/// Refuses to target this process or any of its ancestors, whatever the
/// session metadata claims. An ancestor we cannot read (exited, zombie) ends
/// the walk: it cannot be the live process `alive` just confirmed.
fn rejectAncestor(pid: c_int) !void {
    var ancestor = c.getpid();
    while (ancestor > 1) {
        if (ancestor == pid) return error.UnsafeProcessTarget;
        ancestor = (processStat(ancestor) catch break).parent;
    }
}

fn terminateTree(rt: *Runtime, roots: []const Process) !void {
    var tree: std.ArrayList(Tracked) = .empty;
    defer {
        for (tree.items) |item| {
            if (item.needs_resume) item.signal(c.SIGCONT) catch {};
            _ = c.close(item.fd);
        }
        tree.deinit(rt.allocator);
    }
    for (roots) |process| {
        if (!alive(process)) continue;
        try rejectAncestor(process.pid);
        try track(rt.allocator, &tree, process.pid, try std.fmt.parseInt(u64, process.start, 10), null);
    }
    // Freeze and pin all roots and descendants before any parent can exit in
    // response to TERM and orphan children. Holding pidfds protects escalation.
    try collectTree(rt.allocator, &tree);
    var index = tree.items.len;
    while (index > 0) {
        index -= 1;
        try tree.items[index].signal(c.SIGTERM);
        try tree.items[index].signal(c.SIGCONT);
        tree.items[index].needs_resume = false;
    }
    if (waitTree(tree.items, 1500)) return;
    // Also capture children forked during graceful shutdown when a validated
    // parent is still alive. Already-reparented, unrecorded daemons cannot be
    // safely attributed here; full containment requires a persistent supervisor.
    try collectTree(rt.allocator, &tree);
    index = tree.items.len;
    while (index > 0) {
        index -= 1;
        try tree.items[index].signal(c.SIGKILL);
    }
    if (!waitTree(tree.items, 1500)) return error.SessionStopTimeout;
}

fn terminate(rt: *Runtime, process: Process) !void {
    try terminateTree(rt, &.{process});
}

/// Starts a detached daemon in its own process group, logging to `output`.
fn spawn(rt: *Runtime, env: *const std.process.Environ.Map, argv: []const []const u8, output: []const u8) !Process {
    const fd = c.open(try rt.allocator.dupeZ(u8, output), c.O_WRONLY | c.O_APPEND | c.O_CREAT | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
    if (fd < 0) return error.SessionLogFailed;
    defer _ = c.close(fd);
    const log_file: std.process.SpawnOptions.StdIo = .{ .file = .{ .handle = fd, .flags = .{ .nonblocking = false } } };
    var child = try std.process.spawn(rt.io, .{ .argv = argv, .environ_map = env, .pgid = 0, .stdin = .ignore, .stdout = log_file, .stderr = log_file });
    errdefer child_process.terminate(&child, rt.io);
    return .{ .pid = child.id.?, .start = try startTime(rt, child.id.?) };
}

fn save(rt: *Runtime, session: Session) !void {
    const path = try std.fmt.allocPrintSentinel(rt.allocator, "{s}/session.json", .{session.directory}, 0);
    const tmp = try std.fmt.allocPrintSentinel(rt.allocator, "{s}/metadata-{s}.tmp", .{ session.directory, try rt.randomToken() }, 0);
    defer _ = c.unlink(tmp);
    try std.Io.Dir.cwd().writeFile(rt.io, .{ .sub_path = tmp, .data = try std.json.Stringify.valueAlloc(rt.allocator, session, .{}), .flags = .{ .exclusive = true } });
    if (c.rename(tmp, path) < 0) return error.StateWriteFailed;
}

/// A session runtime directory is `$XDG_RUNTIME_DIR/d<8 hex>`; older
/// releases used the `dc-` prefix. Anything else in metadata is rejected.
fn validRuntimeDirectory(rt: *Runtime, runtime: []const u8) !bool {
    const base = rt.env.get("XDG_RUNTIME_DIR").?;
    // Longest prefix first: "d" would otherwise also match a "dc-" directory.
    for ([_][]const u8{ "dc-", "d" }) |prefix| {
        const expected = try std.fmt.allocPrint(rt.allocator, "{s}/{s}", .{ base, prefix });
        if (!std.mem.startsWith(u8, runtime, expected)) continue;
        const suffix = runtime[expected.len..];
        return suffix.len == 8 and std.mem.indexOfScalar(u8, suffix, '/') == null;
    }
    return false;
}

pub fn load(rt: *Runtime, name: []const u8) !Session {
    const dir = try named(rt, name);
    var st: c.struct_stat = undefined;
    if (c.lstat(try rt.allocator.dupeZ(u8, dir), &st) < 0) return error.SessionNotFound;
    try ensureDirectory(rt, dir);
    const data = rt.readFile(try std.fmt.allocPrint(rt.allocator, "{s}/session.json", .{dir}), 16384) catch return error.SessionNotFound;
    const session = try rt.parseJson(Session, data);
    if (session.schema != 1 or !eq(session.name, name) or !eq(session.directory, dir)) return error.InvalidSessionMetadata;
    if (!try validRuntimeDirectory(rt, session.runtime)) return error.InvalidSessionMetadata;
    if (std.mem.indexOfScalar(u8, session.instance, '/') != null or std.mem.indexOfScalar(u8, session.display, '/') != null) return error.InvalidSessionMetadata;
    return session;
}

/// Retarget `rt` at a managed session: environment, IPC socket and state
/// directory all move to that session's compositor.
pub fn route(rt: *Runtime, name: []const u8) !void {
    if (eq(name, "host")) return;
    const session = try load(rt, name);
    if (!running(session)) return error.SessionNotRunning;
    const env = try rt.allocator.create(std.process.Environ.Map);
    env.* = try rt.env.clone(rt.allocator);
    try env.put("XDG_RUNTIME_DIR", session.runtime);
    try env.put("WAYLAND_DISPLAY", session.display);
    try env.put("HYPRLAND_INSTANCE_SIGNATURE", session.instance);
    try env.put("DBUS_SESSION_BUS_ADDRESS", session.dbus);
    _ = env.swapRemove("DISPLAY");
    if (session.registry != null) try env.put("AT_SPI_BUS_ADDRESS", session.dbus) else _ = env.swapRemove("AT_SPI_BUS_ADDRESS");
    try env.put("GDK_BACKEND", "wayland");
    try env.put("QT_QPA_PLATFORM", "wayland");
    try env.put("MOZ_ENABLE_WAYLAND", "1");
    try exportProfiles(rt, env, session.directory);
    rt.env = env;
    rt.session_id = name;
    rt.session_directory = session.directory;
    rt.instance = session.instance;
    rt.display = session.display;
    rt.socket = try Runtime.socketPath(rt.allocator, session.runtime, session.instance);
    rt.directory = try Runtime.stateDirectory(rt.allocator, session.runtime, session.instance);
    // Never call setenv: libc can invalidate Zig's startup environment block.
    // Native Wayland gets an absolute socket; children get this explicit map.
    try rt.validateDisplay();
}

fn validateHeadlessBridge(rt: *Runtime, path: []const u8) !void {
    var st: c.struct_stat = undefined;
    if (c.lstat(try rt.allocator.dupeZ(u8, path), &st) != 0) return error.InvalidHeadlessBridge;
    const regular = (st.st_mode & c.S_IFMT) == c.S_IFREG;
    const trusted_owner = st.st_uid == c.getuid() or st.st_uid == 0;
    const group_or_world_writable = (st.st_mode & 0o022) != 0;
    if (!regular or !trusted_owner or group_or_world_writable) return error.InvalidHeadlessBridge;
}

/// Minimal compositor configuration: one hidden (or, nested, visible) Wayland
/// output plus the headless output agents render to. Animations and XWayland off.
fn compositorConfig(a: std.mem.Allocator, lua: bool, nested: bool) ![]const u8 {
    if (lua) {
        return std.fmt.allocPrint(a,
            \\hl.monitor({{output='WAYLAND-1',mode='1280x720@60',position='0x0',scale=1,disabled={s}}})
            \\hl.monitor({{output='HEADLESS-1',mode='1280x720@60',position='0x0',scale=1}})
            \\hl.config({{animations={{enabled=false}},xwayland={{enabled=false}},misc={{disable_hyprland_logo=true,disable_splash_rendering=true}}}})
            \\
        , .{if (nested) "false" else "true"});
    }
    return std.fmt.allocPrint(a,
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
fn discoverInstance(rt: *Runtime, runtime: []const u8, compositor: Process) !Discovered {
    const hypr = try rt.allocator.dupeZ(u8, try std.fmt.allocPrint(rt.allocator, "{s}/hypr", .{runtime}));
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const end = native.nowMs() + 10_000;
    while (native.nowMs() < end) {
        try native.checkCancelled();
        if (!alive(compositor)) return error.SessionStartupFailed;
        defer _ = arena.reset(.retain_capacity);
        var scratch = rt.scratch(arena.allocator());
        if (c.opendir(hypr)) |dir| {
            defer _ = c.closedir(dir);
            while (try native.nextEntry(dir)) |name| {
                if (name[0] == '.') continue;
                const lock = try std.fmt.allocPrint(scratch.allocator, "{s}/hypr/{s}/hyprland.lock", .{ runtime, name });
                const data = scratch.readFile(lock, 4096) catch continue;
                var lines = std.mem.tokenizeAny(u8, data, "\r\n");
                const pid = std.fmt.parseInt(c_int, lines.next() orelse continue, 10) catch continue;
                if (pid != compositor.pid) continue;
                const display = lines.next() orelse continue;
                const socket = try Runtime.socketPath(scratch.allocator, runtime, name);
                _ = ipc.request(scratch.allocator, socket, "j/version") catch continue;
                return .{ .instance = try rt.allocator.dupe(u8, name), .display = try rt.allocator.dupe(u8, display) };
            }
        }
        native.sleepMs(50);
    }
    return error.SessionStartupTimeout;
}

/// Waits until the fresh compositor reports at least one output with a
/// non-zero mode, which is the moment rendering can start.
fn waitForUsableOutput(rt: *Runtime, socket: []const u8) !bool {
    for (0..30) |_| {
        const monitors = try rt.parseJson([]struct { width: u32, height: u32 }, try ipc.request(rt.allocator, socket, "j/monitors"));
        for (monitors) |monitor| if (monitor.width > 0 and monitor.height > 0) return true;
        native.sleepMs(50);
    }
    return false;
}

fn create(rt: *Runtime, opt: Args) !void {
    try rt.validateDisplay();
    if (opt.headless_bridge) |path| try validateHeadlessBridge(rt, path);
    const dir = try named(rt, opt.name.?);
    try ensureDirectory(rt, dir);
    var scoped = rt.withDirectory(dir);
    const lock = try scoped.lock();
    defer _ = c.close(lock);
    if (load(rt, opt.name.?)) |existing| {
        if (!existing.destroyed) return error.SessionExists;
    } else |err| if (err != error.SessionNotFound) return err;
    const runtime = try std.fmt.allocPrint(rt.allocator, "{s}/d{s}", .{ rt.env.get("XDG_RUNTIME_DIR").?, (try rt.randomToken())[0..8] });
    if (c.mkdir(try rt.allocator.dupeZ(u8, runtime), 0o700) != 0) return error.RuntimeDirectoryCollision;
    try ensureDirectory(rt, runtime);
    var env = try rt.env.clone(rt.allocator);
    // Experimental injection is scoped to the compositor, never its bus.
    _ = env.swapRemove("LD_PRELOAD");
    _ = env.swapRemove("HYPRLAND_INSTANCE_SIGNATURE");
    _ = env.swapRemove("DISPLAY");
    _ = env.swapRemove("AT_SPI_BUS_ADDRESS");
    try env.put("WAYLAND_DISPLAY", try std.fmt.allocPrint(rt.allocator, "{s}/{s}", .{ rt.env.get("XDG_RUNTIME_DIR").?, std.fs.path.basename(rt.display) }));
    try env.put("XDG_RUNTIME_DIR", runtime);
    try exportProfiles(rt, &env, dir);
    // An invalid libseat backend prevents physical-seat/DRM acquisition. The
    // Wayland backend supplies the render allocator, even in hidden mode.
    try env.put("LIBSEAT_BACKEND", "hyprhand-disabled");
    try env.put("HYPRLAND_NO_SD_VARS", "1");
    try env.put("HYPRLAND_NO_SD_NOTIFY", "1");
    const dbus = try std.fmt.allocPrint(rt.allocator, "unix:path={s}/bus", .{runtime});
    try env.put("DBUS_SESSION_BUS_ADDRESS", dbus);
    try env.put("AT_SPI_BUS_ADDRESS", dbus);
    const bus_config = try scoped.statePath("bus.conf");
    // Do not activate the user's systemd/portal services from this bus.
    const bus_xml = try std.fmt.allocPrint(rt.allocator, "<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen><auth>EXTERNAL</auth><policy context=\"default\"><allow user=\"{d}\"/><allow send_destination=\"*\"/><allow receive_sender=\"*\"/><allow own=\"*\"/></policy></busconfig>", .{c.getuid()});
    try std.Io.Dir.cwd().writeFile(rt.io, .{ .sub_path = bus_config, .data = bus_xml });
    const bus_argv = [_][]const u8{
        "dbus-daemon",
        try std.fmt.allocPrint(rt.allocator, "--config-file={s}", .{bus_config}),
        "--nofork",
        try std.fmt.allocPrint(rt.allocator, "--address={s}", .{dbus}),
    };
    const bus = try spawn(rt, &env, &bus_argv, try scoped.statePath("dbus.log"));
    errdefer terminate(rt, bus) catch {};
    const bus_path = try std.fmt.allocPrintSentinel(rt.allocator, "{s}/bus", .{runtime}, 0);
    for (0..100) |_| {
        if (c.access(bus_path, c.F_OK) == 0) break;
        native.sleepMs(10);
    }
    if (c.access(bus_path, c.F_OK) != 0) return error.SessionBusUnavailable;
    var registry: ?Process = null;
    for ([_][:0]const u8{ "/usr/lib/at-spi2-registryd", "/usr/libexec/at-spi2-registryd" }) |program| {
        if (c.access(program, c.X_OK) == 0) {
            registry = try spawn(rt, &env, &.{program}, try scoped.statePath("accessibility.log"));
            break;
        }
    }
    errdefer if (registry) |process| {
        terminate(rt, process) catch {};
    };
    const config = try scoped.statePath(if (opt.lua) "hyprland.lua" else "hyprland.conf");
    try std.Io.Dir.cwd().writeFile(rt.io, .{ .sub_path = config, .data = try compositorConfig(rt.allocator, opt.lua, opt.nested) });
    var compositor_env = try env.clone(rt.allocator);
    if (opt.headless_bridge) |path| try compositor_env.put("LD_PRELOAD", path);
    const compositor = try spawn(rt, &compositor_env, &.{ "Hyprland", "--config", config }, try scoped.statePath("compositor.log"));
    errdefer terminate(rt, compositor) catch {};
    const discovered = try discoverInstance(rt, runtime, compositor);
    const socket = try Runtime.socketPath(rt.allocator, runtime, discovered.instance);
    if (!opt.nested) {
        const reply = try ipc.request(rt.allocator, socket, "/output create headless HEADLESS-1");
        if (!eq(std.mem.trim(u8, reply, " \r\n"), "ok")) return error.HeadlessOutputFailed;
        // Reapply after output creation: the headless backend initially advertises
        // only its default mode and can report zero geometry until configured.
        const command_text = if (opt.lua) "/eval hl.monitor({output='HEADLESS-1',mode='1920x1080@60',position='0x0',scale=1})" else "/keyword monitor HEADLESS-1,1920x1080@60,0x0,1";
        _ = try ipc.request(rt.allocator, socket, command_text);
    }
    const config_errors = try rt.parseJson([][]const u8, try ipc.request(rt.allocator, socket, "j/configerrors"));
    for (config_errors) |err| if (std.mem.trim(u8, err, " \r\n").len != 0) return error.SessionConfigInvalid;
    if (!try waitForUsableOutput(rt, socket)) return if (opt.nested) error.NestedRenderUnavailable else error.HeadlessRenderUnavailable;
    // Dismiss only this fresh compositor's startup notice (animated progress
    // bar for direct Hyprland launch). No applications have been launched yet.
    _ = try ipc.request(rt.allocator, socket, "/dismissnotify -1");
    const session = Session{
        .name = opt.name.?,
        .compositor = compositor,
        .bus = bus,
        .runtime = runtime,
        .instance = discovered.instance,
        .display = discovered.display,
        .dbus = dbus,
        .directory = dir,
        .nested = opt.nested,
        .registry = registry,
        .headless_bridge = opt.headless_bridge,
    };
    if (!running(session)) return error.SessionStartupFailed;
    try save(rt, session);
    try rt.emit(.{ .ok = true, .session = session, .shared_cursor = false, .filesystem_sandbox = false, .control_enabled = false });
}

/// Every process launched into the session, plus its compositor, registry
/// and bus: the roots whose trees `destroy` terminates.
fn sessionRoots(rt: *Runtime, session: Session) !std.ArrayList(Process) {
    var roots: std.ArrayList(Process) = .empty;
    errdefer roots.deinit(rt.allocator);
    var scoped = rt.withDirectory(session.directory);
    const dir = c.opendir(try rt.allocator.dupeZ(u8, session.directory)) orelse return error.StateDirectoryFailed;
    defer _ = c.closedir(dir);
    while (try native.nextEntry(dir)) |name| {
        if (!std.mem.startsWith(u8, name, "app-") or !std.mem.endsWith(u8, name, ".json")) continue;
        try roots.append(rt.allocator, try rt.parseJson(Process, try rt.readFile(try scoped.statePath(name), 4096)));
    }
    try roots.append(rt.allocator, session.compositor);
    if (session.registry) |registry| try roots.append(rt.allocator, registry);
    try roots.append(rt.allocator, session.bus);
    return roots;
}

pub fn command(rt: *Runtime, opt: Args) !void {
    const verb = opt.value.?;
    if (eq(verb, "create")) return create(rt, opt);
    var session = try load(rt, opt.name.?);
    if (eq(verb, "inspect")) return rt.emit(.{ .ok = true, .session = session, .running = running(session), .filesystem_sandbox = false });
    var scoped = rt.withDirectory(session.directory);
    const lock = try scoped.lock();
    defer _ = c.close(lock);
    // Creation and launch share this lock; metadata loaded before acquiring it
    // may refer to an earlier incarnation of the same session name.
    session = try load(rt, opt.name.?);
    if (!session.destroyed) {
        var roots = try sessionRoots(rt, session);
        defer roots.deinit(rt.allocator);
        try terminateTree(rt, roots.items);
    }
    session.destroyed = true;
    try save(rt, session);
    try rt.emit(.{ .ok = true, .session_id = session.name, .status = "destroyed", .profiles_and_logs_retained = session.directory });
}

pub fn list(rt: *Runtime) !void {
    const base = try root(rt);
    const dir = c.opendir(try rt.allocator.dupeZ(u8, base)) orelse return error.StateDirectoryFailed;
    defer _ = c.closedir(dir);
    const Entry = struct { id: []const u8, running: bool, shared_cursor: bool, nested: bool };
    var entries: std.ArrayList(Entry) = .empty;
    try entries.append(rt.allocator, .{ .id = "host", .running = true, .shared_cursor = true, .nested = false });
    while (try native.nextEntry(dir)) |name| {
        if (!validName(name)) continue;
        const session = load(rt, name) catch continue;
        try entries.append(rt.allocator, .{ .id = session.name, .running = running(session), .shared_cursor = false, .nested = session.nested });
    }
    try rt.emit(.{ .ok = true, .sessions = entries.items });
}

/// Browser profiles live inside the session directory; callers may not point
/// them elsewhere and leak state across sessions.
fn browserArguments(rt: *Runtime, argv: *std.ArrayList([]const u8), program: []const u8, extra: []const []const u8, dir: []const u8) !void {
    const a = rt.allocator;
    if (std.mem.indexOf(u8, program, "brave") != null or std.mem.indexOf(u8, program, "chrom") != null) {
        for (extra) |arg| if (std.mem.startsWith(u8, arg, "--user-data-dir")) return error.ProfileOverrideDenied;
        try argv.appendSlice(a, &.{ try std.fmt.allocPrint(a, "--user-data-dir={s}/browser-profile", .{dir}), "--ozone-platform=wayland", "--no-first-run" });
    } else if (std.mem.indexOf(u8, program, "firefox") != null) {
        for (extra) |arg| if (firefoxProfileOverride(arg)) return error.ProfileOverrideDenied;
        const profile = try std.fmt.allocPrint(a, "{s}/firefox-profile", .{dir});
        try ensureDirectory(rt, profile);
        try argv.appendSlice(a, &.{ "--no-remote", "--profile", profile });
    }
}

pub fn launch(rt: *Runtime, opt: Args) !void {
    // `route` records the directory only for managed sessions; host has none.
    const dir = rt.session_directory orelse return error.ManagedSessionRequired;
    if (opt.dry_run) return rt.emit(.{ .ok = true, .dry_run = true, .session_id = opt.session, .action = "launch" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(rt.allocator, opt.program[0]);
    var scoped = rt.withDirectory(dir);
    const lock = try scoped.lock();
    defer _ = c.close(lock);
    const session = try rt.parseJson(Session, try rt.readFile(try scoped.statePath("session.json"), 16384));
    const same_session = eq(session.name, opt.session) and eq(session.directory, dir) and
        eq(session.runtime, rt.env.get("XDG_RUNTIME_DIR").?) and eq(session.instance, rt.instance);
    if (!same_session or !running(session)) return error.SessionNotRunning;
    try browserArguments(rt, &argv, std.fs.path.basename(opt.program[0]), opt.program[1..], dir);
    try argv.appendSlice(rt.allocator, opt.program[1..]);
    const process = try spawn(rt, rt.env, argv.items, try std.fmt.allocPrint(rt.allocator, "{s}/applications.log", .{dir}));
    errdefer terminate(rt, process) catch {};
    const record = try std.fmt.allocPrint(rt.allocator, "{s}/app-{s}.json", .{ dir, try rt.randomToken() });
    try std.Io.Dir.cwd().writeFile(rt.io, .{ .sub_path = record, .data = try std.json.Stringify.valueAlloc(rt.allocator, process, .{}), .flags = .{ .exclusive = true } });
    try rt.emit(.{ .ok = true, .session_id = opt.session, .action = "launch", .process = process, .status = "started" });
}

fn firefoxProfileOverride(arg: []const u8) bool {
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
        try std.testing.expect(firefoxProfileOverride(arg));
    }
    for ([_][]const u8{ "https://example.org/profile", "--private-window", "--", "-", "--new-window" }) |arg| {
        try std.testing.expect(!firefoxProfileOverride(arg));
    }
}
