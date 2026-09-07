"""Opt-in regression on a named managed session; never inject into host.

HYPRHAND_TEST_SESSION=NAME python3 tests/live_advanced.py --live
Requires a running managed session. Creates and closes only its GTK fixture.
"""
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import threading
import time
import statistics

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/hyprhand"
SESSION = os.environ.get("HYPRHAND_TEST_SESSION")

def call(*args, host=False, ok=True):
    proc = subprocess.run([str(BIN), *args, "--session", "host" if host else SESSION], text=True, capture_output=True, timeout=15)
    data = json.loads(proc.stdout)
    assert (proc.returncode == 0) == ok, (data, proc.stderr)
    return data

def main():
    assert SESSION and SESSION != "host", "Select a managed session, never host"
    meta = json.loads(subprocess.check_output([str(BIN), "session", "inspect", SESSION]))["session"]
    env = dict(os.environ, GDK_BACKEND="wayland", XDG_RUNTIME_DIR=meta["runtime"],
               WAYLAND_DISPLAY=meta["display"], HYPRLAND_INSTANCE_SIGNATURE=meta["instance"],
               DBUS_SESSION_BUS_ADDRESS=meta["dbus"], AT_SPI_BUS_ADDRESS=meta["dbus"])
    env.pop("DISPLAY", None)
    child = subprocess.Popen([sys.executable, str(ROOT / "tests/live_smoke.py"), "--fixture"], env=env, stdout=subprocess.PIPE, text=True)
    events = queue.Queue()
    def read():
        for line in child.stdout:
            events.put(json.loads(line))
    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    def event(name):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            value = events.get(timeout=max(.01, deadline - time.monotonic()))
            if value["event"] == name: return value
        raise TimeoutError(name)
    original_enabled = call("doctor")["control_enabled"]
    try:
        ready = event("ready")
        window = next(w for w in call("state")["windows"] if w["pid"] == child.pid)
        address = window["address"]
        call("enable")
        call("focus", address)
        host_before = call("state", host=True)

        def pointer_args(command, widget, *extra):
            call("wait", "stable", "--stable-ms", "100")
            frame = call("observe")["frame"]
            window = next(w for w in call("state")["windows"] if w["pid"] == child.pid)
            gx, gy = [a + b for a, b in zip(window["at"], ready[widget])]
            r = frame["logical"]
            x = (gx-r["x"]) * frame["image_width"]/r["width"]
            y = (gy-r["y"]) * frame["image_height"]/r["height"]
            result = [command, "--frame", frame["frame_id"], "--x", str(x), "--y", str(y)]
            if command == "drag": result += ["--to-x", str(x+80), "--to-y", str(y)]
            return result + list(extra)

        timings = {}
        text = "Hello ñ ✓ " * 20  # >128 codepoints exercises native keymap chunking
        for backend in ("helper", "native"):
            durations = []
            for _ in range(3):
                call("key", "ctrl+a", "--window", address)
                start = time.monotonic()
                call("type", "--window", address, "--text", text, "--backend", backend)
                durations.append((time.monotonic()-start)*1000)
                call(*pointer_args("click", "button"))
                assert event("click")["text"] == text
                call("key", "shift+Tab", "--window", address)
            timings[backend] = round(statistics.median(durations), 2)

        call(*pointer_args("doubleclick", "button"))
        event("click"); event("click")
        call(*pointer_args("drag", "drag", "--duration-ms", "300"))
        event("drag-begin")
        assert event("drag-end")["dx"] > 50
        # Cancellation must release the pressed button, observed by GTK.
        for cause in ("stop", "signal"):
            call("enable")
            args = pointer_args("drag", "drag", "--duration-ms", "3000")
            moving = subprocess.Popen([str(BIN), *args, "--session", SESSION], text=True, stdout=subprocess.PIPE)
            try:
                event("drag-begin")
                if cause == "stop": call("stop")
                else: moving.send_signal(signal.SIGTERM)
                result = json.loads(moving.communicate(timeout=3)[0])
                assert result["err"]["code"] == ("ControlStopped" if cause == "stop" else "Cancelled"), result
                event("drag-end")
            finally:
                if moving.poll() is None: moving.kill(); moving.wait()
        call("enable")
        # A second successful drag proves no held button remains.
        call(*pointer_args("drag", "drag", "--duration-ms", "100"))
        event("drag-begin"); event("drag-end")
        tree = call("accessibility", "--window", address, "--limit", "100", "--depth", "6")["accessibility"]
        assert any(n["role"] == "button" and n["name"] == "Verify click" for n in tree["nodes"]), tree
        limited = call("accessibility", "--window", address, "--limit", "2")["accessibility"]
        assert len(limited["nodes"]) <= 2 and limited["truncated"]
        host_after = call("state", host=True)
        assert host_before["cursor"] == host_after["cursor"], "Host cursor moved"
        assert host_before["active_window"].get("address") == host_after["active_window"].get("address"), "Host focus changed"
        print(json.dumps({"ok": True, "session": SESSION, "verified": ["chunked Unicode", "helper/native equivalence", "doubleclick", "drag", "stop release", "SIGTERM release", "AT-SPI tree/limits", "host cursor/focus isolation"], "type_180_codepoints_median_ms": timings}))
    finally:
        child.terminate(); child.wait(timeout=5)
        reader.join(timeout=1)
        child.stdout.close()
        if not original_enabled: call("stop")

if __name__ == "__main__":
    if "--live" not in sys.argv: sys.exit("Use --live and HYPRHAND_TEST_SESSION=managed-name")
    main()
