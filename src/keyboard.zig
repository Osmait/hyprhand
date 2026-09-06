const std = @import("std");
const native = @import("native.zig");
const c = native.c;
const Runtime = @import("runtime.zig").Runtime;
const Connection = @import("pointer.zig").Pointer;

pub const Keyboard = struct {
    connection: Connection,
    manager: ?*c.struct_zwp_virtual_keyboard_manager_v1 = null,
    seat: ?*c.struct_wl_seat = null,
    device: ?*c.struct_zwp_virtual_keyboard_v1 = null,
    held: ?u32 = null,
    has_keymap: bool = false,

    fn global(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const self: *Keyboard = @ptrCast(@alignCast(data.?));
        const iface = std.mem.span(interface);
        if (std.mem.eql(u8, iface, "zwp_virtual_keyboard_manager_v1")) self.manager = @ptrCast(c.wl_registry_bind(registry, name, &c.zwp_virtual_keyboard_manager_v1_interface, 1));
        if (std.mem.eql(u8, iface, "wl_seat") and self.seat == null) self.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, @min(7, version)));
    }
    fn removed(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.c) void {}
    const listener = c.struct_wl_registry_listener{ .global = global, .global_remove = removed };
    pub fn init(self: *Keyboard, display: [:0]const u8) !void {
        self.* = .{ .connection = .{ .display = c.wl_display_connect(display) orelse return error.WaylandUnavailable } };
        errdefer self.deinit();
        self.connection.registry = c.wl_display_get_registry(self.connection.display) orelse return error.WaylandUnavailable;
        if (c.wl_registry_add_listener(self.connection.registry, &listener, self) != 0) return error.WaylandUnavailable;
        try self.connection.sync();
        if (self.manager == null or self.seat == null) return error.VirtualKeyboardUnavailable;
    }
    pub fn create(self: *Keyboard) !void {
        self.device = c.zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(self.manager, self.seat) orelse return error.VirtualKeyboardUnavailable;
        try self.connection.sync();
    }
    pub fn release(self: *Keyboard) void {
        self.connection.runtime = null;
        if (self.device) |device| {
            if (!self.has_keymap) return;
            if (self.held) |key| c.zwp_virtual_keyboard_v1_key(device, timestamp(), key, 0);
            self.held = null;
            c.zwp_virtual_keyboard_v1_modifiers(device, 0, 0, 0, 0);
            self.connection.sync() catch {};
        }
    }
    pub fn deinit(self: *Keyboard) void {
        self.release();
        if (self.device) |device| c.zwp_virtual_keyboard_v1_destroy(device);
        if (self.manager) |manager| c.zwp_virtual_keyboard_manager_v1_destroy(manager);
        if (self.seat) |seat| c.wl_seat_destroy(seat);
        self.connection.deinit();
    }
    fn timestamp() u32 {
        return @truncate(@as(u64, @intCast(native.nowMs())));
    }
    fn upload(self: *Keyboard, rt: *Runtime, keysyms: []const u32) !void {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(rt.a, "xkb_keymap { xkb_keycodes { minimum=8; maximum=255; ");
        for (keysyms, 0..) |_, i| try text.appendSlice(rt.a, try std.fmt.allocPrint(rt.a, "<K{d}>={d};", .{ i + 1, i + 9 }));
        try text.appendSlice(rt.a, "}; xkb_types { include \"complete\" }; xkb_compatibility { include \"complete\" }; xkb_symbols { ");
        for (keysyms, 0..) |symbol, i| try text.appendSlice(rt.a, try std.fmt.allocPrint(rt.a, "key <K{d}> {{ [0x{x}] }};", .{ i + 1, symbol }));
        try text.appendSlice(rt.a, "}; };\x00");
        const fd = c.memfd_create("deskctl-keymap", c.MFD_CLOEXEC);
        if (fd < 0) return error.InputBufferFailed;
        defer _ = c.close(fd);
        if (c.write(fd, text.items.ptr, text.items.len) != text.items.len) return error.InputBufferFailed;
        try rt.guard();
        c.zwp_virtual_keyboard_v1_keymap(self.device, c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, @intCast(text.items.len));
        self.has_keymap = true;
        self.connection.runtime = rt;
        try self.connection.sync();
    }
    fn tap(self: *Keyboard, rt: *Runtime, key: u32) !void {
        try rt.guard();
        self.held = key;
        c.zwp_virtual_keyboard_v1_key(self.device, timestamp(), key, 1);
        c.zwp_virtual_keyboard_v1_key(self.device, timestamp(), key, 0);
        self.held = null;
        try self.connection.sync();
    }
    pub fn typeText(self: *Keyboard, rt: *Runtime, text: []const u8) !void {
        var iterator = (try std.unicode.Utf8View.init(text)).iterator();
        while (true) {
            // A bounded keymap avoids client-side XKB keycode limits. Repeated
            // codepoints share a key, and each chunk has its own short-lived arena.
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            var scratch = rt.*;
            scratch.a = arena.allocator();
            var symbols: std.ArrayList(u32) = .empty;
            var keys: std.ArrayList(u32) = .empty;
            for (0..128) |_| {
                const cp = iterator.nextCodepoint() orelse break;
                const symbol: u32 = switch (cp) {
                    '\n', '\r' => 0xff0d,
                    '\t' => 0xff09,
                    0x1b => 0xff1b,
                    else => c.xkb_utf32_to_keysym(cp),
                };
                const index = std.mem.indexOfScalar(u32, symbols.items, symbol) orelse blk: {
                    try symbols.append(scratch.a, symbol);
                    break :blk symbols.items.len - 1;
                };
                try keys.append(scratch.a, @intCast(index + 1));
            }
            if (keys.items.len == 0) break;
            try self.upload(&scratch, symbols.items);
            for (keys.items) |key| try self.tap(&scratch, key);
            self.connection.runtime = rt;
        }
    }
    pub fn chord(self: *Keyboard, rt: *Runtime, value: []const u8) !void {
        var parts = std.mem.splitScalar(u8, value, '+');
        var mods: u32 = 0;
        var symbol: u32 = 0;
        while (parts.next()) |part| {
            if (parts.peek() == null) {
                symbol = c.xkb_keysym_from_name(try rt.a.dupeZ(u8, part), c.XKB_KEYSYM_CASE_INSENSITIVE);
                break;
            }
            mods |= if (std.mem.eql(u8, part, "shift")) @as(u32, 1) else if (std.mem.eql(u8, part, "ctrl")) 4 else if (std.mem.eql(u8, part, "alt")) 8 else if (std.mem.eql(u8, part, "altgr")) 128 else 64;
        }
        if (symbol == 0) return error.InvalidKeyChord;
        try self.upload(rt, &.{symbol});
        defer self.release();
        c.zwp_virtual_keyboard_v1_modifiers(self.device, mods, 0, 0, 0);
        try self.tap(rt, 1);
    }
};
