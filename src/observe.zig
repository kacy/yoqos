//! the observer: reads the machine into a facts document. it never changes
//! anything. every path is taken under `root`, so tests can point it at a
//! directory laid out like a machine.
//!
//! the parsers take file contents and are pure; `observe` does the reading.

const std = @import("std");
const exec = @import("exec.zig");
const generation = @import("generation.zig");
const gens = @import("gens.zig");
const accounts = @import("accounts.zig");
const menu = @import("menu.zig");
const facts = @import("facts.zig");
const alpm = @import("alpm.zig");
const drift = @import("drift.zig");
const rootfs = @import("rootfs.zig");
const systemd = @import("systemd.zig");
const diag = @import("diag.zig");
const lists = @import("lists.zig");
const secrets = @import("secrets.zig");
const uki = @import("uki.zig");
const secureboot = @import("secureboot.zig");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// "/" for the running machine.
    root: []const u8 = "/",
    /// read packages through libalpm. off in builds without it.
    packages: bool = alpm.available,
    /// read units from the running systemd. only for the running machine,
    /// and off in builds without libsystemd.
    units: bool = systemd.available,
    /// the files to hash and keys to look for, from the config.
    wanted: facts.Wanted = .{},
    /// where the secrets the config names are kept. without one, they're
    /// unknown.
    secrets: ?secrets.Store = null,
};

pub fn observe(a: Allocator, io: std.Io, opts: Options, diags: *diag.List) error{OutOfMemory}!facts.Facts {
    var f: facts.Facts = .{ .time = std.Io.Timestamp.now(io, .real).toSeconds() };
    const r: Reader = .{ .a = a, .io = io, .root = opts.root };

    if (try r.file("etc/hostname")) |text| f.hostname = firstLine(text);
    f.timezone = try r.timezone();
    if (try r.file("etc/locale.conf")) |text| f.locale = shellVar(text, "LANG");
    if (try r.file("etc/vconsole.conf")) |text| f.keymap = shellVar(text, "KEYMAP");
    if (try r.file("proc/cpuinfo")) |text| f.cpu = cpuVendor(text);
    f.gpus = try r.gpus();
    const passwd = try r.file("etc/passwd");
    const group = try r.file("etc/group") orelse "";
    if (passwd) |text| f.users = try users(a, text, group);
    const history = try accounts.parseHistory(a, try r.file(accounts.history_path) orelse "");
    f.id_changes = try accounts.changes(a, history, try accounts.systemIds(a, passwd orelse "", group));
    f.pacman_changes = try drift.since(a, io, opts.root);
    const key = if (opts.secrets) |s| (if (opts.wanted.secrets.len > 0) try s.key(a) else null) else null;
    f.files = try files(a, io, opts.root, opts.wanted, key);
    f.secrets = try secretFacts(a, opts.secrets, opts.wanted.secrets, key);
    f.pacman = try pacmanSetup(a, io, r, opts.wanted.keys);
    f.initramfs_modules = try r.mkinitcpio("MODULES");
    const dbpath = try pacmanDb(a, io, opts.root);
    f.boot = try r.boot(dbpath);
    // after boot: it compares the note against the running root.
    if (std.mem.eql(u8, opts.root, "/")) f.staged_changes = try stagedChanges(a, io, f.boot.root_subvol, f.pacman_changes);
    f.pacnew = try r.pacnew();
    if (opts.packages) {
        const pkgs = alpm.localPackages(a, opts.root, dbpath, diags) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AlpmUnavailable => null,
        };
        f.packages = pkgs orelse &.{};
    }
    if (opts.units and std.mem.eql(u8, opts.root, "/")) {
        const us = systemd.units(a, diags) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SystemdUnavailable => null,
        };
        f.units = us orelse &.{};
        for (f.units) |*u| {
            if (u.main_pid != 0) u.stale = try r.runsReplaced(u.main_pid);
        }
    }
    f.normalize();
    return f;
}

/// the subvolume the running root is mounted from, on btrfs.
pub fn rootSubvol(a: Allocator, io: std.Io) !?[]const u8 {
    const r: Reader = .{ .a = a, .io = io, .root = "/" };
    const root = mountAt(try mounts(a, try r.file("proc/self/mountinfo") orelse ""), "/") orelse return null;
    return if (std.mem.eql(u8, root.fstype, "btrfs")) root.root else null;
}

