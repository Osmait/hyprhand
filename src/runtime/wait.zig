const std = @import("std");
const args = @import("../cli/args.zig");
const geometry = @import("../core/geometry.zig");
const native = @import("../platform/native.zig");
const c = native.c;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const observation = @import("../capture/observation.zig");
const eq = @import("../core/text.zig").eq;

pub fn run(runtime: *Runtime, arguments: args.Args) !void {
    const condition = arguments.wait_condition.?;
    try run_validate(condition, arguments);

    try runtime.prepare();
    try runtime.validate_display();
    const started_ms = native.now_ms();
    const token = try runtime.random_token();
    const screenshot_name = try std.fmt.allocPrint(runtime.allocator, "wait-{s}.png", .{token});
    const screenshot_path = try runtime.state_path(screenshot_name);
    defer _ = c.unlink(screenshot_path);
    var stability = Stability{ .since_ms = started_ms };

    while (native.now_ms() - started_ms < arguments.timeout_ms) {
        try native.check_cancelled();
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var scratch = runtime.scratch(arena.allocator());
        try scratch.unlocked();
        const state = try observation.snapshot(&scratch, arguments.monitor);

        const satisfied = switch (condition) {
            .stable => try stability.observe(&scratch, state, arguments, screenshot_path),
            .focus => eq(state.active, arguments.window.?),
            .window => run_window_visible(state.clients, arguments),
            .workspace => workspace: {
                const active = try scratch.query_json(geometry.Workspace, "activeworkspace");
                break :workspace active.id == arguments.workspace_id.?;
            },
        };
        if (satisfied) {
            try runtime.emit(.{
                .ok = true,
                .session_id = runtime.session_id,
                .condition = @tagName(condition),
                .elapsed_ms = native.now_ms() - started_ms,
                .pixels = arguments.pixels,
            });
            return;
        }
        try runtime.pause(50);
    }
    return error.WaitTimeout;
}

/// Each condition names what it waits for; reject a wait that could never end.
fn run_validate(condition: args.WaitCondition, arguments: args.Args) !void {
    switch (condition) {
        .stable => {},
        .focus => if (arguments.window == null) return error.WindowRequired,
        .window => {
            const window_unspecified = arguments.window == null and arguments.class == null;
            if (window_unspecified) return error.WindowRequired;
        },
        .workspace => if (arguments.workspace_id == null) return error.InvalidWorkspace,
    }
}

/// How long the observed desktop has stayed unchanged, for `wait stable`.
/// The compositor revision always counts; `--pixels` also hashes a screenshot.
const Stability = struct {
    digest_last: ?[32]u8 = null,
    since_ms: i64,

    fn observe(
        self: *Stability,
        scratch: *Runtime,
        state: observation.Snapshot,
        arguments: args.Args,
        screenshot_path: [:0]const u8,
    ) !bool {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(state.revision);
        if (arguments.pixels) {
            const monitor = try observation.monitor_by_name(state, arguments.monitor);
            const grim = [_][]const u8{ "grim", "-o", monitor.name, screenshot_path };
            try scratch.run_helper(&grim, null, false);
            hash.update(try scratch.read_file(screenshot_path, 64 * 1024 * 1024));
        }
        const digest = hash.finalResult();

        const changed = if (self.digest_last) |last| !std.mem.eql(u8, &last, &digest) else true;
        if (changed) self.since_ms = native.now_ms();
        self.digest_last = digest;
        return native.now_ms() - self.since_ms >= arguments.stable_ms;
    }
};

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
