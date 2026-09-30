//! json schemas for os's json documents and for machine.toml, worked out
//! from the zig types that write and read them, so the two can't drift
//! apart. `os schema <name>` prints one.

const std = @import("std");
const config = @import("config.zig");
const diag = @import("diag.zig");
const facts = @import("facts.zig");
const lists = @import("lists.zig");
const planner = @import("planner.zig");
const status = @import("status.zig");

pub const Doc = struct {
    name: []const u8,
    what: []const u8,
    write: *const fn (w: *std.Io.Writer) anyerror!void,
};

/// every schema, by the name `os schema` takes.
pub const docs = [_]Doc{
    .{ .name = "config", .what = "machine.toml and the files it includes", .write = configSchema },
    .{ .name = "errors", .what = "errors, as --json prints them", .write = docSchema(diag.JsonDoc, "yoq.errors/1") },
    .{ .name = "facts", .what = "what os reads from a machine: os facts, and --facts", .write = docSchema(facts.Facts, facts.schema) },
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
            try required(&s, T, &.{"schema"});
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

/// a json object's fields without a default, which it always has.
fn required(s: *std.json.Stringify, comptime T: type, comptime extra: []const []const u8) !void {
    try s.objectField("required");
    try s.beginArray();
    for (extra) |n| try s.write(n);
    inline for (std.meta.fields(T)) |f| {
        if (f.default_value_ptr == null and !std.mem.eql(u8, f.name, "schema")) try s.write(f.name);
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
            if (mode == .json) try required(s, T, &.{});
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
