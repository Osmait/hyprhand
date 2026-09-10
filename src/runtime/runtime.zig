const std = @import("std");
const native = @import("../platform/native.zig");
const c = native.c;
const ipc = @import("../platform/ipc.zig");
const child_process = @import("../platform/child_process.zig");
const text = @import("../core/text.zig");
const eq = text.eq;

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    instance: []const u8,
    display: []const u8,
    socket: []const u8,
    /// Per-compositor state directory (frames, locks, audit log, tokens).
    directory: []const u8,
    /// Managed session directory (metadata, profiles, logs); null for host.
    session_directory: ?[]const u8 = null,
    control_token: ?[]const u8 = null,
    session_id: []const u8 = "host",
    target_window: ?[]const u8 = null,
    extra_guard: ?*const fn (*Runtime, *anyopaque) anyerror!void = null,
    guard_context: ?*anyopaque = null,
    guard_arena: ?*std.heap.ArenaAllocator = null,

    pub fn init(context: std.process.Init) !Runtime {
        const allocator = context.arena.allocator();
        const runtime = context.environ_map.get("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDir;
        const instance = context.environ_map.get("HYPRLAND_INSTANCE_SIGNATURE") orelse return error.MissingHyprlandSession;
        const display = context.environ_map.get("WAYLAND_DISPLAY") orelse return error.MissingWaylandDisplay;
        if (!std.fs.path.isAbsolute(runtime) or std.mem.indexOfScalar(u8, instance, '/') != null or instance.len == 0) return error.InvalidSessionEnvironment;
        return .{
            .allocator = allocator,
            .io = context.io,
            .env = context.environ_map,
            .instance = instance,
            .display = display,
            .socket = try socketPath(allocator, runtime, instance),
            .directory = try stateDirectory(allocator, runtime, instance),
        };
    }

    pub fn socketPath(allocator: std.mem.Allocator, runtime: []const u8, instance: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}/hypr/{s}/.socket.sock", .{ runtime, instance });
    }

    pub fn stateDirectory(allocator: std.mem.Allocator, runtime: []const u8, instance: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}/hyprhand-{x}", .{ runtime, std.hash.Wyhash.hash(0, instance) });
    }

    /// A copy of this runtime whose allocations go to `allocator`. Used for
    /// short-lived work (polling, guards) so the main arena does not grow.
    pub fn scratch(self: *const Runtime, allocator: std.mem.Allocator) Runtime {
        var copy = self.*;
        copy.allocator = allocator;
        return copy;
    }

    /// A copy of this runtime whose state directory is `directory`. Used to
    /// take locks and build paths inside a managed session directory.
    pub fn withDirectory(self: *const Runtime, directory: []const u8) Runtime {
        var copy = self.*;
        copy.directory = directory;
        return copy;
    }

    pub fn statePath(self: *Runtime, name: []const u8) ![:0]const u8 {
        return std.fmt.allocPrintSentinel(self.allocator, "{s}/{s}", .{ self.directory, name }, 0);
    }

    pub fn displayPath(self: *Runtime) ![:0]const u8 {
        if (std.fs.path.isAbsolute(self.display)) return self.allocator.dupeZ(u8, self.display);
        return std.fmt.allocPrintSentinel(self.allocator, "{s}/{s}", .{ self.env.get("XDG_RUNTIME_DIR").?, self.display }, 0);
    }

    pub fn prepare(self: *Runtime) !void {
        const path_z = try self.allocator.dupeZ(u8, self.directory);
        if (c.mkdir(path_z, 0o700) < 0 and native.errno() != c.EEXIST) return error.StateDirectoryFailed;
        var st: c.struct_stat = undefined;
        if (c.lstat(path_z, &st) < 0 or (st.st_mode & c.S_IFMT) != c.S_IFDIR or st.st_uid != c.getuid() or (st.st_mode & 0o077) != 0) return error.UnsafeStateDirectory;
    }

    pub fn query(self: *Runtime, command: []const u8) ![]const u8 {
        return ipc.request(self.allocator, self.socket, try std.fmt.allocPrint(self.allocator, "j/{s}", .{command}));
    }

    pub fn parseJson(self: *Runtime, comptime T: type, data: []const u8) !T {
        const parsed = try std.json.parseFromSlice(T, self.allocator, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        return parsed.value;
    }

    /// Query a Hyprland JSON endpoint and parse it in one step.
    pub fn queryJson(self: *Runtime, comptime T: type, command: []const u8) !T {
        return self.parseJson(T, try self.query(command));
    }

    pub fn configProvider(self: *Runtime) ![]const u8 {
        return (try self.queryJson(struct { configProvider: []const u8 }, "status")).configProvider;
    }

    pub fn activeWindow(self: *Runtime) ![]const u8 {
        return (try self.queryJson(struct { address: []const u8 = "" }, "activewindow")).address;
    }

    pub fn emit(self: *Runtime, data: anytype) !void {
        // Bounded streaming output: no per-event serialization allocations.
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stdout().writer(self.io, &buffer);
        try std.json.Stringify.value(data, .{}, &writer.interface);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
    }

    /// Sends a raw command and requires Hyprland's literal "ok" reply.
    pub fn expectOk(self: *Runtime, request: []const u8, failure: anyerror) !void {
        const reply = try ipc.request(self.allocator, self.socket, request);
        if (!eq(std.mem.trim(u8, reply, " \r\n"), "ok")) return failure;
    }

    pub fn dispatch(self: *Runtime, name: []const u8, arg: []const u8) !void {
        const provider = try self.configProvider();
        try self.guard();
        const request = if (eq(provider, "hyprlang"))
            try std.fmt.allocPrint(self.allocator, "/dispatch {s} {s}", .{ name, arg })
        else if (eq(provider, "lua"))
            try self.luaDispatch(name, arg)
        else
            return error.UnsupportedConfigProvider;
        try self.expectOk(request, error.DispatchFailed);
    }

    // Only construct these three dispatchers. User text is never Lua.
    fn luaDispatch(self: *Runtime, name: []const u8, arg: []const u8) ![]const u8 {
        if (eq(name, "workspace")) {
            const id_value = try std.fmt.parseInt(u32, arg, 10);
            return std.fmt.allocPrint(self.allocator, "/dispatch hl.dsp.focus({{workspace='{d}'}})", .{id_value});
        }
        if (eq(name, "focuswindow")) {
            if (!std.mem.startsWith(u8, arg, "address:0x")) return error.InvalidWindowAddress;
            for (arg["address:0x".len..]) |ch| if (!std.ascii.isHex(ch)) return error.InvalidWindowAddress;
            return std.fmt.allocPrint(self.allocator, "/dispatch hl.dsp.focus({{window='{s}'}})", .{arg});
        }
        if (eq(name, "movecursor")) {
            var parts = std.mem.tokenizeScalar(u8, arg, ' ');
            const x = try std.fmt.parseInt(i32, parts.next() orelse return error.InvalidCoordinates, 10);
            const y = try std.fmt.parseInt(i32, parts.next() orelse return error.InvalidCoordinates, 10);
            if (parts.next() != null) return error.InvalidCoordinates;
            return std.fmt.allocPrint(self.allocator, "/dispatch hl.dsp.cursor.move({{x={d},y={d}}})", .{ x, y });
        }
        return error.UnsupportedDispatcher;
    }

    pub fn readFile(self: *Runtime, path_name: []const u8, limit: usize) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path_name, self.allocator, .limited(limit));
    }

    pub fn unlocked(self: *Runtime) !void {
        const status = try self.queryJson(struct { locked: bool }, "locked");
        if (status.locked) return error.SessionLocked;
    }

    pub fn validateDisplay(self: *Runtime) !void {
        // The lock file written by Hyprland binds this IPC instance to Wayland.
        const dir = std.fs.path.dirname(self.socket).?;
        const lock_data = try self.readFile(try std.fmt.allocPrint(self.allocator, "{s}/hyprland.lock", .{dir}), 4096);
        var lines = std.mem.tokenizeAny(u8, lock_data, "\r\n");
        _ = lines.next() orelse return error.InvalidSessionEnvironment;
        const socket_name = lines.next() orelse return error.InvalidSessionEnvironment;
        const display_name = std.fs.path.basename(self.display);
        if (!eq(socket_name, display_name)) return error.SessionMismatch;
        if (std.fs.path.isAbsolute(self.display)) {
            const expected = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.env.get("XDG_RUNTIME_DIR").?, socket_name });
            if (!eq(self.display, expected)) return error.SessionMismatch;
        }
    }

    pub fn token(self: *Runtime) ![]const u8 {
        const path_z = try self.statePath("enabled");
        return self.readFile(path_z, 128) catch |err| switch (err) {
            error.FileNotFound => error.ControlStopped,
            else => err,
        };
    }

    pub fn guard(self: *Runtime) !void {
        try native.checkCancelled();
        const expected = self.control_token orelse return error.ControlStopped;
        var local = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer local.deinit();
        const arena = self.guard_arena orelse &local;
        defer _ = arena.reset(.{ .retain_with_limit = 256 * 1024 });
        var checker = self.scratch(arena.allocator());
        // A nested guard must not reset the arena this check is still using.
        checker.guard_arena = null;
        const actual = try checker.token();
        if (!eq(expected, actual)) return error.ControlStopped;
        try checker.unlocked();
        if (self.target_window) |target| {
            if (!eq(target, try checker.activeWindow())) return error.WindowNotFocused;
        }
        if (self.extra_guard) |check| try check(&checker, self.guard_context.?);
    }

    pub fn pause(self: *Runtime, ms: u32) !void {
        const end = native.nowMs() + ms;
        while (native.nowMs() < end) {
            if (self.control_token != null) try self.guard() else try native.checkCancelled();
            native.sleepMs(@intCast(@max(0, @min(20, end - native.nowMs()))));
        }
    }

    fn openLockFile(self: *Runtime, name: []const u8) !c_int {
        const fd = c.open(try self.statePath(name), c.O_CREAT | c.O_RDWR | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
        if (fd < 0) return error.ControlLockFailed;
        return fd;
    }

    /// Acquires an exclusive lock, retrying briefly instead of failing on the
    /// first contention. Returns `busy` once `wait_ms` elapses.
    pub fn flockWithin(fd: c_int, wait_ms: u32, busy: anyerror) !void {
        const deadline = native.nowMs() + wait_ms;
        while (c.flock(fd, c.LOCK_EX | c.LOCK_NB) < 0) {
            const err = native.errno();
            if (err != c.EWOULDBLOCK and err != c.EINTR) return error.ControlLockFailed;
            if (native.nowMs() >= deadline) return busy;
            native.sleepMs(5);
        }
    }

    /// The action lock: held for the whole duration of one input command.
    pub fn lock(self: *Runtime) !c_int {
        try self.prepare();
        const fd = try self.openLockFile("action.lock");
        errdefer _ = c.close(fd);
        if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) < 0) return error.ControlBusy;
        return fd;
    }

    /// 128 random bits as lowercase hex: tokens, epochs, frame and file names.
    pub fn randomToken(self: *Runtime) ![]const u8 {
        var bytes: [16]u8 = undefined;
        if (c.getrandom(&bytes, bytes.len, 0) != bytes.len) return error.RandomFailed;
        return self.allocator.dupe(u8, &std.fmt.bytesToHex(bytes, .lower));
    }

    pub fn enable(self: *Runtime, indicator: []const u8) !void {
        const lock_fd = try self.lock();
        defer _ = c.close(lock_fd);
        const initial_generation = try self.controlGeneration();
        try self.validateDisplay();
        try self.unlocked();
        const name = try self.randomToken();
        const tmp = try self.statePath(name);
        const enabled_path = try self.statePath("enabled");
        const outline_path = try self.statePath("outline");
        defer _ = c.unlink(tmp);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = tmp, .data = name, .flags = .{ .exclusive = true } });
        {
            const authority = try self.authorityLock();
            defer _ = c.close(authority);
            if (!eq(initial_generation, try self.generation())) return error.ControlStopped;
            if (c.rename(tmp, enabled_path) < 0) return error.StateWriteFailed;
        }
        errdefer _ = c.unlink(enabled_path);
        _ = c.unlink(outline_path);
        if (eq(indicator, "outline")) {
            if (!eq(try self.configProvider(), "hyprlang")) return error.OutlineRequiresHyprlang;
            // The optional plugin must already be loaded by the user. Never
            // load code into the compositor as a side effect of enabling input.
            const request = try std.fmt.allocPrint(self.allocator, "/dispatch hyprhand:outline {s}", .{enabled_path});
            try self.expectOk(request, error.OutlinePluginUnavailable);
            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = outline_path, .data = name, .flags = .{ .exclusive = true } });
        }
        if (!eq(name, try self.token())) return error.ControlStopped;
        try self.emit(.{ .ok = true, .session_id = self.session_id, .control = "enabled", .indicator = indicator, .shared_cursor = self.isHost() });
    }

    pub fn isHost(self: *const Runtime) bool {
        return eq(self.session_id, "host");
    }

    pub fn outlineEnabled(self: *Runtime) !bool {
        const marker = self.readFile(try self.statePath("outline"), 128) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return eq(marker, self.control_token orelse return false);
    }

    pub fn stop(self: *Runtime) !void {
        try self.prepare();
        const authority = try self.authorityLock();
        defer _ = c.close(authority);
        // Enable creates the epoch BEFORE IPC. Removing it invalidates every
        // in-flight enable without allocating disk space or writing new data.
        // Attempt all revocations even if one fails; never strand the token
        // merely because publishing a new journal entry failed.
        var failed = false;
        for ([_][]const u8{ "stop-generation", "enabled", "outline" }) |name| {
            if (c.unlink(try self.statePath(name)) < 0 and native.errno() != c.ENOENT) failed = true;
        }
        if (failed) return error.StateWriteFailed;
        try self.emit(.{ .ok = true, .session_id = self.session_id, .control = "stopped" });
    }

    fn generation(self: *Runtime) ![]const u8 {
        return self.readFile(try self.statePath("stop-generation"), 128) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
    }

    fn controlGeneration(self: *Runtime) ![]const u8 {
        const fd = try self.authorityLock();
        defer _ = c.close(fd);
        const current = try self.generation();
        if (current.len != 0) return current;
        const epoch = try self.randomToken();
        const temp = try self.statePath(epoch);
        defer _ = c.unlink(temp);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = temp, .data = epoch, .flags = .{ .exclusive = true } });
        if (c.rename(temp, try self.statePath("stop-generation")) < 0) return error.StateWriteFailed;
        return epoch;
    }

    // This separate lock protects only local atomic publication, never IPC
    // or input, so stop remains independent from the long-held action lock.
    fn authorityLock(self: *Runtime) !c_int {
        const fd = try self.openLockFile("control.lock");
        errdefer _ = c.close(fd);
        try flockWithin(fd, 500, error.ControlBusy);
        return fd;
    }

    pub fn executable(self: *Runtime, name: []const u8) !bool {
        var paths = std.mem.splitScalar(u8, self.env.get("PATH") orelse "", ':');
        while (paths.next()) |dir| {
            const candidate = try std.fmt.allocPrintSentinel(self.allocator, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name }, 0);
            if (c.access(candidate, c.X_OK) == 0) return true;
        }
        return false;
    }

    fn inputBuffer(input: []const u8) !c_int {
        const fd = c.memfd_create("hyprhand-input", c.MFD_CLOEXEC);
        if (fd < 0) return error.InputBufferFailed;
        errdefer _ = c.close(fd);
        var written: usize = 0;
        while (written < input.len) {
            const n = c.write(fd, input.ptr + written, input.len - written);
            if (n <= 0) return error.InputBufferFailed;
            written += @intCast(n);
        }
        if (c.lseek(fd, 0, c.SEEK_SET) < 0) return error.InputBufferFailed;
        return fd;
    }

    /// Run a bounded helper, with no shell and no text in its argv.
    /// pidfd polling allows stop to cancel without reaping outside Zig's child API.
    pub fn runHelper(self: *Runtime, argv: []const []const u8, input: ?[]const u8, controlled: bool) !void {
        const stdin_fd: c_int = if (input) |data| try inputBuffer(data) else -1;
        defer if (stdin_fd >= 0) {
            _ = c.close(stdin_fd);
        };
        if (controlled) try self.guard();
        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .environ_map = self.env,
            .stdin = if (stdin_fd >= 0) .{ .file = .{ .handle = stdin_fd, .flags = .{ .nonblocking = false } } } else .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
        });
        defer child_process.terminate(&child, self.io);
        const pidfd: c_int = @intCast(c.syscall(c.SYS_pidfd_open, child.id.?, @as(c_uint, 0)));
        if (pidfd < 0) return error.ProcessMonitorFailed;
        defer _ = c.close(pidfd);
        // Typing helpers get 20 ms per byte on top of a base budget, capped at 5 min.
        const input_len: usize = if (input) |data| data.len else 0;
        const budget_ms: i64 = @intCast(@min(300_000, 10_000 + input_len * 20));
        const deadline = native.nowMs() + budget_ms;
        while (true) {
            try native.checkCancelled();
            if (controlled) try self.guard();
            if (native.nowMs() >= deadline) return error.HelperTimeout;
            var pfd = c.struct_pollfd{ .fd = pidfd, .events = c.POLLIN, .revents = 0 };
            const ready = c.poll(&pfd, 1, 25);
            if (ready < 0 and native.errno() != c.EINTR) return error.ProcessMonitorFailed;
            if (ready > 0) break;
        }
        const term = try child.wait(self.io);
        switch (term) {
            .exited => |code| if (code != 0) {
                return error.HelperFailed;
            },
            else => return error.HelperFailed,
        }
    }
};
