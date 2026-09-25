//! toml 1.0 parser. every key and value keeps its source span, so errors can
//! point at the exact spot and later edits can rewrite a value in place
//! without touching the rest of the file.
//!
//! dates and times aren't supported yet; they fail with their own code so
//! the message can say so plainly.

const std = @import("std");
const diag = @import("diag.zig");
const Allocator = std.mem.Allocator;

pub const Pos = struct {
    offset: u32,
    line: u32,
    column: u32,
};

/// `end` is the byte offset just past the last byte.
pub const Span = struct {
    start: Pos,
    end: u32,
};

pub const Value = struct {
    span: Span,
    data: Data,

    pub const Data = union(enum) {
        string: []const u8,
        integer: i64,
        float: f64,
        boolean: bool,
        array: *Array,
        table: *Table,
    };

    pub fn typeName(v: Value) []const u8 {
        return switch (v.data) {
            .string => "a string",
            .integer => "an integer",
            .float => "a float",
            .boolean => "a boolean",
            .array => "a list",
            .table => "a table",
        };
    }
};

pub const Array = struct {
    items: std.ArrayList(Value) = .empty,
    /// made by `[[name]]` headers rather than a `[...]` value.
    of_tables: bool = false,
};

pub const Table = struct {
    entries: std.ArrayList(Entry) = .empty,
    origin: Origin,
    /// where the table was opened: its header, first dotted key, or brace.
    pos: Pos,

    pub const Origin = enum {
        root,
        /// `[name]`
        header,
        /// created as a parent by a header like `[a.b]`; `[a]` may still
        /// define it once.
        implicit,
        /// created by a dotted key like `a.b = 1`
        dotted,
        /// `{ ... }`, closed once parsed
        inline_table,
        /// created by a dotted key inside `{ ... }`, closed with it
        inline_dotted,
        /// one element of a `[[name]]` array
        array_element,
    };

    pub fn get(t: *const Table, key: []const u8) ?*Value {
        for (t.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) return &e.value;
        }
        return null;
    }

    pub fn getEntry(t: *const Table, key: []const u8) ?*Entry {
        for (t.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) return e;
        }
        return null;
    }

    fn closed(t: *const Table) bool {
        return t.origin == .inline_table or t.origin == .inline_dotted;
    }
};

pub const Entry = struct {
    key: []const u8,
    key_span: Span,
    value: Value,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: *Table,

    pub fn deinit(d: *Document) void {
        d.arena.deinit();
    }
};

pub const ErrorInfo = struct {
    code: diag.Code = .toml_syntax,
    pos: Pos = .{ .offset = 0, .line = 1, .column = 1 },
    buf: [192]u8 = undefined,
    len: usize = 0,

    pub fn message(e: *const ErrorInfo) []const u8 {
        return e.buf[0..e.len];
    }
};

pub const ParseError = error{ OutOfMemory, Syntax };

/// parses `source`. on `error.Syntax`, `info` says what went wrong and where.
/// the document keeps no reference to `source`.
pub fn parse(gpa: Allocator, source: []const u8, info: *ErrorInfo) ParseError!Document {
    var doc: Document = .{ .arena = .init(gpa), .root = undefined };
    errdefer doc.arena.deinit();
    var p: Parser = .{ .a = doc.arena.allocator(), .src = source, .info = info };
    doc.root = try p.parseDocument();
    return doc;
}

const KeyPart = struct {
    name: []const u8,
    span: Span,
};

