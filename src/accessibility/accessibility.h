#pragma once
typedef struct DeskNode DeskNode;
typedef struct { int x, y, width, height; } DeskRect;

/* State bits reported in DeskInfo.states. */
enum {
    DESK_STATE_ENABLED = 1 << 0,
    DESK_STATE_FOCUSABLE = 1 << 1,
    DESK_STATE_FOCUSED = 1 << 2,
    DESK_STATE_CHECKABLE = 1 << 3,
    DESK_STATE_CHECKED = 1 << 4,
    DESK_STATE_INDETERMINATE = 1 << 5,
    DESK_STATE_PRESSED = 1 << 6,
    DESK_STATE_EXPANDABLE = 1 << 7,
    DESK_STATE_EXPANDED = 1 << 8,
    DESK_STATE_SELECTABLE = 1 << 9,
    DESK_STATE_SELECTED = 1 << 10,
    DESK_STATE_EDITABLE = 1 << 11,
    DESK_STATE_SHOWING = 1 << 12,
    DESK_STATE_VISIBLE = 1 << 13,
    DESK_STATE_READ_ONLY = 1 << 14,
    DESK_STATE_SENSITIVE = 1 << 15,
};

/* Interface bits reported in DeskInfo.interfaces. */
enum {
    DESK_IFACE_ACTION = 1 << 0,
    DESK_IFACE_COMPONENT = 1 << 1,
    DESK_IFACE_TEXT = 1 << 2,
    DESK_IFACE_EDITABLE_TEXT = 1 << 3,
    DESK_IFACE_VALUE = 1 << 4,
    DESK_IFACE_SELECTION = 1 << 5,
};

/* Outcome of a call that may change the application. */
enum {
    DESK_OK = 1,           /* the application accepted the call */
    DESK_FALSE = 0,        /* the application answered and refused it */
    DESK_UNSUPPORTED = -1, /* the method or interface does not exist: try another */
    DESK_GONE = -2,        /* the object or application no longer exists */
    DESK_UNCERTAIN = -3,   /* sent, but no usable answer (timeout, unknown error) */
};

typedef struct {
    char *name, *role, *description, *accessible_id;
    unsigned int pid;
    int protected_value, focused, has_bounds;
    DeskRect bounds; /* screen coordinates as reported; unverified on Wayland */
    int has_window_bounds;
    DeskRect window_bounds; /* relative to the node's toplevel window */
    unsigned int states;
    unsigned int interfaces;
    int action_count;
} DeskInfo;

int desk_a11y_init(void);
/* Like desk_a11y_init with a longer per-call D-Bus timeout, for actions. */
int desk_a11y_init_timeout(int method_ms);
void desk_a11y_exit(void);
DeskNode *desk_a11y_desktop(void);
void desk_a11y_unref(DeskNode *);
/* A second reference to the same node. */
DeskNode *desk_a11y_ref(DeskNode *);
int desk_a11y_count(DeskNode *);
DeskNode *desk_a11y_child(DeskNode *, int);
DeskNode *desk_a11y_parent(DeskNode *);
int desk_a11y_index_in_parent(DeskNode *);
unsigned int desk_a11y_pid(DeskNode *);
void desk_a11y_info(DeskNode *, DeskInfo *);
void desk_a11y_info_free(DeskInfo *);
/* Re-reads state and text on the next query instead of using a cache. */
void desk_a11y_refresh(DeskNode *);
unsigned int desk_a11y_states(DeskNode *);
void desk_a11y_free(char *);
/* Owned strings; free with desk_a11y_free. NULL when absent. */
char *desk_a11y_action_name(DeskNode *, int index);
char *desk_a11y_toolkit(DeskNode *);
/* At most `limit_chars` characters of the node's text, or NULL. */
char *desk_a11y_text(DeskNode *, int limit_chars);
int desk_a11y_text_length(DeskNode *);
/* 1 when the node has a Value interface; fills the four numbers. */
int desk_a11y_value(DeskNode *, double *current, double *minimum, double *maximum,
                    double *increment);

/* The child of `node` at window coordinates (x, y), or NULL. */
DeskNode *desk_a11y_child_at_point(DeskNode *node, int x, int y);

int desk_a11y_do_action(DeskNode *, int index);
int desk_a11y_grab_focus(DeskNode *);
int desk_a11y_scroll_to(DeskNode *);
int desk_a11y_set_text_contents(DeskNode *, const char *text);
/* Deletes all text, then inserts `text` (`length` in the toolkit's units). */
int desk_a11y_replace_text(DeskNode *, const char *text, int length);
int desk_a11y_set_value(DeskNode *, double value);
int desk_a11y_select_child(DeskNode *parent, int index);
/* The message of the last failed call, or "" ; owned by the library. */
const char *desk_a11y_last_error(void);
