# CLI reference

This reference describes hyprhand 0.4.0. Run `hyprhand --help` for the compact command
list and `hyprhand --version` for the installed version. Commands beginning with
`_` are internal workers or diagnostics, not a stable integration API.

## Invocation and output

```text
hyprhand COMMAND [ARGUMENTS] [--session NAME] [OPTIONS]
```

Read commands default to `host`. Input commands (`focus`, `workspace`, pointer
commands, `type`, `key`, and `launch`) require an explicit `--session NAME`.
Always specify the session in automation, including `enable` and `stop`.
Session names begin with an ASCII letter, contain only letters, digits, `_` or
`-`, and have at most 32 characters. `host` is reserved.

Unknown, repeated, or command-inappropriate options are rejected. Use `--` before
the executable and arguments passed to `launch`. hyprhand does not interpret them
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
{"ok":false,"err":{"code":"StaleObservation","message":"The frame expired or desktop layout/focus changed. Observe again."},"disposition":{"delivery":"not_delivered","retry_safe":true}}
```

Parse `ok` and `err.code`, not English error messages. `err.detail`, when
present, is what the application or library said.

Every error, and every input or `act` success, carries a `disposition`:

| `delivery` | Meaning | `retry_safe` |
| --- | --- | --- |
| `not_delivered` | Nothing reached an application (validation, refusal, stop before input) | `true` |
| `delivery_uncertain` | Input was being sent when the command failed; it may have taken effect | `false` |
| `delivered_unverified` | Input was delivered; its effect was not checked | `false` |
| `delivered_verified` | Delivered, and a read-back confirmed the effect (`act`) | `false` |

Pointer commands count as delivered from their first button or wheel event, so
an approach that aborts is still `not_delivered`. Retry automatically only when
`retry_safe` is true; otherwise observe the application first. Successful response fields
vary by command. `state` returns `session_id`, `monitors`, `windows`, `workspaces`,
`active_window`, `cursor`, `control_enabled` (hyprhand input is enabled) and
`human_takeover` (a human holds the session through the preview's Take over; see
[preview](preview.md#human-takeover)). `windows`, `monitors`, and `workspaces` put their
respective Hyprland data in `data`. Hyprland-provided fields can vary by version.

## Inspection and observation

```sh
hyprhand doctor --session host
hyprhand state --session host
hyprhand windows --session host
hyprhand monitors --session host
hyprhand workspaces --session host
hyprhand sessions
hyprhand observe --session host --monitor MONITOR_NAME --scale 1
hyprhand state --session host --compact
hyprhand cursor --session host --frame FRAME_ID
```

`state --compact` and `windows --compact` replace the raw Hyprland JSON with a
short summary. Each window has `address`, `class`, `title`, `workspace`, `monitor`,
`at`, `size`, `floating`, `fullscreen`, `xwayland` and `visible` (mapped and not
hidden); each monitor has `id`, `name`, its `logical` desktop rectangle, `scale`,
`focused` and active `workspace`. `state --compact` keeps `active_window` (an
address), `cursor`, `control_enabled` and `human_takeover`, and omits the
workspace list. Use the raw commands when a field is missing.

`cursor` reports the pointer position in desktop coordinates. With `--frame ID`
it also returns `frame_pixel`, the image pixel of that frame that shows the
pointer (`null` outside the frame), and `frame_current`, whether the frame still
matches the layout and has not expired. It confirms where a `move` landed
without another capture.

`doctor` checks prerequisites, display routing, and protocol availability. It does
not capture an image, inject input, discover accessibility nodes, or start a
compositor. `operation_verified: false` means untested, not necessarily broken.

`observe` uses `grim`; `--backend auto` and `helper` select that implementation.
`--backend native` returns `NativeCaptureUnavailable`. If `--monitor` is omitted,
the focused monitor is selected. Capture scale accepts `0.1..2` independently of
the monitor's scale; the image is the captured logical size times the scale. `--retry 0..10` (default 0) retries `CommandTimeout`,
`HelperTimeout` and `StaleObservation` up to that many extra times, 0.7 s apart,
each attempt with a fresh 10 s budget; other errors are returned at once.

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
| `capture_scale` | Image pixels per logical pixel, after `--max-edge` |
| `window` | The `--window` address the capture was cropped to, otherwise `null` |
| `image_sha256` | SHA-256 of the PNG file, compared by `--since` |

### Crops, zoom and image budget

A vision model pays for an image by its pixel area, not by its file size. These
options capture fewer pixels; every resulting frame keeps the coordinate
contract below, so pointer commands use it like a full capture.

| Option | Captures |
| --- | --- |
| `--monitor NAME` (default: focused) | The whole output |
| `--window ADDRESS` | The screen inside that window's rectangle, clipped to its output |
| `--frame ID --x X --y Y --to-x X --to-y Y` | A box drawn on an earlier frame, in that frame's pixels |
| `--max-edge PX` (64..16384) | Lowers the scale so the longer image side is at most `PX` |

The three scopes exclude one another (`ConflictingObserveScope`). `--window`
captures what the screen shows inside the window, including anything that
overlaps it. The window must be mapped and on its output's active (or special)
workspace (`WindowNotVisible`). A box needs all four corners and its frame
(`InvalidObserveRegion`); both corner pixels are inside the box, given in any
order. The box frame must still be current (`StaleObservation`); the new frame
covers whole logical pixels around the box. Combine a box with `--scale 2` to
zoom into small text.

`--max-edge` never raises `--scale`. It leaves half a pixel of headroom for
rounding and fails with `CaptureExceedsMaxEdge` rather than return a larger
image. Set it to the model's limit when the agent's API does not downscale for
you: Claude Opus 4.7 and Sonnet 5 and newer accept 2576 pixels on the long side,
earlier Claude models 1568. Anthropic suggests about 1920 × 1080 as a balance of
accuracy and cost, and 1366 × 768 or 1280 × 720 for cost-sensitive work.

`--since FRAME_ID` compares the new capture with an earlier frame of this
session and adds `changed` and `diff` to the response. When the box and image
size match, both images are compared pixel by pixel (differences of up to 16
per channel are ignored as rendering noise): `diff` reports `changed_pixels`,
the `box` holding every change in the new image's pixels, and `cursor_like`.
A change no thicker than 3 pixels and no longer than 64 (a blinking text cursor,
a focus line) is `cursor_like` and leaves `changed` false, so the agent can skip
viewing the image. Other changes, a different box or size, or images that cannot
be decoded report `changed: true`. Without `--since`, both are `null`. The new frame is fresh and
actionable either way. A missing comparison frame fails with `FrameNotFound`
before anything is captured; `gc` removes frames older than five minutes.

### Set-of-marks

```sh
hyprhand observe --session agent --window WINDOW_ADDRESS --marks
hyprhand click --session agent --frame FRAME_ID --mark 7
```

`--marks` (with `--window`) reads the window's operable elements like
`accessibility --interactive`, draws a numbered box over each one that is at
least 4 pixels in the frame, and writes the result as `frame.marked_image_path`
beside the clean `image_path`. The response adds `marks`, one entry per number:
`mark`, `ref`, `role`, `name`, `states` and the target pixel `x`, `y`; and the
accessibility `snapshot` its refs belong to. View the marked image, pick a
number, and aim with `--mark N` instead of `--x --y` on any pointer command:
the mark is stored in the frame, so it goes through the same frame expiry and
layout validation as a coordinate (`MarkNotFound` for an unknown number).
Marks also separate twins that `act` refuses as `AmbiguousTarget`.
Each number sits where it covers neither another number nor another control
when the layout allows (above the box's left corner, else inside its top-right
corner, and so on), leaving the start of the control's text visible; numbers
are drawn smaller when most controls are under 20 pixels tall, as in a capture
reduced with `--max-edge`.

### Coordinate contract

All pointer coordinates are **pixels in the returned PNG**, with origin at its
upper-left corner. They must be finite and satisfy `0 <= x < image_width` and
`0 <= y < image_height`. If an image viewer rescales the image, map your selection
back to the original PNG dimensions before calling hyprhand.

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
hyprhand enable --session agent
hyprhand focus WINDOW_ADDRESS --session agent
hyprhand workspace 2 --session agent
hyprhand stop --session agent
```

