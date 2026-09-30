//! fuzz tests for everything that reads text os didn't write itself, or
//! edits it. a plain `zig build test` runs each once over its seeds;
//! `zig build test -Dfuzz --fuzz` keeps going (see build.zig). besides not
//! crashing or leaking, each checks what should hold for any input it
//! accepts, like a lock written back reading the same.

const std = @import("std");
const toml = @import("toml.zig");
const compose = @import("compose.zig");
const config = @import("config.zig");
const diag = @import("diag.zig");
const lock = @import("lock.zig");
const facts = @import("facts.zig");
const news = @import("news.zig");
const edit = @import("edit.zig");
const show = @import("show.zig");
const planner = @import("planner.zig");

const testing = std.testing;
const Smith = testing.Smith;
const Allocator = std.mem.Allocator;

/// the largest input a target takes. the golden files fit.
const max_input = 8192;

/// mostly the printable ascii and whitespace text formats are made of,
/// with any byte now and then.
const text_bytes: []const Smith.Weight = &.{
    .rangeAtMost(u8, 0x00, 0xff, 1),
    .rangeAtMost(u8, 0x20, 0x7e, 20),
    .rangeAtMost(u8, '\t', '\n', 6),
    .value(u8, '\r', 1),
};

/// raw bytes, then pieces of the format until the fuzzer stops. random
/// bytes alone rarely get past a parser's first checks; the pieces reach
/// the code behind them.
fn input(s: *Smith, buf: *[max_input]u8, pieces: []const []const u8) []const u8 {
    return more(s, buf, raw(s, buf), pieces);
}

fn raw(s: *Smith, buf: *[max_input]u8) usize {
    return s.sliceWeightedBytes(buf, text_bytes);
}

fn more(s: *Smith, buf: *[max_input]u8, start: usize, pieces: []const []const u8) []const u8 {
    var len = start;
    while (!s.eosWeightedSimple(15, 1)) {
        const p = pieces[s.index(pieces.len)];
        if (len + p.len > buf.len) break;
        @memcpy(buf[len..][0..p.len], p);
        len += p.len;
    }
    return buf[0..len];
}

const toml_pieces = [_][]const u8{
    "[",           "]",     "[[",         "]]",    "{",     "}",    "=",      " = ",  ",",     ".",  "\n",
    " ",           "\t",    "# c\n",      "\r\n",  "\"s\"", "'l'",  "\"\"\"", "'''",  "a",     "b",  "\"a b\"",
    "1",           "-0x1f", "0o7",        "1_000", "1.5e3", "+inf", "nan",    "true", "false", "\\", "\\u00e9",
    "\\U0001F600", "\\n",   "1979-05-27", "\x00",  "\xff",
    "é",
};

const config_pieces = toml_pieces ++ [_][]const u8{
    "version = 1\n",                   "include = [\"x.toml\"]\n", "packages = [\"git\"]\n",       "aur = [\"yay\"]\n",
    "unset = [\"system.hostname\"]\n", "[system]\n",               "hostname = \"h\"\n",           "timezone = \"UTC\"\n",
    "[services]\n",                    "ssh = true\n",             "[services.c]\n",               "unit = \"c.service\"\n",
    "package = \"c\"\n",               "enabled = false\n",        "[users.k]\n",                  "shell = \"zsh\"\n",
    "groups = [\"wheel\"]\n",          "[files.\"/etc/x\"]\n",     "text = \"t\"\n",               "source = \"f\"\n",
    "mode = \"0644\"\n",               "[repos.r]\n",              "server = \"https://e.org\"\n", "key = \"0123456789ABCDEF0123456789ABCDEF01234567\"\n",
    "[sysctl]\n",                      "\"vm.x\" = 1\n",           "[desktop]\n",                  "session = \"hyprland\"\n",
    "login = \"tty\"\n",               "login = \"greetd\"\n",     "audio = \"pipewire\"\n",       "session_config = \"h.conf\"\n",
    "[hardware]\n",                    "gpu = \"nvidia\"\n",       "cpu = \"amd\"\n",              "[boot]\n",
    "kernel = \"none\"\n",             "modules = [\"m\"]\n",      "[remove]\n",                   "[providers]\n",
    "initramfs = \"booster\"\n",       "[state]\n",                "carry = [\"/etc/x\"]\n",
};

