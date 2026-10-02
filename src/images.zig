//! unified kernel images and secure boot on a running machine: images
//! built with ukify in the root they're for, and signed with sbctl's keys
//! before they go on the esp, along with the loader files os puts there.
//! uki.zig and secureboot.zig have the pure parts.

const std = @import("std");
const lists = @import("lists.zig");
const rootfs = @import("rootfs.zig");
const exec = @import("exec.zig");
const facts = @import("facts.zig");
const menu = @import("menu.zig");
const uki = @import("uki.zig");
const secureboot = @import("secureboot.zig");
const bootfiles = @import("bootfiles.zig");
const gens = @import("gens.zig");
const Machine = gens.Machine;
const Allocator = std.mem.Allocator;

/// whether the efi binary at `path` is signed with sbctl's db key, or
/// signed at all when there's no key to compare with. one signed with
/// another key, like one from before `sbctl create-keys` was run
/// again, isn't, so it gets signed again.
fn signedNow(m: *const Machine, path: []const u8) !bool {
    return fileSigned(m.io, path, try dbKey(m.a, m.io, m.db_cert));
}

/// whether the root at `subvol` has `rel`, a path inside it.
fn has(m: *const Machine, subvol: []const u8, rel: []const u8) !bool {
    return rootfs.pathExists(m.io, try m.at(&.{ subvol, rel }));
}

/// whether the root at `subvol` boots a unified kernel image: it has
/// os's ukify config from `[boot] uki`.
pub fn bootsImage(m: *const Machine, subvol: []const u8) !bool {
    return has(m, subvol, uki.config_rel);
}

/// whether any of `entries` boots a unified kernel image.
pub fn anyImage(m: *const Machine, entries: []const menu.Entry) !bool {
    for (entries) |e| {
        if (try m.bootsImage(e.subvol)) return true;
    }
    return false;
}

/// whether menus written now sign what they boot: the root at the top,
/// `head`, or the running one has os's file from `[boot] secure_boot`,
/// or the firmware enforces secure boot and sbctl has keys. the
/// running one counts since its firmware may enforce secure boot
/// already, whatever generation goes on top.
pub fn signs(m: *const Machine, head: []const u8) bool {
    if (secureboot.enforcedWithKeys(m.boot.secure_boot, m.boot.sbctl_keys)) return true;
    if (has(m, head, secureboot.config_rel) catch false) return true;
    const running = m.boot.root_subvol orelse return false;
    return has(m, running, secureboot.config_rel) catch false;
}

/// signs the efi binary at `path` in place, with sbctl's keys.
fn signFile(m: *const Machine, path: []const u8) !?[]const u8 {
    const why = try m.run(try secureboot.signArgv(m.a, m.signer, path)) orelse return null;
    return try std.fmt.allocPrint(m.a, "can't sign {s} for secure boot: {s}", .{ path, why });
}

const Signing = union(enum) {
    signed,
    /// it couldn't be, and on a way back that's noted, not a stop.
    unsigned,
    failed: []const u8,
};

/// signs `src`, which goes to `dest` on the esp.
fn trySign(m: *const Machine, src: []const u8, dest: []const u8) !Signing {
    const why = try signFile(m, src) orelse return .signed;
    if (!secureboot.goesOnUnsigned(m.left_unsigned != null)) return .{ .failed = why };
    // a rollback writes the menu more than once.
    const left = m.left_unsigned.?;
    if (!lists.contains(left.items, dest)) try left.append(m.a, dest);
    return .unsigned;
}

/// signs `src`, a file in a work directory, then puts it at `dest` on
/// the esp, so the esp never has it unsigned, unless a way back
/// couldn't sign it.
fn signInto(m: *const Machine, src: []const u8, dest: []const u8) !?[]const u8 {
    return switch (try trySign(m, src, dest)) {
        .failed => |w| w,
        .signed, .unsigned => bootfiles.replaceFile(m, src, dest),
    };
}

/// signs the loader files os puts on the esp itself, when they aren't
/// signed yet: refind's btrfs driver. the one on the esp is replaced
/// by a signed copy of refind's own, never signed as it is, since
/// anyone who can write to the esp could have put it there. the
/// bootloader's own binaries come from its install, and `os doctor`
/// says if they're unsigned.
pub fn signLoader(m: *const Machine, work: []const u8) !?[]const u8 {
    if (m.loader != .refind) return null;
    const conf = m.boot.loader_conf orelse return null;
    const driver = try std.fs.path.join(m.a, &.{ std.fs.path.dirnamePosix(conf).?, refind_driver });
    if (!rootfs.pathExists(m.io, driver) or try signedNow(m, driver)) return null;
    if (!rootfs.pathExists(m.io, m.refind_driver_src)) {
        const why = try std.fmt.allocPrint(m.a, "can't sign {s} for secure boot: refind's own copy, {s}, isn't there to sign", .{ driver, m.refind_driver_src });
        const left = m.left_unsigned orelse return why;
        if (!lists.contains(left.items, driver)) try left.append(m.a, driver);
        return null;
    }
    if (try freshDir(m, work)) |w| return w;
    defer removeDir(m, work);
    const copy = try std.fs.path.join(m.a, &.{ work, std.fs.path.basename(driver) });
    if (try m.run(&.{ "cp", m.refind_driver_src, copy })) |w| return w;
    return signInto(m, copy, driver);
}

/// makes the directory at `path` again, empty and root's alone. it's
/// in a root's /tmp, which anyone can write to through the top level's
/// mount, so one that shows up again after the old one goes is a
/// failure, never used: its owner could swap an image before it's
/// signed.
fn freshDir(m: *const Machine, path: []const u8) !?[]const u8 {
    if (try m.run(&.{ "rm", "-rf", path })) |w| return w;
    if (std.fs.path.dirnamePosix(path)) |parent| std.Io.Dir.cwd().createDirPath(m.io, parent) catch {};
    return switch (std.os.linux.errno(std.os.linux.mkdir(try m.a.dupeZ(u8, path), 0o700))) {
        .SUCCESS => null,
        else => |e| try std.fmt.allocPrint(m.a, "can't make {s}: {s}", .{ path, @tagName(e) }),
    };
}

fn removeDir(m: *const Machine, path: []const u8) void {
    _ = exec.run(m.a, m.io, &.{ "rm", "-rf", path }) catch {};
}

