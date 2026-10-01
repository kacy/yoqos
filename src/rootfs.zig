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

/// the start of a file, up to `out.len` bytes, like an efi binary's
/// headers. null if it's missing or can't be read.
pub fn readHead(io: std.Io, path: []const u8, out: []u8) ?[]u8 {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var buf: [256]u8 = undefined;
    var fr = f.readerStreaming(io, &buf);
    const n = fr.interface.readSliceShort(out) catch return null;
    return out[0..n];
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

/// os's directory under /run, where it locks the machine and mounts
/// roots. others can go through it: libalpm downloads into a staged
/// root's cache, under /run/yoq/next, as pacman's download user.
pub const run_dir = "/run/yoq";

/// the directory in `run_dir` that's root's alone, where the top level of
/// the root's filesystem is mounted. through that mount, anyone could
/// reach every root's world-writable /tmp, where os builds and signs
/// images.
pub const private_dir = run_dir ++ "/private";

/// makes `run_dir`, open to others. false if it can't.
pub fn makeRunDir() bool {
    return makeDir(run_dir, 0o755);
}

/// makes `private_dir` in `run_dir`. false unless it ends up a directory
/// of root's, never a symlink, that only root can go into.
pub fn makePrivateDir() bool {
    return makeRunDir() and makeDir(private_dir, 0o700);
}

/// makes the directory at `path`, or takes one that's there to `mode`.
/// false unless it ends up a directory of root's (or this process's
/// user's, in tests) with that mode.
fn makeDir(path: [:0]const u8, mode: u32) bool {
    const linux = std.os.linux;
    switch (linux.errno(linux.mkdir(path, mode))) {
        .SUCCESS, .EXIST => {},
        else => return false,
    }
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .UID = true, .MODE = true }, &st)) != .SUCCESS) return false;
    if (st.mode & linux.S.IFMT != linux.S.IFDIR or !trustedOwner(st.uid)) return false;
    if (st.mode & 0o7777 != mode and linux.errno(linux.chmod(path, mode)) != .SUCCESS) return false;
    return true;
}

test "the run directory stays open, and the private one in it is root's alone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    // one a run before made root's alone goes back to open.
    try tmp.dir.createDirPath(io, "yoq");
    try tmp.dir.setFilePermissions(io, "yoq", @enumFromInt(0o700), .{});
    try std.testing.expect(makeDir(try std.fmt.allocPrintSentinel(a, "{s}/yoq", .{base}, 0), 0o755));
    try std.testing.expect(makeDir(try std.fmt.allocPrintSentinel(a, "{s}/yoq/private", .{base}, 0), 0o700));
    try std.testing.expectEqual(0o755, @intFromEnum((try tmp.dir.statFile(io, "yoq", .{})).permissions) & 0o7777);
    try std.testing.expectEqual(0o700, @intFromEnum((try tmp.dir.statFile(io, "yoq/private", .{})).permissions) & 0o7777);
    // a symlink in its place isn't used.
    try tmp.dir.createDirPath(io, "theirs");
    try tmp.dir.symLink(io, "../theirs", "yoq/linked", .{});
    try std.testing.expect(!makeDir(try std.fmt.allocPrintSentinel(a, "{s}/yoq/linked", .{base}, 0), 0o700));
    try std.testing.expect(@intFromEnum((try tmp.dir.statFile(io, "theirs", .{})).permissions) & 0o777 != 0o700);
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
    const dir = std.fs.path.dirnamePosix(path) orelse ".";
    std.Io.Dir.cwd().createDirPath(io, dir) catch return error.WriteFailed;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&dir_buf, "{s}", .{dir}) catch return error.WriteFailed;
    const dfd = linux.open(dir_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(dfd) != .SUCCESS) return error.WriteFailed;
    defer _ = linux.close(@intCast(dfd));
    return replaceAt(@intCast(dfd), std.fs.path.basenamePosix(path), bytes, bits);
}

