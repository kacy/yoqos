//! reads config files from the real filesystem.

const std = @import("std");
const compose = @import("compose.zig");

pub const max_config_bytes = 1 << 20;

pub const Files = struct {
    io: std.Io,

    pub fn files(d: *Files) compose.Files {
        return .{ .ctx = d, .readFn = read, .writeFn = write };
    }

    /// writes next to the target, then renames over it.
    fn write(ctx: *anyopaque, path: []const u8, bytes: []const u8) compose.Files.WriteError!void {
        const d: *Files = @ptrCast(@alignCast(ctx));
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp = std.fmt.bufPrint(&buf, "{s}.os-tmp", .{path}) catch return error.WriteFailed;
        const cwd = std.Io.Dir.cwd();
        cwd.writeFile(d.io, .{ .sub_path = tmp, .data = bytes }) catch return error.WriteFailed;
        cwd.rename(tmp, cwd, path, d.io) catch {
            cwd.deleteFile(d.io, tmp) catch {};
            return error.WriteFailed;
        };
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
    try std.testing.expectError(error.WriteFailed, f.write("/nonexistent/machine.toml", "x"));
}
