"""Opt-in experiment, NOT a background-input backend.

Creates two disposable GTK windows in the host compositor. The target is moved
silently to an unused hidden workspace. A foreground witness records protocol
focus transitions while targeted dispatchers / AT-SPI operate on the target.
No user application receives input. A lost foreground witness aborts the probe.
Preparation opens/focuses temporary windows and can alter the host layout or
cursor. Only the measured phases test background behavior. Do not type during
the test. Closing the fixtures restores layout; cursor position is not restored.
Run: python3 tests/background_probe.py --live --workspace 4
"""
import argparse
import collections
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import threading
import time

BIN = Path(__file__).resolve().parents[1] / "zig-out/bin/hyprhand"
TEXT = "hyprhand background test ñ 123"
INSTANCE = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
SOCKET = Path(os.environ.get("XDG_RUNTIME_DIR", "/nonexistent")) / "hypr" / INSTANCE / ".socket.sock"

def ipc(command):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(3)
        sock.connect(str(SOCKET))
        sock.sendall(command.encode())
        result = bytearray()
        while chunk := sock.recv(65536):
            result.extend(chunk)
            if len(result) > 16*1024*1024: raise RuntimeError("Oversized reply")
    return result.decode()

def query(command):
    return json.loads(ipc("j/" + command))

def cli(*args, ok=True):
    p = subprocess.run([str(BIN), *args, "--session", "host"], text=True, capture_output=True, timeout=12)
    data = json.loads(p.stdout)
    if ok and p.returncode: raise RuntimeError(data)
    return data

def fixture(tag):
    import gi
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gtk, GLib, Gio
    def emit(event, **values):
        print(json.dumps({"event": event, **values}), flush=True)
    app = Gtk.Application(application_id="org.hyprhand.BackgroundProbe", flags=Gio.ApplicationFlags.NON_UNIQUE)
    def activate(app):
        win = Gtk.ApplicationWindow(application=app, title="hyprhand background " + tag)
        win.set_default_size(540, 380)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        for prop in ("margin-top", "margin-bottom", "margin-start", "margin-end"): box.set_property(prop, 24)
        box.append(Gtk.Label(label="Prueba temporal: " + tag))
        entry = Gtk.Entry()
        entry.set_placeholder_text("Test field")
        box.append(entry)
        entry.connect("changed", lambda e: emit("text", chars=len(e.get_text()), matches_probe=e.get_text() == TEXT))
        focus = Gtk.EventControllerFocus()
        focus.connect("enter", lambda _: emit("widget-focus-enter"))
        focus.connect("leave", lambda _: emit("widget-focus-leave"))
        entry.add_controller(focus)
        key = Gtk.EventControllerKey()
        key.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        key.connect("key-pressed", lambda _, keyval, keycode, state: (emit("key", code=keycode), False)[1])
        win.add_controller(key)
        button = Gtk.Button(label="Test action")
        button.connect("clicked", lambda _: emit("button-activated"))
        box.append(button)
        # Custom canvas resembles the class of controls that needs coordinates
        # (not a claim to implement or validate a real video editor).
        canvas = Gtk.DrawingArea(content_height=100)
        canvas.set_draw_func(lambda _, ctx, w, h: (ctx.set_source_rgb(.15, .35, .6), ctx.paint()))
        drag = Gtk.GestureDrag()
        drag.connect("drag-begin", lambda _, x, y: emit("drag-begin"))
        drag.connect("drag-end", lambda _, x, y: emit("drag-end"))
        canvas.add_controller(drag)
        box.append(canvas)
        box.append(Gtk.Label(label="No contiene archivos ni cuentas reales"))
        win.connect("notify::is-active", lambda w, _: emit("active", value=w.is_active()))
        win.set_child(box)
        win.present()
        entry.grab_focus()
        GLib.timeout_add(600, lambda: (emit("ready"), False)[1])
    app.connect("activate", activate)
    app.run([])

