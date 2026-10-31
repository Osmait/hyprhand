//! The session keyboard during a takeover. The viewer reports every host key
//! as its physical code plus the symbol the host resolved, so the human's own
//! layout, Shift, AltGr and Caps Lock have already applied; dead keys and
//! Compose sequences are resolved here with the host user's Compose table.
//! This keeps a session keymap that gives each physical code its symbol, with
//! real Shift levels, so applications see text and shortcuts as typed. Codes
//! and symbols travel together, so no keymap can arrive out of order.
const std = @import("std");
const native = @import("../platform/native.zig");
const c = native.c;
const keyboard = @import("../input/keyboard.zig");
const protocol = @import("takeover_protocol.zig");

const key_count = protocol.keycode_max + 1;
/// Session modifiers: indices into `keyboard.modifiers` (Shift, Control, Alt,
/// logo). AltGr and lock keys are not forwarded: the host already applied
/// them to each reported symbol.
const modifier_count = 4;
const shift = 0;

/// What one physical key types: Level 1 without Shift, Level 2 with it.
pub const Entry = struct { base: u32, shifted: u32 };

/// The entry that resolves `keysym` at the Shift state the session holds.
/// A shifted symbol gets its unshifted form as Level 1, so applications see
/// Shift consumed exactly as from a real keyboard.
pub fn entry_for(keysym: u32, shifted: bool) Entry {
    if (shifted) {
        const base: u32 = if (keysym == c.XKB_KEY_ISO_Left_Tab)
            c.XKB_KEY_Tab
        else
            c.xkb_keysym_to_lower(keysym);
        return .{ .base = base, .shifted = keysym };
    }
    const upper: u32 = if (keysym == c.XKB_KEY_Tab)
        c.XKB_KEY_ISO_Left_Tab
    else
        c.xkb_keysym_to_upper(keysym);
    return .{ .base = keysym, .shifted = upper };
}

fn modifier_of(keysym: u32) ?u8 {
    return switch (keysym) {
        c.XKB_KEY_Shift_L, c.XKB_KEY_Shift_R => shift,
        c.XKB_KEY_Control_L, c.XKB_KEY_Control_R => 1,
        c.XKB_KEY_Alt_L, c.XKB_KEY_Alt_R, c.XKB_KEY_Meta_L, c.XKB_KEY_Meta_R => 2,
        c.XKB_KEY_Super_L, c.XKB_KEY_Super_R, c.XKB_KEY_Hyper_L, c.XKB_KEY_Hyper_R => 3,
        else => null,
    };
}

/// Level, group and lock keys change how the host resolves later keys. Their
/// effect already arrives in those symbols, so the session never sees them.
fn host_only(keysym: u32) bool {
    return switch (keysym) {
        c.XKB_KEY_ISO_Level3_Shift,
        c.XKB_KEY_ISO_Level5_Shift,
        c.XKB_KEY_Mode_switch,
        c.XKB_KEY_ISO_Next_Group,
        c.XKB_KEY_ISO_Prev_Group,
        c.XKB_KEY_ISO_First_Group,
        c.XKB_KEY_ISO_Last_Group,
        c.XKB_KEY_Caps_Lock,
        c.XKB_KEY_Shift_Lock,
        c.XKB_KEY_Num_Lock,
        c.XKB_KEY_Scroll_Lock,
        => true,
        else => false,
    };
}

/// Codes the session keymap uses for its own modifier keys.
fn reserved(keycode: u16) bool {
    for (keyboard.modifiers[0..modifier_count]) |modifier| {
        if (modifier.key == keycode) return true;
    }
    return false;
}

