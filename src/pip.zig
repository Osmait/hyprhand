//! Optional GTK viewer. No virtual input devices, IPC dispatchers or enable path.
const std = @import("std");
const protocol = @import("preview_protocol.zig");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("pip_gtk.h");
    @cInclude("signal.h");
});

// Scoped to this process/window, independent of the owner's GTK theme.
// Scrims protect controls over both bright and dark captured applications.
const css = @embedFile("pip.css");

const State = struct {
    cli: [:0]const u8,
    session: [:0]const u8,
    instance: [:0]const u8,
    monitor: [:0]const u8,
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
};
var state: State = undefined;
fn now() i64 {
    return @divTrunc(c.g_get_monotonic_time(), 1000);
}
fn label(text: [*:0]const u8) void {
    c.gtk_label_set_text(state.status, text);
    c.gtk_widget_set_tooltip_text(@ptrCast(state.status), text);
}
fn lost() void {
    c.gtk_picture_set_paintable(state.picture, null);
    state.last_frame = 0;
    label(if (state.stop_failed) "Sin señal · No se pudo detener. Reintenta." else if (state.stop_confirmed) "Sin señal · Control detenido" else "Sin señal · Sesión cerrada, bloqueada o no disponible");
}

fn spawn(command: [*:0]const u8, frame: bool) ?*c.GSubprocess {
    const argv = [_:null]?[*:0]const u8{ state.cli, command, "--session", state.session, "--expected-instance", state.instance, if (frame) "--monitor" else null, if (frame) state.monitor.ptr else null };
    var err: ?*c.GError = null;
    const process = c.g_subprocess_newv(@ptrCast(&argv), c.G_SUBPROCESS_FLAGS_STDOUT_PIPE | c.G_SUBPROCESS_FLAGS_STDERR_SILENCE, &err);
    if (err) |e| c.g_error_free(e);
    return process;
}

fn frameDone(object: ?*c.GObject, result: ?*c.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
    const process: *c.GSubprocess = @ptrCast(object.?);
    defer c.g_object_unref(process);
    state.frame_process = null;
    var bytes: ?*c.GBytes = null;
    var err: ?*c.GError = null;
    const ok = c.g_subprocess_communicate_finish(process, result, &bytes, null, &err);
    defer if (err) |e| c.g_error_free(e);
    defer if (bytes) |b| c.g_bytes_unref(b);
    if (state.closing) return;
    state.retry_after = now() + 1000;
    if (ok == 0 or c.g_subprocess_get_successful(process) == 0 or bytes == null) return lost();
    var length: usize = 0;
    const data: [*]const u8 = @ptrCast(c.g_bytes_get_data(bytes.?, &length));
    const frame = protocol.decode(data[0..length], now()) catch return lost();
    const png = c.g_bytes_new(frame.png.ptr, frame.png.len);
    defer c.g_bytes_unref(png);
    const texture = c.gdk_texture_new_from_bytes(png, &err) orelse return lost();
    defer c.g_object_unref(texture);
    c.gtk_picture_set_paintable(state.picture, @ptrCast(texture));
    state.last_frame = frame.captured_ms;
    state.retry_after = 0;
    if (state.stop_confirmed and frame.captured_ms > state.stopped_at) state.stop_confirmed = !frame.enabled;
    // Frames that started before a successful stop must not overwrite its ack.
    const enabled = frame.enabled and !state.stop_confirmed;
    c.gtk_widget_set_sensitive(state.stop, @intFromBool(state.stop_process == null and enabled));
    label(if (state.stop_process != null) "Deteniendo control…" else if (state.stop_failed) "No se pudo detener · Reintenta" else if (enabled) "● En vivo · Control habilitado" else "● En vivo · Control detenido");
}

fn tick(_: ?*anyopaque) callconv(.c) c_int {
    if (state.closing) return c.G_SOURCE_REMOVE;
    if (state.last_frame != 0 and now() - state.last_frame > protocol.max_age_ms) lost();
    if (state.frame_process) |process| {
        if (now() - state.capture_started > 5000) c.g_subprocess_send_signal(process, c.SIGTERM);
    } else if (now() >= state.retry_after) {
        state.capture_started = now();
        state.frame_process = spawn("_preview_frame", true);
        if (state.frame_process) |process| {
            c.g_subprocess_communicate_async(process, null, null, frameDone, null);
        } else {
            state.retry_after = now() + 1000;
            lost();
        }
    }
    return c.G_SOURCE_CONTINUE;
}

fn stopDone(object: ?*c.GObject, result: ?*c.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
    const process: *c.GSubprocess = @ptrCast(object.?);
    defer c.g_object_unref(process);
    state.stop_process = null;
    var err: ?*c.GError = null;
    var bytes: ?*c.GBytes = null;
    const ok = c.g_subprocess_communicate_finish(process, result, &bytes, null, &err);
    defer if (err) |e| c.g_error_free(e);
    defer if (bytes) |b| c.g_bytes_unref(b);
    if (state.closing) return;
    state.stop_confirmed = ok != 0 and c.g_subprocess_get_successful(process) != 0;
    if (state.stop_confirmed) state.stopped_at = now();
    state.stop_failed = !state.stop_confirmed;
    c.gtk_widget_set_sensitive(state.stop, @intFromBool(state.stop_failed));
    label(if (state.stop_failed) "No se pudo detener · Reintenta" else "Control detenido · Aplicaciones abiertas");
}

