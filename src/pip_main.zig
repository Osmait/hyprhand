//! Separate module root keeps GTK out of the hyprhand executable.
pub const main = @import("preview/viewer.zig").main;
