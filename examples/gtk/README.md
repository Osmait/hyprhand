# GTK note demo

A small, local GTK4 application for learning hyprhand's **observe → act → verify**
workflow. It has a text field, an **Apply text** button, and a visible result.
Applying text only updates this window; it does not save files or use the network.

## Requirements

- A built/installed hyprhand and a working Hyprland session.
- Python 3 with PyGObject (`gi`) and GTK4 typelibs.
- `grim` for screenshots; `hyprhand-pip` for the optional preview.

This example is source-checkout material. It is not installed with the CLI binary.
Use a terminal in the original host environment and run from the repository root.

## 1. Launch an independent desktop and the demo

```sh
hyprhand session create note-demo --nested
hyprhand enable --session note-demo
hyprhand launch --session note-demo -- python3 "$PWD/examples/gtk/note.py"
hyprhand wait window --session note-demo --class org.hyprhand.NoteDemo
hyprhand windows --session note-demo
```

Nested mode opens a compositor window. Compatible systems can omit `--nested`
for headless operation. The screenshots preserve the former deskctl name. Current commands and the app
use Hyprhand. The screenshots in the README used Hyprland 0.56.2 /
Aquamarine 0.15.0 with the explicitly selected experimental headless bridge,
a 1280 × 720 output, and a centered 860 × 560 application window. Window position,
size, decoration, theme and button coordinates will vary in your session.
See [the bridge guide](../../docs/experimental-bridges.md) for that optional setup.

From the returned `data` array, copy the `address` of the window whose `class`
is `org.hyprhand.NoteDemo`. Replace `WINDOW_ADDRESS` below with that address.

## 2. Focus and observe

```sh
hyprhand focus WINDOW_ADDRESS --session note-demo
hyprhand wait focus --session note-demo --window WINDOW_ADDRESS
hyprhand wait stable --session note-demo --pixels
hyprhand observe --session note-demo
```

Open `frame.image_path` in an image viewer. You should see **Draft note** in the
focused field and **Waiting for input** below the button.

## 3. Type, then inspect a fresh image

```sh
hyprhand key ctrl+a --session note-demo --window WINDOW_ADDRESS
hyprhand type --session note-demo --window WINDOW_ADDRESS \
  --text 'Hello from hyprhand! Unicode: ñ ✓'
hyprhand wait stable --session note-demo --pixels
hyprhand observe --session note-demo
```

View the new image and confirm the exact text. A command returning before GTK's
next paint can yield an unchanged immediate screenshot; waiting for stable pixels
helps, but viewing the result is still required.

## 4. Apply and verify

Read the latest `frame.frame_id` and choose the **Apply text** button's center in
that PNG. Replace `FRAME_ID`, `BUTTON_X`, and `BUTTON_Y`; do not reuse coordinates
from the README image as if they came from your session.

```sh
hyprhand click --session note-demo --window WINDOW_ADDRESS \
  --frame FRAME_ID --x BUTTON_X --y BUTTON_Y --dry-run
hyprhand click --session note-demo --window WINDOW_ADDRESS \
  --frame FRAME_ID --x BUTTON_X --y BUTTON_Y
hyprhand wait stable --session note-demo --pixels
hyprhand observe --session note-demo
```

Both the real click and dry run must use an unexpired frame (30 seconds).
If review takes longer or geometry/focus changes, observe and inspect again.
The result should show **Text applied successfully** and the exact typed text.
That application state is the verification; `status: sent` alone is insufficient.

## 5. Preview and cleanup

In a separate terminal:

```sh
hyprhand preview --session note-demo --fps 5
```

Close exits only the viewer. **Stop input** disables hyprhand control while leaving
the application open. When the demonstration is finished:

```sh
hyprhand stop --session note-demo
hyprhand session destroy note-demo
```

Destroy only the session you created. Profiles/logs remain for diagnosis; no
user document is created by this sample application.