fn stopClicked(_: ?*c.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (state.stop_process != null or state.closing) return;
    state.stop_failed = false;
    state.stop_confirmed = false;
    label("Deteniendo control…");
    c.gtk_widget_set_sensitive(state.stop, 0);
    state.stop_process = spawn("_preview_stop", false);
    if (state.stop_process) |process| {
        c.g_subprocess_communicate_async(process, null, null, stopDone, null);
    } else {
        state.stop_failed = true;
        label("No se pudo detener · Reintenta");
        c.gtk_widget_set_sensitive(state.stop, 1);
    }
}

fn quit(_: ?*anyopaque) callconv(.c) c_int {
    state.closing = true;
    c.g_main_loop_quit(state.loop);
    return c.G_SOURCE_CONTINUE;
}
fn closeRequested(_: ?*c.GtkWindow, _: ?*anyopaque) callconv(.c) c_int {
    _ = quit(null);
    return 1;
}
fn closeClicked(_: ?*c.GtkButton, _: ?*anyopaque) callconv(.c) void {
    _ = quit(null);
}
fn drawGrip(_: ?*c.GtkDrawingArea, cr: ?*c.cairo_t, _: c_int, _: c_int, _: ?*anyopaque) callconv(.c) void {
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.75);
    c.cairo_set_line_width(cr, 1.5);
    c.cairo_move_to(cr, 9, 23);
    c.cairo_line_to(cr, 23, 9);
    c.cairo_move_to(cr, 16, 23);
    c.cairo_line_to(cr, 23, 16);
    c.cairo_stroke(cr);
}
fn resizePressed(gesture: ?*c.GtkGestureClick, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
    const controller: *c.GtkEventController = @ptrCast(gesture.?);
    const event = c.gtk_event_controller_get_current_event(controller) orelse return;
    const device = c.gtk_event_controller_get_current_event_device(controller) orelse return;
    const surface = c.gtk_native_get_surface(@ptrCast(data.?)) orelse return;
    var x: f64 = 0;
    var y: f64 = 0;
    if (c.gdk_event_get_position(event, &x, &y) == 0) return;
    _ = c.gtk_gesture_set_state(@ptrCast(gesture.?), c.GTK_EVENT_SEQUENCE_CLAIMED);
    c.gdk_toplevel_begin_resize(@ptrCast(surface), c.GDK_SURFACE_EDGE_SOUTH_EAST, device, 1, x, y, c.gtk_event_controller_get_current_event_time(controller));
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len != 6) return error.UseDeskctlPreview;
    const fps = try std.fmt.parseInt(u32, argv[5], 10);
    if (fps < 1 or fps > 15) return error.InvalidPreviewFps;
    const app_id = init.environ_map.get("DESKCTL_PIP_APP_ID") orelse return error.UseDeskctlPreview;
    c.g_set_prgname(try a.dupeZ(u8, app_id));
    c.g_set_application_name("deskctl · Vista de sesión");
    if (c.gtk_init_check() == 0) return error.PreviewDisplayUnavailable;
    const style = c.gtk_css_provider_new();
    c.gtk_css_provider_load_from_data(style, css, css.len);
    c.gtk_style_context_add_provider_for_display(c.gdk_display_get_default(), @ptrCast(style), 800);
    c.g_object_unref(style);
    const window: *c.GtkWindow = @ptrCast(c.gtk_window_new());
    c.gtk_window_set_title(window, try std.fmt.allocPrintSentinel(a, "deskctl · {s}", .{argv[2]}, 0));
    c.gtk_window_set_default_size(window, 640, 360);
    c.gtk_widget_set_size_request(@ptrCast(window), 360, 203);
    c.gtk_window_set_decorated(window, 0);
    c.gtk_widget_add_css_class(@ptrCast(window), "deskctl-pip");
    const handle: *c.GtkWindowHandle = @ptrCast(c.gtk_window_handle_new());
    const overlay: *c.GtkOverlay = @ptrCast(c.gtk_overlay_new());
    const picture: *c.GtkPicture = @ptrCast(c.gtk_picture_new());
    c.gtk_picture_set_content_fit(picture, c.GTK_CONTENT_FIT_CONTAIN);
    c.gtk_picture_set_can_shrink(picture, 1);
    c.gtk_picture_set_alternative_text(picture, "Vista de la sesión del agente; no envía clics ni teclado");
    c.gtk_widget_set_hexpand(@ptrCast(picture), 1);
    c.gtk_widget_set_vexpand(@ptrCast(picture), 1);
    c.gtk_overlay_set_child(overlay, @ptrCast(picture));
    const header: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12));
    c.gtk_widget_add_css_class(@ptrCast(header), "pip-top");
    c.gtk_widget_set_valign(@ptrCast(header), c.GTK_ALIGN_START);
    const title: *c.GtkLabel = @ptrCast(c.gtk_label_new(try std.fmt.allocPrintSentinel(a, "{s} · Solo lectura", .{argv[2]}, 0)));
    c.gtk_label_set_xalign(title, 0);
    c.gtk_label_set_ellipsize(title, c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_set_hexpand(@ptrCast(title), 1);
    c.gtk_widget_set_tooltip_text(@ptrCast(title), try std.fmt.allocPrintSentinel(a, "{s} · Arrastra la imagen para mover el visor", .{argv[2]}, 0));
    const close = c.gtk_button_new_from_icon_name("window-close-symbolic").?;
    c.gtk_widget_add_css_class(close, "pip-close");
    c.gtk_widget_set_tooltip_text(close, "Cerrar visor (el agente continúa)");
    c.gtk_box_append(header, @ptrCast(title));
    c.gtk_box_append(header, close);
    c.gtk_overlay_add_overlay(overlay, @ptrCast(header));
    const footer: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 10));
    c.gtk_widget_set_valign(@ptrCast(footer), c.GTK_ALIGN_END);
    c.gtk_widget_add_css_class(@ptrCast(footer), "pip-bottom");
    const status: *c.GtkLabel = @ptrCast(c.gtk_label_new("Conectando…"));
    c.gtk_label_set_xalign(status, 0);
    c.gtk_label_set_wrap(status, 1);
    c.gtk_label_set_lines(status, 2);
    c.gtk_label_set_ellipsize(status, c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_set_hexpand(@ptrCast(status), 1);
    const stop = c.gtk_button_new_with_label("Detener agente").?;
    c.gtk_widget_add_css_class(stop, "destructive-action");
    c.gtk_widget_set_tooltip_text(stop, "Deshabilita la entrada de deskctl. No cierra las aplicaciones ni termina otros procesos del agente.");
    c.gtk_box_append(footer, @ptrCast(status));
    c.gtk_box_append(footer, stop);
    const grip = c.gtk_drawing_area_new().?;
    c.gtk_widget_set_size_request(grip, 32, 32);
    c.gtk_widget_set_valign(grip, c.GTK_ALIGN_END);
    c.gtk_widget_set_cursor_from_name(grip, "se-resize");
    c.gtk_widget_set_tooltip_text(grip, "Arrastra para cambiar tamaño; también puedes usar los atajos de Hyprland");
    c.gtk_drawing_area_set_draw_func(@ptrCast(grip), drawGrip, null, null);
    const resize = c.gtk_gesture_click_new();
    _ = c.g_signal_connect_data(resize, "pressed", @ptrCast(&resizePressed), window, null, 0);
    c.gtk_widget_add_controller(grip, @ptrCast(resize));
    c.gtk_box_append(footer, grip);
    c.gtk_overlay_add_overlay(overlay, @ptrCast(footer));
    c.gtk_window_handle_set_child(handle, @ptrCast(overlay));
    c.gtk_window_set_child(window, @ptrCast(handle));
    state = .{
        .cli = try a.dupeZ(u8, argv[1]),
        .session = try a.dupeZ(u8, argv[2]),
        .instance = try a.dupeZ(u8, argv[3]),
        .monitor = try a.dupeZ(u8, argv[4]),
        .loop = c.g_main_loop_new(null, 0).?,
        .picture = picture,
        .status = status,
        .stop = stop,
    };
    _ = c.g_signal_connect_data(window, "close-request", @ptrCast(&closeRequested), null, null, 0);
    _ = c.g_signal_connect_data(stop, "clicked", @ptrCast(&stopClicked), null, null, 0);
    _ = c.g_signal_connect_data(close, "clicked", @ptrCast(&closeClicked), null, null, 0);
    const interrupt = c.g_unix_signal_add(c.SIGINT, quit, null);
    const terminate = c.g_unix_signal_add(c.SIGTERM, quit, null);
    const timer = c.g_timeout_add(@max(66, 1000 / fps), tick, null);
    // Mapping respects no_initial_focus; present() would request activation.
    c.gtk_widget_set_visible(@ptrCast(window), 1);
    _ = tick(null);
    c.g_main_loop_run(state.loop);
    _ = c.g_source_remove(timer);
    _ = c.g_source_remove(interrupt);
    _ = c.g_source_remove(terminate);
    c.gtk_window_destroy(window);
    if (state.frame_process) |process| {
        c.g_subprocess_send_signal(process, c.SIGTERM);
        _ = c.g_subprocess_wait(process, null, null);
        c.g_object_unref(process);
    }
    // A stop already requested must finish even when the owner closes the PiP.
    if (state.stop_process) |process| {
        _ = c.g_subprocess_wait(process, null, null);
        c.g_object_unref(process);
    }
    c.g_main_loop_unref(state.loop);
}
