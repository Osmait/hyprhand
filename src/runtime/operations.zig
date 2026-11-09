const std = @import("std");
const native = @import("../platform/native.zig");
const c = native.c;
const Runtime = @import("runtime.zig").Runtime;
const Args = @import("../cli/args.zig").Args;
const ipc = @import("../platform/ipc.zig");

// Under audit.lock, recover only an uncommitted tail, never complete records.
fn repair_tail(fd: c_int) !c.off_t {
    var log_stat: c.struct_stat = undefined;
    if (c.fstat(fd, &log_stat) < 0) return error.UnsafeLog;
    if ((log_stat.st_mode & c.S_IFMT) != c.S_IFREG) return error.UnsafeLog;
    if (log_stat.st_uid != c.getuid()) return error.UnsafeLog;

    var end = log_stat.st_size;
    var buffer: [4096]u8 = undefined;
    while (end > 0) {
        const length: usize = @intCast(@min(end, buffer.len));
        const start = end - @as(c.off_t, @intCast(length));
        const bytes_read = c.pread(fd, &buffer, length, start);
        if (bytes_read < 0 and native.errno() == c.EINTR) continue;
        if (bytes_read != length) return error.LogFailed;
        if (std.mem.lastIndexOfScalar(u8, buffer[0..length], '\n')) |index| {
            end = start + @as(c.off_t, @intCast(index)) + 1;
            break;
        }
        end = start;
    }

    if (end != log_stat.st_size) {
        if (c.ftruncate(fd, end) < 0) return error.LogFailed;
    }
    return end;
}

// No argv, text, titles, or application content in the audit trail.
pub fn log(runtime: *Runtime, action: []const u8, status: []const u8) !void {
    try runtime.prepare();
    const lock_fd = c.open(
        try runtime.state_path("audit.lock"),
        c.O_CREAT | c.O_RDWR | c.O_CLOEXEC | c.O_NOFOLLOW,
        @as(c_uint, 0o600),
    );
    if (lock_fd < 0) return error.LogFailed;
    defer _ = c.close(lock_fd);
    // Appends are short; a concurrent command should wait, not fail outright.
    try Runtime.flock_within(lock_fd, 500, error.LogBusy);

    const path = try runtime.state_path("actions.jsonl");
    var log_stat: c.struct_stat = undefined;
    if (c.lstat(path, &log_stat) == 0) {
        if ((log_stat.st_mode & c.S_IFMT) != c.S_IFREG) return error.UnsafeLog;
        if (log_stat.st_uid != c.getuid()) return error.UnsafeLog;
        if (log_stat.st_size > 1024 * 1024) {
            const previous = try runtime.state_path("actions.previous.jsonl");
            if (c.rename(path, previous) < 0) return error.LogFailed;
        }
    }
    const fd = c.open(
        path,
        c.O_RDWR | c.O_APPEND | c.O_CREAT | c.O_CLOEXEC | c.O_NOFOLLOW,
        @as(c_uint, 0o600),
    );
    if (fd < 0) return error.LogFailed;
    defer _ = c.close(fd);
    const start = try repair_tail(fd);
    errdefer _ = c.ftruncate(fd, start);

    const json = try std.json.Stringify.valueAlloc(runtime.allocator, .{
        .unix_ms = c.time(null) * 1000,
        .session_id = runtime.session_id,
        .action = action,
        .status = status,
    }, .{});
    const line = try std.fmt.allocPrint(runtime.allocator, "{s}\n", .{json});
    var written: usize = 0;
    while (written < line.len) {
        const bytes_written = c.write(fd, line.ptr + written, line.len - written);
        if (bytes_written < 0 and native.errno() == c.EINTR) continue;
        if (bytes_written <= 0) return error.LogFailed;
        written += @intCast(bytes_written);
    }
}

