/* Small ABI bridge: keep GLib inline macros out of Zig's C translator. */
#include "accessibility.h"
#include <atspi/atspi.h>
#include <string.h>

static char last_error[512];

int desk_a11y_init(void) { atspi_set_timeout(150, 300); return atspi_init(); }
int desk_a11y_init_timeout(int method_ms) {
    atspi_set_timeout(method_ms, method_ms * 2);
    return atspi_init();
}
void desk_a11y_exit(void) { atspi_exit(); }
DeskNode *desk_a11y_desktop(void) { return (DeskNode *)atspi_get_desktop(0); }
void desk_a11y_unref(DeskNode *node) { if (node) g_object_unref(node); }
DeskNode *desk_a11y_ref(DeskNode *node) { return (DeskNode *)g_object_ref(node); }
void desk_a11y_free(char *value) { g_free(value); }
int desk_a11y_count(DeskNode *node) { return atspi_accessible_get_child_count((AtspiAccessible *)node, NULL); }
DeskNode *desk_a11y_child(DeskNode *node, int i) { return (DeskNode *)atspi_accessible_get_child_at_index((AtspiAccessible *)node, i, NULL); }
DeskNode *desk_a11y_parent(DeskNode *node) { return (DeskNode *)atspi_accessible_get_parent((AtspiAccessible *)node, NULL); }
int desk_a11y_index_in_parent(DeskNode *node) { return atspi_accessible_get_index_in_parent((AtspiAccessible *)node, NULL); }
unsigned int desk_a11y_pid(DeskNode *node) { return atspi_accessible_get_process_id((AtspiAccessible *)node, NULL); }
/* clear_cache_single needs libatspi 2.52; clear_cache (this node and the
 * children it has cached) works on every supported release. */
void desk_a11y_refresh(DeskNode *node) { atspi_accessible_clear_cache((AtspiAccessible *)node); }

static const struct { AtspiStateType state; unsigned int bit; } state_bits[] = {
    {ATSPI_STATE_ENABLED, DESK_STATE_ENABLED},
    {ATSPI_STATE_FOCUSABLE, DESK_STATE_FOCUSABLE},
    {ATSPI_STATE_FOCUSED, DESK_STATE_FOCUSED},
    {ATSPI_STATE_CHECKABLE, DESK_STATE_CHECKABLE},
    {ATSPI_STATE_CHECKED, DESK_STATE_CHECKED},
    {ATSPI_STATE_INDETERMINATE, DESK_STATE_INDETERMINATE},
    {ATSPI_STATE_PRESSED, DESK_STATE_PRESSED},
    {ATSPI_STATE_EXPANDABLE, DESK_STATE_EXPANDABLE},
    {ATSPI_STATE_EXPANDED, DESK_STATE_EXPANDED},
    {ATSPI_STATE_SELECTABLE, DESK_STATE_SELECTABLE},
    {ATSPI_STATE_SELECTED, DESK_STATE_SELECTED},
    {ATSPI_STATE_EDITABLE, DESK_STATE_EDITABLE},
    {ATSPI_STATE_SHOWING, DESK_STATE_SHOWING},
    {ATSPI_STATE_VISIBLE, DESK_STATE_VISIBLE},
    {ATSPI_STATE_READ_ONLY, DESK_STATE_READ_ONLY},
    {ATSPI_STATE_SENSITIVE, DESK_STATE_SENSITIVE},
};

unsigned int desk_a11y_states(DeskNode *node) {
    AtspiStateSet *set = atspi_accessible_get_state_set((AtspiAccessible *)node);
    if (!set) return 0;
    unsigned int bits = 0;
    for (size_t i = 0; i < sizeof(state_bits) / sizeof(state_bits[0]); i++)
        if (atspi_state_set_contains(set, state_bits[i].state)) bits |= state_bits[i].bit;
    g_object_unref(set);
    return bits;
}

/* atspi_accessible_is_* needs libatspi 2.56; the get_*_iface accessors answer
 * the same question from the same cached interface list on older releases. */
#define DESK_HAS_IFACE(obj, getter, bit, bits)          \
    do {                                                \
        GObject *iface = (GObject *)getter(obj);        \
        if (iface) { (bits) |= (bit); g_object_unref(iface); } \
    } while (0)

