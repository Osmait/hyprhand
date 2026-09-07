# Host Picture-in-Picture

Build the CLI and the optional native Zig/GTK4 viewer:

```sh
zig build -Doptimize=ReleaseSafe
zig build pip -Doptimize=ReleaseSafe
zig-out/bin/hyprhand preview --session agent
# Explicit output and maximum frame frequency:
zig-out/bin/hyprhand preview --session agent --monitor HEADLESS-1 --fps 10
```

Requires an **existing, running managed session**, GTK4 >= 4.8 (headers and
pkg-config for building), and grim. Keep `hyprhand-pip` beside the matching
`hyprhand` binary. The default CLI build/archive does not depend on or include
GTK4. The optional build verifies its narrow FFI declarations against the
installed GTK headers; application and viewer logic remain Zig.

Supports **Hyprlang and Lua hosts** on the tested Hyprland 0.56.2 stack. Lua uses
a named `hl.window_rule` handle and bounded `set_enabled(false)` cleanup;
unknown providers fail before opening a window. The source may use either provider.
Only internally generated IDs enter Lua expressions, never session names or titles.
See the compositor's [window-rule API](https://wiki.hypr.land/configuring/core/rules/window-rules/).

## Behavior

- A borderless, movable, resizable GTK window lives on the host. Its image fills
  the window with status and controls overlaid on contrast-protecting scrims.
  Drag the image to move, drag the lower-right grip to resize, or use the
  compositor's normal move/resize bindings. It is floating and pinned across
  workspaces; fullscreen stacking remains subject to the compositor.
- No title bar, footer allocation, window border or shadow surrounds the image.
  Default size is 640 × 360, minimum 360 × 203. The source aspect ratio is
  preserved; mismatched window/source proportions can still cause letterboxing.
  Close and stop stay visible and keyboard-focusable. Truncated session/status
  text has its full description in a tooltip. Styles affect only this viewer.
- It does not request activation on opening or follow pointer hover. Clicking
  its controls can focus the viewer normally, but never forwards input to the
  source. The host's input authorization token is never enabled or changed.
- The image includes the source cursor, preserves aspect ratio and updates at
  up to 5 fps by default (configurable 1–15). Captures fit within 960 × 540;
  resizing the viewer does not increase source resolution. This is a monitoring
  preview, not full-frame-rate video streaming or a precise editing viewport.
  The configured rate is a maximum: repeated identical images progressively
  back off to one capture per second. Changed pixels restore the target rate;
  detecting activity after an idle period can therefore take up to one second.
- **Stop input** disables hyprhand input in that source. It cancels guarded
  hyprhand actions, not the model, shell jobs, rendering, or other automation
  that bypasses hyprhand. Applications remain open. There is no resume button.
- Closing the PiP or interrupting its foreground CLI closes **only the viewer**.
  Source applications and the input token remain unchanged. A stop already
  requested is allowed to complete during normal close.
- `Input enabled` describes permission, not proof that an agent is busy.
  Stop is acknowledged only after its worker succeeds. External authorized
  re-enabling is reflected by subsequent fresh frames; the viewer never enables.
- Disconnection, a locked source, invalid frames, or capture failure clear the
  image and show `No signal`. A two-second freshness limit prevents a frozen
  screenshot being labeled live. Retries are serialized, at most one per second
  after failure. A viewer never attaches to a recreated session of the same name:
  close it and explicitly open a new preview.

## Implementation and limits

The GTK process keeps the host environment. A persistent, demand-driven CLI
capture worker routes from the original owner environment on every request and
checks the original compositor identity both before and after capture. A separate
short-lived stop worker remains independent of capture. Frames
use bounded pipes, not screenshot/history files. Output is drained incrementally
and rejected at 8 MiB, before a faulty helper can grow an unbounded memory file.
Each grim invocation has a 1.5-second deadline and is reaped on cancellation.
Each complete capture request has a two-second cooperative budget. Headers, PNG dimensions,
byte size and monotonic timestamps are checked before GTK decodes an image.
There is no image input handler, virtual keyboard or pointer device in the viewer.

