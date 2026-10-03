//! what `yos uninstall` checks and does, worked out from facts alone. it
//! leaves plain arch on the generation that's running: the config stays in
//! /etc/yos, the bootloader boots this root the way arch sets it up, and
//! yos's own state goes. like enable.zig, it reads no files and runs nothing.

const std = @import("std");
const enable = @import("enable.zig");
const facts = @import("facts.zig");
const generation = @import("generation.zig");
const menu = @import("menu.zig");
const Allocator = std.mem.Allocator;

pub const Kind = enum { config_dir, units, pacman_db, boot_menu, snap_pac, generations, package, state };

pub const Step = struct {
    kind: Kind,
    what: []const u8,
};

pub const Plan = struct {
    checks: []const enable.Check,
    steps: []const Step,
    /// what to expect after, which changes nothing.
    notes: []const []const u8 = &.{},

    pub fn ready(p: *const Plan) bool {
        return enable.allOk(p.checks);
    }
};

/// yos's own package, if pacman installed it.
pub fn ownPackage(f: *const facts.Facts) ?[]const u8 {
    for (f.packages) |p| {
        if (std.mem.eql(u8, p.name, "yos") or std.mem.eql(u8, p.name, "yos-git")) return p.name;
    }
    return null;
}

/// `drop_generations` adds the step that deletes every generation but the
/// running one. `unsigned_kernels` are the kernels on the esp's top,
/// where arch installs them with the esp at /boot, that have no
/// signature. `tpm_unlock` says the tpm unlocks a luks root at boot.
pub fn plan(a: Allocator, f: *const facts.Facts, drop_generations: bool, unsigned_kernels: []const []const u8, tpm_unlock: bool) !Plan {
    const b = f.boot;
    var checks: std.ArrayList(enable.Check) = .empty;
    var steps: std.ArrayList(Step) = .empty;
    var notes: std.ArrayList([]const u8) = .empty;
    // a boot through systemd's stub, as every unified kernel image has,
    // adds an os separator to pcr 7, and arch's plain kernel boots without
    // one. a tpm key made while images booted doesn't match then.
    if (tpm_unlock and b.uki and generation.running(b.root_subvol)) if (b.luks_uuid) |uuid| {
        const device = b.luks_device orelse try std.fmt.allocPrint(a, "/dev/disk/by-uuid/{s}", .{uuid});
        try notes.append(a, try std.fmt.allocPrint(a, "the next boot asks for the passphrase once: the tpm's key was made while this machine booted unified kernel images, whose stub adds to pcr 7, and arch's plain kernel boots without one. after that boot, run `systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 {s}` and type the passphrase, and the tpm unlocks it again.", .{device}));
    };
    if (generation.running(b.root_subvol)) {
        const loader = menu.Loader.of(b) orelse .grub;
        // a plain limine, refind, or systemd-boot finds arch's kernels in
        // /boot only when that's the esp, as archinstall sets them up.
        if (loader != .grub) try checks.append(a, .{
            .what = "esp",
            .ok = std.mem.eql(u8, b.esp orelse "", "/boot"),
            .found = b.esp orelse "not mounted",
            .fix = try std.fmt.allocPrint(a, "without yos, {s} boots the kernel arch installs in /boot, so the esp has to be mounted there.", .{@tagName(loader)}),
        });
        // yos's images are signed, but grub, systemd-boot, and refind
        // start arch's plain kernel through the firmware, which refuses
        // one without a signature while it enforces secure boot. limine
        // loads kernels itself. grub is installed again, and has to be
        // signed too.
        const sb = b.secure_boot == true;
        if (sb and loader == .grub) try checks.append(a, .{
            .what = "secure boot",
            .ok = b.sbctl_keys,
            .found = if (b.sbctl_keys) "enforced, and sbctl has keys to sign grub" else "enforced, and sbctl has no keys to sign grub with",
            .fix = "grub is installed again without yos, and the firmware starts it only signed. put sbctl's keys back in /var/lib/sbctl, or turn secure boot off in the firmware setup.",
        });
        if (sb and loader != .limine) try checks.append(a, .{
            .what = "secure boot",
            .ok = unsigned_kernels.len == 0,
            .found = if (unsigned_kernels.len == 0) "enforced, and the kernels in /boot are signed" else try std.fmt.allocPrint(a, "enforced, and {s} has no signature", .{try std.mem.join(a, ", ", unsigned_kernels)}),
            .fix = try std.fmt.allocPrint(a, "without yos, {s} boots arch's kernel in /boot, not yos's signed images. sign it with `sbctl sign -s /boot/vmlinuz-linux`, and sbctl's pacman hook signs each new one too, or turn secure boot off in the firmware setup.", .{@tagName(loader)}),
        });
        try steps.append(a, .{ .kind = .config_dir, .what = "move the config from " ++ enable.config_home ++ " back into /etc/yos" });
        try steps.append(a, .{ .kind = .units, .what = "remove yos's units that run at boot and shutdown: yos-health, yos-watchdog, yos-emergency, and yos-carry, and its mkinitcpio hook" });
        if (b.pacman_moved) try steps.append(a, .{ .kind = .pacman_db, .what = "move the pacman database back to /var/lib/pacman" });
        try steps.append(a, .{ .kind = .boot_menu, .what = switch (loader) {
            .grub => try std.fmt.allocPrint(a, "reinstall grub with a menu from grub-mkconfig in /boot/grub, booting this root{s}{s}", .{
                if (b.luks_uuid != null) ", with what unlocks it added to /etc/default/grub" else "",
                if (sb) ", and sign grub with sbctl's keys" else "",
            }),
            .limine => try std.fmt.allocPrint(a, "replace yos's entries in {s} with one for this root", .{b.loader_conf orelse "limine.conf"}),
            .refind => "remove yos's entries from refind, and boot this root through /boot/refind_linux.conf",
            .@"systemd-boot" => "replace yos's entries in systemd-boot with one for this root, arch-linux.conf, as its default",
        } });
        if (b.snapper_root) try steps.append(a, .{ .kind = .snap_pac, .what = "turn snap-pac's snapshots of the root back on" });
        if (drop_generations) try steps.append(a, .{ .kind = .generations, .what = "delete every generation but this one, and their boot copies" });
    }
    // before the state, since pacman's hook would write to it.
    if (ownPackage(f)) |name| try steps.append(a, .{ .kind = .package, .what = try std.fmt.allocPrint(a, "remove the {s} package: yos itself, and its pacman hook", .{name}) });
    try steps.append(a, .{ .kind = .state, .what = "remove yos's own state: /var/lib/yos, and its files on the esp" });
    return .{ .checks = checks.items, .steps = steps.items, .notes = notes.items };
}

