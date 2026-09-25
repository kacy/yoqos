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
        var t: *const toml.Table = d.doc.root;
        for (path) |p| {
            const v = t.get(p) orelse return null;
            if (v.data != .table) return null;
            t = v.data.table;
        }
        return t;
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

fn quoted(a: Allocator, s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    toml.writeString(&out.writer, s) catch return error.OutOfMemory;
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

    const t = d.table(path) orelse {
        var header: std.Io.Writer.Allocating = .init(a);
        const w = &header.writer;
        w.writeAll(if (text.len > 0) "\n[" else "[") catch return error.OutOfMemory;
        for (path, 0..) |p, i| {
            if (i > 0) w.writeByte('.') catch return error.OutOfMemory;
            toml.writeKey(w, p) catch return error.OutOfMemory;
        }
        w.print("]\n{s} = [{s}]\n", .{ key, q }) catch return error.OutOfMemory;
        return try splice(a, text, text.len, 0, header.written());
    };
    const v = t.get(key) orelse {
        const line = try std.fmt.allocPrint(a, "{s} = [{s}]\n", .{ key, q });
        return try splice(a, text, d.newKeyLine(t), 0, line);
    };
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

    // a list over several lines: a new line before the closing bracket,
    // indented like the last item, with a comma after the last item if it
    // had none.
    const indent = text[d.lineStart(last.span.start.offset)..last.span.start.offset];
    const new_line = try std.fmt.allocPrint(a, "{s}{s},\n", .{ indent, q });
    var out = try splice(a, text, d.lineStart(close), 0, new_line);
    if (!hasCommaAfter(text, last.span.end, close)) out = try splice(a, out, last.span.end, 0, ",");
    return out;
}

/// whether a comma follows `from`, skipping spaces and comments, before `limit`.
fn hasCommaAfter(text: []const u8, from: usize, limit: usize) bool {
    var i = from;
    while (i < limit) : (i += 1) {
        switch (text[i]) {
            ',' => return true,
            ' ', '\t', '\r', '\n' => {},
            '#' => i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse return false,
            else => return false,
        }
    }
    return false;
}

/// removes `item` from the string list `key` in the table at `path`.
/// returns null if it isn't there.
pub fn removeFromList(a: Allocator, text: []const u8, path: []const []const u8, key: []const u8, item: []const u8) Error!?[]u8 {
    var d = try Doc.init(a, text);
    defer d.deinit();
    const t = d.table(path) orelse return null;
    const v = t.get(key) orelse return null;
    if (v.data != .array) return null;
    const items = v.data.array.items.items;
    const i = for (items, 0..) |it, n| {
        if (it.data == .string and std.mem.eql(u8, it.data.string, item)) break n;
    } else return null;
    const it = items[i];
    const start = it.span.start.offset;
    var end: usize = it.span.end;

    // alone on its line: take the whole line, comma and comment included.
    const ls = d.lineStart(start);
    const le = d.lineEnd(start);
    var rest = end;
    while (rest < le and (text[rest] == ' ' or text[rest] == '\t')) rest += 1;
    if (rest < le and text[rest] == ',') rest += 1;
    while (rest < le and (text[rest] == ' ' or text[rest] == '\t')) rest += 1;
    const blank_before = std.mem.trim(u8, text[ls..start], " \t").len == 0;
    if (blank_before and (rest == le or text[rest] == '\n' or text[rest] == '#' or text[rest] == '\r')) {
        return try splice(a, text, ls, le - ls, "");
    }

    // on a shared line: take the item and the comma after it, or the comma
    // before it when it's last.
    var j = end;
    while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
    if (j < text.len and text[j] == ',') {
        end = j + 1;
        while (end < text.len and text[end] == ' ') end += 1;
        return try splice(a, text, start, end - start, "");
    }
    if (i > 0) {
        const prev_end = items[i - 1].span.end;
        return try splice(a, text, prev_end, end - prev_end, "");
    }
    return try splice(a, text, start, end - start, "");
}

/// sets `[services.<name>] enabled`, writing `name = true` style where the
/// service isn't set yet. returns null if it already has that value.
pub fn setService(a: Allocator, text_in: []const u8, name: []const u8, enabled: bool) Error!?[]u8 {
    const text = try ensureNewline(a, text_in);
    var d = try Doc.init(a, text);
    defer d.deinit();
    const value: []const u8 = if (enabled) "true" else "false";
    const key = try keyText(a, name);

    const services = d.table(&.{"services"});
    const e = if (services) |s| s.get(name) else null;
    if (e) |v| switch (v.data) {
        .boolean => |b| {
            if (b == enabled) return null;
            return try splice(a, text, v.span.start.offset, v.span.end - v.span.start.offset, value);
        },
        .table => |t| {
            if (t.get("enabled")) |en| {
                if (en.data == .boolean and en.data.boolean == enabled) return null;
                return try splice(a, text, en.span.start.offset, en.span.end - en.span.start.offset, value);
            }
            return switch (t.origin) {
                .inline_table => if (t.entries.items.len == 0)
                    try splice(a, text, v.span.start.offset, v.span.end - v.span.start.offset, try std.fmt.allocPrint(a, "{{ enabled = {s} }}", .{value}))
                else
                    try splice(a, text, lastEnd(t), 0, try std.fmt.allocPrint(a, ", enabled = {s}", .{value})),
                .dotted => try splice(a, text, d.lineEnd(v.span.end), 0, try std.fmt.allocPrint(a, "{s}.enabled = {s}\n", .{ key, value })),
                else => try splice(a, text, d.newKeyLine(t), 0, try std.fmt.allocPrint(a, "enabled = {s}\n", .{value})),
            };
        },
        else => return error.BadToml,
    };

    const line = try std.fmt.allocPrint(a, "{s} = {s}\n", .{ key, value });
    if (services) |s| {
        if (s.origin == .header) return try splice(a, text, d.newKeyLine(s), 0, line);
    }
    const section = try std.fmt.allocPrint(a, "{s}[services]\n{s}", .{ if (text.len > 0) "\n" else "", line });
    return try splice(a, text, text.len, 0, section);
}

fn lastEnd(t: *const toml.Table) usize {
    var end: usize = 0;
    for (t.entries.items) |e| end = @max(end, e.value.span.end);
    return end;
}

fn keyText(a: Allocator, key: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    toml.writeKey(&out.writer, key) catch return error.OutOfMemory;
    return out.toOwnedSlice();
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
    // only sub-tables so far: [services] is implicit, so add a new table
    try expectEdit(setService(a, "[services.custom]\nunit = \"c.service\"\n", "ssh", true), "[services.custom]\nunit = \"c.service\"\n\n[services]\nssh = true\n");
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
