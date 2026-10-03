//! checks of a plan against the machine before anything is built: room
//! on the esp for the boot files and images the next generation needs,
//! the secrets its files name, sbctl's keys for a config that signs
//! images, and a way to unlock a luks root. pure, like the planner: they
//! go by the config, the plan, and the facts alone.

const std = @import("std");
const config = @import("config.zig");
const facts = @import("facts.zig");
const diag = @import("diag.zig");
const generation = @import("generation.zig");
const menu = @import("menu.zig");
const uki = @import("uki.zig");
const secureboot = @import("secureboot.zig");
const planner = @import("planner.zig");
const desired = @import("desired.zig");
const Plan = planner.Plan;
const Allocator = std.mem.Allocator;

/// whether the plan passes every check, run in the order `yos plan` and
/// `yos apply` report them, stopping at the first that refuses.
pub fn passes(a: Allocator, c: *const config.Config, p: *const Plan, f: *const facts.Facts, diags: *diag.List) !bool {
    return try checkEsp(a, p, f, diags) and try checkSecrets(c, f, diags) and try checkSecureBoot(c, f, diags) and try checkLuks(c, p, f, diags);
}

/// the room on the esp a plan's new boot files take.
pub const EspNeed = struct {
    /// bytes, estimated.
    need: u64,
    /// older generations keep copies of their boot files there, which
    /// `yos gc` frees.
    collectable: bool,
};

/// an estimate of the room on the esp the next generation's new boot
/// files take, or null if the plan puts none there or there's nothing to
/// go by. installed file sizes aren't in the lock, so it goes by the boot
/// files the running root has now, a sixteenth bigger: a kernel the plan
/// changes gets a new kernel and initramfs, one it adds gets a pair like
/// the largest there, an initramfs change gets every initramfs new, and a
/// microcode change the microcode images too. limine and systemd-boot, and
/// any bootloader on a luks root, keep every generation's copies side by
/// side, so those add up. with the esp
/// at /boot, the first good boot also puts them over the running ones
/// there, one at a time.
///
/// with `uki_on`, the next generation boots unified kernel images, which
/// are on the esp for every bootloader: each kernel the plan touches gets
/// an image as big as its kernel, initramfs, and microcode together, plus
/// the stub. turning `[boot] uki` on or off makes every kernel's boot
/// files new.
pub fn espNeed(p: *const Plan, b: *const facts.Boot, uki_on: bool) ?EspNeed {
    if (!generation.running(b.root_subvol)) return null;
    const esp = b.esp orelse return null;
    if (menu.Loader.of(b.*) == null) return null;
    const hashed = menu.copiesOnEsp(b.*) or uki_on;
    const in_place = std.mem.eql(u8, esp, "/boot");
    if (!hashed and !in_place) return null;

    var initramfs = false;
    var microcode = false;
    var every = false;
    // systemd brings the stub, which every image starts with.
    var stub = false;
    for (p.changes) |c| {
        const r = c.reboot orelse continue;
        if (std.mem.eql(u8, r, "initramfs") or std.mem.eql(u8, r, "microcode")) initramfs = true;
        if (std.mem.eql(u8, r, "microcode")) microcode = true;
        if (std.mem.eql(u8, r, desired.uki_reboot)) every = true;
        if (std.mem.eql(u8, r, "systemd")) stub = true;
    }
    // the files the plan changes, and every file, for a menu that stops
    // booting images and needs copies of them all again.
    var est: Estimate = .{};
    var all: Estimate = .{};
    var images: Estimate = .{};
    var largest: [2]u64 = .{ 0, 0 };
    var ucode: u64 = 0;
    for (b.boot_files) |f| {
        all.add(f.size, f.size);
        if (kernelOf(f.name)) |k| {
            const i: usize = if (std.mem.startsWith(u8, f.name, "vmlinuz-")) 0 else 1;
            largest[i] = @max(largest[i], f.size);
            if ((i == 1 and initramfs) or kernelChanges(p, k)) est.add(f.size, f.size);
        } else {
            ucode += f.size;
            if (microcode) est.add(f.size, f.size);
        }
    }
    if (uki_on) {
        for (b.boot_files) |f| {
            if (!std.mem.startsWith(u8, f.name, "vmlinuz-")) continue;
            const k = f.name["vmlinuz-".len..];
            if (every or stub or initramfs or kernelChanges(p, k)) images.add(f.size + initramfsSize(b, k) + ucode + uki.stub_size, 0);
        }
    }
    for (p.changes) |c| {
        if (c.op != .add or !std.mem.eql(u8, c.reboot orelse "", "kernel")) continue;
        if (hasKernel(b, c.subject)) continue;
        for ([_]*Estimate{ &est, &all }) |e| {
            e.add(largest[0], 0);
            e.add(largest[1], 0);
        }
        if (uki_on) images.add(largest[0] + largest[1] + ucode + uki.stub_size, 0);
    }
    const copies = if (uki_on) images.total else if (every) all.total else est.total;
    const need = (if (hashed) copies else 0) + (if (in_place) est.growth + est.lead else 0);
    if (need == 0) return null;
    return .{ .need = need, .collectable = hashed };
}

