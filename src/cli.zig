//! command dispatch. `run` takes its writers and args from the caller so
//! tests can drive it without a terminal.

const std = @import("std");
const build_options = @import("build_options");
const output = @import("output.zig");
const diag = @import("diag.zig");
const compose = @import("compose.zig");
const show = @import("show.zig");
const facts = @import("facts.zig");
const planner = @import("planner.zig");
const pipeline = @import("pipeline.zig");
const why = @import("why.zig");
const change = @import("change.zig");
const alpm = @import("alpm.zig");
const lock = @import("lock.zig");
const observe = @import("observe.zig");

pub const default_config = "/etc/yoq/machine.toml";

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
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
    .{ .name = "plan", .summary = "show what apply would change (plan --facts <file>)", .handler = planCmd },
    .{ .name = "update", .summary = "resolve the config into machine.lock (update --dbs <dir>)", .handler = updateCmd },
    .{ .name = "add", .summary = "add packages to the config", .handler = addCmd },
    .{ .name = "remove", .summary = "remove packages from the config", .handler = removeCmd },
    .{ .name = "enable", .summary = "turn services on in the config", .handler = enableCmd },
    .{ .name = "disable", .summary = "turn services off in the config", .handler = disableCmd },
    .{ .name = "why", .summary = "say which config line brings in a package", .handler = whyCmd },
    .{ .name = "config", .summary = "show the merged config (config show [--resolved])", .handler = configCmd },
    .{ .name = "facts", .summary = "show what os knows about this machine (facts --from <file>)", .handler = factsCmd },
    .{ .name = "explain", .summary = "explain an error code, like E0213", .handler = explain },
};

/// walks a command's own arguments.
const ArgIter = struct {
    args: []const [:0]const u8,
    i: usize = 0,

    fn next(it: *ArgIter) ?[]const u8 {
        if (it.i == it.args.len) return null;
        defer it.i += 1;
        return it.args[it.i];
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

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
    if (eql(name, "-h") or eql(name, "--help")) return help(ctx, args[1..]);
    if (eql(name, "--version")) return version(ctx, args[1..]);

    for (commands) |c| {
        if (eql(c.name, name)) return c.handler(ctx, args[1..]);
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
    var it: ArgIter = .{ .args = raw };
    while (it.next()) |arg| {
        if (eql(arg, "--")) {
            try rest.appendSlice(ctx.gpa, raw[it.i - 1 ..]);
            break;
        } else if (eql(arg, "--json")) {
            ctx.json = true;
        } else if (eql(arg, "--config")) {
            ctx.config_path = it.next() orelse return error.MissingConfigPath;
        } else if (std.mem.startsWith(u8, arg, "--config=")) {
            ctx.config_path = arg["--config=".len..];
        } else {
            try rest.append(ctx.gpa, raw[it.i - 1]);
        }
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

fn usageError(ctx: *Context, comptime text: []const u8) !u8 {
    try ctx.err.writeAll("usage: " ++ text ++ "\n");
    return 2;
}

fn configCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    const usage_text = "os config show [--resolved]";
    var it: ArgIter = .{ .args = args };
    if (!eql(it.next() orelse "", "show")) return usageError(ctx, usage_text);
    var sources = false;
    while (it.next()) |a| {
        if (!eql(a, "--resolved")) return usageError(ctx, usage_text);
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
    const usage_text = "os facts [--from <file> | --root <dir>]";
    var from: ?[]const u8 = null;
    var root: []const u8 = "/";
    var it: ArgIter = .{ .args = args };
    while (it.next()) |a| {
        if (eql(a, "--from")) {
            from = it.next() orelse return usageError(ctx, usage_text);
        } else if (eql(a, "--root")) {
            root = it.next() orelse return usageError(ctx, usage_text);
        } else return usageError(ctx, usage_text);
    }

    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena.deinit();
    var diags: diag.List = .init(ctx.gpa);
    defer diags.deinit();
    const f = if (from) |path|
        pipeline.readFacts(ctx.files, arena.allocator(), path) catch |e| return factsError(ctx, e, path)
    else
        try observe.observe(arena.allocator(), ctx.io, .{ .root = root }, &diags);
    if (diags.items.items.len > 0) return reportDiags(ctx, &diags);
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

fn planCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    const usage_text = "os plan --facts <file> [--lock <file>] [-v]";
    var facts_path: ?[]const u8 = null;
    var lock_path: ?[]const u8 = null;
    var verbose = false;
    var it: ArgIter = .{ .args = args };
    while (it.next()) |a| {
        if (eql(a, "-v") or eql(a, "--verbose")) {
            verbose = true;
        } else if (eql(a, "--facts")) {
            facts_path = it.next() orelse return usageError(ctx, usage_text);
        } else if (eql(a, "--lock")) {
            lock_path = it.next() orelse return usageError(ctx, usage_text);
        } else return usageError(ctx, usage_text);
    }
    const in: pipeline.Inputs = .{
        .config_path = ctx.config_path,
        .lock_path = lock_path,
        .facts_path = facts_path,
    };

    var diags: diag.List = .init(ctx.gpa);
    defer diags.deinit();
    const built = pipeline.buildPlan(ctx.gpa, ctx.io, ctx.files, in, &diags) catch |e| return factsError(ctx, e, in.facts_path orelse "this machine");
    var result = built orelse return reportDiags(ctx, &diags);
    defer result.deinit();

    if (ctx.json) {
        try planner.writeJson(ctx.out, result.allocator(), &result.plan);
    } else {
        try planner.writeText(ctx.out, result.allocator(), &result.plan, .{ .verbose = verbose });
    }
    return 0;
}

fn addCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    return changeCmd(ctx, args, .add);
}

fn removeCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    return changeCmd(ctx, args, .remove);
}

fn enableCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    return changeCmd(ctx, args, .enable);
}

fn disableCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    return changeCmd(ctx, args, .disable);
}

