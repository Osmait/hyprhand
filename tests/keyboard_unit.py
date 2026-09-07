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
    with tempfile.TemporaryDirectory(prefix="deskctl-keyboard-unit-") as directory:
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
        subprocess.run(["zig", "test", "src/keyboard.zig", "-lc",
                        "-lwayland-client", "-lxkbcommon", "-I", directory,
                        *sources, str(xdg)], cwd=root, env=env, check=True)


if __name__ == "__main__":
    main()
