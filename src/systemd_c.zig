//! the libsystemd side of systemd.zig. only compiled with `-Dsystemd`.

const std = @import("std");
const facts = @import("facts.zig");
const diag = @import("diag.zig");
const api = @import("systemd.zig");
const Allocator = std.mem.Allocator;
const c = @cImport({
    // glibc's fortify wrappers use builtins translate-c can't follow, and
    // yos calls none of the functions they wrap.
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("systemd/sd-bus.h");
    @cInclude("systemd/sd-daemon.h");
});

const destination = "org.freedesktop.systemd1";
const object = "/org/freedesktop/systemd1";
const manager_iface = "org.freedesktop.systemd1.Manager";
const service_iface = "org.freedesktop.systemd1.Service";
const unit_iface = "org.freedesktop.systemd1.Unit";

/// units by name, as they're found.
const Found = std.StringArrayHashMapUnmanaged(facts.Unit);

pub fn running() bool {
    return c.sd_booted() > 0;
}

const Bus = union(enum) { bus: *c.sd_bus, absent, failed };

/// the system bus. no bus socket means systemd isn't running, as in a
/// container or a chroot.
fn open(diags: *diag.List) !Bus {
    var bus: ?*c.sd_bus = null;
    const r = c.sd_bus_open_system(&bus);
    if (r == -@as(c_int, @intFromEnum(std.posix.E.NOENT)) or r == -@as(c_int, @intFromEnum(std.posix.E.CONNREFUSED))) return .absent;
    if (r < 0) {
        try diags.add(.systemd_failed, null, "can't reach systemd on the system bus: {s}", .{std.mem.span(c.strerror(-r))}, null);
        return .failed;
    }
    return .{ .bus = bus.? };
}

pub fn units(a: Allocator, diags: *diag.List) api.Error!?[]facts.Unit {
    const bus = switch (try open(diags)) {
        .bus => |b| b,
        // without systemd nothing is enabled or running, which isn't an
        // error.
        .absent => return &.{},
        .failed => return null,
    };
    defer _ = c.sd_bus_flush_close_unref(bus);

    var found: Found = .empty;
    if (!try unitFiles(a, bus, &found, diags)) return null;
    if (!try loadedUnits(a, bus, &found, diags)) return null;

    var out: std.ArrayList(facts.Unit) = .empty;
    for (found.values()) |u| {
        if (u.enabled or u.active or u.failed or u.masked) try out.append(a, u);
    }
    return out.items;
}

fn entry(a: Allocator, found: *Found, name: []const u8) !*facts.Unit {
    const gop = try found.getOrPut(a, name);
    if (!gop.found_existing) {
        gop.key_ptr.* = try a.dupe(u8, name);
        gop.value_ptr.* = .{ .name = gop.key_ptr.* };
    }
    return gop.value_ptr;
}

/// calls a manager method with arguments in sd-bus's `types` notation.
/// returns null after reporting the failure.
fn call(bus: *c.sd_bus, method: [*:0]const u8, types: ?[*:0]const u8, args: anytype, diags: *diag.List) !?*c.sd_bus_message {
    var err: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
    defer c.sd_bus_error_free(&err);
    var reply: ?*c.sd_bus_message = null;
    if (@call(.auto, c.sd_bus_call_method, .{ bus, destination, object, manager_iface, method, &err, &reply, types } ++ args) < 0) {
        const why: []const u8 = if (err.message != null) std.mem.span(err.message) else "no reply";
        try diags.add(.systemd_failed, null, "systemd's {s} failed: {s}", .{ method, why }, null);
        return null;
    }
    return reply;
}

/// calls a method whose reply doesn't matter.
fn do(bus: *c.sd_bus, method: [*:0]const u8, types: ?[*:0]const u8, args: anytype, diags: *diag.List) !bool {
    const m = try call(bus, method, types, args, diags) orelse return false;
    _ = c.sd_bus_message_unref(m);
    return true;
}

