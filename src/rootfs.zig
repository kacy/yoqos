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
        return r.writeMode(rel, bytes, null);
    }

    /// `write`, with the file's permission bits set to `mode`, if given,
    /// before it takes the old one's place.
    pub fn writeMode(r: Root, rel: []const u8, bytes: []const u8, bits: ?u32) error{ OutOfMemory, WriteFailed }!void {
        return writeAtomic(r.io, try r.path(rel), bytes, bits);
    }

    pub fn exists(r: Root, rel: []const u8) bool {
        return pathExists(r.io, r.path(rel) catch return false);
    }

    /// a file's permission bits, or null if it's missing.
    pub fn mode(r: Root, rel: []const u8) !?u32 {
        const st = std.Io.Dir.cwd().statFile(r.io, try r.path(rel), .{}) catch return null;
        return @as(u32, @intCast(@intFromEnum(st.permissions))) & 0o7777;
    }

    /// adds `bytes` to the end of the file. a file that's there but can't
    /// be read is a failure, not an empty file to start over.
    pub fn append(r: Root, rel: []const u8, bytes: []const u8) error{ OutOfMemory, WriteFailed }!void {
        const old = std.Io.Dir.cwd().readFileAlloc(r.io, try r.path(rel), r.a, .limited(64 << 20)) catch |e| switch (e) {
            error.FileNotFound => "",
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.WriteFailed,
        };
        return r.write(rel, try std.mem.concat(r.a, u8, &.{ old, bytes }));
    }
};

pub fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// replaces the file at `path` in one step, making its directory if
/// needed, so a crash leaves the old or the new content, never half of
/// each. the new file has mode `bits`, or 0644, whatever the umask, and is
/// on disk before it takes the old one's place.
pub fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8, bits: ?u32) error{WriteFailed}!void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&buf, "{s}.os-tmp", .{path}) catch return error.WriteFailed;
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirnamePosix(path)) |d| cwd.createDirPath(io, d) catch return error.WriteFailed;
    errdefer cwd.deleteFile(io, tmp) catch {};
    {
        var f = cwd.createFile(io, tmp, .{}) catch return error.WriteFailed;
        defer f.close(io);
        f.writeStreamingAll(io, bytes) catch return error.WriteFailed;
        f.sync(io) catch return error.WriteFailed;
    }
    cwd.setFilePermissions(io, tmp, @enumFromInt(bits orelse 0o644), .{}) catch return error.WriteFailed;
    cwd.rename(tmp, cwd, path, io) catch return error.WriteFailed;
}

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
