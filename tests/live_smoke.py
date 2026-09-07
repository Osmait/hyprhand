"""Opt-in test: opens a disposable GTK window and uses the real mouse/keyboard.

Run: python3 tests/live_smoke.py --live
Requires Python GObject + GTK4 in addition to hyprhand's dependencies.
"""
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import time

BIN = Path(__file__).resolve().parents[1] / "zig-out/bin/hyprhand"
SESSION = os.environ.get("HYPRHAND_TEST_SESSION", "host")


def fixture():
    import gi
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gtk, GLib, Gio

    app = Gtk.Application(application_id="org.hyprhand.Smoke", flags=Gio.ApplicationFlags.NON_UNIQUE)

    def activate(app):
        window = Gtk.ApplicationWindow(application=app, title="hyprhand smoke test")
        if "--motion-events" in sys.argv:
            motion = Gtk.EventControllerMotion()
            motion.connect("motion", lambda _, x, y: print(json.dumps({"event": "motion", "x": x, "y": y}), flush=True))
            window.add_controller(motion)
            axis = Gtk.EventControllerScroll.new(Gtk.EventControllerScrollFlags.BOTH_AXES)
            axis.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
            def axis_input(_, dx, dy):
                print(json.dumps({"event": "scroll-input", "dx": dx, "dy": dy}), flush=True)
                return False  # Observe only; the scrolled window still handles it.
            axis.connect("scroll", axis_input)
            window.add_controller(axis)
        window.set_default_size(480, 300)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24)
        for prop in ("margin-top", "margin-bottom", "margin-start", "margin-end"):
            box.set_property(prop, 30)
        box.append(Gtk.Label(label="Temporary window for verifying hyprhand"))
        entry = Gtk.Entry()
        entry.set_text("previous content")
        box.append(entry)
        button = Gtk.Button(label="Verify click")
        box.append(button)
        label = Gtk.Label(label="Waiting for input…")
        box.append(label)
        drag_area = Gtk.DrawingArea(content_height=60)
        drag_area.set_draw_func(lambda _, ctx, w, h: (ctx.set_source_rgb(.2, .4, .7), ctx.paint()))
        gesture = Gtk.GestureDrag()
        gesture.connect("drag-begin", lambda _, x, y: print(json.dumps({"event": "drag-begin"}), flush=True))
        gesture.connect("drag-end", lambda _, x, y: print(json.dumps({"event": "drag-end", "dx": x, "dy": y}), flush=True))
        drag_area.add_controller(gesture)
        box.append(drag_area)

        def clicked(_):
            label.set_text("Click received")
            print(json.dumps({"event": "click", "text": entry.get_text()}), flush=True)

        button.connect("clicked", clicked)
        scroll = Gtk.ScrolledWindow(vexpand=True, min_content_height=100)
        content = Gtk.TextView(editable=False)
        content.get_buffer().set_text("\n".join(f"Test line {i}" for i in range(100)))
        scroll.set_child(content)
        box.append(scroll)

        def scrolled(adjustment):
            if adjustment.get_value() > 0:
                print(json.dumps({"event": "scroll", "dy": adjustment.get_value()}), flush=True)

        scroll.get_vadjustment().connect("value-changed", scrolled)
        window.set_child(box)
        window.present()
        entry.grab_focus()

        def ready():
            ok, rect = button.compute_bounds(window)
            if not ok or rect.get_width() == 0:
                return True
            _, scroll_rect = scroll.compute_bounds(window)
            _, drag_rect = drag_area.compute_bounds(window)
            print(json.dumps({"event": "ready", "button": [rect.get_x() + rect.get_width()/2,
                                                               rect.get_y() + rect.get_height()/2],
                              "drag": [drag_rect.get_x() + drag_rect.get_width()/2, drag_rect.get_y() + drag_rect.get_height()/2],
                              "scroll": [scroll_rect.get_x() + scroll_rect.get_width()/2,
                                         scroll_rect.get_y() + scroll_rect.get_height()/2]}), flush=True)
            return False

        GLib.timeout_add(500, ready)

    app.connect("activate", activate)
    app.run([])


def cli(*args):
    args = list(args)
    if "--session" in args:
        args[args.index("--session") + 1] = SESSION
    else:
        args += ["--session", SESSION]
    if args[0] in ("type", "key") and os.environ.get("HYPRHAND_TEST_BACKEND"):
        args += ["--backend", os.environ["HYPRHAND_TEST_BACKEND"]]
    result = subprocess.run([str(BIN), *args], capture_output=True, text=True, timeout=12)
    payload = json.loads(result.stdout)
    if result.returncode:
        raise RuntimeError(payload)
    return payload


