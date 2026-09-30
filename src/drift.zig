//! changes made with pacman directly. a pacman hook runs `os
//! record-pacman` after every transaction, which appends the packages it
//! touched to /var/lib/yoq/drift. transactions os runs itself are left out,
//! so what's recorded is what happened outside os.

const std = @import("std");
const facts = @import("facts.zig");
const journal = @import("journal.zig");
const rootfs = @import("rootfs.zig");
const Allocator = std.mem.Allocator;

pub const path = "var/lib/yoq/drift";

/// records a pacman transaction that touched `packages`. the hook leaves
/// out os's own. a record that can't be written is dropped: the hook
/// mustn't fail pacman.
pub fn record(a: Allocator, io: std.Io, root: []const u8, time: i64, packages: []const []const u8) !void {
    if (packages.len == 0) return;
    try journal.appendLine(a, io, root, path, facts.PacmanChange{ .time = time, .packages = packages });
}

/// the pacman transactions since the last apply finished.
pub fn since(a: Allocator, io: std.Io, root: []const u8) ![]facts.PacmanChange {
    const after = try journal.lastDone(a, io, root) orelse 0;
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    var out: std.ArrayList(facts.PacmanChange) = .empty;
    var lines = std.mem.tokenizeScalar(u8, try fs.read(path), '\n');
    while (lines.next()) |text| {
        const c = std.json.parseFromSliceLeaky(facts.PacmanChange, a, text, .{}) catch continue;
        if (c.time > after) try out.append(a, c);
    }
    return out.items;
}

test "pacman's changes since the last apply" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try record(a, io, root, 10, &.{"nano"});
    try journal.record(a, io, root, 20, "begin", "abc");
    try journal.record(a, io, root, 22, "done", "abc");
    try record(a, io, root, 30, &.{ "htop", "btop" });
    // an apply cut off halfway doesn't stop pacman's changes counting.
    try journal.record(a, io, root, 40, "begin", "def");
    try record(a, io, root, 50, &.{"vim"});

    const got = try since(a, io, root);
    try std.testing.expectEqual(2, got.len);
    try std.testing.expectEqual(30, got[0].time);
    try std.testing.expectEqualStrings("btop", got[0].packages[1]);
    try std.testing.expectEqualStrings("vim", got[1].packages[0]);

    // settling the cut-off apply drops what came before it, like any done
    // apply, but not pacman's run after it.
    try journal.settle(a, io, root, (try journal.unfinished(a, io, root)).?);
    const left = try since(a, io, root);
    try std.testing.expectEqual(1, left.len);
    try std.testing.expectEqualStrings("vim", left[0].packages[0]);
}
