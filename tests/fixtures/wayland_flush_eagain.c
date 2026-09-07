/* Fault injection for private fake-Wayland tests only. Never installed. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>

int wl_display_flush(void *display) {
    static int injected;
    if (!injected) {
        injected = 1;
        errno = EAGAIN;
        return -1;
    }
    int (*real_flush)(void *) = dlsym(RTLD_NEXT, "wl_display_flush");
    if (!real_flush) { errno = EIO; return -1; }
    return real_flush(display);
}
