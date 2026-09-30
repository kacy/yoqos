//! `os apply`: make the machine match its config. it shows the plan, asks,
//! applies, and then plans again to check that nothing's left.

const std = @import("std");
const rootfs = @import("../rootfs.zig");
const cli = @import("../cli.zig");
const config = @import("../config.zig");
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
const facts = @import("../facts.zig");
const generation = @import("../generation.zig");
const gens = @import("../gens.zig");
const accounts = @import("../accounts.zig");
const trial = @import("../trial.zig");
const stage = @import("stage.zig");
const locking = @import("lock.zig");
const diag = @import("../diag.zig");
const Context = cli.Context;
const Allocator = std.mem.Allocator;

pub fn applyCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    const usage_text = "os apply [<saved plan>] [--yes]";
    var yes = false;
    var saved: ?[]const u8 = null;
    for (args) |arg| {
        if (cli.isYes(arg)) {
            yes = true;
        } else if (saved == null and arg.len > 0 and arg[0] != '-') {
            saved = arg;
        } else return cli.usageError(ctx, usage_text);
    }
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const expect = if (saved) |path| try savedHash(ctx, w.allocator(), path) orelse return 1 else null;
    if (try cli.refused(ctx, applyBlocker(ctx))) return 1;
    const done = try run(ctx, yes, cli.inputs(ctx), .{ .expect = expect });
    try recordGeneration(ctx, done, "apply");
    return done.code;
}

/// the hash in a plan `os plan -o` saved, or null after saying why
/// there isn't one.
fn savedHash(ctx: *Context, a: Allocator, path: []const u8) !?[]const u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(64 << 20)) catch |e| {
        try ctx.err.print("os: can't read {s}: {s}\n", .{ path, @errorName(e) });
        return null;
    };
    const Saved = struct { schema: []const u8, hash: []const u8 };
    const doc = std.json.parseFromSliceLeaky(Saved, a, text, .{ .ignore_unknown_fields = true }) catch null;
    if (doc) |d| if (cli.eql(d.schema, planner.schema)) return d.hash;
    try ctx.err.print("os: {s} isn't a plan. `os plan -o <file>` saves one.\n", .{path});
    return null;
}

/// whether a command that changes the config or lock applies the change
/// after, from its `--yes` and `--no-apply` flags.
pub const Then = struct {
    apply: bool = false,
    yes: bool = false,

    /// takes `arg` if it's one of the flags.
    pub fn flag(t: *Then, arg: []const u8) bool {
        if (cli.isYes(arg)) {
            t.yes = true;
        } else if (cli.eql(arg, "--no-apply")) {
            t.apply = false;
        } else return false;
        return true;
    }

    /// whether applying can follow here: it's wanted, someone can say yes
    /// to it, and the output stays one json document.
    pub fn applies(t: Then, ctx: *Context) bool {
        return t.apply and !ctx.json and (t.yes or ctx.interactive) and applyBlocker(ctx) == null;
    }
};

/// why os can't change the machine here at all, if it can't.
pub fn blocker(ctx: *Context) ?[]const u8 {
    if (!alpm.available) return "this build can't change packages. build with -Dalpm";
    if (!cli.eql(ctx.root, "/")) return null;
    if (std.os.linux.geteuid() != 0) return "changing the machine needs root";
    return cli.lockMachine();
}

/// why apply can't run here, if it can't: `blocker`, or a boot into an
/// older generation's copy, which os remakes from its record.
fn applyBlocker(ctx: *Context) ?[]const u8 {
    if (blocker(ctx)) |why| return why;
    if (!cli.eql(ctx.root, "/")) return null;
    return bootBlocker(ctx.io);
}

/// why nothing should change the running machine in this boot, if
/// something shouldn't: it runs a menu copy of an older generation, or a
/// newer one is waiting for the next boot.
pub fn bootBlocker(io: std.Io) ?[]const u8 {
    return switch (bootState(io)) {
        .normal => null,
        .copy => "this boot runs a copy of an older generation from the boot menu, and os remakes that copy from its record. `os rollback --to-booted` keeps it as a generation of its own; reboot into that first",
        .pending => "a new generation is waiting for the next boot, and a change now would land on the root being left. reboot first, or `os rollback` to go back to the generation before it",
    };
}