/// a unified kernel image the esp doesn't have yet: the root whose
/// tools build it, its files, kernel first, the command line that goes
/// in it, if any, and where it goes. `again` when the esp has one by
/// that name, but without sbctl's signature. with `version`, `files`
/// is the kernel alone, and the initramfs is built for that kernel
/// version in the root, as for an image that's signed.
pub const UkiBuild = struct { root: []const u8, files: []const []const u8, cmdline: ?[]const u8 = null, version: ?[]const u8 = null, dest: []const u8, size: u64, again: bool = false };

/// makes `e` start a unified kernel image of its kernel and initrds,
/// named by their content and the stub of the root that builds it,
/// and notes the name in `files`, along with the build if the esp
/// doesn't have it yet, or with `sign`, has it without sbctl's
/// signature.
///
/// with `sign`, the image has the entry's command line in it, and the
/// entry passes none: with secure boot on, systemd's stub ignores the
/// loader's command line for an image that has one, and the signature
/// covers it, so nobody who can only write the esp can change it. the
/// entry a trial boots, `trial_boots`, gets a second image then, with
/// the trial's command line.
///
/// an image that's signed doesn't take the root's copies of the boot
/// files as they are either: with the esp at /boot, keepBoot copied
/// them from the esp, where anything that can write it could have put
/// them. its kernel comes from the root's package (see signedKernel),
/// and its initramfs is built for it in the root with mkinitcpio, with
/// early microcode from mkinitcpio's hook. the copies still name the
/// image, so it's built again, once, when they change, and reused by
/// name otherwise.
pub fn ukiName(m: *const Machine, e: *menu.Entry, files: *bootfiles.EspFiles, sign: bool, trial_boots: bool) !?[]const u8 {
    const from = try imageSource(m, e.subvol);
    var inputs: std.ArrayList([]const u8) = .empty;
    var sums: std.ArrayList([]const u8) = .empty;
    var size: u64 = uki.stub_size;
    var initrds: u64 = 0;
    var why: []const u8 = "";
    for (try std.mem.concat(m.a, []const u8, &.{ &.{e.kernel}, e.initrds }), 0..) |name, i| {
        const src = try std.fs.path.join(m.a, &.{ from, name });
        const h = try bootfiles.hash(m, src, &why) orelse return why;
        try inputs.append(m.a, src);
        try sums.append(m.a, h.sum);
        size += h.size;
        if (i > 0) initrds += h.size;
    }
    const stub = try bootfiles.hash(m, try m.at(&.{ e.subvol, uki.stub_rel }), &why) orelse return why;
    try sums.append(m.a, stub.sum);
    var b: UkiBuild = .{ .root = try m.at(&.{e.subvol}), .files = inputs.items, .dest = "", .size = size };
    if (sign) {
        const k = try signedKernel(m, e.subvol, e.kernel, sums.items[0]) orelse
            return try std.fmt.allocPrint(m.a, "can't find the kernel for {s} in {s}", .{ e.kernel, try m.at(&.{ e.subvol, uki.modules_dir }) });
        sums.items[0] = k.sum;
        b.files = try m.a.dupe([]const u8, &.{try m.at(&.{ e.subvol, uki.modules_dir, k.version, "vmlinuz" })});
        b.version = k.version;
        b.size += uki.signedInitramfs(initrds) - initrds;
    }
    e.esp_dir = bootfiles.esp_boot_dir;
    e.embedded = sign;
    e.uki = try noteImage(m, b, sums.items, if (sign) e.args else null, files, sign);
    if (sign and trial_boots) e.trial_uki = try noteImage(m, b, sums.items, try menu.trialArgs(m.a, e.args), files, sign);
    return null;
}

/// the name of the image `b` builds with `cmdline` in it, noted in
/// `files` with its build when the esp doesn't have it, or with
/// `sign`, has it without sbctl's signature.
fn noteImage(m: *const Machine, b: UkiBuild, sums: []const []const u8, cmdline: ?[]const u8, files: *bootfiles.EspFiles, sign: bool) ![]const u8 {
    const name = try uki.name(m.a, sums, cmdline);
    var build = b;
    build.cmdline = cmdline;
    if (lists.contains(files.used.items, name)) return name;
    if (try bootfiles.newOnEsp(m, name, files)) |dest| {
        build.dest = dest;
    } else {
        const there = try std.fs.path.join(m.a, &.{ m.boot.esp.?, bootfiles.esp_boot_dir, name });
        if (!sign or try signedNow(m, there)) return name;
        build.dest = there;
        build.again = true;
    }
    try files.builds.append(m.a, build);
    return name;
}

