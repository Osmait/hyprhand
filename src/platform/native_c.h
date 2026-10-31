/* C declarations imported by src/platform/native.zig through build-time
 * translate-c (Zig 0.17 removed @cImport).
 * glibc's fortify inline wrappers use GCC-only diagnostics that translate-c
 * cannot import. Use plain libc declarations here; Zig callers retain
 * ReleaseSafe bounds/overflow checks. Native libraries are unchanged. */
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0
#define _GNU_SOURCE 1
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/syscall.h>
#include <sys/random.h>
#include <sys/prctl.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <dirent.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "virtual-pointer.h"
#include "virtual-keyboard.h"
#include "layer-shell.h"
#include "ext-image-copy-capture-v1.h"
#include "ext-image-capture-source-v1.h"
