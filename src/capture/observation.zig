//! Screenshot observation, scoped revisions, and frame persistence.
const std = @import("std");
const args = @import("../cli/args.zig");
const geometry = @import("../core/geometry.zig");
const native = @import("../platform/native.zig");
const c = native.c;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const operations = @import("../runtime/operations.zig");
const sessions = @import("../runtime/sessions.zig");
const aura = @import("../input/aura.zig");
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

    const monitor_name = arguments.monitor orelse try focused_monitor_name(runtime);
    const before = try snapshot(runtime, monitor_name);
    const monitor = try monitor_by_name(before, monitor_name);
    const rect = try monitor.rect();
    const frame_id = try runtime.random_token();
    const image_name = try std.fmt.allocPrint(runtime.allocator, "{s}.png", .{frame_id});
    const image_path = try runtime.state_path(image_name);
    errdefer _ = c.unlink(image_path);

    const started = native.now_ms();
    const unix_ms = @as(i64, @intCast(c.time(null))) * 1000;
    const scale = try std.fmt.allocPrint(runtime.allocator, "{d}", .{arguments.scale});
    try runtime.run_helper(
        &.{ "grim", "-t", "png", "-s", scale, "-o", monitor.name, image_path },
        null,
        false,
    );
    try runtime.unlocked();
    const after = try snapshot(runtime, monitor_name);
    if (!eq(before.revision, after.revision)) return error.StaleObservation;

    // Read only the PNG header, without decoding or allocating the image.
    const fd = c.open(image_path, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
    if (fd < 0) return error.InvalidScreenshot;
    defer _ = c.close(fd);
    var header: [24]u8 = undefined;
    if (c.read(fd, &header, header.len) != header.len) return error.InvalidScreenshot;
    const size = try geometry.png_size(&header);

    const frame = geometry.Frame{
        .session_id = runtime.session_id,
        .instance = runtime.instance,
        .wayland_display = runtime.display,
        .frame_id = frame_id,
        .captured_at_unix_ms = unix_ms,
        .captured_at_monotonic_ms = started,
        .monitor_id = monitor.name,
        .workspace_id = monitor.activeWorkspace.id,
        .image_path = image_path,
        .image_width = size.width,
        .image_height = size.height,
        .logical = rect,
        .layout_revision = after.revision,
    };
    try observe_write_metadata(runtime, frame);
    try runtime.emit(.{
        .ok = true,
        .frame = frame,
        .capture_duration_ms = native.now_ms() - started,
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
    const data = runtime.read_file(metadata_path, 16384) catch |err| switch (err) {
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