/// the kernel in the root at `subvol` that a signed image of
/// `boot_name`, whose copy in the root's /boot has `boot_sum`, is
/// built from (see uki.signedKernel).
fn signedKernel(m: *const Machine, subvol: []const u8, boot_name: []const u8, boot_sum: []const u8) !?uki.Kernel {
    const dir_path = try m.at(&.{ subvol, uki.modules_dir });
    var dir = std.Io.Dir.cwd().openDir(m.io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(m.io);
    var kernels: std.ArrayList(uki.Kernel) = .empty;
    var it = dir.iterate();
    while (it.next(m.io) catch null) |d| {
        if (d.kind != .directory) continue;
        const pkgbase = std.Io.Dir.cwd().readFileAlloc(m.io, try std.fs.path.join(m.a, &.{ dir_path, d.name, "pkgbase" }), m.a, .limited(256)) catch continue;
        var why: []const u8 = "";
        const h = try bootfiles.hash(m, try std.fs.path.join(m.a, &.{ dir_path, d.name, "vmlinuz" }), &why) orelse continue;
        try kernels.append(m.a, .{ .version = try m.a.dupe(u8, d.name), .pkgbase = pkgbase, .sum = h.sum });
    }
    return uki.signedKernel(kernels.items, boot_name, boot_sum);
}

/// where an image's kernel and initrds come from: the root's own /boot
/// directory, never the esp, even for the newest entry with /boot as
/// the esp. anything with the esp mounted, or another system on the
/// disk, can write the esp, and what's there would be signed into the
/// image. every root os records has its own copies there: the root's
/// real /boot without the esp at /boot, and with it the copies
/// keepBoot makes as the generation is recorded, which snapshots and
/// boot copies keep. keepBoot takes those from the esp, though, so a
/// signed image doesn't use them as they are (see ukiName).
fn imageSource(m: *const Machine, subvol: []const u8) ![]const u8 {
    return m.at(&.{ subvol, "boot" });
}

/// builds a unified kernel image with ukify, chrooted into the root
/// it's for, so it's that root's ukify and stub, which a root staged
/// with `[boot] uki` has even when the running one doesn't. its files
/// go into a directory in the root first, since the esp isn't in
/// there, and nothing has to be mounted for this. reflinks keep that
/// cheap for files from the root's own /boot.
pub fn buildUki(m: *const Machine, b: UkiBuild, signed: bool) !?[]const u8 {
    const work = try std.fs.path.join(m.a, &.{ b.root, uki.work_dir });
    if (try freshDir(m, work)) |w| return w;
    defer removeDir(m, work);
    var inside: std.ArrayList([]const u8) = .empty;
    for (b.files) |f| {
        const base = std.fs.path.basename(f);
        if (try m.run(&.{ "cp", "--reflink=auto", f, try std.fs.path.join(m.a, &.{ work, base }) })) |w| return w;
        try inside.append(m.a, try std.fmt.allocPrint(m.a, "/{s}/{s}", .{ uki.work_dir, base }));
    }
    if (b.version) |v| {
        const initramfs = "/" ++ uki.work_dir ++ "/initramfs.img";
        if (try m.run(try uki.mkinitcpioArgv(m.a, m.api_chroot, b.root, v, initramfs))) |w| {
            return try std.fmt.allocPrint(m.a, "can't build an initramfs for {s} in {s}: {s}", .{ v, b.root, w });
        }
        try inside.append(m.a, initramfs);
    }
    const out = "/" ++ uki.work_dir ++ "/yoq.efi";
    if (try m.run(try uki.ukifyArgv(m.a, m.chroot, b.root, inside.items[0], inside.items[1..], b.cmdline, out))) |w| {
        return try std.fmt.allocPrint(m.a, "can't build a unified kernel image in {s}: {s}", .{ b.root, w });
    }
    const image = try std.fs.path.join(m.a, &.{ work, "yoq.efi" });
    // signed from here, with the running system's sbctl and keys: the
    // keys live in /var, which no root holds.
    return if (signed) signInto(m, image, b.dest) else bootfiles.replaceFile(m, image, b.dest);
}

/// mounts what mkinitcpio needs in the root given first, as arch-chroot
/// does, then runs the rest there. the root goes on itself first, so it's
/// a mount, and autodetect finds its filesystem at /. mkinitcpio's post
/// hooks get empty directories over theirs: sbctl's signs the kernel it's
/// given whenever it finds keys, which here is the root's package file in
/// /usr/lib/modules, and os signs the image itself.
pub const api_chroot_script =
    \\set -e
    \\r=$1; shift
    \\mount --bind "$r" "$r"
    \\mount -t proc proc "$r/proc"
    \\mount -t sysfs -o ro sys "$r/sys"
    \\mount --rbind /dev "$r/dev"
    \\mount -t tmpfs -o mode=0755,nosuid,nodev run "$r/run"
    \\for d in usr/lib/initcpio/post etc/initcpio/post; do
    \\    if [ -d "$r/$d" ]; then mount -t tmpfs -o mode=0755 post "$r/$d"; fi
    \\done
    \\exec chroot "$r" "$@"
;

/// where images are signed, inside the root at the top of the menu.
pub const sign_dir = "tmp/yoq-sign";

/// refind's btrfs driver, beside refind.conf, which os installs.
pub const refind_driver = "drivers_x64/btrfs_x64.efi";

/// whether the efi binary at `path` has a signature: one from the key
/// `key` names (see secureboot.signerKey), or with no key, any. one that
/// can't be read, or isn't an efi binary, hasn't.
pub fn fileSigned(io: std.Io, path: []const u8, key: ?[]const u8) bool {
    var head: [secureboot.header_bytes]u8 = undefined;
    const t = secureboot.certTable(rootfs.readHead(io, path, &head) orelse return false) orelse return false;
    if (t.size == 0) return false;
    const k = key orelse return true;
    // a signature or two, with their certificates, takes a few KiB.
    var table: [64 << 10]u8 = undefined;
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer f.close(io);
    const n = f.readPositionalAll(io, table[0..@min(t.size, table.len)], t.offset) catch return false;
    return secureboot.signedBy(table[0..n], k);
}

/// what names sbctl's db key as a signer, from its certificate at
/// `cert_path`. null without one.
pub fn dbKey(a: Allocator, io: std.Io, cert_path: []const u8) !?[]const u8 {
    const pem = std.Io.Dir.cwd().readFileAlloc(io, cert_path, a, .limited(64 << 10)) catch return null;
    return secureboot.signerKey(a, pem);
}

/// the entries a test's menu writer was given.
var test_put: []const menu.Entry = &.{};

fn testPut(_: *const Machine, entries: []menu.Entry, _: ?usize) anyerror!?[]const u8 {
    test_put = entries;
    return null;
}

test "entries for a root with os's ukify config start its image, and unused images go" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    // generation 2 boots an image, and generation 1 its root's own files.
    try tmp.dir.createDirPath(io, "top/@roots/2/boot");
    try tmp.dir.createDirPath(io, "top/@roots/2/etc/kernel");
    try tmp.dir.createDirPath(io, "top/@roots/1/boot");
    try tmp.dir.createDirPath(io, "esp/yoq/boot");
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ uki.config_rel, .data = uki.config_content });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/vmlinuz-linux", .data = "kernel" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/initramfs-linux.img", .data = "initramfs" });
    try writeTestStub(tmp.dir, io, "top/@roots/2", "stub");
    try writeTestKernel(tmp.dir, io, "top/@roots/2", "kernel");
    const name = try uki.name(a, &.{ &facts.sha256Hex("kernel"), &facts.sha256Hex("initramfs"), &facts.sha256Hex("stub") }, null);
    // the image is there already, so nothing's built; an older one isn't
    // used any more.
    try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "esp/yoq/boot/{s}", .{name}), .data = "image" });
    try tmp.dir.writeFile(io, .{ .sub_path = "esp/yoq/boot/0123456789abcdef-yoq.efi", .data = "old" });
    const m: Machine = .{
        .a = a,
        .io = io,
        .boot = .{ .esp = try std.fmt.allocPrint(a, "{s}/esp", .{base}), .loader = "grub", .root_subvol = "/@roots/2" },
        .loader = .grub,
        .root_uuid = "r",
        .esp_uuid = "e",
        .top = try std.fmt.allocPrint(a, "{s}/top", .{base}),
    };
    var entries = [_]menu.Entry{
        .{ .id = "head", .title = "yoq 2", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" },
        .{ .id = "gen-1", .title = "yoq 1", .subvol = "/@roots/1", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" },
    };
    try std.testing.expectEqual(null, try bootfiles.writeOnEsp(&m, &entries, &.{}, testPut, null));
    try std.testing.expectEqualStrings(name, test_put[0].uki.?);
    try std.testing.expectEqualStrings(bootfiles.esp_boot_dir, test_put[0].esp_dir.?);
    // grub reads generation 1's files in its root, as without images.
    try std.testing.expectEqual(null, test_put[1].uki);
    try std.testing.expectEqual(null, test_put[1].esp_dir);
    var esp = try tmp.dir.openDir(io, "esp/yoq/boot", .{ .iterate = true });
    defer esp.close(io);
    var it = esp.iterate();
    var left: std.ArrayList([]const u8) = .empty;
    while (try it.next(io)) |f| try left.append(a, try a.dupe(u8, f.name));
    try std.testing.expectEqual(1, left.items.len);
    try std.testing.expectEqualStrings(name, left.items[0]);

    // a new stub makes a new image, here one the esp has already, and the
    // old one goes.
    try writeTestStub(tmp.dir, io, "top/@roots/2", "stub 2");
    const renamed = try uki.name(a, &.{ &facts.sha256Hex("kernel"), &facts.sha256Hex("initramfs"), &facts.sha256Hex("stub 2") }, null);
    try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "esp/yoq/boot/{s}", .{renamed}), .data = "image" });
    entries[0] = .{ .id = "head", .title = "yoq 2", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" };
    try std.testing.expectEqual(null, try bootfiles.writeOnEsp(&m, &entries, &.{}, testPut, null));
    try std.testing.expectEqualStrings(renamed, test_put[0].uki.?);
    try std.testing.expectError(error.FileNotFound, esp.access(io, name, .{}));
    try esp.access(io, renamed, .{});

    // with [boot] uki off everywhere, the last image goes too.
    try tmp.dir.deleteFile(io, "top/@roots/2/" ++ uki.config_rel);
    entries[0] = .{ .id = "head", .title = "yoq 3", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" };
    try std.testing.expectEqual(null, try bootfiles.writeOnEsp(&m, &entries, &.{}, testPut, null));
    try std.testing.expectEqual(null, test_put[0].uki);
    try std.testing.expectError(error.FileNotFound, esp.access(io, renamed, .{}));
}

test "with the esp at /boot, an image is built from the root's copies, not the esp's files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "top/@roots/2/boot");
    try tmp.dir.createDirPath(io, "top/@roots/2/etc/kernel");
    try tmp.dir.createDirPath(io, "esp/yoq/boot");
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ uki.config_rel, .data = uki.config_content });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/vmlinuz-linux", .data = "kernel" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/initramfs-linux.img", .data = "initramfs" });
    // what someone who could write the esp put there.
    try tmp.dir.writeFile(io, .{ .sub_path = "esp/vmlinuz-linux", .data = "planted" });
    try tmp.dir.writeFile(io, .{ .sub_path = "esp/initramfs-linux.img", .data = "planted" });
    try writeTestStub(tmp.dir, io, "top/@roots/2", "stub");
    try writeTestKernel(tmp.dir, io, "top/@roots/2", "kernel");
    // a stand-in for ukify whose image holds the kernel it was given.
    try tmp.dir.writeFile(io, .{ .sub_path = "chroot.sh", .data =
        \\root=$1; shift
        \\for arg; do case $arg in --output=*) out=${arg#--output=} ;; --linux=*) linux=${arg#--linux=} ;; esac; done
        \\cat "$root$linux" > "$root$out"
        \\
    });
    const m: Machine = .{
        .a = a,
        .io = io,
        .boot = .{ .esp = try std.fmt.allocPrint(a, "{s}/esp", .{base}), .loader = "systemd-boot", .root_subvol = "/@roots/2" },
        .loader = .@"systemd-boot",
        .root_uuid = "r",
        .esp_uuid = "e",
        .top = try std.fmt.allocPrint(a, "{s}/top", .{base}),
        .esp_is_boot = true,
        .unsettled_note = try std.fmt.allocPrint(a, "{s}/unsettled", .{base}),
        .chroot = &.{ "sh", try std.fmt.allocPrint(a, "{s}/chroot.sh", .{base}) },
    };
    // the newest entry, with its files on the esp, as entry() makes it.
    var entries = [_]menu.Entry{
        .{ .id = "head", .title = "yoq 2", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw", .esp_dir = "" },
    };
    try std.testing.expectEqual(null, try bootfiles.writeOnEsp(&m, &entries, &.{}, testPut, null));
    const name = try uki.name(a, &.{ &facts.sha256Hex("kernel"), &facts.sha256Hex("initramfs"), &facts.sha256Hex("stub") }, null);
    try std.testing.expectEqualStrings(name, test_put[0].uki.?);
    try std.testing.expectEqualStrings("kernel", try tmp.dir.readFileAlloc(io, try std.fmt.allocPrint(a, "esp/yoq/boot/{s}", .{name}), a, .limited(64)));
}

