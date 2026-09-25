//! command dispatch. `run` takes its writers and args from the caller so
//! tests can drive it without a terminal.

const std = @import("std");
const build_options = @import("build_options");
const output = @import("output.zig");
const diag = @import("diag.zig");
const compose = @import("compose.zig");
const show = @import("show.zig");
const facts = @import("facts.zig");

pub const default_config = "/etc/yoq/machine.toml";

pub const Context = struct {
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    /// set by `--json`. commands print one json document instead of text.
    json: bool = false,
    /// stdout is a terminal and NO_COLOR isn't set. text output may use
    /// color and progress lines only when this is true.
    color: bool = false,
    /// set by `--config <path>`.
    config_path: []const u8 = default_config,
    files: compose.Files,
};

const Handler = *const fn (ctx: *Context, args: []const [:0]const u8) anyerror!u8;

const Command = struct {
    name: []const u8,
    summary: []const u8,
    handler: Handler,
};

const commands = [_]Command{
    .{ .name = "help", .summary = "show this help", .handler = help },
    .{ .name = "version", .summary = "print the version", .handler = version },
    .{ .name = "config", .summary = "show the merged config (config show [--resolved])", .handler = configCmd },
    .{ .name = "facts", .summary = "show what os knows about this machine (facts --from <file>)", .handler = factsCmd },
    .{ .name = "explain", .summary = "explain an error code, like E0213", .handler = explain },
};

/// runs one command line (without the program name) and returns the exit
/// code: 0 ok, 1 failed, 2 bad usage.
pub fn run(ctx: *Context, raw: []const [:0]const u8) !u8 {
    const args = takeGlobalFlags(ctx, raw) catch |e| switch (e) {
        error.MissingConfigPath => {
            try ctx.err.writeAll("os: --config needs a path\n");
            return 2;
        },
        else => return e,
    };
    defer ctx.gpa.free(args);

    if (args.len == 0) return help(ctx, args);

    const name = args[0];
    if (std.mem.eql(u8, name, "-h") or std.mem.eql(u8, name, "--help")) return help(ctx, args[1..]);
    if (std.mem.eql(u8, name, "--version")) return version(ctx, args[1..]);

    for (commands) |c| {
        if (std.mem.eql(u8, c.name, name)) return c.handler(ctx, args[1..]);
    }

    try ctx.err.print("os: unknown command '{s}'\n\n", .{name});
    try usage(ctx.err);
    return 2;
}

/// pulls global flags out of the args wherever they appear before `--`, so
/// `os --json status` and `os status --json` mean the same thing.
fn takeGlobalFlags(ctx: *Context, raw: []const [:0]const u8) ![]const [:0]const u8 {
    var rest: std.ArrayList([:0]const u8) = .empty;
    errdefer rest.deinit(ctx.gpa);
    var passthrough = false;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const arg = raw[i];
        if (!passthrough) {
            if (std.mem.eql(u8, arg, "--")) passthrough = true;
            if (std.mem.eql(u8, arg, "--json")) {
                ctx.json = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--config")) {
                if (i + 1 == raw.len) return error.MissingConfigPath;
                i += 1;
                ctx.config_path = raw[i];
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--config=")) {
                ctx.config_path = arg["--config=".len..];
                continue;
            }
        }
        try rest.append(ctx.gpa, arg);
    }
    return rest.toOwnedSlice(ctx.gpa);
}

fn usage(w: *std.Io.Writer) !void {
    try w.writeAll("usage: os <command> [args]\n\ncommands:\n");
    for (commands) |c| try w.print("  {s:<10}{s}\n", .{ c.name, c.summary });
    try w.writeAll(
        \\
        \\global flags:
        \\  --json           machine-readable output
        \\  --config <path>  config file (default /etc/yoq/machine.toml)
        \\
    );
}

fn help(ctx: *Context, _: []const [:0]const u8) !u8 {
    if (ctx.json) {
        const Entry = struct { name: []const u8, summary: []const u8 };
        var entries: [commands.len]Entry = undefined;
        for (commands, &entries) |c, *e| e.* = .{ .name = c.name, .summary = c.summary };
        try output.writeDoc(ctx.out, "yoq.help/1", .{ .commands = entries });
        return 0;
    }
    try usage(ctx.out);
    return 0;
}

