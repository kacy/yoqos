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

/// a file under /proc, like /proc/cmdline. those report a size of 0, so
/// they're read to the end rather than by their size. empty if it can't
/// be read.
pub fn readProc(a: std.mem.Allocator, io: std.Io, path: []const u8) error{OutOfMemory}![]const u8 {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return "";
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var fr = f.readerStreaming(io, &buf);
    return fr.interface.allocRemaining(a, .limited(4 << 20)) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => "",
    };
}

pub fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// replaces the file at `path` in one step, making its directory if
/// needed, so a crash leaves the old or the new content, never half of
/// each. the new file has mode `bits`, or 0644, whatever the umask, from
/// the moment it exists, and is on disk before it takes the old one's
/// place. the temporary file beside it is made fresh, never through a
/// symlink someone left there.
pub fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8, bits: ?u32) error{WriteFailed}!void {
    const linux = std.os.linux;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&buf, "{s}.os-tmp", .{path}) catch return error.WriteFailed;
    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest = std.fmt.bufPrintZ(&dest_buf, "{s}", .{path}) catch return error.WriteFailed;
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirnamePosix(path)) |d| cwd.createDirPath(io, d) catch return error.WriteFailed;
    const mode: linux.mode_t = @intCast(bits orelse 0o644);
    // one left by a crash goes first; unlink removes a symlink itself.
    _ = linux.unlink(tmp);
    const opened = linux.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, mode);
    if (linux.errno(opened) != .SUCCESS) return error.WriteFailed;
    const fd: linux.fd_t = @intCast(opened);
    errdefer _ = linux.unlink(tmp);
    {
        defer _ = linux.close(fd);
        if (linux.errno(linux.fchmod(fd, mode)) != .SUCCESS) return error.WriteFailed;
        var done: usize = 0;
        while (done < bytes.len) {
            const n = linux.write(fd, bytes[done..].ptr, bytes.len - done);
            switch (linux.errno(n)) {
                .SUCCESS => done += n,
                .INTR => {},
                else => return error.WriteFailed,
            }
        }
        if (linux.errno(linux.fsync(fd)) != .SUCCESS) return error.WriteFailed;
    }
    if (linux.errno(linux.rename(tmp, dest)) != .SUCCESS) return error.WriteFailed;
}

test "an atomic write keeps its mode, and a symlink in the way stays untouched" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(io, .{ .sub_path = "victim", .data = "keep" });
    try tmp.dir.symLink(io, "victim", "secret.os-tmp", .{});
    try writeAtomic(io, try std.fmt.allocPrint(a, "{s}/secret", .{dir}), "hash", 0o600);
    try std.testing.expectEqualStrings("keep", try tmp.dir.readFileAlloc(io, "victim", a, .limited(16)));
    try std.testing.expectEqualStrings("hash", try tmp.dir.readFileAlloc(io, "secret", a, .limited(16)));
    const st = try tmp.dir.statFile(io, "secret", .{});
    try std.testing.expectEqual(0o600, @intFromEnum(st.permissions) & 0o777);
}

test "a /proc file reads whole" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try readProc(arena.allocator(), std.testing.io, "/proc/self/mountinfo")).len > 0);
    try std.testing.expectEqualStrings("", try readProc(arena.allocator(), std.testing.io, "/proc/no-such-file"));
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