test "a signed image takes the kernel from its package and builds its own initramfs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "top/@roots/2/boot");
    try tmp.dir.createDirPath(io, "top/@roots/2/etc/kernel");
    try tmp.dir.createDirPath(io, "esp/yoq/boot");
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ uki.config_rel, .data = uki.config_content });
    // the root's copies, which keepBoot took from an esp someone had
    // written to: a kernel that isn't its package's, and an initramfs
    // and microcode of their own.
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/vmlinuz-linux", .data = "planted kernel" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/intel-ucode.img", .data = "planted ucode" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/initramfs-linux.img", .data = "planted initramfs" });
    try writeTestStub(tmp.dir, io, "top/@roots/2", "stub");
    try writeTestKernel(tmp.dir, io, "top/@roots/2", "kernel");
    // stand-ins: ukify's image holds its kernel and initrds, one after
    // the other, and mkinitcpio's initramfs names its kernel version.
    try tmp.dir.writeFile(io, .{ .sub_path = "chroot.sh", .data =
        \\root=$1; shift
        \\prev= ver= out= parts=
        \\for arg; do
        \\    case $prev in
        \\    -k) ver=$arg ;;
        \\    -g) printf 'mkinitcpio %s' "$ver" > "$root$arg"; echo "$ver" >> "$(dirname "$0")/mkinitcpio.log"; exit 0 ;;
        \\    esac
        \\    case $arg in --output=*) out=${arg#--output=} ;; --linux=* | --initrd=*) parts="$parts ${arg#*=}" ;; esac
        \\    prev=$arg
        \\done
        \\for p in $parts; do cat "$root$p"; printf '|'; done > "$root$out"
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "sign.sh", .data = "[ \"$1\" = sign ] && printf ' signed' >> \"$2\"\n" });
    const chroot = try a.dupe([]const u8, &.{ "sh", try std.fmt.allocPrint(a, "{s}/chroot.sh", .{base}) });
    const m: Machine = .{
        .a = a,
        .io = io,
        .boot = .{ .esp = try std.fmt.allocPrint(a, "{s}/esp", .{base}), .loader = "systemd-boot", .root_subvol = "/@roots/2" },
        .loader = .@"systemd-boot",
        .root_uuid = "r",
        .esp_uuid = "e",
        .top = try std.fmt.allocPrint(a, "{s}/top", .{base}),
        .esp_is_boot = true,
        .unsettled_note = try std.fmt.allocPrint(a, "{s}/unsettled", .{base}),
        .signer = &.{ "sh", try std.fmt.allocPrint(a, "{s}/sign.sh", .{base}) },
        .chroot = chroot,
        .api_chroot = chroot,
    };
    var entries = [_]menu.Entry{
        .{ .id = "head", .title = "yoq 2", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{ "intel-ucode.img", "initramfs-linux.img" }, .args = "rw", .esp_dir = "" },
    };
    // without signing, the image is the copies as they are, and
    // mkinitcpio never runs.
    try std.testing.expectEqual(null, try bootfiles.writeOnEsp(&m, &entries, &.{}, testPut, null));
    const plain = try std.fmt.allocPrint(a, "esp/yoq/boot/{s}", .{test_put[0].uki.?});
    try std.testing.expectEqualStrings("planted kernel|planted ucode|planted initramfs|", try tmp.dir.readFileAlloc(io, plain, a, .limited(256)));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "mkinitcpio.log", .{}));

    // signed: the package's kernel, and an initramfs built for it.
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ secureboot.config_rel, .data = secureboot.config_content });
    entries[0] = .{ .id = "head", .title = "yoq 3", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{ "intel-ucode.img", "initramfs-linux.img" }, .args = "rw", .esp_dir = "" };
    try std.testing.expectEqual(null, try bootfiles.writeOnEsp(&m, &entries, &.{}, testPut, null));
    for ([_][]const u8{ test_put[0].uki.?, test_put[0].trial_uki.? }) |name| {
        const image = try tmp.dir.readFileAlloc(io, try std.fmt.allocPrint(a, "esp/yoq/boot/{s}", .{name}), a, .limited(256));
        try std.testing.expectEqualStrings("kernel|mkinitcpio 6.17.1-arch1-1| signed", image);
    }
    // one mkinitcpio run for each new image: the entry's and its twin's.
    try std.testing.expectEqualStrings("6.17.1-arch1-1\n6.17.1-arch1-1\n", try tmp.dir.readFileAlloc(io, "mkinitcpio.log", a, .limited(256)));
    // the name follows the package's kernel, not the copy.
    const sums: []const []const u8 = &.{ &facts.sha256Hex("kernel"), &facts.sha256Hex("planted ucode"), &facts.sha256Hex("planted initramfs"), &facts.sha256Hex("stub") };
    try std.testing.expectEqualStrings(try uki.name(a, sums, "rw"), test_put[0].uki.?);

    // a root without its kernel's package can't have a signed image.
    try tmp.dir.deleteTree(io, "top/@roots/2/" ++ uki.modules_dir);
    entries[0] = .{ .id = "head", .title = "yoq 4", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw", .esp_dir = "" };
    try std.testing.expect(std.mem.startsWith(u8, (try bootfiles.writeOnEsp(&m, &entries, &.{}, testPut, null)).?, "can't find the kernel for vmlinuz-linux"));
}

