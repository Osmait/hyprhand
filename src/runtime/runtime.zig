const std = @import("std");
const native = @import("../platform/native.zig");
const c = native.c;
const ipc = @import("../platform/ipc.zig");

pub const Runtime = struct {
    a: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    instance: []const u8,
    display: []const u8,
    socket: []const u8,
    directory: []const u8,
    control_token: ?[]const u8 = null,
    session_id: []const u8 = "host",
    target_window: ?[]const u8 = null,
    extra_guard: ?*const fn (*Runtime, *anyopaque) anyerror!void = null,
    guard_context: ?*anyopaque = null,

    pub fn init(context: std.process.Init) !Runtime {
        const a = context.arena.allocator();
        const runtime = context.environ_map.get("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDir;
        const instance = context.environ_map.get("HYPRLAND_INSTANCE_SIGNATURE") orelse return error.MissingHyprlandSession;
        const display = context.environ_map.get("WAYLAND_DISPLAY") orelse return error.MissingWaylandDisplay;
        if (!std.fs.path.isAbsolute(runtime) or std.mem.indexOfScalar(u8, instance, '/') != null or instance.len == 0) return error.InvalidSessionEnvironment;
        const socket = try std.fmt.allocPrint(a, "{s}/hypr/{s}/.socket.sock", .{ runtime, instance });
        const directory = try std.fmt.allocPrint(a, "{s}/deskctl-{x}", .{ runtime, std.hash.Wyhash.hash(0, instance) });
        return .{ .a = a, .io = context.io, .env = context.environ_map, .instance = instance, .display = display, .socket = socket, .directory = directory };
    }

    pub fn path(self: *Runtime, name: []const u8) ![:0]const u8 {
        return std.fmt.allocPrintSentinel(self.a, "{s}/{s}", .{ self.directory, name }, 0);
    }

    pub fn displayPath(self: *Runtime) ![:0]const u8 {
        if (std.fs.path.isAbsolute(self.display)) return self.a.dupeZ(u8, self.display);
        return std.fmt.allocPrintSentinel(self.a, "{s}/{s}", .{ self.env.get("XDG_RUNTIME_DIR").?, self.display }, 0);
    }

    pub fn prepare(self: *Runtime) !void {
        const path_z = try self.a.dupeZ(u8, self.directory);
        if (c.mkdir(path_z, 0o700) < 0 and c.__errno_location().* != c.EEXIST) return error.StateDirectoryFailed;
        var st: c.struct_stat = undefined;
        if (c.lstat(path_z, &st) < 0 or (st.st_mode & c.S_IFMT) != c.S_IFDIR or st.st_uid != c.getuid() or (st.st_mode & 0o077) != 0) return error.UnsafeStateDirectory;
    }

    pub fn query(self: *Runtime, command: []const u8) ![]const u8 {
        return ipc.request(self.a, self.socket, try std.fmt.allocPrint(self.a, "j/{s}", .{command}));
    }

    pub fn json(self: *Runtime, comptime T: type, data: []const u8) !T {
        const parsed = try std.json.parseFromSlice(T, self.a, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        return parsed.value;
    }

    pub fn emit(self: *Runtime, data: anytype) !void {
        const encoded = try std.json.Stringify.valueAlloc(self.a, data, .{});
        try std.Io.File.stdout().writeStreamingAll(self.io, encoded);
        try std.Io.File.stdout().writeStreamingAll(self.io, "\n");
    }

    pub fn dispatch(self: *Runtime, name: []const u8, arg: []const u8) !void {
        const provider = try self.json(struct { configProvider: []const u8 }, try self.query("status"));
        try self.guard();
        const command = if (std.mem.eql(u8, provider.configProvider, "hyprlang"))
            try std.fmt.allocPrint(self.a, "/dispatch {s} {s}", .{ name, arg })
        else if (std.mem.eql(u8, provider.configProvider, "lua")) blk: {
            // Only construct these three dispatchers. User text is never Lua.
            if (std.mem.eql(u8, name, "workspace")) {
                const id_value = try std.fmt.parseInt(u32, arg, 10);
                break :blk try std.fmt.allocPrint(self.a, "/dispatch hl.dsp.focus({{workspace='{d}'}})", .{id_value});
            }
            if (std.mem.eql(u8, name, "focuswindow")) {
                if (!std.mem.startsWith(u8, arg, "address:0x")) return error.InvalidWindowAddress;
                for (arg[10..]) |ch| if (!std.ascii.isHex(ch)) return error.InvalidWindowAddress;
                break :blk try std.fmt.allocPrint(self.a, "/dispatch hl.dsp.focus({{window='{s}'}})", .{arg});
            }
            if (std.mem.eql(u8, name, "movecursor")) {
                var parts = std.mem.tokenizeScalar(u8, arg, ' ');
                const x = try std.fmt.parseInt(i32, parts.next() orelse return error.InvalidCoordinates, 10);
                const y = try std.fmt.parseInt(i32, parts.next() orelse return error.InvalidCoordinates, 10);
                if (parts.next() != null) return error.InvalidCoordinates;
                break :blk try std.fmt.allocPrint(self.a, "/dispatch hl.dsp.cursor.move({{x={d},y={d}}})", .{ x, y });
            }
            return error.UnsupportedDispatcher;
        } else return error.UnsupportedConfigProvider;
        const reply = try ipc.request(self.a, self.socket, command);
        if (!std.mem.eql(u8, std.mem.trim(u8, reply, " \r\n"), "ok")) return error.DispatchFailed;
    }

    pub fn read(self: *Runtime, path_name: []const u8, limit: usize) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path_name, self.a, .limited(limit));
    }

    pub fn unlocked(self: *Runtime) !void {
        const status = try self.json(struct { locked: bool }, try self.query("locked"));
        if (status.locked) return error.SessionLocked;
    }

    pub fn validateDisplay(self: *Runtime) !void {
        // The lock file written by Hyprland binds this IPC instance to Wayland.
        const dir = std.fs.path.dirname(self.socket).?;
        const lock_data = try self.read(try std.fmt.allocPrint(self.a, "{s}/hyprland.lock", .{dir}), 4096);
        var lines = std.mem.tokenizeAny(u8, lock_data, "\r\n");
        _ = lines.next() orelse return error.InvalidSessionEnvironment;
        const socket_name = lines.next() orelse return error.InvalidSessionEnvironment;
        const display_name = std.fs.path.basename(self.display);
        if (!std.mem.eql(u8, socket_name, display_name)) return error.SessionMismatch;
        if (std.fs.path.isAbsolute(self.display)) {
            const expected = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.env.get("XDG_RUNTIME_DIR").?, socket_name });
            if (!std.mem.eql(u8, self.display, expected)) return error.SessionMismatch;
        }
    }

    pub fn token(self: *Runtime) ![]const u8 {
        const path_z = try self.path("enabled");
        return self.read(path_z, 128) catch |err| switch (err) {
            error.FileNotFound => error.ControlStopped,
            else => err,
        };
    }

    pub fn guard(self: *Runtime) !void {
        try native.checkCancelled();
        const expected = self.control_token orelse return error.ControlStopped;
        // Per-check arena avoids growth during long input/wait loops.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var scratch = self.*;
        scratch.a = arena.allocator();
        const actual = try scratch.token();
        if (!std.mem.eql(u8, expected, actual)) return error.ControlStopped;
        try scratch.unlocked();
        if (self.target_window) |target| {
            const active = try scratch.json(struct { address: []const u8 = "" }, try scratch.query("activewindow"));
            if (!std.mem.eql(u8, target, active.address)) return error.WindowNotFocused;
        }
        if (self.extra_guard) |check| try check(self, self.guard_context.?);
    }

    pub fn pause(self: *Runtime, ms: u32) !void {
        const end = native.nowMs() + ms;
        while (native.nowMs() < end) {
            if (self.control_token != null) try self.guard() else try native.checkCancelled();
            native.sleepMs(@intCast(@max(0, @min(20, end - native.nowMs()))));
        }
    }

    pub fn lock(self: *Runtime) !c_int {
        try self.prepare();
        const fd = c.open(try self.path("action.lock"), c.O_CREAT | c.O_RDWR | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
        if (fd < 0) return error.ControlLockFailed;
        errdefer _ = c.close(fd);
        if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) < 0) return error.ControlBusy;
        return fd;
    }

    pub fn id(self: *Runtime) ![]const u8 {
        var bytes: [16]u8 = undefined;
        if (c.getrandom(&bytes, bytes.len, 0) != bytes.len) return error.RandomFailed;
        return self.a.dupe(u8, &std.fmt.bytesToHex(bytes, .lower));
    }

    pub fn enable(self: *Runtime, indicator: []const u8) !void {
        const lock_fd = try self.lock();
        defer _ = c.close(lock_fd);
        const initial_generation = try self.controlGeneration();
        try self.validateDisplay();
        try self.unlocked();
        const name = try self.id();
        const tmp = try self.path(name);
        defer _ = c.unlink(tmp);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = tmp, .data = name, .flags = .{ .exclusive = true } });
        {
            const authority = try self.authorityLock();
            defer _ = c.close(authority);
            if (!std.mem.eql(u8, initial_generation, try self.generation())) return error.ControlStopped;
            if (c.rename(tmp, try self.path("enabled")) < 0) return error.StateWriteFailed;
        }
        errdefer _ = c.unlink(self.path("enabled") catch unreachable);
        _ = c.unlink(try self.path("outline"));
        if (std.mem.eql(u8, indicator, "outline")) {
            const provider = try self.json(struct { configProvider: []const u8 }, try self.query("status"));
            if (!std.mem.eql(u8, provider.configProvider, "hyprlang")) return error.OutlineRequiresHyprlang;
            // The optional plugin must already be loaded by the user. Never
            // load code into the compositor as a side effect of enabling input.
            const result = try ipc.request(self.a, self.socket, try std.fmt.allocPrint(self.a, "/dispatch deskctl:outline {s}", .{try self.path("enabled")}));
            if (!std.mem.eql(u8, std.mem.trim(u8, result, " \r\n"), "ok")) return error.OutlinePluginUnavailable;
            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = try self.path("outline"), .data = name, .flags = .{ .exclusive = true } });
        }
        if (!std.mem.eql(u8, name, try self.token())) return error.ControlStopped;
        try self.emit(.{ .ok = true, .session_id = self.session_id, .control = "enabled", .indicator = indicator, .shared_cursor = std.mem.eql(u8, self.session_id, "host") });
    }

    pub fn outlineEnabled(self: *Runtime) !bool {
        const marker = self.read(try self.path("outline"), 128) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return std.mem.eql(u8, marker, self.control_token orelse return false);
    }

    pub fn stop(self: *Runtime) !void {
        try self.prepare();
        const authority = try self.authorityLock();
        defer _ = c.close(authority);
        // Invalidate an enable that began before this stop but is still waiting
        // for the compositor. New, explicitly requested enables may start later.
        const epoch = try self.id();
        const temp = try self.path(epoch);
        defer _ = c.unlink(temp);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = temp, .data = epoch, .flags = .{ .exclusive = true } });
        if (c.rename(temp, try self.path("stop-generation")) < 0) return error.StateWriteFailed;
        if (c.unlink(try self.path("enabled")) < 0 and c.__errno_location().* != c.ENOENT) return error.StateWriteFailed;
        if (c.unlink(try self.path("outline")) < 0 and c.__errno_location().* != c.ENOENT) return error.StateWriteFailed;
        try self.emit(.{ .ok = true, .session_id = self.session_id, .control = "stopped" });
    }

    fn generation(self: *Runtime) ![]const u8 {
        return self.read(try self.path("stop-generation"), 128) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
    }

    fn controlGeneration(self: *Runtime) ![]const u8 {
        const fd = try self.authorityLock();
        defer _ = c.close(fd);
        return self.generation();
    }

    fn authorityLock(self: *Runtime) !c_int {
        const fd = c.open(try self.path("control.lock"), c.O_CREAT | c.O_RDWR | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
        if (fd < 0) return error.ControlLockFailed;
        errdefer _ = c.close(fd);
        const deadline = native.nowMs() + 500;
        // This separate lock protects only local atomic publication, never IPC
        // or input, so stop remains independent from the long-held action lock.
        while (c.flock(fd, c.LOCK_EX | c.LOCK_NB) < 0) {
            const err = c.__errno_location().*;
            if (err != c.EWOULDBLOCK and err != c.EINTR) return error.ControlLockFailed;
            if (native.nowMs() >= deadline) return error.ControlBusy;
            native.sleepMs(5);
        }
        return fd;
    }

    pub fn executable(self: *Runtime, name: []const u8) !bool {
        var paths = std.mem.splitScalar(u8, self.env.get("PATH") orelse "", ':');
        while (paths.next()) |dir| {
            const candidate = try std.fmt.allocPrintSentinel(self.a, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name }, 0);
            if (c.access(candidate, c.X_OK) == 0) return true;
        }
        return false;
    }

    /// Run a bounded helper, with no shell and no text in its argv.
    /// pidfd polling allows stop to cancel without reaping outside Zig's child API.
    pub fn run(self: *Runtime, argv: []const []const u8, input: ?[]const u8, controlled: bool) !void {
        const stdin_fd = if (input) |text| blk: {
            const fd = c.memfd_create("deskctl-input", c.MFD_CLOEXEC);
            if (fd < 0) return error.InputBufferFailed;
            errdefer _ = c.close(fd);
            var written: usize = 0;
            while (written < text.len) {
                const n = c.write(fd, text.ptr + written, text.len - written);
                if (n <= 0) return error.InputBufferFailed;
                written += @intCast(n);
            }
            if (c.lseek(fd, 0, c.SEEK_SET) < 0) return error.InputBufferFailed;
            break :blk fd;
        } else -1;
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
        defer @import("../platform/child_process.zig").terminate(&child, self.io);
        const pidfd: c_int = @intCast(c.syscall(c.SYS_pidfd_open, child.id.?, @as(c_uint, 0)));
        if (pidfd < 0) return error.ProcessMonitorFailed;
        defer _ = c.close(pidfd);
        const deadline = native.nowMs() + @as(i64, @intCast(@min(300_000, 10_000 + (if (input) |s| s.len * 20 else @as(usize, 0)))));
        while (true) {
            try native.checkCancelled();
            if (controlled) try self.guard();
            if (native.nowMs() >= deadline) return error.HelperTimeout;
            var pfd = c.struct_pollfd{ .fd = pidfd, .events = c.POLLIN, .revents = 0 };
            const ready = c.poll(&pfd, 1, 25);
            if (ready < 0 and c.__errno_location().* != c.EINTR) return error.ProcessMonitorFailed;
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
