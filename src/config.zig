//! the typed config. `decode` turns one parsed file into a `Part`: that
//! file's own settings plus its `include`, `unset`, and `[remove]`. compose.zig
//! merges parts into one `Config`, and `validate` checks the result.
//!
//! every value remembers the file, line, and column it came from, so errors
//! and `os config show --resolved` can point at it.

const std = @import("std");
const toml = @import("toml.zig");
const diag = @import("diag.zig");
const catalog = @import("catalog.zig");
const Allocator = std.mem.Allocator;

pub const supported_version = 1;

pub const Src = struct {
    file: []const u8,
    line: u32,
    column: u32,

    pub fn span(s: Src) diag.Span {
        return .{ .file = s.file, .line = s.line, .column = s.column };
    }
};

pub fn Val(comptime T: type) type {
    return struct {
        v: T,
        src: Src,
    };
}

pub const Str = Val([]const u8);

/// one element of a set, like a package name.
pub const Item = struct {
    name: []const u8,
    src: Src,
};

/// an unordered list: merging two sets keeps every name once.
pub const Set = struct {
    items: std.ArrayList(Item) = .empty,

    pub fn contains(s: *const Set, name: []const u8) bool {
        return s.indexOf(name) != null;
    }

    pub fn indexOf(s: *const Set, name: []const u8) ?usize {
        for (s.items.items, 0..) |it, i| {
            if (std.mem.eql(u8, it.name, name)) return i;
        }
        return null;
    }

    /// adds `item` unless the name is already there. the first source wins.
    pub fn add(s: *Set, a: Allocator, item: Item) !void {
        if (!s.contains(item.name)) try s.items.append(a, item);
    }

    pub fn remove(s: *Set, name: []const u8) bool {
        const i = s.indexOf(name) orelse return false;
        _ = s.items.orderedRemove(i);
        return true;
    }

    pub fn names(s: *const Set, a: Allocator) ![]const []const u8 {
        const out = try a.alloc([]const u8, s.items.items.len);
        for (s.items.items, out) |it, *n| n.* = it.name;
        return out;
    }
};

/// a table keyed by name, like `[users.kacy]`, kept in file order.
pub fn Named(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Value = T;
        pub const Entry = struct {
            name: []const u8,
            value: T,
        };

        entries: std.ArrayList(Entry) = .empty,

        pub fn get(n: *const Self, name: []const u8) ?*T {
            for (n.entries.items) |*e| {
                if (std.mem.eql(u8, e.name, name)) return &e.value;
            }
            return null;
        }

        pub fn remove(n: *Self, name: []const u8) bool {
            for (n.entries.items, 0..) |e, i| {
                if (std.mem.eql(u8, e.name, name)) {
                    _ = n.entries.orderedRemove(i);
                    return true;
                }
            }
            return false;
        }
    };
}

/// true for `Named(...)` types.
pub fn isNamed(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Entry") and @hasField(T, "entries");
}

/// true for `Val(...)` types.
pub fn isVal(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "v") and @hasField(T, "src");
}

/// the config keys of a section: its fields, minus the `src` bookkeeping.
pub fn keysOf(comptime T: type) []const []const u8 {
    comptime {
        var keys: []const []const u8 = &.{};
        for (std.meta.fieldNames(T)) |n| {
            if (!std.mem.eql(u8, n, "src")) keys = keys ++ .{n};
        }
        return keys;
    }
}

pub const Cpu = enum { amd, intel };
pub const Gpu = enum { amd, intel, nvidia, none };
pub const Session = enum { hyprland };
pub const Audio = enum { pipewire };

pub const System = struct {
    hostname: ?Str = null,
    timezone: ?Str = null,
    locale: ?Str = null,
    keymap: ?Str = null,
};

pub const Boot = struct {
    kernel: ?Str = null,
};

pub const Hardware = struct {
    cpu: ?Val(Cpu) = null,
    gpu: ?Val(Gpu) = null,
};

pub const User = struct {
    src: Src,
    shell: ?Str = null,
    groups: Set = .{},
};

pub const Desktop = struct {
    session: ?Val(Session) = null,
    audio: ?Val(Audio) = null,
};

pub const Service = struct {
    /// `ssh = true` is shorthand for `[services.ssh] enabled = true`.
    pub const shorthand = "enabled";

    src: Src,
    enabled: ?Val(bool) = null,
    /// for services the catalog doesn't know.
    unit: ?Str = null,
    package: ?Str = null,
};