const lock_pieces = toml_pieces ++ [_][]const u8{
    "version = 1\n",       "sync_date = \"2026-09-25\"\n",       "keyring = \"1\"\n",                  "[providers]\n",     "sh = \"bash\"\n",
    "[packages.a]\n",      "[packages.b]\n",                     "version = \"1\"\n",                  "repo = \"core\"\n", "depends = [\"a\"]\n",
    "depends = [\"b\"]\n", "sha256 = \"" ++ "a" ** 64 ++ "\"\n", "recipe = \"" ++ "b" ** 40 ++ "\"\n",
};

const json_pieces = [_][]const u8{
    "{",            "}",                    "[",           "]",           ",",              ":",           "\"schema\":\"yoq.facts/1\"",
    "\"packages\"", "\"name\"",             "\"version\"", "\"reason\"",  "\"dependency\"", "\"units\"",   "\"users\"",
    "\"uid\"",      "\"groups\"",           "\"files\"",   "\"path\"",    "\"sha256\"",     "\"mode\"",    "\"boot\"",
    "\"pacman\"",   "\"keys\"",             "\"time\"",    "\"enabled\"", "1",              "-1",          "0.5",
    "1e400",        "18446744073709551616", "true",        "null",        "\"x\"",          "\"\\u0000\"", "\"\\ud800\"",
    " ",
    "\"é\"",
};

const news_pieces = [_][]const u8{
    "<item>", "</item>", "<title>", "</title>", "<link>", "</link>", "<pubDate>",      "</pubDate>", "Tue, ", "22 ",  "0 ",
    "300 ",   "Sep ",    "Dec ",    "2026 ",    "99999 ", "-1 ",     "09:00:00 +0000", "&amp;",      "&lt;",  "&gt;", "&quot;",
    "&#39;",  "&",       "x",
};

const edit_pieces = toml_pieces ++ [_][]const u8{
    "packages = [",        "\"git\"",  "\"a\"",      ", ",           "  ", "\n  ", "]\n", "[remove]\n", "remove = ", "remove.",
    "remove.packages = [", "packages", "aur = []\n", "[remove.x]\n", "{ ", " }",   ", ]",
};

/// the seeds a target starts from: the given texts, then every golden
/// file named `name`. each is encoded the way `Smith.slice` reads it back.
const Seeds = struct {
    arena: std.heap.ArenaAllocator = .init(testing.allocator),
    list: std.ArrayList([]const u8) = .empty,

    fn init(texts: []const []const u8, golden: ?[]const u8) !Seeds {
        var s: Seeds = .{};
        errdefer s.deinit();
        for (texts) |t| try s.add(t);
        const name = golden orelse return s;
        const io = testing.io;
        var dir = try std.Io.Dir.cwd().openDir(io, "tests/golden", .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .directory) continue;
            const path = try std.fmt.allocPrint(s.arena.allocator(), "{s}/{s}", .{ e.name, name });
            const bytes = dir.readFileAlloc(io, path, s.arena.allocator(), .limited(max_input)) catch continue;
            try s.add(bytes);
        }
        return s;
    }

    fn add(s: *Seeds, text: []const u8) !void {
        return s.addWith(text, &.{});
    }

    /// `text`, then `ints` for the target's later `Smith.index` calls.
    fn addWith(s: *Seeds, text: []const u8, ints: []const u64) !void {
        const a = s.arena.allocator();
        const out = try a.alloc(u8, 4 + text.len + 8 * ints.len);
        std.mem.writeInt(u32, out[0..4], @intCast(text.len), .little);
        @memcpy(out[4..][0..text.len], text);
        for (ints, 0..) |n, i| std.mem.writeInt(u64, out[4 + text.len + 8 * i ..][0..8], n, .little);
        try s.list.append(a, out);
    }

    fn deinit(s: *Seeds) void {
        s.arena.deinit();
    }
};

// -- toml --

