//! prints a merged config, as canonical toml or as json. with sources on,
//! every value says which file and line it came from.

const std = @import("std");
const config = @import("config.zig");
const toml = @import("toml.zig");
const Config = config.Config;
const Src = config.Src;
const Writer = std.Io.Writer;

/// canonical toml: top-level values first, then one table per section, in
/// the order the config types declare them. named entries like users get
/// their own `[users.<name>]` table.
pub fn writeToml(w: *Writer, c: *const Config, sources: bool) !void {
    var t: TomlOut = .{ .w = w, .sources = sources };
    inline for (comptime config.keysOf(Config)) |name| {
        const T = @FieldType(Config, name);
        if (comptime isLeaf(T)) try t.leaf(name, @field(c, name));
    }
    inline for (comptime config.keysOf(Config)) |name| {
        const T = @FieldType(Config, name);
        if (comptime !isLeaf(T)) try t.section(T, name, &@field(c, name));
    }
}

/// a value written as `key = ...` rather than as its own table.
fn isLeaf(comptime T: type) bool {
    return T == config.Set or @typeInfo(T) == .optional or config.isVal(T);
}

const TomlOut = struct {
    w: *Writer,
    sources: bool,
    wrote: bool = false,

    fn section(t: *TomlOut, comptime T: type, comptime name: []const u8, v: *const T) !void {
        if (comptime config.isNamed(T)) {
            if (comptime config.isVal(T.Value)) {
                if (v.entries.items.len == 0) return;
                try t.header(name, null);
                for (v.entries.items) |e| try t.leaf(e.name, e.value);
            } else for (v.entries.items) |e| {
                try t.header(name, e.name);
                try t.leaves(T.Value, &e.value);
            }
        } else if (!isEmpty(T, v)) {
            try t.header(name, null);
            try t.leaves(T, v);
        }
    }

    fn leaves(t: *TomlOut, comptime T: type, v: *const T) !void {
        inline for (comptime config.keysOf(T)) |name| try t.leaf(name, @field(v, name));
    }

    fn header(t: *TomlOut, name: []const u8, key: ?[]const u8) !void {
        if (t.wrote) try t.w.writeByte('\n');
        try t.w.print("[{s}", .{name});
        if (key) |k| {
            try t.w.writeByte('.');
            try toml.writeKey(t.w, k);
        }
        try t.w.writeAll("]\n");
        t.wrote = true;
    }

    fn leaf(t: *TomlOut, key: []const u8, v: anytype) !void {
        const T = @TypeOf(v);
        if (T == config.Set) return t.set(key, &v);
        if (@typeInfo(T) == .optional) {
            if (v) |inner| try t.leaf(key, inner);
            return;
        }
        try toml.writeKey(t.w, key);
        try t.w.writeAll(" = ");
        const string = comptime @TypeOf(v.v) == []const u8;
        if (string and !t.sources and isPathKey(key)) try writePath(t.w, v.v, v.src) else try writeScalar(t.w, v.v);
        try t.src(v.src);
        t.wrote = true;
    }

    fn set(t: *TomlOut, key: []const u8, s: *const config.Set) !void {
        if (s.items.items.len == 0) return;
        try toml.writeKey(t.w, key);
        try t.w.writeAll(" = [\n");
        for (s.items.items) |it| {
            try t.w.writeAll("  ");
            try toml.writeString(t.w, it.name);
            try t.w.writeByte(',');
            try t.src(it.src);
        }
        try t.w.writeAll("]\n");
        t.wrote = true;
    }

    fn src(t: *TomlOut, s: Src) !void {
        if (t.sources) try t.w.print("  # {s}:{d}", .{ s.file, s.line });
        try t.w.writeByte('\n');
    }
};

fn writeScalar(w: *Writer, v: anytype) !void {
    switch (@typeInfo(@TypeOf(v))) {
        .pointer => try toml.writeString(w, v),
        // a number stays one; anything else is a string.
        .@"struct" => if (isNumber(v.text)) try w.writeAll(v.text) else try toml.writeString(w, v.text),
        .@"enum" => try w.print("\"{s}\"", .{@tagName(v)}),
        else => try w.print("{}", .{v}),
    }
}

/// keys that hold a path relative to the file that sets them.
fn isPathKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "source") or std.mem.eql(u8, key, "session_config");
}

