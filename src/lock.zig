//! machine.lock: exactly what the config resolved to. os writes it and reads
//! it back; nobody edits it by hand.
//!
//! the format is plain toml laid out for readable diffs: one table per
//! package, sorted by name, so an upgrade shows up as a changed `version`
//! line under the package it touched.

const std = @import("std");
const toml = @import("toml.zig");
const diag = @import("diag.zig");
const Allocator = std.mem.Allocator;

pub const format_version = 1;

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    repo: []const u8,
    sha256: []const u8,
    /// names of the packages this one depends on, as resolved: a
    /// dependency on a virtual package names the provider that was picked.
    depends: []const []const u8 = &.{},
};

pub const Provider = struct {
    name: []const u8,
    chosen: []const u8,
};

pub const Lock = struct {
    /// the arch package date this lock was resolved against, "yyyy-mm-dd".
    sync_date: []const u8,
    /// the archlinux-keyring version used to check signatures.
    keyring: []const u8,
    /// sorted by name.
    providers: []const Provider = &.{},
    /// sorted by name.
    packages: []const Package = &.{},

    pub fn package(l: *const Lock, name: []const u8) ?*const Package {
        const i = std.sort.binarySearch(Package, l.packages, name, struct {
            fn cmp(n: []const u8, p: Package) std.math.Order {
                return std.mem.order(u8, n, p.name);
            }
        }.cmp) orelse return null;
        return &l.packages[i];
    }
};

pub fn write(w: *std.Io.Writer, l: *const Lock) !void {
    try w.print("# machine.lock: written by os. don't edit it by hand.\nversion = {d}\nsync_date = ", .{format_version});
    try toml.writeString(w, l.sync_date);
    try w.writeAll("\nkeyring = ");
    try toml.writeString(w, l.keyring);
    try w.writeByte('\n');

    if (l.providers.len > 0) {
        try w.writeAll("\n[providers]\n");
        for (l.providers) |p| {
            try toml.writeKey(w, p.name);
            try w.writeAll(" = ");
            try toml.writeString(w, p.chosen);
            try w.writeByte('\n');
        }
    }

    for (l.packages) |p| {
        try w.writeAll("\n[packages.");
        try toml.writeKey(w, p.name);
        try w.writeAll("]\nversion = ");
        try toml.writeString(w, p.version);
        try w.writeAll("\nrepo = ");
        try toml.writeString(w, p.repo);
        try w.writeAll("\nsha256 = ");
        try toml.writeString(w, p.sha256);
        try w.writeByte('\n');
        if (p.depends.len > 0) {
            try w.writeAll("depends = [");
            for (p.depends, 0..) |d, i| {
                if (i > 0) try w.writeAll(", ");
                try toml.writeString(w, d);
            }
            try w.writeAll("]\n");
        }
    }
}

