const std = @import("std");
const native = @import("../platform/native.zig");
const c = native.c;

pub const Pointer = struct {
    display: *c.struct_wl_display,
    registry: ?*c.struct_wl_registry = null,
    manager: ?*c.struct_zwlr_virtual_pointer_manager_v1 = null,
    device: ?*c.struct_zwlr_virtual_pointer_v1 = null,
    held: ?u32 = null,
    runtime: ?*@import("../runtime/runtime.zig").Runtime = null,

    fn global(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const self: *Pointer = @ptrCast(@alignCast(data.?));
        if (std.mem.eql(u8, std.mem.span(interface), "zwlr_virtual_pointer_manager_v1")) {
            self.manager = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_virtual_pointer_manager_v1_interface, @min(version, 2)));
        }
    }
    fn removed(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.c) void {}
    const listener = c.struct_wl_registry_listener{ .global = global, .global_remove = removed };

    // Caller-owned storage keeps the registry listener's data pointer stable.
    pub fn init(self: *Pointer, display: [:0]const u8) !void {
        self.* = .{ .display = c.wl_display_connect(display) orelse return error.WaylandUnavailable };
        errdefer self.deinit();
        self.registry = c.wl_display_get_registry(self.display) orelse return error.WaylandUnavailable;
        if (c.wl_registry_add_listener(self.registry, &listener, self) != 0) return error.WaylandUnavailable;
        try self.sync();
        if (self.manager == null) return error.VirtualPointerUnavailable;
    }

    pub fn create(self: *Pointer) !void {
        self.device = c.zwlr_virtual_pointer_manager_v1_create_virtual_pointer(self.manager, null) orelse return error.VirtualPointerUnavailable;
        try self.sync();
    }

    pub fn deinit(self: *Pointer) void {
        self.release();
        if (self.device) |p| c.zwlr_virtual_pointer_v1_destroy(p);
        if (self.manager) |m| c.zwlr_virtual_pointer_manager_v1_destroy(m);
        if (self.registry) |r| c.wl_registry_destroy(r);
        _ = c.wl_display_flush(self.display);
        c.wl_display_disconnect(self.display);
    }

    pub fn press(self: *Pointer, button: u32) !void {
        self.held = button;
        c.zwlr_virtual_pointer_v1_button(self.device, timestamp(), button, 1);
        c.zwlr_virtual_pointer_v1_frame(self.device);
        try self.sync();
    }
    pub fn release(self: *Pointer) void {
        const runtime = self.runtime;
        self.runtime = null;
        defer self.runtime = runtime;
        if (self.held) |button| {
            c.zwlr_virtual_pointer_v1_button(self.device, timestamp(), button, 0);
            c.zwlr_virtual_pointer_v1_frame(self.device);
            self.held = null;
            self.syncWithCancellation(false) catch {};
        }
    }

    fn done(data: ?*anyopaque, callback: ?*c.struct_wl_callback, _: u32) callconv(.c) void {
        const finished: *bool = @ptrCast(@alignCast(data.?));
        finished.* = true;
        c.wl_callback_destroy(callback);
    }
    const callback_listener = c.struct_wl_callback_listener{ .done = done };

    pub fn sync(self: *Pointer) !void {
        return self.syncWithCancellation(true);
    }

    // Bootstrap waits must honor cancellation even before a Runtime is bound.
    // Only delivery/release of already queued owned input opts out.
    pub fn syncWithCancellation(self: *Pointer, cancellable: bool) !void {
        var finished = false;
        const callback = c.wl_display_sync(self.display) orelse return error.WaylandUnavailable;
        // Destroying the callback on errors prevents a later callback into this stack.
        errdefer if (!finished) c.wl_callback_destroy(callback);
        if (c.wl_callback_add_listener(callback, &callback_listener, &finished) != 0) return error.WaylandUnavailable;
        const deadline = native.nowMs() + 3000;
        while (!finished) {
            if (cancellable) try native.checkCancelled();
            if (self.runtime) |rt| try rt.guard();
            if (c.wl_display_dispatch_pending(self.display) < 0) return error.WaylandUnavailable;
            if (finished) break;
            if (c.wl_display_flush(self.display) < 0) return error.WaylandUnavailable;
            if (native.nowMs() >= deadline) return error.WaylandTimeout;
            var pfd = c.struct_pollfd{ .fd = c.wl_display_get_fd(self.display), .events = c.POLLIN, .revents = 0 };
            const ready = c.poll(&pfd, 1, 50);
            if (ready < 0 and c.__errno_location().* != c.EINTR) return error.WaylandUnavailable;
            if (ready > 0 and c.wl_display_dispatch(self.display) < 0) return error.WaylandUnavailable;
        }
    }

    fn timestamp() u32 {
        return @truncate(@as(u64, @intCast(native.nowMs())));
    }

    pub fn refreshPosition(self: *Pointer) !void {
        // IPC cursor warping alone does not deliver wl_pointer.motion to the
        // client. A zero delta refreshes surface-local coordinates and hover.
        c.zwlr_virtual_pointer_v1_motion(self.device, timestamp(), 0, 0);
        c.zwlr_virtual_pointer_v1_frame(self.device);
        try self.sync();
    }

    pub fn click(self: *Pointer, button: u32) !void {
        if (self.runtime) |rt| try rt.guard();
        // The click itself may intentionally focus/open/close a window. Check
        // immediately before dispatch, then finish its release/roundtrip even
        // when that expected application action changes the snapshot.
        const runtime = self.runtime;
        self.runtime = null;
        defer self.runtime = runtime;
        c.zwlr_virtual_pointer_v1_button(self.device, timestamp(), button, 1);
        c.zwlr_virtual_pointer_v1_frame(self.device);
        c.zwlr_virtual_pointer_v1_button(self.device, timestamp(), button, 0);
        c.zwlr_virtual_pointer_v1_frame(self.device);
        try self.syncWithCancellation(false);
    }

    pub fn scroll(self: *Pointer, dx: i32, dy: i32) !void {
        // Include both continuous distance and wheel detents for Wayland/X11.
        // Hyprland applies source to the most recently specified axis.
        if (dy != 0) {
            c.zwlr_virtual_pointer_v1_axis_discrete(self.device, timestamp(), 0, dy * 15 * 256, dy);
            c.zwlr_virtual_pointer_v1_axis_source(self.device, c.WL_POINTER_AXIS_SOURCE_WHEEL);
        }
        if (dx != 0) {
            c.zwlr_virtual_pointer_v1_axis_discrete(self.device, timestamp(), 1, dx * 15 * 256, dx);
            c.zwlr_virtual_pointer_v1_axis_source(self.device, c.WL_POINTER_AXIS_SOURCE_WHEEL);
        }
        c.zwlr_virtual_pointer_v1_frame(self.device);
        try self.sync();
    }

    /// Fixed-point axis distances, without coarse wheel detents. Applications
    /// apply their own scale; cumulative distance is conserved by the driver.
    pub fn scrollContinuous(self: *Pointer, dx: i32, dy: i32) !void {
        if (dy != 0) {
            c.zwlr_virtual_pointer_v1_axis(self.device, timestamp(), 0, dy);
            c.zwlr_virtual_pointer_v1_axis_source(self.device, c.WL_POINTER_AXIS_SOURCE_CONTINUOUS);
        }
        if (dx != 0) {
            c.zwlr_virtual_pointer_v1_axis(self.device, timestamp(), 1, dx);
            c.zwlr_virtual_pointer_v1_axis_source(self.device, c.WL_POINTER_AXIS_SOURCE_CONTINUOUS);
        }
        c.zwlr_virtual_pointer_v1_frame(self.device);
        try self.sync();
    }

    pub fn endScroll(self: *Pointer, dx: i32, dy: i32) void {
        const runtime = self.runtime;
        self.runtime = null;
        defer self.runtime = runtime;
        if (dy != 0) c.zwlr_virtual_pointer_v1_axis_stop(self.device, timestamp(), 0);
        if (dx != 0) c.zwlr_virtual_pointer_v1_axis_stop(self.device, timestamp(), 1);
        c.zwlr_virtual_pointer_v1_frame(self.device);
        self.syncWithCancellation(false) catch {};
    }
};