const Reader = struct {
    a: Allocator,
    io: std.Io,
    root: []const u8,

    fn path(r: Reader, rel: []const u8) ![]const u8 {
        return std.fs.path.join(r.a, &.{ r.root, rel });
    }

    /// a file's contents, or null if it doesn't exist or can't be read.
    /// streamed, so /proc and /sys files read whole.
    fn file(r: Reader, rel: []const u8) !?[]const u8 {
        return rootfs.readStreaming(r.a, r.io, try r.path(rel));
    }

    /// the names in a directory, sorted, or none if it can't be read.
    /// with `kind`, only entries of that kind.
    fn names(r: Reader, rel: []const u8, kind: ?std.Io.File.Kind) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var dir = std.Io.Dir.cwd().openDir(r.io, try r.path(rel), .{ .iterate = true }) catch return out.items;
        defer dir.close(r.io);
        var it = dir.iterate();
        while (it.next(r.io) catch null) |e| {
            if (kind == null or e.kind == kind.?) try out.append(r.a, try r.a.dupe(u8, e.name));
        }
        lists.sortStrings(out.items);
        return out.items;
    }

    /// `name` in the first directory under `rel` that has it, by name.
    fn inSubdir(r: Reader, rel: []const u8, name: []const u8) !?[]const u8 {
        for (try r.names(rel, .directory)) |d| {
            const found = try std.fs.path.join(r.a, &.{ rel, d, name });
            if (r.exists(found)) return found;
        }
        return null;
    }

    /// the files under /etc that have a .pacnew beside them. a directory
    /// that can't be read ends the search early rather than failing.
    fn pacnew(r: Reader) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var etc = std.Io.Dir.cwd().openDir(r.io, try r.path("etc"), .{ .iterate = true }) catch return out.items;
        defer etc.close(r.io);
        var walker = try etc.walk(r.a);
        defer walker.deinit();
        while (walker.next(r.io) catch null) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.basename, ".pacnew")) continue;
            try out.append(r.a, try std.fmt.allocPrint(r.a, "/etc/{s}", .{e.path[0 .. e.path.len - ".pacnew".len]}));
        }
        lists.sortStrings(out.items);
        return out.items;
    }

    /// a mkinitcpio array from mkinitcpio.conf and every drop-in os
    /// didn't write, in the order mkinitcpio reads them.
    fn mkinitcpio(r: Reader, comptime key: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        if (try r.file("etc/mkinitcpio.conf")) |text| try mkinitcpioList(r.a, text, key, &out);
        for (try r.names("etc/mkinitcpio.conf.d", null)) |name| {
            if (facts.osDropIn(name) or !std.mem.endsWith(u8, name, ".conf")) continue;
            const text = try r.file(try std.fmt.allocPrint(r.a, "etc/mkinitcpio.conf.d/{s}", .{name})) orelse continue;
            try mkinitcpioList(r.a, text, key, &out);
        }
        return out.items;
    }

    /// how the machine boots. mounts and firmware only describe the
    /// running machine, so under another root those stay unknown.
    fn boot(r: Reader, dbpath: []const u8) !facts.Boot {
        var b: facts.Boot = .{
            .initramfs_hooks = try r.mkinitcpio("HOOKS"),
            .pacman_moved = std.mem.endsWith(u8, dbpath, "sysimage/pacman"),
            .snapper_root = r.exists("etc/snapper/configs/root"),
            .encrypt_dropin = r.exists(facts.initramfs_dropins[1..] ++ "/" ++ facts.encrypt_dropin),
            .uki = r.exists(uki.config_rel) or try r.presetsBuildUki(),
            .sbctl_keys = r.exists(secureboot.db_key_rel) and r.exists(secureboot.db_cert_rel),
        };
        if (!std.mem.eql(u8, r.root, "/")) return b;
        b.uefi = r.exists("sys/firmware/efi");
        if (try r.file(secureboot.secure_boot_var)) |v| b.secure_boot = secureboot.efiFlag(v);
        if (try r.file(secureboot.setup_mode_var)) |v| b.setup_mode = secureboot.efiFlag(v);
        // an automounted esp only shows up in mountinfo once it's used.
        for ([_][]const u8{ "efi/EFI", "boot/efi/EFI", "boot/EFI" }) |p| _ = r.exists(p);
        const ms = try mounts(r.a, try r.file("proc/self/mountinfo") orelse "");
        const root = mountAt(ms, "/") orelse return b;
        b.root_fs = root.fstype;
        b.root_device = root.source;
        try r.luks(&b, root.source);
        if (std.mem.eql(u8, root.fstype, "btrfs")) {
            b.root_subvol = root.root;
            if (mountAt(ms, "/var")) |v| b.var_subvol = std.mem.eql(u8, v.fstype, "btrfs") and !std.mem.eql(u8, v.root, root.root);
            var apart: std.ArrayList([]const u8) = .empty;
            for (generation.data_dirs) |d| {
                const m = mountAt(ms, try std.fmt.allocPrint(r.a, "/{s}", .{d.dir})) orelse continue;
                if (!std.mem.eql(u8, m.source, root.source) or !std.mem.eql(u8, m.root, root.root)) try apart.append(r.a, d.dir);
            }
            b.data_apart = apart.items;
        }
        for ([_][]const u8{ "/efi", "/boot/efi", "/boot" }) |p| {
            const m = mountAt(ms, p) orelse continue;
            if (std.mem.eql(u8, m.fstype, "vfat")) {
                b.esp = p;
                b.esp_device = m.source;
                break;
            }
        }
        b.loader = try r.loader(b.esp);
        if (b.esp) |esp| {
            b.loader_conf = try r.loaderConf(b.loader orelse "", esp);
            if (rootfs.space(esp)) |s| {
                b.esp_free = s.free;
                b.esp_size = s.size;
            }
            b.boot_files = try r.bootFiles();
            if (!b.uki) b.uki = uki.anyImage(try r.names(try std.fs.path.join(r.a, &.{ esp[1..], "EFI/Linux" }), .file));
            b.unsigned = try r.unsigned(esp);
        }
        if (generation.running(b.root_subvol)) {
            b.menu_missing = try r.menuMissing(b);
            var recorded: std.ArrayList(facts.Generation) = .empty;
            for (try gens.readRecords(r.a, r.io, "/var")) |g| try recorded.append(r.a, .{ .n = g.n, .root = g.root, .pinned = g.pinned });
            b.generations = recorded.items;
        }
        if (b.root_subvol != null) {
            b.top_is_default = switch (try exec.output(r.a, r.io, &.{ "btrfs", "subvolume", "get-default", "/" })) {
                // "ID 5 (FS_TREE)" for the top level.
                .ok => |t| std.mem.startsWith(u8, t, "ID 5 "),
                // not knowing isn't the same as knowing it's fine.
                .failed => false,
            };
        }
        return b;
    }

    /// the efi binaries on the esp at `esp` without a signature: os's
    /// images, and everything under EFI, by path.
    fn unsigned(r: Reader, esp: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        // os's images need sbctl's db key; the bootloader's files may be
        // signed with another the firmware has, like microsoft's.
        const key = try gens.dbKey(r.a, r.io, try r.path(secureboot.db_cert_rel));
        for (try r.names(try std.fs.path.join(r.a, &.{ esp[1..], gens.esp_boot_dir }), .file)) |name| {
            try r.addUnsigned(&out, &.{ esp, gens.esp_boot_dir, name }, key);
        }
        var dir = std.Io.Dir.cwd().openDir(r.io, try r.path(try std.fs.path.join(r.a, &.{ esp[1..], "EFI" })), .{ .iterate = true }) catch return out.items;
        defer dir.close(r.io);
        var walker = try dir.walk(r.a);
        defer walker.deinit();
        while (walker.next(r.io) catch null) |e| {
            if (e.kind == .file) try r.addUnsigned(&out, &.{ esp, "EFI", e.path }, null);
        }
        lists.sortStrings(out.items);
        return out.items;
    }

    /// adds the file at the path `parts` make to `out` when it's an efi
    /// binary without a signature, from `key` when there is one.
    fn addUnsigned(r: Reader, out: *std.ArrayList([]const u8), parts: []const []const u8, key: ?[]const u8) !void {
        const p = try std.fs.path.join(r.a, parts);
        if (!uki.isEfi(std.fs.path.basename(p)) or gens.fileSigned(r.io, try r.path(p[1..]), key)) return;
        try out.append(r.a, p);
    }

    /// whether one of mkinitcpio's presets builds unified kernel images.
    fn presetsBuildUki(r: Reader) !bool {
        for (try r.names("etc/mkinitcpio.d", .file)) |name| {
            if (!std.mem.endsWith(u8, name, ".preset")) continue;
            const text = try r.file(try std.fmt.allocPrint(r.a, "etc/mkinitcpio.d/{s}", .{name})) orelse continue;
            if (uki.presetBuildsUki(text)) return true;
        }
        return false;
    }

    /// the luks volume under the root, when `source` is a dm-crypt
    /// device opened from one: /dev/mapper/<name>, or /dev/dm-<n>. a root
    /// on another device-mapper volume, like lvm's, gets its kind.
    fn luks(r: Reader, b: *facts.Boot, source: []const u8) !void {
        if (!std.mem.startsWith(u8, source, "/dev/")) return;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.cwd().readLink(r.io, try r.path(source[1..]), &buf) catch 0;
        const dm = std.fs.path.basename(if (n > 0) buf[0..n] else source);
        if (!std.mem.startsWith(u8, dm, "dm-")) return;
        const sys = try std.fmt.allocPrint(r.a, "sys/block/{s}", .{dm});
        const dm_uuid = try r.file(try std.fmt.allocPrint(r.a, "{s}/dm/uuid", .{sys})) orelse "";
        const crypt = cryptOf(dm_uuid) orelse {
            b.root_dm = dmKind(dm_uuid);
            return;
        };
        b.luks_uuid = try dashedUuid(r.a, crypt.uuid);
        b.luks_name = crypt.name;
        const under = try r.names(try std.fmt.allocPrint(r.a, "{s}/slaves", .{sys}), null);
        // luks on one partition; a volume on several devices isn't one.
        if (under.len == 1) b.luks_device = try std.fmt.allocPrint(r.a, "/dev/{s}", .{under[0]});
    }

    /// the kernels, initramfs images, and microcode in /boot, with their
    /// sizes, by name.
    fn bootFiles(r: Reader) ![]const facts.BootFile {
        var out: std.ArrayList(facts.BootFile) = .empty;
        var dir = std.Io.Dir.cwd().openDir(r.io, try r.path("boot"), .{}) catch return out.items;
        defer dir.close(r.io);
        for (try r.names("boot", .file)) |name| {
            if (!generation.bootFile(name)) continue;
            const st = dir.statFile(r.io, name, .{}) catch continue;
            try out.append(r.a, .{ .name = name, .size = st.size });
        }
        return out.items;
    }

    /// the file that should hold os's boot entries, if it doesn't.
    fn menuMissing(r: Reader, b: facts.Boot) !?[]const u8 {
        const kind = menu.Loader.of(b) orelse return null;
        const esp = b.esp orelse return null;
        const menu_file = switch (kind) {
            .grub => try std.fs.path.join(r.a, &.{ esp, "grub/grub.cfg" }),
            .limine, .refind => b.loader_conf orelse return null,
            .@"systemd-boot" => try std.fs.path.join(r.a, &.{ esp, "loader/entries", try menu.sdbootName(r.a, "head") }),
        };
        const text = try r.file(menu_file[1..]) orelse return menu_file;
        const ok = switch (kind) {
            .grub, .@"systemd-boot" => std.mem.startsWith(u8, text, "# written by os"),
            .limine => std.mem.indexOf(u8, text, menu.limine_begin) != null,
            .refind => std.mem.indexOf(u8, text, menu.refind_include) != null,
        };
        return if (ok) null else menu_file;
    }

    /// where limine or refind reads its config, as each one looks for it:
    /// first beside its binary, under EFI/, then limine's other places.
    fn loaderConf(r: Reader, name_of: []const u8, esp: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, name_of, "systemd-boot")) {
            const rel = try std.fs.path.join(r.a, &.{ esp[1..], "loader/loader.conf" });
            return if (r.exists(rel)) try std.fmt.allocPrint(r.a, "/{s}", .{rel}) else null;
        }
        const name = if (std.mem.eql(u8, name_of, "limine")) "limine.conf" else if (std.mem.eql(u8, name_of, "refind")) "refind.conf" else return null;
        const efi = try std.fs.path.join(r.a, &.{ esp[1..], "EFI" });
        if (try r.inSubdir(efi, name)) |rel| return try std.fmt.allocPrint(r.a, "/{s}", .{rel});
        if (std.mem.eql(u8, name_of, "refind")) return null;
        for ([_][]const u8{ "boot/limine/limine.conf", "boot/limine.conf", "limine/limine.conf", "limine.conf" }) |p| {
            const rel = try std.fs.path.join(r.a, &.{ esp[1..], p });
            if (r.exists(rel)) return try std.fmt.allocPrint(r.a, "/{s}", .{rel});
        }
        return null;
    }

    /// the bootloader, by the files each one keeps.
    fn loader(r: Reader, esp: ?[]const u8) !?[]const u8 {
        if (esp) |e| {
            const in_esp = [_]struct { []const u8, []const u8 }{
                .{ "loader/loader.conf", "systemd-boot" },
                .{ "limine.conf", "limine" },
                .{ "EFI/limine", "limine" },
                .{ "EFI/refind", "refind" },
            };
            for (in_esp) |c| {
                if (r.exists(try std.fs.path.join(r.a, &.{ e[1..], c[0] }))) return c[1];
            }
            // archinstall keeps it in EFI/arch-limine.
            if (try r.inSubdir(try std.fs.path.join(r.a, &.{ e[1..], "EFI" }), "limine.conf") != null) return "limine";
        }
        if (r.exists("boot/limine.conf")) return "limine";
        if (r.exists("boot/grub/grub.cfg")) return "grub";
        return null;
    }

    fn exists(r: Reader, rel: []const u8) bool {
        return rootfs.pathExists(r.io, r.path(rel) catch return false);
    }

    /// whether a process maps package files that have been replaced
    /// since it started.
    fn runsReplaced(r: Reader, pid: u32) !bool {
        const maps = try r.file(try std.fmt.allocPrint(r.a, "proc/{d}/maps", .{pid})) orelse return false;
        return mapsReplaced(maps);
    }

    /// /etc/localtime is a symlink into the zoneinfo tree; the zone is the
    /// part of the target after "zoneinfo/".
    fn timezone(r: Reader) !?[]const u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.cwd().readLink(r.io, try r.path("etc/localtime"), &buf) catch return null;
        return zoneFromLink(r.a, buf[0..n]);
    }

    /// display controllers on the pci bus: devices whose class starts with
    /// 0x03, by vendor.
    fn gpus(r: Reader) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (try r.names("sys/bus/pci/devices", null)) |n| {
            const class = try r.file(try std.fmt.allocPrint(r.a, "sys/bus/pci/devices/{s}/class", .{n})) orelse continue;
            if (!std.mem.startsWith(u8, std.mem.trim(u8, class, " \n"), "0x03")) continue;
            const vendor = try r.file(try std.fmt.allocPrint(r.a, "sys/bus/pci/devices/{s}/vendor", .{n})) orelse continue;
            if (gpuVendor(std.mem.trim(u8, vendor, " \n"))) |v| try out.append(r.a, v);
        }
        return out.items;
    }
};

