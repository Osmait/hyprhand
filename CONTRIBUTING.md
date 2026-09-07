# Contributing to hyprhand

Thanks for helping improve local desktop automation. Issues, reproducible bug
reports, documentation fixes, and focused pull requests are welcome. Use English
for public documentation, comments, help, interface text, and discussion so that
contributors can work from the same reference.

## Set up a checkout

Install the [build dependencies](docs/dependencies.md), use Zig 0.16.0 from
`.zigversion`, and use Python 3.11 or newer. The default checks need no running
Hyprland desktop.

```sh
git clone https://github.com/Osmait/hyprhand.git
cd hyprhand
git switch -c your-change
zig build -Doptimize=ReleaseSafe
zig build check -Doptimize=ReleaseSafe
```

The public API is the command-line and JSON contract. Internal modules can be
reorganized without changing command names, installed paths, or frame semantics.
Read the [architecture](docs/architecture.md) and [testing guide](docs/testing.md)
before changing input or lifecycle behavior.

## Report a bug or propose a feature

For bugs, include the source commit/version, Zig version, distribution, Hyprland
and Aquamarine versions, configuration provider, session type, steps to reproduce,
expected behavior, actual behavior, and a minimal redacted JSON error. Say whether
a failure occurred on Wayland or XWayland and whether an experimental bridge was
loaded. Remove credentials, application content, personal paths and window titles
from reports. Use [SECURITY.md](SECURITY.md) for suspected vulnerabilities.

For a feature, describe the workflow it enables, the existing limitation, and
how the result can be verified. For changes to input, session routing, dependencies,
or protocol contracts, discuss the approach in an issue before a large rewrite.

## Implement and verify

- Reproduce a behavior bug before fixing it and retain a meaningful regression.
  Cover errors, cancellation, limits, and resource release when applicable.
- Validate external data before arithmetic or conversion. Return JSON errors;
  do not use `assert` or `unreachable` for compositor, file, or CLI input.
- Use assertions for demonstrable internal invariants, not style quotas.
- Bound total time, IPC size, buffers, and repeated work. A timeout per read is
  not an end-to-end deadline.
- Make descriptor, process, and buffer ownership clear. Use `defer`/`errdefer`
  and per-iteration arenas for temporary queries in loops.
- Use `platform/child_process.zig` only for direct, unreaped child processes.
  `runtime/sessions.zig` separately validates PID/start-time/UID/pidfd identities
  for process trees. Neither mechanism accepts arbitrary process IDs.
- Preserve cancellation, focus, token, and frame checks. An error never enables
  input, switches to the host, or authorizes repeating an action with side effects.
- Keep functions focused and modules organized by domain. Avoid generic `utils`
  folders and forwarding-only layers.
- Run `zig fmt build.zig build src`; preserve existing snake_case file names.
  Keep mechanical changes separate from behavior changes where possible.
- Never log typed text, credentials, application content, or window titles.
  Unicode samples in tests are intentional and should retain Unicode coverage.

Run the offline checks and, for viewer changes, the optional GTK checks:

```sh
zig build check -Doptimize=ReleaseSafe
zig build test
python3 tests/keyboard_unit.py
zig build pip pip-test -Doptimize=ReleaseSafe
python3 tests/viewer_broadway.py
```

`check` never opens host windows or injects desktop input. Live tests and probes
need an explicitly chosen disposable session and operator consent; they are not
part of normal CI. Record what you actually ran and distinguish simulated
protocol evidence from application-observed results.

## Submit a pull request

Explain the problem, resulting behavior, relevant tradeoffs, and validation.
Include a minimal before/after example when useful. Update affected documentation,
CLI help, completions, and packaging manifests when the public surface changes.
Do not claim desktop, GPU, or remote CI verification from an offline build alone.
Keep secrets, local profiles, generated binaries, screenshots of private content,
and runtime logs out of patches.

Existing demonstration assets are retained. New renders, videos, editable exports,
and benchmark output belong in ignored `output/`. Avoid adding dependencies or
changing the license without an explicit project need and maintainer agreement.
Treat other contributors respectfully; discuss the code and provide actionable
feedback.
