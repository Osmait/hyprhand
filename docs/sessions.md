# Managed sessions

A managed session is a child Hyprland compositor with its own applications,
cursor, keyboard focus, IPC socket, Wayland socket, D-Bus, and XDG profiles.
The `host` session is your existing desktop. Run commands from the original
owner's Hyprland environment and let `--session NAME` perform routing.

## Choosing a mode

| Mode | Command | Behavior |
| --- | --- | --- |
| Existing desktop | `hyprhand state --session host` | Shares your current cursor, focus, and applications |
| Nested | `hyprhand session create agent --nested` | Creates a child compositor with a visible parent window |
| Headless | `hyprhand session create agent` | Creates a child output without a nested preview window; requires compatible GPU buffers |
| Lua configuration | Automatic when the host uses Lua (Hyprland 0.57+); `--lua` forces it | Generates a Lua configuration instead of Hyprlang |

Another workspace in `host` shares the compositor's input seat. It is not a
replacement for a managed session. Opening or closing a nested window can affect
host focus even though input within the child compositor is isolated.

For long or unattended tasks prefer headless mode (with the bridge where your
stack needs it): its output has a fixed 1920x1080 size and does not depend on a
window the user can hide, resize or close. See [nested windows](#nested-windows).

Headless mode still obtains its renderer through the parent Wayland compositor;
it cannot boot a standalone desktop without a graphical session. On the recorded
NVIDIA/Hyprland 0.56.2/Aquamarine 0.15.0 stack, an explicit
[experimental headless bridge](experimental-bridges.md) is necessary. Startup
failure stops the failed child; there is no fallback to host input.

## Lifecycle

```sh
hyprhand session create agent --nested
hyprhand sessions
hyprhand session inspect agent
hyprhand doctor --session agent
hyprhand enable --session agent
hyprhand launch --session agent -- firefox about:blank
hyprhand windows --session agent
```

Session names have at most 32 characters, start with a letter, and contain ASCII
letters, digits, hyphens, or underscores. `host` cannot be created or destroyed.
`session inspect` returns the recorded runtime, compositor identity, process
identities, and optional bridge. Use that output for diagnosis rather than
assuming socket names or fixed paths.

`launch` counts as input: it requires enabled control (`ControlStopped` until
`enable`), an explicit managed session, and a program
after `--`. Arguments are passed directly. Use `--dry-run` before `--` to validate
without launching. Discover the launched window through `windows` or `wait window`;
a PID alone does not establish that an application opened in the correct session.

```sh
hyprhand wait window --session agent --class firefox
hyprhand focus WINDOW_ADDRESS --session agent
hyprhand wait focus --session agent --window WINDOW_ADDRESS
hyprhand observe --session agent
```

Replace `WINDOW_ADDRESS` with the returned address. Application classes can vary;
choose the class observed in your actual session.

### Liveness

`sessions` and `session inspect` report `running` and a `health` value:

| `health` | `running` | Meaning |
| --- | --- | --- |
| `running` | `true` | Compositor and bus alive; a nested session still has its host window |
| `unresponsive` | `true` | Processes alive, but the nested compositor did not answer IPC within 1 s |
| `window_closed` | `false` | Nested only: the host window was closed. Hyprland keeps running on a zero-size fallback output |
| `exited` | `false` | The compositor or its bus exited (crash, kill, logout) |
| `destroyed` | `false` | `session destroy` already ran |

Commands routed to a `window_closed` session fail with `NestedWindowClosed`, and
to an `exited` or `destroyed` one with `SessionNotRunning`. `session create` with
the name of a session that died on its own fails with `SessionDead` rather than
`SessionExists`: its bus, registry and applications may still run, and only
`session destroy NAME` stops them. Run it once, then create the session again.

### Nested windows

A nested compositor draws into an ordinary window on the host, and the host
controls that window:

- **Visibility.** Hyprland sends no frame callbacks to a window on a workspace
  that no monitor shows. The nested compositor then renders nothing, its
  applications stop painting, and `observe` would wait for a frame forever.
  `observe` checks the host first and fails at once with `NestedWindowHidden`;
  `wait stable --pixels` and other timeouts in a nested session report the same
  code when the window turns out to be hidden. Keyboard input is still delivered
  while hidden; only rendering and capture stop. Keep the window on a visible
  workspace (or a shown special workspace). hyprhand never moves it: ask the user.
- **Size.** The nested output follows the window's size. Tiling changes, floating
  or resizing it change the monitor geometry (for example 945x1022 to 1280x960),
  and every frame taken before is rejected with `StaleObservation`. Observe again
  after any layout change on the host.
- **Closing.** Closing the window does not stop the nested compositor; see
  [liveness](#liveness).

## Environment and isolation

- Generated configurations are independent of your personal Hyprland config.
  Physical-seat acquisition is prevented using an invalid libseat backend.
- Each session uses private runtime/socket paths and a private D-Bus daemon.
  An available AT-SPI registry is started for that bus.
- XDG config, data, cache, and state directories are session-local. `HOME`
  remains your normal home directory.
- Managed sessions disable XWayland and remove the host `DISPLAY`.
  GTK/Qt/browser settings route supported apps to Wayland.
- Recognized Chromium-family launches use a private user-data directory and
  Wayland flags, and get `ACCESSIBILITY_ENABLED=1` so `accessibility` can read
  web content (Chromium otherwise exposes an empty tree). A second launch reuses
  the running browser and its environment. Firefox gets a private profile and `--no-remote`; profile
  overrides are rejected. Generic applications may still reuse another process;
  verify the actual window and PID.
- The private bus does not activate host systemd user services or portals.
  Desktop integration and portal-based file pickers may not work. See
  [saving files](#saving-files).
- An explicitly selected headless library is preloaded only into the newly
  created compositor, not hyprhand's bus, registry, or launched applications.

### Saving files

Without an `xdg-desktop-portal` on the session bus, Chromium-family browsers fall
back to their in-process GTK 3 file chooser. It opens as a separate window in the
session (often floating over the browser), starting in `~/Downloads`: `HOME` is
shared with your desktop. The session's private `XDG_CONFIG_HOME` has no
`user-dirs.dirs`, so a localized download folder of the desktop is not used.

To save to a chosen place, focus the chooser window, select the **Name** field
(`ctrl+a`), type an absolute path such as `/tmp/agent-output/report.csv`, and click
**Save** in a fresh frame. On the recorded Brave/GTK 3.24 stack, Enter in that
field did not confirm the dialog through either keyboard backend; Escape cancels
it. Then verify the file on disk: `status: sent` never proves a download finished.
Earlier builds sent a `key Return` on the Escape key position, which this chooser
treated as Cancel: the download was recorded as cancelled and no file appeared.

**This is not a security sandbox.** Files, credentials, network, user permissions,
and potentially other services remain accessible. Do not treat managed sessions
as containment for untrusted applications or content. See [SECURITY.md](../SECURITY.md).

## Stop, preview, and destroy

```sh
hyprhand preview --session agent --fps 5
hyprhand stop --session agent
hyprhand session destroy agent
```

Preview requires the optional GTK executable. Its **Stop input** button revokes
the source session's hyprhand permission. **Take over** lets the owner use the
session with their own mouse and keyboard (for sign-ins and captchas) while agent
input is stopped; `state` reports `human_takeover`, and **Return** restores control
as it was. Closing it leaves source applications and authorization unchanged,
except that closing during a takeover leaves agent input stopped.
See [preview](preview.md).

`stop` leaves applications open; `destroy` closes the tracked compositor, launched
applications, AT-SPI registry, bus, and descendants still attributable to them.
Launch and destruction share a lifecycle lock. Cleanup validates UID, PID, and
start time using pidfd and applies bounded TERM/KILL handling. It does not kill
by username or blindly by process group. `destroy` also succeeds when the
compositor is already gone, and a process that cannot be frozen in time (stuck in
a driver, or held by a crash reporter's ptrace stop) no longer aborts it; such a
process is still terminated with the rest of the tree. Descendants that detach and can no
longer be attributed after their recorded parent exits cannot safely be reclaimed.

Profiles and logs remain at the path reported by `profiles_and_logs_retained`,
normally under the Linux runtime directory until logout. User documents are not
removed. Frame `gc` does not erase these profiles. Inspect retained data before
sharing it or manually removing it.

## Known limitations

Creating a session from an already managed runtime can exceed Hyprland's Unix
socket path length and currently fail with a generic startup timeout. Use the
original host environment. Managed XWayland startup, arbitrary GPU support, and
complete application compatibility remain unverified. Recreating the same session
name changes its identity; reopen any existing preview explicitly.
