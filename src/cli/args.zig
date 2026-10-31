const std = @import("std");
const text = @import("../core/text.zig");
const eq = text.eq;
const buttons = @import("../input/buttons.zig");

pub const Command = enum {
    doctor,
    state,
    monitors,
    windows,
    workspaces,
    sessions,
    session,
    launch,
    observe,
    preview,
    focus,
    workspace,
    move,
    click,
    doubleclick,
    drag,
    scroll,
    type,
    key,
    stop,
    enable,
    wait,
    events,
    logs,
    gc,
    accessibility,
    _a11y,
    _cursor_probe,
    _preview_frame,
    _preview_stream,
    _preview_stop,
};

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
    pub fn is_preview(self: Args) bool {
        return self.command == .preview or self.is_preview_worker();
    }

    pub fn is_preview_worker(self: Args) bool {
        return switch (self.command) {
            ._preview_frame, ._preview_stop, ._preview_stream => true,
            else => false,
        };
    }

    pub fn is_accessibility(self: Args) bool {
        return self.command == .accessibility or self.command == ._a11y;
    }
};

pub fn valid_name(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name.len > 32) return false;
    if (!std.ascii.isAlphabetic(name[0])) return false;
    for (name) |character| {
        const valid_character = std.ascii.isAlphanumeric(character) or
            character == '-' or character == '_';
        if (!valid_character) return false;
    }
    return true;
}

// Which commands accept an option. Predicates read the command parsed so far.
const Allowed = *const fn (Args) bool;

fn always(_: Args) bool {
    return true;
}

fn only(comptime commands: []const Command) Allowed {
    return struct {
        fn check(arguments: Args) bool {
            inline for (commands) |command| if (arguments.command == command) return true;
            return false;
        }
    }.check;
}

fn pointer_only(arguments: Args) bool {
    return arguments.pointer();
}

fn dry_runnable(arguments: Args) bool {
    return arguments.mutates() or arguments.command == .gc;
}

fn windowed(arguments: Args) bool {
    return arguments.pointer() or
        arguments.is_accessibility() or
        only(&.{ .type, .key, .wait })(arguments);
}

fn timed(arguments: Args) bool {
    return arguments.is_accessibility() or only(&.{ .wait, .events })(arguments);
}

fn limited(arguments: Args) bool {
    return arguments.is_accessibility() or only(&.{ .logs, .events })(arguments);
}

