//! `add`, `remove`, `enable`, and `disable`: change the config file for
//! the user. change.zig works out and checks the edit; this prints it.

const std = @import("std");
const cli = @import("../cli.zig");
const change = @import("../change.zig");
const output = @import("../output.zig");
const alpm = @import("../alpm.zig");
const lock = @import("../lock.zig");
const sync = @import("../sync.zig");
const update = @import("update.zig");
const planner = @import("../planner.zig");
const Context = cli.Context;

pub fn addCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    return run(ctx, args, .add);
}

pub fn removeCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    return run(ctx, args, .remove);
}

pub fn enableCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    return run(ctx, args, .enable);
}

pub fn disableCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    return run(ctx, args, .disable);
}

fn run(ctx: *Context, args: []const [:0]const u8, op: change.Op) !u8 {
    if (args.len == 0) {
        try ctx.err.print("usage: os {s} <{s}>...\n", .{ @tagName(op), if (op == .add or op == .remove) "package" else "service" });
        return 2;
    }
    for (args) |a| {
        if (a[0] == '-') {
            try ctx.err.print("os: unknown flag '{s}'\n", .{a});
            return 2;
        }
    }
    const names = try ctx.gpa.alloc([]const u8, args.len);
    defer ctx.gpa.free(names);
    for (args, names) |arg, *n| n.* = arg;
    return apply(ctx, op, names);
}

/// `os adopt [package...]`: puts packages installed outside the config into
/// it, all of them or the ones named.
pub fn adoptCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    for (args) |a| {
        if (a[0] == '-') return cli.usageError(ctx, "os adopt [package...]");
    }
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const state = try w.state() orelse return w.report();
    const f = try cli.facts(&w) orelse return 1;
    if (w.failed()) return w.report();

    const extra = try planner.extraPackages(a, state.config(), &state.lock, &f);
    for (args) |name| {
        for (extra) |e| {
            if (cli.eql(e, name)) break;
        } else {
            try ctx.err.print("os: {s} isn't installed outside the config\n", .{name});
            return 1;
        }
    }
    if (args.len == 0 and extra.len == 0) {
        try ctx.out.writeAll("nothing to adopt: every installed package is in the config.\n");
        return 0;
    }
    if (args.len == 0) return apply(ctx, .add, extra);
    const names = try a.alloc([]const u8, args.len);
    for (args, names) |arg, *n| n.* = arg;
    return apply(ctx, .add, names);
}

/// edits the config for `op` on each name, writes it, and brings the lock
/// along.
fn apply(ctx: *Context, op: change.Op, names: []const []const u8) !u8 {
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const loaded = try w.config() orelse return w.report();
    const top = loaded.files.items[0];
    const text = ctx.files.read(a, top) catch {
        try ctx.err.print("os: can't read {s}\n", .{top});
        return 1;
    };

    const outcome = try change.plan(a, &loaded.config, top, text, op, names, &w.diags);
    if (w.failed()) return w.report();
    if (outcome.changed()) {
        if (!try change.check(ctx.gpa, ctx.files, top, outcome.text, outcome.notes, &w.diags)) return w.report();
        ctx.files.write(top, outcome.text) catch {
            try ctx.err.print("os: can't write {s}\n", .{top});
            return 1;
        };
    }

    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.change/1", .{ .file = top, .changed = outcome.changed(), .notes = outcome.notes });
        return 0;
    }
    for (outcome.notes) |n| {
        switch (n.what) {
            .added => try ctx.out.print("+ packages \"{s}\"\n", .{n.name}),
            .removed => try ctx.out.print("- packages \"{s}\"\n", .{n.name}),
            .excluded => try ctx.out.print("+ remove.packages \"{s}\"  (set in {s})\n", .{ n.name, n.detail.? }),
            .enabled, .disabled => try ctx.out.print("~ services.{s} = {}\n", .{ n.name, n.what == .enabled }),
            .chosen => try ctx.out.print("+ providers.{s} = \"{s}\"\n", .{ n.name, n.detail.? }),
            .unchanged => try ctx.out.print("  {s} is already set that way  ({s})\n", .{ n.name, n.detail.? }),
        }
    }
    if (!outcome.changed()) return 0;
    try ctx.out.print("\nsaved {s}.\n", .{top});
    const code = if (op == .add or op == .remove) try relock(ctx, top) else 0;
    try cli.record(ctx, a, top, try commitMessage(a, op, outcome.notes));
    return code;
}

