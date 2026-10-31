"""Opt-in Chromium text-entry test in its own uniquely named managed session.

python3 tests/live_keyboard_chromium.py --live [--browser /usr/bin/brave]
    [--headless --headless-bridge /absolute/trusted.so] [--trials 20]

Types mixed Spanish/Unicode text into a local textarea with the native keyboard
and with `--backend clipboard`, and reads the value back through the page title
(length and FNV-1a hash, never the text). Regression: Chromium ran Escape,
Backspace or Tab for characters such as "Ñ" or space placed on those keycodes.
The session, its browser and its clipboard are destroyed at the end.
"""
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

BIN = Path(os.environ.get("HYPRHAND_TEST_BIN",
                        Path(__file__).resolve().parents[1] / "zig-out/bin/hyprhand"))

PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>KB0:0</title></head>
<body><textarea id="t" autofocus style="width:90vw;height:80vh"></textarea><script>
const t = document.getElementById('t');
function update() {
  let h = 0x811c9dc5;
  for (let i = 0; i < t.value.length; i++) {
    h ^= t.value.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  document.title = 'KB' + t.value.length + ':' + h.toString(16);
}
t.addEventListener('input', update);
addEventListener('keydown', e => {
  if (e.key === 'F9') { t.value = ''; update(); e.preventDefault(); }
});
setInterval(() => { if (document.activeElement !== t) t.focus(); }, 200);
</script></body></html>
"""

WORDS = ("PACIENTE MASCULINO DE 21 AÑOS EN EL AÑO 2021 niño señor España CAMIÓN "
         "¿Qué? ¡Hola! 30€ información MÉDICO ÚLTIMO Ñandú pingüino ÁRBOL Ítem "
         "Óscar Ü ç Ç 12,5 kg (dolor) - ok; FIN. Привет ЩУКА Ψυχή ΑΘΗΝΑ ÆØÅ ß "
         "ŁÓDŹ ĞÜŞİ").split()
# Each of these lost characters before the fix (keycodes 1 and 14).
REGRESSIONS = ["Ñ", "ç x", "abcdefghijklmÑ", "abcdefghijklm x",
               "PACIENTE MASCULINO DE 21 AÑOS EN EL AÑO 2021"]


def cli(*args, ok=True, timeout=60):
    process = subprocess.run([str(BIN), *args], capture_output=True, text=True,
                             timeout=timeout)
    payload = json.loads(process.stdout)
    if ok:
        assert process.returncode == 0 and payload["ok"], (payload, process.stderr)
    return payload


def option(name, default=None):
    if name not in sys.argv:
        return default
    return sys.argv[sys.argv.index(name) + 1]


def fnv(text):
    data = text.encode("utf-16-le")
    value = 0x811C9DC5
    for i in range(0, len(data), 2):
        value ^= data[i] | (data[i + 1] << 8)
        value = (value * 0x01000193) & 0xFFFFFFFF
    return f"KB{len(data) // 2}:{value:x}"


def browser_window(session):
    for window in cli("windows", "--session", session)["data"]:
        if window["title"].startswith("KB"):
            return window
    return None


def entered(session, text):
    """Polls until the textarea holds `text`, bounded; returns success."""
    expected = fnv(text)
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        window = browser_window(session)
        if window and window["title"].startswith(expected + " "):
            return True
        time.sleep(0.2)
    return False


def trial(session, text, backend):
    window = browser_window(session)
    assert window, "test page is not focused in the browser"
    address = window["address"]
    cli("key", "F9", "--window", address, "--session", session)
    assert entered(session, ""), "page did not clear"
    cli("type", "--window", address, "--session", session, "--text", text,
        "--backend", backend)
    return entered(session, text)


def run(session, trials):
    rng = random.Random(1)
    texts = REGRESSIONS + [" ".join(rng.choice(WORDS) for _ in range(40))
                           for _ in range(trials)]
    results = {}
    for backend in ("native", "clipboard"):
        failures = [i for i, text in enumerate(texts) if not trial(session, text, backend)]
        results[backend] = {"texts": len(texts), "failed": failures}
    return results


def start(session, browser, directory):
    page = Path(directory) / "keyboard.html"
    page.write_text(PAGE)
    page.chmod(0o644)
    Path(directory).chmod(0o755)
    cli("enable", "--session", session)
    cli("launch", "--session", session, "--", browser, "--no-first-run",
        "--no-default-browser-check", page.as_uri())
    deadline = time.monotonic() + 30
    while browser_window(session) is None:
        assert time.monotonic() < deadline, "browser window did not appear"
        time.sleep(0.5)


def main():
    if "--live" not in sys.argv:
        print(__doc__)
        sys.exit(2)
    browser = option("--browser") or next(
        (path for path in map(shutil.which, ("brave", "chromium", "google-chrome")) if path),
        None)
    assert browser, "no Chromium-based browser found; pass --browser"
    session = "kb-check-" + uuid.uuid4().hex[:8]
    create = ["session", "create", session]
    create += ["--headless-bridge", option("--headless-bridge")] if option("--headless-bridge") \
        else ([] if "--headless" in sys.argv else ["--nested"])
    cli(*create, timeout=120)
    try:
        with tempfile.TemporaryDirectory(prefix="hyprhand-kb-") as directory:
            start(session, browser, directory)
            results = run(session, int(option("--trials", "20")))
    finally:
        cli("stop", "--session", session, ok=False)
        cli("session", "destroy", session, timeout=120)
    print(json.dumps({"ok": all(not r["failed"] for r in results.values()), **results}))
    assert all(not r["failed"] for r in results.values()), results


if __name__ == "__main__":
    main()