The private `_preview_stream` protocol accepts one `F` byte per request and
returns a little-endian u32 length followed by the existing DCP1 frame. Only one
request is in flight. The viewer validates the length before allocating memory,
and uses cancellable I/O and texture decoding in a GLib task, not the GTK main
loop. PNG slices share `GBytes` storage; identical PNGs reuse the previous
texture. The persistent worker releases per-request memory, exits on stdin EOF,
and stops after 30 seconds without requests. `grim` is still launched per capture.
See [GDK's thread-safe texture loading contract](https://docs.gtk.org/gdk4/class.Texture.html).

This implementation uses repeated compressed screenshots, not PipeWire or GPU
zero-copy streaming. Expect latency, GTK memory overhead and CPU usage that
increase with frame rate. Capture authorization and privacy obey the existing
session-lock checks; this is not a filesystem/credential sandbox.

The launcher adds a uniquely named, exact-class host rule for its own window.
It disables that rule on normal exit/failure without editing configuration files
or reloading the user's config. The inactive named entry lasts until the next
normal compositor config reload. SIGKILL/crashes of the launcher can leave its
rule enabled; it only matches that launcher's unique viewer class. Rules are not
a substitute for a compositor-level security boundary.

## Verification

```sh
zig build test integration
python3 tests/preview.py
zig build pip -Doptimize=ReleaseSafe
zig build pip-test -Doptimize=ReleaseSafe
# Optional real GTK callbacks on a private Broadway display, never the host:
python3 tests/viewer_broadway.py
```

Worker tests use fake IPC, managed metadata and disposable processes, without a
desktop: identity mismatch, missing outputs, lock-before/after capture, bounded
PNG, memory-only capture, timeout/cancel reaping, and stop-with-apps-alive.

Manual native checks on Hyprland 0.56.2 / GTK 4.22.4: live source text and cursor,
floating/pinned flags, unchanged Brave focus, 640 × 360 and 360 × 203 layouts,
viewer termination leaving source enabled, accessible stop disabling source
input with its application alive, and source destruction clearing the preview.
No claim of cross-distro GUI, high-DPI, fullscreen or sustained performance
coverage is made by these checks.

September follow-up: the same rule expression and viewer were checked in a
disposable Lua compositor: live source image, floating/pinned 640 × 360 window,
no initial focus, and explicit rule cleanup. The launcher path and signal cleanup
also pass a fake-Lua regression. This is not a full live launcher test on a user's
Lua host. Changing that disposable output to scale 1.5 / rotation 90° exposed an
unresolved compositor-placement issue: the existing floating window remained at
its old coordinates and was partially off-screen. Reopening the viewer or moving
it manually is necessary; automatic monitor-change repositioning is not implemented.

## Reproducible performance sampling

```sh
python3 scripts/benchmark_preview.py --live --session agent --seconds 120 --fps 5
```

This opt-in script opens/closes only its own host preview, never enables input,
and requires an existing managed source. It reports 30 standalone worker latency
samples, viewer RSS and CPU including live/reaped workers. Optional JSON telemetry
(`HYPRHAND_PIP_METRICS=1`) distinguishes received frames, new textures, GTK paints
and updates with confirmed GDK presentation timestamps. Unsupported presentation
feedback is reported as null, not zero FPS. An unchanged scene intentionally
has few visual updates. GPU/compositor CPU and total tree memory remain outside
this benchmark; /proc tree sampling has process-exit boundary noise. See
[the measured follow-up](audit-followup-2026-09.md) for results and remaining limits.

For a reproducible software-path soak without accessing any desktop:

```sh
python3 scripts/benchmark_viewer_offline.py --seconds 300
```

It requires `gtk4-broadwayd`, uses private Unix sockets and a synthetic static
PNG, and accepts up to 3600 seconds. Its results are **not** Hyprland/GPU latency
measurements. Current changes and offline comparisons are documented in
[the performance follow-up](performance-2026-09.md).

Borderless revision: verified over a room-image application at both new sizes,
with accessible close/stop labels and scoped border/shadow suppression. In a
separate disposable compositor, dragging the image changed the window position
and dragging the grip began resizing. The hyprhand frame guard then aborted each
automated drag when geometry changed, as intended; it was not weakened. Stop
through the overlay disabled only the source, left its two applications alive,
and left host authorization disabled. Closing the isolated viewer left the
source applications alive. The source and test compositor were then cleaned up.