/// a path joined to the directory of the file that set it. without the
/// source comments, a relative path from an include would otherwise point
/// next to the wrong file.
fn writePath(w: *Writer, path: []const u8, src: Src) !void {
    const dir = std.fs.path.dirnamePosix(src.file) orelse return toml.writeString(w, path);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const full = std.fs.path.resolvePosix(fba.allocator(), &.{ dir, path }) catch return toml.writeString(w, path);
    try toml.writeString(w, full);
}

/// whether `s` is an integer written the one way toml and {d} agree on,
/// so "010", "1_000", and "+5" stay strings.
fn isNumber(s: []const u8) bool {
    const n = std.fmt.parseInt(i64, s, 10) catch return false;
    var buf: [24]u8 = undefined;
    return std.mem.eql(u8, std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable, s);
}

fn isEmpty(comptime T: type, v: *const T) bool {
    inline for (comptime config.keysOf(T)) |name| {
        const f = @field(v, name);
        if (@TypeOf(f) == config.Set) {
            if (f.items.items.len > 0) return false;
        } else if (f != null) return false;
    }
    return true;
}

/// the config as one json value, for embedding in a json document. every
/// setting is an object with `value`, `file`, `line`, and `column`; sets
/// are lists of those.
pub const Json = struct {
    config: *const Config,

    pub fn jsonStringify(j: Json, s: *std.json.Stringify) !void {
        try jsonValue(s, j.config.*);
    }
};

/// a value as an object that also says where it came from.
fn jsonSourced(s: *std.json.Stringify, value: anytype, src: Src) !void {
    try s.beginObject();
    try s.objectField("value");
    try s.write(value);
    try s.objectField("file");
    try s.write(src.file);
    try s.objectField("line");
    try s.write(src.line);
    try s.objectField("column");
    try s.write(src.column);
    try s.endObject();
}

fn jsonValue(s: *std.json.Stringify, v: anytype) !void {
    const T = @TypeOf(v);
    if (T == config.Set) {
        try s.beginArray();
        for (v.items.items) |it| try jsonSourced(s, it.name, it.src);
        return s.endArray();
    }
    switch (@typeInfo(T)) {
        .@"struct" => {
            if (comptime config.isVal(T)) return jsonSourced(s, v.v, v.src);
            try s.beginObject();
            if (comptime config.isNamed(T)) {
                for (v.entries.items) |e| {
                    try s.objectField(e.name);
                    try jsonValue(s, e.value);
                }
            } else inline for (comptime config.keysOf(T)) |name| {
                // unset values are left out.
                const field = @field(v, name);
                if (@typeInfo(@TypeOf(field)) != .optional or field != null) {
                    try s.objectField(name);
                    try jsonValue(s, field);
                }
            }
            return s.endObject();
        },
        .optional => if (v) |inner| try jsonValue(s, inner) else try s.write(null),
        else => try s.write(v),
    }
}

// -- tests --

const testing = std.testing;
const compose = @import("compose.zig");
const diag = @import("diag.zig");

fn loadExample(fs: *compose.MemFiles, diags: *diag.List) !compose.Loaded {
    try fs.put("base.toml",
        \\packages = ["git"]
        \\[users.kacy]
        \\groups = ["wheel"]
        \\
    );
    try fs.put("machine.toml",
        \\version = 1
        \\include = ["base.toml"]
        \\packages = ["neovim"]
        \\[system]
        \\hostname = "atlas"
        \\[hardware]
        \\gpu = "nvidia"
        \\[users.kacy]
        \\shell = "zsh"
        \\[services]
        \\ssh = true
        \\
    );
    return compose.load(testing.allocator, fs.files(), "machine.toml", diags);
}

test "canonical toml, with and without sources" {
    var fs: compose.MemFiles = .{};
    defer fs.deinit();
    var diags: diag.List = .init(testing.allocator);
    defer diags.deinit();
    var loaded = try loadExample(&fs, &diags);
    defer loaded.deinit();
    try testing.expectEqual(0, diags.items.items.len);

    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeToml(&out.writer, &loaded.config, true);
    try testing.expectEqualStrings(
        \\version = 1  # machine.toml:1
        \\packages = [
        \\  "git",  # base.toml:1
        \\  "neovim",  # machine.toml:3
        \\]
        \\
        \\[system]
        \\hostname = "atlas"  # machine.toml:5
        \\
        \\[hardware]
        \\gpu = "nvidia"  # machine.toml:7
        \\
        \\[users.kacy]
        \\shell = "zsh"  # machine.toml:9
        \\groups = [
        \\  "wheel",  # base.toml:3
        \\]
        \\
        \\[services.ssh]
        \\enabled = true  # machine.toml:11
        \\
    , out.written());

    // without sources the output is itself a valid config with the same meaning.
    var plain: Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    try writeToml(&plain.writer, &loaded.config, false);
    try fs.put("again.toml", plain.written());
    var again = try compose.load(testing.allocator, fs.files(), "again.toml", &diags);
    defer again.deinit();
    try testing.expectEqual(0, diags.items.items.len);
    var round: Writer.Allocating = .init(testing.allocator);
    defer round.deinit();
    try writeToml(&round.writer, &again.config, false);
    try testing.expectEqualStrings(plain.written(), round.written());
}