/// `writeAtomic`'s work, for the file `name` in the open directory `dfd`:
/// the temporary file and the rename both happen in that directory, so
/// nothing can swap the path in between.
fn replaceAt(dfd: std.os.linux.fd_t, name: []const u8, bytes: []const u8, bits: ?u32) error{WriteFailed}!void {
    const linux = std.os.linux;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&buf, "{s}.os-tmp", .{name}) catch return error.WriteFailed;
    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest = std.fmt.bufPrintZ(&dest_buf, "{s}", .{name}) catch return error.WriteFailed;
    const mode: linux.mode_t = @intCast(bits orelse 0o644);
    // one left by a crash goes first; unlink removes a symlink itself.
    _ = linux.unlinkat(dfd, tmp, 0);
    const opened = linux.openat(dfd, tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, mode);
    if (linux.errno(opened) != .SUCCESS) return error.WriteFailed;
    const fd: linux.fd_t = @intCast(opened);
    errdefer _ = linux.unlinkat(dfd, tmp, 0);
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
    if (linux.errno(linux.renameat(dfd, tmp, dfd, dest)) != .SUCCESS) return error.WriteFailed;
    // the rename itself is only durable once the directory is on disk. a
    // filesystem that can't sync a directory still has the new file.
    if (linux.errno(linux.fsync(dfd)) == .IO) return error.WriteFailed;
}

/// writes the file at `rel`, a path inside the machine at `root`, like
/// `writeAtomic`, in a directory `openParent` checked on the way down.
/// null when it worked, or why not, naming the path.
pub fn writeChecked(a: Allocator, root: []const u8, rel: []const u8, bytes: []const u8, bits: ?u32) error{OutOfMemory}!?[]const u8 {
    const shown = try std.fs.path.join(a, &.{ root, rel });
    const dfd = switch (try openParent(a, root, rel, true)) {
        .dir => |fd| fd,
        .refused => |why| return try std.fmt.allocPrint(a, "can't write {s}: {s}", .{ shown, why }),
        .missing => unreachable, // made on the way.
    };
    defer _ = std.os.linux.close(dfd);
    replaceAt(dfd, std.fs.path.basenamePosix(rel), bytes, bits) catch return try std.fmt.allocPrint(a, "can't write {s}", .{shown});
    return null;
}

/// removes the file at `rel` inside `root`, in a directory `openParent`
/// checked. one that's already gone is fine. null when it worked, or why
/// not.
pub fn removeChecked(a: Allocator, root: []const u8, rel: []const u8) error{OutOfMemory}!?[]const u8 {
    const linux = std.os.linux;
    const shown = try std.fs.path.join(a, &.{ root, rel });
    const dfd = switch (try openParent(a, root, rel, false)) {
        .dir => |fd| fd,
        .refused => |why| return try std.fmt.allocPrint(a, "can't remove {s}: {s}", .{ shown, why }),
        .missing => return null,
    };
    defer _ = linux.close(dfd);
    return switch (linux.errno(linux.unlinkat(dfd, try a.dupeZ(u8, std.fs.path.basenamePosix(rel)), 0))) {
        .SUCCESS, .NOENT => null,
        else => try std.fmt.allocPrint(a, "can't remove {s}", .{shown}),
    };
}

const Parent = union(enum) {
    dir: std.os.linux.fd_t,
    /// why os won't write there.
    refused: []const u8,
    /// a directory on the way isn't there, and wasn't to be made.
    missing,
};

/// the most symlinks a path may go through, as the kernel allows.
const max_links = 40;