pub const Keys = struct {
    entries: [key_count]?Entry = @splat(null),
    /// Physical host keys the session holds, symbol and modifier keys alike.
    pressed: std.bit_set.Static(key_count) = .empty,
    /// The session modifier each held host modifier key holds.
    modifier_keys: [key_count]?u8 = @splat(null),
    /// Held host keys per session modifier: left and right Shift share one.
    held: [modifier_count]u8 = @splat(0),
    masks: [modifier_count]u32 = @splat(0),
    uploaded: bool = false,
    depressed_sent: u32 = 0,
    /// Dead keys and Compose sequences, resolved here because the viewer reads
    /// raw keys before any host input method could compose them.
    compose: ?Compose = null,

    /// `sink` provides upload_unguarded, queue_key and queue_modifiers.
    pub fn apply(self: *Keys, sink: anytype, key: protocol.Key) !void {
        if (!key.pressed) return self.release(sink, key.keycode);
        // Host key repeat: the session's client repeats a held key itself.
        if (self.pressed.isSet(key.keycode)) return;
        if (modifier_of(key.keysym)) |modifier| return self.press_modifier(sink, key, modifier);
        if (host_only(key.keysym)) return;
        // A dead key waits for the next one; the composed symbol replaces both.
        const keysym = if (self.compose) |*compose|
            compose.feed(key.keysym) orelse return
        else
            key.keysym;
        if (reserved(key.keycode)) return;

        const entry = entry_for(keysym, self.held[shift] > 0);
        const changed = if (self.entries[key.keycode]) |current|
            !std.meta.eql(current, entry)
        else
            true;
        if (changed or !self.uploaded) {
            self.entries[key.keycode] = entry;
            try self.upload(sink);
        }
        self.sync_modifiers(sink);
        sink.queue_key(key.keycode, true);
        self.pressed.set(key.keycode);
    }

    fn press_modifier(self: *Keys, sink: anytype, key: protocol.Key, modifier: u8) !void {
        if (!self.uploaded) try self.upload(sink);
        self.pressed.set(key.keycode);
        self.modifier_keys[key.keycode] = modifier;
        self.held[modifier] += 1;
        if (self.held[modifier] == 1) sink.queue_key(keyboard.modifiers[modifier].key, true);
        self.sync_modifiers(sink);
    }

    /// Releases follow the press by physical code, whatever the host now
    /// resolves for it.
    fn release(self: *Keys, sink: anytype, keycode: u16) void {
        if (!self.pressed.isSet(keycode)) return;
        self.pressed.unset(keycode);
        const modifier = self.modifier_keys[keycode] orelse {
            sink.queue_key(keycode, false);
            return;
        };
        self.modifier_keys[keycode] = null;
        self.held[modifier] -= 1;
        if (self.held[modifier] == 0) sink.queue_key(keyboard.modifiers[modifier].key, false);
        self.sync_modifiers(sink);
    }

    /// Lifts every key and modifier. Never fails: nothing may stay held.
    pub fn release_all(self: *Keys, sink: anytype) void {
        const held = self.pressed;
        var codes = held.iterator(.{});
        while (codes.next()) |code| self.release(sink, @intCast(code));
        std.debug.assert(self.pressed.count() == 0);
        std.debug.assert(std.mem.allEqual(u8, &self.held, 0));
    }

    fn sync_modifiers(self: *Keys, sink: anytype) void {
        var depressed: u32 = 0;
        for (self.held, self.masks) |count, mask| {
            if (count > 0) depressed |= mask;
        }
        if (depressed == self.depressed_sent) return;
        sink.queue_modifiers(depressed, 0, 0, 0);
        self.depressed_sent = depressed;
    }

    fn upload(self: *Keys, sink: anytype) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var map = try Map.compile(arena.allocator(), &self.entries);
        defer map.deinit();
        for (&self.masks, keyboard.modifiers[0..modifier_count]) |*mask, modifier| {
            mask.* = try map.mask(modifier.name);
        }
        try sink.upload_unguarded(map.text);
        // A new keymap starts with no modifiers; the next key re-sends them.
        self.uploaded = true;
        self.depressed_sent = 0;
    }
};

