"""Non-desktop session cleanup regressions: python3 tests/session_lifecycle.py.

Uses private metadata, a fake IPC socket, and disposable subprocess trees only.
Build first with zig build; DESKCTL_TEST_BIN can select a different binary.
Linux pidfds are required by both the implementation and this test's cleanup.
"""
import ctypes
import fcntl
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest


BIN = Path(os.environ.get("DESKCTL_TEST_BIN", str(Path(__file__).resolve().parents[1] / "zig-out/bin/deskctl")))


def identity(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    return {"pid": pid, "start": fields[19]}


def live(process):
    try:
        fields = Path(f"/proc/{process['pid']}/stat").read_text().rsplit(")", 1)[1].split()
        return fields[0] not in ("Z", "X") and fields[19] == process["start"]
    except FileNotFoundError:
        return False


TREE = r'''
import ctypes, json, os, signal, sys, threading, time, warnings
from pathlib import Path
mode = sys.argv[1]
# Deliberately exercise fork from a non-leader thread in this tiny fixture.
warnings.filterwarnings("ignore", category=DeprecationWarning, message="This process.*multi-threaded")
ctypes.CDLL(None).prctl(15, b"tree ) name", 0, 0, 0)
if mode == "ignore":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
def report():
    fields = Path(f"/proc/{os.getpid()}/stat").read_text().rsplit(")", 1)[1].split()
    os.write(1, (json.dumps({"pid": os.getpid(), "start": fields[19]}) + "\n").encode())
def children():
    if os.fork() == 0:
        os.setsid()
        if os.fork() == 0:
            os.setsid()
        report()
        while True: time.sleep(1)
thread = threading.Thread(target=children)
thread.start()
thread.join()
report()
while True: time.sleep(1)
'''


class SessionLifecycle(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Adopt only this test process's orphaned grandchildren for reaping.
        cls.libc = ctypes.CDLL(None, use_errno=True)
        cls.previous_subreaper = ctypes.c_int()
        if cls.libc.prctl(37, ctypes.byref(cls.previous_subreaper), 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "PR_GET_CHILD_SUBREAPER")
        if cls.libc.prctl(36, 1, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")

    @classmethod
    def tearDownClass(cls):
        cls.libc.prctl(36, cls.previous_subreaper.value, 0, 0, 0)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="deskctl-lifecycle-")
        self.root = Path(self.temp.name)
        self.directory = self.root / "deskctl-sessions/check"
        self.directory.mkdir(mode=0o700, parents=True)
        self.directory.parent.chmod(0o700)
        self.runtime = self.root / "d12345678"
        self.runtime.mkdir(mode=0o700)
        self.env = dict(os.environ, XDG_RUNTIME_DIR=str(self.root),
                        HYPRLAND_INSTANCE_SIGNATURE="unused-host", WAYLAND_DISPLAY="unused-host")
        self.children = []
        self.pinned = {}
        self.servers = []
        self.metadata = dict(schema=1, name="check", compositor={"pid": 0, "start": "0"},
                             bus={"pid": 0, "start": "0"}, runtime=str(self.runtime),
                             instance="test", display="wayland-test", dbus="unused",
                             directory=str(self.directory), nested=False, destroyed=False)
        self.save()

    def tearDown(self):
        for stop, thread, server in self.servers:
            stop.set()
            thread.join(timeout=2)
            server.close()
        for fd in self.pinned.values():
            try:
                signal.pidfd_send_signal(fd, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for child in self.children:
            child.wait(timeout=5)
            if child.stdout:
                child.stdout.close()
        for pid, fd in self.pinned.items():
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
            os.close(fd)
        self.temp.cleanup()

    def pin(self, process):
        pid = process["pid"]
        if pid not in self.pinned:
            fd = os.pidfd_open(pid)
            self.assertEqual(identity(pid), process)
            self.pinned[pid] = fd
        return process

    def sleeper(self, **kwargs):
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], **kwargs)
        self.children.append(child)
        return self.pin(identity(child.pid))

    def tree(self, mode="normal"):
        child = subprocess.Popen([sys.executable, "-c", TREE, mode], stdout=subprocess.PIPE,
                                 process_group=0)
        self.children.append(child)
        # Register the leader even if fixture setup fails before it reports.
        self.pin(identity(child.pid))
        records, data = [], b""
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + 5
            while len(records) < 3:
                self.assertGreater(deadline - time.monotonic(), 0, "tree startup timed out")
                if not selector.select(max(0, deadline - time.monotonic())):
                    continue
                chunk = os.read(child.stdout.fileno(), 4096)
                self.assertTrue(chunk, "tree exited before reporting")
                data += chunk
                while b"\n" in data:
                    line, data = data.split(b"\n", 1)
                    records.append(self.pin(json.loads(line)))
        return identity(child.pid), records

    def save(self):
        (self.directory / "session.json").write_text(json.dumps(self.metadata))

    def record_app(self, process, name="tree"):
        (self.directory / f"app-{name}.json").write_text(json.dumps(process))

    def cli(self, *args, ok=True):
        result = subprocess.run([str(BIN), *args], env=self.env, capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode == 0, ok, (result.stdout, result.stderr))
        payload = json.loads(result.stdout)
        self.assertEqual(payload["ok"], ok, payload)
        return payload

    def destroy(self, **kwargs):
        return self.cli("session", "destroy", "check", **kwargs)

    def fake_running_session(self):
        self.metadata.update(compositor=self.sleeper(), bus=self.sleeper())
        self.save()
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
                    command = conn.recv(8192)
                    conn.sendall(b'{"locked":false}' if command == b"j/locked" else b"{}")

        thread = threading.Thread(target=serve)
        thread.start()
        self.servers.append((stop, thread, server))
        self.cli("enable", "--session", "check")

    def test_descendants_across_sessions_and_threads_leave_same_group_sentinel(self):
        root, records = self.tree()
        sentinel = self.sleeper(process_group=root["pid"])
        self.record_app(root)
        self.record_app(root, "duplicate")
        self.destroy()
        self.assertTrue(all(not live(p) for p in records), records)
        self.assertTrue(live(sentinel), "unrelated member of the same process group was signalled")
        self.assertTrue(self.directory.exists())
        self.destroy()  # Idempotent, retains profiles and logs.

    def test_term_ignoring_tree_is_killed_and_exit_confirmed(self):
        root, records = self.tree("ignore")
        self.record_app(root)
        self.destroy()
        self.assertTrue(all(not live(p) for p in records), records)

    def test_already_stopped_process_is_terminated(self):
        app = self.sleeper()
        self.record_app(app)
        signal.pidfd_send_signal(self.pinned[app["pid"]], signal.SIGSTOP)
        deadline = time.monotonic() + 3
        while Path(f"/proc/{app['pid']}/stat").read_text().rsplit(")", 1)[1].split()[0] != "T":
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        self.destroy()
        self.assertFalse(live(app))

    def test_late_fork_from_surviving_parent_is_captured(self):
        report = self.root / "late-child.json"
        ready = self.root / "ready"
        helper = r'''
import json, os, signal, sys, time
from pathlib import Path
def on_term(signum, frame):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if os.fork() == 0:
        os.setsid()
        fields = Path(f"/proc/{os.getpid()}/stat").read_text().rsplit(")", 1)[1].split()
        Path(sys.argv[1]).write_text(json.dumps({"pid": os.getpid(), "start": fields[19]}))
signal.signal(signal.SIGTERM, on_term)
Path(sys.argv[2]).touch()
while True: time.sleep(1)
'''
        child = subprocess.Popen([sys.executable, "-c", helper, str(report), str(ready)])
        self.children.append(child)
        root = self.pin(identity(child.pid))
        self.record_app(root)
        deadline = time.monotonic() + 5
        while not ready.exists():
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        destroy = subprocess.Popen([str(BIN), "session", "destroy", "check"], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            while not report.exists() or not report.stat().st_size:
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            late = self.pin(json.loads(report.read_text()))
            stdout, stderr = destroy.communicate(timeout=8)
            self.assertEqual(destroy.returncode, 0, (stdout, stderr))
            self.assertTrue(json.loads(stdout)["ok"])
            self.assertFalse(live(root))
            self.assertFalse(live(late))
        finally:
            if destroy.poll() is None:
                destroy.kill()
                destroy.wait(timeout=5)
            destroy.stdout.close()
            destroy.stderr.close()

    def test_stale_start_identity_does_not_touch_tree(self):
        root, records = self.tree()
        self.record_app(dict(root, start=str(int(root["start"]) + 1)))
        self.destroy()
        self.assertTrue(all(live(p) for p in records))

    def test_compositor_bus_and_registry_descendants(self):
        records = []
        for role in ("compositor", "bus", "registry"):
            self.metadata[role], tree = self.tree()
            records.extend(tree)
        self.save()
        self.destroy()
        self.assertTrue(all(not live(p) for p in records))

    def test_ancestor_metadata_is_rejected_before_stopping_anything(self):
        app = self.sleeper()
        self.record_app(app)
        self.metadata["compositor"] = identity(os.getpid())
        self.save()
        result = self.destroy(ok=False)
        self.assertEqual(result["err"]["code"], "UnsafeProcessTarget")
        self.assertTrue(live(app))
        self.assertFalse(json.loads((self.directory / "session.json").read_text())["destroyed"])

    def test_running_requires_both_compositor_and_bus(self):
        self.metadata.update(compositor=self.sleeper(), bus=self.sleeper())
        self.save()
        for expected in (True, False):
            self.assertEqual(self.cli("session", "inspect", "check")["running"], expected)
            entry = next(s for s in self.cli("sessions")["sessions"] if s["id"] == "check")
            self.assertEqual(entry["running"], expected)
            self.metadata["bus"]["start"] = "0"
            self.save()
        self.assertEqual(self.cli("state", "--session", "check", ok=False)["err"]["code"], "SessionNotRunning")

    def test_firefox_profile_overrides_are_rejected_before_spawn(self):
        self.fake_running_session()
        for flag in ("-P", "--profile=/tmp/shared", "-profile", "--PROFILE", "-ProfileManager", "--CreateProfile=test"):
            with self.subTest(flag=flag):
                result = self.cli("launch", "--session", "check", "--", "firefox", flag, ok=False)
                self.assertEqual(result["err"]["code"], "ProfileOverrideDenied")
        self.assertFalse(list(self.directory.glob("app-*.json")))

    def test_launch_and_destroy_use_the_session_lifecycle_lock(self):
        self.fake_running_session()
        with (self.directory / "action.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.destroy(ok=False)["err"]["code"], "ControlBusy")
            result = self.cli("launch", "--session", "check", "--", "/usr/bin/sleep", "60", ok=False)
            self.assertEqual(result["err"]["code"], "ControlBusy")
        self.assertFalse(list(self.directory.glob("app-*.json")))

    def test_successful_launch_is_recorded_and_destroyed(self):
        self.fake_running_session()
        result = self.cli("launch", "--session", "check", "--", sys.executable,
                          "-c", "import time; time.sleep(60)")
        app = self.pin(result["process"])
        records = list(self.directory.glob("app-*.json"))
        self.assertEqual(len(records), 1)
        self.assertEqual(json.loads(records[0].read_text()), app)
        self.destroy()
        self.assertFalse(live(app))

    def test_dead_root_does_not_authorize_reparented_descendants(self):
        root, records = self.tree()
        self.record_app(root)
        signal.pidfd_send_signal(self.pinned[root["pid"]], signal.SIGKILL)
        self.children[0].wait(timeout=5)
        self.destroy()
        # Explicit boundary: their ancestry was lost before cleanup started.
        self.assertTrue(all(live(p) for p in records if p != root))


if __name__ == "__main__":
    unittest.main(verbosity=2)