/// "add fd, bat": what the change did, in the words of the command.
fn commitMessage(a: std.mem.Allocator, op: change.Op, notes: []const change.Note) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (notes) |n| {
        if (n.what != .unchanged) try names.append(a, n.name);
    }
    return std.fmt.allocPrint(a, "{s} {s}", .{ @tagName(op), try std.mem.join(a, ", ", names.items) });
}

/// brings the lock in line with a changed package list, using the
/// databases cached for the lock's own date, so nothing else moves. with
/// no cache for that date, it says to run `os update` instead.
fn relock(ctx: *Context, top: []const u8) !u8 {
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const old = try update.readLock(ctx, a, top) orelse {
        try ctx.out.writeAll("no machine.lock yet: `os update` resolves one.\n");
        return 0;
    };
    if (!alpm.available) {
        try ctx.out.writeAll("this build can't resolve packages, so machine.lock wasn't updated.\n");
        return 0;
    }
    const dbs = try sync.cached(a, ctx.io, try update.repos(ctx, a), try update.cacheDir(ctx, a), old.sync_date) orelse {
        try ctx.out.print("no package databases cached for {s}: `os update` resolves against today's.\n", .{old.sync_date});
        return 0;
    };
    const loaded = try w.config() orelse return w.report();
    const l = try update.resolveLock(ctx, &w, &loaded.config, top, dbs, old.sync_date) orelse return w.report();
    _ = try update.writeLock(ctx, a, top, &l) orelse return 1;
    try update.reportLock(ctx, "updated machine.lock", try lock.diff(a, &old, &l));
    return 0;
}

// -- tests --

const TestRun = cli.TestRun;

