/* Narrow GTK4 ABI used by Zig. GTK4's entire umbrella header currently crashes
 * Zig 0.16 translate-c. pip_gtk_check.c redeclares these same signatures against
 * installed upstream headers, so mismatches fail the optional build. No GTK
 * structures are accessed, and no hand-maintained struct layouts are used. */
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifndef HYPRHAND_PIP_ABI_CHECK
#define OPAQUE(T) typedef struct _##T T
OPAQUE(GtkWidget); OPAQUE(GtkWindow); OPAQUE(GtkBox);
OPAQUE(GtkPicture); OPAQUE(GtkLabel); OPAQUE(GtkButton); OPAQUE(GdkPaintable);
OPAQUE(GdkTexture); OPAQUE(GSubprocess); OPAQUE(GError); OPAQUE(GBytes);
OPAQUE(GMainLoop); OPAQUE(GMainContext); OPAQUE(GObject); OPAQUE(GAsyncResult);
OPAQUE(GCancellable); OPAQUE(GClosure);
OPAQUE(GtkOverlay); OPAQUE(GtkWindowHandle); OPAQUE(GtkCssProvider);
OPAQUE(GtkStyleProvider); OPAQUE(GdkDisplay); OPAQUE(GtkDrawingArea);
OPAQUE(GtkGesture); OPAQUE(GtkGestureClick); OPAQUE(GtkEventController);
OPAQUE(GtkNative); OPAQUE(GdkSurface); OPAQUE(GdkToplevel); OPAQUE(GdkDevice);
OPAQUE(GdkEvent);
OPAQUE(GTask); OPAQUE(GInputStream); OPAQUE(GOutputStream);
OPAQUE(GdkFrameClock); OPAQUE(GdkFrameTimings);
OPAQUE(GtkEventControllerMotion); OPAQUE(GParamSpec);
OPAQUE(GtkEventControllerKey);
typedef struct _cairo cairo_t;
#undef OPAQUE
typedef int gboolean;
typedef unsigned int guint;
typedef int64_t gint64;
typedef size_t gsize;
typedef unsigned long gulong;
typedef unsigned int GConnectFlags;
typedef unsigned int GSubprocessFlags;
typedef unsigned int GtkOrientation;
typedef unsigned int GtkContentFit;
typedef unsigned int GtkAlign;
typedef unsigned int PangoEllipsizeMode;
typedef unsigned int GdkSurfaceEdge;
typedef unsigned int GtkEventSequenceState;
typedef unsigned int GtkPropagationPhase;
typedef unsigned int GdkModifierType;
typedef void (*GDestroyNotify)(void *);
typedef void (*GtkDrawingAreaDrawFunc)(GtkDrawingArea *, cairo_t *, int, int, void *);
typedef void (*GCallback)(void);
typedef void (*GClosureNotify)(void *, GClosure *);
typedef gboolean (*GSourceFunc)(void *);
typedef void (*GAsyncReadyCallback)(GObject *, GAsyncResult *, void *);
typedef void (*GTaskThreadFunc)(GTask *, void *, void *, GCancellable *);
#define GTK_ORIENTATION_HORIZONTAL 0
#define GTK_ORIENTATION_VERTICAL 1
#define GTK_CONTENT_FIT_CONTAIN 1
#define G_SUBPROCESS_FLAGS_STDOUT_PIPE 4
#define G_SUBPROCESS_FLAGS_STDOUT_SILENCE 8
#define G_SUBPROCESS_FLAGS_STDIN_PIPE 1
#define G_SUBPROCESS_FLAGS_STDERR_SILENCE 32
#define G_SOURCE_CONTINUE 1
#define G_SOURCE_REMOVE 0
#define GTK_ALIGN_FILL 0
#define GTK_ALIGN_END 2
#define GTK_ALIGN_START 1
#define PANGO_ELLIPSIZE_END 3
#define GDK_SURFACE_EDGE_SOUTH_EAST 7
#define GTK_EVENT_SEQUENCE_CLAIMED 1
#define GTK_PHASE_CAPTURE 1
#define GDK_KEY_Tab 0xff09
#define GDK_KEY_ISO_Left_Tab 0xfe20
#else
_Static_assert(GTK_ORIENTATION_HORIZONTAL == 0 && GTK_ORIENTATION_VERTICAL == 1, "orientation ABI");
_Static_assert(GTK_CONTENT_FIT_CONTAIN == 1, "fit ABI");
_Static_assert(G_SUBPROCESS_FLAGS_STDOUT_PIPE == 4 && G_SUBPROCESS_FLAGS_STDERR_SILENCE == 32, "subprocess ABI");
_Static_assert(GTK_ALIGN_END == 2 && GTK_ALIGN_START == 1 && PANGO_ELLIPSIZE_END == 3, "layout ABI");
_Static_assert(GDK_SURFACE_EDGE_SOUTH_EAST == 7 && GTK_EVENT_SEQUENCE_CLAIMED == 1, "resize ABI");
_Static_assert(GTK_PHASE_CAPTURE == 1 && GDK_KEY_Tab == 0xff09 && GDK_KEY_ISO_Left_Tab == 0xfe20, "keyboard controller ABI");
#endif
gboolean gtk_init_check(void);
GtkWidget *gtk_window_new(void);
void gtk_window_set_title(GtkWindow *, const char *);
void gtk_window_set_default_size(GtkWindow *, int, int);
void gtk_window_set_decorated(GtkWindow *, gboolean);
void gtk_window_set_child(GtkWindow *, GtkWidget *);
void gtk_window_destroy(GtkWindow *);
gboolean gtk_window_is_active(GtkWindow *);
GtkWidget *gtk_label_new(const char *);
void gtk_label_set_text(GtkLabel *, const char *);
void gtk_label_set_xalign(GtkLabel *, float);
void gtk_label_set_wrap(GtkLabel *, gboolean);
void gtk_label_set_ellipsize(GtkLabel *, PangoEllipsizeMode);
void gtk_label_set_lines(GtkLabel *, int);
GtkWidget *gtk_box_new(GtkOrientation, int);
void gtk_box_append(GtkBox *, GtkWidget *);
GtkWidget *gtk_picture_new(void);
void gtk_picture_set_content_fit(GtkPicture *, GtkContentFit);
void gtk_picture_set_can_shrink(GtkPicture *, gboolean);
void gtk_picture_set_alternative_text(GtkPicture *, const char *);
void gtk_picture_set_paintable(GtkPicture *, GdkPaintable *);
GtkWidget *gtk_button_new_with_label(const char *);
GtkWidget *gtk_button_new_from_icon_name(const char *);
GtkWidget *gtk_overlay_new(void);
void gtk_overlay_set_child(GtkOverlay *, GtkWidget *);
void gtk_overlay_add_overlay(GtkOverlay *, GtkWidget *);
GtkWidget *gtk_window_handle_new(void);
void gtk_window_handle_set_child(GtkWindowHandle *, GtkWidget *);
GtkCssProvider *gtk_css_provider_new(void);
void gtk_css_provider_load_from_data(GtkCssProvider *, const char *, ptrdiff_t);
void gtk_style_context_add_provider_for_display(GdkDisplay *, GtkStyleProvider *, guint);
GdkDisplay *gdk_display_get_default(void);
void gtk_widget_set_halign(GtkWidget *, GtkAlign);
void gtk_widget_set_valign(GtkWidget *, GtkAlign);
void gtk_widget_set_cursor_from_name(GtkWidget *, const char *);
GtkWidget *gtk_drawing_area_new(void);
void gtk_drawing_area_set_draw_func(GtkDrawingArea *, GtkDrawingAreaDrawFunc, void *, GDestroyNotify);
void cairo_set_source_rgba(cairo_t *, double, double, double, double);
void cairo_set_line_width(cairo_t *, double);
void cairo_move_to(cairo_t *, double, double);
void cairo_line_to(cairo_t *, double, double);
void cairo_stroke(cairo_t *);
GtkGesture *gtk_gesture_click_new(void);
gboolean gtk_gesture_set_state(GtkGesture *, GtkEventSequenceState);
void gtk_widget_add_controller(GtkWidget *, GtkEventController *);
GtkEventController *gtk_event_controller_motion_new(void);
gboolean gtk_event_controller_motion_contains_pointer(GtkEventControllerMotion *);
GtkEventController *gtk_event_controller_key_new(void);
void gtk_event_controller_set_propagation_phase(GtkEventController *, GtkPropagationPhase);
GdkEvent *gtk_event_controller_get_current_event(GtkEventController *);
GdkDevice *gtk_event_controller_get_current_event_device(GtkEventController *);
uint32_t gtk_event_controller_get_current_event_time(GtkEventController *);
gboolean gdk_event_get_position(GdkEvent *, double *, double *);
GdkSurface *gtk_native_get_surface(GtkNative *);
void gdk_toplevel_begin_resize(GdkToplevel *, GdkSurfaceEdge, GdkDevice *, int, double, double, uint32_t);
void gtk_widget_set_size_request(GtkWidget *, int, int);
void gtk_widget_set_hexpand(GtkWidget *, gboolean);
void gtk_widget_set_vexpand(GtkWidget *, gboolean);
void gtk_widget_set_sensitive(GtkWidget *, gboolean);
void gtk_widget_set_visible(GtkWidget *, gboolean);
void gtk_widget_set_tooltip_text(GtkWidget *, const char *);
void gtk_widget_add_css_class(GtkWidget *, const char *);
void gtk_widget_remove_css_class(GtkWidget *, const char *);
void gtk_widget_set_margin_start(GtkWidget *, int);
void gtk_widget_set_margin_end(GtkWidget *, int);
void gtk_widget_set_margin_top(GtkWidget *, int);
void gtk_widget_set_margin_bottom(GtkWidget *, int);
GdkTexture *gdk_texture_new_from_bytes(GBytes *, GError **);
void g_set_prgname(const char *);
void g_set_application_name(const char *);
GMainLoop *g_main_loop_new(GMainContext *, gboolean);
void g_main_loop_run(GMainLoop *);
void g_main_loop_quit(GMainLoop *);
void g_main_loop_unref(GMainLoop *);
guint g_timeout_add(guint, GSourceFunc, void *);
guint g_unix_signal_add(int, GSourceFunc, void *);
gboolean g_source_remove(guint);
gint64 g_get_monotonic_time(void);
gulong g_signal_connect_data(void *, const char *, GCallback, void *, GClosureNotify, GConnectFlags);
void g_object_unref(void *);
void *(g_object_ref)(void *);
void g_error_free(GError *);
GBytes *g_bytes_new(const void *, gsize);
GBytes *g_bytes_new_take(void *, gsize);
GBytes *g_bytes_new_from_bytes(GBytes *, gsize, gsize);
GBytes *g_bytes_ref(GBytes *);
gboolean g_bytes_equal(const void *, const void *);
void *g_try_malloc(gsize);
const void *g_bytes_get_data(GBytes *, gsize *);
void g_bytes_unref(GBytes *);
GSubprocess *g_subprocess_newv(const char *const *, GSubprocessFlags, GError **);
void g_subprocess_send_signal(GSubprocess *, int);
gboolean g_subprocess_wait(GSubprocess *, GCancellable *, GError **);
void g_subprocess_wait_async(GSubprocess *, GCancellable *, GAsyncReadyCallback, void *);
gboolean g_subprocess_wait_finish(GSubprocess *, GAsyncResult *, GError **);
void g_subprocess_force_exit(GSubprocess *);
GInputStream *g_subprocess_get_stdout_pipe(GSubprocess *);
GOutputStream *g_subprocess_get_stdin_pipe(GSubprocess *);
gboolean g_input_stream_read_all(GInputStream *, void *, gsize, gsize *, GCancellable *, GError **);
gboolean g_output_stream_write_all(GOutputStream *, const void *, gsize, gsize *, GCancellable *, GError **);
GCancellable *g_cancellable_new(void);
void g_cancellable_cancel(GCancellable *);
GTask *g_task_new(void *, GCancellable *, GAsyncReadyCallback, void *);
void g_task_set_task_data(GTask *, void *, GDestroyNotify);
void *g_task_get_task_data(GTask *);
void g_task_run_in_thread(GTask *, GTaskThreadFunc);
void g_task_return_boolean(GTask *, gboolean);
GdkFrameClock *gtk_widget_get_frame_clock(GtkWidget *);
gint64 gdk_frame_clock_get_frame_counter(GdkFrameClock *);
GdkFrameTimings *gdk_frame_clock_get_timings(GdkFrameClock *, gint64);
gboolean gdk_frame_timings_get_complete(GdkFrameTimings *);
gint64 gdk_frame_timings_get_presentation_time(GdkFrameTimings *);
gboolean g_subprocess_get_successful(GSubprocess *);
void g_subprocess_communicate_async(GSubprocess *, GBytes *, GCancellable *, GAsyncReadyCallback, void *);
gboolean g_subprocess_communicate_finish(GSubprocess *, GAsyncResult *, GBytes **, GBytes **, GError **);
