//! `os update`: resolve the config against arch's package databases, apply
//! the result, and write machine.lock once that worked. with --no-apply,
//! or no one to ask, it only writes the lock.

const std = @import("std");
const cli = @import("../cli.zig");
const alpm = @import("../alpm.zig");
const config = @import("../config.zig");
const lock = @import("../lock.zig");
const output = @import("../output.zig");
const lists = @import("../lists.zig");
const sync = @import("../sync.zig");
const locking = @import("lock.zig");
const applying = @import("apply.zig");
const news = @import("../news.zig");
const Context = cli.Context;
const eql = cli.eql;
const Allocator = std.mem.Allocator;

pub fn updateCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    const usage_text = "os update [--yes] [--no-apply] [-v] [--dbs <dir>] [--date yyyy-mm-dd]";
    var dbs_dir: ?[]const u8 = null;
    var date: ?[]const u8 = null;
    var then: applying.Then = .{ .apply = true };
    var verbose = false;
    var it: cli.ArgIter = .{ .args = args };
    while (it.next()) |a| {
        if (then.flag(a)) {
            continue;
        } else if (eql(a, "-v")) {
            verbose = true;
        } else if (eql(a, "--dbs")) {
            dbs_dir = it.next() orelse return cli.usageError(ctx, usage_text);
        } else if (eql(a, "--date")) {
            date = it.next() orelse return cli.usageError(ctx, usage_text);
        } else return cli.usageError(ctx, usage_text);
    }
    if (!alpm.available) {
        try ctx.err.writeAll("os: this build can't resolve packages. build with -Dalpm.\n");
        return 1;
    }

    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const loaded = try w.config() orelse return w.fail();
    const top = loaded.files.items[0];
    const sync_date = date orelse try locking.today(ctx.io, a);
    const dbs = if (dbs_dir) |dir|
        try syncDbs(ctx, a, dir) orelse return 1
    else
        try sync.databases(a, ctx.io, ctx.fetcher, try locking.repos(ctx, a), try locking.cacheDir(ctx, a), sync_date, &w.diags) orelse return w.fail();

    const old = try locking.readLock(ctx, a, top);
    const l = try locking.resolveLock(ctx, &w, &loaded.config, top, dbs, sync_date, &.{}) orelse return w.fail();
    const d = try lock.diff(a, if (old) |*o| o else null, &l);
    const now = then.applies(ctx);
    const posted = if (old) |o| try newsSince(ctx, a, o.sync_date, l.sync_date) else &.{};
    if (!ctx.json) {
        try locking.reportLock(ctx, try std.fmt.allocPrint(a, "resolved {d} packages as of {s}", .{ l.packages.len, l.sync_date }), d, !now);
        if (old) |o| try writeNews(ctx, o.sync_date, posted);
    }

    var code: u8 = 0;
    var outcome: applying.Outcome = .{ .code = 0, .matches = true };
    if (now) {
        // apply against the new lock first. machine.lock moves only once
        // the machine does, so saying no, or a failure, changes nothing.
        const pending = try cli.machinePath(ctx, a, "/var/lib/yoq/update.lock");
        _ = try locking.writeLockTo(ctx, a, pending, &l) orelse return w.fail();
        var in = cli.inputs(ctx);
        in.lock_path = pending;
        try ctx.out.writeByte('\n');
        const done = try applying.run(ctx, then.yes, in, .{ .summary = true, .verbose = verbose });
        if (!done.matches) return done.code;
        code = done.code;
        outcome = done;
    }

    const message = try std.fmt.allocPrint(a, "update packages to {s}", .{l.sync_date});
    const path = try locking.writeLock(ctx, a, top, &l) orelse return w.fail();
    try cli.record(ctx, a, top, message);
    // the generation comes after the commit, so it records the new lock.
    try applying.recordGeneration(ctx, outcome, message);
    if (ctx.json) try output.writeDoc(ctx.out, "yoq.update/1", .{ .lock = path, .sync_date = l.sync_date, .packages = l.packages.len, .diff = d, .news = posted });
    return code;
}

/// arch news posted after the old lock's date, up to the new one. a feed
/// that can't be fetched is worth a warning, not a failed update.
fn newsSince(ctx: *Context, a: Allocator, old: []const u8, new: []const u8) ![]const news.Item {
    if (!std.mem.lessThan(u8, old, new)) return &.{};
    const xml = try ctx.fetcher.fetch(a, news.feed_url) orelse {
        try ctx.err.writeAll("os: couldn't fetch arch news. read https://archlinux.org/news/ before applying.\n");
        return &.{};
    };
    return news.between(a, try news.parse(a, xml), old, new);
}