pub fn change(a: Allocator, unit: []const u8, verbs: []const api.Verb, diags: *diag.List) api.Error!bool {
    const bus = switch (try open(diags)) {
        .bus => |b| b,
        .absent => {
            try diags.add(.systemd_failed, null, "can't change {s}: systemd isn't running", .{unit}, null);
            return false;
        },
        .failed => return false,
    };
    defer _ = c.sd_bus_flush_close_unref(bus);
    const name = try a.dupeZ(u8, unit);

    // start and stop return a job; its JobRemoved signal says how it went.
    // the match goes in first so the signal can't slip past.
    var jobs: Jobs = .{ .a = a };
    var slot: ?*c.sd_bus_slot = null;
    const match = "type='signal',sender='" ++ destination ++ "',path='" ++ object ++ "',interface='" ++ manager_iface ++ "',member='JobRemoved'";
    if (c.sd_bus_add_match(bus, &slot, match, Jobs.removed, &jobs) < 0) {
        try diags.add(.systemd_failed, null, "can't watch systemd's jobs", .{}, null);
        return false;
    }
    defer _ = c.sd_bus_slot_unref(slot);
    if (!try do(bus, "Subscribe", null, .{}, diags)) return false;

    // an `as` argument is a count, then the strings.
    const one: c_int = 1;
    const no: c_int = 0;
    for (verbs) |v| {
        const ok = switch (v) {
            .enable => try do(bus, "EnableUnitFiles", "asbb", .{ one, name.ptr, no, no }, diags) and try do(bus, "Reload", null, .{}, diags),
            .disable => try do(bus, "DisableUnitFiles", "asb", .{ one, name.ptr, no }, diags) and try do(bus, "Reload", null, .{}, diags),
            .mask => try do(bus, "MaskUnitFiles", "asbb", .{ one, name.ptr, no, no }, diags) and try do(bus, "Reload", null, .{}, diags),
            .unmask => try do(bus, "UnmaskUnitFiles", "asb", .{ one, name.ptr, no }, diags) and try do(bus, "Reload", null, .{}, diags),
            .start, .stop, .restart => try runJob(a, bus, &jobs, name, v, diags),
        };
        if (!ok) return false;
    }
    return true;
}

/// starts, stops, or restarts `unit`, and waits for its job to finish.
fn runJob(a: Allocator, bus: *c.sd_bus, jobs: *Jobs, unit: [:0]const u8, v: api.Verb, diags: *diag.List) !bool {
    const method: [:0]const u8 = switch (v) {
        .start => "StartUnit",
        .stop => "StopUnit",
        .restart => "RestartUnit",
        .enable, .disable, .mask, .unmask => unreachable,
    };
    const m = try call(bus, method.ptr, "ss", .{ unit.ptr, "replace" }, diags) orelse return false;
    defer _ = c.sd_bus_message_unref(m);
    var job: [*c]const u8 = null;
    if (c.sd_bus_message_read(m, "o", &job) < 0) return badReply(diags, method);
    const waited = jobs.wait(bus, std.mem.span(job)) catch |e| switch (e) {
        error.BusFailed => {
            try diags.add(.systemd_failed, null, "lost touch with systemd while waiting to {s} {s}", .{ @tagName(v), unit }, null);
            return false;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    const result = waited orelse {
        try diags.add(.systemd_failed, null, "{s} didn't {s} within 90 seconds", .{ unit, @tagName(v) }, null);
        return false;
    };
    if (std.mem.eql(u8, result, "done")) return true;
    try diags.add(.systemd_failed, null, "{s} of {s} ended with \"{s}\"", .{ @tagName(v), unit, result }, try std.fmt.allocPrint(a, "journalctl -u {s} says why", .{unit}));
    return false;
}

/// finished jobs, from JobRemoved (uoss: id, job path, unit, result).
const Jobs = struct {
    a: Allocator,
    done: std.StringHashMapUnmanaged([]const u8) = .empty,
    out_of_memory: bool = false,

    fn removed(m: ?*c.sd_bus_message, userdata: ?*anyopaque, _: [*c]c.sd_bus_error) callconv(.c) c_int {
        const j: *Jobs = @ptrCast(@alignCast(userdata));
        var id: u32 = 0;
        var path: [*c]const u8 = null;
        var unit: [*c]const u8 = null;
        var result: [*c]const u8 = null;
        if (c.sd_bus_message_read(m, "uoss", &id, &path, &unit, &result) < 0) return 0;
        const k = j.a.dupe(u8, std.mem.span(path)) catch return failed(j);
        const v = j.a.dupe(u8, std.mem.span(result)) catch return failed(j);
        j.done.put(j.a, k, v) catch return failed(j);
        return 0;
    }

    fn failed(j: *Jobs) c_int {
        j.out_of_memory = true;
        return 0;
    }

    /// the job's result, or null if it didn't finish in time.
    /// the wait is by the clock: every other signal systemd sends wakes
    /// sd_bus_wait early.
    fn wait(j: *Jobs, bus: *c.sd_bus, path: []const u8) error{ OutOfMemory, BusFailed }!?[]const u8 {
        const deadline = monotonicSeconds() + 90;
        while (true) {
            if (j.out_of_memory) return error.OutOfMemory;
            if (j.done.get(path)) |r| return r;
            const r = c.sd_bus_process(bus, null);
            if (r > 0) continue;
            if (r < 0) return error.BusFailed;
            if (monotonicSeconds() >= deadline) return null;
            _ = c.sd_bus_wait(bus, std.time.us_per_s);
        }
    }

    fn monotonicSeconds() i64 {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return ts.sec;
    }
};

/// enablement from ListUnitFiles: a(ss) of unit path and state.
fn unitFiles(a: Allocator, bus: *c.sd_bus, found: *Found, diags: *diag.List) !bool {
    const m = try call(bus, "ListUnitFiles", null, .{}, diags) orelse return false;
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
        const u = try entry(a, found, name);
        u.enabled = api.enabledState(std.mem.span(state));
        u.fixed = api.fixedState(std.mem.span(state));
        u.static = std.mem.eql(u8, std.mem.span(state), "static");
        u.masked = api.maskedState(std.mem.span(state));
    }
    return true;
}

/// run state from ListUnits: a(ssssssouso), of which the first and fourth,
/// the name and active state, matter here.
fn loadedUnits(a: Allocator, bus: *c.sd_bus, found: *Found, diags: *diag.List) !bool {
    const m = try call(bus, "ListUnits", null, .{}, diags) orelse return false;
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
        if (!u.active and !u.failed) u.skipped = conditionFailed(bus, s[6]);
        if (std.mem.endsWith(u8, name, ".service")) {
            if (u.active) u.main_pid = mainPid(bus, s[6]) else u.ran = oneshotRan(bus, s[6]);
        }
    }
    return true;
}

