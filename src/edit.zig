//! edits machine.toml in place. every function takes the file's text and
//! returns new text with one change, found through the parser's spans, so
//! comments, spacing, and the order of everything else stay as the user
//! wrote them.

const std = @import("std");
const toml = @import("toml.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{ OutOfMemory, BadToml };

const Doc = struct {
    text: []const u8,
    doc: toml.Document,

    fn init(a: Allocator, text: []const u8) Error!Doc {
        var info: toml.ErrorInfo = .{};
        const doc = toml.parse(a, text, &info) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => return error.BadToml,
        };
        return .{ .text = text, .doc = doc };
    }

    fn deinit(d: *Doc) void {
        d.doc.deinit();
    }

    /// the table at `path` below the root, if it exists.
    fn table(d: *const Doc, path: []const []const u8) ?*const toml.Table {
        return (d.find(path) orelse return null).table;
    }

    const Found = struct {
        table: *const toml.Table,
        /// the value that holds the table, when a parent table holds it.
        value: ?*const toml.Value,
        /// the path from the nearest table with a header, for tables made
        /// by dotted keys.
        dotted: []const []const u8,
    };

    /// the table at `path`, and how it's written.
    fn find(d: *const Doc, path: []const []const u8) ?Found {
        var t: *const toml.Table = d.doc.root;
        var value: ?*const toml.Value = null;
        var header: usize = 0;
        for (path, 0..) |p, i| {
            const v = t.get(p) orelse return null;
            if (v.data != .table) return null;
            t = v.data.table;
            value = v;
            if (t.origin != .dotted) header = i + 1;
        }
        return .{ .table = t, .value = value, .dotted = path[header..] };
    }

    /// whether some key on `path` holds something other than a table.
    fn taken(d: *const Doc, path: []const []const u8) bool {
        var t: *const toml.Table = d.doc.root;
        for (path) |p| {
            const v = t.get(p) orelse return false;
            if (v.data != .table) return true;
            t = v.data.table;
        }
        return false;
    }

    /// the offset just past the end of the line holding `off`.
    fn lineEnd(d: *const Doc, off: usize) usize {
        const nl = std.mem.indexOfScalarPos(u8, d.text, off, '\n') orelse return d.text.len;
        return nl + 1;
    }

    fn lineStart(d: *const Doc, off: usize) usize {
        const nl = std.mem.lastIndexOfScalar(u8, d.text[0..off], '\n') orelse return 0;
        return nl + 1;
    }

    /// where a new `key = ...` line goes in `t`: after its last key, or
    /// right after its header. top-level keys go after `include` or
    /// `version` so they stay above every table.
    fn newKeyLine(d: *const Doc, t: *const toml.Table) usize {
        var end: ?usize = null;
        for (t.entries.items) |e| {
            if (t.origin == .root and !std.mem.eql(u8, e.key, "include") and !std.mem.eql(u8, e.key, "version")) continue;
            if (e.value.data == .table and e.value.data.table.origin != .dotted) continue;
            if (e.value.data == .array and e.value.data.array.of_tables) continue;
            end = @max(end orelse 0, e.value.span.end);
        }
        if (end) |e| return d.lineEnd(e);
        if (t.origin == .root) return 0;
        return d.lineEnd(t.pos.offset);
    }
};

fn splice(a: Allocator, text: []const u8, at: usize, remove: usize, insert: []const u8) ![]u8 {
    return std.mem.concat(a, u8, &.{ text[0..at], insert, text[at + remove ..] });
}

/// `s` as a toml string, quotes included.
fn quoted(a: Allocator, s: []const u8) ![]u8 {
    return render(a, toml.writeString, s);
}

/// `key` as a toml key: bare when it can be, quoted otherwise.
fn keyText(a: Allocator, key: []const u8) ![]u8 {
    return render(a, toml.writeKey, key);
}

