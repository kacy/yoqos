//! the runtime backend: unit state from systemd over sd-bus, and enabling,
//! disabling, starting, and stopping units.
//!
//! build with `-Dsystemd` to link libsystemd; the work happens in
//! systemd_c.zig. without it, `units` returns `error.SystemdUnavailable`.

const std = @import("std");
const build_options = @import("build_options");
const facts = @import("facts.zig");
const diag = @import("diag.zig");
const Allocator = std.mem.Allocator;

pub const available = build_options.systemd;
const impl = if (available) @import("systemd_c.zig") else struct {};

pub const Error = error{ SystemdUnavailable, OutOfMemory };

/// the kinds of units the config manages.
pub const kinds = [_][]const u8{ ".service", ".timer", ".socket" };

pub fn managedKind(name: []const u8) bool {
    for (kinds) |k| {
        if (std.mem.endsWith(u8, name, k)) return true;
    }
    return false;
}

/// services, timers, and sockets that are enabled, running, or failed, from
/// the running system's manager. with no systemd running, that's none.
/// returns null, after saying why in `diags`, if the bus is there but
/// can't be used.
pub fn units(a: Allocator, diags: *diag.List) Error!?[]facts.Unit {
    return if (comptime available) impl.units(a, diags) else error.SystemdUnavailable;
}

/// whether systemd runs this machine. in a container or chroot it doesn't,
/// and units can't be started.
pub fn running() bool {
    return if (comptime available) impl.running() else false;
}

/// what can be done to a unit. a plan's unit change lists these in order,
/// like "disable, stop".
pub const Verb = enum { enable, disable, start, stop };

/// the verbs in a plan's "enable, start".
pub fn parseVerbs(a: Allocator, text: []const u8) ![]const Verb {
    var out: std.ArrayList(Verb) = .empty;
    var it = std.mem.tokenizeAny(u8, text, ", ");
    while (it.next()) |word| try out.append(a, std.meta.stringToEnum(Verb, word) orelse return error.UnknownVerb);
    return out.items;
}

/// does `verbs` to `unit`, in order, waiting for each start or stop to
/// finish. returns false, after saying why in `diags`, if one failed.
pub fn change(a: Allocator, unit: []const u8, verbs: []const Verb, diags: *diag.List) Error!bool {
    return if (comptime available) impl.change(a, unit, verbs, diags) else error.SystemdUnavailable;
}

/// an enablement state from ListUnitFiles counts as enabled.
pub fn enabledState(state: []const u8) bool {
    return std.mem.eql(u8, state, "enabled") or std.mem.eql(u8, state, "enabled-runtime");
}

test "verbs from a plan" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualSlices(Verb, &.{ .disable, .stop }, try parseVerbs(arena.allocator(), "disable, stop"));
    try std.testing.expectEqualSlices(Verb, &.{.start}, try parseVerbs(arena.allocator(), "start"));
}

test "unit kinds and states" {
    try std.testing.expect(managedKind("sshd.service"));
    try std.testing.expect(managedKind("fstrim.timer"));
    try std.testing.expect(!managedKind("home.mount"));
    try std.testing.expect(enabledState("enabled"));
    try std.testing.expect(!enabledState("static"));
}

test "units from the running system" {
    if (!available) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diags: diag.List = .init(std.testing.allocator);
    defer diags.deinit();
    const us = try units(arena.allocator(), &diags) orelse return error.TestUnexpectedResult;
    // no systemd running, as in a container: nothing more to check.
    if (us.len == 0) return error.SkipZigTest;
    var journald = false;
    for (us) |u| {
        try std.testing.expect(managedKind(u.name));
        if (std.mem.eql(u8, u.name, "systemd-journald.service")) journald = u.active;
    }
    try std.testing.expect(journald);
}
