const std = @import("std");
const native = @import("native.zig");
const c = native.c;
const Runtime = @import("runtime.zig").Runtime;
const Connection = @import("pointer.zig").Pointer;

const Modifier = struct {
    name: [:0]const u8,
    key_name: []const u8,
    symbol: []const u8,
    // Linux/Wayland keycodes; XKB keycodes have an offset of eight.
    key: u32,
};
const modifiers = [_]Modifier{
    .{ .name = "Shift", .key_name = "LFSH", .symbol = "Shift_L", .key = 42 },
    .{ .name = "Control", .key_name = "LCTL", .symbol = "Control_L", .key = 29 },
    .{ .name = "Mod1", .key_name = "LALT", .symbol = "Alt_L", .key = 56 },
    .{ .name = "Mod4", .key_name = "LWIN", .symbol = "Super_L", .key = 125 },
    .{ .name = "Mod5", .key_name = "RALT", .symbol = "ISO_Level3_Shift", .key = 100 },
};
const chunk_size = 128;

fn modifierIndex(name: []const u8) ?usize {
    const aliases = [_][]const u8{ "shift", "ctrl", "alt", "logo", "altgr" };
    if (std.mem.eql(u8, name, "super")) return 3;
    for (aliases, 0..) |alias, i| if (std.mem.eql(u8, name, alias)) return i;
    return null;
}

// Keep data keys disjoint from the real modifier keycodes in every chunk.
fn dataKey(index: usize) u32 {
    var remaining = index;
    var key: u32 = 1;
    while (true) : (key += 1) {
        var reserved = false;
        for (modifiers) |mod| if (key == mod.key) {
            reserved = true;
            break;
        };
        if (reserved) continue;
        if (remaining == 0) return key;
        remaining -= 1;
    }
}

const Chord = struct {
    symbol: u32,
    mods: [modifiers.len]usize = undefined,
    count: usize = 0,

    fn parse(a: std.mem.Allocator, value: []const u8) !Chord {
        var result = Chord{ .symbol = 0 };
        var parts = std.mem.splitScalar(u8, value, '+');
        while (parts.next()) |part| {
            if (part.len == 0) return error.InvalidKeyChord;
            if (parts.peek() != null) {
                const index = modifierIndex(part) orelse return error.InvalidKeyChord;
                for (result.mods[0..result.count]) |existing| if (existing == index) return error.InvalidKeyChord;
                result.mods[result.count] = index;
                result.count += 1;
            } else {
                for (part) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return error.InvalidKeyChord;
                const name = try a.dupeZ(u8, part);
                defer a.free(name);
                result.symbol = c.xkb_keysym_from_name(name, c.XKB_KEYSYM_CASE_INSENSITIVE);
            }
        }
        if (result.symbol == c.XKB_KEY_NoSymbol) return error.InvalidKeyChord;
        return result;
    }
};

