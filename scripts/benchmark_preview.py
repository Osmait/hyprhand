#!/usr/bin/env python3
"""Opt-in read-only PiP benchmark. Opens/closes only its own host preview.

An existing managed source is required. Never enables input or launches source
applications. Reports worker latency separately from viewer-tree CPU and RSS;
neither worker throughput nor requested FPS proves frames presented by GTK.
"""
import argparse
import json
import os
from pathlib import Path
import selectors
import signal
import statistics
import subprocess
import threading
from collections import deque
import time

BIN = Path(__file__).resolve().parents[1] / "zig-out/bin/hyprhand"


def cli(*args):
    result = subprocess.run([str(BIN), *args], capture_output=True, timeout=15, check=True)
    value = json.loads(result.stdout)
    if not value.get("ok"):
        raise RuntimeError(value)
    return value


def usage(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    # CPU includes already reaped capture children, not compositor/GPU time.
    cpu = sum(int(fields[i]) for i in (11, 12, 13, 14)) / os.sysconf("SC_CLK_TCK")
    rss = int(fields[21]) * os.sysconf("SC_PAGE_SIZE") / 1024**2
    return fields[19], cpu, rss


def tree_cpu(pid, parent=None):
    """Sample only the owned tree, including live persistent workers/grim.

    Each node includes reaped descendants; live descendants are added once.
    /proc snapshots are not atomic, so process-exit boundaries can add noise.
    """
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        if parent is not None and int(fields[1]) != parent:
            return 0
        cpu = sum(int(fields[i]) for i in (11, 12, 13, 14)) / os.sysconf("SC_CLK_TCK")
        children = Path(f"/proc/{pid}/task/{pid}/children").read_text().split()
        return cpu + sum(tree_cpu(int(child), pid) for child in children)
    except (FileNotFoundError, ProcessLookupError):
        return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--session", required=True)
    parser.add_argument("--seconds", type=int, default=120)
    parser.add_argument("--fps", type=int, choices=range(1, 16), default=5)
    args = parser.parse_args()
    if not args.live or args.session == "host" or not 10 <= args.seconds <= 3600:
        parser.error("requires --live, a managed session, and 10–3600 seconds")
    meta = cli("session", "inspect", args.session)
    if not meta.get("running") or meta["session"].get("destroyed"):
        raise RuntimeError("Source must already be running")
    source = meta["session"]
    doctor = cli("doctor", "--session", args.session)
    if doctor["shared_cursor"] or not doctor["display_matches"]:
        raise RuntimeError("Refusing shared or mismatched source")
    before = cli("state", "--session", "host")["active_window"].get("address")
    enabled = doctor["control_enabled"]
    token_path = Path(doctor["state_directory"]) / "enabled"
    token = token_path.read_bytes() if enabled else None
    monitor = next(m["name"] for m in cli("state", "--session", args.session)["monitors"] if m["focused"])
    latency = []
    sizes = []
    for _ in range(30):
        started = time.monotonic()
        frame = subprocess.run([str(BIN), "_preview_frame", "--session", args.session,
                                "--expected-instance", source["instance"], "--monitor", monitor],
                               capture_output=True, timeout=4, check=True).stdout
        if not (13 < len(frame) <= 8 * 1024**2 + 13 and frame[:4] == b"DCP1" and
                frame[13:21] == b"\x89PNG\r\n\x1a\n"):
            raise RuntimeError("Invalid preview frame")
        latency.append((time.monotonic() - started) * 1000)
        sizes.append(len(frame))
    viewer = subprocess.Popen([str(BIN), "preview", "--session", args.session, "--fps", str(args.fps)],
                              env=dict(os.environ, HYPRHAND_PIP_METRICS="1"),
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    metric_rows = deque(maxlen=1024)
    metrics_lock = threading.Lock()
    reader = None
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(viewer.stdout, selectors.EVENT_READ)
            if not selector.select(10):
                raise RuntimeError("Viewer startup timed out")
        event = json.loads(viewer.stdout.readline())
        if event.get("event") != "preview_started":
            raise RuntimeError(event)
        pid = event["pid"]
        def drain():
            for line in viewer.stdout:
                try: row = json.loads(line)
                except ValueError: continue
                if row.get("event") == "preview_metrics":
                    with metrics_lock: metric_rows.append(row)
        reader = threading.Thread(target=drain, daemon=True)
        reader.start()
        # Exclude GTK/driver initialization from the steady-state RSS interval.
        identity = usage(pid)[0]
        time.sleep(5)
        print(json.dumps({"event": "sampling", "pid": pid, "seconds": args.seconds, "fps": args.fps}), flush=True)
        first = usage(pid)
        first_cpu = tree_cpu(pid)
        if first[0] != identity:
            raise RuntimeError("Viewer identity changed during warmup")
        samples = []
        started = time.monotonic()
        while time.monotonic() - started < args.seconds:
            if viewer.poll() is not None:
                raise RuntimeError("Viewer exited during sampling")
            sample = usage(pid)
            if sample[0] != first[0]:
                raise RuntimeError("Viewer identity changed")
            samples.append(sample[2])
            time.sleep(1)
        last = usage(pid)
        last_cpu = tree_cpu(pid)
        elapsed = time.monotonic() - started
    finally:
        viewer.terminate()
        try:
            viewer.wait(timeout=5)
        except subprocess.TimeoutExpired:
            viewer.kill()
            viewer.wait()
            raise RuntimeError("Launcher did not close normally; viewer cleanup unverified")
        if reader is not None: reader.join(timeout=2)
        viewer.stdout.close()
    after = cli("state", "--session", "host")["active_window"].get("address")
    source_after = cli("doctor", "--session", args.session)
    if source_after["control_enabled"] != enabled or source_after["instance"] != source["instance"]:
        raise RuntimeError("Source control changed during benchmark")
    if (token_path.read_bytes() if source_after["control_enabled"] else None) != token:
        raise RuntimeError("Source control token changed during benchmark")
    if Path(f"/proc/{pid}").exists() and usage(pid)[0] == identity:
        raise RuntimeError("Owned viewer survived launcher shutdown")
    ordered = sorted(latency)
    with metrics_lock: rows = list(metric_rows)
    presentation = None
    if len(rows) >= 2:
        start, end = rows[0], rows[-1]
        span = (end["elapsed_ms"] - start["elapsed_ms"]) / 1000
        paints = end["painted_updates"] - start["painted_updates"]
        presents = end["presented_updates"] - start["presented_updates"]
        presentation = {
            "sample_seconds": span,
            "received_fps": (end["received_frames"] - start["received_frames"]) / span,
            "texture_update_fps": (end["texture_updates"] - start["texture_updates"]) / span,
            "gtk_painted_update_fps": paints / span,
            "presented_update_fps": presents / span if end["presentation_feedback_available"] else None,
            "capture_to_paint_mean_ms": (end["paint_latency_total_ms"] - start["paint_latency_total_ms"]) / paints if paints else None,
            "capture_to_presentation_mean_ms": (end["presentation_latency_total_ms"] - start["presentation_latency_total_ms"]) / presents if presents else None,
            "note": "Identical images reuse a texture; zero visual updates on a static scene is expected. Null means presentation feedback unavailable, not zero FPS.",
        }
    print(json.dumps({"ok": True, "session": args.session, "requested_fps": args.fps,
                      "seconds": round(elapsed, 2), "worker_samples": len(latency),
                      "worker_latency_median_ms": round(statistics.median(latency), 2),
                      "worker_latency_p95_ms": round(ordered[28], 2),
                      "frame_median_bytes": statistics.median(sizes),
                      "viewer_tree_cpu_percent_one_core": round((last_cpu - first_cpu) / elapsed * 100, 2),
                      "viewer_rss_mib_first": round(samples[0], 2), "viewer_rss_mib_last": round(last[2], 2),
                      "viewer_rss_mib_min": round(min(samples), 2), "viewer_rss_mib_max": round(max(samples), 2),
                      "viewer_rss_mib_last_30_range": round(max(samples[-30:]) - min(samples[-30:]), 2),
                      "host_focus_same_at_endpoints": before == after, "source_control_unchanged": True,
                      "presentation": presentation,
                      "scope": "RSS of viewer only; CPU includes live/reaped workers; excludes compositor/GPU; presentation updates require GDK feedback"}))


def interrupted(_signum, _frame):
    raise KeyboardInterrupt("Benchmark interrupted")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    main()
