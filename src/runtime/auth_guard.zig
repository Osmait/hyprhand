//! Authentication prompts belong to the human. Polkit agents, keyring and
//! wallet prompts, pinentry, ssh-askpass and Hyprland's own permission dialogs
//! ask for secrets or consent the agent must never provide, so input is refused
//! while one is focused, under the pointer, targeted, or drawn by the shell.
const std = @import("std");

/// Lowercase substrings of window classes that identify such prompts.
const class_patterns = [_][]const u8{
    "polkit",         "pinentry",             "askpass", "gcr-prompter",
    "kwallet",        "hyprland-dialog",      "kdesu",   "gksu",
    "keyring-prompt", "authentication-agent",
};

/// Lowercase substrings of layer-shell namespaces that identify prompts a
/// shell draws itself (polkit agents built into Quickshell, AGS or similar).
const layer_patterns = [_][]const u8{ "polkit", "pinentry", "keyring", "auth" };

fn contains_any(value: []const u8, comptime patterns: []const []const u8) bool {
    var lower_buffer: [256]u8 = undefined;
    const length = @min(value.len, lower_buffer.len);
    const lower = std.ascii.lowerString(lower_buffer[0..length], value[0..length]);
    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, lower, pattern) != null) return true;
    }
    return false;
}

pub fn prompt_class(class: []const u8) bool {
    return contains_any(class, &class_patterns);
}

pub fn prompt_layer(namespace: []const u8) bool {
    return contains_any(namespace, &layer_patterns);
}

/// The namespace of the first prompt layer anywhere in a `layers` reply, or
/// null. The reply nests outputs, levels and arrays; walk it without recursion.
pub fn find_prompt_layer(allocator: std.mem.Allocator, layers: std.json.Value) !?[]const u8 {
    var pending: std.ArrayList(std.json.Value) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, layers);
    while (pending.pop()) |current| {
        switch (current) {
            .array => |items| try pending.appendSlice(allocator, items.items),
            .object => |object| {
                if (object.get("namespace")) |namespace| {
                    const is_prompt = namespace == .string and prompt_layer(namespace.string);
                    if (is_prompt) return namespace.string;
                }
                var iterator = object.iterator();
                while (iterator.next()) |entry| try pending.append(allocator, entry.value_ptr.*);
            },
            else => {},
        }
    }
    return null;
}

test "prompt classes and layers are recognised, ordinary apps are not" {
    const prompts = [_][]const u8{
        "hyprpolkitagent",
        "polkit-gnome-authentication-agent-1",
        "org.kde.polkit-kde-authentication-agent-1",
        "gcr-prompter",
        "pinentry-qt",
        "org.kde.kwalletd6",
        "hyprland-dialog",
        "ssh-askpass",
    };
    for (prompts) |class| try std.testing.expect(prompt_class(class));
    const ordinary = [_][]const u8{ "brave-browser", "kitty", "org.gnome.Nautilus", "firefox" };
    for (ordinary) |class| try std.testing.expect(!prompt_class(class));

    try std.testing.expect(prompt_layer("quickshell:polkit"));
    try std.testing.expect(!prompt_layer("hyprhand-aura"));
    try std.testing.expect(!prompt_layer("waybar"));
}

test "a prompt layer is found at any depth of a layers reply" {
    const text =
        \\{"DP-1":{"levels":{"0":[{"namespace":"wallpaper"}],
        \\ "3":[{"namespace":"waybar"},{"namespace":"quickshell:polkit-agent"}]}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();
    const found = try find_prompt_layer(std.testing.allocator, parsed.value);
    try std.testing.expectEqualStrings("quickshell:polkit-agent", found.?);

    const calm = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"DP-1\":{\"levels\":{\"2\":[{\"namespace\":\"waybar\"}]}}}",
        .{},
    );
    defer calm.deinit();
    const none = try find_prompt_layer(std.testing.allocator, calm.value);
    try std.testing.expectEqual(@as(?[]const u8, null), none);
}
