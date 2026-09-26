//! the observer: reads the machine into a facts document. it never changes
//! anything. every path is taken under `root`, so tests can point it at a
//! directory laid out like a machine.
//!
//! the parsers take file contents and are pure; `observe` does the reading.

const std = @import("std");
const facts = @import("facts.zig");
const alpm = @import("alpm.zig");
const drift = @import("drift.zig");
const rootfs = @import("rootfs.zig");
const systemd = @import("systemd.zig");
const diag = @import("diag.zig");
const lists = @import("lists.zig");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// "/" for the running machine.
    root: []const u8 = "/",
    /// read packages through libalpm. off in builds without it.
    packages: bool = alpm.available,
    /// read units from the running systemd. only for the running machine,
    /// and off in builds without libsystemd.
    units: bool = systemd.available,
    /// the files to hash, by their absolute paths on the machine.
    files: []const []const u8 = &.{},
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
    if (try r.file("etc/passwd")) |passwd| {
        f.users = try users(a, passwd, try r.file("etc/group") orelse "");
    }
    f.pacman_changes = try drift.since(a, io, opts.root);
    f.files = try files(a, io, opts.root, opts.files);
    f.initramfs_modules = try r.mkinitcpio("MODULES");
    f.boot = try r.boot();
    f.pacnew = try r.pacnew();
    if (opts.packages) {
        const dbpath = try r.dbpath();
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

const Reader = struct {
    a: Allocator,
    io: std.Io,
    root: []const u8,

    fn path(r: Reader, rel: []const u8) ![]const u8 {
        return std.fs.path.join(r.a, &.{ r.root, rel });
    }

    /// a file's contents, or null if it doesn't exist or can't be read. it
    /// reads to the end instead of trusting the file's size, since files
    /// under /proc and /sys say they're empty.
    fn file(r: Reader, rel: []const u8) !?[]const u8 {
        const f = std.Io.Dir.cwd().openFile(r.io, try r.path(rel), .{}) catch return null;
        defer f.close(r.io);
        var buf: [4096]u8 = undefined;
        var fr = f.readerStreaming(r.io, &buf);
        return fr.interface.allocRemaining(r.a, .limited(4 << 20)) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => null,
        };
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
        var dir = std.Io.Dir.cwd().openDir(r.io, try r.path("etc/mkinitcpio.conf.d"), .{ .iterate = true }) catch return out.items;
        defer dir.close(r.io);
        var it = dir.iterate();
        while (it.next(r.io) catch null) |e| {
            if (std.mem.startsWith(u8, e.name, "10-yoq-") or !std.mem.endsWith(u8, e.name, ".conf")) continue;
            const text = try r.file(try std.fmt.allocPrint(r.a, "etc/mkinitcpio.conf.d/{s}", .{e.name})) orelse continue;
            try mkinitcpioList(r.a, text, key, &out);
        }
        return out.items;
    }

    /// how the machine boots. mounts and firmware only describe the
    /// running machine, so under another root those stay unknown.
    fn boot(r: Reader) !facts.Boot {
        var b: facts.Boot = .{
            .initramfs_hooks = try r.mkinitcpio("HOOKS"),
            .pacman_moved = std.mem.endsWith(u8, try r.dbpath(), "sysimage/pacman"),
        };
        if (!std.mem.eql(u8, r.root, "/")) return b;
        b.uefi = r.exists("sys/firmware/efi");
        // an automounted esp only shows up in mountinfo once it's used.
        for ([_][]const u8{ "efi/EFI", "boot/efi/EFI" }) |p| _ = r.exists(p);
        const ms = try mounts(r.a, try r.file("proc/self/mountinfo") orelse "");
        const root = mountAt(ms, "/") orelse return b;
        b.root_fs = root.fstype;
        b.root_device = root.source;
        if (std.mem.eql(u8, root.fstype, "btrfs")) {
            b.root_subvol = root.root;
            if (mountAt(ms, "/var")) |v| b.var_subvol = std.mem.eql(u8, v.fstype, "btrfs") and !std.mem.eql(u8, v.root, root.root);
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
        return b;
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
        }
        if (r.exists("boot/limine.conf")) return "limine";
        if (r.exists("boot/grub/grub.cfg")) return "grub";
        return null;
    }

    fn exists(r: Reader, rel: []const u8) bool {
        const p = r.path(rel) catch return false;
        std.Io.Dir.cwd().access(r.io, p, .{}) catch return false;
        return true;
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
        var dir = std.Io.Dir.cwd().openDir(r.io, try r.path("sys/bus/pci/devices"), .{ .iterate = true }) catch return out.items;
        defer dir.close(r.io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (it.next(r.io) catch null) |e| try names.append(r.a, try r.a.dupe(u8, e.name));
        lists.sortStrings(names.items);
        for (names.items) |n| {
            const class = try r.file(try std.fmt.allocPrint(r.a, "sys/bus/pci/devices/{s}/class", .{n})) orelse continue;
            if (!std.mem.startsWith(u8, std.mem.trim(u8, class, " \n"), "0x03")) continue;
            const vendor = try r.file(try std.fmt.allocPrint(r.a, "sys/bus/pci/devices/{s}/vendor", .{n})) orelse continue;
            if (gpuVendor(std.mem.trim(u8, vendor, " \n"))) |v| try out.append(r.a, v);
        }
        return out.items;
    }

    fn dbpath(r: Reader) ![]const u8 {
        return pacmanDb(r.a, r.io, r.root);
    }
};

/// a mkinitcpio array, like MODULES or HOOKS: `KEY=(...)` sets it and
/// `KEY+=(...)` adds to it, in the order the lines come.
pub fn mkinitcpioList(a: Allocator, text: []const u8, comptime key: []const u8, out: *std.ArrayList([]const u8)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const set = key ++ "=(";
        const add = key ++ "+=(";
        const start = if (std.mem.startsWith(u8, line, set)) set.len else if (std.mem.startsWith(u8, line, add)) add.len else continue;
        if (start == set.len) out.clearRetainingCapacity();
        const end = std.mem.indexOfScalarPos(u8, line, start, ')') orelse continue;
        var names = std.mem.tokenizeAny(u8, line[start..end], " \t\"'");
        while (names.next()) |n| try out.append(a, try a.dupe(u8, n));
    }
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
pub fn mapsReplaced(maps: []const u8) bool {
    var lines = std.mem.splitScalar(u8, maps, '\n');
    while (lines.next()) |line| {
        if (!std.mem.endsWith(u8, line, " (deleted)")) continue;
        const slash = std.mem.indexOfScalar(u8, line, '/') orelse continue;
        const file = line[slash..];
        if (std.mem.startsWith(u8, file, "/usr/") or std.mem.startsWith(u8, file, "/opt/")) return true;
    }
    return false;
}

/// the managed files that exist, with their hash and mode.
fn files(a: Allocator, io: std.Io, root: []const u8, paths: []const []const u8) ![]facts.File {
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    var out: std.ArrayList(facts.File) = .empty;
    for (paths) |p| {
        const rel = std.mem.trimStart(u8, p, "/");
        const m = try fs.mode(rel) orelse continue;
        const hex = facts.sha256Hex(try fs.read(rel));
        try out.append(a, .{ .path = p, .sha256 = try a.dupe(u8, &hex), .mode = try std.fmt.allocPrint(a, "{o:0>4}", .{m}) });
    }
    return out.items;
}

/// pacman's database directory under `root`: in /usr on the rollback rung,
/// in /var otherwise.
pub fn pacmanDb(a: Allocator, io: std.Io, root: []const u8) ![]const u8 {
    const moved = try std.fs.path.join(a, &.{ root, "usr/lib/sysimage/pacman" });
    std.Io.Dir.cwd().access(io, try std.fs.path.join(a, &.{ moved, "local" }), .{}) catch return std.fs.path.join(a, &.{ root, "var/lib/pacman" });
    return moved;
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

pub fn zoneFromLink(a: Allocator, target: []const u8) !?[]const u8 {
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
pub fn shellVar(text: []const u8, key: []const u8) ?[]const u8 {
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

/// regular users: uid 1000 up to 60000, the range useradd hands out.
const first_uid = 1000;
const last_uid = 60000;

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
        if (uid < first_uid or uid > last_uid) continue;
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
    try testing.expectEqual(2, us.len);
    try testing.expectEqualStrings("kacy", us[0].name);
    try testing.expectEqualStrings("/usr/bin/zsh", us[0].shell.?);
    try testing.expectEqualStrings("kacy", us[0].primary_group.?);
    try testing.expectEqual(2, us[0].groups.len);
    try testing.expectEqualStrings("video", us[0].groups[0]);
    try testing.expectEqualStrings("wheel", us[0].groups[1]);
    try testing.expectEqual(1, us[1].groups.len);
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
