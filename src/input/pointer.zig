const std = @import("std");
const native = @import("../platform/native.zig");
const c = native.c;
const Connection = @import("../platform/wayland.zig").Connection;

/// One wheel detent expressed in wl_fixed_t (24.8) surface units.
pub const wheel_detent_units: i32 = 15 * 256;

const Axis = enum(u32) { vertical = 0, horizontal = 1 };

pub const Pointer = struct {
    connection: Connection,
    manager: ?*c.struct_zwlr_virtual_pointer_manager_v1 = null,
    device: ?*c.struct_zwlr_virtual_pointer_v1 = null,
    held: ?u32 = null,

    fn global(
        data: ?*anyopaque,
        registry: ?*c.struct_wl_registry,
        name: u32,
        interface: [*c]const u8,
        version: u32,
    ) callconv(.c) void {
        const self: *Pointer = @ptrCast(@alignCast(data.?));
        if (std.mem.eql(u8, std.mem.span(interface), "zwlr_virtual_pointer_manager_v1")) {
            self.manager = @ptrCast(c.wl_registry_bind(
                registry,
                name,
                &c.zwlr_virtual_pointer_manager_v1_interface,
                @min(version, 2),
            ));
        }
    }
    fn removed(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.c) void {}
    const listener = c.struct_wl_registry_listener{ .global = global, .global_remove = removed };

    // Caller-owned storage keeps the registry listener's data pointer stable.
    pub fn init(self: *Pointer, display: [:0]const u8) !void {
        self.* = .{ .connection = try Connection.connect(display) };
        errdefer self.deinit();

        if (c.wl_registry_add_listener(self.connection.registry, &listener, self) != 0) {
            return error.WaylandUnavailable;
        }
        try self.sync();
        if (self.manager == null) return error.VirtualPointerUnavailable;
    }

    pub fn create(self: *Pointer) !void {
        self.device = c.zwlr_virtual_pointer_manager_v1_create_virtual_pointer(
            self.manager,
            null,
        ) orelse return error.VirtualPointerUnavailable;
        try self.sync();
    }

    pub fn deinit(self: *Pointer) void {
        self.release();
        if (self.device) |device| c.zwlr_virtual_pointer_v1_destroy(device);
        if (self.manager) |manager| c.zwlr_virtual_pointer_manager_v1_destroy(manager);
        self.connection.deinit();
    }

    pub fn sync(self: *Pointer) !void {
        return self.connection.sync();
    }

    pub fn press(self: *Pointer, button: u32) !void {
        self.held = button;
        c.zwlr_virtual_pointer_v1_button(self.device, native.timestamp_ms(), button, 1);
        c.zwlr_virtual_pointer_v1_frame(self.device);
        try self.sync();
    }

    pub fn release(self: *Pointer) void {
        const saved = self.connection.suspend_guard();
        defer self.connection.runtime = saved;

        if (self.held) |button| {
            c.zwlr_virtual_pointer_v1_button(self.device, native.timestamp_ms(), button, 0);
            c.zwlr_virtual_pointer_v1_frame(self.device);
            self.held = null;
            self.connection.sync_with_cancellation(false) catch {};
        }
    }

    pub fn refresh_position(self: *Pointer) !void {
        // IPC cursor warping alone does not deliver wl_pointer.motion to the
        // client. A zero delta refreshes surface-local coordinates and hover.
        c.zwlr_virtual_pointer_v1_motion(self.device, native.timestamp_ms(), 0, 0);
        c.zwlr_virtual_pointer_v1_frame(self.device);
        try self.sync();
    }

    pub fn click(self: *Pointer, button: u32) !void {
        if (self.connection.runtime) |runtime| try runtime.guard();

        // The click itself may intentionally focus/open/close a window. Check
        // immediately before dispatch, then finish its release/roundtrip even
        // when that expected application action changes the snapshot.
        const saved = self.connection.suspend_guard();
        defer self.connection.runtime = saved;
        c.zwlr_virtual_pointer_v1_button(self.device, native.timestamp_ms(), button, 1);
        c.zwlr_virtual_pointer_v1_frame(self.device);
        c.zwlr_virtual_pointer_v1_button(self.device, native.timestamp_ms(), button, 0);
        c.zwlr_virtual_pointer_v1_frame(self.device);
        try self.connection.sync_with_cancellation(false);
    }

    fn axis_discrete(self: *Pointer, axis: Axis, detents: i32) void {
        if (detents == 0) return;

        // Include both continuous distance and wheel detents for Wayland/X11.
        // Hyprland applies source to the most recently specified axis.
        c.zwlr_virtual_pointer_v1_axis_discrete(
            self.device,
            native.timestamp_ms(),
            @backingInt(axis),
            detents * wheel_detent_units,
            detents,
        );
        c.zwlr_virtual_pointer_v1_axis_source(self.device, c.WL_POINTER_AXIS_SOURCE_WHEEL);
    }

    pub fn scroll(self: *Pointer, dx: i32, dy: i32) !void {
        self.axis_discrete(.vertical, dy);
        self.axis_discrete(.horizontal, dx);
        c.zwlr_virtual_pointer_v1_frame(self.device);
        try self.sync();
    }

    fn axis_continuous(self: *Pointer, axis: Axis, units: i32) void {
        if (units == 0) return;

        c.zwlr_virtual_pointer_v1_axis(
            self.device,
            native.timestamp_ms(),
            @backingInt(axis),
            units,
        );
        c.zwlr_virtual_pointer_v1_axis_source(
            self.device,
            c.WL_POINTER_AXIS_SOURCE_CONTINUOUS,
        );
    }

    /// Fixed-point axis distances, without coarse wheel detents. Applications
    /// apply their own scale; cumulative distance is conserved by the driver.
    pub fn scroll_continuous(self: *Pointer, dx: i32, dy: i32) !void {
        self.axis_continuous(.vertical, dy);
        self.axis_continuous(.horizontal, dx);
        c.zwlr_virtual_pointer_v1_frame(self.device);
        try self.sync();
    }

    /// Queues an absolute position, in `zwlr_virtual_pointer_v1` units. The
    /// queue_* requests are unguarded: only the preview takeover worker uses
    /// them, to forward a human's own pointer after revoking agent control.
    pub fn queue_motion_absolute(
        self: *Pointer,
        x: u32,
        y: u32,
        x_extent: u32,
        y_extent: u32,
    ) void {
        const time = native.timestamp_ms();
        c.zwlr_virtual_pointer_v1_motion_absolute(self.device, time, x, y, x_extent, y_extent);
        c.zwlr_virtual_pointer_v1_frame(self.device);
    }

    pub fn queue_button(self: *Pointer, button: u32, pressed: bool) void {
        const button_state: u32 = @intFromBool(pressed);
        c.zwlr_virtual_pointer_v1_button(self.device, native.timestamp_ms(), button, button_state);
        c.zwlr_virtual_pointer_v1_frame(self.device);
    }

    /// Queues whole wheel detents, as `scroll` sends them.
    pub fn queue_wheel(self: *Pointer, dx: i32, dy: i32) void {
        self.axis_discrete(.vertical, dy);
        self.axis_discrete(.horizontal, dx);
        c.zwlr_virtual_pointer_v1_frame(self.device);
    }

    /// Queues continuous (touchpad-like) axis distances in wl_fixed units.
    pub fn queue_continuous(self: *Pointer, dx: i32, dy: i32) void {
        self.axis_continuous(.vertical, dy);
        self.axis_continuous(.horizontal, dx);
        c.zwlr_virtual_pointer_v1_frame(self.device);
    }

    pub fn flush(self: *Pointer) !void {
        try self.connection.flush();
    }

    pub fn end_scroll(self: *Pointer, dx: i32, dy: i32) void {
        const saved = self.connection.suspend_guard();
        defer self.connection.runtime = saved;

        if (dy != 0) {
            c.zwlr_virtual_pointer_v1_axis_stop(
                self.device,
                native.timestamp_ms(),
                @backingInt(Axis.vertical),
            );
        }
        if (dx != 0) {
            c.zwlr_virtual_pointer_v1_axis_stop(
                self.device,
                native.timestamp_ms(),
                @backingInt(Axis.horizontal),
            );
        }
        c.zwlr_virtual_pointer_v1_frame(self.device);
        self.connection.sync_with_cancellation(false) catch {};
    }
};