Input is disabled until enabled. A window address comes from `windows` or `state`;
it is not a title. Focus first, wait for the intended focus, and then observe.
The optional `enable --indicator outline` requires the explicitly loaded
[experimental cursor plugin](experimental-bridges.md). Activation failure leaves
control disabled.

Authentication prompts belong to the human. Every input command, `act`
included, fails with `AuthenticationPrompt` (`err.detail` names it, nothing is
sent) while one of these is focused, under the pointer, targeted by `act`, or
drawn by the shell as a layer: window classes containing `polkit`, `pinentry`,
`askpass`, `gcr-prompter`, `kwallet`, `hyprland-dialog`, `kdesu`, `gksu`,
`keyring-prompt` or `authentication-agent`, and layer namespaces containing
`polkit`, `pinentry`, `keyring` or `auth`. The focused class is checked again
before every event, so a prompt that opens mid-action stops it. There is no
override: ask the human to answer the prompt.

### Confirmation gate

Before an input command activates a control whose accessible name says it pays,
sends, publishes, creates an account, deletes or accepts terms, the gate stops
it. Categories: `payment` (pay, buy, purchase, checkout, place order, subscribe,
pagar, comprar…), `communication` (send, post, publish, share, reply, enviar,
publicar…), `account_creation` (sign up, create account, register, crear
cuenta…), `deletion` (delete, erase, discard, empty trash, eliminar, borrar…)
and `consent` (I agree, accept, consent, acepto…). Phrases match at the start
of a word of the name of a button, link, menu item, check box or tab; fields
and labels are never gated.