/// the size of kernel `kernel`'s initramfs among the boot files, 0 if it
/// has none.
fn initramfsSize(b: *const facts.Boot, kernel: []const u8) u64 {
    for (b.boot_files) |f| {
        if (!std.mem.startsWith(u8, f.name, "initramfs-")) continue;
        if (std.mem.eql(u8, kernelOf(f.name) orelse continue, kernel)) return f.size;
    }
    return 0;
}

/// whether the generation a plan makes boots unified kernel images: the
/// plan writes the ukify config, or keeps the one there.
pub fn ukiAfter(p: *const Plan, f: *const facts.Facts) bool {
    for (p.changes) |c| {
        if (c.kind == .file and std.mem.eql(u8, c.subject, uki.config_path)) return c.op != .remove;
    }
    return f.file(uki.config_path) != null;
}

/// new boot files, as `espNeed` adds them up.
const Estimate = struct {
    /// all of them.
    total: u64 = 0,
    /// what each adds over the file it replaces.
    growth: u64 = 0,
    /// the most any one takes beyond that while it's copied in beside
    /// the file it replaces.
    lead: u64 = 0,

    fn add(e: *Estimate, now: u64, replaces: u64) void {
        const size = now +| now / 16;
        const grows = size -| replaces;
        e.total +|= size;
        e.growth +|= grows;
        e.lead = @max(e.lead, size - grows);
    }
};

/// the kernel a boot file belongs to: "linux" for vmlinuz-linux and
/// initramfs-linux.img. null for microcode.
fn kernelOf(name: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, name, "vmlinuz-")) return name["vmlinuz-".len..];
    if (std.mem.startsWith(u8, name, "initramfs-") and std.mem.endsWith(u8, name, ".img")) return name["initramfs-".len .. name.len - ".img".len];
    return null;
}

fn hasKernel(b: *const facts.Boot, kernel: []const u8) bool {
    for (b.boot_files) |f| {
        if (std.mem.startsWith(u8, f.name, "vmlinuz-") and std.mem.eql(u8, f.name["vmlinuz-".len..], kernel)) return true;
    }
    return false;
}

/// whether the plan installs or upgrades the kernel package `kernel`.
fn kernelChanges(p: *const Plan, kernel: []const u8) bool {
    for (p.changes) |c| {
        if (c.op != .remove and std.mem.eql(u8, c.reboot orelse "", "kernel") and std.mem.eql(u8, c.subject, kernel)) return true;
    }
    return false;
}

/// refuses, with a diagnostic, a plan whose new boot files won't fit on
/// the esp, so nothing gets built only to be thrown away. returns whether
/// the plan can go ahead. the record step checks again with the real
/// files.
pub fn checkEsp(a: Allocator, p: *const Plan, f: *const facts.Facts, diags: *diag.List) !bool {
    const b = &f.boot;
    const uki_on = ukiAfter(p, f);
    var e = espNeed(p, b, uki_on) orelse EspNeed{ .need = 0, .collectable = true };
    e.need +|= try resignRoom(a, p, f, uki_on);
    e.need +|= embeddedRoom(p, f, uki_on);
    if (e.need == 0) return true;
    const free = b.esp_free orelse return true;
    if (generation.fits(e.need, free)) return true;
    const mib = 1 << 20;
    const of = if (b.esp_size) |s| try std.fmt.allocPrint(a, " of {d} MiB", .{s / mib}) else "";
    const hint = if (e.collectable) try generation.gcHint(a, b.generations, b.root_subvol orelse "") else generation.manual_hint;
    try diags.add(.esp_full, null, "the esp at {s} has {d} MiB free{s}, and this plan's new boot files need about {d} MiB", .{ b.esp.?, free / mib, of, (e.need + mib - 1) / mib }, hint);
    return false;
}

