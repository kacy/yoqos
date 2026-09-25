//! loads a config file with its includes and merges everything into one
//! `Config`.
//!
//! for each file: merge its includes in order, apply its `unset` and
//! `[remove]` to that result, then lay the file's own settings on top. the
//! including file always wins. sets (packages, aur, groups, carry) merge;
//! everything else replaces.

const std = @import("std");
const config = @import("config.zig");
const toml = @import("toml.zig");
const diag = @import("diag.zig");
const Allocator = std.mem.Allocator;
const Config = config.Config;
const Src = config.Src;

/// where config files come from. tests use a map; the cli reads the disk.
pub const Files = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) ReadError![]u8,

    pub const ReadError = error{ FileNotFound, ReadFailed, OutOfMemory };

    fn read(f: Files, gpa: Allocator, path: []const u8) ReadError![]u8 {
        return f.readFn(f.ctx, gpa, path);
    }
};

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    config: Config,
    /// every file read, in the order they were loaded.
    files: std.ArrayList([]const u8),

    pub fn deinit(l: *Loaded) void {
        l.arena.deinit();
    }
};

/// loads `path` and everything it includes. problems go to `diags`, and the
/// result holds whatever could be read; check `diags` before trusting it.
pub fn load(gpa: Allocator, files: Files, path: []const u8, diags: *diag.List) error{OutOfMemory}!Loaded {
    var loaded: Loaded = .{ .arena = .init(gpa), .config = .{}, .files = .empty };
    errdefer loaded.arena.deinit();
    var l: Loader = .{ .a = loaded.arena.allocator(), .gpa = gpa, .files = files, .diags = diags, .out = &loaded.files };
    const top = try std.fs.path.resolvePosix(l.a, &.{path});
    if (try l.loadFile(top, null)) |c| {
        loaded.config = c;
        try config.validate(&loaded.config, diags);
    }
    return loaded;
}

const Loader = struct {
    a: Allocator,
    gpa: Allocator,
    files: Files,
    diags: *diag.List,
    out: *std.ArrayList([]const u8),
    stack: std.ArrayList([]const u8) = .empty,

    fn loadFile(l: *Loader, path: []const u8, from: ?Src) error{OutOfMemory}!?Config {
        for (l.stack.items, 0..) |p, i| {
            if (std.mem.eql(u8, p, path)) return l.cycle(i, path, from.?);
        }

        const bytes = l.files.read(l.gpa, path) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const why = if (e == error.FileNotFound) "doesn't exist" else "can't be read";
                if (from) |f| {
                    try l.diags.add(.include_missing, f.span(), "included file {s} {s}", .{ path, why }, null);
                } else {
                    try l.diags.add(.config_missing, null, "{s} {s}", .{ path, why }, "run `os init`, or point at a config with --config");
                }
                return null;
            },
        };
        defer l.gpa.free(bytes);
        try l.out.append(l.a, path);

        var info: toml.ErrorInfo = .{};
        var doc = toml.parse(l.gpa, bytes, &info) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => {
                try l.diags.add(info.code, .{ .file = path, .line = info.pos.line, .column = info.pos.column }, "{s}", .{info.message()}, null);
                return null;
            },
        };
        defer doc.deinit();
        const part = try config.decode(l.a, path, doc.root, l.diags);

        try l.stack.append(l.a, path);
        defer _ = l.stack.pop();

        var merged: Config = .{};
        const dir = std.fs.path.dirnamePosix(path) orelse ".";
        for (part.include.items) |inc| {
            const child = try std.fs.path.resolvePosix(l.a, &.{ dir, inc.v });
            var c = try l.loadFile(child, inc.src) orelse continue;
            try mergeInto(l.a, &merged, &c);
        }
        for (part.unset.items) |u| try l.unset(&merged, u);
        for (part.remove.packages.items.items) |it| _ = merged.packages.remove(it.name);
        for (part.remove.aur.items.items) |it| _ = merged.aur.remove(it.name);
        var own = part.config;
        try mergeInto(l.a, &merged, &own);
        return merged;
    }

    fn cycle(l: *Loader, start: usize, path: []const u8, from: Src) error{OutOfMemory}!?Config {
        var chain: std.Io.Writer.Allocating = .init(l.a);
        for (l.stack.items[start..]) |p| chain.writer.print("{s} -> ", .{p}) catch return error.OutOfMemory;
        chain.writer.writeAll(path) catch return error.OutOfMemory;
        try l.diags.add(.include_cycle, from.span(), "include cycle: {s}", .{chain.written()}, null);
        return null;
    }

    /// clears a key that an include set. the path names a key the way the
    /// config file would, like "desktop.audio" or "users.guest".
    fn unset(l: *Loader, c: *Config, u: config.Str) !void {
        var it = std.mem.splitScalar(u8, u.v, '.');
        const head = it.next().?;
        const second = it.next();
        const third = it.next();
        const ok = if (it.next() != null) false else if (second == null)
            unsetTop(c, head)
        else if (third == null)
            unsetSecond(c, head, second.?)
        else
            unsetThird(c, head, second.?, third.?);
        if (!ok) try l.diags.add(.bad_value, u.src.span(), "\"{s}\" isn't a key that unset can clear", .{u.v}, "name a key like \"desktop.audio\" or \"users.guest\"");
    }
};

