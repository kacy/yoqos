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

/// where config files live. tests use a map; the cli uses the disk.
pub const Files = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) ReadError![]u8,
    /// replaces the file in one step, so a crash leaves the old or the new
    /// content, never half of each.
    writeFn: *const fn (ctx: *anyopaque, path: []const u8, bytes: []const u8) WriteError!void,

    pub const ReadError = error{ FileNotFound, ReadFailed, OutOfMemory };
    pub const WriteError = error{ WriteFailed, OutOfMemory };

    pub fn read(f: Files, gpa: Allocator, path: []const u8) ReadError![]u8 {
        return f.readFn(f.ctx, gpa, path);
    }

    pub fn write(f: Files, path: []const u8, bytes: []const u8) WriteError!void {
        return f.writeFn(f.ctx, path, bytes);
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
        try l.fileContents(&loaded.config);
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
                    try l.diags.add(.include_missing, f, "included file {s} {s}", .{ path, why }, null);
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
            const c = try l.loadFile(child, inc.src) orelse continue;
            try mergeInto(l.a, &merged, &c);
            for (c.removed.items.items) |it| try merged.removed.add(l.a, it);
        }
        for (part.unset.items) |u| try l.unset(&merged, u);
        for (part.remove.packages.items.items) |it| _ = merged.packages.remove(it.name);
        for (part.remove.aur.items.items) |it| _ = merged.aur.remove(it.name);
        try mergeInto(l.a, &merged, &part.config);
        for (part.remove.packages.items.items) |it| try merged.removed.add(l.a, it);
        return merged;
    }

    /// reads what each `[files]` entry holds. a source is relative to the
    /// file that names it, which its span records.
    fn fileContents(l: *Loader, c: *Config) !void {
        for (c.files.entries.items) |*e| {
            const f = &e.value;
            if (f.text) |t| f.content = t.v;
            const source = f.source orelse continue;
            const dir = std.fs.path.dirnamePosix(source.src.file) orelse ".";
            const path = try std.fs.path.resolvePosix(l.a, &.{ dir, source.v });
            f.content = l.files.read(l.a, path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try l.diags.add(.source_missing, source.src, "{s} can't be read, for {s}", .{ path, e.name }, null);
                    continue;
                },
            };
        }
    }

    fn cycle(l: *Loader, start: usize, path: []const u8, from: Src) error{OutOfMemory}!?Config {
        var chain: std.Io.Writer.Allocating = .init(l.a);
        for (l.stack.items[start..]) |p| chain.writer.print("{s} -> ", .{p}) catch return error.OutOfMemory;
        chain.writer.writeAll(path) catch return error.OutOfMemory;
        try l.diags.add(.include_cycle, from, "include cycle: {s}", .{chain.written()}, null);
        return null;
    }

    /// clears a key that an include set. the path names a key the way the
    /// config file would, like "desktop.audio" or "users.guest".
    fn unset(l: *Loader, c: *Config, u: config.Str) !void {
        var segs: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, u.v, '.');
        while (it.next()) |seg| try segs.append(l.a, seg);
        if (!clear(Config, c, segs.items)) {
            try l.diags.add(.bad_value, u.src, "\"{s}\" isn't a key that unset can clear", .{u.v}, "name a key like \"desktop.audio\" or \"users.guest\"");
        }
    }
};

/// clears the key at `segs` below `target`, if it's set. returns false if
/// the path doesn't name a key at all. `target` is null when the path runs
/// through an entry that doesn't exist; the path is still checked.
fn clear(comptime T: type, target: ?*T, segs: []const []const u8) bool {
    if (segs.len == 0) {
        if (@typeInfo(T) == .optional) {
            if (target) |t| t.* = null;
        } else if (comptime !@hasField(T, "src")) {
            if (target) |t| t.* = .{};
        } else unreachable; // named entries are removed by their table
        return true;
    }
    if (T == config.Set or @typeInfo(T) == .optional) return false;
    if (comptime config.isNamed(T)) {
        if (segs.len == 1) {
            if (target) |t| _ = t.remove(segs[0]);
            return true;
        }
        if (comptime config.isVal(T.Value)) return false;
        return clear(T.Value, if (target) |t| t.get(segs[0]) else null, segs[1..]);
    }
    inline for (comptime config.keysOf(T)) |name| {
        if (std.mem.eql(u8, segs[0], name)) {
            return clear(@FieldType(T, name), if (target) |t| &@field(t, name) else null, segs[1..]);
        }
    }
    return false;
}

/// lays `src` over `dst`: sets merge, named tables merge entry by entry, and
/// any other value set in `src` replaces the one in `dst`. `src` is used
/// up; its lists may move into `dst`.
pub fn mergeInto(a: Allocator, dst: *Config, src: *const Config) !void {
    try merge(a, Config, dst, src);
}

fn merge(a: Allocator, comptime T: type, dst: *T, src: *const T) !void {
    if (T == config.Set) {
        for (src.items.items) |it| try dst.add(a, it);
    } else if (@typeInfo(T) == .optional or comptime config.isVal(T)) {
        if (@typeInfo(T) != .optional or src.* != null) dst.* = src.*;
    } else if (comptime config.isNamed(T)) {
        for (src.entries.items) |*e| {
            if (dst.get(e.name)) |v| try merge(a, T.Value, v, &e.value) else try dst.entries.append(a, e.*);
        }
    } else {
        inline for (comptime config.keysOf(T)) |name| try merge(a, @FieldType(T, name), &@field(dst, name), &@field(src, name));
    }
}

