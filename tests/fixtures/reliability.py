"""Operator-launched GTK4 observer for tests/live_reliability.py.

Only run in an existing dedicated managed session after explicit authorization.
Example from the repository root (use a fresh EVENTS path, never an existing file):

  zig-out/bin/deskctl --help
  zig-out/bin/deskctl sessions
  zig-out/bin/deskctl doctor --session NAME
  zig-out/bin/deskctl enable --session NAME
  zig-out/bin/deskctl launch --session NAME -- python3 /ABS/REPO/tests/fixtures/reliability.py --live --session NAME --events /tmp/EVENTS
  python3 tests/live_reliability.py --live --session NAME --events /tmp/EVENTS

Do not repeat enable after humanstop/ControlStopped without renewed permission.
The fixture validates its actual environment against managed-session metadata
BEFORE importing GTK or opening a window. It does not launch subprocess GUIs,
inject input, enable control, or close any other applications. The operator
closes this fixture when finished. Its NDJSON observer exposes key press/release,
modifier transitions, focus, selection, scroll units, and local widget bounds.
No IPC command channel exists; observations cannot cause input or focus changes.
See tests/fixtures/README.md for the observer contract, terminal cancel scenario,
and the distinction between GTK key-event masks and modifier release callbacks.
"""

import argparse
import json
import os
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from live_reliability import TITLE, process_start, require, session_name


