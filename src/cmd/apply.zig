//! `os apply`: make the machine match its config. it shows the plan, asks,
//! applies, and then plans again to check that nothing's left.

const std = @import("std");
const cli = @import("../cli.zig");
const alpm = @import("../alpm.zig");
const apply = @import("../apply.zig");
const journal = @import("../journal.zig");
const lock = @import("../lock.zig");
const observe = @import("../observe.zig");
const output = @import("../output.zig");
const planner = @import("../planner.zig");
const pipeline = @import("../pipeline.zig");
const sync = @import("../sync.zig");
const systemd = @import("../systemd.zig");
const locking = @import("lock.zig");
const Context = cli.Context;
const Allocator = std.mem.Allocator;

pub fn applyCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    var yes = false;
    for (args) |arg| {
        if (isYes(arg)) yes = true else return cli.usageError(ctx, "os apply [--yes]");
    }
    if (try refused(ctx)) return 1;
    return (try run(ctx, yes, cli.inputs(ctx))).code;
}

pub fn isYes(arg: []const u8) bool {
    return cli.eql(arg, "--yes") or cli.eql(arg, "-y");
}

/// whether a command that changes the config or lock applies the change
/// after, from its `--yes` and `--no-apply` flags.
pub const Then = struct {
    apply: bool = false,
    yes: bool = false,

    /// takes `arg` if it's one of the flags.
    pub fn flag(t: *Then, arg: []const u8) bool {
        if (isYes(arg)) {
            t.yes = true;
        } else if (cli.eql(arg, "--no-apply")) {
            t.apply = false;
        } else return false;
        return true;
    }

    /// whether applying can follow here: it's wanted, someone can say yes
    /// to it, and the output stays one json document.
    pub fn applies(t: Then, ctx: *Context) bool {
        return t.apply and !ctx.json and (t.yes or ctx.interactive) and blocker(ctx) == null;
    }
};

/// why apply can't run here at all, if it can't.
pub fn blocker(ctx: *Context) ?[]const u8 {
    if (!alpm.available) return "this build can't change packages. build with -Dalpm";
    if (cli.eql(ctx.root, "/") and std.os.linux.geteuid() != 0) return "applying changes the machine, so it needs root";
    return null;
}

/// says why apply can't run here, for commands that only apply.
pub fn refused(ctx: *Context) !bool {
    const why = blocker(ctx) orelse return false;
    try ctx.err.print("os: {s}.\n", .{why});
    return true;
}

/// how a run went: its exit code, and whether the machine now matches
/// the plan's inputs, because the plan was empty or every step worked.
pub const Outcome = struct {
    code: u8,
    matches: bool,

    fn failed(w: *cli.Work) !Outcome {
        return .{ .code = try w.fail(), .matches = false };
    }
};

/// plans from `in`, shows the plan, asks unless `yes`, applies it, and
/// checks the result. the caller has checked `blocker`.
pub fn run(ctx: *Context, yes: bool, in: pipeline.Inputs) !Outcome {
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const result = try w.plan(in) orelse return Outcome.failed(&w);
    const p = &result.plan;
    if (try journal.unfinished(a, ctx.io, ctx.root)) |hash| {
        try ctx.err.print("os: the last apply (plan {s}) didn't finish. this one starts from the machine as it is now.\n", .{hash[0..@min(12, hash.len)]});
    }
    if (p.empty()) {
        if (!ctx.json) try ctx.out.writeAll("nothing to do. this machine matches its config.\n");
        if (ctx.json) try output.writeDoc(ctx.out, "yoq.apply/1", .{ .applied = 0, .skipped = p.changes });
        return .{ .code = 0, .matches = true };
    }

    if (!ctx.json) try planner.writeText(ctx.out, a, p, .{});
    if (!yes) {
        if (!ctx.interactive) {
            try ctx.err.writeAll("os: pass --yes to apply without a terminal.\n");
            return .{ .code = 2, .matches = false };
        }
        try ctx.out.writeByte('\n');
        if (!try cli.confirm(ctx, "apply this?")) {
            try ctx.out.writeAll("nothing changed.\n");
            return .{ .code = 0, .matches = false };
        }
    }

    const target = try targetFor(ctx, &w, &result.state.lock) orelse return Outcome.failed(&w);
    const units = liveUnits(ctx);
    const hash = try p.hash();
    const now = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    try journal.record(a, ctx.io, ctx.root, now, "begin", &hash);
    const files = try planner.desiredFiles(a, result.state.config());
    const done = try apply.run(a, ctx.io, p, &result.state.lock, files, target, units, &w.diags) orelse {
        try journal.record(a, ctx.io, ctx.root, now, "failed", &hash);
        return Outcome.failed(&w);
    };
    try journal.record(a, ctx.io, ctx.root, now, "done", &hash);
    return .{ .code = try verify(ctx, in, p.changes.len - done.skipped.len, done.skipped, units), .matches = true };
}

