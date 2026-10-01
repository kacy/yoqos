//! unified kernel images: a kernel, its microcode and initramfs, and
//! systemd's efi stub in one file, which a bootloader starts like any efi
//! program. os builds them with ukify, from the root's own tools. without
//! secure boot, an image leaves the command line out, so one image serves
//! every generation with the same boot files, and each menu entry passes
//! its own. with secure boot, each entry's image has its command line in
//! it: the stub ignores the loader's then, and the signature keeps anyone
//! who can write the esp from adding init=/bin/sh to it. this part is
//! pure; gens.zig builds them.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// the ukify config os writes into a root for `[boot] uki`, relative to
/// the root. ukify gets it with --config, which also keeps it from reading
/// a ukify.conf of the machine's that might put a command line in. a root
/// that has it boots a unified kernel image from os's menu.
pub const config_rel = "etc/kernel/yoq-uki.conf";
pub const config_path = "/" ++ config_rel;

pub const config_content =
    \\# written by os from [boot] uki in the config. edits here are overwritten.
    \\# os builds this root's unified kernel images with these settings. it
    \\# passes the kernel command line from each boot entry, so there's none here.
    \\[UKI]
    \\
;

/// what systemd's stub and the image's small sections add to the files in
/// it, a little over the stub's size.
pub const stub_size = 1 << 18;

/// the package with ukify in it.
pub const package = "systemd-ukify";

/// where a root's inputs and the image go while ukify runs, inside the
/// root, since it runs there.
pub const work_dir = "tmp/yoq-uki";

/// the command that builds an image in the root at `root`, through
/// `chroot` (chroot itself, or a stand-in in tests), so it's that root's
/// ukify and stub. `kernel`, `initrds`, and `output` are paths inside the
/// root; initrds go in the order given, microcode first. `cmdline` goes
/// in the image when there is one.
pub fn ukifyArgv(a: Allocator, chroot: []const []const u8, root: []const u8, kernel: []const u8, initrds: []const []const u8, cmdline: ?[]const u8, output: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, chroot);
    try argv.appendSlice(a, &.{ root, "ukify", "build", "--config=" ++ config_path });
    try argv.append(a, try std.fmt.allocPrint(a, "--linux={s}", .{kernel}));
    for (initrds) |i| try argv.append(a, try std.fmt.allocPrint(a, "--initrd={s}", .{i}));
    if (cmdline) |c| try argv.append(a, try std.fmt.allocPrint(a, "--cmdline={s}", .{c}));
    try argv.append(a, try std.fmt.allocPrint(a, "--output={s}", .{output}));
    return argv.items;
}

/// where a root's kernels are, as their packages install them: one
/// directory per version, with the kernel as `vmlinuz` and the package's
/// name in `pkgbase`.
pub const modules_dir = "usr/lib/modules";

/// a kernel in a root's modules directory.
pub const Kernel = struct {
    version: []const u8,
    /// the package it's from, like "linux" or "linux-lts".
    pkgbase: []const u8,
    /// the sha256 of its vmlinuz, in hex.
    sum: []const u8,
};

/// the kernel in `kernels` an image for `/boot/<boot_name>` is built from
/// when it's signed: the one from the package the name says, like linux
/// for vmlinuz-linux, never the copy in /boot, which came from the esp.
/// with several versions of it, the one whose vmlinuz matches the copy
/// (`boot_sum`), or else the newest. null if the root has none.
pub fn signedKernel(kernels: []const Kernel, boot_name: []const u8, boot_sum: ?[]const u8) ?Kernel {
    if (!std.mem.startsWith(u8, boot_name, "vmlinuz-")) return null;
    const pkgbase = boot_name["vmlinuz-".len..];
    var best: ?Kernel = null;
    for (kernels) |k| {
        if (!std.mem.eql(u8, std.mem.trim(u8, k.pkgbase, " \n"), pkgbase)) continue;
        if (boot_sum) |s| {
            if (std.mem.eql(u8, k.sum, s)) return k;
        }
        if (best == null or std.mem.order(u8, k.version, best.?.version) == .gt) best = k;
    }
    return best;
}

/// the command that builds an initramfs for kernel `version` in the root
/// at `root`, through `chroot` (one with /proc, /sys, /dev, and /run
/// mounted, or a stand-in in tests), so it's the root's own mkinitcpio,
/// config, and modules. autodetect stays in: a signed image is only built
/// on the machine that boots it, since `os install` and clean builds
/// refuse secure boot, so what autodetect finds in /sys is right, and the
/// image is about as big as the root's own. early microcode comes from
/// mkinitcpio's microcode hook, from the root's /usr/lib/firmware.
pub fn mkinitcpioArgv(a: Allocator, chroot: []const []const u8, root: []const u8, version: []const u8, output: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, chroot);
    try argv.appendSlice(a, &.{ root, "/usr/bin/mkinitcpio", "-k", version, "-g", output });
    return argv.items;
}

