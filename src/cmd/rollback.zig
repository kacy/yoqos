//! `os history` and `os rollback`: the config's git history, numbered, and
//! going back to any point in it. on a machine without snapshots, a
//! rollback applies an older config and lock, with older packages from
//! the local cache, and then writes those files back as a new commit, so
//! history only grows.

const std = @import("std");
const cli = @import("../cli.zig");
const history = @import("../history.zig");
const output = @import("../output.zig");
const applying = @import("apply.zig");
const Context = cli.Context;

pub fn historyCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (try cli.noArgs(ctx, args, "os history")) |code| return code;
    var w: cli.Work = .init(ctx);
    defer w.deinit();
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
    const usage_text = "os rollback [n] [--yes]";
    var yes = false;
    var wanted: ?usize = null;
    for (args) |arg| {
        if (applying.isYes(arg)) {
            yes = true;
        } else wanted = std.fmt.parseInt(usize, arg, 10) catch return cli.usageError(ctx, usage_text);
    }
    if (try applying.refused(ctx)) return 1;

    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
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