fn accessibility_only(arguments: Args) bool {
    return arguments.is_accessibility();
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
    .{ .name = "--dry-run", .field = "dry_run", .allowed = dry_runnable },
    .{
        .name = "--monitor",
        .field = "monitor",
        .allowed = only(&.{ .observe, .wait, .preview, ._preview_frame, ._preview_stream }),
    },
    .{ .name = "--fps", .field = "fps", .allowed = only(&.{.preview}) },
    .{
        .name = "--expected-instance",
        .field = "expected_instance",
        .allowed = only(&.{ ._preview_frame, ._preview_stop, ._preview_stream }),
    },
    .{ .name = "--scale", .field = "scale", .allowed = only(&.{.observe}) },
    .{ .name = "--window", .field = "window", .allowed = windowed },
    .{ .name = "--scroll-mode", .field = "scroll_mode", .allowed = only(&.{.scroll}) },
    .{ .name = "--class", .field = "class", .allowed = only(&.{.wait}) },
    .{ .name = "--workspace", .field = "workspace_id", .allowed = only(&.{.wait}) },
    .{ .name = "--frame", .field = "frame", .allowed = pointer_only },
    .{ .name = "--x", .field = "x", .allowed = pointer_only },
    .{ .name = "--y", .field = "y", .allowed = pointer_only },
    .{ .name = "--move-duration-ms", .field = "move_duration_ms", .allowed = pointer_only },
    .{ .name = "--no-aura", .field = "no_aura", .allowed = pointer_only },
    .{ .name = "--to-x", .field = "to_x", .allowed = only(&.{.drag}) },
    .{ .name = "--to-y", .field = "to_y", .allowed = only(&.{.drag}) },
    .{ .name = "--duration-ms", .field = "duration_ms", .allowed = only(&.{ .drag, .scroll }) },
    .{ .name = "--text", .field = "text", .allowed = only(&.{.type}) },
    .{
        .name = "--button",
        .field = "button",
        .allowed = only(&.{ .click, .doubleclick, .drag }),
        .kind = .button,
    },
    .{ .name = "--dx", .field = "dx", .allowed = only(&.{.scroll}) },
    .{ .name = "--dy", .field = "dy", .allowed = only(&.{.scroll}) },
    .{ .name = "--timeout-ms", .field = "timeout_ms", .allowed = timed },
    .{ .name = "--stable-ms", .field = "stable_ms", .allowed = only(&.{.wait}) },
    .{ .name = "--pixels", .field = "pixels", .allowed = only(&.{.wait}) },
    .{ .name = "--limit", .field = "limit", .allowed = limited },
    .{ .name = "--depth", .field = "depth", .allowed = accessibility_only },
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
fn assign(
    arguments: *Args,
    comptime option: Option,
    argv: []const []const u8,
    index: *usize,
) !void {
    const Value = Unwrapped(@TypeOf(@field(arguments.*, option.field)));
    if (Value == bool) {
        @field(arguments, option.field) = true;
        return;
    }

    index.* += 1;
    if (index.* >= argv.len) return error.MissingOptionValue;
    const raw = argv[index.*];
    if (option.kind == .button) {
        @field(arguments, option.field) = buttons.from_name(raw) orelse
            return error.InvalidButton;
        return;
    }
    @field(arguments, option.field) = switch (@typeInfo(Value)) {
        .int => try std.fmt.parseInt(Value, raw, 10),
        .float => try std.fmt.parseFloat(Value, raw),
        .pointer => raw,
        else => @compileError("unsupported option field type for " ++ option.name),
    };
}

fn positional(arguments: *Args, argument: []const u8) !void {
    switch (arguments.command) {
        .focus, .workspace, .key, .wait, .session => {},
        else => return error.UnexpectedArgument,
    }

    if (arguments.value == null) {
        arguments.value = argument;
    } else if (arguments.command == .session and arguments.name == null) {
        arguments.name = argument;
    } else {
        return error.UnexpectedArgument;
    }
}

pub fn parse(argv: []const []const u8) !Args {
    if (argv.len == 0) return error.MissingCommand;
    const command = std.meta.stringToEnum(Command, argv[0]) orelse return error.UnknownCommand;

    var arguments = Args{ .command = command };
    var seen: [options.len][]const u8 = undefined;
    var seen_count: usize = 0;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const argument = argv[i];
        if (eq(argument, "--") and arguments.command == .launch) {
            arguments.program = argv[i + 1 ..];
            break;
        }
        if (!std.mem.startsWith(u8, argument, "--")) {
            try positional(&arguments, argument);
            continue;
        }

        var matched = false;
        inline for (options) |option| {
            if (eq(argument, option.name)) {
                if (!option.allowed(arguments)) return error.UnknownOption;
                for (seen[0..seen_count]) |previous| {
                    if (eq(previous, argument)) return error.DuplicateOption;
                }
                seen[seen_count] = argument;
                seen_count += 1;
                try assign(&arguments, option, argv, &i);
                matched = true;
            }
        }
        if (!matched) return error.UnknownOption;
        if (eq(argument, "--session")) arguments.explicit_session = true;
    }

    try validate_values(arguments);
    try validate_shape(arguments);
    return arguments;
}

