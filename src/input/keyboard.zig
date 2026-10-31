const std = @import("std");
const assert = std.debug.assert;
const native = @import("../platform/native.zig");
const c = native.c;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const Connection = @import("../platform/wayland.zig").Connection;
const eq = @import("../core/text.zig").eq;

pub const Modifier = struct {
    /// XKB virtual modifier name used in the generated keymap.
    name: [:0]const u8,
    key_name: []const u8,
    symbol: []const u8,
    // Linux/Wayland keycodes; XKB keycodes have an offset of eight.
    key: u32,
    /// Canonical CLI spelling; also the name wtype expects.
    alias: []const u8,
    /// Spelling xdotool expects.
    x11: []const u8,
};
pub const modifiers = [_]Modifier{
    .{
        .name = "Shift",
        .key_name = "LFSH",
        .symbol = "Shift_L",
        .key = 42,
        .alias = "shift",
        .x11 = "shift",
    },
    .{
        .name = "Control",
        .key_name = "LCTL",
        .symbol = "Control_L",
        .key = 29,
        .alias = "ctrl",
        .x11 = "ctrl",
    },
    .{
        .name = "Mod1",
        .key_name = "LALT",
        .symbol = "Alt_L",
        .key = 56,
        .alias = "alt",
        .x11 = "alt",
    },
    .{
        .name = "Mod4",
        .key_name = "LWIN",
        .symbol = "Super_L",
        .key = 125,
        .alias = "logo",
        .x11 = "super",
    },
    .{
        .name = "Mod5",
        .key_name = "RALT",
        .symbol = "ISO_Level3_Shift",
        .key = 100,
        .alias = "altgr",
        .x11 = "ISO_Level3_Shift",
    },
};
const chunk_size = 128;

pub fn modifier_index(name: []const u8) ?usize {
    // "super" is accepted as a synonym of "logo".
    if (eq(name, "super")) return modifier_index("logo");
    for (modifiers, 0..) |modifier, i| if (eq(name, modifier.alias)) return i;
    return null;
}

// Keep data keys disjoint from the real modifier keycodes in every chunk.
fn data_key(index: usize) u32 {
    var remaining = index;
    var key: u32 = 1;
    while (true) : (key += 1) {
        var reserved = false;
        for (modifiers) |modifier| if (key == modifier.key) {
            reserved = true;
            break;
        };
        if (reserved) continue;

        if (remaining == 0) return key;
        remaining -= 1;
    }
}

/// A parsed "mod+mod+Key" chord. Modifiers are indices into `modifiers`, in
/// the order given; the final key keeps its spelling for helper backends.
pub const Chord = struct {
    symbol: u32,
    key_name: []const u8 = "",
    mods: [modifiers.len]usize = undefined,
    count: usize = 0,

    pub fn parse(allocator: std.mem.Allocator, value: []const u8) !Chord {
        var result = Chord{ .symbol = 0 };
        var parts = std.mem.splitScalar(u8, value, '+');
        while (parts.next()) |part| {
            if (part.len == 0) return error.InvalidKeyChord;

            if (parts.peek() != null) {
                const index = modifier_index(part) orelse return error.InvalidKeyChord;
                for (result.mods[0..result.count]) |existing| {
                    if (existing == index) return error.InvalidKeyChord;
                }
                result.mods[result.count] = index;
                result.count += 1;
            } else {
                for (part) |character| {
                    const valid = std.ascii.isAlphanumeric(character) or character == '_';
                    if (!valid) return error.InvalidKeyChord;
                }
                const name = try allocator.dupeSentinel(u8, part, 0);
                defer allocator.free(name);
                result.symbol = c.xkb_keysym_from_name(name, c.XKB_KEYSYM_CASE_INSENSITIVE);
                result.key_name = part;
            }
        }

        if (result.symbol == c.XKB_KEY_NoSymbol) return error.InvalidKeyChord;
        return result;
    }

    pub fn modifier_slice(self: *const Chord) []const usize {
        return self.mods[0..self.count];
    }
};

