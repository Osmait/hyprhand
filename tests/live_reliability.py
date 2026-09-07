"""Opt-in reliability checks against an ALREADY RUNNING managed GTK fixture.

No GUI/session is launched here, and control is never enabled or re-enabled.
The operator must launch tests/fixtures/reliability.py in a dedicated managed
session (see that file's docstring), leave its first entry focused, then run:

  python3 tests/live_reliability.py --live --session NAME --events /tmp/EVENTS

Default: keyboard only; verifies native GTK modifier events AND editing/focus.
Optional: --pointer --scroll-mode all --guard stop
Use --guard cancel to send SIGTERM to the final scroll process after the
fixture receives its first axis event. No enable occurs between any actions.
With --scroll-mode all, six 500 ms scrolls (three modes, with/without --window)
precede one terminal 10-second guard scroll: seven screenshot reviews in total.
Each pointer action requires a fresh screenshot review on a terminal. Enter
image pixel coordinates yourself; fixture bounds are exposed only as context.
--guard focus/frame requires the operator to change managed-session focus or
window geometry DURING the final scroll. stop/cancel are automatic. Every guard
is terminal: use a fresh, explicitly authorized run for another guard scenario.

Requires Python 3, a built deskctl, and GTK4/PyGObject for the separate fixture.
No host input, automatic focus restoration, session destruction or git actions.
Observer contract and run details: tests/fixtures/README.md.
"""

import argparse
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin/deskctl"
TITLE = "deskctl reliability fixture"
MODS = 1 | 4 | 8 | 64 | 128  # Shift, Control, Alt, Super, Level3; ignore locks.


def require(condition, message):
    # These are safety gates too: do not let python -O remove them.
    if not condition:
        raise RuntimeError(message)


def session_name(value):
    if value.lower() == "host" or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,31}", value):
        raise argparse.ArgumentTypeError("an explicit managed session other than host is required")
    return value


def process_start(pid):
    # /proc comm may contain spaces and parentheses; starttime is field 22.
    return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]


def verify_scroll(mode, received):
    # GTK 4.22.4 gdk/wayland/gdkseat-wayland.c:flush_scroll_event chooses
    # value120 (wheel) OR surface deltas, then clears both. A wheel+surface
    # pair is not a GTK fallback to silently discard or sum as wheel units.
    # https://github.com/GNOME/gtk/blob/4.22.4/gdk/wayland/gdkseat-wayland.c
    require(received and sum(e["dy"] for e in received) > 0,
            "Scroll direction/delivery incorrect")
    units = {e["unit"] for e in received}
    require(units == ({"wheel"} if mode == "wheel" else {"surface"}),
            f"Wrong GTK scroll units for {mode}: {units}")
    if mode == "wheel":
        require(math.isclose(sum(e["dy"] for e in received), 4, abs_tol=1e-6),
                "Wheel mode must deliver exactly the four requested detents")
    else:
        require(len(received) >= 3, "Continuous scrolling was not progressive")


class Deskctl:
    def __init__(self, binary, session):
        self.binary = str(binary)
        self.session = session_name(session)
        self.halted = False

    def argv(self, *args):
        # main.zig recognizes help only as argv == [binary, "--help"]. This
        # standalone informational path never initializes a desktop session.
        if args == ("--help",):
            return [self.binary, "--help"]
        require(args and args[0] in {"--help", "doctor", "state", "stop", "sessions", "session", "observe", "key", "scroll"},
                "The runner never enables control, launches apps, or changes focus")
        if args[0] == "session":
            require(args[1:] == ("inspect", self.session), "Only this session's metadata may be inspected")
        require("--session" not in args, "Session overrides are forbidden")
        if self.halted:
            require(args[0] in {"doctor", "state", "stop"}, "Input sequence already stopped")
        return [self.binary, *map(str, args), "--session", self.session]

    def decode(self, process, stdout, stderr, expected=None):
        try:
            result = json.loads(stdout)
        except (ValueError, TypeError) as exc:
            self.halted = True
            raise RuntimeError(f"deskctl returned invalid JSON: {stderr[:300]}") from exc
        code = result.get("err", {}).get("code")
        if process.returncode or not result.get("ok"):
            # Latch on EVERY error, including ControlStopped/humanstop. No retry.
            self.halted = True
            require(expected is not None and code in expected,
                    f"deskctl failed: {code or result}")
        else:
            require(expected is None, f"Expected rejection {expected}, but input completed")
        if "session_id" in result:
            require(result["session_id"] == self.session, "deskctl session mismatch")
        return result

    def call(self, *args, expected=None):
        proc = subprocess.run(self.argv(*args), capture_output=True, text=True, timeout=15)
        return self.decode(proc, proc.stdout, proc.stderr, expected)