def a11y_worker(pid, operation):
    import gi
    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi
    Atspi.set_timeout(200, 500)
    Atspi.init()
    try:
        desktop = Atspi.get_desktop(0)
        app = next((desktop.get_child_at_index(i) for i in range(desktop.get_child_count())
                    if desktop.get_child_at_index(i).get_process_id() == pid), None)
        if app is None: raise RuntimeError("Fixture not present on AT-SPI bus")
        budget = [100]
        def walk(node, depth=0):
            if node is None or budget[0] <= 0: return
            budget[0] -= 1
            yield node
            if depth < 8:
                for i in range(min(node.get_child_count(), 100)):
                    if budget[0] <= 0: break
                    yield from walk(node.get_child_at_index(i), depth+1)
        nodes = list(walk(app))
        if operation == "text":
            editable = next((n.get_editable_text_iface() for n in nodes if n.get_editable_text_iface()), None)
            result = {"supported": editable is not None, "accepted": bool(editable and editable.set_text_contents(TEXT))}
        elif operation == "button":
            target = next((n for n in nodes if n.get_name() == "Test action" and n.get_role() == Atspi.Role.PUSH_BUTTON), None)
            action = target.get_action_iface() if target else None
            result = {"supported": bool(action and action.get_n_actions()), "accepted": bool(action and action.get_n_actions() and action.do_action(0))}
        else:
            result = {"roles": [n.get_role_name() for n in nodes], "editable_controls": sum(bool(n.get_editable_text_iface()) for n in nodes),
                      "action_controls": sum(bool(n.get_action_iface() and n.get_action_iface().get_n_actions()) for n in nodes)}
        print(json.dumps(result))
    finally:
        Atspi.exit()

