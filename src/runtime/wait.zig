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
    if (!text.one_of(condition, &.{ "stable", "window", "focus", "workspace" })) return error.InvalidWaitCondition;
    if (eq(condition, "focus") and arguments.window == null) return error.WindowRequired;
    if (eq(condition, "window") and arguments.window == null and arguments.class == null) return error.WindowRequired;
    if (eq(condition, "workspace") and arguments.workspace_id == null) return error.InvalidWorkspace;
    try runtime.prepare();
    try runtime.validate_display();
    const started = native.now_ms();
    var last: ?[32]u8 = null;
    var stable_since = started;
    const temp = try runtime.state_path(try std.fmt.allocPrint(runtime.allocator, "wait-{s}.png", .{try runtime.random_token()}));
    defer _ = c.unlink(temp);
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
                try scratch.run_helper(&.{ "grim", "-o", monitor.name, temp }, null, false);
                hash.update(try scratch.read_file(temp, 64 * 1024 * 1024));
            }
            const digest = hash.finalResult();
            if (last == null or !std.mem.eql(u8, &last.?, &digest)) stable_since = native.now_ms();
            last = digest;
            satisfied = native.now_ms() - stable_since >= arguments.stable_ms;
        } else if (eq(condition, "focus")) {
            satisfied = eq(state.active, arguments.window.?);
        } else if (eq(condition, "window")) {
            for (state.clients) |client| {
                if (!client.mapped or client.hidden) continue;
                if (arguments.window) |address| if (!eq(client.address, address)) continue;
                if (arguments.class) |class| if (!eq(client.class, class)) continue;
                satisfied = true;
                break;
            }
        } else {
            const active = try scratch.query_json(geometry.Workspace, "activeworkspace");
            satisfied = active.id == arguments.workspace_id.?;
        }
        if (satisfied) {
            try runtime.emit(.{ .ok = true, .session_id = runtime.session_id, .condition = condition, .elapsed_ms = native.now_ms() - started, .pixels = arguments.pixels });
            return;
        }
        try runtime.pause(50);
    }
    return error.WaitTimeout;
}
