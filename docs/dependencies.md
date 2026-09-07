# Dependencies and installation

The CLI links system libraries. Binary archives target Linux x86_64/glibc and
record their build environment; they are not universal, self-contained, or static
executables. See [compatibility](compatibility.md) and [packaging](../packaging/README.md).

## Requirements by feature

| Scope | Dependencies |
| --- | --- |
| CLI build | Zig 0.16.x (CI/package pin: **0.16.0**), `pkg-config`, `wayland-scanner`, libc and headers for Wayland client, xkbcommon, AT-SPI, GLib/GObject |
| Offline tests and packaging | Python 3.11+ (CI uses 3.12), Git, `readelf` and `strip` from binutils |
| CLI runtime | Linux with pidfd support (5.3+), matching ELF loader/library ABIs, Hyprland IPC and the selected session's Wayland socket |
| Screenshots | `grim` |
| Optional preview | GTK4 >= 4.8; build with `zig build pip`; keep `deskctl-pip` beside `deskctl`; `grim`; tested Hyprlang/Lua hosts. Excluded from the default CLI archive |
| XWayland keyboard/scroll | `xdotool`, XWayland server, and target window's matching `DISPLAY` |
| Wayland helper keyboard | `wtype` for `--backend helper`; not needed by the native keyboard |
| Managed sessions | `Hyprland`, `dbus-daemon`; `at-spi2-registryd` and accessible widgets for AT-SPI |
| Live graphical fixtures | Python GI, GTK4 and AT-SPI; explicitly enabled, excluded from default checks |
| Blender example | Blender and the supplied original room; not a CLI dependency |

Native keyboard maps are self-contained. They require **libxkbcommon**, but not
`xkeyboard-config` data files or `/usr/share/X11/xkb`. Environment-provided XKB
includes and names are not used to build those maps. Other applications and
external helpers can have their own requirements.

## Build packages

The CI workflow installs these packages on Ubuntu 22.04 and 24.04:

```sh
sudo apt-get update
sudo apt-get install -y libwayland-dev libwayland-bin libxkbcommon-dev \
  libatspi2.0-dev libglib2.0-dev pkg-config libc6-dev python3 binutils curl xz-utils
```

Install Zig 0.16.0 separately and ensure `zig version` matches `.zigversion`.
The workflow downloads the pinned toolchain and verifies its checksum.
These packages prepare a build; they do not create a working Hyprland desktop.
Ubuntu 22.04 also needs Python 3.11+ selected for the lifecycle suite's
`subprocess.Popen(process_group=...)`; CI selects Python 3.12 explicitly.
`libwayland-bin` supplies `wayland-scanner`.

On Ubuntu 24.04, the optional preview build/test job additionally installs:

```sh
sudo apt-get install -y libgtk-4-dev libgtk-4-bin
```

Other distributions should install the equivalent development packages and
verify the pkg-config modules:

```sh
pkg-config --modversion wayland-client xkbcommon atspi-2 gobject-2.0
pkg-config --modversion gtk4       # Only for the optional viewer
wayland-scanner --version
zig version
python3 --version
```

Runtime package names and ABI transitions vary across distributions. Let your
package manager resolve transitive dependencies. AT-SPI requires a reachable bus
and application support; installing its library does not guarantee a useful tree.

## Install and remove

```sh
zig build -Doptimize=ReleaseSafe --prefix "$HOME/.local"
# Optional, matching viewer:
zig build pip -Doptimize=ReleaseSafe --prefix "$HOME/.local"
```

Ensure `$HOME/.local/bin` is on `PATH`. Installed paths relative to the prefix:

```text
bin/deskctl
bin/deskctl-pip                                      (optional)
share/bash-completion/completions/deskctl
share/fish/vendor_completions.d/deskctl.fish
share/deskctl/skills/deskctl/SKILL.md
share/deskctl/skills/deskctl/agents/openai.yaml
```

To uninstall, stop input, close any previews, and explicitly destroy managed
sessions you no longer need. Remove only the files above from the prefix used
for installation, and any skill symlink you created. Retained session profiles
and logs are separate runtime data; inspect them before manual removal.
No Hyprland configuration changes need to be reverted by the normal installer.

## Binary compatibility

The [base manifest](../packaging/dependencies.json) describes feature requirements.
Each archive adds observed pkg-config versions, direct SONAMEs, the ELF interpreter,
and required glibc symbol versions to `dependencies.json`. System libraries are
not bundled; this is not a complete transitive SBOM.

A newer distribution's build can require libraries missing on an older one.
The build glibc version and executable symbol floor describe different things;
neither proves compatibility of all transitive libraries. A package per platform
does not certify a graphical session on that platform.

## Optional C++ bridges

- Headless: Aquamarine **0.15.0**, C++23, pixman and libdrm; restricted to the
  documented Hyprland **0.56.2** stack with a parent Wayland renderer.
- Cursor outline: matching Hyprland **0.56.2** headers/ABI, C++23, OpenGL/GLES 3.0+
  and Hyprlang activation. Lua activation is unsupported in this release.

Build locally for the exact stack and rebuild after compositor/dependency updates.
Scripts also require `sha256sum` and GNU/Linux utilities for build metadata.
See [explicit bridge selection](experimental-bridges.md) and
[hardening and metadata](experimental-hardening.md).

The [Blender example](../examples/blender/README.md) chooses output beside the
open `.blend` or in an existing absolute `DESKCTL_BLENDER_OUTPUT_DIR`. It refuses
to overwrite the open scene, but previously generated output names may be replaced.
It configures a PNG destination and saves a styled scene without rendering.
