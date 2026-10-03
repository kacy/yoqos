//! the facts document: what the observer saw on the machine. the planner
//! reads nothing else about the machine, and time only enters through
//! `time`, so the same facts always give the same plan.

const std = @import("std");
const lists = @import("lists.zig");
const Allocator = std.mem.Allocator;

pub const schema = "yos.facts/1";

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    /// pacman's install reason. `explicit` means someone asked for it.
    reason: Reason = .explicit,

    pub const Reason = enum { explicit, dependency };
};

pub const Unit = struct {
    name: []const u8,
    enabled: bool = false,
    /// enabling or disabling it changes nothing, as for a unit without an
    /// [install] section: it only starts and stops.
    fixed: bool = false,
    /// its unit file has no [install] section at all, so only another
    /// unit starts it at boot.
    static: bool = false,
    active: bool = false,
    /// the unit tried to run and failed.
    failed: bool = false,
    /// a oneshot service that ran and finished well: inactive, and as it
    /// should be.
    ran: bool = false,
    /// a running service's main process, 0 if there isn't one.
    main_pid: u32 = 0,
    /// that process runs files an upgrade has since replaced, so it needs
    /// a restart to pick up the new ones.
    stale: bool = false,
};

pub const User = struct {
    name: []const u8,
    uid: u32,
    shell: ?[]const u8 = null,
    /// the group from the user's own passwd entry.
    primary_group: ?[]const u8 = null,
    /// the other groups the user is a member of, by name.
    groups: []const []const u8 = &.{},

    /// a person's account, as opposed to a system one: uid 1000 up to
    /// 60000, as useradd hands them out.
    pub fn person(u: User) bool {
        return u.uid >= 1000 and u.uid <= 60000;
    }
};

/// a file yos manages, as it is on the machine.
pub const File = struct {
    path: []const u8,
    /// hex sha256 of the content.
    sha256: []const u8,
    /// octal permission bits, like "0644".
    mode: []const u8,
    /// yos wrote it: its first line says so.
    ours: bool = false,
    /// it holds a secret, so `sha256` is the keyed hash instead, or ""
    /// when that couldn't be taken.
    keyed: bool = false,
};

/// a secret the config names, as this machine has it. never the value.
pub const Secret = struct {
    name: []const u8,
    state: State = .unknown,
    /// the value's keyed hash, when it could be read.
    keyed: ?[]const u8 = null,

    pub const State = enum {
        set,
        missing,
        /// there, but it can't be decrypted here.
        unreadable,
        /// the observer couldn't look, not running as root.
        unknown,
    };
};

/// how the machine boots, for the rollback rung's checks.
pub const Boot = struct {
    uefi: bool = false,
    /// where the esp is mounted, if it is, and its device.
    esp: ?[]const u8 = null,
    esp_device: ?[]const u8 = null,
    /// "grub", "systemd-boot", "limine", or "refind".
    loader: ?[]const u8 = null,
    /// the config limine or refind reads, which yos adds its entries to.
    loader_conf: ?[]const u8 = null,
    /// the btrfs default subvolume is the top level, where refind's
    /// driver starts its paths.
    top_is_default: bool = true,
    root_fs: ?[]const u8 = null,
    root_device: ?[]const u8 = null,
    /// when the root's filesystem is on luks, opened by dm-crypt: the luks
    /// header's uuid, the name it's opened as under /dev/mapper, and the
    /// partition it's on.
    luks_uuid: ?[]const u8 = null,
    luks_name: ?[]const u8 = null,
    luks_device: ?[]const u8 = null,
    /// when the root's filesystem is on another device-mapper volume, like
    /// lvm's, even one on luks: its kind, like "LVM". generations can't
    /// boot from one yet.
    root_dm: ?[]const u8 = null,
    /// the root's btrfs subvolume: "/@", or "/" for the top level.
    root_subvol: ?[]const u8 = null,
    /// /var is a subvolume of its own.
    var_subvol: bool = false,
    /// the other data directories (home, root, srv, usr/local) that are
    /// mounted apart from the root.
    data_apart: []const []const u8 = &.{},
    /// mkinitcpio's HOOKS, without yos's own drop-ins.
    initramfs_hooks: []const []const u8 = &.{},
    /// yos's drop-in that adds sd-encrypt to them is there.
    encrypt_dropin: bool = false,
    /// the machine boots unified kernel images already: mkinitcpio's
    /// presets build them, the esp has some in EFI/Linux, or the root has
    /// yos's ukify config from `[boot] uki`.
    uki: bool = false,
    /// sbctl's signing key and certificate are in /var/lib/sbctl.
    sbctl_keys: bool = false,
    /// the firmware enforces secure boot, and it's in setup mode, taking
    /// new keys. null where there's no efi variable to say.
    secure_boot: ?bool = null,
    setup_mode: ?bool = null,
    /// the machine has a tpm 2.0. null under another root.
    tpm2: ?bool = null,
    /// the root is one of @roots, but yos has no record of it: an
    /// uninstall left it there. it's a plain machine's root.
    left_root: bool = false,
    /// sbctl's db certificate is in the firmware's db, so images signed
    /// with sbctl's key start. null without both to compare.
    db_enrolled: ?bool = null,
    /// efi binaries on the esp without a signature: yos's images in
    /// yos/boot, which count as unsigned unless sbctl's db key signed
    /// them, and everything under EFI, which any signature will do for.
    unsigned: []const []const u8 = &.{},
    /// the pacman database lives in /usr/lib/sysimage/pacman.
    pacman_moved: bool = false,
    /// snapper has a config for the root, which snap-pac snapshots.
    snapper_root: bool = false,
    /// on a machine with generations: the file the bootloader reads that
    /// has lost yos's entries, like a limine.conf another tool rewrote.
    menu_missing: ?[]const u8 = null,
    /// bytes free on the esp, and its size, when it's mounted.
    esp_free: ?u64 = null,
    esp_size: ?u64 = null,
    /// the kernels, initramfs images, and microcode in /boot, by name: the
    /// running root's boot files, which new ones are sized by.
    boot_files: []const BootFile = &.{},
    /// on a machine with generations: the ones recorded, by number.
    generations: []const Generation = &.{},

    /// whether the initramfs can unlock a luks root: mkinitcpio's hooks
    /// have encrypt or sd-encrypt, or yos's drop-in adds sd-encrypt.
    pub fn unlocksLuks(b: *const Boot) bool {
        return b.encrypt_dropin or hasEncryptHook(b.initramfs_hooks);
    }
};

