//! Separate module root keeps GTK out of the deskctl executable.
pub const main = @import("preview/viewer.zig").main;
