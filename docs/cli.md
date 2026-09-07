# CLI reference

This reference describes deskctl 0.4.0. Run `deskctl --help` for the compact command
list and `deskctl --version` for the installed version. Commands beginning with
`_` are internal workers or diagnostics, not a stable integration API.

## Invocation and output

```text
deskctl COMMAND [ARGUMENTS] [--session NAME] [OPTIONS]
```

Read commands default to `host`. Input commands (`focus`, `workspace`, pointer
commands, `type`, `key`, and `launch`) require an explicit `--session NAME`.
Always specify the session in automation, including `enable` and `stop`.
Session names begin with an ASCII letter, contain only letters, digits, `_` or
`-`, and have at most 32 characters. `host` is reserved.

Unknown, repeated, or command-inappropriate options are rejected. Use `--` before
the executable and arguments passed to `launch`. deskctl does not interpret them
as a shell expression.

| Output | Contract |
| --- | --- |
| Standard commands | JSON on stdout; diagnostics on stderr |
| `events` | NDJSON: one JSON record per line, followed by a summary |
| `--help`, `-h`, no arguments, `--version` | Plain text |
| Exit 0 | Command succeeded; application outcome still needs verification |
| Exit 1 | Runtime failure; input may already have been partially delivered |
| Exit 2 | Invalid command arguments |

Example error shape:

```json
{"ok":false,"err":{"code":"StaleObservation","message":"The frame expired or desktop layout/focus changed. Observe again."}}
```

Parse `ok` and `err.code`, not English error messages. Successful response fields
vary by command. `state` returns `session_id`, `monitors`, `windows`, `workspaces`,
`active_window`, and `cursor`. `windows`, `monitors`, and `workspaces` put their
respective Hyprland data in `data`. Hyprland-provided fields can vary by version.

## Inspection and observation

```sh
deskctl doctor --session host
deskctl state --session host
deskctl windows --session host
deskctl monitors --session host
deskctl workspaces --session host
deskctl sessions
deskctl observe --session host --monitor MONITOR_NAME --scale 1
```

`doctor` checks prerequisites, display routing, and protocol availability. It does
not capture an image, inject input, discover accessibility nodes, or start a
compositor. `operation_verified: false` means untested, not necessarily broken.

`observe` uses `grim`; `--backend auto` and `helper` select that implementation.
`--backend native` returns `NativeCaptureUnavailable`. If `--monitor` is omitted,
the focused monitor is selected. Capture scale accepts `0.1..2` independently of
the monitor's scale.

The response contains `ok`, `capture_duration_ms`, and `frame`:

| Frame field | Meaning |
| --- | --- |
| `schema_version` | Currently `2`; old frame schemas are rejected |
| `session_id`, `instance`, `wayland_display` | Exact source identity |
| `frame_id` | 32-character hexadecimal ID used by pointer commands |
| `image_path` | Absolute path to the private PNG file |
| `image_width`, `image_height` | Actual captured image dimensions |
| `logical` | Desktop rectangle: `x`, `y`, `width`, `height` |
| `monitor_id`, `workspace_id` | Captured output and active workspace |
| `captured_at_unix_ms`, `captured_at_monotonic_ms` | Wall-clock and monotonic capture timestamps |
| `max_age_ms` | 30000; frames expire after 30 seconds |
| `layout_revision` | Hash of relevant compositor state |

### Coordinate contract

All pointer coordinates are **pixels in the returned PNG**, with origin at its
upper-left corner. They must be finite and satisfy `0 <= x < image_width` and
`0 <= y < image_height`. If an image viewer rescales the image, map your selection
back to the original PNG dimensions before calling deskctl.

The conversion is:

```text
desktop_x = floor(logical.x + image_x * logical.width / image_width)
desktop_y = floor(logical.y + image_y * logical.height / image_height)
```

For a 1920 × 1080 image mapped to a 1280 × 720 logical rectangle starting at
(-1280, 100), image point (960, 540) becomes desktop point (-640, 460).
Negative monitor origins, fractional scale, and output transforms are accounted
for in the frame's logical rectangle.

The revision retains global focus and monitor geometry/workspaces, plus windows
and layers relevant to the captured output, including crossing windows. Unrelated
windows/layers on another output do not invalidate the frame. Changes inside an
application page may not change the revision. These guards reduce stale targeting;
they do not make checking and acting atomic.