const Keymap = struct {
    compiled: *c.struct_xkb_keymap,
    text: [:0]const u8,

    fn init(a: std.mem.Allocator, symbols: []const u32) !Keymap {
        return compile(a, symbols, false);
    }

    fn initChord(a: std.mem.Allocator, symbol: u32) !Keymap {
        return compile(a, &.{symbol}, true);
    }

    fn compile(a: std.mem.Allocator, symbols: []const u32, chord_levels: bool) !Keymap {
        if (symbols.len == 0 or symbols.len > chunk_size) return error.InvalidKeymap;
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(a);
        try source.appendSlice(a, "xkb_keymap { xkb_keycodes { minimum=8; maximum=255; ");
        for (symbols, 0..) |_, i| try source.print(a, "<K{d}>={d};", .{ i, dataKey(i) + 8 });
        for (modifiers) |mod| try source.print(a, "<{s}>={d};", .{ mod.key_name, mod.key + 8 });
        // Self-contained types/actions avoid host layout and include-file dependencies.
        // Text stays exact. Chords need real Shift levels: GTK's
        // gdk_key_event_matches expects ISO_Left_Tab and uppercase keysyms.
        // https://github.com/GNOME/gtk/blob/4.22.4/gdk/gdkevents.c
        try source.appendSlice(a, "}; xkb_types { type \"ONE_LEVEL\" { modifiers=None; map[None]=Level1; }; type \"TWO_LEVEL\" { modifiers=Shift; map[None]=Level1; map[Shift]=Level2; }; }; xkb_compatibility {}; xkb_symbols { ");
        for (symbols, 0..) |symbol, i| {
            const shifted: u32 = if (symbol == c.XKB_KEY_Tab) c.XKB_KEY_ISO_Left_Tab else c.xkb_keysym_to_upper(symbol);
            if (chord_levels and shifted != symbol) {
                try source.print(a, "key <K{d}> {{ type=\"TWO_LEVEL\", [0x{x},0x{x}], repeat=no }};", .{ i, symbol, shifted });
            } else {
                try source.print(a, "key <K{d}> {{ type=\"ONE_LEVEL\", [0x{x}], repeat=no }};", .{ i, symbol });
            }
        }
        for (modifiers) |mod| try source.print(a, "key <{s}> {{ type=\"ONE_LEVEL\", [{s}], actions=[SetMods(modifiers={s})], repeat=no }}; modifier_map {s} {{ <{s}> }};", .{ mod.key_name, mod.symbol, mod.name, mod.name, mod.key_name });
        try source.appendSlice(a, "}; };\x00");
        const context = c.xkb_context_new(c.XKB_CONTEXT_NO_DEFAULT_INCLUDES | c.XKB_CONTEXT_NO_ENVIRONMENT_NAMES) orelse return error.InvalidKeymap;
        defer c.xkb_context_unref(context);
        const compiled = c.xkb_keymap_new_from_string(context, @ptrCast(source.items.ptr), c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return error.InvalidKeymap;
        errdefer c.xkb_keymap_unref(compiled);
        const serialized = c.xkb_keymap_get_as_string(compiled, c.XKB_KEYMAP_FORMAT_TEXT_V1) orelse return error.InvalidKeymap;
        return .{ .compiled = compiled, .text = std.mem.span(serialized) };
    }

    fn deinit(self: *Keymap) void {
        c.free(@constCast(self.text.ptr));
        c.xkb_keymap_unref(self.compiled);
    }

    fn mask(self: *const Keymap, name: [:0]const u8) !u32 {
        const index = c.xkb_keymap_mod_get_index(self.compiled, name);
        // Check before narrowing/shifting, including XKB_MOD_INVALID.
        if (index >= @bitSizeOf(c.xkb_mod_mask_t)) return error.InvalidKeymap;
        return @as(u32, 1) << @intCast(index);
    }
};

const Key = struct { code: u32, mask: u32 = 0 };

const HeldKeys = struct {
    keys: [modifiers.len + 1]Key = undefined,
    count: usize = 0,
    depressed: u32 = 0,

    fn press(self: *HeldKeys, sink: anytype, key: Key) void {
        std.debug.assert(self.count < self.keys.len);
        self.keys[self.count] = key;
        self.count += 1;
        sink.sendKey(key.code, 1);
        const mask = self.depressed | key.mask;
        if (mask != self.depressed) sink.sendModifiers(mask);
        self.depressed = mask;
    }

    fn pop(self: *HeldKeys, sink: anytype) void {
        if (self.count == 0) return;
        self.count -= 1;
        sink.sendKey(self.keys[self.count].code, 0);
        var mask: u32 = 0;
        for (self.keys[0..self.count]) |key| mask |= key.mask;
        if (mask != self.depressed) sink.sendModifiers(mask);
        self.depressed = mask;
    }

    fn release(self: *HeldKeys, sink: anytype) void {
        while (self.count > 0) self.pop(sink);
    }

    // Blender's keyboard_handle_key calls keyboard_depressed_state_key_event;
    // keyboard_handle_modifiers only updates its XKB mask. Both events matter:
    // https://github.com/blender/blender/blob/main/intern/ghost/intern/GHOST_SystemWayland.cc
    // The same sequencing runs against Wayland and an in-memory test driver.
    // Synchronize each modifier before the target, then unwind in reverse order.
    fn chord(self: *HeldKeys, driver: anytype, keys: []const Key) !void {
        std.debug.assert(keys.len > 0 and keys.len <= self.keys.len and self.count == 0);
        errdefer {
            self.release(driver);
            driver.sync(false) catch {};
        }
        for (keys[0 .. keys.len - 1]) |key| {
            try driver.guard();
            self.press(driver, key);
            try driver.sync(true);
        }
        try driver.guard();
        self.press(driver, keys[keys.len - 1]);
        self.release(driver);
        // The target may intentionally change focus (e.g. opening a dialog).
        // Queue its release and modifier releases immediately, then acknowledge
        // delivery without applying a post-action focus guard.
        try driver.sync(false);
    }
};

const TextChunk = struct {
    symbols: [chunk_size]u32 = undefined,
    keys: [chunk_size]u32 = undefined,
    symbol_count: usize = 0,
    count: usize = 0,

    fn next(iterator: *std.unicode.Utf8Iterator) TextChunk {
        var result = TextChunk{};
        while (result.count < chunk_size) {
            const cp = iterator.nextCodepoint() orelse break;
            const symbol: u32 = switch (cp) {
                '\n', '\r' => c.XKB_KEY_Return,
                '\t' => c.XKB_KEY_Tab,
                0x1b => c.XKB_KEY_Escape,
                else => c.xkb_utf32_to_keysym(cp),
            };
            const index = std.mem.indexOfScalar(u32, result.symbols[0..result.symbol_count], symbol) orelse blk: {
                const i = result.symbol_count;
                result.symbols[i] = symbol;
                result.symbol_count += 1;
                break :blk i;
            };
            result.keys[result.count] = dataKey(index);
            result.count += 1;
        }
        return result;
    }
};

pub const Keyboard = struct {
    connection: ?Connection = null,
    manager: ?*c.struct_zwp_virtual_keyboard_manager_v1 = null,
    seat: ?*c.struct_wl_seat = null,
    device: ?*c.struct_zwp_virtual_keyboard_v1 = null,
    manager_name: ?u32 = null,
    seat_name: ?u32 = null,
    held: HeldKeys = .{},
    has_keymap: bool = false,

    fn global(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const self: *Keyboard = @ptrCast(@alignCast(data.?));
        const iface = std.mem.span(interface);
        if (version == 0) return;
        if (std.mem.eql(u8, iface, "zwp_virtual_keyboard_manager_v1") and self.manager == null) {
            self.manager = @ptrCast(c.wl_registry_bind(registry, name, &c.zwp_virtual_keyboard_manager_v1_interface, 1));
            self.manager_name = name;
        }
        if (std.mem.eql(u8, iface, "wl_seat") and self.seat == null) {
            self.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, @min(7, version)));
            self.seat_name = name;
        }
    }
    fn removed(data: ?*anyopaque, _: ?*c.struct_wl_registry, name: u32) callconv(.c) void {
        const self: *Keyboard = @ptrCast(@alignCast(data.?));
        if (self.manager_name == name) self.manager_name = null;
        if (self.seat_name == name) self.seat_name = null;
    }
    const listener = c.struct_wl_registry_listener{ .global = global, .global_remove = removed };

    // Caller-owned storage keeps the registry listener pointer stable.
    pub fn init(self: *Keyboard, display: [:0]const u8) !void {
        self.* = .{};
        self.connection = .{ .display = c.wl_display_connect(display) orelse return error.WaylandUnavailable };
        errdefer self.deinit();
        const connection = &self.connection.?;
        connection.registry = c.wl_display_get_registry(connection.display) orelse return error.WaylandUnavailable;
        if (c.wl_registry_add_listener(connection.registry, &listener, self) != 0) return error.WaylandUnavailable;
        try connection.sync();
        try self.available();
    }

    fn available(self: *const Keyboard) !void {
        if (self.connection == null or self.manager == null or self.seat == null or self.manager_name == null or self.seat_name == null) return error.VirtualKeyboardUnavailable;
    }

    pub fn create(self: *Keyboard) !void {
        try self.available();
        if (self.device != null) return error.KeyboardAlreadyCreated;
        self.device = c.zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(self.manager, self.seat) orelse return error.VirtualKeyboardUnavailable;
        errdefer {
            c.zwp_virtual_keyboard_v1_destroy(self.device);
            self.device = null;
            self.has_keymap = false;
        }
        try self.connection.?.sync();
        try self.available();
    }

    fn sync(self: *Keyboard, rt: ?*Runtime) !void {
        const connection = if (self.connection) |*value| value else return error.VirtualKeyboardUnavailable;
        connection.runtime = rt;
        // Never retain a caller's runtime (in particular a stack-local scratch).
        defer connection.runtime = null;
        try connection.sync();
        if (rt != null) try self.available();
    }

    pub fn release(self: *Keyboard) void {
        if (self.device != null and self.has_keymap and self.held.count != 0) {
            self.held.release(self);
            self.sync(null) catch {};
        }
        self.held = .{};
    }

    pub fn deinit(self: *Keyboard) void {
        self.release();
        if (self.device) |device| c.zwp_virtual_keyboard_v1_destroy(device);
        if (self.manager) |manager| c.zwp_virtual_keyboard_manager_v1_destroy(manager);
        if (self.seat) |seat| c.wl_seat_destroy(seat);
        if (self.connection) |*connection| connection.deinit();
        self.* = .{};
    }

    fn timestamp() u32 {
        return @truncate(@as(u64, @intCast(native.nowMs())));
    }

    fn sendKey(self: *Keyboard, key: u32, state: u32) void {
        c.zwp_virtual_keyboard_v1_key(self.device, timestamp(), key, state);
    }

    fn sendModifiers(self: *Keyboard, mask: u32) void {
        c.zwp_virtual_keyboard_v1_modifiers(self.device, mask, 0, 0, 0);
    }

    fn upload(self: *Keyboard, rt: *Runtime, map: *const Keymap) !void {
        try self.available();
        if (self.device == null) return error.VirtualKeyboardUnavailable;
        if (self.held.count != 0) return error.KeyboardBusy;
        const fd = c.memfd_create("deskctl-keymap", c.MFD_CLOEXEC);
        if (fd < 0) return error.InputBufferFailed;
        defer _ = c.close(fd);
        // Include the NUL terminator; handle partial writes and interrupted syscalls.
        const bytes = map.text[0 .. map.text.len + 1];
        var written: usize = 0;
        while (written < bytes.len) {
            const n = c.write(fd, bytes.ptr + written, bytes.len - written);
            if (n < 0 and c.__errno_location().* == c.EINTR) continue;
            if (n <= 0) return error.InputBufferFailed;
            written += @intCast(n);
        }
        if (c.lseek(fd, 0, c.SEEK_SET) < 0) return error.InputBufferFailed;
        try rt.guard();
        c.zwp_virtual_keyboard_v1_keymap(self.device, c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, @intCast(bytes.len));
        self.has_keymap = true;
        self.sendModifiers(0);
        try self.sync(rt);
    }

    const Driver = struct {
        keyboard: *Keyboard,
        rt: *Runtime,
        fn guard(self: *@This()) !void {
            try self.keyboard.available();
            try self.rt.guard();
        }
        fn sendKey(self: *@This(), key: u32, state: u32) void {
            self.keyboard.sendKey(key, state);
        }
        fn sendModifiers(self: *@This(), mask: u32) void {
            self.keyboard.sendModifiers(mask);
        }
        fn sync(self: *@This(), guarded: bool) !void {
            try self.keyboard.sync(if (guarded) self.rt else null);
        }
    };

    pub fn typeText(self: *Keyboard, rt: *Runtime, text: []const u8) !void {
        // Validate the entire string before sending any prefix.
        var iterator = (try std.unicode.Utf8View.init(text)).iterator();
        errdefer self.release();
        while (true) {
            const chunk = TextChunk.next(&iterator);
            if (chunk.count == 0) break;
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            var map = try Keymap.init(arena.allocator(), chunk.symbols[0..chunk.symbol_count]);
            defer map.deinit();
            try self.upload(rt, &map);
            for (chunk.keys[0..chunk.count]) |key| {
                try rt.guard();
                self.held.press(self, .{ .code = key });
                self.held.pop(self);
                try self.sync(rt);
            }
        }
    }

    pub fn chord(self: *Keyboard, rt: *Runtime, value: []const u8) !void {
        const parsed = try Chord.parse(rt.a, value);
        var map = try Keymap.initChord(rt.a, parsed.symbol);
        defer map.deinit();
        var keys: [modifiers.len + 1]Key = undefined;
        for (parsed.mods[0..parsed.count], 0..) |index, i| {
            const mod = modifiers[index];
            keys[i] = .{ .code = mod.key, .mask = try map.mask(mod.name) };
        }
        keys[parsed.count] = .{ .code = dataKey(0) };
        try self.upload(rt, &map);
        var driver = Driver{ .keyboard = self, .rt = rt };
        try self.held.chord(&driver, keys[0 .. parsed.count + 1]);
    }
};

