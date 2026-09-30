//! json schemas for os's json documents and for machine.toml, worked out
//! from the zig types that write and read them, so the two can't drift
//! apart. `os schema <name>` prints one.

const std = @import("std");
const config = @import("config.zig");
const diag = @import("diag.zig");
const events = @import("events.zig");
const facts = @import("facts.zig");
const lists = @import("lists.zig");
const lock = @import("lock.zig");
const planner = @import("planner.zig");
const status = @import("status.zig");
const toml = @import("toml.zig");

pub const Doc = struct {
    name: []const u8,
    what: []const u8,
    write: *const fn (w: *std.Io.Writer) anyerror!void,
};

/// every schema, by the name `os schema` takes.
pub const docs = [_]Doc{
    .{ .name = "config", .what = "machine.toml and the files it includes", .write = configSchema },
    .{ .name = "errors", .what = "errors, as --json prints them", .write = docSchema(diag.JsonDoc, "yoq.errors/1") },
    .{ .name = "events", .what = "a line of os events, as os events prints them", .write = docSchema(events.Event, events.schema) },
    .{ .name = "facts", .what = "what os reads from a machine: os facts, and --facts", .write = docSchema(facts.Facts, facts.schema) },
    .{ .name = "lock", .what = "machine.lock", .write = lockSchema },
    .{ .name = "plan", .what = "os plan --json, and the file os plan -o saves", .write = docSchema(planner.Doc, planner.schema) },
    .{ .name = "status", .what = "os status --json", .write = docSchema(status.Status, status.schema) },
};

pub fn find(name: []const u8) ?Doc {
    return docs[lists.indexOf(&docs, "name", name) orelse return null];
}

const draft = "https://json-schema.org/draft/2020-12/schema";

fn open(w: *std.Io.Writer) std.json.Stringify {
    return .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
}

/// opens a top-level schema with its draft and id, up to an open
/// "properties".
fn beginTop(s: *std.json.Stringify, id: []const u8) !void {
    try s.beginObject();
    try s.objectField("$schema");
    try s.write(draft);
    try s.objectField("$id");
    try s.write(id);
    try beginProperties(s);
}

/// an object's type, and its "properties" left open.
fn beginProperties(s: *std.json.Stringify) !void {
    try s.objectField("type");
    try s.write("object");
    try s.objectField("properties");
    try s.beginObject();
}

/// closes an object schema that allows no other keys.
fn endClosed(s: *std.json.Stringify) !void {
    try s.objectField("additionalProperties");
    try s.write(false);
    try s.endObject();
}

/// a json document: its "schema" tag, then `T`'s fields.
fn docSchema(comptime T: type, comptime tag: []const u8) fn (*std.Io.Writer) anyerror!void {
    return struct {
        fn write(w: *std.Io.Writer) anyerror!void {
            var s = open(w);
            try beginTop(&s, tag);
            try s.objectField("schema");
            try s.write(.{ .@"const" = tag });
            try fields(&s, T, .json);
            try s.endObject();
            try required(&s, T, &.{"schema"}, "schema");
            try endClosed(&s);
            try w.writeByte('\n');
        }
    }.write;
}

/// machine.toml: the config's keys, and the ones only a file has.
fn configSchema(w: *std.Io.Writer) anyerror!void {
    var s = open(w);
    try beginTop(&s, "yoq.config/1");
    try fields(&s, config.Config, .toml);
    inline for (.{ "include", "unset", "remove" }) |k| {
        try s.objectField(k);
        try value(&s, @FieldType(config.Part, k), .toml);
    }
    try s.endObject();
    try endClosed(&s);
    try w.writeByte('\n');
}

/// machine.lock: a few keys at the top, then tables keyed by name, like
/// `[packages.git]`, for what the lock holds as lists.
fn lockSchema(w: *std.Io.Writer) anyerror!void {
    var s = open(w);
    try beginTop(&s, "yoq.lock/1");
    inline for (lock.top_keys) |k| {
        try s.objectField(k);
        if (comptime std.mem.eql(u8, k, "version")) {
            try s.write(.{ .@"const" = lock.format_version });
            continue;
        }
        const T = @FieldType(lock.Lock, k);
        if (comptime @typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice and @typeInfo(@typeInfo(T).pointer.child) == .@"struct") {
            try keyed(&s, @typeInfo(T).pointer.child);
        } else if (!try patterned(&s, k)) try value(&s, T, .toml);
    }
    try s.endObject();
    try required(&s, lock.Lock, &.{"version"}, "");
    try endClosed(&s);
    try w.writeByte('\n');
}

/// what the lock reader checks in a string, besides its type.
const patterns = .{
    .{ "sync_date", "^[0-9]{4}-[0-9]{2}-[0-9]{2}$" },
    .{ "sha256", "^[0-9a-f]{64}$" },
    .{ "recipe", "^[0-9a-f]{40}$" },
};

