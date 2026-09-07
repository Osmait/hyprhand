const std = @import("std");
const native = @import("../platform/native.zig");
const c = native.c;
const Pointer = @import("../input/pointer.zig").Pointer;
const Point = @import("../core/geometry.zig").Point;

// Captures only the compositor's cursor buffer, never an output/window image.
// Callers keep this object in stable storage for the Wayland listeners.
pub const Capture = struct {
    connection: *Pointer,
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

    fn self(data: ?*anyopaque) *Capture {
        return @ptrCast(@alignCast(data.?));
    }
    fn global(data: ?*anyopaque, registry: ?*c.struct_wl_registry, id: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const s = self(data);
        const name = std.mem.span(interface);
        if (std.mem.eql(u8, name, "ext_image_copy_capture_manager_v1")) {
            s.manager = @ptrCast(c.wl_registry_bind(registry, id, &c.ext_image_copy_capture_manager_v1_interface, 1));
        } else if (std.mem.eql(u8, name, "ext_output_image_capture_source_manager_v1")) {
            s.sources = @ptrCast(c.wl_registry_bind(registry, id, &c.ext_output_image_capture_source_manager_v1_interface, 1));
        } else if (std.mem.eql(u8, name, "wl_shm")) {
            s.shm = @ptrCast(c.wl_registry_bind(registry, id, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, name, "wl_seat") and version >= 5 and s.seat == null) {
            s.seat = @ptrCast(c.wl_registry_bind(registry, id, &c.wl_seat_interface, 5));
            _ = c.wl_seat_add_listener(s.seat, &seat_listener, s);
        }
    }
    fn removed(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.c) void {}
    const registry_listener = c.struct_wl_registry_listener{ .global = global, .global_remove = removed };
    fn capabilities(data: ?*anyopaque, seat: ?*c.struct_wl_seat, value: u32) callconv(.c) void {
        const s = self(data);
        if (value & c.WL_SEAT_CAPABILITY_POINTER != 0 and s.pointer == null) s.pointer = c.wl_seat_get_pointer(seat);
    }
    fn seatName(_: ?*anyopaque, _: ?*c.struct_wl_seat, _: [*c]const u8) callconv(.c) void {}
    const seat_listener = c.struct_wl_seat_listener{ .capabilities = capabilities, .name = seatName };

    fn enter(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_cursor_session_v1) callconv(.c) void {
        self(data).entered = true;
    }
    fn leave(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_cursor_session_v1) callconv(.c) void {
        self(data).entered = false;
    }
    fn position(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_cursor_session_v1, _: i32, _: i32) callconv(.c) void {}
    fn hotspotEvent(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_cursor_session_v1, x: i32, y: i32) callconv(.c) void {
        self(data).pending_hotspot = .{ .x = x, .y = y };
    }
    const cursor_listener = c.struct_ext_image_copy_capture_cursor_session_v1_listener{ .enter = enter, .leave = leave, .position = position, .hotspot = hotspotEvent };
    fn size(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, w: u32, h: u32) callconv(.c) void {
        self(data).width = w;
        self(data).height = h;
    }
    fn formatEvent(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, format: u32) callconv(.c) void {
        // Both have alpha in the high byte, which is all the glow needs.
        if (format == c.WL_SHM_FORMAT_ARGB8888 or format == c.WL_SHM_FORMAT_ABGR8888) self(data).format = format;
    }
    fn device(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, _: ?*c.struct_wl_array) callconv(.c) void {}
    fn dmabuf(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1, _: u32, _: ?*c.struct_wl_array) callconv(.c) void {}
    fn done(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1) callconv(.c) void {
        self(data).constraints = true;
    }
    fn stoppedEvent(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_session_v1) callconv(.c) void {
        self(data).stopped = true;
    }
    const session_listener = c.struct_ext_image_copy_capture_session_v1_listener{ .buffer_size = size, .shm_format = formatEvent, .dmabuf_device = device, .dmabuf_format = dmabuf, .done = done, .stopped = stoppedEvent };
    fn transform(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_frame_v1, value: u32) callconv(.c) void {
        if (value != 0) self(data).stopped = true;
    }
    fn damage(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_frame_v1, _: i32, _: i32, _: i32, _: i32) callconv(.c) void {}
    fn time(_: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {}
    fn readyEvent(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_frame_v1) callconv(.c) void {
        self(data).ready = true;
        self(data).hotspot = self(data).pending_hotspot;
    }
    fn failedEvent(data: ?*anyopaque, _: ?*c.struct_ext_image_copy_capture_frame_v1, _: u32) callconv(.c) void {
        self(data).failed = true;
    }
    const frame_listener = c.struct_ext_image_copy_capture_frame_v1_listener{ .transform = transform, .damage = damage, .presentation_time = time, .ready = readyEvent, .failed = failedEvent };

    pub fn init(s: *Capture, connection: *Pointer, output: *c.struct_wl_output) !void {
        s.* = .{ .connection = connection };
        errdefer s.deinit();
        s.registry = c.wl_display_get_registry(connection.display) orelse return error.CursorCaptureUnavailable;
        if (c.wl_registry_add_listener(s.registry, &registry_listener, s) != 0) return error.CursorCaptureUnavailable;
        try connection.sync();
        try connection.sync();
        if (s.manager == null or s.sources == null or s.shm == null or s.pointer == null) return error.CursorCaptureUnavailable;
        s.source = c.ext_output_image_capture_source_manager_v1_create_source(s.sources, output) orelse return error.CursorCaptureUnavailable;
        s.cursor = c.ext_image_copy_capture_manager_v1_create_pointer_cursor_session(s.manager, s.source, s.pointer) orelse return error.CursorCaptureUnavailable;
        if (c.ext_image_copy_capture_cursor_session_v1_add_listener(s.cursor, &cursor_listener, s) != 0) return error.CursorCaptureUnavailable;
        s.session = c.ext_image_copy_capture_cursor_session_v1_get_capture_session(s.cursor) orelse return error.CursorCaptureUnavailable;
        if (c.ext_image_copy_capture_session_v1_add_listener(s.session, &session_listener, s) != 0) return error.CursorCaptureUnavailable;
        try connection.sync();
        if (s.stopped or !s.constraints or s.format == null) return error.CursorCaptureUnavailable;
    }

    pub fn request(s: *Capture) !void {
        if (s.stopped or s.frame != null) return error.CursorCaptureUnavailable;
        s.freeBuffer();
        if (s.width == 0 or s.height == 0 or s.width > 256 or s.height > 256) return error.CursorCaptureUnsupported;
        s.length = @as(usize, s.width) * s.height * 4;
        const fd = c.memfd_create("deskctl-cursor-shape", c.MFD_CLOEXEC);
        if (fd < 0) return error.CursorCaptureUnavailable;
        defer _ = c.close(fd);
        if (c.ftruncate(fd, @intCast(s.length)) != 0) return error.CursorCaptureUnavailable;
        const memory = c.mmap(null, s.length, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (memory == null or memory == c.MAP_FAILED) return error.CursorCaptureUnavailable;
        s.memory = memory;
        const pool = c.wl_shm_create_pool(s.shm, fd, @intCast(s.length)) orelse return error.CursorCaptureUnavailable;
        defer c.wl_shm_pool_destroy(pool);
        s.buffer = c.wl_shm_pool_create_buffer(pool, 0, @intCast(s.width), @intCast(s.height), @intCast(s.width * 4), s.format.?) orelse return error.CursorCaptureUnavailable;
        s.frame = c.ext_image_copy_capture_session_v1_create_frame(s.session) orelse return error.CursorCaptureUnavailable;
        s.ready = false;
        s.failed = false;
        if (c.ext_image_copy_capture_frame_v1_add_listener(s.frame, &frame_listener, s) != 0) return error.CursorCaptureUnavailable;
        c.ext_image_copy_capture_frame_v1_attach_buffer(s.frame, s.buffer);
        c.ext_image_copy_capture_frame_v1_damage_buffer(s.frame, 0, 0, @intCast(s.width), @intCast(s.height));
        c.ext_image_copy_capture_frame_v1_capture(s.frame);
    }
    pub fn pixels(s: *Capture) []const u32 {
        const ptr: [*]const u32 = @ptrCast(@alignCast(s.memory.?));
        return ptr[0 .. s.length / 4];
    }
    pub fn finish(s: *Capture) void {
        if (s.frame) |f| c.ext_image_copy_capture_frame_v1_destroy(f);
        s.frame = null;
    }
    fn freeBuffer(s: *Capture) void {
        if (s.buffer) |b| c.wl_buffer_destroy(b);
        if (s.memory) |m| _ = c.munmap(m, s.length);
        s.buffer = null;
        s.memory = null;
    }
    pub fn deinit(s: *Capture) void {
        s.finish();
        if (s.session) |v| c.ext_image_copy_capture_session_v1_destroy(v);
        if (s.cursor) |v| c.ext_image_copy_capture_cursor_session_v1_destroy(v);
        if (s.source) |v| c.ext_image_capture_source_v1_destroy(v);
        if (s.pointer) |v| c.wl_pointer_release(v);
        if (s.seat) |v| c.wl_seat_release(v);
        s.freeBuffer();
        if (s.manager) |v| c.ext_image_copy_capture_manager_v1_destroy(v);
        if (s.sources) |v| c.ext_output_image_capture_source_manager_v1_destroy(v);
        if (s.shm) |v| c.wl_shm_destroy(v);
        if (s.registry) |v| c.wl_registry_destroy(v);
    }
};

pub fn probe(rt: *@import("../runtime/runtime.zig").Runtime) !void {
    try rt.validateDisplay();
    try rt.unlocked();
    var pointer: Pointer = undefined;
    try pointer.init(try rt.displayPath());
    defer pointer.deinit();
    var aura: @import("../input/aura.zig").Aura = undefined;
    const geometry = @import("../core/geometry.zig");
    const monitors = try rt.json([]geometry.Monitor, try rt.query("monitors"));
    try aura.init(&pointer, monitors);
    defer aura.deinit();
    const p = try rt.json(Point, try rt.query("cursorpos"));
    for (aura.outputs[0..aura.count]) |*output| {
        if (!@import("../input/aura.zig").contains(output.rect orelse continue, p)) continue;
        var capture: Capture = undefined;
        try capture.init(&pointer, output.output.?);
        defer capture.deinit();
        try capture.request();
        const deadline = native.nowMs() + 2000;
        while (!capture.ready and !capture.failed and !capture.stopped and native.nowMs() < deadline) {
            try pointer.sync();
            native.sleepMs(10);
        }
        if (!capture.ready or capture.stopped) return error.CursorCaptureUnavailable;
        const shape = inspectAlpha(capture.pixels());
        try rt.emit(.{ .ok = true, .width = capture.width, .height = capture.height, .hotspot = capture.hotspot, .transparent = shape.transparent, .nontransparent = shape.nontransparent, .usable_shape = shape.usable_shape, .entered = capture.entered });
        return;
    }
    return error.CursorCaptureUnavailable;
}

pub fn inspectAlpha(values: []const u32) struct { transparent: usize, nontransparent: usize, usable_shape: bool } {
    var transparent: usize = 0;
    for (values) |value| if (value >> 24 == 0) {
        transparent += 1;
    };
    // A fully clear image has no contour. Reject fully opaque/redacted images
    // too: do not mistake a compositor's permission mask for the real cursor.
    return .{ .transparent = transparent, .nontransparent = values.len - transparent, .usable_shape = transparent > 0 and transparent < values.len };
}

test "cursor probe does not claim a contour from empty or redacted buffers" {
    try std.testing.expect(!inspectAlpha(&.{}).usable_shape);
    try std.testing.expect(!inspectAlpha(&.{ 0, 0, 0 }).usable_shape);
    try std.testing.expect(!inspectAlpha(&.{ 0xff000000, 0xff000000 }).usable_shape);
    const shape = inspectAlpha(&.{ 0, 0xffffffff, 0x80123456 });
    try std.testing.expect(shape.usable_shape);
    try std.testing.expectEqual(@as(usize, 1), shape.transparent);
    try std.testing.expectEqual(@as(usize, 2), shape.nontransparent);
}