fn render(a: Allocator, comptime f: fn (*std.Io.Writer, []const u8) std.Io.Writer.Error!void, s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    f(&out.writer, s) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn ensureNewline(a: Allocator, text: []const u8) ![]const u8 {
    if (text.len == 0 or text[text.len - 1] == '\n') return text;
    return std.mem.concat(a, u8, &.{ text, "\n" });
}

/// adds `item` to the string list `key` in the table at `path`, creating
/// the list, or the table, if needed. returns null if it's already there.
pub fn addToList(a: Allocator, text_in: []const u8, path: []const []const u8, key: []const u8, item: []const u8) Error!?[]u8 {
    const text = try ensureNewline(a, text_in);
    var d = try Doc.init(a, text);
    defer d.deinit();
    const q = try quoted(a, item);
    const list = try std.fmt.allocPrint(a, "[{s}]", .{q});

    const t = d.table(path) orelse return try addKey(a, &d, path, key, list);
    const v = t.get(key) orelse return try addKey(a, &d, path, key, list);
    if (v.data != .array) return error.BadToml;
    const items = v.data.array.items.items;
    for (items) |it| {
        if (it.data == .string and std.mem.eql(u8, it.data.string, item)) return null;
    }

    const open = v.span.start.offset;
    const close = v.span.end - 1;
    if (items.len == 0) return try splice(a, text, open + 1, 0, q);
    const last = items[items.len - 1];
    if (std.mem.indexOfScalar(u8, text[open..close], '\n') == null) {
        return try splice(a, text, last.span.end, 0, try std.fmt.allocPrint(a, ", {s}", .{q}));
    }

    // what's before the last item on its line: only its indent, when
    // it's on a line of its own.
    const before = text[d.lineStart(last.span.start.offset)..last.span.start.offset];
    const indent = before[0 .. before.len - std.mem.trimStart(u8, before, " \t").len];
    const alone = indent.len == before.len;

    // the last item shares the closing bracket's line: the new item goes
    // right after it, on its own line if the last item is on its own line.
    if (std.mem.indexOfScalar(u8, text[last.span.end..close], '\n') == null) {
        const sep = if (alone)
            try std.fmt.allocPrint(a, "\n{s}", .{indent})
        else
            " ";
        const comma = std.mem.indexOfScalarPos(u8, text[0..close], last.span.end, ',');
        if (comma) |c| return try splice(a, text, c + 1, 0, try std.fmt.allocPrint(a, "{s}{s}", .{ sep, q }));
        return try splice(a, text, last.span.end, 0, try std.fmt.allocPrint(a, ",{s}{s}", .{ sep, q }));
    }

    // a list wrapped with several items a line: the new one goes after
    // the last, on its line.
    if (!alone) {
        if (commaAfter(text, last.span.end, close)) |c| return try splice(a, text, c + 1, 0, try std.fmt.allocPrint(a, " {s},", .{q}));
        return try splice(a, text, last.span.end, 0, try std.fmt.allocPrint(a, ", {s}", .{q}));
    }

    // a list over several lines: a new line before the closing bracket,
    // indented like the last item, with a comma after the last item if it
    // had none.
    const new_line = try std.fmt.allocPrint(a, "{s}{s},\n", .{ indent, q });
    var out = try splice(a, text, d.lineStart(close), 0, new_line);
    if (commaAfter(text, last.span.end, close) == null) out = try splice(a, out, last.span.end, 0, ",");
    return out;
}

/// where the comma after `from` is, skipping spaces, line breaks, and
/// comments, before `limit`.
fn commaAfter(text: []const u8, from: usize, limit: usize) ?usize {
    var i = from;
    while (i < limit) : (i += 1) {
        switch (text[i]) {
            ',' => return i,
            ' ', '\t', '\r', '\n' => {},
            '#' => i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse return null,
            else => return null,
        }
    }
    return null;
}

fn skipBlanks(text: []const u8, from: usize, limit: usize) usize {
    var i = from;
    while (i < limit and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return i;
}

/// removes every `item` from the string list `key` in the table at `path`.
/// returns null if it isn't there.
pub fn removeFromList(a: Allocator, text: []const u8, path: []const []const u8, key: []const u8, item: []const u8) Error!?[]u8 {
    var out: ?[]u8 = null;
    while (try removeOne(a, out orelse text, path, key, item)) |t| out = t;
    return out;
}

fn removeOne(a: Allocator, text: []const u8, path: []const []const u8, key: []const u8, item: []const u8) Error!?[]u8 {
    var d = try Doc.init(a, text);
    defer d.deinit();
    const t = d.table(path) orelse return null;
    const v = t.get(key) orelse return null;
    if (v.data != .array) return error.BadToml;
    const items = v.data.array.items.items;
    const i = for (items, 0..) |it, n| {
        if (it.data == .string and std.mem.eql(u8, it.data.string, item)) break n;
    } else return null;
    const it = items[i];
    const start = it.span.start.offset;
    var end: usize = it.span.end;

    const comma = commaAfter(text, end, v.span.end - 1);

    // alone on its line, with its comma if it has one: take the whole
    // line, comment included.
    const ls = d.lineStart(start);
    const le = d.lineEnd(start);
    var rest = skipBlanks(text, end, le);
    if (rest < le and text[rest] == ',') rest = skipBlanks(text, rest + 1, le);
    const blank_before = std.mem.trim(u8, text[ls..start], " \t").len == 0;
    const own_comma = comma == null or comma.? < le;
    if (blank_before and own_comma and (rest == le or text[rest] == '\n' or text[rest] == '#' or text[rest] == '\r')) {
        return try splice(a, text, ls, le - ls, "");
    }

    // otherwise take the item and the comma after it, wherever that is,
    // or the comma before it when it's last.
    if (comma) |c| {
        end = skipBlanks(text, c + 1, text.len);
        return try splice(a, text, start, end - start, "");
    }
    const from = if (i > 0) items[i - 1].span.end else start;
    return try splice(a, text, from, end - from, "");
}

/// sets `key = value` in the table at `path`, where `value` is toml text
/// like `true` or `"mkinitcpio"`. the table may be a `[section]`, an inline
/// `{ ... }`, dotted keys, or missing, in which case a section is added at
/// the end. returns null if the key already holds exactly that text.
fn setKey(a: Allocator, text_in: []const u8, path: []const []const u8, key: []const u8, value: []const u8) Error!?[]u8 {
    const text = try ensureNewline(a, text_in);
    var d = try Doc.init(a, text);
    defer d.deinit();
    if (d.table(path)) |t| {
        if (t.get(key)) |v| {
            const old = text[v.span.start.offset..v.span.end];
            if (std.mem.eql(u8, old, value)) return null;
            return try splice(a, text, v.span.start.offset, old.len, value);
        }
    }
    return try addKey(a, &d, path, key, value);
}

/// adds `key = value`, a key the table at `path` doesn't have yet, written
/// the way the table is: in its braces, as another dotted key, or on a new
/// line. a missing table gets a section at the end.
fn addKey(a: Allocator, d: *const Doc, path: []const []const u8, key: []const u8, value: []const u8) Error![]u8 {
    const text = d.text;
    const k = try keyText(a, key);
    const found = d.find(path) orelse {
        // a new section would define the key a second time.
        if (d.taken(path)) return error.BadToml;
        // the nearest table on the path that exists. an inline one is
        // closed to sections, so the rest goes inside it as inline tables.
        var n = path.len - 1;
        while (n > 0 and d.find(path[0..n]) == null) n -= 1;
        if (n > 0) {
            const origin = d.find(path[0..n]).?.table.origin;
            if (origin == .inline_table or origin == .inline_dotted) {
                var inner = try std.fmt.allocPrint(a, "{{ {s} = {s} }}", .{ k, value });
                var i = path.len - 1;
                while (i > n) : (i -= 1) inner = try std.fmt.allocPrint(a, "{{ {s} = {s} }}", .{ try keyText(a, path[i]), inner });
                return addKey(a, d, path[0..n], path[n], inner);
            }
        }
        return try appendSection(a, text, path, key, value);
    };
    const t = found.table;
    switch (t.origin) {
        .inline_table, .inline_dotted => {
            const v = found.value.?;
            if (t.entries.items.len == 0) {
                return try splice(a, text, v.span.start.offset, v.span.end - v.span.start.offset, try std.fmt.allocPrint(a, "{{ {s} = {s} }}", .{ k, value }));
            }
            return try splice(a, text, lastEnd(t), 0, try std.fmt.allocPrint(a, ", {s} = {s}", .{ k, value }));
        },
        .dotted => {
            const prefix = try pathText(a, found.dotted);
            return try splice(a, text, d.lineEnd(lastEnd(t)), 0, try std.fmt.allocPrint(a, "{s}.{s} = {s}\n", .{ prefix, k, value }));
        },
        // only sub-tables define it so far, so give it its own header.
        .implicit => return try appendSection(a, text, path, key, value),
        .root, .header, .array_element => return try splice(a, text, d.newKeyLine(t), 0, try std.fmt.allocPrint(a, "{s} = {s}\n", .{ k, value })),
    }
}

/// sets `[services.<name>] enabled`, writing `name = true` style where the
/// service isn't set yet. returns null if it already has that value.
pub fn setService(a: Allocator, text: []const u8, name: []const u8, enabled: bool) Error!?[]u8 {
    const value: []const u8 = if (enabled) "true" else "false";
    var d = try Doc.init(a, text);
    defer d.deinit();
    if (d.table(&.{"services"})) |s| {
        if (s.get(name)) |v| {
            if (v.data == .table) return setKey(a, text, &.{ "services", name }, "enabled", value);
        }
    }
    return setKey(a, text, &.{"services"}, name, value);
}

/// sets `[providers] <name> = "<chosen>"`.
pub fn setProvider(a: Allocator, text: []const u8, name: []const u8, chosen: []const u8) Error!?[]u8 {
    return setKey(a, text, &.{"providers"}, name, try quoted(a, chosen));
}

/// adds `[files."<path>"]` with its source, and its mode when there is one.
pub fn addFile(a: Allocator, text: []const u8, path: []const u8, source: []const u8, mode: ?[]const u8) Error![]const u8 {
    const table = [_][]const u8{ "files", path };
    var out: []const u8 = (try setKey(a, text, &table, "source", try quoted(a, source))) orelse text;
    if (mode) |m| out = (try setKey(a, out, &table, "mode", try quoted(a, m))) orelse out;
    return out;
}

/// adds `[path]` with `key = value` at the end of the file.
fn appendSection(a: Allocator, text: []const u8, path: []const []const u8, key: []const u8, value: []const u8) ![]u8 {
    const section = try std.fmt.allocPrint(a, "{s}[{s}]\n{s} = {s}\n", .{ if (text.len > 0) "\n" else "", try pathText(a, path), try keyText(a, key), value });
    return splice(a, text, text.len, 0, section);
}

/// a dotted key path, each part quoted if it needs to be.
fn pathText(a: Allocator, path: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (path, 0..) |p, i| {
        if (i > 0) try out.append(a, '.');
        try out.appendSlice(a, try keyText(a, p));
    }
    return out.items;
}

/// where the last key written in `t`'s own place ends. sub-tables with a
/// header of their own, like `[remove.x]` below `remove.aur = []`, sit
/// elsewhere in the file, so they don't count.
fn lastEnd(t: *const toml.Table) usize {
    var end: usize = 0;
    for (t.entries.items) |e| {
        switch (e.value.data) {
            .table => |sub| if (sub.origin == .header or sub.origin == .implicit) continue,
            .array => |arr| if (arr.of_tables) continue,
            else => {},
        }
        end = @max(end, e.value.span.end);
    }
    return end;
}

// -- tests --

const testing = std.testing;

fn expectEdit(got: Error!?[]u8, want: ?[]const u8) !void {
    const out = try got;
    if (want) |w| {
        try testing.expectEqualStrings(w, out.?);
        var info: toml.ErrorInfo = .{};
        var doc = try toml.parse(testing.allocator, out.?, &info);
        doc.deinit();
    } else try testing.expectEqual(null, out);
}

test "add to a one-line list" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectEdit(addToList(a, "version = 1\npackages = [\"git\", \"neovim\"]  # tools\n", &.{}, "packages", "ripgrep"), "version = 1\npackages = [\"git\", \"neovim\", \"ripgrep\"]  # tools\n");
    try expectEdit(addToList(a, "packages = []\n", &.{}, "packages", "git"), "packages = [\"git\"]\n");
    try expectEdit(addToList(a, "packages = [\"git\"]\n", &.{}, "packages", "git"), null);
}

test "add to a list over several lines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectEdit(addToList(a,
        \\packages = [
        \\    "git",  # vcs
        \\    "neovim"
        \\]
        \\
    , &.{}, "packages", "ripgrep"),
        \\packages = [
        \\    "git",  # vcs
        \\    "neovim",
        \\    "ripgrep",
        \\]
        \\
    );
}