/// /etc/default/grub, as `text`, with a line that adds the kernel
/// arguments yos's entries passed and grub-mkconfig's wouldn't: what
/// unlocks a luks root, and the consoles. they come from `cmdline`, the
/// running one, and only the ones the file doesn't name already. null
/// when there are none to add.
pub fn grubDefaults(a: Allocator, text: []const u8, cmdline: []const u8) !?[]const u8 {
    var add: std.ArrayList(u8) = .empty;
    var words: generation.Words = .{ .text = cmdline };
    while (words.next()) |w| {
        const keep = for ([_][]const u8{ "rd.luks.", "cryptdevice=", "cryptkey=", "console=" }) |p| {
            if (std.mem.startsWith(u8, w, p)) break true;
        } else false;
        if (!keep or std.mem.indexOf(u8, text, w) != null) continue;
        try add.append(a, ' ');
        // the value goes in shell double quotes.
        for (w) |ch| {
            if (std.mem.indexOfScalar(u8, "\"\\$`", ch) != null) try add.append(a, '\\');
            try add.append(a, ch);
        }
    }
    if (add.items.len == 0) return null;
    const sep: []const u8 = if (text.len > 0 and text[text.len - 1] != '\n') "\n" else "";
    return try std.fmt.allocPrint(a, "{s}{s}\n# added by yos uninstall: kernel arguments yos's boot entries passed.\nGRUB_CMDLINE_LINUX=\"$GRUB_CMDLINE_LINUX{s}\"\n", .{ text, sep, add.items });
}

