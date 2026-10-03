//! `yos secret set`, `list`, and `rm`: the values `[files]` entries name
//! with `secret`. nothing here prints, logs, or records a value.

const std = @import("std");
const cli = @import("../cli.zig");
const output = @import("../output.zig");
const lists = @import("../lists.zig");
const secrets = @import("../secrets.zig");
const Context = cli.Context;
const eql = cli.eql;
const Allocator = std.mem.Allocator;

const usage_text = "yos secret set <name> | yos secret list | yos secret rm <name>";

pub fn secretCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    var buf: [2][]const u8 = undefined;
    var it: cli.ArgIter = .{ .args = args };
    const words = it.names(&buf) orelse return cli.usageError(ctx, usage_text);
    if (words.len == 0) return cli.usageError(ctx, usage_text);
    const verb = words[0];
    const takes_name = eql(verb, "set") or eql(verb, "rm");
    if (!(takes_name and words.len == 2) and !(eql(verb, "list") and words.len == 1)) return cli.usageError(ctx, usage_text);

    const store = ctx.secrets orelse return cli.fail(ctx, "there's nowhere to keep secrets here.", .{});
    if (store.problem()) |why| return cli.fail(ctx, "{s}.", .{why});
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    if (!takes_name) return list(ctx, &w, store);
    const name = words[1];
    if (secrets.nameProblem(name)) |hint| return cli.fail(ctx, "\"{s}\" isn't a secret's name: {s}.", .{ name, hint });
    // the store is the machine's whatever --root says, so the machine's
    // lock is taken whatever it says too.
    if (std.os.linux.geteuid() == 0 and try cli.refused(ctx, cli.lockMachine())) return 1;
    return if (eql(verb, "set")) set(ctx, &w, store, name) else remove(ctx, &w, store, name);
}

fn set(ctx: *Context, w: *cli.Work, store: secrets.Store, name: []const u8) !u8 {
    const a = w.allocator();
    secrets.keepPrivate();
    const buf = try a.alloc(u8, secrets.max_len + 1);
    defer secrets.wipe(buf);
    const value = try readValue(ctx, name, buf) orelse return 1;
    if (value.len == 0) return cli.fail(ctx, "the value is empty, so nothing was kept.", .{});
    if (value.len > secrets.max_len) return cli.fail(ctx, "the value is longer than {d} bytes, so nothing was kept.", .{secrets.max_len});
    if (try store.set(a, name, value)) |why| return cli.fail(ctx, "can't keep the secret {s}: {s}", .{ name, why });
    const files = try filesUsing(w, name);
    if (ctx.json) return writeEntry(ctx, .{ .name = name, .set = true, .files = files });
    if (files.len == 0) {
        try ctx.out.print("kept {s}. the config doesn't use it yet; `[files.\"<path>\"] secret = \"{s}\"` writes it to a file.\n", .{ name, name });
    } else try ctx.out.print("kept {s}. `yos apply` writes it to {s}.\n", .{ name, try joined(a, files) });
    return 0;
}

fn writeEntry(ctx: *Context, entry: secrets.Entry) !u8 {
    try output.writeDoc(ctx.out, secrets.entry_schema, entry);
    return 0;
}

fn joined(a: Allocator, paths: []const []const u8) ![]const u8 {
    return std.mem.join(a, ", ", paths);
}

/// the value, into `buf`: typed twice when stdin is a terminal, without
/// echo, even with --json or stdout elsewhere, or else everything on
/// stdin, byte for byte. null after saying why there's none.
fn readValue(ctx: *Context, name: []const u8, buf: []u8) !?[]u8 {
    const in = ctx.in orelse {
        try ctx.err.writeAll("yos: there's no input to read the value from.\n");
        return null;
    };
    if (!ctx.in_tty) {
        const n = in.readSliceShort(buf) catch {
            try ctx.err.writeAll("yos: can't read the value from stdin.\n");
            return null;
        };
        return buf[0..n];
    }
    const half = buf.len / 2;
    // the questions go to stderr, so --json output stays one document.
    try ctx.err.print("value for {s}: ", .{name});
    const first = try prompt(ctx, buf[0..half]) orelse return null;
    try ctx.err.writeAll("again: ");
    const again = try prompt(ctx, buf[half..]) orelse return null;
    if (!std.mem.eql(u8, first, again)) {
        try ctx.err.writeAll("yos: the two didn't match, so nothing was kept.\n");
        return null;
    }
    secrets.wipe(again);
    return first;
}

