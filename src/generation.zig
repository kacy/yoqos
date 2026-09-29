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

/// where the rollback rung keeps the pacman database, in /usr beside the
/// packages it describes. /var/lib/pacman links to it.
pub const pacman_db = "usr/lib/sysimage/pacman";

/// grub's env file, from the top of the esp.
pub const grubenv = "yoq/grubenv";

/// where a staged root is noted until it has booted well: with /boot as
/// the esp, it boots its own kernel till then, and moves it onto the esp.
pub const unsettled_path = "/var/lib/yoq/unsettled";

/// where enable-rollback notes the root the next boot runs, in the /var
/// the machine runs now, so nothing changes the root it's leaving.
pub const pending_path = "/var/lib/yoq/pending";

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

/// a btrfs mount option that picks the subvolume, which each root sets
/// for itself.
pub fn subvolOption(o: []const u8) bool {
    return std.mem.startsWith(u8, o, "subvol=") or std.mem.startsWith(u8, o, "subvolid=");
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
        // a trial boot adds this; it's never part of an entry.
        if (std.mem.eql(u8, w, "yoq.trial")) continue;
        if (std.mem.startsWith(u8, w, "rootflags=")) {
            var opts = std.mem.tokenizeScalar(u8, w["rootflags=".len..], ',');
            while (opts.next()) |o| {
                if (subvolOption(o)) continue;
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

/// `target`'s shadow file with the password hash, and when it last
/// changed, taken from `current` for every user both have. users only in
/// one of them stay as they are.
pub fn mergeShadow(a: Allocator, current: []const u8, target: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, target, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const name = line[0 .. std.mem.indexOfScalar(u8, line, ':') orelse line.len];
        const now = findUser(current, name) orelse {
            try out.print(a, "{s}\n", .{line});
            continue;
        };
        // name:hash:lastchange:rest
        var theirs = std.mem.splitScalar(u8, line, ':');
        var ours = std.mem.splitScalar(u8, now, ':');
        _ = theirs.next();
        _ = ours.next();
        const hash = ours.next() orelse "";
        const changed = ours.next() orelse "";
        _ = theirs.next();
        _ = theirs.next();
        try out.print(a, "{s}:{s}:{s}:{s}\n", .{ name, hash, changed, theirs.rest() });
    }
    return out.items;
}

fn findUser(shadow: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, shadow, '\n');
    while (lines.next()) |line| {
        if (line.len > name.len and std.mem.startsWith(u8, line, name) and line[name.len] == ':') return line;
    }
    return null;
}

/// the number the next generation gets.
pub fn next(records: []const Record) u32 {
    var n: u32 = 1;
    for (records) |r| n = @max(n, r.n + 1);
    return n;
}

/// "yoq 2 · 2026-09-26 · add fd".
pub fn title(a: Allocator, r: Record) ![]const u8 {
    return std.fmt.allocPrint(a, "yoq {d} · {s} · {s}", .{ r.n, try dateOf(a, r.time), r.reason });
}

/// "2026-09-26" for unix seconds.
pub fn dateOf(a: Allocator, secs: i64) ![]const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    return std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2}", .{ day.year, md.month.numeric(), md.day_index + 1 });
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

test "passwords carry over, users don't" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const merged = try mergeShadow(arena.allocator(),
        \\root:$6$new$root:20000::::::
        \\kacy:$6$new$kacy:20001:0:99999:7:::
        \\newuser:$6$x:20002::::::
        \\
    ,
        \\root:$6$old$root:19000::::::
        \\kacy:!:19001:0:99999:7:::
        \\olduser:$6$y:19002::::::
        \\
    );
    try testing.expectEqualStrings(
        \\root:$6$new$root:20000::::::
        \\kacy:$6$new$kacy:20001:0:99999:7:::
        \\olduser:$6$y:19002::::::
        \\
    , merged);
}
