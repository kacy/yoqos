//! `os history` and `os rollback`. on a machine with generations they're
//! about generations: a rollback starts a new one from an older one's
//! record, and the next boot runs it. without generations they're about
//! the config's git history: a rollback applies an older config and lock,
//! with older packages from the local cache, and writes those files back
//! as a new commit. either way, history only grows.

const std = @import("std");
const cli = @import("../cli.zig");
const history = @import("../history.zig");
const output = @import("../output.zig");
const applying = @import("apply.zig");
const facts = @import("../facts.zig");
const generation = @import("../generation.zig");
const gens = @import("../gens.zig");
const trial = @import("../trial.zig");
const journal = @import("../journal.zig");
const Context = cli.Context;

pub fn historyCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (try cli.noArgs(ctx, args, "os history")) |code| return code;
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    if (try w.generations()) |boot| return listGenerations(ctx, w.allocator(), boot);
    // the config needn't load: history is how to find a good one.
    const entries = try logOf(ctx, w.allocator(), ctx.config_path) orelse return 1;
    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.history/1", .{ .entries = entries });
        return 0;
    }
    for (entries, 1..) |e, i| {
        try ctx.out.print("{s} {d: >3}  {s}\n", .{ if (i == entries.len) "*" else " ", e.n, e.message });
    }
    return 0;
}

pub fn rollbackCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    const usage_text = "os rollback [n | --to-booted] [--yes]";
    var yes = false;
    var to_booted = false;
    var wanted: ?u32 = null;
    var it: cli.ArgIter = .{ .args = args };
    while (it.next()) |arg| {
        if (!it.isFlag(arg)) {
            if (wanted != null) return cli.usageError(ctx, usage_text);
            wanted = std.fmt.parseInt(u32, arg, 10) catch return cli.usageError(ctx, usage_text);
        } else if (cli.isYes(arg)) {
            yes = true;
        } else if (cli.eql(arg, "--to-booted")) {
            to_booted = true;
        } else return cli.usageError(ctx, usage_text);
    }
    if (to_booted and wanted != null) return cli.usageError(ctx, usage_text);
    if (try cli.refused(ctx, applying.blocker(ctx))) return 1;

    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    if (try w.generations()) |boot| return rollbackGeneration(ctx, a, boot, wanted, to_booted, yes);
    if (to_booted) return cli.fail(ctx, "--to-booted keeps an older generation booted from the menu. this machine has no generations; `os enable-rollback` turns them on.", .{});
    // the config needn't load: going back is how to fix one that doesn't.
    const top = ctx.config_path;
    const dir = std.fs.path.dirnamePosix(top) orelse ".";
    const entries = try logOf(ctx, a, top) orelse return 1;
    const target = if (wanted) |n| blk: {
        if (n == 0 or n > entries.len) return cli.noGeneration(ctx, n);
        break :blk entries[n - 1];
    } else blk: {
        if (entries.len < 2) return cli.fail(ctx, "there's nothing before this generation to go back to.", .{});
        break :blk entries[entries.len - 2];
    };

    // edits made by hand go into history before the files change, so
    // going back doesn't lose them.
    try cli.record(ctx, a, top, "local edits before rollback");
    var why: []const u8 = "";
    const files = try ctx.history.files(a, dir, target.rev, &why) orelse return cli.fail(ctx, "can't read generation {d}: {s}", .{ target.n, why });

    // stage that generation's files, and apply them from there. the config
    // directory changes only once the machine has.
    const staging = try cli.machinePath(ctx, a, "/var/lib/yoq/rollback");
    for (files) |f| {
        if (!try cli.writeFile(ctx, try std.fs.path.join(a, &.{ staging, f.path }), f.bytes)) return 1;
    }
    var in = cli.inputs(ctx);
    in.config_path = try std.fs.path.join(a, &.{ staging, std.fs.path.basenamePosix(top) });
    if (!ctx.json) try ctx.out.print("rolling back to {d}: {s}\n\n", .{ target.n, target.message });
    const done = try applying.run(ctx, yes, in, .{});
    if (!done.matches) return done.code;

    for (files) |f| {
        if (!try cli.writeFile(ctx, try std.fs.path.join(a, &.{ dir, f.path }), f.bytes)) return 1;
    }
    try cli.record(ctx, a, top, try std.fmt.allocPrint(a, "rollback to {d}: {s}", .{ target.n, target.message }));
    try cli.note(ctx, a, .{ .time = journal.now(ctx.io), .kind = .rollback, .generation = @intCast(target.n) });
    return done.code;
}