const Parser = struct {
    a: Allocator,
    src: []const u8,
    info: *ErrorInfo,
    i: usize = 0,
    line: u32 = 1,
    line_start: usize = 0,

    fn pos(p: *const Parser) Pos {
        return .{ .offset = @intCast(p.i), .line = p.line, .column = @intCast(p.i - p.line_start + 1) };
    }

    fn peek(p: *const Parser) ?u8 {
        return if (p.i < p.src.len) p.src[p.i] else null;
    }

    fn peekAt(p: *const Parser, n: usize) ?u8 {
        return if (p.i + n < p.src.len) p.src[p.i + n] else null;
    }

    fn startsWith(p: *const Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, p.src[p.i..], s);
    }

    fn advance(p: *Parser) void {
        if (p.src[p.i] == '\n') {
            p.line += 1;
            p.line_start = p.i + 1;
        }
        p.i += 1;
    }

    fn advanceBy(p: *Parser, n: usize) void {
        for (0..n) |_| p.advance();
    }

    fn fail(p: *Parser, code: diag.Code, at: Pos, comptime fmt: []const u8, args: anytype) ParseError {
        var w: std.Io.Writer = .fixed(&p.info.buf);
        w.print(fmt, args) catch {};
        p.info.len = w.end;
        p.info.code = code;
        p.info.pos = at;
        return error.Syntax;
    }

    fn failUnexpected(p: *Parser, expected: []const u8) ParseError {
        const c = p.peek() orelse return p.fail(.toml_syntax, p.pos(), "expected {s}, found the end of the file", .{expected});
        if (c == '\n' or c == '\r') return p.fail(.toml_syntax, p.pos(), "expected {s}, found the end of the line", .{expected});
        if (c >= 0x20 and c < 0x7f) return p.fail(.toml_syntax, p.pos(), "expected {s}, found '{c}'", .{ expected, c });
        return p.fail(.toml_syntax, p.pos(), "expected {s}, found byte 0x{x:0>2}", .{ expected, c });
    }

    fn failDuplicate(p: *Parser, part: KeyPart) ParseError {
        return p.fail(.toml_duplicate_key, part.span.start, "\"{s}\" is already defined", .{part.name});
    }

    fn newTable(p: *Parser, origin: Table.Origin, at: Pos) !*Table {
        const t = try p.a.create(Table);
        t.* = .{ .origin = origin, .pos = at };
        return t;
    }

    fn addTable(p: *Parser, parent: *Table, part: KeyPart, origin: Table.Origin) !*Table {
        const t = try p.newTable(origin, part.span.start);
        try parent.entries.append(p.a, .{
            .key = part.name,
            .key_span = part.span,
            .value = .{ .span = part.span, .data = .{ .table = t } },
        });
        return t;
    }

    fn parseDocument(p: *Parser) ParseError!*Table {
        if (!std.unicode.utf8ValidateSlice(p.src)) {
            var bad: usize = 0;
            while (bad < p.src.len) {
                const n = std.unicode.utf8ByteSequenceLength(p.src[bad]) catch break;
                if (bad + n > p.src.len) break;
                _ = std.unicode.utf8Decode(p.src[bad .. bad + n]) catch break;
                bad += n;
            }
            while (p.i < bad) p.advance();
            return p.fail(.toml_syntax, p.pos(), "the file isn't valid utf-8", .{});
        }
        const root = try p.newTable(.root, p.pos());
        var current = root;
        while (true) {
            try p.skipBlank();
            if (p.peek() == null) break;
            if (p.peek().? == '[') {
                current = try p.parseHeader(root);
            } else {
                try p.parseKeyValue(current);
            }
            try p.expectLineEnd();
        }
        return root;
    }

    fn skipWs(p: *Parser) void {
        while (p.peek()) |c| {
            if (c != ' ' and c != '\t') break;
            p.advance();
        }
    }

    /// skips spaces, comments, and newlines.
    fn skipBlank(p: *Parser) ParseError!void {
        while (p.peek()) |c| {
            switch (c) {
                ' ', '\t', '\n' => p.advance(),
                '\r' => {
                    if (p.peekAt(1) != '\n') return p.fail(.toml_syntax, p.pos(), "a carriage return must be followed by a newline", .{});
                    p.advance();
                },
                '#' => try p.skipComment(),
                else => return,
            }
        }
    }

    fn skipComment(p: *Parser) ParseError!void {
        p.advance();
        while (p.peek()) |c| {
            if (c == '\n' or (c == '\r' and p.peekAt(1) == '\n')) return;
            if (isControl(c)) return p.fail(.toml_syntax, p.pos(), "control character in a comment", .{});
            p.advance();
        }
    }

    fn expectLineEnd(p: *Parser) ParseError!void {
        p.skipWs();
        if (p.peek() == '#') try p.skipComment();
        const c = p.peek() orelse return;
        if (c == '\n') return p.advance();
        if (c == '\r' and p.peekAt(1) == '\n') return p.advanceBy(2);
        return p.failUnexpected("the end of the line");
    }

    fn parseKey(p: *Parser, parts: *std.ArrayList(KeyPart)) ParseError!void {
        while (true) {
            p.skipWs();
            const start = p.pos();
            const c = p.peek() orelse return p.failUnexpected("a key");
            const name = switch (c) {
                '"' => blk: {
                    if (p.startsWith("\"\"\"")) return p.fail(.toml_syntax, start, "a key can't be a multi-line string", .{});
                    break :blk try p.parseBasicString();
                },
                '\'' => blk: {
                    if (p.startsWith("'''")) return p.fail(.toml_syntax, start, "a key can't be a multi-line string", .{});
                    break :blk try p.parseLiteralString();
                },
                else => blk: {
                    if (!isBareKeyChar(c)) return p.failUnexpected("a key");
                    const b = p.i;
                    while (p.peek()) |k| {
                        if (!isBareKeyChar(k)) break;
                        p.advance();
                    }
                    break :blk p.src[b..p.i];
                },
            };
            try parts.append(p.a, .{ .name = name, .span = .{ .start = start, .end = @intCast(p.i) } });
            p.skipWs();
            if (p.peek() != '.') return;
            p.advance();
        }
    }

    fn parseHeader(p: *Parser, root: *Table) ParseError!*Table {
        const start = p.pos();
        p.advance();
        const is_array = p.peek() == '[';
        if (is_array) p.advance();

        var parts: std.ArrayList(KeyPart) = .empty;
        try p.parseKey(&parts);
        if (p.peek() != ']') return p.failUnexpected(if (is_array) "']]'" else "']'");
        p.advance();
        if (is_array) {
            if (p.peek() != ']') return p.failUnexpected("']]'");
            p.advance();
        }

        var t = root;
        for (parts.items[0 .. parts.items.len - 1]) |part| {
            const v = t.get(part.name) orelse {
                t = try p.addTable(t, part, .implicit);
                continue;
            };
            t = switch (v.data) {
                .table => |sub| if (sub.closed()) return p.failDuplicate(part) else sub,
                .array => |arr| if (arr.of_tables) arr.items.items[arr.items.items.len - 1].data.table else return p.failDuplicate(part),
                else => return p.failDuplicate(part),
            };
        }

        const last = parts.items[parts.items.len - 1];
        const header_span: Span = .{ .start = start, .end = @intCast(p.i) };
        if (is_array) {
            const elem = try p.newTable(.array_element, start);
            const elem_value: Value = .{ .span = header_span, .data = .{ .table = elem } };
            if (t.get(last.name)) |v| {
                if (v.data != .array or !v.data.array.of_tables) return p.failDuplicate(last);
                try v.data.array.items.append(p.a, elem_value);
                return elem;
            }
            const arr = try p.a.create(Array);
            arr.* = .{ .of_tables = true };
            try arr.items.append(p.a, elem_value);
            try t.entries.append(p.a, .{ .key = last.name, .key_span = last.span, .value = .{ .span = header_span, .data = .{ .array = arr } } });
            return elem;
        }

        if (t.get(last.name)) |v| {
            if (v.data == .table and v.data.table.origin == .implicit) {
                v.data.table.origin = .header;
                v.data.table.pos = start;
                return v.data.table;
            }
            return p.failDuplicate(last);
        }
        const nt = try p.newTable(.header, start);
        try t.entries.append(p.a, .{ .key = last.name, .key_span = last.span, .value = .{ .span = header_span, .data = .{ .table = nt } } });
        return nt;
    }

    fn parseKeyValue(p: *Parser, table: *Table) ParseError!void {
        var parts: std.ArrayList(KeyPart) = .empty;
        try p.parseKey(&parts);
        if (p.peek() != '=') return p.failUnexpected("'=' after the key");
        p.advance();
        p.skipWs();
        const value = try p.parseValue();
        try p.insertDotted(table, parts.items, value, .dotted);
    }

    /// sets `a.b.c = value` inside `table`, creating the parent tables with
    /// `origin`. a parent may only be reused if a dotted key of the same kind
    /// made it.
    fn insertDotted(p: *Parser, table: *Table, parts: []const KeyPart, value: Value, origin: Table.Origin) ParseError!void {
        var t = table;
        for (parts[0 .. parts.len - 1]) |part| {
            const v = t.get(part.name) orelse {
                t = try p.addTable(t, part, origin);
                continue;
            };
            if (v.data != .table or v.data.table.origin != origin) return p.failDuplicate(part);
            t = v.data.table;
        }
        const last = parts[parts.len - 1];
        if (t.get(last.name) != null) return p.failDuplicate(last);
        try t.entries.append(p.a, .{ .key = last.name, .key_span = last.span, .value = value });
    }

    fn parseValue(p: *Parser) ParseError!Value {
        const start = p.pos();
        const c = p.peek() orelse return p.failUnexpected("a value");
        const data: Value.Data = switch (c) {
            '"' => .{ .string = if (p.startsWith("\"\"\"")) try p.parseMultilineBasic() else try p.parseBasicString() },
            '\'' => .{ .string = if (p.startsWith("'''")) try p.parseMultilineLiteral() else try p.parseLiteralString() },
            '[' => .{ .array = try p.parseArray() },
            '{' => .{ .table = try p.parseInlineTable(start) },
            't', 'f' => .{ .boolean = try p.parseBool() },
            else => try p.parseNumber(),
        };
        return .{ .span = .{ .start = start, .end = @intCast(p.i) }, .data = data };
    }

    fn parseBool(p: *Parser) ParseError!bool {
        inline for (.{ .{ "true", true }, .{ "false", false } }) |kv| {
            if (p.startsWith(kv[0])) {
                const next = p.peekAt(kv[0].len);
                if (next == null or !isBareKeyChar(next.?)) {
                    p.advanceBy(kv[0].len);
                    return kv[1];
                }
            }
        }
        return p.failUnexpected("a value");
    }

    fn parseNumber(p: *Parser) ParseError!Value.Data {
        const start = p.pos();
        const b = p.i;
        while (p.peek()) |c| {
            if (!isNumberChar(c)) break;
            p.advance();
        }
        const tok = p.src[b..p.i];
        if (tok.len == 0) return p.failUnexpected("a value");
        if (looksLikeDateTime(tok)) {
            return p.fail(.toml_unsupported, start, "dates and times aren't supported yet; write it as a string", .{});
        }
        if (parseInteger(tok)) |n| return .{ .integer = n };
        if (parseFloat(tok)) |f| return .{ .float = f };
        return p.fail(.toml_syntax, start, "\"{s}\" isn't a valid value", .{tok});
    }

    fn parseArray(p: *Parser) ParseError!*Array {
        const start = p.pos();
        p.advance();
        const arr = try p.a.create(Array);
        arr.* = .{};
        while (true) {
            try p.skipBlank();
            if (p.peek() == ']') {
                p.advance();
                return arr;
            }
            try arr.items.append(p.a, try p.parseValue());
            try p.skipBlank();
            const c = p.peek() orelse return p.fail(.toml_syntax, start, "this list is never closed", .{});
            switch (c) {
                ',' => p.advance(),
                ']' => {
                    p.advance();
                    return arr;
                },
                else => return p.failUnexpected("',' or ']'"),
            }
        }
    }

    fn parseInlineTable(p: *Parser, start: Pos) ParseError!*Table {
        p.advance();
        const t = try p.newTable(.inline_table, start);
        p.skipWs();
        if (p.peek() == '}') {
            p.advance();
            return t;
        }
        while (true) {
            if (p.peek() == '\n' or p.peek() == '\r') return p.fail(.toml_syntax, p.pos(), "an inline table has to stay on one line", .{});
            var parts: std.ArrayList(KeyPart) = .empty;
            try p.parseKey(&parts);
            if (p.peek() != '=') return p.failUnexpected("'=' after the key");
            p.advance();
            p.skipWs();
            const value = try p.parseValue();
            try p.insertDotted(t, parts.items, value, .inline_dotted);
            p.skipWs();
            const c = p.peek() orelse return p.fail(.toml_syntax, start, "this inline table is never closed", .{});
            switch (c) {
                ',' => {
                    p.advance();
                    p.skipWs();
                    if (p.peek() == '}') return p.fail(.toml_syntax, p.pos(), "an inline table can't end with a comma", .{});
                },
                '}' => {
                    p.advance();
                    return t;
                },
                '\n', '\r' => return p.fail(.toml_syntax, p.pos(), "an inline table has to stay on one line", .{}),
                else => return p.failUnexpected("',' or '}'"),
            }
        }
    }

    fn parseBasicString(p: *Parser) ParseError![]const u8 {
        const start = p.pos();
        p.advance();
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = p.peek() orelse return p.fail(.toml_syntax, start, "this string is never closed", .{});
            switch (c) {
                '"' => {
                    p.advance();
                    return out.toOwnedSlice(p.a);
                },
                '\\' => try p.parseEscape(&out),
                '\n', '\r' => return p.fail(.toml_syntax, start, "this string is never closed; use \"\"\" for text over several lines", .{}),
                else => {
                    if (isControl(c)) return p.fail(.toml_syntax, p.pos(), "control character in a string", .{});
                    try out.append(p.a, c);
                    p.advance();
                },
            }
        }
    }

    fn parseEscape(p: *Parser, out: *std.ArrayList(u8)) ParseError!void {
        const at = p.pos();
        p.advance();
        const e = p.peek() orelse return p.fail(.toml_syntax, at, "unfinished escape", .{});
        p.advance();
        const byte: u8 = switch (e) {
            'b' => 0x08,
            't' => '\t',
            'n' => '\n',
            'f' => 0x0c,
            'r' => '\r',
            '"' => '"',
            '\\' => '\\',
            'u', 'U' => {
                const n: usize = if (e == 'u') 4 else 8;
                if (p.i + n > p.src.len) return p.fail(.toml_syntax, at, "unfinished unicode escape", .{});
                const cp = std.fmt.parseInt(u21, p.src[p.i .. p.i + n], 16) catch
                    return p.fail(.toml_syntax, at, "invalid unicode escape", .{});
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch
                    return p.fail(.toml_syntax, at, "\\{c} escape isn't a unicode scalar value", .{e});
                try out.appendSlice(p.a, buf[0..len]);
                p.advanceBy(n);
                return;
            },
            else => return p.fail(.toml_syntax, at, "unknown escape \\{c}", .{e}),
        };
        try out.append(p.a, byte);
    }

    /// after an opening `"""` or `'''`, a newline right away isn't part of
    /// the string.
    fn skipOpeningNewline(p: *Parser) void {
        if (p.peek() == '\n') {
            p.advance();
        } else if (p.startsWith("\r\n")) {
            p.advanceBy(2);
        }
    }

    /// handles a run of quotes inside a multi-line string. returns true if
    /// the run closed the string. up to two quotes may sit just before the
    /// closing three.
    fn quoteRun(p: *Parser, q: u8, start: Pos, out: *std.ArrayList(u8)) ParseError!bool {
        var n: usize = 0;
        while (p.peekAt(n) == q) n += 1;
        if (n < 3) {
            try out.appendNTimes(p.a, q, n);
            p.advanceBy(n);
            return false;
        }
        if (n > 5) return p.fail(.toml_syntax, start, "too many quotes at the end of this string", .{});
        try out.appendNTimes(p.a, q, n - 3);
        p.advanceBy(n);
        return true;
    }

    fn multilineNewline(p: *Parser, out: *std.ArrayList(u8)) ParseError!void {
        if (p.peek() == '\r') {
            if (p.peekAt(1) != '\n') return p.fail(.toml_syntax, p.pos(), "a carriage return must be followed by a newline", .{});
            p.advance();
        }
        p.advance();
        try out.append(p.a, '\n');
    }

    fn parseMultilineBasic(p: *Parser) ParseError![]const u8 {
        const start = p.pos();
        p.advanceBy(3);
        p.skipOpeningNewline();
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = p.peek() orelse return p.fail(.toml_syntax, start, "this string is never closed", .{});
            switch (c) {
                '"' => if (try p.quoteRun('"', start, &out)) return out.toOwnedSlice(p.a),
                '\\' => {
                    if (p.lineEndingBackslash()) {
                        p.advance();
                        while (p.peek()) |w| {
                            if (w != ' ' and w != '\t' and w != '\n' and w != '\r') break;
                            p.advance();
                        }
                    } else {
                        try p.parseEscape(&out);
                    }
                },
                '\n', '\r' => try p.multilineNewline(&out),
                else => {
                    if (isControl(c)) return p.fail(.toml_syntax, p.pos(), "control character in a string", .{});
                    try out.append(p.a, c);
                    p.advance();
                },
            }
        }
    }

    /// a backslash followed only by spaces up to the end of the line.
    fn lineEndingBackslash(p: *const Parser) bool {
        var j = p.i + 1;
        while (j < p.src.len and (p.src[j] == ' ' or p.src[j] == '\t')) j += 1;
        return j < p.src.len and (p.src[j] == '\n' or (p.src[j] == '\r' and j + 1 < p.src.len and p.src[j + 1] == '\n'));
    }

    fn parseLiteralString(p: *Parser) ParseError![]const u8 {
        const start = p.pos();
        p.advance();
        const b = p.i;
        while (true) {
            const c = p.peek() orelse return p.fail(.toml_syntax, start, "this string is never closed", .{});
            switch (c) {
                '\'' => {
                    const s = p.src[b..p.i];
                    p.advance();
                    return p.a.dupe(u8, s);
                },
                '\n', '\r' => return p.fail(.toml_syntax, start, "this string is never closed; use ''' for text over several lines", .{}),
                else => {
                    if (isControl(c)) return p.fail(.toml_syntax, p.pos(), "control character in a string", .{});
                    p.advance();
                },
            }
        }
    }

    fn parseMultilineLiteral(p: *Parser) ParseError![]const u8 {
        const start = p.pos();
        p.advanceBy(3);
        p.skipOpeningNewline();
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = p.peek() orelse return p.fail(.toml_syntax, start, "this string is never closed", .{});
            switch (c) {
                '\'' => if (try p.quoteRun('\'', start, &out)) return out.toOwnedSlice(p.a),
                '\n', '\r' => try p.multilineNewline(&out),
                else => {
                    if (isControl(c)) return p.fail(.toml_syntax, p.pos(), "control character in a string", .{});
                    try out.append(p.a, c);
                    p.advance();
                },
            }
        }
    }
};