test "fuzz toml parser" {
    var seeds: Seeds = try .init(&.{
        "a = 1\nb = \"x\"\n[t]\nc = [1, 2.5, true, 'lit']\n",
        "[[arr]]\nx = 1\n[[arr]]\nx = 2\n[arr.sub]\ny = { z = [ ] }\n",
        "\"q k\".'l'.m = \"\"\"\nmulti\\\n  line\"\"\"\ns = '''raw'''\ni = 0x1f\nj = -0o7\nk = +1_000\nf = 6.02e+23\ng = inf\nh = nan\n",
        "a = \"\\u00e9\\U0001F600\\t\"\n# comment\r\nb = 1979-05-27\n",
    }, "machine.toml");
    defer seeds.deinit();
    try testing.fuzz({}, fuzzToml, .{ .corpus = seeds.list.items });
}

fn fuzzToml(_: void, s: *Smith) !void {
    var buf: [max_input]u8 = undefined;
    const text = input(s, &buf, &toml_pieces);
    var info: toml.ErrorInfo = .{};
    var doc = toml.parse(testing.allocator, text, &info) catch |e| switch (e) {
        error.Syntax => {
            try testing.expect(info.pos.offset <= text.len);
            try testing.expect(info.message().len > 0);
            return;
        },
        else => return e,
    };
    defer doc.deinit();
    try checkTable(doc.root, text.len);
}

/// every span lies inside the source, and every table's keys are distinct.
fn checkTable(t: *const toml.Table, len: usize) anyerror!void {
    try testing.expect(t.pos.offset <= len);
    for (t.entries.items, 0..) |*e, i| {
        try checkSpan(e.key_span, len);
        for (t.entries.items[0..i]) |*other| try testing.expect(!std.mem.eql(u8, other.key, e.key));
        try checkValue(&e.value, len);
    }
}

fn checkValue(v: *const toml.Value, len: usize) !void {
    try checkSpan(v.span, len);
    switch (v.data) {
        .table => |t| try checkTable(t, len),
        .array => |arr| for (arr.items.items) |*it| try checkValue(it, len),
        else => {},
    }
}

fn checkSpan(sp: toml.Span, len: usize) !void {
    try testing.expect(sp.start.offset <= sp.end);
    try testing.expect(sp.end <= len);
    try testing.expect(sp.start.line >= 1 and sp.start.column >= 1);
}

// -- config --

test "fuzz config decode and validate" {
    var seeds: Seeds = try .init(&.{
        "version = 1\npackages = [\"git\"]\n[services]\nssh = true\n[services.custom]\nunit = \"c.service\"\npackage = \"c\"\n",
        "[users.kacy]\nshell = \"zsh\"\ngroups = [\"wheel\"]\n[hardware]\ncpu = \"amd\"\ngpu = \"nvidia\"\n",
        "[files.\"/etc/motd\"]\ntext = \"hi\\n\"\nmode = \"0600\"\n[sysctl]\n\"vm.swappiness\" = 10\n[boot]\nmodules = [\"i2c-dev\"]\n",
        "[repos.mine]\nserver = \"https://example.org/$repo/$arch\"\nkey = \"0123456789ABCDEF0123456789ABCDEF01234567\"\naur = [\"yay\"]\n",
        "[desktop]\nsession = \"hyprland\"\nlogin = \"tty\"\naudio = \"pipewire\"\n[remove]\npackages = [\"nano\"]\nunset = [\"system.hostname\"]\n",
    }, "machine.toml");
    defer seeds.deinit();
    try testing.fuzz({}, fuzzConfig, .{ .corpus = seeds.list.items });
}

const config_path = "/etc/yoq/machine.toml";