/// the room the menu written after a plan takes to sign an image on the
/// esp that has no signature from sbctl's db key yet: a signed copy goes
/// in beside it, one at a time, so it's the largest image, sized like a
/// new one. 0 when the menu won't sign, boots no images, or none on the
/// esp lack a signature.
fn resignRoom(a: Allocator, p: *const Plan, f: *const facts.Facts, uki_on: bool) !u64 {
    const b = &f.boot;
    if (p.changes.len == 0 or !uki_on or !generation.running(b.root_subvol)) return 0;
    const esp = b.esp orelse return 0;
    if (!signsAfter(p, f) or (try secureboot.ours(a, b.unsigned, esp)).len == 0) return 0;
    return largestImage(b);
}

/// the room the largest signed image takes, from the running root's boot
/// files, a sixteenth bigger, like a new one. yos builds its initramfs, so
/// that counts with a little to spare (see uki.signedInitramfs).
fn largestImage(b: *const facts.Boot) u64 {
    var kernel: u64 = 0;
    var initramfs: u64 = 0;
    var ucode: u64 = 0;
    for (b.boot_files) |file| {
        if (std.mem.startsWith(u8, file.name, "vmlinuz-")) {
            kernel = @max(kernel, file.size);
        } else if (kernelOf(file.name) != null) {
            initramfs = @max(initramfs, file.size);
        } else ucode +|= file.size;
    }
    var e: Estimate = .{};
    e.add(kernel +| uki.signedInitramfs(initramfs) +| ucode +| uki.stub_size, 0);
    return e.total;
}

/// the room images with their command lines in them take, beyond what
/// `espNeed` counts, when the menu written after a plan signs (see
/// images.ukiName): each entry has its own image then. the
/// generation before the new one moves to an entry with a command line of
/// its own, so it gets a new image. a plan that changes the boot files
/// gives the trial its twin of the new one, and counts the new one again
/// at its signed size, which espNeed doesn't. one that starts signing
/// gives every generation's entry, and the trial's, a new image.
fn embeddedRoom(p: *const Plan, f: *const facts.Facts, uki_on: bool) u64 {
    const b = &f.boot;
    if (p.changes.len == 0 or !uki_on or !generation.running(b.root_subvol) or b.esp == null) return 0;
    if (!signsAfter(p, f)) return 0;
    const signs_now = secureboot.enforcedWithKeys(b.secure_boot, b.sbctl_keys) or f.file(secureboot.config_path) != null;
    // the new generation's, the ones already there, and the trial's.
    if (!signs_now) return largestImage(b) *| (b.generations.len + 2);
    var images: u64 = 1;
    for (p.changes) |c| {
        if (c.reboot != null and bootFilesChange(c.reboot.?)) {
            images += 2;
            break;
        }
    }
    return largestImage(b) *| images;
}

/// whether a change for this reboot reason makes new boot files, and so
/// new images.
fn bootFilesChange(reason: []const u8) bool {
    for ([_][]const u8{ "kernel", "initramfs", "microcode", "systemd", desired.uki_reboot }) |r| {
        if (std.mem.eql(u8, reason, r)) return true;
    }
    return false;
}

/// whether the menu written after a plan signs what it boots: the
/// generation it makes or the running one has the secure boot file, or
/// the firmware enforces secure boot and sbctl has keys (see
/// images.signs). a plan that removes the file still signs once,
/// since the running root has it.
fn signsAfter(p: *const Plan, f: *const facts.Facts) bool {
    if (secureboot.enforcedWithKeys(f.boot.secure_boot, f.boot.sbctl_keys)) return true;
    for (p.changes) |c| {
        if (c.kind == .file and std.mem.eql(u8, c.subject, secureboot.config_path)) return true;
    }
    return f.file(secureboot.config_path) != null;
}

/// refuses, with a diagnostic, a plan for a config whose secrets this
/// machine doesn't have. secrets the observer couldn't look at pass: apply
/// runs as root and looks again.
pub fn checkSecrets(c: *const config.Config, f: *const facts.Facts, diags: *diag.List) !bool {
    var ok = true;
    for (c.files.entries.items) |e| {
        const ref = e.value.secret orelse continue;
        const s = f.secret(ref.v) orelse continue;
        switch (s.state) {
            .set, .unknown => continue,
            .missing => try diags.addHint(.secret_missing, ref.src, "files.\"{s}\" needs the secret \"{s}\", and this machine doesn't have it", .{ e.name, ref.v }, "set it with `yos secret set {s}`", .{ref.v}),
            .unreadable => try diags.addHint(.secret_missing, ref.src, "the secret \"{s}\" for files.\"{s}\" can't be decrypted on this machine", .{ ref.v, e.name }, "values don't move between machines; set it again here with `yos secret set {s}`", .{ref.v}),
        }
        ok = false;
    }
    return ok;
}

