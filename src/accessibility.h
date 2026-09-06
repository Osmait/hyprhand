#pragma once
typedef struct DeskNode DeskNode;
typedef struct { int x, y, width, height; } DeskRect;
typedef struct {
    char *name, *role;
    unsigned int pid;
    int protected_value, focused, has_bounds;
    DeskRect bounds;
} DeskInfo;
int desk_a11y_init(void);
void desk_a11y_exit(void);
DeskNode *desk_a11y_desktop(void);
void desk_a11y_unref(DeskNode *);
int desk_a11y_count(DeskNode *);
DeskNode *desk_a11y_child(DeskNode *, int);
unsigned int desk_a11y_pid(DeskNode *);
void desk_a11y_info(DeskNode *, DeskInfo *);
void desk_a11y_info_free(DeskInfo *);
