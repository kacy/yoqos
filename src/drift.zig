//! changes made with pacman directly. a pacman hook runs `os
//! record-pacman` after every transaction, which appends the packages it
//! touched to /var/lib/yoq/drift. transactions os runs itself are left out,
//! so what's recorded is what happened outside os.

const std = @import("std");
const facts = @import("facts.zig");
const journal = @import("journal.zig");
const rootfs = @import("rootfs.zig");
const Allocator = std.mem.Allocator;

const path = "var/lib/yoq/drift";

/// records a pacman transaction that touched `packages`, unless it's one
/// an apply is running. a record that can't be written is dropped: the
/// hook mustn't fail pacman.
pub fn record(a: Allocator, io: std.Io, root: []const u8, time: i64, packages: []const []const u8) !void {
    if (packages.len == 0 or try journal.unfinished(a, io, root) != null) return;
    var line: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(facts.PacmanChange{ .time = time, .packages = packages }, .{}, &line.writer);
    try line.writer.writeByte('\n');
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    fs.append(path, line.written()) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.WriteFailed => {},
    };
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

test "pacman's changes since the last apply, without os's own" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try record(a, io, root, 10, &.{"nano"});
    try journal.record(a, io, root, 20, "begin", "abc");
    // os's own transaction runs the hook too.
    try record(a, io, root, 21, &.{"git"});
    try journal.record(a, io, root, 22, "done", "abc");
    try record(a, io, root, 30, &.{ "htop", "btop" });

    const got = try since(a, io, root);
    try std.testing.expectEqual(1, got.len);
    try std.testing.expectEqual(30, got[0].time);
    try std.testing.expectEqualStrings("btop", got[0].packages[1]);
}
