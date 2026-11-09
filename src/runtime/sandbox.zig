//! Filesystem and credential isolation for applications of a `--sandbox`
//! managed session. Each launch runs inside bubblewrap:
//!
//! - the root filesystem is mounted read-only;
//! - `/tmp` and the user's runtime directory are empty tmpfs mounts, so the
//!   host's Wayland and D-Bus sockets, ssh-agent, gpg-agent, keyring and audio
//!   sockets are out of reach. Of the session's runtime only the Wayland
//!   socket, the session bus (also the accessibility bus) and dconf come back:
//!   never the compositor's IPC socket, whose `dispatch exec` would escape the
//!   sandbox, nor hyprhand's control token, frames and audit log;
//! - `$HOME` is replaced by the session's private, persistent home;
//! - the session's profile directories are mounted back read-write, and
//!   nothing else of the session directory: hyprhand's control token, frames
//!   and audit log stay invisible to the application;
//! - `--offline` sessions also get an empty network namespace.
//!
//! The compositor, its bus and accessibility registry run outside the sandbox.
const std = @import("std");
const assert = std.debug.assert;

pub const Paths = struct {
    /// The host's runtime directory, hidden behind a tmpfs.
    user_runtime: []const u8,
    /// The session's runtime directory.
    session_runtime: []const u8,
    /// Entries of `session_runtime` the application may use.
    runtime_entries: []const []const u8,
    /// The value of HOME, replaced by `home`.
    host_home: []const u8,
    /// The session's private home, at `<session>/home`.
    home: []const u8,
    /// Session directories the application writes (profiles), mounted back.
    writable: []const []const u8,
    offline: bool,
};

/// Variables that point at host credentials or sockets the sandbox hides.
const hidden_variables = [_][]const u8{
    "SSH_AUTH_SOCK",         "SSH_AGENT_PID",           "GPG_AGENT_INFO",
    "GNOME_KEYRING_CONTROL", "DBUS_SYSTEM_BUS_ADDRESS", "PULSE_SERVER",
    "PIPEWIRE_REMOTE",
};

/// The bubblewrap command line that runs `program` inside the sandbox.
pub fn argv(
    allocator: std.mem.Allocator,
    paths: Paths,
    program: []const []const u8,
) ![]const []const u8 {
    assert(program.len >= 1);
    assert(std.fs.path.isAbsolute(paths.session_runtime));
    assert(std.fs.path.isAbsolute(paths.home));
    var result: std.ArrayList([]const u8) = .empty;
    try result.appendSlice(allocator, &.{
        "bwrap",
        "--ro-bind",
        "/",
        "/",
        "--dev",
        "/dev",
        "--dev-bind-try",
        "/dev/dri",
        "/dev/dri",
        "--proc",
        "/proc",
        "--tmpfs",
        "/tmp",
        "--tmpfs",
        paths.user_runtime,
        "--tmpfs",
        paths.host_home,
        "--bind",
        paths.home,
        paths.host_home,
    });
    for (paths.runtime_entries) |entry| {
        assert(std.mem.indexOfScalar(u8, entry, '/') == null);
        const path = try std.fs.path.join(allocator, &.{ paths.session_runtime, entry });
        try result.appendSlice(allocator, &.{ "--bind-try", path, path });
    }
    for (paths.writable) |directory| {
        try result.appendSlice(allocator, &.{ "--bind-try", directory, directory });
    }
    for (hidden_variables) |name| try result.appendSlice(allocator, &.{ "--unsetenv", name });
    // A new terminal session: the application cannot inject keystrokes into
    // the caller's terminal (TIOCSTI).
    try result.append(allocator, "--new-session");
    if (paths.offline) try result.append(allocator, "--unshare-net");
    try result.append(allocator, "--");
    try result.appendSlice(allocator, program);
    return result.toOwnedSlice(allocator);
}

test "sandbox hides the host runtime and home, mounts back only the session" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const command = try argv(arena.allocator(), .{
        .user_runtime = "/run/user/1000",
        .session_runtime = "/run/user/1000/d12345678",
        .runtime_entries = &.{ "wayland-1", "bus" },
        .host_home = "/home/me",
        .home = "/run/user/1000/hyprhand-sessions/agent/home",
        .writable = &.{"/run/user/1000/hyprhand-sessions/agent/profile-CONFIG"},
        .offline = true,
    }, &.{ "brave", "--incognito" });

    const joined = try std.mem.join(allocator, " ", command);
    defer allocator.free(joined);
    const expected = [_][]const u8{
        "--ro-bind / /",
        "--tmpfs /run/user/1000",
        "--bind-try /run/user/1000/d12345678/wayland-1 /run/user/1000/d12345678/wayland-1",
        "--bind-try /run/user/1000/d12345678/bus /run/user/1000/d12345678/bus",
        "--tmpfs /home/me --bind /run/user/1000/hyprhand-sessions/agent/home /home/me",
        "--bind-try /run/user/1000/hyprhand-sessions/agent/profile-CONFIG",
        "--unsetenv SSH_AUTH_SOCK",
        "--new-session --unshare-net -- brave --incognito",
    };
    for (expected) |part| {
        if (std.mem.indexOf(u8, joined, part) == null) {
            std.debug.print("missing: {s}\nin: {s}\n", .{ part, joined });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, joined, "hyprhand-sessions/agent ") == null);
    // Never the compositor IPC socket or hyprhand's own state.
    try std.testing.expect(std.mem.indexOf(u8, joined, "d12345678/hypr") == null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "d12345678 ") == null);
}
