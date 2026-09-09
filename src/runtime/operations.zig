const std = @import("std");
const native = @import("../platform/native.zig");
const c = native.c;
const Runtime = @import("runtime.zig").Runtime;
const Args = @import("../cli/args.zig").Args;
const ipc = @import("../platform/ipc.zig");

// Under audit.lock, recover only an uncommitted tail, never complete records.
fn repairTail(fd: c_int) !c.off_t {
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) < 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG or st.st_uid != c.getuid()) return error.UnsafeLog;
    var end = st.st_size;
    var buffer: [4096]u8 = undefined;
    while (end > 0) {
        const length: usize = @intCast(@min(end, buffer.len));
        const start = end - @as(c.off_t, @intCast(length));
        const n = c.pread(fd, &buffer, length, start);
        if (n < 0 and native.errno() == c.EINTR) continue;
        if (n != length) return error.LogFailed;
        if (std.mem.lastIndexOfScalar(u8, buffer[0..length], '\n')) |index| {
            end = start + @as(c.off_t, @intCast(index)) + 1;
            break;
        }
        end = start;
    }
    if (end != st.st_size and c.ftruncate(fd, end) < 0) return error.LogFailed;
    return end;
}

// No argv, text, titles, or application content in the audit trail.
pub fn log(rt: *Runtime, action: []const u8, status: []const u8) !void {
    try rt.prepare();
    const lock_fd = c.open(try rt.statePath("audit.lock"), c.O_CREAT | c.O_RDWR | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
    if (lock_fd < 0) return error.LogFailed;
    defer _ = c.close(lock_fd);
    // Appends are short; a concurrent command should wait, not fail outright.
    try Runtime.flockWithin(lock_fd, 500, error.LogBusy);
    const path = try rt.statePath("actions.jsonl");
    var st: c.struct_stat = undefined;
    if (c.lstat(path, &st) == 0) {
        if ((st.st_mode & c.S_IFMT) != c.S_IFREG or st.st_uid != c.getuid()) return error.UnsafeLog;
        if (st.st_size > 1024 * 1024 and c.rename(path, try rt.statePath("actions.previous.jsonl")) < 0) return error.LogFailed;
    }
    const fd = c.open(path, c.O_RDWR | c.O_APPEND | c.O_CREAT | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
    if (fd < 0) return error.LogFailed;
    defer _ = c.close(fd);
    const start = try repairTail(fd);
    errdefer _ = c.ftruncate(fd, start);
    const json = try std.json.Stringify.valueAlloc(rt.allocator, .{ .unix_ms = c.time(null) * 1000, .session_id = rt.session_id, .action = action, .status = status }, .{});
    const line = try std.fmt.allocPrint(rt.allocator, "{s}\n", .{json});
    var written: usize = 0;
    while (written < line.len) {
        const n = c.write(fd, line.ptr + written, line.len - written);
        if (n < 0 and native.errno() == c.EINTR) continue;
        if (n <= 0) return error.LogFailed;
        written += @intCast(n);
    }
}

pub fn logs(rt: *Runtime, opt: Args) !void {
    try rt.prepare();
    const data = rt.readFile(try rt.statePath("actions.jsonl"), 2 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    // Newline is the record commit marker. A crash/short write may leave a
    // suffix; report it without making all earlier audit records unreadable.
    const committed = if (std.mem.lastIndexOfScalar(u8, data, '\n')) |index| index + 1 else 0;
    var start = committed;
    var selected: usize = 0;
    while (start > 0 and selected < opt.limit) : (selected += 1) {
        start = if (std.mem.lastIndexOfScalar(u8, data[0 .. start - 1], '\n')) |index| index + 1 else 0;
    }
    var entries: std.ArrayList(std.json.Value) = .empty;
    var lines = std.mem.tokenizeScalar(u8, data[start..committed], '\n');
    while (lines.next()) |line| try entries.append(rt.allocator, try rt.parseJson(std.json.Value, line));
    try rt.emit(.{ .ok = true, .session_id = rt.session_id, .entries = entries.items, .incomplete_tail = committed != data.len });
}

pub fn frameName(name: []const u8) bool {
    if (name.len != 36 and name.len != 37) return false;
    if (!std.mem.eql(u8, name[32..], ".png") and !std.mem.eql(u8, name[32..], ".json")) return false;
    for (name[0..32]) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

/// Removes expired frames. `report` is true for the explicit gc command,
/// which always scans and emits a summary; observe calls with false.
pub fn collect(rt: *Runtime, opt: Args, report: bool) !void {
    try rt.prepare();
    // Frames older than their 30 s validity window are never usable, so
    // cleanup does not need the action lock and cannot block input commands.
    const lock_fd = c.open(try rt.statePath("gc.lock"), c.O_CREAT | c.O_RDWR | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
    if (lock_fd < 0) return error.CleanupFailed;
    defer _ = c.close(lock_fd);
    try Runtime.flockWithin(lock_fd, if (report) 500 else 0, error.ControlBusy);
    // Explicit gc always runs. Observe amortizes directory scans to once per
    // 30 seconds; stale/future markers cannot postpone cleanup indefinitely.
    const stamp = try rt.statePath("gc.stamp");
    var stamp_stat: c.struct_stat = undefined;
    const seconds = c.time(null);
    if (!report and c.lstat(stamp, &stamp_stat) == 0 and
        (stamp_stat.st_mode & c.S_IFMT) == c.S_IFREG and stamp_stat.st_uid == c.getuid() and
        seconds >= stamp_stat.st_mtim.tv_sec and seconds - stamp_stat.st_mtim.tv_sec < 30) return;
    const dir = c.opendir(try rt.allocator.dupeZ(u8, rt.directory)) orelse return error.StateDirectoryFailed;
    defer _ = c.closedir(dir);
    var count: usize = 0;
    while (try native.nextEntry(dir)) |name| {
        if (!frameName(name)) continue;
        var path_buffer: [4096]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/{s}", .{ rt.directory, name });
        var st: c.struct_stat = undefined;
        if (c.lstat(path, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG or st.st_uid != c.getuid()) continue;
        const age = c.time(null) * 1000 - (st.st_mtim.tv_sec * 1000 + @divTrunc(st.st_mtim.tv_nsec, 1_000_000));
        // Never collect a usable frame, even if the requested threshold is zero.
        if (age <= @max(31_000, opt.older_than_ms)) continue;
        if (!opt.dry_run and c.unlink(path) < 0) return error.CleanupFailed;
        count += 1;
    }
    if (!report and !opt.dry_run) {
        const fd = c.open(stamp, c.O_CREAT | c.O_WRONLY | c.O_CLOEXEC | c.O_NOFOLLOW | c.O_NONBLOCK, @as(c_uint, 0o600));
        if (fd >= 0) {
            defer _ = c.close(fd);
            if (c.fstat(fd, &stamp_stat) == 0 and (stamp_stat.st_mode & c.S_IFMT) == c.S_IFREG and stamp_stat.st_uid == c.getuid()) _ = c.futimens(fd, null);
        }
    }
    if (report) try rt.emit(.{ .ok = true, .session_id = rt.session_id, .dry_run = opt.dry_run, .files = count });
}

pub fn events(rt: *Runtime, opt: Args) !void {
    try rt.validateDisplay();
    const path = try std.fmt.allocPrint(rt.allocator, "{s}/.socket2.sock", .{std.fs.path.dirname(rt.socket).?});
    const fd = try ipc.connect(path);
    defer _ = c.close(fd);
    var pending: std.ArrayList(u8) = .empty;
    const deadline = native.nowMs() + opt.timeout_ms;
    var count: usize = 0;
    while (native.nowMs() < deadline and count < opt.limit) {
        try native.checkCancelled();
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        const ready = c.poll(&pfd, 1, @intCast(@max(0, @min(50, deadline - native.nowMs()))));
        if (ready < 0) {
            if (native.errno() == c.EINTR) continue;
            return error.EventReadFailed;
        }
        if (ready == 0) continue;
        var buffer: [4096]u8 = undefined;
        const n = c.read(fd, &buffer, buffer.len);
        if (n < 0 and (native.errno() == c.EINTR or native.errno() == c.EAGAIN)) continue;
        if (n <= 0) return error.EventStreamClosed;
        try pending.appendSlice(rt.allocator, buffer[0..@intCast(n)]);
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |end| {
            // Limit a record, not a socket read that may finish one record
            // and contain the beginning of the next valid record.
            if (end + 1 > 65536) return error.EventTooLarge;
            const line = pending.items[0..end];
            const separator = std.mem.indexOf(u8, line, ">>") orelse return error.InvalidEvent;
            try rt.emit(.{ .ok = true, .session_id = rt.session_id, .event = line[0..separator], .data = line[separator + 2 ..] });
            count += 1;
            const remaining = pending.items.len - end - 1;
            std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[end + 1 ..]);
            pending.shrinkRetainingCapacity(remaining);
            if (count == opt.limit) break;
        }
        if (count < opt.limit and pending.items.len >= 65536) return error.EventTooLarge;
    }
    try rt.emit(.{ .ok = true, .session_id = rt.session_id, .summary = true, .events = count, .timed_out = count < opt.limit });
}

test "GC matches only owned frame filenames" {
    try std.testing.expect(frameName("0123456789abcdef0123456789abcdef.png"));
    try std.testing.expect(!frameName("actions.jsonl"));
    try std.testing.expect(!frameName("../../0123456789abcdef0123456789.json"));
}
