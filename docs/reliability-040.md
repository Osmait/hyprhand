# Reliability 0.4.0 — local historical report

Tests were performed on 2026-09-06 with Hyprland 0.56.2, Aquamarine 0.15.0,
native GTK4, and HEADLESS-1 at 1920 × 1080 using an explicitly selected experimental
bridge. The disposable session was `reliability-040`; no input targeted the host.
This does not certify other machines, applications, or versions.

## Pointer

- Click with aura and explicit window: receiver event confirmed and confirmation
  label inspected in a fresh screenshot.
- Normal 270 px drag: GTK receiver confirmed `drag-end`, dx=270, dy=0.
- Geometry change during 5 s approach: `StaleObservation` before click; click
  counter remained at one. Only test-window geometry was restored.
- Interference during 5 s drag: the child's cursor was deliberately moved through
  its exact IPC. deskctl returned `CursorPositionMismatch` and the receiver
  confirmed button release through `drag-end`.
- Paced wheel and reverse continuous scroll: before/after screenshots confirmed
  movement. Visual distance differs by mode and application.
- Detailed observation found a fifth `surface` event after four wheel steps,
  caused by sending axis-stop for a wheel. End-of-axis was restricted to
  continuous gestures. Repetition yielded exactly four `wheel` events with dy=1
  and no extra event.

## Keyboard and offline tests

The native backend sends physical modifier keys and masks resolved from a
self-contained XKB map. Protocol tests use private fake Wayland/IPC sockets and
cannot inject input into a real compositor.

The initial GTK run found an observer assumption error: it expected an immediate
zero modifier-mask callback after Control release. The receiver recorded Control
down, `a` with Control mask, and both releases. GTK updates its controller mask
while processing key events; a following unmodified key is the needed evidence.
The observer checks balanced physical release and an unmodified F12 probe rather
than fabricating a zero callback.

The complete rerun passed ten checks: three native shortcut groups, auto/wheel/
continuous with explicit and implicit windows, and SIGTERM cancellation without
subsequent scroll events. A new screenshot was reviewed before each pointer action.
An exact Unicode string containing accents, ñ, a check mark and an em dash was
also received through native typing.

`Shift+Tab` exposed a real bug: a one-level keymap failed to send `ISO_Left_Tab`,
so GTK did not change fields. Shortcut maps gained Shift levels for Tab/letters;
text maps retained exact text behavior. Reverse navigation and Ctrl+Shift word
selection then passed.

In **Blender 5.2.1 LTS**, a fresh factory-config instance in the same private
session received `Shift+F4` and switched from 3D view to Python console;
`Ctrl+Space` maximized that editor. Screenshots verified both. This validates
those shortcuts, not all Blender modeling, scroll, or drag workflows.

## Reproducible offline commands

```sh
zig build test
zig build -Doptimize=ReleaseSafe
python3 tests/integration.py
python3 tests/keyboard_unit.py
python3 tests/keyboard_protocol.py
python3 tests/session_lifecycle.py
python3 -m unittest discover -s packaging -p 'test_*.py'
```

At the time, eight isolated keyboard tests overlapped the 26 Zig tests and were
not counted twice. Integration had 36 cases, keyboard protocol seven, lifecycle
twelve, packaging seven, and the offline graphical-observer contract 31: 119
unique automated cases across those suites. Current suite counts may differ.

Cleanup stopped control and destroyed `reliability-040`, retaining temporary
profiles/logs for diagnosis. No user files were deleted or Blender scenes saved.

## Preserved limits

No same-compositor workspace input isolation, file/credential sandbox, general
AT-SPI semantic actions, or native screenshot backend was added. Experimental
bridge ABI/GPU restrictions remain. Native cleanup cannot guarantee recovery from
SIGKILL or compositor failure; X11 helpers have weaker release guarantees.
Success in GTK does not establish correctness in another application's UI.
