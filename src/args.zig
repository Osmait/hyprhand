const std = @import("std");
pub const Command = enum { doctor, state, monitors, windows, workspaces, sessions, session, launch, observe, focus, workspace, move, click, doubleclick, drag, scroll, type, key, stop, enable, wait, events, logs, gc, accessibility, _a11y, _cursor_probe };
pub const Args = struct {
    command: Command,
    session: []const u8 = "host",
    explicit_session: bool = false,
    monitor: ?[]const u8 = null,
    window: ?[]const u8 = null,
    frame: ?[]const u8 = null,
    text: ?[]const u8 = null,
    value: ?[]const u8 = null,
    name: ?[]const u8 = null,
    class: ?[]const u8 = null,
    workspace_id: ?i64 = null,
    x: ?f64 = null,
    y: ?f64 = null,
    to_x: ?f64 = null,
    to_y: ?f64 = null,
    dx: i32 = 0,
    dy: i32 = 0,
    scale: f64 = 1,
    button: u32 = 272,
    dry_run: bool = false,
    timeout_ms: u32 = 5000,
    stable_ms: u32 = 300,
    duration_ms: u32 = 500,
    move_duration_ms: ?u32 = null,
    no_aura: bool = false,
    indicator: []const u8 = "none",
    limit: u32 = 100,
    depth: u32 = 5,
    older_than_ms: u32 = 300_000,
    pixels: bool = false,
    nested: bool = false,
    headless_bridge: ?[]const u8 = null,
    lua: bool = false,
    backend: []const u8 = "auto",
    program: []const []const u8 = &.{},
    pub fn pointer(self: Args) bool {
        return switch (self.command) {
            .move, .click, .doubleclick, .drag, .scroll => true,
            else => false,
        };
    }
    pub fn mutates(self: Args) bool {
        return self.pointer() or switch (self.command) {
            .focus, .workspace, .type, .key, .launch => true,
            else => false,
        };
    }
};
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32 or !std.ascii.isAlphabetic(name[0])) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}
fn allowed(a: Args, option: []const u8) bool {
    const cmd = a.command;
    if (eq(option, "--session")) return true;
    if (eq(option, "--indicator")) return cmd == .enable;
    if (eq(option, "--headless-bridge")) return cmd == .session;
    if (eq(option, "--dry-run")) return a.mutates() or cmd == .gc;
    if (eq(option, "--monitor")) return cmd == .observe or cmd == .wait;
    if (eq(option, "--scale")) return cmd == .observe;
    if (eq(option, "--window")) return cmd == .type or cmd == .key or cmd == .wait or (cmd == .accessibility or cmd == ._a11y);
    if (eq(option, "--class") or eq(option, "--workspace")) return cmd == .wait;
    if (eq(option, "--frame") or eq(option, "--x") or eq(option, "--y")) return a.pointer();
    if (eq(option, "--move-duration-ms")) return a.pointer();
    if (eq(option, "--no-aura")) return a.pointer();
    if (eq(option, "--to-x") or eq(option, "--to-y")) return cmd == .drag;
    if (eq(option, "--duration-ms")) return cmd == .drag or cmd == .scroll;
    if (eq(option, "--text")) return cmd == .type;
    if (eq(option, "--button")) return cmd == .click or cmd == .doubleclick or cmd == .drag;
    if (eq(option, "--dx") or eq(option, "--dy")) return cmd == .scroll;
    if (eq(option, "--timeout-ms")) return cmd == .wait or cmd == .events or (cmd == .accessibility or cmd == ._a11y);
    if (eq(option, "--stable-ms") or eq(option, "--pixels")) return cmd == .wait;
    if (eq(option, "--limit")) return cmd == .logs or cmd == .events or (cmd == .accessibility or cmd == ._a11y);
    if (eq(option, "--depth")) return (cmd == .accessibility or cmd == ._a11y);
    if (eq(option, "--older-than-ms")) return cmd == .gc;
    if (eq(option, "--nested") or eq(option, "--lua")) return cmd == .session;
    if (eq(option, "--backend")) return cmd == .observe or cmd == .type or cmd == .key;
    return false;
}
pub fn parse(argv: []const []const u8) !Args {
    if (argv.len == 0) return error.MissingCommand;
    var a = Args{ .command = std.meta.stringToEnum(Command, argv[0]) orelse return error.UnknownCommand };
    var seen: [32][]const u8 = undefined;
    var seen_len: usize = 0;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (eq(arg, "--") and a.command == .launch) {
            a.program = argv[i + 1 ..];
            break;
        }
        if (!std.mem.startsWith(u8, arg, "--")) {
            switch (a.command) {
                .focus, .workspace, .key, .wait, .session => {},
                else => return error.UnexpectedArgument,
            }
            if (a.value == null) a.value = arg else if (a.command == .session and a.name == null) a.name = arg else return error.UnexpectedArgument;
            continue;
        }
        if (!allowed(a, arg)) return error.UnknownOption;
        for (seen[0..seen_len]) |previous| if (eq(previous, arg)) return error.DuplicateOption;
        if (seen_len == seen.len) return error.TooManyOptions;
        seen[seen_len] = arg;
        seen_len += 1;
        if (eq(arg, "--no-aura")) {
            a.no_aura = true;
            continue;
        }
        if (eq(arg, "--dry-run")) {
            a.dry_run = true;
            continue;
        }
        if (eq(arg, "--pixels")) {
            a.pixels = true;
            continue;
        }
        if (eq(arg, "--nested")) {
            a.nested = true;
            continue;
        }
        if (eq(arg, "--lua")) {
            a.lua = true;
            continue;
        }
        i += 1;
        if (i >= argv.len) return error.MissingOptionValue;
        const v = argv[i];
        if (eq(arg, "--headless-bridge")) {
            a.headless_bridge = v;
            continue;
        }
        if (eq(arg, "--indicator")) {
            a.indicator = v;
            continue;
        }
        if (eq(arg, "--move-duration-ms")) {
            a.move_duration_ms = try std.fmt.parseInt(u32, v, 10);
            continue;
        }
        if (eq(arg, "--session")) {
            a.session = v;
            a.explicit_session = true;
        } else if (eq(arg, "--monitor")) a.monitor = v else if (eq(arg, "--window")) a.window = v else if (eq(arg, "--class")) a.class = v else if (eq(arg, "--workspace")) a.workspace_id = try std.fmt.parseInt(i64, v, 10) else if (eq(arg, "--frame")) a.frame = v else if (eq(arg, "--text")) a.text = v else if (eq(arg, "--backend")) a.backend = v else if (eq(arg, "--x")) a.x = try std.fmt.parseFloat(f64, v) else if (eq(arg, "--y")) a.y = try std.fmt.parseFloat(f64, v) else if (eq(arg, "--to-x")) a.to_x = try std.fmt.parseFloat(f64, v) else if (eq(arg, "--to-y")) a.to_y = try std.fmt.parseFloat(f64, v) else if (eq(arg, "--scale")) a.scale = try std.fmt.parseFloat(f64, v) else if (eq(arg, "--dx")) a.dx = try std.fmt.parseInt(i32, v, 10) else if (eq(arg, "--dy")) a.dy = try std.fmt.parseInt(i32, v, 10) else if (eq(arg, "--timeout-ms")) a.timeout_ms = try std.fmt.parseInt(u32, v, 10) else if (eq(arg, "--stable-ms")) a.stable_ms = try std.fmt.parseInt(u32, v, 10) else if (eq(arg, "--duration-ms")) a.duration_ms = try std.fmt.parseInt(u32, v, 10) else if (eq(arg, "--limit")) a.limit = try std.fmt.parseInt(u32, v, 10) else if (eq(arg, "--depth")) a.depth = try std.fmt.parseInt(u32, v, 10) else if (eq(arg, "--older-than-ms")) a.older_than_ms = try std.fmt.parseInt(u32, v, 10) else if (eq(arg, "--button")) a.button = if (eq(v, "left")) 272 else if (eq(v, "right")) 273 else if (eq(v, "middle")) 274 else return error.InvalidButton;
    }
    if (!validName(a.session)) return error.InvalidSessionName;
    if (!eq(a.indicator, "none") and !eq(a.indicator, "outline")) return error.InvalidIndicator;
    if (a.headless_bridge) |path| {
        if (!std.fs.path.isAbsolute(path) or std.mem.indexOfAny(u8, path, " :\t\r\n\x00") != null or a.nested) return error.InvalidHeadlessBridge;
    }
    if (a.mutates() and !a.explicit_session) return error.SessionRequired;
    if (!std.math.isFinite(a.scale) or a.scale < 0.1 or a.scale > 2) return error.InvalidScale;
    if (a.dx < -100 or a.dx > 100 or a.dy < -100 or a.dy > 100) return error.InvalidScroll;
    if (a.timeout_ms < 1 or a.timeout_ms > 300_000 or a.stable_ms < 50 or a.stable_ms > 30_000 or (a.duration_ms < 50 and !(a.command == .scroll and a.duration_ms == 0)) or a.duration_ms > 10_000) return error.InvalidDuration;
    if (a.limit < 1 or a.limit > 10_000 or a.depth < 1 or a.depth > 32) return error.InvalidLimit;
    if (a.move_duration_ms) |ms| {
        if (ms != 0 and (ms < 50 or ms > 10_000)) return error.InvalidDuration;
    }
    if (!eq(a.backend, "auto") and !eq(a.backend, "native") and !eq(a.backend, "helper")) return error.InvalidBackend;
    if (a.pointer() and (a.frame == null or a.x == null or a.y == null)) return error.FrameCoordinatesRequired;
    if (a.command == .drag and (a.to_x == null or a.to_y == null)) return error.DragDestinationRequired;
    if ((a.command == .type or a.command == .key) and a.window == null) return error.WindowRequired;
    switch (a.command) {
        .focus, .workspace, .key, .wait => if (a.value == null) return error.MissingArgument,
        .type => if (a.text == null) return error.MissingText,
        .launch => if (a.program.len == 0) return error.MissingProgram,
        .session => {
            if (a.value == null or a.name == null) return error.MissingArgument;
            if (!validName(a.name.?) or eq(a.name.?, "host")) return error.InvalidSessionName;
            if (!eq(a.value.?, "create") and !eq(a.value.?, "inspect") and !eq(a.value.?, "destroy")) return error.UnknownSessionCommand;
            if ((a.nested or a.lua or a.headless_bridge != null) and !eq(a.value.?, "create")) return error.UnknownOption;
        },
        else => {},
    }
    return a;
}
test "strict options, sessions, and action arguments" {
    try std.testing.expectError(error.SessionRequired, parse(&.{ "click", "--frame", "a", "--x", "2", "--y", "3" }));
    try std.testing.expectError(error.FrameCoordinatesRequired, parse(&.{ "click", "--session", "host" }));
    try std.testing.expectError(error.InvalidSessionName, parse(&.{ "state", "--session", "../host" }));
    try std.testing.expectError(error.DuplicateOption, parse(&.{ "state", "--session", "host", "--session", "host" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "observe", "--windwo", "x" }));
    try std.testing.expectError(error.InvalidScale, parse(&.{ "observe", "--scale", "nan" }));
    try std.testing.expectError(error.DragDestinationRequired, parse(&.{ "drag", "--session", "host", "--frame", "a", "--x", "1", "--y", "2" }));
    const a = try parse(&.{ "type", "--session", "host", "--window", "0x1", "--text", "--help" });
    try std.testing.expectEqualStrings("--help", a.text.?);
    const launch = try parse(&.{ "launch", "--session", "agent", "--", "brave", "--incognito" });
    try std.testing.expectEqual(@as(usize, 2), launch.program.len);
}
