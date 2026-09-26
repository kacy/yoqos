//! the facts document: what the observer saw on the machine. the planner
//! reads nothing else about the machine, and time only enters through
//! `time`, so the same facts always give the same plan.

const std = @import("std");
const lists = @import("lists.zig");
const Allocator = std.mem.Allocator;

pub const schema = "yoq.facts/1";

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
    active: bool = false,
    /// the unit tried to run and failed.
    failed: bool = false,
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
};

/// a file os manages, as it is on the machine.
pub const File = struct {
    path: []const u8,
    /// hex sha256 of the content.
    sha256: []const u8,
    /// octal permission bits, like "0644".
    mode: []const u8,
};

/// the hash files are compared by.
pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// packages a pacman transaction outside os touched, and when.
pub const PacmanChange = struct {
    /// unix milliseconds, like the apply journal's.
    time: i64,
    packages: []const []const u8,
};

pub const Facts = struct {
    /// the document's schema tag, first in the json like every document os
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
    /// the files the config manages that exist.
    files: []File = &.{},
    /// modules mkinitcpio puts in the initramfs, from mkinitcpio.conf and
    /// its drop-ins, leaving out the ones os writes.
    initramfs_modules: []const []const u8 = &.{},
    /// files under /etc with a new upstream default beside them, as
    /// `<path>.pacnew`, by the path of the file itself.
    pacnew: []const []const u8 = &.{},

    pub fn package(f: *const Facts, name: []const u8) ?*const Package {
        for (f.packages) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    pub fn file(f: *const Facts, path: []const u8) ?*const File {
        for (f.files) |*x| {
            if (std.mem.eql(u8, x.path, path)) return x;
        }
        return null;
    }

    pub fn unit(f: *const Facts, name: []const u8) ?*const Unit {
        for (f.units) |*u| {
            if (std.mem.eql(u8, u.name, name)) return u;
        }
        return null;
    }

    /// sorts every list by name so output and hashes don't depend on the
    /// order things were observed in.
    pub fn normalize(f: *Facts) void {
        lists.sortByField(Package, "name", f.packages);
        lists.sortByField(Unit, "name", f.units);
        lists.sortByField(User, "name", f.users);
        lists.sortByField(File, "path", f.files);
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
    try testing.expectError(error.BadFacts, parse(arena.allocator(), "{\"schema\":\"yoq.plan/1\"}"));
    try testing.expectError(error.BadFacts, parse(arena.allocator(), "not json"));
    try testing.expectError(error.BadFacts, parse(arena.allocator(), "{\"schema\":\"yoq.facts/1\",\"bogus\":1}"));
}

test "parse sorts what it reads" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f = try parse(arena.allocator(),
        \\{"schema":"yoq.facts/1","units":[{"name":"sshd.service","enabled":true},{"name":"bluetooth.service"}]}
    );
    try testing.expectEqualStrings("bluetooth.service", f.units[0].name);
    try testing.expect(f.unit("sshd.service").?.enabled);
}
