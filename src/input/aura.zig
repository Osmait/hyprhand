const std = @import("std");
const native = @import("../platform/native.zig");
const c = native.c;
const geometry = @import("../core/geometry.zig");
const Pointer = @import("pointer.zig").Pointer;

const extent = 64;
const scale = 2;
const pixels = extent * scale;
pub const namespace = "hyprhand-aura";

// Premultiplied ARGB: a restrained blue glow and thin soft ring. Transparent
// outside its footprint; no cursor replacement or compositor theme changes.
pub fn pixel(x: usize, y: usize) u32 {
    const dx = (@as(f64, @floatFromInt(x)) + 0.5) / scale - extent / 2;
    const dy = (@as(f64, @floatFromInt(y)) + 0.5) / scale - extent / 2;
    const r = @sqrt(dx * dx + dy * dy);
    if (r >= 27) return 0;
    const ring = r - 16;
    const opacity = 0.14 * @exp(-r * r / 288) + 0.40 * @exp(-ring * ring / 8);
    const a: u32 = @intFromFloat(@round(opacity * 255));
    return (a << 24) | ((35 * a / 255) << 16) | ((145 * a / 255) << 8) | a;
}

const Buffer = struct {
    object: ?*c.struct_wl_buffer = null,
    memory: ?*anyopaque = null,
    length: usize = 0,
    fn create(self: *Buffer, shm: *c.struct_wl_shm, width: u32, height: u32, painted: bool) !void {
        const length = @as(u64, width) * height * 4;
        if (width == 0 or height == 0 or length > 64 * 1024 * 1024) return error.AuraGeometryUnsupported;
        const fd = c.memfd_create("hyprhand-aura", c.MFD_CLOEXEC);
        if (fd < 0) return error.AuraBufferUnavailable;
        defer _ = c.close(fd);
        if (c.ftruncate(fd, @intCast(length)) != 0) return error.AuraBufferUnavailable;
        const memory = c.mmap(null, @intCast(length), c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (memory == c.MAP_FAILED or memory == null) return error.AuraBufferUnavailable;
        self.memory = memory;
        self.length = @intCast(length);
        errdefer self.destroy();
        if (painted) {
            const data: [*]u32 = @ptrCast(@alignCast(memory));
            for (0..height) |y| for (0..width) |x| {
                data[y * width + x] = pixel(x, y);
            };
        }
        // New memfd pages are zero-filled. Parent buffers stay transparent and
        // immutable; only the tiny child surface is repositioned each sample.
        const pool = c.wl_shm_create_pool(shm, fd, @intCast(length)) orelse return error.AuraBufferUnavailable;
        defer c.wl_shm_pool_destroy(pool);
        self.object = c.wl_shm_pool_create_buffer(pool, 0, @intCast(width), @intCast(height), @intCast(width * 4), c.WL_SHM_FORMAT_ARGB8888) orelse return error.AuraBufferUnavailable;
    }
    fn destroy(self: *Buffer) void {
        if (self.object) |b| c.wl_buffer_destroy(b);
        if (self.memory) |m| _ = c.munmap(m, self.length);
        self.* = .{};
    }
};

const Output = struct {
    id: u32 = 0,
    output: ?*c.struct_wl_output = null,
    name: [128]u8 = @splat(0),
    rect: ?geometry.Rect = null,
    parent: ?*c.struct_wl_surface = null,
    child: ?*c.struct_wl_surface = null,
    subsurface: ?*c.struct_wl_subsurface = null,
    layer: ?*c.struct_zwlr_layer_surface_v1 = null,
    transparent: Buffer = .{},
    configured: bool = false,
    closed: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    visible: bool = false,

    fn outputName(data: ?*anyopaque, _: ?*c.struct_wl_output, name: [*c]const u8) callconv(.c) void {
        const self: *Output = @ptrCast(@alignCast(data.?));
        const value = std.mem.span(name);
        if (value.len >= self.name.len) return;
        @memcpy(self.name[0..value.len], value);
    }
    fn outputGeometry(_: ?*anyopaque, _: ?*c.struct_wl_output, _: i32, _: i32, _: i32, _: i32, _: i32, _: [*c]const u8, _: [*c]const u8, _: i32) callconv(.c) void {}
    fn outputMode(_: ?*anyopaque, _: ?*c.struct_wl_output, _: u32, _: i32, _: i32, _: i32) callconv(.c) void {}
    fn outputDone(_: ?*anyopaque, _: ?*c.struct_wl_output) callconv(.c) void {}
    fn outputScale(_: ?*anyopaque, _: ?*c.struct_wl_output, _: i32) callconv(.c) void {}
    fn outputDescription(_: ?*anyopaque, _: ?*c.struct_wl_output, _: [*c]const u8) callconv(.c) void {}
    const output_listener = c.struct_wl_output_listener{ .geometry = outputGeometry, .mode = outputMode, .done = outputDone, .scale = outputScale, .name = outputName, .description = outputDescription };

    fn configure(data: ?*anyopaque, layer: ?*c.struct_zwlr_layer_surface_v1, serial: u32, width: u32, height: u32) callconv(.c) void {
        const self: *Output = @ptrCast(@alignCast(data.?));
        if (self.configured and (self.width != width or self.height != height)) self.closed = true;
        self.width = width;
        self.height = height;
        self.configured = true;
        c.zwlr_layer_surface_v1_ack_configure(layer, serial);
    }
    fn close(data: ?*anyopaque, _: ?*c.struct_zwlr_layer_surface_v1) callconv(.c) void {
        const self: *Output = @ptrCast(@alignCast(data.?));
        self.closed = true;
    }
    const layer_listener = c.struct_zwlr_layer_surface_v1_listener{ .configure = configure, .closed = close };
};

pub const Aura = struct {
    pointer: *Pointer,
    registry: ?*c.struct_wl_registry = null,
    compositor: ?*c.struct_wl_compositor = null,
    subcompositor: ?*c.struct_wl_subcompositor = null,
    shm: ?*c.struct_wl_shm = null,
    shell: ?*c.struct_zwlr_layer_shell_v1 = null,
    outputs: [16]Output = @splat(.{}),
    count: usize = 0,
    buffer: Buffer = .{},

    fn global(data: ?*anyopaque, registry: ?*c.struct_wl_registry, id: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const self: *Aura = @ptrCast(@alignCast(data.?));
        const name = std.mem.span(interface);
        if (std.mem.eql(u8, name, "wl_compositor") and version >= 4) {
            self.compositor = @ptrCast(c.wl_registry_bind(registry, id, &c.wl_compositor_interface, 4));
        } else if (std.mem.eql(u8, name, "wl_subcompositor")) {
            self.subcompositor = @ptrCast(c.wl_registry_bind(registry, id, &c.wl_subcompositor_interface, 1));
        } else if (std.mem.eql(u8, name, "wl_shm")) {
            self.shm = @ptrCast(c.wl_registry_bind(registry, id, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, name, "zwlr_layer_shell_v1") and version >= 3) {
            self.shell = @ptrCast(c.wl_registry_bind(registry, id, &c.zwlr_layer_shell_v1_interface, 3));
        } else if (std.mem.eql(u8, name, "wl_output") and version >= 4 and self.count < self.outputs.len) {
            const output = &self.outputs[self.count];
            output.id = id;
            output.output = @ptrCast(c.wl_registry_bind(registry, id, &c.wl_output_interface, 4));
            if (output.output != null) {
                _ = c.wl_output_add_listener(output.output, &Output.output_listener, output);
                self.count += 1;
            }
        }
    }
    fn removed(data: ?*anyopaque, _: ?*c.struct_wl_registry, id: u32) callconv(.c) void {
        const self: *Aura = @ptrCast(@alignCast(data.?));
        for (self.outputs[0..self.count]) |*output| if (output.id == id) {
            output.closed = true;
        };
    }
    const registry_listener = c.struct_wl_registry_listener{ .global = global, .global_remove = removed };

    // Caller-owned stable storage is required for Wayland listener pointers.
    pub fn init(self: *Aura, pointer: *Pointer, monitors: []const geometry.Monitor) !void {
        self.* = .{ .pointer = pointer };
        errdefer self.deinit();
        self.registry = c.wl_display_get_registry(pointer.display) orelse return error.AuraUnavailable;
        if (c.wl_registry_add_listener(self.registry, &registry_listener, self) != 0) return error.AuraUnavailable;
        try pointer.sync();
        try pointer.sync(); // wl_output names follow the binds from the first roundtrip.
        if (self.compositor == null or self.subcompositor == null or self.shm == null or self.shell == null) return error.AuraUnavailable;
        for (self.outputs[0..self.count]) |*output| {
            for (monitors) |monitor| {
                if (!monitor.disabled and monitor.dpmsStatus and std.mem.eql(u8, monitor.name, std.mem.sliceTo(&output.name, 0))) output.rect = try monitor.rect();
            }
        }
        try self.buffer.create(self.shm.?, pixels, pixels, true);
    }

    fn passThrough(self: *Aura, surface: *c.struct_wl_surface) !void {
        const empty = c.wl_compositor_create_region(self.compositor) orelse return error.AuraUnavailable;
        defer c.wl_region_destroy(empty);
        c.wl_surface_set_input_region(surface, empty);
        c.wl_surface_set_opaque_region(surface, empty);
    }

    fn mapOutput(self: *Aura, output: *Output) !void {
        output.parent = c.wl_compositor_create_surface(self.compositor) orelse return error.AuraUnavailable;
        try self.passThrough(output.parent.?);
        output.layer = c.zwlr_layer_shell_v1_get_layer_surface(self.shell, output.parent, output.output, c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, namespace) orelse return error.AuraUnavailable;
        if (c.zwlr_layer_surface_v1_add_listener(output.layer, &Output.layer_listener, output) != 0) return error.AuraUnavailable;
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(output.layer, c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
        c.zwlr_layer_surface_v1_set_exclusive_zone(output.layer, -1);
        c.zwlr_layer_surface_v1_set_anchor(output.layer, 15);
        c.zwlr_layer_surface_v1_set_size(output.layer, 0, 0);
        c.wl_surface_commit(output.parent);
        try self.pointer.sync();
        if (!output.configured or output.closed) return error.AuraUnavailable;
        const rect = output.rect.?;
        if (output.width != @as(u32, @intFromFloat(rect.width)) or output.height != @as(u32, @intFromFloat(rect.height))) return error.AuraGeometryUnsupported;
        try output.transparent.create(self.shm.?, output.width, output.height, false);
        output.child = c.wl_compositor_create_surface(self.compositor) orelse return error.AuraUnavailable;
        try self.passThrough(output.child.?);
        c.wl_surface_set_buffer_scale(output.child, scale);
        output.subsurface = c.wl_subcompositor_get_subsurface(self.subcompositor, output.child, output.parent) orelse return error.AuraUnavailable;
        c.wl_surface_attach(output.parent, output.transparent.object, 0, 0);
        c.wl_surface_damage_buffer(output.parent, 0, 0, @intCast(output.width), @intCast(output.height));
    }

    pub fn place(self: *Aura, p: geometry.Point) !void {
        var found = false;
        for (self.outputs[0..self.count]) |*output| {
            const rect = output.rect orelse continue;
            const inside = contains(rect, p);
            if (inside) {
                if (output.closed) return error.AuraUnavailable;
                if (output.parent == null) try self.mapOutput(output);
                const x: i32 = @intFromFloat(@as(f64, @floatFromInt(p.x)) - rect.x);
                const y: i32 = @intFromFloat(@as(f64, @floatFromInt(p.y)) - rect.y);
                c.wl_subsurface_set_position(output.subsurface, x - extent / 2, y - extent / 2);
                c.wl_surface_attach(output.child, self.buffer.object, 0, 0);
                c.wl_surface_damage_buffer(output.child, 0, 0, pixels, pixels);
                c.wl_surface_commit(output.child);
                c.wl_surface_commit(output.parent);
                output.visible = true;
                found = true;
            } else if (output.visible) {
                c.wl_surface_attach(output.child, null, 0, 0);
                c.wl_surface_commit(output.child);
                c.wl_surface_commit(output.parent);
                output.visible = false;
            }
        }
        if (!found) return error.AuraGeometryUnsupported;
        try self.pointer.sync();
    }

    pub fn deinit(self: *Aura) void {
        // Hide before destroy so compositor close animations cannot retain a
        // painted halo. Cleanup must run even after stop or a caught signal.
        const runtime = self.pointer.runtime;
        self.pointer.runtime = null;
        defer self.pointer.runtime = runtime;
        for (self.outputs[0..self.count]) |*output| {
            if (output.child) |child| {
                c.wl_surface_attach(child, null, 0, 0);
                c.wl_surface_commit(child);
                c.wl_surface_commit(output.parent);
            }
        }
        self.pointer.sync() catch {};
        for (self.outputs[0..self.count]) |*output| {
            if (output.subsurface) |s| c.wl_subsurface_destroy(s);
            if (output.child) |s| c.wl_surface_destroy(s);
            if (output.layer) |l| c.zwlr_layer_surface_v1_destroy(l);
            if (output.parent) |s| c.wl_surface_destroy(s);
            output.transparent.destroy();
            if (output.output) |o| c.wl_output_release(o);
        }
        self.buffer.destroy();
        if (self.shell) |s| c.zwlr_layer_shell_v1_destroy(s);
        if (self.shm) |s| c.wl_shm_destroy(s);
        if (self.subcompositor) |s| c.wl_subcompositor_destroy(s);
        if (self.compositor) |s| c.wl_compositor_destroy(s);
        if (self.registry) |r| c.wl_registry_destroy(r);
        self.pointer.sync() catch {};
    }
};

pub fn contains(rect: geometry.Rect, p: geometry.Point) bool {
    const x: f64 = @floatFromInt(p.x);
    const y: f64 = @floatFromInt(p.y);
    return x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height;
}

test "aura raster is blue, premultiplied, symmetric and bounded" {
    try std.testing.expectEqual(@as(u32, 0), pixel(0, 0));
    try std.testing.expect(pixel(pixels / 2, pixels / 2) != 0);
    for (0..pixels) |y| for (0..pixels) |x| {
        const value = pixel(x, y);
        const a = value >> 24;
        const r = (value >> 16) & 255;
        const g = (value >> 8) & 255;
        const b = value & 255;
        try std.testing.expect(r <= g and g <= b and b <= a and a < 160);
        try std.testing.expectEqual(value, pixel(pixels - 1 - x, y));
    };
}

test "aura monitor selection uses logical coordinates including rotated/scaled outputs" {
    const monitor = geometry.Monitor{ .id = 1, .name = "test", .width = 1600, .height = 900, .x = -900, .y = -50, .scale = 1.5, .transform = 3, .activeWorkspace = .{} };
    const rect = try monitor.rect();
    try std.testing.expect(contains(rect, .{ .x = -900, .y = -50 }));
    try std.testing.expect(!contains(rect, .{ .x = -300, .y = -50 }));
    try std.testing.expect(!contains(rect, .{ .x = -901, .y = 0 }));
}
