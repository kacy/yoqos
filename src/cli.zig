//! command dispatch. `run` takes its writers and args from the caller so
//! tests can drive it without a terminal.

const std = @import("std");
const build_options = @import("build_options");
const output = @import("output.zig");
const diag = @import("diag.zig");
const compose = @import("compose.zig");
const pipeline = @import("pipeline.zig");
const sync = @import("sync.zig");
const history = @import("history.zig");
const init_cmd = @import("cmd/init.zig");
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
    /// set by `--config <path>`.
    config_path: []const u8 = default_config,
    /// set by `--root <dir>`: where the machine's own files are, like
    /// /etc/pacman.conf and /var/cache/yoq. "/" for the running machine.
    root: []const u8 = "/",
    /// set by `--facts <file>`: read facts from a file instead of observing
    /// the machine.
    facts_path: ?[]const u8 = null,
    /// downloads package databases.
    fetcher: sync.Fetcher,
    /// records config changes, as git commits.
    history: history.History,
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
    .{ .name = "init", .summary = "write a config that describes this machine", .handler = init_cmd.initCmd },
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
        error.MissingFlagValue => {
            try ctx.err.writeAll("os: --config, --root, and --facts need a path\n");
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
        } else if (try valueFlag(ctx, arg, &it)) |_| {
            continue;
        } else {
            try rest.append(ctx.gpa, raw[it.i - 1]);
        }
    }
    return rest.toOwnedSlice(ctx.gpa);
}

/// the global flags that take a path, as `--flag path` or `--flag=path`.
const value_flags = .{
    .{ "--config", "config_path" },
    .{ "--root", "root" },
    .{ "--facts", "facts_path" },
};

/// sets the context field for a global flag with a value. returns null if
/// `arg` isn't one.
fn valueFlag(ctx: *Context, arg: []const u8, it: *ArgIter) !?void {
    inline for (value_flags) |f| {
        if (eql(arg, f[0])) {
            @field(ctx, f[1]) = it.next() orelse return error.MissingFlagValue;
            return {};
        }
        if (std.mem.startsWith(u8, arg, f[0] ++ "=")) {
            @field(ctx, f[1]) = arg[f[0].len + 1 ..];
            return {};
        }
    }
    return null;
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
        \\  --facts <file>   read the machine from a facts file instead
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

pub fn usageError(ctx: *Context, text: []const u8) !u8 {
    try ctx.err.print("usage: {s}\n", .{text});
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
    result: ?pipeline.Result = null,

    pub fn init(ctx: *Context) Work {
        return .{ .ctx = ctx, .arena = .init(ctx.gpa), .diags = .init(ctx.gpa) };
    }

    pub fn deinit(w: *Work) void {
        if (w.loaded) |*l| l.deinit();
        if (w.loaded_state) |*s| s.deinit();
        if (w.result) |*r| r.deinit();
        w.diags.deinit();
        w.arena.deinit();
    }

    pub fn allocator(w: *Work) std.mem.Allocator {
        return w.arena.allocator();
    }

    pub fn failed(w: *const Work) bool {
        return w.diags.items.items.len > 0;
    }

    /// the exit code for a command that couldn't go on: the problems
    /// found are printed now, or already were.
    pub fn fail(w: *const Work) !u8 {
        return if (w.failed()) reportDiags(w.ctx, &w.diags) else 1;
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

    /// the plan for `in`, with the config, lock, and facts it came from,
    /// or null if any of them has problems.
    pub fn plan(w: *Work, in: pipeline.Inputs) !?*pipeline.Result {
        const built = pipeline.buildPlan(w.ctx.gpa, w.ctx.io, w.ctx.files, in, &w.diags) catch |e| {
            try factsError(w.ctx, e, in.facts_path);
            return null;
        };
        w.result = built orelse return null;
        return &w.result.?;
    }
};

/// commits the config directory holding `top`. a failure is worth a
/// warning, not a failed command: the change itself is saved.
pub fn record(ctx: *Context, a: std.mem.Allocator, top: []const u8, message: []const u8) !void {
    const dir = std.fs.path.dirnamePosix(top) orelse ".";
    var why: []const u8 = "";
    if (!try ctx.history.commit(a, dir, message, &why)) {
        try ctx.err.print("os: saved, but couldn't record it in git: {s}\n", .{why});
    }
}

/// facts from --facts, or observed from the machine. observer problems go
/// to `w.diags`; a bad facts file is reported here and returns null.
pub fn facts(w: *Work) !?@import("facts.zig").Facts {
    const ctx = w.ctx;
    return pipeline.getFacts(ctx.files, ctx.io, w.allocator(), ctx.facts_path, ctx.root, &w.diags) catch |e| {
        try factsError(ctx, e, ctx.facts_path);
        return null;
    };
}

/// fails a command that takes no arguments of its own if it got some.
pub fn noArgs(ctx: *Context, args: []const [:0]const u8, usage_text: []const u8) !?u8 {
    return if (args.len == 0) null else try usageError(ctx, usage_text);
}

/// says why facts couldn't be read.
fn factsError(ctx: *Context, e: pipeline.Error, path: ?[]const u8) !void {
    const from = path orelse "this machine";
    switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FactsUnreadable => try ctx.err.print("os: can't read facts from {s}\n", .{from}),
        error.BadFacts => try ctx.err.print("os: {s} isn't a facts document (yoq.facts/1)\n", .{from}),
    }
}

/// the planner inputs for a command, from the global flags: the config
/// path, the machine root, and the facts file if there is one.
pub fn inputs(ctx: *const Context) pipeline.Inputs {
    return .{ .config_path = ctx.config_path, .root = ctx.root, .facts_path = ctx.facts_path };
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
    /// the commits commands made.
    recorder: history.Recorder = .{ .gpa = std.testing.allocator },
    reader: std.Io.Reader = undefined,
    code: u8 = 0,

    pub fn deinit(t: *TestRun) void {
        t.fs.deinit();
        t.recorder.deinit();
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
            .history = t.recorder.history(),
        };
        if (t.input) |text| {
            t.reader = .fixed(text);
            t.ctx.in = &t.reader;
            t.ctx.interactive = true;
        }
        t.code = try run(&t.ctx, args);
    }
};

/// serves the fixture databases the way a mirror would.
pub const FixtureMirror = struct {
    fetched: usize = 0,

    pub fn fetcher(m: *FixtureMirror) sync.Fetcher {
        return .{ .ctx = m, .fetchFn = fetch };
    }

    fn fetch(ctx: *anyopaque, a: std.mem.Allocator, url: []const u8) error{OutOfMemory}!?[]const u8 {
        const m: *FixtureMirror = @ptrCast(@alignCast(ctx));
        const name = std.fs.path.basename(url);
        const path = try std.fmt.allocPrint(a, "tests/alpm/repos/{s}", .{name});
        m.fetched += 1;
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(1 << 20)) catch null;
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
    _ = init_cmd;
    _ = inspect;
    _ = edit;
    _ = update;
    _ = @import("cmd/lock.zig");
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

test "global flags take a value either way" {
    var t: TestRun = .{};
    defer t.deinit();
    try t.exec(&.{ "--root=/r", "--facts", "f.json", "version", "--config=/c.toml" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqualStrings("/r", t.ctx.root);
    try std.testing.expectEqualStrings("f.json", t.ctx.facts_path.?);
    try std.testing.expectEqualStrings("/c.toml", t.ctx.config_path);
    try t.exec(&.{ "version", "--root" });
    try std.testing.expectEqual(2, t.code);
}
