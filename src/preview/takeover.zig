//! `_preview_input`: the human takeover worker. The PiP viewer starts it when
//! the human clicks Take over. It revokes agent control of the exact session
//! instance the viewer shows, then forwards the human's own pointer and keys,
//! read from its stdin, through virtual devices on that session. Forwarded
//! keys are never logged, echoed, put in argv or written anywhere else.
const std = @import("std");
const assert = std.debug.assert;
const native = @import("../platform/native.zig");
const c = native.c;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const Args = @import("../cli/args.zig").Args;
const sessions = @import("../runtime/sessions.zig");
const operations = @import("../runtime/operations.zig");
const geometry = @import("../core/geometry.zig");
const Pointer = @import("../input/pointer.zig").Pointer;
const Keyboard = @import("../input/keyboard.zig").Keyboard;
const takeover_keys = @import("takeover_keys.zig");
const Keys = takeover_keys.Keys;
const Compose = takeover_keys.Compose;
const protocol = @import("takeover_protocol.zig");
const eq = @import("../core/text.zig").eq;

/// How often identity, lock state, control and geometry are rechecked.
const check_interval_ms = 250;
/// How long agent actions get to notice the revoked token and exit.
const actions_wait_ms = 2000;
/// How long Return keeps retrying while an agent command holds the action lock.
const restore_wait_ms = 1000;

pub fn run(owner: *Runtime, arguments: Args) !void {
    if (eq(arguments.session, "host")) return error.PreviewManagedSessionRequired;
    try verify_parent();

    var session = owner.*;
    try sessions.route(&session, arguments.session);
    try require_instance(&session, arguments);
    try session.validate_display();
    try session.unlocked();

    const lock_fd = try session.takeover_lock();
    var lock_held = true;
    defer if (lock_held) {
        _ = c.close(lock_fd);
    };
    // Connect every device before revoking, so a setup failure leaves
    // agent control exactly as it was.
    var forwarder: Forwarder = undefined;
    try forwarder.init(owner, &session, arguments);
    defer forwarder.deinit();

    const was_enabled = try control_enabled(&session);
    try session.revoke();
    forwarder.holding = true;
    session.wait_for_actions(actions_wait_ms) catch |err| {
        // Control stays revoked: an agent action did not stop in time.
        operations.log(&session, "takeover", @errorName(err)) catch {};
        return err;
    };
    operations.log(&session, "takeover", "started") catch {};
    try reply(.ready);

    const outcome = forwarder.forward() catch |err| {
        operations.log(&session, "takeover", @errorName(err)) catch {};
        return err;
    };
    forwarder.release_all();
    if (outcome == .closed) {
        // Closing the viewer is not consent to resume the agent.
        operations.log(&session, "takeover", "ended") catch {};
        return;
    }

    // Grant refuses while any takeover lock is held, including this one.
    _ = c.close(lock_fd);
    lock_held = false;
    const result = restore(&session, was_enabled);
    operations.log(&session, "takeover", "returned") catch {};
    try reply(result);
}

/// The takeover channel serves only the hyprhand-pip binary installed beside
/// this CLI, whose events come from the human's pointer and keyboard on the
/// host. Agents use enable/stop and guarded input commands. Like control
/// tokens, this is cooperative, not a boundary against malicious same-user
/// processes (SECURITY.md).
fn verify_parent() !void {
    var own_buffer: [4096]u8 = undefined;
    const own = try read_link("/proc/self/exe", &own_buffer);
    const directory = std.fs.path.dirname(own) orelse return error.TakeoverParentRejected;
    var expected_buffer: [4096]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buffer, "{s}/hyprhand-pip", .{directory}) catch
        return error.TakeoverParentRejected;

    var path_buffer: [32]u8 = undefined;
    const parent_path = std.fmt.bufPrintSentinel(
        &path_buffer,
        "/proc/{d}/exe",
        .{c.getppid()},
        0,
    ) catch return error.TakeoverParentRejected;
    var parent_buffer: [4096]u8 = undefined;
    const parent = try read_link(parent_path, &parent_buffer);
    if (!eq(parent, expected)) return error.TakeoverParentRejected;

    var status: c.struct_stat = undefined;
    if (c.fstat(c.STDIN_FILENO, &status) < 0) return error.TakeoverParentRejected;
    if ((status.st_mode & c.S_IFMT) != c.S_IFIFO) return error.TakeoverParentRejected;
}