/// whether mkinitcpio's hooks unlock luks: busybox's encrypt, or
/// systemd's sd-encrypt.
pub fn hasEncryptHook(hooks: []const []const u8) bool {
    return lists.contains(hooks, "encrypt") or lists.contains(hooks, "sd-encrypt");
}

/// where mkinitcpio's drop-ins are.
pub const initramfs_dropins = "/etc/mkinitcpio.conf.d";

/// yos's drop-in that unlocks a luks root. mkinitcpio reads drop-ins in
/// name order, so it comes after most and adds to the hooks they leave;
/// one named after it that sets HOOKS again would undo it.
pub const encrypt_dropin = "90-yos-encrypt.conf";

/// yos's drop-in, in every root with generations, that adds the hook
/// rebooting a trial from an emergency shell in the initramfs. it comes
/// after the luks one, which sets HOOKS whole.
pub const trial_dropin = "95-yos-trial.conf";

/// whether a mkinitcpio drop-in, by name, is one yos makes. facts leave
/// these out of the hooks and modules they list, since the planner
/// decides from those whether yos's are needed.
pub fn osDropIn(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "10-yos-") or std.mem.eql(u8, name, encrypt_dropin) or std.mem.eql(u8, name, trial_dropin);
}

pub const BootFile = struct { name: []const u8, size: u64 };

/// a recorded generation, as far as `yos gc` is concerned.
pub const Generation = struct {
    n: u32,
    /// its writable root, under the btrfs top level.
    root: []const u8,
    pinned: bool = false,
};

/// the file yos writes the config's repositories to, and the line in
/// pacman.conf that reads it.
pub const repos_conf = "/etc/pacman.d/yos-repos.conf";
pub const repos_include = "Include = " ++ repos_conf;

/// how pacman is set up for the config's own repositories.
pub const Pacman = struct {
    /// pacman.conf includes the file yos writes them to.
    includes_repos: bool = false,
    /// the signing keys the config names that pacman's keyring has.
    keys: []const []const u8 = &.{},
    /// the repositories pacman.conf declares itself, not through yos's file.
    repos: []const []const u8 = &.{},
};

/// what the observer should look at beyond the machine itself, because
/// the config asks about it: files to hash, and signing keys to look for.
pub const Wanted = struct {
    files: []const []const u8 = &.{},
    keys: []const []const u8 = &.{},
    /// secrets to look for, by name, and the files among `files` that
    /// hold one, which get a keyed hash.
    secrets: []const []const u8 = &.{},
    secret_files: []const []const u8 = &.{},
};

/// where sysfs says which tpm version the machine has.
pub const tpm_version_rel = "sys/class/tpm/tpm0/tpm_version_major";

/// whether a tpm's tpm_version_major file in sysfs says it's a tpm 2.0,
/// the only kind systemd-cryptenroll, sd-encrypt, and grub's tpm module
/// use.
pub fn isTpm2(version_major: ?[]const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, version_major orelse return false, " \n"), "2");
}

/// the hash files are compared by.
pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// packages a pacman transaction outside yos touched, and when.
pub const PacmanChange = struct {
    /// unix milliseconds, like the apply journal's.
    time: i64,
    packages: []const []const u8,
};