test "the script that runs mkinitcpio in a root parses, and hides its post hooks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(null, try exec.run(arena.allocator(), std.testing.io, &.{ "sh", "-n", "-c", api_chroot_script }));
    try std.testing.expect(std.mem.indexOf(u8, api_chroot_script, "usr/lib/initcpio/post etc/initcpio/post") != null);
}

/// a kernel in the test root at `root`, as linux's package installs it,
/// holding `text`.
fn writeTestKernel(dir: std.Io.Dir, io: std.Io, root: []const u8, text: []const u8) !void {
    var buf: [256]u8 = undefined;
    const kdir = try std.fmt.bufPrint(&buf, "{s}/{s}/6.17.1-arch1-1", .{ root, uki.modules_dir });
    var sub = try dir.createDirPathOpen(io, kdir, .{});
    defer sub.close(io);
    try sub.writeFile(io, .{ .sub_path = "vmlinuz", .data = text });
    try sub.writeFile(io, .{ .sub_path = "pkgbase", .data = "linux\n" });
}

/// systemd's stub in the test root at `root`, holding `text`.
fn writeTestStub(dir: std.Io.Dir, io: std.Io, root: []const u8, text: []const u8) !void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, uki.stub_rel });
    try dir.createDirPath(io, std.fs.path.dirnamePosix(path).?);
    try dir.writeFile(io, .{ .sub_path = path, .data = text });
}

