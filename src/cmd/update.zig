//! `yos update`: resolve the config against arch's package databases, apply
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
    const usage_text = "yos update [--yes] [--trust-aur] [--no-apply] [-v] [--dbs <dir>] [--date yyyy-mm-dd]";
    var dbs_dir: ?[]const u8 = null;
    var date: ?[]const u8 = null;
    var then: applying.Then = .{ .apply = true };
    var verbose = false;
    var trust_aur = false;
    var it: cli.ArgIter = .{ .args = args };
    while (it.next()) |arg| {
        if (!it.isFlag(arg)) {
            return cli.usageError(ctx, usage_text);
        } else if (then.flag(arg)) {
            continue;
        } else if (eql(arg, "--trust-aur")) {
            trust_aur = true;
        } else if (eql(arg, "-v") or eql(arg, "--verbose")) {
            verbose = true;
        } else if (eql(arg, "--dbs")) {
            dbs_dir = it.value() orelse return cli.usageError(ctx, usage_text);
        } else if (eql(arg, "--date")) {
            const d = it.value() orelse return cli.usageError(ctx, usage_text);
            if (!lock.validDate(d)) return cli.usageError(ctx, usage_text);
            date = d;
        } else return cli.usageError(ctx, usage_text);
    }
    if (!alpm.available) return cli.fail(ctx, "this build can't resolve packages. build with -Dalpm.", .{});
    if (try cli.refused(ctx, cli.lockForEdit(ctx))) return 1;

    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const loaded = try w.config() orelse return w.fail();
    const top = loaded.files.items[0];
    const sync_date = date orelse try locking.today(ctx.io, a);
    const old_lock = try locking.readLock(ctx, a, top);
    const old: ?*const lock.Lock = if (old_lock) |*o| o else null;
    if (date == null) {
        if (old) |o| if (try clockBehind(a, sync_date, o.sync_date)) |why| return cli.fail(ctx, "{s}", .{why});
    }
    const rs = try pastRepos(ctx, a, try locking.repos(ctx, a, &loaded.config), sync_date);
    const cache = try locking.cacheDir(ctx, a);
    // the databases without yos's aur repository, which may not exist yet:
    // aur recipes are checked against them before anything builds.
    const arch_dbs = if (dbs_dir) |dir|
        try syncDbs(ctx, a, dir) orelse return 1
    else
        try sync.databases(a, ctx.io, ctx.fetcher, try withoutLocal(a, rs), cache, sync_date, &w.diags) orelse return w.fail();
    // aur packages are built first, into the local repository resolution
    // reads.
    const recipes = try buildAur(ctx, &w, &loaded.config, old, rs, arch_dbs, trust_aur) orelse return w.fail();
    const dbs = if (dbs_dir != null)
        arch_dbs
    else
        try sync.databases(a, ctx.io, ctx.fetcher, rs, cache, sync_date, &w.diags) orelse return w.fail();

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
        const pending = try cli.machinePath(ctx, a, "/var/lib/yos/update.lock");
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
    const code = try applying.recordGeneration(ctx, outcome, message);
    if (ctx.json) try output.writeDoc(ctx.out, "yos.update/1", .{ .lock = path, .sync_date = l.sync_date, .packages = l.packages.len, .diff = d, .news = posted });
    return code;
}