class Observer:
    """Read-only, append-only fixture stream; no commands hidden in observations."""

    def __init__(self, path):
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            os.close(fd)
            raise RuntimeError("Observer must be a regular file owned by this user")
        self.file = os.fdopen(fd, "r", encoding="utf-8")
        self.path = Path(path)
        self.identity = (info.st_dev, info.st_ino)
        self.records = []
        try:
            self.poll()
            require(self.records and self.records[0].get("event") == "ready",
                    "Fixture is not ready; wait for its ready record")
            self.ready = self.records[0]
        except Exception:
            self.file.close()
            raise

    def poll(self):
        info = self.path.stat(follow_symlinks=False)
        require((info.st_dev, info.st_ino) == self.identity and stat.S_ISREG(info.st_mode),
                "Observer file was replaced")
        require(self.file.tell() <= info.st_size <= 8 * 1024 * 1024,
                "Observer truncated or exceeded 8 MiB; start a new fixture")
        while True:
            position = self.file.tell()
            line = self.file.readline()
            if not line or not line.endswith("\n"):
                self.file.seek(position)
                break
            item = json.loads(line)
            require(isinstance(item, dict), "Invalid fixture record")
            self.records.append(item)
        return self.records

    def mark(self):
        self.poll()
        return len(self.records)

    def wait(self, mark, predicate, timeout=3):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for item in self.poll()[mark:]:
                if predicate(item):
                    return item
            time.sleep(.02)
        raise RuntimeError("Timed out waiting for actual fixture input/state")