test "with secure boot, images are signed in the root before they replace the esp's" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "top/@roots/2/boot");
    try tmp.dir.createDirPath(io, "top/@roots/2/etc/kernel");
    try tmp.dir.createDirPath(io, "esp/yoq/boot");
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ uki.config_rel, .data = uki.config_content });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/vmlinuz-linux", .data = "kernel" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/initramfs-linux.img", .data = "initramfs" });
    try writeTestStub(tmp.dir, io, "top/@roots/2", "stub");
    try writeTestKernel(tmp.dir, io, "top/@roots/2", "kernel");
    const sums: []const []const u8 = &.{ &facts.sha256Hex("kernel"), &facts.sha256Hex("initramfs"), &facts.sha256Hex("stub") };
    const shared = try std.fmt.allocPrint(a, "esp/yoq/boot/{s}", .{try uki.name(a, sums, null)});
    try tmp.dir.writeFile(io, .{ .sub_path = shared, .data = "image" });
    // with secure boot, the entry's image has its command line in it, and
    // the trial's twin has the trial's.
    const name = try uki.name(a, sums, "rw");
    const trial_name = try uki.name(a, sums, "rw yoq.trial");
    const image = try std.fmt.allocPrint(a, "esp/yoq/boot/{s}", .{name});
    const trial_image = try std.fmt.allocPrint(a, "esp/yoq/boot/{s}", .{trial_name});
    try tmp.dir.writeFile(io, .{ .sub_path = image, .data = "image" });
    // a stand-in for sbctl, which notes what it signed.
    try tmp.dir.writeFile(io, .{ .sub_path = "sign.sh", .data =
        \\[ "$1" = sign ] || exit 1
        \\printf ' signed' >> "$2"
        \\echo "$2" >> "$(dirname "$0")/signed.log"
        \\
    });
    const m: Machine = .{
        .a = a,
        .io = io,
        .boot = .{ .esp = try std.fmt.allocPrint(a, "{s}/esp", .{base}), .loader = "grub", .root_subvol = "/@roots/2" },
        .loader = .grub,
        .root_uuid = "r",
        .esp_uuid = "e",
        .top = try std.fmt.allocPrint(a, "{s}/top", .{base}),
        .signer = &.{ "sh", try std.fmt.allocPrint(a, "{s}/sign.sh", .{base}) },
        .chroot = try testChroot(tmp.dir, io, a, base),
        .api_chroot = try testChroot(tmp.dir, io, a, base),
    };
    var entries = [_]menu.Entry{
        .{ .id = "head", .title = "yoq 2", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" },
    };
    // without the key, nothing's signed, and the entry passes its command
    // line to the shared image.
    try std.testing.expectEqual(null, try bootfiles.writeOnEsp(&m, &entries, &.{}, testPut, null));
    try std.testing.expectEqualStrings("image", try tmp.dir.readFileAlloc(io, shared, a, .limited(64)));
    try std.testing.expect(!test_put[0].embedded);
    try std.testing.expectEqual(null, test_put[0].trial_uki);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "signed.log", .{}));

    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ secureboot.config_rel, .data = secureboot.config_content });
    entries[0] = .{ .id = "head", .title = "yoq 3", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" };
    try std.testing.expectEqual(null, try bootfiles.writeOnEsp(&m, &entries, &.{}, testPut, null));
    try std.testing.expectEqualStrings(name, test_put[0].uki.?);
    try std.testing.expect(test_put[0].embedded);
    try std.testing.expectEqualStrings(trial_name, test_put[0].trial_uki.?);
    // the unsigned image on the esp, which anyone who can write there
    // could have put there, wasn't signed: one built again in the root
    // was, and replaced it. the trial's is new. the work directory is gone
    // again, and so is the shared image, which no entry uses now.
    try std.testing.expectEqualStrings("built cmdline=rw signed", try tmp.dir.readFileAlloc(io, image, a, .limited(64)));
    try std.testing.expectEqualStrings("built cmdline=rw yoq.trial signed", try tmp.dir.readFileAlloc(io, trial_image, a, .limited(64)));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, shared, .{}));
    const log = try tmp.dir.readFileAlloc(io, "signed.log", a, .limited(1024));
    const signed_one = try std.fmt.allocPrint(a, "{s}/top/@roots/2/{s}/yoq.efi\n", .{ base, uki.work_dir });
    try std.testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ signed_one, signed_one }), log);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "top/@roots/2/" ++ uki.work_dir, .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, try std.fmt.allocPrint(a, "{s}.yoq-new", .{image}), .{}));

    // a signer that fails leaves the esp's image as it was.
    const failing: Machine = .{ .a = a, .io = io, .boot = m.boot, .loader = .grub, .root_uuid = "r", .esp_uuid = "e", .top = m.top, .signer = &.{"false"}, .chroot = m.chroot, .api_chroot = m.api_chroot };
    try tmp.dir.writeFile(io, .{ .sub_path = image, .data = "image" });
    entries[0] = .{ .id = "head", .title = "yoq 4", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" };
    const why = (try bootfiles.writeOnEsp(&failing, &entries, &.{}, testPut, null)).?;
    try std.testing.expect(std.mem.startsWith(u8, why, "can't sign "));
    try std.testing.expectEqualStrings("image", try tmp.dir.readFileAlloc(io, image, a, .limited(64)));
}

