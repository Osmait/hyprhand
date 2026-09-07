# Compatibility matrix — 0.4.0

This matrix distinguishes recorded local tests, automated offline coverage, and
unverified configurations. Results apply only to the versions, applications, and
scenarios in each report. Workflow configuration alone does not prove a successful
remote run. `status: sent` confirms delivery, not the application's outcome.

| Environment or feature | Evidence and scope | Limits |
| --- | --- | --- |
| Ubuntu 22.04/24.04, Linux x86_64/glibc | CI configured with Zig 0.16.0/Python 3.12 for builds, unit tests, fake protocols, lifecycle and offline reliability contracts | No Hyprland or live GUI apps; inspect the run for the exact commit |
| GTK4/Wayland on Hyprland 0.56.2 | Local fixture reports cover text, click/double click, motion, scroll, drag and cancellation | Does not certify other toolkits, versions, GPUs, scales or rotations |
| GTK4/XWayland | Historical X11 fixture results; `tests/live_smoke.py --x11` checks backend, text, click and scroll | Keyboard/scroll use `xdotool`; integer detents, no subpixels or equivalent native cleanup guarantees |
| Hidden workspace, same compositor | [Background probe](archive/background-probe.md) observed AT-SPI text/button actions without fixture focus loss | Targeted `sendshortcut` caused foreground keyboard leave/enter despite unchanged `activewindow`; workspaces do not isolate input |
| Managed nested session, Hyprlang/Lua | Local lifecycle and input records in child windows | Opening/closing the nested window can affect host focus; apps must use Wayland; no file/network/credential sandbox |
| Blender 5.2.1 LTS / native Wayland | Fresh factory-config instance in child compositor: `Shift+F4` switched 3D view to Python console; `Ctrl+Space` maximized that editor; screenshots verified both | **Partial compatibility** only. Other shortcuts, modes, profiles, versions, XWayland, prior scroll and drag issues remain unverified |
| Headless without bridge, recorded NVIDIA stack | Local `HeadlessRenderUnavailable` | No silent fallback to host and no general headless promise |
| Experimental headless bridge | Recorded GTK4 capture/click and lifecycle on **Aquamarine 0.15.0 + Hyprland 0.56.2**, Hyprlang/Lua, NVIDIA | New managed headless session only; explicit `.so`, exact ABI, parent Wayland renderer; cannot combine with `--nested` |
| 0.4.0 headless GTK/Wayland reliability | Ten verified checks covering modifiers, all explicit/implicit scroll modes and cancellation; [report](archive/reliability-040.md) also records exact Unicode, click, 270 px drag and stale-geometry rejection | Exact documented stack and explicit bridge only; does not certify XWayland, Blender, other GPUs, or equal visual scroll distances |
| Optional GTK4 preview | Hyprlang native checks; Lua rule/viewer checks in an isolated compositor; fake-worker and private Broadway regressions | Integrated live Lua host launcher, automatic repositioning, fullscreen/multi-monitor, hours-long and cross-GPU coverage remain incomplete |
| Experimental cursor outline | Arrow/I-beam, click-through and stop in disposable **Hyprland 0.56.2**, OpenGL, Hyprlang compositor | Not automatically built/loaded; Lua activation, animated cursors, all transforms/scales and long sessions unverified |
| Other architectures, musl, distributions or compositors | No established package matrix/local result here | Require independent builds and testing; no binary compatibility promise |

GTK/Wayland/XWayland coverage is limited to the recorded reports and fixture
scopes in `tests/live_smoke.py`, `tests/live_motion.py`, and
`tests/live_advanced.py`. See [experimental bridges](experimental-bridges.md),
[0.4.0 reliability](archive/reliability-040.md), and [audit follow-up](archive/audit-followup-2026-09.md)
for details and open issues. Synthetic observer records check test gates and
success criteria; they do not replace observing a real application.

In Blender, observe after each action and verify the active editor, mode, and
actual result. A Python example that changes a scene and saves a file does not
establish GUI automation support merely because its syntax checks pass.

The headless bridge uses internal APIs. Checking Aquamarine 0.15.0 at build time
does not prove every ABI detail of the loading process. Restrict it to the
documented Hyprland 0.56.2 stack and the new child compositor; never preload it
globally. Private profiles and D-Bus do not isolate user files or permissions.

Packages record platform and dependency metadata, not universal portability.
Read [dependencies](dependencies.md) before installing. Workflows do not change
repository visibility or publish releases/tags. Licensing is described in the
[project README](../README.md).