/// a mkinitcpio array, like MODULES or HOOKS: `KEY=(...)` sets it and
/// `KEY+=(...)` adds to it, in the order the lines come.
fn mkinitcpioList(a: Allocator, text: []const u8, comptime key: []const u8, out: *std.ArrayList([]const u8)) !void {
    const set = key ++ "=(";
    const add = key ++ "+=(";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const start = if (std.mem.startsWith(u8, line, set)) set.len else if (std.mem.startsWith(u8, line, add)) add.len else continue;
        if (start == set.len) out.clearRetainingCapacity();
        const end = std.mem.indexOfScalarPos(u8, line, start, ')') orelse continue;
        var names = std.mem.tokenizeAny(u8, line[start..end], " \t\"'");
        while (names.next()) |n| try out.append(a, try a.dupe(u8, n));
    }
}

/// a dm-crypt device opened from a luks volume, from its dm uuid in
/// sysfs, like "CRYPT-LUKS2-0f7a...e1-root": the luks header's uuid,
/// without dashes, and the name it's opened as.
pub const Crypt = struct { uuid: []const u8, name: []const u8 };

pub fn cryptOf(dm_uuid: []const u8) ?Crypt {
    const text = std.mem.trim(u8, dm_uuid, " \n");
    const rest = for ([_][]const u8{ "CRYPT-LUKS2-", "CRYPT-LUKS1-" }) |p| {
        if (std.mem.startsWith(u8, text, p)) break text[p.len..];
    } else return null;
    if (rest.len < 34 or rest[32] != '-') return null;
    for (rest[0..32]) |ch| {
        if (!std.ascii.isHex(ch)) return null;
    }
    return .{ .uuid = rest[0..32], .name = rest[33..] };
}