/// the room an initramfs os builds for a signed image takes, from the size
/// of the root's own: about the same, with an eighth to spare.
pub fn signedInitramfs(size: u64) u64 {
    return size +| size / 8;
}

/// how an image's name ends.
pub const suffix = "-yoq.efi";

/// systemd's efi stub, which ukify puts in front of the kernel, relative
/// to the root that builds the image. its sum goes in the image's name,
/// so a new stub makes new images.
pub const stub_rel = "usr/lib/systemd/boot/efi/linuxx64.efi.stub";

/// the image's name on the esp, from the sha256 sums of what goes in it,
/// kernel first, then the initrds and the stub, and the command line in
/// it, if there is one: "<16 hex>-yoq.efi". entries with the same boot
/// files, stub, and command line share one.
pub fn name(a: Allocator, sums: []const []const u8, cmdline: ?[]const u8) ![]const u8 {
    var h: std.crypto.hash.sha2.Sha256 = .init(.{});
    for (sums) |s| {
        h.update(s);
        h.update("\n");
    }
    if (cmdline) |c| {
        h.update("cmdline ");
        h.update(c);
        h.update("\n");
    }
    const hex = std.fmt.bytesToHex(h.finalResult(), .lower);
    return std.fmt.allocPrint(a, "{s}" ++ suffix, .{hex[0..16]});
}

/// whether a mkinitcpio preset builds unified kernel images: one of its
/// presets has a `<name>_uki=` path, like default_uki= or fallback_uki=.
pub fn presetBuildsUki(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "#")) continue;
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        if (!std.mem.endsWith(u8, t[0..eq], "_uki")) continue;
        const value = std.mem.trim(u8, t[eq + 1 ..], " \t\"'");
        if (value.len > 0) return true;
    }
    return false;
}

/// whether the names in EFI/Linux on the esp, where systemd-boot finds
/// unified kernel images by itself, include one.
pub fn anyImage(names: []const []const u8) bool {
    for (names) |n| {
        if (isEfi(n)) return true;
    }
    return false;
}

/// whether a file's name says it's an efi binary.
pub fn isEfi(file: []const u8) bool {
    return file.len > 4 and std.ascii.eqlIgnoreCase(file[file.len - 4 ..], ".efi");
}

const testing = std.testing;

test "ukify's arguments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kernel = "/tmp/yoq-uki/vmlinuz-linux";
    const initrds: []const []const u8 = &.{ "/tmp/yoq-uki/amd-ucode.img", "/tmp/yoq-uki/initramfs-linux.img" };
    const argv = try ukifyArgv(a, &.{"chroot"}, "/run/yoq/private/top/@roots/4", kernel, initrds, null, "/tmp/yoq-uki/yoq.efi");
    const want = [_][]const u8{
        "chroot",
        "/run/yoq/private/top/@roots/4",
        "ukify",
        "build",
        "--config=/etc/kernel/yoq-uki.conf",
        "--linux=/tmp/yoq-uki/vmlinuz-linux",
        "--initrd=/tmp/yoq-uki/amd-ucode.img",
        "--initrd=/tmp/yoq-uki/initramfs-linux.img",
        "--output=/tmp/yoq-uki/yoq.efi",
    };
    try testing.expectEqual(want.len, argv.len);
    for (want, argv) |w, g| try testing.expectEqualStrings(w, g);
    // no command line goes in the image.
    for (argv) |arg| try testing.expect(!std.mem.startsWith(u8, arg, "--cmdline"));

    // with secure boot, the entry's goes in, as one argument.
    const cmdline = "root=UUID=r rootflags=subvol=/@roots/4 rw rd.luks.name=u=root console=ttyS0,115200 panic=10";
    const signed = try ukifyArgv(a, &.{"chroot"}, "/run/yoq/private/top/@roots/4", kernel, initrds, cmdline, "/tmp/yoq-uki/yoq.efi");
    try testing.expectEqual(want.len + 1, signed.len);
    try testing.expectEqualStrings("--cmdline=" ++ cmdline, signed[signed.len - 2]);
    try testing.expectEqualStrings("--output=/tmp/yoq-uki/yoq.efi", signed[signed.len - 1]);
}

