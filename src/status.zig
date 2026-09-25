//! `os status`: the plan boiled down to three answers. what matches the
//! config, what changed outside os, and what's failing.

const std = @import("std");
const lists = @import("lists.zig");
const config = @import("config.zig");
const lock = @import("lock.zig");
const facts = @import("facts.zig");
const planner = @import("planner.zig");
const output = @import("output.zig");
const Allocator = std.mem.Allocator;

pub const schema = "yoq.status/1";

/// warn when the lock is older than this, since pinning also holds back
/// security fixes.
pub const stale_days = 14;

pub const Status = struct {
    hostname: ?[]const u8,
    lock_date: []const u8,
    /// days between the lock's package date and when the facts were read.
    lock_age_days: ?i64,
    ok: struct { packages: usize, services: usize },
    changed: struct {
        /// explicitly installed, but nothing in the config asks for them.
        extra: []const []const u8,
        /// dependencies nothing needs any more.
        orphans: usize,
        /// in the lock but not installed.
        missing: []const []const u8,
        /// installed at a different version than the lock says.
        versions: []const []const u8,
        /// `[system]` values that differ.
        settings: []const []const u8,
        /// configured services not enabled or running as configured.
        units: []const []const u8,
        /// declared users that are missing or differ.
        users: []const []const u8,
    },
    /// configured services whose units failed.
    failing: []const []const u8,

    pub fn clean(s: *const Status) bool {
        const ch = s.changed;
        return ch.extra.len + ch.orphans + ch.missing.len + ch.versions.len + ch.settings.len + ch.units.len + ch.users.len + s.failing.len == 0;
    }
};

pub fn summarize(a: Allocator, c: *const config.Config, l: *const lock.Lock, f: *const facts.Facts, p: *const planner.Plan) !Status {
    var extra: std.ArrayList([]const u8) = .empty;
    var missing: std.ArrayList([]const u8) = .empty;
    var versions: std.ArrayList([]const u8) = .empty;
    var settings: std.ArrayList([]const u8) = .empty;
    var units: std.ArrayList([]const u8) = .empty;
    var users: std.ArrayList([]const u8) = .empty;
    var orphans: usize = 0;
    for (p.changes) |ch| switch (ch.kind) {
        .package, .dependency => switch (ch.op) {
            .remove => if (ch.kind == .package) try extra.append(a, ch.subject) else {
                orphans += 1;
            },
            .add => try missing.append(a, ch.subject),
            .change => if (!lists.contains(versions.items, ch.subject)) try versions.append(a, ch.subject),
        },
        // a package can differ in version and install reason at once; count
        // it once.
        .reason => if (!lists.contains(versions.items, ch.subject)) try versions.append(a, ch.subject),
        .setting => try settings.append(a, ch.subject),
        .unit => try units.append(a, ch.subject),
        .user => if (!lists.contains(users.items, ch.subject)) try users.append(a, ch.subject),
    };

    var failing: std.ArrayList([]const u8) = .empty;
    var services: usize = 0;
    for (c.services.entries.items) |e| {
        const unit = e.value.unitFor(e.name);
        if (f.unit(unit)) |u| {
            if (u.failed) {
                try failing.append(a, unit);
                continue;
            }
        }
        if (!lists.contains(units.items, unit)) services += 1;
    }

    const needed = (try planner.closure(a, l, try planner.wants(a, c))).count();
    return .{
        .hostname = f.hostname,
        .lock_date = l.sync_date,
        .lock_age_days = if (epochDay(l.sync_date)) |d| @divFloor(f.time, std.time.s_per_day) - d else null,
        .ok = .{ .packages = needed - missing.items.len - versions.items.len, .services = services },
        .changed = .{
            .extra = extra.items,
            .orphans = orphans,
            .missing = missing.items,
            .versions = versions.items,
            .settings = settings.items,
            .units = units.items,
            .users = users.items,
        },
        .failing = failing.items,
    };
}