def event(child):
    with selectors.DefaultSelector() as selector:
        selector.register(child.stdout, selectors.EVENT_READ)
        if not selector.select(5):
            raise TimeoutError("No input event received in the test window")
    return json.loads(child.stdout.readline())


def observe(monitor):
    for _ in range(15):
        try:
            return cli("observe", "--monitor", monitor)["frame"]
        except RuntimeError as exc:
            if "StaleObservation" not in str(exc):
                raise
            time.sleep(.1)
    raise TimeoutError("Desktop geometry did not settle")


def main():
    original = cli("state")
    original_control = cli("doctor")["control_enabled"]
    backend = "x11" if "--x11" in sys.argv else "wayland"
    env = dict(os.environ, GDK_BACKEND=backend)
    if SESSION != "host":
        s = json.loads(subprocess.check_output([str(BIN), "session", "inspect", SESSION]))["session"]
        env.update(XDG_RUNTIME_DIR=s["runtime"], WAYLAND_DISPLAY=s["display"],
                   HYPRLAND_INSTANCE_SIGNATURE=s["instance"], DBUS_SESSION_BUS_ADDRESS=s["dbus"])
        env.pop("DISPLAY", None)
        if s.get("registry"):
            env["AT_SPI_BUS_ADDRESS"] = s["dbus"]
        else:
            env.pop("AT_SPI_BUS_ADDRESS", None)
    child = subprocess.Popen([sys.executable, __file__, "--fixture"], stdout=subprocess.PIPE, text=True,
                             env=env)
    try:
        ready = event(child)
        state = cli("state")
        windows = [w for w in state["windows"] if w["pid"] == child.pid]
        assert len(windows) == 1, windows
        window = windows[0]
        assert window["xwayland"] == (backend == "x11"), window["xwayland"]
        address = window["address"]
        monitor = next(m for m in state["monitors"] if m["id"] == window["monitor"])
        cli("enable")
        cli("focus", address, "--session", "host")
        cli("key", "ctrl+a", "--window", address, "--session", "host")
        text = "Hello, ñ and accents: áéíóú. Zig + Wayland ✓"
        cli("type", "--window", address, "--text", text, "--session", "host")
        time.sleep(.15)
        # Local widget coordinates come from our test fixture; the desktop
        # position and screenshot transformation come from hyprhand.
        state = cli("state")
        window = next(w for w in state["windows"] if w["address"] == address)
        gx = window["at"][0] + ready["button"][0]
        gy = window["at"][1] + ready["button"][1]

        def pointer_action(command, *extra):
            f = observe(monitor["name"])
            target_x = window["at"][0] + ready["scroll"][0] if command == "scroll" else gx
            target_y = window["at"][1] + ready["scroll"][1] if command == "scroll" else gy
            px = (target_x - f["logical"]["x"]) * f["image_width"] / f["logical"]["width"]
            py = (target_y - f["logical"]["y"]) * f["image_height"] / f["logical"]["height"]
            return cli(command, "--session", "host", "--frame", f["frame_id"], "--x", str(px), "--y", str(py), *extra)

        pointer_action("click")
        clicked = event(child)
        assert clicked == {"event": "click", "text": text}, clicked
        pointer_action("scroll", "--dy", "2")
        scrolled = event(child)
        assert scrolled["event"] == "scroll" and scrolled["dy"] > 0, scrolled
        print(json.dumps({"ok": True, "backend": backend, "verified": ["window focus", "ctrl+a", "Unicode text received",
                                                     "native pointer click received", "scroll received"]}, ensure_ascii=False))
    finally:
        child.terminate()
        child.wait(timeout=5)
        # Restore the original target when it still exists, then restore the
        # control setting. A pre-existing human stop must never be re-enabled.
        try:
            previous = original["active_window"].get("address")
            if previous and cli("doctor")["control_enabled"]:
                cli("focus", previous, "--session", "host")
                cursor = original["cursor"]
                for m in cli("monitors")["data"]:
                    f = observe(m["name"])
                    r = f["logical"]
                    if r["x"] <= cursor["x"] < r["x"] + r["width"] and r["y"] <= cursor["y"] < r["y"] + r["height"]:
                        cli("move", "--frame", f["frame_id"], "--x", str((cursor["x"]-r["x"])*f["image_width"]/r["width"]),
                            "--y", str((cursor["y"]-r["y"])*f["image_height"]/r["height"]), "--session", "host")
                        break
        finally:
            if not original_control:
                cli("stop")


if __name__ == "__main__":
    if "--fixture" in sys.argv:
        fixture()
    elif "--live" in sys.argv:
        main()
    else:
        sys.exit("Use --live to explicitly run a test on your current desktop.")
