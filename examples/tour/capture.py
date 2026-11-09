"""Capture the demo-host output with its cursor at ~10 fps until $TOUR_STATE/stage-stop exists.

Usage: python3 capture.py DEMO_HOST_RUNTIME_DIR OUTPUT_DIR
"""
import json
import os
import subprocess
import sys
import time

D = os.environ.get("TOUR_STATE") or os.path.join(os.environ["XDG_RUNTIME_DIR"], "hyprhand-tour")
runtime, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
env = dict(os.environ, XDG_RUNTIME_DIR=runtime, WAYLAND_DISPLAY="wayland-1")
period = 0.1
stamps = []
start = time.monotonic()
index = 0
while not os.path.exists(f"{D}/stage-stop"):
    due = start + index * period
    now = time.monotonic()
    if now < due:
        time.sleep(due - now)
    path = f"{out}/f{index:06d}.jpg"
    taken = time.monotonic() - start
    result = subprocess.run(["grim", "-c", "-t", "jpeg", "-q", "92", "-o", "HEADLESS-1", path],
                            env=env, capture_output=True)
    if result.returncode == 0:
        stamps.append([index, round(taken, 3)])
    index += 1
json.dump(stamps, open(f"{out}/stamps.json", "w"))
print(f"captured {len(stamps)} frames in {time.monotonic() - start:.1f}s")
