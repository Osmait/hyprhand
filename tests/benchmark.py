"""Read-only capture/state benchmark; no input and no application data output."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--session", default="host")
parser.add_argument("--samples", type=int, default=15)
opt = parser.parse_args()
assert 1 <= opt.samples <= 100
binary = Path(__file__).resolve().parents[1] / "zig-out/bin/deskctl"
results = {}
for command in ("state", "observe"):
    elapsed, capture = [], []
    for _ in range(opt.samples):
        started = time.perf_counter()
        proc = subprocess.run([str(binary), command, "--session", opt.session], capture_output=True, text=True, timeout=12)
        value = json.loads(proc.stdout)
        if proc.returncode:
            if value["err"]["code"] == "StaleObservation": continue
            raise RuntimeError(value)
        elapsed.append((time.perf_counter()-started)*1000)
        if command == "observe": capture.append(value["capture_duration_ms"])
    if not elapsed: raise RuntimeError("No stable samples")
    results[command] = {"samples": len(elapsed), "median_ms": round(statistics.median(elapsed), 2), "max_ms": round(max(elapsed), 2)}
    if capture: results[command]["capture_median_ms"] = statistics.median(capture)
print(json.dumps({"session": opt.session, "results": results}))