## Enable, stop, focus, and workspace

```sh
deskctl enable --session agent
deskctl focus WINDOW_ADDRESS --session agent
deskctl workspace 2 --session agent
deskctl stop --session agent
```

Input is disabled until enabled. A window address comes from `windows` or `state`;
it is not a title. Focus first, wait for the intended focus, and then observe.
The optional `enable --indicator outline` requires the explicitly loaded
[experimental cursor plugin](experimental-bridges.md). Activation failure leaves
control disabled.

`stop` revokes authorization without waiting for the action lock. It cancels
guarded deskctl input, leaving applications and external jobs open. It cannot
undo events or text already sent. Never automatically re-enable after a human stop.

## Pointer actions

The following commands show separate examples. Replace `FRAME_ID` and coordinates
with a fresh, inspected observation for each action.

```sh
deskctl move --session agent --frame FRAME_ID --x 300 --y 200
deskctl click --session agent --frame FRAME_ID --x 300 --y 200 --button left
deskctl doubleclick --session agent --frame FRAME_ID --x 300 --y 200
deskctl drag --session agent --frame FRAME_ID --x 100 --y 200 \
  --to-x 400 --to-y 200 --duration-ms 500
deskctl scroll --session agent --frame FRAME_ID --x 500 --y 400 --dy 2
```

All pointer commands accept `--window WINDOW_ADDRESS`, `--dry-run`,
`--move-duration-ms`, and `--no-aura`. With `--window`, the initial/click point
must be inside that focused window. Without it, the initially observed focus is
still protected. Click, double click, and drag support `left`, `right`, and
`middle` buttons, defaulting to `left`.

A focus or geometry change during approach can abort before input. Hover-to-focus
settings can trigger this. Moving or resizing a compositor window by dragging
may invalidate the drag's own frame; dragging within application content need
not change compositor geometry. This guard does not promise unrestricted window
movement.

### Motion and visual indicator

Approach follows a straight line with gradual acceleration/deceleration. Automatic
duration is 200–600 ms based on logical distance; an already reached destination
adds no approach delay. `--move-duration-ms` accepts `0` for an instant jump or
`50..10000` for an explicit approach. It also controls the unpressed approach
before a drag. Drag `--duration-ms` separately controls the button-held segment:
`50..10000`, default `500`.

Motion aims for 16 ms steps and skips overdue samples. Each step validates stop,
signals, lock state, focus/layout, and cursor position. External movement,
application recentering, or compositor constraints can raise
`CursorPositionMismatch`. The tool aborts rather than fighting for the pointer.
Durations are targets, not real-time guarantees.

A small blue, input-transparent halo accompanies pointer actions by default.
It uses native Wayland layer-shell surfaces with no keyboard focus and exists
only for that action. Instant actions retain an approximately 100 ms cancelable
visibility interval. `--no-aura` disables this per-action halo; use it together
with `--move-duration-ms 0` to omit both approach and the minimum visual interval.
The halo requires wl_output v4, compositor v4, and layer-shell v3. If unsupported,
it fails explicitly; it does not silently disappear. It uses output logical
coordinates and scale-2 drawing. Snapshots taken during an action may include it.
The continuous outline is a different experimental feature; `--no-aura` does not
turn off that plugin.

### Scroll mode and pacing

`--dx` and `--dy` accept integer values from -100 to 100. Positive values scroll
right/down. The application and compositor determine the visible distance.
`--duration-ms` accepts `0` or `50..10000`, default `500`.

| `--scroll-mode` | Native Wayland | XWayland |
| --- | --- | --- |
| `auto` (default) | Continuous when duration > 0; wheel when duration = 0 | Integer XTEST wheel events, paced when duration > 0 |
| `wheel` | Discrete wheel events, optionally paced | Integer XTEST wheel events, optionally paced |
| `continuous` | Continuous distance, including instant duration = 0 | Rejected with `ContinuousScrollUnavailable` |

Native continuous scroll preserves accumulated distance and emits axis-stop on
completion/cancellation. Wheel mode avoids a spurious continuous end event.
Cancellation stops future input; application inertia may continue. XWayland has
no subpixel wheel behavior and weaker cleanup guarantees.

## Keyboard