fn isControl(c: u8) bool {
    return (c < 0x20 and c != '\t') or c == 0x7f;
}

fn isBareKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn isNumberChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '+' or c == '-' or c == '.' or c == ':';
}

fn looksLikeDateTime(tok: []const u8) bool {
    const d = std.ascii.isDigit;
    if (tok.len >= 5 and d(tok[0]) and d(tok[1]) and d(tok[2]) and d(tok[3]) and tok[4] == '-') return true;
    return tok.len >= 3 and d(tok[0]) and d(tok[1]) and tok[2] == ':';
}

/// digits of `base`, with single underscores only between digits.
fn validDigits(s: []const u8, base: u8) bool {
    if (s.len == 0 or s[0] == '_' or s[s.len - 1] == '_') return false;
    var prev_underscore = false;
    for (s) |c| {
        if (c == '_') {
            if (prev_underscore) return false;
            prev_underscore = true;
            continue;
        }
        prev_underscore = false;
        _ = std.fmt.charToDigit(c, base) catch return false;
    }
    return true;
}

fn stripUnderscores(buf: []u8, s: []const u8) ?[]const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (c == '_') continue;
        if (n == buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

fn parseInteger(tok: []const u8) ?i64 {
    var s = tok;
    var sign: ?u8 = null;
    if (s[0] == '+' or s[0] == '-') {
        sign = s[0];
        s = s[1..];
    }
    var base: u8 = 10;
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'o' or s[1] == 'b')) {
        if (sign != null) return null;
        base = switch (s[1]) {
            'x' => 16,
            'o' => 8,
            else => 2,
        };
        s = s[2..];
    } else if (s.len > 1 and s[0] == '0') {
        return null;
    }
    if (!validDigits(s, base)) return null;
    var buf: [72]u8 = undefined;
    buf[0] = if (sign == '-') '-' else '+';
    const digits = stripUnderscores(buf[1..], s) orelse return null;
    return std.fmt.parseInt(i64, buf[0 .. digits.len + 1], base) catch null;
}

