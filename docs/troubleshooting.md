# Troubleshooting

Start with `hyprhand --version` and `hyprhand doctor --session NAME` from the original
owner's Hyprland terminal. Inspect `checks`, `display_matches`, `config_provider`,
and dependency availability. `operation_verified: false` means a check has not
executed the corresponding operation.

Do not blindly retry input after a runtime failure: part of the action may already
have reached the application. Inspect state, take a fresh observation, and verify
the result before deciding what action is still needed.

| Error or symptom | Meaning and next step |
| --- | --- |
| Zig compile-time version error | Use Zig 0.16.x; CI/package verification expects exactly 0.16.0 |
| Missing pkg-config module or header | Install the feature's development packages from [dependencies](dependencies.md) |
| `MissingRuntimeDir`, missing display/instance | Run inside the original Hyprland session environment; do not invent socket names or use an unrelated `DISPLAY` |
| `SessionRequired` | Add an explicit `--session host` or managed session name |
| `ControlStopped` | Input is disabled. Enable only when the operator authorizes control; never override a human stop automatically |
| `ControlBusy` | Another hyprhand input action holds the action lock. Let it finish or stop it; do not delete locks to bypass serialization |
| `StaleObservation` | Frame expired or relevant focus/layout changed. Focus the intended window, observe again, inspect the PNG, and use its new frame ID |
| `FrameNotFound`, `InvalidFrameId` | Use the exact `frame.frame_id` from the selected session; old captures may have been collected |
| `SessionMismatch` | The frame or runtime belongs to a different session/display. Obtain a new observation from the intended session |
| `WindowNotFocused` | Focus the exact window address from `windows`, wait for focus, then observe before input |
| `PointerOutsideTarget` | Initial/click coordinates are outside the explicit `--window`. Choose a point inside that window in the actual PNG |
| `CursorPositionMismatch` | Human movement, pointer locking/recentering, or compositor constraints interrupted the expected path. Inspect state and resolve interference before acting |
| `NativeCaptureUnavailable` | Screenshots use `grim` in 0.4.0. Use `--backend auto` or `helper` |
| `XWaylandHelperMissing`, `X11TargetMismatch` | X11 keyboard/scroll needs `xdotool` and the target's matching `DISPLAY`/focus. Managed sessions currently disable XWayland |
| `ContinuousScrollUnavailable` | Explicit continuous scrolling is unsupported on XWayland. Select wheel mode if suitable; verify visible results |
| `HeadlessRenderUnavailable` | GPU buffer allocation failed. Read the reported session's `compositor.log`; use explicit nested mode or review the exact-version experimental bridge |
| `SessionStartupFailed`, `SessionStartupTimeout`, `SessionConfigInvalid` | Read `compositor.log` at the session path. Check Hyprland/dependencies/config provider; create sessions from the original host to avoid overly long nested socket paths |
| `PreviewHelperMissing` | Build `zig build pip` and install `hyprhand-pip` beside the matching CLI |
| `PreviewManagedSessionRequired` | Preview only accepts an explicit managed session, never `host` |
| `PreviewIdentityMismatch` | The source ended or was recreated. Close the old viewer and explicitly open a new one |
| Preview shows **No signal** | Source is locked/unavailable, capture failed, or the frame is stale. Inspect that session and `grim`; the old image is intentionally cleared |
| `OutlinePluginUnavailable`, `OutlineRequiresHyprlang` | Outline requires manual plugin loading in a compatible Hyprlang compositor. Activation failure keeps input disabled |
| `AuraUnavailable`, `AuraBufferUnavailable`, `AuraGeometryUnsupported` | The per-action halo cannot be shown. Inspect the output/protocols; choose `--no-aura` explicitly if input without the indicator is appropriate |
| `WaitTimeout` | Requested state did not become true within the total deadline; check exact class/address/workspace and application behavior |
| `CommandTimeout`, `Cancelled` | Inspect the application for partial delivery. Native owned-input cleanup runs for ordinary cancellation; completed effects are not undone |
| Empty AT-SPI tree | Bus/registry or app accessibility may be unavailable. Inspect the correct session; custom controls may expose no nodes |

## Unexpected target or geometry changes

Pointer coordinates come from the captured image, not physical monitor pixels or
a scaled preview. Focus the destination before capturing. Hover-to-focus can change
focus during approach, and dragging a compositor window can invalidate its own
frame. Neither situation is a reason to bypass frame checks.

## Preview placement and performance

The preview uses compressed PNG capture, not PipeWire/zero-copy streaming.
Its configured fps is a maximum; static content backs off to 1 fps. It may take
up to a second to notice activity after idle. Resizing the viewer does not increase
capture resolution. After monitor rotation/resizing it may need to be moved back
onscreen with compositor bindings. Fullscreen stacking depends on Hyprland.

## Useful diagnostics for a report

Include the source commit, hyprhand/Zig/Python versions, distribution, Hyprland and
Aquamarine versions, GPU, config provider, host/nested/headless mode, backend,
and exact redacted reproduction steps. Record whether a bridge is loaded and
whether the failure was seen by the application or only in command output.

`hyprhand logs --session NAME --limit 20` contains redacted action metadata.
`session inspect NAME`, `doctor`, compositor logs, and screenshots may reveal
private paths or content; review them before sharing. Do not upload browser
profiles, runtime authorization files, credentials, or unrelated desktop captures.
Use [security reporting](../SECURITY.md) for suspected vulnerabilities.
