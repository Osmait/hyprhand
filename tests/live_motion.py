"""Opt-in host mouse test. Inspect the printed screenshot, then press Enter.

python3 tests/live_motion.py --live
Opens a disposable GTK fixture; shares host focus/cursor. Never types in user
apps. Aborts if fixture identity/focus/geometry or control token changes.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/hyprhand"
SESSION = os.environ.get("HYPRHAND_TEST_SESSION", "host")

def call(*args):
    p = subprocess.run([str(BIN), *args, "--session", SESSION], capture_output=True, text=True, timeout=15)
    data = json.loads(p.stdout)
    if p.returncode: raise RuntimeError(data)
    return data

def main():
    original = call("state")
    original_address = original["active_window"].get("address")
    doctor = call("doctor")
    if doctor["control_enabled"]: raise RuntimeError("Stop other hyprhand work before starting this test")
    token_file = Path(doctor["state_directory"]) / "enabled"
    token = None
    fixture_env = dict(os.environ, GDK_BACKEND="wayland")
    if SESSION != "host":
        result = subprocess.run([str(BIN), "session", "inspect", SESSION], capture_output=True, text=True, check=True)
        session = json.loads(result.stdout)["session"]
        fixture_env.update(XDG_RUNTIME_DIR=session["runtime"], WAYLAND_DISPLAY=session["display"],
                           HYPRLAND_INSTANCE_SIGNATURE=session["instance"], DBUS_SESSION_BUS_ADDRESS=session["dbus"])
        for key in ("DISPLAY", "LD_PRELOAD", "AT_SPI_BUS_ADDRESS"):
            fixture_env.pop(key, None)
        if session.get("registry"): fixture_env["AT_SPI_BUS_ADDRESS"] = session["dbus"]
        for kind in ("CONFIG", "CACHE", "DATA", "STATE"):
            fixture_env[f"XDG_{kind}_HOME"] = str(Path(session["directory"]) / f"profile-{kind}")
    child = subprocess.Popen([sys.executable, str(ROOT / "tests/live_smoke.py"), "--fixture", "--motion-events"],
        env=fixture_env, stdout=subprocess.PIPE, text=True)
    events = []
    ready_signal = threading.Event()
    def read():
        for line in child.stdout:
            item = json.loads(line)
            events.append({"t": time.monotonic(), **item})
            if item["event"] == "ready": ready_signal.set()
    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    moving = None
    address = None
    try:
        if not ready_signal.wait(5): raise RuntimeError("Fixture startup failed")
        ready = next(e for e in events if e["event"] == "ready")
        window = next(w for w in call("state")["windows"] if w["pid"] == child.pid)
        address = window["address"]
        monitor = next(m for m in call("state")["monitors"] if m["id"] == window["monitor"])
        # Opening the fixture normally focuses it. Do not override a human switch.
        if call("state")["active_window"].get("address") != address: raise RuntimeError("Fixture not foreground")
        frame = call("observe", "--monitor", monitor["name"])["frame"]
        print(json.dumps({"review_image": frame["image_path"], "fixture_pid": child.pid,
                          "fixture_at": window["at"], "targets_local": ready,
                          "instruction": "Inspect screenshot. Enter to test; Ctrl+C to abort."}), flush=True)
        if sys.stdin.readline() == "": raise RuntimeError("Visual review required")
        call("enable")
        token = token_file.read_bytes()
        def guard():
            if token_file.read_bytes() != token: raise RuntimeError("Control revoked")
            state = call("state")
            current = next(w for w in state["windows"] if w["pid"] == child.pid and w["address"] == address)
            if state["active_window"].get("address") != address: raise RuntimeError("Human changed focus")
            if (current["at"], current["size"], current["workspace"]) != (window["at"], window["size"], window["workspace"]):
                raise RuntimeError("Fixture geometry changed; review a new screenshot")
        def args(command, widget, offset=0, **extra):
            guard()
            call("wait", "stable", "--monitor", monitor["name"], "--stable-ms", "100")
            f = call("observe", "--monitor", monitor["name"])["frame"]
            r = f["logical"]
            gx, gy = [a+b for a,b in zip(window["at"], ready[widget])]
            x = (gx + offset-r["x"]) * f["image_width"] / r["width"]
            y = (gy-r["y"]) * f["image_height"] / r["height"]
            result = [command, "--frame", f["frame_id"], "--x", str(x), "--y", str(y)]
            if command == "drag": result += ["--to-x", str(x+160*f["image_width"]/r["width"]), "--to-y", str(y)]
            for key, value in extra.items():
                result += ["--" + key.replace("_", "-")]
                if value is not True: result += [str(value)]
            return result
        def do(command, widget, offset=0, **extra):
            argv = args(command, widget, offset, **extra)
            start = time.monotonic()
            result = call(*argv)
            elapsed = (time.monotonic()-start)*1000
            time.sleep(.08)
            observed = [e for e in events if e["t"] >= start]
            motions = [e for e in observed if e["event"] == "motion"]
            unique = len({(round(e["x"], 1), round(e["y"], 1)) for e in motions})
            print(json.dumps({"action": command, "options": extra, "elapsed_ms": round(elapsed, 2),
                              "distinct_motion_positions": unique, "received": sorted(set(e["event"] for e in observed))}), flush=True)
            guard()
            return observed, elapsed, unique
        # Target coordinates are fixture-owned and reviewed before this sequence.
        do("move", "drag", -180)
        observed, elapsed, unique = do("move", "drag", 180)
        assert unique >= 8 and 180 < elapsed < 1500, (elapsed, unique)
        observed, elapsed, unique = do("move", "drag", -180, move_duration_ms=400)
        assert unique >= 8 and 370 < elapsed < 1500, (elapsed, unique)
        _, elapsed, unique = do("move", "drag", 180, move_duration_ms=0)
        assert unique <= 3, unique
        if "--aura-review" in sys.argv:
            # The same reviewed fixture targets, long enough to capture the
            # indicator in-flight. No extra click, no user application target.
            do("move", "button", -180)
            argv = args("move", "button", 180, move_duration_ms=3000)
            moving = subprocess.Popen([str(BIN), *argv, "--session", SESSION], stdout=subprocess.PIPE, text=True)
            time.sleep(1.2)
            capture = call("observe", "--monitor", monitor["name"])["frame"]
            state = call("state")
            print(json.dumps({"aura_image": capture["image_path"], "cursor_desktop": state["cursor"],
                              "focus_unchanged": state["active_window"].get("address") == address}), flush=True)
            assert json.loads(moving.communicate(timeout=5)[0])["ok"]
            guard()
            do("move", "button", -180, no_aura=True)
        for command, widget, extra, name, count in (
            ("click", "button", {}, "click", 1),
            ("doubleclick", "button", {}, "click", 2),
            ("scroll", "scroll", {"dy": 2}, "scroll", 1),
            ("drag", "drag", {"duration_ms": 300}, "drag-end", 1),
        ):
            observed, _, _ = do(command, widget, **extra)
            assert sum(e["event"] == name for e in observed) >= count, observed
            if command == "scroll":
                samples = [e for e in observed if e["event"] == "scroll"]
                assert len(samples) >= 8, samples
                print(json.dumps({"verified": "progressive scroll", "samples": len(samples),
                                  "distance_px": samples[-1]["dy"],
                                  "sample_span_ms": round((samples[-1]["t"]-samples[0]["t"])*1000, 2)}), flush=True)
            if command == "drag": assert next(e for e in observed if e["event"] == name)["dx"] > 120
        for extra, axis, sign in (({"dy": -2}, "dy", -1), ({"dx": 2}, "dx", 1),
                                 ({"dy": 2, "duration_ms": 0}, "dy", 1)):
            observed, _, _ = do("scroll", "scroll", **extra)
            received = [e for e in observed if e["event"] == "scroll-input"]
            assert received and sum(e[axis] for e in received) * sign > 0, received
            print(json.dumps({"verified": "scroll direction/instant", "options": extra,
                              "native_samples": len(received)}), flush=True)
        # Cancel a long approach before click: SIGTERM must prevent the click.
        argv = args("click", "button", move_duration_ms=3000)
        start = time.monotonic()
        moving = subprocess.Popen([str(BIN), *argv, "--session", SESSION], stdout=subprocess.PIPE, text=True)
        time.sleep(.15)
        moving.send_signal(signal.SIGTERM)
        result = json.loads(moving.communicate(timeout=3)[0])
        assert result["err"]["code"] == "Cancelled", result
        assert not any(e["event"] == "click" and e["t"] >= start for e in events)
        print(json.dumps({"verified": "SIGTERM during approach prevents click"}), flush=True)
        # Cancel after scrolling actually begins, not just during approach.
        do("move", "scroll", no_aura=True)
        argv = args("scroll", "scroll", dy=20, duration_ms=3000, no_aura=True)
        start = time.monotonic()
        moving = subprocess.Popen([str(BIN), *argv, "--session", SESSION], stdout=subprocess.PIPE, text=True)
        deadline = time.monotonic()+5
        while not any(e["event"] == "scroll-input" and e["t"] >= start for e in events):
            if time.monotonic() > deadline or moving.poll() is not None: raise RuntimeError("Scroll did not begin")
            time.sleep(.01)
        moving.send_signal(signal.SIGTERM)
        result = json.loads(moving.communicate(timeout=3)[0])
        assert result["err"]["code"] == "Cancelled", result
        time.sleep(.15)
        count = sum(e["event"] == "scroll-input" for e in events)
        time.sleep(.25)
        assert sum(e["event"] == "scroll-input" for e in events) == count
        print(json.dumps({"verified": "SIGTERM stops progressive scroll input; app inertia is independent"}), flush=True)
        # Stop during a button-held drag; observe release in the application.
        argv = args("drag", "drag", duration_ms=3000)
        start = time.monotonic()
        moving = subprocess.Popen([str(BIN), *argv, "--session", SESSION], stdout=subprocess.PIPE, text=True)
        deadline = time.monotonic()+5
        while not any(e["event"] == "drag-begin" and e["t"] >= start for e in events):
            if time.monotonic() > deadline or moving.poll() is not None: raise RuntimeError("Drag did not begin")
            time.sleep(.01)
        call("stop")
        result = json.loads(moving.communicate(timeout=3)[0])
        assert result["err"]["code"] == "ControlStopped", result
        time.sleep(.1)
        assert any(e["event"] == "drag-end" and e["t"] >= start for e in events)
        print(json.dumps({"ok": True, "verified": "stop during drag releases button; control stays disabled"}), flush=True)
    finally:
        if moving and moving.poll() is None:
            moving.terminate()
            try: moving.wait(timeout=3)
            except subprocess.TimeoutExpired: moving.kill(); moving.wait()
        try:
            # Only restore focus if we still own the token and the foreground.
            if token and token_file.exists() and token_file.read_bytes() == token:
                if call("state")["active_window"].get("address") == address and original_address:
                    call("focus", original_address)
        finally:
            child.terminate()
            child.wait(timeout=5)
            reader.join(timeout=1)
            child.stdout.close()
            if token: call("stop")

if __name__ == "__main__":
    if "--live" not in sys.argv: sys.exit("Pass --live to authorize host input and visual review")
    main()