```sh
deskctl type --session agent --window WINDOW_ADDRESS --text 'Hello, Unicode: ñ ✓'
deskctl key ctrl+shift+Return --session agent --window WINDOW_ADDRESS
deskctl key alt+Left --session agent --window WINDOW_ADDRESS
```

Both commands require the exact target to remain focused. UTF-8 text supports up
to 64 KiB, including tabs and newlines. The native keyboard uses self-contained
XKB maps in chunks of at most 128 codepoints. It sends physical modifier keys as
well as resolved modifier masks, and releases owned input in reverse order.
No clipboard or shell is used to transport the text.

Shortcut modifiers are `ctrl`, `shift`, `alt`, `super`/`logo`, and `altgr`;
the final key uses an XKB keysym name, such as `Return`, `Left`, or `Tab`.

| Backend | Wayland window | XWayland window |
| --- | --- | --- |
| `auto` | Native virtual keyboard | `xdotool` |
| `native` | Native virtual keyboard | Explicit failure |
| `helper` | `wtype` | `xdotool` |

X11 input verifies the focused window PID against the target in the routed
`DISPLAY`. There is no silent retry on a different backend after potentially
partial text delivery. `--dry-run` validates without typing.

## Waits and events

```sh
deskctl wait focus --session agent --window WINDOW_ADDRESS
deskctl wait window --session agent --class firefox
deskctl wait workspace --session agent --workspace 2
deskctl wait stable --session agent --stable-ms 300
deskctl wait stable --session agent --pixels --monitor MONITOR_NAME --timeout-ms 5000
deskctl events --session agent --limit 20 --timeout-ms 5000
```

`wait window` accepts an exact `--window` address, a `--class`, or both; the
matching window must be mapped and not hidden. `wait stable` compares geometric
revisions. `--pixels` additionally compares captured PNG content and removes its
temporary capture afterward. Stable pixels do not prove that a network request
finished or data was saved.

`--timeout-ms` defaults to 5000 and accepts `1..300000`. For waits it includes
queries inside each iteration, not just pauses. `--stable-ms` accepts
`50..30000`, default `300`. `WaitTimeout` means the condition was not met.
Events are bounded by `--limit` (`1..10000`, default `100`) and the timeout;
they do not attest to application-level outcomes.

## Accessibility

```sh
deskctl accessibility --session agent --window WINDOW_ADDRESS \
  --depth 5 --limit 100 --timeout-ms 5000
```

AT-SPI traversal is read-only, executed in a disposable worker with an outer
timeout plus per-call limits. `--depth` accepts `1..32`; `--limit` accepts
`1..10000`. The defaults are 5 and 100. Password values and their children are
omitted, but other accessible names may contain private content.

Bounds are labeled `atspi-screen-unverified`: some Wayland applications report
origins of (0, 0). They cannot be used directly as frame coordinates. An empty
tree does not establish that no controls exist. The CLI does not expose semantic
AT-SPI editing or click actions.

## Logs, cleanup, and cancellation

```sh
deskctl logs --session agent --limit 20
deskctl gc --session agent --older-than-ms 300000 --dry-run
deskctl gc --session agent
```

Audit records contain time, session, action, and status, excluding typed text,
argv, and titles. They rotate around 1 MiB with one previous rotation. `logs`
returns the requested tail and reports `incomplete_tail` when a final record is
unfinished. Full records remain readable.

Screenshots use 0700 directories and 0600 files. Automatic observation cleanup
removes frames older than five minutes, scanning at most once per 30 seconds.
Explicit `gc` always scans and can adjust the age threshold, but never removes
a still-usable frame. Only exact regular frame filenames are eligible; unrelated
files and symlinks are excluded. The tool does not upload captures or logs.

SIGINT/SIGTERM and `stop` cancel guarded input. Native devices release owned
keys/modifiers/buttons during normal cleanup and catchable cancellation. There
is no persistent held button across CLI invocations. SIGKILL, compositor failure,
and external X11 helpers cannot provide the same release guarantee.

Command deadlines are cooperative: ordinary reads have 10 s, actions 30 s, and
`type` 300 s. Helpers and IPC also have bounded waits; cleanup has independent
budgets so cancellation does not skip release. Kernel/native-library stalls are
outside real-time guarantees. Inspect state after errors before deciding whether
to send more input. See [troubleshooting](troubleshooting.md).
