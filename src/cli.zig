//! command dispatch. `run` takes its writers and args from the caller so
//! tests can drive it without a terminal.

const std = @import("std");
const build_options = @import("build_options");
const output = @import("output.zig");
const diag = @import("diag.zig");
const compose = @import("compose.zig");
const pipeline = @import("pipeline.zig");
const sync = @import("sync.zig");
const inspect = @import("cmd/inspect.zig");
const edit = @import("cmd/edit.zig");
const update = @import("cmd/update.zig");

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
    /// set by `--root <dir>`: where the machine's own files are, like
    /// /etc/pacman.conf and /var/cache/yoq. "/" for the running machine.
    root: []const u8 = "/",
    /// downloads package databases.
    fetcher: sync.Fetcher,
    files: compose.Files,
    /// answers to questions. commands ask only when `interactive` is set:
    /// stdin and stdout are terminals and --json is off.
    in: ?*std.Io.Reader = null,
    interactive: bool = false,
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
    .{ .name = "status", .summary = "what matches the config, what changed, what's failing", .handler = inspect.statusCmd },
    .{ .name = "plan", .summary = "show what apply would change", .handler = inspect.planCmd },
    .{ .name = "update", .summary = "resolve the config into machine.lock (update --dbs <dir>)", .handler = update.updateCmd },
    .{ .name = "add", .summary = "add packages to the config", .handler = edit.addCmd },
    .{ .name = "remove", .summary = "remove packages from the config", .handler = edit.removeCmd },
    .{ .name = "enable", .summary = "turn services on in the config", .handler = edit.enableCmd },
    .{ .name = "disable", .summary = "turn services off in the config", .handler = edit.disableCmd },
    .{ .name = "adopt", .summary = "put packages installed outside os into the config", .handler = edit.adoptCmd },
    .{ .name = "why", .summary = "say which config line brings in a package", .handler = inspect.whyCmd },
    .{ .name = "config", .summary = "show the merged config (config show [--resolved])", .handler = inspect.configCmd },
    .{ .name = "facts", .summary = "show what os knows about this machine", .handler = inspect.factsCmd },
    .{ .name = "explain", .summary = "explain an error code, like E0213", .handler = explain },
};

/// walks a command's own arguments.
pub const ArgIter = struct {
    args: []const [:0]const u8,
    i: usize = 0,

    pub fn next(it: *ArgIter) ?[]const u8 {
        if (it.i == it.args.len) return null;
        defer it.i += 1;
        return it.args[it.i];
    }
};

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// runs one command line (without the program name) and returns the exit
/// code: 0 ok, 1 failed, 2 bad usage.
pub fn run(ctx: *Context, raw: []const [:0]const u8) !u8 {
    const args = takeGlobalFlags(ctx, raw) catch |e| switch (e) {
        error.MissingConfigPath => {
            try ctx.err.writeAll("os: --config and --root need a path\n");
            return 2;
        },
        else => return e,
    };
    defer ctx.gpa.free(args);

    if (ctx.json) ctx.interactive = false;
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
        } else if (eql(arg, "--root")) {
            ctx.root = it.next() orelse return error.MissingConfigPath;
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
        \\  --root <dir>     the machine's files live under dir (default /)
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

pub fn usageError(ctx: *Context, comptime text: []const u8) !u8 {
    try ctx.err.writeAll("usage: " ++ text ++ "\n");
    return 2;
}

/// what most commands need while they run: an arena, a list for the
/// problems they find, and the config or config-plus-lock they load. all of
/// it goes away with `deinit`.
pub const Work = struct {
    ctx: *Context,
    arena: std.heap.ArenaAllocator,
    diags: diag.List,
    loaded: ?compose.Loaded = null,
    loaded_state: ?pipeline.State = null,

    pub fn init(ctx: *Context) Work {
        return .{ .ctx = ctx, .arena = .init(ctx.gpa), .diags = .init(ctx.gpa) };
    }

    pub fn deinit(w: *Work) void {
        if (w.loaded) |*l| l.deinit();
        if (w.loaded_state) |*s| s.deinit();
        w.diags.deinit();
        w.arena.deinit();
    }

    pub fn allocator(w: *Work) std.mem.Allocator {
        return w.arena.allocator();
    }

    pub fn failed(w: *const Work) bool {
        return w.diags.items.items.len > 0;
    }

    /// prints the problems found and returns the exit code for a failed
    /// command.
    pub fn report(w: *const Work) !u8 {
        return reportDiags(w.ctx, &w.diags);
    }

    /// the merged config, or null if it has problems.
    pub fn config(w: *Work) !?*compose.Loaded {
        w.loaded = try compose.load(w.ctx.gpa, w.ctx.files, w.ctx.config_path, &w.diags);
        return if (w.failed()) null else &w.loaded.?;
    }

    /// the config and its lock, or null if either has problems.
    pub fn state(w: *Work) !?*pipeline.State {
        w.loaded_state = try pipeline.load(w.ctx.gpa, w.ctx.files, w.ctx.config_path, null, &w.diags) orelse return null;
        return &w.loaded_state.?;
    }
};

/// says why facts couldn't be read. returns the exit code.
pub fn factsError(ctx: *Context, e: pipeline.Error, path: ?[]const u8) !u8 {
    const from = path orelse "this machine";
    switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FactsUnreadable => try ctx.err.print("os: can't read facts from {s}\n", .{from}),
        error.BadFacts => try ctx.err.print("os: {s} isn't a facts document (yoq.facts/1)\n", .{from}),
    }
    return 1;
}