fn listGenerations(ctx: *Context, a: std.mem.Allocator, boot: facts.Boot) !u8 {
    const records = try gens.readRecords(a, ctx.io, "/var");
    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.history/1", .{ .generations = records, .running = boot.root_subvol });
        return 0;
    }
    // the running root may be shared by several records; the newest of
    // them is the one running.
    var running: ?u32 = null;
    for (records) |r| {
        if (std.mem.eql(u8, r.root, boot.root_subvol.?[1..])) running = r.n;
    }
    for (records) |r| {
        try ctx.out.print("{s} {d: >3}  {s}  {s}{s}\n", .{ if (running == r.n) "*" else " ", r.n, try generation.dateOf(a, r.time), r.reason, if (r.pinned) "  (pinned)" else "" });
    }
    return 0;
}

/// starts a new generation from an older one, or from the copy of one
/// that's running, and puts it first in the boot menu.
fn rollbackGeneration(ctx: *Context, a: std.mem.Allocator, boot: facts.Boot, wanted: ?u32, to_booted: bool, yes: bool) !u8 {
    const records = try gens.readRecords(a, ctx.io, "/var");
    if (records.len == 0) return cli.fail(ctx, "no generations are recorded in /var/lib/yoq/generations.", .{});
    const newest = records[records.len - 1];
    const n: u32 = if (to_booted)
        generation.bootCopyOf(boot.root_subvol.?) orelse
            return cli.fail(ctx, "this is the newest generation already. --to-booted keeps an older one you booted from the menu.", .{})
    else
        wanted orelse newest.n -| 1;
    const target = generation.find(records, n) orelse return cli.noGeneration(ctx, n);
    if (!to_booted and n == newest.n) return cli.fail(ctx, "generation {d} is the newest; it's what boots already.", .{n});

    const source = if (to_booted) boot.root_subvol.? else try std.fmt.allocPrint(a, "/{s}/{d}", .{ generation.gens_dir, n });
    const reason = try std.fmt.allocPrint(a, "{s} {d}: {s}", .{ if (to_booted) "keep" else "rollback to", n, target.reason });
    try ctx.out.print("generation {d} ({s} · {s}) becomes generation {d}, and the next boot runs it.\n/var and /home stay as they are.\n", .{ n, try generation.dateOf(a, target.time), target.reason, generation.next(records) });
    if (try cli.approve(ctx, yes, "roll back", "roll back?")) |code| return code;
    const made = try startFrom(ctx, a, boot, target, source, reason) orelse return 1;
    try cli.note(ctx, a, .{ .time = journal.now(ctx.io), .kind = .rollback, .generation = n });
    try ctx.out.print("generation {d} is ready. reboot to start it.\n", .{made});
    return 0;
}

/// starts the next generation from `source`, carrying `target`'s config
/// back with it so the files match that system, and collects old
/// generations. returns its number, or null after saying why.
pub fn startFrom(ctx: *Context, a: std.mem.Allocator, boot: facts.Boot, target: generation.Record, source: []const u8, reason: []const u8) !?u32 {
    const m = try cli.openMachine(ctx, a, boot) orelse return null;
    defer m.close();
    const config: ?generation.Config = if (target.config_dir != null and target.config_rev != null) .{ .dir = target.config_dir.?, .rev = target.config_rev.? } else null;
    var made: u32 = 0;
    if (try m.start(source, reason, std.Io.Timestamp.now(ctx.io, .real).toSeconds(), config, &made)) |w| {
        try ctx.err.print("os: {s}\n", .{w});
        return null;
    }
    try cli.note(ctx, a, .{ .time = journal.now(ctx.io), .kind = .generation, .generation = made, .message = reason });
    // a trial still waiting is overtaken: the next boot runs this.
    if (trial.Store.of(a, ctx.io, boot)) |store| if (try store.end()) |w| try ctx.err.print("os: couldn't end the pending trial: {s}\n", .{w});
    if (config) |c| {
        if (!try restoreConfig(ctx, a, c, reason)) return null;
    }
    try applying.collectOld(ctx, &m, generation.default_keep);
    gens.blockHibernation(ctx.io);
    return made;
}

