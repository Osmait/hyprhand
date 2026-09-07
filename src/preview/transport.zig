//! One bounded frame in flight. I/O and thread-safe texture decoding never run
//! on the GTK main loop. Only that loop may attach a texture to a widget.
const std = @import("std");
const protocol = @import("protocol.zig");
const c = @import("gtk.zig").c;

pub const Job = struct {
    process: *c.GSubprocess,
    previous: ?*c.GBytes,
    png: ?*c.GBytes = null,
    texture: ?*c.GdkTexture = null,
    captured_ms: i64 = 0,
    enabled: bool = false,
    ok: bool = false,

    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(data.?));
        if (self.previous) |p| c.g_bytes_unref(p);
        if (self.png) |p| c.g_bytes_unref(p);
        if (self.texture) |t| c.g_object_unref(t);
        std.heap.c_allocator.destroy(self);
    }

    fn read(self: *Job, bytes: []u8, cancel: ?*c.GCancellable) !void {
        var count: usize = 0;
        var err: ?*c.GError = null;
        defer if (err) |e| c.g_error_free(e);
        if (c.g_input_stream_read_all(c.g_subprocess_get_stdout_pipe(self.process), bytes.ptr, bytes.len, &count, cancel, &err) == 0 or count != bytes.len) return error.PreviewStreamClosed;
    }

    fn receive(self: *Job, cancel: ?*c.GCancellable) !void {
        var err: ?*c.GError = null;
        defer if (err) |e| c.g_error_free(e);
        var count: usize = 0;
        if (c.g_output_stream_write_all(c.g_subprocess_get_stdin_pipe(self.process), "F", 1, &count, cancel, &err) == 0 or count != 1) return error.PreviewStreamClosed;
        var prefix: [4]u8 = undefined;
        try self.read(&prefix, cancel);
        const length = std.mem.readInt(u32, &prefix, .little);
        if (length < protocol.header_len or length > protocol.header_len + protocol.max_bytes) return error.InvalidPreviewFrame;
        const memory = c.g_try_malloc(length) orelse return error.OutOfMemory;
        const bytes = c.g_bytes_new_take(memory, length);
        defer c.g_bytes_unref(bytes);
        const data = @as([*]u8, @ptrCast(memory))[0..length];
        try self.read(data, cancel);
        const frame = try protocol.decode(data, @divTrunc(c.g_get_monotonic_time(), 1000));
        self.png = c.g_bytes_new_from_bytes(bytes, protocol.header_len, length - protocol.header_len);
        self.captured_ms = frame.captured_ms;
        self.enabled = frame.enabled;
        // Exact equality, not a hash: never mistake new pixels for old content.
        if (self.previous == null or c.g_bytes_equal(self.previous.?, self.png.?) == 0)
            self.texture = c.gdk_texture_new_from_bytes(self.png.?, &err) orelse return error.InvalidScreenshot;
        self.ok = true;
    }

    fn run(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, cancel: ?*c.GCancellable) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(data.?));
        self.receive(cancel) catch {};
        c.g_task_return_boolean(task, @intFromBool(self.ok));
    }

    pub fn start(process: *c.GSubprocess, previous: ?*c.GBytes, cancel: *c.GCancellable, callback: c.GAsyncReadyCallback) !void {
        const self = try std.heap.c_allocator.create(Job);
        self.* = .{ .process = process, .previous = if (previous) |p| c.g_bytes_ref(p) else null };
        // GTask keeps source_object/process and cancellable alive until done.
        const task = c.g_task_new(process, cancel, callback, null);
        c.g_task_set_task_data(task, self, destroy);
        c.g_task_run_in_thread(task, run);
        c.g_object_unref(task);
    }
};

fn testProcess(mode: [:0]const u8) !*c.GSubprocess {
    const script =
        \\import sys,struct,time,zlib,binascii
        \\def chunk(tag,data):
        \\ return struct.pack('>I',len(data))+tag+data+struct.pack('>I',binascii.crc32(tag+data)&0xffffffff)
        \\png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',1,1,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(b'\x00\x2f\x6f\xe3\xff'))+chunk(b'IEND',b'')
        \\while sys.stdin.buffer.read(1):
        \\ if sys.argv[1]=='oversize':
        \\  sys.stdout.buffer.write(struct.pack('<I',8*1024*1024+14));sys.stdout.buffer.flush();break
        \\ if sys.argv[1]=='partial':
        \\  sys.stdout.buffer.write(struct.pack('<I',1000)+b'abc');sys.stdout.buffer.flush();break
        \\ if sys.argv[1]=='invalid': png=png[:24]
        \\ data=b'DCP1\1'+struct.pack('<q',int(time.monotonic()*1000))+png
        \\ sys.stdout.buffer.write(struct.pack('<I',len(data))+data);sys.stdout.buffer.flush()
    ;
    const argv = [_:null]?[*:0]const u8{ "python3", "-c", script, mode };
    var err: ?*c.GError = null;
    defer if (err) |e| c.g_error_free(e);
    return c.g_subprocess_newv(@ptrCast(&argv), c.G_SUBPROCESS_FLAGS_STDIN_PIPE | c.G_SUBPROCESS_FLAGS_STDOUT_PIPE | c.G_SUBPROCESS_FLAGS_STDERR_SILENCE, &err) orelse error.TestProcessFailed;
}

fn endTestProcess(process: *c.GSubprocess) void {
    c.g_subprocess_force_exit(process);
    _ = c.g_subprocess_wait(process, null, null);
    c.g_object_unref(process);
}

fn testJob(process: *c.GSubprocess, previous: ?*c.GBytes) !*Job {
    const job = try std.heap.c_allocator.create(Job);
    job.* = .{ .process = process, .previous = if (previous) |p| c.g_bytes_ref(p) else null };
    return job;
}

test "transport decodes without a display and reuses identical PNG storage" {
    const process = try testProcess("valid");
    defer endTestProcess(process);
    const first = try testJob(process, null);
    defer Job.destroy(first);
    try first.receive(null);
    try std.testing.expect(first.ok and first.texture != null);
    const second = try testJob(process, first.png);
    defer Job.destroy(second);
    try second.receive(null);
    try std.testing.expect(second.ok and second.texture == null);
}

test "transport rejects oversized lengths, truncated payloads and invalid PNG" {
    for ([_][:0]const u8{ "oversize", "partial", "invalid" }, [_]anyerror{ error.InvalidPreviewFrame, error.PreviewStreamClosed, error.InvalidScreenshot }) |mode, expected| {
        const process = try testProcess(mode);
        defer endTestProcess(process);
        const job = try testJob(process, null);
        defer Job.destroy(job);
        try std.testing.expectError(expected, job.receive(null));
        try std.testing.expect(!job.ok);
    }
}

test "transport honors a cancelled request" {
    const process = try testProcess("valid");
    defer endTestProcess(process);
    const job = try testJob(process, null);
    defer Job.destroy(job);
    const cancel = c.g_cancellable_new();
    defer c.g_object_unref(cancel);
    c.g_cancellable_cancel(cancel);
    try std.testing.expectError(error.PreviewStreamClosed, job.receive(cancel));
}