fn parseFloat(tok: []const u8) ?f64 {
    var s = tok;
    var negative = false;
    if (s[0] == '+' or s[0] == '-') {
        negative = s[0] == '-';
        s = s[1..];
    }
    if (std.mem.eql(u8, s, "inf")) return if (negative) -std.math.inf(f64) else std.math.inf(f64);
    if (std.mem.eql(u8, s, "nan")) return std.math.nan(f64);

    const exp_at = std.mem.indexOfAny(u8, s, "eE");
    const mantissa = s[0 .. exp_at orelse s.len];
    const dot = std.mem.indexOfScalar(u8, mantissa, '.');
    if (dot == null and exp_at == null) return null;

    const int_part = mantissa[0 .. dot orelse mantissa.len];
    if (!validDigits(int_part, 10)) return null;
    if (int_part.len > 1 and int_part[0] == '0') return null;
    if (dot) |d| {
        if (!validDigits(mantissa[d + 1 ..], 10)) return null;
    }
    if (exp_at) |e| {
        var exp = s[e + 1 ..];
        if (exp.len > 0 and (exp[0] == '+' or exp[0] == '-')) exp = exp[1..];
        if (!validDigits(exp, 10)) return null;
    }
    var buf: [128]u8 = undefined;
    const clean = stripUnderscores(&buf, tok) orelse return null;
    return std.fmt.parseFloat(f64, clean) catch null;
}

