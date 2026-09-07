# Experimental compositor bridges

The CLI and input remain Zig. These optional libraries use C++ to interact with
internal Hyprland/Aquamarine APIs. The default build does not need them. They are
compositor libraries, not MCP servers or agent plugins. They do not change drivers,
themes, personal configuration, or physical-seat access.

A library bug can terminate its compositor. Build locally for the exact documented
versions, use a disposable session first, and rebuild after compositor/dependency
updates. Path/version validation is not a security audit or a complete ABI
compatibility guarantee. Only load trusted code.

## Headless format bridge

Requirements: C++23, pkg-config, Aquamarine **0.15.0** headers, pixman and libdrm.
The documented runtime stack is Hyprland **0.56.2**, using a parent Wayland
renderer. The recorded NVIDIA setup fails without this bridge.

```sh
zig build -Doptimize=ReleaseSafe
zig build headless-bridge
./zig-out/bin/hyprhand session create bridge-test \
  --headless-bridge /ABSOLUTE/PROJECT/zig-out/lib/hyprhand-headless-formats.so
./zig-out/bin/hyprhand enable --session bridge-test
./zig-out/bin/hyprhand launch --session bridge-test -- firefox about:blank
./zig-out/bin/hyprhand observe --session bridge-test
# Inspect and complete your test, then:
./zig-out/bin/hyprhand stop --session bridge-test
./zig-out/bin/hyprhand session destroy bridge-test
```

Replace the library path with the actual trusted build. It must be absolute, a
regular file owned by the user or root, not group/other-writable, without a final
symlink, spaces, or `:`. It cannot be combined with `--nested`.

The CLI sets `LD_PRELOAD` only for the new Hyprland process, not hyprhand, the parent,
the private bus/registry, or apps launched by hyprhand. A compositor could propagate
its own environment to processes it launches; do not add `exec` commands to this
experimental configuration. `session inspect` records the selected library.

Aquamarine 0.15.0's headless backend prefers DRM formats and otherwise uses fallback
formats/modifiers. The bridge preserves DRM preference and adds formats already
negotiated by the Wayland backend with the parent. It does not invent modifiers
when no formats exist or provide generic GPU support.

Recorded local result: without the bridge, `HeadlessRenderUnavailable`; with it,
HEADLESS-1 at 1920 × 1080, GTK4 capture and a confirmed click. Hyprlang/Lua lifecycle,
pixel waits, events, workspace changes, no surviving attributable processes after
destruction, and no preload in bus/registry/apps were checked.

```sh
python3 tests/live_sessions.py --live --headless \
  --headless-bridge /ABSOLUTE/PROJECT/zig-out/lib/hyprhand-headless-formats.so
# Repeat with --lua for that configuration provider.
# Existing test session; interactive screenshot review required:
HYPRHAND_TEST_SESSION=bridge-test python3 tests/live_motion.py --live
```

Headless still needs the parent renderer. It cannot operate host windows without
focus or start an independent desktop without a graphical session. Session apps
and profiles are separate; user files and permissions are shared.

## Continuous cursor outline

Requirements: exact Hyprland **0.56.2** headers/ABI, C++23, OpenGL with GLES 3.0+
context, and **Hyprlang** activation. Lua activation is unsupported.

```sh
zig build cursor-plugin
./zig-out/bin/hyprhand session create cursor-test --nested
./zig-out/bin/hyprhand session inspect cursor-test
```

Take the actual `runtime` and `instance` from inspection. The following commands
must target that disposable compositor, and use the actual absolute library path:

```sh
XDG_RUNTIME_DIR=TEST_RUNTIME hyprctl -i TEST_INSTANCE \
  plugin load /ABSOLUTE/PROJECT/zig-out/lib/hyprhand-outline.so
./zig-out/bin/hyprhand enable --session cursor-test --indicator outline
# Inspect the cursor and interact with an explicitly selected test app.
./zig-out/bin/hyprhand stop --session cursor-test
XDG_RUNTIME_DIR=TEST_RUNTIME hyprctl -i TEST_INSTANCE \
  plugin unload /ABSOLUTE/PROJECT/zig-out/lib/hyprhand-outline.so
./zig-out/bin/hyprhand session destroy cursor-test
```

Do not point these commands at the host without deliberately accepting compositor
plugin risk. The plugin checks the headers' commit and dependency ABI hash at
load time and rejects unsupported renderers. Toolchain/build-option mismatches
can still be unsafe.

The plugin uses `getCurrentCursorTexture()` and `getCursorBoxGlobal()`, reads the
texture's transparency, and draws a blue dilation. It does not read desktop
imagery or create an input-catching surface. Cursor changes invalidate the shape;
position and control token are checked approximately every 20 ms, not in real time.

Activation requires the selected session's private `enabled` file. `stop`, token
replacement, or token removal disable the effect. SIGTERM of one action does not
itself revoke `enable`, so the outline can persist until `stop`. The glow indicates
input permission, not proof that every cursor movement came from an agent.

Recorded checks cover arrow/I-beam, pauses, click-through, stop, and isolated
load/unload. Animated cursors, non-RGBA/transformed textures, textures above
256 × 256, all scales/rotations, and long sessions remain unsupported or unverified.
Fully transparent/opaque images have no usable silhouette and show no glow.
Successful activation does not guarantee every future cursor texture is supported.

## Build metadata and limits

Both optional targets install the `.so` and `.so.build-metadata` under the selected
prefix's `lib` directory. Verify the sidecar's `binary_sha256` against the actual
library; metadata is diagnostic text, not something to execute or `source`.
See [experimental hardening](experimental-hardening.md) for GL state preservation,
ABI guards, atomic file publication limits, and historical validation.

Frame v2 and scroll guard behavior remain active with bridges. Local overlays,
global focus and actual layout changes still invalidate frames; expiration remains
30 seconds. Earlier XWayland `StaleObservation` causes were not all conclusively
reproduced, and no guard was disabled to hide them. Scroll uses minimum-jerk pacing
and accumulated native continuous distance or integer XWayland detents. As always,
`status: sent` does not verify application behavior.
