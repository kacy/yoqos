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
const catalog = @import("../catalog.zig");
const generation = @import("../generation.zig");
const gens = @import("../gens.zig");
const locking = @import("lock.zig");
const Context = cli.Context;
const Allocator = std.mem.Allocator;

pub fn applyCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    var yes = false;
    for (args) |arg| {
        if (isYes(arg)) yes = true else return cli.usageError(ctx, "os apply [--yes]");
    }
    if (try refused(ctx)) return 1;
    const done = try run(ctx, yes, cli.inputs(ctx), .{});
    try recordGeneration(ctx, done, "apply");
    return done.code;
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
    /// the machine runs generations and this run changed it, so the
    /// caller records a generation once its own commits are made.
    changed_generation: bool = false,
    /// the change needs a reboot, so its generation boots on trial.
    needs_reboot: bool = false,

    fn failed(w: *cli.Work) !Outcome {
        return .{ .code = try w.fail(), .matches = false };
    }
};

/// plans from `in`, shows the plan, asks unless `yes`, applies it, and
/// checks the result. the caller has checked `blocker`, and records a
/// generation afterwards with `recordGeneration`.
pub fn run(ctx: *Context, yes: bool, in: pipeline.Inputs, render: planner.RenderOptions) !Outcome {
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

    if (!ctx.json) try planner.writeText(ctx.out, a, p, render);
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
    try journal.record(a, ctx.io, ctx.root, journal.now(ctx.io), "begin", &hash);
    const files = try planner.desiredFiles(a, result.state.config(), &result.facts);
    const done = try apply.run(a, ctx.io, p, &result.state.lock, files, target, units, &w.diags) orelse {
        try journal.record(a, ctx.io, ctx.root, journal.now(ctx.io), "failed", &hash);
        return Outcome.failed(&w);
    };
    try journal.record(a, ctx.io, ctx.root, journal.now(ctx.io), "done", &hash);
    const code = try verify(ctx, in, p.changes.len - done.skipped.len, done.skipped, units);
    if (units and !ctx.json and changesPackages(p)) try offerRestarts(ctx, yes);
    return .{
        .code = code,
        .matches = true,
        .changed_generation = cli.eql(ctx.root, "/") and generation.running(result.facts.boot.root_subvol),
        .needs_reboot = (try p.rebootReasons(a)).len > 0,
    };
}

/// after a run that changed a machine with generations, and after the
/// caller's commits: the machine as it is becomes the next generation,
/// with the config's commit. the change is done either way, so a
/// generation that can't be recorded is a warning.
pub fn recordGeneration(ctx: *Context, done: Outcome, reason: []const u8) !void {
    if (!done.changed_generation) return;
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const f = try @import("../observe.zig").observe(a, ctx.io, .{ .packages = false, .units = false }, &w.diags);
    var why: []const u8 = "";
    const m = try gens.Machine.open(a, ctx.io, f.boot, &why) orelse {
        try ctx.err.print("os: applied, but not recorded as a generation: {s}\n", .{why});
        return;
    };
    defer m.close();
    if (try m.record(reason, std.Io.Timestamp.now(ctx.io, .real).toSeconds(), try configNow(ctx, a))) |problem| {
        try ctx.err.print("os: applied, but not recorded as a generation: {s}\n", .{problem});
        return;
    }
    if (!ctx.json) try ctx.out.writeAll("recorded as a new generation; the boot menu has it.\n");
    try collectOld(ctx, &m, generation.default_keep);
    if (done.needs_reboot) try armTrial(ctx, a, f.boot);
}

/// a generation that needs a reboot boots once on trial: the next boot
/// tries it, the default stays on the one before, and `os health` makes
/// it the default once it has come up healthy.
fn armTrial(ctx: *Context, a: Allocator, boot: @import("../facts.zig").Boot) !void {
    const records = try gens.readRecords(a, ctx.io, "/var");
    if (records.len < 2) return;
    const n = records[records.len - 1].n;
    const before = records[records.len - 2].n;
    if (try gens.setEnv(a, ctx.io, boot.esp.?, &.{
        "yoq_next=head",
        try std.fmt.allocPrint(a, "yoq_default=gen-{d}", .{before}),
        try std.fmt.allocPrint(a, "yoq_trial={d}", .{n}),
    })) |problem| {
        try ctx.err.print("os: couldn't set up the trial boot: {s}. the next boot runs generation {d} without a fallback.\n", .{ problem, n });
        return;
    }
    if (!ctx.json) try ctx.out.print("reboot to finish. the next boot tries generation {d} once; if it doesn't come up healthy, the machine goes back to generation {d}.\n", .{ n, before });
}

/// removes generations past the newest `keep`, besides the first and
/// pinned ones, and says which went.
pub fn collectOld(ctx: *Context, m: *const gens.Machine, keep: usize) !void {
    var removed: std.ArrayList(u32) = .empty;
    if (try m.collect(keep, &removed)) |problem| {
        try ctx.err.print("os: couldn't remove old generations: {s}\n", .{problem});
        return;
    }
    if (removed.items.len == 0 or ctx.json) return;
    try ctx.out.writeAll("removed old generations:");
    for (removed.items) |n| try ctx.out.print(" {d}", .{n});
    try ctx.out.writeAll(". `os pin <n>` keeps one.\n");
}

/// the config directory and its newest commit, if it has history.
fn configNow(ctx: *Context, a: Allocator) !?generation.Config {
    const dir = std.fs.path.dirnamePosix(ctx.config_path) orelse return null;
    var why: []const u8 = "";
    const entries = try ctx.history.log(a, dir, &why) orelse return null;
    if (entries.len == 0) return null;
    return .{ .dir = dir, .rev = entries[entries.len - 1].rev };
}

fn changesPackages(p: *const planner.Plan) bool {
    for (p.changes) |c| {
        if (c.kind == .package or c.kind == .dependency) return true;
    }
    return false;
}

/// arch doesn't restart services after an upgrade. this finds the ones
/// still running replaced files and offers to restart them, or says how
/// when there's no one to ask.
fn offerRestarts(ctx: *Context, yes: bool) !void {
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const f = try cli.facts(&w) orelse return;
    var names: std.ArrayList([]const u8) = .empty;
    for (f.units) |u| {
        if (u.stale and catalog.restartable(u.name)) try names.append(a, u.name);
    }
    if (names.items.len == 0) return;
    const list = try std.mem.join(a, " ", names.items);
    try ctx.out.print("\nthese services still run files the upgrade replaced: {s}\n", .{list});
    if (yes or !ctx.interactive or !try cli.confirm(ctx, "restart them now?")) {
        try ctx.out.print("restart them when it suits: systemctl restart {s}\n", .{list});
        return;
    }
    for (names.items) |n| {
        if (!try systemd.change(a, n, &.{.restart}, &w.diags)) {
            _ = try w.fail();
            return;
        }
    }
    try ctx.out.writeAll("restarted.\n");
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
