//! the runtime backend's read side: unit state from systemd over sd-bus.
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
/// the running system's manager. returns null, after saying why in
/// `diags`, if the system bus can't be reached.
pub fn units(a: Allocator, diags: *diag.List) Error!?[]facts.Unit {
    return if (comptime available) impl.units(a, diags) else error.SystemdUnavailable;
}

/// an enablement state from ListUnitFiles counts as enabled.
pub fn enabledState(state: []const u8) bool {
    return std.mem.eql(u8, state, "enabled") or std.mem.eql(u8, state, "enabled-runtime");
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
    // no system bus, as in a container: nothing to check here.
    const us = try units(arena.allocator(), &diags) orelse return error.SkipZigTest;
    var journald = false;
    for (us) |u| {
        try std.testing.expect(managedKind(u.name));
        if (std.mem.eql(u8, u.name, "systemd-journald.service")) journald = u.active;
    }
    try std.testing.expect(journald);
}
