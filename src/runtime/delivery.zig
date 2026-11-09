//! What the current command delivered to applications, reported as the
//! `disposition` of every response so an agent knows whether a retry is safe.
//! One command is one process, so the state is process-wide.
const std = @import("std");

pub const Delivery = enum {
    /// Nothing reached an application: retrying is safe.
    not_delivered,
    /// Input may have reached an application and the outcome is unknown:
    /// inspect the application before deciding to retry.
    delivery_uncertain,
    /// Input was delivered; its effect was not checked.
    delivered_unverified,
    /// Input was delivered and a read-back confirmed its effect.
    delivered_verified,
};

var current: Delivery = .not_delivered;
/// What the application or library said when an action failed, if anything.
var failure_detail: ?[]const u8 = null;

/// Called immediately before the first event that can change an application:
/// a button, wheel or key event, a compositor dispatch, a launch, or a
/// semantic accessibility call. Until the command completes, a failure leaves
/// the outcome uncertain.
pub fn mark_sent() void {
    if (current == .not_delivered) current = .delivery_uncertain;
}

pub fn set(value: Delivery) void {
    current = value;
}

pub fn get() Delivery {
    return current;
}

pub fn set_detail(text: ?[]const u8) void {
    failure_detail = text;
}

pub fn detail() ?[]const u8 {
    return failure_detail;
}

/// The `disposition` object of a response.
pub const Disposition = struct {
    delivery: Delivery,
    /// True only when nothing was delivered.
    retry_safe: bool,
};

pub fn disposition() Disposition {
    return .{ .delivery = current, .retry_safe = current == .not_delivered };
}

test "delivery starts undelivered and becomes uncertain once input is sent" {
    defer set(.not_delivered);
    set(.not_delivered);
    try std.testing.expect(disposition().retry_safe);
    mark_sent();
    try std.testing.expectEqual(Delivery.delivery_uncertain, get());
    try std.testing.expect(!disposition().retry_safe);
    set(.delivered_verified);
    mark_sent();
    try std.testing.expectEqual(Delivery.delivered_verified, get());
}
