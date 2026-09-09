const std = @import("std");
const text = @import("../core/text.zig");
const eq = text.eq;
const buttons = @import("../input/buttons.zig");

pub const Command = enum { doctor, state, monitors, windows, workspaces, sessions, session, launch, observe, preview, focus, workspace, move, click, doubleclick, drag, scroll, type, key, stop, enable, wait, events, logs, gc, accessibility, _a11y, _cursor_probe, _preview_frame, _preview_stream, _preview_stop };

pub const Args = struct {
    command: Command,
    session: []const u8 = "host",
    explicit_session: bool = false,
    fps: u32 = 5,
    expected_instance: ?[]const u8 = null,
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
    button: u32 = buttons.left,
    dry_run: bool = false,
    timeout_ms: u32 = 5000,
    stable_ms: u32 = 300,
    duration_ms: u32 = 500,
    scroll_mode: []const u8 = "auto",
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
    /// The viewer launcher and the workers it spawns.
    pub fn isPreview(self: Args) bool {
        return self.command == .preview or self.isPreviewWorker();
    }
    pub fn isPreviewWorker(self: Args) bool {
        return switch (self.command) {
            ._preview_frame, ._preview_stop, ._preview_stream => true,
            else => false,
        };
    }
    pub fn isAccessibility(self: Args) bool {
        return self.command == .accessibility or self.command == ._a11y;
    }
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32 or !std.ascii.isAlphabetic(name[0])) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}

// Which commands accept an option. Predicates read the command parsed so far.
const Allowed = *const fn (Args) bool;

fn always(_: Args) bool {
    return true;
}
fn only(comptime commands: []const Command) Allowed {
    return struct {
        fn check(a: Args) bool {
            inline for (commands) |command| if (a.command == command) return true;
            return false;
        }
    }.check;
}
fn pointerOnly(a: Args) bool {
    return a.pointer();
}
fn dryRunnable(a: Args) bool {
    return a.mutates() or a.command == .gc;
}
fn windowed(a: Args) bool {
    return a.pointer() or a.isAccessibility() or only(&.{ .type, .key, .wait })(a);
}
fn timed(a: Args) bool {
    return a.isAccessibility() or only(&.{ .wait, .events })(a);
}
fn limited(a: Args) bool {
    return a.isAccessibility() or only(&.{ .logs, .events })(a);
}
fn accessibilityOnly(a: Args) bool {
    return a.isAccessibility();
}

/// One CLI option. The value is parsed according to the Args field type:
/// bool fields are flags, integers and floats are parsed, strings are kept.
const Option = struct {
    name: []const u8,
    field: []const u8,
    allowed: Allowed,
    kind: enum { auto, button } = .auto,
};

const options = [_]Option{
    .{ .name = "--session", .field = "session", .allowed = always },
    .{ .name = "--indicator", .field = "indicator", .allowed = only(&.{.enable}) },
    .{ .name = "--headless-bridge", .field = "headless_bridge", .allowed = only(&.{.session}) },
    .{ .name = "--dry-run", .field = "dry_run", .allowed = dryRunnable },
    .{ .name = "--monitor", .field = "monitor", .allowed = only(&.{ .observe, .wait, .preview, ._preview_frame, ._preview_stream }) },
    .{ .name = "--fps", .field = "fps", .allowed = only(&.{.preview}) },
    .{ .name = "--expected-instance", .field = "expected_instance", .allowed = only(&.{ ._preview_frame, ._preview_stop, ._preview_stream }) },
    .{ .name = "--scale", .field = "scale", .allowed = only(&.{.observe}) },
    .{ .name = "--window", .field = "window", .allowed = windowed },
    .{ .name = "--scroll-mode", .field = "scroll_mode", .allowed = only(&.{.scroll}) },
    .{ .name = "--class", .field = "class", .allowed = only(&.{.wait}) },
    .{ .name = "--workspace", .field = "workspace_id", .allowed = only(&.{.wait}) },
    .{ .name = "--frame", .field = "frame", .allowed = pointerOnly },
    .{ .name = "--x", .field = "x", .allowed = pointerOnly },
    .{ .name = "--y", .field = "y", .allowed = pointerOnly },
    .{ .name = "--move-duration-ms", .field = "move_duration_ms", .allowed = pointerOnly },
    .{ .name = "--no-aura", .field = "no_aura", .allowed = pointerOnly },
    .{ .name = "--to-x", .field = "to_x", .allowed = only(&.{.drag}) },
    .{ .name = "--to-y", .field = "to_y", .allowed = only(&.{.drag}) },
    .{ .name = "--duration-ms", .field = "duration_ms", .allowed = only(&.{ .drag, .scroll }) },
    .{ .name = "--text", .field = "text", .allowed = only(&.{.type}) },
    .{ .name = "--button", .field = "button", .allowed = only(&.{ .click, .doubleclick, .drag }), .kind = .button },
    .{ .name = "--dx", .field = "dx", .allowed = only(&.{.scroll}) },
    .{ .name = "--dy", .field = "dy", .allowed = only(&.{.scroll}) },
    .{ .name = "--timeout-ms", .field = "timeout_ms", .allowed = timed },
    .{ .name = "--stable-ms", .field = "stable_ms", .allowed = only(&.{.wait}) },
    .{ .name = "--pixels", .field = "pixels", .allowed = only(&.{.wait}) },
    .{ .name = "--limit", .field = "limit", .allowed = limited },
    .{ .name = "--depth", .field = "depth", .allowed = accessibilityOnly },
    .{ .name = "--older-than-ms", .field = "older_than_ms", .allowed = only(&.{.gc}) },
    .{ .name = "--nested", .field = "nested", .allowed = only(&.{.session}) },
    .{ .name = "--lua", .field = "lua", .allowed = only(&.{.session}) },
    .{ .name = "--backend", .field = "backend", .allowed = only(&.{ .observe, .type, .key }) },
};

