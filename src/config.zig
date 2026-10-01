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
const lists = @import("lists.zig");
const planner = @import("planner.zig");
const secrets = @import("secrets.zig");
const Allocator = std.mem.Allocator;

pub const supported_version = 1;

/// where a value came from: the file, line, and column.
pub const Src = diag.Span;

pub fn Val(comptime T: type) type {
    return struct {
        v: T,
        src: Src,
    };
}

pub const Str = Val([]const u8);

/// a value written as a number or a string, like a sysctl's, kept as the
/// text it stands for.
pub const Loose = struct {
    text: []const u8,

    pub fn jsonStringify(l: Loose, jw: anytype) !void {
        try jw.write(l.text);
    }
};

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
        return lists.indexOf(s.items.items, "name", name);
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
            const e = lists.find(n.entries.items, "name", name) orelse return null;
            return &e.value;
        }

        pub fn remove(n: *Self, name: []const u8) bool {
            const i = lists.indexOf(n.entries.items, "name", name) orelse return false;
            _ = n.entries.orderedRemove(i);
            return true;
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

/// fields that aren't config keys: where a value came from, and what
/// loading works out from the keys.
fn isHidden(comptime name: []const u8) bool {
    return lists.contains(&.{ "src", "removed", "content", "session_content" }, name);
}

/// the config keys of a section: its fields, minus the hidden ones.
pub fn keysOf(comptime T: type) []const []const u8 {
    comptime {
        var keys: []const []const u8 = &.{};
        for (std.meta.fieldNames(T)) |n| {
            if (!isHidden(n)) keys = keys ++ .{n};
        }
        return keys;
    }
}

pub const Cpu = enum { amd, intel };
pub const Gpu = enum { amd, intel, nvidia, none };
pub const Session = enum { hyprland };
pub const Audio = enum { pipewire };
pub const Login = enum { greetd, sddm, tty };

pub const System = struct {
    hostname: ?Str = null,
    timezone: ?Str = null,
    locale: ?Str = null,
    keymap: ?Str = null,
};

pub const Boot = struct {
    kernel: ?Str = null,
    /// kernel modules loaded at every boot, like i2c-dev.
    modules: Set = .{},
    /// the root is on luks, so the initramfs has to unlock it. os adds
    /// sd-encrypt to mkinitcpio's hooks when they can't already.
    encrypt: ?Val(bool) = null,
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
    /// how a person logs in: a display manager, or a console on tty1.
    login: ?Val(Login) = null,
    /// the session's own config, like hyprland.conf: a file next to the
    /// config, copied as it is.
    session_config: ?Str = null,
    /// what `session_config` holds, read when the config loaded. not a key.
    session_content: ?[]const u8 = null,
};

pub const Service = struct {
    /// `ssh = true` is shorthand for `[services.ssh] enabled = true`.
    pub const shorthand = "enabled";

    src: Src,
    enabled: ?Val(bool) = null,
    /// for services the catalog doesn't know.
    unit: ?Str = null,
    package: ?Str = null,

    /// a service is on unless the config says otherwise.
    pub fn isEnabled(s: *const Service) bool {
        return if (s.enabled) |e| e.v else true;
    }

    /// the unit, from the config or else the catalog. the service must be
    /// known; `validate` checks that.
    pub fn unitFor(s: *const Service, name: []const u8) []const u8 {
        return if (s.unit) |u| u.v else catalog.service(name).?.unit;
    }

    pub fn packageFor(s: *const Service, name: []const u8) []const u8 {
        return if (s.package) |p| p.v else catalog.service(name).?.package;
    }
};

pub const State = struct {
    carry: Set = .{},
};

/// a package repository beyond arch's own, like chaotic-aur, keyed by its
/// name.
pub const Repo = struct {
    src: Src,
    /// where its packages are, with `$repo` and `$arch` as pacman has them.
    server: ?Str = null,
    /// the full fingerprint of the key its packages are signed with. with
    /// none, its packages aren't checked.
    key: ?Str = null,
};

/// a file os writes whole, keyed by its absolute path.
pub const File = struct {
    src: Src,
    /// a file next to the config, relative to the one that names it.
    source: ?Str = null,
    /// or the content itself.
    text: ?Str = null,
    /// or a secret's name: os writes the value `os secret set` keeps for
    /// it, which never goes into the config.
    secret: ?Str = null,
    /// octal, like "0644", the default, or "0600" for a secret.
    mode: ?Str = null,
    /// what the file holds: `text`, or `source` as it was read when the
    /// config loaded. not a key.
    content: ?[]const u8 = null,

    pub const default_mode = "0644";
    pub const secret_mode = "0600";

    pub fn modeOf(f: *const File) []const u8 {
        if (f.mode) |m| return m.v;
        return if (f.secret != null) secret_mode else default_mode;
    }
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
    files: Named(File) = .{},
    repos: Named(Repo) = .{},
    /// kernel settings, written to one file in /etc/sysctl.d.
    sysctl: Named(Val(Loose)) = .{},
    /// every package a `[remove]` names, in this file or an include. not a
    /// key: it's what lets the plan remove a protected package.
    removed: Set = .{},
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
            try d.stringList(e, "", &part.include);
        } else if (std.mem.eql(u8, e.key, "unset")) {
            try d.stringList(e, "", &part.unset);
        } else if (std.mem.eql(u8, e.key, "remove")) {
            try d.value(Remove, &part.remove, e, "");
        } else if (!try d.field(Config, &part.config, e, "")) {
            try d.unknownKey(e, "", root_keys);
        }
    }
    if (part.config.version) |v| {
        if (v.v != supported_version) {
            try diags.add(.bad_value, v.src, "config version {d} isn't supported", .{v.v}, "this os reads version 1");
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

    fn path(d: *const Decoder, prefix: []const u8, key: []const u8) ![]const u8 {
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
            .@"struct" => switch (e.value.data) {
                .string => |t| return .{ .v = .{ .text = try d.a.dupe(u8, t) }, .src = at },
                .integer => |i| return .{ .v = .{ .text = try std.fmt.allocPrint(d.a, "{d}", .{i}) }, .src = at },
                else => {},
            },
            .@"enum" => if (e.value.data == .string) {
                if (std.meta.stringToEnum(X, e.value.data.string)) |v| return .{ .v = v, .src = at };
                try d.diags.addHint(.bad_value, at, "{s}{s} can't be \"{s}\"", .{ prefix, e.key, e.value.data.string }, "use one of {s}", .{comptime quotedList(X)});
                return null;
            },
            else => @compileError("no decoder for " ++ @typeName(X)),
        }
        const want = switch (@typeInfo(X)) {
            .bool => "true or false",
            .int => "an integer",
            .@"struct" => "a number or a string",
            else => "a string",
        };
        try d.wrongType(e, prefix, want, e.value);
        return null;
    }

    fn unknownKey(d: *Decoder, e: *const toml.Entry, prefix: []const u8, known: []const []const u8) !void {
        const at = d.src(e.key_span);
        if (diag.suggest(e.key, known)) |s| {
            try d.diags.addHint(.unknown_key, at, "unknown key \"{s}{s}\"", .{ prefix, e.key }, "did you mean \"{s}\"?", .{s});
        } else {
            try d.diags.add(.unknown_key, at, "unknown key \"{s}{s}\"", .{ prefix, e.key }, null);
        }
    }

    fn wrongType(d: *Decoder, e: *const toml.Entry, prefix: []const u8, want: []const u8, got: toml.Value) !void {
        try d.diags.add(.wrong_type, d.src(got.span), "{s}{s} should be {s}, not {s}", .{ prefix, e.key, want, got.typeName() }, null);
    }

    fn table(d: *Decoder, e: *const toml.Entry, prefix: []const u8) !?*const toml.Table {
        if (e.value.data == .table) return e.value.data.table;
        try d.wrongType(e, prefix, "a table", e.value);
        return null;
    }

    /// appends each string in a list, with its own position.
    fn stringList(d: *Decoder, e: *const toml.Entry, prefix: []const u8, out: *std.ArrayList(Str)) !void {
        if (e.value.data != .array) return d.wrongType(e, prefix, "a list of strings", e.value);
        for (e.value.data.array.items.items) |item| {
            if (item.data != .string) {
                try d.diags.add(.wrong_type, d.src(item.span), "{s}{s} should only hold strings, not {s}", .{ prefix, e.key, item.typeName() }, null);
                continue;
            }
            try out.append(d.a, .{ .v = try d.a.dupe(u8, item.data.string), .src = d.src(item.span) });
        }
    }

    fn set(d: *Decoder, e: *const toml.Entry, prefix: []const u8, out: *Set) !void {
        var list: std.ArrayList(Str) = .empty;
        try d.stringList(e, prefix, &list);
        for (list.items) |s| try out.add(d.a, .{ .name = s.v, .src = s.src });
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
    try validatePackages(c, diags);
    try validateServices(c, diags);
    try validateSystem(c, diags);
    try validateRepos(c, diags);
    try validateModules(c, diags);
    if (c.desktop.session_config) |sc| {
        if (c.desktop.session == null) try diags.add(.bad_value, sc.src, "session_config needs a session", .{}, "set `session = \"hyprland\"` in [desktop] too");
    }
    try validateFiles(c, diags);
    try validateSysctl(c, diags);
    try validateUsers(c, diags);
}

fn validatePackages(c: *const Config, diags: *diag.List) !void {
    for ([_]*const Set{ &c.packages, &c.aur }) |set| {
        for (set.items.items) |it| {
            if (!validPackageName(it.name)) try badPackageName(diags, it.name, it.src);
        }
    }
}

fn validateServices(c: *const Config, diags: *diag.List) !void {
    for (c.services.entries.items) |e| {
        if (!knownService(c, e.name)) try unknownService(diags, e.name, e.value.src);
        const u = e.value.unit orelse continue;
        if (!validUnitName(u.v)) try diags.add(.bad_value, u.src, "\"{s}\" isn't a unit name", .{u.v}, "a unit name ends in its type, like tailscaled.service, and uses letters, digits, and :-_.@\\");
    }
}

fn validateSystem(c: *const Config, diags: *diag.List) !void {
    inline for (comptime keysOf(System)) |key| {
        if (@field(c.system, key)) |v| {
            if (systemProblem(key, v.v)) |hint| try diags.add(.bad_value, v.src, "\"{s}\" isn't a valid {s}", .{ v.v, key }, hint);
        }
    }
}

fn validateRepos(c: *const Config, diags: *diag.List) !void {
    const arch_repos = [_][]const u8{ "options", "core", "extra", "multilib", "core-testing", "extra-testing", "multilib-testing" };
    for (c.repos.entries.items) |e| {
        const r = &e.value;
        if (e.name.len == 0 or !onlyAlnumOr(e.name, "-_.") or lists.contains(&arch_repos, e.name)) {
            try diags.add(.bad_value, r.src, "\"{s}\" can't be a repository's name here", .{e.name}, "use letters, digits, dashes, dots, and underscores, and not one of arch's own repositories");
        }
        if (r.server) |sv| {
            if (!lists.startsWithAny(sv.v, &.{ "https://", "http://", "file://" }) or hasControl(sv.v) or std.mem.indexOfScalar(u8, sv.v, ' ') != null) {
                try diags.add(.bad_value, sv.src, "\"{s}\" isn't a server url", .{sv.v}, "servers start with https://, http://, or file://, like pacman.conf's");
            } else if (std.mem.startsWith(u8, sv.v, "http://") and r.key == null) {
                // unsigned packages over plain http: anyone on the way
                // could hand the machine their own.
                try diags.add(.bad_value, sv.src, "repos.{s} is plain http with no key", .{e.name}, "use https, or add the repository's signing key with `key = \"<fingerprint>\"`");
            }
        } else try diags.add(.bad_value, r.src, "repos.{s} needs a server", .{e.name}, "like `server = \"https://example.org/$repo/$arch\"`");
        if (r.key) |k| {
            if (!isFingerprint(k.v)) try diags.add(.bad_value, k.src, "\"{s}\" isn't a key fingerprint", .{k.v}, "use the full 40-character fingerprint, like pacman-key --list-keys shows");
        }
    }
}

fn validateModules(c: *const Config, diags: *diag.List) !void {
    for (c.boot.modules.items.items) |m| {
        if (m.name.len == 0 or !onlyAlnumOr(m.name, "_-")) try diags.add(.bad_value, m.src, "\"{s}\" isn't a kernel module name", .{m.name}, "module names are letters, digits, dashes, and underscores, like i2c-dev");
    }
}

fn validateFiles(c: *const Config, diags: *diag.List) !void {
    // files os makes from other keys. a [files] entry for one of them
    // would fight it on every apply.
    const made = try planner.desiredFiles(diags.arena.allocator(), c, &.{});
    for (c.files.entries.items) |e| {
        const f = &e.value;
        if (filePathProblem(e.name)) |hint| try diags.add(.bad_value, f.src, "\"{s}\" isn't a path os can write", .{e.name}, hint);
        for (made) |m| {
            const cause = m.cause orelse continue;
            if (!std.mem.eql(u8, m.path, e.name)) continue;
            try diags.addHint(.bad_value, f.src, "os writes {s} itself", .{e.name}, "`{s}` in the config makes this file; drop the [files] entry", .{cause});
        }
        const given = @as(u8, @intFromBool(f.source != null)) + @intFromBool(f.text != null) + @intFromBool(f.secret != null);
        if (given != 1) {
            try diags.add(.bad_value, f.src, "{s} needs exactly one of source, text, or secret", .{e.name}, "source names a file next to the config, text is the content itself, and secret names a value `os secret set` keeps");
        }
        if (f.secret) |s| {
            if (secrets.nameProblem(s.v)) |hint| try diags.add(.bad_value, s.src, "\"{s}\" isn't a secret's name", .{s.v}, hint);
        }
        if (f.mode) |m| {
            if (!validMode(m.v)) try diags.add(.bad_value, m.src, "\"{s}\" isn't a file mode", .{m.v}, "write it in octal, like \"0644\" or \"0600\"");
        }
    }
}

fn validateSysctl(c: *const Config, diags: *diag.List) !void {
    for (c.sysctl.entries.items) |e| {
        if (e.name.len == 0 or std.mem.indexOfAny(u8, e.name, " =") != null or hasControl(e.name)) {
            try diags.add(.bad_value, e.value.src, "\"{s}\" isn't a sysctl key", .{e.name}, "keys look like \"vm.swappiness\"");
        }
        if (hasControl(e.value.v.text)) try diags.add(.bad_value, e.value.src, "sysctl.{s} has a line break or control character in it", .{e.name}, "a sysctl value is one line");
    }
}

fn validateUsers(c: *const Config, diags: *diag.List) !void {
    for (c.users.entries.items) |u| {
        if (!validUserName(u.name)) {
            try diags.add(.bad_value, u.value.src, "\"{s}\" isn't a valid user name", .{u.name}, name_rule);
        }
        if (systemUser(u.name)) {
            try diags.add(.bad_value, u.value.src, "os can't manage the system account \"{s}\"", .{u.name}, "os manages regular users, uid 1000 and up");
        }
        for (u.value.groups.items.items) |g| {
            if (!validUserName(g.name)) try diags.add(.bad_value, g.src, "\"{s}\" isn't a valid group name", .{g.name}, name_rule);
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

/// why os can't write a file at `p`, or null if it can: it wants a plain
/// absolute path, outside os's own state.
pub fn filePathProblem(p: []const u8) ?[]const u8 {
    if (p.len < 2 or p[0] != '/' or p[p.len - 1] == '/') return "files are keyed by their full path, like \"/etc/motd\"";
    if (hasOddSegment(p[1..])) return "write the path without //, . or .. in it";
    for ([_][]const u8{ "/etc/yoq", "/var/lib/yoq" }) |own| {
        if (std.mem.startsWith(u8, p, own) and (p.len == own.len or p[own.len] == '/')) return "os keeps its own state there";
    }
    return null;
}

/// whether a /-separated path has an empty, "." or ".." part.
fn hasOddSegment(p: []const u8) bool {
    var parts = std.mem.splitScalar(u8, p, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

/// three or four octal digits, like "644" or "0600".
fn validMode(m: []const u8) bool {
    if (m.len < 3 or m.len > 4) return false;
    for (m) |ch| {
        if (ch < '0' or ch > '7') return false;
    }
    return true;
}

/// a full pgp key fingerprint: 40 hex digits.
fn isFingerprint(k: []const u8) bool {
    if (k.len != 40) return false;
    for (k) |ch| {
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

/// a newline, tab, or other control character, which would start a new
/// line or field in the files os writes from config values.
fn hasControl(s: []const u8) bool {
    for (s) |ch| {
        if (std.ascii.isControl(ch)) return true;
    }
    return false;
}

/// whether every byte of `s` is a letter, a digit, or one of `extra`.
fn onlyAlnumOr(s: []const u8, extra: []const u8) bool {
    for (s) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, extra, ch) == null) return false;
    }
    return true;
}

/// systemd's unit names: a name and a type suffix, from letters, digits,
/// and :-_.@\, and never starting with a dash, which tools would take for
/// an option.
fn validUnitName(n: []const u8) bool {
    if (n.len == 0 or n[0] == '-' or !onlyAlnumOr(n, ":-_.@\\")) return false;
    const dot = std.mem.lastIndexOfScalar(u8, n, '.') orelse return false;
    return dot > 0 and lists.contains(&.{ "service", "socket", "timer", "path", "target", "mount", "automount", "swap", "slice", "scope", "device" }, n[dot + 1 ..]);
}

/// pacman's rule: letters, digits, and @._+-, not starting with - or .
pub fn validPackageName(n: []const u8) bool {
    if (n.len == 0 or n[0] == '-' or n[0] == '.') return false;
    return onlyAlnumOr(n, "@._+-");
}

pub fn badPackageName(diags: *diag.List, name: []const u8, at: ?diag.Span) !void {
    try diags.add(.bad_value, at, "\"{s}\" isn't a valid package name", .{name}, "use letters, digits, and @._+-, not starting with - or .");
}

/// why a `[system]` value can't be used, or null if it can. the values end
/// up as lines in files like /etc/locale.conf, and the time zone as a path.
pub fn systemProblem(key: []const u8, v: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, key, "hostname")) {
        return if (validHostname(v)) null else "use dot-separated labels of letters, digits, and dashes, up to 63 characters each";
    }
    if (v.len == 0) return "leave it out instead";
    if (hasControl(v)) return "control characters like newlines can't be in it";
    if (std.mem.eql(u8, key, "timezone") and hasOddSegment(v)) return "zone names look like America/New_York";
    return null;
}

/// a hostname or a dotted name like atlas.lan: labels of letters, digits,
/// and dashes, not starting or ending with a dash.
fn validHostname(h: []const u8) bool {
    if (h.len == 0 or h.len > 253) return false;
    var labels = std.mem.splitScalar(u8, h, '.');
    while (labels.next()) |l| {
        if (l.len == 0 or l.len > 63 or l[0] == '-' or l[l.len - 1] == '-') return false;
        if (!onlyAlnumOr(l, "-")) return false;
    }
    return true;
}

/// accounts arch's own packages make, below uid 1000. the observer only
/// sees regular users, so declaring one of these would never settle.
pub fn systemUser(n: []const u8) bool {
    return lists.contains(&.{ "root", "bin", "daemon", "mail", "ftp", "http", "nobody", "dbus", "polkitd", "git" }, n) or std.mem.startsWith(u8, n, "systemd-");
}

const name_rule = "start with a lowercase letter or _, then lowercase letters, digits, _ or -, up to 32 characters";

/// shadow's rule for user and group names.
pub fn validUserName(n: []const u8) bool {
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

test "repositories name a server, and a key by its fingerprint" {
    const f = try Fixture.init(
        \\[repos.chaotic-aur]
        \\server = "https://cdn-mirror.chaotic.cx/$repo/$arch"
        \\key = "3056513887B78AEB"
        \\[repos.core]
        \\server = "ftp://x"
        \\[repos.mine]
        \\key = "EF925EA60F33D0CB85C44AD13056513887B78AEB"
        \\
    );
    defer f.deinit();
    try validate(&f.part.config, &f.diags);
    try testing.expectEqual(4, f.diags.items.items.len);
    try f.expectDiag(0, .bad_value, 3, "\"3056513887B78AEB\" isn't a key fingerprint");
    try f.expectDiag(1, .bad_value, 4, "\"core\" can't be a repository's name here");
    try f.expectDiag(2, .bad_value, 5, "\"ftp://x\" isn't a server url");
    try testing.expect(validUnitName("getty@tty1.service"));
    try testing.expect(!validUnitName("--root=/x"));
    try testing.expect(!validUnitName("tailscaled"));
    try testing.expect(hasControl("1\nkernel.x = 2"));
    try f.expectDiag(3, .bad_value, 6, "repos.mine needs a server");
}

test "kernel module names" {
    const f = try Fixture.init("[boot]\nmodules = [\"i2c-dev\", \"nct6775\", \"bad name\"]\n");
    defer f.deinit();
    try validate(&f.part.config, &f.diags);
    try testing.expectEqual(1, f.diags.items.items.len);
    try f.expectDiag(0, .bad_value, 2, "\"bad name\" isn't a kernel module name");
}

test "a session's config needs a session" {
    const f = try Fixture.init("[desktop]\nsession_config = \"files/hyprland.conf\"\n");
    defer f.deinit();
    try validate(&f.part.config, &f.diags);
    try testing.expectEqual(1, f.diags.items.items.len);
    try f.expectDiag(0, .bad_value, 2, "session_config needs a session");
}

test "[files] can't name a file os writes itself" {
    const f = try Fixture.init(
        \\[sysctl]
        \\"vm.swappiness" = 10
        \\[files."/etc/sysctl.d/99-yoq.conf"]
        \\text = "vm.swappiness = 60\n"
        \\[files."/etc/motd"]
        \\text = "hi\n"
        \\
    );
    defer f.deinit();
    try validate(&f.part.config, &f.diags);
    try testing.expectEqual(1, f.diags.items.items.len);
    try f.expectDiag(0, .bad_value, 3, "os writes /etc/sysctl.d/99-yoq.conf itself");
    try testing.expectEqualStrings("`sysctl` in the config makes this file; drop the [files] entry", f.diags.items.items[0].hint.?);
}

test "[files] paths are plain and stay out of os's own state" {
    for ([_][]const u8{ "etc/motd", "/", "/etc/../../tmp/x", "/etc/./motd", "/etc//motd", "/etc/motd/", "/etc/yoq/machine.toml", "/var/lib/yoq", "/var/lib/yoq/ids" }) |p| {
        try testing.expect(filePathProblem(p) != null);
    }
    for ([_][]const u8{ "/etc/motd", "/etc/yoqx", "/var/lib/yoq-other/x", "/etc/..hidden" }) |p| {
        try testing.expectEqual(null, filePathProblem(p));
    }
    const f = try Fixture.init("[files.\"/etc/../../tmp/x\"]\ntext = \"x\"\n");
    defer f.deinit();
    try validate(&f.part.config, &f.diags);
    try testing.expectEqual(1, f.diags.items.items.len);
    try f.expectDiag(0, .bad_value, 1, "\"/etc/../../tmp/x\" isn't a path os can write");
}

test "a file takes exactly one of source, text, and secret" {
    const f = try Fixture.init(
        \\[files."/etc/wifi.psk"]
        \\secret = "wifi/home"
        \\[files."/etc/both"]
        \\text = "x"
        \\secret = "x"
        \\[files."/etc/none"]
        \\mode = "0600"
        \\[files."/etc/badname"]
        \\secret = "../key"
        \\[files."/etc/shared"]
        \\secret = "shared"
        \\mode = "0644"
        \\
    );
    defer f.deinit();
    try validate(&f.part.config, &f.diags);
    try testing.expectEqual(3, f.diags.items.items.len);
    try f.expectDiag(0, .bad_value, 3, "/etc/both needs exactly one of source, text, or secret");
    try f.expectDiag(1, .bad_value, 6, "/etc/none needs exactly one of source, text, or secret");
    try f.expectDiag(2, .bad_value, 9, "\"../key\" isn't a secret's name");
    const files = &f.part.config.files;
    try testing.expectEqualStrings("wifi/home", files.get("/etc/wifi.psk").?.secret.?.v);
    try testing.expectEqualStrings("0600", files.get("/etc/wifi.psk").?.modeOf());
    try testing.expectEqualStrings("0644", files.get("/etc/shared").?.modeOf());
}

test "a console login needs no session" {
    const f = try Fixture.init("[desktop]\nlogin = \"tty\"\n");
    defer f.deinit();
    try validate(&f.part.config, &f.diags);
    try testing.expectEqual(0, f.diags.items.items.len);
}

test "group names follow the user name rules" {
    const f = try Fixture.init("[users.kacy]\ngroups = [\"wheel\", \"-r\"]\n");
    defer f.deinit();
    try validate(&f.part.config, &f.diags);
    try testing.expectEqual(1, f.diags.items.items.len);
    try f.expectDiag(0, .bad_value, 2, "\"-r\" isn't a valid group name");
}

test "[system] values" {
    try testing.expectEqual(null, systemProblem("hostname", "atlas.lan"));
    try testing.expectEqual(null, systemProblem("hostname", "a-1.b"));
    try testing.expect(systemProblem("hostname", "atlas.") != null);
    try testing.expect(systemProblem("hostname", "a..b") != null);
    try testing.expect(systemProblem("hostname", "a.-b") != null);
    try testing.expectEqual(null, systemProblem("timezone", "America/New_York"));
    try testing.expect(systemProblem("timezone", "/etc/passwd") != null);
    try testing.expect(systemProblem("timezone", "../../etc/passwd") != null);
    try testing.expectEqual(null, systemProblem("locale", "en_US.UTF-8"));
    try testing.expect(systemProblem("locale", "C\nLD_PRELOAD=/x") != null);
    try testing.expect(systemProblem("keymap", "us\r") != null);

    const f = try Fixture.init("[system]\nhostname = \"atlas.lan\"\nlocale = \"C\\nX=1\"\n");
    defer f.deinit();
    try validate(&f.part.config, &f.diags);
    try testing.expectEqual(1, f.diags.items.items.len);
    try f.expectDiag(0, .bad_value, 3, "\"C\nX=1\" isn't a valid locale");
}

test "system accounts can't be declared" {
    const f = try Fixture.init("[users.root]\nshell = \"zsh\"\n[users.kacy]\n");
    defer f.deinit();
    try validate(&f.part.config, &f.diags);
    try testing.expectEqual(1, f.diags.items.items.len);
    try f.expectDiag(0, .bad_value, 1, "os can't manage the system account \"root\"");
}

test "package names follow pacman's rules" {
    try testing.expect(validPackageName("lib32-nvidia-utils"));
    try testing.expect(validPackageName("gtk+3"));
    try testing.expect(validPackageName("python3.12"));
    try testing.expect(!validPackageName(""));
    try testing.expect(!validPackageName("-rf"));
    try testing.expect(!validPackageName("has space"));
}