fn version(ctx: *Context, _: []const [:0]const u8) !u8 {
    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.version/1", .{ .version = build_options.version });
        return 0;
    }
    try ctx.out.print("os {s}\n", .{build_options.version});
    return 0;
}

fn configCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "show")) {
        try ctx.err.writeAll("usage: os config show [--resolved]\n");
        return 2;
    }
    var sources = false;
    for (args[1..]) |a| {
        if (!std.mem.eql(u8, a, "--resolved")) {
            try ctx.err.print("os: unknown flag '{s}' for config show\n", .{a});
            return 2;
        }
        sources = true;
    }

    var diags: diag.List = .init(ctx.gpa);
    defer diags.deinit();
    var loaded = try compose.load(ctx.gpa, ctx.files, ctx.config_path, &diags);
    defer loaded.deinit();
    if (diags.items.items.len > 0) return reportDiags(ctx, &diags);

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

fn factsCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (args.len != 2 or !std.mem.eql(u8, args[0], "--from")) {
        if (args.len == 0) {
            try ctx.err.writeAll("os: reading facts from this machine isn't built yet. use `os facts --from <file>`.\n");
            return 1;
        }
        try ctx.err.writeAll("usage: os facts [--from <file>]\n");
        return 2;
    }
    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena.deinit();
    const f = try readFacts(ctx, arena.allocator(), args[1]) orelse return 1;
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

/// reads a facts file, or says why it couldn't and returns null.
fn readFacts(ctx: *Context, a: std.mem.Allocator, path: []const u8) !?facts.Facts {
    const bytes = ctx.files.readFn(ctx.files.ctx, a, path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try ctx.err.print("os: can't read facts from {s}\n", .{path});
            return null;
        },
    };
    return facts.parse(a, bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadFacts => {
            try ctx.err.print("os: {s} isn't a facts document ({s})\n", .{ path, facts.schema });
            return null;
        },
    };
}

/// prints collected problems to stderr, or as a json document on stdout
/// with --json. returns the exit code for a failed command.
fn reportDiags(ctx: *Context, diags: *const diag.List) !u8 {
    if (ctx.json) {
        try diags.writeJson(ctx.out);
    } else {
        try diags.render(ctx.err);
    }
    return 1;
}

fn explain(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (args.len == 0) {
        if (ctx.json) {
            var all: [diag.table.len]diag.EntryJson = undefined;
            for (diag.table, &all) |e, *j| j.* = diag.entryJson(e);
            try output.writeDoc(ctx.out, "yoq.explain/1", .{ .codes = all });
            return 0;
        }
        for (diag.table) |e| try ctx.out.print("{s}  {s}\n", .{ e.id, e.title });
        return 0;
    }
    if (args.len > 1) {
        try ctx.err.writeAll("usage: os explain [code]\n");
        return 2;
    }
    const e = diag.byId(args[0]) orelse {
        try ctx.err.print("os: no error code '{s}'. `os explain` lists them all.\n", .{args[0]});
        return 2;
    };
    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.explain/1", .{ .codes = [_]diag.EntryJson{diag.entryJson(e)} });
        return 0;
    }
    try ctx.out.print("{s}: {s}\n\n{s}\n", .{ e.id, e.title, e.explanation });
    return 0;
}

const TestRun = struct {
    out_buf: [8192]u8 = undefined,
    err_buf: [4096]u8 = undefined,
    out: std.Io.Writer = undefined,
    err: std.Io.Writer = undefined,
    ctx: Context = undefined,
    fs: compose.MemFiles = .{},
    code: u8 = 0,

    fn deinit(t: *TestRun) void {
        t.fs.deinit();
    }

    fn exec(t: *TestRun, args: []const [:0]const u8) !void {
        t.out = .fixed(&t.out_buf);
        t.err = .fixed(&t.err_buf);
        t.ctx = .{ .gpa = std.testing.allocator, .out = &t.out, .err = &t.err, .files = t.fs.files() };
        t.code = try run(&t.ctx, args);
    }
};

