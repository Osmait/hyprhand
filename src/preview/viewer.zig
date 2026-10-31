//! Optional GTK viewer. No virtual input devices, IPC dispatchers or enable path.
const std = @import("std");
const protocol = @import("protocol.zig");
const c = @import("gtk.zig").c;
const Job = @import("transport.zig").Job;
const Cadence = @import("cadence.zig").Cadence;

// Scoped to this process/window, independent of the owner's GTK theme.
// Scrims protect controls over both bright and dark captured applications.
const css = @embedFile("pip.css");

const State = struct {
    cli: [:0]const u8,
    session: [:0]const u8,
    instance: [:0]const u8,
    monitor: [:0]const u8,
    window: *c.GtkWindow,
    motion: *c.GtkEventControllerMotion,
    controls_visible: bool = false,
    keyboard_controls: bool = false,
    loop: *c.GMainLoop,
    picture: *c.GtkPicture,
    status: *c.GtkLabel,
    stop: *c.GtkWidget,
    frame_process: ?*c.GSubprocess = null,
    stop_process: ?*c.GSubprocess = null,
    capture_started: i64 = 0,
    last_frame: i64 = 0,
    retry_after: i64 = 0,
    closing: bool = false,
    stop_failed: bool = false,
    stop_confirmed: bool = false,
    stopped_at: i64 = 0,
    frame_busy: bool = false,
    frame_cancel: ?*c.GCancellable = null,
    retiring_at: i64 = 0,
    close_started: i64 = 0,
    stop_started: i64 = 0,
    png: ?*c.GBytes = null,
    texture: ?*c.GdkTexture = null,
    cadence: Cadence,
    metrics: bool = false,
    metrics_started: i64 = 0,
    metrics_emitted: i64 = 0,
    received: u64 = 0,
    updates: u64 = 0,
    painted: u64 = 0,
    presented: u64 = 0,
    paint_pending: ?i64 = null,
    paint_latency_ms: i64 = 0,
    present_latency_ms: i64 = 0,
    feedback: [64]?struct { counter: i64, captured: i64 } = @splat(null),
    clock: ?*c.GdkFrameClock = null,
};
var state: State = undefined;
fn now() i64 {
    return @divTrunc(c.g_get_monotonic_time(), 1000);
}
fn label(text: [*:0]const u8) void {
    c.gtk_label_set_text(state.status, text);
    c.gtk_widget_set_tooltip_text(@ptrCast(state.status), text);
}

fn signal_connect(
    instance: ?*anyopaque,
    signal: [*:0]const u8,
    handler: c.GCallback,
    data: ?*anyopaque,
) void {
    _ = c.g_signal_connect_data(instance, signal, handler, data, null, 0);
}

// Observe the whole window, including controls, so crossing an overlay does not
// flicker. Reveal before GTK moves keyboard focus: transparent containers may
// otherwise be skipped during Tab navigation.
fn update_controls() void {
    const pointer_inside = c.gtk_event_controller_motion_contains_pointer(state.motion) != 0;
    const visible = pointer_inside or state.keyboard_controls;
    if (visible == state.controls_visible) return;

    state.controls_visible = visible;
    const widget: *c.GtkWidget = @ptrCast(state.window);
    if (visible) {
        c.gtk_widget_add_css_class(widget, "controls-visible");
    } else {
        c.gtk_widget_remove_css_class(widget, "controls-visible");
    }
}
fn pointer_changed(_: ?*c.GObject, _: ?*c.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    state.keyboard_controls = false;
    update_controls();
}
fn active_changed(_: ?*c.GObject, _: ?*c.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    if (c.gtk_window_is_active(state.window) == 0) state.keyboard_controls = false;
    update_controls();
}
fn key_pressed(
    _: ?*c.GtkEventControllerKey,
    keyval: c_uint,
    _: c_uint,
    _: c.GdkModifierType,
    _: ?*anyopaque,
) callconv(.c) c_int {
    if (keyval == c.GDK_KEY_Tab or keyval == c.GDK_KEY_ISO_Left_Tab) {
        state.keyboard_controls = true;
        update_controls();
    }
    return 0; // GTK still handles native focus traversal; no input forwarding.
}
fn lost() void {
    c.gtk_picture_set_paintable(state.picture, null);
    state.last_frame = 0;
    state.paint_pending = null;

    const text: [*:0]const u8 = if (state.stop_failed)
        "No signal · Could not stop input. Try again."
    else if (state.stop_confirmed)
        "No signal · Input stopped"
    else
        "No signal · Session closed, locked, or unavailable";
    label(text);
}