fn changeCmd(ctx: *Context, args: []const [:0]const u8, op: change.Op) !u8 {
    if (args.len == 0) {
        try ctx.err.print("usage: os {s} <{s}>...\n", .{ @tagName(op), if (op == .add or op == .remove) "package" else "service" });
        return 2;
    }
    for (args) |a| {
        if (a[0] == '-') {
            try ctx.err.print("os: unknown flag '{s}'\n", .{a});
            return 2;
        }
    }

    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var diags: diag.List = .init(ctx.gpa);
    defer diags.deinit();

    var loaded = try compose.load(ctx.gpa, ctx.files, ctx.config_path, &diags);
    defer loaded.deinit();
    if (diags.items.items.len > 0) return reportDiags(ctx, &diags);
    const top = loaded.files.items[0];
    const text = ctx.files.read(a, top) catch {
        try ctx.err.print("os: can't read {s}\n", .{top});
        return 1;
    };

    const names = try a.alloc([]const u8, args.len);
    for (args, names) |arg, *n| n.* = arg;
    const outcome = try change.plan(a, &loaded.config, top, text, op, names, &diags);
    if (diags.items.items.len > 0) return reportDiags(ctx, &diags);
    if (outcome.changed()) {
        if (!try change.check(ctx.gpa, ctx.files, top, outcome.text, op, outcome.notes, &diags)) return reportDiags(ctx, &diags);
        ctx.files.write(top, outcome.text) catch {
            try ctx.err.print("os: can't write {s}\n", .{top});
            return 1;
        };
    }

    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.change/1", .{ .file = top, .changed = outcome.changed(), .notes = outcome.notes });
        return 0;
    }
    for (outcome.notes) |n| {
        switch (n.what) {
            .added => try ctx.out.print("+ packages \"{s}\"\n", .{n.name}),
            .removed => try ctx.out.print("- packages \"{s}\"\n", .{n.name}),
            .excluded => try ctx.out.print("+ remove.packages \"{s}\"  (set in {s})\n", .{ n.name, n.detail.? }),
            .enabled, .disabled => try ctx.out.print("~ services.{s} = {}\n", .{ n.name, n.what == .enabled }),
            .unchanged => try ctx.out.print("  {s} is already set that way  ({s})\n", .{ n.name, n.detail.? }),
        }
    }
    if (outcome.changed()) {
        try ctx.out.print("\nsaved {s}. applying isn't built yet; `os plan` shows what would change.\n", .{top});
    }
    return 0;
}

