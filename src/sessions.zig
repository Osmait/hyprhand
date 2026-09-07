const std = @import("std");
const native = @import("native.zig");
const c = native.c;
const Runtime = @import("runtime.zig").Runtime;
const Args = @import("args.zig").Args;
const ipc = @import("ipc.zig");
const eq = std.mem.eql;

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

fn directory(rt: *Runtime, path: []const u8) !void {
    var scoped = rt.*;
    scoped.directory = path;
    try scoped.prepare();
}
fn root(rt: *Runtime) ![]const u8 {
    const path = try std.fmt.allocPrint(rt.a, "{s}/deskctl-sessions", .{rt.env.get("XDG_RUNTIME_DIR").?});
    try directory(rt, path);
    return path;
}
fn named(rt: *Runtime, name: []const u8) ![]const u8 {
    if (!@import("args.zig").validName(name) or eq(u8, name, "host")) return error.InvalidSessionName;
    return std.fmt.allocPrint(rt.a, "{s}/{s}", .{ try root(rt), name });
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
    const end = std.mem.lastIndexOfScalar(u8, data, ')') orelse return error.InvalidProcessIdentity;
    var fields = std.mem.tokenizeScalar(u8, data[end + 1 ..], ' ');
    const state = fields.next() orelse return error.InvalidProcessIdentity;
    if (state.len != 1) return error.InvalidProcessIdentity;
    if (state[0] == 'Z' or state[0] == 'X') return error.ProcessNotFound;
    const parent = try std.fmt.parseInt(c_int, fields.next() orelse return error.InvalidProcessIdentity, 10);
    for (0..17) |_| _ = fields.next() orelse return error.InvalidProcessIdentity;
    return .{ .start = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidProcessIdentity, 10), .parent = parent, .state = state[0], .uid = st.st_uid };
}
fn startTime(rt: *Runtime, pid: c_int) ![]const u8 {
    return std.fmt.allocPrint(rt.a, "{d}", .{(try processStat(pid)).start});
}
fn alive(rt: *Runtime, process: Process) bool {
    _ = rt;
    const actual = processStat(process.pid) catch return false;
    const expected = std.fmt.parseInt(u64, process.start, 10) catch return false;
    return actual.start == expected;
}
fn running(rt: *Runtime, session: Session) bool {
    return !session.destroyed and alive(rt, session.compositor) and alive(rt, session.bus);
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
        if (c.syscall(c.SYS_pidfd_send_signal, self.fd, sig, @as(?*anyopaque, null), @as(c_uint, 0)) < 0 and c.__errno_location().* != c.ESRCH) return error.SessionStopFailed;
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
        if (c.__errno_location().* == c.ESRCH) return;
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
        while (true) {
            c.__errno_location().* = 0;
            const entry = c.readdir(proc) orelse {
                if (c.__errno_location().* != 0) return error.ProcessScanFailed;
                break;
            };
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
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

fn terminateTree(rt: *Runtime, roots: []const Process) !void {
    var tree: std.ArrayList(Tracked) = .empty;
    defer {
        for (tree.items) |item| {
            if (item.needs_resume) item.signal(c.SIGCONT) catch {};
            _ = c.close(item.fd);
        }
        tree.deinit(rt.a);
    }
    for (roots) |process| {
        if (!alive(rt, process)) continue;
        // Even corrupted metadata must not stop the caller or its ancestors.
        var ancestor = c.getpid();
        while (ancestor > 1) {
            if (ancestor == process.pid) return error.UnsafeProcessTarget;
            ancestor = (try processStat(ancestor)).parent;
        }
        try track(rt.a, &tree, process.pid, try std.fmt.parseInt(u64, process.start, 10), null);
    }
    // Freeze and pin all roots and descendants before any parent can exit in
    // response to TERM and orphan children. Holding pidfds protects escalation.
    try collectTree(rt.a, &tree);
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
    try collectTree(rt.a, &tree);
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
fn spawn(rt: *Runtime, env: *std.process.Environ.Map, argv: []const []const u8, output: []const u8) !Process {
    const fd = c.open(try rt.a.dupeZ(u8, output), c.O_WRONLY | c.O_APPEND | c.O_CREAT | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
    if (fd < 0) return error.SessionLogFailed;
    defer _ = c.close(fd);
    var child = try std.process.spawn(rt.io, .{ .argv = argv, .environ_map = env, .pgid = 0, .stdin = .ignore, .stdout = .{ .file = .{ .handle = fd, .flags = .{ .nonblocking = false } } }, .stderr = .{ .file = .{ .handle = fd, .flags = .{ .nonblocking = false } } } });
    errdefer child.kill(rt.io);
    return .{ .pid = child.id.?, .start = try startTime(rt, child.id.?) };
}
fn save(rt: *Runtime, session: Session) !void {
    const path = try std.fmt.allocPrintSentinel(rt.a, "{s}/session.json", .{session.directory}, 0);
    const tmp = try std.fmt.allocPrintSentinel(rt.a, "{s}/metadata-{s}.tmp", .{ session.directory, try rt.id() }, 0);
    defer _ = c.unlink(tmp);
    try std.Io.Dir.cwd().writeFile(rt.io, .{ .sub_path = tmp, .data = try std.json.Stringify.valueAlloc(rt.a, session, .{}), .flags = .{ .exclusive = true } });
    if (c.rename(tmp, path) < 0) return error.StateWriteFailed;
}
pub fn load(rt: *Runtime, name: []const u8) !Session {
    const dir = try named(rt, name);
    var st: c.struct_stat = undefined;
    if (c.lstat(try rt.a.dupeZ(u8, dir), &st) < 0) return error.SessionNotFound;
    try directory(rt, dir);
    const data = rt.read(try std.fmt.allocPrint(rt.a, "{s}/session.json", .{dir}), 16384) catch return error.SessionNotFound;
    const session = try rt.json(Session, data);
    if (session.schema != 1 or !eq(u8, session.name, name) or !eq(u8, session.directory, dir)) return error.InvalidSessionMetadata;
    const prefix = try std.fmt.allocPrint(rt.a, "{s}/d", .{rt.env.get("XDG_RUNTIME_DIR").?});
    const old_prefix = try std.fmt.allocPrint(rt.a, "{s}/dc-", .{rt.env.get("XDG_RUNTIME_DIR").?});
    const runtime_ok = (std.mem.startsWith(u8, session.runtime, prefix) and session.runtime.len == prefix.len + 8) or (std.mem.startsWith(u8, session.runtime, old_prefix) and session.runtime.len == old_prefix.len + 8);
    if (!runtime_ok or std.mem.indexOfScalar(u8, session.runtime[prefix.len..], '/') != null or std.mem.indexOfScalar(u8, session.instance, '/') != null or std.mem.indexOfScalar(u8, session.display, '/') != null) return error.InvalidSessionMetadata;
    return session;
}
pub fn route(rt: *Runtime, name: []const u8) !void {
    if (eq(u8, name, "host")) return;
    const session = try load(rt, name);
    if (!running(rt, session)) return error.SessionNotRunning;
    const env = try rt.a.create(std.process.Environ.Map);
    env.* = try rt.env.clone(rt.a);
    try env.put("XDG_RUNTIME_DIR", session.runtime);
    try env.put("WAYLAND_DISPLAY", session.display);
    try env.put("HYPRLAND_INSTANCE_SIGNATURE", session.instance);
    try env.put("DBUS_SESSION_BUS_ADDRESS", session.dbus);
    _ = env.swapRemove("DISPLAY");
    if (session.registry != null) try env.put("AT_SPI_BUS_ADDRESS", session.dbus) else _ = env.swapRemove("AT_SPI_BUS_ADDRESS");
    try env.put("GDK_BACKEND", "wayland");
    try env.put("QT_QPA_PLATFORM", "wayland");
    try env.put("MOZ_ENABLE_WAYLAND", "1");
    for ([_][]const u8{ "CONFIG", "CACHE", "DATA", "STATE" }) |kind| {
        const path = try std.fmt.allocPrint(rt.a, "{s}/profile-{s}", .{ session.directory, kind });
        try directory(rt, path);
        try env.put(try std.fmt.allocPrint(rt.a, "XDG_{s}_HOME", .{kind}), path);
    }
    rt.env = env;
    rt.session_id = name;
    rt.instance = session.instance;
    rt.display = session.display;
    rt.socket = try std.fmt.allocPrint(rt.a, "{s}/hypr/{s}/.socket.sock", .{ session.runtime, session.instance });
    rt.directory = try std.fmt.allocPrint(rt.a, "{s}/deskctl-{x}", .{ session.runtime, std.hash.Wyhash.hash(0, session.instance) });
    // Never call setenv: libc can invalidate Zig's startup environment block.
    // Native Wayland gets an absolute socket; children get this explicit map.
    try rt.validateDisplay();
}

fn create(rt: *Runtime, opt: Args) !void {
    try rt.validateDisplay();
    if (opt.headless_bridge) |path| {
        var st: c.struct_stat = undefined;
        if (c.lstat(try rt.a.dupeZ(u8, path), &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG or
            (st.st_uid != c.getuid() and st.st_uid != 0) or (st.st_mode & 0o022) != 0) return error.InvalidHeadlessBridge;
    }
    const dir = try named(rt, opt.name.?);
    try directory(rt, dir);
    var scoped = rt.*;
    scoped.directory = dir;
    const lock = try scoped.lock();
    defer _ = c.close(lock);
    if (load(rt, opt.name.?)) |existing| {
        if (!existing.destroyed) return error.SessionExists;
    } else |err| if (err != error.SessionNotFound) return err;
    const runtime = try std.fmt.allocPrint(rt.a, "{s}/d{s}", .{ rt.env.get("XDG_RUNTIME_DIR").?, (try rt.id())[0..8] });
    if (c.mkdir(try rt.a.dupeZ(u8, runtime), 0o700) != 0) return error.RuntimeDirectoryCollision;
    try directory(rt, runtime);
    var env = try rt.env.clone(rt.a);
    // Experimental injection is scoped to the compositor, never its bus.
    _ = env.swapRemove("LD_PRELOAD");
    _ = env.swapRemove("HYPRLAND_INSTANCE_SIGNATURE");
    _ = env.swapRemove("DISPLAY");
    _ = env.swapRemove("AT_SPI_BUS_ADDRESS");
    try env.put("WAYLAND_DISPLAY", try std.fmt.allocPrint(rt.a, "{s}/{s}", .{ rt.env.get("XDG_RUNTIME_DIR").?, std.fs.path.basename(rt.display) }));
    try env.put("XDG_RUNTIME_DIR", runtime);
    for ([_][]const u8{ "CONFIG", "CACHE", "DATA", "STATE" }) |kind| {
        const profile = try std.fmt.allocPrint(rt.a, "{s}/profile-{s}", .{ dir, kind });
        try directory(rt, profile);
        try env.put(try std.fmt.allocPrint(rt.a, "XDG_{s}_HOME", .{kind}), profile);
    }
    // An invalid libseat backend prevents physical-seat/DRM acquisition. The
    // Wayland backend supplies the render allocator, even in hidden mode.
    try env.put("LIBSEAT_BACKEND", "deskctl-disabled");
    try env.put("HYPRLAND_NO_SD_VARS", "1");
    try env.put("HYPRLAND_NO_SD_NOTIFY", "1");
    const dbus = try std.fmt.allocPrint(rt.a, "unix:path={s}/bus", .{runtime});
    try env.put("DBUS_SESSION_BUS_ADDRESS", dbus);
    try env.put("AT_SPI_BUS_ADDRESS", dbus);
    const bus_config = try scoped.path("bus.conf");
    // Do not activate the user's systemd/portal services from this bus.
    const bus_xml = try std.fmt.allocPrint(rt.a, "<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen><auth>EXTERNAL</auth><policy context=\"default\"><allow user=\"{d}\"/><allow send_destination=\"*\"/><allow receive_sender=\"*\"/><allow own=\"*\"/></policy></busconfig>", .{c.getuid()});
    try std.Io.Dir.cwd().writeFile(rt.io, .{ .sub_path = bus_config, .data = bus_xml });
    const bus = try spawn(rt, &env, &.{ "dbus-daemon", try std.fmt.allocPrint(rt.a, "--config-file={s}", .{bus_config}), "--nofork", try std.fmt.allocPrint(rt.a, "--address={s}", .{dbus}) }, try scoped.path("dbus.log"));
    errdefer terminate(rt, bus) catch {};
    const bus_path = try std.fmt.allocPrintSentinel(rt.a, "{s}/bus", .{runtime}, 0);
    for (0..100) |_| {
        if (c.access(bus_path, c.F_OK) == 0) break;
        native.sleepMs(10);
    }
    if (c.access(bus_path, c.F_OK) != 0) return error.SessionBusUnavailable;
    var registry: ?Process = null;
    for ([_][:0]const u8{ "/usr/lib/at-spi2-registryd", "/usr/libexec/at-spi2-registryd" }) |program| {
        if (c.access(program, c.X_OK) == 0) {
            registry = try spawn(rt, &env, &.{program}, try scoped.path("accessibility.log"));
            break;
        }
    }
    errdefer if (registry) |process| {
        terminate(rt, process) catch {};
    };
    const config = try scoped.path(if (opt.lua) "hyprland.lua" else "hyprland.conf");
    const content = if (opt.lua) try std.fmt.allocPrint(rt.a, "hl.monitor({{output='WAYLAND-1',mode='1280x720@60',position='0x0',scale=1,disabled={s}}})\nhl.monitor({{output='HEADLESS-1',mode='1280x720@60',position='0x0',scale=1}})\nhl.config({{animations={{enabled=false}},xwayland={{enabled=false}},misc={{disable_hyprland_logo=true,disable_splash_rendering=true}}}})\n", .{if (opt.nested) "false" else "true"}) else try std.fmt.allocPrint(rt.a, "monitor = WAYLAND-1,{s}\nmonitor = HEADLESS-1,1280x720@60,0x0,1\nanimations:enabled = false\nxwayland:enabled = false\nmisc:disable_hyprland_logo = true\nmisc:disable_splash_rendering = true\n", .{if (opt.nested) "1280x720@60,0x0,1" else "disable"});
    try std.Io.Dir.cwd().writeFile(rt.io, .{ .sub_path = config, .data = content });
    var display: []const u8 = "";
    var compositor_env = try env.clone(rt.a);
    if (opt.headless_bridge) |path| try compositor_env.put("LD_PRELOAD", path);
    const compositor = try spawn(rt, &compositor_env, &.{ "Hyprland", "--config", config }, try scoped.path("compositor.log"));
    errdefer terminate(rt, compositor) catch {};
    const end = native.nowMs() + 10_000;
    var instance: ?[]const u8 = null;
    while (native.nowMs() < end) {
        try native.checkCancelled();
        if (!alive(rt, compositor)) return error.SessionStartupFailed;
        const hyprdir = c.opendir(try rt.a.dupeZ(u8, try std.fmt.allocPrint(rt.a, "{s}/hypr", .{runtime})));
        if (hyprdir) |hd| {
            defer _ = c.closedir(hd);
            while (c.readdir(hd)) |entry| {
                const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
                if (name[0] == '.') continue;
                const data = rt.read(try std.fmt.allocPrint(rt.a, "{s}/hypr/{s}/hyprland.lock", .{ runtime, name }), 4096) catch continue;
                var lines = std.mem.tokenizeAny(u8, data, "\r\n");
                const pid = std.fmt.parseInt(c_int, lines.next() orelse continue, 10) catch continue;
                if (pid != compositor.pid) continue;
                display = try rt.a.dupe(u8, lines.next() orelse continue);
                const socket = try std.fmt.allocPrint(rt.a, "{s}/hypr/{s}/.socket.sock", .{ runtime, name });
                _ = ipc.request(rt.a, socket, "j/version") catch continue;
                instance = try rt.a.dupe(u8, name);
                break;
            }
        }
        if (instance != null) break;
        native.sleepMs(50);
    }
    if (instance == null) return error.SessionStartupTimeout;
    const socket = try std.fmt.allocPrint(rt.a, "{s}/hypr/{s}/.socket.sock", .{ runtime, instance.? });
    if (!opt.nested) {
        const reply = try ipc.request(rt.a, socket, "/output create headless HEADLESS-1");
        if (!eq(u8, std.mem.trim(u8, reply, " \r\n"), "ok")) return error.HeadlessOutputFailed;
    }
    if (!opt.nested) {
        // Reapply after output creation: the headless backend initially advertises
        // only its default mode and can report zero geometry until configured.
        const command_text = if (opt.lua) "/eval hl.monitor({output='HEADLESS-1',mode='1920x1080@60',position='0x0',scale=1})" else "/keyword monitor HEADLESS-1,1920x1080@60,0x0,1";
        _ = try ipc.request(rt.a, socket, command_text);
    }
    const errors = try ipc.request(rt.a, socket, "j/configerrors");
    const config_errors = try rt.json([][]const u8, errors);
    for (config_errors) |err| if (std.mem.trim(u8, err, " \r\n").len != 0) return error.SessionConfigInvalid;
    var usable = false;
    for (0..30) |_| {
        const monitors = try rt.json([]struct { width: u32, height: u32 }, try ipc.request(rt.a, socket, "j/monitors"));
        for (monitors) |monitor| if (monitor.width > 0 and monitor.height > 0) {
            usable = true;
            break;
        };
        if (usable) break;
        native.sleepMs(50);
    }
    if (!usable) return if (opt.nested) error.NestedRenderUnavailable else error.HeadlessRenderUnavailable;
    // Dismiss only this fresh compositor's startup notice (animated progress
    // bar for direct Hyprland launch). No applications have been launched yet.
    _ = try ipc.request(rt.a, socket, "/dismissnotify -1");
    const session = Session{ .name = opt.name.?, .compositor = compositor, .bus = bus, .runtime = runtime, .instance = instance.?, .display = display, .dbus = dbus, .directory = dir, .nested = opt.nested, .registry = registry, .headless_bridge = opt.headless_bridge };
    if (!running(rt, session)) return error.SessionStartupFailed;
    try save(rt, session);
    try rt.emit(.{ .ok = true, .session = session, .shared_cursor = false, .filesystem_sandbox = false, .control_enabled = false });
}

pub fn command(rt: *Runtime, opt: Args) !void {
    if (eq(u8, opt.value.?, "create")) return create(rt, opt);
    var session = try load(rt, opt.name.?);
    if (eq(u8, opt.value.?, "inspect")) return rt.emit(.{ .ok = true, .session = session, .running = running(rt, session), .filesystem_sandbox = false });
    var scoped = rt.*;
    scoped.directory = session.directory;
    const lock = try scoped.lock();
    defer _ = c.close(lock);
    // Creation and launch share this lock; metadata loaded before acquiring it
    // may refer to an earlier incarnation of the same session name.
    session = try load(rt, opt.name.?);
    var roots: std.ArrayList(Process) = .empty;
    defer roots.deinit(rt.a);
    if (!session.destroyed) {
        const dir = c.opendir(try rt.a.dupeZ(u8, session.directory)) orelse return error.StateDirectoryFailed;
        defer _ = c.closedir(dir);
        while (true) {
            c.__errno_location().* = 0;
            const entry = c.readdir(dir) orelse {
                if (c.__errno_location().* != 0) return error.ProcessScanFailed;
                break;
            };
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            if (!std.mem.startsWith(u8, name, "app-") or !std.mem.endsWith(u8, name, ".json")) continue;
            const process = try rt.json(Process, try rt.read(try scoped.path(name), 4096));
            try roots.append(rt.a, process);
        }
        try roots.append(rt.a, session.compositor);
        if (session.registry) |registry| try roots.append(rt.a, registry);
        try roots.append(rt.a, session.bus);
        try terminateTree(rt, roots.items);
    }
    session.destroyed = true;
    try save(rt, session);
    try rt.emit(.{ .ok = true, .session_id = session.name, .status = "destroyed", .profiles_and_logs_retained = session.directory });
}

pub fn list(rt: *Runtime) !void {
    const base = try root(rt);
    const dir = c.opendir(try rt.a.dupeZ(u8, base)) orelse return error.StateDirectoryFailed;
    defer _ = c.closedir(dir);
    const Entry = struct { id: []const u8, running: bool, shared_cursor: bool, nested: bool };
    var entries: std.ArrayList(Entry) = .empty;
    try entries.append(rt.a, .{ .id = "host", .running = true, .shared_cursor = true, .nested = false });
    while (c.readdir(dir)) |item| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&item.*.d_name)));
        if (!@import("args.zig").validName(name)) continue;
        const session = load(rt, name) catch continue;
        try entries.append(rt.a, .{ .id = session.name, .running = running(rt, session), .shared_cursor = false, .nested = session.nested });
    }
    try rt.emit(.{ .ok = true, .sessions = entries.items });
}

pub fn launch(rt: *Runtime, opt: Args) !void {
    if (eq(u8, opt.session, "host")) return error.ManagedSessionRequired;
    if (opt.dry_run) return rt.emit(.{ .ok = true, .dry_run = true, .session_id = opt.session, .action = "launch" });
    try rt.guard();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(rt.a, opt.program[0]);
    const program = std.fs.path.basename(opt.program[0]);
    const dir = std.fs.path.dirname(rt.env.get("XDG_CONFIG_HOME").?).?;
    var scoped = rt.*;
    scoped.directory = dir;
    const lock = try scoped.lock();
    defer _ = c.close(lock);
    const session = try rt.json(Session, try rt.read(try scoped.path("session.json"), 16384));
    if (!eq(u8, session.name, opt.session) or !eq(u8, session.directory, dir) or
        !eq(u8, session.runtime, rt.env.get("XDG_RUNTIME_DIR").?) or !eq(u8, session.instance, rt.instance) or
        !running(rt, session)) return error.SessionNotRunning;
    if (std.mem.indexOf(u8, program, "brave") != null or std.mem.indexOf(u8, program, "chrom") != null) {
        for (opt.program[1..]) |arg| if (std.mem.startsWith(u8, arg, "--user-data-dir")) return error.ProfileOverrideDenied;
        try argv.appendSlice(rt.a, &.{ try std.fmt.allocPrint(rt.a, "--user-data-dir={s}/browser-profile", .{dir}), "--ozone-platform=wayland", "--no-first-run" });
    } else if (std.mem.indexOf(u8, program, "firefox") != null) {
        for (opt.program[1..]) |arg| if (firefoxProfileOverride(arg)) return error.ProfileOverrideDenied;
        const profile = try std.fmt.allocPrint(rt.a, "{s}/firefox-profile", .{dir});
        try directory(rt, profile);
        try argv.appendSlice(rt.a, &.{ "--no-remote", "--profile", profile });
    }
    try argv.appendSlice(rt.a, opt.program[1..]);
    var env = try rt.env.clone(rt.a);
    const process = try spawn(rt, &env, argv.items, try std.fmt.allocPrint(rt.a, "{s}/applications.log", .{dir}));
    errdefer terminate(rt, process) catch {};
    try std.Io.Dir.cwd().writeFile(rt.io, .{ .sub_path = try std.fmt.allocPrint(rt.a, "{s}/app-{s}.json", .{ dir, try rt.id() }), .data = try std.json.Stringify.valueAlloc(rt.a, process, .{}), .flags = .{ .exclusive = true } });
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
