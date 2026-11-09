//! Screenshot observation, scoped revisions, and frame persistence.
const std = @import("std");
const assert = std.debug.assert;
const args = @import("../cli/args.zig");
const geometry = @import("../core/geometry.zig");
const native = @import("../platform/native.zig");
const c = native.c;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const operations = @import("../runtime/operations.zig");
const sessions = @import("../runtime/sessions.zig");
const aura = @import("../input/aura.zig");
const png = @import("png.zig");
const marks = @import("marks.zig");
const eq = @import("../core/text.zig").eq;

pub const Client = struct {
    address: []const u8,
    at: [2]i32,
    size: [2]i32,
    workspace: geometry.Workspace,
    monitor: i64 = -1,
    mapped: bool = true,
    hidden: bool = false,
    floating: bool = false,
    pinned: bool = false,
    fullscreen: i64 = 0,
    xwayland: bool = false,
    pid: i64 = 0,
    class: []const u8 = "",
    title: []const u8 = "",

    /// True when `point` (desktop coordinates) lies inside the window rectangle.
    pub fn contains(self: Client, point: geometry.Point) bool {
        const right = @as(i64, self.at[0]) + self.size[0];
        const bottom = @as(i64, self.at[1]) + self.size[1];
        return point.x >= self.at[0] and point.y >= self.at[1] and
            point.x < right and point.y < bottom;
    }
};
pub const Snapshot = struct {
    monitors: []geometry.Monitor,
    clients: []Client,
    active: []const u8,
    revision: []const u8,
};

pub fn snapshot(runtime: *Runtime, scope: ?[]const u8) !Snapshot {
    return snapshot_for_action(runtime, scope, false);
}

// Do not trust a namespace alone: only our own PID's input-transparent aura
// is excluded during input. Other overlays remain safety dependencies.
fn strip_owned_aura(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    pid: i64,
) !std.json.Value {
    var result = value;
    // Every array and object still to be filtered. Arrays are compacted in
    // place, so the walk needs no recursion however deep the reply nests.
    var pending: std.ArrayList(*std.json.Value) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, &result);

    while (pending.pop()) |current| {
        switch (current.*) {
            .array => |*items| {
                var kept: usize = 0;
                for (items.items) |item| {
                    if (is_owned_aura(item, pid)) continue;
                    items.items[kept] = item;
                    kept += 1;
                }
                items.shrinkRetainingCapacity(kept);
                for (items.items) |*item| try pending.append(allocator, item);
            },
            .object => |*object| {
                var iterator = object.iterator();
                while (iterator.next()) |entry| try pending.append(allocator, entry.value_ptr);
            },
            else => {},
        }
    }
    return result;
}

fn is_owned_aura(item: std.json.Value, pid: i64) bool {
    if (item != .object) return false;
    const owner = item.object.get("pid") orelse return false;
    const namespace = item.object.get("namespace") orelse return false;
    const owned = owner == .integer and owner.integer == pid;
    const is_aura = namespace == .string and eq(namespace.string, aura.namespace);
    return owned and is_aura;
}

pub fn snapshot_for_action(runtime: *Runtime, scope: ?[]const u8, owned_aura: bool) !Snapshot {
    const monitors = try runtime.query_json([]geometry.Monitor, "monitors");
    const clients = try runtime.query_json([]Client, "clients");
    const active = try runtime.active_window();
    var layers = try runtime.query_json(std.json.Value, "layers");
    if (owned_aura) layers = try strip_owned_aura(runtime.allocator, layers, c.getpid());

    var relevant: std.ArrayList(Client) = .empty;
    if (scope) |name| {
        var target: ?geometry.Monitor = null;
        for (monitors) |candidate| {
            if (eq(candidate.name, name)) {
                target = candidate;
                break;
            }
        }
        const monitor = target orelse return error.MonitorNotFound;
        const rect = try monitor.rect();
        // A floating window may cross an output boundary. Keep intersecting
        // clients as well as all clients assigned to the captured output.
        for (clients) |client| {
            const left: f64 = @floatFromInt(client.at[0]);
            const top: f64 = @floatFromInt(client.at[1]);
            const right: f64 = @floatFromInt(@as(i64, client.at[0]) + client.size[0]);
            const bottom: f64 = @floatFromInt(@as(i64, client.at[1]) + client.size[1]);
            const intersects = left < rect.x + rect.width and top < rect.y + rect.height and
                right > rect.x and bottom > rect.y;
            const assigned = client.monitor == monitor.id;
            if (assigned or intersects) try relevant.append(runtime.allocator, client);
        }
        if (layers != .object) return error.InvalidLayerState;
        layers = layers.object.get(name) orelse .null;
    } else {
        try relevant.appendSlice(runtime.allocator, clients);
    }

    const normalized = try runtime.allocator.dupe(geometry.Monitor, monitors);
    for (normalized) |*normalized_monitor| normalized_monitor.focused = false;
    const data = try std.json.Stringify.valueAlloc(runtime.allocator, .{
        .scope = scope,
        .monitors = normalized,
        .clients = relevant.items,
        .active = active,
        .layers = layers,
    }, .{});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});

    return .{
        .monitors = monitors,
        .clients = clients,
        .active = active,
        .revision = try runtime.allocator.dupe(u8, &std.fmt.bytesToHex(digest, .lower)),
    };
}

