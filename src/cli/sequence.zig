//! `sequence`: several input steps from one JSON request, run in order by one
//! process. Every step is validated before the first one runs, so a malformed
//! request sends nothing. Steps keep their own guards; the first failing step
//! stops the sequence.
const std = @import("std");
const args = @import("args.zig");
const eq = @import("../core/text.zig").eq;

/// Parses `[["click","--frame","F","--x","1","--y","2"], ["key","Return",...]]`.
/// Each step is a command line without `--session`: the sequence's session is
/// added to every step. `dry_run` adds `--dry-run` to every input step.
pub fn parse(
    allocator: std.mem.Allocator,
    input: []const u8,
    session: []const u8,
    dry_run: bool,
) ![]args.Args {
    const Lines = []const []const []const u8;
    const parsed = std.json.parseFromSlice(Lines, allocator, input, .{}) catch
        return error.InvalidSequence;
    const lines = parsed.value;
    if (lines.len == 0) return error.InvalidSequence;
    if (lines.len > args.sequence_steps_max) return error.InvalidSequence;

    const steps = try allocator.alloc(args.Args, lines.len);
    for (lines, steps) |line, *step| step.* = try parse_step(allocator, line, session, dry_run);
    return steps;
}

fn parse_step(
    allocator: std.mem.Allocator,
    line: []const []const u8,
    session: []const u8,
    dry_run: bool,
) !args.Args {
    if (line.len == 0) return error.InvalidSequenceStep;
    for (line) |argument| {
        // The session is the sequence's; a step cannot name another one.
        if (eq(argument, "--session")) return error.InvalidSequenceStep;
        if (eq(argument, "--")) break;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ line[0], "--session", session });
    const waits = eq(line[0], "wait");
    if (dry_run and !waits) try argv.append(allocator, "--dry-run");
    try argv.appendSlice(allocator, line[1..]);

    const step = args.parse(argv.items) catch return error.InvalidSequenceStep;
    if (!step.mutates() and step.command != .wait) return error.InvalidSequenceStep;
    // --then reports after the whole sequence, never between its steps.
    if (step.then != .none) return error.InvalidSequenceStep;
    return step;
}

test "sequence steps get the session, stay input-only, and fail before running" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const steps = try parse(allocator,
        \\[["click","--frame","f","--x","1","--y","2"],["key","Return","--window","0x1"],
        \\ ["wait","stable"],["launch","--","brave","--session","x"]]
    , "agent", true);
    try std.testing.expectEqual(@as(usize, 4), steps.len);
    try std.testing.expectEqualStrings("agent", steps[0].session);
    try std.testing.expect(steps[0].dry_run and steps[1].dry_run and !steps[2].dry_run);
    try std.testing.expectEqualStrings("--session", steps[3].program[1]);

    const refused = [_][]const u8{
        "[]",
        "{}",
        "[[\"state\"]]",
        "[[\"click\",\"--session\",\"host\",\"--frame\",\"f\",\"--x\",\"1\",\"--y\",\"2\"]]",
        "[[\"key\",\"a\",\"--window\",\"0x1\",\"--then\",\"state\"]]",
        "[[\"sequence\"]]",
        "[[\"key\"]]",
    };
    for (refused) |input| {
        const result = parse(allocator, input, "agent", false);
        if (result) |_| return error.TestUnexpectedResult else |_| {}
    }
}