fn isBareKey(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!isBareKeyChar(c)) return false;
    }
    return true;
}

/// writes `s` as a toml basic string, quotes included.
pub fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\t' => try w.writeAll("\\t"),
            '\r' => try w.writeAll("\\r"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            else => if (isControl(c)) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

/// writes a key as bare if it can be, quoted otherwise.
pub fn writeKey(w: *std.Io.Writer, key: []const u8) !void {
    if (isBareKey(key)) return w.writeAll(key);
    try writeString(w, key);
}

// -- tests --

const testing = std.testing;

fn expectParse(src: []const u8) !Document {
    var info: ErrorInfo = .{};
    return parse(testing.allocator, src, &info) catch |e| {
        if (e == error.Syntax) std.debug.print("unexpected error at {d}:{d}: {s}\n", .{ info.pos.line, info.pos.column, info.message() });
        return e;
    };
}

fn expectError(src: []const u8, code: diag.Code, line: u32, column: u32, contains: []const u8) !void {
    var info: ErrorInfo = .{};
    if (parse(testing.allocator, src, &info)) |d| {
        var doc = d;
        doc.deinit();
        std.debug.print("expected an error for:\n{s}\n", .{src});
        return error.TestExpectedError;
    } else |e| {
        try testing.expectEqual(error.Syntax, e);
    }
    try testing.expectEqual(code, info.code);
    testing.expectEqual(line, info.pos.line) catch |e| {
        std.debug.print("message: {s}\n", .{info.message()});
        return e;
    };
    try testing.expectEqual(column, info.pos.column);
    if (std.mem.indexOf(u8, info.message(), contains) == null) {
        std.debug.print("message \"{s}\" doesn't contain \"{s}\"\n", .{ info.message(), contains });
        return error.TestUnexpectedMessage;
    }
}

fn expectInvalid(src: []const u8) !void {
    var info: ErrorInfo = .{};
    if (parse(testing.allocator, src, &info)) |d| {
        var doc = d;
        doc.deinit();
        std.debug.print("expected an error for:\n{s}\n", .{src});
        return error.TestExpectedError;
    } else |_| {}
}

fn str(t: *const Table, key: []const u8) []const u8 {
    return t.get(key).?.data.string;
}

test "key values and types" {
    var doc = try expectParse(
        \\# a machine
        \\hostname = "atlas"   # trailing comment
        \\count = 42
        \\ratio = 0.5
        \\on = true
        \\off = false
        \\
    );
    defer doc.deinit();
    const r = doc.root;
    try testing.expectEqualStrings("atlas", str(r, "hostname"));
    try testing.expectEqual(42, r.get("count").?.data.integer);
    try testing.expectEqual(0.5, r.get("ratio").?.data.float);
    try testing.expect(r.get("on").?.data.boolean);
    try testing.expect(!r.get("off").?.data.boolean);
    try testing.expectEqual(5, r.entries.items.len);
}

test "spans point at keys and values" {
    const src = "a = 1\n  name = \"atlas\"\n";
    var doc = try expectParse(src);
    defer doc.deinit();
    const e = doc.root.getEntry("name").?;
    try testing.expectEqual(2, e.key_span.start.line);
    try testing.expectEqual(3, e.key_span.start.column);
    try testing.expectEqual(2, e.value.span.start.line);
    try testing.expectEqual(10, e.value.span.start.column);
    try testing.expectEqualStrings("\"atlas\"", src[e.value.span.start.offset..e.value.span.end]);
}

test "tables, dotted keys, and implicit parents" {
    var doc = try expectParse(
        \\[system]
        \\hostname = "atlas"
        \\
        \\[users.kacy]
        \\shell = "zsh"
        \\groups = ["wheel", "video"]
        \\
        \\[users]
        \\root.shell = "bash"
        \\
        \\[services.ssh]
        \\enabled = true
        \\
    );
    defer doc.deinit();
    const users = doc.root.get("users").?.data.table;
    try testing.expectEqualStrings("zsh", str(users.get("kacy").?.data.table, "shell"));
    try testing.expectEqualStrings("bash", str(users.get("root").?.data.table, "shell"));
    const groups = users.get("kacy").?.data.table.get("groups").?.data.array.items.items;
    try testing.expectEqual(2, groups.len);
    try testing.expectEqualStrings("video", groups[1].data.string);
    try testing.expect(doc.root.get("services").?.data.table.get("ssh").?.data.table.get("enabled").?.data.boolean);
}

test "dotted keys at the root build tables" {
    var doc = try expectParse("a.b.c = 1\na.b.d = 2\na.e = 3\n");
    defer doc.deinit();
    const b = doc.root.get("a").?.data.table.get("b").?.data.table;
    try testing.expectEqual(2, b.get("d").?.data.integer);
}

test "sub-tables may extend a table made by dotted keys" {
    var doc = try expectParse("[fruit]\napple.color = \"red\"\n[fruit.apple.texture]\nsmooth = true\n");
    defer doc.deinit();
    const apple = doc.root.get("fruit").?.data.table.get("apple").?.data.table;
    try testing.expect(apple.get("texture").?.data.table.get("smooth").?.data.boolean);
}

test "arrays of tables" {
    var doc = try expectParse(
        \\[[repo]]
        \\name = "core"
        \\[repo.sig]
        \\level = 1
        \\[[repo]]
        \\name = "extra"
        \\
    );
    defer doc.deinit();
    const arr = doc.root.get("repo").?.data.array;
    try testing.expect(arr.of_tables);
    try testing.expectEqual(2, arr.items.items.len);
    try testing.expectEqualStrings("extra", str(arr.items.items[1].data.table, "name"));
    try testing.expectEqual(1, arr.items.items[0].data.table.get("sig").?.data.table.get("level").?.data.integer);
}

test "multi-line arrays with comments and trailing commas" {
    var doc = try expectParse(
        \\packages = [
        \\  "git",      # vcs
        \\  "neovim",
        \\
        \\  "ripgrep",
        \\]
        \\empty = []
        \\nested = [[1, 2], ["a"]]
        \\
    );
    defer doc.deinit();
    try testing.expectEqual(3, doc.root.get("packages").?.data.array.items.items.len);
    try testing.expectEqual(0, doc.root.get("empty").?.data.array.items.items.len);
    const nested = doc.root.get("nested").?.data.array.items.items;
    try testing.expectEqual(2, nested[0].data.array.items.items[1].data.integer);
}

test "inline tables" {
    var doc = try expectParse("providers = { java-runtime = \"jre-openjdk\", a.b = 1 }\nempty = {}\n");
    defer doc.deinit();
    const p = doc.root.get("providers").?.data.table;
    try testing.expectEqualStrings("jre-openjdk", str(p, "java-runtime"));
    try testing.expectEqual(1, p.get("a").?.data.table.get("b").?.data.integer);
    try testing.expectEqual(0, doc.root.get("empty").?.data.table.entries.items.len);
}

test "quoted keys" {
    var doc = try expectParse("\"with space\" = 1\n'lit.eral' = 2\n\"\" = 3\n1234 = 4\ntrue = 5\n");
    defer doc.deinit();
    try testing.expectEqual(1, doc.root.get("with space").?.data.integer);
    try testing.expectEqual(2, doc.root.get("lit.eral").?.data.integer);
    try testing.expectEqual(3, doc.root.get("").?.data.integer);
    try testing.expectEqual(4, doc.root.get("1234").?.data.integer);
    try testing.expectEqual(5, doc.root.get("true").?.data.integer);
}

test "basic string escapes" {
    var doc = try expectParse(
        \\s = "tab\there \"quoted\" back\\slash \u00e9 \U0001F600 nl\n"
        \\
    );
    defer doc.deinit();
    try testing.expectEqualStrings("tab\there \"quoted\" back\\slash é 😀 nl\n", str(doc.root, "s"));
}

test "literal strings keep backslashes" {
    var doc = try expectParse("path = 'C:\\Users\\nobody'\nre = '<\\i\\c*\\s*>'\n");
    defer doc.deinit();
    try testing.expectEqualStrings("C:\\Users\\nobody", str(doc.root, "path"));
    try testing.expectEqualStrings("<\\i\\c*\\s*>", str(doc.root, "re"));
}

test "multi-line basic strings" {
    var doc = try expectParse("a = \"\"\"\nroses\nviolets\"\"\"\n" ++
        "b = \"\"\"\\\n    the quick \\\n    brown fox\"\"\"\n" ++
        "c = \"\"\"she said \"hi\"\"\"\"\n" ++
        "d = \"\"\"two \"\"quotes\"\"\"\n");
    defer doc.deinit();
    try testing.expectEqualStrings("roses\nviolets", str(doc.root, "a"));
    try testing.expectEqualStrings("the quick brown fox", str(doc.root, "b"));
    try testing.expectEqualStrings("she said \"hi\"", str(doc.root, "c"));
    try testing.expectEqualStrings("two \"\"quotes", str(doc.root, "d"));
}

test "multi-line literal strings" {
    var doc = try expectParse("a = '''\nfirst line\n  \\n stays raw'''\nb = ''''quoted'''''\n");
    defer doc.deinit();
    try testing.expectEqualStrings("first line\n  \\n stays raw", str(doc.root, "a"));
    try testing.expectEqualStrings("'quoted''", str(doc.root, "b"));
}

test "crlf line endings" {
    var doc = try expectParse("a = 1\r\n[t]\r\nb = \"\"\"x\r\ny\"\"\"\r\n");
    defer doc.deinit();
    try testing.expectEqualStrings("x\ny", str(doc.root.get("t").?.data.table, "b"));
}

test "integers" {
    var doc = try expectParse(
        \\a = +99
        \\b = -17
        \\c = 0
        \\d = 1_000_000
        \\e = 0xDEAD_beef
        \\f = 0o755
        \\g = 0b1101
        \\h = 9223372036854775807
        \\i = -9223372036854775808
        \\
    );
    defer doc.deinit();
    const r = doc.root;
    try testing.expectEqual(99, r.get("a").?.data.integer);
    try testing.expectEqual(-17, r.get("b").?.data.integer);
    try testing.expectEqual(0, r.get("c").?.data.integer);
    try testing.expectEqual(1_000_000, r.get("d").?.data.integer);
    try testing.expectEqual(0xdeadbeef, r.get("e").?.data.integer);
    try testing.expectEqual(0o755, r.get("f").?.data.integer);
    try testing.expectEqual(13, r.get("g").?.data.integer);
    try testing.expectEqual(std.math.maxInt(i64), r.get("h").?.data.integer);
    try testing.expectEqual(std.math.minInt(i64), r.get("i").?.data.integer);
}

test "floats" {
    var doc = try expectParse(
        \\a = 3.1415
        \\b = -0.01
        \\c = 5e+22
        \\d = 1e06
        \\e = -2E-2
        \\f = 6.626e-34
        \\g = 224_617.445_991
        \\h = inf
        \\i = -inf
        \\j = nan
        \\
    );
    defer doc.deinit();
    const r = doc.root;
    try testing.expectEqual(3.1415, r.get("a").?.data.float);
    try testing.expectEqual(5e22, r.get("c").?.data.float);
    try testing.expectEqual(1e6, r.get("d").?.data.float);
    try testing.expectEqual(-2e-2, r.get("e").?.data.float);
    try testing.expectEqual(224617.445991, r.get("g").?.data.float);
    try testing.expect(std.math.isPositiveInf(r.get("h").?.data.float));
    try testing.expect(std.math.isNegativeInf(r.get("i").?.data.float));
    try testing.expect(std.math.isNan(r.get("j").?.data.float));
}

test "bad numbers" {
    for ([_][]const u8{
        "a = 01\n",  "a = 1__0\n", "a = _1\n",                   "a = 1_\n",   "a = +0x10\n",
        "a = 0xG\n", "a = 1.\n",   "a = .5\n",                   "a = 1.e5\n", "a = 03.14\n",
        "a = 1e\n",  "a = 1_.0\n", "a = 99999999999999999999\n",
    }) |src| try expectInvalid(src);
}

test "error positions and messages" {
    try expectError("a = 1\nb = atlas\n", .toml_syntax, 2, 5, "\"atlas\" isn't a valid value");
    try expectError("a = \"open\n", .toml_syntax, 1, 5, "never closed");
    try expectError("a = 1 b = 2\n", .toml_syntax, 1, 7, "expected the end of the line, found 'b'");
    try expectError("[t\na = 1\n", .toml_syntax, 1, 3, "expected ']', found the end of the line");
    try expectError("a =\n", .toml_syntax, 1, 4, "expected a value, found the end of the line");
    try expectError("a\n", .toml_syntax, 1, 2, "expected '=' after the key");
    try expectError("a = \"\\q\"\n", .toml_syntax, 1, 6, "unknown escape \\q");
    try expectError("a = { b = 1,\n", .toml_syntax, 1, 13, "one line");
    try expectError("a = [1, 2\n", .toml_syntax, 1, 5, "never closed");
}

test "dates are unsupported, not wrong" {
    try expectError("when = 1979-05-27\n", .toml_unsupported, 1, 8, "dates and times");
    try expectError("when = 07:32:00\n", .toml_unsupported, 1, 8, "dates and times");
    try expectError("when = 1979-05-27T07:32:00Z\n", .toml_unsupported, 1, 8, "dates and times");
}

test "duplicate keys and tables" {
    try expectError("a = 1\na = 2\n", .toml_duplicate_key, 2, 1, "\"a\" is already defined");
    try expectError("[t]\n[t]\n", .toml_duplicate_key, 2, 2, "\"t\"");
    try expectError("[t.u]\n[t]\n[t]\n", .toml_duplicate_key, 3, 2, "\"t\"");
    try expectError("a.b = 1\na = 2\n", .toml_duplicate_key, 2, 1, "\"a\"");
    try expectError("[fruit]\napple.color = 1\n[fruit.apple]\n", .toml_duplicate_key, 3, 8, "\"apple\"");
    try expectError("[a.b.c]\nz = 9\n[a]\nb.c.t = 1\n", .toml_duplicate_key, 4, 1, "\"b\"");
    try expectError("t = { a = 1 }\n[t]\n", .toml_duplicate_key, 2, 2, "\"t\"");
    try expectError("t = { a = 1 }\n[t.b]\n", .toml_duplicate_key, 2, 2, "\"t\"");
    try expectError("a = [1]\n[[a]]\n", .toml_duplicate_key, 2, 3, "\"a\"");
    try expectError("[[a]]\n[a]\n", .toml_duplicate_key, 2, 2, "\"a\"");
    try expectError("t = { a.b = 1, a = 2 }\n", .toml_duplicate_key, 1, 16, "\"a\"");
}

test "a header may define its implicit parent once" {
    var doc = try expectParse("[a.b]\nx = 1\n[a]\ny = 2\n");
    defer doc.deinit();
    try testing.expectEqual(2, doc.root.get("a").?.data.table.get("y").?.data.integer);
}

test "invalid documents" {
    for ([_][]const u8{
        "a = 1 # bell \x07\n",
        "a = \"bell \x07\"\n",
        "a = 1\rb = 2\n",
        "[]\n",
        "[a.]\n",
        "a = { b = 1, }\n",
        "a = \"\"\"never closed\n",
        "a = '''x''''''\n",
        "\"\"\"key\"\"\" = 1\n",
        "a = \"\\uD800\"\n",
        "a = tru\n",
        "a = truex\n",
        "a = [1 2]\n",
        "a = \xff\n",
    }) |src| try expectInvalid(src);
}

test "writeString round-trips" {
    const cases = [_][]const u8{ "plain", "with \"quotes\"", "tab\tand\nnewline", "back\\slash", "bell\x07" };
    for (cases) |s| {
        var buf: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.writeAll("v = ");
        try writeString(&w, s);
        try w.writeByte('\n');
        var doc = try expectParse(w.buffered());
        defer doc.deinit();
        try testing.expectEqualStrings(s, str(doc.root, "v"));
    }
}

test "writeKey quotes only when needed" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeKey(&w, "java-runtime");
    try w.writeByte(' ');
    try writeKey(&w, "has space");
    try testing.expectEqualStrings("java-runtime \"has space\"", w.buffered());
}