/// sorts packages, providers, and each dependency list, so equal locks
/// write identical files.
pub fn normalize(a: Allocator, l: *Lock) !void {
    const pkgs = try a.dupe(Package, l.packages);
    std.mem.sort(Package, pkgs, {}, struct {
        fn lt(_: void, x: Package, y: Package) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    for (pkgs) |*p| {
        const deps = try a.dupe([]const u8, p.depends);
        std.mem.sort([]const u8, deps, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        p.depends = deps;
    }
    l.packages = pkgs;
    const provs = try a.dupe(Provider, l.providers);
    std.mem.sort(Provider, provs, {}, struct {
        fn lt(_: void, x: Provider, y: Provider) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    l.providers = provs;
}

/// reads a lock file. problems go to `diags` as E0120 and the result is
/// null. strings are allocated in `a`, which should be an arena.
pub fn parse(a: Allocator, path: []const u8, bytes: []const u8, diags: *diag.List) !?Lock {
    var info: toml.ErrorInfo = .{};
    var doc = toml.parse(a, bytes, &info) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => {
            try diags.add(.lock_invalid, .{ .file = path, .line = info.pos.line, .column = info.pos.column }, "{s}", .{info.message()}, null);
            return null;
        },
    };
    defer doc.deinit();

    var r: Reader = .{ .a = a, .path = path, .diags = diags };
    const root = doc.root;
    const version = r.int(root, "version", null) orelse return null;
    if (version != format_version) return r.bad(null, "lock format {d} isn't supported", .{version});
    var l: Lock = .{
        .sync_date = try r.str(root, "sync_date", null) orelse return null,
        .keyring = try r.str(root, "keyring", null) orelse return null,
    };

    var providers: std.ArrayList(Provider) = .empty;
    if (root.get("providers")) |pv| {
        const t = try r.table(pv, "providers") orelse return null;
        for (t.entries.items) |*e| {
            if (e.value.data != .string) return r.bad(e.value.span, "providers.{s} should be a string", .{e.key});
            try providers.append(a, .{ .name = try a.dupe(u8, e.key), .chosen = try a.dupe(u8, e.value.data.string) });
        }
    }
    l.providers = providers.items;

    var packages: std.ArrayList(Package) = .empty;
    if (root.get("packages")) |pv| {
        const t = try r.table(pv, "packages") orelse return null;
        for (t.entries.items) |*e| {
            const pt = try r.table(&e.value, e.key) orelse return null;
            var p: Package = .{
                .name = try a.dupe(u8, e.key),
                .version = try r.str(pt, "version", e.key) orelse return null,
                .repo = try r.str(pt, "repo", e.key) orelse return null,
                .sha256 = try r.str(pt, "sha256", e.key) orelse return null,
            };
            if (!validSha256(p.sha256)) return r.bad(pt.get("sha256").?.span, "packages.{s}.sha256 isn't a sha-256 hash", .{e.key});
            if (pt.get("depends")) |dv| {
                if (dv.data != .array) return r.bad(dv.span, "packages.{s}.depends should be a list", .{e.key});
                var deps: std.ArrayList([]const u8) = .empty;
                for (dv.data.array.items.items) |d| {
                    if (d.data != .string) return r.bad(d.span, "packages.{s}.depends should only hold names", .{e.key});
                    try deps.append(a, try a.dupe(u8, d.data.string));
                }
                p.depends = deps.items;
            }
            for (pt.entries.items) |*f| {
                if (!oneOf(f.key, &.{ "version", "repo", "sha256", "depends" })) return r.bad(f.key_span, "unknown key packages.{s}.{s}", .{ e.key, f.key });
            }
            try packages.append(a, p);
        }
    }
    l.packages = packages.items;
    for (root.entries.items) |*e| {
        if (!oneOf(e.key, &.{ "version", "sync_date", "keyring", "providers", "packages" })) return r.bad(e.key_span, "unknown key {s}", .{e.key});
    }

    try normalize(a, &l);
    for (l.packages) |p| {
        for (p.depends) |d| {
            if (l.package(d) == null) return r.bad(null, "{s} depends on {s}, which isn't in the lock", .{ p.name, d });
        }
    }
    return l;
}

fn oneOf(s: []const u8, options: []const []const u8) bool {
    for (options) |o| {
        if (std.mem.eql(u8, s, o)) return true;
    }
    return false;
}

fn validSha256(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

const Reader = struct {
    a: Allocator,
    path: []const u8,
    diags: *diag.List,
    failed: bool = false,

    fn bad(r: *Reader, span: ?toml.Span, comptime fmt: []const u8, args: anytype) !?Lock {
        const at: ?diag.Span = if (span) |s| .{ .file = r.path, .line = s.start.line, .column = s.start.column } else .{ .file = r.path, .line = 1, .column = 1 };
        try r.diags.add(.lock_invalid, at, fmt, args, "restore it from git or run `os update`");
        return null;
    }

    fn table(r: *Reader, v: *const toml.Value, name: []const u8) !?*const toml.Table {
        if (v.data == .table) return v.data.table;
        _ = try r.bad(v.span, "{s} should be a table", .{name});
        return null;
    }

    fn int(r: *Reader, t: *const toml.Table, key: []const u8, owner: ?[]const u8) ?i64 {
        const v = t.get(key) orelse {
            r.missing(key, owner);
            return null;
        };
        if (v.data == .integer) return v.data.integer;
        r.wrong(v.span, key, owner, "an integer");
        return null;
    }

    fn str(r: *Reader, t: *const toml.Table, key: []const u8, owner: ?[]const u8) !?[]const u8 {
        const v = t.get(key) orelse {
            r.missing(key, owner);
            return null;
        };
        if (v.data == .string) return try r.a.dupe(u8, v.data.string);
        r.wrong(v.span, key, owner, "a string");
        return null;
    }

    fn missing(r: *Reader, key: []const u8, owner: ?[]const u8) void {
        if (owner) |o| {
            _ = r.bad(null, "packages.{s} has no {s}", .{ o, key }) catch {};
        } else {
            _ = r.bad(null, "the lock has no {s}", .{key}) catch {};
        }
    }

    fn wrong(r: *Reader, span: toml.Span, key: []const u8, owner: ?[]const u8, want: []const u8) void {
        if (owner) |o| {
            _ = r.bad(span, "packages.{s}.{s} should be {s}", .{ o, key, want }) catch {};
        } else {
            _ = r.bad(span, "{s} should be {s}", .{ key, want }) catch {};
        }
    }
};

// -- tests --

const testing = std.testing;

const hash_a = "a" ** 64;
const hash_b = "0123456789abcdef" ** 4;

const example =
    \\# machine.lock: written by os. don't edit it by hand.
    \\version = 1
    \\sync_date = "2026-09-25"
    \\keyring = "20260901-1"
    \\
    \\[providers]
    \\java-runtime = "jre-openjdk"
    \\
    \\[packages.git]
    \\version = "2.51.0-1"
    \\repo = "extra"
    \\sha256 = "
++ hash_a ++
    \\"
    \\depends = ["glibc", "perl-error"]
    \\
    \\[packages.glibc]
    \\version = "2.42-1"
    \\repo = "core"
    \\sha256 = "
++ hash_b ++
    \\"
    \\
    \\[packages.perl-error]
    \\version = "0.17030-2"
    \\repo = "extra"
    \\sha256 = "
++ hash_a ++
    \\"
    \\depends = ["glibc"]
    \\
;

test "parse and write round-trip exactly" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: diag.List = .init(testing.allocator);
    defer diags.deinit();

    const l = (try parse(arena.allocator(), "machine.lock", example, &diags)).?;
    try testing.expectEqual(0, diags.items.items.len);
    try testing.expectEqualStrings("2026-09-25", l.sync_date);
    try testing.expectEqual(3, l.packages.len);
    try testing.expectEqualStrings("2.42-1", l.package("glibc").?.version);
    try testing.expectEqual(null, l.package("vim"));
    try testing.expectEqualStrings("jre-openjdk", l.providers[0].chosen);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, &l);
    try testing.expectEqualStrings(example, out.written());
}

test "normalize makes writing order-independent" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var l: Lock = .{
        .sync_date = "2026-09-25",
        .keyring = "1",
        .packages = &.{
            .{ .name = "zsh", .version = "5.9-5", .repo = "extra", .sha256 = hash_a, .depends = &.{ "pcre2", "gdbm" } },
            .{ .name = "gdbm", .version = "1.26-1", .repo = "core", .sha256 = hash_a },
            .{ .name = "pcre2", .version = "10.45-1", .repo = "core", .sha256 = hash_a },
        },
    };
    try normalize(arena.allocator(), &l);
    try testing.expectEqualStrings("gdbm", l.packages[0].name);
    try testing.expectEqualStrings("gdbm", l.packages[2].depends[0]);
}

fn expectBad(src: []const u8, message: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: diag.List = .init(testing.allocator);
    defer diags.deinit();
    try testing.expectEqual(null, try parse(arena.allocator(), "machine.lock", src, &diags));
    try testing.expect(diags.items.items.len > 0);
    try testing.expectEqual(diag.Code.lock_invalid, diags.items.items[0].code);
    try testing.expectEqualStrings(message, diags.items.items[0].message);
}

test "damaged locks are rejected with a reason" {
    const head = "version = 1\nsync_date = \"2026-09-25\"\nkeyring = \"1\"\n";
    try expectBad("version = 1\n", "the lock has no sync_date");
    try expectBad("version = 2\n", "lock format 2 isn't supported");
    try expectBad(head ++ "[packages.git]\nversion = \"1\"\nrepo = \"core\"\n", "packages.git has no sha256");
    try expectBad(head ++ "[packages.git]\nversion = \"1\"\nrepo = \"core\"\nsha256 = \"abc\"\n", "packages.git.sha256 isn't a sha-256 hash");
    try expectBad(head ++ "[packages.git]\nversion = 1\n", "packages.git.version should be a string");
    try expectBad(head ++ "[packages.git]\nversion = \"1\"\nrepo = \"core\"\nsha256 = \"" ++ hash_a ++ "\"\ndepends = [\"gone\"]\n", "git depends on gone, which isn't in the lock");
    try expectBad(head ++ "<<<<<<< HEAD\n", "expected a key, found '<'");
    try expectBad(head ++ "extra = 1\n", "unknown key extra");
}