| Input | Control examined |
| --- | --- |
| `act click`, `select`, `check`, `toggle` | The ref's element |
| `click`, `doubleclick` with `--mark N` | The mark's element |
| `click`, `doubleclick` at coordinates | The element under the point (AT-SPI hit test), or its nearest activating ancestor |
| `key Return`, `KP_Enter`, `space` | The focused element of `--window` |

```sh
hyprhand enable --session agent --gate ask     # default
hyprhand enable --session agent --gate human   # managed sessions only
hyprhand enable --session agent --gate off
```

| Mode | When a control is consequential |
| --- | --- |
| `ask` (default) | Fails with `ConfirmationRequired`, nothing sent, and `err.confirmation`: `id`, `category`, `role`, `name`, `window`. Ask the human; only if they agree, repeat the same command with `--ack ID` (`act`, `click`, `doubleclick`, `key`). An ID works once, for the same control and window, within 2 minutes (`ConfirmationMismatch`, `ConfirmationExpired`, `ConfirmationNotFound`) |
| `human` | hyprhand shows a host desktop notification with Approve and Deny and waits up to 2 minutes; Deny or no answer is `ConfirmationDenied`. Needs `notify-send` and a notification daemon (`ConfirmationUnavailable`); refused on `host`, where the agent could answer it itself |
| `off` | No gate |

`state` reports `confirmation_gate`. The audit log records every
acknowledgement and every notification answer by category, never the control's
name. The gate only knows what the application exposes: an unnamed or
inaccessible control, a canvas, or a site that labels its purchase button with
an image is not gated, so `ask` reduces but does not remove the need for the
agent to ask before consequential steps. `--ack` is a convention the agent is
told to respect; `human` mode is the one the agent cannot answer.

`stop` revokes authorization without waiting for the action lock. It cancels
guarded hyprhand input, leaving applications and external jobs open. It cannot
undo events or text already sent. Never automatically re-enable after a human stop.

## Pointer actions

The following commands show separate examples. Replace `FRAME_ID` and coordinates
with a fresh, inspected observation for each action.