/// a list of `T` written as a table keyed by each one's name. with one
/// field besides the name, the table maps names to that field's value.
fn keyed(s: *std.json.Stringify, comptime T: type) !void {
    const all = comptime std.meta.fieldNames(T);
    comptime std.debug.assert(std.mem.eql(u8, all[0], "name"));
    const names = all[1..];
    try s.beginObject();
    try s.objectField("type");
    try s.write("object");
    try s.objectField("additionalProperties");
    if (names.len == 1) {
        try value(s, @FieldType(T, names[0]), .toml);
    } else {
        try s.beginObject();
        try beginProperties(s);
        inline for (names) |n| {
            try s.objectField(n);
            if (!try patterned(s, n)) try value(s, @FieldType(T, n), .toml);
        }
        try s.endObject();
        try required(s, T, &.{}, "name");
        try endClosed(s);
    }
    try s.endObject();
}

/// writes a string with its pattern, if `name` has one.
fn patterned(s: *std.json.Stringify, comptime name: []const u8) !bool {
    inline for (patterns) |p| {
        if (comptime std.mem.eql(u8, p[0], name)) {
            try s.write(.{ .type = "string", .pattern = p[1] });
            return true;
        }
    }
    return false;
}

/// json writes optional fields as null; toml leaves them out, and has
/// keys that aren't fields.
const Mode = enum { json, toml };

fn fields(s: *std.json.Stringify, comptime T: type, comptime mode: Mode) !void {
    const names: []const []const u8 = comptime if (mode == .toml) config.keysOf(T) else std.meta.fieldNames(T);
    inline for (names) |n| {
        // a document's tag, which docSchema writes as a constant.
        if (comptime std.mem.eql(u8, n, "schema")) continue;
        try s.objectField(n);
        try value(s, @FieldType(T, n), mode);
    }
}

/// an object's fields without a default, which it always has, besides
/// `skip`.
fn required(s: *std.json.Stringify, comptime T: type, comptime extra: []const []const u8, comptime skip: []const u8) !void {
    try s.objectField("required");
    try s.beginArray();
    for (extra) |n| try s.write(n);
    inline for (std.meta.fields(T)) |f| {
        if (f.default_value_ptr == null and !std.mem.eql(u8, f.name, skip)) try s.write(f.name);
    }
    try s.endArray();
}

fn value(s: *std.json.Stringify, comptime T: type, comptime mode: Mode) !void {
    if (T == []const u8 or T == []u8) return s.write(.{ .type = "string" });
    if (T == config.Set) return s.write(.{ .type = "array", .items = .{ .type = "string" }, .uniqueItems = true });
    // a sysctl value is a number or a string.
    if (T == config.Loose) return s.write(.{ .type = .{ "string", "integer" } });
    switch (@typeInfo(T)) {
        .bool => return s.write(.{ .type = "boolean" }),
        .int => return s.write(.{ .type = "integer" }),
        .float => return s.write(.{ .type = "number" }),
        .@"enum" => return s.write(.{ .@"enum" = std.meta.fieldNames(T) }),
        .optional => |o| {
            if (mode == .toml) return value(s, o.child, mode);
            try s.beginObject();
            try s.objectField("anyOf");
            try s.beginArray();
            try value(s, o.child, mode);
            try s.write(.{ .type = "null" });
            try s.endArray();
            return s.endObject();
        },
        .pointer => |p| {
            if (p.size == .one) return value(s, p.child, mode);
            return array(s, p.child, mode);
        },
        .array => |arr| {
            if (arr.child == u8) return s.write(.{ .type = "string" });
            return array(s, arr.child, mode);
        },
        .@"struct" => {
            if (comptime config.isVal(T)) return value(s, @FieldType(T, "v"), mode);
            if (comptime config.isNamed(T)) return named(s, T.Value, mode);
            // std.ArrayList
            if (@hasField(T, "items") and @hasField(T, "capacity")) return array(s, @typeInfo(@FieldType(T, "items")).pointer.child, mode);
            try s.beginObject();
            try beginProperties(s);
            try fields(s, T, mode);
            try s.endObject();
            if (mode == .json) try required(s, T, &.{}, "schema");
            return endClosed(s);
        },
        else => @compileError("no json schema for " ++ @typeName(T)),
    }
}

fn array(s: *std.json.Stringify, comptime T: type, comptime mode: Mode) !void {
    try s.beginObject();
    try s.objectField("type");
    try s.write("array");
    try s.objectField("items");
    try value(s, T, mode);
    try s.endObject();
}

