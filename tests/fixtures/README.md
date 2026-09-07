# Managed reliability observer

`reliability.py` is a disposable, operator-launched GTK4/PyGObject fixture for
`../live_reliability.py`. The runner attaches to it; it never launches GUI apps,
creates sessions, steals focus, or enables control. Use an existing dedicated
managed session with explicitly authorized control. Both programs reject `host`
and require `--live` and `--session NAME`; environment variables cannot silently
select the runner's session.

Fixture launch instructions are in `reliability.py --help`. Launch through
`hyprhand launch --session NAME` so its environment matches the managed metadata.
Choose a fresh observer path: the fixture creates it exclusively, with mode 0600.
Wait for `ready`, leave the fixture's first entry focused, then run from the
repository root:

```sh
python3 -B tests/live_reliability.py --live --session NAME --events /absolute/path/events.ndjson
```

For the complete pointer matrix followed by cancellation, use an interactive
TTY and append these options to that command:

```text
--pointer --scroll-mode all --guard cancel
```

The run verifies keyboard behavior first. Home clears the initial selection,
Ctrl+A selects the text, Tab moves to the second entry, Shift+Tab moves back,
and Ctrl+Shift+Right selects a word. Modifier checks require actual matching
Control/Shift press and release events and the expected mask on the target key.
Each chord is followed by an unmodified F12 probe before it is reported as passed.

The pointer sequence contains six 500 ms scrolls: `auto`, `wheel`, then
`continuous`, each with and without an explicit `--window`. A seventh scroll
tests the selected interruption guard. Each of these seven actions prints a
fresh screenshot path and requires the operator to view that exact image and
enter `reviewed X Y`, using image pixels inside the blue fixture scroll area.
Local widget bounds are exposed for inspection and target validation; the runner
does not choose coordinates. Piped approval is rejected. Finish each review
within about 26 seconds, or 17 seconds for the final 10-second scroll, so the
frame has time to remain valid for the whole action. Expired review aborts.

For `--guard cancel`, the runner waits until the observer receives an axis event,
sends SIGTERM to that hyprhand scroll process, and requires a `Cancelled` result.
After a short queue-drain interval it requires no further received scroll events.
Cancellation is terminal: there is no retry, follow-up input, or re-enable.
Finally, the runner calls `stop` only if the original control token is still
present and unchanged. The externally launched fixture and session remain for
the operator to close. `--guard stop` is a separate terminal scenario expecting
`ControlStopped`; it is never followed by re-enabling. Human stop or token
replacement also ends the run. Renewed authorization is required before
re-enabling after a human stop.

## Read-only observer contract

The runner reads a bounded, append-only NDJSON file, checks its ownership and
identity, and binds `ready` to the live fixture PID/start time and managed
session. Each action ignores older records and requires fresh receiver evidence.
The fixture has no command channel; observing a record causes no input.

| Record | Evidence |
| --- | --- |
| `ready` | Schema, PID/start time, session/runtime/display/instance, title, GTK version on new fixtures |
| `snapshot` | Focused entry, first-entry text/selection/cursor, active state and widget bounds local to the window; emitted every 100 ms |
| `key-press`, `key-release` | Received keysym, hardware keycode, GTK modifier mask and entry focus |
| `modifiers` | GTK controller's observed mask transition while processing a key event |
| `scroll` | Controller deltas, raw GDK deltas, wheel/surface units, direction and stop marker |
| `scroll-begin`, `scroll-end` | GTK scroll-controller lifecycle notifications |

A final modifier release may carry its previous mask. GTK does not guarantee a
standalone `modifiers=0` callback before another key arrives. Balanced physical
releases plus F12's zero mask are the test's release evidence; the runner never
fabricates a zero callback. Focus assertions require a real observed transition,
so merely dispatching Shift+Tab with a Shift mask does not pass backward traversal.

Wheel tests require wheel units only and exactly four requested detents. A late
surface delta is a failure, even if the preceding four wheel events were correct.
For the tested 500 ms duration, auto and continuous require progressive surface
events. The drawing area has no scrolling inertia or animation, so the observer
measures received input rather than changes in an application's scroll position.

## Offline checks

```sh
python3 -B tests/fixtures/test_reliability_contract.py
python3 -B -O tests/fixtures/test_reliability_contract.py
```

These use mocked process, observer and review boundaries. They cover permission
gates, token lifecycle, receiver assertions, all six pointer variants and terminal
cancellation. They do not start GTK, invoke hyprhand, send signals to real
processes, choose live coordinates, or substitute for a live managed-session run.