/// opens the directory that holds `rel`, a path inside the machine at
/// `root`, walking down from the root one directory at a time, and making
/// the ones that are missing when `make` says so. a directory another
/// user owns, or that others can write to without the sticky bit, is
/// refused, and so is a symlink another user owns: either could point the
/// write somewhere else. a symlink of root's, like /bin -> usr/bin, is
/// followed, inside the root.
fn openParent(a: Allocator, root: []const u8, rel: []const u8, make: bool) error{OutOfMemory}!Parent {
    const linux = std.os.linux;
    var stack: std.ArrayList(linux.fd_t) = .empty;
    defer for (stack.items[0..stack.items.len -| 1]) |fd| {
        _ = linux.close(fd);
    };
    const root_fd = linux.open(try a.dupeZ(u8, root), .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(root_fd) != .SUCCESS) return .{ .refused = "the root can't be opened" };
    try stack.append(a, @intCast(root_fd));
    if (try dirProblem(a, stack.items[0], root)) |why| return .{ .refused = why };
    // what's left to walk, last first.
    var pending: std.ArrayList([]const u8) = .empty;
    try pushParts(a, &pending, std.fs.path.dirnamePosix(rel) orelse "");
    var links: usize = 0;
    while (pending.pop()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (stack.items.len > 1) _ = linux.close(stack.pop().?);
            continue;
        }
        const at = stack.items[stack.items.len - 1];
        const z = try a.dupeZ(u8, part);
        var st: linux.Statx = undefined;
        var e = linux.errno(linux.statx(at, z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .UID = true, .MODE = true }, &st));
        if (e == .NOENT) {
            if (!make) return .missing;
            switch (linux.errno(linux.mkdirat(at, z, 0o755))) {
                .SUCCESS, .EXIST => {},
                else => return .{ .refused = try std.fmt.allocPrint(a, "can't make the directory {s}", .{part}) },
            }
            e = linux.errno(linux.statx(at, z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .UID = true, .MODE = true }, &st));
        }
        if (e != .SUCCESS) return .{ .refused = try std.fmt.allocPrint(a, "can't look at {s}", .{part}) };
        switch (st.mode & linux.S.IFMT) {
            linux.S.IFLNK => {
                if (!trustedOwner(st.uid)) return .{ .refused = try std.fmt.allocPrint(a, "{s} on the way is a symlink another user owns", .{part}) };
                links += 1;
                if (links > max_links) return .{ .refused = "too many symlinks on the way" };
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = linux.readlinkat(at, z, &buf, buf.len);
                if (linux.errno(n) != .SUCCESS) return .{ .refused = try std.fmt.allocPrint(a, "can't read the symlink {s}", .{part}) };
                const target = try a.dupe(u8, buf[0..n]);
                // an absolute target starts again at the root, not the host's.
                if (target.len > 0 and target[0] == '/') while (stack.items.len > 1) {
                    _ = linux.close(stack.pop().?);
                };
                try pushParts(a, &pending, target);
            },
            linux.S.IFDIR => {
                const opened = linux.openat(at, z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
                if (linux.errno(opened) != .SUCCESS) return .{ .refused = try std.fmt.allocPrint(a, "can't open the directory {s}", .{part}) };
                try stack.append(a, @intCast(opened));
                // checked once open, so it's the directory os goes on in.
                if (try dirProblem(a, @intCast(opened), part)) |why| return .{ .refused = why };
            },
            else => return .{ .refused = try std.fmt.allocPrint(a, "{s} on the way isn't a directory", .{part}) },
        }
    }
    return .{ .dir = stack.pop().? };
}

/// adds the parts of `path` to `pending`, so the first comes off first.
fn pushParts(a: Allocator, pending: *std.ArrayList([]const u8), path: []const u8) !void {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |p| try parts.append(a, p);
    std.mem.reverse([]const u8, parts.items);
    try pending.appendSlice(a, parts.items);
}

/// root's, or this process's own user's, as in a test.
fn trustedOwner(uid: std.os.linux.uid_t) bool {
    return uid == 0 or uid == std.os.linux.geteuid();
}