test "no args prints usage" {
    var t: TestRun = .{};
    try t.exec(&.{});
    try std.testing.expectEqual(0, t.code);
    try std.testing.expect(std.mem.startsWith(u8, t.out.buffered(), "usage: os"));
}

test "version prints the build version" {
    var t: TestRun = .{};
    try t.exec(&.{"version"});
    try std.testing.expectEqualStrings("os " ++ build_options.version ++ "\n", t.out.buffered());

    try t.exec(&.{"--version"});
    try std.testing.expectEqualStrings("os " ++ build_options.version ++ "\n", t.out.buffered());
}

test "unknown command is a usage error" {
    var t: TestRun = .{};
    try t.exec(&.{"frobnicate"});
    try std.testing.expectEqual(2, t.code);
    try std.testing.expect(std.mem.startsWith(u8, t.err.buffered(), "os: unknown command 'frobnicate'"));
    try std.testing.expectEqual(0, t.out.buffered().len);
}

test "--json works before or after the command" {
    const want =
        \\{
        \\  "schema": "yoq.version/1",
        \\  "version": "
    ++ build_options.version ++
        \\"
        \\}
        \\
    ;
    var t: TestRun = .{};
    try t.exec(&.{ "--json", "version" });
    try std.testing.expectEqualStrings(want, t.out.buffered());
    try t.exec(&.{ "version", "--json" });
    try std.testing.expectEqualStrings(want, t.out.buffered());
}

test "--json after -- is left alone" {
    var t: TestRun = .{};
    try t.exec(&.{ "version", "--", "--json" });
    try std.testing.expect(!t.ctx.json);
}

test "help --json lists every command" {
    var t: TestRun = .{};
    try t.exec(&.{ "help", "--json" });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, t.out.buffered(), .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("yoq.help/1", obj.get("schema").?.string);
    try std.testing.expectEqual(commands.len, obj.get("commands").?.array.items.len);
}

test "explain prints one code or lists them all" {
    var t: TestRun = .{};
    try t.exec(&.{ "explain", "e0213" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expect(std.mem.startsWith(u8, t.out.buffered(), "E0213: unknown service\n\n"));

    try t.exec(&.{"explain"});
    try std.testing.expect(std.mem.indexOf(u8, t.out.buffered(), "E0001  toml syntax error\n") != null);

    try t.exec(&.{ "explain", "E9999" });
    try std.testing.expectEqual(2, t.code);
}

test "explain --json" {
    var t: TestRun = .{};
    try t.exec(&.{ "explain", "E0101", "--json" });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, t.out.buffered(), .{});
    defer parsed.deinit();
    const codes = parsed.value.object.get("codes").?.array.items;
    try std.testing.expectEqual(1, codes.len);
    try std.testing.expectEqualStrings("unknown key", codes[0].object.get("title").?.string);
    try std.testing.expectEqualStrings("E0101", codes[0].object.get("code").?.string);
    try std.testing.expectEqualStrings("unknown_key", codes[0].object.get("name").?.string);
}

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

test "--config without a path is a usage error" {
    var t: TestRun = .{};
    try t.exec(&.{ "config", "show", "--config" });
    try std.testing.expectEqual(2, t.code);
}

test "facts --from reads a fixture" {
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("f.json",
        \\{"schema":"yoq.facts/1","hostname":"atlas","packages":[{"name":"git","version":"2.51.0-1"}]}
    );
    try t.exec(&.{ "facts", "--from", "f.json" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expect(std.mem.startsWith(u8, t.out.buffered(), "hostname  atlas\n"));
    try std.testing.expect(std.mem.indexOf(u8, t.out.buffered(), "packages  1\n") != null);

    try t.fs.put("bad.json", "{}");
    try t.exec(&.{ "facts", "--from", "bad.json" });
    try std.testing.expectEqual(1, t.code);
}
