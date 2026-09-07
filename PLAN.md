# deskctl delivery ledger

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

## 0.4 reliability delivery

- [x] Revalidate scoped geometry/focus during pointer actions, excluding only
  the current action's PID-owned aura; explicit pointer --window bounds.
- [x] Abort on external cursor displacement before a subsequent warp. Live
  geometry change prevented a pending click; injected drag interference
  aborted and released the held button in the receiver.
- [x] Native modifier key events plus resolved XKB masks, self-contained maps,
  reverse-order cleanup and fake-wire cancellation/Unicode regressions.
- [x] Independent --scroll-mode auto/wheel/continuous and duration; reject
  unsupported explicit continuous XWayland input.
- [x] Doctor separates prerequisites from operational verification; no default
  claim that managed headless GPU creation or AT-SPI discovery was tested.
- [x] PID/start/uid/pidfd-validated descendant teardown, bounded TERM/KILL,
  launch/destroy lifecycle lock, Firefox profile override checks.
- [x] Dependency manifest, local checksummed release archives, manual private
  Actions artifacts workflow, Ubuntu build matrix, portable Blender output.
- [x] Opt-in managed-only GTK modifier/scroll observer and reviewed live runner.
- [x] Experimental bridge hardening: cursor invalidation/GL resource cleanup,
  initialization rollback, ABI guards and installed checksum metadata. Compiled
  and mock-tested; real long-running/animated GPU coverage remains below.

- [x] Optional host PiP (`zig build pip`, `preview --session NAME`): native
  Zig/GTK4 read-only viewer, cursor-inclusive in-memory capture, instance pinning,
  bounded workers, stop without closing apps, viewer-only close, stale-frame
  clearing, host floating/pinned/no-initial-focus rules. Worker regressions and
  live Hyprlang 0.56.2 / GTK4 4.22.4 checks; see docs/preview.md.

## Maintenance audit — September 2026

- [x] Reproduce and fix IPC trickle deadlines, signal cancellation while reading,
  extreme frame timestamp overflow, and TERM-ignoring viewer/helper teardown.
- [x] Preserve bounded window-rule cleanup after cancellation; use per-check
  token allocation in guards rather than retaining it for the whole action.
- [x] Domain-oriented source directories, extracted observation/help, modular
  native/optional build configuration, contribution guide and audit evidence.
- [x] Single offline `zig build check` path used by CI; package tests include
  the new IPC and preview regressions. Public command/JSON contracts preserved.
- [x] Extract action/wait coordination; share cooperative command deadlines;
  invalidate in-flight enables on stop; cancel initial Wayland synchronization.
- [x] Incrementally bound PiP capture output; scoped Lua PiP rules and cleanup;
  repeat real Wayland input/stop and Lua lifecycle tests in disposable sessions.
- [x] Add opt-in PiP CPU/RSS/worker-latency benchmark; measure 120 s at 5 and
  15 requested fps. Results are not presentation-fps or long-running leak proofs.
- [x] Verify follow-up CI and manual private packaging on Ubuntu 22.04/24.04
  (261fe93: runs 34075926551 / 34075926414); update deprecated Actions to SHA pins.

See [audit scope and follow-ups](docs/audit-2026-09.md). This is not a claim
that all bugs or live platform incompatibilities are eliminated.

## Remaining platform limitations

- [ ] PiP follow-ups: PipeWire/zero-copy higher-fps streaming, automatic placement
  after monitor rotation/resizing, fullscreen/multimonitor and hours-long coverage.
  Lua rules/viewer verified in isolation; live integrated Lua host launcher pending.

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
- Private repository created; 0.4 maintenance matrix passed on Ubuntu 22.04/24.04
  (run 34074547410, commit 4f230f3). Follow-up commits require their own CI result;
  manual packaging verification is tracked separately.
- New live XWayland test requires a managed opt-in startup/display route; current
  managed sessions disable XWayland. Nested managed runtime paths can exceed
  Hyprland's Unix socket limit and currently fail with a generic startup timeout.
- Isolation is input/session isolation, not a filesystem or credential sandbox.
  Portals/systemd user services are not activated from the private bus.
- Reparented unrecorded processes cannot safely be attributed after their
  recorded parent has exited. No process-group-wide or username-wide killing.
- AT-SPI remains read-only in the CLI; the experimental semantic background
  probe is not a general-purpose automation backend.
- No project license is selected; the repository owner must choose it.

Detailed follow-up evidence: [September follow-up](docs/audit-followup-2026-09.md).
- Native owned-input cleanup cannot promise recovery from SIGKILL or compositor
  failure. X11 helpers remain external and lack the same cleanup guarantee.
