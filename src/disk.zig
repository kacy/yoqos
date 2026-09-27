//! reads config files from the real filesystem.

const std = @import("std");
const compose = @import("compose.zig");
const rootfs = @import("rootfs.zig");

const max_config_bytes = 1 << 20;

pub const Files = struct {
    io: std.Io,

    pub fn files(d: *Files) compose.Files {
        return .{ .ctx = d, .readFn = read, .writeFn = write };
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