fn fuzzConfig(_: void, s: *Smith) !void {
    var buf: [max_input]u8 = undefined;
    const text = input(s, &buf, &config_pieces);
    var fs: compose.MemFiles = .{};
    defer fs.deinit();
    try fs.put(config_path, text);
    var diags: diag.List = .init(testing.allocator);
    defer diags.deinit();
    var loaded = try compose.load(testing.allocator, fs.files(), config_path, &diags);
    defer loaded.deinit();

    var sink: std.Io.Writer.Discarding = .init(&.{});
    try diags.render(&sink.writer);
    if (diags.items.items.len > 0) return;

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = &loaded.config;

    // `config show --resolved` prints toml that reads back as the same config.
    var shown: std.Io.Writer.Allocating = .init(a);
    try show.writeToml(&shown.writer, c, false);
    try fs.put("/etc/yoq/shown.toml", shown.written());
    var again = try compose.load(testing.allocator, fs.files(), "/etc/yoq/shown.toml", &diags);
    defer again.deinit();
    if (diags.items.items.len > 0) {
        std.debug.print("config show printed a config that doesn't load:\n{s}\n", .{shown.written()});
        return error.TestUnexpectedResult;
    }
    var reshown: std.Io.Writer.Allocating = .init(a);
    try show.writeToml(&reshown.writer, &again.config, false);
    try testing.expectEqualStrings(shown.written(), reshown.written());

    // the planner takes any valid config. an empty lock stops it early, so
    // one holding every wanted package goes through the whole plan.
    const ws = try planner.wants(a, c);
    const pkgs = try a.alloc(lock.Package, ws.len);
    for (ws, pkgs) |w, *p| p.* = .{ .name = w.name, .version = "1", .repo = "core", .sha256 = "a" ** 64 };
    var l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = pkgs };
    try lock.normalize(a, &l);
    _ = try planner.wanted(a, c);
    var f: facts.Facts = .{};
    const p = try planner.plan(a, c, &l, &f, &diags) orelse return;
    try planner.writeText(&sink.writer, a, &p, .{ .verbose = true });
    try planner.writeJson(&sink.writer, a, &p);
}

// -- lock --

test "fuzz lock reader" {
    var seeds: Seeds = try .init(&.{
        "version = 1\nsync_date = \"2026-09-25\"\nkeyring = \"1\"\n[providers]\nsh = \"bash\"\n[packages.a]\nversion = \"1\"\nrepo = \"core\"\nsha256 = \"" ++ "a" ** 64 ++ "\"\nrecipe = \"" ++ "b" ** 40 ++ "\"\n",
    }, "machine.lock");
    defer seeds.deinit();
    try testing.fuzz({}, fuzzLock, .{ .corpus = seeds.list.items });
}

fn fuzzLock(_: void, s: *Smith) !void {
    var buf: [max_input]u8 = undefined;
    const text = input(s, &buf, &lock_pieces);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags: diag.List = .init(testing.allocator);
    defer diags.deinit();
    const l = try lock.parse(a, "machine.lock", text, &diags) orelse {
        try testing.expect(diags.items.items.len > 0);
        return;
    };
    try testing.expectEqual(0, diags.items.items.len);
    for (l.packages) |*p| try testing.expectEqual(p, l.package(p.name).?);

    // what os writes, it reads back as the same lock.
    var first: std.Io.Writer.Allocating = .init(a);
    try lock.write(&first.writer, &l);
    const back = try lock.parse(a, "machine.lock", first.written(), &diags) orelse {
        std.debug.print("a lock os wrote doesn't read back:\n{s}\n", .{first.written()});
        return error.TestUnexpectedResult;
    };
    var second: std.Io.Writer.Allocating = .init(a);
    try lock.write(&second.writer, &back);
    try testing.expectEqualStrings(first.written(), second.written());
}

// -- facts --

test "fuzz facts parser" {
    var seeds: Seeds = try .init(&.{
        "{\"schema\":\"yoq.facts/1\",\"time\":1,\"hostname\":\"h\",\"packages\":[{\"name\":\"a\",\"version\":\"1\",\"reason\":\"dependency\"}],\"units\":[{\"name\":\"u.service\",\"enabled\":true}],\"users\":[{\"name\":\"k\",\"uid\":1000,\"groups\":[\"wheel\"]}],\"files\":[{\"path\":\"/etc/x\",\"sha256\":\"00\",\"mode\":\"0644\"}],\"boot\":{\"uefi\":true},\"pacman\":{\"keys\":[\"K\"]}}",
    }, "facts.json");
    defer seeds.deinit();
    try testing.fuzz({}, fuzzFacts, .{ .corpus = seeds.list.items });
}

fn fuzzFacts(_: void, s: *Smith) !void {
    var buf: [max_input]u8 = undefined;
    const text = input(s, &buf, &json_pieces);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = facts.parse(a, text) catch |e| switch (e) {
        error.BadFacts => return,
        else => return e,
    };
    var first: std.Io.Writer.Allocating = .init(a);
    try facts.write(&first.writer, &f);
    const back = try facts.parse(a, first.written());
    var second: std.Io.Writer.Allocating = .init(a);
    try facts.write(&second.writer, &back);
    try testing.expectEqualStrings(first.written(), second.written());
}

// -- news --

