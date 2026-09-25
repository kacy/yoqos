//! `os apply`: make the machine match its config. it shows the plan, asks,
//! applies, and then plans again to check that nothing's left.

const std = @import("std");
const cli = @import("../cli.zig");
const alpm = @import("../alpm.zig");
const apply = @import("../apply.zig");
const lock = @import("../lock.zig");
const observe = @import("../observe.zig");
const output = @import("../output.zig");
const planner = @import("../planner.zig");
const sync = @import("../sync.zig");
const locking = @import("lock.zig");
const Context = cli.Context;
const Allocator = std.mem.Allocator;

pub fn applyCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    var yes = false;
    for (args) |arg| {
        if (cli.eql(arg, "--yes") or cli.eql(arg, "-y")) yes = true else return cli.usageError(ctx, "os apply [--yes]");
    }
    if (!alpm.available) {
        try ctx.err.writeAll("os: this build can't change packages. build with -Dalpm.\n");
        return 1;
    }
    if (cli.eql(ctx.root, "/") and std.os.linux.geteuid() != 0) {
        try ctx.err.writeAll("os: apply changes the machine, so it needs root.\n");
        return 1;
    }

    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const result = try w.plan(cli.inputs(ctx)) orelse return w.fail();
    const p = &result.plan;
    if (try apply.unfinished(a, ctx.io, ctx.root)) |hash| {
        try ctx.err.print("os: the last apply (plan {s}) didn't finish. this one starts from the machine as it is now.\n", .{hash[0..@min(12, hash.len)]});
    }
    if (p.empty()) {
        if (!ctx.json) try ctx.out.writeAll("nothing to do. this machine matches its config.\n");
        if (ctx.json) try output.writeDoc(ctx.out, "yoq.apply/1", .{ .applied = 0, .skipped = p.changes });
        return 0;
    }

    if (!ctx.json) try planner.writeText(ctx.out, a, p, .{});
    if (!yes) {
        if (!ctx.interactive) {
            try ctx.err.writeAll("os: pass --yes to apply without a terminal.\n");
            return 2;
        }
        try ctx.out.writeByte('\n');
        if (!try cli.confirm(ctx, "apply this?")) {
            try ctx.out.writeAll("nothing changed.\n");
            return 0;
        }
    }

    const target = try targetFor(ctx, &w, &result.state.lock) orelse return w.fail();
    const hash = try p.hash();
    const now = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    try apply.record(a, ctx.io, ctx.root, now, "begin", &hash);
    const done = try apply.run(a, ctx.io, p, &result.state.lock, target, &w.diags) orelse {
        try apply.record(a, ctx.io, ctx.root, now, "failed", &hash);
        return w.fail();
    };
    try apply.record(a, ctx.io, ctx.root, now, "done", &hash);
    return verify(ctx, p.changes.len - done.skipped.len, done.skipped);
}

/// plans again after applying. anything left besides what apply skipped
/// means something didn't take.
fn verify(ctx: *Context, applied: usize, skipped: []const planner.Change) !u8 {
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const result = try w.plan(cli.inputs(ctx)) orelse return w.fail();
    var left: std.ArrayList([]const u8) = .empty;
    for (result.plan.changes) |c| {
        if (apply.applies(c.kind)) try left.append(a, c.subject);
    }
    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.apply/1", .{ .applied = applied, .skipped = skipped, .left = left.items });
    } else {
        try ctx.out.print("\napplied {d} {s}.\n", .{ applied, if (applied == 1) "change" else "changes" });
        if (skipped.len > 0) {
            var names: std.ArrayList([]const u8) = .empty;
            for (skipped) |c| try names.append(a, c.subject);
            try ctx.out.print("not applied yet, since os can't change services or users yet: {s}.\n", .{try std.mem.join(a, ", ", names.items)});
        }
    }
    if (left.items.len == 0) return 0;
    if (!ctx.json) try ctx.err.print("os: applied, but these still differ from the config: {s}\n", .{try std.mem.join(a, ", ", left.items)});
    return 1;
}

/// the machine to change, and the package databases for the lock's own
/// date, with the servers packages come from.
fn targetFor(ctx: *Context, w: *cli.Work, l: *const lock.Lock) !?apply.Target {
    const a = w.allocator();
    const pc = try locking.pacman(ctx, a);
    const rs = pc.repos;
    const cache = try locking.cacheDir(ctx, a);
    const dbs = try sync.cached(a, ctx.io, rs, cache, l.sync_date) orelse blk: {
        // mirrors only serve today's databases.
        if (!cli.eql(l.sync_date, try locking.today(ctx.io, a))) {
            try w.diags.add(.lock_stale, null, "no package databases for {s} are cached here", .{l.sync_date}, "run `os update` to move the lock to today");
            return null;
        }
        break :blk try sync.databases(a, ctx.io, ctx.fetcher, rs, cache, l.sync_date, &w.diags) orelse return null;
    };
    return .{
        .root = ctx.root,
        .dbpath = try observe.pacmanDb(a, ctx.io, ctx.root),
        .dbs = try sync.withServers(a, dbs, rs),
        .cachedir = try cli.machinePath(ctx, a, "/var/cache/yoq/pkg"),
        .gpgdir = try keyring(ctx, a),
        .download_user = pc.download_user,
        .sandbox = pc.sandbox,
    };
}

