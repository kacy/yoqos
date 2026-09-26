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
const Context = cli.Context;

pub fn historyCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (try cli.noArgs(ctx, args, "os history")) |code| return code;
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    if (try generationsHere(&w)) |boot| return listGenerations(ctx, w.allocator(), boot);
    const loaded = try w.config() orelse return w.fail();
    const entries = try logOf(ctx, w.allocator(), loaded.files.items[0]) orelse return 1;
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
    var wanted: ?usize = null;
    for (args) |arg| {
        if (applying.isYes(arg)) {
            yes = true;
        } else if (cli.eql(arg, "--to-booted")) {
            to_booted = true;
        } else wanted = std.fmt.parseInt(usize, arg, 10) catch return cli.usageError(ctx, usage_text);
    }
    if (to_booted and wanted != null) return cli.usageError(ctx, usage_text);
    if (try applying.refused(ctx)) return 1;

    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    if (try generationsHere(&w)) |boot| return rollbackGeneration(ctx, a, boot, wanted, to_booted, yes);
    if (to_booted) {
        try ctx.err.writeAll("os: --to-booted keeps an older generation booted from the menu. this machine has no generations; `os enable-rollback` turns them on.\n");
        return 1;
    }
    const loaded = try w.config() orelse return w.fail();
    const top = loaded.files.items[0];
    const dir = std.fs.path.dirnamePosix(top) orelse ".";
    const entries = try logOf(ctx, a, top) orelse return 1;
    const target = if (wanted) |n| blk: {
        if (n == 0 or n > entries.len) {
            try ctx.err.print("os: there's no generation {d}. `os history` lists them.\n", .{n});
            return 1;
        }
        break :blk entries[n - 1];
    } else blk: {
        if (entries.len < 2) {
            try ctx.err.writeAll("os: there's nothing before this generation to go back to.\n");
            return 1;
        }
        break :blk entries[entries.len - 2];
    };

    var why: []const u8 = "";
    const files = try ctx.history.files(a, dir, target.rev, &why) orelse {
        try ctx.err.print("os: can't read generation {d}: {s}\n", .{ target.n, why });
        return 1;
    };

    // stage that generation's files, and apply them from there. the config
    // directory changes only once the machine has.
    const staging = try cli.machinePath(ctx, a, "/var/lib/yoq/rollback");
    for (files) |f| {
        if (!try cli.writeFile(ctx, try std.fs.path.join(a, &.{ staging, f.path }), f.bytes)) return 1;
    }
    var in = cli.inputs(ctx);
    in.config_path = try std.fs.path.join(a, &.{ staging, top[dir.len + 1 ..] });
    try ctx.out.print("rolling back to {d}: {s}\n\n", .{ target.n, target.message });
    const done = try applying.run(ctx, yes, in, .{});
    if (!done.matches) return done.code;

    for (files) |f| {
        if (!try cli.writeFile(ctx, try std.fs.path.join(a, &.{ dir, f.path }), f.bytes)) return 1;
    }
    try cli.record(ctx, a, top, try std.fmt.allocPrint(a, "rollback to {d}: {s}", .{ target.n, target.message }));
    return done.code;
}

/// the running machine's boot facts, when it runs a generation.
fn generationsHere(w: *cli.Work) !?facts.Boot {
    if (!cli.eql(w.ctx.root, "/") or w.ctx.facts_path != null) return null;
    // only how the machine boots: no packages or units to read.
    const f = try @import("../observe.zig").observe(w.allocator(), w.ctx.io, .{ .packages = false, .units = false }, &w.diags);
    return if (generation.running(f.boot.root_subvol)) f.boot else null;
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
        try ctx.out.print("{s} {d: >3}  {s}  {s}{s}\n", .{ if (running == r.n) "*" else " ", r.n, try gens.dateOf(a, r.time), r.reason, if (r.pinned) "  (pinned)" else "" });
    }
    return 0;
}

