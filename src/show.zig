//! prints a merged config, as canonical toml or as json. with sources on,
//! every value says which file and line it came from.

const std = @import("std");
const config = @import("config.zig");
const toml = @import("toml.zig");
const Config = config.Config;
const Src = config.Src;
const Writer = std.Io.Writer;

pub fn writeToml(w: *Writer, c: *const Config, sources: bool) !void {
    var t: TomlOut = .{ .w = w, .sources = sources };
    try t.run(c);
}

const TomlOut = struct {
    w: *Writer,
    sources: bool,
    wrote: bool = false,

    fn src(t: *TomlOut, s: Src) !void {
        if (t.sources) try t.w.print("  # {s}:{d}", .{ s.file, s.line });
        try t.w.writeByte('\n');
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

    fn str(t: *TomlOut, key: []const u8, v: ?config.Str) !void {
        const s = v orelse return;
        try toml.writeKey(t.w, key);
        try t.w.writeAll(" = ");
        try toml.writeString(t.w, s.v);
        try t.src(s.src);
        t.wrote = true;
    }

    fn tag(t: *TomlOut, key: []const u8, v: anytype) !void {
        const s = v orelse return;
        try t.w.print("{s} = \"{s}\"", .{ key, @tagName(s.v) });
        try t.src(s.src);
        t.wrote = true;
    }

    fn set(t: *TomlOut, key: []const u8, s: *const config.Set) !void {
        if (s.items.items.len == 0) return;
        try t.w.print("{s} = [\n", .{key});
        for (s.items.items) |it| {
            try t.w.writeAll("  ");
            try toml.writeString(t.w, it.name);
            try t.w.writeByte(',');
            try t.src(it.src);
        }
        try t.w.writeAll("]\n");
        t.wrote = true;
    }

    fn run(t: *TomlOut, c: *const Config) !void {
        if (c.version) |v| {
            try t.w.print("version = {d}", .{v.v});
            try t.src(v.src);
            t.wrote = true;
        }
        try t.set("packages", &c.packages);
        try t.set("aur", &c.aur);

        if (c.providers.entries.items.len > 0) {
            try t.header("providers", null);
            for (c.providers.entries.items) |e| try t.str(e.name, e.value);
        }
        if (anySet(c.system)) {
            try t.header("system", null);
            try t.str("hostname", c.system.hostname);
            try t.str("timezone", c.system.timezone);
            try t.str("locale", c.system.locale);
            try t.str("keymap", c.system.keymap);
        }
        if (anySet(c.boot)) {
            try t.header("boot", null);
            try t.str("kernel", c.boot.kernel);
        }
        if (anySet(c.hardware)) {
            try t.header("hardware", null);
            try t.tag("cpu", c.hardware.cpu);
            try t.tag("gpu", c.hardware.gpu);
        }
        if (anySet(c.desktop)) {
            try t.header("desktop", null);
            try t.tag("session", c.desktop.session);
            try t.tag("audio", c.desktop.audio);
        }
        for (c.users.entries.items) |e| {
            try t.header("users", e.name);
            try t.str("shell", e.value.shell);
            try t.set("groups", &e.value.groups);
        }
        for (c.services.entries.items) |e| {
            try t.header("services", e.name);
            if (e.value.enabled) |en| {
                try t.w.print("enabled = {}", .{en.v});
                try t.src(en.src);
            }
            try t.str("unit", e.value.unit);
            try t.str("package", e.value.package);
        }
        if (c.state.carry.items.items.len > 0) {
            try t.header("state", null);
            try t.set("carry", &c.state.carry);
        }
    }
};

fn anySet(section: anytype) bool {
    inline for (std.meta.fields(@TypeOf(section))) |f| {
        if (@field(section, f.name) != null) return true;
    }
    return false;
}

/// the config as one json value. every setting is an object with `value`,
/// `file`, `line`, and `column`; sets are lists of those.
pub fn writeJson(s: *std.json.Stringify, c: *const Config) !void {
    try jsonValue(s, c.*);
}

fn jsonSrc(s: *std.json.Stringify, src: Src) !void {
    try s.objectField("file");
    try s.write(src.file);
    try s.objectField("line");
    try s.write(src.line);
    try s.objectField("column");
    try s.write(src.column);
}

fn jsonValue(s: *std.json.Stringify, v: anytype) !void {
    const T = @TypeOf(v);
    if (T == config.Set) {
        try s.beginArray();
        for (v.items.items) |it| {
            try s.beginObject();
            try s.objectField("value");
            try s.write(it.name);
            try jsonSrc(s, it.src);
            try s.endObject();
        }
        return s.endArray();
    }
    switch (@typeInfo(T)) {
        .@"struct" => {
            if (@hasField(T, "v") and @hasField(T, "src")) {
                try s.beginObject();
                try s.objectField("value");
                try s.write(v.v);
                try jsonSrc(s, v.src);
                return s.endObject();
            }
            if (@hasField(T, "entries") and @hasDecl(T, "Entry")) {
                try s.beginObject();
                for (v.entries.items) |e| {
                    try s.objectField(e.name);
                    try jsonValue(s, e.value);
                }
                return s.endObject();
            }
            try s.beginObject();
            inline for (std.meta.fields(T)) |f| {
                if (comptime std.mem.eql(u8, f.name, "src")) continue;
                const field = @field(v, f.name);
                if (@typeInfo(f.type) == .optional) {
                    if (field) |inner| {
                        try s.objectField(f.name);
                        try jsonValue(s, inner);
                    }
                } else {
                    try s.objectField(f.name);
                    try jsonValue(s, field);
                }
            }
            return s.endObject();
        },
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
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try writeJson(&s, &loaded.config);

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
    try testing.expect(root.get("boot").?.object.count() == 0);
}