// -- tests --

const testing = std.testing;

pub const MemFiles = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// paths and contents written through `files()`, owned by the map.
    written: std.ArrayList([]u8) = .empty,

    pub fn put(m: *MemFiles, path: []const u8, content: []const u8) !void {
        try m.map.put(testing.allocator, path, content);
    }

    pub fn get(m: *MemFiles, path: []const u8) ?[]const u8 {
        return m.map.get(path);
    }

    pub fn deinit(m: *MemFiles) void {
        for (m.written.items) |w| testing.allocator.free(w);
        m.written.deinit(testing.allocator);
        m.map.deinit(testing.allocator);
    }

    pub fn files(m: *MemFiles) Files {
        return .{ .ctx = m, .readFn = read, .writeFn = write };
    }

    fn write(ctx: *anyopaque, path: []const u8, bytes: []const u8) Files.WriteError!void {
        const m: *MemFiles = @ptrCast(@alignCast(ctx));
        // the caller's path may not outlive the call, so the map keeps a copy.
        const key = try testing.allocator.dupe(u8, path);
        try m.written.append(testing.allocator, key);
        const copy = try testing.allocator.dupe(u8, bytes);
        try m.written.append(testing.allocator, copy);
        try m.map.put(testing.allocator, key, copy);
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
        if (r.loaded) |*l| l.deinit();
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

    const pkgs = c.packages.items.items;
    try testing.expectEqual(4, pkgs.len);
    try testing.expectEqualStrings("git", pkgs[0].name);
    try testing.expectEqualStrings("/etc/yoq/base.toml", pkgs[0].src.file);
    try testing.expectEqualStrings("neovim", pkgs[3].name);

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

    // a [remove] counts from any file, for the planner's core packages.
    try testing.expect(c.removed.contains("nano"));
    try r.fs.put("host.toml", "include = [\"machine.toml\"]\n");
    try testing.expect((try r.load("host.toml")).removed.contains("nano"));
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

test "unset reaches every kind of key" {
    var r: Run = .{};
    defer r.deinit();
    try r.fs.put("base.toml",
        \\packages = ["git"]
        \\[providers]
        \\java-runtime = "jre-openjdk"
        \\[system]
        \\hostname = "base"
        \\locale = "C.UTF-8"
        \\[users.kacy]
        \\shell = "zsh"
        \\groups = ["wheel"]
        \\[services.custom]
        \\unit = "custom.service"
        \\package = "custom"
        \\
    );
    try r.fs.put("machine.toml",
        \\include = ["base.toml"]
        \\unset = ["packages", "providers.java-runtime", "system", "users.kacy.groups", "services.custom.unit", "users.nobody.shell"]
        \\[services.custom]
        \\unit = "other.service"
        \\
    );
    const c = try r.load("machine.toml");
    try r.expectClean();
    try testing.expectEqual(0, c.packages.items.items.len);
    try testing.expectEqual(null, c.providers.get("java-runtime"));
    try testing.expectEqual(null, c.system.hostname);
    try testing.expectEqual(null, c.system.locale);
    try testing.expectEqualStrings("zsh", c.users.get("kacy").?.shell.?.v);
    try testing.expectEqual(0, c.users.get("kacy").?.groups.items.items.len);
    try testing.expectEqualStrings("other.service", c.services.get("custom").?.unit.?.v);
}

test "unset rejects paths that aren't keys" {
    var r: Run = .{};
    defer r.deinit();
    try r.fs.put("machine.toml", "unset = [\"packages.git\", \"users.kacy.colour\", \"system.hostname.x\", \"bogus\", \"providers.a.b\"]\n");
    _ = try r.load("machine.toml");
    try testing.expectEqual(5, r.diags.items.items.len);
    for (r.diags.items.items) |d| try testing.expectEqual(diag.Code.bad_value, d.code);
}

test "files read their source next to the file that names them" {
    var r: Run = .{};
    defer r.deinit();
    try r.fs.put("/etc/yoq/profiles/base.toml",
        \\[files."/etc/motd"]
        \\source = "motd"
        \\
    );
    try r.fs.put("/etc/yoq/profiles/motd", "welcome\n");
    try r.fs.put("/etc/yoq/machine.toml",
        \\include = ["profiles/base.toml"]
        \\[files."/etc/issue"]
        \\text = "atlas\n"
        \\mode = "0600"
        \\[sysctl]
        \\"vm.swappiness" = 10
        \\"kernel.printk" = "3 3 3 3"
        \\
    );
    const c = try r.load("/etc/yoq/machine.toml");
    try r.expectClean();
    try testing.expectEqualStrings("welcome\n", c.files.get("/etc/motd").?.content.?);
    try testing.expectEqualStrings("atlas\n", c.files.get("/etc/issue").?.content.?);
    try testing.expectEqualStrings("0600", c.files.get("/etc/issue").?.modeOf());
    try testing.expectEqualStrings("10", c.sysctl.get("vm.swappiness").?.v.text);
    try testing.expectEqualStrings("3 3 3 3", c.sysctl.get("kernel.printk").?.v.text);

    try r.fs.put("/etc/yoq/machine.toml", "[files.\"/etc/motd\"]\nsource = \"gone\"\n");
    _ = try r.load("/etc/yoq/machine.toml");
    try testing.expectEqual(diag.Code.source_missing, r.diags.items.items[0].code);
}