fn unsetTop(c: *Config, key: []const u8) bool {
    if (eql(key, "packages")) {
        c.packages = .{};
    } else if (eql(key, "aur")) {
        c.aur = .{};
    } else if (eql(key, "providers")) {
        c.providers = .{};
    } else if (eql(key, "system")) {
        c.system = .{};
    } else if (eql(key, "boot")) {
        c.boot = .{};
    } else if (eql(key, "hardware")) {
        c.hardware = .{};
    } else if (eql(key, "users")) {
        c.users = .{};
    } else if (eql(key, "desktop")) {
        c.desktop = .{};
    } else if (eql(key, "services")) {
        c.services = .{};
    } else return false;
    return true;
}

fn unsetSecond(c: *Config, head: []const u8, key: []const u8) bool {
    if (eql(head, "system")) {
        if (eql(key, "hostname")) c.system.hostname = null else if (eql(key, "timezone")) c.system.timezone = null else if (eql(key, "locale")) c.system.locale = null else if (eql(key, "keymap")) c.system.keymap = null else return false;
    } else if (eql(head, "boot")) {
        if (eql(key, "kernel")) c.boot.kernel = null else return false;
    } else if (eql(head, "hardware")) {
        if (eql(key, "cpu")) c.hardware.cpu = null else if (eql(key, "gpu")) c.hardware.gpu = null else return false;
    } else if (eql(head, "desktop")) {
        if (eql(key, "session")) c.desktop.session = null else if (eql(key, "audio")) c.desktop.audio = null else return false;
    } else if (eql(head, "state")) {
        if (eql(key, "carry")) c.state.carry = .{} else return false;
    } else if (eql(head, "providers")) {
        _ = c.providers.remove(key);
    } else if (eql(head, "users")) {
        _ = c.users.remove(key);
    } else if (eql(head, "services")) {
        _ = c.services.remove(key);
    } else return false;
    return true;
}

fn unsetThird(c: *Config, head: []const u8, name: []const u8, key: []const u8) bool {
    if (eql(head, "users")) {
        const u = c.users.get(name) orelse return eql(key, "shell") or eql(key, "groups");
        if (eql(key, "shell")) u.shell = null else if (eql(key, "groups")) u.groups = .{} else return false;
    } else if (eql(head, "services")) {
        const s = c.services.get(name) orelse return eql(key, "enabled") or eql(key, "unit") or eql(key, "package");
        if (eql(key, "enabled")) s.enabled = null else if (eql(key, "unit")) s.unit = null else if (eql(key, "package")) s.package = null else return false;
    } else return false;
    return true;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn override(dst: anytype, src: @TypeOf(dst.*)) void {
    if (src != null) dst.* = src;
}

fn mergeSet(a: Allocator, dst: *config.Set, src: *const config.Set) !void {
    for (src.items.items) |it| try dst.add(a, it);
}

/// lays `src` over `dst`. `src` is used up: its lists may move into `dst`.
pub fn mergeInto(a: Allocator, dst: *Config, src: *Config) !void {
    override(&dst.version, src.version);
    try mergeSet(a, &dst.packages, &src.packages);
    try mergeSet(a, &dst.aur, &src.aur);
    for (src.providers.entries.items) |e| {
        if (dst.providers.get(e.name)) |v| v.* = e.value else try dst.providers.entries.append(a, e);
    }
    inline for (.{ "hostname", "timezone", "locale", "keymap" }) |f| override(&@field(dst.system, f), @field(src.system, f));
    override(&dst.boot.kernel, src.boot.kernel);
    override(&dst.hardware.cpu, src.hardware.cpu);
    override(&dst.hardware.gpu, src.hardware.gpu);
    override(&dst.desktop.session, src.desktop.session);
    override(&dst.desktop.audio, src.desktop.audio);
    for (src.users.entries.items) |e| {
        const u = dst.users.get(e.name) orelse {
            try dst.users.entries.append(a, e);
            continue;
        };
        override(&u.shell, e.value.shell);
        try mergeSet(a, &u.groups, &e.value.groups);
    }
    for (src.services.entries.items) |e| {
        const s = dst.services.get(e.name) orelse {
            try dst.services.entries.append(a, e);
            continue;
        };
        override(&s.enabled, e.value.enabled);
        override(&s.unit, e.value.unit);
        override(&s.package, e.value.package);
    }
    try mergeSet(a, &dst.state.carry, &src.state.carry);
}

// -- tests --

const testing = std.testing;

pub const MemFiles = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn put(m: *MemFiles, path: []const u8, content: []const u8) !void {
        try m.map.put(testing.allocator, path, content);
    }

    pub fn deinit(m: *MemFiles) void {
        m.map.deinit(testing.allocator);
    }

    pub fn files(m: *MemFiles) Files {
        return .{ .ctx = m, .readFn = read };
    }

    fn read(ctx: *anyopaque, gpa: Allocator, path: []const u8) Files.ReadError![]u8 {
        const m: *MemFiles = @ptrCast(@alignCast(ctx));
        const content = m.map.get(path) orelse return error.FileNotFound;
        return gpa.dupe(u8, content);
    }
};

