"""Optional real-GTK lifecycle test with a private Broadway display, never host.

Requires zig build pip and gtk4-broadwayd. No browser/client or GPU is required;
this checks GTK callbacks, texture reuse, signal loss and process shutdown, not
physical presentation FPS. HTTP uses a private Unix socket, not a TCP listener.
"""
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import time
import unittest

import preview as preview_fixture

BIN = preview_fixture.BIN


@unittest.skipUnless(shutil.which("gtk4-broadwayd"), "optional gtk4-broadwayd is unavailable")
class Viewer(unittest.TestCase):
    def setUp(self):
        self.fixture = preview_fixture.Preview()
        self.fixture.sleeper_seconds = getattr(self, "sleeper_seconds", 60)
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.root = self.fixture.root
        (self.root / "valid-png").touch()
        self.env = dict(self.fixture.env, GDK_BACKEND="broadway", BROADWAY_DISPLAY=":19",
                        DESKCTL_PIP_APP_ID="deskctl-test-private", DESKCTL_PIP_METRICS="1")
        for name in ("DISPLAY", "WAYLAND_SOCKET", "DBUS_SESSION_BUS_ADDRESS", "AT_SPI_BUS_ADDRESS"):
            self.env.pop(name, None)
        self.daemon = subprocess.Popen(["gtk4-broadwayd", "--unixsocket=" + str(self.root / "http.sock"), ":19"],
                                       env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.addCleanup(self.finish, self.daemon)
        deadline = time.monotonic() + 3
        while not list(self.root.glob("broadway*.socket")):
            self.assertIsNone(self.daemon.poll())
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        self.viewer = subprocess.Popen([str(BIN.with_name("deskctl-pip")), str(BIN), "check", "test", "HEADLESS-1", "15"],
                                       env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        self.addCleanup(self.finish, self.viewer)
        self.pending = b""

    def finish(self, process):
        if process.poll() is None: process.terminate()
        try: process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            self.fail("owned process did not terminate")

    def metrics(self):
        deadline = time.monotonic() + 7
        while b"\n" not in self.pending:
            self.assertIsNone(self.viewer.poll(), "viewer exited early")
            self.assertTrue(select.select([self.viewer.stdout], [], [], max(0, deadline - time.monotonic()))[0])
            data = os.read(self.viewer.stdout.fileno(), 4096)
            self.assertTrue(data)
            self.pending += data
        line, self.pending = self.pending.split(b"\n", 1)
        return json.loads(line)

    def test_real_gtk_reuses_texture_recovers_signal_and_closes(self):
        first = self.metrics()
        self.assertGreater(first["received_frames"], 1)
        self.assertEqual(first["texture_updates"], 1)
        (self.root / "locked").touch()
        locked = self.metrics()
        self.assertFalse(locked["signal_live"])
        (self.root / "locked").unlink()
        (self.root / "changed").touch()
        recovered = self.metrics()
        self.assertTrue(recovered["signal_live"])
        self.assertGreater(recovered["texture_updates"], 1)
        self.viewer.terminate()
        out, err = self.viewer.communicate(timeout=3)
        self.assertEqual(self.viewer.returncode, 0, err.decode())
        self.assertNotIn(b"CRITICAL", err)
        capture = json.loads((self.root / "capture.json").read_text())
        self.assertFalse(Path(f"/proc/{capture['pid']}").exists())

    def test_close_during_capture_reaps_a_helper_ignoring_term(self):
        (self.root / "slow").touch()
        (self.root / "ignore-term").touch()
        deadline = time.monotonic() + 4
        marker = self.root / "capture.json"
        while not marker.exists():
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        pid = json.loads(marker.read_text())["pid"]
        self.viewer.terminate()
        _, err = self.viewer.communicate(timeout=3)
        self.assertEqual(self.viewer.returncode, 0, err.decode())
        self.assertFalse(Path(f"/proc/{pid}").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
