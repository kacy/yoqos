//! reads config files from the real filesystem.

const std = @import("std");
const compose = @import("compose.zig");
const rootfs = @import("rootfs.zig");

const max_config_bytes = 1 << 20;

pub const Files = struct {
    io: std.Io,

    pub fn files(d: *Files) compose.Files {
        return .{ .ctx = d, .readFn = read, .writeFn = write, .readBelowFn = readBelow };
    }

    fn readBelow(ctx: *anyopaque, gpa: std.mem.Allocator, dir: []const u8, rel: []const u8) compose.Files.BelowError![]u8 {
        const d: *Files = @ptrCast(@alignCast(ctx));
        const linux = std.os.linux;
        var parent = std.Io.Dir.cwd().openDir(d.io, dir, .{}) catch |e| return switch (e) {
            error.FileNotFound => error.FileNotFound,
            else => error.ReadFailed,
        };
        defer parent.close(d.io);
        const how: extern struct { flags: u64, mode: u64, resolve: u64 } = .{
            .flags = @as(u32, @bitCast(linux.O{ .ACCMODE = .RDONLY, .CLOEXEC = true })),
            .mode = 0,
            .resolve = 0x04, // RESOLVE_NO_SYMLINKS
        };
        const relz = try gpa.dupeZ(u8, rel);
        defer gpa.free(relz);
        const rc = linux.syscall4(.openat2, @bitCast(@as(isize, parent.handle)), @intFromPtr(relz.ptr), @intFromPtr(&how), @sizeOf(@TypeOf(how)));
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .NOENT => return error.FileNotFound,
            .LOOP => return error.Symlink,
            else => return error.ReadFailed,
        }
        const f: std.Io.File = .{ .handle = @intCast(rc), .flags = .{ .nonblocking = false } };
        defer f.close(d.io);
        var buf: [4096]u8 = undefined;
        var fr = f.readerStreaming(d.io, &buf);
        return fr.interface.allocRemaining(gpa, .limited(max_config_bytes)) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ReadFailed,
        };
    }

    fn write(ctx: *anyopaque, path: []const u8, bytes: []const u8) compose.Files.WriteError!void {
        const d: *Files = @ptrCast(@alignCast(ctx));
        return rootfs.writeAtomic(d.io, path, bytes, null);
    }

    fn read(ctx: *anyopaque, gpa: std.mem.Allocator, path: []const u8) compose.Files.ReadError![]u8 {
        const d: *Files = @ptrCast(@alignCast(ctx));
        return std.Io.Dir.cwd().readFileAlloc(d.io, path, gpa, .limited(max_config_bytes)) catch |e| switch (e) {
            error.FileNotFound => error.FileNotFound,
            error.OutOfMemory => error.OutOfMemory,
            else => error.ReadFailed,
        };
    }
};

test "reads a file and reports a missing one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "machine.toml", .data = "packages = [\"git\"]\n" });

    var d: Files = .{ .io = std.testing.io };
    const f = d.files();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/machine.toml", .{tmp.sub_path});
    defer std.testing.allocator.free(path);

    const bytes = try f.read(std.testing.allocator, path);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("packages = [\"git\"]\n", bytes);

    try f.write(path, "packages = []\n");
    const again = try f.read(std.testing.allocator, path);
    defer std.testing.allocator.free(again);
    try std.testing.expectEqualStrings("packages = []\n", again);
    try std.testing.expectError(error.FileNotFound, f.read(std.testing.allocator, "/nonexistent/machine.toml"));
    // a directory can't be made under a file, even by root.
    const under_file = try std.fmt.allocPrint(std.testing.allocator, "{s}/nested", .{path});
    defer std.testing.allocator.free(under_file);
    try std.testing.expectError(error.WriteFailed, f.write(under_file, "x"));

    // missing parent directories are made, which `os init` relies on.
    const deep = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/etc/yoq/machine.toml", .{tmp.sub_path});
    defer std.testing.allocator.free(deep);
    try f.write(deep, "version = 1\n");
}

test "a source below the config can't go through a symlink" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "files");
    try tmp.dir.writeFile(io, .{ .sub_path = "files/motd", .data = "hi\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "secret", .data = "hash\n" });
    try tmp.dir.symLink(io, "../secret", "files/link", .{});
    try tmp.dir.symLink(io, "files", "dir-link", .{});

    var d: Files = .{ .io = io };
    const f = d.files();
    const gpa = std.testing.allocator;
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);
    const got = try f.readBelow(gpa, dir, "files/motd");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hi\n", got);
    try std.testing.expectError(error.Symlink, f.readBelow(gpa, dir, "files/link"));
    try std.testing.expectError(error.Symlink, f.readBelow(gpa, dir, "dir-link/motd"));
    try std.testing.expectError(error.FileNotFound, f.readBelow(gpa, dir, "files/gone"));
}