/// how this boot stands with generations: running a menu copy of an
/// older one, or with a newer one waiting for the next boot.
fn bootState(io: std.Io) enum { normal, copy, pending } {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const subvol = (observe.rootSubvol(a, io) catch return .normal) orelse return .normal;
    if (generation.bootCopyOf(subvol) != null) return .copy;
    const next = (nextRoot(a, io) catch return .normal) orelse return .normal;
    return if (std.mem.eql(u8, next, subvol[1..])) .normal else .pending;
}

/// the root the next boot runs, like "@roots/2": the newest generation's,
/// or with none in this /var, the one enable-rollback noted. it moved /var
/// into a subvolume of its own and put generation 1's record there, so
/// until that boots, this /var only has the note.
pub fn nextRoot(a: Allocator, io: std.Io) !?[]const u8 {
    const records = try gens.readRecords(a, io, "/var");
    if (records.len > 0) return records[records.len - 1].root;
    const note = std.Io.Dir.cwd().readFileAlloc(io, generation.pending_path, a, .limited(256)) catch return null;
    return std.mem.trim(u8, note, " \n");
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
    /// the change went into this root, staged beside the running one, not
    /// into the running system. it's the generation to record.
    staged_root: ?[]const u8 = null,

    fn failed(w: *cli.Work) !Outcome {
        return .{ .code = try w.fail(), .matches = false };
    }
};

pub const RunOptions = struct {
    render: planner.RenderOptions = .{},
    /// the hash of a saved plan: the run applies that plan or nothing.
    expect: ?[]const u8 = null,
};

/// plans from `in`, shows the plan, asks unless `yes`, applies it, and
/// checks the result. the caller has checked `blocker`, and records a
/// generation afterwards with `recordGeneration`.
pub fn run(ctx: *Context, yes: bool, in: pipeline.Inputs, opts: RunOptions) !Outcome {
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const result = try w.plan(in) orelse return Outcome.failed(&w);
    const p = &result.plan;
    if (opts.expect) |want| {
        const got = try p.hash();
        if (!cli.eql(want, &got)) {
            try w.diags.add(.plan_changed, null, "this machine's plan isn't the saved one any more (saved {s}, now {s})", .{ want[0..@min(12, want.len)], got[0..12] }, "`os plan -o <file>` saves the plan as it is now");
            return Outcome.failed(&w);
        }
    }
    if (try journal.unfinished(a, ctx.io, ctx.root)) |hash| {
        try ctx.err.print("os: the last apply (plan {s}) didn't finish. this one starts from the machine as it is now.\n", .{hash[0..@min(12, hash.len)]});
    }
    if (p.empty()) {
        if (ctx.json) {
            try output.writeDoc(ctx.out, "yoq.apply/1", .{ .applied = 0, .skipped = p.changes });
        } else try ctx.out.writeAll("nothing to do. this machine matches its config.\n");
        return .{ .code = 0, .matches = true };
    }

    if (!ctx.json and !opts.render.quiet) try planner.writeText(ctx.out, a, p, opts.render);
    if (try cli.approve(ctx, yes, "apply", "apply this?")) |code| return .{ .code = code, .matches = false };

    const on_generations = cli.eql(ctx.root, "/") and generation.running(result.facts.boot.root_subvol);
    const needs_reboot = (try p.rebootReasons(a)).len > 0;
    // a change that needs a reboot, on a machine with generations, goes
    // into the next root instead of the running one.
    if (on_generations and needs_reboot) {
        const root = try stage.build(ctx, result.facts.boot, in) orelse return .{ .code = 1, .matches = false };
        return .{ .code = 0, .matches = true, .changed_generation = true, .needs_reboot = true, .staged_root = root };
    }

    const target = try targetFor(ctx, &w, result.state.config(), &result.state.lock) orelse return Outcome.failed(&w);
    const units = liveUnits(ctx);
    const hash = try p.hash();
    try journal.record(a, ctx.io, ctx.root, journal.now(ctx.io), "begin", &hash);
    const files = try planner.desiredFiles(a, result.state.config(), &result.facts);
    const problems = w.diags.items.items.len;
    const done = try apply.run(a, ctx.io, p, &result.state.lock, files, target, units, &w.diags) orelse {
        try journal.record(a, ctx.io, ctx.root, journal.now(ctx.io), "failed", &hash);
        return Outcome.failed(&w);
    };
    try journal.record(a, ctx.io, ctx.root, journal.now(ctx.io), "done", &hash);
    try recordIds(ctx, a);
    var code = try verify(ctx, in, p.changes.len - done.skipped.len, done.skipped, units);
    if (w.diags.items.items.len > problems) code = try scriptsFailed(ctx, w.diags.items.items[problems..]);
    if (units and !ctx.json and changesPackages(p)) try offerRestarts(ctx, yes);
    return .{ .code = code, .matches = true, .changed_generation = on_generations, .needs_reboot = needs_reboot };
}

