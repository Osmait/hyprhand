# Architecture and source organization

The public interface is a command-line/JSON contract. The implementation is a
small native Zig program with system-library bindings, a separate optional GTK
executable, and two explicitly built experimental C++ compositor libraries.

## Source map

```text
build.zig                artifacts and public build steps
build/                   native dependencies and optional artifacts
src/
  main.zig               entry point, command routing, JSON errors
  pip_main.zig           independent GTK executable root
  test_keyboard.zig      isolated keyboard test root
  cli/                   strict argument parsing and help
  core/                  geometry and frame contract, no native dependencies
  platform/              Linux/Wayland FFI, signals, clock, IPC, child cleanup
  runtime/               session routing, control, guards, waits, audit, events, GC
  input/                 action coordination, keyboard, pointer, motion, scroll, aura
  capture/               observation, layout revision, cursor capture
  accessibility/         AT-SPI traversal and narrow C bridge
  preview/               controller, bounded transport, cadence, protocol, GTK, C ABI
tests/                   offline and opt-in live runners
protocols/               vendored Wayland XML; C/headers generated in build cache
scripts/                 checks, benchmarks, local packaging and verification
experimental/            opt-in compositor bridges, never automatically loaded
docs/                    guides, contracts, compatibility and historical evidence
```

## Command lifecycle

1. `main` installs signal handlers and parses arguments. Help/version do not
   initialize a desktop runtime. Argument failures exit 2 with a JSON error.
2. `Runtime.init` reads the owner environment. Session routing resolves the
   selected compositor and redirects IPC, Wayland, D-Bus and XDG profiles.
3. Read commands query compositor state or call bounded workers. Mutating
   commands record a redacted audit entry and enter action coordination.
4. Input acquires its action lock and validates authorization, display identity,
   screen lock, focus, and, for pointer input, a stored frame and cursor position.
5. Cursor movement uses guarded Hyprland dispatch; native Wayland devices send
   keyboard, button and scroll events, with explicit helper paths where selected.
   Guards run during the
   operation; owned input and child processes are cleaned up before return.
6. The command emits JSON success or error. Success indicates delivery/command
   completion, not verification of the target application's outcome.

`input/actions.zig` coordinates input and `runtime/wait.zig` implements waiting.
Motion/scroll algorithms receive a driver, enabling tests without a compositor.
Geometry and preview protocol modules validate data without creating windows or
devices. Runtime code owns authority and lifecycle; platform code implements
lower-level operations without interpreting command names.

## Observation and frame revisions

`capture/observation.zig` reads monitors, clients, active window and layers,
selects the output, captures with `grim`, and re-reads relevant state. A changed
revision rejects the capture. Valid frames save PNG dimensions and a logical
rectangle along with session identity, timestamps, and a revision hash.

Revision schema v2 scopes windows/layers to the captured output, includes crossing
windows, and preserves global focus and monitor geometry/workspaces. During input,
only the current process's PID-owned aura is excluded. A matching namespace alone
never excludes an arbitrary overlay. See the [coordinate contract](cli.md).

## Time and memory budgets

`native.limitCommand` sets a shared monotonic deadline. Repeated IPC requests do
not renew it. Ordinary reads have 10 s, actions 30 s, `type` 300 s, and waits their
requested timeout. Sessions, events, accessibility, and persistent viewers have
specialized limits. Input release and direct-child cleanup retain independent
budgets so cancellation does not skip them. These are cooperative bounds, not
protection against kernel or native-library stalls.

IPC uses nonblocking sockets with a shared connect/send/read budget and short
cancelable polls. Wayland reads use prepare/read/cancel with writable polling for
flush `EAGAIN`, avoiding blocking dispatch after a read-ready notification.
Guards reuse temporary arenas with at most 256 KiB retention. Authorization is
not cached across characters; only an immediately preceding full text guard can
be reused by its synchronization step.

JSON serialization uses a fixed output buffer. Events bound each record, not the
entire received chunk. Automatic frame GC scans at most every 30 s; explicit
`gc` always scans. Audit appends recover incomplete tails when the filesystem
allows it, and `logs` reports `incomplete_tail` while retaining complete records.

## Control authority and cleanup

`stop` and authorization publication share a short `control.lock`, distinct from
the action lock. `enable` creates a stop generation before querying the compositor.
`stop` removes the generation and token under the lock, invalidating any older
in-flight enable. No compositor IPC occurs while holding the publication lock.
Revocation needs no new journal write and attempts remaining markers even if one
removal fails. Filesystem removal failures can still prevent revocation.

`platform/child_process.zig` handles direct, unreaped children with TERM, bounded
grace, KILL, and reaping. It cannot safely operate on arbitrary PIDs.
`runtime/sessions.zig` separately records and validates PID/start time/UID/pidfd
for compositor/application trees and serializes launch/destruction. Deliberately
detached descendants may no longer be attributable. See [sessions](sessions.md).

## Preview boundary

The GTK viewer has its own executable and module root; it does not link input or
session management. A persistent CLI capture worker routes from the original
owner environment on each request and pins the source compositor identity.
A separate stop worker can revoke control independently of capture.

The internal stream wraps DCP1 frames with a length prefix. Output is bounded
before allocation and decoded off the GTK thread by `transport.zig`.
`cadence.zig` allows one request at a time and reduces static-image capture to
1 fps. Image freshness, lock state and session identity are checked independently
of image equality. GTK is never a dependency of the default CLI build.
See [preview](preview.md) for the complete transport and UI contract.

## Design influences

The repository's earlier architecture review used Ghostty's separation of build
assembly and platform/UI runtimes, and TigerBeetle's TigerStyle emphasis on explicit
bounds, invariants, and invalid-input tests as design references. No code from
those projects is imported by that reorganization. This project does not claim
their robustness or adopt a general prohibition on dynamic allocation: bounded
arenas remain appropriate here, and the module graph is not strictly layered.