/// what kind of device-mapper volume a dm uuid is: its subsystem, like
/// "LVM", or "CRYPT-PLAIN" for dm-crypt, or "device-mapper" when it has
/// no uuid to say.
pub fn dmKind(dm_uuid: []const u8) []const u8 {
    const text = std.mem.trim(u8, dm_uuid, " \n");
    if (text.len == 0) return "device-mapper";
    const skip = if (std.mem.startsWith(u8, text, "CRYPT-")) "CRYPT-".len else 0;
    const end = std.mem.indexOfScalarPos(u8, text, skip, '-') orelse text.len;
    return text[0..end];
}

/// a uuid of 32 hex digits in its usual form, 8-4-4-4-12.
pub fn dashedUuid(a: Allocator, hex: []const u8) ![]const u8 {
    std.debug.assert(hex.len == 32);
    return std.fmt.allocPrint(a, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
}

/// one line of /proc/self/mountinfo.
pub const Mount = struct {
    /// the path inside the filesystem that's mounted: for btrfs, the
    /// subvolume.
    root: []const u8,
    point: []const u8,
    fstype: []const u8,
    source: []const u8,
};

pub fn mounts(a: Allocator, text: []const u8) ![]const Mount {
    var out: std.ArrayList(Mount) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // id parent major:minor root point options [optional...] - fstype source super
        const dash = std.mem.indexOf(u8, line, " - ") orelse continue;
        var head = std.mem.tokenizeScalar(u8, line[0..dash], ' ');
        var tail = std.mem.tokenizeScalar(u8, line[dash + 3 ..], ' ');
        _ = head.next();
        _ = head.next();
        _ = head.next();
        const root = head.next() orelse continue;
        const point = head.next() orelse continue;
        const fstype = tail.next() orelse continue;
        const source = tail.next() orelse continue;
        try out.append(a, .{ .root = try unescape(a, root), .point = try unescape(a, point), .fstype = fstype, .source = source });
    }
    return out.items;
}

/// mountinfo writes spaces and a few other bytes as \ooo.
fn unescape(a: Allocator, field: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, field, '\\') == null) return field;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < field.len) : (i += 1) {
        if (field[i] == '\\' and i + 3 < field.len) {
            if (std.fmt.parseInt(u8, field[i + 1 .. i + 4], 8)) |b| {
                try out.append(a, b);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(a, field[i]);
    }
    return out.items;
}

/// the last mount at `point`: the one in effect.
pub fn mountAt(ms: []const Mount, point: []const u8) ?Mount {
    var found: ?Mount = null;
    for (ms) |m| {
        if (std.mem.eql(u8, m.point, point)) found = m;
    }
    return found;
}

/// whether /proc/<pid>/maps lists a deleted file from a package's
/// directories. memfds and deleted files in /tmp don't count.
fn mapsReplaced(maps: []const u8) bool {
    var lines = std.mem.splitScalar(u8, maps, '\n');
    while (lines.next()) |line| {
        if (!std.mem.endsWith(u8, line, " (deleted)")) continue;
        const slash = std.mem.indexOfScalar(u8, line, '/') orelse continue;
        const file = line[slash..];
        if (std.mem.startsWith(u8, file, "/usr/") or std.mem.startsWith(u8, file, "/opt/")) return true;
    }
    return false;
}

/// the managed files that exist, with their hash and mode. a file that
/// holds a secret gets the keyed hash instead, with `key`.
fn files(a: Allocator, io: std.Io, root: []const u8, wanted: facts.Wanted, key: ?secrets.Key) ![]facts.File {
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    var out: std.ArrayList(facts.File) = .empty;
    for (wanted.files) |p| {
        const rel = std.mem.trimStart(u8, p, "/");
        const m = try fs.mode(rel) orelse continue;
        const mode = try std.fmt.allocPrint(a, "{o:0>4}", .{m});
        if (lists.contains(wanted.secret_files, p)) {
            try out.append(a, .{ .path = p, .sha256 = try keyedFile(a, io, try fs.path(rel), key), .mode = mode, .keyed = true });
            continue;
        }
        const content = try fs.read(rel);
        const hex = facts.sha256Hex(content);
        try out.append(a, .{
            .path = p,
            .sha256 = try a.dupe(u8, &hex),
            .mode = mode,
            .ours = std.mem.startsWith(u8, content, "# written by os"),
        });
    }
    return out.items;
}

/// the keyed hash of the file at `path`, or "" without the key or when it
/// can't be read. what it read is wiped: it's a secret.
fn keyedFile(a: Allocator, io: std.Io, path: []const u8, key: ?secrets.Key) ![]const u8 {
    const k = key orelse return "";
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 20)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return "",
    };
    defer secrets.wipe(content);
    return a.dupe(u8, &secrets.keyedHex(&k, content));
}