/// adds the system accounts packages made to the history of system ids,
/// which `os status` checks later ids against.
fn recordIds(ctx: *Context, a: Allocator) !void {
    const fs: rootfs.Root = .{ .a = a, .io = ctx.io, .dir = ctx.root };
    const seen = try accounts.systemIds(a, try fs.read("etc/passwd"), try fs.read("etc/group"));
    const lines = try accounts.newHistory(a, try accounts.parseHistory(a, try fs.read(accounts.history_path)), seen);
    if (lines.len > 0) fs.append(accounts.history_path, lines) catch {};
}

/// an apply that worked can still leave `problems`: hooks or package
/// scripts that failed after the packages changed, like a mkinitcpio hook.
/// they're warnings, since the change is made, but the run fails so nobody
/// takes it for a clean one.
fn scriptsFailed(ctx: *Context, problems: []const diag.Diagnostic) !u8 {
    for (problems) |d| {
        try ctx.err.print("warning: {s}\n", .{d.message});
        if (d.hint) |out| {
            var lines = std.mem.splitScalar(u8, out, '\n');
            while (lines.next()) |line| try ctx.err.print("   | {s}\n", .{line});
        }
    }
    try ctx.err.writeAll("os: the packages changed, but a hook or package script failed. fix what it says, then run it again or reinstall the package.\n");
    return 1;
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
    const boot = try w.generations() orelse return;
    var why: []const u8 = "";
    const m = try gens.Machine.open(a, ctx.io, boot, &why) orelse {
        try ctx.err.print("os: applied, but not recorded as a generation: {s}\n", .{why});
        return;
    };
    defer m.close();
    const now = std.Io.Timestamp.now(ctx.io, .real).toSeconds();
    const commit = try configNow(ctx, a);
    const recorded = if (done.staged_root) |root| try m.recordStaged(root, reason, now, commit) else try m.record(reason, now, commit);
    if (recorded) |problem| {
        try ctx.err.print("os: applied, but not recorded as a generation: {s}\n", .{problem});
        return;
    }
    if (!ctx.json) try ctx.out.writeAll("recorded as a new generation; the boot menu has it.\n");
    try collectOld(ctx, &m, generation.default_keep);
    if (done.needs_reboot) try armTrial(ctx, a, boot);
}

