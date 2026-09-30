//! the apply journal, /var/lib/yoq/journal: a json line when an apply
//! starts and one when it ends, so a run that never finished shows up next
//! time, and the pacman hook can tell os's own transactions from others.
//! os's other events, like commits and generations, go in it too (see
//! events.zig); the readers here skip those.

const std = @import("std");
const rootfs = @import("rootfs.zig");
const Allocator = std.mem.Allocator;

pub const path = "var/lib/yoq/journal";

/// `time` is unix milliseconds: seconds are too coarse to tell an apply
/// from a pacman run right after it.
pub const Line = struct { time: i64, event: []const u8, plan: []const u8 };

/// the time to record, in unix milliseconds.
pub fn now(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

/// appends one line. a journal that can't be written doesn't stop the
/// apply.
pub fn record(a: Allocator, io: std.Io, root: []const u8, time: i64, event: []const u8, hash: []const u8) !void {
    try appendLine(a, io, root, path, Line{ .time = time, .event = event, .plan = hash });
}

/// appends `value` as a json line to `file` under `root`, or drops it if
/// the file can't be written.
pub fn appendLine(a: Allocator, io: std.Io, root: []const u8, file: []const u8, value: anytype) !void {
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    const line = try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(value, .{ .emit_null_optional_fields = false })});
    fs.append(file, line) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.WriteFailed => {},
    };
}

/// the begin line of a run that started and never finished, if the last
/// one didn't.
pub fn unfinished(a: Allocator, io: std.Io, root: []const u8) !?Line {
    const last = (try scan(a, io, root)).last orelse return null;
    return if (std.mem.eql(u8, last.event, "begin")) last else null;
}

/// records a run that was cut off after it made its changes as done. the
/// line carries the run's own start time, not now: the run's pacman
/// transactions never reached the drift log, and a pacman run outside os
/// after the cut-off should still count as drift.
pub fn settle(a: Allocator, io: std.Io, root: []const u8, begin: Line) !void {
    try record(a, io, root, begin.time, "done", begin.plan);
}

/// when the last apply that got to the end finished, or null if none has.
pub fn lastDone(a: Allocator, io: std.Io, root: []const u8) !?i64 {
    return (try scan(a, io, root)).done;
}

/// the journal's last apply line, and when the last apply that got to the
/// end finished.
fn scan(a: Allocator, io: std.Io, root: []const u8) !struct { last: ?Line = null, done: ?i64 = null } {
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    var last: ?Line = null;
    var done: ?i64 = null;
    var lines = std.mem.tokenizeScalar(u8, try fs.read(path), '\n');
    while (lines.next()) |text| {
        const line = std.json.parseFromSliceLeaky(Line, a, text, .{ .ignore_unknown_fields = true }) catch continue;
        last = line;
        if (std.mem.eql(u8, line.event, "done")) done = line.time;
    }
    return .{ .last = last, .done = done };
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
    try std.testing.expectEqualStrings("abc", (try unfinished(a, io, root)).?.plan);
    try record(a, io, root, 2, "done", "abc");
    try record(a, io, root, 3, "begin", "def");
    try record(a, io, root, 4, "failed", "def");
    try std.testing.expectEqual(null, try unfinished(a, io, root));
    try std.testing.expectEqual(2, (try lastDone(a, io, root)).?);
    // other events after a run cut off don't hide it.
    try record(a, io, root, 5, "begin", "ghi");
    try appendLine(a, io, root, path, .{ .time = 6, .kind = "trial", .step = "passed" });
    try std.testing.expectEqualStrings("ghi", (try unfinished(a, io, root)).?.plan);
}

test "settling a cut-off run leaves an ordinary done line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try record(a, io, root, 1, "begin", "abc");
    try record(a, io, root, 2, "done", "abc");
    try record(a, io, root, 10, "begin", "def");
    try appendLine(a, io, root, path, .{ .time = 11, .kind = "trial", .step = "passed" });
    try settle(a, io, root, (try unfinished(a, io, root)).?);
    try std.testing.expectEqual(null, try unfinished(a, io, root));
    try std.testing.expectEqual(10, (try lastDone(a, io, root)).?);
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    const text = std.mem.trimEnd(u8, try fs.read(path), "\n");
    const last = text[std.mem.lastIndexOfScalar(u8, text, '\n').? + 1 ..];
    try std.testing.expectEqualStrings("{\"time\":10,\"event\":\"done\",\"plan\":\"def\"}", last);
}
