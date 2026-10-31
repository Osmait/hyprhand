# Host Picture-in-Picture

Build the CLI and the optional native Zig/GTK4 viewer:

```sh
zig build -Doptimize=ReleaseSafe
zig build pip -Doptimize=ReleaseSafe
zig-out/bin/hyprhand preview --session agent
# Explicit output and maximum frame frequency:
zig-out/bin/hyprhand preview --session agent --monitor HEADLESS-1 --fps 10
# Place the PiP on a specific host monitor:
zig-out/bin/hyprhand preview --session agent --host-monitor DP-1
```

`--monitor` names the **session's** monitor to show (`HEADLESS-1` for headless
sessions). `--host-monitor` names the host monitor where the PiP window opens;
it must exist on the host and contain only connector-name characters, because it
becomes part of the viewer's window rule.

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
  The session label, status, close/stop controls and resize grip appear while
  the pointer is anywhere over the viewer, and hide when it leaves. Keyboard
  navigation also reveals them while the window is active, preserving Tab access
  and visible focus. The idle viewer displays only the session image.
  Truncated session/status
  text has its full description in a tooltip. Styles affect only this viewer.
- It does not request activation on opening or follow pointer hover. Clicking
  its controls can focus the viewer normally. It forwards input to the source
  only during a human takeover (below). The host's input authorization token
  is never enabled or changed.
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

## Human takeover

Some steps belong to the human: signing in, a captcha, a second factor. **Take
over** lets the owner do them inside the session with their own mouse and
keyboard, without the agent ever seeing what they type.

- **Take over** (next to Stop input, available while the image is live) first
  stops agent control of that session, then forwards the human's pointer,
  buttons, scrolling and keys. While it lasts, agent input commands fail with
  `ControlStopped`, `enable` fails with `HumanTakeoverActive`, and
  `hyprhand state --session NAME` reports `"human_takeover": true` and
  `"control_enabled": false`. A second viewer cannot take over the same session.
- The viewer marks takeover with an amber frame and the status
  `You are in control · Agent paused`. The header hides and the controls become
  a solid bar below the image, so no part of the image is covered. Captures run
  at the 15 fps maximum without the idle back-off while the human is in control.
- Clicks start only on the image; letterbox bars are ignored, and a drag that
  leaves the image continues at its edge. Image coordinates are mapped onto the
  source monitor, accounting for the viewer's scale and letterbox offsets.
- Keys go to the session while the viewer has keyboard focus. Clicking Take over
  normally gives it focus despite the viewer's `no_initial_focus` and
  `no_follow_mouse` rules; if it did not, the viewer asks for activation once.
  Every key is forwarded, including Tab, Escape, Enter and shortcuts such as
  ctrl+a, ctrl+c and ctrl+v. Compositor bindings (for example Super shortcuts)
  stay with the host. When the viewer loses focus, held keys and buttons are
  released; click the image to continue.
- **Return** stops forwarding and gives control back **as it was taken**: if the
  agent had control when the human took over, it is enabled again with a new
  token; if input was already stopped, it stays stopped. The agent detects the
  change through `state` (`human_takeover: false`, `control_enabled: true`) and
  the audit log (`takeover` `started`, then `returned`). The viewer stops
  capturing keys; keyboard focus moves away when the human clicks elsewhere.
- Closing the viewer, a crash, the session locking, closing or being replaced,
  or a worker that stops reading all end the takeover **without** re-enabling the
  agent: closing is not consent to resume. Use `enable` deliberately afterwards.

Keys travel as one event each: the host's physical key code plus the symbol
GTK resolved for it, with the human's own layout, Shift, AltGr and Caps Lock
already applied. The worker resolves dead keys and Compose sequences with the
host user's Compose table (locale, `XCOMPOSEFILE`, `~/.XCompose`), then builds a
session keymap that gives each physical key its symbol with real Shift levels.
Shifted characters and non-ASCII text (é, ñ, Ñ) therefore type exactly as on the
host, and code and symbol can never be paired with a stale keymap. Host input
methods (IBus/Fcitx composition) are bypassed; keys with codes above XKB's 255
limit and sequences composing more than one symbol are not forwarded.

### Takeover security

- Typed keys are never logged, echoed, written to files, put in argv or sent to
  the agent. The audit log records only `takeover` with `started`, `returned`,
  `ended` or an error name.
- The private `_preview_input` worker accepts input only from a parent whose
  executable is the `hyprhand-pip` installed beside it, reading a pipe on stdin,
  so agents have no command that injects unguarded input. Like control tokens,
  this is a cooperative check, not a boundary against malicious same-user
  processes (see [SECURITY.md](../SECURITY.md)).
- The worker connects its devices before revoking control, so a setup failure
  leaves agent control unchanged. It then removes the token, waits for running
  agent actions to notice and exit, and only then reports ready.
- Every 250 ms, and before it reports ready, it re-routes the session from the
  original owner environment and requires the pinned compositor instance, an
  unlocked session and the selected monitor. It revokes any token that appears.
  Any failure ends the takeover with agent control stopped.
- `takeover.lock` in the session state directory is held by an open descriptor
  for the worker's lifetime, so a crash cannot leave a stale takeover.

## UI maintenance

The desktop owner monitors a managed session while continuing work on the host.
Keep the session image as the full window surface and preserve one-action access
to stop input. Close and stop must retain their distinct behavior described above.