/// Ranges and enumerations, independent of the command.
fn validate_values(arguments: Args) !void {
    if (!valid_name(arguments.session)) return error.InvalidSessionName;
    if (!text.one_of(arguments.scroll_mode, &.{ "auto", "wheel", "continuous" })) {
        return error.InvalidScrollMode;
    }
    if (!text.one_of(arguments.indicator, &.{ "none", "outline" })) return error.InvalidIndicator;
    if (!text.one_of(arguments.backend, &.{ "auto", "native", "helper" })) {
        return error.InvalidBackend;
    }
    if (arguments.headless_bridge) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidHeadlessBridge;
        if (std.mem.indexOfAny(u8, path, " :\t\r\n\x00") != null) {
            return error.InvalidHeadlessBridge;
        }
        if (arguments.nested) return error.InvalidHeadlessBridge;
    }

    if (arguments.fps < 1) return error.InvalidPreviewFps;
    if (arguments.fps > 15) return error.InvalidPreviewFps;
    if (!std.math.isFinite(arguments.scale)) return error.InvalidScale;
    if (arguments.scale < 0.1) return error.InvalidScale;
    if (arguments.scale > 2) return error.InvalidScale;
    if (arguments.dx < -100) return error.InvalidScroll;
    if (arguments.dx > 100) return error.InvalidScroll;
    if (arguments.dy < -100) return error.InvalidScroll;
    if (arguments.dy > 100) return error.InvalidScroll;

    if (arguments.timeout_ms < 1) return error.InvalidDuration;
    if (arguments.timeout_ms > 300_000) return error.InvalidDuration;
    if (arguments.stable_ms < 50) return error.InvalidDuration;
    if (arguments.stable_ms > 30_000) return error.InvalidDuration;
    // Scroll may be instantaneous; every other paced action needs at least 50 ms.
    const instant_scroll = arguments.command == .scroll and arguments.duration_ms == 0;
    if (arguments.duration_ms < 50 and !instant_scroll) return error.InvalidDuration;
    if (arguments.duration_ms > 10_000) return error.InvalidDuration;
    if (arguments.move_duration_ms) |move_duration_ms| {
        const instant_move = move_duration_ms == 0;
        if (move_duration_ms < 50 and !instant_move) return error.InvalidDuration;
        if (move_duration_ms > 10_000) return error.InvalidDuration;
    }

    if (arguments.limit < 1) return error.InvalidLimit;
    if (arguments.limit > 10_000) return error.InvalidLimit;
    if (arguments.depth < 1) return error.InvalidLimit;
    if (arguments.depth > 32) return error.InvalidLimit;
}

/// Required arguments and option combinations for the chosen command.
fn validate_shape(arguments: Args) !void {
    if (arguments.mutates() and !arguments.explicit_session) return error.SessionRequired;
    if (arguments.is_preview()) {
        if (!arguments.explicit_session) return error.SessionRequired;
        if (eq(arguments.session, "host")) return error.PreviewManagedSessionRequired;
        const identity = arguments.expected_instance orelse "";
        if (arguments.is_preview_worker() and identity.len == 0) {
            return error.PreviewIdentityRequired;
        }
        const captures_monitor = arguments.command == ._preview_frame or
            arguments.command == ._preview_stream;
        if (captures_monitor and arguments.monitor == null) return error.MonitorRequired;
    }
    if (arguments.pointer()) {
        if (arguments.frame == null) return error.FrameCoordinatesRequired;
        if (arguments.x == null) return error.FrameCoordinatesRequired;
        if (arguments.y == null) return error.FrameCoordinatesRequired;
    }
    if (arguments.command == .drag) {
        if (arguments.to_x == null) return error.DragDestinationRequired;
        if (arguments.to_y == null) return error.DragDestinationRequired;
    }
    const requires_window = arguments.command == .type or arguments.command == .key;
    if (requires_window and arguments.window == null) return error.WindowRequired;

    switch (arguments.command) {
        .focus, .workspace, .key, .wait => {
            if (arguments.value == null) return error.MissingArgument;
        },
        .type => if (arguments.text == null) return error.MissingText,
        .launch => if (arguments.program.len == 0) return error.MissingProgram,
        .session => {
            const verb = arguments.value orelse return error.MissingArgument;
            const name = arguments.name orelse return error.MissingArgument;
            if (!valid_name(name)) return error.InvalidSessionName;
            if (eq(name, "host")) return error.InvalidSessionName;
            if (!text.one_of(verb, &.{ "create", "inspect", "destroy" })) {
                return error.UnknownSessionCommand;
            }
            const create_options = arguments.nested or
                arguments.lua or
                arguments.headless_bridge != null;
            if (create_options and !eq(verb, "create")) return error.UnknownOption;
        },
        else => {},
    }
}