/// `os carry`, run by yoq-carry.service as the machine shuts down: a
/// generation waiting for this reboot gets the running machine's
/// passwords, host keys, and the rest of its state once more, so a
/// password changed after `os rollback` isn't left behind.
pub fn carryCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (try cli.noArgs(ctx, args, "os carry")) |code| return code;
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const boot = try w.generations() orelse return 0;
    const running = boot.root_subvol.?;
    const waiting = try waitingRoot(ctx, a, running) orelse return 0;
    const m = try cli.openMachine(ctx, a, boot) orelse return 1;
    defer m.close();
    if (try m.carry(waiting)) |problem| return cli.fail(ctx, "couldn't carry this machine's state into {s}: {s}", .{ waiting, problem });
    try ctx.out.print("carried this machine's state into {s}, which the next boot runs.\n", .{waiting});
    return 0;
}

/// the root the next boot runs, like "/@roots/2", if it isn't the running
/// one.
fn waitingRoot(ctx: *Context, a: std.mem.Allocator, running: []const u8) !?[]const u8 {
    const next = try applying.nextRoot(a, ctx.io) orelse return null;
    const root = try std.fmt.allocPrint(a, "/{s}", .{next});
    return if (std.mem.eql(u8, root, running)) null else root;
}

/// `os gc [--keep n]`: removes old generations now.
pub fn gcCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    const usage_text = "os gc [--keep n]";
    var keep: usize = generation.default_keep;
    var it: cli.ArgIter = .{ .args = args };
    while (it.next()) |arg| {
        if (!it.isFlag(arg) or !cli.eql(arg, "--keep")) return cli.usageError(ctx, usage_text);
        keep = std.fmt.parseInt(usize, it.value() orelse return cli.usageError(ctx, usage_text), 10) catch return cli.usageError(ctx, usage_text);
        // the newest generation always stays.
        if (keep == 0) return cli.usageError(ctx, usage_text);
    }
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const boot = try w.generations() orelse return cli.noGenerations(ctx);
    // from a menu copy, collecting could take the record of the very
    // generation this boot runs.
    if (try cli.refused(ctx, applying.bootBlocker(ctx.io))) return 1;
    const m = try cli.openMachine(ctx, a, boot) orelse return 1;
    defer m.close();
    var removed: std.ArrayList(u32) = .empty;
    if (try m.collect(keep, &removed)) |problem| return cli.fail(ctx, "{s}", .{problem});
    // a menu another tool dropped os's entries from gets them back.
    if (removed.items.len == 0) if (boot.menu_missing) |file| {
        const records = try gens.readRecords(a, ctx.io, "/var");
        if (records.len > 0) {
            const head = try std.fmt.allocPrint(a, "/{s}", .{records[records.len - 1].root});
            if (try m.writeMenu(head, records)) |problem| return cli.fail(ctx, "{s}", .{problem});
            try ctx.out.print("wrote the boot menu's generations back into {s}.\n", .{file});
        }
    };
    if (removed.items.len == 0) {
        try ctx.out.writeAll("nothing to remove.\n");
        return 0;
    }
    try cli.note(ctx, a, .{ .time = journal.now(ctx.io), .kind = .gc, .generations = removed.items });
    try ctx.out.writeAll("removed generations:");
    for (removed.items) |n| try ctx.out.print(" {d}", .{n});
    try ctx.out.writeAll(".\n");
    return 0;
}

/// `os pin <n>` and `os pin --remove <n>`: keep a generation through
/// garbage collection, or stop keeping it.
pub fn pinCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    const usage_text = "os pin [--remove] <n>";
    var pin = true;
    var wanted: ?u32 = null;
    var it: cli.ArgIter = .{ .args = args };
    while (it.next()) |arg| {
        if (!it.isFlag(arg)) {
            if (wanted != null) return cli.usageError(ctx, usage_text);
            wanted = std.fmt.parseInt(u32, arg, 10) catch return cli.usageError(ctx, usage_text);
        } else if (cli.eql(arg, "--remove")) {
            pin = false;
        } else return cli.usageError(ctx, usage_text);
    }
    const n = wanted orelse return cli.usageError(ctx, usage_text);
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    _ = try w.generations() orelse return cli.noGenerations(ctx);
    var changed = generation.find(try gens.readRecords(a, ctx.io, "/var"), n) orelse return cli.noGeneration(ctx, n);
    changed.pinned = pin;
    if (try gens.writeRecord(a, ctx.io, "/var", changed)) |why| return cli.fail(ctx, "{s}", .{why});
    try cli.note(ctx, a, .{ .time = journal.now(ctx.io), .kind = .pin, .step = if (pin) .pinned else .unpinned, .generation = n });
    try ctx.out.print("generation {d} {s}.\n", .{ n, if (pin) "is pinned: garbage collection keeps it" else "isn't pinned any more" });
    return 0;
}