/// Starts a hyprhand worker for this viewer's session. Frame workers get a
/// monitor and bidirectional pipes; the stop worker runs silently.
fn spawn(command: [*:0]const u8, frame: bool) ?*c.GSubprocess {
    var argv = [_:null]?[*:0]const u8{
        state.cli,
        command,
        "--session",
        state.session,
        "--expected-instance",
        state.instance,
        null,
        null,
    };
    if (frame) {
        argv[6] = "--monitor";
        argv[7] = state.monitor.ptr;
    }

    var glib_error: ?*c.GError = null;
    const pipes: c_int = if (frame)
        c.G_SUBPROCESS_FLAGS_STDIN_PIPE | c.G_SUBPROCESS_FLAGS_STDOUT_PIPE
    else
        c.G_SUBPROCESS_FLAGS_STDOUT_SILENCE;
    const flags: c.GSubprocessFlags = @intCast(c.G_SUBPROCESS_FLAGS_STDERR_SILENCE | pipes);
    const process = c.g_subprocess_newv(@ptrCast(&argv), flags, &glib_error);
    if (glib_error) |value| c.g_error_free(value);
    return process;
}

fn reaped(object: ?*c.GObject, result: ?*c.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
    const process: *c.GSubprocess = @ptrCast(object.?);
    var glib_error: ?*c.GError = null;
    _ = c.g_subprocess_wait_finish(process, result, &glib_error);
    if (glib_error) |value| c.g_error_free(value);

    state.frame_process = null;
    state.retiring_at = 0;
    c.g_object_unref(process);
}

fn retire() void {
    if (state.frame_cancel) |cancellable| c.g_cancellable_cancel(cancellable);
    if (state.frame_process) |process| {
        if (state.retiring_at == 0) {
            state.retiring_at = now();
            c.g_subprocess_send_signal(process, c.SIGTERM);
            c.g_subprocess_wait_async(process, null, reaped, null);
        }
    }
}

fn frame_done(_: ?*c.GObject, result: ?*c.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
    const task_data = c.g_task_get_task_data(@ptrCast(result.?)).?;
    const job: *Job = @ptrCast(@alignCast(task_data));
    state.frame_busy = false;
    c.g_object_unref(state.frame_cancel.?);
    state.frame_cancel = null;
    if (state.closing) return;

    const frame_rejected = !job.ok or
        now() - job.captured_ms > protocol.max_age_ms or
        state.retiring_at != 0;
    if (frame_rejected) {
        retire();
        state.retry_after = now() + 1000;
        return lost();
    }

    const changed = job.texture != null;
    state.received += 1;
    if (job.texture) |texture| {
        if (state.texture) |previous| c.g_object_unref(previous);
        state.texture = @ptrCast(c.g_object_ref(texture));
        if (state.png) |previous| c.g_bytes_unref(previous);
        state.png = c.g_bytes_ref(job.png.?);
        state.updates += 1;
    }
    // A lost signal clears only the widget. Fresh identical pixels may safely
    // reuse the cached texture after lock/identity/time validation succeeds.
    if (changed or state.last_frame == 0) {
        c.gtk_picture_set_paintable(state.picture, @ptrCast(state.texture.?));
        state.paint_pending = job.captured_ms;
    }
    state.last_frame = job.captured_ms;
    state.retry_after = state.cadence.completed(state.capture_started, now(), changed);
    if (state.stop_confirmed and job.captured_ms > state.stopped_at) {
        state.stop_confirmed = !job.enabled;
    }

    const enabled = job.enabled and !state.stop_confirmed;
    const stop_sensitive = state.stop_process == null and enabled;
    c.gtk_widget_set_sensitive(state.stop, @intFromBool(stop_sensitive));
    const text: [*:0]const u8 = if (state.stop_process != null)
        "Stopping input…"
    else if (state.stop_failed)
        "Could not stop input · Try again"
    else if (enabled)
        "● Live · Input enabled"
    else
        "● Live · Input stopped";
    label(text);
}

fn request_frame() void {
    if (state.frame_process == null) state.frame_process = spawn("_preview_stream", true);
    if (state.frame_process) |process| {
        state.capture_started = now();
        state.frame_cancel = c.g_cancellable_new();
        Job.start(process, state.png, state.frame_cancel.?, frame_done) catch {
            c.g_object_unref(state.frame_cancel.?);
            state.frame_cancel = null;
            retire();
            state.retry_after = now() + 1000;
            return lost();
        };
        state.frame_busy = true;
    } else {
        state.retry_after = now() + 1000;
        lost();
    }
}