fn updateCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    const usage_text = "os update --dbs <dir> [--date yyyy-mm-dd]";
    var dbs_dir: ?[]const u8 = null;
    var date: ?[]const u8 = null;
    var it: ArgIter = .{ .args = args };
    while (it.next()) |a| {
        if (eql(a, "--dbs")) {
            dbs_dir = it.next() orelse return usageError(ctx, usage_text);
        } else if (eql(a, "--date")) {
            date = it.next() orelse return usageError(ctx, usage_text);
        } else return usageError(ctx, usage_text);
    }
    if (!alpm.available) {
        try ctx.err.writeAll("os: this build can't resolve packages. build with -Dalpm.\n");
        return 1;
    }
    const dir = dbs_dir orelse {
        try ctx.err.writeAll("os: downloading package databases isn't built yet. pass --dbs <dir> with core.db and friends.\n");
        return 1;
    };

    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var diags: diag.List = .init(ctx.gpa);
    defer diags.deinit();
    var loaded = try compose.load(ctx.gpa, ctx.files, ctx.config_path, &diags);
    defer loaded.deinit();
    if (diags.items.items.len > 0) return reportDiags(ctx, &diags);

    const dbs = try syncDbs(ctx, a, dir) orelse return 1;
    const scratch = try std.fmt.allocPrint(a, "/tmp/os-resolve-{d}", .{std.Io.Timestamp.now(ctx.io, .real).toNanoseconds()});
    defer std.Io.Dir.cwd().deleteTree(ctx.io, scratch) catch {};

    const ws = try planner.wants(a, &loaded.config);
    const names = try a.alloc([]const u8, ws.len);
    for (ws, names) |w, *n| n.* = w.name;
    var providers: std.ArrayList(lock.Provider) = .empty;
    for (loaded.config.providers.entries.items) |e| try providers.append(a, .{ .name = e.name, .chosen = e.value.v });

    const l = try alpm.resolve(a, ctx.io, .{
        .dbs = dbs,
        .wants = names,
        .providers = providers.items,
        .sync_date = date orelse try today(ctx.io, a),
        .scratch = scratch,
    }, &diags) orelse return reportDiags(ctx, &diags);

    var out: std.Io.Writer.Allocating = .init(a);
    try lock.write(&out.writer, &l);
    const lock_path = try std.fs.path.join(a, &.{ std.fs.path.dirnamePosix(loaded.files.items[0]) orelse ".", "machine.lock" });
    ctx.files.write(lock_path, out.written()) catch {
        try ctx.err.print("os: can't write {s}\n", .{lock_path});
        return 1;
    };
    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.update/1", .{ .lock = lock_path, .sync_date = l.sync_date, .packages = l.packages.len });
    } else {
        try ctx.out.print("resolved {d} packages as of {s} into {s}.\n", .{ l.packages.len, l.sync_date, lock_path });
    }
    return 0;
}

/// every `<repo>.db` file in `dir`, in the order pacman.conf lists arch's
/// repositories, then the rest by name.
fn syncDbs(ctx: *Context, a: std.mem.Allocator, dir: []const u8) !?[]const alpm.SyncDb {
    var d = std.Io.Dir.cwd().openDir(ctx.io, dir, .{ .iterate = true }) catch {
        try ctx.err.print("os: can't open {s}\n", .{dir});
        return null;
    };
    defer d.close(ctx.io);
    var names: std.ArrayList([]const u8) = .empty;
    var iter = d.iterate();
    while (try iter.next(ctx.io)) |e| {
        if (std.mem.endsWith(u8, e.name, ".db")) try names.append(a, try a.dupe(u8, e.name[0 .. e.name.len - 3]));
    }
    @import("sort.zig").strings(names.items);
    const order = [_][]const u8{ "core-testing", "core", "extra-testing", "extra", "multilib-testing", "multilib" };
    var dbs: std.ArrayList(alpm.SyncDb) = .empty;
    for (order) |o| {
        for (names.items) |n| {
            if (eql(n, o)) try dbs.append(a, .{ .name = n, .path = try std.fmt.allocPrint(a, "{s}/{s}.db", .{ dir, n }) });
        }
    }
    for (names.items) |n| {
        for (order) |o| {
            if (eql(n, o)) break;
        } else try dbs.append(a, .{ .name = n, .path = try std.fmt.allocPrint(a, "{s}/{s}.db", .{ dir, n }) });
    }
    if (dbs.items.len == 0) {
        try ctx.err.print("os: no .db files in {s}\n", .{dir});
        return null;
    }
    return dbs.items;
}

fn today(io: std.Io, a: std.mem.Allocator) ![]const u8 {
    const secs: u64 = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());
    const day = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = day.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 });
}

