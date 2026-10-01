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

    /// `write`, with the file's permission bits set to `bits`, if given,
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

/// a file read to the end rather than by its size, since files under
/// /proc and /sys report a size of 0. null if it's missing or can't be
/// read.
pub fn readStreaming(a: Allocator, io: std.Io, path: []const u8) error{OutOfMemory}!?[]const u8 {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var fr = f.readerStreaming(io, &buf);
    return fr.interface.allocRemaining(a, .limited(4 << 20)) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// a file under /proc, like /proc/cmdline, or "" if it can't be read.
pub fn readProc(a: Allocator, io: std.Io, path: []const u8) error{OutOfMemory}![]const u8 {
    return try readStreaming(a, io, path) orelse "";
}

/// when this boot started, in unix seconds: /proc/stat's btime. null if
/// it can't be read.
pub fn bootTime(a: Allocator, io: std.Io) error{OutOfMemory}!?i64 {
    return parseBootTime(try readProc(a, io, "/proc/stat"));
}

fn parseBootTime(stat: []const u8) ?i64 {
    var lines = std.mem.tokenizeScalar(u8, stat, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "btime ")) continue;
        return std.fmt.parseInt(i64, std.mem.trim(u8, line["btime ".len..], " "), 10) catch null;
    }
    return null;
}

/// the bytes free for anyone to use on the filesystem holding `path`, or
/// null if that can't be told.
pub fn freeBytes(path: []const u8) ?u64 {
    return (space(path) orelse return null).free;
}

pub const Space = struct { free: u64, size: u64 };

/// the bytes free for anyone to use on the filesystem holding `path`, and
/// its size, or null if that can't be told.
pub fn space(path: []const u8) ?Space {
    const linux = std.os.linux;
    var z: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch return null;
    var st: Statfs = undefined;
    if (linux.errno(linux.syscall2(.statfs, @intFromPtr(p.ptr), @intFromPtr(&st))) != .SUCCESS) return null;
    const block: u64 = @intCast(st.bsize);
    return .{ .free = block *| st.bavail, .size = block *| st.blocks };
}

/// struct statfs on 64-bit linux, whole: the kernel writes all of it, so
/// a shorter one lets it write past the end.
const Statfs = extern struct {
    type: i64,
    bsize: i64,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    namelen: i64,
    frsize: i64,
    flags: i64,
    spare: [4]i64,
};

/// gives os a mount namespace of its own, with every mount in it
/// private, for commands that mount a root to build in. what they mount
/// then never reaches another namespace, like a service's, where an
/// unmount wouldn't follow and the mount would keep its disk busy, and it
/// all goes when os exits. the programs os runs see it too. an esp that
/// systemd automounts is mounted first, since its automount can't reach
/// in here. call it before mounting anything: a mount from before is a
/// copy here, and unmounting it here leaves the original. null when it
/// worked, or why not.
pub fn privateMounts(io: std.Io) ?[]const u8 {
    const linux = std.os.linux;
    for ([_][]const u8{ "/efi/EFI", "/boot/efi/EFI", "/boot/EFI" }) |p| _ = pathExists(io, p);
    if (namespaceProblem(linux.errno(linux.unshare(linux.CLONE.NEWNS)))) |why| return why;
    return namespaceProblem(linux.errno(linux.mount(null, "/", null, linux.MS.REC | linux.MS.PRIVATE, 0)));
}

fn namespaceProblem(e: std.os.linux.E) ?[]const u8 {
    return switch (e) {
        .SUCCESS => null,
        .PERM => "can't give os mounts of its own: that needs root",
        .NOMEM, .NOSPC => "can't give os mounts of its own: the kernel is out of room for them",
        else => "can't give os mounts of its own",
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
    // the rename itself is only durable once the directory is on disk. a
    // filesystem that can't sync a directory still has the new file.
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "{s}", .{std.fs.path.dirnamePosix(path) orelse "."}) catch return;
    const dfd = linux.open(dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(dfd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(dfd));
    if (linux.errno(linux.fsync(@intCast(dfd))) == .IO) return error.WriteFailed;
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

test "why os can't have mounts of its own" {
    try std.testing.expectEqual(null, namespaceProblem(.SUCCESS));
    try std.testing.expectEqualStrings("can't give os mounts of its own: that needs root", namespaceProblem(.PERM).?);
    try std.testing.expectEqualStrings("can't give os mounts of its own", namespaceProblem(.INVAL).?);
}

test "the boot time from /proc/stat" {
    try std.testing.expectEqual(1759200000, parseBootTime("cpu  1 2 3\nintr 5\nbtime 1759200000\nprocesses 9\n").?);
    try std.testing.expectEqual(null, parseBootTime("cpu  1 2 3\n"));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try bootTime(arena.allocator(), std.testing.io)).? > 0);
}

test "free space on a filesystem" {
    // the kernel's struct statfs is 120 bytes on 64-bit linux.
    try std.testing.expectEqual(120, @sizeOf(Statfs));
    try std.testing.expect(freeBytes(".").? > 0);
    try std.testing.expect(space(".").?.size >= space(".").?.free);
    try std.testing.expectEqual(null, freeBytes("/no/such/place"));
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
