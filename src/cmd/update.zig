//! `os update`: resolve the config against arch's package databases and
//! write machine.lock.

const std = @import("std");
const cli = @import("../cli.zig");
const alpm = @import("../alpm.zig");
const config = @import("../config.zig");
const lock = @import("../lock.zig");
const change = @import("../change.zig");
const edit = @import("../edit.zig");
const output = @import("../output.zig");
const planner = @import("../planner.zig");
const sort = @import("../sort.zig");
const sync = @import("../sync.zig");
const Context = cli.Context;
const eql = cli.eql;
const Allocator = std.mem.Allocator;

pub fn updateCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    const usage_text = "os update [--dbs <dir>] [--date yyyy-mm-dd]";
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

    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const loaded = try w.config() orelse return w.report();
    const top = loaded.files.items[0];
    const sync_date = date orelse try today(ctx.io, a);
    const dbs = if (dbs_dir) |dir|
        try syncDbs(ctx, a, dir) orelse return 1
    else
        try sync.databases(a, ctx.io, ctx.fetcher, try repos(ctx, a), try cacheDir(ctx, a), sync_date, &w.diags) orelse return w.report();

    const old = try readLock(ctx, a, top);
    const l = try resolveLock(ctx, &w, &loaded.config, top, dbs, sync_date) orelse return w.report();
    const path = try writeLock(ctx, a, top, &l) orelse return 1;
    const d = try lock.diff(a, if (old) |*o| o else null, &l);
    try cli.record(ctx, a, top, try std.fmt.allocPrint(a, "update packages to {s}", .{l.sync_date}));
    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.update/1", .{ .lock = path, .sync_date = l.sync_date, .packages = l.packages.len, .diff = d });
        return 0;
    }
    try reportLock(ctx, try std.fmt.allocPrint(a, "resolved {d} packages as of {s}", .{ l.packages.len, l.sync_date }), d);
    return 0;
}

/// "<what>: +2 -1. applying isn't built yet; ..." after the lock changes.
pub fn reportLock(ctx: *Context, what: []const u8, d: lock.Diff) !void {
    try ctx.out.print("{s}: ", .{what});
    try d.write(ctx.out);
    try ctx.out.writeAll(". applying isn't built yet; `os plan` shows what would change.\n");
}

/// resolves the config into a lock against `dbs`, asking for provider
/// choices when someone is there to answer and saving them to `top`.
/// returns null, with reasons in `w.diags`, when it can't.
pub fn resolveLock(ctx: *Context, w: *cli.Work, c: *const config.Config, top: []const u8, dbs: []const alpm.SyncDb, sync_date: []const u8) !?lock.Lock {
    const a = w.allocator();
    const scratch = try std.fmt.allocPrint(a, "/tmp/os-resolve-{d}", .{std.Io.Timestamp.now(ctx.io, .real).toNanoseconds()});
    defer std.Io.Dir.cwd().deleteTree(ctx.io, scratch) catch {};

    var in = try resolveInput(a, c);
    in.dbs = dbs;
    in.sync_date = sync_date;
    in.scratch = scratch;

    // each round of choices can surface new ones, since a picked provider
    // brings its own dependencies.
    while (true) {
        const choices = switch (try alpm.resolve(a, ctx.io, in, &w.diags)) {
            .lock => |l| return l,
            .failed => return null,
            .choose => |choices| choices,
        };
        if (!ctx.interactive) {
            try alpm.reportChoices(a, choices, &w.diags);
            return null;
        }
        const picked = try askProviders(ctx, a, choices) orelse return null;
        if (!try saveProviders(ctx, w, top, picked)) return null;
        in.providers = try std.mem.concat(a, lock.Provider, &.{ in.providers, picked });
    }
}

/// machine.lock next to the top config file.
pub fn lockPath(a: Allocator, top: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ std.fs.path.dirnamePosix(top) orelse ".", "machine.lock" });
}

