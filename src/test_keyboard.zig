//! Standalone keyboard suite rooted at src/ for explicit sibling imports.
test {
    @import("std").testing.refAllDecls(@import("input/keyboard.zig"));
}