/// days since 1970-01-01 for a "yyyy-mm-dd" date.
pub fn epochDay(date: []const u8) ?i64 {
    if (date.len != 10 or date[4] != '-' or date[7] != '-') return null;
    const y = std.fmt.parseInt(i64, date[0..4], 10) catch return null;
    const m = std.fmt.parseInt(i64, date[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, date[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > 31) return null;
    // days from civil, after howard hinnant's algorithm.
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn writeText(w: *std.Io.Writer, s: *const Status) !void {
    try w.print("{s} · lock from {s}", .{ s.hostname orelse "this machine", s.lock_date });
    if (s.lock_age_days) |d| {
        if (d <= 0) {
            try w.writeAll(" (today)");
        } else {
            try w.print(" ({d} {s} old)", .{ d, if (d == 1) "day" else "days" });
        }
        if (d > stale_days) try w.writeAll(": `os update` picks up security fixes");
    }
    try w.print("\n\nok        {d} packages", .{s.ok.packages});
    if (s.ok.services > 0) try w.print(", {d} services", .{s.ok.services});
    try w.writeByte('\n');

    const ch = s.changed;
    var rows: Rows = .{ .w = w };
    if (ch.extra.len > 0) try rows.list("installed but not in the config", ch.extra, "os adopt keeps them, os plan removes them");
    if (ch.missing.len > 0) try rows.count(ch.missing.len, .{ "isn't", "aren't" }, "installed yet", "os plan");
    if (ch.versions.len > 0) try rows.count(ch.versions.len, .{ "differs", "differ" }, "from the lock", "os plan");
    if (ch.orphans > 0) try rows.count(ch.orphans, .{ "is", "are" }, "no longer needed", "os plan");
    if (ch.settings.len > 0) try rows.list("settings differ", ch.settings, "os plan");
    if (ch.units.len > 0) try rows.list("services not as configured", ch.units, "os plan");
    if (ch.users.len > 0) try rows.list("users not as configured", ch.users, "os plan");
    if (rows.first) try w.writeAll("changed   none\n");

    try w.writeAll("failing   ");
    if (s.failing.len == 0) try w.writeAll("none") else try joined(w, s.failing);
    try w.writeByte('\n');
}

/// the "changed" rows: the label on the first one only, and the command
/// that deals with each at the end.
const Rows = struct {
    w: *std.Io.Writer,
    first: bool = true,

    fn start(r: *Rows) !void {
        try r.w.print("{s:<10}", .{if (r.first) "changed" else ""});
        r.first = false;
    }

    fn list(r: *Rows, what: []const u8, items: []const []const u8, next: []const u8) !void {
        try r.start();
        try r.w.print("{s}: ", .{what});
        try joined(r.w, items);
        try r.w.print("  -> {s}\n", .{next});
    }

    /// "1 package differs", "2 packages differ": `verb` is the singular
    /// and plural form.
    fn count(r: *Rows, n: usize, verb: [2][]const u8, what: []const u8, next: []const u8) !void {
        try r.start();
        const one = n == 1;
        try r.w.print("{d} {s} {s} {s}  -> {s}\n", .{ n, if (one) "package" else "packages", if (one) verb[0] else verb[1], what, next });
    }
};

fn joined(w: *std.Io.Writer, items: []const []const u8) !void {
    const shown = @min(items.len, 6);
    for (items[0..shown], 0..) |it, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(it);
    }
    if (items.len > shown) try w.print(" and {d} more", .{items.len - shown});
}

pub fn writeJson(w: *std.Io.Writer, s: *const Status) !void {
    try output.writeDoc(w, schema, s.*);
}

// -- tests --

const testing = std.testing;

test "epoch days" {
    try testing.expectEqual(0, epochDay("1970-01-01").?);
    try testing.expectEqual(20356, epochDay("2025-09-25").?);
    try testing.expectEqual(20721, epochDay("2026-09-25").?);
    try testing.expectEqual(null, epochDay("2026-13-01"));
    try testing.expectEqual(null, epochDay("soon"));
}

test "status text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s: Status = .{
        .hostname = "atlas",
        .lock_date = "2026-09-01",
        .lock_age_days = 24,
        .ok = .{ .packages = 400, .services = 2 },
        .changed = .{ .extra = &.{ "htop", "btop" }, .orphans = 0, .missing = &.{}, .versions = &.{"git"}, .settings = &.{}, .units = &.{}, .users = &.{} },
        .failing = &.{"tailscaled.service"},
    };
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try writeText(&out.writer, &s);
    try testing.expectEqualStrings(
        \\atlas · lock from 2026-09-01 (24 days old): `os update` picks up security fixes
        \\
        \\ok        400 packages, 2 services
        \\changed   installed but not in the config: htop, btop  -> os adopt keeps them, os plan removes them
        \\          1 package differs from the lock  -> os plan
        \\failing   tailscaled.service
        \\
    , out.written());
}

test "a package differing in version and reason counts once" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c: config.Config = .{};
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{
        .{ .name = "linux", .version = "2", .repo = "core", .sha256 = "a" ** 64 },
    } };
    var have = [_]facts.Package{.{ .name = "linux", .version = "1", .reason = .dependency }};
    const f: facts.Facts = .{ .packages = &have };
    var diags: @import("diag.zig").List = .init(testing.allocator);
    defer diags.deinit();
    const p = (try planner.plan(a, &c, &l, &f, &diags)).?;
    try testing.expectEqual(2, p.changes.len);
    const s = try summarize(a, &c, &l, &f, &p);
    try testing.expectEqual(1, s.changed.versions.len);
    try testing.expectEqual(0, s.ok.packages);
}
