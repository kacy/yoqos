//! commands that read and report: `config show`, `facts`, `plan`, and `why`.
//! none of them change anything.

const std = @import("std");
const cli = @import("../cli.zig");
const facts = @import("../facts.zig");
const pipeline = @import("../pipeline.zig");
const planner = @import("../planner.zig");
const show = @import("../show.zig");
const why = @import("../why.zig");
const status = @import("../status.zig");
const Context = cli.Context;
const eql = cli.eql;

pub fn configCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    const usage_text = "os config show [--resolved]";
    var it: cli.ArgIter = .{ .args = args };
    if (!eql(it.next() orelse "", "show")) return cli.usageError(ctx, usage_text);
    var sources = false;
    while (it.next()) |a| {
        if (!eql(a, "--resolved")) return cli.usageError(ctx, usage_text);
        sources = true;
    }

    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const loaded = try w.config() orelse return w.report();

    if (ctx.json) {
        var s: std.json.Stringify = .{ .writer = ctx.out, .options = .{ .whitespace = .indent_2 } };
        try s.beginObject();
        try s.objectField("schema");
        try s.write("yoq.config/1");
        try s.objectField("files");
        try s.write(loaded.files.items);
        try s.objectField("config");
        try show.writeJson(&s, &loaded.config);
        try s.endObject();
        try ctx.out.writeByte('\n');
        return 0;
    }
    try show.writeToml(ctx.out, &loaded.config, sources);
    return 0;
}

pub fn factsCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (try cli.noArgs(ctx, args, "os facts")) |code| return code;
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const f = try cli.facts(&w) orelse return 1;
    if (w.failed()) return w.report();

    if (ctx.json) {
        try facts.write(ctx.out, &f);
        return 0;
    }
    try ctx.out.print("hostname  {s}\ntimezone  {s}\nlocale    {s}\npackages  {d}\nunits     {d}\nusers     {d}\n", .{
        f.hostname orelse "-",
        f.timezone orelse "-",
        f.locale orelse "-",
        f.packages.len,
        f.units.len,
        f.users.len,
    });
    return 0;
}

pub fn planCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    const usage_text = "os plan [--lock <file>] [-v]";
    var in = cli.inputs(ctx);
    var verbose = false;
    var it: cli.ArgIter = .{ .args = args };
    while (it.next()) |a| {
        if (eql(a, "-v") or eql(a, "--verbose")) {
            verbose = true;
        } else if (eql(a, "--lock")) {
            in.lock_path = it.next() orelse return cli.usageError(ctx, usage_text);
        } else return cli.usageError(ctx, usage_text);
    }

    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const built = pipeline.buildPlan(ctx.gpa, ctx.io, ctx.files, in, &w.diags) catch |e| return cli.factsError(ctx, e, in.facts_path);
    var result = built orelse return w.report();
    defer result.deinit();

    if (ctx.json) {
        try planner.writeJson(ctx.out, result.allocator(), &result.plan);
    } else {
        try planner.writeText(ctx.out, result.allocator(), &result.plan, .{ .verbose = verbose });
    }
    return 0;
}

pub fn statusCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (try cli.noArgs(ctx, args, "os status")) |code| return code;
    const in = cli.inputs(ctx);
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const built = pipeline.buildPlan(ctx.gpa, ctx.io, ctx.files, in, &w.diags) catch |e| return cli.factsError(ctx, e, in.facts_path);
    var result = built orelse return w.report();
    defer result.deinit();

    const s = try status.summarize(result.allocator(), result.state.config(), &result.state.lock, &result.facts, &result.plan);
    if (ctx.json) try status.writeJson(ctx.out, &s) else try status.writeText(ctx.out, &s);
    return if (s.failing.len > 0) 1 else 0;
}

pub fn whyCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (args.len != 1 or args[0][0] == '-') return cli.usageError(ctx, "os why <package>");
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const state = try w.state() orelse return w.report();

    const ans = try why.explain(w.allocator(), state.config(), &state.lock, args[0]);
    if (ctx.json) try why.writeJson(ctx.out, &ans) else try why.writeText(ctx.out, &ans);
    return if (ans.root == null) 1 else 0;
}

// -- tests --

const TestRun = cli.TestRun;

