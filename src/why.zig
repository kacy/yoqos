//! `os why <package>`: which line of the config makes a package part of the
//! machine. a package is either asked for (in `packages`, or implied by a
//! service or hardware choice) or pulled in by one that is, and then the
//! answer is the shortest dependency chain back to something asked for.

const std = @import("std");
const config = @import("config.zig");
const lock = @import("lock.zig");
const planner = @import("planner.zig");
const output = @import("output.zig");
const lists = @import("lists.zig");
const Allocator = std.mem.Allocator;

pub const schema = "yoq.why/1";

pub const Answer = struct {
    package: []const u8,
    /// the package the config asks for that brings this one in. it's this
    /// package itself when the config asks for it directly.
    root: ?planner.Want,
    /// from `root` down to `package`. just the package when asked for directly.
    chain: []const []const u8,
    /// needed packages that depend on this one directly.
    needed_by: []const []const u8,
};

pub fn explain(a: Allocator, c: *const config.Config, l: *const lock.Lock, name: []const u8) !Answer {
    const ws = try planner.wants(a, c);
    var answer: Answer = .{ .package = name, .root = null, .chain = &.{}, .needed_by = &.{} };
    if (planner.findWant(ws, name)) |w| {
        answer.root = w.*;
        answer.chain = try a.dupe([]const u8, &.{name});
    }
    const needed = try planner.closure(a, l, ws);
    if (!needed.contains(name)) return answer;

    var parents: std.ArrayList([]const u8) = .empty;
    for (needed.keys()) |n| {
        for (l.package(n).?.depends) |d| {
            if (std.mem.eql(u8, d, name)) try parents.append(a, n);
        }
    }
    lists.sortStrings(parents.items);
    answer.needed_by = parents.items;
    if (answer.root != null) return answer;

    // breadth-first from the wanted packages finds the shortest chain.
    var came_from: std.StringHashMapUnmanaged([]const u8) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;
    for (ws) |w| {
        if (l.package(w.name) == null) continue;
        try came_from.put(a, w.name, "");
        try queue.append(a, w.name);
    }
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        if (std.mem.eql(u8, cur, name)) break;
        for (l.package(cur).?.depends) |d| {
            if (came_from.contains(d)) continue;
            try came_from.put(a, d, cur);
            try queue.append(a, d);
        }
    }
    var chain: std.ArrayList([]const u8) = .empty;
    var at = name;
    while (at.len > 0) : (at = came_from.get(at).?) try chain.append(a, at);
    std.mem.reverse([]const u8, chain.items);
    answer.chain = chain.items;
    answer.root = planner.findWant(ws, chain.items[0]).?.*;
    return answer;
}

pub fn writeText(w: *std.Io.Writer, ans: *const Answer) !void {
    const root = ans.root orelse {
        try w.print("{s}: nothing in the config needs it\n", .{ans.package});
        return;
    };
    if (ans.chain.len > 1) {
        try w.print("{s}: needed by ", .{ans.package});
        for (ans.chain, 0..) |n, i| {
            if (i > 0) try w.writeAll(" -> ");
            try w.writeAll(n);
        }
        try w.writeByte('\n');
    }
    try w.print("{s}: ", .{root.name});
    if (root.cause) |cause| try w.print("from {s}", .{cause}) else try w.writeAll("in packages");
    if (root.src) |s| {
        try w.print("  ({s}:{d})\n", .{ s.file, s.line });
    } else {
        try w.writeAll("  (the default)\n");
    }
    if (ans.needed_by.len > 1) {
        try w.print("also needed by {d} more: ", .{ans.needed_by.len - 1});
        var first = true;
        for (ans.needed_by) |n| {
            if (ans.chain.len > 1 and std.mem.eql(u8, n, ans.chain[ans.chain.len - 2])) continue;
            if (!first) try w.writeAll(", ");
            first = false;
            try w.writeAll(n);
        }
        try w.writeByte('\n');
    }
}

pub fn writeJson(w: *std.Io.Writer, ans: *const Answer) !void {
    const Root = struct { name: []const u8, cause: ?[]const u8, file: ?[]const u8, line: ?u32 };
    const root: ?Root = if (ans.root) |r| .{
        .name = r.name,
        .cause = r.cause,
        .file = if (r.src) |s| s.file else null,
        .line = if (r.src) |s| s.line else null,
    } else null;
    try output.writeDoc(w, schema, .{
        .package = ans.package,
        .needed = ans.root != null,
        .root = root,
        .chain = ans.chain,
        .needed_by = ans.needed_by,
    });
}

// -- tests --

const testing = std.testing;

fn lockPkg(name: []const u8, depends: []const []const u8) lock.Package {
    return .{ .name = name, .version = "1", .repo = "core", .sha256 = "a" ** 64, .depends = depends };
}

const test_lock: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{
    lockPkg("curl", &.{ "glibc", "openssl" }),
    lockPkg("git", &.{ "curl", "glibc", "perl-error" }),
    lockPkg("glibc", &.{}),
    lockPkg("linux", &.{}),
    lockPkg("openssh", &.{ "glibc", "openssl" }),
    lockPkg("openssl", &.{"glibc"}),
    lockPkg("perl", &.{"glibc"}),
    lockPkg("perl-error", &.{"perl"}),
} };

fn run(src: []const u8, name: []const u8) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags: @import("diag.zig").List = .init(testing.allocator);
    defer diags.deinit();
    var info: @import("toml.zig").ErrorInfo = .{};
    var doc = try @import("toml.zig").parse(testing.allocator, src, &info);
    defer doc.deinit();
    const part = try config.decode(a, "machine.toml", doc.root, &diags);
    const ans = try explain(a, &part.config, &test_lock, name);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    try writeText(&out.writer, &ans);
    return out.toOwnedSlice();
}

fn expectWhy(src: []const u8, name: []const u8, want: []const u8) !void {
    const got = try run(src, name);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

const cfg = "packages = [\"git\"]\n[services]\nssh = true\n";

test "asked for directly" {
    try expectWhy(cfg, "git", "git: in packages  (machine.toml:1)\n");
}

test "implied by a service or the default kernel" {
    try expectWhy(cfg, "openssh", "openssh: from services.ssh  (machine.toml:3)\n");
    try expectWhy(cfg, "linux", "linux: from boot.kernel  (the default)\n");
}

test "a dependency takes the shortest chain" {
    try expectWhy(cfg, "perl",
        \\perl: needed by git -> perl-error -> perl
        \\git: in packages  (machine.toml:1)
        \\
    );
}

test "shared dependencies list their other dependents" {
    try expectWhy(cfg, "openssl",
        \\openssl: needed by openssh -> openssl
        \\openssh: from services.ssh  (machine.toml:3)
        \\also needed by 1 more: curl
        \\
    );
}

test "nothing needs it" {
    try expectWhy(cfg, "nano", "nano: nothing in the config needs it\n");
    try expectWhy("packages = [\"git\"]\n", "openssh", "openssh: nothing in the config needs it\n");
}
