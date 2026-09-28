//! generations on the rollback rung: where they live on btrfs, and what
//! os keeps about each one. this part is pure; menu.zig has the boot menu,
//! and cmd/enable_rollback.zig and apply do the work.
//!
//! the layout, under the btrfs top level:
//!   @roots/<n>       writable roots: the one running, and the one before it
//!   @roots/boot-<n>  a fresh writable copy of generation n, for its menu
//!                    entry, remade whenever the menu is written
//!   @gens/<n>        a read-only record of every generation
//!   @var             /var, which never rolls back

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const roots_dir = "@roots";
pub const gens_dir = "@gens";
pub const var_subvol = "@var";

/// data directories besides /var that no generation holds, and the
/// subvolume each gets when it's inside the root.
pub const DataDir = struct { dir: []const u8, subvol: []const u8 };

pub const data_dirs = [_]DataDir{
    .{ .dir = "home", .subvol = "@home" },
    .{ .dir = "root", .subvol = "@root" },
    .{ .dir = "srv", .subvol = "@srv" },
    .{ .dir = "usr/local", .subvol = "@usrlocal" },
};

/// where the btrfs top level is mounted while os works on it.
pub const top_mount = "/run/yoq/top";

/// generation records, one json file each, under /var so they outlive
/// every rollback. relative to a var directory.
pub const records_dir = "lib/yoq/generations";

/// whether a machine runs a generation: its root is one of @roots.
pub fn running(root_subvol: ?[]const u8) bool {
    const sv = root_subvol orelse return false;
    return std.mem.startsWith(u8, sv, "/" ++ roots_dir ++ "/");
}

/// what os keeps about a generation.
pub const Record = struct {
    n: u32,
    /// unix seconds.
    time: i64,
    /// its writable root, under the top level.
    root: []const u8,
    /// what made it, like "enable-rollback" or "add fd".
    reason: []const u8,
    /// for the first generation: the root the machine ran before, still
    /// bootable from the menu.
    from: ?[]const u8 = null,
    /// the config directory and its commit when the generation was made,
    /// so a rollback can put that config back.
    config_dir: ?[]const u8 = null,
    config_rev: ?[]const u8 = null,
    /// kept by garbage collection however old it gets.
    pinned: bool = false,
};

/// how many generations garbage collection keeps, besides pinned ones and
/// the first.
pub const default_keep = 5;

/// the generations to keep of `records`, sorted by number: the newest
/// `keep`, the first, and every pinned one.
pub fn keeps(r: Record, records: []const Record, keep: usize) bool {
    if (r.n == 1 or r.pinned) return true;
    var newer: usize = 0;
    for (records) |o| newer += @intFromBool(o.n > r.n);
    return newer < keep;
}

/// a config directory at one commit.
pub const Config = struct { dir: []const u8, rev: []const u8 };

/// a file in /boot that belongs to the root beside it: a kernel, a
/// microcode image, or an initramfs. fallback images are left out; they're
/// large and no menu entry uses them.
pub fn bootFile(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "vmlinuz-") or std.mem.endsWith(u8, name, "-ucode.img")) return true;
    return std.mem.startsWith(u8, name, "initramfs-") and std.mem.endsWith(u8, name, ".img") and !std.mem.endsWith(u8, name, "-fallback.img");
}

/// the writable copy the menu boots for an older generation.
pub fn bootCopy(a: Allocator, n: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "/{s}/boot-{d}", .{ roots_dir, n });
}

/// the generation whose copy the root at `subvol` is, if it's one.
pub fn bootCopyOf(subvol: []const u8) ?u32 {
    const prefix = "/" ++ roots_dir ++ "/boot-";
    if (!std.mem.startsWith(u8, subvol, prefix)) return null;
    return std.fmt.parseInt(u32, subvol[prefix.len..], 10) catch null;
}

pub fn find(records: []const Record, n: u32) ?Record {
    for (records) |r| {
        if (r.n == n) return r;
    }
    return null;
}

