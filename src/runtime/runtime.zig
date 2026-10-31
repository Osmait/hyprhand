const std = @import("std");
const native = @import("../platform/native.zig");
const c = native.c;
const ipc = @import("../platform/ipc.zig");
const child_process = @import("../platform/child_process.zig");
const text = @import("../core/text.zig");
const eq = text.eq;

/// The configuration languages hyprhand can drive. Hyprland 0.57 and later
/// only read Lua; earlier releases read Hyprlang.
pub const ConfigProvider = enum { hyprlang, lua };

/// The compositor dispatchers hyprhand sends, with typed arguments.
pub const Dispatch = union(enum) {
    workspace: u32,
    /// A window address, "0x" followed by hexadecimal digits.
    focus_window: []const u8,
    move_cursor: struct { x: i32, y: i32 },
};

/// What every input step re-verifies while an action runs. `actions.run`
/// owns one for the duration of a command and attaches it to the runtime;
/// copies made with `scratch` share it. Without one, `guard` fails closed.
pub const ActionGuard = struct {
    /// The control token read when the action started. `stop` replaces the
    /// token on disk, so a mismatch means the human took control back.
    control_token: []const u8,
    /// The window input must stay focused on, when the action targets one.
    target_window: ?[]const u8 = null,
    /// Pointer actions also re-validate the frame they were aimed with.
    frame_check: ?FrameCheck = null,
    /// Storage for guard checks, reset after each one, so polling does not
    /// grow the command's main arena.
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    arena_in_use: bool = false,

    pub fn deinit(self: *ActionGuard) void {
        self.arena.deinit();
    }
};

