# hyprhand

<!-- impeccable:product-schema 1 -->

## Platform

Native Linux / Hyprland (not a web or mobile surface).

## Stack

Existing Zig 0.16 CLI. Optional native GTK4 preview helper; no MCP server.

## Users and purpose

The desktop owner delegates application work to an agent while continuing their
own work. Managed compositor sessions isolate mouse and keyboard input, not
files or credentials. The owner needs to see background activity without
entering that session.

## Confirmed preview workflow

A live, read-only Picture-in-Picture on the host, movable and resizable. Show the
managed session and its cursor. A stop control disables hyprhand input without
closing the applications. Closing the viewer does not stop the agent. Never
forward pointer or keyboard input from the viewer to the source session.

## Constraints

Explicit session selection; no silent host fallback. Existing stop/enable
authorization remains authoritative. Signal loss must not look like live video.
Preview remains an optional dependency, not a requirement for CLI automation.

## Owner's PiP design preference

Borderless image-first window, with controls integrated over the image instead
of separate title and footer bars. Preserve the established read-only, close
and stop semantics, movement and resizing.

Controls, session identity and status appear on pointer hover or active keyboard
navigation. At rest, show only the session image.