/// a generation's kernel command line, from the running one: the root is
/// the btrfs filesystem by uuid, mounted from `subvol`; other rootflags
/// and arguments stay as they are.
pub fn kernelArgs(a: Allocator, cmdline: []const u8, root_uuid: []const u8, subvol: []const u8) ![]const u8 {
    var flags: std.ArrayList(u8) = .empty;
    try flags.print(a, "subvol={s}", .{subvol});
    var rest: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeAny(u8, cmdline, " \t\n");
    while (words.next()) |w| {
        if (std.mem.startsWith(u8, w, "BOOT_IMAGE=") or std.mem.startsWith(u8, w, "initrd=") or std.mem.startsWith(u8, w, "root=")) continue;
        // grub adds this on a trial boot; it's never part of an entry.
        if (std.mem.eql(u8, w, "yoq.trial")) continue;
        if (std.mem.startsWith(u8, w, "rootflags=")) {
            var opts = std.mem.tokenizeScalar(u8, w["rootflags=".len..], ',');
            while (opts.next()) |o| {
                if (std.mem.startsWith(u8, o, "subvol=") or std.mem.startsWith(u8, o, "subvolid=")) continue;
                try flags.print(a, ",{s}", .{o});
            }
            continue;
        }
        try rest.print(a, " {s}", .{w});
    }
    // a kernel that panics reboots, so a generation on trial falls back.
    const panic = if (std.mem.indexOf(u8, rest.items, " panic=") == null) " panic=10" else "";
    return std.fmt.allocPrint(a, "root=UUID={s} rootflags={s}{s}{s}", .{ root_uuid, flags.items, rest.items, panic });
}

// -- tests --

const testing = std.testing;

test "which generations collection keeps" {
    const recs = [_]Record{
        .{ .n = 1, .time = 0, .root = "@roots/1", .reason = "enable-rollback" },
        .{ .n = 2, .time = 0, .root = "@roots/1", .reason = "a" },
        .{ .n = 3, .time = 0, .root = "@roots/1", .reason = "b", .pinned = true },
        .{ .n = 4, .time = 0, .root = "@roots/1", .reason = "c" },
        .{ .n = 5, .time = 0, .root = "@roots/1", .reason = "d" },
        .{ .n = 6, .time = 0, .root = "@roots/1", .reason = "e" },
    };
    var kept: [6]bool = undefined;
    for (recs, &kept) |r, *k| k.* = keeps(r, &recs, 2);
    try testing.expectEqualSlices(bool, &.{ true, false, true, false, true, true }, &kept);
}

test "a generation's kernel command line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cmdline = "BOOT_IMAGE=/boot/vmlinuz-linux root=UUID=abc rw net.ifnames=0 rootflags=compress=zstd:1,subvol=/@ console=ttyS0,115200 yoq.trial\n";
    try testing.expectEqualStrings("root=UUID=abc rootflags=subvol=/@roots/1,compress=zstd:1 rw net.ifnames=0 console=ttyS0,115200 panic=10", try kernelArgs(arena.allocator(), cmdline, "abc", "/@roots/1"));
    try testing.expectEqualStrings("root=UUID=abc rootflags=subvol=/ rw panic=30", try kernelArgs(arena.allocator(), "rw panic=30", "abc", "/"));
    try testing.expectEqualStrings("/@roots/boot-2", try bootCopy(arena.allocator(), 2));
    try testing.expectEqual(2, bootCopyOf("/@roots/boot-2"));
    try testing.expectEqual(null, bootCopyOf("/@roots/2"));
}

test "which files in /boot a root keeps" {
    for ([_][]const u8{ "vmlinuz-linux", "vmlinuz-linux-lts", "amd-ucode.img", "initramfs-linux.img" }) |f| try testing.expect(bootFile(f));
    for ([_][]const u8{ "initramfs-linux-fallback.img", "grub", "EFI", "loader.conf" }) |f| try testing.expect(!bootFile(f));
}
