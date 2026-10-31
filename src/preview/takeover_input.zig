//! The viewer's half of human takeover. The GTK process holds no virtual
//! devices: it starts one `_preview_input` worker and writes fixed-size
//! records of the human's own pointer and key events into a private,
//! non-blocking pipe. Records carry key codes, never text, and are not logged.
const std = @import("std");
const c = @import("gtk.zig").c;
const protocol = @import("takeover_protocol.zig");

/// A worker that does not report ready, or exit after Return, is stopped.
pub const start_timeout_ms = 5000;
pub const return_timeout_ms = 3000;

pub const Worker = struct {
    process: *c.GSubprocess,
    /// Write end of the event pipe; -1 once closed, which the worker reads as EOF.
    events_fd: c_int,
    /// Read end of the reply pipe; -1 once the worker closed it.
    replies_fd: c_int,
    reply_source: c_uint = 0,
    ready: bool = false,
    reply: ?protocol.Reply = null,
    /// The worker wrote something other than a reply: its error report.
    failed: bool = false,
    exited: bool = false,

    /// Spawns the worker on two private pipes. GLib closes every other
    /// descriptor in the child, so no frame worker or helper inherits them.
    pub fn start(argv: [*:null]const ?[*:0]const u8) !*Worker {
        var events: [2]c_int = undefined;
        if (c.pipe(&events) < 0) return error.PreviewBufferFailed;
        var replies: [2]c_int = undefined;
        if (c.pipe(&replies) < 0) {
            close_all(&events);
            return error.PreviewBufferFailed;
        }
        const parent_ends = [_]c_int{ events[1], replies[0] };
        const all = [_]c_int{ events[0], events[1], replies[0], replies[1] };
        for (all) |fd| _ = c.fcntl(fd, c.F_SETFD, @as(c_int, c.FD_CLOEXEC));
        for (parent_ends) |fd| _ = c.fcntl(fd, c.F_SETFL, @as(c_int, c.O_NONBLOCK));

        const self = std.heap.c_allocator.create(Worker) catch {
            close_all(&events);
            close_all(&replies);
            return error.OutOfMemory;
        };
        errdefer std.heap.c_allocator.destroy(self);
        const process = spawn(argv, events[0], replies[1]) orelse {
            close_all(&parent_ends);
            return error.PreviewWorkerFailed;
        };
        self.* = .{ .process = process, .events_fd = events[1], .replies_fd = replies[0] };
        const condition = c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR;
        self.reply_source = c.g_unix_fd_add(self.replies_fd, condition, on_reply, self);
        c.g_subprocess_wait_async(process, null, on_exit, self);
        return self;
    }

    /// The launcher owns the child ends from here and closes them after spawn.
    fn spawn(argv: [*:null]const ?[*:0]const u8, stdin: c_int, stdout: c_int) ?*c.GSubprocess {
        const launcher = c.g_subprocess_launcher_new(c.G_SUBPROCESS_FLAGS_STDERR_SILENCE).?;
        defer c.g_object_unref(launcher);
        c.g_subprocess_launcher_take_stdin_fd(launcher, stdin);
        c.g_subprocess_launcher_take_stdout_fd(launcher, stdout);
        var glib_error: ?*c.GError = null;
        const process = c.g_subprocess_launcher_spawnv(launcher, @ptrCast(argv), &glib_error);
        if (glib_error) |value| c.g_error_free(value);
        return process;
    }

    fn close_all(fds: []const c_int) void {
        for (fds) |fd| _ = c.close(fd);
    }

    /// False when the record could not be written whole: the pipe is closed
    /// or full because the worker stopped reading. Records are smaller than
    /// PIPE_BUF, so a write is never partial.
    pub fn send(self: *Worker, event: protocol.Event) bool {
        if (self.events_fd < 0) return false;
        var buffer: [protocol.record_size_max]u8 = undefined;
        const record = protocol.encode(event, &buffer);
        while (true) {
            const written = c.write(self.events_fd, record.ptr, record.len);
            if (written == record.len) return true;
            if (written < 0 and c.__errno_location().* == c.EINTR) continue;
            return false;
        }
    }

    pub fn close_events(self: *Worker) void {
        if (self.events_fd < 0) return;
        _ = c.close(self.events_fd);
        self.events_fd = -1;
    }

    /// Only after `exited`: GLib holds no more callbacks into this memory.
    pub fn destroy(self: *Worker) void {
        std.debug.assert(self.exited);
        self.close_events();
        if (self.reply_source != 0) _ = c.g_source_remove(self.reply_source);
        if (self.replies_fd >= 0) _ = c.close(self.replies_fd);
        c.g_object_unref(self.process);
        std.heap.c_allocator.destroy(self);
    }

    pub fn force_exit(self: *Worker) void {
        if (!self.exited) c.g_subprocess_force_exit(self.process);
    }

    pub fn terminate(self: *Worker) void {
        if (!self.exited) c.g_subprocess_send_signal(self.process, c.SIGTERM);
    }

    fn on_reply(fd: c_int, _: c.GIOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Worker = @ptrCast(@alignCast(data.?));
        var bytes: [256]u8 = undefined;
        const count = c.read(fd, &bytes, bytes.len);
        if (count < 0) {
            const errno = c.__errno_location().*;
            if (errno == c.EAGAIN or errno == c.EINTR) return c.G_SOURCE_CONTINUE;
        }
        if (count <= 0) {
            _ = c.close(fd);
            self.replies_fd = -1;
            self.reply_source = 0;
            return c.G_SOURCE_REMOVE;
        }
        for (bytes[0..@intCast(count)]) |byte| self.receive(byte);
        return c.G_SOURCE_CONTINUE;
    }

    fn receive(self: *Worker, byte: u8) void {
        // After an error report every later byte is report text, not a reply.
        if (self.failed) return;
        const value = std.enums.fromInt(protocol.Reply, byte) orelse {
            self.failed = true;
            return;
        };
        switch (value) {
            .ready => self.ready = true,
            .returned_enabled, .returned_stopped => self.reply = value,
        }
    }

    fn on_exit(object: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Worker = @ptrCast(@alignCast(data.?));
        var glib_error: ?*c.GError = null;
        _ = c.g_subprocess_wait_finish(@ptrCast(object.?), result, &glib_error);
        if (glib_error) |value| c.g_error_free(value);
        self.exited = true;
    }
};