test "strict options, sessions, and action arguments" {
    try std.testing.expectError(
        error.SessionRequired,
        parse(&.{ "click", "--frame", "a", "--x", "2", "--y", "3" }),
    );
    try std.testing.expectError(
        error.FrameCoordinatesRequired,
        parse(&.{ "click", "--session", "host" }),
    );
    try std.testing.expectError(
        error.InvalidSessionName,
        parse(&.{ "state", "--session", "../host" }),
    );
    try std.testing.expectError(
        error.DuplicateOption,
        parse(&.{ "state", "--session", "host", "--session", "host" }),
    );
    try std.testing.expectError(error.UnknownOption, parse(&.{ "observe", "--windwo", "x" }));
    try std.testing.expectError(
        error.UnknownOption,
        parse(&.{ "state", "--scroll-mode", "wheel" }),
    );
    try std.testing.expectError(error.MissingOptionValue, parse(&.{ "observe", "--monitor" }));
    try std.testing.expectError(error.InvalidButton, parse(&.{
        "click",
        "--session",
        "host",
        "--frame",
        "a",
        "--x",
        "1",
        "--y",
        "2",
        "--button",
        "side",
    }));
    try std.testing.expectError(error.InvalidScale, parse(&.{ "observe", "--scale", "nan" }));
    try std.testing.expectError(
        error.DragDestinationRequired,
        parse(&.{ "drag", "--session", "host", "--frame", "a", "--x", "1", "--y", "2" }),
    );

    const typed = try parse(&.{
        "type",
        "--session",
        "host",
        "--window",
        "0x1",
        "--text",
        "--help",
    });
    try std.testing.expectEqualStrings("--help", typed.text.?);

    const click = try parse(&.{
        "click",
        "--session",
        "host",
        "--frame",
        "a",
        "--x",
        "1.5",
        "--y",
        "2",
        "--button",
        "right",
        "--no-aura",
    });
    try std.testing.expectEqual(buttons.right, click.button);
    try std.testing.expectEqual(@as(?f64, 1.5), click.x);
    try std.testing.expect(click.no_aura and click.explicit_session);

    const launch = try parse(&.{ "launch", "--session", "agent", "--", "brave", "--incognito" });
    try std.testing.expectEqual(@as(usize, 2), launch.program.len);
}

test "preview is explicit, managed, bounded, and workers pin identity" {
    try std.testing.expectError(error.SessionRequired, parse(&.{"preview"}));
    try std.testing.expectError(
        error.PreviewManagedSessionRequired,
        parse(&.{ "preview", "--session", "host" }),
    );
    try std.testing.expectError(
        error.InvalidPreviewFps,
        parse(&.{ "preview", "--session", "agent", "--fps", "16" }),
    );
    try std.testing.expectError(
        error.PreviewIdentityRequired,
        parse(&.{ "_preview_stop", "--session", "agent" }),
    );
    try std.testing.expectError(
        error.MonitorRequired,
        parse(&.{ "_preview_frame", "--session", "agent", "--expected-instance", "one" }),
    );
    try std.testing.expectError(
        error.UnknownOption,
        parse(&.{ "preview", "--session", "agent", "--expected-instance", "one" }),
    );

    const preview = try parse(&.{
        "preview",
        "--session",
        "agent",
        "--fps",
        "10",
        "--monitor",
        "HEADLESS-1",
    });
    try std.testing.expectEqual(@as(u32, 10), preview.fps);
    try std.testing.expect(!preview.mutates());
}
