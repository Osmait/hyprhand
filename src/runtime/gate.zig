//! Confirmation gate for consequential actions. Before an input command
//! activates a control whose name says it pays, sends, publishes, creates an
//! account, deletes or accepts terms, the gate stops it:
//!
//! - `ask` (default): the action fails with `ConfirmationRequired` and a
//!   one-time confirmation ID. After the human agrees, the agent repeats the
//!   same command with `--ack ID`. Every acknowledgement is audited.
//! - `human`: hyprhand itself asks the human with a host desktop notification
//!   (Approve / Deny) and waits. Only for managed sessions, whose input cannot
//!   reach the host's notifications.
//! - `off`: no gate.
//!
//! The gate sees a control's accessible role and name, so it only knows what
//! the application exposes; an unnamed or inaccessible control is not gated.
const std = @import("std");
const assert = std.debug.assert;
const eq = @import("../core/text.zig").eq;
const Runtime = @import("runtime.zig").Runtime;
const native = @import("../platform/native.zig");
const delivery = @import("delivery.zig");
const operations = @import("operations.zig");

pub const Mode = @import("../cli/args.zig").GateMode;

pub const Category = enum {
    payment,
    communication,
    account_creation,
    deletion,
    consent,
};

/// Lowercase phrases, matched at the start of a word of the control's name.
const patterns = [_]struct { category: Category, phrases: []const []const u8 }{
    .{ .category = .payment, .phrases = &.{
        "pay",       "payment",          "buy",             "purchase",       "checkout",
        "check out", "place order",      "order now",       "complete order", "donate",
        "subscribe", "upgrade",          "pagar",           "pago",           "comprar",
        "compra",    "finalizar compra", "realizar pedido", "donar",          "suscribir",
    } },
    .{ .category = .communication, .phrases = &.{
        "send",   "post",     "publish",   "share",     "reply", "tweet",
        "enviar", "publicar", "compartir", "responder",
    } },
    .{ .category = .account_creation, .phrases = &.{
        "sign up", "create account", "register",         "join now",
        "registr", "crear cuenta",   "crear una cuenta",
    } },
    .{ .category = .deletion, .phrases = &.{
        "delete",   "erase",  "wipe",            "empty trash", "discard",
        "eliminar", "borrar", "vaciar papelera", "descartar",
    } },
    .{ .category = .consent, .phrases = &.{
        "i agree", "agree", "accept", "consent", "acepto", "aceptar", "de acuerdo",
    } },
};

/// Roles that activate something; fields and labels are never gated.
const activating_roles = [_][]const u8{
    "push button",      "button",          "toggle button",   "link",
    "menu item",        "check menu item", "radio menu item", "check box",
    "push button menu", "page tab",
};

/// The category a control falls in, or null when it is not consequential.
pub fn classify(role: []const u8, name: []const u8) ?Category {
    var activates = false;
    for (activating_roles) |candidate| activates = activates or eq(candidate, role);
    if (!activates) return null;
    var buffer: [256]u8 = undefined;
    const length = @min(name.len, buffer.len);
    const lower = std.ascii.lowerString(buffer[0..length], name[0..length]);
    for (patterns) |group| {
        for (group.phrases) |phrase| {
            if (word_start_match(lower, phrase)) return group.category;
        }
    }
    return null;
}

/// True when `phrase` occurs in `text` at the start of a word.
fn word_start_match(text: []const u8, phrase: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, phrase)) |index| {
        const at_word_start = index == 0 or !std.ascii.isAlphanumeric(text[index - 1]);
        if (at_word_start) return true;
        start = index + 1;
    }
    return false;
}

/// The control an input command is about to activate.
pub const Target = struct {
    role: []const u8,
    name: []const u8,
    window: []const u8,
};

/// A confirmation waiting for `--ack`.
pub const Pending = struct {
    id: []const u8,
    category: Category,
    role: []const u8,
    name: []const u8,
    window: []const u8,
    created_monotonic_ms: i64,
};

/// Confirmations expire unused after this long.
pub const pending_max_age_ms = 2 * 60 * 1000;
/// How long `human` mode waits for an answer.
const human_wait_ms = 120_000;

/// The confirmation the last refusal created, for the error report.
var reported: ?Pending = null;

pub fn reported_pending() ?Pending {
    return reported;
}

/// Forgets the last refusal, before the next step of a composite command.
pub fn clear_reported() void {
    reported = null;
}

pub fn read_mode(runtime: *Runtime) !Mode {
    const path = try runtime.state_path("gate");
    const text = runtime.read_file(path, 64) catch |err| switch (err) {
        error.FileNotFound => return .ask,
        else => return err,
    };
    return std.meta.stringToEnum(Mode, std.mem.trim(u8, text, " \n")) orelse .ask;
}

pub fn write_mode(runtime: *Runtime, mode: Mode) !void {
    if (mode == .human and runtime.is_host()) return error.GateHumanNeedsManagedSession;
    try runtime.prepare();
    const path = try runtime.state_path("gate");
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = path, .data = @tagName(mode) });
}