```sh
hyprhand move --session agent --frame FRAME_ID --x 300 --y 200
hyprhand click --session agent --frame FRAME_ID --x 300 --y 200 --button left
hyprhand doubleclick --session agent --frame FRAME_ID --x 300 --y 200
hyprhand drag --session agent --frame FRAME_ID --x 100 --y 200 \
  --to-x 400 --to-y 200 --duration-ms 500
hyprhand scroll --session agent --frame FRAME_ID --x 500 --y 400 --dy 2
```

All pointer commands accept `--window WINDOW_ADDRESS`, `--dry-run`,
`--move-duration-ms`, and `--no-aura`. With `--window`, the initial/click point
must be inside that focused window. Without it, the initially observed focus is
still protected. Click, double click, and drag support `left`, `right`,
`middle`, `back` and `forward` buttons, defaulting to `left`. `back` and
`forward` are the thumb buttons (BTN_SIDE, BTN_EXTRA) that browsers and file
managers use for history navigation.

`click --count 1..3` sends that many clicks 80 ms apart, well inside the
double-click interval: `--count 3` selects a line or paragraph in most editors.
`doubleclick` remains an alias for `--count 2`.

`--mods ctrl+shift` holds modifier keys (`ctrl`, `shift`, `alt`, `super`/`logo`,
`altgr`) on a virtual keyboard while `click`, `doubleclick`, `drag` or `scroll`
acts: they are pressed after the approach, immediately before the button or
wheel, and released after it, in reverse order, also on failure or
cancellation. Use it for ctrl+click (open in a new tab, multi-select),
shift+click (range select) or ctrl+scroll (zoom). XWayland windows take
keyboard input through XTEST instead, so a target or click point on an XWayland
window fails with `ModifiersUnavailableForX11` before any input.

Holding a button or key *across* commands (separate `mouse down` and `mouse up`)
is not available: each command owns its virtual devices and releases everything
it pressed when it exits.

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
hyprhand type --session agent --window WINDOW_ADDRESS --text 'Hello, Unicode: ñ ✓'
hyprhand key ctrl+shift+Return --session agent --window WINDOW_ADDRESS
hyprhand key alt+Left --session agent --window WINDOW_ADDRESS
hyprhand key Down --repeat 5 --session agent --window WINDOW_ADDRESS
```

`key --repeat 1..100` taps the chord that many times, 25 ms apart, with one
focus guard per tap; the native keyboard uploads its map once.

Both commands require the exact target to remain focused. UTF-8 text supports up
to 64 KiB, including tabs and newlines; a `\r\n` pair is sent as one Return, the
same as a lone `\n` or `\r`. The native keyboard uses self-contained
XKB maps; a new map is uploaded only when the next new character finds no free
key, never after a fixed number of characters, so most texts need one map. It
sends physical modifier keys as well as resolved modifier masks, and releases
owned input in reverse order. Unless `--backend clipboard` is chosen, no
clipboard or shell is used to transport the text.

Each symbol is sent on its US-layout key when it has one (`t` on KEY_T, `minus`
on KEY_MINUS, `Return` on KEY_ENTER, `Escape` on KEY_ESC); other characters use
free letter, digit or punctuation keys, so a map holds at most 48 distinct
characters without a key of their own. Chromium derives shortcut and editing key
codes from the hardware keycode, and GTK 3 matches some bindings by keycode, so a
character sent on another key's position could act as that key (for example, a
`>` on the Backspace position deleted text in Brave, and `ctrl+minus` on the Escape
position did not zoom).

Shortcut modifiers are `ctrl`, `shift`, `alt`, `super`/`logo`, and `altgr`;
the final key uses an XKB keysym name, such as `Return`, `Left`, or `Tab`.

| Backend | Wayland window | XWayland window |
| --- | --- | --- |
| `auto` | Native virtual keyboard | `xdotool` |
| `native` | Native virtual keyboard | Explicit failure |
| `helper` | `wtype` | `xdotool` |
| `clipboard` (`type` only) | Session clipboard + native `ctrl+v` | Not applicable: managed sessions run without XWayland |

`wtype` places keys from keycode 1 upwards, so `--backend helper` can still
lose characters in Chromium-based browsers (Brave lost text in 10 of 15
trials); prefer `auto`.

`type --backend clipboard` writes the text into the **managed session's**
Wayland clipboard with `wl-copy` (from wl-clipboard), run against the session's
`XDG_RUNTIME_DIR`/`WAYLAND_DISPLAY`, then sends `ctrl+v` through the normal
chord path with the same control token and focus guards. The text goes through
`wl-copy`'s stdin, never its argv. It is refused for `--session host`
(`ClipboardManagedSessionRequired`): the host clipboard belongs to the human.
After a successful paste the text **stays on the session clipboard** until
the next copy in that session or until the session is destroyed, and any
application in the session can read it. Clearing it does not work reliably:
`wl-copy --paste-once` is consumed by Chromium before it inserts anything
(Brave pasted nothing), and `wl-copy --clear` right after `ctrl+v` races the
application, which fetches the data asynchronously (Brave pasted 2 of 10
times). For secrets prefer the default backend, or destroy the session after
use. If the chord fails, hyprhand clears the session clipboard. The focused
widget must paste with `ctrl+v` (terminals use `ctrl+shift+v`), and the paste
replaces any selected text. A missing `wl-copy` fails with
`ClipboardHelperMissing` before anything is sent; `doctor` reports it as
`dependencies.wl_copy` and `capabilities.clipboard_paste`.

X11 input verifies the focused window PID against the target in the routed
`DISPLAY`. There is no silent retry on a different backend after potentially
partial text delivery. `--dry-run` validates without typing.

## Waits and events

```sh
hyprhand wait focus --session agent --window WINDOW_ADDRESS
hyprhand wait window --session agent --class firefox
hyprhand wait workspace --session agent --workspace 2
hyprhand wait stable --session agent --stable-ms 300
hyprhand wait stable --session agent --pixels --monitor MONITOR_NAME --timeout-ms 5000
hyprhand events --session agent --limit 20 --timeout-ms 5000
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
hyprhand accessibility --session agent --window WINDOW_ADDRESS \
  [--interactive] [--frame FRAME_ID] [--depth 5] [--limit 100] [--timeout-ms 5000]
