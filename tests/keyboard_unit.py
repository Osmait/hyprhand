#!/usr/bin/env python3
"""Compile/run keyboard.zig unit tests; no Wayland connection or desktop input.

This isolated runner complements zig build test and strips inherited desktop
connection settings before running only the keyboard tests.
"""
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    # Prevent accidental connection to any inherited desktop in future tests.
    env = dict(os.environ)
    for name in ("WAYLAND_SOCKET", "WAYLAND_DISPLAY", "DISPLAY",
                 "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS"):
        env.pop(name, None)
    with tempfile.TemporaryDirectory(prefix="hyprhand-keyboard-unit-") as directory:
        env["XDG_RUNTIME_DIR"] = directory
        generated = Path(directory)
        protocols = {
            "wlr-virtual-pointer-unstable-v1": "virtual-pointer",
            "virtual-keyboard-unstable-v1": "virtual-keyboard",
            "wlr-layer-shell-unstable-v1": "layer-shell",
            "ext-image-copy-capture-v1": "ext-image-copy-capture-v1",
            "ext-image-capture-source-v1": "ext-image-capture-source-v1",
            "ext-foreign-toplevel-list-v1": "ext-foreign-toplevel-list-v1",
        }
        sources = []
        for protocol, output in protocols.items():
            xml = root / "protocols" / f"{protocol}.xml"
            subprocess.run(["wayland-scanner", "client-header", str(xml),
                            str(generated / f"{output}.h")], check=True, env=env)
            source = generated / f"{output}.c"
            subprocess.run(["wayland-scanner", "private-code", str(xml),
                            str(source)], check=True, env=env)
            sources.append(str(source))
        xdg = generated / "xdg-shell.c"
        subprocess.run(["wayland-scanner", "private-code",
                        str(root / "protocols/xdg-shell.xml"), str(xdg)],
                       check=True, env=env)
        # Zig 0.17 has no @cImport: translate the C import header the same
        # way build.zig does and pass it as the native_c module.
        cflags = subprocess.run(["pkg-config", "--cflags", "wayland-client", "xkbcommon"],
                                check=True, env=env, capture_output=True, text=True).stdout.split()
        native_c = generated / "native_c.zig"
        with native_c.open("w") as out:
            subprocess.run(["zig", "translate-c", "-lc", "-I", directory, *cflags,
                            "src/platform/native_c.h"], cwd=root, env=env, check=True, stdout=out)
        subprocess.run(["zig", "test", "-lc", "-lwayland-client", "-lxkbcommon",
                        "-I", directory, *sources, str(xdg),
                        "--dep", "native_c", "-Mroot=src/test_keyboard.zig",
                        f"-Mnative_c={native_c}"], cwd=root, env=env, check=True)


if __name__ == "__main__":
    main()
