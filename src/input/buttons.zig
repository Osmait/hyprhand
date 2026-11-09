//! Button codes shared by the CLI parser and the input backends. Kept free of
//! C imports so the argument parser stays independent from Wayland headers.
const text = @import("../core/text.zig");

/// Linux input event codes (BTN_LEFT, BTN_RIGHT, BTN_MIDDLE).
pub const left: u32 = 0x110;
pub const right: u32 = 0x111;
pub const middle: u32 = 0x112;
/// The thumb buttons (BTN_SIDE, BTN_EXTRA). Browsers and file managers treat
/// them as history back and forward, as they do for a physical mouse.
pub const back: u32 = 0x113;
pub const forward: u32 = 0x114;

pub fn from_name(name: []const u8) ?u32 {
    if (text.eq(name, "left")) return left;
    if (text.eq(name, "right")) return right;
    if (text.eq(name, "middle")) return middle;
    if (text.eq(name, "back")) return back;
    if (text.eq(name, "forward")) return forward;
    return null;
}

/// X11 core protocol wheel buttons used by xdotool.
pub const x11 = struct {
    pub const wheel_up: u8 = 4;
    pub const wheel_down: u8 = 5;
    pub const wheel_left: u8 = 6;
    pub const wheel_right: u8 = 7;
};
