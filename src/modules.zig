//! the running kernel's modules, kept through an apply that upgrades or
//! removes its package, as arch's kernel-modules-hook does. pacman takes
//! the old /usr/lib/modules/<release> away with the old package, and the
//! kernel that's still running can't load anything new until the reboot,
//! like a usb stick's driver. a copy goes back in its place, marked, and
//! the first `yos apply` after a reboot into another kernel removes it.

const std = @import("std");
const planner = @import("planner.zig");
const exec = @import("exec.zig");
const rootfs = @import("rootfs.zig");
const Allocator = std.mem.Allocator;

const dir_rel = "usr/lib/modules";
/// where the copy waits during the transaction.
const backup_name = ".yos-running";
/// the file in a modules directory yos put back, which no package owns.
const marker = ".yos-kept";

/// the running kernel's release, as `uname -r` prints it.
pub fn running(buf: *std.os.linux.utsname) []const u8 {
    _ = std.os.linux.uname(buf);
    return std.mem.sliceTo(&buf.release, 0);
}

/// whether `changes` upgrade or remove `pkgbase`, the package whose
/// modules the running kernel loads.
pub fn replaced(changes: []const planner.Change, pkgbase: []const u8) bool {
    for (changes) |c| {
        if (c.kind != .package and c.kind != .dependency) continue;
        if (c.op != .add and std.mem.eql(u8, c.subject, pkgbase)) return true;
    }
    return false;
}

/// what `keep` did: whether there's a copy for `restore` to put back.
pub const Kept = struct {
    release: []const u8,
    copied: bool,
};

/// copies the running kernel's modules aside when `changes` replace its
/// package. a copy that fails is skipped: the apply goes on, as it would
/// without this.
pub fn keep(a: Allocator, io: std.Io, root: []const u8, release: []const u8, changes: []const planner.Change) !Kept {
    const dir = try std.fs.path.join(a, &.{ root, dir_rel, release });
    const backup = try std.fs.path.join(a, &.{ root, dir_rel, backup_name });
    _ = try exec.run(a, io, &.{ "rm", "-rf", backup });
    var buf: [256]u8 = undefined;
    const pkgbase = std.mem.trim(u8, rootfs.readHead(io, try std.fs.path.join(a, &.{ dir, "pkgbase" }), &buf) orelse return .{ .release = release, .copied = false }, " \n");
    if (!replaced(changes, pkgbase)) return .{ .release = release, .copied = false };
    // a copy yos put back before belongs to no package, so it moves out of
    // the way: a transaction putting that release back, like a rollback
    // before the reboot, would find its files there and stop.
    const ours = rootfs.pathExists(io, try std.fs.path.join(a, &.{ dir, marker }));
    const argv: []const []const u8 = if (ours) &.{ "mv", dir, backup } else &.{ "cp", "-a", dir, backup };
    const copied = try exec.run(a, io, argv) == null;
    return .{ .release = release, .copied = copied };
}

/// puts the copy back if the transaction took the running kernel's
/// modules away, marked as yos's, and removes the copy. when the package
/// still has them, as after reinstalling the same version, they stay
/// the package's.
pub fn restore(a: Allocator, io: std.Io, root: []const u8, k: Kept) !void {
    if (!k.copied) return;
    const dir = try std.fs.path.join(a, &.{ root, dir_rel, k.release });
    const backup = try std.fs.path.join(a, &.{ root, dir_rel, backup_name });
    if (!rootfs.pathExists(io, try std.fs.path.join(a, &.{ dir, "modules.dep" }))) {
        _ = try exec.runAll(a, io, &.{
            &.{ "mkdir", "-p", dir },
            &.{ "cp", "-an", try std.fmt.allocPrint(a, "{s}/.", .{backup}), dir },
            &.{ "touch", try std.fs.path.join(a, &.{ dir, marker }) },
        });
    }
    _ = try exec.run(a, io, &.{ "rm", "-rf", backup });
}

/// the packages the kernels installed under `root` came from, whatever
/// they're called, like linux-cachyos: each /usr/lib/modules/<release>
/// has a pkgbase file naming one.
pub fn kernelPackages(a: Allocator, io: std.Io, root: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const path = try std.fs.path.join(a, &.{ root, dir_rel });
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        var buf: [256]u8 = undefined;
        const name = std.mem.trim(u8, rootfs.readHead(io, try std.fs.path.join(a, &.{ path, e.name, "pkgbase" }), &buf) orelse continue, " \n");
        if (name.len > 0) try out.append(a, try a.dupe(u8, name));
    }
    return out.items;
}

/// removes the modules yos kept for kernels other than `release`, the
/// running one.
pub fn dropKept(a: Allocator, io: std.Io, root: []const u8, release: []const u8) !void {
    const path = try std.fs.path.join(a, &.{ root, dir_rel });
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory or std.mem.eql(u8, e.name, release)) continue;
        dir.access(io, try std.fs.path.join(a, &.{ e.name, marker }), .{}) catch continue;
        _ = try exec.run(a, io, &.{ "rm", "-rf", try std.fs.path.join(a, &.{ path, e.name }) });
    }
}