static unsigned int interfaces(AtspiAccessible *obj) {
    unsigned int bits = 0;
    DESK_HAS_IFACE(obj, atspi_accessible_get_action_iface, DESK_IFACE_ACTION, bits);
    DESK_HAS_IFACE(obj, atspi_accessible_get_component_iface, DESK_IFACE_COMPONENT, bits);
    DESK_HAS_IFACE(obj, atspi_accessible_get_text_iface, DESK_IFACE_TEXT, bits);
    DESK_HAS_IFACE(obj, atspi_accessible_get_editable_text_iface, DESK_IFACE_EDITABLE_TEXT, bits);
    DESK_HAS_IFACE(obj, atspi_accessible_get_value_iface, DESK_IFACE_VALUE, bits);
    DESK_HAS_IFACE(obj, atspi_accessible_get_selection_iface, DESK_IFACE_SELECTION, bits);
    return bits;
}

static int extents(AtspiComponent *component, AtspiCoordType type, DeskRect *out) {
    AtspiRect *rect = atspi_component_get_extents(component, type, NULL);
    if (!rect) return 0;
    *out = (DeskRect){rect->x, rect->y, rect->width, rect->height};
    g_free(rect);
    return 1;
}

void desk_a11y_info(DeskNode *node, DeskInfo *info) {
    memset(info, 0, sizeof(*info));
    AtspiAccessible *obj = (AtspiAccessible *)node;
    info->protected_value = atspi_accessible_get_role(obj, NULL) == ATSPI_ROLE_PASSWORD_TEXT;
    if (!info->protected_value) info->name = atspi_accessible_get_name(obj, NULL);
    info->role = atspi_accessible_get_role_name(obj, NULL);
    info->description = atspi_accessible_get_description(obj, NULL);
    info->accessible_id = atspi_accessible_get_accessible_id(obj, NULL);
    info->pid = desk_a11y_pid(node);
    info->states = desk_a11y_states(node);
    info->focused = (info->states & DESK_STATE_FOCUSED) != 0;
    info->interfaces = interfaces(obj);
    AtspiAction *action = atspi_accessible_get_action_iface(obj);
    if (action) { info->action_count = atspi_action_get_n_actions(action, NULL); g_object_unref(action); }
    AtspiComponent *component = atspi_accessible_get_component_iface(obj);
    if (component) {
        info->has_bounds = extents(component, ATSPI_COORD_TYPE_SCREEN, &info->bounds);
        info->has_window_bounds = extents(component, ATSPI_COORD_TYPE_WINDOW, &info->window_bounds);
        g_object_unref(component);
    }
}
void desk_a11y_info_free(DeskInfo *info) {
    g_free(info->name);
    g_free(info->role);
    g_free(info->description);
    g_free(info->accessible_id);
}

char *desk_a11y_action_name(DeskNode *node, int index) {
    AtspiAction *action = atspi_accessible_get_action_iface((AtspiAccessible *)node);
    if (!action) return NULL;
    char *name = atspi_action_get_action_name(action, index, NULL);
    g_object_unref(action);
    return name;
}

char *desk_a11y_toolkit(DeskNode *node) {
    return atspi_accessible_get_toolkit_name((AtspiAccessible *)node, NULL);
}

int desk_a11y_text_length(DeskNode *node) {
    AtspiText *text = atspi_accessible_get_text_iface((AtspiAccessible *)node);
    if (!text) return -1;
    int count = atspi_text_get_character_count(text, NULL);
    g_object_unref(text);
    return count;
}

char *desk_a11y_text(DeskNode *node, int limit_chars) {
    AtspiText *text = atspi_accessible_get_text_iface((AtspiAccessible *)node);
    if (!text) return NULL;
    int count = atspi_text_get_character_count(text, NULL);
    char *value = NULL;
    if (count >= 0) value = atspi_text_get_text(text, 0, count < limit_chars ? count : limit_chars, NULL);
    g_object_unref(text);
    return value;
}

int desk_a11y_value(DeskNode *node, double *current, double *minimum, double *maximum,
                    double *increment) {
    AtspiValue *value = atspi_accessible_get_value_iface((AtspiAccessible *)node);
    if (!value) return 0;
    *current = atspi_value_get_current_value(value, NULL);
    *minimum = atspi_value_get_minimum_value(value, NULL);
    *maximum = atspi_value_get_maximum_value(value, NULL);
    *increment = atspi_value_get_minimum_increment(value, NULL);
    g_object_unref(value);
    return 1;
}

/* libatspi reports D-Bus failures as text, without a stable code: classify
 * by message. Anything unrecognised after a call was sent stays uncertain,
 * except an error reply with no text at all: GTK 4 answers methods it does
 * not implement (GrabFocus, ScrollTo) with G_IO_ERROR_NOT_SUPPORTED and an
 * empty message, while a lost or late reply always carries libdbus's text. */
