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

/// the name the root's luks volume is opened as on the new machine, which
/// its kernel command line gives sd-encrypt: /dev/mapper/root.
pub const luks_name = "root";

/// the name it's opened as during the install, which nothing on the live
/// system is likely to use already.
pub const luks_install_name = "yoq-install";

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
    /// btrfs-progs, which os uses for generations, and the initramfs to
    /// check the root with fsck.btrfs.
    has_btrfs_progs: bool,
    /// tools the install runs that aren't on the live system.
    missing: []const []const u8 = &.{},
    /// luks2 under the btrfs filesystem, and whether the tpm unlocks it.
    encrypt: bool = false,
    tpm: bool = false,
    /// the passphrase comes from a file, given with --passphrase-file.
    passphrase_file: bool = false,
    /// there's a terminal for cryptsetup to ask for it on.
    interactive: bool = false,
    /// the config has `[boot] encrypt = true`, which the new machine's
    /// initramfs needs to unlock its root.
    config_encrypt: bool = false,
    /// the config has `[boot] secure_boot = true`, which needs keys the
    /// new machine doesn't have yet.
    secure_boot: bool = false,
    /// secrets the config names that the live system has no value for.
    /// the build writes each file from this system's own.
    secrets_unset: []const []const u8 = &.{},
    /// the live system has a tpm 2.0, and the lock has tpm2-tss, which the new
    /// machine's initramfs uses to unlock with it.
    has_tpm: bool = false,
    has_tpm2_tss: bool = false,
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

/// what --encrypt and --tpm run besides: cryptsetup, and systemd's tool
/// that puts a tpm key in a luks volume.
pub const encrypt_tools = [_][]const u8{"cryptsetup"};
pub const tpm_tools = [_][]const u8{"systemd-cryptenroll"};

/// the tpm2-tss library systemd-cryptenroll loads to talk to the tpm.
/// it's missing as "tpm2-tss", the package that has it.
pub const tpm_library = "/usr/lib/libtss2-esys.so.0";

/// whether a tpm's tpm_version_major file in sysfs says it's a tpm 2.0,
/// the only kind systemd-cryptenroll and sd-encrypt use.
pub fn isTpm2(version_major: ?[]const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, version_major orelse return false, " \n"), "2");
}

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
        .fix = try std.fmt.allocPrint(a, "install them on the live system first: `pacman -S dosfstools btrfs-progs grub git{s}{s}`.", .{ if (f.encrypt) " cryptsetup" else "", if (f.tpm) " tpm2-tss" else "" }),
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
    if (f.encrypt) try encryptChecks(a, f, &checks);
    try checks.append(a, .{
        .what = "aur packages",
        .ok = f.aur == 0,
        .found = try std.fmt.allocPrint(a, "{d}", .{f.aur}),
        .fix = "aur packages build on a running machine. install without them, then add them back and run `os update` there.",
    });
    try checks.append(a, .{
        .what = "btrfs tools",
        .ok = f.has_btrfs_progs,
        .found = if (f.has_btrfs_progs) "in the lock" else "no btrfs-progs in the lock",
        .fix = "the new machine's root is btrfs: os keeps its generations with btrfs-progs, and the initramfs checks the root with its fsck.btrfs. add btrfs-progs to packages.",
    });
    if (f.secrets_unset.len > 0) try checks.append(a, .{
        .what = "secrets",
        .ok = false,
        .found = try std.fmt.allocPrint(a, "not set here: {s}", .{try std.mem.join(a, ", ", f.secrets_unset)}),
        .fix = "the build writes them from this live system's values. set each with `os secret set <name>` here first; the new machine needs them set again once it runs.",
    });
    if (f.secure_boot) try checks.append(a, .{
        .what = "secure boot",
        .ok = false,
        .found = "[boot] secure_boot = true",
        .fix = "its images are signed with the machine's own keys, which don't exist before it does. install without it, then make keys with sbctl on the new machine and turn it on there.",
    });
    var summary: std.ArrayList([]const u8) = .empty;
    try summary.append(a, try std.fmt.allocPrint(a, "install {s} on {s} ({d} GiB). everything on it is erased.", .{ f.host, f.disk, f.size >> 30 }));
    try summary.append(a, "");
    try summary.append(a, try std.fmt.allocPrint(a, "disk      an esp of {d} MiB at /boot, and btrfs for the rest:", .{esp_mib}));
    try summary.append(a, "          @roots/1, @var, @home, @root, @srv, @usrlocal");
    if (f.encrypt) {
        try summary.append(a, "encrypt   luks2 under btrfs, opened at boot as /dev/mapper/" ++ luks_name);
        try summary.append(a, if (f.tpm)
            "          the tpm unlocks it by itself, and the passphrase still works"
        else
            "          the passphrase unlocks it, typed at every boot");
    }
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