pub fn monitor_by_name(layout: Snapshot, name: ?[]const u8) !geometry.Monitor {
    for (layout.monitors) |monitor| {
        const matches = if (name) |wanted| eq(wanted, monitor.name) else monitor.focused;
        if (!matches) continue;

        if (monitor.disabled) return error.MonitorUnavailable;
        if (!monitor.dpmsStatus) return error.MonitorUnavailable;
        return monitor;
    }
    return error.MonitorNotFound;
}

fn focused_monitor_name(runtime: *Runtime) ![]const u8 {
    const monitors = try runtime.query_json([]geometry.Monitor, "monitors");
    for (monitors) |monitor| {
        if (monitor.focused) return monitor.name;
    }
    return error.MonitorNotFound;
}

/// Each attempt gets the full observe budget again; the pause lets a slow
/// compositor deliver the next frame instead of failing the same way twice.
const observe_attempt_timeout_ms = 10_000;
const observe_retry_delay_ms = 700;

/// `observe --retry N`: retry transient failures up to N extra times.
pub fn observe_with_retry(runtime: *Runtime, arguments: args.Args) !void {
    std.debug.assert(arguments.retry <= args.observe_retry_max);
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        native.limit_command(observe_attempt_timeout_ms, error.CommandTimeout);
        if (observe(runtime, arguments)) |_| {
            return;
        } else |err| {
            if (attempt >= arguments.retry) return err;
            if (!observe_retryable(err)) return err;
        }
        native.clear_command_limit();
        native.sleep_ms(observe_retry_delay_ms);
        try native.check_cancelled();
    }
}

fn observe_retryable(err: anyerror) bool {
    return switch (err) {
        error.CommandTimeout, error.HelperTimeout, error.StaleObservation => true,
        else => false,
    };
}

pub fn observe(runtime: *Runtime, arguments: args.Args) !void {
    if (arguments.backend == .native) return error.NativeCaptureUnavailable;
    // Opportunistic cleanup under its own lock: never contends with an input
    // action, and another observer already collecting is not an error.
    operations.collect(runtime, arguments, false) catch |err| switch (err) {
        error.ControlBusy => {},
        else => return err,
    };
    try runtime.prepare();
    try runtime.validate_display();
    try runtime.unlocked();
    // Fail fast instead of letting grim wait the whole budget for a frame.
    try sessions.check_nested_window(runtime);

    // Load the comparison frame first: a missing one fails before capturing.
    const previous: ?geometry.Frame = if (arguments.since) |frame_id|
        try load_frame(runtime, frame_id)
    else
        null;
    const started = native.now_ms();
    var frame = try capture(runtime, arguments, try capture_scope(runtime, arguments));
    var marked: ?marks.Marked = null;
    if (arguments.marks) {
        marked = try marks.apply(runtime, frame, frame.window.?);
        frame.marks = marked.?.marks;
        frame.marked_image_path = marked.?.image_path;
    }
    try observe_write_metadata(runtime, frame);
    const comparison: ?Comparison = if (previous) |earlier|
        compare(runtime, earlier, frame)
    else
        null;
    try runtime.emit(.{
        .ok = true,
        .frame = frame,
        .capture_duration_ms = native.now_ms() - started,
        .changed = if (comparison) |result| result.changed else null,
        .diff = if (comparison) |result| result.diff else null,
        .marks = if (marked) |result| result.legend else null,
        .snapshot = if (marked) |result| result.snapshot else null,
    });
}

const Comparison = struct { changed: bool, diff: ?png.Diff };

