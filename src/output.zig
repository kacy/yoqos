//! json documents. every document starts with a "schema" field that names
//! its shape and version, like "yos.version/1", so scripts can check what
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

/// a writer that passes text on to `out` with its control characters
/// written as escapes, like "\x1b", except newlines and tabs. yos's output
/// on a terminal holds text from places others control: a cloned config
/// repository and its lock, aur recipes and what their builds print,
/// file names on the esp. an escape sequence in any of them could move
/// the cursor and hide a line of a plan, or set the clipboard. the c1
/// controls in utf-8, like 0xc2 0x9b, which some terminals act on too,
/// are escaped as well.
pub const Plain = struct {
    out: *std.Io.Writer,
    /// a 0xc2 at the end of the last write: a c1 control or not, which
    /// the next byte says.
    held: bool = false,
    /// what goes through is json, whose strings take \u escapes and no
    /// others: c0 controls come escaped already, so only del and the c1
    /// controls are left.
    json: bool = false,
    interface: std.Io.Writer,

    pub fn init(out: *std.Io.Writer, buffer: []u8) Plain {
        return .{ .out = out, .interface = .{ .vtable = &.{ .drain = drain, .flush = flush }, .buffer = buffer } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const p: *Plain = @alignCast(@fieldParentPtr("interface", w));
        try p.put(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try p.put(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try p.put(last);
        return n + last.len * splat;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const p: *Plain = @alignCast(@fieldParentPtr("interface", w));
        try p.put(w.buffered());
        w.end = 0;
        // a lead byte with nothing after it yet: flushed, it could join a
        // byte written after, out of sight of this writer.
        if (p.held) try p.out.writeAll("\\xc2");
        p.held = false;
        try p.out.flush();
    }

    fn put(p: *Plain, bytes: []const u8) std.Io.Writer.Error!void {
        for (bytes) |ch| {
            if (p.held) {
                p.held = false;
                if (ch >= 0x80 and ch <= 0x9f) {
                    if (p.json) try p.out.print("\\u00{x:0>2}", .{ch}) else try p.out.print("\\xc2\\x{x:0>2}", .{ch});
                    continue;
                }
                try p.out.writeByte(0xc2);
            }
            if (ch == 0xc2) {
                p.held = true;
            } else if ((ch < 0x20 and ch != '\n' and ch != '\t') or ch == 0x7f) {
                if (p.json) try p.out.print("\\u00{x:0>2}", .{ch}) else try p.out.print("\\x{x:0>2}", .{ch});
            } else try p.out.writeByte(ch);
        }
    }
};

test "control characters reach the terminal as escapes" {
    var buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    // small enough that a c1 control is split between two writes.
    var small: [4]u8 = undefined;
    var plain: Plain = .init(&out, &small);
    const w = &plain.interface;
    try w.print("  + {s}\n", .{"git 2.51\x1b[1A\x1b[2K"});
    try w.writeAll("abc\xc2");
    try w.writeAll("\x9b2J \xc2\xa2\r\x07\tend\n");
    try w.flush();
    try std.testing.expectEqualStrings("  + git 2.51\\x1b[1A\\x1b[2K\nabc\\xc2\\x9b2J \xc2\xa2\\x0d\\x07\tend\n", out.buffered());
}

test "json keeps its escapes json's own" {
    var buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var small: [64]u8 = undefined;
    var plain: Plain = .init(&out, &small);
    plain.json = true;
    try writeDoc(&plain.interface, "yos.test/1", .{ .name = "a\x7fb\xc2\x9bc\x1b" });
    try plain.interface.flush();
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"a\\u007fb\\u009bc\\u001b\"") != null);
}

test "schema comes first" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeDoc(&w, "yos.test/1", .{ .name = "atlas", .count = 3 });
    try std.testing.expectEqualStrings(
        \\{
        \\  "schema": "yos.test/1",
        \\  "name": "atlas",
        \\  "count": 3
        \\}
        \\
    , w.buffered());
}