/// Lets the action through, or stops it until the human agrees.
pub fn check(runtime: *Runtime, target: Target, ack: ?[]const u8) !void {
    const mode = try read_mode(runtime);
    if (mode == .off) return;
    const category = classify(target.role, target.name) orelse return;
    switch (mode) {
        .off => unreachable,
        .ask => {
            if (ack) |id| return consume(runtime, id, target, category);
            reported = try create(runtime, target, category);
            return error.ConfirmationRequired;
        },
        .human => return ask_human(runtime, target, category),
    }
}

fn pending_path(runtime: *Runtime, id: []const u8) ![:0]const u8 {
    return runtime.state_path(try std.fmt.allocPrint(runtime.allocator, "{s}.confirm", .{id}));
}

fn create(runtime: *Runtime, target: Target, category: Category) !Pending {
    const token = try runtime.random_token();
    const pending = Pending{
        .id = token[0..8],
        .category = category,
        .role = target.role,
        .name = target.name,
        .window = target.window,
        .created_monotonic_ms = native.now_ms(),
    };
    try std.Io.Dir.cwd().writeFile(runtime.io, .{
        .sub_path = try pending_path(runtime, pending.id),
        .data = try std.json.Stringify.valueAlloc(runtime.allocator, pending, .{}),
        .flags = .{ .exclusive = true },
    });
    return pending;
}

/// Accepts an acknowledgement once, for the same control, while it is fresh.
fn consume(runtime: *Runtime, id: []const u8, target: Target, category: Category) !void {
    if (id.len != 8) return error.ConfirmationNotFound;
    for (id) |character| {
        if (!std.ascii.isHex(character)) return error.ConfirmationNotFound;
    }
    const path = try pending_path(runtime, id);
    const data = runtime.read_file(path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.ConfirmationNotFound,
        else => return err,
    };
    // One use: remove it before acting, whatever happens next.
    _ = native.c.unlink(path);
    const pending = try runtime.parse_json(Pending, data);
    const age = native.now_ms() - pending.created_monotonic_ms;
    if (age < 0 or age > pending_max_age_ms) return error.ConfirmationExpired;
    const same = pending.category == category and eq(pending.role, target.role) and
        eq(pending.name, target.name) and eq(pending.window, target.window);
    if (!same) return error.ConfirmationMismatch;
    // The audit log keeps every acknowledgement, never the control's name.
    const status = try std.fmt.allocPrint(
        runtime.allocator,
        "acknowledged {s} {s}",
        .{ @tagName(category), id },
    );
    try operations.log(runtime, "confirmation", status);
}

/// `human` mode: a host notification with Approve and Deny, answered by a person.
fn ask_human(runtime: *Runtime, target: Target, category: Category) !void {
    assert(!runtime.is_host());
    var host = runtime.*;
    host.env = runtime.host_env orelse return error.ConfirmationUnavailable;
    host.action = null;
    const title = try std.fmt.allocPrint(
        runtime.allocator,
        "hyprhand: approve {s}?",
        .{@tagName(category)},
    );
    const body = try std.fmt.allocPrint(
        runtime.allocator,
        "Session {s} wants to activate {s} \u{201C}{s}\u{201D}.",
        .{ runtime.session_id, target.role, target.name },
    );
    const captured = host.run_capture(&.{
        "notify-send",          "--app-name=hyprhand",      "--urgency=critical",
        "--expire-time=120000", "--action=approve=Approve", "--action=deny=Deny",
        title,                  body,
    }, "", false, human_wait_ms + 5000) catch |err| switch (err) {
        error.HelperTimeout => return error.ConfirmationDenied,
        else => return error.ConfirmationUnavailable,
    };
    if (!captured.succeeded) return error.ConfirmationUnavailable;
    const approved = eq(std.mem.trim(u8, captured.stdout, " \n"), "approve");
    const status = try std.fmt.allocPrint(
        runtime.allocator,
        "{s} {s} by notification",
        .{ if (approved) "approved" else "denied", @tagName(category) },
    );
    try operations.log(runtime, "confirmation", status);
    if (!approved) return error.ConfirmationDenied;
}

test "consequential controls are classified, ordinary ones are not" {
    try std.testing.expectEqual(Category.payment, classify("push button", "Pay $20.00").?);
    try std.testing.expectEqual(Category.payment, classify("link", "Finalizar compra").?);
    try std.testing.expectEqual(Category.communication, classify("button", "Send").?);
    const send = classify("push button", "Enviar mensaje").?;
    try std.testing.expectEqual(Category.communication, send);
    try std.testing.expectEqual(Category.account_creation, classify("button", "Sign up").?);
    try std.testing.expectEqual(Category.deletion, classify("menu item", "Delete repository").?);
    try std.testing.expectEqual(Category.consent, classify("check box", "I agree to the terms").?);

    const ordinary = [_][2][]const u8{
        .{ "push button", "Display settings" }, // "pay" inside a word
        .{ "push button", "Repost history" },
        .{ "push button", "Apply" },
        .{ "entry", "Send to" }, // fields are never gated
        .{ "label", "Delete" },
        .{ "push button", "" },
    };
    for (ordinary) |pair| {
        try std.testing.expectEqual(@as(?Category, null), classify(pair[0], pair[1]));
    }
}