const testing = std.testing;

test "the running kernel's modules outlast its package's upgrade" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "usr/lib/modules/7.1.0-arch1-1/kernel");
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/lib/modules/7.1.0-arch1-1/pkgbase", .data = "linux\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/lib/modules/7.1.0-arch1-1/modules.dep", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/lib/modules/7.1.0-arch1-1/kernel/dummy.ko", .data = "ko" });
    const upgrade = [_]planner.Change{.{ .kind = .package, .op = .change, .subject = "linux", .from = "7.1.0.arch1-1", .to = "7.2.0.arch1-1" }};
    const other = [_]planner.Change{.{ .kind = .package, .op = .change, .subject = "tree", .from = "1", .to = "2" }};

    // nothing to keep when the kernel's package stays.
    try testing.expect(!(try keep(a, io, root, "7.1.0-arch1-1", &other)).copied);
    try testing.expect(!replaced(&.{.{ .kind = .package, .op = .add, .subject = "linux", .to = "7.2.0.arch1-1" }}, "linux"));

    // pacman takes the old modules away, and the copy goes back, marked.
    const k = try keep(a, io, root, "7.1.0-arch1-1", &upgrade);
    try testing.expect(k.copied);
    try tmp.dir.deleteTree(io, "usr/lib/modules/7.1.0-arch1-1");
    try tmp.dir.createDirPath(io, "usr/lib/modules/7.2.0-arch1-1");
    try restore(a, io, root, k);
    try testing.expectEqualStrings("ko", try tmp.dir.readFileAlloc(io, "usr/lib/modules/7.1.0-arch1-1/kernel/dummy.ko", a, .limited(16)));
    try tmp.dir.access(io, "usr/lib/modules/7.1.0-arch1-1/" ++ marker, .{});
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "usr/lib/modules/" ++ backup_name, .{}));

    // still running that kernel: the next apply leaves them.
    try dropKept(a, io, root, "7.1.0-arch1-1");
    try tmp.dir.access(io, "usr/lib/modules/7.1.0-arch1-1/kernel/dummy.ko", .{});
    // going back to that kernel before the reboot: the kept copy moves
    // aside so the package's files go in, and they stay the package's.
    const back = [_]planner.Change{.{ .kind = .package, .op = .change, .subject = "linux", .from = "7.2.0.arch1-1", .to = "7.1.0.arch1-1" }};
    const k2 = try keep(a, io, root, "7.1.0-arch1-1", &back);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "usr/lib/modules/7.1.0-arch1-1", .{}));
    try tmp.dir.createDirPath(io, "usr/lib/modules/7.1.0-arch1-1/kernel");
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/lib/modules/7.1.0-arch1-1/modules.dep", .data = "" });
    try restore(a, io, root, k2);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "usr/lib/modules/7.1.0-arch1-1/" ++ marker, .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "usr/lib/modules/" ++ backup_name, .{}));
    // put the kept copy back as it was, for the rest.
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/lib/modules/7.1.0-arch1-1/" ++ marker, .data = "" });
    try tmp.dir.deleteFile(io, "usr/lib/modules/7.1.0-arch1-1/modules.dep");
    // after a reboot into the new one, they go.
    try dropKept(a, io, root, "7.2.0-arch1-1");
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "usr/lib/modules/7.1.0-arch1-1", .{}));
    try tmp.dir.access(io, "usr/lib/modules/7.2.0-arch1-1", .{});
}

test "kernel packages, by what their modules say" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "usr/lib/modules/6.17.1-cachyos/kernel");
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/lib/modules/6.17.1-cachyos/pkgbase", .data = "linux-cachyos\n" });
    try tmp.dir.createDirPath(io, "usr/lib/modules/extramodules-6.17");
    const got = try kernelPackages(a, io, root);
    try testing.expectEqual(1, got.len);
    try testing.expectEqualStrings("linux-cachyos", got[0]);
}

test "modules a reinstall leaves in place stay the package's" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "usr/lib/modules/7.1.0-arch1-1");
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/lib/modules/7.1.0-arch1-1/pkgbase", .data = "linux\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/lib/modules/7.1.0-arch1-1/modules.dep", .data = "" });
    const reinstall = [_]planner.Change{.{ .kind = .package, .op = .change, .subject = "linux", .from = "7.1.0.arch1-1", .to = "7.1.0.arch1-1" }};
    const k = try keep(a, io, root, "7.1.0-arch1-1", &reinstall);
    try restore(a, io, root, k);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "usr/lib/modules/7.1.0-arch1-1/" ++ marker, .{}));
    try dropKept(a, io, root, "7.2.0-arch1-1");
    try tmp.dir.access(io, "usr/lib/modules/7.1.0-arch1-1/pkgbase", .{});
}