test "keyboard chord Shift levels translate Tab and letters without changing exact text" {
    const cases = [_][2]u32{
        .{ c.XKB_KEY_Tab, c.XKB_KEY_ISO_Left_Tab },
        .{ c.XKB_KEY_z, c.XKB_KEY_Z },
        .{ c.XKB_KEY_eacute, c.XKB_KEY_Eacute },
        .{ c.XKB_KEY_Right, c.XKB_KEY_Right },
    };
    for (cases) |pair| {
        var map = try Keymap.initChord(std.testing.allocator, pair[0]);
        defer map.deinit();
        // Compile the exact serialized map sent to the compositor.
        const context = c.xkb_context_new(c.XKB_CONTEXT_NO_DEFAULT_INCLUDES) orelse return error.OutOfMemory;
        defer c.xkb_context_unref(context);
        const compiled = c.xkb_keymap_new_from_string(context, map.text, c.XKB_KEYMAP_FORMAT_TEXT_V1, 0) orelse return error.InvalidKeymap;
        defer c.xkb_keymap_unref(compiled);
        const state = c.xkb_state_new(compiled) orelse return error.OutOfMemory;
        defer c.xkb_state_unref(state);
        const target = dataKey(0) + 8;
        const ctrl = try map.mask("Control");
        const shift = try map.mask("Shift");
        try std.testing.expectEqual(pair[0], c.xkb_state_key_get_one_sym(state, target));
        _ = c.xkb_state_update_key(state, 29 + 8, c.XKB_KEY_DOWN);
        try std.testing.expectEqual(pair[0], c.xkb_state_key_get_one_sym(state, target));
        _ = c.xkb_state_update_key(state, 42 + 8, c.XKB_KEY_DOWN);
        try std.testing.expectEqual(ctrl | shift, c.xkb_state_serialize_mods(state, c.XKB_STATE_MODS_DEPRESSED));
        try std.testing.expectEqual(pair[1], c.xkb_state_key_get_one_sym(state, target));
        try std.testing.expectEqual(if (pair[0] != pair[1]) shift else @as(u32, 0), c.xkb_state_key_get_consumed_mods(state, target));
        _ = c.xkb_state_update_key(state, target, c.XKB_KEY_DOWN);
        _ = c.xkb_state_update_key(state, target, c.XKB_KEY_UP);
        try std.testing.expectEqual(pair[1], c.xkb_state_key_get_one_sym(state, target));
        _ = c.xkb_state_update_key(state, 42 + 8, c.XKB_KEY_UP);
        try std.testing.expectEqual(pair[0], c.xkb_state_key_get_one_sym(state, target));
        _ = c.xkb_state_update_key(state, 29 + 8, c.XKB_KEY_UP);
        try std.testing.expectEqual(@as(u32, 0), c.xkb_state_serialize_mods(state, c.XKB_STATE_MODS_DEPRESSED));

        var exact = try Keymap.init(std.testing.allocator, &.{pair[0]});
        defer exact.deinit();
        const text_state = c.xkb_state_new(exact.compiled) orelse return error.OutOfMemory;
        defer c.xkb_state_unref(text_state);
        _ = c.xkb_state_update_key(text_state, 42 + 8, c.XKB_KEY_DOWN);
        try std.testing.expectEqual(pair[0], c.xkb_state_key_get_one_sym(text_state, target));
        try std.testing.expectEqual(@as(u32, 0), c.xkb_state_key_get_consumed_mods(text_state, target));
    }
}