/// each secret the config names: whether this machine has it, and its
/// value's keyed hash. the value itself is wiped as soon as it's hashed.
fn secretFacts(a: Allocator, store: ?secrets.Store, names: []const []const u8, key: ?secrets.Key) ![]facts.Secret {
    var out: std.ArrayList(facts.Secret) = .empty;
    for (names) |name| {
        var s: facts.Secret = .{ .name = name };
        if (store) |st| switch (try st.get(a, name)) {
            .value => |v| {
                defer secrets.wipe(v);
                s.state = .set;
                if (key) |k| s.keyed = try a.dupe(u8, &secrets.keyedHex(&k, v));
            },
            .missing => s.state = .missing,
            .unreadable => s.state = .unreadable,
            .unknown => {},
        };
        try out.append(a, s);
    }
    return out.items;
}

/// whether pacman.conf reads os's repositories, and which of `keys` the
/// keyring has.
fn pacmanSetup(a: Allocator, io: std.Io, r: Reader, keys: []const []const u8) !facts.Pacman {
    var out: facts.Pacman = .{};
    var repos: std.ArrayList([]const u8) = .empty;
    if (try r.file("etc/pacman.conf")) |conf| {
        var lines = std.mem.splitScalar(u8, conf, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            out.includes_repos = out.includes_repos or std.mem.eql(u8, line, facts.repos_include);
            if (line.len > 2 and line[0] == '[' and line[line.len - 1] == ']' and !std.mem.eql(u8, line, "[options]")) try repos.append(a, line[1 .. line.len - 1]);
        }
    }
    out.repos = repos.items;
    var have: std.ArrayList([]const u8) = .empty;
    const gpgdir = try r.path("etc/pacman.d/gnupg");
    for (keys) |k| {
        if (try exec.run(a, io, &.{ "pacman-key", "--gpgdir", gpgdir, "--list-keys", k }) == null) try have.append(a, k);
    }
    out.keys = have.items;
    return out;
}

/// pacman's database directory under `root`: in /usr on the rollback rung,
/// in /var otherwise.
pub fn pacmanDb(a: Allocator, io: std.Io, root: []const u8) ![]const u8 {
    const moved = try std.fs.path.join(a, &.{ root, generation.pacman_db });
    if (rootfs.pathExists(io, try std.fs.path.join(a, &.{ moved, "local" }))) return moved;
    return std.fs.path.join(a, &.{ root, "var/lib/pacman" });
}

/// the installed package whose file list has `path`, like `pacman -Qo`
/// but without following symlinks. null if none does.
pub fn fileOwner(a: Allocator, io: std.Io, root: []const u8, path: []const u8) !?[]const u8 {
    const local = try std.fs.path.join(a, &.{ try pacmanDb(a, io, root), "local" });
    var dir = std.Io.Dir.cwd().openDir(io, local, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        const list = try rootfs.readStreaming(a, io, try std.fs.path.join(a, &.{ local, e.name, "files" })) orelse continue;
        if (listsFile(list, path)) return try a.dupe(u8, packageOfDir(e.name));
    }
    return null;
}

/// whether a local database `files` entry lists `path`. it writes paths
/// without the leading slash.
fn listsFile(text: []const u8, path: []const u8) bool {
    const rel = std.mem.trimStart(u8, path, "/");
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_files = false;
    while (lines.next()) |line| {
        if (line.len > 0 and line[0] == '%') {
            in_files = std.mem.eql(u8, line, "%FILES%");
        } else if (in_files and std.mem.eql(u8, line, rel)) return true;
    }
    return false;
}

/// "openssh-10.0p1-2" is openssh: neither pkgver nor pkgrel has a dash.
fn packageOfDir(name: []const u8) []const u8 {
    const rel = std.mem.lastIndexOfScalar(u8, name, '-') orelse return name;
    const ver = std.mem.lastIndexOfScalar(u8, name[0..rel], '-') orelse return name;
    return name[0..ver];
}

/// "amd" or "intel" from /proc/cpuinfo's vendor_id, or the raw vendor.
fn cpuVendor(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "vendor_id")) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const v = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.mem.eql(u8, v, "AuthenticAMD")) return "amd";
        if (std.mem.eql(u8, v, "GenuineIntel")) return "intel";
        return v;
    }
    return null;
}

/// a pci vendor id as a gpu vendor name.
fn gpuVendor(id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, id, "0x1002")) return "amd";
    if (std.mem.eql(u8, id, "0x8086")) return "intel";
    if (std.mem.eql(u8, id, "0x10de")) return "nvidia";
    return null;
}

fn zoneFromLink(a: Allocator, target: []const u8) !?[]const u8 {
    const marker = "zoneinfo/";
    const i = std.mem.indexOf(u8, target, marker) orelse return null;
    return try a.dupe(u8, target[i + marker.len ..]);
}

fn firstLine(text: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    const line = std.mem.trim(u8, it.first(), " \t\r");
    return if (line.len == 0) null else line;
}

