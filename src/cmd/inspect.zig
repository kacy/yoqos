//! commands that read and report: `config show`, `facts`, `status`, `plan`,
//! and `why`. none of them change anything.

const std = @import("std");
const rootfs = @import("../rootfs.zig");
const gens = @import("../gens.zig");
const cli = @import("../cli.zig");
const facts = @import("../facts.zig");
const planner = @import("../planner.zig");
const show = @import("../show.zig");
const output = @import("../output.zig");
const why = @import("../why.zig");
const observe = @import("../observe.zig");
const config = @import("../config.zig");
const status = @import("../status.zig");
const Context = cli.Context;
const eql = cli.eql;

pub fn configCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    const usage_text = "os config show [--resolved]";
    var it: cli.ArgIter = .{ .args = args };
    if (!eql(it.next() orelse "", "show")) return cli.usageError(ctx, usage_text);
    var sources = false;
    while (it.next()) |arg| {
        if (!it.isFlag(arg) or !eql(arg, "--resolved")) return cli.usageError(ctx, usage_text);
        sources = true;
    }

    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const loaded = try w.config() orelse return w.fail();

    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.config/1", .{ .files = loaded.files.items, .config = show.Json{ .config = &loaded.config } });
        return 0;
    }
    try show.writeToml(ctx.out, &loaded.config, sources);
    return 0;
}

pub fn factsCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (try cli.noArgs(ctx, args, "os facts")) |code| return code;
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const f = try w.facts() orelse return w.fail();

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
    const usage_text = "os plan [--lock <file>] [-o <file>] [-v]";
    var in = cli.inputs(ctx);
    var verbose = false;
    var save: ?[]const u8 = null;
    var it: cli.ArgIter = .{ .args = args };
    while (it.next()) |arg| {
        if (!it.isFlag(arg)) {
            return cli.usageError(ctx, usage_text);
        } else if (eql(arg, "-v") or eql(arg, "--verbose")) {
            verbose = true;
        } else if (eql(arg, "-o") or eql(arg, "--output")) {
            save = it.value() orelse return cli.usageError(ctx, usage_text);
        } else if (eql(arg, "--lock")) {
            in.lock_path = it.value() orelse return cli.usageError(ctx, usage_text);
        } else return cli.usageError(ctx, usage_text);
    }

    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const result = try w.plan(in) orelse return w.fail();
    if (!try planner.checkEsp(result.allocator(), &result.plan, &result.facts, &w.diags)) return w.fail();
    if (!try planner.checkSecrets(result.state.config(), &result.facts, &w.diags)) return w.fail();
    if (!try planner.checkSecureBoot(result.state.config(), &result.facts, &w.diags)) return w.fail();
    if (!try planner.checkLuks(result.state.config(), &result.plan, &result.facts, &w.diags)) return w.fail();

    if (ctx.json) {
        try planner.writeJson(ctx.out, result.allocator(), &result.plan);
    } else {
        try planner.writeText(ctx.out, result.allocator(), &result.plan, .{ .verbose = verbose });
    }
    if (save) |path| {
        // the same document --json prints: `os apply <file>` checks its hash.
        var doc: std.Io.Writer.Allocating = .init(result.allocator());
        try planner.writeJson(&doc.writer, result.allocator(), &result.plan);
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = doc.written() }) catch |e|
            return cli.fail(ctx, "can't write {s}: {s}", .{ path, @errorName(e) });
        if (!ctx.json) try ctx.out.print("\nsaved to {s}. `os apply {s}` applies this plan, and refuses if it changed.\n", .{ path, path });
    }
    return 0;
}

