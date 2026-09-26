//! `add`, `remove`, `enable`, and `disable`: change the config file for
//! the user. change.zig works out and checks the edit; this prints it.

const std = @import("std");
const cli = @import("../cli.zig");
const change = @import("../change.zig");
const output = @import("../output.zig");
const alpm = @import("../alpm.zig");
const lock = @import("../lock.zig");
const sync = @import("../sync.zig");
const locking = @import("lock.zig");
const applying = @import("apply.zig");
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
    const usage_text = switch (op) {
        inline else => |o| "os " ++ @tagName(o) ++ (if (o == .add or o == .remove) " <package>..." else " <service>...") ++ " [--yes] [--no-apply]",
    };
    var then: Then = .{ .apply = true };
    var rest: std.ArrayList([:0]const u8) = .empty;
    defer rest.deinit(ctx.gpa);
    for (args) |arg| {
        if (!then.flag(arg)) try rest.append(ctx.gpa, arg);
    }
    if (rest.items.len == 0) return cli.usageError(ctx, usage_text);
    const names = try namesOf(ctx, ctx.gpa, rest.items, usage_text) orelse return 2;
    defer ctx.gpa.free(names);
    return editConfig(ctx, op, names, then);
}

const Then = applying.Then;

/// the arguments as names. returns null after a usage error if one looks
/// like a flag.
fn namesOf(ctx: *Context, a: std.mem.Allocator, args: []const [:0]const u8, usage_text: []const u8) !?[]const []const u8 {
    const out = try a.alloc([]const u8, args.len);
    for (args, out) |arg, *n| {
        if (std.mem.startsWith(u8, arg, "-")) {
            a.free(out);
            _ = try cli.usageError(ctx, usage_text);
            return null;
        }
        n.* = arg;
    }
    return out;
}

/// `os adopt [package...]`: puts packages installed outside the config into
/// it, all of them or the ones named.
pub fn adoptCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const wanted = try namesOf(ctx, a, args, "os adopt [package...]") orelse return 2;
    const state = try w.state() orelse return w.fail();
    const f = try cli.facts(&w) orelse return w.fail();
    if (w.failed()) return w.fail();

    const extra = try planner.extraPackages(a, state.config(), &state.lock, &f);
    for (wanted) |name| {
        for (extra) |e| {
            if (cli.eql(e, name)) break;
        } else {
            try ctx.err.print("os: {s} isn't installed outside the config\n", .{name});
            return 1;
        }
    }
    // adopting records what's already installed; there's nothing to apply.
    if (wanted.len > 0) return editConfig(ctx, .add, wanted, .{});
    if (extra.len == 0) {
        try ctx.out.writeAll("nothing to adopt: every installed package is in the config.\n");
        return 0;
    }
    return editConfig(ctx, .add, extra, .{});
}

/// edits the config for `op` on each name, writes it, and brings the lock
/// along.
fn editConfig(ctx: *Context, op: change.Op, names: []const []const u8, then: Then) !u8 {
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const loaded = try w.config() orelse return w.fail();
    const top = loaded.files.items[0];
    const text = try cli.readFile(ctx, a, top) orelse return 1;

    const outcome = try change.plan(a, &loaded.config, top, text, op, names, &w.diags);
    if (w.failed()) return w.fail();
    if (outcome.changed()) {
        if (!try change.check(ctx.gpa, ctx.files, top, outcome.text, outcome.notes, &w.diags)) return w.fail();
        if (!try cli.writeFile(ctx, top, outcome.text)) return 1;
    }

    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.change/1", .{ .file = top, .changed = outcome.changed(), .notes = outcome.notes });
    } else for (outcome.notes) |n| {
        switch (n.what) {
            .added => try ctx.out.print("+ packages \"{s}\"\n", .{n.name}),
            .removed => try ctx.out.print("- packages \"{s}\"\n", .{n.name}),
            .excluded => try ctx.out.print("+ remove.packages \"{s}\"  (set in {s})\n", .{ n.name, n.detail.? }),
            .enabled, .disabled => try ctx.out.print("~ services.{s} = {}\n", .{ n.name, n.what == .enabled }),
            .chosen => try ctx.out.print("+ providers.{s} = \"{s}\"\n", .{ n.name, n.detail.? }),
            .unchanged => try ctx.out.print("  {s} is already set that way  ({s})\n", .{ n.name, n.detail.? }),
        }
    }
    const now = then.applies(ctx);
    const message = try commitMessage(a, op, outcome.notes);
    if (outcome.changed()) {
        if (!ctx.json) try ctx.out.print("\nsaved {s}.\n", .{top});
        // services and packages both change what's wanted.
        const locked = try relock(ctx, top, !now);
        try cli.record(ctx, a, top, message);
        if (locked != .locked) return @intFromBool(locked == .failed);
    }
    if (!now) return 0;
    // a name already in the config applies too: the machine may be behind.
    try ctx.out.writeByte('\n');
    const done = try applying.run(ctx, then.yes, cli.inputs(ctx), .{});
    try applying.recordGeneration(ctx, done, if (outcome.changed()) message else "apply");
    return done.code;
}

