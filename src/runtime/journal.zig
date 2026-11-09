//! Journals: a replayable record of input commands. While a journal is active
//! in a session, every input command (also inside `sequence`) appends one step
//! that names its target by what stays true across runs: the window's class
//! and title, the element's role and name, and points relative to the window.
//! Frames and refs expire; `replay` resolves these again on the live desktop.
//!
//! Text typed into a password field is never stored: only its length and
//! SHA-256, and the step is marked secret, so replay stops there.
const std = @import("std");
const args = @import("../cli/args.zig");
const eq = @import("../core/text.zig").eq;
const Runtime = @import("runtime.zig").Runtime;
const delivery = @import("delivery.zig");
const native = @import("../platform/native.zig");
const geometry = @import("../core/geometry.zig");
const observation = @import("../capture/observation.zig");
const marks = @import("../capture/marks.zig");
const refs = @import("../accessibility/refs.zig");
const tree = @import("../accessibility/tree.zig");
const probe = @import("../accessibility/probe.zig");

pub const WindowRef = struct { class: []const u8, title: []const u8 };
pub const Element = struct { role: []const u8, name: []const u8 };

/// One recorded input command.
pub const Step = struct {
    seq: u32,
    unix_ms: i64,
    command: args.Command,
    ok: bool,
    error_code: ?[]const u8 = null,
    delivery: delivery.Delivery,
    window: ?WindowRef = null,
    /// The target window's logical size, for replays by relative point.
    window_size: ?[2]i32 = null,
    element: ?Element = null,
    /// Pointer target and drag destination, relative to the window.
    point: ?[2]i32 = null,
    to_point: ?[2]i32 = null,
    verb: ?args.ActVerb = null,
    chord: ?[]const u8 = null,
    key_repeat: u32 = 1,
    text: ?[]const u8 = null,
    text_sha256: ?[]const u8 = null,
    text_length: ?usize = null,
    secret: bool = false,
    backend: args.Backend = .auto,
    button: u32 = 0,
    click_count: u32 = 1,
    mods: ?[]const u8 = null,
    dx: i32 = 0,
    dy: i32 = 0,
    scroll_mode: args.ScrollMode = .auto,
    duration_ms: u32 = 500,
    workspace: ?[]const u8 = null,
    program: []const []const u8 = &.{},
};

/// What is learned about the target before the command runs.
pub const Context = struct {
    step: Step,
};

fn path_for(runtime: *Runtime, name: []const u8) ![:0]const u8 {
    if (!args.valid_name(name)) return error.InvalidJournalName;
    const file = try std.fmt.allocPrint(runtime.allocator, "journal-{s}.jsonl", .{name});
    return runtime.state_path(file);
}

/// The name of the active journal, or null.
pub fn active(runtime: *Runtime) !?[]const u8 {
    const pointer = try runtime.state_path("journal-active");
    const text = runtime.read_file(pointer, 64) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const name = std.mem.trim(u8, text, " \n");
    if (!args.valid_name(name)) return null;
    return name;
}

pub fn start(runtime: *Runtime, name: []const u8) !void {
    try runtime.prepare();
    if (try active(runtime)) |current| {
        if (!eq(current, name)) return error.JournalActive;
    }
    const path = try path_for(runtime, name);
    std.Io.Dir.cwd().writeFile(runtime.io, .{
        .sub_path = path,
        .data = "",
        .flags = .{ .exclusive = true },
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.JournalExists,
        else => return err,
    };
    const pointer = try runtime.state_path("journal-active");
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = pointer, .data = name });
}

pub fn stop(runtime: *Runtime) !?[]const u8 {
    const name = try active(runtime) orelse return null;
    _ = native.c.unlink(try runtime.state_path("journal-active"));
    return name;
}

pub fn load(runtime: *Runtime, name: []const u8) ![]Step {
    const data = runtime.read_file(try path_for(runtime, name), 64 * 1024 * 1024) catch |err|
        switch (err) {
            error.FileNotFound => return error.JournalNotFound,
            else => return err,
        };
    var steps: std.ArrayList(Step) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try steps.append(runtime.allocator, try runtime.parse_json(Step, line));
    }
    return steps.toOwnedSlice(runtime.allocator);
}

fn recordable(command: args.Command) bool {
    return switch (command) {
        .act, .click, .doubleclick, .move, .drag, .scroll, .type, .key, .focus => true,
        .workspace, .launch => true,
        else => false,
    };
}