/// refuses, with a diagnostic, a plan for a machine with generations
/// whose config signs images for secure boot, when sbctl has no keys to
/// sign them with, or grub couldn't start: without shim, grub's lockdown
/// loads nothing unless grub's tpm module checks it, and that module
/// does nothing without a tpm 2.0. yos never makes or enrolls keys
/// itself. returns whether the plan can go ahead.
pub fn checkSecureBoot(c: *const config.Config, f: *const facts.Facts, diags: *diag.List) !bool {
    const v = c.boot.secure_boot orelse return true;
    if (!v.v or !generation.running(f.boot.root_subvol)) return true;
    if (!f.boot.sbctl_keys) {
        try diags.add(.secure_boot_keys, v.src, "secure_boot is on, but sbctl has no keys in {s} to sign with", .{secureboot.keys_dir}, "run `sbctl create-keys`, then plan again. enroll the keys only once a generation with signed images is ready");
        return false;
    }
    // images signed with keys the firmware doesn't have won't start, and
    // limine and refind stop there for good instead of falling back.
    if (f.boot.secure_boot == true and f.boot.db_enrolled == false) {
        try diags.add(.secure_boot_enrolled, v.src, "the firmware enforces secure boot, but sbctl's keys in {s} aren't enrolled in it", .{secureboot.keys_dir}, "images signed with them wouldn't start. put the firmware in setup mode and run `sbctl enroll-keys -m`, or turn secure boot off in the firmware until then");
        return false;
    }
    if (std.mem.eql(u8, f.boot.loader orelse "", "grub") and f.boot.tpm2 == false) {
        try diags.add(.secure_boot_tpm, v.src, "secure_boot is on, but grub can't start under secure boot without a tpm 2.0", .{}, "turn the tpm on in the firmware setup, or leave secure_boot off on this machine");
        return false;
    }
    return true;
}

/// refuses, with a diagnostic, a plan that removes yos's drop-in that
/// unlocks a luks root while mkinitcpio's own hooks don't: the initramfs
/// built after it couldn't open the root, and without generations
/// nothing would boot. returns whether the plan can go ahead.
pub fn checkLuks(c: *const config.Config, p: *const Plan, f: *const facts.Facts, diags: *diag.List) !bool {
    if (f.boot.luks_uuid == null or facts.hasEncryptHook(f.boot.initramfs_hooks)) return true;
    if (c.providers.get("initramfs")) |pr| {
        if (!std.mem.eql(u8, pr.v, "mkinitcpio")) return true;
    }
    for (p.changes) |ch| {
        if (ch.kind != .file or ch.op != .remove or !std.mem.eql(u8, ch.subject, desired.encrypt_initramfs_path)) continue;
        const src = if (c.boot.encrypt) |e| e.src else null;
        try diags.add(.luks_locked, src, "the root is on luks, and without [boot] encrypt nothing in the initramfs would unlock it", .{}, "keep `encrypt = true` under [boot], or add sd-encrypt to HOOKS in /etc/mkinitcpio.conf first");
        return false;
    }
    return true;
}

const testing = std.testing;
const helpers = @import("test_helpers.zig");
const T = helpers.Scratch;
const lock = @import("lock.zig");
const plan = planner.plan;

test "turning encrypt off stops the plan when nothing else would unlock a luks root" {
    var t: T = .{};
    defer t.deinit();
    const a = t.a();
    var files = [_]facts.File{.{ .path = desired.encrypt_initramfs_path, .sha256 = &facts.sha256Hex(desired.encrypt_initramfs_content), .mode = "0644", .ours = true }};
    const hooks = [_][]const u8{ "base", "systemd", "autodetect", "block", "filesystems" };
    const luks: facts.Facts = .{ .files = &files, .boot = .{ .luks_uuid = "0f7a1c2e", .encrypt_dropin = true, .initramfs_hooks = &hooks } };
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{} };
    for ([_][]const u8{ "[boot]\nkernel = \"none\"\n", "[boot]\nkernel = \"none\"\nencrypt = false\n" }) |text| {
        const off = try t.cfg(text);
        const p = (try plan(a, &off, &l, &luks, &t.diags)).?;
        try testing.expect(!try checkLuks(&off, &p, &luks, &t.diags));
        try testing.expectEqual(diag.Code.luks_locked, t.diags.items.items[t.diags.items.items.len - 1].code);
        // a root that isn't on luks, hooks that unlock it themselves, or
        // another initramfs generator: the drop-in can go.
        var plain = luks;
        plain.boot.luks_uuid = null;
        try testing.expect(try checkLuks(&off, &p, &plain, &t.diags));
        var hooked = luks;
        hooked.boot.initramfs_hooks = &.{ "base", "systemd", "sd-encrypt", "filesystems" };
        try testing.expect(try checkLuks(&off, &p, &hooked, &t.diags));
    }
    const booster = try t.cfg("[boot]\nkernel = \"none\"\n[providers]\ninitramfs = \"booster\"\n");
    try testing.expect(try checkLuks(&booster, &(try plan(a, &booster, &l, &luks, &t.diags)).?, &luks, &t.diags));
    // left on, nothing is removed.
    const on = try t.cfg("[boot]\nkernel = \"none\"\nencrypt = true\n");
    try testing.expect(try checkLuks(&on, &(try plan(a, &on, &l, &luks, &t.diags)).?, &luks, &t.diags));
}

