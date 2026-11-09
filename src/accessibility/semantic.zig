//! `act VERB --ref REF`: semantic accessibility actions. The parent checks
//! control, the ref and its snapshot; a disposable worker resolves the
//! element again, tries the verb's calls in order, and reads the result back.
//! Nothing here moves the pointer or synthesizes keys: when no semantic call
//! fits, the action fails and the agent decides whether to use the pointer.
const std = @import("std");
const assert = std.debug.assert;
const eq = @import("../core/text.zig").eq;
const native = @import("../platform/native.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const Args = @import("../cli/args.zig").Args;
const delivery = @import("../runtime/delivery.zig");
const atspi = @import("atspi.zig");
const refs = @import("refs.zig");
const tree = @import("tree.zig");
const auth_guard = @import("../runtime/auth_guard.zig");
const c = atspi.c;

pub const Verb = @import("../cli/args.zig").ActVerb;

/// Everything the worker needs, passed on stdin so text never reaches argv.
const Request = struct {
    verb: Verb,
    window: []const u8,
    pid: u32,
    entry: refs.Entry,
    text: ?[]const u8 = null,
    dry_run: bool = false,
};

/// One semantic call the worker made, in order.
const Step = struct {
    call: []const u8,
    result: []const u8,
    detail: ?[]const u8 = null,
};

/// The worker's report of a completed action.
const Outcome = struct {
    ok: bool = true,
    verb: Verb,
    resolved_by: []const u8,
    role: []const u8,
    name: ?[]const u8,
    delivery: delivery.Delivery,
    verified: bool,
    /// The element already had the requested state; nothing was sent.
    satisfied: bool = false,
    /// Read back after the action: text, range value or state.
    value: ?[]const u8 = null,
    steps: []const Step,
    /// Dry runs: the element's action names, without acting.
    actions: ?[]const []const u8 = null,
    /// Dry runs: the AT-SPI interfaces the element offers.
    interfaces: ?[]const []const u8 = null,
};

/// Per-call D-Bus deadline in the worker; slower replies count as uncertain.
const call_timeout_ms = 1500;
/// The worker's whole budget, enforced by the parent.
const worker_budget_ms = 15_000;

// ---------------------------------------------------------------- parent ---

pub fn run(runtime: *Runtime, arguments: Args) !void {
    const ref_text = arguments.ref.?;
    const ref = try refs.Ref.parse(ref_text);
    const verb = arguments.act_verb.?;
    const snapshot = try tree.load_snapshot(runtime, ref);
    const entry = snapshot.entry(ref.index) orelse return error.StaleRef;
    // act reaches windows that are not focused: check the target itself.
    const client = try tree.find_client(runtime, snapshot.window);
    if (auth_guard.prompt_class(client.class)) return runtime.prompt_error(client.class);
    try check_request(verb, entry, arguments);

    const request = Request{
        .verb = verb,
        .window = snapshot.window,
        .pid = snapshot.pid,
        .entry = entry,
        .text = arguments.text,
        .dry_run = arguments.dry_run,
    };
    const input = try std.json.Stringify.valueAlloc(runtime.allocator, request, .{});
    // Fail before the worker starts while nothing can have been sent.
    if (!arguments.dry_run) try runtime.guard();
    const captured = runtime.run_capture(
        &.{ "/proc/self/exe", "_a11y_act" },
        input,
        !arguments.dry_run,
        worker_budget_ms,
    ) catch |err| return worker_lost(err);
    if (!captured.succeeded) return worker_failure(runtime, captured.stdout);

    const outcome = try runtime.parse_json(Outcome, captured.stdout);
    delivery.set(outcome.delivery);
    try runtime.emit(.{
        .ok = true,
        .action = "act",
        .session_id = runtime.session_id,
        .dry_run = arguments.dry_run,
        .ref = ref_text,
        .verb = outcome.verb,
        .disposition = delivery.disposition(),
        .verified = outcome.verified,
        .satisfied = outcome.satisfied,
        .resolved_by = outcome.resolved_by,
        .role = outcome.role,
        .name = outcome.name,
        .value = outcome.value,
        .actions = outcome.actions,
        .interfaces = outcome.interfaces,
        .steps = outcome.steps,
    });
}

/// Refusals that need no worker: nothing is sent.
fn check_request(verb: Verb, entry: refs.Entry, arguments: Args) !void {
    if (entry.twins > 1) return error.AmbiguousTarget;
    if (verb == .@"set-value") {
        if (entry.protected) return error.ProtectedField;
        if (arguments.text == null) return error.MissingText;
    } else if (arguments.text != null) {
        return error.UnexpectedText;
    }
}

/// A worker killed by the deadline or a stop may have been inside a call.
fn worker_lost(err: anyerror) anyerror {
    switch (err) {
        error.HelperTimeout => {
            delivery.mark_sent();
            return error.AccessibilityTimeout;
        },
        error.ControlStopped, error.Cancelled => {
            delivery.mark_sent();
            return err;
        },
        else => return err,
    }
}

const passed_errors = [_]anyerror{
    error.StaleRef,                    error.AmbiguousTarget,
    error.ActionNotSupported,          error.ActionRefused,
    error.ProtectedField,              error.WriteIgnored,
    error.ValueMismatch,               error.IndeterminateState,
    error.AccessibilityTimeout,        error.AccessibilityUnavailable,
    error.AccessibilityWindowNotFound, error.AccessibilityWindowAmbiguous,
    error.WindowNotFound,              error.InvalidValue,
};

/// The worker's error and disposition, passed on unchanged.
fn worker_failure(runtime: *Runtime, stdout: []const u8) anyerror {
    const Failure = struct {
        err: struct { code: []const u8, detail: ?[]const u8 = null },
        disposition: struct { delivery: delivery.Delivery },
    };
    const failure = runtime.parse_json(Failure, stdout) catch {
        // A crash may have happened inside a call.
        delivery.mark_sent();
        return error.AccessibilityUnavailable;
    };
    delivery.set(failure.disposition.delivery);
    delivery.set_detail(failure.err.detail);
    for (passed_errors) |err| {
        if (eq(failure.err.code, @errorName(err))) return err;
    }
    return error.AccessibilityUnavailable;
}

// ---------------------------------------------------------------- worker ---

/// The element an action works on, resolved again in this process.
const Target = struct {
    node: atspi.Node,
    details: atspi.Info,
    /// The identity's name: for an unnamed row, its child's text.
    name: ?[]const u8,
    actions: []const []const u8,
    /// Qt counts inserted text in UTF-16 units; everyone else in bytes.
    utf16_lengths: bool,
    resolved_by: []const u8,
};

pub fn worker(runtime: *Runtime) !void {
    const input = try read_stdin(runtime.allocator, 1024 * 1024);
    const request = try runtime.parse_json(Request, input);
    try runtime.validate_display();
    try runtime.unlocked();
    if (c.desk_a11y_init_timeout(call_timeout_ms) != 0) return error.AccessibilityUnavailable;
    defer c.desk_a11y_exit();
    const desktop = c.desk_a11y_desktop() orelse return error.AccessibilityUnavailable;
    defer c.desk_a11y_unref(desktop);

    const client = try tree.find_client(runtime, request.window);
    if (client.pid != request.pid) return error.StaleRef;
    const app = atspi.application(desktop, request.pid) orelse return error.StaleRef;
    defer c.desk_a11y_unref(app);
    const top = try atspi.toplevel(runtime.allocator, app, client.title);
    defer c.desk_a11y_unref(top.node);
    const toolkit = (try atspi.toolkit(runtime.allocator, app)) orelse "";

    var target = try resolve(runtime.allocator, top.node, request.entry);
    defer c.desk_a11y_unref(target.node);
    target.utf16_lengths = std.ascii.startsWithIgnoreCase(toolkit, "qt");
    if (request.dry_run) return emit_dry_run(runtime, request, target);

    var attempt = Attempt{ .allocator = runtime.allocator };
    const result = try perform(&attempt, request, &target);
    try runtime.emit(Outcome{
        .verb = request.verb,
        .resolved_by = target.resolved_by,
        .role = target.details.role,
        .name = target.name,
        .delivery = delivery.get(),
        .verified = result.verified,
        .satisfied = result.satisfied,
        .value = result.value,
        .steps = attempt.steps.items,
    });
}

fn emit_dry_run(runtime: *Runtime, request: Request, target: Target) !void {
    try runtime.emit(Outcome{
        .verb = request.verb,
        .resolved_by = target.resolved_by,
        .role = target.details.role,
        .name = target.name,
        .delivery = .not_delivered,
        .verified = false,
        .steps = &.{},
        .actions = target.actions,
        .interfaces = try interface_names(runtime.allocator, target.details),
    });
}

fn interface_names(allocator: std.mem.Allocator, details: atspi.Info) ![]const []const u8 {
    const known = [_]struct { bit: c_uint, name: []const u8 }{
        .{ .bit = c.DESK_IFACE_ACTION, .name = "Action" },
        .{ .bit = c.DESK_IFACE_COMPONENT, .name = "Component" },
        .{ .bit = c.DESK_IFACE_TEXT, .name = "Text" },
        .{ .bit = c.DESK_IFACE_EDITABLE_TEXT, .name = "EditableText" },
        .{ .bit = c.DESK_IFACE_VALUE, .name = "Value" },
        .{ .bit = c.DESK_IFACE_SELECTION, .name = "Selection" },
    };
    var names: std.ArrayList([]const u8) = .empty;
    for (known) |interface| {
        if (details.has_interface(interface.bit)) try names.append(allocator, interface.name);
    }
    return names.toOwnedSlice(allocator);
}

fn read_stdin(allocator: std.mem.Allocator, limit: usize) ![]const u8 {
    var input: std.ArrayList(u8) = .empty;
    var buffer: [16 * 1024]u8 = undefined;
    while (input.items.len < limit) {
        const count = native.c.read(0, &buffer, buffer.len);
        if (count < 0 and native.errno() == native.c.EINTR) continue;
        if (count < 0) return error.InvalidRequest;
        if (count == 0) break;
        try input.appendSlice(allocator, buffer[0..@intCast(count)]);
    }
    return input.toOwnedSlice(allocator);
}

// ------------------------------------------------------------ resolution ---

/// The element at the ref's path when its identity still matches; otherwise
/// the only element of the window with that identity.
fn resolve(allocator: std.mem.Allocator, top: atspi.Node, entry: refs.Entry) !Target {
    if (entry.path.len == 0) return error.StaleRef;
    if (entry.path.len > refs.path_max) return error.StaleRef;
    if (atspi.follow(top, entry.path)) |node| {
        if (try matching(allocator, node, entry.identity)) |details| {
            return target_of(allocator, node, details, entry.identity, "path");
        }
        c.desk_a11y_unref(node);
    }
    const found = try search(allocator, top, entry.identity);
    return target_of(allocator, found.node, found.details, entry.identity, "identity");
}

fn matching(allocator: std.mem.Allocator, node: atspi.Node, identity: refs.Identity) !?atspi.Info {
    const details = try atspi.info(allocator, node);
    const current = try atspi.stable_identity(allocator, node, details);
    if (!current.eql(identity)) return null;
    return details;
}

fn target_of(
    allocator: std.mem.Allocator,
    node: atspi.Node,
    cached: atspi.Info,
    identity: refs.Identity,
    resolved_by: []const u8,
) !Target {
    // libatspi caches interfaces and states from the application's first
    // report; Chromium adds EditableText later. Read them again.
    c.desk_a11y_refresh(node);
    var details = try atspi.info(allocator, node);
    details.protected = details.protected or cached.protected;
    return .{
        .node = node,
        .details = details,
        .name = identity.name,
        .actions = try atspi.action_names(allocator, node, details.action_count),
        .utf16_lengths = false,
        .resolved_by = resolved_by,
    };
}

const Found = struct { node: atspi.Node, details: atspi.Info };

/// The walk an identity search may take before it gives up proving uniqueness.
const search_node_limit = 5000;

/// Depth-first over the toplevel. Exactly one match is required: none means
/// the element is gone, two mean the identity no longer tells them apart.
fn search(allocator: std.mem.Allocator, top: atspi.Node, identity: refs.Identity) !Found {
    const Level = struct { node: atspi.Node, next: c_int, count: c_int };
    // stack[0] is the caller's toplevel; deeper levels hold their own reference.
    var stack: [refs.path_max + 1]Level = undefined;
    var height: usize = 1;
    stack[0] = .{ .node = top, .next = 0, .count = c.desk_a11y_count(top) };
    defer if (height > 1) for (stack[1..height]) |level| c.desk_a11y_unref(level.node);
    var found: ?Found = null;
    errdefer if (found) |kept| c.desk_a11y_unref(kept.node);
    var visited: u32 = 0;

    while (height > 0) {
        const level = &stack[height - 1];
        if (level.next >= level.count) {
            if (height > 1) c.desk_a11y_unref(level.node);
            height -= 1;
            continue;
        }
        const index = level.next;
        level.next += 1;
        const child = c.desk_a11y_child(level.node, index) orelse continue;
        visited += 1;
        if (visited > search_node_limit) {
            c.desk_a11y_unref(child);
            return error.AmbiguousTarget;
        }
        try native.check_cancelled();
        if (try matching(allocator, child, identity)) |details| {
            if (found != null) {
                c.desk_a11y_unref(child);
                return error.AmbiguousTarget;
            }
            found = .{ .node = c.desk_a11y_ref(child).?, .details = details };
        }
        if (height == stack.len) {
            c.desk_a11y_unref(child);
            continue;
        }
        stack[height] = .{ .node = child, .next = 0, .count = c.desk_a11y_count(child) };
        height += 1;
    }
    return found orelse error.StaleRef;
}

// ------------------------------------------------------------- execution ---

const Result = struct { verified: bool, satisfied: bool = false, value: ?[]const u8 = null };

/// Records semantic calls and keeps the disposition exact: a call the
/// application refused or does not support changed nothing.
const Attempt = struct {
    allocator: std.mem.Allocator,
    steps: std.ArrayList(Step) = .empty,
    refused: bool = false,

    /// Marks delivery before a call; returns the disposition to restore if the
    /// call turns out to have changed nothing.
    fn begin(_: *Attempt) delivery.Delivery {
        const before = delivery.get();
        delivery.mark_sent();
        return before;
    }

    /// Records a call's result. True when the application accepted it.
    fn finish(self: *Attempt, before: delivery.Delivery, call: []const u8, code: c_int) !bool {
        const result: []const u8 = switch (code) {
            c.DESK_OK => "ok",
            c.DESK_FALSE => "refused",
            c.DESK_UNSUPPORTED => "unsupported",
            c.DESK_GONE => "gone",
            else => "uncertain",
        };
        const reason = std.mem.span(c.desk_a11y_last_error());
        const detail: ?[]const u8 = if (code < 0 and reason.len > 0)
            try self.allocator.dupe(u8, reason)
        else
            null;
        const step = Step{ .call = call, .result = result, .detail = detail };
        try self.steps.append(self.allocator, step);

        switch (code) {
            c.DESK_OK => return true,
            c.DESK_FALSE, c.DESK_UNSUPPORTED => {
                if (code == c.DESK_FALSE) self.refused = true;
                delivery.set(before);
                if (detail != null) delivery.set_detail(detail);
                return false;
            },
            c.DESK_GONE => {
                delivery.set(before);
                delivery.set_detail(detail);
                return error.StaleRef;
            },
            else => {
                delivery.set_detail(detail);
                return error.AccessibilityTimeout;
            },
        }
    }

    /// The error when every call was refused or unsupported.
    fn exhausted(self: *const Attempt) anyerror {
        return if (self.refused) error.ActionRefused else error.ActionNotSupported;
    }

    /// Tries the element's actions named in `wanted`, in that order.
    fn named(self: *Attempt, target: *const Target, wanted: []const []const u8) !bool {
        for (wanted) |name| {
            for (target.actions, 0..) |offered, index| {
                if (!eq(offered, name)) continue;
                const call = try std.fmt.allocPrint(
                    self.allocator,
                    "Action.DoAction({s})",
                    .{name},
                );
                const before = self.begin();
                const code = c.desk_a11y_do_action(target.node, @intCast(index));
                if (try self.finish(before, call, code)) return true;
            }
        }
        return false;
    }
};

fn perform(attempt: *Attempt, request: Request, target: *Target) !Result {
    return switch (request.verb) {
        .click => click(attempt, target),
        .focus => focus(attempt, target),
        .@"set-value" => set_value(attempt, target, request.text.?),
        .toggle, .check, .uncheck => toggle(attempt, target, request.verb),
        .expand, .collapse => disclose(attempt, target, request.verb == .expand),
        .select => select(attempt, target),
        .@"scroll-to" => scroll_to(attempt, target),
    };
}

const click_actions = [_][]const u8{ "click", "press", "activate", "open", "jump", "dodefault" };

fn click(attempt: *Attempt, target: *Target) !Result {
    if (!try attempt.named(target, &click_actions)) return attempt.exhausted();
    delivery.set(.delivered_unverified);
    return .{ .verified = false };
}

fn focus(attempt: *Attempt, target: *Target) !Result {
    if (target.details.has_state(c.DESK_STATE_FOCUSED)) return satisfied();
    const before = attempt.begin();
    const code = c.desk_a11y_grab_focus(target.node);
    if (!try attempt.finish(before, "Component.GrabFocus", code)) return attempt.exhausted();
    return settle(target.node, c.DESK_STATE_FOCUSED, true, 500);
}

fn scroll_to(attempt: *Attempt, target: *Target) !Result {
    const before = attempt.begin();
    const code = c.desk_a11y_scroll_to(target.node);
    if (!try attempt.finish(before, "Component.ScrollTo", code)) return attempt.exhausted();
    delivery.set(.delivered_unverified);
    return .{ .verified = false };
}

/// Nothing was sent: the element already had the requested state.
fn satisfied() Result {
    assert(delivery.get() == .not_delivered);
    return .{ .verified = true, .satisfied = true };
}

/// Waits until the state bit has the wanted value and records the outcome.
fn settle(node: atspi.Node, bit: c_uint, wanted: bool, timeout_ms: u32) Result {
    const deadline = native.now_ms() + timeout_ms;
    while (true) {
        c.desk_a11y_refresh(node);
        const present = c.desk_a11y_states(node) & bit != 0;
        if (present == wanted) {
            delivery.set(.delivered_verified);
            return .{ .verified = true };
        }
        if (native.now_ms() >= deadline) break;
        native.sleep_ms(50);
    }
    delivery.set(.delivered_unverified);
    return .{ .verified = false };
}

const checkable_roles = [_][]const u8{
    "check box",       "toggle button",   "radio button",  "switch",
    "check menu item", "radio menu item", "toggle switch",
};

fn checked(target: *const Target) bool {
    if (target.details.has_state(c.DESK_STATE_CHECKED)) return true;
    const toggle_button = eq(target.details.role, "toggle button");
    return toggle_button and target.details.has_state(c.DESK_STATE_PRESSED);
}

fn toggle(attempt: *Attempt, target: *Target, verb: Verb) !Result {
    var checkable = target.details.has_state(c.DESK_STATE_CHECKABLE);
    for (checkable_roles) |role| checkable = checkable or eq(role, target.details.role);
    if (!checkable) return error.ActionNotSupported;
    if (target.details.has_state(c.DESK_STATE_INDETERMINATE)) return error.IndeterminateState;

    const current = checked(target);
    const wanted = switch (verb) {
        .check => true,
        .uncheck => false,
        else => !current,
    };
    if (current == wanted) return satisfied();
    // The verb that sets the wanted state comes first; a plain toggle next.
    const set_on = [_][]const u8{ "check", "toggle", "switch", "click", "press", "activate" };
    const set_off = [_][]const u8{ "uncheck", "toggle", "switch", "click", "press", "activate" };
    if (!try attempt.named(target, if (wanted) &set_on else &set_off)) {
        return attempt.exhausted();
    }
    const bit: c_uint = if (eq(target.details.role, "toggle button") and
        !target.details.has_state(c.DESK_STATE_CHECKED))
        c.DESK_STATE_PRESSED
    else
        c.DESK_STATE_CHECKED;
    var result = settle(target.node, bit, wanted, 1000);
    const now_checked = c.desk_a11y_states(target.node) & bit != 0;
    result.value = if (now_checked) "checked" else "unchecked";
    return result;
}

fn disclose(attempt: *Attempt, target: *Target, expand: bool) !Result {
    if (!target.details.has_state(c.DESK_STATE_EXPANDABLE)) return error.ActionNotSupported;
    if (target.details.has_state(c.DESK_STATE_EXPANDED) == expand) return satisfied();
    const opening = [_][]const u8{
        "expand", "listitem.expand", "listitem.toggle-expand", "click", "press", "activate", "open",
    };
    const closing = [_][]const u8{
        "collapse", "listitem.collapse", "listitem.toggle-expand", "click", "press", "activate",
    };
    if (!try attempt.named(target, if (expand) &opening else &closing)) {
        return attempt.exhausted();
    }
    return settle(target.node, c.DESK_STATE_EXPANDED, expand, 1500);
}

fn select(attempt: *Attempt, target: *Target) !Result {
    if (!target.details.has_state(c.DESK_STATE_SELECTABLE)) return error.ActionNotSupported;
    if (target.details.has_state(c.DESK_STATE_SELECTED)) return satisfied();
    if (try attempt.named(target, &.{"select"})) {
        return settle(target.node, c.DESK_STATE_SELECTED, true, 1000);
    }
    if (try select_in_parent(attempt, target)) {
        return settle(target.node, c.DESK_STATE_SELECTED, true, 1000);
    }
    if (!try attempt.named(target, &click_actions)) return attempt.exhausted();
    return settle(target.node, c.DESK_STATE_SELECTED, true, 1000);
}

fn select_in_parent(attempt: *Attempt, target: *Target) !bool {
    const parent = c.desk_a11y_parent(target.node) orelse return false;
    defer c.desk_a11y_unref(parent);
    const index = c.desk_a11y_index_in_parent(target.node);
    if (index < 0) return false;
    const before = attempt.begin();
    const code = c.desk_a11y_select_child(parent, index);
    return attempt.finish(before, "Selection.SelectChild", code);
}

// ----------------------------------------------------------------- values ---

fn set_value(attempt: *Attempt, target: *Target, text: []const u8) !Result {
    if (target.details.protected) return error.ProtectedField;
    // Ranges and spin buttons take numbers through Value, which commits at
    // once; their text field may only commit on activation.
    const numeric = if (std.fmt.parseFloat(f64, text)) |_| true else |_| false;
    if (numeric and target.details.has_interface(c.DESK_IFACE_VALUE)) {
        return set_range(attempt, target, text);
    }
    if (!target.details.has_interface(c.DESK_IFACE_EDITABLE_TEXT)) {
        // Chromium exposes Text without EditableText on its inputs.
        delivery.set_detail("no EditableText interface: act focus, then key ctrl+a and type");
        return error.ActionNotSupported;
    }

    const original = (try atspi.text(attempt.allocator, target.node, text_limit)) orelse "";
    if (eq(original, text)) return satisfied();
    const text_z = try attempt.allocator.dupeSentinel(u8, text, 0);
    var before = attempt.begin();
    var code = c.desk_a11y_set_text_contents(target.node, text_z.ptr);
    if (try attempt.finish(before, "EditableText.SetTextContents", code)) {
        const settled = try text_settled(attempt.allocator, target.node, text, original);
        if (settled) |result| return result;
    }
    // Some toolkits accept SetTextContents and change nothing (Gecko): replace.
    const length = if (target.utf16_lengths) utf16_length(text) else text.len;
    before = attempt.begin();
    code = c.desk_a11y_replace_text(target.node, text_z.ptr, @intCast(length));
    if (!try attempt.finish(before, "EditableText.DeleteText+InsertText", code)) {
        return attempt.exhausted();
    }
    if (try text_settled(attempt.allocator, target.node, text, original)) |result| return result;
    return error.WriteIgnored;
}

/// Text values are read back in full up to this many characters.
const text_limit = 64 * 1024;

/// The verified result once the text equals `wanted`. Null when it still
/// equals `original`, meaning the call changed nothing. Any other text is a
/// partial write: `ValueMismatch`, delivered but wrong.
fn text_settled(
    allocator: std.mem.Allocator,
    node: atspi.Node,
    wanted: []const u8,
    original: []const u8,
) !?Result {
    const deadline = native.now_ms() + 1000;
    var current: []const u8 = original;
    while (true) {
        c.desk_a11y_refresh(node);
        current = (try atspi.text(allocator, node, text_limit)) orelse "";
        if (eq(current, wanted)) {
            delivery.set(.delivered_verified);
            return .{ .verified = true, .value = current };
        }
        if (native.now_ms() >= deadline) break;
        native.sleep_ms(50);
    }
    if (eq(current, original)) {
        delivery.set(.not_delivered);
        return null;
    }
    delivery.set(.delivered_unverified);
    return error.ValueMismatch;
}

fn utf16_length(text: []const u8) usize {
    var length: usize = 0;
    var view = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (view.nextCodepoint()) |codepoint| length += if (codepoint > 0xFFFF) 2 else 1;
    return length;
}

fn set_range(attempt: *Attempt, target: *Target, text: []const u8) !Result {
    const wanted = std.fmt.parseFloat(f64, text) catch return error.InvalidValue;
    if (!std.math.isFinite(wanted)) return error.InvalidValue;
    const range = atspi.range_value(target.node) orelse return error.ActionNotSupported;
    if (wanted < range.minimum or wanted > range.maximum) return error.InvalidValue;
    if (range.current == wanted) return satisfied();

    const before = attempt.begin();
    const code = c.desk_a11y_set_value(target.node, wanted);
    if (!try attempt.finish(before, "Value.CurrentValue", code)) return attempt.exhausted();
    const tolerance = @max(range.increment, 1e-9);
    const deadline = native.now_ms() + 1000;
    while (true) {
        c.desk_a11y_refresh(target.node);
        const now = atspi.range_value(target.node) orelse break;
        const value = try std.fmt.allocPrint(attempt.allocator, "{d}", .{now.current});
        if (@abs(now.current - wanted) <= tolerance) {
            delivery.set(.delivered_verified);
            return .{ .verified = true, .value = value };
        }
        if (native.now_ms() >= deadline) break;
        native.sleep_ms(50);
    }
    delivery.set(.delivered_unverified);
    return error.ValueMismatch;
}

test "utf16 lengths count astral characters twice" {
    try std.testing.expectEqual(@as(usize, 5), utf16_length("hello"));
    try std.testing.expectEqual(@as(usize, 2), utf16_length("ñ✓"));
    try std.testing.expectEqual(@as(usize, 3), utf16_length("a😀"));
}