pub fn logs(runtime: *Runtime, arguments: Args) !void {
    try runtime.prepare();
    const path = try runtime.state_path("actions.jsonl");
    const data = runtime.read_file(path, 2 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };

    // Newline is the record commit marker. A crash/short write may leave a
    // suffix; report it without making all earlier audit records unreadable.
    const committed = if (std.mem.lastIndexOfScalar(u8, data, '\n')) |index| index + 1 else 0;
    var start = committed;
    var selected: usize = 0;
    while (start > 0 and selected < arguments.limit) : (selected += 1) {
        const before = data[0 .. start - 1];
        start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |index| index + 1 else 0;
    }
    var entries: std.ArrayList(std.json.Value) = .empty;
    var lines = std.mem.tokenizeScalar(u8, data[start..committed], '\n');
    while (lines.next()) |line| {
        const entry = try runtime.parse_json(std.json.Value, line);
        try entries.append(runtime.allocator, entry);
    }

    try runtime.emit(.{
        .ok = true,
        .session_id = runtime.session_id,
        .entries = entries.items,
        .incomplete_tail = committed != data.len,
    });
}

pub fn frame_name(name: []const u8) bool {
    if (snapshot_name(name)) return true;
    if (marked_image_name(name)) return true;
    if (confirmation_name(name)) return true;
    if (name.len != 36 and name.len != 37) return false;
    const extension = name[32..];
    if (!std.mem.eql(u8, extension, ".png") and !std.mem.eql(u8, extension, ".json")) return false;
    for (name[0..32]) |character| if (!std.ascii.isHex(character)) return false;
    return true;
}

/// Pending confirmations: eight hexadecimal digits and ".confirm".
fn confirmation_name(name: []const u8) bool {
    if (name.len != 16) return false;
    if (!std.mem.eql(u8, name[8..], ".confirm")) return false;
    for (name[0..8]) |character| if (!std.ascii.isHex(character)) return false;
    return true;
}

/// Marked frame images: a frame ID and ".marks.png".
fn marked_image_name(name: []const u8) bool {
    if (name.len != 42) return false;
    if (!std.mem.eql(u8, name[32..], ".marks.png")) return false;
    for (name[0..32]) |character| if (!std.ascii.isHex(character)) return false;
    return true;
}

/// Accessibility snapshots: eight hexadecimal digits and ".a11y".
fn snapshot_name(name: []const u8) bool {
    if (name.len != 13) return false;
    if (!std.mem.eql(u8, name[8..], ".a11y")) return false;
    for (name[0..8]) |character| if (!std.ascii.isHex(character)) return false;
    return true;
}

/// Removes expired frames. `report` is true for the explicit gc command,
/// which always scans and emits a summary; observe calls with false.
pub fn collect(runtime: *Runtime, arguments: Args, report: bool) !void {
    try runtime.prepare();
    // Frames older than their 30 s validity window are never usable, so
    // cleanup does not need the action lock and cannot block input commands.
    const lock_fd = c.open(
        try runtime.state_path("gc.lock"),
        c.O_CREAT | c.O_RDWR | c.O_CLOEXEC | c.O_NOFOLLOW,
        @as(c_uint, 0o600),
    );
    if (lock_fd < 0) return error.CleanupFailed;
    defer _ = c.close(lock_fd);
    try Runtime.flock_within(lock_fd, if (report) 500 else 0, error.ControlBusy);

    // Explicit gc always runs. Observe amortizes directory scans to once per
    // 30 seconds; stale/future markers cannot postpone cleanup indefinitely.
    const stamp = try runtime.state_path("gc.stamp");
    const seconds = c.time(null);
    if (!report and collect_stamp_recent(stamp, seconds)) return;

    const directory = try runtime.allocator.dupeSentinel(u8, runtime.directory, 0);
    const directory_stream = c.opendir(directory) orelse return error.StateDirectoryFailed;
    defer _ = c.closedir(directory_stream);
    var count: usize = 0;
    while (try native.next_entry(directory_stream)) |name| {
        if (!frame_name(name)) continue;
        var path_buffer: [4096]u8 = undefined;
        const path = try std.mem.printSentinel(
            &path_buffer,
            "{s}/{s}",
            .{ runtime.directory, name },
            0,
        );
        var frame_stat: c.struct_stat = undefined;
        if (c.lstat(path, &frame_stat) != 0) continue;
        if ((frame_stat.st_mode & c.S_IFMT) != c.S_IFREG) continue;
        if (frame_stat.st_uid != c.getuid()) continue;
        const modified = frame_stat.st_mtim;
        const modified_ms = modified.tv_sec * 1000 + @divTrunc(modified.tv_nsec, 1_000_000);
        const age_ms = c.time(null) * 1000 - modified_ms;
        // Never collect a usable frame, even if the requested threshold is zero.
        if (age_ms <= @max(31_000, arguments.older_than_ms)) continue;
        if (!arguments.dry_run and c.unlink(path) < 0) return error.CleanupFailed;
        count += 1;
    }

    if (!report and !arguments.dry_run) collect_stamp_touch(stamp);
    if (report) {
        try runtime.emit(.{
            .ok = true,
            .session_id = runtime.session_id,
            .dry_run = arguments.dry_run,
            .files = count,
        });
    }
}