test "secure boot without sbctl's keys stops the plan" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("[boot]\nkernel = \"none\"\nuki = true\nsecure_boot = true\n");
    try testing.expect(try checkSecureBoot(&c, &.{ .boot = .{ .root_fs = "btrfs", .root_subvol = "/@roots/3", .sbctl_keys = true } }, &t.diags));
    // without generations, nothing is signed, so nothing needs keys.
    try testing.expect(try checkSecureBoot(&c, &.{ .boot = .{ .root_fs = "ext4" } }, &t.diags));
    try testing.expectEqual(0, t.diags.items.items.len);
    try testing.expect(!try checkSecureBoot(&c, &.{ .boot = .{ .root_fs = "btrfs", .root_subvol = "/@roots/3" } }, &t.diags));
    try testing.expectEqual(1, t.diags.items.items.len);
    const d = t.diags.items.items[0];
    try testing.expectEqual(diag.Code.secure_boot_keys, d.code);
    try testing.expectEqualStrings("secure_boot is on, but sbctl has no keys in /var/lib/sbctl/keys to sign with", d.message);
    try testing.expect(std.mem.startsWith(u8, d.hint.?, "run `sbctl create-keys`"));
    const off = try t.cfg("[boot]\nkernel = \"none\"\nuki = true\nsecure_boot = false\n");
    try testing.expect(try checkSecureBoot(&off, &.{ .boot = .{ .root_fs = "btrfs", .root_subvol = "/@roots/3" } }, &t.diags));

    // grub can't start under secure boot without a tpm 2.0; unknown is let through.
    const grub: facts.Boot = .{ .root_fs = "btrfs", .root_subvol = "/@roots/3", .sbctl_keys = true, .loader = "grub", .tpm2 = false };
    try testing.expect(!try checkSecureBoot(&c, &.{ .boot = grub }, &t.diags));
    try testing.expectEqual(diag.Code.secure_boot_tpm, t.diags.items.items[1].code);
    var with_tpm = grub;
    with_tpm.tpm2 = true;
    try testing.expect(try checkSecureBoot(&c, &.{ .boot = with_tpm }, &t.diags));
    var sdboot = grub;
    sdboot.loader = "systemd-boot";
    try testing.expect(try checkSecureBoot(&c, &.{ .boot = sdboot }, &t.diags));
    // enforced, with keys the firmware doesn't have. in setup mode the
    // firmware enforces nothing, which is when keys get enrolled.
    var other_keys = sdboot;
    other_keys.secure_boot = true;
    other_keys.db_enrolled = false;
    try testing.expect(!try checkSecureBoot(&c, &.{ .boot = other_keys }, &t.diags));
    try testing.expectEqual(diag.Code.secure_boot_enrolled, t.diags.items.items[2].code);
    other_keys.secure_boot = false;
    try testing.expect(try checkSecureBoot(&c, &.{ .boot = other_keys }, &t.diags));
    other_keys.secure_boot = true;
    other_keys.db_enrolled = true;
    try testing.expect(try checkSecureBoot(&c, &.{ .boot = other_keys }, &t.diags));
}