/// Learns the command's target before it runs, when a journal is active.
/// Failing to learn it never stops the command: the step is simply not
/// recorded.
pub fn before(runtime: *Runtime, arguments: args.Args) !?Context {
    if (arguments.dry_run) return null;
    if (!recordable(arguments.command)) return null;
    if (try active(runtime) == null) return null;
    var step = Step{
        .seq = 0,
        .unix_ms = @as(i64, @intCast(native.c.time(null))) * 1000,
        .command = arguments.command,
        .ok = false,
        .delivery = .not_delivered,
        .verb = arguments.act_verb,
        .chord = arguments.key_chord,
        .key_repeat = arguments.key_repeat,
        .backend = arguments.backend,
        .button = arguments.button,
        .click_count = arguments.click_count,
        .mods = arguments.mods,
        .dx = arguments.dx,
        .dy = arguments.dy,
        .scroll_mode = arguments.scroll_mode,
        .duration_ms = arguments.duration_ms,
        .workspace = arguments.workspace_target,
        .program = arguments.program,
    };
    try learn_target(runtime, arguments, &step);
    try learn_text(runtime, arguments, &step);
    return .{ .step = step };
}

fn learn_target(runtime: *Runtime, arguments: args.Args, step: *Step) !void {
    switch (arguments.command) {
        .act => {
            const ref = try refs.Ref.parse(arguments.ref.?);
            const snapshot = try tree.load_snapshot(runtime, ref);
            const entry = snapshot.entry(ref.index) orelse return error.StaleRef;
            try learn_window(runtime, snapshot.window, step);
            step.element = .{
                .role = entry.identity.role,
                .name = entry.identity.name orelse "",
            };
        },
        .click, .doubleclick, .move, .drag, .scroll => try learn_pointer(runtime, arguments, step),
        .type, .key => try learn_window(runtime, arguments.window.?, step),
        .focus => try learn_window(runtime, arguments.focus_window.?, step),
        else => {},
    }
}

fn learn_window(runtime: *Runtime, address: []const u8, step: *Step) !void {
    const client = try tree.find_client(runtime, address);
    step.window = .{ .class = client.class, .title = client.title };
    step.window_size = client.size;
}

/// The window under the pointer, the point relative to it, and the element
/// there: the mark's, or what the accessibility tree reports at that point.
fn learn_pointer(runtime: *Runtime, arguments: args.Args, step: *Step) !void {
    const frame = try observation.load_frame(runtime, arguments.frame.?);
    const aim = if (arguments.mark) |index|
        try marks.point_of(frame, index)
    else
        [2]f64{ arguments.x.?, arguments.y.? };
    const point = try frame.point(aim[0], aim[1]);
    const clients = try runtime.query_json([]observation.Client, "clients");
    const active_window = try runtime.active_window();
    var chosen: ?observation.Client = null;
    for (clients) |client| {
        if (!client.contains(point)) continue;
        if (chosen == null or eq(client.address, active_window)) chosen = client;
    }
    const client = chosen orelse return;
    step.window = .{ .class = client.class, .title = client.title };
    step.window_size = client.size;
    step.point = .{ point.x - client.at[0], point.y - client.at[1] };
    if (arguments.command == .drag) {
        const destination = try frame.point(arguments.to_x.?, arguments.to_y.?);
        step.to_point = .{ destination.x - client.at[0], destination.y - client.at[1] };
    }
    if (arguments.command == .scroll or arguments.command == .drag) return;
    const answer = try probe.probe(runtime, client.address, .{ point.x, point.y });
    const role = answer.role orelse return;
    const name = answer.name orelse return;
    if (name.len == 0) return;
    step.element = .{ .role = role, .name = name };
}

/// Text is kept for replay, except what goes into a password field.
fn learn_text(runtime: *Runtime, arguments: args.Args, step: *Step) !void {
    const sets_value = arguments.command == .act and arguments.act_verb.? == .@"set-value";
    const typed = if (arguments.command == .type or sets_value) arguments.text else null;
    const text = typed orelse return;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    step.text_sha256 = try runtime.allocator.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
    step.text_length = text.len;
    const window = arguments.window orelse {
        step.text = text;
        return;
    };
    const focused = try probe.probe(runtime, window, null);
    const role = focused.role orelse "";
    step.secret = eq(role, "password text");
    if (!step.secret) step.text = text;
}

/// Appends the step with the command's outcome.
pub fn append(runtime: *Runtime, context: Context, failure: ?anyerror) !void {
    const name = try active(runtime) orelse return;
    var step = context.step;
    step.ok = failure == null;
    step.error_code = if (failure) |err| @errorName(err) else null;
    step.delivery = delivery.get();
    const path = try path_for(runtime, name);
    const existing = runtime.read_file(path, 64 * 1024 * 1024) catch "";
    step.seq = @intCast(std.mem.count(u8, existing, "\n") + 1);
    const line = try std.json.Stringify.valueAlloc(runtime.allocator, step, .{});
    const flags = native.c.O_WRONLY | native.c.O_APPEND | native.c.O_CLOEXEC | native.c.O_NOFOLLOW;
    const fd = native.c.open(path, flags);
    if (fd < 0) return error.JournalWriteFailed;
    defer _ = native.c.close(fd);
    const record = try std.fmt.allocPrint(runtime.allocator, "{s}\n", .{line});
    if (native.c.write(fd, record.ptr, record.len) != record.len) return error.JournalWriteFailed;
}
