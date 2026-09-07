#!/usr/bin/env python3
"""Opt-in GTK soak on a PRIVATE Broadway display and simulated capture source.

No host display, input, credentials or network listener. Measures software-path
CPU/RSS and texture reuse; it cannot certify Wayland/GPU presentation latency.
Requires zig build pip and gtk4-broadwayd. --seconds supports up to one hour.
"""
import argparse
import json
from pathlib import Path
import sys
import signal
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests"))
import viewer_broadway
from benchmark_preview import usage, tree_cpu


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=120)
    args = parser.parse_args()
    if not 20 <= args.seconds <= 3600: parser.error("seconds must be 20–3600")
    fixture = viewer_broadway.Viewer()
    fixture.sleeper_seconds = args.seconds + 60
    fixture.setUp()
    try:
        fixture.metrics()  # Warmup includes GTK initialization and first image.
        pid = fixture.viewer.pid
        identity = usage(pid)[0]
        cpu_start = tree_cpu(pid)
        started = time.monotonic()
        samples = []
        last = None
        while time.monotonic() - started < args.seconds:
            last = fixture.metrics()
            if not last["signal_live"]: raise RuntimeError("source signal lost during soak; results invalid")
            current = usage(pid)
            if current[0] != identity: raise RuntimeError("viewer identity changed")
            samples.append(current[2])
            print(json.dumps({"event": "sample", "seconds": round(time.monotonic() - started, 1),
                              "rss_mib": round(current[2], 2), **last}), flush=True)
        elapsed = time.monotonic() - started
        result = {"ok": True, "scope": "Private Broadway, static synthetic PNG; not compositor/GPU performance",
                  "seconds": round(elapsed, 2), "cpu_percent_one_core": round((tree_cpu(pid) - cpu_start) / elapsed * 100, 2),
                  "rss_mib_first": samples[0], "rss_mib_last": samples[-1],
                  "rss_mib_range": max(samples) - min(samples),
                  "rss_mib_last_30_range": max(samples[-6:]) - min(samples[-6:]), "metrics": last}
        fixture.viewer.terminate()
        _, err = fixture.viewer.communicate(timeout=3)
        if fixture.viewer.returncode != 0 or b"CRITICAL" in err: raise RuntimeError(err.decode())
        print(json.dumps(result), flush=True)
    finally:
        if not fixture.doCleanups(): raise RuntimeError("fixture cleanup failed")


if __name__ == "__main__":
    def interrupted(_signal, _frame): raise KeyboardInterrupt("soak interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    main()
