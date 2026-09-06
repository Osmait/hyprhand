# deskctl 0.3 delivery

Scope: CLI only, no MCP. Preserve host configuration and user applications.

- [x] Runtime: bounded geometry/pixel waits, compositor event stream, continuous
  focus/lock/control checks, signal cancellation, chunked long-text input.
- [x] Actions: double click, cancelable drag, observable owned-button release.
- [x] Smooth default pointer approach and drag: minimum-jerk straight paths,
  distance-based 200–600ms approach, --move-duration-ms override (0 = instant),
  wall-clock pacing, exact destination and per-step cancellation/position checks.
  GTK4 host verification: motion samples, click/doubleclick/scroll/drag,
  SIGTERM prevents a pending click; stop releases a held drag button.
- [x] Blue cursor aura: native Wayland layer/subsurface, input-transparent,
  no keyboard focus, per-action lifetime, --no-aura opt-out. Real rotated-output
  screenshot inspected; clicks pass through and stop leaves no aura layers.
- [x] Operations: redacted action logs with rotation, exact-target frame GC,
  install/completions/CI and versioned documentation.
- [x] Agent integration: repository skill, metadata validation and independent
  forward test using real state and a screenshot, without desktop input.
- [x] Sessions: create/list/inspect/launch/destroy, private IPC/Wayland/D-Bus/XDG
  profiles, no host DISPLAY, physical-seat acquisition disabled, nested mode
  verified without host cursor/focus interference during input.
- [x] Backends: Lua dispatch verified on a real managed compositor; bounded
  read-only AT-SPI tree; native Zig Wayland keyboard; helper benchmarks.
- [x] Verification: 16 unit + 33 fake-compositor tests; actual Wayland/XWayland;
  doubleclick/drag/cancellation/AT-SPI; session lifecycle and orphan checks;
  real pixel waits/events/workspace changes in Hyprlang and Lua; ReleaseSafe.

## Follow-up delivery

- [x] Scoped frame v2 revisions: unrelated output layers/clients excluded;
  crossing windows, local overlays and global focus remain safety dependencies.
- [x] Progressive scroll, duration override, native axis-stop cleanup and
  paced discrete XWayland fallback; signed totals/cancellation unit tests.
  Live headless fixture: reverse/horizontal/instant events, SIGTERM during scroll,
  movement/click/doubleclick/drag and stop-triggered button release verified.
- [x] Optional real-cursor outline plugin, tested only in a disposable
  compositor: arrow/I-beam, pause lifetime, click-through, stop and unload.
- [x] Optional Aquamarine 0.15.0 headless format bridge, explicitly scoped to
  the child compositor. NVIDIA 1920x1080 capture/click verified; Hyprlang/Lua
  lifecycle, private environment and cleanup tested.

## Explicit limitations, not claimed complete

- [ ] Outline production hardening: long-running/animated cursor coverage,
  all scales/rotations and Lua activation; host loading is deliberately manual.
  Experimental bridges use C++; the CLI/input code remains Zig.
- Same-compositor hidden-workspace input is not isolated: the GTK4 background
  probe observed a foreground Wayland keyboard leave/enter on targeted
  sendshortcut, despite unchanged global activewindow. AT-SPI text/button
  actions worked without focus loss only in the fixture. See
  docs/background-probe.md; arbitrary video-editor interaction is unverified.
- [ ] General headless compatibility beyond the tested stack: without the
  optional bridge this NVIDIA setup still fails. No automatic preload, driver
  changes or physical-seat access. See docs/experimental-bridges.md.
- Exact historical X StaleObservation cause was not reproduced conclusively;
  scoped invalidation regressions are fixed without suppressing safety checks.
- Native capture remains deferred after measurement: grim observation median
  25.23 ms including CLI overhead. Native keyboard was worthwhile (40.36 ms
  versus helper 750.24 ms for the same 180-codepoint input in ReleaseSafe).
- Remote CI execution requires publishing the repository; configuration is
  supplied, but no remote run or passing badge is claimed.
- Isolation is input/session isolation, not a filesystem or credential sandbox.
  Portals/systemd user services are not activated from the private bus.
- Native owned-input cleanup cannot promise recovery from SIGKILL or compositor
  failure. X11 helpers remain external and lack the same cleanup guarantee.