/// A key event for the worker, or null when GTK reports no usable key. GTK
/// gives the hardware key code as an XKB code (evdev plus eight) and the
/// symbol its keymap resolved, with Shift, AltGr, locks and layout applied.
pub fn key_event(keyval: c_uint, keycode: c_uint, pressed: bool) ?protocol.Event {
    if (keycode < 8) return null;
    if (keycode - 8 > protocol.keycode_max) return null;
    if (keyval == 0) return null;
    if (keyval > protocol.keysym_max) return null;
    return .{ .key = .{
        .keycode = @intCast(keycode - 8),
        .keysym = @intCast(keyval),
        .pressed = pressed,
    } };
}

pub fn pointer_button(event: *c.GdkEvent) ?protocol.PointerButton {
    const button = c.gdk_button_event_get_button(event);
    if (button > std.math.maxInt(u8)) return null;
    return std.enums.fromInt(protocol.PointerButton, @as(u8, @intCast(button)));
}

pub fn scroll_event(event: *c.GdkEvent) protocol.Event {
    if (c.gdk_scroll_event_is_stop(event) != 0) return .scroll_stop;
    const detent: f64 = protocol.wheel_detent;
    const step = protocol.wheel_detent;
    return switch (c.gdk_scroll_event_get_direction(event)) {
        c.GDK_SCROLL_UP => .{ .scroll = .{ .unit = .wheel, .dx = 0, .dy = -step } },
        c.GDK_SCROLL_DOWN => .{ .scroll = .{ .unit = .wheel, .dx = 0, .dy = step } },
        c.GDK_SCROLL_LEFT => .{ .scroll = .{ .unit = .wheel, .dx = -step, .dy = 0 } },
        c.GDK_SCROLL_RIGHT => .{ .scroll = .{ .unit = .wheel, .dx = step, .dy = 0 } },
        else => {
            var dx: f64 = 0;
            var dy: f64 = 0;
            c.gdk_scroll_event_get_deltas(event, &dx, &dy);
            if (c.gdk_scroll_event_get_unit(event) == c.GDK_SCROLL_UNIT_WHEEL) {
                return .{ .scroll = .{
                    .unit = .wheel,
                    .dx = scaled(dx, detent, protocol.wheel_delta_max),
                    .dy = scaled(dy, detent, protocol.wheel_delta_max),
                } };
            }
            // Surface deltas are pixels; the worker expects wl_fixed (1/256).
            return .{ .scroll = .{
                .unit = .surface,
                .dx = scaled(dx, 256, protocol.surface_delta_max),
                .dy = scaled(dy, 256, protocol.surface_delta_max),
            } };
        },
    };
}

/// Scales and clamps a GTK delta into the protocol's bounded integer range.
pub fn scaled(delta: f64, factor: f64, limit: i32) i32 {
    if (!std.math.isFinite(delta)) return 0;
    const bound: f64 = @floatFromInt(limit);
    return @intFromFloat(std.math.clamp(@round(delta * factor), -bound, bound));
}

test "takeover deltas scale, round and clamp into protocol bounds" {
    try std.testing.expectEqual(@as(i32, 60), scaled(0.5, 120, protocol.wheel_delta_max));
    try std.testing.expectEqual(@as(i32, -384), scaled(-1.5, 256, protocol.surface_delta_max));
    try std.testing.expectEqual(
        @as(i32, protocol.wheel_delta_max),
        scaled(1e9, 120, protocol.wheel_delta_max),
    );
    try std.testing.expectEqual(@as(i32, 0), scaled(std.math.nan(f64), 120, 10));
    try std.testing.expectEqual(@as(i32, 0), scaled(-std.math.inf(f64), 120, 10));
}