const Keymap = struct {
    compiled: *c.struct_xkb_keymap,
    text: [:0]const u8,

    fn init(allocator: std.mem.Allocator, symbols: []const u32) !Keymap {
        return compile(allocator, symbols, false);
    }

    fn init_chord(allocator: std.mem.Allocator, symbol: u32) !Keymap {
        return compile(allocator, &.{symbol}, true);
    }

    fn compile(allocator: std.mem.Allocator, symbols: []const u32, chord_levels: bool) !Keymap {
        if (symbols.len == 0) return error.InvalidKeymap;
        if (symbols.len > chunk_size) return error.InvalidKeymap;

        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(allocator);
        try compile_source(allocator, &source, symbols, chord_levels);
        const source_terminated = try source.toOwnedSliceSentinel(allocator, 0);
        defer allocator.free(source_terminated);

        const context_flags = c.XKB_CONTEXT_NO_DEFAULT_INCLUDES |
            c.XKB_CONTEXT_NO_ENVIRONMENT_NAMES;
        const context = c.xkb_context_new(context_flags) orelse return error.InvalidKeymap;
        defer c.xkb_context_unref(context);
        const compiled = c.xkb_keymap_new_from_string(
            context,
            source_terminated,
            c.XKB_KEYMAP_FORMAT_TEXT_V1,
            c.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse return error.InvalidKeymap;
        errdefer c.xkb_keymap_unref(compiled);
        const serialized = c.xkb_keymap_get_as_string(
            compiled,
            c.XKB_KEYMAP_FORMAT_TEXT_V1,
        ) orelse return error.InvalidKeymap;
        return .{ .compiled = compiled, .text = std.mem.span(serialized) };
    }

    fn compile_source(
        allocator: std.mem.Allocator,
        source: *std.ArrayList(u8),
        symbols: []const u32,
        chord_levels: bool,
    ) !void {
        try source.appendSlice(
            allocator,
            "xkb_keymap { xkb_keycodes { minimum=8; maximum=255; ",
        );
        for (symbols, 0..) |_, i| {
            try source.print(allocator, "<K{d}>={d};", .{ i, data_key(i) + 8 });
        }
        for (modifiers) |modifier| {
            try source.print(allocator, "<{s}>={d};", .{ modifier.key_name, modifier.key + 8 });
        }

        // Self-contained types/actions avoid host layout and include-file dependencies.
        // Text stays exact. Chords need real Shift levels: GTK's
        // gdk_key_event_matches expects ISO_Left_Tab and uppercase keysyms.
        // https://github.com/GNOME/gtk/blob/4.22.4/gdk/gdkevents.c
        try source.appendSlice(
            allocator,
            "}; xkb_types { " ++
                "type \"ONE_LEVEL\" { modifiers=None; map[None]=Level1; }; " ++
                "type \"TWO_LEVEL\" { modifiers=Shift; map[None]=Level1; map[Shift]=Level2; }; " ++
                "}; xkb_compatibility {}; xkb_symbols { ",
        );
        for (symbols, 0..) |symbol, i| {
            const shifted: u32 = if (symbol == c.XKB_KEY_Tab)
                c.XKB_KEY_ISO_Left_Tab
            else
                c.xkb_keysym_to_upper(symbol);
            if (chord_levels and shifted != symbol) {
                try source.print(
                    allocator,
                    "key <K{d}> {{ type=\"TWO_LEVEL\", [0x{x},0x{x}], repeat=no }};",
                    .{ i, symbol, shifted },
                );
            } else {
                try source.print(
                    allocator,
                    "key <K{d}> {{ type=\"ONE_LEVEL\", [0x{x}], repeat=no }};",
                    .{ i, symbol },
                );
            }
        }
        for (modifiers) |modifier| {
            try source.print(
                allocator,
                "key <{s}> {{ type=\"ONE_LEVEL\", [{s}], " ++
                    "actions=[SetMods(modifiers={s})], repeat=no }}; " ++
                    "modifier_map {s} {{ <{s}> }};",
                .{
                    modifier.key_name,
                    modifier.symbol,
                    modifier.name,
                    modifier.name,
                    modifier.key_name,
                },
            );
        }
        try source.appendSlice(allocator, "}; };");
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

    fn press(self: *HeldKeys, sink: anytype, key: Key) !void {
        assert(self.count <= self.keys.len);
        if (self.count == self.keys.len) return error.TooManyHeldKeys;

        self.keys[self.count] = key;
        self.count += 1;
        sink.send_key(key.code, 1);
        const mask = self.depressed | key.mask;
        if (mask != self.depressed) sink.send_modifiers(mask);
        self.depressed = mask;
    }

    fn pop(self: *HeldKeys, sink: anytype) void {
        if (self.count == 0) return;

        self.count -= 1;
        sink.send_key(self.keys[self.count].code, 0);
        var mask: u32 = 0;
        for (self.keys[0..self.count]) |key| mask |= key.mask;
        if (mask != self.depressed) sink.send_modifiers(mask);
        self.depressed = mask;
    }

    fn release(self: *HeldKeys, sink: anytype) void {
        while (self.count > 0) self.pop(sink);
        // Nothing may stay pressed: a stuck modifier would corrupt every
        // later keystroke on the human's desktop.
        assert(self.count == 0);
        assert(self.depressed == 0);
    }

    // Blender's keyboard_handle_key calls keyboard_depressed_state_key_event;
    // keyboard_handle_modifiers only updates its XKB mask. Both events matter:
    // https://github.com/blender/blender/blob/main/intern/ghost/intern/GHOST_SystemWayland.cc
    // The same sequencing runs against Wayland and an in-memory test driver.
    // Synchronize each modifier before the target, then unwind in reverse order.
    fn chord(self: *HeldKeys, driver: anytype, keys: []const Key) !void {
        if (keys.len == 0) return error.KeyboardBusy;
        if (keys.len > self.keys.len) return error.KeyboardBusy;
        if (self.count != 0) return error.KeyboardBusy;

        errdefer {
            self.release(driver);
            driver.sync(false) catch {};
        }
        for (keys[0 .. keys.len - 1]) |key| {
            try driver.guard();
            try self.press(driver, key);
            try driver.sync(true);
        }
        try driver.guard();
        try self.press(driver, keys[keys.len - 1]);
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
            const codepoint = iterator.nextCodepoint() orelse break;
            // A CRLF pair is one line break; a lone CR or LF is one as well.
            const crlf = codepoint == '\r' and std.mem.eql(u8, iterator.peek(1), "\n");
            if (crlf) _ = iterator.nextCodepoint();

            const symbol: u32 = switch (codepoint) {
                '\n', '\r' => c.XKB_KEY_Return,
                '\t' => c.XKB_KEY_Tab,
                0x1b => c.XKB_KEY_Escape,
                else => c.xkb_utf32_to_keysym(codepoint),
            };
            const symbols_seen = result.symbols[0..result.symbol_count];
            const index = std.mem.indexOfScalar(u32, symbols_seen, symbol) orelse blk: {
                const index_appended = result.symbol_count;
                result.symbols[index_appended] = symbol;
                result.symbol_count += 1;
                break :blk index_appended;
            };
            result.keys[result.count] = data_key(index);
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

    fn global(
        data: ?*anyopaque,
        registry: ?*c.struct_wl_registry,
        name: u32,
        interface: [*c]const u8,
        version: u32,
    ) callconv(.c) void {
        const self: *Keyboard = @ptrCast(@alignCast(data.?));
        const interface_name = std.mem.span(interface);
        if (version == 0) return;

        if (eq(interface_name, "zwp_virtual_keyboard_manager_v1") and self.manager == null) {
            self.manager = @ptrCast(c.wl_registry_bind(
                registry,
                name,
                &c.zwp_virtual_keyboard_manager_v1_interface,
                1,
            ));
            self.manager_name = name;
        }
        if (eq(interface_name, "wl_seat") and self.seat == null) {
            self.seat = @ptrCast(c.wl_registry_bind(
                registry,
                name,
                &c.wl_seat_interface,
                @min(7, version),
            ));
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
        self.connection = try Connection.connect(display);
        errdefer self.deinit();

        const connection = &self.connection.?;
        if (c.wl_registry_add_listener(connection.registry, &listener, self) != 0) {
            return error.WaylandUnavailable;
        }
        try connection.sync();
        try self.available();
    }

    fn available(self: *const Keyboard) !void {
        if (self.connection == null) return error.VirtualKeyboardUnavailable;
        if (self.manager == null) return error.VirtualKeyboardUnavailable;
        if (self.seat == null) return error.VirtualKeyboardUnavailable;
        if (self.manager_name == null) return error.VirtualKeyboardUnavailable;
        if (self.seat_name == null) return error.VirtualKeyboardUnavailable;
    }

    pub fn create(self: *Keyboard) !void {
        try self.available();
        if (self.device != null) return error.KeyboardAlreadyCreated;

        self.device = c.zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(
            self.manager,
            self.seat,
        ) orelse return error.VirtualKeyboardUnavailable;
        errdefer {
            c.zwp_virtual_keyboard_v1_destroy(self.device);
            self.device = null;
            self.has_keymap = false;
        }
        try self.connection.?.sync();
        try self.available();
    }

    fn sync(self: *Keyboard, runtime: ?*Runtime) !void {
        return self.sync_checked(runtime, false);
    }

    fn sync_checked(self: *Keyboard, runtime: ?*Runtime, already_guarded: bool) !void {
        const connection = if (self.connection) |*value|
            value
        else
            return error.VirtualKeyboardUnavailable;
        connection.runtime = runtime;
        // Never retain a caller's runtime (in particular a stack-local scratch).
        defer connection.runtime = null;

        if (already_guarded) {
            try connection.sync_after_guard();
        } else {
            try connection.sync_with_cancellation(runtime != null);
        }
        if (runtime != null) try self.available();
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

    fn send_key(self: *Keyboard, key: u32, state: u32) void {
        c.zwp_virtual_keyboard_v1_key(self.device, native.timestamp_ms(), key, state);
    }

    fn send_modifiers(self: *Keyboard, mask: u32) void {
        c.zwp_virtual_keyboard_v1_modifiers(self.device, mask, 0, 0, 0);
    }

    /// A memory file holding `text` and its NUL terminator, rewound.
    fn keymap_buffer(text: [:0]const u8) !c_int {
        const fd = c.memfd_create("hyprhand-keymap", c.MFD_CLOEXEC);
        if (fd < 0) return error.InputBufferFailed;
        errdefer _ = c.close(fd);
        // Include the NUL terminator; handle partial writes and interrupted syscalls.
        const bytes = text[0 .. text.len + 1];
        var written: usize = 0;
        while (written < bytes.len) {
            const write_result = c.write(fd, bytes.ptr + written, bytes.len - written);
            if (write_result < 0 and native.errno() == c.EINTR) continue;
            if (write_result <= 0) return error.InputBufferFailed;
            written += @intCast(write_result);
        }
        if (c.lseek(fd, 0, c.SEEK_SET) < 0) return error.InputBufferFailed;
        return fd;
    }

    fn send_keymap(self: *Keyboard, fd: c_int, text: [:0]const u8) void {
        c.zwp_virtual_keyboard_v1_keymap(
            self.device,
            c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,
            fd,
            @intCast(text.len + 1),
        );
        self.has_keymap = true;
        self.send_modifiers(0);
    }

    fn upload(self: *Keyboard, runtime: *Runtime, map: *const Keymap) !void {
        try self.available();
        if (self.device == null) return error.VirtualKeyboardUnavailable;
        if (self.held.count != 0) return error.KeyboardBusy;

        const fd = try keymap_buffer(map.text);
        defer _ = c.close(fd);
        try runtime.guard();
        self.send_keymap(fd, map.text);
        try self.sync(runtime);
    }

    /// Uploads a complete serialized keymap without an action guard. Only the
    /// preview takeover worker calls this and the other *_unguarded/queue_*
    /// functions, after revoking agent control: it forwards a human's keys.
    pub fn upload_unguarded(self: *Keyboard, text: [:0]const u8) !void {
        try self.available();
        if (self.device == null) return error.VirtualKeyboardUnavailable;
        if (self.held.count != 0) return error.KeyboardBusy;

        const fd = try keymap_buffer(text);
        defer _ = c.close(fd);
        self.send_keymap(fd, text);
        try self.roundtrip_unguarded();
    }

    /// A cancellable roundtrip that also detects a lost compositor.
    pub fn roundtrip_unguarded(self: *Keyboard) !void {
        const connection = if (self.connection) |*value|
            value
        else
            return error.VirtualKeyboardUnavailable;
        try connection.sync_with_cancellation(true);
        try self.available();
    }

    /// Queues one key of the uploaded keymap. Callers track what they hold.
    pub fn queue_key(self: *Keyboard, key: u32, pressed: bool) void {
        self.send_key(key, @intFromBool(pressed));
    }

    pub fn queue_modifiers(
        self: *Keyboard,
        depressed: u32,
        latched: u32,
        locked: u32,
        group: u32,
    ) void {
        c.zwp_virtual_keyboard_v1_modifiers(self.device, depressed, latched, locked, group);
    }

    pub fn flush(self: *Keyboard) !void {
        const connection = if (self.connection) |*value|
            value
        else
            return error.VirtualKeyboardUnavailable;
        try connection.flush();
    }

    const Driver = struct {
        keyboard: *Keyboard,
        runtime: *Runtime,
        fn guard(self: *@This()) !void {
            try self.keyboard.available();
            try self.runtime.guard();
        }
        fn send_key(self: *@This(), key: u32, state: u32) void {
            self.keyboard.send_key(key, state);
        }
        fn send_modifiers(self: *@This(), mask: u32) void {
            self.keyboard.send_modifiers(mask);
        }
        fn sync(self: *@This(), guarded: bool) !void {
            try self.keyboard.sync(if (guarded) self.runtime else null);
        }
    };

    pub fn type_text(self: *Keyboard, runtime: *Runtime, text: []const u8) !void {
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
            try self.upload(runtime, &map);

            for (chunk.keys[0..chunk.count]) |key| {
                try runtime.guard();
                try self.held.press(self, .{ .code = key });
                self.held.pop(self);
                try self.sync_checked(runtime, true);
            }
        }
    }

    pub fn chord(self: *Keyboard, runtime: *Runtime, value: []const u8) !void {
        const parsed = try Chord.parse(runtime.allocator, value);
        var map = try Keymap.init_chord(runtime.allocator, parsed.symbol);
        defer map.deinit();

        var keys: [modifiers.len + 1]Key = undefined;
        for (parsed.modifier_slice(), 0..) |index, i| {
            const modifier = modifiers[index];
            keys[i] = .{ .code = modifier.key, .mask = try map.mask(modifier.name) };
        }
        keys[parsed.count] = .{ .code = data_key(0) };

        try self.upload(runtime, &map);
        var driver = Driver{ .keyboard = self, .runtime = runtime };
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
    const depressed = c.XKB_STATE_MODS_DEPRESSED;
    for (cases) |pair| {
        var map = try Keymap.init_chord(std.testing.allocator, pair[0]);
        defer map.deinit();
        // Compile the exact serialized map sent to the compositor.
        const context = c.xkb_context_new(c.XKB_CONTEXT_NO_DEFAULT_INCLUDES) orelse
            return error.OutOfMemory;
        defer c.xkb_context_unref(context);
        const compiled = c.xkb_keymap_new_from_string(
            context,
            map.text,
            c.XKB_KEYMAP_FORMAT_TEXT_V1,
            0,
        ) orelse return error.InvalidKeymap;
        defer c.xkb_keymap_unref(compiled);
        const state = c.xkb_state_new(compiled) orelse return error.OutOfMemory;
        defer c.xkb_state_unref(state);

        const target = data_key(0) + 8;
        const control = try map.mask("Control");
        const shift = try map.mask("Shift");
        const consumed_expected = if (pair[0] != pair[1]) shift else @as(u32, 0);
        try std.testing.expectEqual(pair[0], c.xkb_state_key_get_one_sym(state, target));
        _ = c.xkb_state_update_key(state, 29 + 8, c.XKB_KEY_DOWN);
        try std.testing.expectEqual(pair[0], c.xkb_state_key_get_one_sym(state, target));
        _ = c.xkb_state_update_key(state, 42 + 8, c.XKB_KEY_DOWN);
        try std.testing.expectEqual(control | shift, c.xkb_state_serialize_mods(state, depressed));
        try std.testing.expectEqual(pair[1], c.xkb_state_key_get_one_sym(state, target));
        try std.testing.expectEqual(
            consumed_expected,
            c.xkb_state_key_get_consumed_mods(state, target),
        );
        _ = c.xkb_state_update_key(state, target, c.XKB_KEY_DOWN);
        _ = c.xkb_state_update_key(state, target, c.XKB_KEY_UP);
        try std.testing.expectEqual(pair[1], c.xkb_state_key_get_one_sym(state, target));
        _ = c.xkb_state_update_key(state, 42 + 8, c.XKB_KEY_UP);
        try std.testing.expectEqual(pair[0], c.xkb_state_key_get_one_sym(state, target));
        _ = c.xkb_state_update_key(state, 29 + 8, c.XKB_KEY_UP);
        try std.testing.expectEqual(@as(u32, 0), c.xkb_state_serialize_mods(state, depressed));

        var exact = try Keymap.init(std.testing.allocator, &.{pair[0]});
        defer exact.deinit();
        const text_state = c.xkb_state_new(exact.compiled) orelse return error.OutOfMemory;
        defer c.xkb_state_unref(text_state);
        _ = c.xkb_state_update_key(text_state, 42 + 8, c.XKB_KEY_DOWN);
        try std.testing.expectEqual(pair[0], c.xkb_state_key_get_one_sym(text_state, target));
        try std.testing.expectEqual(
            @as(u32, 0),
            c.xkb_state_key_get_consumed_mods(text_state, target),
        );
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

    const malformed = [_][]const u8{
        "",
        "+a",
        "ctrl+",
        "ctrl++a",
        "ctrl+ctrl+a",
        "super+logo+a",
        "typo+a",
        "CTRL+a",
        "ctrl+a\x00b",
        "NotAnXkbKey",
    };
    for (malformed) |bad| {
        try std.testing.expectError(error.InvalidKeyChord, Chord.parse(std.testing.allocator, bad));
    }
}

test "keyboard modifier masks match XKB actions and survive serialized keymap round trip" {
    var map = try Keymap.init(std.testing.allocator, &.{c.XKB_KEY_z});
    defer map.deinit();
    try std.testing.expectError(error.InvalidKeymap, map.mask("missing"));

    const context = c.xkb_context_new(c.XKB_CONTEXT_NO_DEFAULT_INCLUDES) orelse
        return error.OutOfMemory;
    defer c.xkb_context_unref(context);
    const roundtrip = c.xkb_keymap_new_from_string(
        context,
        map.text,
        c.XKB_KEYMAP_FORMAT_TEXT_V1,
        c.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return error.InvalidKeymap;
    defer c.xkb_keymap_unref(roundtrip);
    const state = c.xkb_state_new(roundtrip) orelse return error.OutOfMemory;
    defer c.xkb_state_unref(state);

    const depressed = c.XKB_STATE_MODS_DEPRESSED;
    const target = data_key(0) + 8;
    var expected: u32 = 0;
    for (modifiers) |modifier| {
        try std.testing.expectEqual(
            c.xkb_keymap_mod_get_index(map.compiled, modifier.name),
            c.xkb_keymap_mod_get_index(roundtrip, modifier.name),
        );
        const name = try std.testing.allocator.dupeSentinel(u8, modifier.symbol, 0);
        defer std.testing.allocator.free(name);
        try std.testing.expectEqual(
            c.xkb_keysym_from_name(name, 0),
            c.xkb_state_key_get_one_sym(state, modifier.key + 8),
        );
        _ = c.xkb_state_update_key(state, modifier.key + 8, c.XKB_KEY_DOWN);
        expected |= try map.mask(modifier.name);
        try std.testing.expectEqual(expected, c.xkb_state_serialize_mods(state, depressed));
        try std.testing.expectEqual(
            @as(u32, c.XKB_KEY_z),
            c.xkb_state_key_get_one_sym(state, target),
        );
        try std.testing.expectEqual(
            @as(u32, 0),
            c.xkb_state_key_get_consumed_mods(state, target),
        );
        try std.testing.expectEqual(
            @as(c_int, 0),
            c.xkb_keymap_key_repeats(roundtrip, modifier.key + 8),
        );
    }

    var i = modifiers.len;
    while (i > 0) {
        i -= 1;
        _ = c.xkb_state_update_key(state, modifiers[i].key + 8, c.XKB_KEY_UP);
        expected &= ~(try map.mask(modifiers[i].name));
        try std.testing.expectEqual(expected, c.xkb_state_serialize_mods(state, depressed));
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

    fn send_key(self: *@This(), key: u32, state: u32) void {
        self.events[self.count] = .{ .key = .{ .code = key, .state = state } };
        self.count += 1;
    }
    fn send_modifiers(self: *@This(), mask: u32) void {
        self.events[self.count] = .{ .modifiers = mask };
        self.count += 1;
    }
    fn guard(self: *@This()) !void {
        const guard_index = self.guards;
        self.guards += 1;
        if (self.fail_guard == guard_index) return error.ControlStopped;
    }
    fn sync(self: *@This(), guarded: bool) !void {
        const sync_index = self.syncs;
        self.syncs += 1;
        if (!guarded) self.cleanup_syncs += 1;
        if (self.fail_sync == sync_index) return error.WaylandUnavailable;
    }
    fn expect_balanced(self: *@This()) !void {
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
            .modifiers => |depressed| mask = depressed,
        };
        try std.testing.expectEqual(@as(usize, 0), count);
        try std.testing.expectEqual(@as(u32, 0), mask);
    }
};

test "keyboard emits modifier keys before target and releases target then modifiers" {
    var map = try Keymap.init(std.testing.allocator, &.{c.XKB_KEY_z});
    defer map.deinit();
    const control = try map.mask("Control");
    const shift = try map.mask("Shift");

    var held = HeldKeys{};
    var fake = FakeKeyboard{};
    try held.chord(&fake, &.{
        .{ .code = 29, .mask = control },
        .{ .code = 42, .mask = shift },
        .{ .code = data_key(0) },
    });
    const expected = [_]FakeKeyboard.Event{
        .{ .key = .{ .code = 29, .state = 1 } },
        .{ .modifiers = control },
        .{ .key = .{ .code = 42, .state = 1 } },
        .{ .modifiers = control | shift },
        .{ .key = .{ .code = data_key(0), .state = 1 } },
        .{ .key = .{ .code = data_key(0), .state = 0 } },
        .{ .key = .{ .code = 42, .state = 0 } },
        .{ .modifiers = control },
        .{ .key = .{ .code = 29, .state = 0 } },
        .{ .modifiers = 0 },
    };
    try std.testing.expectEqualDeep(expected[0..], fake.events[0..fake.count]);
    try std.testing.expectEqual(@as(usize, 3), fake.guards);
    try std.testing.expectEqual(@as(usize, 3), fake.syncs);
    try fake.expect_balanced();

    const previous_count = fake.count;
    held.release(&fake);
    held.release(&fake);
    try std.testing.expectEqual(previous_count, fake.count);
}

test "keyboard unwinds every guard and synchronization failure without guarded cleanup" {
    var map = try Keymap.init(std.testing.allocator, &.{c.XKB_KEY_a});
    defer map.deinit();
    var keys: [6]Key = undefined;
    for (modifiers, 0..) |modifier, i| {
        keys[i] = .{ .code = modifier.key, .mask = try map.mask(modifier.name) };
    }
    keys[5] = .{ .code = data_key(0) };

    for (0..keys.len) |stage| {
        var held = HeldKeys{};
        var fake = FakeKeyboard{ .fail_guard = stage };
        try std.testing.expectError(error.ControlStopped, held.chord(&fake, &keys));
        try fake.expect_balanced();
        try std.testing.expectEqual(@as(usize, 0), held.count);
        try std.testing.expectEqual(@as(u32, 0), held.depressed);
        try std.testing.expectEqual(@as(usize, 1), fake.cleanup_syncs);
    }
    // Also fail the final unguarded delivery sync: success must not hide errors.
    for (0..keys.len) |stage| {
        var held = HeldKeys{};
        var fake = FakeKeyboard{ .fail_sync = stage };
        try std.testing.expectError(error.WaylandUnavailable, held.chord(&fake, &keys));
        try fake.expect_balanced();
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
    const expected = [_]u32{ 'A', 'é', '中', 0x1f600, 'e', 0x301, 'é', '\r', '\r', '\t', 0x1b };
    for (expected, 0..) |codepoint, i| {
        try std.testing.expectEqual(codepoint, c.xkb_state_key_get_utf32(state, chunk.keys[i] + 8));
    }
    try std.testing.expectEqual(@as(usize, 0), TextChunk.next(&iterator).count);

    // Windows line endings are one Return, not two.
    var crlf = (try std.unicode.Utf8View.init("a\r\nb\n\r")).iterator();
    const lines = TextChunk.next(&crlf);
    try std.testing.expectEqual(@as(usize, 5), lines.count);
    try std.testing.expectEqual(lines.keys[1], lines.keys[3]);
    try std.testing.expectEqual(lines.keys[1], lines.keys[4]);
}

test "keyboard maximum Unicode chunks avoid modifier collisions and keycode limits" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    for (0..257) |i| {
        var encoded: [4]u8 = undefined;
        const encoded_length = try std.unicode.utf8Encode(@intCast(0x400 + i), &encoded);
        try bytes.appendSlice(std.testing.allocator, encoded[0..encoded_length]);
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
            for (modifiers) |modifier| try std.testing.expect(key != modifier.key);
            try std.testing.expectEqual(
                @as(u32, @intCast(0x400 + total + i)),
                c.xkb_state_key_get_utf32(state, key + 8),
            );
        }
        total += size;
    }
    try std.testing.expectEqual(@as(usize, 257), total);

    const allocator = std.testing.allocator;
    const oversized: [129]u32 = @splat(c.XKB_KEY_a);
    try std.testing.expectError(error.InvalidKeymap, Keymap.init(allocator, &.{}));
    try std.testing.expectError(error.InvalidKeymap, Keymap.init(allocator, &oversized));
}

test "keyboard cleanup is idempotent without a connection and invalid UTF8 sends nothing" {
    var keyboard = Keyboard{};
    try std.testing.expectError(error.VirtualKeyboardUnavailable, keyboard.create());
    // No runtime field may be accessed before full UTF8 validation, or for empty text.
    var runtime: Runtime = undefined;
    try std.testing.expectError(
        error.InvalidUtf8,
        keyboard.type_text(&runtime, "valid prefix\xff"),
    );
    try keyboard.type_text(&runtime, "");

    keyboard.release();
    keyboard.deinit();
    keyboard.deinit();
    try std.testing.expect(keyboard.connection == null);
    try std.testing.expect(keyboard.device == null);

    keyboard.manager_name = 10;
    keyboard.seat_name = 11;
    Keyboard.removed(&keyboard, null, 99);
    try std.testing.expectEqual(@as(?u32, 10), keyboard.manager_name);
    Keyboard.removed(&keyboard, null, 10);
    Keyboard.removed(&keyboard, null, 11);
    try std.testing.expect(keyboard.manager_name == null);
    try std.testing.expect(keyboard.seat_name == null);
}
