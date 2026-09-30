//! `os record-pacman`: what the pacman hook in dist/ runs after every
//! transaction, with the packages it touched on stdin, one per line. it
//! never fails, since a failing hook would worry pacman's user for nothing.

const std = @import("std");
const cli = @import("../cli.zig");
const drift = @import("../drift.zig");
const journal = @import("../journal.zig");
const Context = cli.Context;

pub fn recordPacmanCmd(ctx: *Context, _: []const [:0]const u8) !u8 {
    // os's own transactions run the hook too; those aren't drift.
    if (ctx.in_own_transaction) return 0;
    const in = ctx.in orelse return 0;
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    while (in.takeDelimiter('\n') catch null) |line| {
        const name = std.mem.trim(u8, line, " \t\r");
        if (name.len > 0) try names.append(a, try a.dupe(u8, name));
    }
    try drift.record(a, ctx.io, ctx.root, journal.now(ctx.io), names.items);
    return 0;
}

test "the hook's targets land in the drift log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try std.fmt.allocPrintSentinel(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    var t: cli.TestRun = .{ .input = "htop\nbtop\n" };
    defer t.deinit();
    try t.exec(&.{ "--root", root, "record-pacman" });
    try std.testing.expectEqual(0, t.code);
    const got = try drift.since(arena.allocator(), std.testing.io, root);
    try std.testing.expectEqual(1, got.len);
    try std.testing.expectEqualStrings("htop", got[0].packages[0]);
    try std.testing.expectEqualStrings("btop", got[0].packages[1]);
}

test "os's own transactions aren't drift" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try std.fmt.allocPrintSentinel(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    var t: cli.TestRun = .{ .input = "git\n", .in_own_transaction = true };
    defer t.deinit();
    try t.exec(&.{ "--root", root, "record-pacman" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqual(0, (try drift.since(arena.allocator(), std.testing.io, root)).len);
}
