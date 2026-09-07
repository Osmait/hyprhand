"""CLI contract tests using a fake compositor and helpers; never inject input."""
import json
import resource
import os
from pathlib import Path
import socket
import signal
import subprocess
import tempfile
import threading
import time
import unittest

BIN = Path(os.environ.get("DESKCTL_TEST_BIN", str(Path(__file__).resolve().parents[1] / "zig-out/bin/deskctl")))


class CLI(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="deskctl-test-")
        self.root = Path(self.temp.name)
        self.session = self.root / "hypr/test-instance"
        self.session.mkdir(parents=True)
        (self.session / "hyprland.lock").write_text("123\nwayland-test\n")
        self.env = dict(os.environ, XDG_RUNTIME_DIR=str(self.root),
                        HYPRLAND_INSTANCE_SIGNATURE="test-instance", WAYLAND_DISPLAY="wayland-test",
                        PATH=f"{self.root}:{os.environ['PATH']}", DESKCTL_TEST_ROOT=str(self.root))
        self.address = "0x123"
        self.active = self.address
        self.locked = False
        self.hold_locked = threading.Event()
        self.locked_requested = threading.Event()
        self.query_delay = 0
        self.provider = "hyprlang"
        self.outline_plugin = False
        self.xwayland = False
        self.x = -1280
        self.client_size = [1280, 720]
        self.extra_clients = []
        self.layers = {}
        self.commands = []
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(str(self.session / ".socket.sock"))
        self.server.listen()
        self.server.settimeout(0.05)
        self.running = True
        self.thread = threading.Thread(target=self.serve)
        self.thread.start()
        helper = '''#!/usr/bin/python3
import os, pathlib, struct, sys, time
root = pathlib.Path(os.environ["DESKCTL_TEST_ROOT"])
if pathlib.Path(sys.argv[0]).name == "xdotool" and sys.argv[1] == "getwindowfocus":
    print(os.environ.get("DESKCTL_TEST_X11_PID", "123"))
elif pathlib.Path(sys.argv[0]).name == "grim":
    pathlib.Path(sys.argv[-1]).write_bytes(b"\\x89PNG\\r\\n\\x1a\\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", 1920, 1080))
else:
    text = sys.stdin.read()
    (root / "input.json").write_text(__import__("json").dumps({"argv": sys.argv[1:], "text": text}))
    if text == "SLOW":
        time.sleep(20)
'''
        for name in ("grim", "wtype", "xdotool"):
            path = self.root / name
            path.write_text(helper)
            path.chmod(0o700)

    def tearDown(self):
        self.running = False
        self.thread.join(timeout=2)
        self.server.close()
        self.temp.cleanup()

    def serve(self):
        while self.running:
            try:
                conn, _ = self.server.accept()
            except socket.timeout:
                continue
            with conn:
                request = conn.recv(8192).decode()
                self.commands.append(request)
                command = request.split("/", 1)[1]
                if self.query_delay:
                    time.sleep(self.query_delay)
                if command == "monitors":
                    result = [{"id": 0, "name": "DP-test", "width": 1920, "height": 1080,
                               "x": self.x, "y": 100, "scale": 1.5, "transform": 0,
                               "activeWorkspace": {"id": 1, "name": "1"}, "focused": True}]
                elif command == "clients":
                    result = [{"address": self.address, "at": [self.x, 100], "size": self.client_size,
                               "workspace": {"id": 1, "name": "1"}, "xwayland": self.xwayland, "pid": 123}] + self.extra_clients
                elif command == "activewindow":
                    result = {"address": self.active}
                elif command == "layers":
                    result = self.layers
                elif command == "locked":
                    self.locked_requested.set()
                    while self.hold_locked.is_set() and self.running:
                        time.sleep(0.005)
                    result = {"locked": self.locked}
                elif command == "status":
                    result = {"configProvider": self.provider}
                elif command == "version":
                    result = {"version": "test"}
                elif command.startswith("dispatch "):
                    if command.startswith("dispatch deskctl:outline ") and not self.outline_plugin:
                        conn.sendall(b"Invalid dispatcher")
                        continue
                    conn.sendall(b"ok")
                    continue
                else:
                    result = []
                try:
                    conn.sendall(json.dumps(result).encode())
                except BrokenPipeError:
                    pass

    def cli(self, *args, ok=True, env=None):
        if args[0] in ("type", "key") and "--backend" not in args:
            args = (*args, "--backend", "helper")
        result = subprocess.run([str(BIN), *args], env=env or self.env, capture_output=True, text=True, timeout=15)
        payload = json.loads(result.stdout)
        self.assertEqual(result.returncode == 0, ok, (result.stdout, result.stderr))
        self.assertEqual(payload["ok"], ok)
        return payload

    def error(self, code, *args, **kwargs):
        self.assertEqual(self.cli(*args, ok=False, **kwargs)["err"]["code"], code)

    def frame(self):
        return self.cli("observe")["frame"]

    def test_observe_mapping_and_private_files(self):
        f = self.frame()
        self.assertEqual(f["logical"], {"x": -1280, "y": 100, "width": 1280, "height": 720})
        result = self.cli("click", "--frame", f["frame_id"], "--x", "960", "--y", "540", "--session", "host", "--dry-run")
        self.assertEqual(result["desktop_point"], {"x": -640, "y": 460})
        self.assertEqual(Path(f["image_path"]).stat().st_mode & 0o777, 0o600)
        self.assertEqual(Path(f["image_path"]).parent.stat().st_mode & 0o777, 0o700)
        self.assertFalse(any("dispatch" in cmd for cmd in self.commands))

    def test_stale_geometry(self):
        f = self.frame()
        self.x += 10
        self.error("StaleObservation", "move", "--frame", f["frame_id"], "--x", "0", "--y", "0", "--session", "host", "--dry-run")

    def test_stale_focus(self):
        f = self.frame()
        self.active = "0x999"
        self.error("StaleObservation", "click", "--frame", f["frame_id"], "--x", "0", "--y", "0", "--session", "host", "--dry-run")

    def test_other_output_layers_do_not_invalidate_capture(self):
        self.layers = {"OTHER": {"levels": {"2": [{"x": 2000, "w": 900}]}}}
        f = self.frame()
        self.layers["OTHER"]["levels"]["2"][0]["w"] = 940
        self.cli("move", "--frame", f["frame_id"], "--x", "100", "--y", "100", "--session", "host", "--dry-run")
        self.layers["DP-test"] = {"levels": {"3": [{"x": -1000, "w": 300}]}}
        self.error("StaleObservation", "move", "--frame", f["frame_id"], "--x", "100", "--y", "100", "--session", "host", "--dry-run")

    def test_other_output_clients_and_crossing_windows(self):
        self.extra_clients = [{"address": "0x456", "at": [2000, 100], "size": [800, 600],
                               "workspace": {"id": 2}, "monitor": 1}]
        f = self.frame()
        self.extra_clients[0]["size"] = [900, 600]
        self.cli("move", "--frame", f["frame_id"], "--x", "100", "--y", "100", "--session", "host", "--dry-run")
        self.extra_clients[0]["at"] = [-100, 100]
        self.error("StaleObservation", "move", "--frame", f["frame_id"], "--x", "100", "--y", "100", "--session", "host", "--dry-run")

    def test_scroll_duration_contract(self):
        f = self.frame()
        base = ("scroll", "--frame", f["frame_id"], "--x", "100", "--y", "100", "--session", "host", "--dry-run")
        for duration in ("0", "50", "500", "10000"):
            self.cli(*base, "--duration-ms", duration)
        for duration in ("1", "49", "10001"):
            self.error("InvalidDuration", *base, "--duration-ms", duration)

    def test_explicit_scroll_mode_and_pointer_window(self):
        f = self.frame()
        base = ("scroll", "--frame", f["frame_id"], "--x", "100", "--y", "100", "--session", "host", "--dry-run")
        for mode in ("auto", "wheel", "continuous"):
            for duration in ("0", "500"):
                self.cli(*base, "--scroll-mode", mode, "--duration-ms", duration, "--window", self.address)
        self.error("InvalidScrollMode", *base, "--scroll-mode", "magic")
        self.error("UnknownOption", "state", "--scroll-mode", "wheel")
        self.error("WindowNotFound", *base, "--window", "0x999")
        self.error("InvalidWindowAddress", *base, "--window", "not-an-address")

    def test_doctor_distinguishes_prerequisites_from_verification(self):
        env = dict(self.env)
        env.pop("DBUS_SESSION_BUS_ADDRESS", None)
        result = self.cli("doctor", env=env)
        self.assertFalse(result["capabilities"]["accessibility"])
        self.assertFalse(result["checks"]["accessibility"]["operation_verified"])
        self.assertFalse(result["checks"]["managed_sessions"]["operation_verified"])
        self.assertFalse(result["checks"]["managed_sessions"]["headless_gpu_verified"])
        self.assertFalse(result["checks"]["input"]["pointer_protocol_available"])
        self.assertTrue(result["checks"]["capture"]["prerequisites_available"])
        self.assertFalse(result["checks"]["capture"]["operation_verified"])

    def test_outline_requires_plugin_and_fails_closed(self):
        self.cli("enable")
        self.error("OutlinePluginUnavailable", "enable", "--indicator", "outline")
        self.error("ControlStopped", "focus", self.address, "--session", "host")
        self.error("InvalidIndicator", "enable", "--indicator", "circle")
        self.error("UnknownOption", "stop", "--indicator", "outline")

    def test_outline_lifetime_and_provider(self):
        self.outline_plugin = True
        self.assertEqual(self.cli("enable", "--indicator", "outline")["indicator"], "outline")
        enabled = next(self.root.glob("deskctl-*/enabled"))
        marker = enabled.with_name("outline")
        self.assertEqual(enabled.read_bytes(), marker.read_bytes())
        self.cli("enable")
        self.assertFalse(marker.exists())
        self.cli("enable", "--indicator", "outline")
        self.cli("stop")
        self.assertFalse(enabled.exists())
        self.assertFalse(marker.exists())
        self.provider = "lua"
        self.error("OutlineRequiresHyprlang", "enable", "--indicator", "outline")
        self.assertFalse(enabled.exists())

    def test_headless_bridge_restrictions_before_spawn(self):
        for path in ("relative.so", "/tmp/a:b.so", "/tmp/a b.so", "/missing.so"):
            self.error("InvalidHeadlessBridge", "session", "create", "bridge-test", "--headless-bridge", path)
        self.error("InvalidHeadlessBridge", "session", "create", "bridge-test", "--nested", "--headless-bridge", "/tmp/test.so")
        self.error("UnknownOption", "session", "destroy", "bridge-test", "--headless-bridge", "/tmp/test.so")
        library = self.root / "bridge.so"
        library.write_bytes(b"not a library")
        library.chmod(0o666)
        self.error("InvalidHeadlessBridge", "session", "create", "bridge-test", "--headless-bridge", str(library))
        library.chmod(0o600)
        link = self.root / "linked.so"
        link.symlink_to(library)
        self.error("InvalidHeadlessBridge", "session", "create", "bridge-test", "--headless-bridge", str(link))

    def test_old_frame_schema_rejected(self):
        f = self.frame()
        f["schema_version"] = 1
        Path(f["image_path"]).with_suffix(".json").write_text(json.dumps(f))
        self.error("StaleObservation", "move", "--frame", f["frame_id"], "--x", "100", "--y", "100", "--session", "host", "--dry-run")

    def test_expired_frame(self):
        f = self.frame()
        f["captured_at_monotonic_ms"] -= 31000
        Path(f["image_path"]).with_suffix(".json").write_text(json.dumps(f))
        self.error("StaleObservation", "click", "--frame", f["frame_id"], "--x", "0", "--y", "0", "--session", "host", "--dry-run")

    def test_extreme_frame_timestamp_is_rejected_without_panic(self):
        f = self.frame()
        f["captured_at_monotonic_ms"] = -(2 ** 63)
        Path(f["image_path"]).with_suffix(".json").write_text(json.dumps(f))
        self.error("StaleObservation", "move", "--frame", f["frame_id"],
                   "--x", "0", "--y", "0", "--session", "host", "--dry-run")

    def test_stop_invalidates_inflight_enable(self):
        self.hold_locked.set()
        process = subprocess.Popen([str(BIN), "enable", "--session", "host"],
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertTrue(self.locked_requested.wait(2))
            self.cli("stop", "--session", "host")
            self.hold_locked.clear()
            out, _ = process.communicate(timeout=2)
            self.assertEqual(json.loads(out)["err"]["code"], "ControlStopped")
            self.assertFalse(list(self.root.glob("deskctl-*/enabled")))
            self.cli("enable", "--session", "host")
            self.assertTrue(list(self.root.glob("deskctl-*/enabled")))
        finally:
            self.hold_locked.clear()
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=2)

    def test_stop_needs_no_file_writes_and_invalidates_inflight_enable(self):
        def no_writes():
            resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
            signal.signal(signal.SIGXFSZ, signal.SIG_IGN)

        self.cli("enable")
        result = subprocess.run([str(BIN), "stop", "--session", "host"], env=self.env,
                                preexec_fn=no_writes, capture_output=True, text=True, timeout=2)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.error("ControlStopped", "type", "--session", "host", "--window", self.address, "--text", "blocked")
        self.assertFalse((self.root / "input.json").exists())
        self.hold_locked.set()
        self.locked_requested.clear()
        process = subprocess.Popen([str(BIN), "enable", "--session", "host"], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertTrue(self.locked_requested.wait(2))
            result = subprocess.run([str(BIN), "stop", "--session", "host"], env=self.env,
                                    preexec_fn=no_writes, capture_output=True, text=True, timeout=2)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.hold_locked.clear()
            out, _ = process.communicate(timeout=2)
            self.assertEqual(json.loads(out)["err"]["code"], "ControlStopped")
            self.cli("enable")
        finally:
            self.hold_locked.clear()
            if process.poll() is None: process.kill()
            process.communicate(timeout=2)

    def test_wait_budget_spans_multiple_queries(self):
        self.query_delay = 0.08
        started = time.monotonic()
        self.error("WaitTimeout", "wait", "focus", "--window", self.address,
                   "--timeout-ms", "100")
        self.assertLess(time.monotonic() - started, 0.35)

    def test_coordinate_bounds(self):
        f = self.frame()
        for x in ("nan", "inf", "-1", "1920"):
            self.error("CoordinatesOutOfBounds", "click", "--frame", f["frame_id"], "--x", x, "--y", "0", "--session", "host", "--dry-run")

    def test_disabled_input(self):
        self.error("ControlStopped", "type", "--window", self.address, "--text", "hola", "--session", "host")
        self.assertFalse((self.root / "input.json").exists())

    def test_unicode_stdin_not_shell_or_options(self):
        self.cli("enable")
        text = "--help; $(touch /DO-NOT-CREATE) `echo hello` ñáéíóú ∇\nsecond line"
        self.cli("type", "--window", self.address, "--text", text, "--session", "host")
        captured = json.loads((self.root / "input.json").read_text())
        self.assertEqual(captured, {"argv": ["-"], "text": text})

    def test_wrong_focus(self):
        self.cli("enable")
        self.active = "0x999"
        self.error("WindowNotFocused", "type", "--window", self.address, "--text", "hola", "--session", "host")
        self.assertFalse((self.root / "input.json").exists())

    def test_xwayland_uses_xdotool_and_stdin(self):
        self.xwayland = True
        self.cli("enable")
        self.cli("type", "--window", self.address, "--text", "ñáéíóú", "--session", "host")
        captured = json.loads((self.root / "input.json").read_text())
        self.assertEqual(captured, {"argv": ["type", "--delay", "12", "--file", "-"], "text": "ñáéíóú"})

    def test_xwayland_rejects_other_display_target(self):
        self.xwayland = True
        self.cli("enable")
        self.env["DESKCTL_TEST_X11_PID"] = "456"
        self.error("X11TargetMismatch", "type", "--window", self.address, "--text", "hola", "--session", "host")
        self.assertFalse((self.root / "input.json").exists())

    def test_key_names_cannot_be_xdotool_commands(self):
        self.error("InvalidKeyChord", "key", "exec", "--window", self.address, "--session", "host", "--dry-run")
        self.error("InvalidKeyChord", "key", "windowkill", "--window", self.address, "--session", "host", "--dry-run")

    def test_locked_session(self):
        self.locked = True
        self.error("SessionLocked", "observe")
        self.error("SessionLocked", "enable")

    def test_session_mismatch(self):
        env = dict(self.env, WAYLAND_DISPLAY="wayland-wrong")
        self.error("SessionMismatch", "observe", env=env)
        self.error("SessionMismatch", "enable", env=env)

    def test_lua_dispatch_uses_validated_expression(self):
        self.cli("enable")
        self.provider = "lua"
        self.cli("focus", self.address, "--session", "host")
        self.assertIn("/dispatch hl.dsp.focus({window='address:0x123'})", self.commands)
        self.provider = "unknown"
        self.error("UnsupportedConfigProvider", "focus", self.address, "--session", "host")

    def test_stop_cancels_helper_and_blocks_competing_input(self):
        self.cli("enable")
        child = subprocess.Popen([str(BIN), "type", "--window", self.address, "--text", "SLOW", "--session", "host", "--backend", "helper"], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 3
            while not (self.root / "input.json").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((self.root / "input.json").exists())
            self.error("ControlBusy", "focus", self.address, "--session", "host")
            start = time.monotonic()
            self.cli("stop")
            stdout, _ = child.communicate(timeout=2)
            self.assertLess(time.monotonic() - start, 1)
            self.assertEqual(json.loads(stdout)["err"]["code"], "ControlStopped")
            self.error("ControlStopped", "focus", self.address, "--session", "host")
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()

    def test_invalid_frame_and_arguments(self):
        self.error("InvalidFrameId", "click", "--frame", "../../file", "--x", "0", "--y", "0", "--session", "host", "--dry-run")
        self.error("UnknownOption", "observe", "--unknown", "x")
        self.error("SessionRequired", "focus", self.address)
        self.error("SessionNotFound", "state", "--session", "agent-1")

    def test_wait_conditions_and_timeouts(self):
        self.cli("wait", "focus", "--window", self.address)
        self.cli("wait", "window", "--window", self.address)
        self.cli("wait", "stable", "--stable-ms", "100", "--timeout-ms", "1000")
        self.cli("wait", "stable", "--pixels", "--stable-ms", "100", "--timeout-ms", "1000")
        self.error("WaitTimeout", "wait", "focus", "--window", "0x999", "--timeout-ms", "100")
        self.error("InvalidWaitCondition", "wait", "whatever")

    def test_drag_destination_checked_before_input(self):
        f = self.frame()
        self.cli("drag", "--session", "host", "--frame", f["frame_id"], "--x", "1", "--y", "1", "--to-x", "4", "--to-y", "5", "--dry-run")
        self.error("CoordinatesOutOfBounds", "drag", "--session", "host", "--frame", f["frame_id"], "--x", "1", "--y", "1", "--to-x", "nan", "--to-y", "5", "--dry-run")
        self.assertFalse(any("dispatch" in cmd for cmd in self.commands))

    def test_pointer_window_bounds_and_continuous_xwayland_preflight(self):
        self.client_size = [100, 100]
        f = self.frame()
        self.error("PointerOutsideTarget", "click", "--session", "host", "--frame", f["frame_id"],
                   "--x", "300", "--y", "300", "--window", self.address, "--dry-run")
        self.xwayland = True
        f = self.frame()
        self.error("ContinuousScrollUnavailable", "scroll", "--session", "host", "--frame", f["frame_id"],
                   "--x", "10", "--y", "10", "--scroll-mode", "continuous", "--dry-run")
        self.assertFalse(any("dispatch" in cmd for cmd in self.commands))

    def test_pointer_approach_duration_options_without_input(self):
        f = self.frame()
        for command in ("move", "click", "doubleclick", "scroll", "drag"):
            base = (command, "--session", "host", "--frame", f["frame_id"], "--x", "10", "--y", "10", "--dry-run")
            if command == "drag": base += ("--to-x", "20", "--to-y", "20", "--duration-ms", "300")
            self.cli(*base)
            for ms in ("0", "50", "400", "10000"):
                self.cli(*base, "--move-duration-ms", ms)
            for ms in ("1", "49", "10001"):
                self.error("InvalidDuration", *base, "--move-duration-ms", ms)
            self.error("DuplicateOption", *base, "--move-duration-ms", "400", "--move-duration-ms", "500")
        self.error("UnknownOption", "observe", "--move-duration-ms", "400")
        self.assertFalse(any("dispatch" in cmd for cmd in self.commands))

    def test_aura_opt_out_is_pointer_only_and_dry_run_never_creates_surfaces(self):
        f = self.frame()
        for command in ("move", "click", "doubleclick", "scroll", "drag"):
            base = (command, "--session", "host", "--frame", f["frame_id"], "--x", "10", "--y", "10", "--dry-run")
            if command == "drag": base += ("--to-x", "20", "--to-y", "20")
            self.cli(*base, "--no-aura")
            self.error("DuplicateOption", *base, "--no-aura", "--no-aura")
        self.error("UnknownOption", "observe", "--no-aura")
        self.error("UnknownOption", "key", "ctrl+a", "--window", self.address, "--session", "host", "--no-aura")
        self.assertFalse(any("dispatch" in cmd for cmd in self.commands))

    def test_logs_redact_text_and_rotate(self):
        self.cli("enable")
        secret = "PRIVATE_TEST_TEXT_ñ"
        self.cli("type", "--window", self.address, "--text", secret, "--session", "host")
        entries = self.cli("logs")["entries"]
        self.assertEqual(entries[-1]["status"], "completed")
        self.assertNotIn(secret, json.dumps(entries))
        root = Path(self.frame()["image_path"]).parent
        log = root / "actions.jsonl"
        self.assertEqual(log.stat().st_mode & 0o777, 0o600)
        log.write_bytes(b" " * (1024 * 1024 + 1))
        self.cli("focus", self.address, "--session", "host", "--dry-run")
        self.assertTrue((root / "actions.previous.jsonl").exists())
        self.assertLess(log.stat().st_size, 4096)

    def test_logs_recover_partial_writes_and_truncated_tail(self):
        self.cli("enable")
        def short_write():
            resource.setrlimit(resource.RLIMIT_FSIZE, (128, 128))
            signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
        result = subprocess.run([str(BIN), "type", "--session", "host", "--window", self.address,
                                 "--backend", "helper", "--text", "x"], env=self.env,
                                preexec_fn=short_write, capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue((self.root / "input.json").exists())
        self.assertEqual(self.cli("logs")["entries"][-1]["status"], "started")
        path = next(self.root.glob("deskctl-*/actions.jsonl"))
        with path.open("ab") as out: out.write(b'{"interrupted":')
        logs = self.cli("logs")
        self.assertTrue(logs["incomplete_tail"])
        self.assertEqual(len(logs["entries"]), 1)
        self.cli("focus", self.address, "--session", "host", "--dry-run")
        logs = self.cli("logs", "--limit", "1")
        self.assertFalse(logs["incomplete_tail"])
        self.assertEqual(len(logs["entries"]), 1)
        self.assertEqual(logs["entries"][0]["status"], "completed")

    def test_observe_amortizes_gc_but_explicit_gc_never_skips(self):
        frame = self.frame()
        root = Path(frame["image_path"]).parent
        stale = root / ("b" * 32 + ".png")
        stale.write_bytes(b"old")
        os.utime(stale, (time.time() - 600,) * 2)
        self.frame()
        self.assertTrue(stale.exists())
        self.assertEqual(self.cli("gc")["files"], 1)
        self.assertFalse(stale.exists())
        stale.write_bytes(b"old")
        os.utime(stale, (time.time() - 600,) * 2)
        os.utime(root / "gc.stamp", (time.time() - 31,) * 2)
        self.frame()
        self.assertFalse(stale.exists())

    def test_gc_preserves_live_frames_unrelated_files_and_symlinks(self):
        f = self.frame()
        root = Path(f["image_path"]).parent
        unrelated = root / "important.txt"
        unrelated.write_text("keep")
        link = root / ("a" * 32 + ".png")
        link.symlink_to(unrelated)
        self.assertEqual(self.cli("gc", "--older-than-ms", "0")["files"], 0)
        image = Path(f["image_path"])
        for path in (image, image.with_suffix(".json")):
            os.utime(path, (time.time() - 600,) * 2)
        self.assertEqual(self.cli("gc", "--dry-run")["files"], 2)
        self.assertTrue(image.exists())
        self.assertEqual(self.cli("gc")["files"], 2)
        self.assertFalse(image.exists())
        self.assertTrue(link.is_symlink())
        self.assertEqual(unrelated.read_text(), "keep")

    def test_focus_lock_and_sigterm_cancel_inflight_helper(self):
        for cause in ("focus", "lock", "signal"):
            with self.subTest(cause=cause):
                self.active, self.locked = self.address, False
                (self.root / "input.json").unlink(missing_ok=True)
                self.cli("enable")
                child = subprocess.Popen([str(BIN), "type", "--window", self.address, "--text", "SLOW", "--session", "host", "--backend", "helper"], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    deadline = time.monotonic() + 2
                    while not (self.root / "input.json").exists() and time.monotonic() < deadline:
                        time.sleep(.01)
                    self.assertTrue((self.root / "input.json").exists())
                    if cause == "focus": self.active = "0x999"
                    elif cause == "lock": self.locked = True
                    else: child.send_signal(signal.SIGTERM)
                    stdout, _ = child.communicate(timeout=2)
                    expected = {"focus": "WindowNotFocused", "lock": "SessionLocked", "signal": "Cancelled"}[cause]
                    self.assertEqual(json.loads(stdout)["err"]["code"], expected)
                finally:
                    if child.poll() is None: child.kill()
                    child.communicate()

    def test_event_stream_has_json_records_and_summary(self):
        server = socket.socket(socket.AF_UNIX)
        server.bind(str(self.session / ".socket2.sock"))
        server.listen()
        def emit():
            with server.accept()[0] as conn:
                conn.sendall(b'activewindow>>app,title "quoted"\nworkspace>>2\n')
                time.sleep(.2)
        thread = threading.Thread(target=emit)
        thread.start()
        try:
            result = subprocess.run([str(BIN), "events", "--limit", "2", "--timeout-ms", "500"], env=self.env, capture_output=True, text=True, timeout=2)
            rows = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual(rows[0]["event"], "activewindow")
            self.assertEqual(rows[-1]["events"], 2)
            self.assertFalse(rows[-1]["timed_out"])
        finally:
            thread.join(timeout=2)
            server.close()

    def test_event_serialization_memory_is_bounded(self):
        server = socket.socket(socket.AF_UNIX)
        server.bind(str(self.session / ".socket2.sock"))
        server.listen()
        server.settimeout(5)
        def emit():
            try:
                with server.accept()[0] as conn:
                    conn.settimeout(5)
                    for _ in range(4096): conn.sendall(b"activewindow>>" + b"x" * 60000 + b"\n")
            except (BrokenPipeError, ConnectionResetError, socket.timeout):
                pass
        thread = threading.Thread(target=emit)
        thread.start()
        def bounded(): resource.setrlimit(resource.RLIMIT_AS, (128 * 1024**2,) * 2)
        try:
            result = subprocess.run([str(BIN), "events", "--limit", "4096", "--timeout-ms", "5000"],
                                    env=self.env, preexec_fn=bounded, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.PIPE, timeout=7)
            self.assertEqual(result.returncode, 0, result.stderr)
        finally:
            thread.join(timeout=6)
            server.close()

    def test_large_adjacent_events_are_limited_per_record(self):
        server = socket.socket(socket.AF_UNIX)
        server.bind(str(self.session / ".socket2.sock"))
        server.listen()
        server.settimeout(3)
        line = b"activewindow>>" + b"x" * (65535 - len(b"activewindow>>\n")) + b"\n"
        def emit():
            try:
                with server.accept()[0] as conn:
                    conn.settimeout(3)
                    conn.sendall(line * 3)
            except (BrokenPipeError, socket.timeout):
                pass
        thread = threading.Thread(target=emit)
        thread.start()
        try:
            result = subprocess.run([str(BIN), "events", "--limit", "3", "--timeout-ms", "2000"],
                                    env=self.env, capture_output=True, text=True, timeout=3)
            self.assertEqual(result.returncode, 0, result.stdout[-500:])
            rows = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(rows[-1]["events"], 3)
        finally:
            thread.join(timeout=3)
            server.close()

    def test_native_backend_does_not_fall_back_to_helpers(self):
        self.cli("enable")
        self.error("WaylandUnavailable", "type", "--session", "host", "--window", self.address, "--text", "hello", "--backend", "native")
        self.assertFalse((self.root / "input.json").exists())

    def test_session_management_rejects_host_and_path_traversal(self):
        self.error("InvalidSessionName", "session", "destroy", "host")
        self.error("InvalidSessionName", "session", "create", "../escape")
        self.error("SessionNotFound", "session", "inspect", "missing")
        self.assertEqual(self.cli("sessions")["sessions"][0]["id"], "host")


if __name__ == "__main__":
    unittest.main(verbosity=2)