test "how much room a plan's new boot files take on the esp" {
    const mib = 1 << 20;
    const files = [_]facts.BootFile{
        .{ .name = "amd-ucode.img", .size = 4 * mib },
        .{ .name = "initramfs-linux.img", .size = 32 * mib },
        .{ .name = "vmlinuz-linux", .size = 16 * mib },
    };
    var b: facts.Boot = .{ .esp = "/efi", .loader = "systemd-boot", .root_subvol = "/@roots/3", .boot_files = &files };
    const upgrade: Plan = .{ .changes = &.{.{ .op = .change, .kind = .package, .subject = "linux", .from = "6.16.8", .to = "6.17.1", .reboot = "kernel" }} };
    // limine and systemd-boot keep the new pair beside the old one.
    try testing.expectEqual(EspNeed{ .need = 51 * mib, .collectable = true }, espNeed(&upgrade, &b, false).?);
    const lts: Plan = .{ .changes = &.{.{ .op = .add, .kind = .package, .subject = "linux-lts", .to = "6.12.48", .reboot = "kernel" }} };
    try testing.expectEqual(51 * mib, espNeed(&lts, &b, false).?.need);
    const ucode: Plan = .{ .changes = &.{.{ .op = .change, .kind = .package, .subject = "amd-ucode", .from = "1", .to = "2", .reboot = "microcode" }} };
    try testing.expectEqual(38 * mib + mib / 4, espNeed(&ucode, &b, false).?.need);
    const drop_in: Plan = .{ .changes = &.{.{ .op = .add, .kind = .file, .subject = "/etc/mkinitcpio.conf.d/10-yos-nvidia.conf", .reboot = "initramfs" }} };
    try testing.expectEqual(34 * mib, espNeed(&drop_in, &b, false).?.need);
    // nothing new to boot, or a kernel that goes.
    const tool: Plan = .{ .changes = &.{.{ .op = .add, .kind = .package, .subject = "ripgrep", .to = "14" }} };
    try testing.expectEqual(null, espNeed(&tool, &b, false));
    const gone: Plan = .{ .changes = &.{.{ .op = .remove, .kind = .package, .subject = "linux", .from = "6.16.8", .reboot = "kernel" }} };
    try testing.expectEqual(null, espNeed(&gone, &b, false));

    // with the esp at /boot, a good boot also puts them over the running
    // ones, one at a time: the growth, and the largest while it's copied.
    b.esp = "/boot";
    try testing.expectEqual(EspNeed{ .need = (51 + 35) * mib, .collectable = true }, espNeed(&upgrade, &b, false).?);
    b.loader = "grub";
    try testing.expectEqual(EspNeed{ .need = 35 * mib, .collectable = false }, espNeed(&upgrade, &b, false).?);
    // grub and refind read each root's kernel over btrfs.
    b.esp = "/efi";
    try testing.expectEqual(null, espNeed(&upgrade, &b, false));
    b.loader = "refind";
    try testing.expectEqual(null, espNeed(&upgrade, &b, false));
    // unless the root is on luks: then they can't, and boot copies on the
    // esp like limine.
    b.luks_uuid = "0f7a1c2e-9b3d-4e5f-8a6b-7c8d9e0f1a2b";
    try testing.expectEqual(EspNeed{ .need = 51 * mib, .collectable = true }, espNeed(&upgrade, &b, false).?);
    // without generations, pacman changes the files in place, as always.
    b = .{ .esp = "/boot", .loader = "systemd-boot", .root_subvol = "/@", .boot_files = &files };
    try testing.expectEqual(null, espNeed(&upgrade, &b, false));
    // no boot files to go by.
    b = .{ .esp = "/efi", .loader = "limine", .root_subvol = "/@roots/3" };
    try testing.expectEqual(null, espNeed(&upgrade, &b, false));
}

