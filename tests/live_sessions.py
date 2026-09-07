"""Opt-in lifecycle test, creates/cleans only uniquely named managed sessions.

python3 tests/live_sessions.py --live [--headless]
Headless incompatibility is reported as an explicit skip after cleanup checks.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

BIN = Path(__file__).resolve().parents[1] / "zig-out/bin/hyprhand"

def cli(*args, ok=True):
    p = subprocess.run([str(BIN), *args], capture_output=True, text=True, timeout=20)
    payload = json.loads(p.stdout)
    if ok: assert p.returncode == 0, (payload, p.stderr)
    return payload

def live(pid):
    try:
        status = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
        return status not in ("Z", "X")
    except FileNotFoundError:
        return False

def owned_processes(runtime):
    matches = []
    needle = f"XDG_RUNTIME_DIR={runtime}".encode()
    for path in Path("/proc").iterdir():
        if not path.name.isdigit(): continue
        try:
            if needle in (path / "environ").read_bytes().split(b"\0") and live(int(path.name)):
                matches.append(int(path.name))
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            pass
    return matches

def main():
    name = "check-" + uuid.uuid4().hex[:8]
    headless = "--headless" in sys.argv
    args = ["session", "create", name] + ([] if headless else ["--nested"])
    bridge = None
    if "--headless-bridge" in sys.argv:
        assert headless, "--headless-bridge requires --headless"
        bridge = sys.argv[sys.argv.index("--headless-bridge") + 1]
        args += ["--headless-bridge", bridge]
    if "--lua" in sys.argv: args += ["--lua"]
    runtime_parent = Path(os.environ["XDG_RUNTIME_DIR"])
    before = set(runtime_parent.glob("d????????"))
    result = cli(*args, ok=False)
    if not result["ok"]:
        for runtime in set(runtime_parent.glob("d????????")) - before:
            assert not owned_processes(runtime), ("Orphaned failed session", owned_processes(runtime))
        if headless and result["err"]["code"] == "HeadlessRenderUnavailable":
            print(json.dumps({"ok": True, "headless": "unavailable-on-this-GPU", "failure_cleanup_verified": True}))
            return
        raise AssertionError(result)
    session = result["session"]
    try:
        if bridge:
            assert session["headless_bridge"] == bridge
            for role in ("compositor", "bus", "registry"):
                if not session.get(role): continue
                env = Path(f"/proc/{session[role]['pid']}/environ").read_bytes().split(b"\0")
                preloads = [v for v in env if v.startswith(b"LD_PRELOAD=")]
                assert preloads == ([f"LD_PRELOAD={bridge}".encode()] if role == "compositor" else []), (role, preloads)
        assert cli("session", "create", name, "--nested", ok=False)["err"]["code"] == "SessionExists"
        assert not cli("doctor", "--session", name)["shared_cursor"]
        cli("enable", "--session", name)
        cli("wait", "stable", "--pixels", "--stable-ms", "100", "--session", name)
        stream = subprocess.Popen([str(BIN), "events", "--session", name, "--limit", "1", "--timeout-ms", "3000"], text=True, stdout=subprocess.PIPE)
        try:
            time.sleep(.1)
            cli("workspace", "2", "--session", name)
            cli("wait", "workspace", "--workspace", "2", "--session", name)
            records = [json.loads(line) for line in stream.communicate(timeout=4)[0].splitlines()]
            assert records[-1]["events"] == 1, records
        finally:
            if stream.poll() is None: stream.kill(); stream.wait()
        launched = cli("launch", "--session", name, "--", "/usr/bin/sleep", "60")
        pid = launched["process"]["pid"]
        env = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
        assert b"DISPLAY=" not in env
        assert not any(v.startswith(b"DISPLAY=") for v in env)
        assert f"XDG_RUNTIME_DIR={session['runtime']}".encode() in env
        assert f"DBUS_SESSION_BUS_ADDRESS={session['dbus']}".encode() in env
        assert f"HOME={os.environ['HOME']}".encode() in env
        if bridge: assert not any(v.startswith(b"LD_PRELOAD=") for v in env), env
        cli("session", "destroy", name)
        for _ in range(30):
            if not owned_processes(session["runtime"]): break
            time.sleep(.1)
        assert not owned_processes(session["runtime"]), owned_processes(session["runtime"])
        assert cli("state", "--session", name, ok=False)["err"]["code"] == "SessionNotRunning"
        assert Path(session["directory"]).exists(), "Profiles must be retained"
        print(json.dumps({"ok": True, "verified": ["create", "duplicate rejected", "routing", "pixel wait", "native events", "workspace wait", "launch", "environment isolation", "destroy", "no owned live processes", "profiles retained"]}))
    finally:
        cli("session", "destroy", name)

if __name__ == "__main__":
    if "--live" not in sys.argv: sys.exit("Use --live to create a temporary compositor")
    main()
