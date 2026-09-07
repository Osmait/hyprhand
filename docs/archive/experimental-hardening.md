# Experimental bridge hardening

This historical review supplements [experimental bridges](../experimental-bridges.md).
Plugin loading remains manual and explicit in a disposable instance. Building
loads no library, starts no compositor, and changes no desktop. The headless bridge
remains an explicit choice for a new session; its implementation was not rewritten.

## Review scope

The original review changed `experimental/cursor-outline/plugin.cpp`, both
experimental `build.sh` files, and this report. It did not rewrite backends,
vtables, internal buffers, compositor scheduling, or client frame dispatch.
Cursor textures remain limited to 256 × 256; desktop imagery is not read.

### Cursor invalidation and resources

Hyprland v0.56.2's PointerManager emits `cursorChanged` for surface commits and
buffer changes. The plugin listens even when a texture changes in place, and now
damages both old and current areas immediately: a render can consume the dirty
flag before the next 20 ms timer check.

Each render compares weak reference, texture ID, dimensions, type and transform.
Replacement invalidates the silhouette without retaining old buffers. Recalculation
damages updated bounds again. The timer also detects visibility changes. Static
cursors do not receive continuous pixel reads or an independent animation clock.

Stop, token revocation and unload release the glow and reset dimensions/cache
without requiring a later render. The pinned CGLTexture destructor activates its
EGL context and checks compositor shutdown. If a render pass retains the texture,
its last reference controls destruction; the plugin does not delete compositor-owned
resources.

Cleanup removes timers, listeners and dispatcher and tolerates repetition. It also
runs if initialization throws, because Hyprland v0.56.2 skips `PLUGIN_EXIT` when
removing a plugin whose initialization failed. Timer rearm failure disables the
effect/removes the timer; later activation is rejected until manual reload.
Render/signal/timer callback exceptions disable the effect. This does not promise
recovery from driver faults, fatal signals, or allocation failure during cleanup.

### GL transfers and ABI

Texture reading/creation preserve read framebuffer, pack/unpack buffers, alignment,
row length, row/pixel skips, and 2D texture binding. Buffers are unbound for CPU
memory transfers. A scope guard restores state and deletes the temporary FBO on
early return or exception.

Dimensions must be finite integers before conversion. Non-RGBA, transformed,
oversized, fully opaque/transparent textures, incomplete framebuffer, and GL errors
produce no glow. Read failure clears the old shape and waits for another invalidation
rather than retrying every render. GL error queries consume errors and cannot
preserve the compositor's error queue.

Builds require Hyprland **0.56.2** or Aquamarine **0.15.0**, respectively. The plugin
also checks header tag `v0.56.2`, API `0.1`, and a full commit hash at compile time.
At load it compares commit and Hyprland's dependency ABI hash and requires GL with
GLES 3.0+ for the readback features. Hyprland's dependency hash omits patch versions;
these guards do not establish toolchain/build-option or all internal compatibility.
Rebuild after compositor/dependency updates.

Both builds enable C++ diagnostics, RELRO and immediate symbol binding. Headless
requires linked Aquamarine references to resolve (`-z defs`). The plugin retains
references resolved by the compositor during explicit load; loading is not used
as a build test.

## Build metadata and installation

Each script accepts `SOURCE.cpp OUTPUT.so` and writes `OUTPUT.so.build-metadata`.
`CXX`, when set, must be one executable/path without arguments. C++23, pkg-config,
sha256sum and GNU/Linux utilities are required. pkg-config flags are word-split
without shell evaluation or glob expansion.

Metadata is diagnostic text, never something to execute or `source`. It includes
source/binary SHA-256, compiler, target, flags, versions and C++ library ABI macros.
The plugin also records dependency versions from headers. Metadata is neither a
signature nor a complete ABI guarantee.

Build results are published from a private temporary directory after compilation
and metadata collection. Ordinary build failure preserves the previous result.
Each rename is atomic, but binary/metadata publication is not a two-file transaction;
always compare `binary_sha256` with the actual library.

Optional build targets install both `.so` and sidecar in `zig-out/lib` or the
selected prefix's `lib`, using explicit step dependencies. Generated copies remain
in the build cache at the paths printed by the scripts. After integration,
`zig build cursor-plugin headless-bridge` succeeded and the installed pairs matched:

- `hyprhand-outline.so` / `hyprhand-outline.so.build-metadata`
- `hyprhand-headless-formats.so` / `hyprhand-headless-formats.so.build-metadata`

This only builds, installs and inspects files. It adds no load/preload step and
does not expand ABI guarantees or replace disposable-compositor testing.

## Historical validation and limits

Local checks on 2026-09-06 used GCC 16.2.1, Hyprland 0.56.2 headers and Aquamarine
0.15.0:

- Both optional targets built, including the repeated combined build after sidecar
  installation was integrated; installed binary/sidecar checksums matched.
- Injecting header tag `v99.0.0` failed its static assertion. ELF inspection found
  plugin entrypoints, RELRO, immediate binding and a nonexecutable stack.
- Shell syntax, missing arguments/wrong versions, output paths with spaces,
  metadata checksums, preservation on compiler failure and temporary cleanup passed.
- A temporary isolated C++ harness extracted reviewed functions and mocked GL,
  renderer and timer, with ASan/UBSan. It covered GL state restoration on success,
  exception and failed FBO, immediate invalidation, visibility damage, timer failure,
  token revocation, release without render and repeated cleanup. It created no GL
  context and loaded no plugin. It was not a checked-in compositor integration suite.

No desktop input, plugin load/unload, or GPU test occurred in that hardening review.
Pending disposable-session checks include real theme/client animation, long-lived
resources, actual failed load/unload, multiple outputs, scales, rotations and
drivers. Pixel mutation without a signal or metadata change cannot be detected
by this cache. Compilation and mocks do not prove visual correctness or universal
GPU support. Original Lua/headless restrictions still apply.