test "add to a list wrapped with several items a line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectEdit(addToList(a, "packages = [\n  \"base\", \"grub\",\n  \"git\", \"nano\",\n]\n", &.{}, "packages", "ripgrep"), "packages = [\n  \"base\", \"grub\",\n  \"git\", \"nano\", \"ripgrep\",\n]\n");
    try expectEdit(addToList(a, "packages = [\"a\", \"b\"\n]\n", &.{}, "packages", "c"), "packages = [\"a\", \"b\", \"c\"\n]\n");
}

test "add to a list whose last item shares the closing bracket's line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectEdit(addToList(a, "packages = [\n  \"base\",\n  \"linux-firmware\"]\n", &.{}, "packages", "git"), "packages = [\n  \"base\",\n  \"linux-firmware\",\n  \"git\"]\n");
    try expectEdit(addToList(a, "packages = [\"base\",\n  \"nano\"]  # tools\n", &.{}, "packages", "git"), "packages = [\"base\",\n  \"nano\",\n  \"git\"]  # tools\n");
    try expectEdit(addToList(a, "packages = [\n  \"base\", \"nano\"]\n", &.{}, "packages", "git"), "packages = [\n  \"base\", \"nano\", \"git\"]\n");
    try expectEdit(addToList(a, "packages = [\n  \"base\",\n  \"nano\", ]\n", &.{}, "packages", "git"), "packages = [\n  \"base\",\n  \"nano\",\n  \"git\" ]\n");
}