/// what --encrypt needs: the config's initramfs key, a passphrase, and,
/// with --tpm, a tpm and what unlocks with it.
fn encryptChecks(a: Allocator, f: Found, checks: *std.ArrayList(enable.Check)) !void {
    try checks.append(a, .{
        .what = "encryption in the config",
        .ok = f.config_encrypt,
        .found = if (f.config_encrypt) "[boot] encrypt = true" else "no [boot] encrypt",
        .fix = "the new machine's initramfs has to unlock its root. put `encrypt = true` under [boot] in the config, and commit it.",
    });
    try checks.append(a, .{
        .what = "passphrase",
        .ok = f.passphrase_file or f.interactive,
        .found = if (f.passphrase_file) "from --passphrase-file" else if (f.interactive) "cryptsetup asks for it" else "no terminal to type it on",
        .fix = "run os install on a terminal, where cryptsetup asks for it, or pass --passphrase-file <file>.",
    });
    if (!f.tpm) return;
    try checks.append(a, .{
        .what = "tpm",
        .ok = f.has_tpm and f.has_tpm2_tss,
        .found = if (!f.has_tpm) "no tpm 2.0 on this machine" else if (!f.has_tpm2_tss) "no tpm2-tss in the lock" else "tpm2, and tpm2-tss in the lock",
        .fix = if (!f.has_tpm)
            "--tpm needs a tpm 2.0, turned on in the firmware. install without --tpm to unlock with the passphrase alone."
        else
            "the initramfs unlocks with the tpm through tpm2-tss. add tpm2-tss to packages.",
    });
}

/// the arguments that unlock the new machine's root at boot, for
/// sd-encrypt: its luks volume by uuid, opened as /dev/mapper/root, and
/// the tpm tried first with --tpm.
pub fn luksArgs(a: Allocator, luks_uuid: []const u8, tpm: bool) ![]const u8 {
    return std.fmt.allocPrint(a, "rd.luks.name={s}={s}{s}", .{ luks_uuid, luks_name, if (tpm) " rd.luks.options=tpm2-device=auto" else "" });
}

/// the longest passphrase --passphrase-file reads.
pub const max_passphrase = 4096;

pub const Passphrase = union(enum) {
    ok: []u8,
    /// what's wrong with the file, after its name.
    problem: []const u8,
};

/// a passphrase file's contents, as the passphrase it holds: without the
/// newline an editor or echo leaves at the end, so typing it at boot
/// matches. a newline before that couldn't be typed at all.
pub fn passphrase(text: []u8) Passphrase {
    var end = text.len;
    if (end > 0 and text[end - 1] == '\n') end -= 1;
    if (end > 0 and text[end - 1] == '\r') end -= 1;
    if (end == 0) return .{ .problem = "has no passphrase in it" };
    if (std.mem.indexOfAny(u8, text[0..end], "\r\n") != null) return .{ .problem = "has more than one line, and a passphrase typed at boot can't" };
    return .{ .ok = text[0..end] };
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
        .has_btrfs_progs = true,
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
    // generations on btrfs need btrfs-progs.
    f.has_btrfs_progs = false;
    const s = try plan(a, f);
    try testing.expect(!s.ready());
    try testing.expectEqualStrings("no btrfs-progs in the lock", s.checks[s.checks.len - 1].found);
}

