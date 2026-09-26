//! the apply journal, /var/lib/yoq/journal: a json line when an apply
//! starts and one when it ends, so a run that never finished shows up next
//! time, and the pacman hook can tell os's own transactions from others.

const std = @import("std");
const rootfs = @import("rootfs.zig");
const Allocator = std.mem.Allocator;

const path = "var/lib/yoq/journal";

const Line = struct { time: i64, event: []const u8, plan: []const u8 };

/// appends one line. a journal that can't be written doesn't stop the
/// apply.
pub fn record(a: Allocator, io: std.Io, root: []const u8, time: i64, event: []const u8, hash: []const u8) !void {
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    const line = try std.fmt.allocPrint(a, "{{\"time\":{d},\"event\":\"{s}\",\"plan\":\"{s}\"}}\n", .{ time, event, hash });
    fs.append(path, line) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.WriteFailed => {},
    };
}

/// the plan hash of a run that started and never finished, if the last one
/// didn't.
pub fn unfinished(a: Allocator, io: std.Io, root: []const u8) !?[]const u8 {
    const last = try lastLine(a, io, root) orelse return null;
    return if (std.mem.eql(u8, last.event, "begin")) last.plan else null;
}

/// when the last apply that got to the end finished, or null if none has.
pub fn lastDone(a: Allocator, io: std.Io, root: []const u8) !?i64 {
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    var done: ?i64 = null;
    var lines = std.mem.tokenizeScalar(u8, try fs.read(path), '\n');
    while (lines.next()) |text| {
        const line = std.json.parseFromSliceLeaky(Line, a, text, .{}) catch continue;
        if (std.mem.eql(u8, line.event, "done")) done = line.time;
    }
    return done;
}

fn lastLine(a: Allocator, io: std.Io, root: []const u8) !?Line {
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    const trimmed = std.mem.trimEnd(u8, try fs.read(path), "\n");
    const last = trimmed[if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |i| i + 1 else 0..];
    return std.json.parseFromSliceLeaky(Line, a, last, .{}) catch null;
}

test "the journal notices an unfinished run, and knows the last done" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try std.testing.expectEqual(null, try unfinished(a, io, root));
    try std.testing.expectEqual(null, try lastDone(a, io, root));
    try record(a, io, root, 1, "begin", "abc");
    try std.testing.expectEqualStrings("abc", (try unfinished(a, io, root)).?);
    try record(a, io, root, 2, "done", "abc");
    try record(a, io, root, 3, "begin", "def");
    try record(a, io, root, 4, "failed", "def");
    try std.testing.expectEqual(null, try unfinished(a, io, root));
    try std.testing.expectEqual(2, (try lastDone(a, io, root)).?);
}