/// the current lock, or null if there isn't a readable one.
pub fn readLock(ctx: *Context, a: Allocator, top: []const u8) !?lock.Lock {
    const path = try lockPath(a, top);
    const bytes = ctx.files.read(a, path) catch return null;
    var ignored: @import("../diag.zig").List = .init(a);
    return lock.parse(a, path, bytes, &ignored);
}

/// writes `l` next to `top`. returns the path, or null after saying why.
pub fn writeLock(ctx: *Context, a: Allocator, top: []const u8, l: *const lock.Lock) !?[]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try lock.write(&out.writer, l);
    const path = try lockPath(a, top);
    ctx.files.write(path, out.written()) catch {
        try ctx.err.print("os: can't write {s}\n", .{path});
        return null;
    };
    return path;
}

fn askProviders(ctx: *Context, a: Allocator, choices: []const alpm.Choice) !?[]const lock.Provider {
    const picked = try a.alloc(lock.Provider, choices.len);
    for (choices, picked) |ch, *p| {
        const q = try std.fmt.allocPrint(a, "{s} has more than one provider:", .{ch.name});
        const i = try cli.choose(ctx, q, ch.options) orelse return null;
        p.* = .{ .name = ch.name, .chosen = ch.options[i] };
    }
    return picked;
}

/// writes provider picks into `[providers]` of the top config file, so the
/// question isn't asked again.
fn saveProviders(ctx: *Context, w: *cli.Work, top: []const u8, picked: []const lock.Provider) !bool {
    const a = w.allocator();
    var text: []const u8 = ctx.files.read(a, top) catch {
        try ctx.err.print("os: can't read {s}\n", .{top});
        return false;
    };
    const notes = try a.alloc(change.Note, picked.len);
    for (picked, notes) |p, *n| {
        text = try edit.setProvider(a, text, p.name, p.chosen) orelse text;
        n.* = .{ .name = p.name, .what = .chosen, .detail = p.chosen };
    }
    if (!try change.check(ctx.gpa, ctx.files, top, text, notes, &w.diags)) return false;
    ctx.files.write(top, text) catch {
        try ctx.err.print("os: can't write {s}\n", .{top});
        return false;
    };
    for (picked) |p| try ctx.out.print("+ providers.{s} = \"{s}\"\n", .{ p.name, p.chosen });
    return true;
}

/// the repositories in the machine's pacman.conf, or core and extra from
/// arch's main mirror if there isn't one.
pub fn repos(ctx: *Context, a: Allocator) ![]const sync.Repo {
    const conf = try readMachineFile(ctx, a, "/etc/pacman.conf") orelse return &.{
        .{ .name = "core", .servers = &.{} },
        .{ .name = "extra", .servers = &.{} },
    };
    return sync.repos(a, conf, ctx, readMachineFile);
}

/// where downloaded package databases are kept, one directory per date.
pub fn cacheDir(ctx: *Context, a: Allocator) ![]const u8 {
    return cli.machinePath(ctx, a, "/var/cache/yoq/sync");
}

fn readMachineFile(ptr: *anyopaque, a: Allocator, path: []const u8) error{OutOfMemory}!?[]const u8 {
    const ctx: *Context = @ptrCast(@alignCast(ptr));
    return ctx.files.read(a, try cli.machinePath(ctx, a, path)) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
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
pub fn today(io: std.Io, a: Allocator) ![]const u8 {
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

test "update asks for providers and saves the answer" {
    if (!alpm.available) return error.SkipZigTest;
    var t: TestRun = .{ .input = "x\n2\n" };
    defer t.deinit();
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"jdk-tool\"]\n");
    try t.exec(&.{ "update", "--dbs", "tests/alpm/repos", "--date", "2026-09-25" });
    try std.testing.expectEqualStrings("", t.err.buffered());
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqualStrings(
        \\java-runtime has more than one provider:
        \\  1) jre-openjdk
        \\  2) jre17-openjdk
        \\pick one [1]: pick a number from 1 to 2.
        \\pick one [1]: + providers.java-runtime = "jre17-openjdk"
        \\resolved 8 packages as of 2026-09-25: +8. applying isn't built yet; `os plan` shows what would change.
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
}