/// Whether the screen changed since `earlier`. Identical bytes are unchanged;
/// otherwise both images are decoded and compared, and a change no bigger than
/// a text cursor does not count. Images that cannot be compared are changed.
fn compare(runtime: *Runtime, earlier: geometry.Frame, later: geometry.Frame) Comparison {
    if (!same_box(earlier, later)) return .{ .changed = true, .diff = null };
    const same_bytes = earlier.image_sha256.len != 0 and
        eq(earlier.image_sha256, later.image_sha256);
    const unchanged = png.Diff{ .changed_pixels = 0, .box = null, .cursor_like = false };
    if (same_bytes) return .{ .changed = false, .diff = unchanged };
    const unknown = Comparison{ .changed = true, .diff = null };
    const result = pixel_diff(runtime, earlier, later) catch return unknown;
    const difference = result orelse return unknown;
    const changed = difference.changed_pixels > 0 and !difference.cursor_like;
    return .{ .changed = changed, .diff = difference };
}

fn pixel_diff(runtime: *Runtime, earlier: geometry.Frame, later: geometry.Frame) !?png.Diff {
    const limit = 256 * 1024 * 1024;
    const before_bytes = try runtime.read_file(earlier.image_path, limit);
    const after_bytes = try runtime.read_file(later.image_path, limit);
    const before = try png.decode(runtime.allocator, before_bytes);
    const after = try png.decode(runtime.allocator, after_bytes);
    return png.diff(before, after);
}

/// The output an observation captures and, for `--frame`, the frame its
/// region is drawn on. The crop box itself is resolved from the snapshot taken
/// around the capture, so it always matches the captured layout.
const CaptureScope = struct {
    monitor_name: []const u8,
    region_frame: ?geometry.Frame = null,
};

fn capture_scope(runtime: *Runtime, arguments: args.Args) !CaptureScope {
    if (arguments.window) |address| {
        const monitors = try runtime.query_json([]geometry.Monitor, "monitors");
        const clients = try runtime.query_json([]Client, "clients");
        const client = find_client(clients, address) orelse return error.WindowNotFound;
        const monitor = try client_monitor(monitors, client);
        return .{ .monitor_name = monitor.name };
    }
    if (arguments.frame) |frame_id| {
        const frame = try load_frame(runtime, frame_id);
        return .{ .monitor_name = frame.monitor_id, .region_frame = frame };
    }
    return .{ .monitor_name = arguments.monitor orelse try focused_monitor_name(runtime) };
}

fn find_client(clients: []const Client, address: []const u8) ?Client {
    for (clients) |client| {
        if (eq(client.address, address)) return client;
    }
    return null;
}

fn client_monitor(monitors: []const geometry.Monitor, client: Client) !geometry.Monitor {
    for (monitors) |monitor| {
        if (monitor.id == client.monitor) return monitor;
    }
    return error.WindowNotVisible;
}

/// The logical box `--window` or a `--frame` region crops to, inside the
/// output. Null captures the whole output.
fn capture_box(
    runtime: *Runtime,
    arguments: args.Args,
    scope: CaptureScope,
    layout: Snapshot,
    monitor: geometry.Monitor,
) !?geometry.Rect {
    const output = try monitor.rect();
    if (arguments.window) |address| {
        const client = find_client(layout.clients, address) orelse return error.WindowNotFound;
        if (!client.mapped) return error.WindowNotVisible;
        if (client.hidden) return error.WindowNotVisible;
        if (client.monitor != monitor.id) return error.StaleObservation;
        const special = monitor.specialWorkspace.id;
        const on_special = special != 0 and client.workspace.id == special;
        const shown = client.workspace.id == monitor.activeWorkspace.id or on_special;
        if (!shown) return error.WindowNotVisible;

        const window = geometry.Rect{
            .x = @floatFromInt(client.at[0]),
            .y = @floatFromInt(client.at[1]),
            .width = @floatFromInt(client.size[0]),
            .height = @floatFromInt(client.size[1]),
        };
        return window.intersection(output) orelse error.WindowNotVisible;
    }
    if (scope.region_frame) |frame| {
        // The region is drawn on that frame: it must still show this layout.
        try frame.validate(runtime.instance, runtime.display, layout.revision, native.now_ms());
        const box = try frame.box(arguments.x.?, arguments.y.?, arguments.to_x.?, arguments.to_y.?);
        return box.whole_pixels().intersection(output) orelse error.CoordinatesOutOfBounds;
    }
    return null;
}