fn read_link(path: [:0]const u8, buffer: *[4096]u8) ![]const u8 {
    const count = c.readlink(path, buffer, buffer.len);
    if (count <= 0) return error.TakeoverParentRejected;
    if (count == buffer.len) return error.TakeoverParentRejected;
    return buffer[0..@intCast(count)];
}

fn require_instance(runtime: *Runtime, arguments: Args) !void {
    if (runtime.is_host()) return error.PreviewManagedSessionRequired;
    if (!eq(runtime.instance, arguments.expected_instance.?)) {
        return error.PreviewIdentityMismatch;
    }
}

fn control_enabled(runtime: *Runtime) !bool {
    _ = runtime.token() catch |err| switch (err) {
        error.ControlStopped => return false,
        else => return err,
    };
    return true;
}

fn reply(value: protocol.Reply) !void {
    const byte = [1]u8{@backingInt(value)};
    while (true) {
        const written = c.write(c.STDOUT_FILENO, &byte, 1);
        if (written == 1) return;
        if (written < 0 and native.errno() == c.EINTR) continue;
        return error.PreviewStreamClosed;
    }
}

/// Return gives control back as it was taken: re-enabled only if the agent
/// had control when the human took over. A failure leaves input stopped.
fn restore(session: *Runtime, was_enabled: bool) protocol.Reply {
    if (!was_enabled) return .returned_stopped;
    const deadline = native.now_ms() + restore_wait_ms;
    while (true) {
        session.grant(false) catch |err| {
            const retry = err == error.ControlBusy and native.now_ms() < deadline;
            if (retry) {
                native.sleep_ms(20);
                continue;
            }
            operations.log(session, "takeover_restore", @errorName(err)) catch {};
            return .returned_stopped;
        };
        return .returned_enabled;
    }
}

const Outcome = enum { finished, closed };