/// fetches every aur recipe the config lists, has each new or changed
/// one reviewed, and builds them, needs first. returns each built
/// package's recipe commit, or null after saying why it stopped. builds
/// get their arch packages from `rs`, the repositories the new lock
/// resolves against, as of its date, and `dbs` are arch's databases for
/// that date.
fn buildAur(ctx: *Context, w: *cli.Work, c: *const config.Config, old: ?*const lock.Lock, rs: []const sync.Repo, dbs: []const alpm.SyncDb, trust: bool) !?locking.Recipes {
    const a = w.allocator();
    var out: locking.Recipes = .empty;
    if (c.aur.items.items.len == 0) return out;
    // builds need root, for the chroot; say so before fetching anything.
    if (try cli.refused(ctx, applying.blocker(ctx))) return null;
    const b: aur.Builder = .{ .a = a, .io = ctx.io, .dirs = try aur.Dirs.under(a, ctx.root), .url = ctx.aur_url, .pacman_conf = try aur.chrootPacmanConf(a, rs) };
    var infos: std.ArrayList(aur.SrcInfo) = .empty;
    for (c.aur.items.items) |pkg| {
        var why: []const u8 = "";
        const commit = try b.fetch(pkg.name, &why) orelse {
            try ctx.err.print("yos: can't fetch {s}'s recipe: {s}\n", .{ pkg.name, why });
            return null;
        };
        const info = try b.srcInfo(pkg.name, commit) orelse {
            try ctx.err.print("yos: {s}'s recipe has no .SRCINFO at {s}\n", .{ pkg.name, commit[0..@min(12, commit.len)] });
            return null;
        };
        if (try aur.nameProblem(a, pkg.name, info)) |problem| {
            try ctx.err.print("yos: {s}\n", .{problem});
            return null;
        }
        try infos.append(a, info);
    }
    // before anyone reads a recipe: one that can't build or install
    // without an aur package the config leaves out stops here, by name.
    if (!try checkNeeds(ctx, w, infos.items, dbs)) return null;
    for (infos.items) |info| {
        // a recipe is reviewed when it's new, or changed since the lock.
        const was = if (old) |o| if (o.package(info.pkgbase)) |p| p.recipe else null else null;
        if (was == null or !eql(was.?, info.commit)) {
            if (!try reviewRecipe(ctx, a, b, info.pkgbase, was, info.commit, trust)) return null;
        }
    }
    var why: []const u8 = "";
    const order = try aur.buildOrder(a, infos.items, &why) orelse {
        try ctx.err.print("yos: these aur packages need each other: {s}\n", .{why});
        return null;
    };
    for (order) |info| {
        if (!ctx.json) try ctx.out.print("building {s} {s}-{s} from the aur...\n", .{ info.pkgbase, info.pkgver, info.pkgrel });
        if (try b.build(info, try aur.aurNeeds(a, infos.items, info))) |problem| {
            try ctx.err.print("yos: building {s} failed: {s}\n", .{ info.pkgbase, problem });
            return null;
        }
        try out.put(a, info.pkgbase, info.commit);
    }
    return out;
}

/// whether everything `recipes` need is in `dbs` or among them. what
/// isn't goes to `w.diags`.
fn checkNeeds(ctx: *Context, w: *cli.Work, recipes: []const aur.SrcInfo, dbs: []const alpm.SyncDb) !bool {
    const a = w.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    for (recipes) |r| {
        for (r.needs) |n| {
            if (!lists.contains(names.items, n)) try names.append(a, n);
        }
    }
    const unresolvable = try locking.unsatisfied(ctx, w, dbs, names.items) orelse return false;
    const missing = try aur.missingNeeds(a, recipes, unresolvable);
    for (missing) |m| {
        if (m.split_from) |base| {
            try w.diags.addHint(.aur_missing, null, "{s} needs {s}, which {s}'s recipe splits off", .{ m.by, m.need, base }, "yos installs only the package named after a recipe, so it can't build {s} yet", .{m.by});
        } else {
            try w.diags.addHint(.aur_missing, null, "{s} needs {s}, which isn't in the arch repositories or in `aur`", .{ m.by, m.need }, "if it's on the aur, add it: yos add --aur {s}", .{m.need});
        }
    }
    return missing.len == 0;
}

/// shows what to review in `name`'s recipe and asks. a script passes
/// --trust-aur instead: --yes alone doesn't build an unreviewed recipe.
fn reviewRecipe(ctx: *Context, a: Allocator, b: aur.Builder, name: []const u8, was: ?[]const u8, commit: []const u8, trust: bool) !bool {
    const what = if (was == null) "new" else "changed";
    if (trust) {
        if (!ctx.json) try ctx.out.print("{s}'s recipe is {s}; building it, as --trust-aur says.\n", .{ name, what });
        return true;
    }
    if (!ctx.interactive) {
        try ctx.err.print("yos: {s}'s aur recipe is {s}. review it in a terminal, or pass --trust-aur to build it unreviewed.\n", .{ name, what });
        return false;
    }
    try ctx.out.print("\n{s}'s recipe is {s}. aur recipes run as code when they build, so read it first:\n\n{s}\n", .{ name, what, try b.review(name, was, commit) });
    if (try cli.confirm(ctx, try std.fmt.allocPrint(a, "build {s}?", .{name}))) return true;
    try ctx.out.writeAll("the machine is as it was.\n");
    return false;
}

/// what to say when today, by the clock, is before `locked`, the lock's
/// date: a clock reset to an old date, like a dead cmos battery's, before
/// ntp sets it. the new lock would be dated then, and only `yos update`
/// moves the date, which should only go forward. null when it's fine.
fn clockBehind(a: Allocator, today: []const u8, locked: []const u8) !?[]const u8 {
    if (!std.mem.lessThan(u8, today, locked)) return null;
    return try std.fmt.allocPrint(a, "the clock says it's {s}, before the lock's date, {s}, so nothing changed. set the clock, or if it's right and the lock's date isn't, `yos update --date {s}` resolves as of today", .{ today, locked, today });
}

