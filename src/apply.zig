//! carries out a plan on a machine: packages through a libalpm
//! transaction, `[system]` settings through their files, users through
//! shadow's tools, and units through systemd when it runs the machine.
//! without systemd, `run` hands the units back as skipped.
//!
//! every run is journaled: a line when it starts and one when it ends, so a
//! run that never finished shows up next time.

const std = @import("std");
const alpm = @import("alpm.zig");
const diag = @import("diag.zig");
const lock = @import("lock.zig");
const planner = @import("planner.zig");
const settings = @import("settings.zig");
const systemd = @import("systemd.zig");
const users = @import("users.zig");
const rootfs = @import("rootfs.zig");
const Allocator = std.mem.Allocator;

pub const Target = alpm.Target;

/// whether `run` changes this kind of thing. units need systemd running
/// the machine.
pub fn applies(k: planner.Kind, units: bool) bool {
    return k != .unit or units;
}

pub const Result = struct {
    /// changes that weren't applied: units without systemd.
    skipped: []const planner.Change,
};

/// the package side of a plan, as one transaction's worth of lists.
pub fn transaction(a: Allocator, p: *const planner.Plan, l: *const lock.Lock, t: Target) !alpm.Transaction {
    var install: std.ArrayList(lock.Package) = .empty;
    var remove: std.ArrayList([]const u8) = .empty;
    var explicit: std.ArrayList([]const u8) = .empty;
    var dependency: std.ArrayList([]const u8) = .empty;
    for (p.changes) |c| switch (c.kind) {
        .package, .dependency => switch (c.op) {
            .add, .change => {
                try install.append(a, l.package(c.subject).?.*);
                // libalpm installs every target as explicit; set it right.
                try (if (c.kind == .package) &explicit else &dependency).append(a, c.subject);
            },
            .remove => try remove.append(a, c.subject),
        },
        .reason => try (if (std.mem.eql(u8, c.to.?, "explicit")) &explicit else &dependency).append(a, c.subject),
        .setting, .unit, .user => {},
    };
    return .{
        .target = t,
        .install = install.items,
        .remove = remove.items,
        .explicit = explicit.items,
        .dependency = dependency.items,
    };
}

/// applies `p`, with units only when `units` says systemd runs the
/// machine. units going away stop before their packages are removed, and
/// new ones start after theirs are installed. returns null, with reasons
/// in `diags`, if a step failed; steps before it stay done.
pub fn run(a: Allocator, io: std.Io, p: *const planner.Plan, l: *const lock.Lock, t: Target, units: bool, diags: *diag.List) !?Result {
    var skipped: std.ArrayList(planner.Change) = .empty;
    for (p.changes) |c| {
        if (!applies(c.kind, units)) try skipped.append(a, c);
    }
    if (units and !try changeUnits(a, p, true, diags)) return null;
    const tx = try transaction(a, p, l, t);
    if (tx.install.len + tx.remove.len + tx.explicit.len + tx.dependency.len > 0) {
        if (!try alpm.transact(a, io, tx, diags)) return null;
    }
    for (p.changes) |c| {
        const ok = switch (c.kind) {
            .setting => try settings.apply(a, io, t.root, c.subject, c.to.?, diags),
            .user => try users.apply(a, io, t.root, c, diags),
            else => true,
        };
        if (!ok) return null;
    }
    if (units and !try changeUnits(a, p, false, diags)) return null;
    return .{ .skipped = skipped.items };
}

/// the unit changes that turn units off, or the ones that turn them on.
fn changeUnits(a: Allocator, p: *const planner.Plan, off: bool, diags: *diag.List) !bool {
    for (p.changes) |c| {
        if (c.kind != .unit or (c.op == .remove) != off) continue;
        if (!try systemd.change(a, c.subject, try systemd.parseVerbs(a, c.to.?), diags)) return false;
    }
    return true;
}

const journal = "var/lib/yoq/journal";

/// appends one line to the journal. a journal that can't be written
/// doesn't stop the apply.
pub fn record(a: Allocator, io: std.Io, root: []const u8, time: i64, event: []const u8, hash: []const u8) !void {
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    const line = try std.fmt.allocPrint(a, "{{\"time\":{d},\"event\":\"{s}\",\"plan\":\"{s}\"}}\n", .{ time, event, hash });
    fs.append(journal, line) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.WriteFailed => {},
    };
}

/// the plan hash of a run that started and never finished, if the last one
/// didn't.
pub fn unfinished(a: Allocator, io: std.Io, root: []const u8) !?[]const u8 {
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    const trimmed = std.mem.trimEnd(u8, try fs.read(journal), "\n");
    const last = trimmed[if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |i| i + 1 else 0..];
    const Line = struct { time: i64, event: []const u8, plan: []const u8 };
    const parsed = std.json.parseFromSliceLeaky(Line, a, last, .{}) catch return null;
    return if (std.mem.eql(u8, parsed.event, "begin")) parsed.plan else null;
}

// -- tests --

const testing = std.testing;
const helpers = @import("test_helpers.zig");

test "a plan becomes one transaction" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{
        helpers.lockPackage("git", "2", &.{"glibc"}),
        helpers.lockPackage("glibc", "2", &.{}),
        helpers.lockPackage("vim", "1", &.{}),
    } };
    const p: planner.Plan = .{ .changes = &.{
        .{ .op = .change, .kind = .package, .subject = "git", .from = "1", .to = "2" },
        .{ .op = .add, .kind = .dependency, .subject = "glibc", .to = "2" },
        .{ .op = .change, .kind = .reason, .subject = "vim", .from = "dependency", .to = "explicit" },
        .{ .op = .remove, .kind = .package, .subject = "nano", .from = "8" },
        .{ .op = .change, .kind = .setting, .subject = "system.hostname", .to = "atlas" },
        .{ .op = .add, .kind = .unit, .subject = "sshd.service", .to = "enable, start" },
    } };
    const tx = try transaction(a, &p, &l, .{ .root = "/", .dbpath = "/var/lib/pacman", .dbs = &.{}, .cachedir = "/c", .gpgdir = null });
    try testing.expectEqual(2, tx.install.len);
    try testing.expectEqualStrings("2", tx.install[0].version);
    try testing.expectEqualStrings("nano", tx.remove[0]);
    try testing.expectEqual(2, tx.explicit.len);
    try testing.expectEqualStrings("vim", tx.explicit[1]);
    try testing.expectEqualStrings("glibc", tx.dependency[0]);
}

test "the journal notices an unfinished run" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try testing.expectEqual(null, try unfinished(a, testing.io, root));
    try record(a, testing.io, root, 1, "begin", "abc");
    try testing.expectEqualStrings("abc", (try unfinished(a, testing.io, root)).?);
    try record(a, testing.io, root, 2, "done", "abc");
    try testing.expectEqual(null, try unfinished(a, testing.io, root));
}