const Run = struct {
    fs: MemFiles = .{},
    diags: diag.List = .init(testing.allocator),
    loaded: ?Loaded = null,

    fn load(r: *Run, path: []const u8) !*Config {
        r.loaded = try compose.load(testing.allocator, r.fs.files(), path, &r.diags);
        return &r.loaded.?.config;
    }

    fn deinit(r: *Run) void {
        if (r.loaded) |*l| l.deinit();
        r.diags.deinit();
        r.fs.deinit();
    }

    fn expectClean(r: *Run) !void {
        if (r.diags.items.items.len == 0) return;
        for (r.diags.items.items) |d| std.debug.print("unexpected: {s}\n", .{d.message});
        return error.TestUnexpectedDiagnostics;
    }
};

const compose = @This();

test "includes merge with the including file winning" {
    var r: Run = .{};
    defer r.deinit();
    try r.fs.put("/etc/yoq/base.toml",
        \\packages = ["git", "nano"]
        \\[system]
        \\timezone = "UTC"
        \\locale = "en_US.UTF-8"
        \\[users.kacy]
        \\shell = "bash"
        \\groups = ["wheel"]
        \\[services]
        \\ssh = true
        \\
    );
    try r.fs.put("/etc/yoq/profiles/desktop.toml",
        \\packages = ["ghostty"]
        \\[desktop]
        \\session = "hyprland"
        \\audio = "pipewire"
        \\
    );
    try r.fs.put("/etc/yoq/machine.toml",
        \\include = ["base.toml", "profiles/desktop.toml"]
        \\packages = ["neovim", "git"]
        \\[system]
        \\hostname = "atlas"
        \\timezone = "America/New_York"
        \\[users.kacy]
        \\shell = "zsh"
        \\groups = ["video"]
        \\[services.ssh]
        \\enabled = false
        \\
    );
    const c = try r.load("/etc/yoq/machine.toml");
    try r.expectClean();

    const names = try c.packages.names(testing.allocator);
    defer testing.allocator.free(names);
    try testing.expectEqual(4, names.len);
    try testing.expectEqualStrings("git", names[0]);
    try testing.expectEqualStrings("/etc/yoq/base.toml", c.packages.items.items[0].src.file);
    try testing.expectEqualStrings("neovim", names[3]);

    try testing.expectEqualStrings("America/New_York", c.system.timezone.?.v);
    try testing.expectEqualStrings("/etc/yoq/machine.toml", c.system.timezone.?.src.file);
    try testing.expectEqualStrings("en_US.UTF-8", c.system.locale.?.v);
    try testing.expectEqualStrings("zsh", c.users.get("kacy").?.shell.?.v);
    try testing.expect(c.users.get("kacy").?.groups.contains("wheel"));
    try testing.expect(c.users.get("kacy").?.groups.contains("video"));
    try testing.expect(!c.services.get("ssh").?.enabled.?.v);
    try testing.expectEqual(3, r.loaded.?.files.items.len);
}