static int classify(gboolean answer, GError *error) {
    if (!error) {
        last_error[0] = 0;
        return answer ? DESK_OK : DESK_FALSE;
    }
    g_strlcpy(last_error, error->message ? error->message : "", sizeof(last_error));
    if (last_error[0] == 0) {
        g_strlcpy(last_error, "error reply without a message (not supported)", sizeof(last_error));
        g_error_free(error);
        return DESK_UNSUPPORTED;
    }
    const char *gone[] = {"Unknown object", "UnknownObject", "no owner", "not provided by",
                          "ServiceUnknown", "does not exist"};
    const char *unsupported[] = {"nknown method", "No such method", "UnknownMethod",
                                 "nknown interface", "UnknownInterface", "not supported",
                                 "NotSupported", "No such interface", "doesn't exist"};
    int result = DESK_UNCERTAIN;
    for (size_t i = 0; i < sizeof(gone) / sizeof(gone[0]); i++)
        if (strstr(last_error, gone[i])) result = DESK_GONE;
    for (size_t i = 0; i < sizeof(unsupported) / sizeof(unsupported[0]); i++)
        if (strstr(last_error, unsupported[i])) result = DESK_UNSUPPORTED;
    g_error_free(error);
    return result;
}

const char *desk_a11y_last_error(void) { return last_error; }

int desk_a11y_do_action(DeskNode *node, int index) {
    AtspiAction *action = atspi_accessible_get_action_iface((AtspiAccessible *)node);
    if (!action) return DESK_UNSUPPORTED;
    GError *error = NULL;
    gboolean answer = atspi_action_do_action(action, index, &error);
    g_object_unref(action);
    return classify(answer, error);
}

int desk_a11y_grab_focus(DeskNode *node) {
    AtspiComponent *component = atspi_accessible_get_component_iface((AtspiAccessible *)node);
    if (!component) return DESK_UNSUPPORTED;
    GError *error = NULL;
    gboolean answer = atspi_component_grab_focus(component, &error);
    g_object_unref(component);
    return classify(answer, error);
}

int desk_a11y_scroll_to(DeskNode *node) {
    AtspiComponent *component = atspi_accessible_get_component_iface((AtspiAccessible *)node);
    if (!component) return DESK_UNSUPPORTED;
    GError *error = NULL;
    gboolean answer = atspi_component_scroll_to(component, ATSPI_SCROLL_ANYWHERE, &error);
    g_object_unref(component);
    return classify(answer, error);
}

int desk_a11y_set_text_contents(DeskNode *node, const char *text) {
    AtspiEditableText *editable = atspi_accessible_get_editable_text_iface((AtspiAccessible *)node);
    if (!editable) return DESK_UNSUPPORTED;
    GError *error = NULL;
    gboolean answer = atspi_editable_text_set_text_contents(editable, text, &error);
    g_object_unref(editable);
    return classify(answer, error);
}

int desk_a11y_replace_text(DeskNode *node, const char *text, int length) {
    AtspiEditableText *editable = atspi_accessible_get_editable_text_iface((AtspiAccessible *)node);
    if (!editable) return DESK_UNSUPPORTED;
    int count = desk_a11y_text_length(node);
    GError *error = NULL;
    gboolean answer = TRUE;
    if (count > 0) answer = atspi_editable_text_delete_text(editable, 0, count, &error);
    int result = classify(answer, error);
    if (result == DESK_OK) {
        error = NULL;
        answer = atspi_editable_text_insert_text(editable, 0, text, length, &error);
        result = classify(answer, error);
        /* The deletion already changed the text: an unsupported insert is not
         * "nothing happened", so it must not invite another attempt. */
        if (result == DESK_UNSUPPORTED) result = DESK_UNCERTAIN;
    }
    g_object_unref(editable);
    return result;
}

int desk_a11y_set_value(DeskNode *node, double value) {
    AtspiValue *iface = atspi_accessible_get_value_iface((AtspiAccessible *)node);
    if (!iface) return DESK_UNSUPPORTED;
    GError *error = NULL;
    gboolean answer = atspi_value_set_current_value(iface, value, &error);
    g_object_unref(iface);
    return classify(answer, error);
}

int desk_a11y_select_child(DeskNode *parent, int index) {
    AtspiSelection *selection = atspi_accessible_get_selection_iface((AtspiAccessible *)parent);
    if (!selection) return DESK_UNSUPPORTED;
    GError *error = NULL;
    gboolean answer = atspi_selection_select_child(selection, index, &error);
    g_object_unref(selection);
    return classify(answer, error);
}