/// why os won't write through the open directory `fd`, named `name`, or
/// null if it will. a group that can write to it counts as others, unless
/// it's root's group, or this process's.
fn dirProblem(a: Allocator, fd: std.os.linux.fd_t, name: []const u8) !?[]const u8 {
    const linux = std.os.linux;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .UID = true, .GID = true, .MODE = true }, &st)) != .SUCCESS) return try std.fmt.allocPrint(a, "can't look at {s}", .{name});
    if (!trustedOwner(st.uid)) return try std.fmt.allocPrint(a, "the directory {s} on the way belongs to another user", .{name});
    const group = st.gid == 0 or st.gid == linux.getegid();
    const open = st.mode & 0o002 != 0 or (st.mode & 0o020 != 0 and !group);
    if (open and st.mode & linux.S.ISVTX == 0) return try std.fmt.allocPrint(a, "others can write to the directory {s} on the way", .{name});
    return null;
}

test "a checked write follows root's symlinks, and refuses others' and open directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/root", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "root/usr/lib");
    try tmp.dir.createDirPath(io, "elsewhere");
    // a normal path, made as it goes.
    try std.testing.expectEqual(null, try writeChecked(a, root, "etc/motd", "hi", 0o600));
    try std.testing.expectEqualStrings("hi", try tmp.dir.readFileAlloc(io, "root/etc/motd", a, .limited(64)));
    // /lib -> usr/lib, and an absolute link, which stays inside the root.
    try tmp.dir.symLink(io, "usr/lib", "root/lib", .{});
    try tmp.dir.symLink(io, "/usr/lib", "root/abs", .{});
    try std.testing.expectEqual(null, try writeChecked(a, root, "lib/x.conf", "x", null));
    try std.testing.expectEqual(null, try writeChecked(a, root, "abs/y.conf", "y", null));
    try std.testing.expectEqualStrings("x", try tmp.dir.readFileAlloc(io, "root/usr/lib/x.conf", a, .limited(64)));
    try std.testing.expectEqualStrings("y", try tmp.dir.readFileAlloc(io, "root/usr/lib/y.conf", a, .limited(64)));
    // a link out of the root through .. stays in it too: .. at the root is
    // the root.
    try tmp.dir.symLink(io, "../../../../elsewhere", "root/up", .{});
    try std.testing.expectEqual(null, try writeChecked(a, root, "up/z", "z", null));
    try std.testing.expectEqualStrings("z", try tmp.dir.readFileAlloc(io, "root/elsewhere/z", a, .limited(64)));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "elsewhere/z", .{}));
    // a directory others can write to, without the sticky bit, is refused,
    // and nothing's written past it.
    try tmp.dir.createDirPath(io, "root/home/u");
    try tmp.dir.setFilePermissions(io, "root/home/u", @enumFromInt(0o777), .{});
    const why = (try writeChecked(a, root, "home/u/.config/x", "secret", 0o600)).?;
    try std.testing.expect(std.mem.endsWith(u8, why, "others can write to the directory u on the way"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "root/home/u/.config", .{}));
    // a sticky one, like /tmp, is fine.
    try tmp.dir.setFilePermissions(io, "root/home/u", @enumFromInt(0o1777), .{});
    try std.testing.expectEqual(null, try writeChecked(a, root, "home/u/f", "f", null));
    // removing goes through the same checks.
    try std.testing.expectEqual(null, try removeChecked(a, root, "lib/x.conf"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "root/usr/lib/x.conf", .{}));
    try std.testing.expectEqual(null, try removeChecked(a, root, "no/such/dir/f"));
}

test "a symlink another user owns is refused, as root" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "root/home/u");
    try tmp.dir.symLink(io, "/etc", "root/home/u/.config", .{});
    const link = try std.fmt.allocPrintSentinel(a, "{s}/root/home/u/.config", .{base}, 0);
    _ = std.os.linux.fchownat(std.os.linux.AT.FDCWD, link, 1000, 1000, std.os.linux.AT.SYMLINK_NOFOLLOW);
    const why = (try writeChecked(a, try std.fmt.allocPrint(a, "{s}/root", .{base}), "home/u/.config/x", "secret", 0o600)).?;
    try std.testing.expect(std.mem.endsWith(u8, why, ".config on the way is a symlink another user owns"));
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