fn after_paint(clock: ?*c.GdkFrameClock, _: ?*anyopaque) callconv(.c) void {
    if (state.paint_pending) |captured| {
        state.paint_pending = null;
        state.painted += 1;
        state.paint_latency_ms += @max(0, now() - captured);
        const counter = c.gdk_frame_clock_get_frame_counter(clock);
        const slot = @as(u64, @intCast(counter)) % state.feedback.len;
        state.feedback[slot] = .{ .counter = counter, .captured = captured };
    }
}

fn metrics() void {
    if (!state.metrics) return;
    if (state.clock) |clock| {
        for (&state.feedback) |*entry| {
            const sample = entry.* orelse continue;
            const timings = c.gdk_frame_clock_get_timings(clock, sample.counter) orelse {
                entry.* = null;
                continue;
            };
            if (c.gdk_frame_timings_get_complete(timings) != 0) {
                const timestamp = c.gdk_frame_timings_get_presentation_time(timings);
                if (timestamp > 0) {
                    state.presented += 1;
                    state.present_latency_ms +=
                        @max(0, @divTrunc(timestamp, 1000) - sample.captured);
                }
                entry.* = null;
            }
        }
    }
    if (now() - state.metrics_emitted < 5000) return;

    state.metrics_emitted = now();
    const encoded = std.json.Stringify.valueAlloc(std.heap.c_allocator, .{
        .event = "preview_metrics",
        .elapsed_ms = now() - state.metrics_started,
        .received_frames = state.received,
        .texture_updates = state.updates,
        .painted_updates = state.painted,
        .presented_updates = state.presented,
        .paint_latency_total_ms = state.paint_latency_ms,
        .presentation_latency_total_ms = state.present_latency_ms,
        .presentation_feedback_available = state.presented > 0,
        .signal_live = state.last_frame != 0,
        .controls_visible = state.controls_visible,
    }, .{}) catch return;
    defer std.heap.c_allocator.free(encoded);
    var buffer: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{s}\n", .{encoded}) catch return;
    // Optional telemetry must never block GTK when its consumer stops reading.
    _ = c.write(c.STDOUT_FILENO, line.ptr, line.len);
}

fn tick(_: ?*anyopaque) callconv(.c) c_int {
    metrics();
    if (state.retiring_at != 0 and now() - state.retiring_at > 500) {
        if (state.frame_process) |process| c.g_subprocess_force_exit(process);
    }
    if (state.closing) {
        retire();
        if (state.stop_process) |process| {
            if (now() - state.close_started > 750) c.g_subprocess_force_exit(process);
        }
        const workers_finished = state.frame_process == null and
            !state.frame_busy and
            state.stop_process == null;
        if (workers_finished) c.g_main_loop_quit(state.loop);
        // A native decoder that ignores cancellation must not hang shutdown.
        if (now() - state.close_started > 1500) c._exit(1);
        return c.G_SOURCE_CONTINUE;
    }
    if (state.stop_process) |process| {
        const waited = now() - state.stop_started;
        if (waited > 2500) {
            c.g_subprocess_force_exit(process);
        } else if (waited > 2000) {
            c.g_subprocess_send_signal(process, c.SIGTERM);
        }
    }
    if (state.last_frame != 0 and now() - state.last_frame > protocol.max_age_ms) lost();
    if (state.frame_busy) {
        if (now() - state.capture_started > 2500) retire();
    } else if (state.retiring_at == 0 and now() >= state.retry_after) {
        request_frame();
    }
    return c.G_SOURCE_CONTINUE;
}

fn stop_done(object: ?*c.GObject, result: ?*c.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
    const process: *c.GSubprocess = @ptrCast(object.?);
    defer c.g_object_unref(process);
    state.stop_process = null;
    var glib_error: ?*c.GError = null;
    const finished = c.g_subprocess_wait_finish(process, result, &glib_error);
    defer if (glib_error) |value| c.g_error_free(value);
    if (state.closing) return;

    state.stop_confirmed = finished != 0 and c.g_subprocess_get_successful(process) != 0;
    if (state.stop_confirmed) state.stopped_at = now();
    state.stop_failed = !state.stop_confirmed;
    c.gtk_widget_set_sensitive(state.stop, @intFromBool(state.stop_failed));
    const text: [*:0]const u8 = if (state.stop_failed)
        "Could not stop input · Try again"
    else
        "Input stopped · Applications remain open";
    label(text);
}