test "fuzz news feed parser" {
    var seeds: Seeds = try .init(&.{
        "<rss><channel><item><title>A &amp; B &lt;3</title><link>https://archlinux.org/news/a/</link><pubDate>Tue, 22 Sep 2026 09:09:27 +0000</pubDate></item>" ++
            "<item><title>Old</title><link>l</link><pubDate>Mon, 1 Sep 2026 10:00:00 +0000</pubDate></item></channel></rss>",
        "<item><title>no date</title><link>x</link></item><item><pubDate>Fri, 31 Dec 1999 00:00:00 +0000</pubDate><title>t</title><link>l</link></item>",
        "<item><title>t</title><link>l</link><pubDate>Tue, 99 Sep 20266 00:00:00 +0000</pubDate></item>",
    }, null);
    defer seeds.deinit();
    try testing.fuzz({}, fuzzNews, .{ .corpus = seeds.list.items });
}

fn fuzzNews(_: void, s: *Smith) !void {
    var buf: [max_input]u8 = undefined;
    const text = input(s, &buf, &news_pieces);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = try news.parse(a, text);
    for (items) |it| {
        if (!lock.validDate(it.date)) {
            std.debug.print("news date \"{s}\" isn't yyyy-mm-dd\n", .{it.date});
            return error.TestUnexpectedResult;
        }
    }
    const some = try news.between(a, items, "2026-01-01", "2026-12-31");
    try testing.expect(some.len <= items.len);
}

// -- in-place edits --

test "fuzz package edits" {
    var seeds: Seeds = try .init(&.{
        "",
        "version = 1\npackages = [\"git\", \"vim\"]  # tools\n",
        "packages = [\n  \"git\",  # vcs\n  \"vim\"\n]\n[remove]\npackages = [\"nano\"]\n",
        "packages = [\"a\",\n  \"b\"]\nremove = { aur = [] }\n",
        "remove.aur = []\n[system]\nhostname = \"atlas\"\n",
        "[remove.x]\ny = 1\n",
    }, "machine.toml");
    defer seeds.deinit();
    try seeds.addWith("remove = 5\n", &.{ 1, 0 });
    try seeds.addWith("packages = [\"a\" # x\n , \"b\"]\n", &.{ 0, 3 });
    try testing.fuzz({}, fuzzEdits, .{ .corpus = seeds.list.items });
}

/// names to add and remove: ones the seeds hold, and ones that need quoting.
const edit_names = [_][]const u8{ "git", "vim", "nano", "a", "b", "ripgrep", "with \"quote\"", "tab\there", "é", "" };
const edit_paths = [_][]const []const u8{ &.{}, &.{"remove"} };

fn fuzzEdits(_: void, s: *Smith) !void {
    var buf: [max_input]u8 = undefined;
    const start = raw(s, &buf);
    const path = edit_paths[s.index(edit_paths.len)];
    const name = edit_names[s.index(edit_names.len)];
    const text = more(s, &buf, start, &edit_pieces);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var info: toml.ErrorInfo = .{};
    var before = toml.parse(a, text, &info) catch return;
    defer before.deinit();

    const added = edit.addToList(a, text, path, "packages", name) catch |e| switch (e) {
        // the key holds something other than a list; nothing to edit.
        error.BadToml => return,
        else => return e,
    };
    if (added) |t| {
        try expectEdited(a, text, t, path, name, .add);
        if (try edit.removeFromList(a, t, path, "packages", name)) |t2| {
            try expectEdited(a, t, t2, path, name, .remove);
        } else return error.TestUnexpectedResult;
    } else {
        try testing.expect(listHolds(before.root, path, name));
    }

    if (try edit.removeFromList(a, text, path, "packages", name)) |t| {
        try expectEdited(a, text, t, path, name, .remove);
    } else {
        try testing.expect(!listHolds(before.root, path, name));
    }
}

const EditOp = enum { add, remove };