class Witness:
    def __init__(self, tag):
        self.records = []
        self.ready = threading.Event()
        self.process = subprocess.Popen([sys.executable, __file__, "--fixture", tag],
            env=dict(os.environ, GDK_BACKEND="wayland", WAYLAND_DEBUG="client"), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def stdout():
            for line in self.process.stdout:
                try: record = json.loads(line)
                except json.JSONDecodeError: continue
                self.records.append({"t": time.monotonic(), "source": "gtk", **record})
                if record["event"] == "ready": self.ready.set()
        def stderr():
            for line in self.process.stderr:
                match = re.search(r"wl_(keyboard|pointer)[@#]\d+\.(enter|leave|key|button)\(", line)
                if match:
                    self.records.append({"t": time.monotonic(), "source": "wayland", "event": match[1] + "-" + match[2]})
        self.threads = [threading.Thread(target=stdout), threading.Thread(target=stderr)]
        for thread in self.threads: thread.start()
    def close(self):
        self.process.terminate()
        try: self.process.wait(timeout=3)
        except subprocess.TimeoutExpired: self.process.kill(); self.process.wait()
        for thread in self.threads: thread.join(timeout=2)
        self.process.stdout.close(); self.process.stderr.close()

def focus_verdict(phases):
    """A counterexample disproves isolation; a finite clean run cannot prove it."""
    violation = any(
        p["foreground"]["counts"].get("wayland:keyboard-leave", 0)
        or p["foreground"]["counts"].get("wayland:pointer-leave", 0)
        or not p["final_focus_unchanged"] or not p["sampled_focus_unchanged"]
        for p in phases if p["name"] != "idle_baseline"
    )
    baseline_dirty = any(p["foreground"]["counts"] for p in phases if p["name"] == "idle_baseline")
    return {"foreground_focus_loss_observed": bool(violation),
            "universal_background_input_safe": False if violation else None,
            "verdict": "inconclusive_baseline_activity" if baseline_dirty else
                       "focus_isolation_failed" if violation else "not_established"}

def run(workspace):
    original = cli("state")
    doctor = cli("doctor")
    if doctor["config_provider"] != "hyprlang": raise RuntimeError("This probe's raw dispatch syntax requires Hyprlang")
    if any(w["id"] == workspace for w in original["workspaces"]): raise RuntimeError("Choose an unused workspace; no existing workspace will be changed")
    if any(m["activeWorkspace"]["id"] == workspace for m in original["monitors"]): raise RuntimeError("Workspace must be hidden")
    witnesses = []
    samples = []
    phases = []
    running = threading.Event()
    watcher = None
    guardian = target = None
    enabled_file = Path(doctor["state_directory"]) / "enabled"
    expected_token = None
    def guard():
        if enabled_file.read_bytes() != expected_token: raise RuntimeError("Control revoked; refusing more test input")
        if query("locked")["locked"]: raise RuntimeError("Session locked")
        clients = query("clients")
        for witness in witnesses:
            if not any(w["pid"] == witness.process.pid and w["address"] == witness.address for w in clients): raise RuntimeError("Fixture identity changed")
        if guardian and query("activewindow").get("address") != guardian.address: raise RuntimeError("Foreground changed; aborting to avoid interrupting user")
    def signature():
        return {"active": query("activewindow").get("address"), "cursor": query("cursorpos"),
                "workspaces": sorted((m["id"], m["activeWorkspace"]["id"]) for m in query("monitors"))}
    def monitor():
        while running.is_set():
            try: samples.append({"t": time.monotonic(), **signature()})
            except Exception: pass
            time.sleep(.005)
    def phase(name, action):
        guard()
        before = signature()
        start = time.monotonic()
        result = action()
        time.sleep(.25)
        end = time.monotonic()
        after = signature()
        def summarize(w):
            records = [r for r in w.records if start <= r["t"] <= end]
            return {"counts": dict(collections.Counter(r["source"] + ":" + r["event"] for r in records)),
                    "probe_text_confirmed": any(r.get("matches_probe") for r in records)}
        phase_samples = [s for s in samples if start <= s["t"] <= end]
        phases.append({"name": name, "result": result, "foreground": summarize(guardian), "target": summarize(target),
                       "final_focus_unchanged": before["active"] == after["active"],
                       "sampled_focus_unchanged": all(s["active"] == before["active"] for s in phase_samples),
                       "cursor_unchanged": before["cursor"] == after["cursor"] and all(s["cursor"] == before["cursor"] for s in phase_samples),
                       "visible_workspaces_unchanged": before["workspaces"] == after["workspaces"], "samples": len(phase_samples)})
        print(json.dumps({"phase": phases[-1]}), flush=True)
        guard()
    def atspi(operation):
        p = subprocess.run([sys.executable, __file__, "--a11y", str(target.process.pid), operation], capture_output=True, text=True, timeout=6)
        if p.returncode: return {"error": "AT-SPI operation unavailable", "detail": p.stderr[-700:]}
        return json.loads(p.stdout)
    try:
        cli("enable")
        expected_token = enabled_file.read_bytes()
        for tag in ("target", "foreground"):
            witness = Witness(tag)
            witnesses.append(witness)
            if not witness.ready.wait(5): raise RuntimeError("Fixture startup failed")
            window = next(w for w in query("clients") if w["pid"] == witness.process.pid)
            witness.address = window["address"]
            if tag == "target":
                target = witness
                reply = ipc(f"/dispatch movetoworkspacesilent {workspace},address:{target.address}")
                if reply.strip() != "ok": raise RuntimeError(reply)
            else:
                guardian = witness
                cli("focus", guardian.address)
        time.sleep(.4)
        assert next(w for w in query("clients") if w["pid"] == target.process.pid)["workspace"]["id"] == workspace
        guard()
        running.set()
        watcher = threading.Thread(target=monitor)
        watcher.start()
        # Calibrate the protocol witness; baseline focus ENTER must exist.
        if not any(r["event"] == "keyboard-enter" for r in guardian.records): raise RuntimeError("Protocol observer did not record keyboard enter")
        phase("idle_baseline", lambda: time.sleep(.3))
        phase("atspi_set_text", lambda: atspi("text"))
        phase("atspi_button_action", lambda: atspi("button"))
        phase("targeted_shortcut_a", lambda: ipc(f"/dispatch sendshortcut ,a,address:{target.address}").strip())
        # Do not add pointer/drag injection after a strict focus violation: one
        # counterexample already disproves universal input isolation.
        return {"tested": True, "hyprland": doctor["hyprland"]["version"], "target_workspace": workspace,
                "foreground_workspace": next(w for w in query("clients") if w["pid"] == guardian.process.pid)["workspace"]["id"],
                "phases": phases, **focus_verdict(phases),
                "scope": "GTK4 fixtures only; no video editor or user application controlled"}
    finally:
        running.clear()
        if watcher: watcher.join(timeout=4)
        for witness in reversed(witnesses): witness.close()
        # Restore only if the foreground is still owned by the test (or already
        # returned to the original); don't override a human stop or focus change.
        try:
            active = query("activewindow").get("address")
            original_address = original["active_window"].get("address")
            allowed = {w.address for w in witnesses if hasattr(w, "address")} | {original_address, None}
            try: token_valid = expected_token and enabled_file.read_bytes() == expected_token
            except FileNotFoundError: token_valid = False
            if token_valid and active in allowed and original_address:
                cli("focus", original_address)
        finally:
            if not doctor["control_enabled"]: cli("stop")

if __name__ == "__main__":
    if "--fixture" in sys.argv: fixture(sys.argv[sys.argv.index("--fixture")+1])
    elif "--a11y" in sys.argv:
        at = sys.argv.index("--a11y")
        a11y_worker(int(sys.argv[at+1]), sys.argv[at+2])
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("--live", action="store_true")
        parser.add_argument("--workspace", type=int, default=4)
        opt = parser.parse_args()
        if not opt.live: parser.error("--live is required")
        if opt.workspace <= 0: parser.error("Positive workspace required")
        print(json.dumps(run(opt.workspace)), flush=True)