test "unified kernel images on the esp take a kernel's files together" {
    const mib = 1 << 20;
    const k = 16 * mib - uki.stub_size;
    const files = [_]facts.BootFile{
        .{ .name = "amd-ucode.img", .size = 4 * mib },
        .{ .name = "initramfs-linux.img", .size = 28 * mib },
        .{ .name = "vmlinuz-linux", .size = k },
    };
    // 4 + 28 + 16 MiB with the stub, and a sixteenth: 51 MiB an image.
    var b: facts.Boot = .{ .esp = "/efi", .loader = "grub", .root_subvol = "/@roots/3", .boot_files = &files };
    const upgrade: Plan = .{ .changes = &.{.{ .op = .change, .kind = .package, .subject = "linux", .from = "6.16.8", .to = "6.17.1", .reboot = "kernel" }} };
    // grub reads the roots, but images are on the esp for every bootloader.
    try testing.expectEqual(null, espNeed(&upgrade, &b, false));
    try testing.expectEqual(EspNeed{ .need = 51 * mib, .collectable = true }, espNeed(&upgrade, &b, true).?);
    const drop_in: Plan = .{ .changes = &.{.{ .op = .add, .kind = .file, .subject = "/etc/mkinitcpio.conf.d/10-yos-nvidia.conf", .reboot = "initramfs" }} };
    try testing.expectEqual(51 * mib, espNeed(&drop_in, &b, true).?.need);
    const lts: Plan = .{ .changes = &.{.{ .op = .add, .kind = .package, .subject = "linux-lts", .to = "6.12.48", .reboot = "kernel" }} };
    try testing.expectEqual(51 * mib, espNeed(&lts, &b, true).?.need);
    const tool: Plan = .{ .changes = &.{.{ .op = .add, .kind = .package, .subject = "ripgrep", .to = "14" }} };
    try testing.expectEqual(null, espNeed(&tool, &b, true));
    // a new systemd brings a new stub, and every image is new.
    const systemd: Plan = .{ .changes = &.{.{ .op = .change, .kind = .package, .subject = "systemd", .from = "258-1", .to = "258-2", .reboot = "systemd" }} };
    try testing.expectEqual(51 * mib, espNeed(&systemd, &b, true).?.need);
    try testing.expectEqual(null, espNeed(&systemd, &b, false));
    // turning them on makes every kernel's image.
    const on: Plan = .{ .changes = &.{.{ .op = .add, .kind = .file, .subject = uki.config_path, .reboot = desired.uki_reboot }} };
    try testing.expectEqual(51 * mib, espNeed(&on, &b, true).?.need);
    // turning them off on systemd-boot needs copies of every file again.
    b.loader = "systemd-boot";
    const off: Plan = .{ .changes = &.{.{ .op = .remove, .kind = .file, .subject = uki.config_path, .reboot = desired.uki_reboot }} };
    try testing.expectEqual(34 * mib + k + k / 16, espNeed(&off, &b, false).?.need);
    b.loader = "grub";
    try testing.expectEqual(null, espNeed(&off, &b, false));
    // with the esp at /boot, a good boot puts the files there as before.
    b.esp = "/boot";
    try testing.expectEqual(EspNeed{ .need = 51 * mib + 28 * mib + 28 * mib / 16 + k / 16, .collectable = true }, espNeed(&upgrade, &b, true).?);
}

test "a plan whose boot files don't fit on the esp stops before anything is built" {
    var t: T = .{};
    defer t.deinit();
    const a = t.a();
    const mib = 1 << 20;
    const files = [_]facts.BootFile{
        .{ .name = "initramfs-linux.img", .size = 32 * mib },
        .{ .name = "vmlinuz-linux", .size = 16 * mib },
    };
    const gens = [_]facts.Generation{
        .{ .n = 1, .root = "@roots/1" },
        .{ .n = 2, .root = "@roots/1" },
        .{ .n = 3, .root = "@roots/3" },
    };
    var f: facts.Facts = .{ .boot = .{ .esp = "/efi", .loader = "limine", .root_subvol = "/@roots/3", .esp_free = 40 * mib, .esp_size = 512 * mib, .boot_files = &files, .generations = &gens } };
    const upgrade: Plan = .{ .changes = &.{.{ .op = .change, .kind = .package, .subject = "linux", .from = "6.16.8", .to = "6.17.1", .reboot = "kernel" }} };
    try testing.expect(!try checkEsp(a, &upgrade, &f, &t.diags));
    const d = t.diags.items.items[0];
    try testing.expectEqual(diag.Code.esp_full, d.code);
    try testing.expectEqualStrings("the esp at /efi has 40 MiB free of 512 MiB, and this plan's new boot files need about 51 MiB", d.message);
    try testing.expectEqualStrings("`yos gc --keep 1` removes generation 2, with the boot files only it uses", d.hint.?);

    // grub with the esp at /boot: removing generations frees nothing there.
    f.boot.esp = "/boot";
    f.boot.loader = "grub";
    f.boot.esp_free = 20 * mib;
    f.boot.esp_size = null;
    try testing.expect(!try checkEsp(a, &upgrade, &f, &t.diags));
    try testing.expectEqualStrings("the esp at /boot has 20 MiB free, and this plan's new boot files need about 35 MiB", t.diags.items.items[1].message);
    try testing.expectEqualStrings(generation.manual_hint, t.diags.items.items[1].hint.?);

    // room enough, with a mebibyte to spare; or no telling how much.
    f.boot.esp_free = 36 * mib;
    try testing.expect(try checkEsp(a, &upgrade, &f, &t.diags));
    f.boot.esp_free = null;
    try testing.expect(try checkEsp(a, &upgrade, &f, &t.diags));
    try testing.expectEqual(2, t.diags.items.items.len);
}

