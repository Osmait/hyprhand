//! One Wayland client connection plus the cancellable roundtrip every input
//! device shares. Owners register their own registry listeners on `registry`.
const std = @import("std");
const native = @import("native.zig");
const c = native.c;
const Runtime = @import("../runtime/runtime.zig").Runtime;

pub const Connection = struct {
    display: *c.struct_wl_display,
    registry: ?*c.struct_wl_registry = null,
    /// While bound, every roundtrip re-runs the runtime guard (stop token,
    /// lock state, focused window). Owners clear it for teardown traffic.
    runtime: ?*Runtime = null,

    pub fn connect(display_path: [:0]const u8) !Connection {
        var self = Connection{ .display = c.wl_display_connect(display_path) orelse return error.WaylandUnavailable };
        errdefer self.deinit();
        self.registry = c.wl_display_get_registry(self.display) orelse return error.WaylandUnavailable;
        return self;
    }

    pub fn deinit(self: *Connection) void {
        if (self.registry) |r| c.wl_registry_destroy(r);
        self.registry = null;
        _ = c.wl_display_flush(self.display);
        c.wl_display_disconnect(self.display);
    }

    /// Detaches the guard for input that is already owed to the compositor
    /// (releases, acknowledgements). Callers restore the returned value with
    /// `defer connection.runtime = saved;`.
    pub fn suspendGuard(self: *Connection) ?*Runtime {
        const saved = self.runtime;
        self.runtime = null;
        return saved;
    }

    fn done(data: ?*anyopaque, callback: ?*c.struct_wl_callback, _: u32) callconv(.c) void {
        const finished: *bool = @ptrCast(@alignCast(data.?));
        finished.* = true;
        c.wl_callback_destroy(callback);
    }
    const callback_listener = c.struct_wl_callback_listener{ .done = done };

    pub fn sync(self: *Connection) !void {
        return self.syncChecked(true, false);
    }

    // Bootstrap waits must honor cancellation even before a Runtime is bound.
    // Only delivery/release of already queued owned input opts out.
    pub fn syncWithCancellation(self: *Connection, cancellable: bool) !void {
        return self.syncChecked(cancellable, false);
    }

    /// Only for callers that just guarded, then queued non-blocking requests.
    /// No cached authorization: checks resume on the first wait iteration.
    pub fn syncAfterGuard(self: *Connection) !void {
        return self.syncChecked(true, true);
    }

    fn syncChecked(self: *Connection, cancellable: bool, already_guarded: bool) !void {
        var finished = false;
        const callback = c.wl_display_sync(self.display) orelse return error.WaylandUnavailable;
        // Destroying the callback on errors prevents a later callback into this stack.
        errdefer if (!finished) c.wl_callback_destroy(callback);
        if (c.wl_callback_add_listener(callback, &callback_listener, &finished) != 0) return error.WaylandUnavailable;
        const deadline = native.nowMs() + 3000;
        var first = true;
        while (!finished) {
            if (cancellable) try native.checkCancelled();
            if (!first or !already_guarded) if (self.runtime) |rt| try rt.guard();
            first = false;
            if (c.wl_display_dispatch_pending(self.display) < 0) return error.WaylandUnavailable;
            if (finished) break;
            if (native.nowMs() >= deadline) return error.WaylandTimeout;
            // read_events reads available bytes, including partial messages;
            // dispatch() may instead block internally waiting for a full event.
            if (c.wl_display_prepare_read(self.display) < 0) {
                if (native.errno() == c.EAGAIN) continue;
                return error.WaylandUnavailable;
            }
            var prepared = true;
            defer if (prepared) c.wl_display_cancel_read(self.display);
            var events: c_short = c.POLLIN;
            if (c.wl_display_flush(self.display) < 0) {
                if (native.errno() != c.EAGAIN) return error.WaylandUnavailable;
                events |= c.POLLOUT;
            }
            var pfd = c.struct_pollfd{ .fd = c.wl_display_get_fd(self.display), .events = events, .revents = 0 };
            const ready = c.poll(&pfd, 1, 50);
            if (ready < 0 and native.errno() != c.EINTR) return error.WaylandUnavailable;
            if (ready > 0 and pfd.revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) {
                prepared = false;
                if (c.wl_display_read_events(self.display) < 0) return error.WaylandUnavailable;
                if (c.wl_display_dispatch_pending(self.display) < 0) return error.WaylandUnavailable;
            } else if (ready > 0 and pfd.revents & c.POLLNVAL != 0) return error.WaylandUnavailable;
        }
    }
};