const Forwarder = struct {
    owner: *Runtime,
    arguments: Args,
    pointer: Pointer,
    keyboard: Keyboard,
    keys: Keys = .{},
    buttons: std.EnumSet(protocol.PointerButton) = .empty,
    monitor: protocol.Area = undefined,
    layout: protocol.Area = undefined,
    /// Sub-detent wheel distance not yet sent, in 1/120 detents.
    wheel: struct { x: i32 = 0, y: i32 = 0 } = .{},
    /// Axes with continuous scrolling since the last stop.
    scrolled: struct { x: bool = false, y: bool = false } = .{},
    checked_ms: i64 = 0,
    /// Set once agent control is revoked; checks keep it revoked from then on.
    holding: bool = false,
    /// Storage for one check, reset after it.
    arena: std.heap.ArenaAllocator,

    /// Caller-owned storage keeps the device listener pointers stable.
    fn init(self: *Forwarder, owner: *Runtime, session: *Runtime, arguments: Args) !void {
        self.* = .{
            .owner = owner,
            .arguments = arguments,
            .pointer = undefined,
            .keyboard = undefined,
            .arena = .init(std.heap.page_allocator),
        };
        errdefer self.arena.deinit();
        try self.pointer.init(try session.display_path());
        errdefer self.pointer.deinit();
        try self.pointer.create();
        try self.keyboard.init(try session.display_path());
        errdefer self.keyboard.deinit();
        try self.keyboard.create();
        try self.check();

        var locale_buffer: [256]u8 = undefined;
        const locale = compose_locale(owner, &locale_buffer) orelse "C";
        self.keys.compose = Compose.from_locale(locale);
    }

    fn deinit(self: *Forwarder) void {
        self.release_all();
        if (self.keys.compose) |*compose| compose.deinit();
        self.keyboard.deinit();
        self.pointer.deinit();
        self.arena.deinit();
    }

    /// Releases everything this worker holds on the session. Never fails:
    /// teardown must not strand a pressed key or button.
    fn release_all(self: *Forwarder) void {
        self.keys.release_all(&self.keyboard);
        var held = self.buttons.iterator();
        while (held.next()) |button| self.pointer.queue_button(button.code(), false);
        self.buttons = .empty;
        self.keyboard.flush() catch {};
        self.pointer.flush() catch {};
    }

    /// Rechecks what the viewer's stream worker checks for every frame, so
    /// input never outlives the session instance the human is looking at.
    fn check(self: *Forwarder) !void {
        defer _ = self.arena.reset(.{ .retain_with_limit = 256 * 1024 });
        var current = self.owner.scratch(self.arena.allocator());
        try sessions.route(&current, self.arguments.session);
        try require_instance(&current, self.arguments);
        try current.unlocked();
        // Agent control stays revoked while the human holds the session.
        if (self.holding and try control_enabled(&current)) try current.revoke();
        try self.update_geometry(&current);
        try self.keyboard.roundtrip_unguarded();
        try self.pointer.sync();
        self.checked_ms = native.now_ms();
    }

    fn update_geometry(self: *Forwarder, runtime: *Runtime) !void {
        const monitors = try runtime.query_json([]geometry.Monitor, "monitors");
        var layout: ?protocol.Area = null;
        var selected: ?protocol.Area = null;
        for (monitors) |monitor| {
            if (monitor.disabled) continue;
            const rect = try monitor.rect();
            const area = protocol.Area{
                .x = rect.x,
                .y = rect.y,
                .width = rect.width,
                .height = rect.height,
            };
            layout = if (layout) |bounds| bounding_box(bounds, area) else area;
            if (!eq(monitor.name, self.arguments.monitor.?)) continue;
            if (!monitor.dpmsStatus) return error.MonitorUnavailable;
            selected = area;
        }
        self.monitor = selected orelse return error.MonitorNotFound;
        self.layout = layout.?;
        _ = try protocol.absolute_motion(self.monitor, self.layout, .{ .x = 0, .y = 0 });
    }

    fn forward(self: *Forwarder) !Outcome {
        var buffer: [4096]u8 = undefined;
        var length: usize = 0;
        while (true) {
            try native.check_cancelled();
            if (native.now_ms() - self.checked_ms >= check_interval_ms) try self.check();

            var readable = c.struct_pollfd{
                .fd = c.STDIN_FILENO,
                .events = c.POLLIN,
                .revents = 0,
            };
            const ready = c.poll(&readable, 1, 50);
            if (ready < 0 and native.errno() == c.EINTR) continue;
            if (ready < 0) return error.PreviewStreamClosed;
            if (ready == 0) continue;

            const count = c.read(c.STDIN_FILENO, buffer[length..].ptr, buffer.len - length);
            if (count < 0) {
                const retry = native.errno() == c.EINTR or native.errno() == c.EAGAIN;
                if (retry) continue;
                return error.PreviewStreamClosed;
            }
            if (count == 0) return .closed;
            length += @intCast(count);

            const applied = try self.apply_records(buffer[0..length]);
            if (applied.finished) return .finished;
            std.mem.copyForwards(u8, buffer[0..], buffer[applied.consumed..length]);
            length -= applied.consumed;
            // Only a partial record can remain, so the buffer never fills.
            assert(length < protocol.record_size_max);
        }
    }

    fn apply_records(
        self: *Forwarder,
        bytes: []const u8,
    ) !struct { consumed: usize, finished: bool } {
        var offset: usize = 0;
        defer {
            self.keyboard.flush() catch {};
            self.pointer.flush() catch {};
        }
        while (try protocol.decode(bytes[offset..])) |decoded| {
            offset += decoded.size;
            switch (decoded.event) {
                .finish => return .{ .consumed = offset, .finished = true },
                else => |event| try self.apply(event),
            }
        }
        try self.keyboard.flush();
        try self.pointer.flush();
        return .{ .consumed = offset, .finished = false };
    }

    fn apply(self: *Forwarder, event: protocol.Event) !void {
        switch (event) {
            .motion => |position| {
                const motion = try protocol.absolute_motion(self.monitor, self.layout, position);
                self.pointer.queue_motion_absolute(
                    motion.x,
                    motion.y,
                    motion.x_extent,
                    motion.y_extent,
                );
            },
            .button => |button| {
                // Unmatched releases and repeated presses change nothing.
                if (self.buttons.contains(button.button) == button.pressed) return;
                self.pointer.queue_button(button.button.code(), button.pressed);
                self.buttons.setPresent(button.button, button.pressed);
            },
            .scroll => |scroll| self.apply_scroll(scroll.unit, scroll.dx, scroll.dy),
            .scroll_stop => {
                if (self.scrolled.x or self.scrolled.y) {
                    const dx: i32 = @intFromBool(self.scrolled.x);
                    const dy: i32 = @intFromBool(self.scrolled.y);
                    self.pointer.end_scroll(dx, dy);
                }
                self.scrolled = .{};
                self.wheel = .{};
            },
            .key => |key| try self.keys.apply(&self.keyboard, key),
            .release_all => self.release_all(),
            .finish => {},
        }
    }

    fn apply_scroll(self: *Forwarder, unit: protocol.ScrollUnit, dx: i32, dy: i32) void {
        switch (unit) {
            .wheel => {
                // Decoding bounds each delta, so the sums cannot overflow.
                self.wheel.x += dx;
                self.wheel.y += dy;
                const detents_x = @divTrunc(self.wheel.x, protocol.wheel_detent);
                const detents_y = @divTrunc(self.wheel.y, protocol.wheel_detent);
                self.wheel.x -= detents_x * protocol.wheel_detent;
                self.wheel.y -= detents_y * protocol.wheel_detent;
                if (detents_x != 0 or detents_y != 0) {
                    self.pointer.queue_wheel(detents_x, detents_y);
                }
            },
            .surface => {
                self.pointer.queue_continuous(dx, dy);
                if (dx != 0) self.scrolled.x = true;
                if (dy != 0) self.scrolled.y = true;
            },
        }
    }
};

/// The host user's locale, as the C library resolves it: it selects the
/// Compose table that host toolkits apply to dead keys.
fn compose_locale(owner: *Runtime, buffer: *[256]u8) ?[:0]const u8 {
    for ([_][]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |name| {
        const value = owner.env.get(name) orelse continue;
        if (value.len == 0) continue;
        return std.fmt.bufPrintSentinel(buffer, "{s}", .{value}, 0) catch null;
    }
    return null;
}

fn bounding_box(left: protocol.Area, right: protocol.Area) protocol.Area {
    const x = @min(left.x, right.x);
    const y = @min(left.y, right.y);
    const x_end = @max(left.x + left.width, right.x + right.width);
    const y_end = @max(left.y + left.height, right.y + right.height);
    return .{ .x = x, .y = y, .width = x_end - x, .height = y_end - y };
}

test "takeover layout bounds cover every monitor" {
    const box = bounding_box(
        .{ .x = -1280, .y = 200, .width = 1280, .height = 720 },
        .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
    );
    const expected = protocol.Area{ .x = -1280, .y = 0, .width = 3200, .height = 1080 };
    try std.testing.expectEqual(expected, box);
}
