"""PiP worker contracts: private fake compositor/helpers, no GUI or input."""
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import unittest

from session_lifecycle import SessionLifecycle, BIN, live


class Preview(unittest.TestCase):
    # Reuse only fixture utilities, not the lifecycle test cases.
    pin = SessionLifecycle.pin
    sleeper = SessionLifecycle.sleeper
    save = SessionLifecycle.save
    cli = SessionLifecycle.cli
    tearDown = SessionLifecycle.tearDown

    def setUp(self):
        SessionLifecycle.setUp(self)
        self.metadata.update(compositor=self.sleeper(), bus=self.sleeper())
        self.save()
        self.requests = []
        ipc_dir = self.runtime / "hypr/test"
        ipc_dir.mkdir(parents=True)
        (ipc_dir / "hyprland.lock").write_text(f"{self.metadata['compositor']['pid']}\nwayland-test\n")
        server = socket.socket(socket.AF_UNIX)
        server.bind(str(ipc_dir / ".socket.sock"))
        server.listen()
        server.settimeout(0.05)
        stop = threading.Event()

        def serve():
            while not stop.is_set():
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                with conn:
                    request = conn.recv(8192).decode()
                    self.requests.append(request)
                    if request == "j/locked":
                        data = {"locked": (self.root / "locked").exists()}
                    elif request == "j/monitors":
                        data = [{"id": 1, "name": "HEADLESS-1", "width": 1920, "height": 1080,
                                 "scale": 1, "x": 0, "y": 0, "transform": 0,
                                 "activeWorkspace": {"id": 1}, "focused": True}]
                    else:
                        data = {}
                    try:
                        conn.sendall(json.dumps(data).encode())
                    except BrokenPipeError:
                        pass

        thread = threading.Thread(target=serve)
        thread.start()
        self.servers.append((stop, thread, server))
        helper = self.root / "grim"
        helper.write_text(f"#!{sys.executable}\n" + r'''
import json, os, pathlib, struct, sys, time
root = pathlib.Path(os.environ['DESKCTL_PREVIEW_TEST_ROOT'])
(root / 'capture.json').write_text(json.dumps({'argv': sys.argv, 'pid': os.getpid(),
    'runtime': os.environ['XDG_RUNTIME_DIR'], 'instance': os.environ['HYPRLAND_INSTANCE_SIGNATURE']}))
if (root / 'slow').exists(): time.sleep(30)
if (root / 'lock-after').exists(): (root / 'locked').touch()
width = 9999 if (root / 'oversize').exists() else 960
sys.stdout.buffer.write(b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 13) + b'IHDR' + struct.pack('>II', width, 540))
''')
        helper.chmod(0o700)
        self.env.update(PATH=f"{self.root}:{os.environ['PATH']}", DESKCTL_PREVIEW_TEST_ROOT=str(self.root))
        self.cli("enable", "--session", "check")

    def argv(self, command="_preview_frame", instance="test", monitor="HEADLESS-1"):
        argv = [str(BIN), command, "--session", "check", "--expected-instance", instance]
        if command == "_preview_frame":
            argv += ["--monitor", monitor]
        return argv

    def worker(self, **kwargs):
        return subprocess.run(self.argv(**kwargs), env=self.env, capture_output=True, timeout=8)

    def error(self, code, **kwargs):
        result = self.worker(**kwargs)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["err"]["code"], code)

    def test_frames_are_memory_only_cursor_included_and_source_routed(self):
        before = set(self.runtime.rglob("*"))
        for _ in range(3):
            result = self.worker()
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual(result.stdout[:5], b"DCP1\1")
            self.assertGreater(struct.unpack('<q', result.stdout[5:13])[0], 0)
            self.assertEqual(result.stdout[13:21], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(before, set(self.runtime.rglob("*")))
        capture = json.loads((self.root / "capture.json").read_text())
        self.assertEqual(capture["runtime"], str(self.runtime))
        self.assertEqual(capture["instance"], "test")
        self.assertIn("-c", capture["argv"])
        self.assertEqual(capture["argv"][-1], "-")
        self.assertFalse(any("dispatch" in command for command in self.requests))

    def test_wrong_instance_cannot_capture_or_stop_replacement(self):
        self.error("PreviewIdentityMismatch", instance="replacement")
        self.error("PreviewIdentityMismatch", command="_preview_stop", instance="replacement")
        self.assertFalse((self.root / "capture.json").exists())
        self.assertEqual(self.worker().stdout[:5], b"DCP1\1")

    def test_stop_disables_only_input_and_preview_continues(self):
        result = self.worker(command="_preview_stop")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(live(self.metadata["compositor"]))
        self.assertTrue(live(self.metadata["bus"]))
        self.assertEqual(self.worker().stdout[:5], b"DCP1\0")

    def test_missing_monitor_never_falls_back(self):
        self.error("MonitorNotFound", monitor="HOST-DP")
        self.assertFalse((self.root / "capture.json").exists())

    def test_locked_and_lock_during_capture_never_return_pixels(self):
        (self.root / "locked").touch()
        self.error("SessionLocked")
        self.assertFalse((self.root / "capture.json").exists())
        (self.root / "locked").unlink()
        (self.root / "lock-after").touch()
        self.error("SessionLocked")

    def test_rejects_oversized_png_before_ui_decode(self):
        (self.root / "oversize").touch()
        self.error("InvalidScreenshot")

    def test_capture_timeout_reaps_helper(self):
        (self.root / "slow").touch()
        started = time.monotonic()
        self.error("HelperTimeout")
        self.assertLess(time.monotonic() - started, 4)
        pid = json.loads((self.root / "capture.json").read_text())["pid"]
        self.assertFalse(Path(f"/proc/{pid}").exists())

    def test_cancel_reaps_helper(self):
        (self.root / "slow").touch()
        process = subprocess.Popen(self.argv(), env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 4
            while not (self.root / "capture.json").exists():
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            process.send_signal(signal.SIGTERM)
            stdout, _ = process.communicate(timeout=4)
            self.assertEqual(json.loads(stdout)["err"]["code"], "Cancelled")
            pid = json.loads((self.root / "capture.json").read_text())["pid"]
            self.assertFalse(Path(f"/proc/{pid}").exists())
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == "__main__":
    unittest.main(defaultTest="Preview", verbosity=2)