pub const State = struct {
    carry: Set = .{},
};

pub const Config = struct {
    version: ?Val(i64) = null,
    packages: Set = .{},
    aur: Set = .{},
    providers: Named(Str) = .{},
    system: System = .{},
    boot: Boot = .{},
    hardware: Hardware = .{},
    desktop: Desktop = .{},
    users: Named(User) = .{},
    services: Named(Service) = .{},
    state: State = .{},
};

pub const Remove = struct {
    packages: Set = .{},
    aur: Set = .{},
};

/// one file's contribution before merging.
pub const Part = struct {
    file: []const u8,
    include: std.ArrayList(Str) = .empty,
    unset: std.ArrayList(Str) = .empty,
    remove: Remove = .{},
    config: Config = .{},
};

/// keys a file may use besides the config itself.
const file_keys = [_][]const u8{ "include", "unset", "remove" };
const root_keys = keysOf(Config) ++ file_keys;

/// decodes one parsed file. problems go to `diags`; decoding carries on past
/// them so one run reports everything. strings are copied into `a`.
pub fn decode(a: Allocator, file: []const u8, root: *const toml.Table, diags: *diag.List) !Part {
    var d: Decoder = .{ .a = a, .file = try a.dupe(u8, file), .diags = diags };
    var part: Part = .{ .file = d.file };

    for (root.entries.items) |*e| {
        if (std.mem.eql(u8, e.key, "include")) {
            try d.stringList(e, &part.include);
        } else if (std.mem.eql(u8, e.key, "unset")) {
            try d.stringList(e, &part.unset);
        } else if (std.mem.eql(u8, e.key, "remove")) {
            try d.value(Remove, &part.remove, e, "");
        } else if (!try d.field(Config, &part.config, e, "")) {
            try d.unknownKey(e, "", root_keys);
        }
    }
    if (part.config.version) |v| {
        if (v.v != supported_version) {
            try diags.add(.bad_value, v.src.span(), "config version {d} isn't supported", .{v.v}, "this os reads version 1");
        }
    }
    return part;
}

