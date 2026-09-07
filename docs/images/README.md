# README image provenance

All images referenced here are actual project screenshots or the existing Blender
render. No application screenshot is an AI-generated mockup.

| File | Source and scope |
| --- | --- |
| `note-before.png` | Unedited `deskctl observe` capture of the GTK demo before input |
| `note-after.png` | Unedited capture after native Unicode typing and a frame-guarded click; visible status/text verified |
| `session-preview.png` | `grim` region capture of the actual 640 × 360 deskctl-pip window on the host; only that viewer is included |
| `../../examples/blender/assets/room-styled.png` | Existing procedural room render, with export metadata removed during publication preparation; not a screenshot of live GUI control |

The note demonstration was recorded on 2026-09-07 using deskctl 0.4.0, Hyprland
0.56.2, Aquamarine 0.15.0 and GTK4 4.22.4. A dedicated managed headless session used
the locally built, explicitly selected format bridge, a 1280 × 720 output and an
860 × 560 demo window at (210, 80). The verified click was at image point (301, 358).
Those values describe the recording, not portable automation coordinates.

The host input token remained disabled. The viewer was closed and the task-created
session stopped/destroyed afterward. The before/after images contain only demo
content and the child compositor's background. They are intentionally preserved
at their original resolution without retouching or labels added over the image.

To recreate the interaction, follow [the GTK walkthrough](../../examples/gtk/README.md).
To record new images, copy the relevant `frame.image_path` immediately after
inspection; take a fresh observation for each new action. Inspect captures for
unrelated/private content before checking them in. New screenshots belong here
only when explicitly selected for public documentation.