/// True when the gc stamp is a regular file we own, touched less than 30
/// seconds before `seconds`.
fn collect_stamp_recent(stamp: [:0]const u8, seconds: c.time_t) bool {
    var stamp_stat: c.struct_stat = undefined;
    if (c.lstat(stamp, &stamp_stat) != 0) return false;
    if ((stamp_stat.st_mode & c.S_IFMT) != c.S_IFREG) return false;
    if (stamp_stat.st_uid != c.getuid()) return false;
    if (seconds < stamp_stat.st_mtim.tv_sec) return false;
    return seconds - stamp_stat.st_mtim.tv_sec < 30;
}

fn collect_stamp_touch(stamp: [:0]const u8) void {
    const fd = c.open(
        stamp,
        c.O_CREAT | c.O_WRONLY | c.O_CLOEXEC | c.O_NOFOLLOW | c.O_NONBLOCK,
        @as(c_uint, 0o600),
    );
    if (fd < 0) return;
    defer _ = c.close(fd);

    var stamp_stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stamp_stat) != 0) return;
    if ((stamp_stat.st_mode & c.S_IFMT) != c.S_IFREG) return;
    if (stamp_stat.st_uid != c.getuid()) return;
    _ = c.futimens(fd, null);
}

pub fn events(runtime: *Runtime, arguments: Args) !void {
    try runtime.validate_display();
    const socket_directory = std.fs.path.dirname(runtime.socket).?;
    const path = try std.fmt.allocPrint(
        runtime.allocator,
        "{s}/.socket2.sock",
        .{socket_directory},
    );
    const fd = try ipc.connect(path);
    defer _ = c.close(fd);

    var pending: std.ArrayList(u8) = .empty;
    const deadline = native.now_ms() + arguments.timeout_ms;
    var count: usize = 0;
    while (native.now_ms() < deadline and count < arguments.limit) {
        try native.check_cancelled();
        var poll_fd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        const poll_timeout_ms = @max(0, @min(50, deadline - native.now_ms()));
        const ready = c.poll(&poll_fd, 1, @intCast(poll_timeout_ms));
        if (ready < 0) {
            if (native.errno() == c.EINTR) continue;
            return error.EventReadFailed;
        }
        if (ready == 0) continue;

        var buffer: [4096]u8 = undefined;
        const bytes_read = c.read(fd, &buffer, buffer.len);
        if (bytes_read < 0 and native.errno() == c.EINTR) continue;
        if (bytes_read < 0 and native.errno() == c.EAGAIN) continue;
        if (bytes_read <= 0) return error.EventStreamClosed;
        try pending.appendSlice(runtime.allocator, buffer[0..@intCast(bytes_read)]);

        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |end| {
            // Limit a record, not a socket read that may finish one record
            // and contain the beginning of the next valid record.
            if (end + 1 > 65536) return error.EventTooLarge;
            const line = pending.items[0..end];
            const separator = std.mem.indexOf(u8, line, ">>") orelse return error.InvalidEvent;
            try runtime.emit(.{
                .ok = true,
                .session_id = runtime.session_id,
                .event = line[0..separator],
                .data = line[separator + 2 ..],
            });
            count += 1;
            const remaining = pending.items.len - end - 1;
            std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[end + 1 ..]);
            pending.shrinkRetainingCapacity(remaining);
            if (count == arguments.limit) break;
        }
        if (count < arguments.limit and pending.items.len >= 65536) return error.EventTooLarge;
    }

    try runtime.emit(.{
        .ok = true,
        .session_id = runtime.session_id,
        .summary = true,
        .events = count,
        .timed_out = count < arguments.limit,
    });
}

test "GC matches only owned frame filenames" {
    try std.testing.expect(frame_name("0123456789abcdef0123456789abcdef.png"));
    try std.testing.expect(!frame_name("actions.jsonl"));
    try std.testing.expect(!frame_name("../../0123456789abcdef0123456789.json"));
}
