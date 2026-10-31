const std = @import("std");
const native = @import("../platform/native.zig");
const c = native.c;
const Pointer = @import("../input/pointer.zig").Pointer;
const Connection = @import("../platform/wayland.zig").Connection;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const aura = @import("../input/aura.zig");
const geometry = @import("../core/geometry.zig");
const Point = geometry.Point;

// Captures only the compositor's cursor buffer, never an output/window image.
// Callers keep this object in stable storage for the Wayland listeners.
pub const Capture = struct {
    connection: *Connection,
    registry: ?*c.struct_wl_registry = null,
    manager: ?*c.struct_ext_image_copy_capture_manager_v1 = null,
    sources: ?*c.struct_ext_output_image_capture_source_manager_v1 = null,
    shm: ?*c.struct_wl_shm = null,
    seat: ?*c.struct_wl_seat = null,
    pointer: ?*c.struct_wl_pointer = null,
    source: ?*c.struct_ext_image_capture_source_v1 = null,
    cursor: ?*c.struct_ext_image_copy_capture_cursor_session_v1 = null,
    session: ?*c.struct_ext_image_copy_capture_session_v1 = null,
    frame: ?*c.struct_ext_image_copy_capture_frame_v1 = null,
    buffer: ?*c.struct_wl_buffer = null,
    memory: ?*anyopaque = null,
    length: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    format: ?u32 = null,
    constraints: bool = false,
    ready: bool = false,
    failed: bool = false,
    stopped: bool = false,
    entered: bool = false,
    hotspot: Point = .{ .x = 0, .y = 0 },
    pending_hotspot: Point = .{ .x = 0, .y = 0 },

    fn from_data(data: ?*anyopaque) *Capture {
        return @ptrCast(@alignCast(data.?));
    }

    fn global(
        data: ?*anyopaque,
        registry: ?*c.struct_wl_registry,
        id: u32,
        interface: [*c]const u8,
        version: u32,
    ) callconv(.c) void {
        const capture = from_data(data);
        const name = std.mem.span(interface);
        if (std.mem.eql(u8, name, "ext_image_copy_capture_manager_v1")) {
            capture.manager = @ptrCast(c.wl_registry_bind(
                registry,
                id,
                &c.ext_image_copy_capture_manager_v1_interface,
                1,
            ));
        } else if (std.mem.eql(u8, name, "ext_output_image_capture_source_manager_v1")) {
            capture.sources = @ptrCast(c.wl_registry_bind(
                registry,
                id,
                &c.ext_output_image_capture_source_manager_v1_interface,
                1,
            ));
        } else if (std.mem.eql(u8, name, "wl_shm")) {
            capture.shm = @ptrCast(c.wl_registry_bind(registry, id, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, name, "wl_seat") and version >= 5 and capture.seat == null) {
            capture.seat = @ptrCast(c.wl_registry_bind(registry, id, &c.wl_seat_interface, 5));
            _ = c.wl_seat_add_listener(capture.seat, &seat_listener, capture);
        }
    }

    fn removed(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.c) void {}

    const registry_listener = c.struct_wl_registry_listener{
        .global = global,
        .global_remove = removed,
    };

    fn capabilities(data: ?*anyopaque, seat: ?*c.struct_wl_seat, value: u32) callconv(.c) void {
        const capture = from_data(data);
        if (value & c.WL_SEAT_CAPABILITY_POINTER == 0) return;
        if (capture.pointer != null) return;
        capture.pointer = c.wl_seat_get_pointer(seat);
    }

    fn seat_name(_: ?*anyopaque, _: ?*c.struct_wl_seat, _: [*c]const u8) callconv(.c) void {}

    const seat_listener = c.struct_wl_seat_listener{
        .capabilities = capabilities,
        .name = seat_name,
    };

    fn enter(
        data: ?*anyopaque,
        _: ?*c.struct_ext_image_copy_capture_cursor_session_v1,
    ) callconv(.c) void {
        from_data(data).entered = true;
    }

    fn leave(
        data: ?*anyopaque,
        _: ?*c.struct_ext_image_copy_capture_cursor_session_v1,
    ) callconv(.c) void {
        from_data(data).entered = false;
    }

    fn position(
        _: ?*anyopaque,
        _: ?*c.struct_ext_image_copy_capture_cursor_session_v1,
        _: i32,
        _: i32,
    ) callconv(.c) void {}

    fn hotspot_event(
        data: ?*anyopaque,
        _: ?*c.struct_ext_image_copy_capture_cursor_session_v1,
        x: i32,
        y: i32,
    ) callconv(.c) void {
        from_data(data).pending_hotspot = .{ .x = x, .y = y };
    }

    const cursor_listener = c.struct_ext_image_copy_capture_cursor_session_v1_listener{
        .enter = enter,
        .leave = leave,
        .position = position,
        .hotspot = hotspot_event,
    };

    fn size(
        data: ?*anyopaque,
        _: ?*c.struct_ext_image_copy_capture_session_v1,
        width: u32,
        height: u32,
    ) callconv(.c) void {
        from_data(data).width = width;
        from_data(data).height = height;
    }

    fn format_event(
        data: ?*anyopaque,
        _: ?*c.struct_ext_image_copy_capture_session_v1,
        format: u32,
    ) callconv(.c) void {
        // Both have alpha in the high byte, which is all the glow needs.
        const alpha_in_high_byte = format == c.WL_SHM_FORMAT_ARGB8888 or
            format == c.WL_SHM_FORMAT_ABGR8888;
        if (alpha_in_high_byte) from_data(data).format = format;
    }

    fn device(
        _: ?*anyopaque,
        _: ?*c.struct_ext_image_copy_capture_session_v1,
        _: ?*c.struct_wl_array,
    ) callconv(.c) void {}

    fn dmabuf(
        _: ?*anyopaque,
        _: ?*c.struct_ext_image_copy_capture_session_v1,
        _: u32,
        _: ?*c.struct_wl_array,
    ) callconv(.c) void {}

    fn done(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1) callconv(.c) void {
        from_data(data).constraints = true;
    }

    fn stopped_event(
        data: ?*anyopaque,
        _: ?*c.struct_ext_image_copy_capture_session_v1,
    ) callconv(.c) void {
        from_data(data).stopped = true;
    }

    const session_listener = c.struct_ext_image_copy_capture_session_v1_listener{
        .buffer_size = size,
        .shm_format = format_event,
        .dmabuf_device = device,
        .dmabuf_format = dmabuf,
        .done = done,
        .stopped = stopped_event,
    };

    fn transform(
        data: ?*anyopaque,
        _: ?*c.struct_ext_image_copy_capture_frame_v1,
        value: u32,
    ) callconv(.c) void {
        if (value != 0) from_data(data).stopped = true;
    }

    fn damage(
        _: ?*anyopaque,
        _: ?*c.struct_ext_image_copy_capture_frame_v1,
        _: i32,
        _: i32,
        _: i32,
        _: i32,
    ) callconv(.c) void {}

    fn time(
        _: ?*anyopaque,
        _: ?*c.struct_ext_image_copy_capture_frame_v1,
        _: u32,
        _: u32,
        _: u32,
    ) callconv(.c) void {}

    fn ready_event(
        data: ?*anyopaque,
        _: ?*c.struct_ext_image_copy_capture_frame_v1,
    ) callconv(.c) void {
        from_data(data).ready = true;
        from_data(data).hotspot = from_data(data).pending_hotspot;
    }

    fn failed_event(
        data: ?*anyopaque,
        _: ?*c.struct_ext_image_copy_capture_frame_v1,
        _: u32,
    ) callconv(.c) void {
        from_data(data).failed = true;
    }

    const frame_listener = c.struct_ext_image_copy_capture_frame_v1_listener{
        .transform = transform,
        .damage = damage,
        .presentation_time = time,
        .ready = ready_event,
        .failed = failed_event,
    };

    pub fn init(self: *Capture, connection: *Connection, output: *c.struct_wl_output) !void {
        self.* = .{ .connection = connection };
        errdefer self.deinit();

        self.registry = c.wl_display_get_registry(connection.display) orelse
            return error.CursorCaptureUnavailable;
        if (c.wl_registry_add_listener(self.registry, &registry_listener, self) != 0) {
            return error.CursorCaptureUnavailable;
        }
        try connection.sync();
        try connection.sync();
        if (self.manager == null) return error.CursorCaptureUnavailable;
        if (self.sources == null) return error.CursorCaptureUnavailable;
        if (self.shm == null) return error.CursorCaptureUnavailable;
        if (self.pointer == null) return error.CursorCaptureUnavailable;

        self.source = c.ext_output_image_capture_source_manager_v1_create_source(
            self.sources,
            output,
        ) orelse return error.CursorCaptureUnavailable;
        self.cursor = c.ext_image_copy_capture_manager_v1_create_pointer_cursor_session(
            self.manager,
            self.source,
            self.pointer,
        ) orelse return error.CursorCaptureUnavailable;
        if (c.ext_image_copy_capture_cursor_session_v1_add_listener(
            self.cursor,
            &cursor_listener,
            self,
        ) != 0) {
            return error.CursorCaptureUnavailable;
        }
        self.session = c.ext_image_copy_capture_cursor_session_v1_get_capture_session(
            self.cursor,
        ) orelse return error.CursorCaptureUnavailable;
        if (c.ext_image_copy_capture_session_v1_add_listener(
            self.session,
            &session_listener,
            self,
        ) != 0) {
            return error.CursorCaptureUnavailable;
        }

        try connection.sync();
        if (self.stopped) return error.CursorCaptureUnavailable;
        if (!self.constraints) return error.CursorCaptureUnavailable;
        if (self.format == null) return error.CursorCaptureUnavailable;
    }

    pub fn request(self: *Capture) !void {
        if (self.stopped) return error.CursorCaptureUnavailable;
        if (self.frame != null) return error.CursorCaptureUnavailable;
        self.free_buffer();
        if (self.width == 0) return error.CursorCaptureUnsupported;
        if (self.height == 0) return error.CursorCaptureUnsupported;
        if (self.width > 256) return error.CursorCaptureUnsupported;
        if (self.height > 256) return error.CursorCaptureUnsupported;

        self.length = @as(usize, self.width) * self.height * 4;
        const fd = c.memfd_create("hyprhand-cursor-shape", c.MFD_CLOEXEC);
        if (fd < 0) return error.CursorCaptureUnavailable;
        defer _ = c.close(fd);
        if (c.ftruncate(fd, @intCast(self.length)) != 0) return error.CursorCaptureUnavailable;

        const memory = c.mmap(null, self.length, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (memory == null) return error.CursorCaptureUnavailable;
        if (memory == c.MAP_FAILED) return error.CursorCaptureUnavailable;
        self.memory = memory;

        const pool = c.wl_shm_create_pool(self.shm, fd, @intCast(self.length)) orelse
            return error.CursorCaptureUnavailable;
        defer c.wl_shm_pool_destroy(pool);
        self.buffer = c.wl_shm_pool_create_buffer(
            pool,
            0,
            @intCast(self.width),
            @intCast(self.height),
            @intCast(self.width * 4),
            self.format.?,
        ) orelse return error.CursorCaptureUnavailable;

        self.frame = c.ext_image_copy_capture_session_v1_create_frame(self.session) orelse
            return error.CursorCaptureUnavailable;
        self.ready = false;
        self.failed = false;
        if (c.ext_image_copy_capture_frame_v1_add_listener(
            self.frame,
            &frame_listener,
            self,
        ) != 0) {
            return error.CursorCaptureUnavailable;
        }
        c.ext_image_copy_capture_frame_v1_attach_buffer(self.frame, self.buffer);
        c.ext_image_copy_capture_frame_v1_damage_buffer(
            self.frame,
            0,
            0,
            @intCast(self.width),
            @intCast(self.height),
        );
        c.ext_image_copy_capture_frame_v1_capture(self.frame);
    }

    pub fn pixels(self: *Capture) []const u32 {
        const words: [*]const u32 = @ptrCast(@alignCast(self.memory.?));
        return words[0 .. self.length / 4];
    }

    pub fn finish(self: *Capture) void {
        if (self.frame) |frame| c.ext_image_copy_capture_frame_v1_destroy(frame);
        self.frame = null;
    }

    fn free_buffer(self: *Capture) void {
        if (self.buffer) |buffer| c.wl_buffer_destroy(buffer);
        if (self.memory) |memory| _ = c.munmap(memory, self.length);
        self.buffer = null;
        self.memory = null;
    }

    pub fn deinit(self: *Capture) void {
        self.finish();
        if (self.session) |session| c.ext_image_copy_capture_session_v1_destroy(session);
        if (self.cursor) |cursor| c.ext_image_copy_capture_cursor_session_v1_destroy(cursor);
        if (self.source) |source| c.ext_image_capture_source_v1_destroy(source);
        if (self.pointer) |pointer| c.wl_pointer_release(pointer);
        if (self.seat) |seat| c.wl_seat_release(seat);
        self.free_buffer();
        if (self.manager) |manager| c.ext_image_copy_capture_manager_v1_destroy(manager);
        if (self.sources) |sources| c.ext_output_image_capture_source_manager_v1_destroy(sources);
        if (self.shm) |shm| c.wl_shm_destroy(shm);
        if (self.registry) |registry| c.wl_registry_destroy(registry);
    }
};

pub fn probe(runtime: *Runtime) !void {
    try runtime.validate_display();
    try runtime.unlocked();

    var pointer: Pointer = undefined;
    try pointer.init(try runtime.display_path());
    defer pointer.deinit();
    var halo: aura.Aura = undefined;
    const monitors = try runtime.query_json([]geometry.Monitor, "monitors");
    try halo.init(&pointer.connection, monitors);
    defer halo.deinit();

    const cursor_position = try runtime.query_json(Point, "cursorpos");
    for (halo.outputs[0..halo.count]) |*output| {
        if (!aura.contains(output.rect orelse continue, cursor_position)) continue;

        var capture: Capture = undefined;
        try capture.init(&pointer.connection, output.output.?);
        defer capture.deinit();
        try capture.request();
        const deadline = native.now_ms() + 2000;
        while (!capture.ready and !capture.failed and !capture.stopped) {
            if (native.now_ms() >= deadline) break;
            try pointer.sync();
            native.sleep_ms(10);
        }
        if (!capture.ready) return error.CursorCaptureUnavailable;
        if (capture.stopped) return error.CursorCaptureUnavailable;

        const shape = inspect_alpha(capture.pixels());
        try runtime.emit(.{
            .ok = true,
            .width = capture.width,
            .height = capture.height,
            .hotspot = capture.hotspot,
            .transparent = shape.transparent,
            .nontransparent = shape.nontransparent,
            .usable_shape = shape.usable_shape,
            .entered = capture.entered,
        });
        return;
    }
    return error.CursorCaptureUnavailable;
}

pub fn inspect_alpha(values: []const u32) struct {
    transparent: usize,
    nontransparent: usize,
    usable_shape: bool,
} {
    var transparent: usize = 0;
    for (values) |value| {
        if (value >> 24 == 0) transparent += 1;
    }
    // A fully clear image has no contour. Reject fully opaque/redacted images
    // too: do not mistake a compositor's permission mask for the real cursor.
    return .{
        .transparent = transparent,
        .nontransparent = values.len - transparent,
        .usable_shape = transparent > 0 and transparent < values.len,
    };
}

test "cursor probe does not claim a contour from empty or redacted buffers" {
    try std.testing.expect(!inspect_alpha(&.{}).usable_shape);
    try std.testing.expect(!inspect_alpha(&.{ 0, 0, 0 }).usable_shape);
    try std.testing.expect(!inspect_alpha(&.{ 0xff000000, 0xff000000 }).usable_shape);
    const shape = inspect_alpha(&.{ 0, 0xffffffff, 0x80123456 });
    try std.testing.expect(shape.usable_shape);
    try std.testing.expectEqual(@as(usize, 1), shape.transparent);
    try std.testing.expectEqual(@as(usize, 2), shape.nontransparent);
}