test "add creates the list after version and include" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectEdit(addToList(a, "# my machine\nversion = 1\ninclude = [\"base.toml\"]\n\n[system]\nhostname = \"atlas\"\n", &.{}, "packages", "git"), "# my machine\nversion = 1\ninclude = [\"base.toml\"]\npackages = [\"git\"]\n\n[system]\nhostname = \"atlas\"\n");
    try expectEdit(addToList(a, "[system]\nhostname = \"atlas\"", &.{}, "packages", "git"), "packages = [\"git\"]\n[system]\nhostname = \"atlas\"\n");
}

test "add to [remove], creating it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectEdit(addToList(a, "packages = [\"git\"]\n", &.{"remove"}, "packages", "nano"), "packages = [\"git\"]\n\n[remove]\npackages = [\"nano\"]\n");
    try expectEdit(addToList(a, "[remove]\naur = [\"x\"]\n\n[system]\n", &.{"remove"}, "packages", "nano"), "[remove]\naur = [\"x\"]\npackages = [\"nano\"]\n\n[system]\n");
    // inline and dotted forms
    try expectEdit(addToList(a, "remove = { aur = [] }\npackages = [\"git\"]\n", &.{"remove"}, "packages", "nano"), "remove = { aur = [], packages = [\"nano\"] }\npackages = [\"git\"]\n");
    try expectEdit(addToList(a, "remove.aur = []\npackages = [\"git\"]\n", &.{"remove"}, "packages", "nano"), "remove.aur = []\nremove.packages = [\"nano\"]\npackages = [\"git\"]\n");
}