/// whether an inactive service is a oneshot whose last run succeeded.
fn oneshotRan(bus: *c.sd_bus, path: [*c]const u8) bool {
    return serviceProperty(bus, path, "Type", "oneshot") and serviceProperty(bus, path, "Result", "success");
}

/// whether systemd last left the unit stopped because a Condition*= of
/// its didn't hold, like bluetooth.service on a machine with no adapter.
/// ConditionResult is false too for a unit never started, so its
/// timestamp has to be set.
fn conditionFailed(bus: *c.sd_bus, path: [*c]const u8) bool {
    var err: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
    defer c.sd_bus_error_free(&err);
    var checked: u64 = 0;
    if (c.sd_bus_get_property_trivial(bus, destination, path, unit_iface, "ConditionTimestampMonotonic", &err, 't', &checked) < 0 or checked == 0) return false;
    var result: c_int = 1;
    if (c.sd_bus_get_property_trivial(bus, destination, path, unit_iface, "ConditionResult", &err, 'b', &result) < 0) return false;
    return result == 0;
}

fn serviceProperty(bus: *c.sd_bus, path: [*c]const u8, name: [*:0]const u8, want: []const u8) bool {
    var err: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
    defer c.sd_bus_error_free(&err);
    var value: [*c]u8 = null;
    if (c.sd_bus_get_property_string(bus, destination, path, service_iface, name, &err, &value) < 0) return false;
    defer std.c.free(value);
    return std.mem.eql(u8, std.mem.span(value), want);
}

/// a service's main process, or 0 if it has none or systemd won't say.
fn mainPid(bus: *c.sd_bus, path: [*c]const u8) u32 {
    var err: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
    defer c.sd_bus_error_free(&err);
    var pid: u32 = 0;
    if (c.sd_bus_get_property_trivial(bus, destination, path, service_iface, "MainPID", &err, 'u', &pid) < 0) return 0;
    return pid;
}

fn badReply(diags: *diag.List, method: []const u8) !bool {
    try diags.add(.systemd_failed, null, "couldn't read systemd's {s} reply", .{method}, null);
    return false;
}