/// the value of `KEY=value` in a shell-style config file like
/// /etc/locale.conf, without quotes.
fn shellVar(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) continue;
        const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0]) return v[1 .. v.len - 1];
        return v;
    }
    return null;
}

/// what changed on the running system since a staged generation waiting
/// for the reboot was built: files in /etc, less the machine state carried
/// into it anyway, and packages pacman touched. the note staging leaves
/// says when it was built.
fn stagedChanges(a: Allocator, io: std.Io, running: ?[]const u8, pacman: []const facts.PacmanChange) ![]const []const u8 {
    const cwd = std.Io.Dir.cwd();
    const note = cwd.readFileAlloc(io, generation.unsettled_path, a, .limited(256)) catch return &.{};
    if (std.mem.eql(u8, std.mem.trim(u8, note, " \n"), running orelse "")) return &.{};
    const built = (cwd.statFile(io, generation.unsettled_path, .{}) catch return &.{}).mtime.nanoseconds;
    var out: std.ArrayList([]const u8) = .empty;
    var etc = cwd.openDir(io, "/etc", .{ .iterate = true }) catch return out.items;
    defer etc.close(io);
    var walker = try etc.walk(a);
    defer walker.deinit();
    while (walker.next(io) catch null) |e| {
        if (e.kind != .file or carriedEtc(e.path)) continue;
        const st = etc.statFile(io, e.path, .{}) catch continue;
        if (st.mtime.nanoseconds > built) try out.append(a, try std.fmt.allocPrint(a, "/etc/{s}", .{e.path}));
        if (out.items.len >= 20) break;
    }
    const built_ms: i64 = @intCast(@divFloor(built, std.time.ns_per_ms));
    var names: std.ArrayList([]const u8) = .empty;
    for (pacman) |c| {
        if (c.time <= built_ms) continue;
        for (c.packages) |p| {
            if (!lists.contains(names.items, p)) try names.append(a, p);
        }
    }
    if (names.items.len > 0) try out.append(a, try std.fmt.allocPrint(a, "packages with pacman: {s}", .{try std.mem.join(a, ", ", names.items)}));
    return out.items;
}

/// files in /etc a new root gets from the running one as it boots, or that
/// aren't the machine's to begin with: passwords and accounts, its
/// identity, host keys, the keyring, and os's own config.
pub fn carriedEtc(path: []const u8) bool {
    for ([_][]const u8{ "shadow", "gshadow", "passwd", "group", "machine-id", "adjtime", "subuid", "subgid", "ld.so.cache" }) |f| {
        if (std.mem.eql(u8, path, f) or (std.mem.startsWith(u8, path, f) and path.len == f.len + 1 and path[f.len] == '-')) return true;
    }
    return lists.startsWithAny(path, &.{ "ssh/ssh_host_", "pacman.d/gnupg/", "yoq/" });
}

/// users from /etc/passwd with their groups from /etc/group.
pub fn users(a: Allocator, passwd: []const u8, group: []const u8) ![]facts.User {
    var out: std.ArrayList(facts.User) = .empty;
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const name = f.next() orelse continue;
        _ = f.next();
        const uid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        const gid = f.next() orelse continue;
        _ = f.next();
        _ = f.next();
        const shell = f.next() orelse continue;
        var u: facts.User = .{ .name = name, .uid = uid, .shell = shell };
        try groupsOf(a, &u, gid, group);
        try out.append(a, u);
    }
    return out.items;
}

/// fills in the user's primary group, by gid, and the groups that list the
/// user as a member.
fn groupsOf(a: Allocator, u: *facts.User, gid: []const u8, group: []const u8) !void {
    const user = u.name;
    var rest: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, group, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const name = f.next() orelse continue;
        _ = f.next();
        const id = f.next() orelse continue;
        const members = f.next() orelse "";
        if (std.mem.eql(u8, id, gid)) {
            u.primary_group = name;
            continue;
        }
        var m = std.mem.splitScalar(u8, std.mem.trim(u8, members, " \r"), ',');
        while (m.next()) |member| {
            if (std.mem.eql(u8, member, user)) try rest.append(a, name);
        }
    }
    lists.sortStrings(rest.items);
    u.groups = rest.items;
}

// -- tests --

const testing = std.testing;

test "shell-style values" {
    try testing.expectEqualStrings("en_US.UTF-8", shellVar("# comment\nLANG=en_US.UTF-8\n", "LANG").?);
    try testing.expectEqualStrings("de-latin1", shellVar("KEYMAP=\"de-latin1\"\nFONT=ter-v16n\n", "KEYMAP").?);
    try testing.expectEqual(null, shellVar("LC_TIME=C\n", "LANG"));
}

test "timezone from the localtime link" {
    const ny = (try zoneFromLink(testing.allocator, "/usr/share/zoneinfo/America/New_York")).?;
    defer testing.allocator.free(ny);
    try testing.expectEqualStrings("America/New_York", ny);
    const utc = (try zoneFromLink(testing.allocator, "../usr/share/zoneinfo/UTC")).?;
    defer testing.allocator.free(utc);
    try testing.expectEqualStrings("UTC", utc);
    try testing.expectEqual(null, try zoneFromLink(testing.allocator, "/etc/somewhere"));
}

test "mounts from mountinfo" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ms = try mounts(arena.allocator(),
        \\29 1 0:30 /@ / rw,relatime shared:1 - btrfs /dev/vda3 rw,compress=zstd:1,subvol=/@
        \\31 29 0:30 /@var /var rw,relatime shared:3 - btrfs /dev/vda3 rw,subvol=/@var
        \\33 29 0:31 / /efi rw,relatime shared:5 - vfat /dev/vda2 rw
        \\34 29 0:32 / /mnt/with\040space rw - ext4 /dev/vdb1 rw
        \\
    );
    try testing.expectEqual(4, ms.len);
    try testing.expectEqualStrings("/@", mountAt(ms, "/").?.root);
    try testing.expectEqualStrings("btrfs", mountAt(ms, "/var").?.fstype);
    try testing.expectEqualStrings("/dev/vda2", mountAt(ms, "/efi").?.source);
    try testing.expectEqualStrings("/mnt/with space", ms[3].point);
}