/// "add fd, bat": what the change did, in the words of the command.
fn commitMessage(a: std.mem.Allocator, op: change.Op, notes: []const change.Note) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (notes) |n| {
        if (n.what != .unchanged) try names.append(a, n.name);
    }
    return std.fmt.allocPrint(a, "{s} {s}", .{ @tagName(op), try std.mem.join(a, ", ", names.items) });
}

const Relocked = enum { locked, skipped, failed };

/// brings the lock in line with a changed config, using the
/// databases cached for the lock's own date, so nothing else moves. with
/// no cache for that date, it says to run `os update` instead. `next` says
/// what comes after, when applying doesn't follow.
fn relock(ctx: *Context, top: []const u8, next: bool) !Relocked {
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const old = try locking.readLock(ctx, a, top) orelse {
        try ctx.out.writeAll("no machine.lock yet: `os update` resolves one.\n");
        return .skipped;
    };
    if (!alpm.available) {
        try ctx.out.writeAll("this build can't resolve packages, so machine.lock wasn't updated.\n");
        return .skipped;
    }
    const dbs = try sync.cached(a, ctx.io, try locking.repos(ctx, a), try locking.cacheDir(ctx, a), old.sync_date) orelse {
        try ctx.out.print("no package databases cached for {s}: `os update` resolves against today's.\n", .{old.sync_date});
        return .skipped;
    };
    const loaded = try w.config() orelse return failed(&w);
    const l = try locking.resolveLock(ctx, &w, &loaded.config, top, dbs, old.sync_date, &.{}) orelse return failed(&w);
    _ = try locking.writeLock(ctx, a, top, &l) orelse return failed(&w);
    try locking.reportLock(ctx, "updated machine.lock", try lock.diff(a, &old, &l), next);
    return .locked;
}

fn failed(w: *cli.Work) !Relocked {
    _ = try w.fail();
    return .failed;
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

test "edits update the lock from the cached databases" {
    if (!alpm.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);

    const cache = try @import("../test_helpers.zig").cacheFixtureDbs(a, root);

    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"git\"]\n");
    try t.exec(&.{ "--root", root, "update", "--dbs", cache, "--date", "2026-09-25" });
    try std.testing.expectEqual(0, t.code);

    try t.exec(&.{ "--root", root, "add", "neovim" });
    try std.testing.expectEqualStrings("", t.err.buffered());
    try std.testing.expect(std.mem.endsWith(u8, t.out.buffered(), "updated machine.lock: +3. next: os plan, then os apply\n"));
    const locked = t.fs.get("/etc/yoq/machine.lock").?;
    try std.testing.expect(std.mem.indexOf(u8, locked, "[packages.luajit]") != null);
    try std.testing.expect(std.mem.indexOf(u8, locked, "sync_date = \"2026-09-25\"") != null);

    try t.exec(&.{ "--root", root, "remove", "git" });
    try std.testing.expect(std.mem.endsWith(u8, t.out.buffered(), "updated machine.lock: -5. next: os plan, then os apply\n"));
    try std.testing.expect(std.mem.indexOf(u8, t.fs.get("/etc/yoq/machine.lock").?, "perl-error") == null);

    // a service brings its package into the lock, and takes it out again.
    try t.exec(&.{ "--root", root, "enable", "ssh" });
    try std.testing.expect(std.mem.endsWith(u8, t.out.buffered(), "updated machine.lock: +2. next: os plan, then os apply\n"));
    try std.testing.expect(std.mem.indexOf(u8, t.fs.get("/etc/yoq/machine.lock").?, "[packages.openssh]") != null);
    try t.exec(&.{ "--root", root, "disable", "ssh" });
    try std.testing.expect(std.mem.endsWith(u8, t.out.buffered(), "updated machine.lock: -2. next: os plan, then os apply\n"));
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

test "empty and flag-like names are usage errors, not crashes" {
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/machine.toml", "packages = []\n");
    try t.exec(&.{ "add", "" });
    try std.testing.expect(t.code != 0);
    try t.exec(&.{ "why", "" });
    try std.testing.expectEqual(2, t.code);
    try t.exec(&.{ "adopt", "-x" });
    try std.testing.expectEqual(2, t.code);
}