test "an encrypted install" {
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
        .users = &.{},
        .services = 1,
        .aur = 0,
        .lock_date = "2026-09-29",
        .today = "2026-09-29",
        .update = true,
        .has_kernel = true,
        .has_grub = true,
        .has_btrfs_progs = true,
        .encrypt = true,
        .interactive = true,
        .config_encrypt = true,
    };
    var p = try plan(a, f);
    try testing.expect(p.ready());
    var out: std.Io.Writer.Allocating = .init(a);
    try writeText(&out.writer, &p);
    try testing.expect(std.mem.indexOf(u8, out.written(),
        \\  ok  passphrase: cryptsetup asks for it
    ) != null);
    try testing.expect(std.mem.indexOf(u8, out.written(),
        \\          @roots/1, @var, @home, @root, @srv, @usrlocal
        \\encrypt   luks2 under btrfs, opened at boot as /dev/mapper/root
        \\          the passphrase unlocks it, typed at every boot
        \\
    ) != null);

    // the config has to build an initramfs that unlocks it.
    f.config_encrypt = false;
    p = try plan(a, f);
    try testing.expect(!p.ready());
    try testing.expectEqualStrings("no [boot] encrypt", p.checks[4].found);
    f.config_encrypt = true;
    // no terminal, and no file.
    f.interactive = false;
    try testing.expect(!(try plan(a, f)).ready());
    f.passphrase_file = true;
    try testing.expect((try plan(a, f)).ready());

    f.tpm = true;
    p = try plan(a, f);
    try testing.expect(!p.ready());
    try testing.expectEqualStrings("no tpm 2.0 on this machine", p.checks[6].found);
    f.has_tpm = true;
    try testing.expectEqualStrings("no tpm2-tss in the lock", (try plan(a, f)).checks[6].found);
    f.has_tpm2_tss = true;
    f.missing = &.{"tpm2-tss"};
    p = try plan(a, f);
    try testing.expectEqualStrings("install them on the live system first: `pacman -S dosfstools btrfs-progs grub git cryptsetup tpm2-tss`.", p.checks[1].fix.?);
    f.missing = &.{};
    p = try plan(a, f);
    try testing.expect(p.ready());
    try testing.expectEqualStrings("          the tpm unlocks it by itself, and the passphrase still works", p.summary[5]);

    try testing.expectEqualStrings("rd.luks.name=0f7a1c2e-9b3d-4e5f-8a6b-7c8d9e0f1a2b=root", try luksArgs(a, "0f7a1c2e-9b3d-4e5f-8a6b-7c8d9e0f1a2b", false));
    try testing.expectEqualStrings("rd.luks.name=u=root rd.luks.options=tpm2-device=auto", try luksArgs(a, "u", true));

    // a tpm 1.2 is still a tpm in sysfs, and no use here.
    try testing.expect(isTpm2("2\n"));
    try testing.expect(!isTpm2("1\n"));
    try testing.expect(!isTpm2(null));
}

test "a passphrase file's passphrase" {
    var a = "hunter2\n".*;
    try testing.expectEqualStrings("hunter2", passphrase(&a).ok);
    var b = "hunter2".*;
    try testing.expectEqualStrings("hunter2", passphrase(&b).ok);
    var c = "two words \r\n".*;
    try testing.expectEqualStrings("two words ", passphrase(&c).ok);
    var d = "\n".*;
    try testing.expectEqualStrings("has no passphrase in it", passphrase(&d).problem);
    // cryptsetup would take the newline as part of it, and nobody could
    // type it at the prompt.
    var e = "hunter2\nhunter3\n".*;
    try testing.expectEqualStrings("has more than one line, and a passphrase typed at boot can't", passphrase(&e).problem);
}

test "secure boot waits for the installed machine" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Found = .{
        .disk = "/dev/vdb",
        .size = 20 << 30,
        .whole = true,
        .mounted = false,
        .has_btrfs_progs = true,
        .uefi = true,
        .host = "atlas",
        .packages = 412,
        .users = &.{},
        .services = 1,
        .aur = 0,
        .lock_date = "2026-09-29",
        .today = "2026-09-29",
        .update = true,
        .has_kernel = true,
        .has_grub = true,
    };
    try testing.expect((try plan(a, f)).ready());
    f.secure_boot = true;
    const p = try plan(a, f);
    try testing.expect(!p.ready());
    try testing.expectEqualStrings("secure boot", p.checks[p.checks.len - 1].what);
}

test "secrets the live system doesn't have stop the install before the disk" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f: Found = .{
        .disk = "/dev/vdb",
        .size = 20 << 30,
        .whole = true,
        .mounted = false,
        .has_btrfs_progs = true,
        .uefi = true,
        .host = "atlas",
        .packages = 412,
        .users = &.{},
        .services = 1,
        .aur = 0,
        .lock_date = "2026-09-29",
        .today = "2026-09-29",
        .update = true,
        .has_kernel = true,
        .has_grub = true,
        .secrets_unset = &.{ "vpn", "wifi/home" },
    };
    const p = try plan(a, f);
    try testing.expect(!p.ready());
    const last = p.checks[p.checks.len - 1];
    try testing.expectEqualStrings("secrets", last.what);
    try testing.expectEqualStrings("not set here: vpn, wifi/home", last.found);
}

fn notes(lines: []const []const u8) usize {
    var n: usize = 0;
    for (lines) |l| n += @intFromBool(std.mem.startsWith(u8, l, "note: "));
    return n;
}