pub fn writeText(w: *std.Io.Writer, p: *const Plan) !void {
    if (p.checks.len > 0) {
        try enable.writeChecks(w, p.checks);
        try w.writeByte('\n');
    }
    try w.writeAll("steps\n");
    for (p.steps, 1..) |s, i| try w.print("  {d}. {s}\n", .{ i, s.what });
    try writeNotes(w, p);
}

/// the plan's notes, if it has any, after a blank line.
pub fn writeNotes(w: *std.Io.Writer, p: *const Plan) !void {
    if (p.notes.len == 0) return;
    try w.writeAll("\nnotes\n");
    for (p.notes) |n| try w.print("  {s}\n", .{n});
}

// -- tests --

const testing = std.testing;

test "the steps on each rung" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pkgs = [_]facts.Package{.{ .name = "yos", .version = "0.1.0-1" }};
    const manage = try plan(a, &.{ .boot = .{ .root_subvol = "/@" }, .packages = &pkgs }, true, &.{}, false);
    try testing.expectEqual(2, manage.steps.len);
    try testing.expectEqual(Kind.package, manage.steps[0].kind);
    try testing.expectEqual(Kind.state, manage.steps[1].kind);

    const gens = try plan(a, &.{ .boot = .{ .root_subvol = "/@roots/4", .loader = "grub", .esp = "/efi", .pacman_moved = true } }, false, &.{}, false);
    try testing.expect(gens.ready());
    var kinds: [6]Kind = undefined;
    for (gens.steps, 0..) |s, i| kinds[i] = s.kind;
    try testing.expectEqualSlices(Kind, &.{ .config_dir, .units, .pacman_db, .boot_menu, .state }, kinds[0..gens.steps.len]);

    // on luks, the step says grub's defaults get what unlocks the root.
    const luks = try plan(a, &.{ .boot = .{ .root_subvol = "/@roots/1", .loader = "grub", .esp = "/boot", .luks_uuid = "u" } }, false, &.{}, false);
    try testing.expect(std.mem.endsWith(u8, luks.steps[2].what, "with what unlocks it added to /etc/default/grub"));

    // under secure boot, systemd-boot and refind need arch's kernel signed.
    const sb: facts.Boot = .{ .root_subvol = "/@roots/3", .loader = "systemd-boot", .esp = "/boot", .secure_boot = true };
    const refused = try plan(a, &.{ .boot = sb }, false, &.{"vmlinuz-linux"}, false);
    try testing.expect(!refused.ready());
    try testing.expectEqualStrings("enforced, and vmlinuz-linux has no signature", refused.checks[1].found);
    try testing.expect((try plan(a, &.{ .boot = sb }, false, &.{}, false)).ready());
    var off = sb;
    off.secure_boot = false;
    try testing.expect((try plan(a, &.{ .boot = off }, false, &.{"vmlinuz-linux"}, false)).ready());
    var limine_sb = sb;
    limine_sb.loader = "limine";
    try testing.expect((try plan(a, &.{ .boot = limine_sb }, false, &.{"vmlinuz-linux"}, false)).ready());
    // grub needs arch's kernel signed, and sbctl's keys to sign itself.
    var grub_sb = sb;
    grub_sb.loader = "grub";
    const no_keys = try plan(a, &.{ .boot = grub_sb }, false, &.{}, false);
    try testing.expect(!no_keys.ready());
    try testing.expectEqualStrings("enforced, and sbctl has no keys to sign grub with", no_keys.checks[0].found);
    grub_sb.sbctl_keys = true;
    try testing.expect(!(try plan(a, &.{ .boot = grub_sb }, false, &.{"vmlinuz-linux"}, false)).ready());
    const keys = try plan(a, &.{ .boot = grub_sb }, false, &.{}, false);
    try testing.expect(keys.ready());
    try testing.expect(std.mem.endsWith(u8, keys.steps[2].what, "booting this root, and sign grub with sbctl's keys"));

    // limine without the esp at /boot can't boot arch's kernels on its own.
    const limine = try plan(a, &.{ .boot = .{ .root_subvol = "/@roots/2", .loader = "limine", .esp = "/efi", .snapper_root = true } }, true, &.{}, false);
    try testing.expect(!limine.ready());
    try testing.expectEqual(Kind.generations, limine.steps[limine.steps.len - 2].kind);
}