/// reads the answer to the question just printed, with echo off, and
/// copies it into `into`. null at the end of input.
fn prompt(ctx: *Context, into: []u8) !?[]u8 {
    try ctx.err.flush();
    if (ctx.set_echo) |echo| echo(false);
    const line = ctx.in.?.takeDelimiter('\n');
    if (ctx.set_echo) |echo| {
        echo(true);
        // the newline typed wasn't echoed.
        try ctx.err.writeByte('\n');
    }
    const typed = line catch |e| {
        try ctx.err.writeAll(switch (e) {
            error.StreamTooLong => "yos: the value is longer than a typed line can be, so nothing was kept. pipe it in on stdin instead.\n",
            error.ReadFailed => "yos: can't read the value, so nothing was kept.\n",
        });
        return null;
    };
    const got = std.mem.trimEnd(u8, typed orelse {
        try ctx.err.writeAll("yos: no value was typed, so nothing was kept.\n");
        return null;
    }, "\r");
    if (got.len > into.len) {
        try ctx.err.writeAll("yos: the value is too long, so nothing was kept.\n");
        return null;
    }
    @memcpy(into[0..got.len], got);
    return into[0..got.len];
}

fn remove(ctx: *Context, w: *cli.Work, store: secrets.Store, name: []const u8) !u8 {
    const a = w.allocator();
    if (try store.remove(a, name)) |why| return cli.fail(ctx, "{s}.", .{why});
    const files = try filesUsing(w, name);
    if (ctx.json) return writeEntry(ctx, .{ .name = name, .set = false, .files = files });
    if (files.len == 0) {
        try ctx.out.print("removed {s}.\n", .{name});
    } else try ctx.out.print("removed {s}. the config still writes it to {s}, so plans fail until it's set again or those entries go. the files stay as they are.\n", .{ name, try joined(a, files) });
    return 0;
}

fn list(ctx: *Context, w: *cli.Work, store: secrets.Store) !u8 {
    const a = w.allocator();
    var entries: std.ArrayList(secrets.Entry) = .empty;
    for (try store.names(a)) |n| try entries.append(a, .{ .name = n, .set = true });
    for (try configUses(w)) |u| {
        // a name the config uses but this machine doesn't keep is missing.
        if (lists.indexOf(entries.items, "name", u.name) == null) try entries.append(a, .{ .name = u.name, .set = false });
        const e = &entries.items[lists.indexOf(entries.items, "name", u.name).?];
        e.files = try std.mem.concat(a, []const u8, &.{ e.files, &.{u.path} });
    }
    lists.sortByField(secrets.Entry, "name", entries.items);
    if (ctx.json) {
        try output.writeDoc(ctx.out, secrets.list_schema, secrets.List{ .secrets = entries.items });
        return 0;
    }
    if (entries.items.len == 0) try ctx.out.writeAll("no secrets. `yos secret set <name>` keeps one.\n");
    for (entries.items) |e| {
        try ctx.out.print("{s: <24} ", .{e.name});
        if (!e.set) {
            try ctx.out.print("missing: `yos secret set {s}`, for {s}\n", .{ e.name, try joined(a, e.files) });
        } else if (e.files.len == 0) {
            try ctx.out.writeAll("not in the config\n");
        } else try ctx.out.print("{s}\n", .{try joined(a, e.files)});
    }
    return 0;
}

const Use = struct { name: []const u8, path: []const u8 };

/// the `secret` keys in the config, if it loads. a config with problems
/// has none to show, and its problems are for the commands that use it.
fn configUses(w: *cli.Work) ![]const Use {
    var out: std.ArrayList(Use) = .empty;
    const loaded = try w.config() orelse {
        w.diags.items.clearRetainingCapacity();
        return out.items;
    };
    for (loaded.config.files.entries.items) |e| {
        if (e.value.secret) |s| try out.append(w.allocator(), .{ .name = s.v, .path = e.name });
    }
    return out.items;
}