test "keyboard parses documented modifiers and rejects malformed or duplicate chords" {
    const parsed = try Chord.parse(std.testing.allocator, "ctrl+shift+alt+super+altgr+F12");
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 2, 3, 4 }, parsed.mods[0..parsed.count]);
    try std.testing.expectEqual(@as(u32, c.XKB_KEY_F12), parsed.symbol);
    const bare = try Chord.parse(std.testing.allocator, "Return");
    try std.testing.expectEqual(@as(usize, 0), bare.count);
    const logo = try Chord.parse(std.testing.allocator, "logo+a");
    try std.testing.expectEqual(@as(usize, 3), logo.mods[0]);
    for ([_][]const u8{ "", "+a", "ctrl+", "ctrl++a", "ctrl+ctrl+a", "super+logo+a", "typo+a", "CTRL+a", "ctrl+a\x00b", "NotAnXkbKey" }) |bad| {
        try std.testing.expectError(error.InvalidKeyChord, Chord.parse(std.testing.allocator, bad));
    }
}

test "keyboard modifier masks match XKB actions and survive serialized keymap round trip" {
    var map = try Keymap.init(std.testing.allocator, &.{c.XKB_KEY_z});
    defer map.deinit();
    try std.testing.expectError(error.InvalidKeymap, map.mask("missing"));
    const context = c.xkb_context_new(c.XKB_CONTEXT_NO_DEFAULT_INCLUDES) orelse return error.OutOfMemory;
    defer c.xkb_context_unref(context);
    const roundtrip = c.xkb_keymap_new_from_string(context, map.text, c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return error.InvalidKeymap;
    defer c.xkb_keymap_unref(roundtrip);
    const state = c.xkb_state_new(roundtrip) orelse return error.OutOfMemory;
    defer c.xkb_state_unref(state);
    var expected: u32 = 0;
    for (modifiers) |mod| {
        try std.testing.expectEqual(c.xkb_keymap_mod_get_index(map.compiled, mod.name), c.xkb_keymap_mod_get_index(roundtrip, mod.name));
        const name = try std.testing.allocator.dupeZ(u8, mod.symbol);
        defer std.testing.allocator.free(name);
        try std.testing.expectEqual(c.xkb_keysym_from_name(name, 0), c.xkb_state_key_get_one_sym(state, mod.key + 8));
        _ = c.xkb_state_update_key(state, mod.key + 8, c.XKB_KEY_DOWN);
        expected |= try map.mask(mod.name);
        try std.testing.expectEqual(expected, c.xkb_state_serialize_mods(state, c.XKB_STATE_MODS_DEPRESSED));
        try std.testing.expectEqual(@as(u32, c.XKB_KEY_z), c.xkb_state_key_get_one_sym(state, dataKey(0) + 8));
        try std.testing.expectEqual(@as(u32, 0), c.xkb_state_key_get_consumed_mods(state, dataKey(0) + 8));
        try std.testing.expectEqual(@as(c_int, 0), c.xkb_keymap_key_repeats(roundtrip, mod.key + 8));
    }
    var i = modifiers.len;
    while (i > 0) {
        i -= 1;
        _ = c.xkb_state_update_key(state, modifiers[i].key + 8, c.XKB_KEY_UP);
        expected &= ~(try map.mask(modifiers[i].name));
        try std.testing.expectEqual(expected, c.xkb_state_serialize_mods(state, c.XKB_STATE_MODS_DEPRESSED));
    }
}

const FakeKeyboard = struct {
    const Event = union(enum) { key: struct { code: u32, state: u32 }, modifiers: u32 };
    events: [64]Event = undefined,
    count: usize = 0,
    guards: usize = 0,
    syncs: usize = 0,
    cleanup_syncs: usize = 0,
    fail_guard: ?usize = null,
    fail_sync: ?usize = null,

    fn sendKey(self: *@This(), key: u32, state: u32) void {
        self.events[self.count] = .{ .key = .{ .code = key, .state = state } };
        self.count += 1;
    }
    fn sendModifiers(self: *@This(), mask: u32) void {
        self.events[self.count] = .{ .modifiers = mask };
        self.count += 1;
    }
    fn guard(self: *@This()) !void {
        const n = self.guards;
        self.guards += 1;
        if (self.fail_guard == n) return error.ControlStopped;
    }
    fn sync(self: *@This(), guarded: bool) !void {
        const n = self.syncs;
        self.syncs += 1;
        if (!guarded) self.cleanup_syncs += 1;
        if (self.fail_sync == n) return error.WaylandUnavailable;
    }
    fn expectBalanced(self: *@This()) !void {
        var stack: [6]u32 = undefined;
        var count: usize = 0;
        var mask: u32 = 0;
        for (self.events[0..self.count]) |event| switch (event) {
            .key => |key| {
                if (key.state == 1) {
                    stack[count] = key.code;
                    count += 1;
                } else {
                    try std.testing.expect(count > 0);
                    count -= 1;
                    try std.testing.expectEqual(stack[count], key.code);
                }
            },
            .modifiers => |mods| mask = mods,
        };
        try std.testing.expectEqual(@as(usize, 0), count);
        try std.testing.expectEqual(@as(u32, 0), mask);
    }
};

test "keyboard emits modifier keys before target and releases target then modifiers" {
    var map = try Keymap.init(std.testing.allocator, &.{c.XKB_KEY_z});
    defer map.deinit();
    const ctrl = try map.mask("Control");
    const shift = try map.mask("Shift");
    var held = HeldKeys{};
    var fake = FakeKeyboard{};
    try held.chord(&fake, &.{ .{ .code = 29, .mask = ctrl }, .{ .code = 42, .mask = shift }, .{ .code = dataKey(0) } });
    const expected = [_]FakeKeyboard.Event{
        .{ .key = .{ .code = 29, .state = 1 } },         .{ .modifiers = ctrl },
        .{ .key = .{ .code = 42, .state = 1 } },         .{ .modifiers = ctrl | shift },
        .{ .key = .{ .code = dataKey(0), .state = 1 } }, .{ .key = .{ .code = dataKey(0), .state = 0 } },
        .{ .key = .{ .code = 42, .state = 0 } },         .{ .modifiers = ctrl },
        .{ .key = .{ .code = 29, .state = 0 } },         .{ .modifiers = 0 },
    };
    try std.testing.expectEqualDeep(expected[0..], fake.events[0..fake.count]);
    try std.testing.expectEqual(@as(usize, 3), fake.guards);
    try std.testing.expectEqual(@as(usize, 3), fake.syncs);
    try fake.expectBalanced();
    const previous_count = fake.count;
    held.release(&fake);
    held.release(&fake);
    try std.testing.expectEqual(previous_count, fake.count);
}

test "keyboard unwinds every guard and synchronization failure without guarded cleanup" {
    var map = try Keymap.init(std.testing.allocator, &.{c.XKB_KEY_a});
    defer map.deinit();
    var keys: [6]Key = undefined;
    for (modifiers, 0..) |mod, i| keys[i] = .{ .code = mod.key, .mask = try map.mask(mod.name) };
    keys[5] = .{ .code = dataKey(0) };
    for (0..keys.len) |stage| {
        var held = HeldKeys{};
        var fake = FakeKeyboard{ .fail_guard = stage };
        try std.testing.expectError(error.ControlStopped, held.chord(&fake, &keys));
        try fake.expectBalanced();
        try std.testing.expectEqual(@as(usize, 0), held.count);
        try std.testing.expectEqual(@as(u32, 0), held.depressed);
        try std.testing.expectEqual(@as(usize, 1), fake.cleanup_syncs);
    }
    // Also fail the final unguarded delivery sync: success must not hide errors.
    for (0..keys.len) |stage| {
        var held = HeldKeys{};
        var fake = FakeKeyboard{ .fail_sync = stage };
        try std.testing.expectError(error.WaylandUnavailable, held.chord(&fake, &keys));
        try fake.expectBalanced();
        try std.testing.expectEqual(@as(usize, 0), held.count);
        try std.testing.expectEqual(@as(u32, 0), held.depressed);
        try std.testing.expect(fake.cleanup_syncs > 0);
    }
}

test "keyboard Unicode chunks preserve scalars controls and repeated keys" {
    const text = "Aé中😀e\u{301}é\n\r\t\x1b";
    var iterator = (try std.unicode.Utf8View.init(text)).iterator();
    const chunk = TextChunk.next(&iterator);
    try std.testing.expectEqual(@as(usize, 11), chunk.count);
    try std.testing.expectEqual(@as(usize, 9), chunk.symbol_count);
    try std.testing.expectEqual(chunk.keys[1], chunk.keys[6]);
    try std.testing.expectEqual(chunk.keys[7], chunk.keys[8]);
    var map = try Keymap.init(std.testing.allocator, chunk.symbols[0..chunk.symbol_count]);
    defer map.deinit();
    const state = c.xkb_state_new(map.compiled) orelse return error.OutOfMemory;
    defer c.xkb_state_unref(state);
    for ([_]u32{ 'A', 'é', '中', 0x1f600, 'e', 0x301, 'é', '\r', '\r', '\t', 0x1b }, 0..) |cp, i| {
        try std.testing.expectEqual(cp, c.xkb_state_key_get_utf32(state, chunk.keys[i] + 8));
    }
    try std.testing.expectEqual(@as(usize, 0), TextChunk.next(&iterator).count);
}

test "keyboard maximum Unicode chunks avoid modifier collisions and keycode limits" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    for (0..257) |i| {
        var encoded: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(@intCast(0x400 + i), &encoded);
        try bytes.appendSlice(std.testing.allocator, encoded[0..n]);
    }
    var iterator = (try std.unicode.Utf8View.init(bytes.items)).iterator();
    var total: usize = 0;
    for ([_]usize{ 128, 128, 1, 0 }) |size| {
        const chunk = TextChunk.next(&iterator);
        try std.testing.expectEqual(size, chunk.count);
        try std.testing.expectEqual(size, chunk.symbol_count);
        if (size == 0) break;
        var map = try Keymap.init(std.testing.allocator, chunk.symbols[0..size]);
        defer map.deinit();
        const state = c.xkb_state_new(map.compiled) orelse return error.OutOfMemory;
        defer c.xkb_state_unref(state);
        for (chunk.keys[0..size], 0..) |key, i| {
            try std.testing.expect(key + 8 <= 255);
            for (modifiers) |mod| try std.testing.expect(key != mod.key);
            try std.testing.expectEqual(@as(u32, @intCast(0x400 + total + i)), c.xkb_state_key_get_utf32(state, key + 8));
        }
        total += size;
    }
    try std.testing.expectEqual(@as(usize, 257), total);
    try std.testing.expectError(error.InvalidKeymap, Keymap.init(std.testing.allocator, &.{}));
    try std.testing.expectError(error.InvalidKeymap, Keymap.init(std.testing.allocator, &(@as([129]u32, @splat(c.XKB_KEY_a)))));
}

test "keyboard cleanup is idempotent without a connection and invalid UTF8 sends nothing" {
    var keyboard = Keyboard{};
    try std.testing.expectError(error.VirtualKeyboardUnavailable, keyboard.create());
    // No runtime field may be accessed before full UTF8 validation, or for empty text.
    var rt: Runtime = undefined;
    try std.testing.expectError(error.InvalidUtf8, keyboard.typeText(&rt, "valid prefix\xff"));
    try keyboard.typeText(&rt, "");
    keyboard.release();
    keyboard.deinit();
    keyboard.deinit();
    try std.testing.expect(keyboard.connection == null and keyboard.device == null);
    keyboard.manager_name = 10;
    keyboard.seat_name = 11;
    Keyboard.removed(&keyboard, null, 99);
    try std.testing.expectEqual(@as(?u32, 10), keyboard.manager_name);
    Keyboard.removed(&keyboard, null, 10);
    Keyboard.removed(&keyboard, null, 11);
    try std.testing.expect(keyboard.manager_name == null and keyboard.seat_name == null);
}
