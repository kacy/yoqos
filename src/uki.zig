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
