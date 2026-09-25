//! diagnostics. every error a user can hit has a stable code, a message,
//! where it happened, and usually a hint. `os explain <code>` prints the long
//! form from `table`.
//!
//! codes are grouped by area: E00xx toml, E01xx config, E02xx services and
//! packages. once a code ships it keeps its number and meaning.

const std = @import("std");
const output = @import("output.zig");

pub const Code = enum {
    toml_syntax,
    toml_unsupported,
    toml_duplicate_key,
    config_missing,
    unknown_key,
    wrong_type,
    bad_value,
    include_missing,
    include_cycle,
    lock_invalid,
    lock_stale,
    unresolvable,
    provider_choice,
    alpm_failed,
    unknown_service,
};

pub const Entry = struct {
    code: Code,
    id: []const u8,
    title: []const u8,
    explanation: []const u8,
};

/// one entry per `Code`, in the same order.
pub const table = [_]Entry{
    .{
        .code = .toml_syntax,
        .id = "E0001",
        .title = "toml syntax error",
        .explanation = "the file isn't valid toml. the message says what the parser expected and where. " ++
            "a common cause is a missing quote around a string value, like `hostname = atlas` instead of " ++
            "`hostname = \"atlas\"`.",
    },
    .{
        .code = .toml_unsupported,
        .id = "E0002",
        .title = "unsupported toml feature",
        .explanation = "the file uses a toml feature os doesn't read yet, such as a date or time value. " ++
            "write the value as a string instead.",
    },
    .{
        .code = .toml_duplicate_key,
        .id = "E0003",
        .title = "key defined twice",
        .explanation = "toml doesn't allow setting the same key or table twice in one file. remove one of " ++
            "the two definitions. to change a value that an include sets, set it in the including file; " ++
            "the including file always wins.",
    },
    .{
        .code = .config_missing,
        .id = "E0100",
        .title = "no config file",
        .explanation = "os couldn't read the config file. by default it's /etc/yoq/machine.toml, and " ++
            "`--config <path>` points somewhere else. `os init` writes one that describes this machine.",
    },
    .{
        .code = .unknown_key,
        .id = "E0101",
        .title = "unknown key",
        .explanation = "the config has a key os doesn't know. it's usually a typo, and the hint names the " ++
            "closest known key.",
    },
    .{
        .code = .wrong_type,
        .id = "E0102",
        .title = "wrong type",
        .explanation = "the key exists, but its value has the wrong type, for example a string where a list " ++
            "is expected: `packages = \"git\"` instead of `packages = [\"git\"]`.",
    },
    .{
        .code = .bad_value,
        .id = "E0103",
        .title = "invalid value",
        .explanation = "the value has the right type but isn't allowed, for example an empty hostname or an " ++
            "unknown cpu vendor. the message lists what's accepted.",
    },
    .{
        .code = .include_missing,
        .id = "E0110",
        .title = "include not found",
        .explanation = "a file named in `include` doesn't exist. include paths are relative to the file that " ++
            "includes them.",
    },
    .{
        .code = .include_cycle,
        .id = "E0111",
        .title = "include cycle",
        .explanation = "two or more files include each other, directly or through other files. the message " ++
            "shows the chain. break it by moving the shared settings into a file that neither includes.",
    },
    .{
        .code = .lock_invalid,
        .id = "E0120",
        .title = "damaged lock file",
        .explanation = "machine.lock is written by os and read back exactly. this one doesn't match the " ++
            "format, usually because it was edited by hand or a merge left conflict markers in it. restore " ++
            "it from git (`git -C /etc/yoq checkout machine.lock`) or write a fresh one with `os update`.",
    },
    .{
        .code = .lock_stale,
        .id = "E0121",
        .title = "lock doesn't cover the config",
        .explanation = "the config asks for a package that machine.lock doesn't have, so os doesn't know which " ++
            "version to install. `os add <package>` resolves one package against the lock's current package " ++
            "date; `os update` resolves everything against today's.",
    },
    .{
        .code = .unresolvable,
        .id = "E0122",
        .title = "can't resolve packages",
        .explanation = "resolving the config against the arch package databases failed: a package doesn't " ++
            "exist, needs something no repository has, or conflicts with another package the config asks " ++
            "for. the message names the packages involved.",
    },
    .{
        .code = .provider_choice,
        .id = "E0123",
        .title = "choose a provider",
        .explanation = "a package depends on something several packages provide, like java-runtime, and os " ++
            "won't pick one for you. add the choice to the config under [providers], for example " ++
            "`java-runtime = \"jre-openjdk\"`.",
    },
    .{
        .code = .alpm_failed,
        .id = "E0124",
        .title = "package database error",
        .explanation = "libalpm couldn't open or read a package database. the message has libalpm's own " ++
            "reason. a stale lock file (db.lck) left by a crashed pacman is a common cause.",
    },
    .{
        .code = .unknown_service,
        .id = "E0213",
        .title = "unknown service",
        .explanation = "`[services]` names a service os doesn't know how to set up. names are short and " ++
            "stable, like `ssh` rather than `sshd` or `openssh`. for a unit os doesn't know, declare it with " ++
            "`[services.<name>] unit = \"<unit>.service\"` and `package = \"<package>\"`.",
    },
};

