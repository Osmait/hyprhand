/* Small ABI bridge: keep GLib inline macros out of Zig's C translator. */
#include "accessibility.h"
#include <atspi/atspi.h>
#include <string.h>
int desk_a11y_init(void) { atspi_set_timeout(150, 300); return atspi_init(); }
void desk_a11y_exit(void) { atspi_exit(); }
DeskNode *desk_a11y_desktop(void) { return (DeskNode *)atspi_get_desktop(0); }
void desk_a11y_unref(DeskNode *node) { if (node) g_object_unref(node); }
int desk_a11y_count(DeskNode *node) { return atspi_accessible_get_child_count((AtspiAccessible *)node, NULL); }
DeskNode *desk_a11y_child(DeskNode *node, int i) { return (DeskNode *)atspi_accessible_get_child_at_index((AtspiAccessible *)node, i, NULL); }
unsigned int desk_a11y_pid(DeskNode *node) { return atspi_accessible_get_process_id((AtspiAccessible *)node, NULL); }
void desk_a11y_info(DeskNode *node, DeskInfo *info) {
    memset(info, 0, sizeof(*info));
    AtspiAccessible *obj = (AtspiAccessible *)node;
    info->protected_value = atspi_accessible_get_role(obj, NULL) == ATSPI_ROLE_PASSWORD_TEXT;
    if (!info->protected_value) info->name = atspi_accessible_get_name(obj, NULL);
    info->role = atspi_accessible_get_role_name(obj, NULL);
    info->pid = desk_a11y_pid(node);
    AtspiStateSet *states = atspi_accessible_get_state_set(obj);
    if (states) { info->focused = atspi_state_set_contains(states, ATSPI_STATE_FOCUSED); g_object_unref(states); }
    AtspiComponent *component = atspi_accessible_get_component_iface(obj);
    if (component) {
        AtspiRect *rect = atspi_component_get_extents(component, ATSPI_COORD_TYPE_SCREEN, NULL);
        if (rect) { info->has_bounds = 1; info->bounds = (DeskRect){rect->x, rect->y, rect->width, rect->height}; g_free(rect); }
        g_object_unref(component);
    }
}
void desk_a11y_info_free(DeskInfo *info) { g_free(info->name); g_free(info->role); }
