const std = @import("std");
const args = @import("../cli/args.zig");
const geometry = @import("../core/geometry.zig");
const native = @import("../platform/native.zig");
const c = native.c;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const observation = @import("../capture/observation.zig");
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn run(rt: *Runtime, opt: args.Args) !void {
    const condition = opt.value.?;
    if (!eq(condition, "stable") and !eq(condition, "window") and !eq(condition, "focus") and !eq(condition, "workspace")) return error.InvalidWaitCondition;
    if (eq(condition, "focus") and opt.window == null) return error.WindowRequired;
    if (eq(condition, "window") and opt.window == null and opt.class == null) return error.WindowRequired;
    if (eq(condition, "workspace") and opt.workspace_id == null) return error.InvalidWorkspace;
    try rt.prepare();
    try rt.validateDisplay();
    const started = native.nowMs();
    var last: ?[32]u8 = null;
    var stable_since = started;
    const temp = try rt.path(try std.fmt.allocPrint(rt.a, "wait-{s}.png", .{try rt.id()}));
    defer _ = c.unlink(temp);
    while (native.nowMs() - started < opt.timeout_ms) {
        try native.checkCancelled();
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var scratch = rt.*;
        scratch.a = arena.allocator();
        try scratch.unlocked();
        const state = try observation.snapshot(&scratch, opt.monitor);
        var satisfied = false;
        if (eq(condition, "stable")) {
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hash.update(state.revision);
            if (opt.pixels) {
                const monitor = try observation.monitorByName(state, opt.monitor);
                try scratch.run(&.{ "grim", "-o", monitor.name, temp }, null, false);
                hash.update(try scratch.read(temp, 64 * 1024 * 1024));
            }
            const digest = hash.finalResult();
            if (last == null or !std.mem.eql(u8, &last.?, &digest)) stable_since = native.nowMs();
            last = digest;
            satisfied = native.nowMs() - stable_since >= opt.stable_ms;
        } else if (eq(condition, "focus")) {
            satisfied = eq(state.active, opt.window.?);
        } else if (eq(condition, "window")) {
            for (state.clients) |client| {
                if (!client.mapped or client.hidden) continue;
                if (opt.window) |address| if (!eq(client.address, address)) continue;
                if (opt.class) |class| if (!eq(client.class, class)) continue;
                satisfied = true;
                break;
            }
        } else {
            const active = try scratch.json(geometry.Workspace, try scratch.query("activeworkspace"));
            satisfied = active.id == opt.workspace_id.?;
        }
        if (satisfied and native.nowMs() - started < opt.timeout_ms) {
            try rt.emit(.{ .ok = true, .session_id = rt.session_id, .condition = condition, .elapsed_ms = native.nowMs() - started, .pixels = opt.pixels });
            return;
        }
        try rt.pause(50);
    }
    return error.WaitTimeout;
}