def managed_environment(name):
    # deskctl launch replaces XDG_RUNTIME_DIR, so calling `session inspect`
    # inside the child would search the wrong session registry. launch also
    # supplies a private profile-CONFIG directory beside its session.json.
    profile = Path(os.environ.get("XDG_CONFIG_HOME", ""))
    require(profile.is_absolute() and profile.name == "profile-CONFIG",
            "Use deskctl launch in an explicitly authorized managed session")
    directory = profile.parent
    require(directory.name == name and directory.parent.name == "deskctl-sessions",
            "Profile is not part of the requested managed session")
    session = json.loads((directory / "session.json").read_text())
    require(session["name"] == name and session["directory"] == str(directory) and
            not session.get("destroyed"), "Managed session identity mismatch")
    require(Path(session["runtime"]) != directory.parent.parent,
            "Managed runtime must not be the host runtime")
    for name, key in (("XDG_RUNTIME_DIR", "runtime"), ("WAYLAND_DISPLAY", "display"),
                      ("HYPRLAND_INSTANCE_SIGNATURE", "instance"), ("DBUS_SESSION_BUS_ADDRESS", "dbus")):
        require(os.environ.get(name) == session[key],
                f"{name} does not match managed session; use deskctl launch")
    for kind in ("compositor", "bus"):
        process = session[kind]
        require(type(process.get("pid")) is int and process["pid"] > 1 and
                process_start(process["pid"]) == str(process["start"]),
                f"Managed {kind} is no longer running")
    return session


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--session", required=True, type=session_name)
    parser.add_argument("--events", required=True, type=Path)
    args = parser.parse_args(argv)
    if not args.live:
        parser.error("--live is required before opening a managed fixture")
    session = managed_environment(args.session)
    os.environ["GDK_BACKEND"] = "wayland"
    os.environ.pop("DISPLAY", None)

    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Gdk", "4.0")
    from gi.repository import Gdk, Gio, GLib, Gtk

    # Exclusive file creation prevents overwriting user data or mixing runs.
    fd = os.open(args.events, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", buffering=1) as stream:
        started = False

        def emit(event, **values):
            if started or event == "ready":
                stream.write(json.dumps({"event": event, "time": time.monotonic(), **values}) + "\n")

        app = Gtk.Application(application_id="org.deskctl.Reliability", flags=Gio.ApplicationFlags.NON_UNIQUE)

        def activate(application):
            nonlocal started
            window = Gtk.ApplicationWindow(application=application, title=TITLE)
            window.set_default_size(560, 420)
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
            for prop in ("margin-top", "margin-bottom", "margin-start", "margin-end"):
                box.set_property(prop, 24)
            box.append(Gtk.Label(label="Managed reliability fixture — disposable input only"))
            first = Gtk.Entry(text="alpha beta gamma")
            first.set_name("first")
            second = Gtk.Entry(text="second focus target")
            second.set_name("second")
            box.append(first)
            box.append(second)
            box.append(Gtk.Label(label="Blue area: scroll observer (no inertia)"))
            area = Gtk.DrawingArea(content_height=180, vexpand=True)

            def draw(_, ctx, width, height):
                ctx.set_source_rgb(.1, .3, .65)
                ctx.paint()

            area.set_draw_func(draw)
            box.append(area)
            window.set_child(box)

            def focus_name():
                focus = window.get_focus()
                while focus is not None:
                    if focus == first:
                        return "first"
                    if focus == second:
                        return "second"
                    focus = focus.get_parent()
                return None

            def snapshot():
                bounds = {}
                for name, widget in (("first", first), ("second", second), ("scroll", area)):
                    ok, rect = widget.compute_bounds(window)
                    if ok:
                        bounds[name] = [rect.get_x(), rect.get_y(), rect.get_width(), rect.get_height()]
                selection = list(first.get_selection_bounds())
                # PyGObject versions expose either (start,end), (), or
                # (selected,start,end) for this out-parameter API.
                if len(selection) == 3:
                    selection = selection[1:] if selection[0] else []
                emit("snapshot", focus=focus_name(), text=first.get_text(),
                     selection=selection, cursor=first.get_position(), bounds_local=bounds,
                     active=window.is_active())
                return True

            controller = Gtk.EventControllerKey()
            controller.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)

            def key_event(kind, keyval, keycode, state):
                emit(kind, key=Gdk.keyval_name(keyval), keycode=keycode, modifiers=int(state), focus=focus_name())
                GLib.idle_add(lambda: (snapshot(), False)[1])
                return False

            controller.connect("key-pressed", lambda _, keyval, keycode, state:
                               key_event("key-press", keyval, keycode, state))
            controller.connect("key-released", lambda _, keyval, keycode, state:
                               key_event("key-release", keyval, keycode, state))

            def modifiers(_, state):
                emit("modifiers", modifiers=int(state))
                return False

            controller.connect("modifiers", modifiers)
            window.add_controller(controller)
            axis = Gtk.EventControllerScroll.new(Gtk.EventControllerScrollFlags.BOTH_AXES)
            axis.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)

            def scroll(_, dx, dy):
                event = axis.get_current_event()
                # GDK >= 4.8 exposes units. Missing support is a test failure for
                # --pointer, not a false pass inferred from deskctl's mode flag.
                unit = event.get_unit().value_nick if event and hasattr(event, "get_unit") else "unknown"
                emit("scroll", dx=dx, dy=dy, unit=unit,
                     raw_deltas=list(event.get_deltas()) if event else None,
                     direction=event.get_direction().value_nick if event else None,
                     is_stop=event.is_stop() if event else None)
                return True

            axis.connect("scroll", scroll)
            axis.connect("scroll-begin", lambda _: emit("scroll-begin"))
            axis.connect("scroll-end", lambda _: emit("scroll-end"))
            area.add_controller(axis)
            window.present()
            first.grab_focus()

            def ready():
                nonlocal started
                ok, rect = area.compute_bounds(window)
                if not ok or rect.get_width() <= 0:
                    return True
                emit("ready", schema=1, session=args.session, pid=os.getpid(),
                     start=process_start(os.getpid()), title=TITLE, runtime=session["runtime"],
                     display=session["display"], instance=session["instance"],
                     gtk_version=[Gtk.get_major_version(), Gtk.get_minor_version(), Gtk.get_micro_version()])
                started = True
                snapshot()
                GLib.timeout_add(100, snapshot)
                return False

            GLib.timeout_add(200, ready)

        app.connect("activate", activate)
        return app.run([])


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError, KeyError) as exc:
        sys.exit(str(exc))