/// a table keyed by name. one with a shorthand, like `ssh = true`, takes
/// that key's value in place of the table.
fn named(s: *std.json.Stringify, comptime T: type, comptime mode: Mode) !void {
    try s.beginObject();
    try s.objectField("type");
    try s.write("object");
    try s.objectField("additionalProperties");
    if (@hasDecl(T, "shorthand")) {
        try s.beginObject();
        try s.objectField("anyOf");
        try s.beginArray();
        try value(s, @FieldType(T, T.shorthand), mode);
        try value(s, T, mode);
        try s.endArray();
        try s.endObject();
    } else try value(s, T, mode);
    try s.endObject();
}

// -- tests --

const testing = std.testing;

fn render(a: std.mem.Allocator, name: []const u8) !std.json.Parsed(std.json.Value) {
    var out: std.Io.Writer.Allocating = .init(a);
    try find(name).?.write(&out.writer);
    return std.json.parseFromSlice(std.json.Value, a, out.written(), .{});
}

test "every schema is json, with its id" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (docs) |d| {
        const p = try render(arena.allocator(), d.name);
        try testing.expect(std.mem.startsWith(u8, p.value.object.get("$id").?.string, "yoq."));
    }
}

test "the config's schema has its keys, and none of the hidden fields" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try render(arena.allocator(), "config");
    const props = p.value.object.get("properties").?.object;
    try testing.expect(props.contains("include"));
    try testing.expect(!props.contains("removed"));
    const file = props.get("files").?.object.get("additionalProperties").?.object.get("properties").?.object;
    try testing.expect(file.contains("text"));
    try testing.expect(!file.contains("content"));
    try testing.expect(!file.contains("src"));
    // `ssh = true`, or a table.
    const service = props.get("services").?.object.get("additionalProperties").?.object.get("anyOf").?.array;
    try testing.expectEqualStrings("boolean", service.items[0].object.get("type").?.string);
    const gpu = props.get("hardware").?.object.get("properties").?.object.get("gpu").?.object.get("enum").?.array;
    try testing.expectEqualStrings("nvidia", gpu.items[2].string);
}

test "a plan's schema requires what a plan always has" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try render(arena.allocator(), "plan");
    const req = p.value.object.get("required").?.array;
    try testing.expectEqualStrings("schema", req.items[0].string);
    try testing.expectEqualStrings("hash", req.items[1].string);
    const change = p.value.object.get("properties").?.object.get("changes").?.object.get("items").?.object;
    const from = change.get("properties").?.object.get("from").?.object.get("anyOf").?.array;
    try testing.expectEqualStrings("null", from.items[1].object.get("type").?.string);
}

/// whether `v` fits `schema`, for the parts of json schema these use,
/// besides patterns.
fn conforms(schema: std.json.Value, v: std.json.Value) bool {
    const o = schema.object;
    if (o.get("const")) |c| {
        if (!jsonEql(c, v)) return false;
    }
    if (o.get("enum")) |e| {
        for (e.array.items) |x| {
            if (jsonEql(x, v)) break;
        } else return false;
    }
    if (o.get("anyOf")) |any| {
        for (any.array.items) |x| {
            if (conforms(x, v)) break;
        } else return false;
    }
    if (o.get("type")) |t| switch (t) {
        .string => |name| if (!isType(name, v)) return false,
        else => {
            for (t.array.items) |name| {
                if (isType(name.string, v)) break;
            } else return false;
        },
    };
    if (v == .array) if (o.get("items")) |items| {
        for (v.array.items) |x| if (!conforms(items, x)) return false;
    };
    if (v != .object) return true;
    const props = if (o.get("properties")) |p| p.object else std.json.ObjectMap.empty;
    var it = v.object.iterator();
    while (it.next()) |e| {
        if (props.get(e.key_ptr.*)) |p| {
            if (!conforms(p, e.value_ptr.*)) return false;
        } else if (o.get("additionalProperties")) |more| switch (more) {
            .bool => |ok| if (!ok) return false,
            else => if (!conforms(more, e.value_ptr.*)) return false,
        };
    }
    if (o.get("required")) |req| for (req.array.items) |k| {
        if (!v.object.contains(k.string)) return false;
    };
    return true;
}

/// scalars only, which is all a const or an enum here holds.
fn jsonEql(x: std.json.Value, y: std.json.Value) bool {
    return switch (x) {
        .integer => |i| y == .integer and y.integer == i,
        .string => |s| y == .string and std.mem.eql(u8, s, y.string),
        .bool => |b| y == .bool and y.bool == b,
        else => false,
    };
}

fn isType(name: []const u8, v: std.json.Value) bool {
    const eq = std.mem.eql;
    return switch (v) {
        .null => eq(u8, name, "null"),
        .bool => eq(u8, name, "boolean"),
        .integer => eq(u8, name, "integer") or eq(u8, name, "number"),
        .float, .number_string => eq(u8, name, "number"),
        .string => eq(u8, name, "string"),
        .array => eq(u8, name, "array"),
        .object => eq(u8, name, "object"),
    };
}