/// a generation that needs a reboot boots once on trial: the next boot
/// tries it, the default stays on the one before, and `os health` makes
/// it the default once it has come up healthy.
fn armTrial(ctx: *Context, a: Allocator, boot: facts.Boot) !void {
    gens.blockHibernation(ctx.io);
    const records = try gens.readRecords(a, ctx.io, "/var");
    if (records.len < 2) return;
    const n = records[records.len - 1].n;
    const store = trial.Store.of(a, ctx.io, boot) orelse return;
    // with a trial already waiting for a reboot, the fallback stays the
    // generation before that one, the last that booted, while it's there.
    const pending = if (try store.current()) |t| t.fallback else 0;
    const before = if (pending != 0 and generation.find(records, pending) != null) pending else records[records.len - 2].n;
    if (try store.arm(n, generation.find(records, before).?)) |problem| {
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
    const f = try w.facts() orelse return;
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
    // with what's still to do, which says more about why it didn't take.
    var told: std.ArrayList([]const u8) = .empty;
    for (result.plan.changes) |c| {
        if (!apply.applies(c.kind, units)) continue;
        try left.append(a, c.subject);
        try told.append(a, if (c.to) |to| try std.fmt.allocPrint(a, "{s} ({s})", .{ c.subject, to }) else c.subject);
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
    if (!ctx.json) try ctx.err.print("os: applied, but these still differ from the config: {s}\n", .{try std.mem.join(a, ", ", told.items)});
    return 1;
}

/// the machine to change, and the package databases for the lock's own
/// date, with the servers packages come from.
fn targetFor(ctx: *Context, w: *cli.Work, c: *const config.Config, l: *const lock.Lock) !?apply.Target {
    const a = w.allocator();
    const pc = try locking.pacman(ctx, a, c);
    const cache = try locking.cacheDir(ctx, a);
    // mirrors keep only today's packages. a lock from an earlier day gets
    // what the cache doesn't have from the arch linux archive.
    const old = !cli.eql(l.sync_date, try locking.today(ctx.io, a));
    const rs = if (old) try sync.archived(a, pc.repos, l.sync_date) else pc.repos;
    const dbs = try sync.cached(a, ctx.io, rs, cache, l.sync_date) orelse blk: {
        if (old and !ctx.json) try ctx.out.print("the lock is from {s}, so its packages come from the arch linux archive, which is slower than a mirror.\n", .{l.sync_date});
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
    return if (rootfs.pathExists(ctx.io, dir)) dir else null;
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
    try std.testing.expect(std.mem.indexOf(u8, t.out.buffered(), "the machine is as it was.") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.fs.get("/etc/yoq/machine.lock").?, "[packages.git]") == null);
    t.input = null;
    try t.exec(&(update ++ .{"--yes"}));
    try std.testing.expectEqualStrings("", t.err.buffered());
    try std.testing.expectEqual(0, t.code);
    try std.testing.expect(std.mem.indexOf(u8, t.fs.get("/etc/yoq/machine.lock").?, "[packages.git]") != null);
    try cwd.access(io, try std.fs.path.join(a, &.{ root, "usr/share/doc/git/README" }), .{});
}

test "a hook that fails after the packages change fails the apply, with a warning" {
    if (!alpm.available) return error.SkipZigTest;
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const m = try @import("../test_helpers.zig").FixtureMachine.init(a, tmp);
    const hooks = try std.fs.path.join(a, &.{ m.root, "etc/pacman.d/hooks" });
    try std.Io.Dir.cwd().createDirPath(io, hooks);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(a, &.{ hooks, "90-fails.hook" }),
        .data = "[Trigger]\nOperation = Install\nType = Package\nTarget = git\n\n[Action]\nWhen = PostTransaction\nExec = /usr/bin/no-such-command\n",
    });

    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put(m.conf_path, m.conf);
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"git\"]\n[boot]\nkernel = \"none\"\n");
    try t.exec(&.{ "--root", m.root, "update", "--dbs", m.cache, "--date", "2026-09-25", "--no-apply" });
    try std.testing.expectEqual(0, t.code);
    try t.exec(&.{ "--root", m.root, "apply", "--yes" });
    try std.testing.expectEqual(1, t.code);
    try std.testing.expect(std.mem.startsWith(u8, t.err.buffered(), "warning: hook 90-fails.hook: command failed to execute correctly\n   | call to execv failed"));
    try std.testing.expect(std.mem.indexOf(u8, t.err.buffered(), "os: the packages changed, but a hook or package script failed.") != null);
    // the packages did change.
    try std.Io.Dir.cwd().access(io, try std.fs.path.join(a, &.{ m.root, "usr/share/doc/git/README" }), .{});
}