test "grub's defaults get what yos's entries passed to unlock the root" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // what `yos install --encrypt --tpm` boots with, from a serial console.
    const cmdline = "root=UUID=b rootflags=subvol=/@roots/1 rw console=ttyS0,115200 rd.luks.name=0f7a=root rd.luks.options=tpm2-device=auto panic=10\n";
    const stock = "GRUB_DEFAULT=0\nGRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet\"\nGRUB_CMDLINE_LINUX=\"\"\n";
    const got = (try grubDefaults(a, stock, cmdline)).?;
    try testing.expectEqualStrings(stock ++
        \\
        \\# added by yos uninstall: kernel arguments yos's boot entries passed.
        \\GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX console=ttyS0,115200 rd.luks.name=0f7a=root rd.luks.options=tpm2-device=auto"
        \\
    , got);
    // a second uninstall adds nothing, and neither does a machine whose
    // defaults had them all along.
    try testing.expectEqual(null, try grubDefaults(a, got, cmdline));
    try testing.expectEqual(null, try grubDefaults(a, "GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=x:root\"", "root=/dev/mapper/root cryptdevice=UUID=x:root rw"));
    try testing.expectEqual(null, try grubDefaults(a, stock, "root=UUID=b rw quiet"));
    // a value with shell's special characters stays as it was.
    try testing.expect(std.mem.endsWith(u8, (try grubDefaults(a, "", "console=\"a$b\"")).?, "GRUB_CMDLINE_LINUX=\"$GRUB_CMDLINE_LINUX console=\\\"a\\$b\\\"\"\n"));
}

test "leaving images behind on a luks root the tpm unlocks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b: facts.Boot = .{ .root_subvol = "/@roots/3", .loader = "grub", .esp = "/boot", .luks_uuid = "u", .luks_device = "/dev/vda2", .uki = true };
    const p = try plan(a, &.{ .boot = b }, false, &.{}, true);
    try testing.expect(p.ready());
    try testing.expectEqual(1, p.notes.len);
    try testing.expect(std.mem.startsWith(u8, p.notes[0], "the next boot asks for the passphrase once"));
    try testing.expect(std.mem.indexOf(u8, p.notes[0], "`systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 /dev/vda2`") != null);
    var out: std.Io.Writer.Allocating = .init(a);
    try writeText(&out.writer, &p);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\nnotes\n  the next boot asks") != null);
    // nothing to say with the passphrase alone, or without images.
    try testing.expectEqual(0, (try plan(a, &.{ .boot = b }, false, &.{}, false)).notes.len);
    var plain = b;
    plain.uki = false;
    try testing.expectEqual(0, (try plan(a, &.{ .boot = plain }, false, &.{}, true)).notes.len);
    // without the partition in facts, the luks volume by uuid.
    var by_uuid = b;
    by_uuid.luks_device = null;
    try testing.expect(std.mem.indexOf(u8, (try plan(a, &.{ .boot = by_uuid }, false, &.{}, true)).notes[0], "/dev/disk/by-uuid/u`") != null);
}