/// Captures the scope with grim between two equal layout snapshots and
/// returns the frame that maps its pixels back onto the desktop.
fn capture(runtime: *Runtime, arguments: args.Args, scope: CaptureScope) !geometry.Frame {
    const before = try snapshot(runtime, scope.monitor_name);
    const monitor = try monitor_by_name(before, scope.monitor_name);
    const box = try capture_box(runtime, arguments, scope, before, monitor);
    const logical = box orelse try monitor.rect();
    const scale = capture_scale(arguments, logical);

    const frame_id = try runtime.random_token();
    const image_name = try std.fmt.allocPrint(runtime.allocator, "{s}.png", .{frame_id});
    const image_path = try runtime.state_path(image_name);
    errdefer _ = c.unlink(image_path);

    const started = native.now_ms();
    const unix_ms = @as(i64, @intCast(c.time(null))) * 1000;
    try runtime.run_helper(
        try grim_argv(runtime.allocator, monitor.name, box, scale, image_path),
        null,
        false,
    );
    try runtime.unlocked();
    const after = try snapshot(runtime, scope.monitor_name);
    if (!eq(before.revision, after.revision)) return error.StaleObservation;

    const image = try read_image(image_path);
    if (arguments.max_edge) |max_edge| {
        if (@max(image.width, image.height) > max_edge) return error.CaptureExceedsMaxEdge;
    }
    return .{
        .session_id = runtime.session_id,
        .instance = runtime.instance,
        .wayland_display = runtime.display,
        .frame_id = frame_id,
        .captured_at_unix_ms = unix_ms,
        .captured_at_monotonic_ms = started,
        .monitor_id = monitor.name,
        .workspace_id = monitor.activeWorkspace.id,
        .image_path = image_path,
        .image_width = image.width,
        .image_height = image.height,
        .logical = logical,
        .layout_revision = after.revision,
        .capture_scale = scale,
        .window = arguments.window,
        .image_sha256 = try runtime.allocator.dupe(u8, &image.sha256),
    };
}

/// `--scale`, lowered when needed so the longest image side fits `--max-edge`.
fn capture_scale(arguments: args.Args, logical: geometry.Rect) f64 {
    const max_edge = arguments.max_edge orelse return arguments.scale;
    const long_side = @max(logical.width, logical.height);
    assert(long_side > 0);
    // Half a pixel of headroom absorbs grim rounding the scaled size up.
    const fitted = (@as(f64, @floatFromInt(max_edge)) - 0.5) / long_side;
    return @min(arguments.scale, fitted);
}

fn grim_argv(
    allocator: std.mem.Allocator,
    monitor_name: []const u8,
    box: ?geometry.Rect,
    scale: f64,
    image_path: []const u8,
) ![]const []const u8 {
    const scale_text = try std.fmt.allocPrint(allocator, "{d}", .{scale});
    const rect = box orelse return allocator.dupe([]const u8, &.{
        "grim", "-t", "png", "-s", scale_text, "-o", monitor_name, image_path,
    });
    // grim -g takes whole logical pixels in layout coordinates: "X,Y WxH".
    assert(rect.width >= 1);
    assert(rect.height >= 1);
    const geometry_text = try std.fmt.allocPrint(allocator, "{d},{d} {d}x{d}", .{
        @as(i64, @intFromFloat(rect.x)),
        @as(i64, @intFromFloat(rect.y)),
        @as(i64, @intFromFloat(rect.width)),
        @as(i64, @intFromFloat(rect.height)),
    });
    return allocator.dupe([]const u8, &.{
        "grim", "-t", "png", "-s", scale_text, "-g", geometry_text, image_path,
    });
}

const Image = struct { width: u32, height: u32, sha256: [64]u8 };

/// The PNG size from its header and the SHA-256 of the whole file, read in
/// chunks without decoding or holding the image in memory.
fn read_image(image_path: [:0]const u8) !Image {
    const fd = c.open(image_path, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
    if (fd < 0) return error.InvalidScreenshot;
    defer _ = c.close(fd);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var header: [24]u8 = undefined;
    var header_length: usize = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const read_result = c.read(fd, &buffer, buffer.len);
        if (read_result < 0 and native.errno() == c.EINTR) continue;
        if (read_result < 0) return error.InvalidScreenshot;
        if (read_result == 0) break;
        const chunk = buffer[0..@intCast(read_result)];
        const wanted = @min(header.len - header_length, chunk.len);
        @memcpy(header[header_length..][0..wanted], chunk[0..wanted]);
        header_length += wanted;
        hasher.update(chunk);
    }
    if (header_length != header.len) return error.InvalidScreenshot;
    const size = try geometry.png_size(&header);
    return .{
        .width = size.width,
        .height = size.height,
        .sha256 = std.fmt.bytesToHex(hasher.finalResult(), .lower),
    };
}

