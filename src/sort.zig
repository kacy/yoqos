//! sorting helpers, so every list that ends up in output or a hash is
//! ordered the same way.

const std = @import("std");

/// sorts by a string field, like `name`.
pub fn byField(comptime T: type, comptime field: []const u8, items: []T) void {
    std.mem.sort(T, items, {}, struct {
        fn lt(_: void, a: T, b: T) bool {
            return std.mem.lessThan(u8, @field(a, field), @field(b, field));
        }
    }.lt);
}

pub fn strings(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
}

test byField {
    const P = struct { name: []const u8, n: u8 };
    var items = [_]P{ .{ .name = "b", .n = 1 }, .{ .name = "a", .n = 2 } };
    byField(P, "name", &items);
    try std.testing.expectEqual(2, items[0].n);
}
