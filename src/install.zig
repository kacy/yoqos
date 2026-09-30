//! what `os install` checks and does, worked out from what it found. it
//! puts a config repository's machine on a blank disk, from a live arch
//! system: one esp, one btrfs filesystem with the layout enable-rollback
//! makes, the clean build in generation 1, and grub. like enable.zig, it
//! reads no files and runs nothing.

const std = @import("std");
const enable = @import("enable.zig");
const Allocator = std.mem.Allocator;

/// where the new machine is mounted while it's built.
pub const target = "/mnt/yoq";

/// the esp's size. kernels and initramfs images live there, with copies
/// for generations, so it's generous.
pub const esp_mib = 1024;

/// the smallest disk worth installing on.
pub const min_bytes: u64 = 16 << 30;

/// what os install found before it asks.
pub const Found = struct {
    disk: []const u8,
    /// bytes, or 0 if it isn't a disk os could read.
    size: u64,
    /// it's a whole disk, not a partition.
    whole: bool,
    /// something on it is mounted.
    mounted: bool,
    uefi: bool,
    /// the host the config is for, and what it asks for.
    host: []const u8,
    packages: usize,
    users: []const []const u8,
    services: usize,
    aur: usize,
    /// the lock's date, and today's.
    lock_date: []const u8,
    today: []const u8,
    /// the lock resolves to today's packages before the install.
    update: bool,
    /// the lock has these.
    has_kernel: bool,
    has_grub: bool,
    /// tools the install runs that aren't on the live system.
    missing: []const []const u8 = &.{},
    /// what a new machine can't do without, which a config written for
    /// another one may lack. the plan notes each that's missing.
    virtual: bool = false,
    firmware: bool = true,
    network: bool = true,
    sudo_user: bool = true,
};

/// what the install runs, from arch's live iso: its packages are
/// util-linux, dosfstools, btrfs-progs, grub, and git.
pub const tools = [_][]const u8{ "wipefs", "sfdisk", "udevadm", "blkid", "mkfs.fat", "mkfs.btrfs", "grub-install", "grub-editenv", "git" };

pub const Plan = struct {
    checks: []const enable.Check,
    /// the lines that describe the install, before the question.
    summary: []const []const u8,

    pub fn ready(p: *const Plan) bool {
        return enable.allOk(p.checks);
    }
};

pub fn plan(a: Allocator, f: Found) !Plan {
    var checks: std.ArrayList(enable.Check) = .empty;
    try checks.append(a, .{
        .what = "firmware",
        .ok = f.uefi,
        .found = if (f.uefi) "uefi" else "bios",
        .fix = "os installs a uefi boot. boot the live system in uefi mode.",
    });
    try checks.append(a, .{
        .what = "tools",
        .ok = f.missing.len == 0,
        .found = if (f.missing.len == 0) "all here" else try std.fmt.allocPrint(a, "missing {s}", .{try std.mem.join(a, ", ", f.missing)}),
        .fix = "install them on the live system first: `pacman -S dosfstools btrfs-progs grub git`.",
    });
    try checks.append(a, .{
        .what = "disk",
        .ok = f.whole and !f.mounted and f.size >= min_bytes,
        .found = try std.fmt.allocPrint(a, "{s}, {d} GiB{s}{s}", .{ f.disk, f.size >> 30, if (f.whole) "" else ", a partition", if (f.mounted) ", in use" else "" }),
        .fix = "name a whole disk of 16 GiB or more that nothing has mounted, like /dev/nvme0n1. everything on it is erased.",
    });
    try checks.append(a, .{
        .what = "kernel and bootloader",
        .ok = f.has_kernel and f.has_grub,
        .found = if (f.has_kernel and f.has_grub) "in the lock" else if (f.has_kernel) "no grub in the lock" else "no kernel in the lock",
        .fix = "the new machine boots with grub and the kernel its lock names. add grub and a kernel, like linux, to packages.",
    });
    try checks.append(a, .{
        .what = "aur packages",
        .ok = f.aur == 0,
        .found = try std.fmt.allocPrint(a, "{d}", .{f.aur}),
        .fix = "aur packages build on a running machine. install without them, then add them back and run `os update` there.",
    });
    var summary: std.ArrayList([]const u8) = .empty;
    try summary.append(a, try std.fmt.allocPrint(a, "install {s} on {s} ({d} GiB). everything on it is erased.", .{ f.host, f.disk, f.size >> 30 }));
    try summary.append(a, "");
    try summary.append(a, try std.fmt.allocPrint(a, "disk      an esp of {d} MiB at /boot, and btrfs for the rest:", .{esp_mib}));
    try summary.append(a, "          @roots/1, @var, @home, @root, @srv, @usrlocal");
    try summary.append(a, "boot      grub, with generation 1 as its first entry");
    const from_archive = !f.update and !std.mem.eql(u8, f.lock_date, f.today);
    try summary.append(a, try std.fmt.allocPrint(a, "packages  {d} from the lock ({s}){s}", .{ f.packages, if (f.update) f.today else f.lock_date, if (from_archive) ", from the arch linux archive" else "" }));
    if (f.users.len > 0) {
        const names = try std.mem.join(a, ", ", f.users);
        try summary.append(a, try std.fmt.allocPrint(a, "users     {s}", .{names}));
    }
    try summary.append(a, try std.fmt.allocPrint(a, "services  {d}", .{f.services}));
    // not stops: a server may want no firmware or no sudo. but each is easy
    // to miss in a config written for another machine.
    if (!f.firmware and !f.virtual) try summary.append(a, "note: no linux-firmware in packages. wi-fi and some graphics won't work without it.");
    if (!f.network) try summary.append(a, "note: nothing in the config brings up a network, like `networkmanager = true` in [services].");
    if (!f.sudo_user) try summary.append(a, "note: no user in wheel with sudo installed, so only root can run anything as root.");
    return .{ .checks = checks.items, .summary = summary.items };
}