pub fn statusCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (try cli.noArgs(ctx, args, "os status")) |code| return code;
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const result = try w.plan(cli.inputs(ctx)) orelse return w.fail();

    const s = try status.summarize(result.allocator(), result.state.config(), &result.state.lock, &result.facts, &result.plan);
    if (ctx.json) {
        try status.writeJson(ctx.out, &s);
    } else {
        try status.writeText(ctx.out, &s);
        // something os did on its own, like falling back from a generation.
        const fs: rootfs.Root = .{ .a = result.allocator(), .io = ctx.io, .dir = ctx.root };
        const notice = try fs.read(gens.notice_path[1..]);
        if (notice.len > 0) try ctx.out.print("\nnote: {s}", .{notice});
    }
    return if (s.failed()) 1 else 0;
}

pub fn whyCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    var buf: [1][]const u8 = undefined;
    var it: cli.ArgIter = .{ .args = args };
    const names = it.names(&buf) orelse &.{};
    if (names.len != 1 or names[0].len == 0) return cli.usageError(ctx, "os why <package | file | unit>");
    const arg = names[0];
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    switch (why.kindOf(arg)) {
        .file => {
            const loaded = try w.config() orelse return w.fail();
            var ans = try why.explainFile(a, &loaded.config, arg);
            if (ans.cause == null) ans.package = try observe.fileOwner(a, ctx.io, ctx.root, arg);
            if (ctx.json) try why.writeFileJson(ctx.out, &ans) else try why.writeFileText(ctx.out, &ans);
            return if (ans.cause == null) 1 else 0;
        },
        .unit => {
            const loaded = try w.config() orelse return w.fail();
            return whyUnit(ctx, a, &loaded.config, arg);
        },
        .package => {},
    }
    const state = try w.state() orelse return w.fail();
    const ans = try why.explain(a, state.config(), &state.lock, arg);
    // a name nothing needs as a package may be a service, like "ssh".
    if (ans.root == null and state.lock.package(arg) == null) {
        if (why.serviceUnit(state.config(), arg)) |unit| return whyUnit(ctx, a, state.config(), unit);
    }
    if (ctx.json) try why.writeJson(ctx.out, &ans) else try why.writeText(ctx.out, &ans);
    return if (ans.root == null) 1 else 0;
}

fn whyUnit(ctx: *Context, a: std.mem.Allocator, c: *const config.Config, unit: []const u8) !u8 {
    const ans = try why.explainUnit(a, c, unit);
    if (ctx.json) try why.writeUnitJson(ctx.out, &ans) else try why.writeUnitText(ctx.out, &ans);
    return if (ans.cause == null) 1 else 0;
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

test "facts reads a fixture" {
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

test "why takes files and units too" {
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"git\"]\n[sysctl]\n\"vm.swappiness\" = 10\n[services]\nssh = true\n");
    try t.fs.put("/etc/yoq/machine.lock", "version = 1\nsync_date = \"2026-09-25\"\nkeyring = \"1\"\n" ++
        "[packages.git]\nversion = \"1\"\nrepo = \"extra\"\nsha256 = \"" ++ "a" ** 64 ++ "\"\n");
    try t.exec(&.{ "why", "/etc/sysctl.d/99-yoq.conf" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqualStrings("/etc/sysctl.d/99-yoq.conf: os writes it for sysctl  (/etc/yoq/machine.toml:3)\n", t.out.buffered());

    try t.exec(&.{ "--root", "/nonexistent", "why", "/etc/hosts" });
    try std.testing.expectEqual(1, t.code);
    try std.testing.expect(std.mem.startsWith(u8, t.out.buffered(), "/etc/hosts: not managed by os\n"));

    try t.exec(&.{ "why", "sshd.service" });
    try std.testing.expectEqualStrings("sshd.service: enabled by services.ssh  (/etc/yoq/machine.toml:5)\n", t.out.buffered());
    // a name that's a service and no package goes to its unit.
    try t.exec(&.{ "why", "ssh", "--json" });
    try std.testing.expectEqual(0, t.code);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, t.out.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("yoq.why-unit/1", parsed.value.object.get("schema").?.string);
    try std.testing.expectEqualStrings("sshd.service", parsed.value.object.get("unit").?.string);
    try std.testing.expectEqualStrings("services.ssh", parsed.value.object.get("cause").?.string);
}