fn stop_clicked(_: ?*c.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (state.stop_process != null) return;
    if (state.closing) return;

    state.stop_failed = false;
    state.stop_confirmed = false;
    label("Stopping input…");
    c.gtk_widget_set_sensitive(state.stop, 0);
    state.stop_process = spawn("_preview_stop", false);
    state.stop_started = now();
    if (state.stop_process) |process| {
        c.g_subprocess_wait_async(process, null, stop_done, null);
    } else {
        state.stop_failed = true;
        label("Could not stop input · Try again");
        c.gtk_widget_set_sensitive(state.stop, 1);
    }
}

fn quit(_: ?*anyopaque) callconv(.c) c_int {
    if (state.closing) return c.G_SOURCE_CONTINUE;
    state.closing = true;
    state.close_started = now();
    retire();
    return c.G_SOURCE_CONTINUE;
}
fn close_requested(_: ?*c.GtkWindow, _: ?*anyopaque) callconv(.c) c_int {
    _ = quit(null);
    return 1;
}
fn close_clicked(_: ?*c.GtkButton, _: ?*anyopaque) callconv(.c) void {
    _ = quit(null);
}
fn draw_grip(
    _: ?*c.GtkDrawingArea,
    cairo: ?*c.cairo_t,
    _: c_int,
    _: c_int,
    _: ?*anyopaque,
) callconv(.c) void {
    c.cairo_set_source_rgba(cairo, 1, 1, 1, 0.75);
    c.cairo_set_line_width(cairo, 1.5);
    c.cairo_move_to(cairo, 9, 23);
    c.cairo_line_to(cairo, 23, 9);
    c.cairo_move_to(cairo, 16, 23);
    c.cairo_line_to(cairo, 23, 16);
    c.cairo_stroke(cairo);
}
fn resize_pressed(
    gesture: ?*c.GtkGestureClick,
    _: c_int,
    _: f64,
    _: f64,
    data: ?*anyopaque,
) callconv(.c) void {
    const controller: *c.GtkEventController = @ptrCast(gesture.?);
    const event = c.gtk_event_controller_get_current_event(controller) orelse return;
    const device = c.gtk_event_controller_get_current_event_device(controller) orelse return;
    const surface = c.gtk_native_get_surface(@ptrCast(data.?)) orelse return;
    var x: f64 = 0;
    var y: f64 = 0;
    if (c.gdk_event_get_position(event, &x, &y) == 0) return;

    _ = c.gtk_gesture_set_state(@ptrCast(gesture.?), c.GTK_EVENT_SEQUENCE_CLAIMED);
    c.gdk_toplevel_begin_resize(
        @ptrCast(surface),
        c.GDK_SURFACE_EDGE_SOUTH_EAST,
        device,
        1,
        x,
        y,
        c.gtk_event_controller_get_current_event_time(controller),
    );
}
/// Widgets the event handlers need after construction.
const Ui = struct {
    window: *c.GtkWindow,
    picture: *c.GtkPicture,
    status: *c.GtkLabel,
    stop: *c.GtkWidget,
    close: *c.GtkWidget,
};

/// Undecorated window: picture, a header with title and close button, and a
/// footer with status, stop button and a resize grip, all as overlays.
fn build_ui(allocator: std.mem.Allocator, session: []const u8) !Ui {
    const window: *c.GtkWindow = @ptrCast(c.gtk_window_new());
    const window_title = try std.fmt.allocPrintSentinel(
        allocator,
        "Hyprhand · {s}",
        .{session},
        0,
    );
    c.gtk_window_set_title(window, window_title);
    c.gtk_window_set_default_size(window, 640, 360);
    c.gtk_widget_set_size_request(@ptrCast(window), 360, 203);
    c.gtk_window_set_decorated(window, 0);
    c.gtk_widget_add_css_class(@ptrCast(window), "hyprhand-pip");

    const handle: *c.GtkWindowHandle = @ptrCast(c.gtk_window_handle_new());
    const overlay: *c.GtkOverlay = @ptrCast(c.gtk_overlay_new());
    const picture = build_ui_picture();
    c.gtk_overlay_set_child(overlay, @ptrCast(picture));
    const header = try build_ui_header(allocator, session);
    c.gtk_overlay_add_overlay(overlay, @ptrCast(header.box));
    const footer = build_ui_footer(window);
    c.gtk_overlay_add_overlay(overlay, @ptrCast(footer.box));
    c.gtk_window_handle_set_child(handle, @ptrCast(overlay));
    c.gtk_window_set_child(window, @ptrCast(handle));

    return .{
        .window = window,
        .picture = picture,
        .status = footer.status,
        .stop = footer.stop,
        .close = header.close,
    };
}