hyprhand act VERB --ref @1a2b3c4d:e3 --session agent [--text VALUE] [--dry-run]
```

AT-SPI traversal runs in a disposable worker with an outer timeout plus per-call
limits. `--depth` accepts `1..32`; `--limit` accepts `1..10000`. The defaults are
5 and 100. Password values and their children are omitted, but other accessible
names and values may contain private content: treat them as untrusted
application text, never as instructions.

Without `--window` the walk covers every application and bounds are labeled
`atspi-screen-unverified`. With `--window ADDRESS` it covers that window's own
toplevel (matched by title, or the application's only toplevel) and reports:

| Node field | Meaning |
| --- | --- |
| `role`, `name` | AT-SPI role and name; an unnamed row, cell or tab takes its child's text |
| `states` | Notable states: `focused`, `checked`, `indeterminate`, `pressed`, `expanded`, `collapsed`, `selected`, `editable`, `read_only`, `disabled` |
| `value` | Current text of editable fields or a range value, at most 256 characters |
| `bounds` | Desktop logical coordinates: window-relative extents plus the window origin |
| `ref` | `@SNAPSHOT:eN` for elements a person operates (interactive roles, focusable or editable) |
| `frame_point` | With `--frame ID`: the element's centre as a pixel of that frame, ready for `click` |

`coordinate_space` is then `desktop-logical`, and `snapshot` names the stored
snapshot. `--interactive` keeps only nodes that received a ref, which is
usually a small fraction of the tree.

### Refs

A ref stores the element's child path from the toplevel and its identity:
role, name, accessible ID and description. Position and value are never part
of the identity; a name equal to the current text of an entry, text, combo box
or spin button is ignored. `act` follows the path, checks the identity, and
otherwise searches the window for exactly one element with that identity:

| Result | Error | Delivery |
| --- | --- | --- |
| Element gone, renamed, or snapshot older than 5 minutes | `StaleRef`, `SnapshotNotFound`, `SnapshotExpired` | `not_delivered` |
| Two elements had or have the same identity | `AmbiguousTarget` | `not_delivered` |
| Malformed ref; a bare `e3` names no snapshot | `InvalidRef` | `not_delivered` |

Some toolkits rename elements as they change: GTK 4 names an open expander after
its content. Take a new snapshot after an action that changes a label. For
twins and other ambiguous elements, click their `frame_point` with the pointer.
Snapshots are private files in the session state directory; `gc` removes them.

### Semantic actions

`act` changes an element through AT-SPI without moving the pointer, taking
keyboard focus, or synthesizing keys, so it also works on windows that are not
focused. It is an input command: it needs an explicit `--session`, enabled
control, the action lock and the audit log, and `stop` cancels it. When no
semantic call fits, it fails with `ActionNotSupported` and nothing is sent; it
never falls back to the pointer by itself.

| Verb | Calls, in order | Verified by |
| --- | --- | --- |
| `click` | Action `click`, `press`, `activate`, `open`, `jump`, `dodefault` | Not verifiable |
| `focus` | Component.GrabFocus | `focused` state |
| `set-value --text V` | Numbers on a Value element: Value.CurrentValue; text: EditableText.SetTextContents, then DeleteText+InsertText | Reading the value or text back |
| `check`, `uncheck`, `toggle` | Action `check`/`uncheck`, `toggle`, `switch`, `click`, `press`, `activate` | `checked` (or `pressed`) state |
| `expand`, `collapse` | Action `expand`/`collapse`, `listitem.*`, `click`, `press`, `activate` | `expanded` state |
| `select` | Action `select`, the parent's Selection.SelectChild, then `click` | `selected` state |
| `scroll-to` | Component.ScrollTo | Not verifiable |

The response reports `disposition`, `verified`, `satisfied` (the element
already had the requested state or value, so nothing was sent), `resolved_by`
(`path` or `identity`), the read-back `value`, and every call in `steps`.
`--dry-run` resolves the ref and lists the element's `actions` and `interfaces`
without acting. Password fields refuse `set-value` (`ProtectedField`): hand
sign-ins to the human.

A call the application refuses or does not implement changes nothing and leaves
`not_delivered`. A reply that never arrives leaves `delivery_uncertain`
(`AccessibilityTimeout`): inspect before retrying. A write the application
accepted without changing the text is `WriteIgnored`; a different text than
requested is `ValueMismatch` (`delivered_unverified`).

Toolkit behavior verified live on this release:

| Toolkit | Works semantically | Use the pointer or keyboard for |
| --- | --- | --- |
| GTK 4 | Button click, entry text, toggle button, expander, spin button value, list row select | Check buttons (no action), focus and scroll-to (not implemented) |
| Chromium (Brave) | Button click, focus, checkbox check/uncheck, `<details>`, `<option>` select | Text inputs: no EditableText; `act focus`, then `key ctrl+a` and `type` |

Chromium exposes its tree only when started with `--force-renderer-accessibility`;
Qt needs `QT_ACCESSIBILITY=1`. An empty tree does not establish that no controls
exist.

## Composing: `--then` and `sequence`

```sh
hyprhand act toggle --ref @1a2b3c4d:e5 --session agent --then accessibility
hyprhand click --session agent --frame FRAME --x 300 --y 200 --then observe --max-edge 1568
printf '%s' '[["act","set-value","--ref","@1a2b3c4d:e2","--text","Ada"],
              ["act","check","--ref","@1a2b3c4d:e4"],
              ["key","Return","--window","0x55d0c0"]]' |
  hyprhand sequence --session agent --then state
