#!/usr/bin/env python3
"""Offline checks only. Invoked by zig build check after compilation/unit tests."""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    env = dict(os.environ)
    # Defense in depth: these suites create their own sockets/process fixtures.
    # Never add live_*.py or desktop probes to this default verification path.
    for name in ("WAYLAND_SOCKET", "WAYLAND_DISPLAY", "DISPLAY",
                 "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS",
                 "AT_SPI_BUS_ADDRESS"):
        env.pop(name, None)
    suites = [
        ["scripts/check_docs.py"],
        ["tests/integration.py"],
        ["tests/ipc.py"],
        ["tests/keyboard_protocol.py"],
        ["tests/session_lifecycle.py"],
        ["tests/preview.py"],
        ["tests/fixtures/test_reliability_contract.py"],
        ["-m", "unittest", "discover", "-s", "packaging", "-p", "test_*.py", "-v"],
    ]
    for suite in suites:
        print(f"Checking: {' '.join(suite)}", flush=True)
        subprocess.run([sys.executable, "-B", *suite], cwd=ROOT, env=env, check=True)


if __name__ == "__main__":
    main()