fn whyCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (args.len != 1 or args[0][0] == '-') return usageError(ctx, "os why <package>");
    var diags: diag.List = .init(ctx.gpa);
    defer diags.deinit();
    var state = try pipeline.load(ctx.gpa, ctx.files, ctx.config_path, null, &diags) orelse return reportDiags(ctx, &diags);
    defer state.deinit();

    const ans = try why.explain(state.arena.allocator(), state.config(), &state.lock, args[0]);
    if (ctx.json) try why.writeJson(ctx.out, &ans) else try why.writeText(ctx.out, &ans);
    return if (ans.root == null) 1 else 0;
}

/// says why a facts file couldn't be used. returns the exit code.
fn factsError(ctx: *Context, e: pipeline.Error, path: []const u8) !u8 {
    switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FactsUnreadable => try ctx.err.print("os: can't read facts from {s}\n", .{path}),
        error.BadFacts => try ctx.err.print("os: {s} isn't a facts document ({s})\n", .{ path, facts.schema }),
    }
    return 1;
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
    if (args.len > 1) return usageError(ctx, "os explain [code]");
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
        t.ctx = .{ .gpa = std.testing.allocator, .io = std.testing.io, .out = &t.out, .err = &t.err, .files = t.fs.files() };
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
    try t.exec(&.{ "plan", "--facts", "f.json" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqualStrings(
        \\packages
        \\  + git 2.51.0-1
        \\  - nano 8.6-1
        \\
        \\plan: 1 to add, 0 to change, 1 to remove · no reboot
        \\
    , t.out.buffered());

    try t.exec(&.{ "plan", "--facts", "missing.json" });
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

test "add, remove, enable, and disable edit the config file" {
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/base.toml", "packages = [\"nano\", \"git\"]\n");
    try t.fs.put("/etc/yoq/machine.toml",
        \\# my laptop
        \\include = ["base.toml"]
        \\packages = ["git", "neovim"]  # editors
        \\
        \\[services]
        \\ssh = true
        \\
    );
    try t.exec(&.{ "add", "ripgrep", "neovim" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expect(std.mem.startsWith(u8, t.out.buffered(), "+ packages \"ripgrep\"\n  neovim is already set that way  (/etc/yoq/machine.toml:3)\n"));

    try t.exec(&.{ "remove", "nano", "git" });
    try std.testing.expectEqual(0, t.code);
    try t.exec(&.{ "enable", "tailscale" });
    try t.exec(&.{ "disable", "ssh" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqualStrings(
        \\# my laptop
        \\include = ["base.toml"]
        \\packages = ["neovim", "ripgrep"]  # editors
        \\
        \\[services]
        \\ssh = false
        \\tailscale = true
        \\
        \\[remove]
        \\packages = ["nano", "git"]
        \\
    , t.fs.get("/etc/yoq/machine.toml").?);
}

test "change refuses what it can't do" {
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"git\"]\n[services]\nssh = true\n");
    try t.exec(&.{ "remove", "openssh" });
    try std.testing.expectEqual(1, t.code);
    try std.testing.expect(std.mem.indexOf(u8, t.err.buffered(), "openssh comes from services.ssh") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.err.buffered(), "run `os disable ssh`") != null);

    try t.exec(&.{ "remove", "vim" });
    try std.testing.expectEqual(1, t.code);
    try t.exec(&.{ "enable", "sshd" });
    try std.testing.expectEqual(1, t.code);
    try std.testing.expect(std.mem.indexOf(u8, t.err.buffered(), "did you mean \"ssh\"?") != null);
    try t.exec(&.{"add"});
    try std.testing.expectEqual(2, t.code);
    try std.testing.expectEqualStrings("packages = [\"git\"]\n[services]\nssh = true\n", t.fs.get("/etc/yoq/machine.toml").?);
}

test "update resolves the fixture repos into a lock" {
    if (!alpm.available) return error.SkipZigTest;
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"git\"]\n");
    try t.exec(&.{ "update", "--dbs", "tests/alpm/repos", "--date", "2026-09-25" });
    try std.testing.expectEqualStrings("", t.err.buffered());
    try std.testing.expectEqual(0, t.code);
    const written = t.fs.get("/etc/yoq/machine.lock").?;
    try std.testing.expect(std.mem.indexOf(u8, written, "sync_date = \"2026-09-25\"\nkeyring = \"none\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "[packages.perl-error]") != null);

    // the new lock covers the config, so planning works.
    try t.fs.put("f.json", "{\"schema\":\"yoq.facts/1\"}");
    try t.exec(&.{ "plan", "--facts", "f.json" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expect(std.mem.indexOf(u8, t.out.buffered(), "+ git 2.51.0-1") != null);
}
