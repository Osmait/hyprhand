# Blender room example

This optional example demonstrates a room created with hyprhand-assisted GUI work
and then styled with Blender's Python API. It is not required by hyprhand and is
excluded from the CLI binary archive. The recorded application version is Blender
5.2.1 LTS; other Blender versions need their own validation.

## Files

| File | Purpose |
| --- | --- |
| `assets/room-original.blend` | Original editable room geometry, with English object names |
| `assets/room-styled.blend` | Styled scene with materials, furniture details, camera and lighting |
| `assets/room-styled.png` | Existing rendered illustration; personal export metadata removed |
| `style_room.py` | Styling pass using procedural geometry/materials and no external assets |

The source assets were renamed and their scene labels translated for publication.
Geometry and object transforms were preserved; render destinations are now relative.
The PNG retains its original compressed pixel data. Do not treat the illustration
as evidence that every Blender GUI command or workflow is supported.

## Run the styling pass

1. Open `assets/room-original.blend` in Blender. The script expects its named room
   objects, beginning with `01 Floor`; a factory-empty scene will not work.
2. Create an output directory outside the checked-in assets, such as the repository's
   ignored `output/blender-demo/`.
3. Open Blender's Python console and run the following with your actual absolute
   checkout and output paths:

```python
import os
from pathlib import Path
os.environ['HYPRHAND_BLENDER_OUTPUT_DIR'] = '/ABSOLUTE/PROJECT/output/blender-demo'
script = Path('/ABSOLUTE/PROJECT/examples/blender/style_room.py')
exec(compile(script.read_text(), str(script), 'exec'))
```

The output directory must already exist and be absolute. If the environment
variable is unset, output goes beside the currently open `.blend`. An unsaved
scene requires the explicit environment variable. Use a separate directory to
avoid replacing the supplied styled example.

The script modifies the current scene, saves `room-styled.blend`, and configures
`room-styled.png` as its render destination. **It does not render.** Start rendering
in Blender if desired. Existing generated output names may be replaced on reruns;
saving over the currently open scene path is rejected. The styling pass removes
objects marked as its own generated output before rebuilding them.

It sets a deterministic geometry seed, procedural materials, Cycles, camera,
lighting, and render settings. It attempts available OptiX GPU configuration and
falls back to CPU when that setup is unavailable. Actual rendering speed and GPU
support depend on your Blender installation.

## Verification scope

Offline packaging tests execute only the path-selection preflight with plain
Python stubs, without importing `bpy` or running the styling pass. Publication
preparation also reopened both renamed assets in background Blender and checked
geometry/data counts and relative output paths. It did not render or exercise
GUI input. Historical GUI verification is limited to the two shortcuts described
in [compatibility](../../docs/compatibility.md).