fn build_ui_picture() *c.GtkPicture {
    const picture: *c.GtkPicture = @ptrCast(c.gtk_picture_new());
    c.gtk_picture_set_content_fit(picture, c.GTK_CONTENT_FIT_CONTAIN);
    c.gtk_picture_set_can_shrink(picture, 1);
    c.gtk_picture_set_alternative_text(
        picture,
        "Agent session preview; does not forward clicks or keyboard input",
    );
    c.gtk_widget_set_hexpand(@ptrCast(picture), 1);
    c.gtk_widget_set_vexpand(@ptrCast(picture), 1);
    return picture;
}

fn build_ui_header(
    allocator: std.mem.Allocator,
    session: []const u8,
) !struct { box: *c.GtkBox, close: *c.GtkWidget } {
    const header: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12));
    c.gtk_widget_add_css_class(@ptrCast(header), "pip-top");
    c.gtk_widget_set_valign(@ptrCast(header), c.GTK_ALIGN_START);

    const title_text = try std.fmt.allocPrintSentinel(
        allocator,
        "{s} · Read-only",
        .{session},
        0,
    );
    const title: *c.GtkLabel = @ptrCast(c.gtk_label_new(title_text));
    c.gtk_label_set_xalign(title, 0);
    c.gtk_label_set_ellipsize(title, c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_set_hexpand(@ptrCast(title), 1);
    const title_tooltip = try std.fmt.allocPrintSentinel(
        allocator,
        "{s} · Drag the image to move the viewer",
        .{session},
        0,
    );
    c.gtk_widget_set_tooltip_text(@ptrCast(title), title_tooltip);

    const close = c.gtk_button_new_from_icon_name("window-close-symbolic").?;
    c.gtk_widget_add_css_class(close, "pip-close");
    c.gtk_widget_set_tooltip_text(close, "Close viewer (the agent keeps running)");
    c.gtk_box_append(header, @ptrCast(title));
    c.gtk_box_append(header, close);
    return .{ .box = header, .close = close };
}

fn build_ui_footer(
    window: *c.GtkWindow,
) struct { box: *c.GtkBox, status: *c.GtkLabel, stop: *c.GtkWidget } {
    const footer: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 10));
    c.gtk_widget_set_valign(@ptrCast(footer), c.GTK_ALIGN_END);
    c.gtk_widget_add_css_class(@ptrCast(footer), "pip-bottom");

    const status: *c.GtkLabel = @ptrCast(c.gtk_label_new("Connecting…"));
    c.gtk_label_set_xalign(status, 0);
    c.gtk_label_set_wrap(status, 1);
    c.gtk_label_set_lines(status, 2);
    c.gtk_label_set_ellipsize(status, c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_set_hexpand(@ptrCast(status), 1);

    const stop = c.gtk_button_new_with_label("Stop input").?;
    c.gtk_widget_add_css_class(stop, "destructive-action");
    c.gtk_widget_set_tooltip_text(
        stop,
        "Disable hyprhand input. Applications and other agent processes remain running.",
    );
    c.gtk_box_append(footer, @ptrCast(status));
    c.gtk_box_append(footer, stop);
    c.gtk_box_append(footer, build_ui_grip(window));
    return .{ .box = footer, .status = status, .stop = stop };
}

