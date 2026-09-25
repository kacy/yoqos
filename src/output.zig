//! json documents. every document starts with a "schema" field that names
//! its shape and version, like "yoq.version/1", so scripts can check what
//! they got before reading the rest.

const std = @import("std");

/// writes `payload`'s fields as one json object, after the schema tag.
pub fn writeDoc(w: *std.Io.Writer, comptime schema: []const u8, payload: anytype) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("schema");
    try s.write(schema);
    inline for (std.meta.fields(@TypeOf(payload))) |f| {
        try s.objectField(f.name);
        try s.write(@field(payload, f.name));
    }
    try s.endObject();
    try w.writeByte('\n');
}

test "schema comes first" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeDoc(&w, "yoq.test/1", .{ .name = "atlas", .count = 3 });
    try std.testing.expectEqualStrings(
        \\{
        \\  "schema": "yoq.test/1",
        \\  "name": "atlas",
        \\  "count": 3
        \\}
        \\
    , w.buffered());
}