test "mkinitcpio's modules" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    try mkinitcpioList(arena.allocator(),
        \\# MODULES=(ignored)
        \\MODULES=(nvidia "nvidia_modeset")
        \\MODULES+=(nvidia_uvm nvidia_drm)
        \\HOOKS=(base udev)
        \\
    , "MODULES", &out);
    try testing.expectEqual(4, out.items.len);
    try testing.expectEqualStrings("nvidia_modeset", out.items[1]);
}

test "mkinitcpio drop-ins read in name order, past os's own" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "etc/mkinitcpio.conf.d");
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/mkinitcpio.conf", .data = "MODULES=(a)\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/mkinitcpio.conf.d/30-c.conf", .data = "MODULES+=(c)\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/mkinitcpio.conf.d/20-b.conf", .data = "MODULES+=(b)\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/mkinitcpio.conf.d/10-yoq-nvidia.conf", .data = "MODULES+=(nvidia)\n" });
    const r: Reader = .{ .a = arena.allocator(), .io = io, .root = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path}) };
    const got = try r.mkinitcpio("MODULES");
    try testing.expectEqual(3, got.len);
    for ([_][]const u8{ "a", "b", "c" }, got) |want, have| try testing.expectEqualStrings(want, have);
    // the drop-in for luks is os's too, though it isn't named 10-yoq-.
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/mkinitcpio.conf", .data = "HOOKS=(base systemd filesystems)\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/mkinitcpio.conf.d/90-yoq-encrypt.conf", .data = "HOOKS=(base systemd sd-encrypt filesystems)\n" });
    try testing.expectEqual(3, (try r.mkinitcpio("HOOKS")).len);
    const b = try r.boot("usr/lib/sysimage/pacman");
    try testing.expect(b.encrypt_dropin);
    try testing.expect(b.unlocksLuks());
    try testing.expect(!facts.osDropIn("50-yoq-test.conf"));
}

test "the luks volume under the root" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = cryptOf("CRYPT-LUKS2-0f7a1c2e9b3d4e5f8a6b7c8d9e0f1a2b-root\n").?;
    try testing.expectEqualStrings("root", c.name);
    try testing.expectEqualStrings("0f7a1c2e-9b3d-4e5f-8a6b-7c8d9e0f1a2b", try dashedUuid(a, c.uuid));
    // a name can have dashes of its own.
    try testing.expectEqualStrings("luks-0f7a", cryptOf("CRYPT-LUKS1-0f7a1c2e9b3d4e5f8a6b7c8d9e0f1a2b-luks-0f7a").?.name);
    try testing.expectEqual(null, cryptOf("LVM-abcdef"));
    try testing.expectEqual(null, cryptOf("CRYPT-PLAIN-root"));
    try testing.expectEqual(null, cryptOf("CRYPT-LUKS2-0f7a1c2e-root"));
    try testing.expectEqual(null, cryptOf("CRYPT-LUKS2-zf7a1c2e9b3d4e5f8a6b7c8d9e0f1a2b-root"));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "dev/mapper");
    try tmp.dir.symLink(io, "../dm-0", "dev/mapper/root", .{});
    try tmp.dir.createDirPath(io, "sys/block/dm-0/dm");
    try tmp.dir.createDirPath(io, "sys/block/dm-0/slaves/nvme0n1p2");
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/block/dm-0/dm/uuid", .data = "CRYPT-LUKS2-0f7a1c2e9b3d4e5f8a6b7c8d9e0f1a2b-root\n" });
    const r: Reader = .{ .a = a, .io = io, .root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}) };
    var b: facts.Boot = .{};
    try r.luks(&b, "/dev/mapper/root");
    try testing.expectEqualStrings("0f7a1c2e-9b3d-4e5f-8a6b-7c8d9e0f1a2b", b.luks_uuid.?);
    try testing.expectEqualStrings("root", b.luks_name.?);
    try testing.expectEqualStrings("/dev/nvme0n1p2", b.luks_device.?);
    // a plain partition has no luks under it.
    var plain: facts.Boot = .{};
    try r.luks(&plain, "/dev/vda2");
    try testing.expectEqual(null, plain.luks_uuid);
    try testing.expectEqual(null, plain.root_dm);
    // lvm, even on luks, is a volume of its own, not a luks one.
    try tmp.dir.symLink(io, "../dm-1", "dev/mapper/vg-root", .{});
    try tmp.dir.createDirPath(io, "sys/block/dm-1/dm");
    try tmp.dir.createDirPath(io, "sys/block/dm-1/slaves/dm-0");
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/block/dm-1/dm/uuid", .data = "LVM-Jd3k2l1m0n9o8p7q6r5s4t3u2v1w0x9yZa8b7c6d5e4f3g2h1i0j9k8l7m6n5\n" });
    var lvm: facts.Boot = .{};
    try r.luks(&lvm, "/dev/mapper/vg-root");
    try testing.expectEqual(null, lvm.luks_uuid);
    try testing.expectEqualStrings("LVM", lvm.root_dm.?);
    try testing.expectEqualStrings("CRYPT-PLAIN", dmKind("CRYPT-PLAIN-root"));
    try testing.expectEqualStrings("device-mapper", dmKind("\n"));
}

test "files in /etc a new root gets anyway" {
    try testing.expect(carriedEtc("shadow"));
    try testing.expect(carriedEtc("shadow-"));
    try testing.expect(carriedEtc("ssh/ssh_host_ed25519_key"));
    try testing.expect(carriedEtc("yoq/machine.toml"));
    try testing.expect(!carriedEtc("hosts"));
    try testing.expect(!carriedEtc("shadowsocks.json"));
}

test "a process running replaced package files" {
    try testing.expect(mapsReplaced(
        \\55d0a000-55d0b000 r--p 00000000 fe:01 1234   /usr/bin/sshd
        \\7f00a000-7f00b000 r-xp 00000000 fe:01 5678   /usr/lib/libcrypto.so.3 (deleted)
        \\
    ));
    try testing.expect(!mapsReplaced(
        \\7f00a000-7f00b000 rw-s 00000000 00:01 42     /memfd:pulseaudio (deleted)
        \\7f00c000-7f00d000 rw-p 00000000 fe:01 43     /tmp/scratch (deleted)
        \\7f00e000-7f00f000 r-xp 00000000 fe:01 44     /usr/lib/libc.so.6
        \\
    ));
}

