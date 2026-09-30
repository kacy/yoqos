//! `os update`: resolve the config against arch's package databases, apply
//! the result, and write machine.lock once that worked. with --no-apply,
//! or no one to ask, it only writes the lock.

const std = @import("std");
const aur = @import("../aur.zig");
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
    const usage_text = "os update [--yes] [--trust-aur] [--no-apply] [-v] [--dbs <dir>] [--date yyyy-mm-dd]";
    var dbs_dir: ?[]const u8 = null;
    var date: ?[]const u8 = null;
    var then: applying.Then = .{ .apply = true };
    var verbose = false;
    var trust_aur = false;
    var it: cli.ArgIter = .{ .args = args };
    while (it.next()) |a| {
        if (then.flag(a)) {
            continue;
        } else if (eql(a, "--trust-aur")) {
            trust_aur = true;
        } else if (eql(a, "-v") or eql(a, "--verbose")) {
            verbose = true;
        } else if (eql(a, "--dbs")) {
            dbs_dir = it.next() orelse return cli.usageError(ctx, usage_text);
        } else if (eql(a, "--date")) {
            const d = it.next() orelse return cli.usageError(ctx, usage_text);
            if (!validDate(d)) return cli.usageError(ctx, usage_text);
            date = d;
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
    const old_lock = try locking.readLock(ctx, a, top);
    const old: ?*const lock.Lock = if (old_lock) |*o| o else null;
    // aur packages are built first, into the local repository resolution
    // reads.
    const recipes = try buildAur(ctx, &w, &loaded.config, old, trust_aur) orelse return 1;
    const dbs = if (dbs_dir) |dir|
        try syncDbs(ctx, a, dir) orelse return 1
    else
        try sync.databases(a, ctx.io, ctx.fetcher, try pastRepos(ctx, a, try locking.repos(ctx, a, &loaded.config), sync_date), try locking.cacheDir(ctx, a), sync_date, &w.diags) orelse return w.fail();

    var l = try locking.resolveLock(ctx, &w, &loaded.config, top, dbs, sync_date, &.{}) orelse return w.fail();
    try locking.pinRecipes(a, &l, recipes, old);
    const d = try lock.diff(a, old, &l);
    const now = then.applies(ctx);
    const posted = if (old) |o| try newsSince(ctx, a, o.sync_date, l.sync_date) else &.{};
    if (!ctx.json) {
        try locking.reportLock(ctx, try std.fmt.allocPrint(a, "resolved {d} packages as of {s}", .{ l.packages.len, l.sync_date }), d, !now);
        if (old) |o| try writeNews(ctx, o.sync_date, posted);
    }

    var outcome: applying.Outcome = .{ .code = 0, .matches = true };
    if (now) {
        // apply against the new lock first. machine.lock moves only once
        // the machine does, so saying no, or a failure, changes nothing.
        const pending = try cli.machinePath(ctx, a, "/var/lib/yoq/update.lock");
        _ = try locking.writeLockTo(ctx, a, pending, &l) orelse return w.fail();
        var in = cli.inputs(ctx);
        in.lock_path = pending;
        try ctx.out.writeByte('\n');
        outcome = try applying.run(ctx, then.yes, in, .{ .render = .{ .summary = true, .verbose = verbose } });
        if (!outcome.matches) return outcome.code;
    }

    const message = try std.fmt.allocPrint(a, "update packages to {s}", .{l.sync_date});
    const path = try locking.writeLock(ctx, a, top, &l) orelse return w.fail();
    try cli.record(ctx, a, top, message);
    // the generation comes after the commit, so it records the new lock.
    try applying.recordGeneration(ctx, outcome, message);
    if (ctx.json) try output.writeDoc(ctx.out, "yoq.update/1", .{ .lock = path, .sync_date = l.sync_date, .packages = l.packages.len, .diff = d, .news = posted });
    return outcome.code;
}

/// fetches every aur recipe the config lists, has each new or changed
/// one reviewed, and builds them, needs first. returns each built
/// package's recipe commit, or null after saying why it stopped.
fn buildAur(ctx: *Context, w: *cli.Work, c: *const config.Config, old: ?*const lock.Lock, trust: bool) !?locking.Recipes {
    const a = w.allocator();
    var out: locking.Recipes = .empty;
    if (c.aur.items.items.len == 0) return out;
    // builds need root, for the chroot; say so before fetching anything.
    if (try cli.refused(ctx, applying.blocker(ctx))) return null;
    const b: aur.Builder = .{ .a = a, .io = ctx.io, .dirs = try aur.Dirs.under(a, ctx.root), .url = ctx.aur_url };
    var infos: std.ArrayList(aur.SrcInfo) = .empty;
    for (c.aur.items.items) |it| {
        var why: []const u8 = "";
        const commit = try b.fetch(it.name, &why) orelse {
            try ctx.err.print("os: can't fetch {s}'s recipe: {s}\n", .{ it.name, why });
            return null;
        };
        const info = try b.srcInfo(it.name, commit) orelse {
            try ctx.err.print("os: {s}'s recipe has no .SRCINFO at {s}\n", .{ it.name, commit[0..@min(12, commit.len)] });
            return null;
        };
        // the build's paths come from pkgbase, so it has to be the recipe
        // that was fetched and reviewed.
        if (!eql(info.pkgbase, it.name)) {
            try ctx.err.print("os: {s}'s recipe says its pkgbase is {s}. os builds a recipe only under its own name.\n", .{ it.name, info.pkgbase });
            return null;
        }
        // a recipe is reviewed when it's new, or changed since the lock.
        const was = if (old) |o| if (o.package(it.name)) |p| p.recipe else null else null;
        if (was == null or !eql(was.?, commit)) {
            if (!try approve(ctx, a, b, it.name, was, commit, trust)) return null;
        }
        try infos.append(a, info);
    }
    var why: []const u8 = "";
    const order = try aur.buildOrder(a, infos.items, &why) orelse {
        try ctx.err.print("os: these aur packages need each other: {s}\n", .{why});
        return null;
    };
    for (order) |info| {
        if (!ctx.json) try ctx.out.print("building {s} {s}-{s} from the aur...\n", .{ info.pkgbase, info.pkgver, info.pkgrel });
        if (try b.build(info)) |problem| {
            try ctx.err.print("os: building {s} failed: {s}\n", .{ info.pkgbase, problem });
            return null;
        }
        for (info.pkgnames) |name| try out.put(a, name, info.commit);
    }
    return out;
}

/// shows what to review in `name`'s recipe and asks. a script passes
/// --trust-aur instead: --yes alone doesn't build an unreviewed recipe.
fn approve(ctx: *Context, a: Allocator, b: aur.Builder, name: []const u8, was: ?[]const u8, commit: []const u8, trust: bool) !bool {
    const what = if (was == null) "new" else "changed";
    if (trust) {
        if (!ctx.json) try ctx.out.print("{s}'s recipe is {s}; building it, as --trust-aur says.\n", .{ name, what });
        return true;
    }
    if (!ctx.interactive) {
        try ctx.err.print("os: {s}'s aur recipe is {s}. review it in a terminal, or pass --trust-aur to build it unreviewed.\n", .{ name, what });
        return false;
    }
    try ctx.out.print("\n{s}'s recipe is {s}. aur recipes run as code when they build, so read it first:\n\n{s}\n", .{ name, what, try b.review(name, was, commit) });
    if (try cli.confirm(ctx, try std.fmt.allocPrint(a, "build {s}?", .{name}))) return true;
    try ctx.out.writeAll("the machine is as it was.\n");
    return false;
}

/// `rs`, or for a --date before today, arch's own repositories as the arch
/// linux archive has them for that day: mirrors only have today's.
fn pastRepos(ctx: *Context, a: Allocator, rs: []const sync.Repo, date: []const u8) ![]const sync.Repo {
    if (eql(date, try locking.today(ctx.io, a))) return rs;
    return sync.archived(a, rs, date);
}

/// yyyy-mm-dd, the way sync dates are written.
fn validDate(d: []const u8) bool {
    if (d.len != 10 or d[4] != '-' or d[7] != '-') return false;
    for (d, 0..) |ch, i| {
        if (i != 4 and i != 7 and !std.ascii.isDigit(ch)) return false;
    }
    return true;
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