class Suite:
    def __init__(self, args):
        self.args = args
        self.cli = Deskctl(args.deskctl, args.session)
        self.observer = None
        self.token_path = None
        self.token = None
        self.child = None  # Only a deskctl input process, never a GUI.
        self.passed = []

    def preflight(self):
        # Skill preflight: standalone help; all session operations explicitly scoped.
        help_proc = subprocess.run(self.cli.argv("--help"), capture_output=True,
                                   text=True, timeout=15)
        require(help_proc.returncode == 0, "Cannot read deskctl help")
        sessions = self.cli.call("sessions")["sessions"]
        require(any(s["id"] == self.args.session and s.get("running") and
                    s.get("shared_cursor") is False for s in sessions),
                "Session must be a running managed desktop")
        meta = self.cli.call("session", "inspect", self.args.session)
        require(meta.get("running") and not meta["session"].get("destroyed"),
                "Managed session is not running")
        session = meta["session"]
        doctor = self.cli.call("doctor")
        require(doctor.get("session_id") == self.args.session and
                doctor.get("shared_cursor") is False and doctor.get("display_matches"),
                "Refusing shared or mismatched desktop")
        self.observer = Observer(self.args.events)
        ready = self.observer.ready
        require(ready.get("schema") == 1 and ready.get("session") == self.args.session and
                ready.get("instance") == session["instance"] and
                ready.get("display") == session["display"] and
                ready.get("runtime") == session["runtime"], "Fixture/session identity mismatch")
        require(type(ready.get("pid")) is int and ready["pid"] > 1, "Invalid fixture PID")
        require(process_start(ready["pid"]) == ready["start"], "Fixture PID was reused")
        state = self.cli.call("state")
        windows = [w for w in state["windows"] if w.get("pid") == ready["pid"] and
                   w.get("title") == TITLE and not w.get("xwayland")]
        require(len(windows) == 1, "Expected exactly one native Wayland fixture window")
        self.window = windows[0]
        self.address = self.window["address"]
        self.monitor = next(m["name"] for m in state["monitors"] if
                            m["id"] == self.window["monitor"])
        require(state["active_window"].get("address") == self.address,
                "Fixture must already be focused; runner will not steal focus")
        fresh = self.observer.wait(self.observer.mark(), lambda e: e["event"] == "snapshot")
        require(fresh["focus"] == "first", "Focus the fixture's first entry before running")
        require(doctor.get("control_enabled"),
                "Control is disabled; this runner never enables or re-enables it")
        self.token_path = Path(doctor["state_directory"]) / "enabled"
        self.token = self.token_path.read_bytes()
        require(self.token, "Empty control token")
        self.guard()

    def guard(self):
        require(not self.cli.halted, "Input sequence is terminal")
        try:
            require(self.token_path.read_bytes() == self.token, "Control token changed (human stop)")
            ready = self.observer.ready
            require(process_start(ready["pid"]) == ready["start"], "Fixture exited/replaced")
            state = self.cli.call("state")
            current = next((w for w in state["windows"] if w["address"] == self.address), None)
            require(current and current.get("pid") == ready["pid"] and
                    current.get("title") == TITLE and not current.get("xwayland"),
                    "Fixture identity changed")
            require(state["active_window"].get("address") == self.address, "Fixture lost focus")
            require(all(current.get(k) == self.window.get(k) for k in
                        ("at", "size", "workspace", "monitor")), "Fixture geometry changed")
        except Exception:
            self.cli.halted = True
            raise

    def verified(self, name):
        self.passed.append(name)
        print(json.dumps({"verified": name, "session": self.args.session}), flush=True)

    def key(self, chord, key_names, modifiers, check=None):
        self.guard()
        mark = self.observer.mark()
        self.cli.call("key", chord, "--backend", "native", "--window", self.address)
        event = self.observer.wait(mark, lambda e: e["event"] == "key-release" and
                                   e["key"] in key_names)
        modifier_keys = [(bit, names) for bit, names in (
            (1, {"Shift_L", "Shift_R"}), (4, {"Control_L", "Control_R"})) if modifiers & bit]
        for _, names in modifier_keys:
            self.observer.wait(mark, lambda e: e["event"] == "key-release" and e["key"] in names)
        records = self.observer.poll()[mark:]
        pressed = [e for e in records if e["event"] == "key-press" and e["key"] in key_names]
        require(len(pressed) == 1 and pressed[0]["modifiers"] & MODS == modifiers,
                f"{chord}: actual GTK key modifiers missing/wrong: {pressed}")
        require(event["keycode"] == pressed[0]["keycode"], f"{chord}: unmatched release")
        if modifiers:
            transitions = [i for i, e in enumerate(records) if e["event"] == "modifiers" and
                           e["modifiers"] & MODS == modifiers]
            require(transitions, f"{chord}: no GTK modifier transition")
            for _, names in modifier_keys:
                down = [(i, e) for i, e in enumerate(records) if e["event"] == "key-press" and e["key"] in names]
                up = [(i, e) for i, e in enumerate(records) if e["event"] == "key-release" and e["key"] in names]
                require(len(down) == len(up) == 1 and
                        down[0][1]["key"] == up[0][1]["key"] and
                        down[0][1]["keycode"] == up[0][1]["keycode"] and
                        down[0][0] < records.index(pressed[0]) < records.index(event) < up[0][0],
                        f"{chord}: missing, unmatched or out-of-order modifier press/release")
            # GtkEventControllerKey updates its modifiers signal only while
            # handling a key event. The final Control/Shift release can still
            # carry the old mask; no standalone zero callback is guaranteed.
            # Verify physical releases here; the guarded F12 probe in keyboard()
            # verifies zero received modifiers before declaring the chord passed.
            # https://github.com/GNOME/gtk/blob/4.22.4/gtk/gtkeventcontrollerkey.c
        if check:
            self.observer.wait(mark + records.index(event) + 1,
                               lambda e: e["event"] == "snapshot" and check(e))
        self.guard()

    def keyboard(self):
        # GTK initially selects all text on focus. Establish a different state
        # so ctrl+a must cause a real selection change to pass.
        self.key("Home", {"Home"}, 0, lambda e: e["focus"] == "first" and
                 e["cursor"] == 0 and not e["selection"] and bool(e["text"]))
        self.key("ctrl+a", {"a", "A"}, 4,
                 lambda e: e["focus"] == "first" and e["selection"] == [0, len(e["text"])])
        self.key("F12", {"F12"}, 0)  # Unmodified probe also detects stuck modifiers.
        self.verified("native ctrl+a: Control events, select-all, modifier release")
        self.key("Tab", {"Tab"}, 0, lambda e: e["focus"] == "second")
        self.key("shift+Tab", {"Tab", "ISO_Left_Tab"}, 1, lambda e: e["focus"] == "first")
        self.key("F12", {"F12"}, 0)
        self.verified("native shift+Tab: Shift events and backward focus traversal")
        self.key("Home", {"Home"}, 0, lambda e: e["cursor"] == 0 and not e["selection"])
        self.key("ctrl+shift+Right", {"Right"}, 5,
                 lambda e: len(e["selection"]) == 2 and e["selection"][0] == 0 and
                 0 < e["selection"][1] < len(e["text"]))
        self.key("F12", {"F12"}, 0)
        self.verified("native ctrl+shift+Right: combined modifiers and word selection")

    def reviewed_scroll(self, mode, duration, with_window=True):
        self.guard()
        frame = self.cli.call("observe", "--monitor", self.monitor)["frame"]
        snapshot = self.observer.wait(self.observer.mark(), lambda e: e["event"] == "snapshot")
        require(frame.get("session_id") == self.args.session, "Capture belongs to another session")
        print(json.dumps({"review_image": frame["image_path"], "frame_id": frame["frame_id"],
                          "fixture_window": self.address, "fixture_at": self.window["at"],
                          "fixture_observer": snapshot,
                          "mode": mode, "duration_ms": duration,
                          "instruction": "View this exact screenshot. Enter: reviewed X Y (image pixels inside the blue scroll area); Ctrl+C aborts."}),
              flush=True)
        # Never derive targets from GTK bounds or automatically approve a capture.
        words = input("reviewed X Y> ").split()
        require(len(words) == 3 and words[0] == "reviewed", "Explicit screenshot review required")
        x, y = map(float, words[1:])
        require(math.isfinite(x) and math.isfinite(y) and 0 <= x < frame["image_width"] and
                0 <= y < frame["image_height"], "Target outside the reviewed image")
        age = time.monotonic() - frame["captured_at_monotonic_ms"] / 1000
        require(0 <= age < 27 - duration / 1000,
                "Review expired; aborting without recapture/input (allow time for the full action)")
        # Validate the OPERATOR'S target against fixture bounds; never choose
        # a target from these bounds. Wrong targets cannot reach unrelated UI.
        logical = frame["logical"]
        local_x = math.floor(logical["x"] + x * logical["width"] / frame["image_width"]) - self.window["at"][0]
        local_y = math.floor(logical["y"] + y * logical["height"] / frame["image_height"]) - self.window["at"][1]
        bx, by, width, height = snapshot["bounds_local"]["scroll"]
        require(bx <= local_x < bx + width and by <= local_y < by + height,
                "Reviewed target must be inside the fixture's scroll observer")
        self.guard()
        argv = ["scroll", "--frame", frame["frame_id"], "--x", str(x), "--y", str(y),
                "--dy", "4", "--scroll-mode", mode, "--duration-ms", str(duration),
                "--move-duration-ms", "0", "--no-aura"]
        if with_window:
            argv += ["--window", self.address]
        return argv

    def pointer(self):
        modes = ("auto", "wheel", "continuous") if self.args.scroll_mode == "all" else (self.args.scroll_mode,)
        for mode in modes:
            for with_window in (True, False):
                argv = self.reviewed_scroll(mode, 500, with_window)
                mark = self.observer.mark()
                self.cli.call(*argv)
                self.observer.wait(mark, lambda e: e["event"] == "scroll" and e["dy"] > 0)
                # Wait for a post-command fixture heartbeat so queued final
                # axis/stop events are included in the semantic assertions.
                self.observer.wait(self.observer.mark(), lambda e: e["event"] == "snapshot")
                received = [e for e in self.observer.poll()[mark:] if e["event"] == "scroll"]
                print(json.dumps({"scroll_mode": mode, "with_window": with_window,
                                  "native_samples": len(received), "samples": received[:16]}), flush=True)
                verify_scroll(mode, received)
                self.guard()
                self.verified(f"{mode} scroll, {'explicit' if with_window else 'implicit'} window: actual GTK axis events")
        self.interrupt_scroll()

    def interrupt_scroll(self):
        cause = self.args.guard
        argv = self.reviewed_scroll("continuous", 10000)
        mark = self.observer.mark()
        self.child = subprocess.Popen(self.cli.argv(*argv), stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True)
        self.observer.wait(mark, lambda e: e["event"] == "scroll", timeout=3)
        if cause == "stop":
            self.cli.call("stop")
            self.cli.halted = True
            expected = {"ControlStopped"}
        elif cause == "cancel":
            self.child.send_signal(signal.SIGTERM)
            expected = {"Cancelled"}
        else:
            print(json.dumps({"instruction": "NOW change only the managed fixture's " +
                              ("focus to another window using a keyboard shortcut; keep the pointer still." if cause == "focus" else
                               "geometry using a keyboard shortcut while keeping it focused and the pointer still."),
                              "deadline_seconds": 8}), flush=True)
            expected = {"WindowNotFocused"} if cause == "focus" else {"StaleObservation"}
        stdout, stderr = self.child.communicate(timeout=12)
        self.cli.decode(self.child, stdout, stderr, expected)
        # Observe the receiver, not just deskctl's acknowledgement. Allow events
        # already queued in GTK to drain, then require a quiet interval.
        time.sleep(.2)
        quiet = self.observer.mark()
        time.sleep(.35)
        require(not any(e["event"] == "scroll" for e in self.observer.poll()[quiet:]),
                "Native scroll events continued after interruption")
        if cause == "stop":
            require(not self.cli.call("doctor")["control_enabled"], "Control was re-enabled")
        self.verified(f"continuous scroll {cause} guard: rejection and no subsequent axis events")

    def close(self):
        if self.child is not None and self.child.poll() is None:
            self.child.terminate()
            try:
                self.child.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.communicate(timeout=3)
        # Never restore focus, enable, kill the external fixture, or destroy its
        # session. Stop only the token this run borrowed; don't revoke a new one.
        try:
            if self.token is not None and self.token_path.exists() and self.token_path.read_bytes() == self.token:
                self.cli.call("stop")
        finally:
            if self.observer is not None:
                self.observer.file.close()


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--live", action="store_true", help="authorize input into the named managed fixture")
    parser.add_argument("--session", required=True, type=session_name, help="explicit managed session; no environment fallback")
    parser.add_argument("--events", required=True, type=Path, help="NDJSON file from the already-running reliability fixture")
    parser.add_argument("--deskctl", type=Path, default=BIN)
    parser.add_argument("--pointer", action="store_true", help="require terminal screenshot review before each pointer action")
    parser.add_argument("--scroll-mode", choices=("auto", "wheel", "continuous", "all"), default="all")
    parser.add_argument("--guard", choices=("stop", "cancel", "focus", "frame"), default="stop")
    args = parser.parse_args(argv)
    if not args.live:
        parser.error("--live is required; no computer actions were taken")
    if args.pointer and not sys.stdin.isatty():
        parser.error("--pointer requires an interactive terminal for screenshot review")
    return args


def main(argv=None):
    args = parse_args(argv)  # All authorization gates precede any subprocess.
    suite = Suite(args)
    previous_signal = signal.getsignal(signal.SIGTERM)

    def interrupted(_signum, _frame):
        raise KeyboardInterrupt("SIGTERM: stopping the reliability run")

    signal.signal(signal.SIGTERM, interrupted)
    try:
        suite.preflight()
        suite.keyboard()
        if args.pointer:
            suite.pointer()
    finally:
        try:
            suite.close()
        finally:
            signal.signal(signal.SIGTERM, previous_signal)
    print(json.dumps({"ok": True, "session": args.session, "verified": suite.passed,
                      "pointer": args.pointer,
                      "control_policy": "never enabled; stopped only if original token still owned"}))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError, EOFError, KeyboardInterrupt) as exc:
        print(json.dumps({"ok": False, "error": str(exc) or "Interrupted",
                          "instruction": "Do not re-enable after a human stop without renewed authorization."}),
              file=sys.stderr)
        sys.exit(1)