test "config show prints the merged config" {
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/base.toml", "packages = [\"git\"]\n");
    try t.fs.put("/etc/yoq/machine.toml", "include = [\"base.toml\"]\npackages = [\"neovim\"]\n");
    try t.exec(&.{ "config", "show" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqualStrings("packages = [\n  \"git\",\n  \"neovim\",\n]\n", t.out.buffered());

    try t.exec(&.{ "config", "show", "--resolved" });
    try std.testing.expect(std.mem.indexOf(u8, t.out.buffered(), "\"git\",  # /etc/yoq/base.toml:1") != null);
}

test "config show takes --config and reports problems" {
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/tmp/m.toml", "[services]\nsshd = true\n");
    try t.exec(&.{ "--config", "/tmp/m.toml", "config", "show" });
    try std.testing.expectEqual(1, t.code);
    try std.testing.expectEqualStrings(
        \\error[E0213]: unknown service "sshd"
        \\  --> /tmp/m.toml:2:1
        \\   | did you mean "ssh"?  (os explain E0213)
        \\
    , t.err.buffered());

    try t.exec(&.{ "config", "show", "--config=/tmp/m.toml", "--json" });
    try std.testing.expectEqual(1, t.code);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, t.out.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("E0213", parsed.value.object.get("errors").?.array.items[0].object.get("code").?.string);
}

test "config show with no config file" {
    var t: TestRun = .{};
    defer t.deinit();
    try t.exec(&.{ "config", "show" });
    try std.testing.expectEqual(1, t.code);
    try std.testing.expect(std.mem.startsWith(u8, t.err.buffered(), "error[E0100]: /etc/yoq/machine.toml doesn't exist"));
}

test "config show --json" {
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/machine.toml", "[system]\nhostname = \"atlas\"\n");
    try t.exec(&.{ "--json", "config", "show" });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, t.out.buffered(), .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("yoq.config/1", obj.get("schema").?.string);
    try std.testing.expectEqualStrings("/etc/yoq/machine.toml", obj.get("files").?.array.items[0].string);
    try std.testing.expectEqualStrings("atlas", obj.get("config").?.object.get("system").?.object.get("hostname").?.object.get("value").?.string);
}

test "facts --from reads a fixture" {
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("f.json",
        \\{"schema":"yoq.facts/1","hostname":"atlas","packages":[{"name":"git","version":"2.51.0-1"}]}
    );
    try t.exec(&.{ "--facts", "f.json", "facts" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expect(std.mem.startsWith(u8, t.out.buffered(), "hostname  atlas\n"));
    try std.testing.expect(std.mem.indexOf(u8, t.out.buffered(), "packages  1\n") != null);

    try t.fs.put("bad.json", "{}");
    try t.exec(&.{ "--facts", "bad.json", "facts" });
    try std.testing.expectEqual(1, t.code);
}

test "plan from fixture files" {
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"git\"]\n");
    try t.fs.put("/etc/yoq/machine.lock",
        \\version = 1
        \\sync_date = "2026-09-25"
        \\keyring = "1"
        \\[packages.git]
        \\version = "2.51.0-1"
        \\repo = "extra"
        \\sha256 = "
    ++ "a" ** 64 ++
        \\"
        \\[packages.linux]
        \\version = "6.16.8-1"
        \\repo = "core"
        \\sha256 = "
    ++ "a" ** 64 ++
        \\"
        \\
    );
    try t.fs.put("f.json",
        \\{"schema":"yoq.facts/1","packages":[{"name":"linux","version":"6.16.8-1"},{"name":"nano","version":"8.6-1"}]}
    );
    try t.exec(&.{ "--facts", "f.json", "plan" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqualStrings(
        \\packages
        \\  + git 2.51.0-1
        \\  - nano 8.6-1
        \\
        \\plan: 1 to add, 0 to change, 1 to remove · no reboot
        \\
    , t.out.buffered());

    try t.exec(&.{ "--facts", "missing.json", "plan" });
    try std.testing.expectEqual(1, t.code);
    try t.exec(&.{ "plan", "--bogus" });
    try std.testing.expectEqual(2, t.code);
}

test "why reads the config and lock" {
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"git\"]\n");
    try t.fs.put("/etc/yoq/machine.lock", "version = 1\nsync_date = \"2026-09-25\"\nkeyring = \"1\"\n" ++
        "[packages.git]\nversion = \"1\"\nrepo = \"extra\"\nsha256 = \"" ++ "a" ** 64 ++ "\"\ndepends = [\"zlib\"]\n" ++
        "[packages.linux]\nversion = \"1\"\nrepo = \"core\"\nsha256 = \"" ++ "a" ** 64 ++ "\"\n" ++
        "[packages.zlib]\nversion = \"1\"\nrepo = \"core\"\nsha256 = \"" ++ "a" ** 64 ++ "\"\n");
    try t.exec(&.{ "why", "zlib" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqualStrings("zlib: needed by git -> zlib\ngit: in packages  (/etc/yoq/machine.toml:1)\n", t.out.buffered());

    try t.exec(&.{ "why", "nano", "--json" });
    try std.testing.expectEqual(1, t.code);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, t.out.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("needed").?.bool);

    try t.exec(&.{"why"});
    try std.testing.expectEqual(2, t.code);
}
