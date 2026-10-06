//! the runtime backend: unit state from systemd over sd-bus, and enabling,
//! disabling, starting, and stopping units.
//!
//! build with `-Dsystemd` to link libsystemd; the work happens in
//! systemd_c.zig. without it, `units` returns `error.SystemdUnavailable`.

const std = @import("std");
const build_options = @import("build_options");
const facts = @import("facts.zig");
const diag = @import("diag.zig");
const lists = @import("lists.zig");
const Allocator = std.mem.Allocator;

pub const available = build_options.systemd;
const impl = if (available) @import("systemd_c.zig") else struct {};

pub const Error = error{ SystemdUnavailable, OutOfMemory };

/// the kinds of units the config manages.
const kinds = [_][]const u8{ ".service", ".timer", ".socket" };

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
pub const Verb = enum { enable, disable, mask, unmask, start, stop, restart };

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

/// the units an enabled unit's links make it wanted or required by, from
/// the links themselves, like
/// /etc/systemd/system/bluetooth.target.wants/bluetooth.service for
/// bluetooth.target. an alias link names no unit.
pub fn wantedBy(a: std.mem.Allocator, links: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (links) |link| {
        const dir = std.fs.path.basename(std.fs.path.dirname(link) orelse continue);
        for ([_][]const u8{ ".wants", ".requires" }) |suffix| {
            if (std.mem.endsWith(u8, dir, suffix) and dir.len > suffix.len) try out.append(a, dir[0 .. dir.len - suffix.len]);
        }
    }
    return out.items;
}

/// whether an enabled unit that isn't running is only waiting for the
/// boot to ask for it: nothing started it this boot, and none of the
/// units its enablement links it to (its WantedBy= and RequiredBy=) is
/// active.
pub fn waiting(wanted_by: []const []const u8, active: *const std.StringHashMapUnmanaged(void), started: bool) bool {
    if (started or wanted_by.len == 0) return false;
    for (wanted_by) |w| {
        if (active.contains(w)) return false;
    }
    return true;
}

/// an enablement state from ListUnitFiles counts as enabled.
pub fn enabledState(state: []const u8) bool {
    return std.mem.eql(u8, state, "enabled") or std.mem.eql(u8, state, "enabled-runtime");
}

pub fn maskedState(state: []const u8) bool {
    return std.mem.eql(u8, state, "masked") or std.mem.eql(u8, state, "masked-runtime");
}

/// a state enabling or disabling doesn't change: a unit without an
/// [Install] section, one a generator makes, an alias, or one another
/// unit turns on.
pub fn fixedState(state: []const u8) bool {
    return lists.contains(&.{ "static", "generated", "alias", "indirect", "transient" }, state);
}

test "verbs from a plan" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualSlices(Verb, &.{ .disable, .stop }, try parseVerbs(arena.allocator(), "disable, stop"));
    try std.testing.expectEqualSlices(Verb, &.{.start}, try parseVerbs(arena.allocator(), "start"));
}

test "what a unit's links make it wanted by" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try wantedBy(arena.allocator(), &.{
        "/etc/systemd/system/bluetooth.target.wants/bluetooth.service",
        "/etc/systemd/system/dbus-org.bluez.service",
        "/etc/systemd/system/multi-user.target.requires/x.service",
        "/etc/systemd/system/.wants/y.service",
    });
    try std.testing.expectEqual(2, got.len);
    try std.testing.expectEqualStrings("bluetooth.target", got[0]);
    try std.testing.expectEqualStrings("multi-user.target", got[1]);
}

test "a unit waits until something that wants it starts" {
    var active: std.StringHashMapUnmanaged(void) = .empty;
    defer active.deinit(std.testing.allocator);
    try active.put(std.testing.allocator, "multi-user.target", {});
    try std.testing.expect(waiting(&.{"bluetooth.target"}, &active, false));
    try std.testing.expect(!waiting(&.{ "bluetooth.target", "multi-user.target" }, &active, false));
    // started and stopped since, by hand or by a crash: not waiting.
    try std.testing.expect(!waiting(&.{"bluetooth.target"}, &active, true));
    // nothing wants it, so nothing will start it.
    try std.testing.expect(!waiting(&.{}, &active, false));
}

test "unit kinds and states" {
    try std.testing.expect(managedKind("sshd.service"));
    try std.testing.expect(managedKind("fstrim.timer"));
    try std.testing.expect(!managedKind("home.mount"));
    try std.testing.expect(enabledState("enabled"));
    try std.testing.expect(!enabledState("static"));
    try std.testing.expect(fixedState("static"));
    try std.testing.expect(!fixedState("disabled"));
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
