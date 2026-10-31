const std = @import("std");
const args = @import("../cli/args.zig");
const geometry = @import("../core/geometry.zig");
const native = @import("../platform/native.zig");
const c = native.c;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const observation = @import("../capture/observation.zig");
const text = @import("../core/text.zig");
const eq = text.eq;

pub fn run(runtime: *Runtime, arguments: args.Args) !void {
    const condition = arguments.value.?;
    const known = text.one_of(condition, &.{ "stable", "window", "focus", "workspace" });
    if (!known) return error.InvalidWaitCondition;
    if (eq(condition, "focus") and arguments.window == null) return error.WindowRequired;
    const window_unspecified = arguments.window == null and arguments.class == null;
    if (eq(condition, "window") and window_unspecified) return error.WindowRequired;
    const workspace_unspecified = arguments.workspace_id == null;
    if (eq(condition, "workspace") and workspace_unspecified) return error.InvalidWorkspace;

    try runtime.prepare();
    try runtime.validate_display();
    const started = native.now_ms();
    var last_digest: ?[32]u8 = null;
    var stable_since = started;
    const token = try runtime.random_token();
    const screenshot_name = try std.fmt.allocPrint(runtime.allocator, "wait-{s}.png", .{token});
    const screenshot_path = try runtime.state_path(screenshot_name);
    defer _ = c.unlink(screenshot_path);

    while (native.now_ms() - started < arguments.timeout_ms) {
        try native.check_cancelled();
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var scratch = runtime.scratch(arena.allocator());
        try scratch.unlocked();
        const state = try observation.snapshot(&scratch, arguments.monitor);

        var satisfied = false;
        if (eq(condition, "stable")) {
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hash.update(state.revision);
            if (arguments.pixels) {
                const monitor = try observation.monitor_by_name(state, arguments.monitor);
                const grim = [_][]const u8{ "grim", "-o", monitor.name, screenshot_path };
                try scratch.run_helper(&grim, null, false);
                hash.update(try scratch.read_file(screenshot_path, 64 * 1024 * 1024));
            }
            const digest = hash.finalResult();
            const changed = last_digest == null or !std.mem.eql(u8, &last_digest.?, &digest);
            if (changed) stable_since = native.now_ms();
            last_digest = digest;
            satisfied = native.now_ms() - stable_since >= arguments.stable_ms;
        } else if (eq(condition, "focus")) {
            satisfied = eq(state.active, arguments.window.?);
        } else if (eq(condition, "window")) {
            satisfied = run_window_visible(state.clients, arguments);
        } else {
            const active = try scratch.query_json(geometry.Workspace, "activeworkspace");
            satisfied = active.id == arguments.workspace_id.?;
        }

        if (satisfied) {
            try runtime.emit(.{
                .ok = true,
                .session_id = runtime.session_id,
                .condition = condition,
                .elapsed_ms = native.now_ms() - started,
                .pixels = arguments.pixels,
            });
            return;
        }
        try runtime.pause(50);
    }
    return error.WaitTimeout;
}

/// True when a mapped, visible client matches every window filter given.
fn run_window_visible(clients: []const observation.Client, arguments: args.Args) bool {
    for (clients) |client| {
        if (!client.mapped) continue;
        if (client.hidden) continue;
        if (arguments.window) |address| if (!eq(client.address, address)) continue;
        if (arguments.class) |class| if (!eq(client.class, class)) continue;
        return true;
    }
    return false;
}