fn Unwrapped(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |info| info.child,
        else => T,
    };
}

/// Stores the option value into its Args field, consuming argv[index + 1]
/// for options that take a value.
fn assign(a: *Args, comptime option: Option, argv: []const []const u8, index: *usize) !void {
    const Value = Unwrapped(@TypeOf(@field(a.*, option.field)));
    if (Value == bool) {
        @field(a, option.field) = true;
        return;
    }
    index.* += 1;
    if (index.* >= argv.len) return error.MissingOptionValue;
    const raw = argv[index.*];
    if (option.kind == .button) {
        @field(a, option.field) = buttons.fromName(raw) orelse return error.InvalidButton;
        return;
    }
    @field(a, option.field) = switch (@typeInfo(Value)) {
        .int => try std.fmt.parseInt(Value, raw, 10),
        .float => try std.fmt.parseFloat(Value, raw),
        .pointer => raw,
        else => @compileError("unsupported option field type for " ++ option.name),
    };
}

fn positional(a: *Args, arg: []const u8) !void {
    switch (a.command) {
        .focus, .workspace, .key, .wait, .session => {},
        else => return error.UnexpectedArgument,
    }
    if (a.value == null) {
        a.value = arg;
    } else if (a.command == .session and a.name == null) {
        a.name = arg;
    } else return error.UnexpectedArgument;
}

pub fn parse(argv: []const []const u8) !Args {
    if (argv.len == 0) return error.MissingCommand;
    var a = Args{ .command = std.meta.stringToEnum(Command, argv[0]) orelse return error.UnknownCommand };
    var seen: [options.len][]const u8 = undefined;
    var seen_len: usize = 0;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (eq(arg, "--") and a.command == .launch) {
            a.program = argv[i + 1 ..];
            break;
        }
        if (!std.mem.startsWith(u8, arg, "--")) {
            try positional(&a, arg);
            continue;
        }
        var matched = false;
        inline for (options) |option| {
            if (eq(arg, option.name)) {
                if (!option.allowed(a)) return error.UnknownOption;
                for (seen[0..seen_len]) |previous| if (eq(previous, arg)) return error.DuplicateOption;
                seen[seen_len] = arg;
                seen_len += 1;
                try assign(&a, option, argv, &i);
                matched = true;
            }
        }
        if (!matched) return error.UnknownOption;
        if (eq(arg, "--session")) a.explicit_session = true;
    }
    try validateValues(a);
    try validateShape(a);
    return a;
}

/// Ranges and enumerations, independent of the command.
fn validateValues(a: Args) !void {
    if (!validName(a.session)) return error.InvalidSessionName;
    if (!text.oneOf(a.scroll_mode, &.{ "auto", "wheel", "continuous" })) return error.InvalidScrollMode;
    if (!text.oneOf(a.indicator, &.{ "none", "outline" })) return error.InvalidIndicator;
    if (!text.oneOf(a.backend, &.{ "auto", "native", "helper" })) return error.InvalidBackend;
    if (a.headless_bridge) |path| {
        if (!std.fs.path.isAbsolute(path) or std.mem.indexOfAny(u8, path, " :\t\r\n\x00") != null or a.nested) return error.InvalidHeadlessBridge;
    }
    if (a.fps < 1 or a.fps > 15) return error.InvalidPreviewFps;
    if (!std.math.isFinite(a.scale) or a.scale < 0.1 or a.scale > 2) return error.InvalidScale;
    if (a.dx < -100 or a.dx > 100 or a.dy < -100 or a.dy > 100) return error.InvalidScroll;
    if (a.timeout_ms < 1 or a.timeout_ms > 300_000) return error.InvalidDuration;
    if (a.stable_ms < 50 or a.stable_ms > 30_000) return error.InvalidDuration;
    // Scroll may be instantaneous; every other paced action needs at least 50 ms.
    const instant_scroll = a.command == .scroll and a.duration_ms == 0;
    if ((a.duration_ms < 50 and !instant_scroll) or a.duration_ms > 10_000) return error.InvalidDuration;
    if (a.move_duration_ms) |ms| {
        if (ms != 0 and (ms < 50 or ms > 10_000)) return error.InvalidDuration;
    }
    if (a.limit < 1 or a.limit > 10_000 or a.depth < 1 or a.depth > 32) return error.InvalidLimit;
}