fn filesUsing(w: *cli.Work, name: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try configUses(w)) |u| {
        if (eql(u.name, name)) try out.append(w.allocator(), u.path);
    }
    return out.items;
}

// -- tests --

const testing = std.testing;

const config_text =
    \\[files."/etc/wifi.psk"]
    \\secret = "wifi/home"
    \\
;

fn run(t: *cli.TestRun, mem: *secrets.Memory, args: []const [:0]const u8) !void {
    t.secrets = mem;
    try t.exec(args);
}

test "set reads stdin byte for byte, and nothing prints the value" {
    var mem: secrets.Memory = .init(testing.allocator);
    defer mem.deinit();
    var t: cli.TestRun = .{ .piped = "hunter2\n" };
    defer t.deinit();
    try t.fs.put("/etc/yos/machine.toml", config_text);
    try run(&t, &mem, &.{ "--config", "/etc/yos/machine.toml", "secret", "set", "wifi/home" });
    try testing.expectEqual(0, t.code);
    try testing.expectEqualStrings("hunter2\n", mem.values.get("wifi/home").?);
    try testing.expectEqualStrings("kept wifi/home. `yos apply` writes it to /etc/wifi.psk.\n", t.out.buffered());

    t.piped = "x";
    try run(&t, &mem, &.{ "--config", "/etc/yos/machine.toml", "secret", "set", "other" });
    try run(&t, &mem, &.{ "--config", "/etc/yos/machine.toml", "secret", "list" });
    try testing.expectEqualStrings("other                    not in the config\nwifi/home                /etc/wifi.psk\n", t.out.buffered());
    try run(&t, &mem, &.{ "--config", "/etc/yos/machine.toml", "--json", "secret", "list" });
    try testing.expect(std.mem.indexOf(u8, t.out.buffered(), "hunter2") == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, t.out.buffered(), .{});
    defer parsed.deinit();
    const list_json = parsed.value.object.get("secrets").?.array.items;
    try testing.expectEqual(2, list_json.len);
    try testing.expectEqualStrings("wifi/home", list_json[1].object.get("name").?.string);
    try testing.expectEqualStrings("/etc/wifi.psk", list_json[1].object.get("files").?.array.items[0].string);
}

test "set at a terminal asks twice" {
    var mem: secrets.Memory = .init(testing.allocator);
    defer mem.deinit();
    var t: cli.TestRun = .{ .input = "hunter2\nhunter2\n" };
    defer t.deinit();
    try run(&t, &mem, &.{ "secret", "set", "wifi/home" });
    try testing.expectEqual(0, t.code);
    try testing.expectEqualStrings("hunter2", mem.values.get("wifi/home").?);
    try testing.expect(std.mem.indexOf(u8, t.out.buffered(), "hunter2") == null);

    // with --json, the questions stay off stdout, and the value is still
    // typed without echo.
    t.input = "hunter4\nhunter4\n";
    try run(&t, &mem, &.{ "--json", "secret", "set", "wifi/home" });
    try testing.expectEqual(0, t.code);
    try testing.expectEqualStrings("hunter4", mem.values.get("wifi/home").?);
    const doc = try std.json.parseFromSlice(std.json.Value, testing.allocator, t.out.buffered(), .{});
    doc.deinit();
    try testing.expectEqualStrings("value for wifi/home: again: ", t.err.buffered());

    t.input = "hunter2\nhunter3\n";
    try run(&t, &mem, &.{ "secret", "set", "wifi/home" });
    try testing.expectEqual(1, t.code);
    try testing.expectEqualStrings("value for wifi/home: again: yos: the two didn't match, so nothing was kept.\n", t.err.buffered());
    try testing.expectEqualStrings("hunter4", mem.values.get("wifi/home").?);
}

