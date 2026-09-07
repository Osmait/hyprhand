# Real-cursor outline: capture probe and experimental backend

The requested effect is a blue glow following the actual arrow silhouette,
without a ring, for the entire enabled interval (`enable` → `stop`), including
pauses. The native probe could not obtain a usable silhouette on the recorded
stack. A later optional plugin was tested in a disposable compositor; see
[experimental bridges](../experimental-bridges.md). The per-action circular aura
is a separate feature. The probe did not alter the cursor theme or load a host plugin.

## Historical investigation

Hyprland 0.56.2 advertises `ext_image_copy_capture_manager_v1` and
`ext_output_image_capture_source_manager_v1`. The read-only `_cursor_probe`
requests only the cursor image, not desktop content, and does not save its pixels.

An initially hidden cursor yielded no usable capture constraints. After moving
within a disposable GTK4 window onto its test button, without clicking, the
immediate result was:

```json
{"ok":true,"width":24,"height":24,"hotspot":{"x":5,"y":1},"transparent":576,"nontransparent":0,"entered":true}
```

The request succeeded, but **all 576 pixels were transparent**. No silhouette
was available for an accurate glow. The probe now includes `usable_shape` so
protocol success is not confused with useful imagery. Fully opaque buffers are
also rejected because they might represent compositor redaction.

The original investigation traced this to Hyprland 0.56.2's
`CCursorshareSession::render`: it produces transparency when
`cursorImage.surface`, its buffer, or texture is absent. A compositor-provided
cursor need not have an application surface. The result was not attributed to
permission denial: `enter` was received and the buffer was transparent, not
opaque black.

This does not establish behavior for every compositor or application cursor.
No permissions, drivers, or compositor code were changed. Only the temporary
window was closed and control was left stopped.

## Later result

`experimental/cursor-outline/plugin.cpp` reads the internal cursor texture
without function hooks and overcame that limitation in the test session.
Arrow/I-beam, click-through, persistence during pauses, disappearance on stop,
and unload were verified. Loading it into any host remains explicit because it
executes inside the compositor.

The CLI remains Zig. This diagnostic and its vendored protocols alone do not
implement the continuous indicator. To build and run the diagnostic:

```sh
zig build
./zig-out/bin/hyprhand _cursor_probe --session host
```

Its output is diagnostic and is not a stable public automation contract.