/// decodes toml into the config types by their shape, so a new key only
/// needs a new field. messages name keys by their full path, like
/// "users.kacy.shell".
const Decoder = struct {
    a: Allocator,
    file: []const u8,
    diags: *diag.List,

    fn src(d: *const Decoder, span: toml.Span) Src {
        return .{ .file = d.file, .line = span.start.line, .column = span.start.column };
    }

    fn path(d: *Decoder, prefix: []const u8, key: []const u8) ![]const u8 {
        return std.fmt.allocPrint(d.a, "{s}{s}.", .{ prefix, key });
    }

    /// decodes `e` into the field of `target` named by its key. returns
    /// false if `T` has no such field.
    fn field(d: *Decoder, comptime T: type, target: *T, e: *const toml.Entry, prefix: []const u8) !bool {
        inline for (comptime keysOf(T)) |name| {
            if (std.mem.eql(u8, e.key, name)) {
                try d.value(@FieldType(T, name), &@field(target, name), e, prefix);
                return true;
            }
        }
        return false;
    }

    fn fields(d: *Decoder, comptime T: type, target: *T, t: *const toml.Table, prefix: []const u8) !void {
        for (t.entries.items) |*e| {
            if (!try d.field(T, target, e, prefix)) try d.unknownKey(e, prefix, comptime keysOf(T));
        }
    }

    fn value(d: *Decoder, comptime T: type, target: *T, e: *const toml.Entry, prefix: []const u8) !void {
        if (T == Set) return d.set(e, prefix, target);
        if (@typeInfo(T) == .optional) {
            target.* = try d.scalar(@typeInfo(T).optional.child, e, prefix);
        } else if (comptime isNamed(T)) {
            const t = try d.table(e, prefix) orelse return;
            const sub = try d.path(prefix, e.key);
            for (t.entries.items) |*n| {
                const v = try d.entry(T.Value, n, sub) orelse continue;
                try target.entries.append(d.a, .{ .name = try d.a.dupe(u8, n.key), .value = v });
            }
        } else {
            const t = try d.table(e, prefix) orelse return;
            try d.fields(T, target, t, try d.path(prefix, e.key));
        }
    }

    /// one entry of a `Named` table: a plain value, or a table of fields.
    fn entry(d: *Decoder, comptime T: type, e: *const toml.Entry, prefix: []const u8) !?T {
        if (comptime isVal(T)) return d.scalar(T, e, prefix);
        var out: T = .{ .src = d.src(e.key_span) };
        if (@hasDecl(T, "shorthand") and e.value.data == .boolean) {
            @field(out, T.shorthand) = .{ .v = e.value.data.boolean, .src = d.src(e.value.span) };
            return out;
        }
        if (e.value.data != .table) {
            try d.wrongType(e, prefix, if (@hasDecl(T, "shorthand")) "true, false, or a table" else "a table", e.value);
            return null;
        }
        try d.fields(T, &out, e.value.data.table, try d.path(prefix, e.key));
        return out;
    }

    fn scalar(d: *Decoder, comptime V: type, e: *const toml.Entry, prefix: []const u8) !?V {
        const X = @FieldType(V, "v");
        const at = d.src(e.value.span);
        switch (@typeInfo(X)) {
            .bool => if (e.value.data == .boolean) return .{ .v = e.value.data.boolean, .src = at },
            .int => if (e.value.data == .integer) return .{ .v = e.value.data.integer, .src = at },
            .pointer => if (e.value.data == .string) return .{ .v = try d.a.dupe(u8, e.value.data.string), .src = at },
            .@"enum" => if (e.value.data == .string) {
                if (std.meta.stringToEnum(X, e.value.data.string)) |v| return .{ .v = v, .src = at };
                try d.diags.addHint(.bad_value, at.span(), "{s}{s} can't be \"{s}\"", .{ prefix, e.key, e.value.data.string }, "use one of {s}", .{comptime quotedList(X)});
                return null;
            },
            else => @compileError("no decoder for " ++ @typeName(X)),
        }
        const want = switch (@typeInfo(X)) {
            .bool => "true or false",
            .int => "an integer",
            else => "a string",
        };
        try d.wrongType(e, prefix, want, e.value);
        return null;
    }

    fn unknownKey(d: *Decoder, e: *const toml.Entry, prefix: []const u8, known: []const []const u8) !void {
        const at = d.src(e.key_span).span();
        if (diag.suggest(e.key, known)) |s| {
            try d.diags.addHint(.unknown_key, at, "unknown key \"{s}{s}\"", .{ prefix, e.key }, "did you mean \"{s}\"?", .{s});
        } else {
            try d.diags.add(.unknown_key, at, "unknown key \"{s}{s}\"", .{ prefix, e.key }, null);
        }
    }

    fn wrongType(d: *Decoder, e: *const toml.Entry, prefix: []const u8, want: []const u8, got: toml.Value) !void {
        try d.diags.add(.wrong_type, d.src(got.span).span(), "{s}{s} should be {s}, not {s}", .{ prefix, e.key, want, got.typeName() }, null);
    }

    fn table(d: *Decoder, e: *const toml.Entry, prefix: []const u8) !?*const toml.Table {
        if (e.value.data == .table) return e.value.data.table;
        try d.wrongType(e, prefix, "a table", e.value);
        return null;
    }

    /// calls `f` for each string in a list, with its own position.
    fn eachString(d: *Decoder, e: *const toml.Entry, prefix: []const u8, ctx: anytype, comptime f: anytype) !void {
        if (e.value.data != .array) return d.wrongType(e, prefix, "a list of strings", e.value);
        for (e.value.data.array.items.items) |item| {
            if (item.data != .string) {
                try d.diags.add(.wrong_type, d.src(item.span).span(), "{s}{s} should only hold strings, not {s}", .{ prefix, e.key, item.typeName() }, null);
                continue;
            }
            try f(ctx, d.a, try d.a.dupe(u8, item.data.string), d.src(item.span));
        }
    }

    fn set(d: *Decoder, e: *const toml.Entry, prefix: []const u8, out: *Set) !void {
        try d.eachString(e, prefix, out, struct {
            fn f(s: *Set, a: Allocator, name: []const u8, at: Src) !void {
                try s.add(a, .{ .name = name, .src = at });
            }
        }.f);
    }

    fn stringList(d: *Decoder, e: *const toml.Entry, out: *std.ArrayList(Str)) !void {
        try d.eachString(e, "", out, struct {
            fn f(l: *std.ArrayList(Str), a: Allocator, v: []const u8, at: Src) !void {
                try l.append(a, .{ .v = v, .src = at });
            }
        }.f);
    }
};

