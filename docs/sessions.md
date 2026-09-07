# Managed sessions

A managed session is a child Hyprland compositor with its own applications,
cursor, keyboard focus, IPC socket, Wayland socket, D-Bus, and XDG profiles.
The `host` session is your existing desktop. Run commands from the original
owner's Hyprland environment and let `--session NAME` perform routing.

## Choosing a mode

| Mode | Command | Behavior |
| --- | --- | --- |
| Existing desktop | `deskctl state --session host` | Shares your current cursor, focus, and applications |
| Nested | `deskctl session create agent --nested` | Creates a child compositor with a visible parent window |
| Headless | `deskctl session create agent` | Creates a child output without a nested preview window; requires compatible GPU buffers |
| Lua configuration | Add `--lua` to `session create` | Generates a Lua configuration instead of Hyprlang |

Another workspace in `host` shares the compositor's input seat. It is not a
replacement for a managed session. Opening or closing a nested window can affect
host focus even though input within the child compositor is isolated.

Headless mode still obtains its renderer through the parent Wayland compositor;
it cannot boot a standalone desktop without a graphical session. On the recorded
NVIDIA/Hyprland 0.56.2/Aquamarine 0.15.0 stack, an explicit
[experimental headless bridge](experimental-bridges.md) is necessary. Startup
failure stops the failed child; there is no fallback to host input.

## Lifecycle

```sh
deskctl session create agent --nested
deskctl sessions
deskctl session inspect agent
deskctl doctor --session agent
deskctl enable --session agent
deskctl launch --session agent -- firefox about:blank
deskctl windows --session agent
```

Session names have at most 32 characters, start with a letter, and contain ASCII
letters, digits, hyphens, or underscores. `host` cannot be created or destroyed.
`session inspect` returns the recorded runtime, compositor identity, process
identities, and optional bridge. Use that output for diagnosis rather than
assuming socket names or fixed paths.

`launch` requires enabled control, an explicit managed session, and a program
after `--`. Arguments are passed directly. Use `--dry-run` before `--` to validate
without launching. Discover the launched window through `windows` or `wait window`;
a PID alone does not establish that an application opened in the correct session.

```sh
deskctl wait window --session agent --class firefox
deskctl focus WINDOW_ADDRESS --session agent
deskctl wait focus --session agent --window WINDOW_ADDRESS
deskctl observe --session agent
```

Replace `WINDOW_ADDRESS` with the returned address. Application classes can vary;
choose the class observed in your actual session.

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
  Wayland flags. Firefox gets a private profile and `--no-remote`; profile
  overrides are rejected. Generic applications may still reuse another process;
  verify the actual window and PID.
- The private bus does not activate host systemd user services or portals.
  Desktop integration and portal-based file pickers may not work.
- An explicitly selected headless library is preloaded only into the newly
  created compositor, not deskctl's bus, registry, or launched applications.

**This is not a security sandbox.** Files, credentials, network, user permissions,
and potentially other services remain accessible. Do not treat managed sessions
as containment for untrusted applications or content. See [SECURITY.md](../SECURITY.md).

## Stop, preview, and destroy

```sh
deskctl preview --session agent --fps 5
deskctl stop --session agent
deskctl session destroy agent
```

Preview is read-only and requires the optional GTK executable. Its **Stop input**
button revokes the source session's deskctl permission. Closing it leaves source
applications and authorization unchanged. See [preview](preview.md).

`stop` leaves applications open; `destroy` closes the tracked compositor, launched
applications, AT-SPI registry, bus, and descendants still attributable to them.
Launch and destruction share a lifecycle lock. Cleanup validates UID, PID, and
start time using pidfd and applies bounded TERM/KILL handling. It does not kill
by username or blindly by process group. Descendants that detach and can no
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
