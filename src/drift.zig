//! changes made with pacman directly. a pacman hook runs `yos
//! record-pacman` after every transaction, which appends the packages it
//! touched to /var/lib/yos/drift. transactions yos runs itself are left out,
//! so what's recorded is what happened outside yos.

const std = @import("std");
const facts = @import("facts.zig");
const journal = @import("journal.zig");
const rootfs = @import("rootfs.zig");
const Allocator = std.mem.Allocator;

pub const path = "var/lib/yos/drift";

/// records a pacman transaction that touched `packages`. the hook leaves
/// out yos's own. a record that can't be written is dropped: the hook
/// mustn't fail pacman.
pub fn record(a: Allocator, io: std.Io, root: []const u8, time: i64, packages: []const []const u8) !void {
    if (packages.len == 0) return;
    try journal.appendLine(a, io, root, path, facts.PacmanChange{ .time = time, .packages = packages });
}

/// the pacman transactions since the last apply finished.
/// they're the lines past where the log ended when the apply did, which
/// its done line notes, so a clock set back since, say by ntp fixing one
/// that ran ahead, doesn't hide them. a done line without that, from an
/// older yos or a run settled later, goes by time.
pub fn since(a: Allocator, io: std.Io, root: []const u8) ![]facts.PacmanChange {
    const last = try journal.lastDoneLine(a, io, root);
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    const at = if (last) |l| l.drift else null;
    // a log shorter than that was started over.
    const by_place = if (at) |off| (try fs.readFrom(path, 0, 0)).size >= off else false;
    const text = if (by_place) (try fs.readFrom(path, at.?, journal.window)).bytes else try fs.readTail(path, journal.window);
    const after = if (by_place) std.math.minInt(i64) else if (last) |l| l.time else 0;
    var out: std.ArrayList(facts.PacmanChange) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const c = std.json.parseFromSliceLeaky(facts.PacmanChange, a, line, .{}) catch continue;
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

test "pacman's changes after an apply count, whatever the clock said" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try record(a, io, root, 10, &.{ "nano", "vi", "ed", "less", "man-db" });
    // the clock ran a day ahead during the apply, and ntp set it back.
    try journal.record(a, io, root, 86_400_000, "begin", "abc");
    try journal.recordDone(a, io, root, 86_400_010, "abc");
    try record(a, io, root, 500, &.{"htop"});
    const got = try since(a, io, root);
    try std.testing.expectEqual(1, got.len);
    try std.testing.expectEqualStrings("htop", got[0].packages[0]);

    // a drift log started over goes by time.
    try std.Io.Dir.cwd().deleteFile(io, try std.fs.path.join(a, &.{ root, path }));
    try record(a, io, root, 86_400_020, &.{"vim"});
    const after = try since(a, io, root);
    try std.testing.expectEqual(1, after.len);
    try std.testing.expectEqualStrings("vim", after[0].packages[0]);
}