`src/preview/pip.css` defines the scoped palette: dark canvas `#080c12`, white
labels, neutral controls `#121821`, muted red stop `#943546` and focus `#8ac4ff`.
Take over is blue `#24476b`; during takeover Return is amber `#8a5a12` and the
image carries a 2px `#e0a24a` frame.
Use the native font family with 12px labels and 6px button corners. Status uses
text as well as color. Session labels ellipsize; status wraps to at most two lines,
with complete text available in tooltips.

`GtkOverlay` places identity/close at the top and status/stop/resize at the bottom.
The top overlay has 10px top, 12px side and 24px bottom padding; the bottom uses
26px top, 10px right/bottom and 14px left padding with 10px control gaps. The resize
target is 32px, with two Cairo strokes. `GtkWindowHandle` provides image dragging.
Opacity changes reveal the overlays without changing image layout. Tab reveals
controls before focus traversal; pointer crossing or deactivation ends keyboard
reveal. Preserve native hit targets, accessibility and the visible focus outline.

Validate changes against the native GTK viewer with both bright and dark source
images, pointer entry/exit, keyboard navigation, move/resize, stop and close. Web
previews do not establish native behavior. The repository's internal design
metadata is maintained under `.impeccable/`.

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
The GTK process itself holds no virtual keyboard or pointer device; takeover input
goes through a separate worker, described below.

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

### Takeover transport

Take over starts one long-lived `_preview_input` worker with the same session,
pinned instance and monitor as the capture worker, on two private pipes created
by the viewer (close-on-exec, so no other child inherits them). The worker
replies with one byte: `R` once control is revoked and its virtual pointer and
keyboard exist, then `E` (control re-enabled) or `S` (stays stopped) after
Return. Any other byte is its JSON error report.

The viewer writes fixed-size little-endian records (`takeover_protocol.zig`):
`M` motion with a normalized u16 position in the frame, `B` button and state,
`S` scroll (wheel in 1/120 detents, or surface pixels in 1/256), `T` scroll stop,
`K` key (physical code, keysym, state), `A` release everything and `Q` Return.
Records are at most 10 bytes, below `PIPE_BUF`, and the event pipe is
non-blocking: a write that does not fit ends the takeover instead of blocking
GTK or queuing input without bound. The worker validates every record (known
tag, 0/1 flags, known buttons, key code ≤ 247, keysym range, bounded deltas) and
exits on the first invalid one. Its stdin buffer never holds more than one partial
record. EOF without `Q` is a close, not a Return.

Pointer positions use `zwlr_virtual_pointer_v1.motion_absolute` against the
bounding box of all enabled monitors, which is how Hyprland maps an unbound
virtual pointer. Wheel detents and continuous axes use the same requests as
`scroll`. Host key repeats are dropped; the session application repeats held
keys itself.

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
Takeover adds: the worker refuses any parent but `hyprhand-pip`, identity and
device failures leave control enabled, and `enable` is refused while
`takeover.lock` is held (`state` reports it). Zig unit tests cover record
encoding and validation, letterbox and absolute-motion mapping, Shift levels,
host repeats, shared modifiers, Compose sequences and full release.

Takeover was checked live on Hyprland 0.57 / GTK 4.24 with two disposable
headless sessions: the real viewer ran inside one of them, standing in for the
host, and showed the other, which ran the GTK note demo. Driving the stand-in
host with hyprhand: Take over revoked the source's control (`state` reported
the takeover, agent `key` failed with `ControlStopped`, `enable` with
`HumanTakeoverActive`, a second takeover with `TakeoverBusy`); clicks through
the letterboxed image landed on the entry; ctrl+a, `Contraseña é! Ñ#2`,
BackSpace, Tab and Enter typed and applied exactly; a drag selected text without
moving the viewer; Return re-enabled control, or kept it stopped when it had
been stopped; closing the viewer during takeover left control stopped. A
recorded stream checked dead-key composition and dropped host repeats. The
audit log held only `takeover` entries. This stand-in host had no physical
keyboard, so the human-keyboard path on a real host desktop was not exercised.

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
[the measured follow-up](archive/audit-followup-2026-09.md) for results and remaining limits.

For a reproducible software-path soak without accessing any desktop:

```sh
python3 scripts/benchmark_viewer_offline.py --seconds 300
```

It requires `gtk4-broadwayd`, uses private Unix sockets and a synthetic static
PNG, and accepts up to 3600 seconds. Its results are **not** Hyprland/GPU latency
measurements. Current changes and offline comparisons are documented in
[the performance follow-up](archive/performance-2026-09.md).

Borderless revision: verified over a room-image application at both new sizes,
with accessible close/stop labels and scoped border/shadow suppression. In a
separate disposable compositor, dragging the image changed the window position
and dragging the grip began resizing. The hyprhand frame guard then aborted each
automated drag when geometry changed, as intended; it was not weakened. Stop
through the overlay disabled only the source, left its two applications alive,
and left host authorization disabled. Closing the isolated viewer left the
source applications alive. The source and test compositor were then cleaned up.

### Hover controls verification

The hover update was checked against a real GTK viewer showing the Blender
session in a separate managed test desktop: pointer entry reveals both overlays,
pointer exit hides them, and Tab with the pointer outside reveals the close
button with its native focus ring. Enter closes that test viewer. The Blender
source remains open with input stopped. Optional GTK build/ABI checks, preview
unit tests and the private Broadway lifecycle tests passed.
