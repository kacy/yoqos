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
        const hex = sha256Hex(try fs.read(rel));
        try out.append(a, .{ .path = p, .sha256 = try a.dupe(u8, &hex), .mode = try std.fmt.allocPrint(a, "{o:0>4}", .{m}) });
    }
    return out.items;
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
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