/// a toml value as json, to check against a schema.
fn tomlToJson(a: std.mem.Allocator, v: toml.Value) !std.json.Value {
    return switch (v.data) {
        .string => |s| .{ .string = s },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .boolean => |b| .{ .bool = b },
        .array => |arr| blk: {
            var out: std.json.Array = .init(a);
            for (arr.items.items) |x| try out.append(try tomlToJson(a, x));
            break :blk .{ .array = out };
        },
        .table => |t| blk: {
            var out: std.json.ObjectMap = .empty;
            for (t.entries.items) |e| try out.put(a, e.key, try tomlToJson(a, e.value));
            break :blk .{ .object = out };
        },
    };
}

fn fitsLock(a: std.mem.Allocator, schema: std.json.Value, text: []const u8) !bool {
    var info: toml.ErrorInfo = .{};
    var doc = try toml.parse(a, text, &info);
    defer doc.deinit();
    return conforms(schema, try tomlToJson(a, .{ .span = undefined, .data = .{ .table = doc.root } }));
}

test "the lock's schema fits what the lock writer writes, and every golden lock" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const schema = (try render(a, "lock")).value;

    const hash = "a" ** 64;
    const l: lock.Lock = .{
        .sync_date = "2026-09-25",
        .keyring = "1",
        .providers = &.{.{ .name = "java-runtime", .chosen = "jre-openjdk" }},
        .packages = &.{
            .{ .name = "glibc", .version = "2.42-1", .repo = "core", .sha256 = hash },
            .{ .name = "yay-bin", .version = "12.5.0-1", .repo = "yoq-aur", .sha256 = hash, .depends = &.{"glibc"}, .recipe = "0" ** 40 },
        },
    };
    var out: std.Io.Writer.Allocating = .init(a);
    try lock.write(&out.writer, &l);
    try testing.expect(try fitsLock(a, schema, out.written()));
    const head = "version = 1\nsync_date = \"2026-09-25\"\nkeyring = \"1\"\n";
    try testing.expect(!try fitsLock(a, schema, "version = 1\n"));
    try testing.expect(!try fitsLock(a, schema, head ++ "extra = 1\n"));
    try testing.expect(!try fitsLock(a, schema, head ++ "[packages.git]\nversion = 1\n"));
    try testing.expect(!try fitsLock(a, schema, head ++ "[packages.git]\nversion = \"1\"\nrepo = \"x\"\n"));

    var dir = try std.Io.Dir.cwd().openDir(io, "tests/golden", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var checked: usize = 0;
    while (try it.next(io)) |e| {
        if (e.kind != .directory) continue;
        const path = try std.fmt.allocPrint(a, "tests/golden/{s}/machine.lock", .{e.name});
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch continue;
        var diags: diag.List = .init(testing.allocator);
        defer diags.deinit();
        // a lock damaged on purpose isn't one the reader takes either.
        if (try lock.parse(a, path, text, &diags) == null) continue;
        if (!try fitsLock(a, schema, text)) {
            std.debug.print("{s} doesn't fit the lock's schema\n", .{path});
            return error.TestUnexpectedResult;
        }
        checked += 1;
    }
    try testing.expect(checked > 5);
}

test "events fit their schema" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = (try render(a, "events")).value;
    const samples = [_]events.Event{
        .{ .time = 1, .kind = .apply, .step = .begin, .plan = "abc" },
        .{ .time = 2, .kind = .pacman, .packages = &.{"htop"} },
        .{ .time = 3, .kind = .generation, .generation = 4, .message = "add fd" },
        .{ .time = 4, .kind = .gc, .generations = &.{ 2, 3 } },
        .{ .time = 5, .kind = .pin, .step = .unpinned, .generation = 2 },
        .{ .time = 6, .kind = .@"enable-rollback", .step = .done, .generation = 1 },
        .{ .time = 7, .kind = .install, .generation = 1, .message = "atlas" },
    };
    for (samples) |e| {
        var out: std.Io.Writer.Allocating = .init(a);
        try events.encode(&out.writer, e);
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, out.written(), .{});
        try testing.expect(conforms(schema, v));
    }
    const odd = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"schema\":\"yoq.event/1\",\"time\":1,\"kind\":\"reboot\"}", .{});
    try testing.expect(!conforms(schema, odd));
}

test "the lock's schema has the keys the lock reader takes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try render(arena.allocator(), "lock");
    const props = p.value.object.get("properties").?.object;
    try testing.expectEqual(lock.top_keys.len, props.count());
    for (lock.top_keys) |k| try testing.expect(props.contains(k));
    const pkg = props.get("packages").?.object.get("additionalProperties").?.object.get("properties").?.object;
    try testing.expectEqual(lock.package_keys.len, pkg.count());
    for (lock.package_keys) |k| try testing.expect(pkg.contains(k));
}
