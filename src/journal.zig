//! the apply journal, /var/lib/yoq/journal: a json line when an apply
//! starts and one when it ends, so a run that never finished shows up next
//! time, and the pacman hook can tell os's own transactions from others.
//! os's other events, like commits and generations, go in it too (see
//! events.zig); the readers here skip those.

const std = @import("std");
const rootfs = @import("rootfs.zig");
const Allocator = std.mem.Allocator;

pub const path = "var/lib/yoq/journal";

/// the most of a log os reads at once: its end, for what happened last,
/// or a window at a time for `os events`. the logs only grow, and a few
/// years of applies are far less.
pub const window = 16 << 20;

/// `time` is unix milliseconds: seconds are too coarse to tell an apply
/// from a pacman run right after it. a done line has `drift`, how long
/// the drift log was then, so pacman runs after it are the ones past that
/// point, whatever the clock said when each was recorded.
pub const Line = struct { time: i64, event: []const u8, plan: []const u8, drift: ?u64 = null };

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
/// the file can't be written. the line goes on the end in place, in one
/// write, so another os adding a line at the same time, like the health
/// check at boot or an `os pin`, can't write over it, and a full disk
/// only needs room for the line, not a copy of the whole log.
pub fn appendLine(a: Allocator, io: std.Io, root: []const u8, file: []const u8, value: anytype) !void {
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    const line = try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(value, .{ .emit_null_optional_fields = false })});
    const p = try fs.path(file);
    if (std.fs.path.dirnamePosix(p)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch return;
    appendInPlace(try a.dupeZ(u8, p), line);
}

/// adds `line` to the end of the file at `file`, and syncs it. a line a
/// power cut left without its newline gets one first, so it stays a line
/// of its own that readers skip, instead of spoiling this one.
fn appendInPlace(file: [:0]const u8, line: []const u8) void {
    const linux = std.os.linux;
    const opened = linux.open(file, .{ .ACCMODE = .RDWR, .CREAT = true, .APPEND = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(opened) != .SUCCESS) return;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    const size = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(size) != .SUCCESS) return;
    if (size > 0) {
        var last: [1]u8 = undefined;
        if (linux.pread(fd, &last, 1, @intCast(size - 1)) == 1 and last[0] != '\n') _ = linux.write(fd, "\n", 1);
    }
    var done: usize = 0;
    while (done < line.len) {
        const n = linux.write(fd, line[done..].ptr, line.len - done);
        switch (linux.errno(n)) {
            .SUCCESS => done += n,
            .INTR => {},
            else => return,
        }
    }
    _ = linux.fsync(fd);
}

/// the begin line of a run that started and never finished, if the last
/// one didn't.
pub fn unfinished(a: Allocator, io: std.Io, root: []const u8) !?Line {
    const last = (try scan(a, io, root)).last orelse return null;
    return if (std.mem.eql(u8, last.event, "begin")) last else null;
}

/// records that a run got to the end, with how long the drift log is now.
pub fn recordDone(a: Allocator, io: std.Io, root: []const u8, time: i64, hash: []const u8) !void {
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    const size = (try fs.readFrom(drift_path, 0, 0)).size;
    try appendLine(a, io, root, path, Line{ .time = time, .event = "done", .plan = hash, .drift = size });
}

/// the drift log (see drift.zig).
const drift_path = "var/lib/yoq/drift";

/// records a run that was cut off after it made its changes as done. the
/// line carries the run's own start time, not now: the run's pacman
/// transactions never reached the drift log, and a pacman run outside os
/// after the cut-off should still count as drift.
pub fn settle(a: Allocator, io: std.Io, root: []const u8, begin: Line) !void {
    try record(a, io, root, begin.time, "done", begin.plan);
}

/// when the last apply that got to the end finished, or null if none has.
pub fn lastDone(a: Allocator, io: std.Io, root: []const u8) !?i64 {
    return if (try lastDoneLine(a, io, root)) |l| l.time else null;
}

/// the done line of the last apply that got to the end, if one has.
pub fn lastDoneLine(a: Allocator, io: std.Io, root: []const u8) !?Line {
    return (try scan(a, io, root)).done;
}

/// the journal's last apply line, and the last apply that got to the end.
fn scan(a: Allocator, io: std.Io, root: []const u8) !struct { last: ?Line = null, done: ?Line = null } {
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    var last: ?Line = null;
    var done_line: ?Line = null;
    var lines = std.mem.tokenizeScalar(u8, try fs.readTail(path, window), '\n');
    while (lines.next()) |text| {
        const line = std.json.parseFromSliceLeaky(Line, a, text, .{ .ignore_unknown_fields = true }) catch continue;
        last = line;
        if (std.mem.eql(u8, line.event, "done")) done_line = line;
    }
    return .{ .last = last, .done = done_line };
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

test "lines go on the end in place, and a cut-short line stays on its own" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try record(a, io, root, 1, "begin", "abc");
    // a writer that read the log before this line and wrote it back whole
    // would lose it; in place, the file keeps its inode and every line.
    const before = try tmp.dir.statFile(io, path, .{});
    try record(a, io, root, 2, "done", "abc");
    const after = try tmp.dir.statFile(io, path, .{});
    try std.testing.expectEqual(before.inode, after.inode);
    try std.testing.expectEqual(null, try unfinished(a, io, root));
    // a power cut left half a line; the next one isn't glued to it.
    const f = try tmp.dir.openFile(io, path, .{ .mode = .read_write });
    try f.writePositionalAll(io, "{\"time\":3,\"ev", after.size);
    f.close(io);
    try record(a, io, root, 4, "begin", "def");
    try std.testing.expectEqualStrings("def", (try unfinished(a, io, root)).?.plan);
    try std.testing.expectEqual(2, (try lastDone(a, io, root)).?);
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