pub const Facts = struct {
    /// the document's schema tag, first in the json like every document yos
    /// writes.
    schema: []const u8 = schema,
    /// unix seconds when the facts were read.
    time: i64 = 0,
    hostname: ?[]const u8 = null,
    timezone: ?[]const u8 = null,
    locale: ?[]const u8 = null,
    keymap: ?[]const u8 = null,
    /// the cpu vendor: "amd", "intel", or what /proc/cpuinfo says.
    cpu: ?[]const u8 = null,
    /// display controller vendors: "amd", "intel", "nvidia", in pci order.
    gpus: []const []const u8 = &.{},
    packages: []Package = &.{},
    units: []Unit = &.{},
    users: []User = &.{},
    /// pacman transactions since the last apply, from the drift hook.
    pacman_changes: []PacmanChange = &.{},
    /// with a staged generation waiting for the reboot: what changed on the
    /// running system since it was built, which stays behind. files in
    /// /etc, and packages pacman touched.
    staged_changes: []const []const u8 = &.{},
    /// system accounts whose id isn't the one yos first saw them with, or
    /// ids that went to another name, as sentences.
    id_changes: []const []const u8 = &.{},
    /// the files the config manages that exist.
    files: []File = &.{},
    /// the secrets the config names.
    secrets: []Secret = &.{},
    /// modules mkinitcpio puts in the initramfs, from mkinitcpio.conf and
    /// its drop-ins, leaving out the ones yos writes.
    initramfs_modules: []const []const u8 = &.{},
    /// files under /etc with a new upstream default beside them, as
    /// `<path>.pacnew`, by the path of the file itself.
    pacnew: []const []const u8 = &.{},
    boot: Boot = .{},
    pacman: Pacman = .{},

    pub fn package(f: *const Facts, name: []const u8) ?*const Package {
        return lists.find(f.packages, "name", name);
    }

    pub fn file(f: *const Facts, path: []const u8) ?*const File {
        return lists.find(f.files, "path", path);
    }

    pub fn unit(f: *const Facts, name: []const u8) ?*const Unit {
        return lists.find(f.units, "name", name);
    }

    pub fn secret(f: *const Facts, name: []const u8) ?*const Secret {
        return lists.find(f.secrets, "name", name);
    }

    /// sorts every list by name so output and hashes don't depend on the
    /// order things were observed in.
    pub fn normalize(f: *Facts) void {
        lists.sortByField(Package, "name", f.packages);
        lists.sortByField(Unit, "name", f.units);
        lists.sortByField(User, "name", f.users);
        lists.sortByField(File, "path", f.files);
        lists.sortByField(Secret, "name", f.secrets);
    }
};

pub fn write(w: *std.Io.Writer, f: *const Facts) !void {
    try std.json.Stringify.value(f.*, .{ .whitespace = .indent_2 }, w);
    try w.writeByte('\n');
}

pub const ParseError = error{ BadFacts, OutOfMemory };

/// reads a facts document. everything is allocated in `a`, which should be
/// an arena. the result is normalized.
pub fn parse(a: Allocator, bytes: []const u8) ParseError!Facts {
    // the tag has to be there, not just defaulted, so check it on its own.
    const tag = std.json.parseFromSliceLeaky(struct { schema: []const u8 }, a, bytes, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadFacts,
    };
    if (!std.mem.eql(u8, tag.schema, schema)) return error.BadFacts;
    var f = std.json.parseFromSliceLeaky(Facts, a, bytes, .{ .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadFacts,
    };
    f.normalize();
    return f;
}

const testing = std.testing;

test "round trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var pkgs = [_]Package{
        .{ .name = "vim", .version = "9.1-1" },
        .{ .name = "glibc", .version = "2.42-1", .reason = .dependency },
    };
    var f: Facts = .{ .time = 1790294400, .hostname = "archlinux", .packages = &pkgs };
    f.normalize();
    try testing.expectEqualStrings("glibc", f.packages[0].name);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, &f);

    const back = try parse(a, out.written());
    try testing.expectEqual(1790294400, back.time);
    try testing.expectEqualStrings("archlinux", back.hostname.?);
    try testing.expectEqual(Package.Reason.dependency, back.package("glibc").?.reason);
    try testing.expectEqual(null, back.timezone);

    var again: std.Io.Writer.Allocating = .init(testing.allocator);
    defer again.deinit();
    try write(&again.writer, &back);
    try testing.expectEqualStrings(out.written(), again.written());
}

test "rejects other documents" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.BadFacts, parse(arena.allocator(), "{\"schema\":\"yos.plan/1\"}"));
    try testing.expectError(error.BadFacts, parse(arena.allocator(), "not json"));
    try testing.expectError(error.BadFacts, parse(arena.allocator(), "{\"schema\":\"yos.facts/1\",\"bogus\":1}"));
}

test "parse sorts what it reads" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f = try parse(arena.allocator(),
        \\{"schema":"yos.facts/1","units":[{"name":"sshd.service","enabled":true},{"name":"bluetooth.service"}]}
    );
    try testing.expectEqualStrings("bluetooth.service", f.units[0].name);
    try testing.expect(f.unit("sshd.service").?.enabled);
}

test "a tpm 1.2 is still a tpm in sysfs, and no use here" {
    try std.testing.expect(isTpm2("2\n"));
    try std.testing.expect(!isTpm2("1\n"));
    try std.testing.expect(!isTpm2(null));
}
