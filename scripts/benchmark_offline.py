#!/usr/bin/env python3
"""Reproducible CLI/IPC and event-memory benchmarks using private fake servers.

No desktop input, GUI, host sockets, or screenshot capture. Times include Python
fixture overhead; these are scaling comparisons, not real compositor latency.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import statistics
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests"))
import integration
import keyboard_protocol


def keyboard(samples):
    fixture = keyboard_protocol.KeyboardProtocol()
    fixture.setUp()
    try:
        fixture.start()
        for count, delay in ((16, 0), (128, 0), (1024, 0), (128, .001)):
            fixture.fixture.query_delay = delay
            durations, requests = [], []
            for _ in range(samples):
                mark = len(fixture.fixture.commands)
                started = time.perf_counter()
                fixture.fixture.cli("type", "--session", "host", "--window", fixture.fixture.address,
                                    "--backend", "native", "--text", "a" * count)
                durations.append((time.perf_counter() - started) * 1000)
                requests.append(len(fixture.fixture.commands) - mark)
            print(json.dumps({"benchmark": "fake_keyboard", "characters": count, "samples": samples,
                              "query_delay_ms": delay * 1000, "median_ms": round(statistics.median(durations), 2),
                              "ipc_requests_median": statistics.median(requests)}), flush=True)
    finally:
        fixture.doCleanups()


def event_memory(count):
    fixture = integration.CLI()
    fixture.setUp()
    server = socket.socket(socket.AF_UNIX)
    server.bind(str(fixture.session / ".socket2.sock"))
    server.listen()
    server.settimeout(5)
    failures = []
    def emit():
        try:
            with server.accept()[0] as conn:
                conn.settimeout(5)
                for _ in range(count): conn.sendall(b"activewindow>>" + b"x" * 60000 + b"\n")
        except Exception as error:
            failures.append(str(error))
    thread = threading.Thread(target=emit)
    thread.start()
    process = None
    try:
        process = subprocess.Popen([str(integration.BIN), "events", "--session", "host", "--limit", str(count),
                                    "--timeout-ms", "5000"], env=fixture.env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 7
        while True:
            pid, status, usage = os.wait4(process.pid, os.WNOHANG)
            if pid: break
            if time.monotonic() > deadline: process.kill()
            time.sleep(.005)
        process.returncode = os.waitstatus_to_exitcode(status)
        if process.returncode: raise RuntimeError(f"events failed: {process.returncode}")
        thread.join(timeout=6)
        if failures or thread.is_alive(): raise RuntimeError(failures or "server did not finish")
        print(json.dumps({"benchmark": "event_memory", "events": count, "payload_bytes": 60000,
                          "max_rss_kib": usage.ru_maxrss}), flush=True)
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
        thread.join(timeout=6)
        server.close()
        fixture.tearDown()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=5)
    args = parser.parse_args()
    if not 1 <= args.samples <= 100: parser.error("samples must be 1–100")
    keyboard(args.samples)
    for count in (10, 1000): event_memory(count)