fn quotedList(comptime E: type) []const u8 {
    comptime {
        var list: []const u8 = "";
        for (std.meta.fieldNames(E), 0..) |n, i| list = list ++ (if (i > 0) ", " else "") ++ "\"" ++ n ++ "\"";
        return list;
    }
}

/// checks a merged config for problems that need the whole picture, like a
/// service no file explains.
pub fn validate(c: *const Config, diags: *diag.List) !void {
    for (c.services.entries.items) |e| {
        if (!knownService(c, e.name)) try unknownService(diags, e.name, e.value.src.span());
    }
    if (c.system.hostname) |h| {
        if (!validHostname(h.v)) {
            try diags.add(.bad_value, h.src.span(), "\"{s}\" isn't a valid hostname", .{h.v}, "use letters, digits, and dashes, up to 63 characters");
        }
    }
    for (c.users.entries.items) |u| {
        if (!validUserName(u.name)) {
            try diags.add(.bad_value, u.value.src.span(), "\"{s}\" isn't a valid user name", .{u.name}, "start with a lowercase letter or _, then lowercase letters, digits, _ or -, up to 32 characters");
        }
    }
}

/// a service os can set up: one the catalog knows, or one the config
/// describes with its own unit and package.
pub fn knownService(c: *const Config, name: []const u8) bool {
    if (catalog.service(name) != null) return true;
    const s = c.services.get(name) orelse return false;
    return s.unit != null and s.package != null;
}

pub fn unknownService(diags: *diag.List, name: []const u8, at: ?diag.Span) !void {
    const known = catalog.serviceNames();
    if (diag.suggest(name, &known)) |s| {
        try diags.addHint(.unknown_service, at, "unknown service \"{s}\"", .{name}, "did you mean \"{s}\"?", .{s});
    } else {
        try diags.add(.unknown_service, at, "unknown service \"{s}\"", .{name}, "set its unit and package in [services.<name>]");
    }
}

fn validHostname(h: []const u8) bool {
    if (h.len == 0 or h.len > 63 or h[0] == '-' or h[h.len - 1] == '-') return false;
    for (h) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    }
    return true;
}

fn validUserName(n: []const u8) bool {
    if (n.len == 0 or n.len > 32) return false;
    if (!std.ascii.isLower(n[0]) and n[0] != '_') return false;
    for (n[1..]) |ch| {
        if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '_' and ch != '-') return false;
    }
    return true;
}

// -- tests --

const testing = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    diags: diag.List,
    doc: toml.Document,
    part: Part,

    fn init(src: []const u8) !*Fixture {
        const f = try testing.allocator.create(Fixture);
        f.arena = .init(testing.allocator);
        f.diags = .init(testing.allocator);
        var info: toml.ErrorInfo = .{};
        f.doc = try toml.parse(testing.allocator, src, &info);
        f.part = try decode(f.arena.allocator(), "machine.toml", f.doc.root, &f.diags);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.doc.deinit();
        f.diags.deinit();
        f.arena.deinit();
        testing.allocator.destroy(f);
    }

    fn expectDiag(f: *Fixture, i: usize, code: diag.Code, line: u32, message: []const u8) !void {
        try testing.expect(i < f.diags.items.items.len);
        const d = f.diags.items.items[i];
        try testing.expectEqual(code, d.code);
        try testing.expectEqual(line, d.span.?.line);
        try testing.expectEqualStrings(message, d.message);
    }
};

test "decodes the example config" {
    const f = try Fixture.init(
        \\version = 1
        \\include = ["imported.toml"]
        \\packages = ["ghostty", "git", "neovim", "git"]
        \\
        \\[system]
        \\hostname = "atlas"
        \\timezone = "America/New_York"
        \\locale = "en_US.UTF-8"
        \\
        \\[hardware]
        \\cpu = "amd"
        \\gpu = "nvidia"
        \\
        \\[users.kacy]
        \\shell = "zsh"
        \\groups = ["wheel"]
        \\
        \\[desktop]
        \\session = "hyprland"
        \\audio = "pipewire"
        \\
        \\[services]
        \\ssh = true
        \\bluetooth = true
        \\
        \\[services.tailscale]
        \\enabled = false
        \\
    );
    defer f.deinit();
    try testing.expectEqual(0, f.diags.items.items.len);
    const c = f.part.config;
    try testing.expectEqual(1, c.version.?.v);
    try testing.expectEqualStrings("imported.toml", f.part.include.items[0].v);
    try testing.expectEqual(3, c.packages.items.items.len);
    try testing.expectEqual(3, c.packages.items.items[1].src.line);
    try testing.expectEqualStrings("atlas", c.system.hostname.?.v);
    try testing.expectEqual(Gpu.nvidia, c.hardware.gpu.?.v);
    try testing.expectEqualStrings("zsh", c.users.get("kacy").?.shell.?.v);
    try testing.expect(c.users.get("kacy").?.groups.contains("wheel"));
    try testing.expectEqual(Session.hyprland, c.desktop.session.?.v);
    try testing.expect(c.services.get("ssh").?.enabled.?.v);
    try testing.expect(!c.services.get("tailscale").?.enabled.?.v);
    try testing.expectEqual(3, c.services.entries.items.len);
}