/// The host user's Compose table (locale, XCOMPOSEFILE, ~/.XCompose), as GTK
/// and other toolkits on the host would apply it.
pub const Compose = struct {
    table: *c.struct_xkb_compose_table,
    state: *c.struct_xkb_compose_state,

    /// The table for `locale`, or null when the system has none: dead keys
    /// then reach the session unchanged.
    pub fn from_locale(locale: [:0]const u8) ?Compose {
        const context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return null;
        defer c.xkb_context_unref(context);
        c.xkb_context_set_log_level(context, c.XKB_LOG_LEVEL_CRITICAL);
        const flags = c.XKB_COMPOSE_COMPILE_NO_FLAGS;
        const table = c.xkb_compose_table_new_from_locale(context, locale, flags) orelse
            return null;
        return from_table(table);
    }

    fn from_buffer(text: []const u8) ?Compose {
        const context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return null;
        defer c.xkb_context_unref(context);
        const table = c.xkb_compose_table_new_from_buffer(
            context,
            text.ptr,
            text.len,
            "C",
            c.XKB_COMPOSE_FORMAT_TEXT_V1,
            c.XKB_COMPOSE_COMPILE_NO_FLAGS,
        ) orelse return null;
        return from_table(table);
    }

    fn from_table(table: *c.struct_xkb_compose_table) ?Compose {
        const state = c.xkb_compose_state_new(table, c.XKB_COMPOSE_STATE_NO_FLAGS) orelse {
            c.xkb_compose_table_unref(table);
            return null;
        };
        return .{ .table = table, .state = state };
    }

    pub fn deinit(self: *Compose) void {
        c.xkb_compose_state_unref(self.state);
        c.xkb_compose_table_unref(self.table);
    }

    /// The symbol to press for `keysym`, or null while a sequence is pending,
    /// was cancelled, or composed more than one symbol.
    fn feed(self: *Compose, keysym: u32) ?u32 {
        if (c.xkb_compose_state_feed(self.state, keysym) != c.XKB_COMPOSE_FEED_ACCEPTED) {
            return keysym;
        }
        switch (c.xkb_compose_state_get_status(self.state)) {
            c.XKB_COMPOSE_COMPOSING => return null,
            c.XKB_COMPOSE_COMPOSED => {
                const composed = c.xkb_compose_state_get_one_sym(self.state);
                c.xkb_compose_state_reset(self.state);
                if (composed == c.XKB_KEY_NoSymbol) return null;
                return composed;
            },
            c.XKB_COMPOSE_CANCELLED => {
                c.xkb_compose_state_reset(self.state);
                return null;
            },
            else => return keysym,
        }
    }
};

