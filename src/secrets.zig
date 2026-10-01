//! secrets: values a managed file holds that stay out of the config and
//! the lock, like a wifi password. `[files."<path>"] secret = "<name>"`
//! names one, and `os secret set <name>` keeps its value here.

const std = @import("std");

/// why `n` can't name a secret, or null if it can: letters, digits, and
/// -_. in parts split by /, none of them empty or starting with a dot.
/// names become paths under the secrets directory, so this keeps them
/// inside it, and away from the machine key, .key.
pub fn nameProblem(n: []const u8) ?[]const u8 {
    const rule = "secret names are letters, digits, -, _, and ., with / to group them, like wifi/home";
    if (n.len == 0 or n.len > 128) return rule;
    var parts = std.mem.splitScalar(u8, n, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or part[0] == '.') return "each part of the name, between the slashes, needs a first character that isn't a dot";
        for (part) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "-_.", ch) == null) return rule;
        }
    }
    return null;
}

const testing = std.testing;

test "secret names" {
    for ([_][]const u8{ "wifi", "wifi/home", "a.b-c_d/e1", "x/y/z" }) |n| try testing.expectEqual(null, nameProblem(n));
    for ([_][]const u8{ "", "/wifi", "wifi/", "a//b", "../x", "a/../b", "a/./b", ".key", "a/.hidden", "has space", "a\nb", "a:b", "a" ** 129 }) |n| {
        try testing.expect(nameProblem(n) != null);
    }
}
