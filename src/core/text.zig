const std = @import("std");

/// Byte-exact string comparison, shared by every module instead of a local copy.
pub fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// True when `value` equals one of `candidates`.
pub fn oneOf(value: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| if (eq(value, candidate)) return true;
    return false;
}