/// writes the config directory back as it was at `c.rev`, and commits it.
fn restoreConfig(ctx: *Context, a: std.mem.Allocator, c: generation.Config, message: []const u8) !bool {
    var why: []const u8 = "";
    const files = try ctx.history.files(a, c.dir, c.rev, &why) orelse {
        try ctx.err.print("os: the new generation is ready, but {s} couldn't go back with it: {s}\n", .{ c.dir, why });
        return false;
    };
    for (files) |f| {
        if (!try cli.writeFile(ctx, try std.fs.path.join(a, &.{ c.dir, f.path }), f.bytes)) return false;
    }
    try cli.record(ctx, a, try std.fs.path.join(a, &.{ c.dir, "machine.toml" }), message);
    return true;
}

fn logOf(ctx: *Context, a: std.mem.Allocator, top: []const u8) !?[]const history.Entry {
    const dir = std.fs.path.dirnamePosix(top) orelse ".";
    var why: []const u8 = "";
    const entries = try ctx.history.log(a, dir, &why) orelse {
        try ctx.err.print("os: can't read the history of {s}: {s}\n", .{ dir, why });
        return null;
    };
    if (entries.len == 0) {
        try ctx.err.print("os: {s} has no history yet. os records one with every change it makes.\n", .{dir});
        return null;
    }
    return entries;
}

// -- tests --

const TestRun = cli.TestRun;

test "history lists generations, and rollback needs one to go back to" {
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"git\"]\n");
    try t.exec(&.{"history"});
    try std.testing.expectEqualStrings("os: /etc/yoq has no history yet. os records one with every change it makes.\n", t.err.buffered());

    try t.exec(&.{ "add", "--no-apply", "ripgrep" });
    try t.exec(&.{ "add", "--no-apply", "fd" });
    try t.exec(&.{"history"});
    try std.testing.expectEqualStrings(
        \\    1  add ripgrep
        \\*   2  add fd
        \\
    , t.out.buffered());
    try t.exec(&.{ "rollback", "seven" });
    try std.testing.expectEqual(2, t.code);
    // past the checks for root and libalpm, the number has to exist.
    if (!@import("../alpm.zig").available) return;
    try t.exec(&.{ "--root", "/nonexistent", "rollback", "7" });
    try std.testing.expectEqualStrings("os: there's no generation 7. `os history` lists them.\n", t.err.buffered());
}

test "rollback goes back a generation, and forward again" {
    if (!@import("../alpm.zig").available) return error.SkipZigTest;
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try @import("../test_helpers.zig").FixtureMachine.init(a, tmp);
    const neovim = try std.fs.path.join(a, &.{ m.root, "usr/share/doc/neovim/README" });
    const cwd = std.Io.Dir.cwd();

    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put(m.conf_path, m.conf);
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"git\"]\n[boot]\nkernel = \"none\"\n");
    try t.exec(&.{ "--root", m.root, "update", "--yes", "--dbs", m.cache, "--date", "2026-09-25" });
    try std.testing.expectEqual(0, t.code);
    try t.exec(&.{ "--root", m.root, "add", "--yes", "neovim" });
    try std.testing.expectEqual(0, t.code);
    try cwd.access(std.testing.io, neovim, .{});

    // back to before neovim: gone from the machine and from the config.
    try t.exec(&.{ "--root", m.root, "rollback", "--yes" });
    try std.testing.expectEqualStrings("", t.err.buffered());
    try std.testing.expectEqual(0, t.code);
    try std.testing.expect(std.mem.startsWith(u8, t.out.buffered(), "rolling back to 1: update packages to 2026-09-25\n"));
    if (cwd.access(std.testing.io, neovim, .{})) |_| return error.TestUnexpectedResult else |_| {}
    try std.testing.expect(std.mem.indexOf(u8, t.fs.get("/etc/yoq/machine.toml").?, "neovim") == null);
    try std.testing.expect(std.mem.indexOf(u8, t.fs.get("/etc/yoq/machine.lock").?, "[packages.neovim]") == null);

    // and forward again: rollback with no number goes to the one before.
    try t.exec(&.{ "--root", m.root, "rollback", "--yes" });
    try std.testing.expectEqual(0, t.code);
    try cwd.access(std.testing.io, neovim, .{});
    try t.exec(&.{"history"});
    try std.testing.expect(std.mem.endsWith(u8, t.out.buffered(), "*   4  rollback to 2: add neovim\n"));
}