test "remove from lists" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectEdit(removeFromList(a, "packages = [\"git\", \"nano\", \"vim\"]\n", &.{}, "packages", "nano"), "packages = [\"git\", \"vim\"]\n");
    try expectEdit(removeFromList(a, "packages = [\"git\", \"nano\"]\n", &.{}, "packages", "nano"), "packages = [\"git\"]\n");
    try expectEdit(removeFromList(a, "packages = [\"nano\"]\n", &.{}, "packages", "nano"), "packages = []\n");
    try expectEdit(removeFromList(a, "packages = [\n  \"git\",\n  \"nano\",  # editor\n  \"vim\",\n]\n", &.{}, "packages", "nano"), "packages = [\n  \"git\",\n  \"vim\",\n]\n");
    try expectEdit(removeFromList(a, "packages = [\"git\"]\n", &.{}, "packages", "nano"), null);
    try expectEdit(removeFromList(a, "packages = [\"base\",\"nano\",\"nano\"]\n", &.{}, "packages", "nano"), "packages = [\"base\"]\n");
    try expectEdit(removeFromList(a, "packages = [\"nano\",\t\"git\"]\n", &.{}, "packages", "nano"), "packages = [\"git\"]\n");
}

test "remove takes the comma after an item past a comment or line break" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectEdit(removeFromList(a, "packages = [\"a\" # x\n , \"b\"]\n", &.{}, "packages", "a"), "packages = [\"b\"]\n");
    try expectEdit(removeFromList(a, "packages = [\n  \"a\"\n  , \"b\"\n]\n", &.{}, "packages", "a"), "packages = [\n  \"b\"\n]\n");
}