comptime {
    for (table, 0..) |e, i| {
        if (@intFromEnum(e.code) != i) @compileError("diag.table is out of order at " ++ e.id);
    }
    if (table.len != @typeInfo(Code).@"enum".fields.len) @compileError("diag.table is missing a code");
}

/// the json shape of an entry: `code` is the stable id, like in error
/// documents, and `name` is the short name.
pub const EntryJson = struct {
    code: []const u8,
    name: []const u8,
    title: []const u8,
    explanation: []const u8,
};

pub fn entryJson(e: Entry) EntryJson {
    return .{ .code = e.id, .name = @tagName(e.code), .title = e.title, .explanation = e.explanation };
}

pub fn entry(code: Code) Entry {
    return table[@intFromEnum(code)];
}

pub fn byId(id: []const u8) ?Entry {
    for (table) |e| {
        if (std.ascii.eqlIgnoreCase(e.id, id)) return e;
    }
    return null;
}

pub const Span = struct {
    file: []const u8,
    line: u32,
    column: u32,
};

pub const Diagnostic = struct {
    code: Code,
    message: []const u8,
    span: ?Span = null,
    hint: ?[]const u8 = null,

    pub fn render(d: Diagnostic, w: *std.Io.Writer) !void {
        const id = entry(d.code).id;
        try w.print("error[{s}]: {s}\n", .{ id, d.message });
        if (d.span) |s| try w.print("  --> {s}:{d}:{d}\n", .{ s.file, s.line, s.column });
        if (d.hint) |h| {
            try w.print("   | {s}  (os explain {s})\n", .{ h, id });
        } else {
            try w.print("   | os explain {s}\n", .{id});
        }
    }

    pub const Json = struct {
        code: []const u8,
        title: []const u8,
        message: []const u8,
        file: ?[]const u8,
        line: ?u32,
        column: ?u32,
        hint: ?[]const u8,
    };

    pub fn toJson(d: Diagnostic) Json {
        const e = entry(d.code);
        return .{
            .code = e.id,
            .title = e.title,
            .message = d.message,
            .file = if (d.span) |s| s.file else null,
            .line = if (d.span) |s| s.line else null,
            .column = if (d.span) |s| s.column else null,
            .hint = d.hint,
        };
    }
};

