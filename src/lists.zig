//! helpers for lists of names: sorting, so every list that ends up in
//! output or a hash is ordered the same way, and lookup.

const std = @import("std");

/// sorts by a string field, like `name`.
pub fn sortByField(comptime T: type, comptime field: []const u8, items: []T) void {
    std.mem.sort(T, items, {}, struct {
        fn lt(_: void, a: T, b: T) bool {
            return std.mem.lessThan(u8, @field(a, field), @field(b, field));
        }
    }.lt);
}

pub fn sortStrings(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
}

test sortByField {
    const P = struct { name: []const u8, n: u8 };
    var items = [_]P{ .{ .name = "b", .n = 1 }, .{ .name = "a", .n = 2 } };
    sortByField(P, "name", &items);
    try std.testing.expectEqual(2, items[0].n);
}

/// the index of the first item whose string `field` equals `key`.
pub fn indexOf(items: anytype, comptime field: []const u8, key: []const u8) ?usize {
    for (items, 0..) |x, i| {
        if (std.mem.eql(u8, @field(x, field), key)) return i;
    }
    return null;
}

/// like `indexOf`, but a pointer to the item.
pub fn find(items: anytype, comptime field: []const u8, key: []const u8) ?@TypeOf(&items[0]) {
    return &items[indexOf(items, field, key) orelse return null];
}

test find {
    const P = struct { name: []const u8, n: u8 };
    var items = [_]P{ .{ .name = "a", .n = 1 }, .{ .name = "b", .n = 2 } };
    try std.testing.expectEqual(2, find(&items, "name", "b").?.n);
    try std.testing.expectEqual(null, find(&items, "name", "c"));
}

pub fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, s)) return true;
    }
    return false;
}

pub fn startsWithAny(s: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, s, p)) return true;
    }
    return false;
}