test "remove and unset act on what includes set" {
    var r: Run = .{};
    defer r.deinit();
    try r.fs.put("base.toml",
        \\packages = ["git", "nano"]
        \\[desktop]
        \\session = "hyprland"
        \\audio = "pipewire"
        \\[users.guest]
        \\shell = "bash"
        \\
    );
    try r.fs.put("machine.toml",
        \\include = ["base.toml"]
        \\packages = ["nano-syntax"]
        \\unset = ["desktop.audio", "users.guest"]
        \\[remove]
        \\packages = ["nano"]
        \\
    );
    const c = try r.load("machine.toml");
    try r.expectClean();
    try testing.expect(!c.packages.contains("nano"));
    try testing.expect(c.packages.contains("nano-syntax"));
    try testing.expect(c.desktop.audio == null);
    try testing.expect(c.desktop.session != null);
    try testing.expectEqual(null, c.users.get("guest"));
}

test "unset that names nothing is an error" {
    var r: Run = .{};
    defer r.deinit();
    try r.fs.put("machine.toml", "unset = [\"desktop.wallpaper\", \"services.ssh.enabled\"]\n");
    _ = try r.load("machine.toml");
    try testing.expectEqual(1, r.diags.items.items.len);
    try testing.expectEqual(diag.Code.bad_value, r.diags.items.items[0].code);
    try testing.expectEqualStrings("\"desktop.wallpaper\" isn't a key that unset can clear", r.diags.items.items[0].message);
}

test "missing include and missing config" {
    var r: Run = .{};
    defer r.deinit();
    try r.fs.put("/cfg/machine.toml", "include = [\"gone.toml\"]\npackages = [\"git\"]\n");
    const c = try r.load("/cfg/machine.toml");
    try testing.expectEqual(1, r.diags.items.items.len);
    const d = r.diags.items.items[0];
    try testing.expectEqual(diag.Code.include_missing, d.code);
    try testing.expectEqualStrings("included file /cfg/gone.toml doesn't exist", d.message);
    try testing.expectEqual(1, d.span.?.line);
    try testing.expectEqual(12, d.span.?.column);
    try testing.expect(c.packages.contains("git"));

    var r2: Run = .{};
    defer r2.deinit();
    _ = try r2.load("/etc/yoq/machine.toml");
    try testing.expectEqual(diag.Code.config_missing, r2.diags.items.items[0].code);
}

test "include cycles are reported with the chain" {
    var r: Run = .{};
    defer r.deinit();
    try r.fs.put("a.toml", "include = [\"b.toml\"]\n");
    try r.fs.put("b.toml", "include = [\"./a.toml\"]\n");
    _ = try r.load("a.toml");
    try testing.expectEqual(1, r.diags.items.items.len);
    try testing.expectEqual(diag.Code.include_cycle, r.diags.items.items[0].code);
    try testing.expectEqualStrings("include cycle: a.toml -> b.toml -> a.toml", r.diags.items.items[0].message);
    try testing.expectEqualStrings("b.toml", r.diags.items.items[0].span.?.file);
}

test "syntax errors in an include name that file" {
    var r: Run = .{};
    defer r.deinit();
    try r.fs.put("machine.toml", "include = [\"bad.toml\"]\n");
    try r.fs.put("bad.toml", "\n\nhostname = atlas\n");
    _ = try r.load("machine.toml");
    const d = r.diags.items.items[0];
    try testing.expectEqual(diag.Code.toml_syntax, d.code);
    try testing.expectEqualStrings("bad.toml", d.span.?.file);
    try testing.expectEqual(3, d.span.?.line);
}

test "validation runs on the merged result" {
    var r: Run = .{};
    defer r.deinit();
    try r.fs.put("base.toml", "[services.custom]\nunit = \"custom.service\"\n");
    try r.fs.put("machine.toml", "include = [\"base.toml\"]\n[services.custom]\npackage = \"custom\"\n");
    _ = try r.load("machine.toml");
    try r.expectClean();
}

test "the same file included twice is fine" {
    var r: Run = .{};
    defer r.deinit();
    try r.fs.put("common.toml", "packages = [\"git\"]\n");
    try r.fs.put("a.toml", "include = [\"common.toml\"]\n");
    try r.fs.put("machine.toml", "include = [\"common.toml\", \"a.toml\"]\n");
    const c = try r.load("machine.toml");
    try r.expectClean();
    try testing.expectEqual(1, c.packages.items.items.len);
}