test "firmware that enforces secure boot has images signed without the config's key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    // a generation rolled back to from before `[boot] secure_boot`: an
    // image, but no file that asks for signing.
    try tmp.dir.createDirPath(io, "top/@roots/2/boot");
    try tmp.dir.createDirPath(io, "top/@roots/2/etc/kernel");
    try tmp.dir.createDirPath(io, "esp/yoq/boot");
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ uki.config_rel, .data = uki.config_content });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/vmlinuz-linux", .data = "kernel" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/initramfs-linux.img", .data = "initramfs" });
    try writeTestStub(tmp.dir, io, "top/@roots/2", "stub");
    try writeTestKernel(tmp.dir, io, "top/@roots/2", "kernel");
    const sums: []const []const u8 = &.{ &facts.sha256Hex("kernel"), &facts.sha256Hex("initramfs"), &facts.sha256Hex("stub") };
    const image = try std.fmt.allocPrint(a, "esp/yoq/boot/{s}", .{try uki.name(a, sums, null)});
    const signed_image = try std.fmt.allocPrint(a, "esp/yoq/boot/{s}", .{try uki.name(a, sums, "rw")});
    try tmp.dir.writeFile(io, .{ .sub_path = "sign.sh", .data = "[ \"$1\" = sign ] && printf ' signed' >> \"$2\"\n" });
    var m: Machine = .{
        .a = a,
        .io = io,
        .boot = .{ .esp = try std.fmt.allocPrint(a, "{s}/esp", .{base}), .loader = "grub", .root_subvol = "/@roots/2", .secure_boot = false, .sbctl_keys = true },
        .loader = .grub,
        .root_uuid = "r",
        .esp_uuid = "e",
        .top = try std.fmt.allocPrint(a, "{s}/top", .{base}),
        .signer = &.{ "sh", try std.fmt.allocPrint(a, "{s}/sign.sh", .{base}) },
        .chroot = try testChroot(tmp.dir, io, a, base),
        .api_chroot = try testChroot(tmp.dir, io, a, base),
    };
    var entries = [_]menu.Entry{
        .{ .id = "head", .title = "yoq 2", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" },
    };
    // secure boot off in the firmware: nothing to sign for.
    try tmp.dir.writeFile(io, .{ .sub_path = image, .data = "image" });
    try std.testing.expectEqual(null, try bootfiles.writeOnEsp(&m, &entries, &.{}, testPut, null));
    try std.testing.expectEqualStrings("image", try tmp.dir.readFileAlloc(io, image, a, .limited(64)));
    // enforced, with keys: the image is signed, or it wouldn't start, and
    // has the command line in it.
    m.boot.secure_boot = true;
    entries[0] = .{ .id = "head", .title = "yoq 3", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" };
    try std.testing.expectEqual(null, try bootfiles.writeOnEsp(&m, &entries, &.{}, testPut, null));
    try std.testing.expect(test_put[0].embedded);
    try std.testing.expectEqualStrings("built cmdline=rw signed", try tmp.dir.readFileAlloc(io, signed_image, a, .limited(64)));
}

test "a way back that can't sign writes the menu anyway" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "top/@roots/2/boot");
    try tmp.dir.createDirPath(io, "top/@roots/2/etc/kernel");
    try tmp.dir.createDirPath(io, "esp/yoq/boot");
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ uki.config_rel, .data = uki.config_content });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ secureboot.config_rel, .data = secureboot.config_content });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/vmlinuz-linux", .data = "kernel" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/initramfs-linux.img", .data = "initramfs" });
    try writeTestStub(tmp.dir, io, "top/@roots/2", "stub");
    try writeTestKernel(tmp.dir, io, "top/@roots/2", "kernel");
    const name = try uki.name(a, &.{ &facts.sha256Hex("kernel"), &facts.sha256Hex("initramfs"), &facts.sha256Hex("stub") }, "rw");
    const image = try std.fmt.allocPrint(a, "esp/yoq/boot/{s}", .{name});
    try tmp.dir.writeFile(io, .{ .sub_path = image, .data = "image" });
    // sbctl without its keys.
    var m: Machine = .{
        .a = a,
        .io = io,
        .boot = .{ .esp = try std.fmt.allocPrint(a, "{s}/esp", .{base}), .loader = "grub", .root_subvol = "/@roots/2" },
        .loader = .grub,
        .root_uuid = "r",
        .esp_uuid = "e",
        .top = try std.fmt.allocPrint(a, "{s}/top", .{base}),
        .signer = &.{"false"},
        .chroot = try testChroot(tmp.dir, io, a, base),
        .api_chroot = try testChroot(tmp.dir, io, a, base),
    };
    var entries = [_]menu.Entry{
        .{ .id = "head", .title = "yoq 2", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" },
    };
    // apply stops.
    test_put = &.{};
    try std.testing.expect(std.mem.startsWith(u8, (try bootfiles.writeOnEsp(&m, &entries, &.{}, testPut, null)).?, "can't sign "));
    try std.testing.expectEqual(0, test_put.len);
    // a way back writes the menu, with the image built again but
    // unsigned, and notes it.
    var left: std.ArrayList([]const u8) = .empty;
    m.left_unsigned = &left;
    entries[0] = .{ .id = "head", .title = "yoq 3", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" };
    try std.testing.expectEqual(null, try bootfiles.writeOnEsp(&m, &entries, &.{}, testPut, null));
    try std.testing.expectEqualStrings(name, test_put[0].uki.?);
    try std.testing.expectEqualStrings("built cmdline=rw", try tmp.dir.readFileAlloc(io, image, a, .limited(64)));
    // the trial's twin too.
    try std.testing.expectEqual(2, left.items.len);
    try std.testing.expect(std.mem.endsWith(u8, left.items[0], name));
}

/// an efi binary signed by the key `key` names: pe headers whose
/// certificate table, at 0x1000, names it.
fn testSignedEfi(a: Allocator, key: []const u8) ![]const u8 {
    const table = try std.mem.concat(a, u8, &.{ &.{ 0, 1, 0, 0, 0, 2, 2, 0 }, try secureboot.testDer(a, 0x30, key) });
    const head = secureboot.testPe(0x20b, @intCast(table.len));
    return std.mem.concat(a, u8, &.{ &head, &([_]u8{0} ** (0x1000 - 512)), table });
}

test "images signed with another key are signed again" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const db = try secureboot.testCert(a, "yoq db", &.{ 0x01, 0x02 });
    const old = try secureboot.testCert(a, "yoq db", &.{ 0x01, 0x01 });
    try tmp.dir.writeFile(io, .{ .sub_path = "db.pem", .data = db.pem });
    const key = (try dbKey(a, io, try std.fmt.allocPrint(a, "{s}/db.pem", .{base}))).?;
    try std.testing.expectEqualSlices(u8, db.key, key);
    try std.testing.expectEqual(null, try dbKey(a, io, try std.fmt.allocPrint(a, "{s}/missing.pem", .{base})));

    try tmp.dir.createDirPath(io, "top/@roots/2/boot");
    try tmp.dir.createDirPath(io, "top/@roots/2/etc/kernel");
    try tmp.dir.createDirPath(io, "esp/yoq/boot");
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ uki.config_rel, .data = uki.config_content });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ secureboot.config_rel, .data = secureboot.config_content });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/vmlinuz-linux", .data = "kernel" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/initramfs-linux.img", .data = "initramfs" });
    try writeTestStub(tmp.dir, io, "top/@roots/2", "stub");
    try writeTestKernel(tmp.dir, io, "top/@roots/2", "kernel");
    const sums: []const []const u8 = &.{ &facts.sha256Hex("kernel"), &facts.sha256Hex("initramfs"), &facts.sha256Hex("stub") };
    const image = try std.fmt.allocPrint(a, "esp/yoq/boot/{s}", .{try uki.name(a, sums, "rw")});
    const image_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, image });
    // the trial's twin, signed with the db key throughout.
    try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "esp/yoq/boot/{s}", .{try uki.name(a, sums, "rw yoq.trial")}), .data = try testSignedEfi(a, db.key) });
    try tmp.dir.writeFile(io, .{ .sub_path = "sign.sh", .data = "[ \"$1\" = sign ] && echo \"$2\" >> \"$(dirname \"$0\")/signed.log\"\n" });
    const m: Machine = .{
        .a = a,
        .io = io,
        .boot = .{ .esp = try std.fmt.allocPrint(a, "{s}/esp", .{base}), .loader = "grub", .root_subvol = "/@roots/2" },
        .loader = .grub,
        .root_uuid = "r",
        .esp_uuid = "e",
        .top = try std.fmt.allocPrint(a, "{s}/top", .{base}),
        .signer = &.{ "sh", try std.fmt.allocPrint(a, "{s}/sign.sh", .{base}) },
        .db_cert = try std.fmt.allocPrint(a, "{s}/db.pem", .{base}),
        .chroot = try testChroot(tmp.dir, io, a, base),
        .api_chroot = try testChroot(tmp.dir, io, a, base),
    };
    var entries = [_]menu.Entry{
        .{ .id = "head", .title = "yoq 2", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" },
    };
    // signed with the db key: it stays.
    try tmp.dir.writeFile(io, .{ .sub_path = image, .data = try testSignedEfi(a, db.key) });
    try std.testing.expect(fileSigned(io, image_path, key));
    try std.testing.expectEqual(null, try bootfiles.writeOnEsp(&m, &entries, &.{}, testPut, null));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "signed.log", .{}));
    // signed with the key from before: signed, but not by this one, so it's
    // built again and signed.
    try tmp.dir.writeFile(io, .{ .sub_path = image, .data = try testSignedEfi(a, old.key) });
    try std.testing.expect(fileSigned(io, image_path, null));
    try std.testing.expect(!fileSigned(io, image_path, key));
    entries[0] = .{ .id = "head", .title = "yoq 3", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" };
    try std.testing.expectEqual(null, try bootfiles.writeOnEsp(&m, &entries, &.{}, testPut, null));
    const log = try tmp.dir.readFileAlloc(io, "signed.log", a, .limited(1024));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/top/@roots/2/{s}/yoq.efi\n", .{ base, uki.work_dir }), log);
}