/// `after` parses, and differs from `before` only in the list at `path`:
/// `name` added at its end, or every copy of it gone.
fn expectEdited(a: Allocator, before_text: []const u8, after_text: []const u8, path: []const []const u8, name: []const u8, op: EditOp) !void {
    var info: toml.ErrorInfo = .{};
    var before = try toml.parse(a, before_text, &info);
    defer before.deinit();
    var after = toml.parse(a, after_text, &info) catch |e| {
        std.debug.print("{t} \"{s}\" made invalid toml ({s}):\n--- before\n{s}\n--- after\n{s}\n", .{ op, name, info.message(), before_text, after_text });
        return e;
    };
    defer after.deinit();
    errdefer std.debug.print("{t} \"{s}\" changed more than it should:\n--- before\n{s}\n--- after\n{s}\n", .{ op, name, before_text, after_text });

    const old = listAt(before.root, path);
    const new = listAt(after.root, path) orelse return error.TestUnexpectedResult;
    var want: std.ArrayList(toml.Value) = .empty;
    for (if (old) |o| o else &.{}) |v| {
        if (op == .remove and isString(v, name)) continue;
        try want.append(a, v);
    }
    if (op == .add) try want.append(a, .{ .span = undefined, .data = .{ .string = name } });
    try testing.expectEqual(want.items.len, new.len);
    for (want.items, new) |w, n| try testing.expect(sameValue(w, n));

    try testing.expect(sameTableExcept(before.root, after.root, path));
}

fn listAt(root: *const toml.Table, path: []const []const u8) ?[]const toml.Value {
    var t = root;
    for (path) |p| {
        const v = t.get(p) orelse return null;
        if (v.data != .table) return null;
        t = v.data.table;
    }
    const v = t.get("packages") orelse return null;
    if (v.data != .array) return null;
    return v.data.array.items.items;
}

fn listHolds(root: *const toml.Table, path: []const []const u8, name: []const u8) bool {
    for (listAt(root, path) orelse return false) |v| {
        if (isString(v, name)) return true;
    }
    return false;
}

fn isString(v: toml.Value, s: []const u8) bool {
    return v.data == .string and std.mem.eql(u8, v.data.string, s);
}

/// the same keys and values in the same order, but `packages` under `path`
/// may differ, and the tables on `path` may be created. spans and how a
/// table was written don't count.
fn sameTableExcept(x: *const toml.Table, y: *const toml.Table, path: []const []const u8) bool {
    const skip: ?[]const u8 = if (path.len == 0) "packages" else path[0];
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < x.entries.items.len and eqlOpt(skip, x.entries.items[i].key)) i += 1;
        while (j < y.entries.items.len and eqlOpt(skip, y.entries.items[j].key)) j += 1;
        if (i == x.entries.items.len or j == y.entries.items.len) break;
        const ex = x.entries.items[i];
        const ey = y.entries.items[j];
        if (!std.mem.eql(u8, ex.key, ey.key) or !sameValue(ex.value, ey.value)) return false;
        i += 1;
        j += 1;
    }
    if (i != x.entries.items.len or j != y.entries.items.len) return false;
    if (path.len == 0) return true;
    const vy = y.get(path[0]) orelse return false;
    if (vy.data != .table) return false;
    const vx = x.get(path[0]) orelse return sameTableExcept(&.{ .origin = .root, .pos = .{ .offset = 0, .line = 1, .column = 1 } }, vy.data.table, path[1..]);
    if (vx.data != .table) return false;
    return sameTableExcept(vx.data.table, vy.data.table, path[1..]);
}

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return if (a) |s| std.mem.eql(u8, s, b) else false;
}

fn sameValue(x: toml.Value, y: toml.Value) bool {
    if (std.meta.activeTag(x.data) != std.meta.activeTag(y.data)) return false;
    return switch (x.data) {
        .string => |s| std.mem.eql(u8, s, y.data.string),
        .integer => |n| n == y.data.integer,
        .float => |f| (std.math.isNan(f) and std.math.isNan(y.data.float)) or f == y.data.float,
        .boolean => |b| b == y.data.boolean,
        .array => |arr| arr.items.items.len == y.data.array.items.items.len and for (arr.items.items, y.data.array.items.items) |p, q| {
            if (!sameValue(p, q)) break false;
        } else true,
        .table => |t| sameTableExcept(t, y.data.table, &.{}) and eqlPackages(t, y.data.table),
    };
}

/// `sameTableExcept` with an empty path skips `packages`, so nested tables
/// compare it here.
fn eqlPackages(x: *const toml.Table, y: *const toml.Table) bool {
    const px = x.get("packages");
    const py = y.get("packages");
    if (px == null or py == null) return px == null and py == null;
    return sameValue(px.?.*, py.?.*);
}