test "add, remove, enable, and disable edit the config file" {
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/base.toml", "packages = [\"nano\", \"git\"]\n");
    try t.fs.put("/etc/yoq/machine.toml",
        \\# my laptop
        \\include = ["base.toml"]
        \\packages = ["git", "neovim"]  # editors
        \\
        \\[services]
        \\ssh = true
        \\
    );
    try t.exec(&.{ "add", "ripgrep", "neovim" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expect(std.mem.startsWith(u8, t.out.buffered(), "+ packages \"ripgrep\"\n  neovim is already set that way  (/etc/yoq/machine.toml:3)\n"));

    try t.exec(&.{ "remove", "nano", "git" });
    try std.testing.expectEqual(0, t.code);
    try t.exec(&.{ "enable", "tailscale" });
    try t.exec(&.{ "disable", "ssh" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqualStrings("add ripgrep", t.recorder.messages.items[0]);
    try std.testing.expectEqualStrings("remove nano, git", t.recorder.messages.items[1]);
    try std.testing.expectEqual(4, t.recorder.messages.items.len);
    try std.testing.expectEqualStrings(
        \\# my laptop
        \\include = ["base.toml"]
        \\packages = ["neovim", "ripgrep"]  # editors
        \\
        \\[services]
        \\ssh = false
        \\tailscale = true
        \\
        \\[remove]
        \\packages = ["nano", "git"]
        \\
    , t.fs.get("/etc/yoq/machine.toml").?);
}

test "change refuses what it can't do" {
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"git\"]\n[services]\nssh = true\n");
    try t.exec(&.{ "remove", "openssh" });
    try std.testing.expectEqual(1, t.code);
    try std.testing.expect(std.mem.indexOf(u8, t.err.buffered(), "openssh comes from services.ssh") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.err.buffered(), "run `os disable ssh`") != null);

    try t.exec(&.{ "remove", "vim" });
    try std.testing.expectEqual(1, t.code);
    try t.exec(&.{ "enable", "sshd" });
    try std.testing.expectEqual(1, t.code);
    try std.testing.expect(std.mem.indexOf(u8, t.err.buffered(), "did you mean \"ssh\"?") != null);
    try t.exec(&.{"add"});
    try std.testing.expectEqual(2, t.code);
    try std.testing.expectEqualStrings("packages = [\"git\"]\n[services]\nssh = true\n", t.fs.get("/etc/yoq/machine.toml").?);
}

test "add and remove update the lock from the cached databases" {
    if (!alpm.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);

    // the fixture databases, cached as if downloaded on 2026-09-25.
    const cache = try std.fs.path.join(a, &.{ root, "var/cache/yoq/sync/2026-09-25" });
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, cache);
    for ([_][]const u8{ "core", "extra" }) |r| {
        const bytes = try cwd.readFileAlloc(std.testing.io, try std.fmt.allocPrint(a, "tests/alpm/repos/{s}.db", .{r}), a, .limited(1 << 20));
        try cwd.writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/{s}.db", .{ cache, r }), .data = bytes });
    }

    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"git\"]\n");
    try t.exec(&.{ "--root", root, "update", "--dbs", try a.dupeZ(u8, cache), "--date", "2026-09-25" });
    try std.testing.expectEqual(0, t.code);

    try t.exec(&.{ "--root", root, "add", "neovim" });
    try std.testing.expectEqualStrings("", t.err.buffered());
    try std.testing.expect(std.mem.endsWith(u8, t.out.buffered(), "updated machine.lock: +3. applying isn't built yet; `os plan` shows what would change.\n"));
    const locked = t.fs.get("/etc/yoq/machine.lock").?;
    try std.testing.expect(std.mem.indexOf(u8, locked, "[packages.luajit]") != null);
    try std.testing.expect(std.mem.indexOf(u8, locked, "sync_date = \"2026-09-25\"") != null);

    try t.exec(&.{ "--root", root, "remove", "git" });
    try std.testing.expect(std.mem.endsWith(u8, t.out.buffered(), "updated machine.lock: -5. applying isn't built yet; `os plan` shows what would change.\n"));
    try std.testing.expect(std.mem.indexOf(u8, t.fs.get("/etc/yoq/machine.lock").?, "perl-error") == null);
}

test "adopt puts extra packages into the config" {
    var t: TestRun = .{};
    defer t.deinit();
    const h = "a" ** 64;
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"git\"]\n");
    try t.fs.put("/etc/yoq/machine.lock", "version = 1\nsync_date = \"2026-09-25\"\nkeyring = \"1\"\n" ++
        "[packages.git]\nversion = \"1\"\nrepo = \"extra\"\nsha256 = \"" ++ h ++ "\"\n" ++
        "[packages.linux]\nversion = \"1\"\nrepo = \"core\"\nsha256 = \"" ++ h ++ "\"\n");
    try t.fs.put("f.json",
        \\{"schema":"yoq.facts/1","packages":[
        \\ {"name":"git","version":"1"},{"name":"linux","version":"1"},
        \\ {"name":"htop","version":"3.4-1"},{"name":"btop","version":"1.4-1"},
        \\ {"name":"ncurses","version":"6.5","reason":"dependency"}]}
    );
    try t.exec(&.{ "--facts", "f.json", "adopt", "nano" });
    try std.testing.expectEqual(1, t.code);
    try std.testing.expectEqualStrings("os: nano isn't installed outside the config\n", t.err.buffered());

    try t.exec(&.{ "--facts", "f.json", "adopt", "htop" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqualStrings("packages = [\"git\", \"htop\"]\n", t.fs.get("/etc/yoq/machine.toml").?);

    try t.exec(&.{ "--facts", "f.json", "adopt" });
    try std.testing.expectEqualStrings("packages = [\"git\", \"htop\", \"btop\"]\n", t.fs.get("/etc/yoq/machine.toml").?);
}
