# Feature tour

[Animated tour](../../docs/video/hyprhand-tour.gif) ·
[MP4](../../docs/video/hyprhand-tour.mp4) ·
[Script](demo.sh) · [Demo page](northwind.html) ·
[Edit timeline](edit.json) · [Recording metadata](recording.json)

One continuous take of a scripted tour. Every command shown in the terminal really
ran; the terminal prints a one-line summary of each JSON reply. The top half is the
Picture-in-Picture viewer showing the agent's session live.

| Chapter | What it shows |
| --- | --- |
| 1 | `session create` (headless, with the format bridge), `enable`, `launch` |
| 2 | `preview`: the PiP opens on the desktop |
| 3 | The frame contract: `windows`, `observe` → `click` / `type` with a fresh frame |
| 4 | Human takeover: the agent hands a login with password and captcha to the human, `state` reports `human_takeover`, an agent `click` fails with `ControlStopped`, and Return gives control back |
| 5 | `accessibility` reads the new page heading from Brave's AT-SPI tree |
| 6 | Unicode text (`Begoña Muñoz Ibáñez`, `«…»`), a select menu, a slider `drag`, `scroll` |
| 7 | Verification through accessibility, `stop`, `session destroy` |

The intranet is a fictional single-file page ([northwind.html](northwind.html));
no real account, service or personal data is involved.

## How it was recorded

The tour must show the PiP without recording anyone's real desktop, so a second
headless session, `demo-host`, stands in for the desktop.
[stand-in-host.sh](stand-in-host.sh) creates it and exposes it to hyprhand as a
host through an instance alias and a `wayland-demo` socket link. A kitty terminal
inside `demo-host` ran [demo.sh](demo.sh), which created the `agent` session and
opened the preview there. [capture.py](capture.py) grabbed `demo-host` with its
cursor at about 10 fps.

The person's part (Take over, password, captcha, Sign in, Return) was performed
by sending pointer and keyboard input with hyprhand to `demo-host`, that is, to the
PiP window, the way a person's mouse and keyboard would. The PiP forwarded it to
the agent session. The agent's own commands could not act during that time
(`ControlStopped`).

Lines marked `HIDDEN` in the script only arrange the recording: the agent display
is set to 1024 × 576 so the PiP shows it at 1:1, and stage files let the recorder
follow the script. The recorder also enlarged the PiP and moved it to the top.

The edit cuts the waits while the recorder placed the PiP and measured the
person's click targets, and plays segments at 1×–2× ([edit.json](edit.json)). It
adds no captions, synthetic cursor or interpolated frames. The MP4 is
1024 × 1024 at 10 fps; the GIF is 880 × 880 at 8 fps with 128 colours.

## Reproduce

1. Install hyprhand with the bridge (`scripts/install.sh --with-bridge`), Brave,
   kitty and `jq`.
2. Run `examples/tour/stand-in-host.sh`, or use your own desktop and skip the
   alias variables.
3. In a terminal on that desktop, run `examples/tour/demo.sh`. When it asks, press
   **Take over** in the preview, type any password of six or more characters and
   the captcha `7KQ4P`, sign in, and press **Return**. Create the stage files the
   script waits for (`pip-placed`) in `$TOUR_STATE`, by default
   `$XDG_RUNTIME_DIR/hyprhand-tour`.
4. Coordinates in the script match the 1024 × 576 agent display. With another
   size, observe first and adjust them.
