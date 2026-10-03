//! system accounts: the users and groups packages make, below id 1000.
//! their ids end up on files in /var, which never rolls back, while
//! /etc/passwd and /etc/group belong to a generation. so every root yos
//! makes gets the newest root's system accounts it lacks, copied as they
//! are, which keeps an id, once given out, from going to anyone else. and
//! yos keeps a history of every system id it has seen, to say when one
//! changed anyway. this part is pure; gens.zig and apply do the writing.

const std = @import("std");
const lists = @import("lists.zig");
const Allocator = std.mem.Allocator;

/// the ids below this are the system's; people's accounts start here.
pub const first_person = 1000;

pub const Kind = enum { user, group };

/// one account's id, as the history keeps it.
pub const Id = struct {
    kind: Kind,
    name: []const u8,
    id: u32,
};

/// the system accounts in passwd or group text: name, and the uid or gid
/// in the third field.
pub fn parse(a: Allocator, text: []const u8, kind: Kind) ![]Id {
    var out: std.ArrayList(Id) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const e = entry(line) orelse continue;
        if (e.id < first_person) try out.append(a, .{ .kind = kind, .name = e.name, .id = e.id });
    }
    return out.items;
}

const Entry = struct { name: []const u8, id: u32 };

fn entry(line: []const u8) ?Entry {
    var f = std.mem.splitScalar(u8, line, ':');
    const name = f.next() orelse return null;
    if (name.len == 0 or name[0] == '#') return null;
    _ = f.next() orelse return null;
    return .{ .name = name, .id = std.fmt.parseInt(u32, f.next() orelse return null, 10) catch return null };
}

pub const Merged = struct {
    text: []const u8,
    /// the accounts that came from `current`.
    added: []const []const u8,
};

/// `target`'s passwd or group with every system account from `current`
/// that it lacks, copied line for line, home, shell, and all. one whose id
/// `target` already gives to someone else stays out: the id is theirs
/// there.
pub fn merge(a: Allocator, current: []const u8, target: []const u8) !Merged {
    var out: std.ArrayList(u8) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var ids: std.ArrayList(u32) = .empty;
    const trimmed = std.mem.trimEnd(u8, target, "\n");
    if (trimmed.len > 0) try out.print(a, "{s}\n", .{trimmed});
    var theirs = std.mem.splitScalar(u8, trimmed, '\n');
    while (theirs.next()) |line| {
        const e = entry(line) orelse continue;
        try names.append(a, e.name);
        try ids.append(a, e.id);
    }
    var added: std.ArrayList([]const u8) = .empty;
    var ours = std.mem.splitScalar(u8, current, '\n');
    while (ours.next()) |line| {
        const e = entry(line) orelse continue;
        if (e.id >= first_person) continue;
        if (lists.contains(names.items, e.name) or std.mem.indexOfScalar(u32, ids.items, e.id) != null) continue;
        try out.print(a, "{s}\n", .{line});
        try names.append(a, e.name);
        try ids.append(a, e.id);
        try added.append(a, e.name);
    }
    return .{ .text = out.items, .added = added.items };
}

/// shadow or gshadow `target` with lines for `names` it lacks: `current`'s
/// line for each, or a locked one with `empty` fields after the name and
/// password.
pub fn addLines(a: Allocator, target: []const u8, current: []const u8, names: []const []const u8, empty: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const trimmed = std.mem.trimEnd(u8, target, "\n");
    if (trimmed.len > 0) try out.print(a, "{s}\n", .{trimmed});
    for (names) |n| {
        if (lineFor(trimmed, n) != null) continue;
        if (lineFor(current, n)) |line| {
            try out.print(a, "{s}\n", .{line});
        } else {
            try out.print(a, "{s}:!*", .{n});
            for (0..empty) |_| try out.append(a, ':');
            try out.append(a, '\n');
        }
    }
    return out.items;
}

fn lineFor(text: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len > name.len and std.mem.startsWith(u8, line, name) and line[name.len] == ':') return line;
    }
    return null;
}

/// where yos keeps every system id it has seen, under a root.
pub const history_path = "var/lib/yos/system-ids";

/// the system accounts in a root's passwd and group files.
pub fn systemIds(a: Allocator, passwd: []const u8, group: []const u8) ![]Id {
    return std.mem.concat(a, Id, &.{ try parse(a, passwd, .user), try parse(a, group, .group) });
}