fn build_ui_grip(window: *c.GtkWindow) *c.GtkWidget {
    const grip = c.gtk_drawing_area_new().?;
    c.gtk_widget_set_size_request(grip, 32, 32);
    c.gtk_widget_set_valign(grip, c.GTK_ALIGN_END);
    c.gtk_widget_set_cursor_from_name(grip, "se-resize");
    c.gtk_widget_set_tooltip_text(grip, "Drag to resize; Hyprland shortcuts also work");
    c.gtk_drawing_area_set_draw_func(@ptrCast(grip), draw_grip, null, null);

    const resize = c.gtk_gesture_click_new();
    signal_connect(resize, "pressed", @ptrCast(&resize_pressed), window);
    c.gtk_widget_add_controller(grip, @ptrCast(resize));
    return grip;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(allocator);
    if (argv.len != 6) return error.UseHyprhandPreview;
    const fps = try std.fmt.parseInt(u32, argv[5], 10);
    if (fps < 1) return error.InvalidPreviewFps;
    if (fps > 15) return error.InvalidPreviewFps;
    const app_id = init.environ_map.get("HYPRHAND_PIP_APP_ID") orelse
        return error.UseHyprhandPreview;

    c.g_set_prgname(try allocator.dupeSentinel(u8, app_id, 0));
    c.g_set_application_name("Hyprhand · Session preview");
    if (c.gtk_init_check() == 0) return error.PreviewDisplayUnavailable;
    main_load_css();
    const ui = try build_ui(allocator, argv[2]);
    const motion = c.gtk_event_controller_motion_new();
    c.gtk_widget_add_controller(@ptrCast(ui.window), motion);
    state = .{
        .cli = try allocator.dupeSentinel(u8, argv[1], 0),
        .session = try allocator.dupeSentinel(u8, argv[2], 0),
        .instance = try allocator.dupeSentinel(u8, argv[3], 0),
        .monitor = try allocator.dupeSentinel(u8, argv[4], 0),
        .window = ui.window,
        .motion = @ptrCast(motion),
        .loop = c.g_main_loop_new(null, 0).?,
        .picture = ui.picture,
        .status = ui.status,
        .stop = ui.stop,
        .cadence = .{ .interval_ms = @intCast((1000 + fps - 1) / fps) },
        .metrics = if (init.environ_map.get("HYPRHAND_PIP_METRICS")) |value|
            std.mem.eql(u8, value, "1")
        else
            false,
        .metrics_started = now(),
        .metrics_emitted = now(),
    };
    main_connect_signals(ui, motion);
    const interrupt = c.g_unix_signal_add(c.SIGINT, quit, null);
    const terminate = c.g_unix_signal_add(c.SIGTERM, quit, null);
    const timer = c.g_timeout_add(25, tick, null);
    // Mapping respects no_initial_focus; present() would request activation.
    c.gtk_widget_set_visible(@ptrCast(ui.window), 1);
    if (state.metrics) main_enable_metrics(ui.window);

    _ = tick(null);
    c.g_main_loop_run(state.loop);

    _ = c.g_source_remove(timer);
    _ = c.g_source_remove(interrupt);
    _ = c.g_source_remove(terminate);
    c.gtk_window_destroy(ui.window);
    if (state.png) |png| c.g_bytes_unref(png);
    if (state.texture) |texture| c.g_object_unref(texture);
    c.g_main_loop_unref(state.loop);
}

fn main_load_css() void {
    const style = c.gtk_css_provider_new();
    c.gtk_css_provider_load_from_string(style, css);
    c.gtk_style_context_add_provider_for_display(
        c.gdk_display_get_default(),
        @ptrCast(style),
        c.GTK_STYLE_PROVIDER_PRIORITY_USER,
    );
    c.g_object_unref(style);
}

fn main_connect_signals(ui: Ui, motion: ?*c.GtkEventController) void {
    signal_connect(motion, "notify::contains-pointer", @ptrCast(&pointer_changed), null);
    signal_connect(ui.window, "notify::is-active", @ptrCast(&active_changed), null);
    const keys = c.gtk_event_controller_key_new();
    c.gtk_event_controller_set_propagation_phase(keys, c.GTK_PHASE_CAPTURE);
    signal_connect(keys, "key-pressed", @ptrCast(&key_pressed), null);
    c.gtk_widget_add_controller(@ptrCast(ui.window), keys);
    signal_connect(ui.window, "close-request", @ptrCast(&close_requested), null);
    signal_connect(ui.stop, "clicked", @ptrCast(&stop_clicked), null);
    signal_connect(ui.close, "clicked", @ptrCast(&close_clicked), null);
}

fn main_enable_metrics(window: *c.GtkWindow) void {
    const flags = c.fcntl(c.STDOUT_FILENO, c.F_GETFL);
    const nonblocking = flags >= 0 and
        c.fcntl(c.STDOUT_FILENO, c.F_SETFL, flags | c.O_NONBLOCK) >= 0;
    if (!nonblocking) state.metrics = false;

    state.clock = c.gtk_widget_get_frame_clock(@ptrCast(window));
    if (state.clock) |clock| {
        signal_connect(clock, "after-paint", @ptrCast(&after_paint), null);
    }
}
