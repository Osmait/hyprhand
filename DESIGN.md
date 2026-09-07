---
name: hyprhand borderless PiP
description: Image-first native monitor with integrated controls
colors:
  canvas: "#080c12"
  foreground: "#ffffff"
  control: "#121821"
  stop: "#943546"
  focus: "#8ac4ff"
rounded:
  control: "6px"
---

# Design System: hyprhand PiP

## Overview

The viewer uses no borders and integrates controls into the image. The
captured session is the surface, not content inside a decorated GTK window.
The Operate contract is in `.impeccable/surfaces/src-pip-zig.md`.

## Colors

`src/preview/pip.css` defines a scoped dark canvas, white text, neutral controls and a
muted red stop action. Top and bottom gradient scrims protect text over bright
or dark application imagery. The live state is also written as text; color alone
does not indicate permission. Styles apply only inside this viewer.

## Typography

Use the native font family with 12px labels. The session name ellipsizes; status
wraps to at most two lines and ellipsizes. Tooltips retain the complete text.

## Layout

Default 640 × 360; minimum request 360 × 203 GTK logical pixels. `GtkOverlay`
places the session name and close control at the top, status/stop/resize grip at
the bottom. Neither overlay subtracts space from the image. Contain-fit preserves
all source pixels; mismatched source/window proportions can cause letterboxing.

The top overlay has 10px top / 12px side / 24px bottom padding. The bottom has
26px top / 10px right / 10px bottom / 14px left padding and 10px control gaps.

## Shapes

No window border, rounding, shadow, title bar or allocated footer. Buttons have
small rounded corners; close uses the native symbolic close icon. The resize
grip is two diagonal Cairo strokes, not a text character masquerading as an icon.

## Components

- The image is wrapped in `GtkWindowHandle`: drag non-control content to move
  the viewer. The lower-right 32px grip begins a native southeast resize.
  Compositor move/resize shortcuts remain available.
- Close and stop are permanently visible GTK buttons with tooltips and a visible
  keyboard focus outline. Close exits only the viewer; stop disables hyprhand
  input while leaving applications open. No resume or input-forwarding path.
- States remain connecting, live/enabled, live/stopped, stopping, failed and
  disconnected. Stale or failed captures clear the picture, not the controls.
- GTK supplies font-family selection, widget behavior and accessibility semantics.

## Do's and Don'ts

- Do keep controls integrated into the image and readable over arbitrary content.
- Do preserve visible close/stop, native movement, resizing and keyboard focus.
- Don't restore separate title/footer bars or compositor borders and shadows.
- Don't crop the source just to hide aspect-ratio letterboxing.
- Don't relay clicks or key events into the captured session.

Sources: `src/preview/viewer.zig`, `src/preview/pip.css`,
`src/preview/pip_gtk.h`, `src/preview/controller.zig`.
Historical visual checks are described in [the preview guide](docs/preview.md).
They cover native Linux behavior, not web or theme-matrix certification.