pub fn writeText(w: *std.Io.Writer, p: *const Plan) !void {
    try enable.writeChecks(w, p.checks);
    if (!p.ready()) return;
    try w.writeByte('\n');
    for (p.summary) |line| try w.print("{s}\n", .{line});
}

/// the device name of `disk`'s partition `n`: /dev/vda2, or
/// /dev/nvme0n1p2 for a disk whose name ends in a digit.
pub fn partition(a: Allocator, disk: []const u8, n: u8) ![]const u8 {
    const digit = disk.len > 0 and std.ascii.isDigit(disk[disk.len - 1]);
    return std.fmt.allocPrint(a, "{s}{s}{d}", .{ disk, if (digit) "p" else "", n });
}

/// sfdisk's script for the layout: a gpt label, the esp, and linux for
/// the rest.
pub fn partitionScript(a: Allocator) ![]const u8 {
    return std.fmt.allocPrint(a, "label: gpt\n,{d}MiB,U\n,,L\n", .{esp_mib});
}

/// the new machine's kernel arguments, from the live system's: only its
/// consoles, which say where the machine talks. the rest is about booting
/// the live image.
pub fn consoleArgs(a: Allocator, cmdline: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "rw");
    var words = std.mem.tokenizeAny(u8, cmdline, " \t\n");
    while (words.next()) |w| {
        if (std.mem.startsWith(u8, w, "console=")) try out.print(a, " {s}", .{w});
    }
    return out.items;
}

// -- tests --

const testing = std.testing;

test "partition names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/dev/vda2", try partition(a, "/dev/vda", 2));
    try testing.expectEqualStrings("/dev/nvme0n1p1", try partition(a, "/dev/nvme0n1", 1));
    try testing.expectEqualStrings("label: gpt\n,1024MiB,U\n,,L\n", try partitionScript(a));
    try testing.expectEqualStrings("rw console=tty0 console=ttyS0,115200", try consoleArgs(a, "BOOT_IMAGE=/arch/boot/x86_64/vmlinuz-linux archisobasedir=arch console=tty0 console=ttyS0,115200\n"));
}

test "what stops an install" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Found = .{
        .disk = "/dev/vdb",
        .size = 20 << 30,
        .whole = true,
        .mounted = false,
        .uefi = true,
        .host = "atlas",
        .packages = 412,
        .users = &.{"kacy"},
        .services = 18,
        .aur = 0,
        .lock_date = "2026-09-25",
        .today = "2026-09-29",
        .update = true,
        .has_kernel = true,
        .has_grub = true,
    };
    try testing.expect((try plan(a, f)).ready());
    // a lock from an earlier day installs from the archive.
    f.update = false;
    const old = try plan(a, f);
    try testing.expect(old.ready());
    try testing.expect(std.mem.endsWith(u8, old.summary[5], "from the arch linux archive"));
    f.update = true;
    f.mounted = true;
    const p = try plan(a, f);
    try testing.expect(!p.ready());
    try testing.expectEqualStrings("/dev/vdb, 20 GiB, in use", p.checks[2].found);
    f.mounted = false;
    f.missing = &.{"mkfs.btrfs"};
    const q = try plan(a, f);
    try testing.expect(!q.ready());
    try testing.expectEqualStrings("missing mkfs.btrfs", q.checks[1].found);
    f.missing = &.{};
    f.firmware = false;
    f.network = false;
    const r = try plan(a, f);
    try testing.expect(r.ready());
    try testing.expectEqual(2, notes(r.summary));
    f.virtual = true;
    try testing.expectEqual(1, notes((try plan(a, f)).summary));
}

fn notes(lines: []const []const u8) usize {
    var n: usize = 0;
    for (lines) |l| n += @intFromBool(std.mem.startsWith(u8, l, "note: "));
    return n;
}
