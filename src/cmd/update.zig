//! `os update`: resolve the config against arch's package databases and
//! write machine.lock.

const std = @import("std");
const cli = @import("../cli.zig");
const alpm = @import("../alpm.zig");
const config = @import("../config.zig");
const lock = @import("../lock.zig");
const output = @import("../output.zig");
const planner = @import("../planner.zig");
const sort = @import("../sort.zig");
const Context = cli.Context;
const eql = cli.eql;
const Allocator = std.mem.Allocator;

pub fn updateCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    const usage_text = "os update --dbs <dir> [--date yyyy-mm-dd]";
    var dbs_dir: ?[]const u8 = null;
    var date: ?[]const u8 = null;
    var it: cli.ArgIter = .{ .args = args };
    while (it.next()) |a| {
        if (eql(a, "--dbs")) {
            dbs_dir = it.next() orelse return cli.usageError(ctx, usage_text);
        } else if (eql(a, "--date")) {
            date = it.next() orelse return cli.usageError(ctx, usage_text);
        } else return cli.usageError(ctx, usage_text);
    }
    if (!alpm.available) {
        try ctx.err.writeAll("os: this build can't resolve packages. build with -Dalpm.\n");
        return 1;
    }
    const dir = dbs_dir orelse {
        try ctx.err.writeAll("os: downloading package databases isn't built yet. pass --dbs <dir> with core.db and friends.\n");
        return 1;
    };

    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const loaded = try w.config() orelse return w.report();
    const dbs = try syncDbs(ctx, a, dir) orelse return 1;
    const scratch = try std.fmt.allocPrint(a, "/tmp/os-resolve-{d}", .{std.Io.Timestamp.now(ctx.io, .real).toNanoseconds()});
    defer std.Io.Dir.cwd().deleteTree(ctx.io, scratch) catch {};

    var in = try resolveInput(a, &loaded.config);
    in.dbs = dbs;
    in.sync_date = date orelse try today(ctx.io, a);
    in.scratch = scratch;
    const l = try alpm.resolve(a, ctx.io, in, &w.diags) orelse return w.report();

    var out: std.Io.Writer.Allocating = .init(a);
    try lock.write(&out.writer, &l);
    const lock_path = try std.fs.path.join(a, &.{ std.fs.path.dirnamePosix(loaded.files.items[0]) orelse ".", "machine.lock" });
    ctx.files.write(lock_path, out.written()) catch {
        try ctx.err.print("os: can't write {s}\n", .{lock_path});
        return 1;
    };
    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.update/1", .{ .lock = lock_path, .sync_date = l.sync_date, .packages = l.packages.len });
    } else {
        try ctx.out.print("resolved {d} packages as of {s} into {s}.\n", .{ l.packages.len, l.sync_date, lock_path });
    }
    return 0;
}

/// what the config asks the resolver for: its wanted packages and provider
/// choices. the caller fills in the databases, date, and scratch space.
fn resolveInput(a: Allocator, c: *const config.Config) !alpm.ResolveInput {
    const ws = try planner.wants(a, c);
    const names = try a.alloc([]const u8, ws.len);
    for (ws, names) |w, *n| n.* = w.name;
    const providers = try a.alloc(lock.Provider, c.providers.entries.items.len);
    for (c.providers.entries.items, providers) |e, *p| p.* = .{ .name = e.name, .chosen = e.value.v };
    return .{ .dbs = &.{}, .wants = names, .providers = providers, .sync_date = "", .scratch = "" };
}

/// arch's repositories in the order pacman.conf lists them. others follow
/// by name.
const repo_order = [_][]const u8{ "core-testing", "core", "extra-testing", "extra", "multilib-testing", "multilib" };

fn repoRank(name: []const u8) usize {
    for (repo_order, 0..) |r, i| {
        if (eql(r, name)) return i;
    }
    return repo_order.len;
}

/// every `<repo>.db` file in `dir`, in pacman's repository order.
fn syncDbs(ctx: *Context, a: Allocator, dir: []const u8) !?[]const alpm.SyncDb {
    var d = std.Io.Dir.cwd().openDir(ctx.io, dir, .{ .iterate = true }) catch {
        try ctx.err.print("os: can't open {s}\n", .{dir});
        return null;
    };
    defer d.close(ctx.io);
    var dbs: std.ArrayList(alpm.SyncDb) = .empty;
    var iter = d.iterate();
    while (try iter.next(ctx.io)) |e| {
        if (!std.mem.endsWith(u8, e.name, ".db")) continue;
        const name = try a.dupe(u8, e.name[0 .. e.name.len - 3]);
        try dbs.append(a, .{ .name = name, .path = try std.fmt.allocPrint(a, "{s}/{s}.db", .{ dir, name }) });
    }
    if (dbs.items.len == 0) {
        try ctx.err.print("os: no .db files in {s}\n", .{dir});
        return null;
    }
    sortRepos(dbs.items);
    return dbs.items;
}

fn sortRepos(dbs: []alpm.SyncDb) void {
    // by name first; the sort is stable, so repositories of equal rank
    // stay in name order.
    sort.byField(alpm.SyncDb, "name", dbs);
    std.mem.sort(alpm.SyncDb, dbs, {}, struct {
        fn lt(_: void, x: alpm.SyncDb, y: alpm.SyncDb) bool {
            return repoRank(x.name) < repoRank(y.name);
        }
    }.lt);
}

/// today's date as yyyy-mm-dd, in utc.
fn today(io: std.Io, a: Allocator) ![]const u8 {
    const secs: u64 = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());
    const day = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = day.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 });
}

// -- tests --

const TestRun = cli.TestRun;

test "repositories sort the way pacman.conf lists them" {
    var dbs = [_]alpm.SyncDb{
        .{ .name = "zeta", .path = "" },     .{ .name = "extra", .path = "" }, .{ .name = "alpha", .path = "" },
        .{ .name = "multilib", .path = "" }, .{ .name = "core", .path = "" },
    };
    sortRepos(&dbs);
    const want = [_][]const u8{ "core", "extra", "multilib", "alpha", "zeta" };
    for (want, dbs) |n, db| try std.testing.expectEqualStrings(n, db.name);
}

test "update resolves the fixture repos into a lock" {
    if (!alpm.available) return error.SkipZigTest;
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"git\"]\n");
    try t.exec(&.{ "update", "--dbs", "tests/alpm/repos", "--date", "2026-09-25" });
    try std.testing.expectEqualStrings("", t.err.buffered());
    try std.testing.expectEqual(0, t.code);
    const written = t.fs.get("/etc/yoq/machine.lock").?;
    try std.testing.expect(std.mem.indexOf(u8, written, "sync_date = \"2026-09-25\"\nkeyring = \"none\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "[packages.perl-error]") != null);

    // the new lock covers the config, so planning works.
    try t.fs.put("f.json", "{\"schema\":\"yoq.facts/1\"}");
    try t.exec(&.{ "plan", "--facts", "f.json" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expect(std.mem.indexOf(u8, t.out.buffered(), "+ git 2.51.0-1") != null);
}