test "signing an image already on the esp needs room beside it" {
    var t: T = .{};
    defer t.deinit();
    const a = t.a();
    const mib = 1 << 20;
    const boot_files = [_]facts.BootFile{
        .{ .name = "initramfs-linux.img", .size = 32 * mib },
        .{ .name = "vmlinuz-linux", .size = 16 * mib },
    };
    var files = [_]facts.File{.{ .path = uki.config_path, .sha256 = &facts.sha256Hex(uki.config_content), .mode = "0644", .ours = true }};
    var f: facts.Facts = .{ .files = &files, .boot = .{
        .esp = "/efi",
        .loader = "grub",
        .root_subvol = "/@roots/3",
        .esp_free = 100 * mib,
        .boot_files = &boot_files,
        .secure_boot = true,
        .sbctl_keys = true,
        .unsigned = &.{"/efi/yos/boot/0123456789abcdef-yos.efi"},
    } };
    // a change that brings no new boot files; the menu after it still
    // signs the image, in a copy beside it, and the generation before
    // the new one gets an image with its own command line in it.
    const tool: Plan = .{ .changes = &.{.{ .op = .add, .kind = .package, .subject = "tree", .to = "2.2.1" }} };
    try testing.expect(!try checkEsp(a, &tool, &f, &t.diags));
    try testing.expectEqualStrings("the esp at /efi has 100 MiB free, and this plan's new boot files need about 112 MiB", t.diags.items.items[0].message);
    // with nothing unsigned, or nothing that signs, there's room.
    f.boot.unsigned = &.{"/efi/EFI/BOOT/BOOTX64.EFI"};
    try testing.expect(try checkEsp(a, &tool, &f, &t.diags));
    f.boot.unsigned = &.{"/efi/yos/boot/0123456789abcdef-yos.efi"};
    f.boot.secure_boot = false;
    try testing.expect(try checkEsp(a, &tool, &f, &t.diags));
    // the config's key signs too, and an empty plan writes no menu.
    files[0].path = secureboot.config_path;
    var both = [_]facts.File{ .{ .path = uki.config_path, .sha256 = "", .mode = "0644" }, files[0] };
    f.files = &both;
    try testing.expect(!try checkEsp(a, &tool, &f, &t.diags));
    try testing.expect(try checkEsp(a, &.{ .changes = &.{} }, &f, &t.diags));
}

test "with secure boot, each entry's image has its command line, and takes room" {
    const mib = 1 << 20;
    const boot_files = [_]facts.BootFile{
        .{ .name = "initramfs-linux.img", .size = 32 * mib },
        .{ .name = "vmlinuz-linux", .size = 16 * mib },
    };
    // yos builds the initramfs for a signed image, with an eighth to spare.
    const now = 16 * mib + 36 * mib + uki.stub_size;
    const image = now + now / 16;
    var files = [_]facts.File{
        .{ .path = uki.config_path, .sha256 = "", .mode = "0644" },
        .{ .path = secureboot.config_path, .sha256 = "", .mode = "0644" },
    };
    const gens = [_]facts.Generation{ .{ .n = 1, .root = "@roots/1" }, .{ .n = 2, .root = "@roots/2" } };
    var f: facts.Facts = .{ .files = &files, .boot = .{ .esp = "/efi", .loader = "grub", .root_subvol = "/@roots/3", .boot_files = &boot_files, .generations = &gens } };
    const tool: Plan = .{ .changes = &.{.{ .op = .add, .kind = .package, .subject = "tree", .to = "2.2.1" }} };
    const upgrade: Plan = .{ .changes = &.{.{ .op = .change, .kind = .package, .subject = "linux", .from = "6.16.8", .to = "6.17.1", .reboot = "kernel" }} };
    // the generation before the new one moves to an entry of its own.
    try testing.expectEqual(image, embeddedRoom(&tool, &f, true));
    // new boot files give the trial a twin of the new image, and the new
    // one counts again at its signed size, besides what espNeed counts.
    try testing.expectEqual(3 * image, embeddedRoom(&upgrade, &f, true));
    // no images, an empty plan, or no signing: nothing.
    try testing.expectEqual(0, embeddedRoom(&tool, &f, false));
    try testing.expectEqual(0, embeddedRoom(&.{ .changes = &.{} }, &f, true));
    f.files = files[0..1];
    try testing.expectEqual(0, embeddedRoom(&tool, &f, true));
    // a plan that starts signing makes every entry's image new: the two
    // generations there, the new one, and the trial's.
    const on: Plan = .{ .changes = &.{.{ .op = .add, .kind = .file, .subject = secureboot.config_path, .reboot = desired.secure_boot_reboot }} };
    try testing.expectEqual(4 * image, embeddedRoom(&on, &f, true));
    // firmware that enforces it, with keys, signs already.
    f.boot.secure_boot = true;
    f.boot.sbctl_keys = true;
    try testing.expectEqual(image, embeddedRoom(&on, &f, true));
}
