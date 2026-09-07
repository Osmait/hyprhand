# Testing and verification

Run commands from the repository root with Zig 0.16.0, the native build
dependencies, and Python 3.11+. Offline tests use private sockets/process fixtures;
application and GPU verification requires separate live runs.

## Default offline checks

```sh
zig build check -Doptimize=ReleaseSafe
zig build test
python3 tests/keyboard_unit.py
```

`check` builds the CLI, checks Zig formatting, runs Zig unit tests, then invokes
`scripts/check.py`. That runner removes inherited desktop/display/bus variables
and executes:

| Suite | Scope |
| --- | --- |
| `tests/integration.py` | Strict CLI, frames, routing, control, helper behavior, events, logs, GC |
| `tests/ipc.py` | Fragmented/trickled IPC, deadlines and signal cancellation |
| `tests/keyboard_protocol.py` | Fake Wayland keyboard messages, modifiers, Unicode, cancellation and flush backpressure |
| `tests/session_lifecycle.py` | Recorded process identities, routing, launch/destroy and cleanup |
| `tests/preview.py` | Fake capture workers, source identity, stop, bounds, cancellation and rule cleanup |
| `tests/fixtures/test_reliability_contract.py` | Mocked live-runner consent, receiver evidence, token lifecycle and terminal guards |
| `packaging/test_release.py` | Archives, checksums, manifests, documentation payload and Blender output preflight |

The separate keyboard unit runner builds an isolated root with no Wayland
connection. Its tests overlap those in the full Zig test root; do not add both
counts as independent coverage.

For an individual suite after building:

```sh
zig build -Doptimize=ReleaseSafe
python3 tests/integration.py
python3 tests/ipc.py
python3 tests/keyboard_protocol.py
python3 tests/session_lifecycle.py
python3 tests/preview.py
python3 tests/fixtures/test_reliability_contract.py
python3 -m unittest discover -s packaging -p 'test_*.py' -v
```

Runners normally use `zig-out/bin/hyprhand`; supported suites honor
`HYPRHAND_TEST_BIN` for a different build. Avoid pointing an offline fixture at a
wrapper that routes to a real desktop.

## Optional GTK checks without a host window

```sh
zig build pip pip-test -Doptimize=ReleaseSafe
python3 tests/viewer_broadway.py
```

The optional viewer is built independently and checks its C ABI declarations
against installed GTK4 headers. The Broadway runner uses private Unix sockets,
a synthetic PNG, and real GTK callbacks. It exercises texture reuse, signal
loss/recovery and shutdown during capture. It does not require a browser or open
a host window, and it cannot establish physical Wayland presentation or GPU behavior.

## Syntax and formatting

```sh
zig fmt --check build.zig build src
python3 -m py_compile tests/*.py tests/fixtures/*.py scripts/*.py \
  packaging/*.py examples/blender/style_room.py examples/gtk/note.py
bash -n completions/hyprhand.bash
sh -n experimental/cursor-outline/build.sh
sh -n experimental/headless-formats/build.sh
python3 scripts/check_docs.py
```

`check_docs.py` validates local Markdown file links and confirms that distributed
documentation links remain resolvable in the explicitly selected package payload.
Source-only links use repository URLs or are presented as source paths.

## Live tests: explicit operator action

Live runners create temporary windows and send real input. Use a disposable
managed session, read the runner's instructions, and authorize the specific test.
They are excluded from `zig build check`, normal CI, and package creation.
Some older runners default to `host`; set `HYPRHAND_TEST_SESSION` deliberately.

```sh
hyprhand session create test-session --nested
HYPRHAND_TEST_SESSION=test-session python3 tests/live_smoke.py --live
HYPRHAND_TEST_SESSION=test-session python3 tests/live_advanced.py --live
HYPRHAND_TEST_SESSION=test-session python3 tests/live_motion.py --live
# Review the aura visually as well:
HYPRHAND_TEST_SESSION=test-session python3 tests/live_motion.py --live --aura-review
hyprhand stop --session test-session
hyprhand session destroy test-session
```

Motion tests require inspecting the newly printed screenshot and confirming it
interactively. Do not pipe approval. A human stop ends the run; later control
requires new authorization. Existing fixtures can have their own enable/cleanup
behavior, so inspect them before use.

Session lifecycle tests create and destroy their own managed sessions:

```sh
python3 tests/live_sessions.py --live
python3 tests/live_sessions.py --live --lua
python3 tests/live_sessions.py --live --headless
```

Headless tests require compatible buffers or an explicitly selected trusted bridge
as described in [experimental bridges](experimental-bridges.md). XWayland smoke
coverage uses `tests/live_smoke.py --live --x11` in a separately authorized X11
setup; current managed sessions disable XWayland, so this is not part of the
managed example above.

The stricter `tests/live_reliability.py` requires an already running managed
observer, explicit `--session`, and an event file. It never enables input or
creates GUI applications. Follow the complete [observer guide](../tests/fixtures/README.md).
Its pointer matrix requires fresh screenshot review before each action and
verifies application-received events. The [hidden-workspace probe](archive/background-probe.md)
is a separate host-affecting investigation, not an isolated automation backend.

## Benchmarks

```sh
python3 scripts/benchmark_offline.py --samples 5
python3 scripts/benchmark_viewer_offline.py --seconds 300
# Opt-in host viewer, existing managed source; never enables input:
python3 scripts/benchmark_preview.py --live --session agent --seconds 120 --fps 5
```

Offline timings include Python fixture overhead. Broadway software measurements
cannot be compared directly with physical Hyprland/NVIDIA runs. Requested fps,
capture responses, texture updates, GTK paints and confirmed presentation are
separate metrics. See [performance evidence](archive/performance-2026-09.md).

## CI and release validation

The workflows configure Ubuntu 22.04/24.04 x86_64, pinned Zig 0.16.0, and Python
3.12. GTK build/ABI/Broadway checks run on Ubuntu 24.04. All default jobs are
offline. Read the result for the exact commit; workflow files or past successful
runs do not prove a new change passed remotely.

Record commands, versions, outcomes, and limitations in a PR. Preserve useful
regressions without substituting test counts for correctness. For publication, follow the
[release checklist](releasing.md).