/// `rs`, or for a --date before today, arch's own repositories as the arch
/// linux archive has them for that day: mirrors only have today's.
fn pastRepos(ctx: *Context, a: Allocator, rs: []const sync.Repo, date: []const u8) ![]const sync.Repo {
    if (eql(date, try locking.today(ctx.io, a))) return rs;
    return sync.archived(a, rs, date);
}

fn withoutLocal(a: Allocator, rs: []const sync.Repo) ![]const sync.Repo {
    var out: std.ArrayList(sync.Repo) = .empty;
    for (rs) |r| {
        if (!r.local) try out.append(a, r);
    }
    return out.items;
}

/// arch news posted from the old lock's date, up to the new one. a feed
/// that can't be fetched is worth a warning, not a failed update.
fn newsSince(ctx: *Context, a: Allocator, old: []const u8, new: []const u8) ![]const news.Item {
    if (!std.mem.lessThan(u8, old, new)) return &.{};
    const xml = try ctx.fetcher.fetch(a, news.feed_url) orelse {
        try ctx.err.writeAll("yos: couldn't fetch arch news. read https://archlinux.org/news/ before applying.\n");
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
        try ctx.err.print("yos: can't open {s}\n", .{dir});
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
        try ctx.err.print("yos: no .db files in {s}\n", .{dir});
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

test "a clock behind the lock's date stops an update" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(null, try clockBehind(a, "2026-09-25", "2026-09-25"));
    try std.testing.expectEqual(null, try clockBehind(a, "2026-10-02", "2026-09-25"));
    try std.testing.expectEqualStrings(
        "the clock says it's 2000-01-01, before the lock's date, 2026-09-25, so nothing changed. set the clock, or if it's right and the lock's date isn't, `yos update --date 2000-01-01` resolves as of today",
        (try clockBehind(a, "2000-01-01", "2026-09-25")).?,
    );
}

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
    try t.fs.put("/etc/yos/machine.toml", "packages = [\"git\"]\n");
    try t.exec(&.{ "update", "--dbs", "tests/alpm/repos", "--date", "2026-09-25" });
    try std.testing.expectEqualStrings("", t.err.buffered());
    try std.testing.expectEqual(0, t.code);
    const written = t.fs.get("/etc/yos/machine.lock").?;
    try std.testing.expect(std.mem.indexOf(u8, written, "sync_date = \"2026-09-25\"\nkeyring = \"none\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "[packages.perl-error]") != null);

    // the new lock covers the config, so planning works.
    try t.fs.put("f.json", "{\"schema\":\"yos.facts/1\"}");
    try t.exec(&.{ "--facts", "f.json", "plan" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expect(std.mem.indexOf(u8, t.out.buffered(), "+ git 2.51.0-1") != null);
}

test "update asks for providers and saves the answer" {
    if (!alpm.available) return error.SkipZigTest;
    var t: TestRun = .{ .input = "x\n2\n" };
    defer t.deinit();
    try t.fs.put("/etc/yos/machine.toml", "packages = [\"jdk-tool\"]\n");
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
        \\resolved 8 packages as of 2026-09-25: +8. next: yos plan, then yos apply
        \\
    , t.out.buffered());
    try std.testing.expectEqualStrings("packages = [\"jdk-tool\"]\n\n[providers]\njava-runtime = \"jre17-openjdk\"\n", t.fs.get("/etc/yos/machine.toml").?);
    try std.testing.expect(std.mem.indexOf(u8, t.fs.get("/etc/yos/machine.lock").?, "[packages.jre17-openjdk]") != null);
}

test "update without a terminal says which choices to make" {
    if (!alpm.available) return error.SkipZigTest;
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yos/machine.toml", "packages = [\"jdk-tool\"]\n");
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
    try t.fs.put("/etc/yos/machine.toml", "packages = [\"git\"]\n");
    try t.fs.put(try std.fs.path.join(arena.allocator(), &.{ root, "etc/pacman.conf" }), "[options]\n[core]\nServer = https://mirror.example/$repo/os/$arch\n[extra]\nServer = https://mirror.example/$repo/os/$arch\n");
    try t.exec(&.{ "--root", root, "update", "--date", "2026-09-25" });
    try std.testing.expectEqualStrings("", t.err.buffered());
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqual(2, mirror.fetched);
    try std.testing.expect(std.mem.indexOf(u8, t.fs.get("/etc/yos/machine.lock").?, "[packages.perl-error]") != null);

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