/// A compiled session keymap and its serialized text, both owned by XKB.
const Map = struct {
    compiled: *c.struct_xkb_keymap,
    text: [:0]const u8,

    fn compile(allocator: std.mem.Allocator, entries: *const [key_count]?Entry) !Map {
        const source = try map_source(allocator, entries);
        const flags = c.XKB_CONTEXT_NO_DEFAULT_INCLUDES | c.XKB_CONTEXT_NO_ENVIRONMENT_NAMES;
        const context = c.xkb_context_new(flags) orelse return error.InvalidKeymap;
        defer c.xkb_context_unref(context);
        const compiled = c.xkb_keymap_new_from_string(
            context,
            source,
            c.XKB_KEYMAP_FORMAT_TEXT_V1,
            c.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse return error.InvalidKeymap;
        errdefer c.xkb_keymap_unref(compiled);
        const serialized = c.xkb_keymap_get_as_string(compiled, c.XKB_KEYMAP_FORMAT_TEXT_V1) orelse
            return error.InvalidKeymap;
        return .{ .compiled = compiled, .text = std.mem.span(serialized) };
    }

    fn deinit(self: *Map) void {
        c.free(@constCast(self.text.ptr));
        c.xkb_keymap_unref(self.compiled);
    }

    fn mask(self: *const Map, name: [:0]const u8) !u32 {
        const index = c.xkb_keymap_mod_get_index(self.compiled, name);
        // Check before narrowing/shifting, including XKB_MOD_INVALID.
        if (index >= @bitSizeOf(c.xkb_mod_mask_t)) return error.InvalidKeymap;
        return @as(u32, 1) << @intCast(index);
    }
};

/// Self-contained source: no include files, host layout or environment.
/// Symbol keys repeat in the session; modifier keys do not.
fn map_source(allocator: std.mem.Allocator, entries: *const [key_count]?Entry) ![:0]u8 {
    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(allocator, "xkb_keymap { xkb_keycodes { minimum=8; maximum=255; ");
    for (entries, 0..) |entry, code| {
        if (entry != null) try source.print(allocator, "<K{d}>={d};", .{ code, code + 8 });
    }
    for (keyboard.modifiers[0..modifier_count]) |modifier| {
        try source.print(allocator, "<{s}>={d};", .{ modifier.key_name, modifier.key + 8 });
    }
    try source.appendSlice(
        allocator,
        "}; xkb_types { " ++
            "type \"ONE_LEVEL\" { modifiers=None; map[None]=Level1; }; " ++
            "type \"TWO_LEVEL\" { modifiers=Shift; map[None]=Level1; map[Shift]=Level2; }; " ++
            "}; xkb_compatibility {}; xkb_symbols { ",
    );
    for (entries, 0..) |entry, code| {
        const value = entry orelse continue;
        try source.print(
            allocator,
            "key <K{d}> {{ type=\"TWO_LEVEL\", [0x{x},0x{x}] }};",
            .{ code, value.base, value.shifted },
        );
    }
    for (keyboard.modifiers[0..modifier_count]) |modifier| {
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
    return source.toOwnedSliceSentinel(allocator, 0);
}

const FakeKeyboard = struct {
    const Event = union(enum) {
        upload,
        key: struct { code: u32, pressed: bool },
        modifiers: u32,
    };
    events: [32]Event = undefined,
    count: usize = 0,
    /// The last uploaded keymap, compiled, to check what keys resolve to.
    state: ?*c.struct_xkb_state = null,
    keymap: ?*c.struct_xkb_keymap = null,

    /// Keeps the first events for exact comparison and counts all of them.
    fn record(self: *FakeKeyboard, event: Event) void {
        if (self.count < self.events.len) self.events[self.count] = event;
        self.count += 1;
    }
    fn upload_unguarded(self: *FakeKeyboard, text: [:0]const u8) !void {
        self.deinit();
        const context = c.xkb_context_new(c.XKB_CONTEXT_NO_DEFAULT_INCLUDES).?;
        defer c.xkb_context_unref(context);
        self.keymap = c.xkb_keymap_new_from_string(context, text, c.XKB_KEYMAP_FORMAT_TEXT_V1, 0);
        self.state = c.xkb_state_new(self.keymap.?);
        self.record(.upload);
    }
    fn queue_key(self: *FakeKeyboard, code: u32, pressed: bool) void {
        self.record(.{ .key = .{ .code = code, .pressed = pressed } });
    }
    fn queue_modifiers(self: *FakeKeyboard, depressed: u32, _: u32, _: u32, _: u32) void {
        self.record(.{ .modifiers = depressed });
        _ = c.xkb_state_update_mask(self.state, depressed, 0, 0, 0, 0, 0);
    }
    /// What the session resolves for a host code under the current modifiers.
    fn resolves(self: *FakeKeyboard, code: u32) u32 {
        return c.xkb_state_key_get_one_sym(self.state, code + 8);
    }
    fn deinit(self: *FakeKeyboard) void {
        if (self.state) |state| c.xkb_state_unref(state);
        if (self.keymap) |keymap| c.xkb_keymap_unref(keymap);
        self.state = null;
        self.keymap = null;
    }
};

fn host_key(keycode: u16, keysym: u32, pressed: bool) protocol.Key {
    return .{ .keycode = keycode, .keysym = keysym, .pressed = pressed };
}

test "takeover entries keep the reported symbol at the session Shift level" {
    const cases = [_]struct { keysym: u32, shifted: bool, entry: Entry }{
        .{ .keysym = 'a', .shifted = false, .entry = .{ .base = 'a', .shifted = 'A' } },
        .{ .keysym = 'A', .shifted = true, .entry = .{ .base = 'a', .shifted = 'A' } },
        // Caps Lock on the host: uppercase without Shift, lowercase with it.
        .{ .keysym = 'A', .shifted = false, .entry = .{ .base = 'A', .shifted = 'A' } },
        .{ .keysym = 'a', .shifted = true, .entry = .{ .base = 'a', .shifted = 'a' } },
        .{ .keysym = '!', .shifted = true, .entry = .{ .base = '!', .shifted = '!' } },
        .{
            .keysym = c.XKB_KEY_Tab,
            .shifted = false,
            .entry = .{ .base = c.XKB_KEY_Tab, .shifted = c.XKB_KEY_ISO_Left_Tab },
        },
        .{
            .keysym = c.XKB_KEY_ISO_Left_Tab,
            .shifted = true,
            .entry = .{ .base = c.XKB_KEY_Tab, .shifted = c.XKB_KEY_ISO_Left_Tab },
        },
        .{
            .keysym = c.XKB_KEY_ntilde,
            .shifted = false,
            .entry = .{ .base = c.XKB_KEY_ntilde, .shifted = c.XKB_KEY_Ntilde },
        },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.entry, entry_for(case.keysym, case.shifted));
    }
}

test "takeover keys type shifted, non-ASCII and dead-key symbols as reported" {
    var keys = Keys{};
    var fake = FakeKeyboard{};
    defer fake.deinit();

    // Right Shift, then 'A' on the physical A key: the session resolves 'A'.
    try keys.apply(&fake, host_key(54, c.XKB_KEY_Shift_R, true));
    try keys.apply(&fake, host_key(30, 'A', true));
    try std.testing.expectEqual(@as(u32, 'A'), fake.resolves(30));
    // A host repeat sends nothing; the release follows the physical code.
    const before_repeat = fake.count;
    try keys.apply(&fake, host_key(30, 'A', true));
    try std.testing.expectEqual(before_repeat, fake.count);
    try keys.apply(&fake, host_key(54, c.XKB_KEY_Shift_R, false));
    try keys.apply(&fake, host_key(30, 'a', false));
    try std.testing.expectEqual(@as(u32, 'a'), fake.resolves(30));

    // Same key unshifted needs no new keymap; a new symbol does.
    const uploads_before = count_uploads(&fake);
    try keys.apply(&fake, host_key(30, 'a', true));
    try keys.apply(&fake, host_key(30, 'a', false));
    try std.testing.expectEqual(uploads_before, count_uploads(&fake));
    try keys.apply(&fake, host_key(39, c.XKB_KEY_ntilde, true));
    try std.testing.expectEqual(@as(u32, c.XKB_KEY_ntilde), fake.resolves(39));
    try keys.apply(&fake, host_key(39, c.XKB_KEY_ntilde, false));
    try keys.apply(&fake, host_key(26, c.XKB_KEY_dead_acute, true));
    try std.testing.expectEqual(@as(u32, c.XKB_KEY_dead_acute), fake.resolves(26));
    keys.release_all(&fake);
    try std.testing.expectEqual(uploads_before + 2, count_uploads(&fake));
}

fn count_uploads(fake: *const FakeKeyboard) usize {
    var uploads: usize = 0;
    for (fake.events[0..fake.count]) |event| {
        if (event == .upload) uploads += 1;
    }
    return uploads;
}

test "takeover composes dead keys before they reach the session" {
    const table =
        \\<dead_acute> <e> : "é" eacute
        \\<dead_acute> <E> : "É" Eacute
        \\<Multi_key> <n> <asciitilde> : "ñ" ntilde
        \\
    ;
    var keys = Keys{ .compose = Compose.from_buffer(table) orelse return error.SkipZigTest };
    defer keys.compose.?.deinit();
    var fake = FakeKeyboard{};
    defer fake.deinit();

    // The dead key itself is never pressed in the session.
    try keys.apply(&fake, host_key(40, c.XKB_KEY_dead_acute, true));
    try keys.apply(&fake, host_key(40, c.XKB_KEY_dead_acute, false));
    try std.testing.expectEqual(@as(usize, 0), fake.count);
    try keys.apply(&fake, host_key(18, 'e', true));
    try std.testing.expectEqual(@as(u32, c.XKB_KEY_eacute), fake.resolves(18));
    try keys.apply(&fake, host_key(18, 'e', false));

    // Shift inside a sequence does not break it.
    try keys.apply(&fake, host_key(40, c.XKB_KEY_dead_acute, true));
    try keys.apply(&fake, host_key(42, c.XKB_KEY_Shift_L, true));
    try keys.apply(&fake, host_key(18, 'E', true));
    try std.testing.expectEqual(@as(u32, c.XKB_KEY_Eacute), fake.resolves(18));
    keys.release_all(&fake);

    // Compose key sequences, and plain keys outside any sequence.
    try keys.apply(&fake, host_key(100, c.XKB_KEY_Multi_key, true));
    try keys.apply(&fake, host_key(49, 'n', true));
    try keys.apply(&fake, host_key(41, c.XKB_KEY_asciitilde, true));
    try std.testing.expectEqual(@as(u32, c.XKB_KEY_ntilde), fake.resolves(41));
    try keys.apply(&fake, host_key(30, 'a', true));
    try std.testing.expectEqual(@as(u32, 'a'), fake.resolves(30));
    keys.release_all(&fake);
    try std.testing.expectEqual(@as(usize, 0), keys.pressed.count());
}

test "takeover modifiers share one session key and release everything" {
    var keys = Keys{};
    var fake = FakeKeyboard{};
    defer fake.deinit();

    try keys.apply(&fake, host_key(29, c.XKB_KEY_Control_L, true));
    try keys.apply(&fake, host_key(97, c.XKB_KEY_Control_R, true));
    // AltGr and Caps Lock stay on the host: they already shaped the symbols.
    try keys.apply(&fake, host_key(100, c.XKB_KEY_ISO_Level3_Shift, true));
    try keys.apply(&fake, host_key(58, c.XKB_KEY_Caps_Lock, true));
    try keys.apply(&fake, host_key(30, 'a', true));
    const control = keys.masks[1];
    try std.testing.expect(control != 0);
    const expected = [_]FakeKeyboard.Event{
        .upload,
        .{ .key = .{ .code = 29, .pressed = true } },
        .{ .modifiers = control },
        .upload,
        .{ .modifiers = control },
        .{ .key = .{ .code = 30, .pressed = true } },
    };
    try std.testing.expectEqualDeep(expected[0..], fake.events[0..fake.count]);

    // Releasing one Control key keeps the session modifier held.
    try keys.apply(&fake, host_key(29, c.XKB_KEY_Control_L, false));
    try std.testing.expectEqual(@as(usize, expected.len), fake.count);
    keys.release_all(&fake);
    const released = [_]FakeKeyboard.Event{
        .{ .key = .{ .code = 30, .pressed = false } },
        .{ .key = .{ .code = 29, .pressed = false } },
        .{ .modifiers = 0 },
    };
    try std.testing.expectEqualDeep(released[0..], fake.events[expected.len..fake.count]);
    // Unmatched releases and a second release_all send nothing.
    try keys.apply(&fake, host_key(30, 'a', false));
    keys.release_all(&fake);
    try std.testing.expectEqual(@as(usize, expected.len + released.len), fake.count);
}

test "takeover keymaps fit every physical code and skip reserved ones" {
    var keys = Keys{};
    var fake = FakeKeyboard{};
    defer fake.deinit();
    for (0..protocol.keycode_max + 1) |code| {
        const keycode: u16 = @intCast(code);
        try keys.apply(&fake, host_key(keycode, 0x1000400 + @as(u32, keycode), true));
        try keys.apply(&fake, host_key(keycode, 0x1000400 + @as(u32, keycode), false));
    }
    for (keyboard.modifiers[0..modifier_count]) |modifier| {
        try std.testing.expect(keys.entries[modifier.key] == null);
    }
    try std.testing.expectEqual(@as(u32, 0x1000400 + 247), fake.resolves(247));
    try std.testing.expectEqual(@as(usize, 0), keys.pressed.count());
}