test "json carries values and sources" {
    var fs: compose.MemFiles = .{};
    defer fs.deinit();
    var diags: diag.List = .init(testing.allocator);
    defer diags.deinit();
    var loaded = try loadExample(&fs, &diags);
    defer loaded.deinit();

    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(Json{ .config = &loaded.config }, .{}, &out.writer);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const host = root.get("system").?.object.get("hostname").?.object;
    try testing.expectEqualStrings("atlas", host.get("value").?.string);
    try testing.expectEqual(5, host.get("line").?.integer);
    const pkgs = root.get("packages").?.array.items;
    try testing.expectEqualStrings("base.toml", pkgs[0].object.get("file").?.string);
    try testing.expectEqualStrings("nvidia", root.get("hardware").?.object.get("gpu").?.object.get("value").?.string);
    try testing.expect(root.get("services").?.object.get("ssh").?.object.get("enabled").?.object.get("value").?.bool);
    // unset values are left out; sets are always there.
    const boot = root.get("boot").?.object;
    try testing.expectEqual(null, boot.get("kernel"));
    try testing.expectEqual(0, boot.get("modules").?.array.items.len);
}

test "sysctl strings that look like numbers stay strings" {
    var fs: compose.MemFiles = .{};
    defer fs.deinit();
    var diags: diag.List = .init(testing.allocator);
    defer diags.deinit();
    try fs.put("machine.toml",
        \\[sysctl]
        \\"vm.a" = "010"
        \\"vm.b" = "1_000"
        \\"vm.c" = "+5"
        \\"vm.d" = 10
        \\"vm.e" = "-3"
        \\
    );
    var loaded = try compose.load(testing.allocator, fs.files(), "machine.toml", &diags);
    defer loaded.deinit();
    try testing.expectEqual(0, diags.items.items.len);

    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeToml(&out.writer, &loaded.config, false);
    try testing.expectEqualStrings(
        \\[sysctl]
        \\"vm.a" = "010"
        \\"vm.b" = "1_000"
        \\"vm.c" = "+5"
        \\"vm.d" = 10
        \\"vm.e" = -3
        \\
    , out.written());
}

test "paths from an include point at the same file without sources" {
    var fs: compose.MemFiles = .{};
    defer fs.deinit();
    var diags: diag.List = .init(testing.allocator);
    defer diags.deinit();
    try fs.put("/etc/yoq/profiles/base.toml",
        \\[desktop]
        \\session = "hyprland"
        \\session_config = "hyprland.conf"
        \\[files."/etc/motd"]
        \\source = "motd"
        \\
    );
    try fs.put("/etc/yoq/profiles/hyprland.conf", "");
    try fs.put("/etc/yoq/profiles/motd", "hi\n");
    try fs.put("/etc/yoq/machine.toml", "include = [\"profiles/base.toml\"]\n");
    var loaded = try compose.load(testing.allocator, fs.files(), "/etc/yoq/machine.toml", &diags);
    defer loaded.deinit();
    try testing.expectEqual(0, diags.items.items.len);

    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeToml(&out.writer, &loaded.config, false);
    try testing.expect(std.mem.indexOf(u8, out.written(), "session_config = \"/etc/yoq/profiles/hyprland.conf\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "source = \"/etc/yoq/profiles/motd\"\n") != null);

    // with sources, the comment names the file the path is relative to.
    var resolved: Writer.Allocating = .init(testing.allocator);
    defer resolved.deinit();
    try writeToml(&resolved.writer, &loaded.config, true);
    try testing.expect(std.mem.indexOf(u8, resolved.written(), "source = \"motd\"  # /etc/yoq/profiles/base.toml:5\n") != null);
}
