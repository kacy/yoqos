//! a machine's own files under its root: `/`, or a mounted install. apply's
//! steps read and write through this, so they work on either.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Root = struct {
    a: Allocator,
    io: std.Io,
    dir: []const u8,

    /// `rel`, a path inside the machine like "etc/hostname", on this host.
    pub fn path(r: Root, rel: []const u8) ![]const u8 {
        return std.fs.path.join(r.a, &.{ r.dir, rel });
    }

    /// the file's contents, or "" if it's missing or can't be read.
    pub fn read(r: Root, rel: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(r.io, try r.path(rel), r.a, .limited(64 << 20)) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => "",
        };
    }

    /// replaces the file in one step, making its directory if needed, so a
    /// crash leaves the old or the new content, never half of each.
    pub fn write(r: Root, rel: []const u8, bytes: []const u8) error{ OutOfMemory, WriteFailed }!void {
        const p = try r.path(rel);
        const tmp = try std.fmt.allocPrint(r.a, "{s}.os-tmp", .{p});
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirnamePosix(p)) |d| cwd.createDirPath(r.io, d) catch return error.WriteFailed;
        cwd.writeFile(r.io, .{ .sub_path = tmp, .data = bytes }) catch return error.WriteFailed;
        cwd.rename(tmp, cwd, p, r.io) catch return error.WriteFailed;
    }

    /// adds `bytes` to the end of the file.
    pub fn append(r: Root, rel: []const u8, bytes: []const u8) !void {
        return r.write(rel, try std.mem.concat(r.a, u8, &.{ try r.read(rel), bytes }));
    }
};

test "write, read, and append under a root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r: Root = .{ .a = arena.allocator(), .io = std.testing.io, .dir = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path}) };
    try std.testing.expectEqualStrings("", try r.read("var/lib/yoq/ids"));
    try r.append("var/lib/yoq/ids", "kacy 1000\n");
    try r.append("var/lib/yoq/ids", "guest 1001\n");
    try std.testing.expectEqualStrings("kacy 1000\nguest 1001\n", try r.read("var/lib/yoq/ids"));
}
