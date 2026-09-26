//! btrfs subvolumes, snapshots, and their read-only flag, through btrfs's
//! own ioctls: what generations are built from. paths are absolute and
//! name a subvolume or the directory one goes in.

const std = @import("std");
const linux = std.os.linux;
const IOCTL = linux.IOCTL;

pub const Error = error{
    /// the path isn't on btrfs.
    NotBtrfs,
    AlreadyExists,
    NotFound,
    /// only root can make or remove subvolumes here.
    PermissionDenied,
    NameTooLong,
    /// something still uses it, like a mount.
    Busy,
    Unexpected,
};

const magic = 0x94;
/// BTRFS_SUPER_MAGIC, statfs's f_type for btrfs.
const super_magic = 0x9123683e;
/// a subvolume's top directory always has this inode number.
const first_free_objectid = 256;
const subvol_rdonly: u64 = 1 << 1;

/// btrfs_ioctl_vol_args.
const VolArgs = extern struct {
    fd: i64 = 0,
    name: [4088]u8 = @splat(0),
};

/// btrfs_ioctl_vol_args_v2.
const VolArgsV2 = extern struct {
    fd: i64 = 0,
    transid: u64 = 0,
    flags: u64 = 0,
    unused: [4]u64 = @splat(0),
    name: [4040]u8 = @splat(0),
};

const subvol_create = IOCTL.IOW(magic, 14, VolArgs);
const snap_destroy = IOCTL.IOW(magic, 15, VolArgs);
const snap_create_v2 = IOCTL.IOW(magic, 23, VolArgsV2);
const subvol_getflags = IOCTL.IOR(magic, 25, u64);
const subvol_setflags = IOCTL.IOW(magic, 26, u64);

/// makes an empty subvolume at `path`.
pub fn create(path: []const u8) Error!void {
    var args: VolArgs = .{};
    const parent = try openParent(path, &args.name);
    defer _ = linux.close(parent);
    try check(linux.ioctl(parent, subvol_create, @intFromPtr(&args)));
}

/// snapshots the subvolume at `source` to `dest`, read-only if asked.
pub fn snapshot(source: []const u8, dest: []const u8, read_only: bool) Error!void {
    const src = try open(source);
    defer _ = linux.close(src);
    var args: VolArgsV2 = .{ .fd = src, .flags = if (read_only) subvol_rdonly else 0 };
    const parent = try openParent(dest, &args.name);
    defer _ = linux.close(parent);
    try check(linux.ioctl(parent, snap_create_v2, @intFromPtr(&args)));
}

/// removes the subvolume at `path`, which mustn't hold other subvolumes.
/// a read-only one has to be made writable first.
pub fn delete(path: []const u8) Error!void {
    var args: VolArgs = .{};
    const parent = try openParent(path, &args.name);
    defer _ = linux.close(parent);
    try check(linux.ioctl(parent, snap_destroy, @intFromPtr(&args)));
}

pub fn isReadOnly(path: []const u8) Error!bool {
    const fd = try open(path);
    defer _ = linux.close(fd);
    var flags: u64 = 0;
    try check(linux.ioctl(fd, subvol_getflags, @intFromPtr(&flags)));
    return flags & subvol_rdonly != 0;
}

pub fn setReadOnly(path: []const u8, read_only: bool) Error!void {
    const fd = try open(path);
    defer _ = linux.close(fd);
    var flags: u64 = 0;
    try check(linux.ioctl(fd, subvol_getflags, @intFromPtr(&flags)));
    flags = if (read_only) flags | subvol_rdonly else flags & ~subvol_rdonly;
    try check(linux.ioctl(fd, subvol_setflags, @intFromPtr(&flags)));
}

/// whether `path` is a btrfs subvolume's top directory.
pub fn isSubvolume(path: []const u8) Error!bool {
    const fd = open(path) catch |e| return if (e == error.NotFound) false else e;
    defer _ = linux.close(fd);
    if (!try onBtrfs(fd)) return false;
    var st: linux.Statx = undefined;
    try check(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .INO = true }, &st));
    return st.ino == first_free_objectid;
}

/// whether the filesystem holding `fd` is btrfs.
fn onBtrfs(fd: i32) Error!bool {
    // struct statfs starts with f_type; the rest isn't needed.
    var buf: [120]u8 align(8) = undefined;
    try check(linux.syscall2(.fstatfs, @bitCast(@as(isize, fd)), @intFromPtr(&buf)));
    return std.mem.readInt(i64, buf[0..8], .little) == super_magic;
}

fn open(path: []const u8) Error!i32 {
    var z: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= z.len) return error.NameTooLong;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const rc = linux.open(&z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    try check(rc);
    return @intCast(rc);
}