```

Every input command accepts `--then state|observe|accessibility` and
`--settle-ms 0..10000` (default 250). After the action succeeds and the pause
passes, the response gains a `then` object holding what that command would print:

| `--then` | Reports |
| --- | --- |
| `state` | `state --compact` |
| `observe` | A capture of the action's frame scope (same window or output) with `--since` that frame, so `changed` tells whether the screen moved; otherwise the action's `--window`, `act` window or focused window; otherwise the focused output. `--max-edge` applies to it |
| `accessibility` | `accessibility --window W --interactive` of the action's window, or the focused one |

A failed report (`{"ok":false,"err":…}` inside `then`) never turns the action's
success into a failure. Dry runs and failed actions report no `then`.

`sequence --session S` reads a JSON array of steps from stdin, at most 50. Each
step is a command line without `--session`: input commands (`act`, `click`,
`type`, `key`, `focus`, `launch`…) or `wait`. All steps are parsed and validated
before the first runs, so a malformed request (`InvalidSequence`,
`InvalidSequenceStep`) sends nothing. Steps run in order with their own guards,
budgets and audit entries, and the first failure stops the rest:

| Field | Meaning |
| --- | --- |
| `steps` | Each executed step: `index`, `command`, `ok`, its `result` or `err`, and its `disposition` |
| `completed`, `failed_step`, `not_executed` | How far it got |
| `disposition` | The least certain delivery of all steps |
| `then` | With `--then`, the report after the last executed step |

A failed sequence exits 1 with this report, not a bare error. Use it for steps
whose targets are known in advance: several refs of one snapshot, or several
points of one frame while the layout stays put. `--dry-run` validates every step
and dry-runs each input step.

## Model dialects

```sh
hyprhand dialect anthropic --session agent [--window ADDR] [--max-edge PX] [--ack ID] < calls.json
hyprhand dialect openai    --session agent [--window ADDR] < computer_call.json
hyprhand dialect gemini    --session agent [--window ADDR] [--confirmed] < function_calls.json
```

`dialect` lets an agent loop pass a computer-use model's own calls straight to
hyprhand and its own result format straight back. It reads one model turn on
stdin, runs each call through the normal input path (control, guards, the
authentication guard, the confirmation gate, the audit log and an active
journal), and prints `results` in the provider's format, ready to append to the
next request, plus `failed_call`, `disposition` and `frame_id`.

| Dialect | Reads | Answers | Coordinates |
| --- | --- | --- | --- |
| `anthropic` | `tool_use` blocks of `computer_toolset_20260801` (action in `name`; other blocks ignored) | One `tool_result` per call, echoing `toolset_name: "computer"`; images for `screenshot` and `zoom`, `"OK"` or text otherwise | Screenshot pixels |
| `openai` | `computer_call` items with an `actions` array | One `computer_call_output` per call, with the screenshot taken after the turn as a PNG data URL | Screenshot pixels |
| `gemini` | `computer_use` function calls (`name`, `args`) | One `function_result` per call; the last carries the screenshot taken after the turn | 0-999 of the screenshot |

Coordinates refer to the **last screenshot the dialect returned** in this
session: its frame is remembered and every pointer call is validated against it
like any frame (expiry, layout). Without a screenshot first, pointer calls fail
asking for one. `--window` crops screenshots to that window and types into it;
otherwise screenshots show the focused output and keys go to the focused window.
`anthropic` screenshots default to `--max-edge 1568`, the limit of the older
Claude models (current ones accept 2576; the API rejects larger images).

Calls run in order and the first failure stops the rest: Anthropic's later
blocks get exactly `Not executed: an earlier computer action in this turn
failed.`; the exit status is 1 and the results are still printed. A failure's
text tells the model what to do, including the confirmation ID when the gate
stops a call: after the human agrees, send the same turn again with `--ack ID`.
For Gemini calls carrying `safety_decision: require_confirmation`, ask the human
and resend with `--confirmed`, which adds `safety_acknowledgement` to the result.

| Provider action | hyprhand |
| --- | --- |
| `left_click`, `right_click`, `middle_click`, `double_click`, `triple_click` (Anthropic), `click` with `button` and `keys` (OpenAI), `click`, `double_click`, `triple_click`, `right_click`, `middle_click` (Gemini) | `click --count` with `--button` and `--mods`; no coordinate means the cursor |
| `left_click_drag`, `drag` (first and last point of `path`), `drag_and_drop` | `drag` |
| `mouse_move`, `move` | `move` |
| `scroll` | wheel steps: Anthropic `scroll_amount`; OpenAI `scroll_x`/`scroll_y` and Gemini `magnitude_in_pixels` at 100 pixels per step |
| `type`, Gemini `press_enter` | `type` (a trailing newline for Enter) |
| `key` (`text`, `repeat`), `keypress` (`keys`), `press_key`, `hotkey` | `key`, with names such as `CTRL`, `Enter`, `ArrowUp`, `cmd` mapped to `ctrl`, `Return`, `Up`, `super` |
| `screenshot`, `take_screenshot`; Anthropic `zoom` | `observe` (`zoom` keeps the full screenshot's coordinate space) |
| `cursor_position`, `wait` | read locally; waits are cancellable |
| `left_mouse_down`/`up`, `hold_key`, Gemini `mouse_down`/`up`, `key_down`/`up` | Refused: hyprhand releases everything a command presses. With Anthropic, disable them through the toolset's `configs` |

OpenAI's public guide shows `computer_call`, `click` and `type` but not every
action's fields; `drag.path`, `scroll_x`/`scroll_y` in pixels and `keypress.keys`
follow its sample implementation.

## Journals and replay

```sh
hyprhand journal start checkout --session agent
# ... act, click, type, key as usual ...
hyprhand journal stop --session agent
hyprhand journal show checkout --session agent
hyprhand replay checkout --session agent             # plan only
hyprhand replay checkout --session agent --execute   # repeat it
```

While a journal records, every input command (`act`, pointer commands, `type`,
`key`, `focus`, `workspace`, `launch`, also inside `sequence`) appends one step
with its outcome and `disposition`. Steps name their target by what survives a
new run, never by frames or refs, which expire:

| Field | Recorded |
| --- | --- |
| `window` | The target window's `class` and `title`, and its size |
| `element` | Role and name: the ref's element for `act`, the mark's for `--mark`, and for coordinate clicks the nearest operable control under the point |
| `point`, `to_point` | The pointer target and drag destination, relative to the window |
| Parameters | Verb, chord, repeat, text, button, click count, modifiers, scroll, program |

Text typed with `type` into a focused password field is never stored: the step
keeps only `text_length` and `text_sha256` and is marked `secret`. Other text is
stored in the journal, a private file in the session's state directory. Dry runs
and commands whose target cannot be learned are not recorded.

`replay NAME` plans: it resolves every recorded step on the live desktop and
reports its status, window, ref and point. `--execute` resolves and runs the
steps in order through the normal input path, with every guard, the
authentication guard and the confirmation gate, and stops at the first step
that cannot be resolved or fails:

| Resolution | Rule | Error |
| --- | --- | --- |
| Window | The only mapped window of the recorded class, or the only one also matching the title | `ReplayWindowNotFound`, `ReplayWindowAmbiguous` |
| Element | The window's only operable element with the recorded role and name | `ReplayElementNotFound`, `ReplayElementAmbiguous` |
| Pointer | A fresh frame of the window, aimed at the element's centre, or at the recorded relative point only while the window keeps its recorded size | `ReplayLayoutChanged` |
| Keyboard | The window is focused first if it is not | `ReplaySecretStep` for secret text |

Steps that failed when recorded are `skipped`. The report has the same shape as
`sequence`: per-step `status` (`planned`, `done`, `skipped`, `unresolved`,
`failed`), result or error and disposition, `failed_step`, `not_executed` and an
overall `disposition`; a failed replay exits 1. A replay is as safe as its
targets are distinctive: two buttons with the same name stop it rather than
guess.

## Logs, cleanup, and cancellation

```sh
hyprhand logs --session agent --limit 20
hyprhand gc --session agent --older-than-ms 300000 --dry-run
hyprhand gc --session agent
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