test "invalid utf-8 is reported where it starts" {
    try expectError("a = \"é\"\nb = \"\xff\"\n", .toml_syntax, 2, 6, "utf-8");
}

test "mutated documents never crash the parser" {
    const seeds = [_][]const u8{
        "version = 1\ninclude = [\"imported.toml\"]\npackages = [\"git\", \"neovim\"]\n[system]\nhostname = \"atlas\"\n",
        "[users.kacy]\nshell = \"zsh\"\ngroups = [\"wheel\"]\n[[repo]]\nname = 'core'\n[services]\nssh = true\n",
        "a = \"\"\"\nmulti \\\n  line\"\"\"\nb = { c = 1, d.e = [1.5, -2e3, 0x1f] }\nf = '''lit'''\n",
    };
    var prng: std.Random.DefaultPrng = .init(0x70a1);
    const rand = prng.random();
    const alphabet = "[]{}=,.\"'#\\\n\r\t -_+aez019xob:\xc3\xa9";
    var buf: [256]u8 = undefined;
    for (0..3000) |_| {
        const seed = seeds[rand.uintLessThan(usize, seeds.len)];
        var len = seed.len;
        @memcpy(buf[0..len], seed);
        for (0..rand.intRangeAtMost(usize, 1, 6)) |_| {
            const at = rand.uintLessThan(usize, len);
            switch (rand.uintLessThan(u8, 3)) {
                0 => buf[at] = alphabet[rand.uintLessThan(usize, alphabet.len)],
                1 => if (len > 1) {
                    std.mem.copyForwards(u8, buf[at .. len - 1], buf[at + 1 .. len]);
                    len -= 1;
                },
                else => if (len < buf.len) {
                    std.mem.copyBackwards(u8, buf[at + 1 .. len + 1], buf[at..len]);
                    buf[at] = alphabet[rand.uintLessThan(usize, alphabet.len)];
                    len += 1;
                },
            }
        }
        var info: ErrorInfo = .{};
        if (parse(testing.allocator, buf[0..len], &info)) |d| {
            var doc = d;
            doc.deinit();
        } else |e| {
            try testing.expectEqual(error.Syntax, e);
            try testing.expect(info.pos.offset <= len);
            try testing.expect(info.len > 0);
        }
    }
}
