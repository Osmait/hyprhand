const std = @import("std");
const native = @import("native.zig");
const c = native.c;
const Runtime = @import("runtime.zig").Runtime;
const Args = @import("args.zig").Args;

// No argv, text, titles, or application content in the audit trail.
pub fn log(rt: *Runtime, action: []const u8, status: []const u8) !void {
    try rt.prepare();
    const lock_fd = c.open(try rt.path("audit.lock"), c.O_CREAT | c.O_RDWR | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
    if (lock_fd < 0) return error.LogFailed;
    defer _ = c.close(lock_fd);
    if (c.flock(lock_fd, c.LOCK_EX | c.LOCK_NB) < 0) return error.LogBusy;
    const path = try rt.path("actions.jsonl");
    var st: c.struct_stat = undefined;
    if (c.lstat(path, &st) == 0) {
        if ((st.st_mode & c.S_IFMT) != c.S_IFREG or st.st_uid != c.getuid()) return error.UnsafeLog;
        if (st.st_size > 1024 * 1024 and c.rename(path, try rt.path("actions.previous.jsonl")) < 0) return error.LogFailed;
    }
    const fd = c.open(path, c.O_WRONLY | c.O_APPEND | c.O_CREAT | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
    if (fd < 0) return error.LogFailed;
    defer _ = c.close(fd);
    const json = try std.json.Stringify.valueAlloc(rt.a, .{ .unix_ms = c.time(null) * 1000, .session_id = rt.session_id, .action = action, .status = status }, .{});
    const line = try std.fmt.allocPrint(rt.a, "{s}\n", .{json});
    if (c.write(fd, line.ptr, line.len) != line.len) return error.LogFailed;
}

pub fn logs(rt: *Runtime, opt: Args) !void {
    try rt.prepare();
    const data = rt.read(try rt.path("actions.jsonl"), 2 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    var entries: std.ArrayList(std.json.Value) = .empty;
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| try entries.append(rt.a, try rt.json(std.json.Value, line));
    const start = entries.items.len - @min(entries.items.len, opt.limit);
    try rt.emit(.{ .ok = true, .session_id = rt.session_id, .entries = entries.items[start..] });
}

pub fn frameName(name: []const u8) bool {
    if (name.len != 36 and name.len != 37) return false;
    if (!std.mem.eql(u8, name[32..], ".png") and !std.mem.eql(u8, name[32..], ".json")) return false;
    for (name[0..32]) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

pub fn collect(rt: *Runtime, opt: Args, emit: bool) !void {
    const lock_fd = try rt.lock();
    defer _ = c.close(lock_fd);
    const dir = c.opendir(try rt.a.dupeZ(u8, rt.directory)) orelse return error.StateDirectoryFailed;
    defer _ = c.closedir(dir);
    var count: usize = 0;
    while (c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (!frameName(name)) continue;
        const path = try rt.path(name);
        var st: c.struct_stat = undefined;
        if (c.lstat(path, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG or st.st_uid != c.getuid()) continue;
        const age = c.time(null) * 1000 - (st.st_mtim.tv_sec * 1000 + @divTrunc(st.st_mtim.tv_nsec, 1_000_000));
        // Never collect a usable frame, even if the requested threshold is zero.
        if (age <= @max(31_000, opt.older_than_ms)) continue;
        if (!opt.dry_run and c.unlink(path) < 0) return error.CleanupFailed;
        count += 1;
    }
    if (emit) try rt.emit(.{ .ok = true, .session_id = rt.session_id, .dry_run = opt.dry_run, .files = count });
}

pub fn events(rt: *Runtime, opt: Args) !void {
    try rt.validateDisplay();
    const path = try std.fmt.allocPrint(rt.a, "{s}/.socket2.sock", .{std.fs.path.dirname(rt.socket).?});
    const fd = try @import("ipc.zig").connect(path);
    defer _ = c.close(fd);
    var pending: std.ArrayList(u8) = .empty;
    const deadline = native.nowMs() + opt.timeout_ms;
    var count: usize = 0;
    while (native.nowMs() < deadline and count < opt.limit) {
        try native.checkCancelled();
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        const ready = c.poll(&pfd, 1, @intCast(@max(0, @min(50, deadline - native.nowMs()))));
        if (ready < 0) {
            if (c.__errno_location().* == c.EINTR) continue;
            return error.EventReadFailed;
        }
        if (ready == 0) continue;
        var buffer: [4096]u8 = undefined;
        const n = c.read(fd, &buffer, buffer.len);
        if (n <= 0) return error.EventStreamClosed;
        try pending.appendSlice(rt.a, buffer[0..@intCast(n)]);
        if (pending.items.len > 65536) return error.EventTooLarge;
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |end| {
            const line = pending.items[0..end];
            const separator = std.mem.indexOf(u8, line, ">>") orelse return error.InvalidEvent;
            try rt.emit(.{ .ok = true, .session_id = rt.session_id, .event = line[0..separator], .data = line[separator + 2 ..] });
            count += 1;
            const remaining = pending.items.len - end - 1;
            std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[end + 1 ..]);
            pending.shrinkRetainingCapacity(remaining);
            if (count == opt.limit) break;
        }
    }
    try rt.emit(.{ .ok = true, .session_id = rt.session_id, .summary = true, .events = count, .timed_out = count < opt.limit });
}

test "GC matches only owned frame filenames" {
    try std.testing.expect(frameName("0123456789abcdef0123456789abcdef.png"));
    try std.testing.expect(!frameName("actions.jsonl"));
    try std.testing.expect(!frameName("../../0123456789abcdef0123456789.json"));
}