/// units change only on the running machine, and only when systemd runs
/// it: not under another --root, and not in a container.
fn liveUnits(ctx: *Context) bool {
    return systemd.available and cli.eql(ctx.root, "/") and systemd.running();
}

/// plans again after applying. anything left besides what apply skipped
/// means something didn't take.
fn verify(ctx: *Context, in: pipeline.Inputs, applied: usize, skipped: []const planner.Change, units: bool) !u8 {
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const result = try w.plan(in) orelse return w.fail();
    var left: std.ArrayList([]const u8) = .empty;
    for (result.plan.changes) |c| {
        if (apply.applies(c.kind, units)) try left.append(a, c.subject);
    }
    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.apply/1", .{ .applied = applied, .skipped = skipped, .left = left.items });
    } else {
        try ctx.out.print("\napplied {d} {s}.\n", .{ applied, if (applied == 1) "change" else "changes" });
        if (skipped.len > 0) {
            var names: std.ArrayList([]const u8) = .empty;
            for (skipped) |c| try names.append(a, c.subject);
            try ctx.out.print("services not changed, since systemd isn't running this machine: {s}.\n", .{try std.mem.join(a, ", ", names.items)});
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
    const m = try @import("../test_helpers.zig").FixtureMachine.init(a, tmp);
    const root = m.root;
    const cache = m.cache;

    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put(m.conf_path, m.conf);
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"git\"]\n[boot]\nkernel = \"none\"\n[system]\nhostname = \"atlas\"\n");
    try t.exec(&.{ "--root", root, "update", "--dbs", cache, "--date", "2026-09-25" });
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
    // `remove --yes` edits, relocks, and applies in one go.
    try t.exec(&.{ "--root", root, "remove", "--yes", "git" });
    try std.testing.expectEqual(1, t.code);
    try std.testing.expect(std.mem.startsWith(u8, t.err.buffered(), "error[E0126]: applying would remove filesystem, glibc,"));
    try t.fs.put("/etc/yoq/machine.toml", "[boot]\nkernel = \"none\"\n[system]\nhostname = \"atlas\"\n[remove]\npackages = [\"filesystem\", \"glibc\"]\n");
    try t.exec(&.{ "--root", root, "apply", "--yes" });
    try std.testing.expectEqualStrings("", t.err.buffered());
    try t.exec(&.{ "--root", root, "plan" });
    try std.testing.expectEqualStrings("nothing to do. this machine matches its config.\n", t.out.buffered());
    if (cwd.access(io, try std.fs.path.join(a, &.{ root, "usr/share/doc/git/README" }), .{})) |_| return error.TestUnexpectedResult else |_| {}

    // update applies before it writes the lock: saying no leaves the lock
    // as it was, and --yes moves both.
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"git\"]\n[boot]\nkernel = \"none\"\n[system]\nhostname = \"atlas\"\n");
    const update = [_][:0]const u8{ "--root", root, "update", "--dbs", cache, "--date", "2026-09-25" };
    t.input = "n\n";
    try t.exec(&update);
    try std.testing.expect(std.mem.indexOf(u8, t.out.buffered(), "nothing changed.") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.fs.get("/etc/yoq/machine.lock").?, "[packages.git]") == null);
    t.input = null;
    try t.exec(&(update ++ .{"--yes"}));
    try std.testing.expectEqualStrings("", t.err.buffered());
    try std.testing.expectEqual(0, t.code);
    try std.testing.expect(std.mem.indexOf(u8, t.fs.get("/etc/yoq/machine.lock").?, "[packages.git]") != null);
    try cwd.access(io, try std.fs.path.join(a, &.{ root, "usr/share/doc/git/README" }), .{});
}