fn writeNews(ctx: *Context, since: []const u8, items: []const news.Item) !void {
    if (items.len == 0) return;
    try ctx.out.print("\narch news since {s}. read it before applying; some updates need a hand:\n", .{since});
    for (items) |it| try ctx.out.print("  {s}  {s}\n              {s}\n", .{ it.date, it.title, it.link });
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
    lists.sortByField(alpm.SyncDb, "name", dbs);
    std.mem.sort(alpm.SyncDb, dbs, {}, struct {
        fn lt(_: void, x: alpm.SyncDb, y: alpm.SyncDb) bool {
            return sync.repoRank(x.name) < sync.repoRank(y.name);
        }
    }.lt);
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
    try t.exec(&.{ "--facts", "f.json", "plan" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expect(std.mem.indexOf(u8, t.out.buffered(), "+ git 2.51.0-1") != null);
}

test "update asks for providers and saves the answer" {
    if (!alpm.available) return error.SkipZigTest;
    var t: TestRun = .{ .input = "x\n2\n" };
    defer t.deinit();
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"jdk-tool\"]\n");
    // --no-apply: this is about the question, not the machine running it.
    try t.exec(&.{ "update", "--no-apply", "--dbs", "tests/alpm/repos", "--date", "2026-09-25" });
    try std.testing.expectEqualStrings("", t.err.buffered());
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqualStrings(
        \\java-runtime has more than one provider:
        \\  1) jre-openjdk
        \\  2) jre17-openjdk
        \\pick one [1]: pick a number from 1 to 2.
        \\pick one [1]: + providers.java-runtime = "jre17-openjdk"
        \\resolved 8 packages as of 2026-09-25: +8. next: os plan, then os apply
        \\
    , t.out.buffered());
    try std.testing.expectEqualStrings("packages = [\"jdk-tool\"]\n\n[providers]\njava-runtime = \"jre17-openjdk\"\n", t.fs.get("/etc/yoq/machine.toml").?);
    try std.testing.expect(std.mem.indexOf(u8, t.fs.get("/etc/yoq/machine.lock").?, "[packages.jre17-openjdk]") != null);
}

test "update without a terminal says which choices to make" {
    if (!alpm.available) return error.SkipZigTest;
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"jdk-tool\"]\n");
    try t.exec(&.{ "update", "--dbs", "tests/alpm/repos" });
    try std.testing.expectEqual(1, t.code);
    try std.testing.expect(std.mem.startsWith(u8, t.err.buffered(), "error[E0123]: java-runtime has more than one provider: jre-openjdk, jre17-openjdk"));
}

test "update downloads the databases pacman.conf names, once per date" {
    if (!alpm.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try std.fmt.allocPrintSentinel(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);

    var mirror: cli.FixtureMirror = .{};
    var t: TestRun = .{ .fetcher = mirror.fetcher() };
    defer t.deinit();
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"git\"]\n");
    try t.fs.put(try std.fs.path.join(arena.allocator(), &.{ root, "etc/pacman.conf" }), "[options]\n[core]\nServer = https://mirror.example/$repo/os/$arch\n[extra]\nServer = https://mirror.example/$repo/os/$arch\n");
    try t.exec(&.{ "--root", root, "update", "--date", "2026-09-25" });
    try std.testing.expectEqualStrings("", t.err.buffered());
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqual(2, mirror.fetched);
    try std.testing.expect(std.mem.indexOf(u8, t.fs.get("/etc/yoq/machine.lock").?, "[packages.perl-error]") != null);

    try t.exec(&.{ "--root", root, "update", "--date", "2026-09-25" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqual(2, mirror.fetched);

    // the next day: two databases and the news, of which one item is new.
    try t.exec(&.{ "--root", root, "update", "--date", "2026-09-26" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqual(5, mirror.fetched);
    try std.testing.expect(std.mem.indexOf(u8, t.out.buffered(),
        \\arch news since 2026-09-25. read it before applying; some updates need a hand:
        \\  2026-09-26  Mkinitcpio >=42 requires manual intervention
        \\              https://archlinux.org/news/mkinitcpio-42/
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, t.out.buffered(), "before the lock") == null);
}