/// starts a new generation from an older one, or from the copy of one
/// that's running, and puts it first in the boot menu.
fn rollbackGeneration(ctx: *Context, a: std.mem.Allocator, boot: facts.Boot, wanted: ?usize, to_booted: bool, yes: bool) !u8 {
    const records = try gens.readRecords(a, ctx.io, "/var");
    if (records.len == 0) {
        try ctx.err.writeAll("os: no generations are recorded in /var/lib/yoq/generations.\n");
        return 1;
    }
    const newest = records[records.len - 1];
    const copy_prefix = "/" ++ generation.roots_dir ++ "/boot-";
    const n: u32 = if (to_booted) blk: {
        const running = boot.root_subvol.?;
        if (!std.mem.startsWith(u8, running, copy_prefix)) {
            try ctx.err.writeAll("os: this is the newest generation already. --to-booted keeps an older one you booted from the menu.\n");
            return 1;
        }
        break :blk std.fmt.parseInt(u32, running[copy_prefix.len..], 10) catch return 1;
    } else if (wanted) |w| @intCast(w) else newest.n -| 1;
    const target = for (records) |r| {
        if (r.n == n) break r;
    } else {
        try ctx.err.print("os: there's no generation {d}. `os history` lists them.\n", .{n});
        return 1;
    };
    if (!to_booted and n == newest.n) {
        try ctx.err.print("os: generation {d} is the newest; it's what boots already.\n", .{n});
        return 1;
    }

    const source = if (to_booted) boot.root_subvol.? else try std.fmt.allocPrint(a, "/{s}/{d}", .{ generation.gens_dir, n });
    const reason = try std.fmt.allocPrint(a, "{s} {d}: {s}", .{ if (to_booted) "keep" else "rollback to", n, target.reason });
    try ctx.out.print("generation {d} ({s} · {s}) becomes generation {d}, and the next boot runs it.\n/var and /home stay as they are.\n", .{ n, try gens.dateOf(a, target.time), target.reason, gens.next(records) });
    if (!yes) {
        if (!ctx.interactive) {
            try ctx.err.writeAll("os: pass --yes to roll back without a terminal.\n");
            return 2;
        }
        try ctx.out.writeByte('\n');
        if (!try cli.confirm(ctx, "roll back?")) {
            try ctx.out.writeAll("nothing changed.\n");
            return 0;
        }
    }
    var why: []const u8 = "";
    const m = try gens.Machine.open(a, ctx.io, boot, &why) orelse {
        try ctx.err.print("os: {s}\n", .{why});
        return 1;
    };
    defer m.close();
    const config: ?generation.Config = if (target.config_dir != null and target.config_rev != null) .{ .dir = target.config_dir.?, .rev = target.config_rev.? } else null;
    const made = try m.start(source, reason, std.Io.Timestamp.now(ctx.io, .real).toSeconds(), config, &why) orelse {
        try ctx.err.print("os: {s}\n", .{why});
        return 1;
    };
    // the config goes back with the system, so the files match what the
    // next boot runs.
    if (config) |c| {
        if (!try restoreConfig(ctx, a, c, reason)) return 1;
    }
    try ctx.out.print("generation {d} is ready. reboot to start it.\n", .{made});
    try applying.collectOld(ctx, &m, generation.default_keep);
    return 0;
}

/// `os gc [--keep n]`: removes old generations now.
pub fn gcCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    const usage_text = "os gc [--keep n]";
    var keep: usize = generation.default_keep;
    var it: cli.ArgIter = .{ .args = args };
    while (it.next()) |arg| {
        if (!cli.eql(arg, "--keep")) return cli.usageError(ctx, usage_text);
        keep = std.fmt.parseInt(usize, it.next() orelse return cli.usageError(ctx, usage_text), 10) catch return cli.usageError(ctx, usage_text);
    }
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const boot = try generationsHere(&w) orelse return noGenerations(ctx);
    var why: []const u8 = "";
    const m = try gens.Machine.open(a, ctx.io, boot, &why) orelse {
        try ctx.err.print("os: {s}\n", .{why});
        return 1;
    };
    defer m.close();
    var removed: std.ArrayList(u32) = .empty;
    if (try m.collect(keep, &removed)) |problem| {
        try ctx.err.print("os: {s}\n", .{problem});
        return 1;
    }
    if (removed.items.len == 0) {
        try ctx.out.writeAll("nothing to remove.\n");
        return 0;
    }
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
    for (args) |arg| {
        if (cli.eql(arg, "--remove")) {
            pin = false;
        } else wanted = std.fmt.parseInt(u32, arg, 10) catch return cli.usageError(ctx, usage_text);
    }
    const n = wanted orelse return cli.usageError(ctx, usage_text);
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    _ = try generationsHere(&w) orelse return noGenerations(ctx);
    for (try gens.readRecords(a, ctx.io, "/var")) |r| {
        if (r.n != n) continue;
        var changed = r;
        changed.pinned = pin;
        if (try gens.writeRecord(a, ctx.io, "/var", changed)) |why| {
            try ctx.err.print("os: {s}\n", .{why});
            return 1;
        }
        try ctx.out.print("generation {d} {s}.\n", .{ n, if (pin) "is pinned: garbage collection keeps it" else "isn't pinned any more" });
        return 0;
    }
    try ctx.err.print("os: there's no generation {d}. `os history` lists them.\n", .{n});
    return 1;
}

fn noGenerations(ctx: *Context) !u8 {
    try ctx.err.writeAll("os: this machine has no generations. `os enable-rollback` turns them on.\n");
    return 1;
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