test "enable and disable services" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // flip a shorthand value
    try expectEdit(setService(a, "[services]\nssh = false  # later\n", "ssh", true), "[services]\nssh = true  # later\n");
    try expectEdit(setService(a, "[services]\nssh = true\n", "ssh", true), null);
    // add to an existing [services]
    try expectEdit(setService(a, "[services]\nssh = true\n\n[users.kacy]\nshell = \"zsh\"\n", "tailscale", true), "[services]\nssh = true\ntailscale = true\n\n[users.kacy]\nshell = \"zsh\"\n");
    // no [services] yet
    try expectEdit(setService(a, "packages = [\"git\"]\n", "ssh", true), "packages = [\"git\"]\n\n[services]\nssh = true\n");
    // table forms
    try expectEdit(setService(a, "[services.custom]\nunit = \"c.service\"\nenabled = true\n", "custom", false), "[services.custom]\nunit = \"c.service\"\nenabled = false\n");
    try expectEdit(setService(a, "[services.custom]\nunit = \"c.service\"\n", "custom", false), "[services.custom]\nunit = \"c.service\"\nenabled = false\n");
    try expectEdit(setService(a, "[services]\ncustom = { unit = \"c.service\" }\n", "custom", true), "[services]\ncustom = { unit = \"c.service\", enabled = true }\n");
    try expectEdit(setService(a, "[services]\ncustom = {}\n", "custom", true), "[services]\ncustom = { enabled = true }\n");
    // only sub-tables so far: [services] is implicit, so it gets a header
    try expectEdit(setService(a, "[services.custom]\nunit = \"c.service\"\n", "ssh", true), "[services.custom]\nunit = \"c.service\"\n\n[services]\nssh = true\n");
}

test "set keys in every kind of table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // inline table at the top
    try expectEdit(setProvider(a, "version = 1\nproviders = { initramfs = \"mkinitcpio\" }\npackages = []\n", "libxtables.so", "iptables"), "version = 1\nproviders = { initramfs = \"mkinitcpio\", \"libxtables.so\" = \"iptables\" }\npackages = []\n");
    try expectEdit(setProvider(a, "providers = {}\n", "initramfs", "booster"), "providers = { initramfs = \"booster\" }\n");
    // a section, replacing and adding
    try expectEdit(setProvider(a, "[providers]\ninitramfs = \"dracut\"  # fast\n\n[system]\n", "initramfs", "mkinitcpio"), "[providers]\ninitramfs = \"mkinitcpio\"  # fast\n\n[system]\n");
    try expectEdit(setProvider(a, "[providers]\ninitramfs = \"mkinitcpio\"\n", "initramfs", "mkinitcpio"), null);
    // missing
    try expectEdit(setProvider(a, "packages = [\"git\"]\n", "initramfs", "mkinitcpio"), "packages = [\"git\"]\n\n[providers]\ninitramfs = \"mkinitcpio\"\n");
    // dotted keys
    try expectEdit(setProvider(a, "providers.initramfs = \"mkinitcpio\"\n[system]\n", "sh", "bash"), "providers.initramfs = \"mkinitcpio\"\nproviders.sh = \"bash\"\n[system]\n");
    try expectEdit(setKey(a, "[services]\nssh.enabled = true\n", &.{ "services", "ssh" }, "unit", "\"x.service\""), "[services]\nssh.enabled = true\nssh.unit = \"x.service\"\n");
}

test "add a file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFile(addFile(a, "# laptop\npackages = [\"git\"]  # tools\n", "/etc/ssh/sshd_config", "files/etc/ssh/sshd_config", "0600"),
        \\# laptop
        \\packages = ["git"]  # tools
        \\
        \\[files."/etc/ssh/sshd_config"]
        \\source = "files/etc/ssh/sshd_config"
        \\mode = "0600"
        \\
    );
    try expectFile(addFile(a, "[files.\"/etc/motd\"]\ntext = \"hi\"  # greeting\n\n[services]\nssh = true\n", "/etc/hosts", "files/etc/hosts", null),
        \\[files."/etc/motd"]
        \\text = "hi"  # greeting
        \\
        \\[services]
        \\ssh = true
        \\
        \\[files."/etc/hosts"]
        \\source = "files/etc/hosts"
        \\
    );
}

