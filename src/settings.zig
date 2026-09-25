//! writes the `[system]` settings to a machine's files: /etc/hostname,
//! /etc/localtime, /etc/locale.conf, and /etc/vconsole.conf, all under a
//! root. the observer reads the same files back.

const std = @import("std");
const diag = @import("diag.zig");
const Allocator = std.mem.Allocator;

/// sets one `[system]` key, by its plan subject ("system.hostname") and
/// value. returns false after saying why in `diags`.
pub fn apply(a: Allocator, io: std.Io, root: []const u8, subject: []const u8, value: []const u8, diags: *diag.List) !bool {
    const key = subject["system.".len..];
    const r: Root = .{ .a = a, .io = io, .root = root, .diags = diags };
    if (std.mem.eql(u8, key, "hostname")) return r.write("etc/hostname", try std.fmt.allocPrint(a, "{s}\n", .{value}));
    if (std.mem.eql(u8, key, "locale")) return r.setVar("etc/locale.conf", "LANG", value);
    if (std.mem.eql(u8, key, "keymap")) return r.setVar("etc/vconsole.conf", "KEYMAP", value);
    if (std.mem.eql(u8, key, "timezone")) return r.timezone(value);
    try diags.add(.bad_value, null, "os doesn't know how to set {s}", .{subject}, null);
    return false;
}

const Root = struct {
    a: Allocator,
    io: std.Io,
    root: []const u8,
    diags: *diag.List,

    fn path(r: Root, rel: []const u8) ![]const u8 {
        return std.fs.path.join(r.a, &.{ r.root, rel });
    }

    fn failed(r: Root, what: []const u8, p: []const u8) !bool {
        try r.diags.add(.bad_value, null, "can't {s} {s}", .{ what, p }, null);
        return false;
    }

    /// replaces a file in one step.
    fn write(r: Root, rel: []const u8, bytes: []const u8) !bool {
        const p = try r.path(rel);
        const tmp = try std.fmt.allocPrint(r.a, "{s}.os-tmp", .{p});
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirnamePosix(p)) |dir| cwd.createDirPath(r.io, dir) catch return r.failed("create", dir);
        cwd.writeFile(r.io, .{ .sub_path = tmp, .data = bytes }) catch return r.failed("write", tmp);
        cwd.rename(tmp, cwd, p, r.io) catch return r.failed("replace", p);
        return true;
    }

    fn read(r: Root, rel: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(r.io, try r.path(rel), r.a, .limited(1 << 20)) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => "",
        };
    }

    fn setVar(r: Root, rel: []const u8, key: []const u8, value: []const u8) !bool {
        return r.write(rel, try setShellVar(r.a, try r.read(rel), key, value));
    }

    /// /etc/localtime is a link into the zoneinfo files, which have to
    /// have the zone.
    fn timezone(r: Root, zone: []const u8) !bool {
        const target = try std.fmt.allocPrint(r.a, "/usr/share/zoneinfo/{s}", .{zone});
        const cwd = std.Io.Dir.cwd();
        cwd.access(r.io, try r.path(target[1..]), .{}) catch {
            try r.diags.add(.bad_value, null, "there's no time zone called {s}", .{zone}, "zone names look like America/New_York; they're the files under /usr/share/zoneinfo");
            return false;
        };
        const link = try r.path("etc/localtime");
        const tmp = try std.fmt.allocPrint(r.a, "{s}.os-tmp", .{link});
        cwd.deleteFile(r.io, tmp) catch {};
        cwd.symLink(r.io, target, tmp, .{}) catch return r.failed("link", tmp);
        cwd.rename(tmp, cwd, link, r.io) catch return r.failed("replace", link);
        return true;
    }
};

/// `text` with `key=value` set: the existing line replaced, or a new one
/// added at the end. other lines stay as they are.
pub fn setShellVar(a: Allocator, text: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var found = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(a, '\n');
        first = false;
        const t = std.mem.trim(u8, line, " \t");
        const eq = std.mem.indexOfScalar(u8, t, '=');
        if (!found and eq != null and std.mem.eql(u8, std.mem.trim(u8, t[0..eq.?], " \t"), key)) {
            try out.print(a, "{s}={s}", .{ key, value });
            found = true;
        } else try out.appendSlice(a, line);
    }
    if (!found) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
        try out.print(a, "{s}={s}\n", .{ key, value });
    }
    return out.items;
}

// -- tests --

const testing = std.testing;

test "set a shell variable in place" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("# comment\nLANG=en_US.UTF-8\nLC_TIME=C\n", try setShellVar(a, "# comment\nLANG=C.UTF-8\nLC_TIME=C\n", "LANG", "en_US.UTF-8"));
    try testing.expectEqualStrings("FONT=ter-v16n\nKEYMAP=us\n", try setShellVar(a, "FONT=ter-v16n\n", "KEYMAP", "us"));
    try testing.expectEqualStrings("FONT=x\nKEYMAP=de\n", try setShellVar(a, "FONT=x", "KEYMAP", "de"));
    try testing.expectEqualStrings("LANG=C\n", try setShellVar(a, "", "LANG", "C"));
}

test "settings land where the observer reads them" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var diags: diag.List = .init(testing.allocator);
    defer diags.deinit();
    try tmp.dir.createDirPath(io, "usr/share/zoneinfo/Europe");
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/share/zoneinfo/Europe/Berlin", .data = "TZif" });
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    try testing.expect(try apply(a, io, root, "system.hostname", "atlas", &diags));
    try testing.expect(try apply(a, io, root, "system.locale", "en_US.UTF-8", &diags));
    try testing.expect(try apply(a, io, root, "system.keymap", "us", &diags));
    try testing.expect(try apply(a, io, root, "system.timezone", "Europe/Berlin", &diags));
    // a second time replaces the link.
    try testing.expect(try apply(a, io, root, "system.timezone", "Europe/Berlin", &diags));
    try testing.expect(!try apply(a, io, root, "system.timezone", "Mars/Olympus", &diags));
    try testing.expectEqualStrings("there's no time zone called Mars/Olympus", diags.items.items[0].message);

    const f = try @import("observe.zig").observe(a, io, .{ .root = root, .packages = false, .units = false }, &diags);
    try testing.expectEqualStrings("atlas", f.hostname.?);
    try testing.expectEqualStrings("en_US.UTF-8", f.locale.?);
    try testing.expectEqualStrings("us", f.keymap.?);
    try testing.expectEqualStrings("Europe/Berlin", f.timezone.?);
}