test "refind's driver on the esp is replaced by a signed copy of refind's own" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "top/@roots/2/etc/kernel");
    try tmp.dir.createDirPath(io, "esp/EFI/refind/drivers_x64");
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ secureboot.config_rel, .data = secureboot.config_content });
    // a driver someone else put on the esp, and refind's own.
    try tmp.dir.writeFile(io, .{ .sub_path = "esp/EFI/refind/" ++ refind_driver, .data = "planted" });
    try tmp.dir.writeFile(io, .{ .sub_path = "refind-driver.efi", .data = "driver" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sign.sh", .data = "[ \"$1\" = sign ] && printf ' signed' >> \"$2\"\n" });
    var m: Machine = .{
        .a = a,
        .io = io,
        .boot = .{ .esp = try std.fmt.allocPrint(a, "{s}/esp", .{base}), .loader = "refind", .loader_conf = try std.fmt.allocPrint(a, "{s}/esp/EFI/refind/refind.conf", .{base}), .root_subvol = "/@roots/2" },
        .loader = .refind,
        .root_uuid = "r",
        .esp_uuid = "e",
        .top = try std.fmt.allocPrint(a, "{s}/top", .{base}),
        .signer = &.{ "sh", try std.fmt.allocPrint(a, "{s}/sign.sh", .{base}) },
        .refind_driver_src = try std.fmt.allocPrint(a, "{s}/refind-driver.efi", .{base}),
    };
    var entries = [_]menu.Entry{
        .{ .id = "head", .title = "yoq 2", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" },
    };
    try std.testing.expectEqual(null, try bootfiles.writeOnEsp(&m, &entries, &.{}, testPut, null));
    try std.testing.expectEqualStrings("driver signed", try tmp.dir.readFileAlloc(io, "esp/EFI/refind/" ++ refind_driver, a, .limited(64)));

    // without refind's own, an apply stops, and a way back goes on.
    try tmp.dir.writeFile(io, .{ .sub_path = "esp/EFI/refind/" ++ refind_driver, .data = "planted" });
    m.refind_driver_src = try std.fmt.allocPrint(a, "{s}/missing.efi", .{base});
    try std.testing.expect(std.mem.startsWith(u8, (try bootfiles.writeOnEsp(&m, &entries, &.{}, testPut, null)).?, "can't sign "));
    var left: std.ArrayList([]const u8) = .empty;
    m.left_unsigned = &left;
    try std.testing.expectEqual(null, try bootfiles.writeOnEsp(&m, &entries, &.{}, testPut, null));
    try std.testing.expectEqual(1, left.items.len);
    try std.testing.expectEqualStrings("planted", try tmp.dir.readFileAlloc(io, "esp/EFI/refind/" ++ refind_driver, a, .limited(64)));
}

/// a stand-in for chroot running ukify or mkinitcpio in a test's root:
/// the image ukify builds holds "built", and " cmdline=" and the command
/// line it was given, if any. mkinitcpio's initramfs holds "mkinitcpio"
/// and the kernel version, and it notes each run in mkinitcpio.log.
fn testChroot(dir: std.Io.Dir, io: std.Io, a: Allocator, base: []const u8) ![]const []const u8 {
    try dir.writeFile(io, .{ .sub_path = "chroot.sh", .data =
        \\root=$1; shift
        \\cmdline= prev= ver=
        \\for arg; do
        \\    case $prev in
        \\    -k) ver=$arg ;;
        \\    -g) printf 'mkinitcpio %s' "$ver" > "$root$arg"; echo "$ver" >> "$(dirname "$0")/mkinitcpio.log"; exit 0 ;;
        \\    esac
        \\    case $arg in --output=*) out=${arg#--output=} ;; --cmdline=*) cmdline=" cmdline=${arg#--cmdline=}" ;; esac
        \\    prev=$arg
        \\done
        \\printf 'built%s' "$cmdline" > "$root$out"
        \\
    });
    return a.dupe([]const u8, &.{ "sh", try std.fmt.allocPrint(a, "{s}/chroot.sh", .{base}) });
}

test "an efi binary without a certificate table isn't signed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(io, .{ .sub_path = "plain.efi", .data = "not an efi binary" });
    try std.testing.expect(!fileSigned(io, try std.fmt.allocPrint(a, "{s}/plain.efi", .{base}), null));
    try std.testing.expect(!fileSigned(io, try std.fmt.allocPrint(a, "{s}/missing.efi", .{base}), null));
}

test "a work directory in a root's /tmp is made fresh, and root's alone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    // someone else's directory, and a link to it where os works.
    try tmp.dir.createDirPath(io, "theirs");
    try tmp.dir.writeFile(io, .{ .sub_path = "theirs/yoq.efi", .data = "theirs" });
    try tmp.dir.createDirPath(io, "top/@roots/2/tmp");
    try tmp.dir.symLink(io, try std.fmt.allocPrint(a, "{s}/theirs", .{try std.Io.Dir.cwd().realPathFileAlloc(io, base, a)}), "top/@roots/2/" ++ sign_dir, .{});
    const m: Machine = .{ .a = a, .io = io, .boot = .{}, .loader = .grub, .root_uuid = "r", .esp_uuid = "e", .top = try std.fmt.allocPrint(a, "{s}/top", .{base}) };
    const work = try m.at(&.{ "/@roots/2", sign_dir });
    try std.testing.expectEqual(null, try freshDir(&m, work));
    const st = try tmp.dir.statFile(io, "top/@roots/2/" ++ sign_dir, .{ .follow_symlinks = false });
    try std.testing.expectEqual(.directory, st.kind);
    try std.testing.expectEqual(0o700, @intFromEnum(st.permissions) & 0o777);
    try std.testing.expectEqualStrings("theirs", try tmp.dir.readFileAlloc(io, "theirs/yoq.efi", a, .limited(64)));
}