fn expectFile(got: Error![]const u8, want: []const u8) !void {
    const out = try got;
    try testing.expectEqualStrings(want, out);
    var info: toml.ErrorInfo = .{};
    var doc = try toml.parse(testing.allocator, out, &info);
    doc.deinit();
}

test "a dotted key goes next to its siblings, not under a later header" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try expectEdit(addToList(arena.allocator(), "remove.aur = []\n[system]\n[remove.x]\n", &.{"remove"}, "packages", "git"), "remove.aur = []\nremove.packages = [\"git\"]\n[system]\n[remove.x]\n");
}

test "a file goes inside an inline files table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFile(addFile(a, "files = { }\n", "/etc/motd", "files/etc/motd", "0600"), "files = { \"/etc/motd\" = { source = \"files/etc/motd\", mode = \"0600\" } }\n");
    try expectFile(addFile(a, "files = { \"/etc/x\" = { text = \"t\" } }\n", "/etc/motd", "m", null), "files = { \"/etc/x\" = { text = \"t\" }, \"/etc/motd\" = { source = \"m\" } }\n");
}

test "a key that isn't a table isn't given a section" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.BadToml, addToList(a, "packages = [\"git\"]\nremove = +inf\n", &.{"remove"}, "packages", "git"));
    try testing.expectError(error.BadToml, setProvider(a, "providers = 5\n", "sh", "bash"));
    try testing.expectError(error.BadToml, setService(a, "[[services]]\n", "ssh", true));
    try testing.expectError(error.BadToml, addFile(a, "files = 5\n", "/etc/motd", "files/etc/motd", null));
    try testing.expectError(error.BadToml, addFile(a, "[files]\n\"/etc/motd\" = \"hi\"\n", "/etc/motd", "files/etc/motd", "0600"));
}

test "odd names are quoted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try expectEdit(addToList(arena.allocator(), "packages = [\"a\"]\n", &.{}, "packages", "with \"quote\""), "packages = [\"a\", \"with \\\"quote\\\"\"]\n");
}

fn packagesOf(a: Allocator, text: []const u8) ![]const []const u8 {
    var info: toml.ErrorInfo = .{};
    var doc = toml.parse(a, text, &info) catch |e| {
        std.debug.print("edit produced invalid toml ({s}):\n{s}\n", .{ info.message(), text });
        return e;
    };
    defer doc.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    if (doc.root.get("packages")) |v| {
        for (v.data.array.items.items) |it| try out.append(a, try a.dupe(u8, it.data.string));
    }
    return out.items;
}

test "random adds and removes keep the file valid and correct" {
    const seeds = [_][]const u8{
        "",
        "version = 1\n",
        "packages = []\n",
        "packages = [\"git\"] # tools\n[system]\nhostname = \"atlas\"\n",
        "version = 1\npackages = [\n  \"git\",\n  \"vim\" # editor\n]\n\n[services]\nssh = true\n",
        "include = [\"base.toml\"]\npackages = [ \"a\" , \"b\" ]\n",
    };
    const pool = [_][]const u8{ "git", "vim", "a", "b", "ripgrep", "neovim" };
    var prng: std.Random.DefaultPrng = .init(0xed17);
    const rand = prng.random();
    for (seeds) |seed| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var text: []const u8 = seed;
        var model: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (try packagesOf(a, text)) |p| try model.put(a, p, {});
        for (0..120) |_| {
            const name = pool[rand.uintLessThan(usize, pool.len)];
            if (rand.boolean()) {
                if (try addToList(a, text, &.{}, "packages", name)) |t| text = t;
                try model.put(a, name, {});
            } else {
                if (try removeFromList(a, text, &.{}, "packages", name)) |t| text = t;
                _ = model.orderedRemove(name);
            }
            const got = try packagesOf(a, text);
            try testing.expectEqual(model.count(), got.len);
            for (got) |p| try testing.expect(model.contains(p));
        }
    }
}