test "a typed line longer than stdin's buffer says so" {
    var mem: secrets.Memory = .init(testing.allocator);
    defer mem.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "typed", .data = "a" ** 40 ++ "\n" });
    const file = try tmp.dir.openFile(testing.io, "typed", .{});
    defer file.close(testing.io);
    var small: [16]u8 = undefined;
    var in = file.reader(testing.io, &small);
    var t: cli.TestRun = .{ .in = &in.interface };
    defer t.deinit();
    try run(&t, &mem, &.{ "secret", "set", "wifi/home" });
    try testing.expectEqual(1, t.code);
    try testing.expect(std.mem.endsWith(u8, t.err.buffered(), "yos: the value is longer than a typed line can be, so nothing was kept. pipe it in on stdin instead.\n"));
    try testing.expectEqual(null, mem.values.get("wifi/home"));
}

test "plan, status, why, and list never show a secret's value" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    try tmp.dir.createDirPath(testing.io, "etc");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "etc/wifi.psk", .data = "old horse battery" });
    // an empty package database, for builds that read one.
    try tmp.dir.createDirPath(testing.io, "var/lib/pacman/local");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "var/lib/pacman/local/ALPM_DB_VERSION", .data = "9\n" });
    var mem: secrets.Memory = .init(testing.allocator);
    defer mem.deinit();
    const value = "correct horse battery";
    _ = try mem.store().set(a, "wifi/home", value);
    var t: cli.TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yos/machine.toml", "[boot]\nkernel = \"none\"\n" ++ config_text);
    try t.fs.put("/etc/yos/machine.lock", "version = 1\nsync_date = \"2026-09-25\"\nkeyring = \"1\"\n");

    const runs = [_][]const [:0]const u8{
        &.{ "plan", "--json" },       &.{ "plan", "-v" },                     &.{ "status", "--json" },         &.{"status"},
        &.{ "why", "/etc/wifi.psk" }, &.{ "why", "--json", "/etc/wifi.psk" }, &.{ "secret", "list", "--json" },
    };
    var planned = false;
    for (runs) |args| {
        try run(&t, &mem, try std.mem.concat(a, [:0]const u8, &.{ &.{ "--root", root }, args }));
        const shown = try std.mem.concat(a, u8, &.{ t.out.buffered(), t.err.buffered() });
        for ([_][]const u8{ "horse", &@import("../facts.zig").sha256Hex(value) }) |leak| {
            if (std.mem.indexOf(u8, shown, leak) != null) {
                std.debug.print("yos {s} showed {s}:\n{s}\n", .{ args[0], leak, shown });
                return error.TestUnexpectedResult;
            }
        }
        if (std.mem.indexOf(u8, shown, "rewrite, mode 0600") != null) planned = true;
    }
    try testing.expect(planned);
}

test "list, rm, and what they refuse" {
    var mem: secrets.Memory = .init(testing.allocator);
    defer mem.deinit();
    var t: cli.TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yos/machine.toml", config_text);
    try run(&t, &mem, &.{ "--config", "/etc/yos/machine.toml", "secret", "list" });
    try testing.expectEqualStrings("wifi/home                missing: `yos secret set wifi/home`, for /etc/wifi.psk\n", t.out.buffered());

    _ = try mem.store().set(testing.allocator, "wifi/home", "hunter2");
    try run(&t, &mem, &.{ "--config", "/etc/yos/machine.toml", "secret", "list" });
    try testing.expectEqualStrings("wifi/home                /etc/wifi.psk\n", t.out.buffered());
    try run(&t, &mem, &.{ "--config", "/etc/yos/machine.toml", "secret", "rm", "wifi/home" });
    try testing.expectEqual(0, t.code);
    try testing.expect(std.mem.startsWith(u8, t.out.buffered(), "removed wifi/home. the config still writes it to /etc/wifi.psk"));
    try run(&t, &mem, &.{ "secret", "rm", "wifi/home" });
    try testing.expectEqual(1, t.code);
    try testing.expectEqualStrings("yos: there's no secret called wifi/home. `yos secret list` lists them.\n", t.err.buffered());

    try run(&t, &mem, &.{ "secret", "set", "../key" });
    try testing.expectEqual(1, t.code);
    try run(&t, &mem, &.{ "secret", "get", "wifi/home" });
    try testing.expectEqual(2, t.code);
    mem.refuse = "secrets are root's, so this needs root";
    try run(&t, &mem, &.{ "secret", "list" });
    try testing.expectEqualStrings("yos: secrets are root's, so this needs root.\n", t.err.buffered());
}