test "users and their groups" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const us = try users(arena.allocator(),
        \\root:x:0:0::/root:/usr/bin/bash
        \\bin:x:1:1::/:/usr/bin/nologin
        \\kacy:x:1000:1000::/home/kacy:/usr/bin/zsh
        \\guest:x:1001:1001::/home/guest:/usr/bin/bash
        \\nobody:x:65534:65534:Kernel Overflow User:/:/usr/bin/nologin
        \\
    ,
        \\root:x:0:root
        \\wheel:x:998:kacy
        \\video:x:986:kacy,guest
        \\kacy:x:1000:
        \\guest:x:1001:
        \\
    );
    // every account is read, so a declared one is found at any uid.
    try testing.expectEqual(5, us.len);
    var people: std.ArrayList(facts.User) = .empty;
    for (us) |u| if (u.person()) try people.append(arena.allocator(), u);
    try testing.expectEqual(2, people.items.len);
    try testing.expectEqualStrings("kacy", people.items[0].name);
    const kacy = people.items[0];
    try testing.expectEqualStrings("/usr/bin/zsh", kacy.shell.?);
    try testing.expectEqualStrings("kacy", kacy.primary_group.?);
    try testing.expectEqual(2, kacy.groups.len);
    try testing.expectEqualStrings("video", kacy.groups[0]);
    try testing.expectEqualStrings("wheel", kacy.groups[1]);
    try testing.expectEqual(1, people.items[1].groups.len);
}

test "observe a machine laid out in a directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "etc");
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/hostname", .data = "atlas\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/locale.conf", .data = "LANG=en_US.UTF-8\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/passwd", .data = "kacy:x:1000:1000::/home/kacy:/usr/bin/zsh\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/group", .data = "kacy:x:1000:\nwheel:x:998:kacy\n" });
    try tmp.dir.symLink(io, "../usr/share/zoneinfo/Europe/Berlin", "etc/localtime", .{});
    try tmp.dir.createDirPath(io, "proc");
    try tmp.dir.writeFile(io, .{ .sub_path = "proc/cpuinfo", .data = "processor\t: 0\nvendor_id\t: AuthenticAMD\ncpu family\t: 25\n" });
    for ([_][3][]const u8{
        .{ "0000:00:02.0", "0x030000", "0x8086" }, // intel igpu
        .{ "0000:01:00.0", "0x030000", "0x10de" }, // nvidia dgpu
        .{ "0000:02:00.0", "0x020000", "0x10ec" }, // a network card
    }) |dev| {
        const dir = try std.fmt.allocPrint(testing.allocator, "sys/bus/pci/devices/{s}", .{dev[0]});
        defer testing.allocator.free(dir);
        try tmp.dir.createDirPath(io, dir);
        var sub = try tmp.dir.openDir(io, dir, .{});
        defer sub.close(io);
        try sub.writeFile(io, .{ .sub_path = "class", .data = dev[1] });
        try sub.writeFile(io, .{ .sub_path = "vendor", .data = dev[2] });
    }

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: diag.List = .init(testing.allocator);
    defer diags.deinit();
    const root = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const f = try observe(arena.allocator(), io, .{ .root = root, .packages = false }, &diags);
    try testing.expectEqualStrings("atlas", f.hostname.?);
    try testing.expectEqualStrings("Europe/Berlin", f.timezone.?);
    try testing.expectEqualStrings("en_US.UTF-8", f.locale.?);
    try testing.expectEqual(null, f.keymap);
    try testing.expectEqualStrings("wheel", f.users[0].groups[0]);
    try testing.expectEqualStrings("amd", f.cpu.?);
    try testing.expectEqual(2, f.gpus.len);
    try testing.expectEqualStrings("intel", f.gpus[0]);
    try testing.expectEqualStrings("nvidia", f.gpus[1]);
    try testing.expect(f.time > 1_700_000_000);
}

test "files with a new upstream default beside them" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "etc/ssh");
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/ssh/sshd_config.pacnew", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/pacman.conf.pacnew", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/pacman.conf", .data = "" });
    const root = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var diags: diag.List = .init(testing.allocator);
    defer diags.deinit();
    const f = try observe(arena.allocator(), io, .{ .root = root, .packages = false, .units = false }, &diags);
    try testing.expectEqual(2, f.pacnew.len);
    try testing.expectEqualStrings("/etc/pacman.conf", f.pacnew[0]);
    try testing.expectEqualStrings("/etc/ssh/sshd_config", f.pacnew[1]);
}

test "the package that owns a file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "var/lib/pacman/local/openssh-10.0p1-2");
    try tmp.dir.writeFile(io, .{ .sub_path = "var/lib/pacman/local/openssh-10.0p1-2/files", .data = "%FILES%\netc/\netc/ssh/\netc/ssh/sshd_config\n\n%BACKUP%\netc/ssh/sshd_config\tabc\n" });
    try tmp.dir.createDirPath(io, "var/lib/pacman/local/lib32-foo-bar-1:2.0-1");
    try tmp.dir.writeFile(io, .{ .sub_path = "var/lib/pacman/local/lib32-foo-bar-1:2.0-1/files", .data = "%FILES%\netc/foo.conf\n" });
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try testing.expectEqualStrings("openssh", (try fileOwner(a, io, root, "/etc/ssh/sshd_config")).?);
    try testing.expectEqualStrings("lib32-foo-bar", (try fileOwner(a, io, root, "/etc/foo.conf")).?);
    try testing.expectEqual(null, try fileOwner(a, io, root, "/etc/motd"));
    // a backup line isn't a file line.
    try testing.expect(!listsFile("%BACKUP%\netc/motd\n", "/etc/motd"));
}

test "which bootloader an esp at /boot holds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const io = testing.io;
    const r: Reader = .{ .a = arena.allocator(), .io = io, .root = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path}) };
    try testing.expectEqual(null, try r.loader("/boot"));
    try tmp.dir.createDirPath(io, "boot/grub");
    try tmp.dir.writeFile(io, .{ .sub_path = "boot/grub/grub.cfg", .data = "" });
    try testing.expectEqualStrings("grub", (try r.loader("/boot")).?);
    try tmp.dir.createDirPath(io, "boot/EFI/arch-limine");
    try tmp.dir.writeFile(io, .{ .sub_path = "boot/EFI/arch-limine/limine.conf", .data = "" });
    try testing.expectEqualStrings("limine", (try r.loader("/boot")).?);
}