test "unknown keys get suggestions" {
    const f = try Fixture.init(
        \\pakages = ["git"]
        \\[system]
        \\hostnme = "atlas"
        \\[users.kacy]
        \\shel = "zsh"
        \\colour = "red"
        \\
    );
    defer f.deinit();
    try testing.expectEqual(4, f.diags.items.items.len);
    try f.expectDiag(0, .unknown_key, 1, "unknown key \"pakages\"");
    try testing.expectEqualStrings("did you mean \"packages\"?", f.diags.items.items[0].hint.?);
    try f.expectDiag(1, .unknown_key, 3, "unknown key \"system.hostnme\"");
    try f.expectDiag(2, .unknown_key, 5, "unknown key \"users.kacy.shel\"");
    try testing.expectEqual(null, f.diags.items.items[3].hint);
}

test "wrong types point at the value" {
    const f = try Fixture.init(
        \\packages = "git"
        \\aur = ["ok", 3]
        \\system = 1
        \\[services]
        \\ssh = "yes"
        \\
    );
    defer f.deinit();
    try testing.expectEqual(4, f.diags.items.items.len);
    try f.expectDiag(0, .wrong_type, 1, "packages should be a list of strings, not a string");
    try testing.expectEqual(12, f.diags.items.items[0].span.?.column);
    try f.expectDiag(1, .wrong_type, 2, "aur should only hold strings, not an integer");
    try f.expectDiag(2, .wrong_type, 3, "system should be a table, not an integer");
    try f.expectDiag(3, .wrong_type, 5, "services.ssh should be true, false, or a table, not a string");
    try testing.expectEqual(1, f.part.config.aur.items.items.len);
}

test "enum values list the options" {
    const f = try Fixture.init("[hardware]\ncpu = \"arm\"\n");
    defer f.deinit();
    try f.expectDiag(0, .bad_value, 2, "hardware.cpu can't be \"arm\"");
    try testing.expectEqualStrings("use one of \"amd\", \"intel\"", f.diags.items.items[0].hint.?);
}

test "unsupported version" {
    const f = try Fixture.init("version = 2\n");
    defer f.deinit();
    try f.expectDiag(0, .bad_value, 1, "config version 2 isn't supported");
}

test "unset and remove" {
    const f = try Fixture.init("unset = [\"desktop.audio\"]\n[remove]\npackages = [\"nano\"]\n");
    defer f.deinit();
    try testing.expectEqual(0, f.diags.items.items.len);
    try testing.expectEqualStrings("desktop.audio", f.part.unset.items[0].v);
    try testing.expect(f.part.remove.packages.contains("nano"));
}

test "validate catches unknown services and bad names" {
    const f = try Fixture.init(
        \\[system]
        \\hostname = "-atlas"
        \\[users.Kacy]
        \\shell = "zsh"
        \\[services]
        \\sshd = true
        \\custom = { unit = "custom.service", package = "custom" }
        \\mystery = true
        \\
    );
    defer f.deinit();
    try validate(&f.part.config, &f.diags);
    try testing.expectEqual(4, f.diags.items.items.len);
    try f.expectDiag(0, .unknown_service, 6, "unknown service \"sshd\"");
    try testing.expectEqualStrings("did you mean \"ssh\"?", f.diags.items.items[0].hint.?);
    try f.expectDiag(1, .unknown_service, 8, "unknown service \"mystery\"");
    try f.expectDiag(2, .bad_value, 2, "\"-atlas\" isn't a valid hostname");
    try f.expectDiag(3, .bad_value, 3, "\"Kacy\" isn't a valid user name");
}
