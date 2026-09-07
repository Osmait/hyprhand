"""IPC deadlines and cancellation using private sockets, never desktop input."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import threading
import time
import unittest

BIN = Path(os.environ.get("HYPRHAND_TEST_BIN", str(Path(__file__).resolve().parents[1] / "zig-out/bin/hyprhand")))


class IPC(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hyprhand-ipc-")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        ipc = root / "hypr/test"
        ipc.mkdir(parents=True)
        self.env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                        HYPRLAND_INSTANCE_SIGNATURE="test", WAYLAND_DISPLAY="unused")
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(str(ipc / ".socket.sock"))
        self.server.listen()
        self.server.settimeout(0.1)
        self.addCleanup(self.server.close)
        self.stop = threading.Event()
        self.accepted = threading.Event()

    def run_peer(self, mode):
        def serve():
            while not self.stop.is_set():
                try:
                    connection, _ = self.server.accept()
                    break
                except socket.timeout:
                    continue
            else:
                return
            with connection:
                connection.recv(8192)
                self.accepted.set()
                if mode == "fragmented":
                    chunks = (b"[", b"{\"name\":", b"\"test\"}", b"]")
                    for chunk in chunks:
                        connection.sendall(chunk)
                        if self.stop.wait(0.02):
                            return
                    return
                while not self.stop.wait(0.1):
                    if mode == "trickle":
                        try:
                            connection.sendall(b" ")
                        except BrokenPipeError:
                            return
        thread = threading.Thread(target=serve)
        thread.start()
        def cleanup():
            self.stop.set()
            thread.join(timeout=2)
            self.assertFalse(thread.is_alive())
        self.addCleanup(cleanup)

    def spawn(self):
        process = subprocess.Popen([str(BIN), "monitors"], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        def cleanup():
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=2)
        self.addCleanup(cleanup)
        self.assertTrue(self.accepted.wait(2))
        return process

    def test_fragmented_reply_is_preserved(self):
        self.run_peer("fragmented")
        process = self.spawn()
        out, err = process.communicate(timeout=2)
        self.assertEqual(process.returncode, 0, err)
        self.assertEqual(json.loads(out)["data"], [{"name": "test"}])

    def test_trickle_cannot_extend_total_deadline(self):
        self.run_peer("trickle")
        started = time.monotonic()
        process = self.spawn()
        out, _ = process.communicate(timeout=4.5)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(json.loads(out)["err"]["code"], "IpcReadTimeout")
        self.assertLess(time.monotonic() - started, 4.5)

    def test_signal_cancels_a_silent_peer_promptly(self):
        self.run_peer("silent")
        process = self.spawn()
        started = time.monotonic()
        process.send_signal(signal.SIGTERM)
        out, _ = process.communicate(timeout=1)
        self.assertEqual(json.loads(out)["err"]["code"], "Cancelled")
        self.assertLess(time.monotonic() - started, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
