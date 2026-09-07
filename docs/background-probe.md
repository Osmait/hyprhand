# Hidden-workspace probe in the same Hyprland compositor

Local result: **this does not meet the requirement for general input without
taking focus from the user**. No general background-input backend was implemented.

Historical environment: Hyprland 0.56.2, Hyprlang configuration, GTK4 Wayland test
apps; witness on workspace 1 and target on previously empty, hidden workspace 4.
Both belonged to the same compositor, not a nested session.

## Observed evidence

| Action on hidden target | Target result | Witness keyboard focus events |
| --- | --- | --- |
| Baseline, no action | Unchanged | None |
| AT-SPI `EditableText.set_text_contents` | Exact Unicode text confirmed by GTK | None |
| AT-SPI button `Action.do_action` | `clicked` signal confirmed | None |
| Targeted Hyprland `sendshortcut`, key `a` | Key received and text changed | One `wl_keyboard.leave` and one `wl_keyboard.enter` |

GTK also reported losing/regaining focus during the last phase. End queries and
sampled `activewindow` values still identified the same active window. Cursor and
visible workspaces remained unchanged across all four phases. **Global active
window identity is insufficient to detect transient keyboard focus theft.**
This probe did not measure its exact duration.

The original investigation linked this to Hyprland 0.56.2's `Actions::pass`, which
redirects Wayland seat focus to the target, sends input, and restores prior focus.
Restoring focus is not equivalent to never changing it.

## Scope and limits

- Accessibility text/button success is specific to the GTK4 fixture; it does not
  guarantee arbitrary apps, dialogs, or custom controls.
- Video editors, timeline drags, and hidden-window capture were not tested.
  Observed focus loss already contradicted the requirement, so pointer injection
  was not pursued.
- No content actions were sent to the user's browser or other apps. Setup did
  open/focus temporary windows and alter their arrangement; phase invariance
  does not describe setup.
- Cleanup closed the two test windows, removed empty workspace 4, restored the
  prior foreground browser, and disabled host control. It did not reset the
  cursor over any subsequent human movement.

Arbitrary concurrent GUI work needs isolation beyond separate workspaces.
Managed sessions separate input but require their own rendering/application
validation. The headless limitation recorded at the time of this probe has a
later, narrowly scoped [experimental bridge](experimental-bridges.md); neither
report promises unrestricted invisible video editing.

## Explicitly repeat the probe

```sh
python3 tests/background_probe.py --live --workspace 4
```

Requires the built `zig-out/bin/hyprhand`, Python GI/GTK4/AT-SPI, an unlocked
Hyprlang host, and an unused destination workspace. The operator should not type
during the run. The script verifies window identity and authorization, records
GTK/Wayland events without saving user content, emits JSON, and aborts if the
global active window changes. A run with no observed loss returns
`not_established`, not a universal guarantee.
