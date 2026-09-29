//! `os diff <a> [<b>]`: what differs between two generations, generation
//! `b` against `a`, the newest if there's no `b`: packages added, removed,
//! and at other versions, from each one's own pacman database, and the
//! config between their commits.

const std = @import("std");
const cli = @import("../cli.zig");
const exec = @import("../exec.zig");
const generation = @import("../generation.zig");
const gens = @import("../gens.zig");
const lists = @import("../lists.zig");
const output = @import("../output.zig");
const Context = cli.Context;
const Allocator = std.mem.Allocator;

const usage_text = "os diff <generation> [<generation>]";

pub const Package = struct { name: []const u8, version: []const u8 };
pub const Changed = struct { name: []const u8, from: []const u8, to: []const u8 };

pub const Diff = struct {
    added: []const Package,
    removed: []const Package,
    changed: []const Changed,
};

pub fn diffCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (args.len < 1 or args.len > 2) return cli.usageError(ctx, usage_text);
    const from_n = std.fmt.parseInt(u32, args[0], 10) catch return cli.usageError(ctx, usage_text);
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const boot = try w.generations() orelse {
        try ctx.err.writeAll("os: this machine has no generations. `os enable-rollback` turns them on.\n");
        return 1;
    };
    const records = try gens.readRecords(a, ctx.io, "/var");
    if (records.len == 0) return cli.usageError(ctx, usage_text);
    const to_n = if (args.len == 2) std.fmt.parseInt(u32, args[1], 10) catch return cli.usageError(ctx, usage_text) else records[records.len - 1].n;
    const from = generation.find(records, from_n) orelse return noGeneration(ctx, from_n);
    const to = generation.find(records, to_n) orelse return noGeneration(ctx, to_n);
    if (std.os.linux.geteuid() != 0) {
        try ctx.err.writeAll("os: diff reads each generation's root, so it needs root.\n");
        return 1;
    }
    var why: []const u8 = "";
    const m = try gens.Machine.open(a, ctx.io, boot, &why) orelse {
        try ctx.err.print("os: {s}\n", .{why});
        return 1;
    };
    defer m.close();
    const d = try compare(a, try packagesOf(&m, from.n), try packagesOf(&m, to.n));
    const config = try configDiff(ctx, a, from, to);
    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.diff/1", .{ .from = from.n, .to = to.n, .added = d.added, .removed = d.removed, .changed = d.changed, .config = config });
        return 0;
    }
    try ctx.out.print("generation {d} ({s}) to {d} ({s})\n", .{ from.n, from.reason, to.n, to.reason });
    if (d.added.len + d.removed.len + d.changed.len == 0) try ctx.out.writeAll("\npackages  the same\n") else {
        try ctx.out.writeAll("\npackages\n");
        for (d.added) |p| try ctx.out.print("  + {s} {s}\n", .{ p.name, p.version });
        for (d.removed) |p| try ctx.out.print("  - {s} {s}\n", .{ p.name, p.version });
        for (d.changed) |c| try ctx.out.print("  ~ {s} {s} -> {s}\n", .{ c.name, c.from, c.to });
    }
    if (config) |text| {
        try ctx.out.writeAll(if (text.len == 0) "\nconfig    the same\n" else "\nconfig\n");
        if (text.len > 0) try ctx.out.writeAll(text);
    } else try ctx.out.writeAll("\nconfig    one of them has no commit recorded\n");
    return 0;
}

fn noGeneration(ctx: *Context, n: u32) !u8 {
    try ctx.err.print("os: there's no generation {d}. `os history` lists them.\n", .{n});
    return 1;
}

/// the packages in generation `n`'s record, from its pacman database's
/// directories, named like "linux-6.16.8.arch1-1".
fn packagesOf(m: *const gens.Machine, n: u32) ![]Package {
    const a = m.a;
    const local = try m.at(&.{ generation.gens_dir, try std.fmt.allocPrint(a, "{d}", .{n}), generation.pacman_db, "local" });
    var dir = std.Io.Dir.cwd().openDir(m.io, local, .{ .iterate = true }) catch return &.{};
    defer dir.close(m.io);
    var out: std.ArrayList(Package) = .empty;
    var it = dir.iterate();
    while (it.next(m.io) catch null) |e| {
        if (e.kind != .directory) continue;
        if (splitEntry(e.name)) |p| try out.append(a, .{ .name = try a.dupe(u8, p.name), .version = try a.dupe(u8, p.version) });
    }
    return out.items;
}

/// "linux-6.16.8.arch1-1" as linux and 6.16.8.arch1-1: the version is the
/// last two parts, pkgver and pkgrel.
fn splitEntry(entry: []const u8) ?Package {
    const rel = std.mem.lastIndexOfScalar(u8, entry, '-') orelse return null;
    const ver = std.mem.lastIndexOfScalar(u8, entry[0..rel], '-') orelse return null;
    if (ver == 0) return null;
    return .{ .name = entry[0..ver], .version = entry[ver + 1 ..] };
}

/// `to` against `from`, each list sorted by name.
pub fn compare(a: Allocator, from: []Package, to: []Package) !Diff {
    const byName = struct {
        fn lt(_: void, x: Package, y: Package) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt;
    std.mem.sort(Package, from, {}, byName);
    std.mem.sort(Package, to, {}, byName);
    var added: std.ArrayList(Package) = .empty;
    var removed: std.ArrayList(Package) = .empty;
    var changed: std.ArrayList(Changed) = .empty;
    for (to) |p| {
        const old = lists.find(from, "name", p.name) orelse {
            try added.append(a, p);
            continue;
        };
        if (!std.mem.eql(u8, old.version, p.version)) try changed.append(a, .{ .name = p.name, .from = old.version, .to = p.version });
    }
    for (from) |p| {
        if (lists.find(to, "name", p.name) == null) try removed.append(a, p);
    }
    return .{ .added = added.items, .removed = removed.items, .changed = changed.items };
}

/// the config between the two generations' commits, or null if one has
/// none recorded.
fn configDiff(ctx: *Context, a: Allocator, from: generation.Record, to: generation.Record) !?[]const u8 {
    const dir = to.config_dir orelse return null;
    const old = from.config_rev orelse return null;
    const new = to.config_rev orelse return null;
    return switch (try exec.output(a, ctx.io, &.{ "git", "-C", dir, "diff", "--no-color", old, new, "--", "." })) {
        .ok => |t| t,
        .failed => |w| try std.fmt.allocPrint(a, "  (git couldn't compare them: {s})\n", .{w}),
    };
}

test "packages between two generations" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var from = [_]Package{ .{ .name = "linux", .version = "6.16.7.arch1-1" }, .{ .name = "nano", .version = "8.2-1" }, .{ .name = "git", .version = "2.51.0-1" } };
    var to = [_]Package{ .{ .name = "linux", .version = "6.16.8.arch1-1" }, .{ .name = "tree", .version = "2.2.1-1" }, .{ .name = "git", .version = "2.51.0-1" } };
    const d = try compare(a, &from, &to);
    try std.testing.expectEqual(1, d.added.len);
    try std.testing.expectEqualStrings("tree", d.added[0].name);
    try std.testing.expectEqualStrings("nano", d.removed[0].name);
    try std.testing.expectEqualStrings("6.16.8.arch1-1", d.changed[0].to);
    const p = splitEntry("lib32-gcc-libs-15.2.1+r22+gc4e96a094636-1").?;
    try std.testing.expectEqualStrings("lib32-gcc-libs", p.name);
    try std.testing.expectEqualStrings("15.2.1+r22+gc4e96a094636-1", p.version);
}