test "a signed image's kernel comes from its package, not /boot" {
    const kernels = [_]Kernel{
        .{ .version = "6.16.8-arch1-1", .pkgbase = "linux\n", .sum = "old" },
        .{ .version = "6.17.1-arch1-1", .pkgbase = "linux\n", .sum = "new" },
        .{ .version = "6.12.48-1-lts", .pkgbase = "linux-lts\n", .sum = "lts" },
    };
    // the copy matches one of them.
    try testing.expectEqualStrings("6.16.8-arch1-1", signedKernel(&kernels, "vmlinuz-linux", "old").?.version);
    // a copy that matches none, like one planted on the esp: the newest.
    try testing.expectEqualStrings("6.17.1-arch1-1", signedKernel(&kernels, "vmlinuz-linux", "planted").?.version);
    try testing.expectEqualStrings("6.12.48-1-lts", signedKernel(&kernels, "vmlinuz-linux-lts", null).?.version);
    try testing.expectEqual(null, signedKernel(&kernels, "vmlinuz-linux-zen", "x"));
    try testing.expectEqual(null, signedKernel(&kernels, "initramfs-linux.img", "x"));
}

test "mkinitcpio's arguments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const argv = try mkinitcpioArgv(arena.allocator(), &.{"chroot"}, "/run/yoq/private/top/@roots/4", "6.17.1-arch1-1", "/tmp/yoq-uki/initramfs.img");
    const want = [_][]const u8{ "chroot", "/run/yoq/private/top/@roots/4", "/usr/bin/mkinitcpio", "-k", "6.17.1-arch1-1", "-g", "/tmp/yoq-uki/initramfs.img" };
    try testing.expectEqual(want.len, argv.len);
    for (want, argv) |w, g| try testing.expectEqualStrings(w, g);
}

test "an image's name follows what's in it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try name(a, &.{ "aa", "bb" }, null);
    try testing.expect(std.mem.endsWith(u8, one, "-yoq.efi"));
    try testing.expectEqual(16 + "-yoq.efi".len, one.len);
    try testing.expectEqualStrings(one, try name(a, &.{ "aa", "bb" }, null));
    try testing.expect(!std.mem.eql(u8, one, try name(a, &.{ "aa", "cc" }, null)));
    // the order counts: microcode goes before the initramfs.
    try testing.expect(!std.mem.eql(u8, one, try name(a, &.{ "bb", "aa" }, null)));
    // a command line in the image makes another, one per command line,
    // and the same one shares it.
    const two = try name(a, &.{ "aa", "bb" }, "root=UUID=r rootflags=subvol=/@roots/2 rw");
    try testing.expect(!std.mem.eql(u8, one, two));
    try testing.expectEqualStrings(two, try name(a, &.{ "aa", "bb" }, "root=UUID=r rootflags=subvol=/@roots/2 rw"));
    try testing.expect(!std.mem.eql(u8, two, try name(a, &.{ "aa", "bb" }, "root=UUID=r rootflags=subvol=/@roots/2 rw yoq.trial")));
    // an empty command line is still one.
    try testing.expect(!std.mem.eql(u8, one, try name(a, &.{ "aa", "bb" }, "")));
}

test "presets that build unified kernel images" {
    try testing.expect(presetBuildsUki(
        \\ALL_kver="/boot/vmlinuz-linux"
        \\PRESETS=('default' 'fallback')
        \\#default_image="/boot/initramfs-linux.img"
        \\default_uki="/efi/EFI/Linux/arch-linux.efi"
        \\
    ));
    try testing.expect(presetBuildsUki("PRESETS=('fallback')\n  fallback_uki='/boot/EFI/Linux/arch-linux-fallback.efi'\n"));
    // arch's own preset, which has them commented out.
    try testing.expect(!presetBuildsUki(
        \\ALL_kver="/boot/vmlinuz-linux"
        \\PRESETS=('default' 'fallback')
        \\default_image="/boot/initramfs-linux.img"
        \\#default_uki="/efi/EFI/Linux/arch-linux.efi"
        \\#default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"
        \\fallback_image="/boot/initramfs-linux-fallback.img"
        \\
    ));
    try testing.expect(!presetBuildsUki("default_uki=\"\"\n"));
}

test "unified kernel images in EFI/Linux" {
    try testing.expect(anyImage(&.{ "arch-linux.efi", "README" }));
    try testing.expect(anyImage(&.{"ARCH-LINUX.EFI"}));
    try testing.expect(!anyImage(&.{ "README", ".efi" }));
    try testing.expect(!anyImage(&.{}));
}