/// pacman's keyring, to check package signatures. the running machine
/// always has its signatures checked. another root without a keyring, like
/// a test's, doesn't.
fn keyring(ctx: *Context, a: Allocator) !?[]const u8 {
    const dir = try cli.machinePath(ctx, a, "/etc/pacman.d/gnupg");
    if (cli.eql(ctx.root, "/")) return dir;
    std.Io.Dir.cwd().access(ctx.io, dir, .{}) catch return null;
    return dir;
}

// -- tests --

const TestRun = cli.TestRun;

test "apply installs, sets, and removes, and the plan comes back empty" {
    if (!alpm.available) return error.SkipZigTest;
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const here = buf[0..try std.process.currentPath(io, &buf)];
    const root = try std.fmt.allocPrintSentinel(a, "{s}/.zig-cache/tmp/{s}", .{ here, tmp.sub_path }, 0);
    const local = try std.fs.path.join(a, &.{ root, "var/lib/pacman/local" });
    try cwd.createDirPath(io, local);
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ local, "ALPM_DB_VERSION" }), .data = "9\n" });
    const cache = try std.fs.path.join(a, &.{ root, "var/cache/yoq/sync/2026-09-25" });
    try cwd.createDirPath(io, cache);
    for ([_][]const u8{ "core", "extra" }) |r| {
        const bytes = try cwd.readFileAlloc(io, try std.fmt.allocPrint(a, "tests/alpm/repos/{s}.db", .{r}), a, .limited(1 << 20));
        try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/{s}.db", .{ cache, r }), .data = bytes });
    }

    var t: TestRun = .{};
    defer t.deinit();
    const server = try std.fmt.allocPrint(a, "file://{s}/tests/alpm/repos/$repo", .{here});
    try t.fs.put(try std.fs.path.join(a, &.{ root, "etc/pacman.conf" }), try std.fmt.allocPrint(a, "[core]\nServer = {s}\n[extra]\nServer = {s}\n", .{ server, server }));
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"git\"]\n[boot]\nkernel = \"none\"\n[system]\nhostname = \"atlas\"\n");
    try t.exec(&.{ "--root", root, "update", "--dbs", try a.dupeZ(u8, cache), "--date", "2026-09-25" });
    try std.testing.expectEqual(0, t.code);

    try t.exec(&.{ "--root", root, "apply" });
    try std.testing.expectEqual(2, t.code);

    try t.exec(&.{ "--root", root, "apply", "--yes" });
    try std.testing.expectEqualStrings("", t.err.buffered());
    try std.testing.expectEqual(0, t.code);
    try std.testing.expect(std.mem.indexOf(u8, t.out.buffered(), "applied 8 changes.") != null);
    try cwd.access(io, try std.fs.path.join(a, &.{ root, "usr/share/doc/git/README" }), .{});
    const hostname = try cwd.readFileAlloc(io, try std.fs.path.join(a, &.{ root, "etc/hostname" }), a, .limited(64));
    try std.testing.expectEqualStrings("atlas\n", hostname);

    try t.exec(&.{ "--root", root, "plan" });
    try std.testing.expectEqualStrings("nothing to do. this machine matches its config.\n", t.out.buffered());

    // removing git orphans glibc and filesystem, which apply keeps until
    // [remove] names them.
    try t.exec(&.{ "--root", root, "remove", "git" });
    try std.testing.expectEqual(0, t.code);
    try t.exec(&.{ "--root", root, "apply", "--yes" });
    try std.testing.expectEqual(1, t.code);
    try std.testing.expect(std.mem.startsWith(u8, t.err.buffered(), "error[E0126]: applying would remove filesystem, glibc,"));
    try t.fs.put("/etc/yoq/machine.toml", "[boot]\nkernel = \"none\"\n[system]\nhostname = \"atlas\"\n[remove]\npackages = [\"filesystem\", \"glibc\"]\n");
    try t.exec(&.{ "--root", root, "apply", "--yes" });
    try std.testing.expectEqualStrings("", t.err.buffered());
    try t.exec(&.{ "--root", root, "plan" });
    try std.testing.expectEqualStrings("nothing to do. this machine matches its config.\n", t.out.buffered());
    cwd.access(io, try std.fs.path.join(a, &.{ root, "usr/share/doc/git/README" }), .{}) catch return;
    return error.TestUnexpectedResult;
}