/// the planner inputs for a command: the config path and machine root from
/// the global flags.
pub fn inputs(ctx: *const Context) pipeline.Inputs {
    return .{ .config_path = ctx.config_path, .root = ctx.root };
}

/// asks the user to pick one of `options` and returns its index. empty
/// input picks the first. returns null at the end of input.
pub fn choose(ctx: *Context, question: []const u8, options: []const []const u8) !?usize {
    try ctx.out.print("{s}\n", .{question});
    for (options, 1..) |o, i| try ctx.out.print("  {d}) {s}\n", .{ i, o });
    while (true) {
        try ctx.out.writeAll("pick one [1]: ");
        try ctx.out.flush();
        const read = ctx.in.?.takeDelimiter('\n') catch return null;
        const line = read orelse return null;
        const answer = std.mem.trim(u8, line, " \t\r");
        if (answer.len == 0) return 0;
        const n = std.fmt.parseInt(usize, answer, 10) catch 0;
        if (n >= 1 and n <= options.len) return n - 1;
        try ctx.out.print("pick a number from 1 to {d}.\n", .{options.len});
    }
}

/// prints collected problems to stderr, or as a json document on stdout
/// with --json. returns the exit code for a failed command.
pub fn reportDiags(ctx: *Context, diags: *const diag.List) !u8 {
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

/// runs commands against in-memory files, for tests here and in cmd/.
pub const TestRun = struct {
    out_buf: [8192]u8 = undefined,
    err_buf: [4096]u8 = undefined,
    out: std.Io.Writer = undefined,
    err: std.Io.Writer = undefined,
    ctx: Context = undefined,
    fs: compose.MemFiles = .{},
    /// typed answers to any questions, which makes the run interactive.
    input: ?[]const u8 = null,
    /// answers downloads. by default every download fails, so no test
    /// touches the network by accident.
    fetcher: ?sync.Fetcher = null,
    reader: std.Io.Reader = undefined,
    code: u8 = 0,

    pub fn deinit(t: *TestRun) void {
        t.fs.deinit();
    }

    pub fn exec(t: *TestRun, args: []const [:0]const u8) !void {
        t.out = .fixed(&t.out_buf);
        t.err = .fixed(&t.err_buf);
        t.ctx = .{
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .out = &t.out,
            .err = &t.err,
            .files = t.fs.files(),
            .fetcher = t.fetcher orelse offline,
        };
        if (t.input) |text| {
            t.reader = .fixed(text);
            t.ctx.in = &t.reader;
            t.ctx.interactive = true;
        }
        t.code = try run(&t.ctx, args);
    }
};

const offline: sync.Fetcher = .{ .ctx = undefined, .fetchFn = struct {
    fn f(_: *anyopaque, _: std.mem.Allocator, _: []const u8) error{OutOfMemory}!?[]const u8 {
        return null;
    }
}.f };

/// a path under the machine's root, like /etc/pacman.conf.
pub fn machinePath(ctx: *const Context, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ ctx.root, path });
}

test {
    _ = inspect;
    _ = edit;
    _ = update;
}

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

test "--config without a path is a usage error" {
    var t: TestRun = .{};
    try t.exec(&.{ "config", "show", "--config" });
    try std.testing.expectEqual(2, t.code);
}