/// opens the directory `path` goes in, checks it's on btrfs, and copies
/// `path`'s last part into `name`.
fn openParent(path: []const u8, name: []u8) Error!i32 {
    const dir = std.fs.path.dirnamePosix(path) orelse return error.NotFound;
    const base = std.fs.path.basenamePosix(path);
    if (base.len >= name.len) return error.NameTooLong;
    @memcpy(name[0..base.len], base);
    const fd = try open(dir);
    errdefer _ = linux.close(fd);
    if (!try onBtrfs(fd)) return error.NotBtrfs;
    return fd;
}

fn check(rc: usize) Error!void {
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        .EXIST => error.AlreadyExists,
        .NOENT => error.NotFound,
        .PERM, .ACCES, .ROFS => error.PermissionDenied,
        .NAMETOOLONG => error.NameTooLong,
        .BUSY, .NOTEMPTY => error.Busy,
        .NOTTY, .OPNOTSUPP, .INVAL => error.NotBtrfs,
        else => error.Unexpected,
    };
}

// -- tests --

const testing = std.testing;

test "ioctl argument layouts match the kernel's" {
    try testing.expectEqual(4096, @sizeOf(VolArgs));
    try testing.expectEqual(4096, @sizeOf(VolArgsV2));
    try testing.expectEqual(0x5000940e, subvol_create);
    try testing.expectEqual(0x50009417, snap_create_v2);
}

test "not btrfs" {
    try testing.expect(!try isSubvolume("/proc"));
    try testing.expectError(error.NotBtrfs, create("/proc/os-test"));
}

/// a small btrfs filesystem for tests, loop-mounted at a scratch path.
/// needs root and mkfs.btrfs; null means the test should skip.
pub const Scratch = struct {
    dir: []const u8,
    image: []const u8,

    pub fn mount(a: std.mem.Allocator) !?Scratch {
        if (linux.geteuid() != 0) return null;
        const io = testing.io;
        const base = try std.fmt.allocPrint(a, "/tmp/os-btrfs-{d}", .{std.Io.Timestamp.now(io, .real).toNanoseconds()});
        const s: Scratch = .{ .dir = try std.fmt.allocPrint(a, "{s}/mnt", .{base}), .image = try std.fmt.allocPrint(a, "{s}/image", .{base}) };
        try std.Io.Dir.cwd().createDirPath(io, s.dir);
        const exec = @import("exec.zig");
        for ([_][]const []const u8{
            &.{ "truncate", "-s", "256M", s.image },
            &.{ "mkfs.btrfs", "-q", s.image },
            &.{ "mount", "-o", "loop", s.image, s.dir },
        }) |argv| {
            if (try exec.run(a, io, argv)) |why| {
                std.debug.print("no scratch btrfs: {s}\n", .{why});
                return null;
            }
        }
        return s;
    }

    pub fn unmount(s: Scratch, a: std.mem.Allocator) void {
        _ = @import("exec.zig").run(a, testing.io, &.{ "umount", s.dir }) catch {};
        _ = @import("exec.zig").run(a, testing.io, &.{ "rm", "-rf", std.fs.path.dirnamePosix(s.dir).? }) catch {};
    }
};

test "subvolumes, snapshots, and the read-only flag" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try Scratch.mount(a) orelse return error.SkipZigTest;
    defer s.unmount(a);
    const io = testing.io;
    const path = struct {
        fn at(al: std.mem.Allocator, dir: []const u8, rel: []const u8) ![]const u8 {
            return std.fs.path.join(al, &.{ dir, rel });
        }
    }.at;

    const head = try path(a, s.dir, "head");
    try create(head);
    try testing.expect(try isSubvolume(head));
    // a fresh filesystem's top level is a subvolume too.
    try testing.expect(try isSubvolume(s.dir));
    try testing.expectError(error.AlreadyExists, create(head));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try path(a, head, "motd"), .data = "one\n" });

    // a read-only snapshot keeps what head had.
    const gen = try path(a, s.dir, "gen-1");
    try snapshot(head, gen, true);
    try testing.expect(try isSubvolume(gen));
    try testing.expect(try isReadOnly(gen));
    try testing.expect(!try isReadOnly(head));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try path(a, head, "motd"), .data = "two\n" });
    const kept = try std.Io.Dir.cwd().readFileAlloc(io, try path(a, gen, "motd"), a, .limited(64));
    try testing.expectEqualStrings("one\n", kept);
    if (std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try path(a, gen, "new"), .data = "" })) |_| return error.TestUnexpectedResult else |_| {}

    // a writable copy of a generation, and the flag flipped both ways.
    const again = try path(a, s.dir, "head-2");
    try snapshot(gen, again, false);
    try testing.expect(!try isReadOnly(again));
    try setReadOnly(again, true);
    try testing.expect(try isReadOnly(again));
    try setReadOnly(again, false);

    try delete(again);
    try testing.expect(!try isSubvolume(again));
    try setReadOnly(gen, false);
    try delete(gen);
    try testing.expectError(error.NotFound, delete(gen));
}