/// True when two frames show the same desktop box at the same image size.
fn same_box(earlier: geometry.Frame, later: geometry.Frame) bool {
    if (!eq(earlier.monitor_id, later.monitor_id)) return false;
    if (!std.meta.eql(earlier.logical, later.logical)) return false;
    if (earlier.image_width != later.image_width) return false;
    return earlier.image_height == later.image_height;
}

/// `cursor`: the pointer position on the desktop and, with `--frame`, the
/// frame pixel that shows it, so an agent can verify a hover without a capture.
pub fn cursor(runtime: *Runtime, arguments: args.Args) !void {
    const position = try runtime.query_json(geometry.Point, "cursorpos");
    var frame_pixel: ?geometry.Point = null;
    var frame_current: ?bool = null;
    if (arguments.frame) |frame_id| {
        const frame = try load_frame(runtime, frame_id);
        frame_pixel = frame.pixel(position);
        const layout = try snapshot(runtime, frame.monitor_id);
        const now = native.now_ms();
        frame_current = true;
        frame.validate(runtime.instance, runtime.display, layout.revision, now) catch |err| {
            if (err != error.StaleObservation) return err;
            frame_current = false;
        };
    }
    try runtime.emit(.{
        .ok = true,
        .session_id = runtime.session_id,
        .cursor = position,
        .frame_pixel = frame_pixel,
        .frame_current = frame_current,
    });
}

fn observe_write_metadata(runtime: *Runtime, frame: geometry.Frame) !void {
    const metadata_name = try std.fmt.allocPrint(runtime.allocator, "{s}.json", .{frame.frame_id});
    const metadata_path = try runtime.state_path(metadata_name);
    const encoded = try std.json.Stringify.valueAlloc(runtime.allocator, frame, .{});
    try std.Io.Dir.cwd().writeFile(runtime.io, .{
        .sub_path = metadata_path,
        .data = encoded,
        .flags = .{ .exclusive = true },
    });
}

pub fn load_frame(runtime: *Runtime, frame_id: []const u8) !geometry.Frame {
    if (frame_id.len != 32) return error.InvalidFrameId;
    for (frame_id) |character| {
        if (!std.ascii.isHex(character)) return error.InvalidFrameId;
    }

    const metadata_name = try std.fmt.allocPrint(runtime.allocator, "{s}.json", .{frame_id});
    const metadata_path = try runtime.state_path(metadata_name);
    // Marks make metadata grow with the number of operable elements.
    const data = runtime.read_file(metadata_path, 4 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.FrameNotFound,
        else => return err,
    };
    const frame = try runtime.parse_json(geometry.Frame, data);
    if (!eq(frame.frame_id, frame_id)) return error.InvalidFrameId;
    if (!eq(frame.session_id, runtime.session_id)) return error.SessionMismatch;
    return frame;
}

test "pointer snapshot excludes only the current process aura, never arbitrary overlays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const layers =
        \\{"levels":{"3":[
        \\  {"namespace":"hyprhand-aura","pid":42},
        \\  {"namespace":"hyprhand-aura","pid":43},
        \\  {"namespace":"dialog","pid":42},
        \\  {"namespace":"hyprhand-aura"} ]}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, layers, .{});
    const filtered = try strip_owned_aura(allocator, parsed.value, 42);
    const items = filtered.object.get("levels").?.object.get("3").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(i64, 43), items[0].object.get("pid").?.integer);
    try std.testing.expectEqualStrings("dialog", items[1].object.get("namespace").?.string);
}

test "aura filtering reaches arrays nested at any depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const layers =
        \\[[{"namespace":"hyprhand-aura","pid":42}, 1],
        \\ {"deeper":[[{"namespace":"hyprhand-aura","pid":42},
        \\             {"namespace":"hyprhand-aura","pid":7}]]}]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, layers, .{});
    const filtered = try strip_owned_aura(allocator, parsed.value, 42);
    const outer = filtered.array.items;
    try std.testing.expectEqual(@as(usize, 1), outer[0].array.items.len);
    try std.testing.expectEqual(@as(i64, 1), outer[0].array.items[0].integer);
    const deeper = outer[1].object.get("deeper").?.array.items[0].array.items;
    try std.testing.expectEqual(@as(usize, 1), deeper.len);
    try std.testing.expectEqual(@as(i64, 7), deeper[0].object.get("pid").?.integer);
}