/// the history file's lines: "user postgres 971".
pub fn parseHistory(a: Allocator, text: []const u8) ![]Id {
    var out: std.ArrayList(Id) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var w = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = std.meta.stringToEnum(Kind, w.next() orelse continue) orelse continue;
        const name = w.next() orelse continue;
        const id = std.fmt.parseInt(u32, w.next() orelse continue, 10) catch continue;
        try out.append(a, .{ .kind = kind, .name = name, .id = id });
    }
    return out.items;
}

/// the lines to add to the history for `now`: each account whose name and
/// id it doesn't have together yet.
pub fn newHistory(a: Allocator, history: []const Id, now: []const Id) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (now) |s| {
        const known = for (history) |h| {
            if (h.kind == s.kind and h.id == s.id and std.mem.eql(u8, h.name, s.name)) break true;
        } else false;
        if (!known) try out.print(a, "{s} {s} {d}\n", .{ @tagName(s.kind), s.name, s.id });
    }
    return out.items;
}

/// what's different from the history: a system account whose id isn't
/// the one it first had, or an id that went to another name. each is a
/// sentence for `yos status`.
pub fn changes(a: Allocator, history: []const Id, now: []const Id) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (now) |s| {
        for (history) |h| {
            if (h.kind != s.kind) continue;
            const kind = @tagName(s.kind);
            if (std.mem.eql(u8, h.name, s.name) and h.id != s.id) {
                try out.append(a, try std.fmt.allocPrint(a, "{s} {s} is {d}, but was {d}", .{ kind, s.name, s.id, h.id }));
                break;
            }
            if (h.id == s.id and !std.mem.eql(u8, h.name, s.name) and firstFor(history, h) == h.id) {
                try out.append(a, try std.fmt.allocPrint(a, "{s} {s} has {d}, which was {s}'s", .{ kind, s.name, s.id, h.name }));
                break;
            }
        }
    }
    return out.items;
}

/// the id `h`'s name first had, which is the one it keeps.
fn firstFor(history: []const Id, h: Id) u32 {
    for (history) |x| {
        if (x.kind == h.kind and std.mem.eql(u8, x.name, h.name)) return x.id;
    }
    return h.id;
}

// -- tests --

const testing = std.testing;

test "a root gets the system accounts it lacks, and keeps its own ids" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const current =
        \\root:x:0:0::/root:/usr/bin/bash
        \\postgres:x:971:971:PostgreSQL user:/var/lib/postgres:/bin/bash
        \\dnsmasq:x:970:970::/:/usr/bin/nologin
        \\kacy:x:1000:1000::/home/kacy:/usr/bin/zsh
        \\
    ;
    const target =
        \\root:x:0:0::/root:/usr/bin/bash
        \\docker:x:970:970::/:/usr/bin/nologin
        \\
    ;
    const m = try merge(a, current, target);
    try testing.expectEqualStrings(
        \\root:x:0:0::/root:/usr/bin/bash
        \\docker:x:970:970::/:/usr/bin/nologin
        \\postgres:x:971:971:PostgreSQL user:/var/lib/postgres:/bin/bash
        \\
    , m.text);
    try testing.expectEqual(1, m.added.len);
    try testing.expectEqualStrings("postgres", m.added[0]);
    // shadow lines come along, or locked ones if there were none.
    try testing.expectEqualStrings("root:!:::::::\npostgres:!*:::::::\n", try addLines(a, "root:!:::::::\n", "", m.added, 7));
    try testing.expectEqualStrings("root:x::\npostgres:!::\n", try addLines(a, "root:x::\n", "postgres:!::\n", m.added, 2));
}

test "the history of system ids, and what changed from it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const history = try parseHistory(a, "user postgres 971\ngroup postgres 971\n");
    const seen = try parse(a, "postgres:x:970:970::/:/bin/bash\ndocker:x:971:971::/:/usr/bin/nologin\nkacy:x:1000:1000::/:/bin/sh\n", .user);
    try testing.expectEqual(2, seen.len);
    try testing.expectEqualStrings("user postgres 970\nuser docker 971\n", try newHistory(a, history, seen));
    const c = try changes(a, history, seen);
    try testing.expectEqual(2, c.len);
    try testing.expectEqualStrings("user postgres is 970, but was 971", c[0]);
    try testing.expectEqualStrings("user docker has 971, which was postgres's", c[1]);
    try testing.expectEqual(0, (try changes(a, history, try parse(a, "postgres:x:971:971::/:/bin/bash\n", .user))).len);
}