/// A check that only the caller's module knows how to run, with its context.
pub const FrameCheck = struct {
    context: *anyopaque,
    check: *const fn (runtime: *Runtime, context: *anyopaque) anyerror!void,
};

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
    session_id: []const u8 = "host",
    /// Set only while an input action runs; see ActionGuard.
    action: ?*ActionGuard = null,

    pub fn init(context: std.process.Init) !Runtime {
        const allocator = context.arena.allocator();
        const environment = context.environ_map;
        const runtime_directory = environment.get("XDG_RUNTIME_DIR") orelse
            return error.MissingRuntimeDir;
        const instance = environment.get("HYPRLAND_INSTANCE_SIGNATURE") orelse
            return error.MissingHyprlandSession;
        const display = environment.get("WAYLAND_DISPLAY") orelse
            return error.MissingWaylandDisplay;

        if (!std.fs.path.isAbsolute(runtime_directory)) return error.InvalidSessionEnvironment;
        if (std.mem.indexOfScalar(u8, instance, '/') != null) {
            return error.InvalidSessionEnvironment;
        }
        if (instance.len == 0) return error.InvalidSessionEnvironment;

        return .{
            .allocator = allocator,
            .io = context.io,
            .env = environment,
            .instance = instance,
            .display = display,
            .socket = try socket_path(allocator, runtime_directory, instance),
            .directory = try state_directory(allocator, runtime_directory, instance),
        };
    }

    pub fn socket_path(
        allocator: std.mem.Allocator,
        runtime_directory: []const u8,
        instance: []const u8,
    ) ![]const u8 {
        return std.fmt.allocPrint(
            allocator,
            "{s}/hypr/{s}/.socket.sock",
            .{ runtime_directory, instance },
        );
    }

    pub fn state_directory(
        allocator: std.mem.Allocator,
        runtime_directory: []const u8,
        instance: []const u8,
    ) ![]const u8 {
        return std.fmt.allocPrint(
            allocator,
            "{s}/hyprhand-{x}",
            .{ runtime_directory, std.hash.Wyhash.hash(0, instance) },
        );
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
    pub fn with_directory(self: *const Runtime, directory: []const u8) Runtime {
        var copy = self.*;
        copy.directory = directory;
        return copy;
    }

    pub fn state_path(self: *Runtime, name: []const u8) ![:0]const u8 {
        return std.fmt.allocPrintSentinel(self.allocator, "{s}/{s}", .{ self.directory, name }, 0);
    }

    pub fn display_path(self: *Runtime) ![:0]const u8 {
        if (std.fs.path.isAbsolute(self.display)) {
            return self.allocator.dupeSentinel(u8, self.display, 0);
        }
        const runtime_directory = self.env.get("XDG_RUNTIME_DIR").?;
        return std.fmt.allocPrintSentinel(
            self.allocator,
            "{s}/{s}",
            .{ runtime_directory, self.display },
            0,
        );
    }

    pub fn prepare(self: *Runtime) !void {
        const directory_path = try self.allocator.dupeSentinel(u8, self.directory, 0);
        if (c.mkdir(directory_path, 0o700) < 0) {
            if (native.errno() != c.EEXIST) return error.StateDirectoryFailed;
        }

        var status: c.struct_stat = undefined;
        if (c.lstat(directory_path, &status) < 0) return error.UnsafeStateDirectory;
        if ((status.st_mode & c.S_IFMT) != c.S_IFDIR) return error.UnsafeStateDirectory;
        if (status.st_uid != c.getuid()) return error.UnsafeStateDirectory;
        if ((status.st_mode & 0o077) != 0) return error.UnsafeStateDirectory;
    }

    pub fn query(self: *Runtime, command: []const u8) ![]const u8 {
        const request = try std.fmt.allocPrint(self.allocator, "j/{s}", .{command});
        return ipc.request(self.allocator, self.socket, request);
    }

    pub fn parse_json(self: *Runtime, comptime T: type, data: []const u8) !T {
        const parsed = try std.json.parseFromSlice(T, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        return parsed.value;
    }

    /// Query a Hyprland JSON endpoint and parse it in one step.
    pub fn query_json(self: *Runtime, comptime T: type, command: []const u8) !T {
        return self.parse_json(T, try self.query(command));
    }

    /// The provider as Hyprland reports it, including ones hyprhand cannot drive.
    pub fn config_provider_name(self: *Runtime) ![]const u8 {
        const status = try self.query_json(struct { configProvider: []const u8 }, "status");
        return status.configProvider;
    }

    /// The provider, or null when hyprhand does not support it.
    pub fn config_provider(self: *Runtime) !?ConfigProvider {
        return std.meta.stringToEnum(ConfigProvider, try self.config_provider_name());
    }

    pub fn active_window(self: *Runtime) ![]const u8 {
        return (try self.query_json(struct { address: []const u8 = "" }, "activewindow")).address;
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
    pub fn expect_ok(self: *Runtime, request: []const u8, failure: anyerror) !void {
        const reply = try ipc.request(self.allocator, self.socket, request);
        if (!eq(std.mem.trim(u8, reply, " \r\n"), "ok")) return failure;
    }

    pub fn dispatch(self: *Runtime, action: Dispatch) !void {
        const provider = try self.config_provider();
        try self.guard();

        const request = switch (provider orelse return error.UnsupportedConfigProvider) {
            .hyprlang => try self.dispatch_hyprlang(action),
            .lua => try self.dispatch_lua(action),
        };
        try self.expect_ok(request, error.DispatchFailed);
    }

    fn dispatch_hyprlang(self: *Runtime, action: Dispatch) ![]const u8 {
        return switch (action) {
            .workspace => |number| std.fmt.allocPrint(
                self.allocator,
                "/dispatch workspace {d}",
                .{number},
            ),
            .focus_window => |address| std.fmt.allocPrint(
                self.allocator,
                "/dispatch focuswindow address:{s}",
                .{address},
            ),
            .move_cursor => |point| std.fmt.allocPrint(
                self.allocator,
                "/dispatch movecursor {d} {d}",
                .{ point.x, point.y },
            ),
        };
    }

    /// Builds a Lua dispatch from typed values only: no caller text becomes
    /// Lua code, and the window address is checked to be hexadecimal.
    fn dispatch_lua(self: *Runtime, action: Dispatch) ![]const u8 {
        return switch (action) {
            .workspace => |number| std.fmt.allocPrint(
                self.allocator,
                "/dispatch hl.dsp.focus({{workspace='{d}'}})",
                .{number},
            ),
            .focus_window => |address| {
                const prefix = "0x";
                if (!std.mem.startsWith(u8, address, prefix)) return error.InvalidWindowAddress;
                for (address[prefix.len..]) |character| {
                    if (!std.ascii.isHex(character)) return error.InvalidWindowAddress;
                }
                return std.fmt.allocPrint(
                    self.allocator,
                    "/dispatch hl.dsp.focus({{window='address:{s}'}})",
                    .{address},
                );
            },
            .move_cursor => |point| std.fmt.allocPrint(
                self.allocator,
                "/dispatch hl.dsp.cursor.move({{x={d},y={d}}})",
                .{ point.x, point.y },
            ),
        };
    }

    pub fn read_file(self: *Runtime, path_name: []const u8, limit: usize) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path_name, self.allocator, .limited(limit));
    }

    pub fn unlocked(self: *Runtime) !void {
        const status = try self.query_json(struct { locked: bool }, "locked");
        if (status.locked) return error.SessionLocked;
    }

    pub fn validate_display(self: *Runtime) !void {
        // The lock file written by Hyprland binds this IPC instance to Wayland.
        const socket_directory = std.fs.path.dirname(self.socket).?;
        const lock_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/hyprland.lock",
            .{socket_directory},
        );
        const lock_data = try self.read_file(lock_path, 4096);
        var lines = std.mem.tokenizeAny(u8, lock_data, "\r\n");
        _ = lines.next() orelse return error.InvalidSessionEnvironment;
        const socket_name = lines.next() orelse return error.InvalidSessionEnvironment;

        const display_name = std.fs.path.basename(self.display);
        if (!eq(socket_name, display_name)) return error.SessionMismatch;
        if (std.fs.path.isAbsolute(self.display)) {
            const runtime_directory = self.env.get("XDG_RUNTIME_DIR").?;
            const expected = try std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ runtime_directory, socket_name },
            );
            if (!eq(self.display, expected)) return error.SessionMismatch;
        }
    }

    pub fn token(self: *Runtime) ![]const u8 {
        const token_path = try self.state_path("enabled");
        return self.read_file(token_path, 128) catch |err| switch (err) {
            error.FileNotFound => error.ControlStopped,
            else => err,
        };
    }

    /// Fails unless the action may still send input: not cancelled, control
    /// not stopped, session not locked, target window focused, frame valid.
    pub fn guard(self: *Runtime) !void {
        try native.check_cancelled();
        const action = self.action orelse return error.ControlStopped;

        // A frame check can itself reach a guard. Only the outermost call may
        // reset the shared arena; a nested call uses its own.
        var nested_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer nested_arena.deinit();
        const outermost = !action.arena_in_use;
        const arena = if (outermost) &action.arena else &nested_arena;
        action.arena_in_use = true;
        defer if (outermost) {
            action.arena_in_use = false;
            _ = arena.reset(.{ .retain_with_limit = 256 * 1024 });
        };
        var checker = self.scratch(arena.allocator());

        if (!eq(action.control_token, try checker.token())) return error.ControlStopped;
        try checker.unlocked();
        if (action.target_window) |target| {
            if (!eq(target, try checker.active_window())) return error.WindowNotFocused;
        }
        if (action.frame_check) |frame_check| try frame_check.check(&checker, frame_check.context);
    }

    pub fn pause(self: *Runtime, duration_ms: u32) !void {
        const end = native.now_ms() + duration_ms;
        while (native.now_ms() < end) {
            if (self.action != null) try self.guard() else try native.check_cancelled();
            native.sleep_ms(@intCast(@max(0, @min(20, end - native.now_ms()))));
        }
    }

    fn open_lock_file(self: *Runtime, name: []const u8) !c_int {
        const path = try self.state_path(name);
        const flags = c.O_CREAT | c.O_RDWR | c.O_CLOEXEC | c.O_NOFOLLOW;
        const fd = c.open(path, flags, @as(c_uint, 0o600));
        if (fd < 0) return error.ControlLockFailed;
        return fd;
    }

    /// Acquires an exclusive lock, retrying briefly instead of failing on the
    /// first contention. Returns `busy` once `wait_ms` elapses.
    pub fn flock_within(fd: c_int, wait_ms: u32, busy: anyerror) !void {
        const deadline = native.now_ms() + wait_ms;
        while (c.flock(fd, c.LOCK_EX | c.LOCK_NB) < 0) {
            const error_code = native.errno();
            const retryable = error_code == c.EWOULDBLOCK or error_code == c.EINTR;
            if (!retryable) return error.ControlLockFailed;
            if (native.now_ms() >= deadline) return busy;
            native.sleep_ms(5);
        }
    }

    /// The action lock: held for the whole duration of one input command.
    pub fn lock(self: *Runtime) !c_int {
        try self.prepare();
        const fd = try self.open_lock_file("action.lock");
        errdefer _ = c.close(fd);
        if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) < 0) return error.ControlBusy;
        return fd;
    }

    /// 128 random bits as lowercase hex: tokens, epochs, frame and file names.
    pub fn random_token(self: *Runtime) ![]const u8 {
        var bytes: [16]u8 = undefined;
        if (c.getrandom(&bytes, bytes.len, 0) != bytes.len) return error.RandomFailed;
        return self.allocator.dupe(u8, &std.fmt.bytesToHex(bytes, .lower));
    }

    /// Enables input. With `outline`, also asks the optional cursor-outline
    /// plugin to draw while input is enabled.
    pub fn enable(self: *Runtime, outline: bool) !void {
        const lock_fd = try self.lock();
        defer _ = c.close(lock_fd);
        const initial_generation = try self.control_generation();
        try self.validate_display();
        try self.unlocked();

        const name = try self.random_token();
        const temporary_path = try self.state_path(name);
        const enabled_path = try self.state_path("enabled");
        const outline_path = try self.state_path("outline");
        defer _ = c.unlink(temporary_path);
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = temporary_path,
            .data = name,
            .flags = .{ .exclusive = true },
        });
        {
            const authority = try self.authority_lock();
            defer _ = c.close(authority);
            if (!eq(initial_generation, try self.generation())) return error.ControlStopped;
            if (c.rename(temporary_path, enabled_path) < 0) return error.StateWriteFailed;
        }
        errdefer _ = c.unlink(enabled_path);
        _ = c.unlink(outline_path);

        if (outline) {
            const provider = try self.config_provider();
            if (provider != .hyprlang) return error.OutlineRequiresHyprlang;
            // The optional plugin must already be loaded by the user. Never
            // load code into the compositor as a side effect of enabling input.
            const request = try std.fmt.allocPrint(
                self.allocator,
                "/dispatch hyprhand:outline {s}",
                .{enabled_path},
            );
            try self.expect_ok(request, error.OutlinePluginUnavailable);
            try std.Io.Dir.cwd().writeFile(self.io, .{
                .sub_path = outline_path,
                .data = name,
                .flags = .{ .exclusive = true },
            });
        }

        if (!eq(name, try self.token())) return error.ControlStopped;
        try self.emit(.{
            .ok = true,
            .session_id = self.session_id,
            .control = "enabled",
            .indicator = @as([]const u8, if (outline) "outline" else "none"),
            .shared_cursor = self.is_host(),
        });
    }

    pub fn is_host(self: *const Runtime) bool {
        return eq(self.session_id, "host");
    }

    pub fn outline_enabled(self: *Runtime) !bool {
        const outline_path = try self.state_path("outline");
        const marker = self.read_file(outline_path, 128) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        const action = self.action orelse return false;
        return eq(marker, action.control_token);
    }

    pub fn stop(self: *Runtime) !void {
        try self.prepare();
        const authority = try self.authority_lock();
        defer _ = c.close(authority);

        // Enable creates the epoch BEFORE IPC. Removing it invalidates every
        // in-flight enable without allocating disk space or writing new data.
        // Attempt all revocations even if one fails; never strand the token
        // merely because publishing a new journal entry failed.
        var failed = false;
        for ([_][]const u8{ "stop-generation", "enabled", "outline" }) |name| {
            const path = try self.state_path(name);
            if (c.unlink(path) < 0 and native.errno() != c.ENOENT) failed = true;
        }
        if (failed) return error.StateWriteFailed;

        try self.emit(.{ .ok = true, .session_id = self.session_id, .control = "stopped" });
    }

    fn generation(self: *Runtime) ![]const u8 {
        const generation_path = try self.state_path("stop-generation");
        return self.read_file(generation_path, 128) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
    }

    fn control_generation(self: *Runtime) ![]const u8 {
        const fd = try self.authority_lock();
        defer _ = c.close(fd);
        const current = try self.generation();
        if (current.len != 0) return current;

        const epoch = try self.random_token();
        const temporary_path = try self.state_path(epoch);
        defer _ = c.unlink(temporary_path);
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = temporary_path,
            .data = epoch,
            .flags = .{ .exclusive = true },
        });
        const generation_path = try self.state_path("stop-generation");
        if (c.rename(temporary_path, generation_path) < 0) return error.StateWriteFailed;
        return epoch;
    }

    // This separate lock protects only local atomic publication, never IPC
    // or input, so stop remains independent from the long-held action lock.
    fn authority_lock(self: *Runtime) !c_int {
        const fd = try self.open_lock_file("control.lock");
        errdefer _ = c.close(fd);
        try flock_within(fd, 500, error.ControlBusy);
        return fd;
    }

    pub fn executable(self: *Runtime, name: []const u8) !bool {
        var entries = std.mem.splitScalar(u8, self.env.get("PATH") orelse "", ':');
        while (entries.next()) |entry| {
            const directory = if (entry.len == 0) "." else entry;
            const candidate = try std.fmt.allocPrintSentinel(
                self.allocator,
                "{s}/{s}",
                .{ directory, name },
                0,
            );
            if (c.access(candidate, c.X_OK) == 0) return true;
        }
        return false;
    }

    fn input_buffer(input: []const u8) !c_int {
        const fd = c.memfd_create("hyprhand-input", c.MFD_CLOEXEC);
        if (fd < 0) return error.InputBufferFailed;
        errdefer _ = c.close(fd);

        var written: usize = 0;
        while (written < input.len) {
            const count = c.write(fd, input.ptr + written, input.len - written);
            if (count <= 0) return error.InputBufferFailed;
            written += @intCast(count);
        }
        if (c.lseek(fd, 0, c.SEEK_SET) < 0) return error.InputBufferFailed;
        return fd;
    }

    /// Run a bounded helper, with no shell and no text in its argv.
    /// pidfd polling allows stop to cancel without reaping outside Zig's child API.
    pub fn run_helper(
        self: *Runtime,
        argv: []const []const u8,
        input: ?[]const u8,
        controlled: bool,
    ) !void {
        const stdin_fd: c_int = if (input) |data| try input_buffer(data) else -1;
        defer if (stdin_fd >= 0) {
            _ = c.close(stdin_fd);
        };
        if (controlled) try self.guard();

        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .environ_map = self.env,
            .stdin = if (stdin_fd >= 0)
                .{ .file = .{ .handle = stdin_fd, .flags = .{ .nonblocking = false } } }
            else
                .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
        });
        defer child_process.terminate(&child, self.io);
        const pidfd: c_int = @intCast(c.syscall(c.SYS_pidfd_open, child.id.?, @as(c_uint, 0)));
        if (pidfd < 0) return error.ProcessMonitorFailed;
        defer _ = c.close(pidfd);

        // Typing helpers get 20 ms per byte on top of a base budget, capped at 5 min.
        const input_length: usize = if (input) |data| data.len else 0;
        const budget_ms: i64 = @intCast(@min(300_000, 10_000 + input_length * 20));
        const deadline = native.now_ms() + budget_ms;
        while (true) {
            try native.check_cancelled();
            if (controlled) try self.guard();
            if (native.now_ms() >= deadline) return error.HelperTimeout;
            var poll_fd = c.struct_pollfd{ .fd = pidfd, .events = c.POLLIN, .revents = 0 };
            const ready = c.poll(&poll_fd, 1, 25);
            if (ready < 0 and native.errno() != c.EINTR) return error.ProcessMonitorFailed;
            if (ready > 0) break;
        }

        const termination = try child.wait(self.io);
        switch (termination) {
            .exited => |code| if (code != 0) {
                return error.HelperFailed;
            },
            else => return error.HelperFailed,
        }
    }
};
