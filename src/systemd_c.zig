//! the libsystemd side of systemd.zig. only compiled with `-Dsystemd`.

const std = @import("std");
const facts = @import("facts.zig");
const diag = @import("diag.zig");
const api = @import("systemd.zig");
const Allocator = std.mem.Allocator;
const c = @cImport(@cInclude("systemd/sd-bus.h"));

const manager = .{ "org.freedesktop.systemd1", "/org/freedesktop/systemd1", "org.freedesktop.systemd1.Manager" };

pub fn units(a: Allocator, diags: *diag.List) api.Error!?[]facts.Unit {
    var bus: ?*c.sd_bus = null;
    const r = c.sd_bus_open_system(&bus);
    // no bus socket means systemd isn't running, as in a container or a
    // chroot: nothing is enabled or running then, which isn't an error.
    if (r == -@as(c_int, @intFromEnum(std.posix.E.NOENT)) or r == -@as(c_int, @intFromEnum(std.posix.E.CONNREFUSED))) return &.{};
    if (r < 0) {
        try diags.add(.systemd_failed, null, "can't reach systemd on the system bus: {s}", .{std.mem.span(c.strerror(-r))}, null);
        return null;
    }
    defer _ = c.sd_bus_flush_close_unref(bus);

    var found: std.StringArrayHashMapUnmanaged(facts.Unit) = .empty;
    if (!try unitFiles(a, bus, &found, diags)) return null;
    if (!try loadedUnits(a, bus, &found, diags)) return null;

    var out: std.ArrayList(facts.Unit) = .empty;
    for (found.values()) |u| {
        if (u.enabled or u.active or u.failed) try out.append(a, u);
    }
    return out.items;
}

fn entry(a: Allocator, found: *std.StringArrayHashMapUnmanaged(facts.Unit), name: []const u8) !*facts.Unit {
    const gop = try found.getOrPut(a, name);
    if (!gop.found_existing) {
        gop.key_ptr.* = try a.dupe(u8, name);
        gop.value_ptr.* = .{ .name = gop.key_ptr.* };
    }
    return gop.value_ptr;
}

/// calls a manager method with no arguments. returns null after reporting
/// the failure.
fn call(bus: ?*c.sd_bus, method: [*:0]const u8, diags: *diag.List) !?*c.sd_bus_message {
    var err: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
    defer c.sd_bus_error_free(&err);
    var reply: ?*c.sd_bus_message = null;
    if (c.sd_bus_call_method(bus, manager[0], manager[1], manager[2], method, &err, &reply, null) < 0) {
        const why: []const u8 = if (err.message != null) std.mem.span(err.message) else "no reply";
        try diags.add(.systemd_failed, null, "systemd's {s} failed: {s}", .{ method, why }, null);
        return null;
    }
    return reply;
}

/// enablement from ListUnitFiles: a(ss) of unit path and state.
fn unitFiles(a: Allocator, bus: ?*c.sd_bus, found: *std.StringArrayHashMapUnmanaged(facts.Unit), diags: *diag.List) !bool {
    const m = try call(bus, "ListUnitFiles", diags) orelse return false;
    defer _ = c.sd_bus_message_unref(m);
    if (c.sd_bus_message_enter_container(m, 'a', "(ss)") < 0) return badReply(diags, "ListUnitFiles");
    while (true) {
        var path: [*c]const u8 = null;
        var state: [*c]const u8 = null;
        const r = c.sd_bus_message_read(m, "(ss)", &path, &state);
        if (r < 0) return badReply(diags, "ListUnitFiles");
        if (r == 0) break;
        const name = std.fs.path.basename(std.mem.span(path));
        if (!api.managedKind(name)) continue;
        (try entry(a, found, name)).enabled = api.enabledState(std.mem.span(state));
    }
    return true;
}

/// run state from ListUnits: a(ssssssouso), of which the first and fourth,
/// the name and active state, matter here.
fn loadedUnits(a: Allocator, bus: ?*c.sd_bus, found: *std.StringArrayHashMapUnmanaged(facts.Unit), diags: *diag.List) !bool {
    const m = try call(bus, "ListUnits", diags) orelse return false;
    defer _ = c.sd_bus_message_unref(m);
    if (c.sd_bus_message_enter_container(m, 'a', "(ssssssouso)") < 0) return badReply(diags, "ListUnits");
    while (true) {
        var s: [8][*c]const u8 = @splat(null);
        var job_id: u32 = 0;
        var job_path: [*c]const u8 = null;
        const r = c.sd_bus_message_read(m, "(ssssssouso)", &s[0], &s[1], &s[2], &s[3], &s[4], &s[5], &s[6], &job_id, &s[7], &job_path);
        if (r < 0) return badReply(diags, "ListUnits");
        if (r == 0) break;
        const name = std.mem.span(s[0]);
        if (!api.managedKind(name)) continue;
        const active = std.mem.span(s[3]);
        const u = try entry(a, found, name);
        u.active = std.mem.eql(u8, active, "active");
        u.failed = std.mem.eql(u8, active, "failed");
    }
    return true;
}

fn badReply(diags: *diag.List, method: []const u8) !bool {
    try diags.add(.systemd_failed, null, "couldn't read systemd's {s} reply", .{method}, null);
    return false;
}
