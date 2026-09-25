//! the facts document: what the observer saw on the machine. the planner
//! reads nothing else about the machine, and time only enters through
//! `time`, so the same facts always give the same plan.

const std = @import("std");
const output = @import("output.zig");
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
};

pub const User = struct {
    name: []const u8,
    uid: u32,
    shell: ?[]const u8 = null,
    groups: []const []const u8 = &.{},
};

pub const Facts = struct {
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

    pub fn package(f: *const Facts, name: []const u8) ?*const Package {
        for (f.packages) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
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
    }
};

pub fn write(w: *std.Io.Writer, f: *const Facts) !void {
    try output.writeDoc(w, schema, f.*);
}

pub const ParseError = error{ BadFacts, OutOfMemory };

const Doc = struct {
    schema: []const u8,
    time: i64 = 0,
    hostname: ?[]const u8 = null,
    timezone: ?[]const u8 = null,
    locale: ?[]const u8 = null,
    keymap: ?[]const u8 = null,
    cpu: ?[]const u8 = null,
    gpus: []const []const u8 = &.{},
    packages: []Package = &.{},
    units: []Unit = &.{},
    users: []User = &.{},
};

/// reads a facts document. everything is allocated in `a`, which should be
/// an arena. the result is normalized.
pub fn parse(a: Allocator, bytes: []const u8) ParseError!Facts {
    const doc = std.json.parseFromSliceLeaky(Doc, a, bytes, .{ .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadFacts,
    };
    if (!std.mem.eql(u8, doc.schema, schema)) return error.BadFacts;
    var f: Facts = .{
        .time = doc.time,
        .hostname = doc.hostname,
        .timezone = doc.timezone,
        .locale = doc.locale,
        .keymap = doc.keymap,
        .cpu = doc.cpu,
        .gpus = doc.gpus,
        .packages = doc.packages,
        .units = doc.units,
        .users = doc.users,
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
