# Audit follow-up — 2026-09-06

Historical base: `4f230f3`. Scope: complete locally verifiable maintenance work,
without equating passing tests with absence of bugs or universal compatibility.
Frame v2, DCP1 and public command names were preserved.

## Implementation

- Extracted `input/actions.zig` and `runtime/wait.zig`, leaving `main` at roughly
  220 lines. Algorithms and contracts remain in domain modules.
- Shared monotonic budgets for waits, queries, observation and input. Repeated
  slow queries no longer renew a wait's deadline. Cleanup and persistent
  processes keep separate budgets.
- `stop-generation` and `control.lock` prevent an in-flight enable from publishing
  authorization after a stop invalidates it. No compositor query holds that lock.
- Nonblocking PiP capture pipe with an incremental 8 MiB limit. Endless-output
  helpers are rejected and reaped even if they ignore SIGTERM.
- Initial Wayland synchronization checks cancellation before a runtime exists;
  release of already queued input remains noncancelable.
- X11 checks use the routed environment, like the input helper, and the command's
  remaining time rather than accidentally inheriting the host DISPLAY.
- Scoped Lua preview rules use internal identifiers, validate replies, and have
  bounded signal cleanup. External names are not interpolated into Lua.
- Added an opt-in read-only preview benchmark for worker latency and viewer
  CPU/RAM including reaped children. It neither enables input nor changes source apps.

## Historical test results

`zig build check -Doptimize=ReleaseSafe` passed 27 Zig units and 112 Python tests
(139 total). Debug units, nine overlapping isolated keyboard units, GTK4
ReleaseSafe build and syntax/format checks also passed.

The stop/enable race and composite wait regressions failed on the old binary and
passed after fixes. Other regressions covered unlimited helper output, cancellation
during Wayland bootstrap, and viewer termination with Lua rules.

Live checks used disposable sessions, without enabling host control:

- GTK4 Wayland: Control/Shift combinations, text selection, focus navigation,
  and application-observed modifier release.
- Six scrolls: auto/wheel/continuous with and without explicit window. Fresh
  screenshots were inspected and receiver events confirmed units/progression.
  Terminal stop rejected the action and ended new axis events.
- Lua headless lifecycle: create, route, pixel wait, events, workspace, launch,
  environment, teardown and absence of surviving attributable processes.
- Hyprlang PiP: two 120 s samples, unchanged endpoint host focus, stopped source
  unchanged, and viewer close without source destruction.
- Lua PiP: rule expression and native viewer in an isolated compositor, real
  imagery, 640 × 360, floating/pinned, no initial focus and cleanup. The integrated
  launcher had offline coverage, not a complete live host-launcher test.

Created sessions were destroyed; temporary profiles/logs remained under the
session-destroy contract. No user files or main compositor configuration were changed.

## Historical PiP measurements

Hyprland 0.56.2, Aquamarine 0.15.0, NVIDIA with explicit headless bridge, GTK4
4.22.4, ReleaseSafe. Static GTK source: 1920 × 1080, reduced to 960 × 540 PNG,
median 32,525 bytes. This was not animated video.

| Configured fps | Duration | Worker median / p95 | Viewer + children CPU¹ | Final viewer RSS | Last 30 s RSS range |
| --- | --- | --- | --- | --- | --- |
| 5 | 120.02 s | 100.03 / 109.05 ms | 50.61% | 136.41 MiB | 2.29 MiB |
| 15 | 120.02 s | 99.55 / 111.26 ms | 76.63% | 137.98 MiB | 2.17 MiB |

¹ Percentage of one CPU core, including reaped children, excluding compositor/GPU.
RSS covers only the viewer. The first run included GTK startup; the second used
5 s warmup. Thirty worker latencies were sampled separately before each viewer.
Configured fps was not measured presentation fps. Two minutes without apparent
sustained growth does not prove long-term leak freedom. These results supported
a 5 fps default; PipeWire/zero-copy would need a new backend and separate measurement.
See [later offline performance work](performance-2026-09.md) before comparing numbers.

## Remaining limitations found

- Rotating/resizing a monitor can leave PiP partly offscreen; reproduced with
  Lua output scale 1.5 and 90° rotation. Automatic repositioning and fullscreen/
  multi-monitor validation remained missing.
- Managed sessions disable XWayland. Toggling it dynamically did not start a
  server on this version. Host X11 was outside scope; historical live and offline
  evidence remained, without a new live X11 run. Managed opt-in startup is pending.
- Starting a session from an already managed runtime exceeded Hyprland's Unix
  socket path limit (`Socket2 path is too long`), timed out, and cleaned up.
  Early diagnosis of overly long runtime paths remains missing.
- Compressed captures remain the backend; zero-copy, hours-long tests, animated
  cursors, and additional GPUs remain pending. No drivers were installed.
- Budgets are cooperative, not proof against native-library blocking or every
  possible helper disk-output problem.
- The project license had not been selected at the time of this report.

## Remote evidence recorded at the time

The `4f230f3` CI passed on both Ubuntu versions
([run](https://github.com/Osmait/computer-use-hyperland/actions/runs/34074547410)).
Follow-up `261fe93` passed
[CI](https://github.com/Osmait/computer-use-hyperland/actions/runs/34075926551)
and [manual packaging](https://github.com/Osmait/computer-use-hyperland/actions/runs/34075926414).
No tag or GitHub Release was created. Those runs exposed Node 20 action warnings;
checkout/setup-python/upload-artifact were subsequently updated to SHA-pinned v7
actions. The workflow update needs its own run; historical results do not verify
later commits or the current publication-preparation changes.
