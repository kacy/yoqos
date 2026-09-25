//! small helpers shared by tests in more than one file.

const std = @import("std");
const config = @import("config.zig");
const diag = @import("diag.zig");
const lock = @import("lock.zig");
const toml = @import("toml.zig");

/// a config from toml text, allocated in `a`. fails the test if the text
/// has problems.
pub fn configFrom(a: std.mem.Allocator, text: []const u8) !config.Config {
    var diags: diag.List = .init(std.testing.allocator);
    defer diags.deinit();
    var info: toml.ErrorInfo = .{};
    var doc = try toml.parse(std.testing.allocator, text, &info);
    defer doc.deinit();
    const part = try config.decode(a, "machine.toml", doc.root, &diags);
    try std.testing.expectEqual(0, diags.items.items.len);
    return part.config;
}

/// a locked package with a placeholder repo and hash.
pub fn lockPackage(name: []const u8, version: []const u8, depends: []const []const u8) lock.Package {
    return .{ .name = name, .version = version, .repo = "core", .sha256 = "a" ** 64, .depends = depends };
}
