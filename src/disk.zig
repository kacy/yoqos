//! reads config files from the real filesystem.

const std = @import("std");
const compose = @import("compose.zig");

pub const max_config_bytes = 1 << 20;

pub const Files = struct {
    io: std.Io,

    pub fn files(d: *Files) compose.Files {
        return .{ .ctx = d, .readFn = read };
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

    const bytes = try f.readFn(f.ctx, std.testing.allocator, path);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("packages = [\"git\"]\n", bytes);
    try std.testing.expectError(error.FileNotFound, f.readFn(f.ctx, std.testing.allocator, "/nonexistent/machine.toml"));
}