/// Required arguments and option combinations for the chosen command.
fn validateShape(a: Args) !void {
    if (a.mutates() and !a.explicit_session) return error.SessionRequired;
    if (a.isPreview()) {
        if (!a.explicit_session) return error.SessionRequired;
        if (eq(a.session, "host")) return error.PreviewManagedSessionRequired;
        const identity = a.expected_instance orelse "";
        if (a.isPreviewWorker() and identity.len == 0) return error.PreviewIdentityRequired;
        if ((a.command == ._preview_frame or a.command == ._preview_stream) and a.monitor == null) return error.MonitorRequired;
    }
    if (a.pointer() and (a.frame == null or a.x == null or a.y == null)) return error.FrameCoordinatesRequired;
    if (a.command == .drag and (a.to_x == null or a.to_y == null)) return error.DragDestinationRequired;
    if ((a.command == .type or a.command == .key) and a.window == null) return error.WindowRequired;
    switch (a.command) {
        .focus, .workspace, .key, .wait => if (a.value == null) return error.MissingArgument,
        .type => if (a.text == null) return error.MissingText,
        .launch => if (a.program.len == 0) return error.MissingProgram,
        .session => {
            const verb = a.value orelse return error.MissingArgument;
            const name = a.name orelse return error.MissingArgument;
            if (!validName(name) or eq(name, "host")) return error.InvalidSessionName;
            if (!text.oneOf(verb, &.{ "create", "inspect", "destroy" })) return error.UnknownSessionCommand;
            if ((a.nested or a.lua or a.headless_bridge != null) and !eq(verb, "create")) return error.UnknownOption;
        },
        else => {},
    }
}

test "strict options, sessions, and action arguments" {
    try std.testing.expectError(error.SessionRequired, parse(&.{ "click", "--frame", "a", "--x", "2", "--y", "3" }));
    try std.testing.expectError(error.FrameCoordinatesRequired, parse(&.{ "click", "--session", "host" }));
    try std.testing.expectError(error.InvalidSessionName, parse(&.{ "state", "--session", "../host" }));
    try std.testing.expectError(error.DuplicateOption, parse(&.{ "state", "--session", "host", "--session", "host" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "observe", "--windwo", "x" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "state", "--scroll-mode", "wheel" }));
    try std.testing.expectError(error.MissingOptionValue, parse(&.{ "observe", "--monitor" }));
    try std.testing.expectError(error.InvalidButton, parse(&.{ "click", "--session", "host", "--frame", "a", "--x", "1", "--y", "2", "--button", "side" }));
    try std.testing.expectError(error.InvalidScale, parse(&.{ "observe", "--scale", "nan" }));
    try std.testing.expectError(error.DragDestinationRequired, parse(&.{ "drag", "--session", "host", "--frame", "a", "--x", "1", "--y", "2" }));
    const a = try parse(&.{ "type", "--session", "host", "--window", "0x1", "--text", "--help" });
    try std.testing.expectEqualStrings("--help", a.text.?);
    const click = try parse(&.{ "click", "--session", "host", "--frame", "a", "--x", "1.5", "--y", "2", "--button", "right", "--no-aura" });
    try std.testing.expectEqual(buttons.right, click.button);
    try std.testing.expectEqual(@as(?f64, 1.5), click.x);
    try std.testing.expect(click.no_aura and click.explicit_session);
    const launch = try parse(&.{ "launch", "--session", "agent", "--", "brave", "--incognito" });
    try std.testing.expectEqual(@as(usize, 2), launch.program.len);
}

test "preview is explicit, managed, bounded, and workers pin identity" {
    try std.testing.expectError(error.SessionRequired, parse(&.{"preview"}));
    try std.testing.expectError(error.PreviewManagedSessionRequired, parse(&.{ "preview", "--session", "host" }));
    try std.testing.expectError(error.InvalidPreviewFps, parse(&.{ "preview", "--session", "agent", "--fps", "16" }));
    try std.testing.expectError(error.PreviewIdentityRequired, parse(&.{ "_preview_stop", "--session", "agent" }));
    try std.testing.expectError(error.MonitorRequired, parse(&.{ "_preview_frame", "--session", "agent", "--expected-instance", "one" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "preview", "--session", "agent", "--expected-instance", "one" }));
    const a = try parse(&.{ "preview", "--session", "agent", "--fps", "10", "--monitor", "HEADLESS-1" });
    try std.testing.expectEqual(@as(u32, 10), a.fps);
    try std.testing.expect(!a.mutates());
}