/// collects diagnostics so a command can report every problem at once. all
/// strings live in the list's arena.
pub const List = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Diagnostic) = .empty,

    pub fn init(gpa: std.mem.Allocator) List {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(l: *List) void {
        l.arena.deinit();
    }

    pub fn add(
        l: *List,
        code: Code,
        span: ?Span,
        comptime fmt: []const u8,
        args: anytype,
        hint: ?[]const u8,
    ) !void {
        const a = l.arena.allocator();
        try l.items.append(a, .{
            .code = code,
            .message = try std.fmt.allocPrint(a, fmt, args),
            .span = if (span) |s| .{ .file = try a.dupe(u8, s.file), .line = s.line, .column = s.column } else null,
            .hint = if (hint) |h| try a.dupe(u8, h) else null,
        });
    }

    /// like `add`, with a formatted hint.
    pub fn addHint(
        l: *List,
        code: Code,
        span: ?Span,
        comptime fmt: []const u8,
        args: anytype,
        comptime hint_fmt: []const u8,
        hint_args: anytype,
    ) !void {
        const hint = try std.fmt.allocPrint(l.arena.allocator(), hint_fmt, hint_args);
        try l.add(code, span, fmt, args, hint);
    }

    pub fn render(l: *const List, w: *std.Io.Writer) !void {
        for (l.items.items, 0..) |d, i| {
            if (i > 0) try w.writeByte('\n');
            try d.render(w);
        }
    }

    pub fn writeJson(l: *const List, w: *std.Io.Writer) !void {
        const a = l.arena.child_allocator;
        const errors = try a.alloc(Diagnostic.Json, l.items.items.len);
        defer a.free(errors);
        for (l.items.items, errors) |d, *j| j.* = d.toJson();
        try output.writeDoc(w, "yoq.errors/1", .{ .errors = errors });
    }
};

/// the candidate closest to `name` by edit distance, if it's close enough to
/// be a likely typo.
pub fn suggest(name: []const u8, candidates: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = std.math.maxInt(usize);
    for (candidates) |c| {
        const d = editDistance(name, c);
        if (d < best_dist) {
            best = c;
            best_dist = d;
        }
    }
    const limit = @max(1, @min(name.len, 12) / 3);
    return if (best_dist <= limit) best else null;
}

/// levenshtein distance, for short identifiers only.
fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 64 or b.len > 64) return std.math.maxInt(usize);
    var prev: [65]usize = undefined;
    var cur: [65]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const sub = prev[j] + @intFromBool(ca != cb);
            cur[j + 1] = @min(sub, prev[j + 1] + 1, cur[j] + 1);
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

test "codes are unique" {
    for (table, 0..) |a, i| {
        for (table[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.id, b.id));
    }
}

test "render with span and hint" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const d: Diagnostic = .{
        .code = .unknown_service,
        .message = "unknown service \"sshd\"",
        .span = .{ .file = "/etc/yoq/machine.toml", .line = 24, .column = 1 },
        .hint = "did you mean \"ssh\"?",
    };
    try d.render(&w);
    try std.testing.expectEqualStrings(
        \\error[E0213]: unknown service "sshd"
        \\  --> /etc/yoq/machine.toml:24:1
        \\   | did you mean "ssh"?  (os explain E0213)
        \\
    , w.buffered());
}

test "list collects and renders json" {
    var l: List = .init(std.testing.allocator);
    defer l.deinit();
    try l.add(.wrong_type, .{ .file = "m.toml", .line = 2, .column = 12 }, "packages must be a list", .{}, null);
    try l.addHint(.unknown_key, null, "unknown key \"hostnme\"", .{}, "did you mean \"{s}\"?", .{"hostname"});

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try l.writeJson(&w);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    const errors = parsed.value.object.get("errors").?.array.items;
    try std.testing.expectEqual(2, errors.len);
    try std.testing.expectEqualStrings("E0102", errors[0].object.get("code").?.string);
    try std.testing.expectEqual(2, errors[0].object.get("line").?.integer);
    try std.testing.expectEqualStrings("did you mean \"hostname\"?", errors[1].object.get("hint").?.string);
    try std.testing.expect(errors[1].object.get("file").? == .null);
}

test "suggest finds likely typos only" {
    const keys: []const []const u8 = &.{ "hostname", "timezone", "locale" };
    try std.testing.expectEqualStrings("hostname", suggest("hostnme", keys).?);
    try std.testing.expectEqualStrings("timezone", suggest("timzone", keys).?);
    try std.testing.expectEqual(null, suggest("kernel", keys));
    try std.testing.expectEqualStrings("ssh", suggest("sshd", &.{ "ssh", "cups", "docker" }).?);
}

test "byId ignores case" {
    try std.testing.expectEqual(Code.unknown_service, byId("e0213").?.code);
    try std.testing.expectEqual(null, byId("E9999"));
}
