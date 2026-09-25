//! the observer: reads the machine into a facts document. it never changes
//! anything. every path is taken under `root`, so tests can point it at a
//! directory laid out like a machine.
//!
//! the parsers take file contents and are pure; `observe` does the reading.

const std = @import("std");
const facts = @import("facts.zig");
const alpm = @import("alpm.zig");
const systemd = @import("systemd.zig");
const diag = @import("diag.zig");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// "/" for the running machine.
    root: []const u8 = "/",
    /// read packages through libalpm. off in builds without it.
    packages: bool = alpm.available,
    /// read units from the running systemd. only for the running machine,
    /// and off in builds without libsystemd.
    units: bool = systemd.available,
};

pub fn observe(a: Allocator, io: std.Io, opts: Options, diags: *diag.List) error{OutOfMemory}!facts.Facts {
    var f: facts.Facts = .{ .time = std.Io.Timestamp.now(io, .real).toSeconds() };
    const r: Reader = .{ .a = a, .io = io, .root = opts.root };

    if (try r.file("etc/hostname")) |text| f.hostname = firstLine(text);
    f.timezone = try r.timezone();
    if (try r.file("etc/locale.conf")) |text| f.locale = shellVar(text, "LANG");
    if (try r.file("etc/vconsole.conf")) |text| f.keymap = shellVar(text, "KEYMAP");
    if (try r.file("etc/passwd")) |passwd| {
        f.users = try users(a, passwd, try r.file("etc/group") orelse "");
    }
    if (opts.packages) {
        const dbpath = try r.dbpath();
        const pkgs = alpm.localPackages(a, opts.root, dbpath, diags) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AlpmUnavailable, error.AlpmFailed => null,
        };
        f.packages = pkgs orelse &.{};
    }
    if (opts.units and std.mem.eql(u8, opts.root, "/")) {
        const us = systemd.units(a, diags) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SystemdUnavailable => null,
        };
        f.units = us orelse &.{};
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

    /// a file's contents, or null if it doesn't exist or can't be read.
    fn file(r: Reader, rel: []const u8) !?[]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(r.io, try r.path(rel), r.a, .limited(4 << 20)) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => null,
        };
    }

    /// /etc/localtime is a symlink into the zoneinfo tree; the zone is the
    /// part of the target after "zoneinfo/".
    fn timezone(r: Reader) !?[]const u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.cwd().readLink(r.io, try r.path("etc/localtime"), &buf) catch return null;
        return zoneFromLink(r.a, buf[0..n]);
    }

    /// pacman's database lives in /usr on the rollback rung and in /var
    /// otherwise.
    fn dbpath(r: Reader) ![]const u8 {
        const moved = try r.path("usr/lib/sysimage/pacman");
        std.Io.Dir.cwd().access(r.io, try std.fs.path.join(r.a, &.{ moved, "local" }), .{}) catch return r.path("var/lib/pacman");
        return moved;
    }
};

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

/// users from /etc/passwd with their groups from /etc/group. the primary
/// group comes first, then the rest by name.
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
        try out.append(a, .{ .name = name, .uid = uid, .shell = shell, .groups = try groupsOf(a, name, gid, group) });
    }
    return out.items;
}

fn groupsOf(a: Allocator, user: []const u8, gid: []const u8, group: []const u8) ![]const []const u8 {
    var primary: ?[]const u8 = null;
    var rest: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, group, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const name = f.next() orelse continue;
        _ = f.next();
        const id = f.next() orelse continue;
        const members = f.next() orelse "";
        if (std.mem.eql(u8, id, gid)) {
            primary = name;
            continue;
        }
        var m = std.mem.splitScalar(u8, std.mem.trim(u8, members, " \r"), ',');
        while (m.next()) |member| {
            if (std.mem.eql(u8, member, user)) try rest.append(a, name);
        }
    }
    @import("sort.zig").strings(rest.items);
    if (primary) |p| try rest.insert(a, 0, p);
    return rest.items;
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
    try testing.expectEqual(3, us[0].groups.len);
    try testing.expectEqualStrings("kacy", us[0].groups[0]);
    try testing.expectEqualStrings("video", us[0].groups[1]);
    try testing.expectEqualStrings("wheel", us[0].groups[2]);
    try testing.expectEqual(2, us[1].groups.len);
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
    try testing.expectEqualStrings("wheel", f.users[0].groups[1]);
    try testing.expect(f.time > 1_700_000_000);
}
