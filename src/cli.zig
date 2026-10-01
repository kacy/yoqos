//! command dispatch. `run` takes its writers and args from the caller so
//! tests can drive it without a terminal.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const output = @import("output.zig");
const diag = @import("diag.zig");
const compose = @import("compose.zig");
const pipeline = @import("pipeline.zig");
const facts_mod = @import("facts.zig");
const generation = @import("generation.zig");
const gens = @import("gens.zig");
const observe = @import("observe.zig");
const sync = @import("sync.zig");
const history = @import("history.zig");
const events = @import("events.zig");
const journal = @import("journal.zig");
const progress = @import("progress.zig");
const init_cmd = @import("cmd/init.zig");
const apply_cmd = @import("cmd/apply.zig");
const rollback = @import("cmd/rollback.zig");
const hook = @import("cmd/hook.zig");
const health = @import("cmd/health.zig");
const uninstall = @import("cmd/uninstall.zig");
const build_cmd = @import("cmd/build.zig");
const install_cmd = @import("cmd/install.zig");
const enable_rollback = @import("cmd/enable_rollback.zig");
const inspect = @import("cmd/inspect.zig");
const edit = @import("cmd/edit.zig");
const diff_cmd = @import("cmd/diff.zig");
const doctor = @import("cmd/doctor.zig");
const docs = @import("cmd/docs.zig");
const update = @import("cmd/update.zig");
const events_cmd = @import("cmd/events.zig");
const secret_cmd = @import("cmd/secret.zig");
const schemas = @import("schema.zig");
const secrets = @import("secrets.zig");

pub const default_config = "/etc/yoq/machine.toml";

/// where a repository for several machines keeps `host`'s config.
pub fn hostConfigPath(a: std.mem.Allocator, host: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "/etc/yoq/hosts/{s}/machine.toml", .{host});
}

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
    /// stdin is a terminal, whatever stdout is and --json says. a secret's
    /// value typed there is read without echo.
    in_tty: bool = false,
    /// this process runs under one of os's own transactions, as the drift
    /// hook does then.
    in_own_transaction: bool = false,
    /// where aur recipes are fetched from; YOQ_AUR points it elsewhere, as
    /// tests do.
    aur_url: []const u8 = @import("aur.zig").default_url,
    /// what `os edit` opens the config with: $VISUAL, $EDITOR, or vi.
    editor: []const u8 = "vi",
    /// how package transactions show progress on `err`, unless --json is
    /// set. tests leave it off.
    progress: progress.Mode = .off,
    /// where secrets are kept: the machine's own, always, whatever --root
    /// says, since a root os builds is for this machine too.
    secrets: ?secrets.Store = null,
    /// turns echo on the terminal off and on again, while a secret's
    /// value is typed.
    set_echo: ?*const fn (on: bool) void = null,
};

const Handler = *const fn (ctx: *Context, args: []const [:0]const u8) anyerror!u8;

const Command = struct {
    name: []const u8,
    summary: []const u8,
    handler: Handler,
    /// plumbing for other programs, like the pacman hook, left out of help.
    hidden: bool = false,
};

const commands = [_]Command{
    .{ .name = "help", .summary = "show this help", .handler = help },
    .{ .name = "version", .summary = "print the version", .handler = version },
    .{ .name = "init", .summary = "write a config that describes this machine", .handler = init_cmd.initCmd },
    .{ .name = "status", .summary = "what matches the config, what changed, what's failing", .handler = inspect.statusCmd },
    .{ .name = "plan", .summary = "show what apply would change", .handler = inspect.planCmd },
    .{ .name = "apply", .summary = "make this machine match its config", .handler = apply_cmd.applyCmd },
    .{ .name = "update", .summary = "resolve the config against today's arch packages", .handler = update.updateCmd },
    .{ .name = "add", .summary = "add packages to the config", .handler = edit.addCmd },
    .{ .name = "remove", .summary = "remove packages from the config", .handler = edit.removeCmd },
    .{ .name = "enable", .summary = "turn services on in the config", .handler = edit.enableCmd },
    .{ .name = "disable", .summary = "turn services off in the config", .handler = edit.disableCmd },
    .{ .name = "edit", .summary = "open the config in $EDITOR, check it, and apply it", .handler = edit.editCmd },
    .{ .name = "adopt", .summary = "put packages installed outside os into the config", .handler = edit.adoptCmd },
    .{ .name = "secret", .summary = "keep, list, or remove the values files name with secret", .handler = secret_cmd.secretCmd },
    .{ .name = "rollback", .summary = "go back to an earlier generation", .handler = rollback.rollbackCmd },
    .{ .name = "enable-rollback", .summary = "turn on generations of the whole system (btrfs)", .handler = enable_rollback.enableRollbackCmd },
    .{ .name = "install", .summary = "put the machine a config describes on a blank disk, from a live system", .handler = install_cmd.installCmd },
    .{ .name = "uninstall", .summary = "leave plain arch on the running system, keeping the config", .handler = uninstall.uninstallCmd },
    .{ .name = "doctor", .summary = "check how os is set up here, and say what to fix", .handler = doctor.doctorCmd },
    .{ .name = "gc", .summary = "remove old generations, keeping the newest and pinned ones", .handler = rollback.gcCmd },
    .{ .name = "pin", .summary = "keep a generation through garbage collection", .handler = rollback.pinCmd },
    .{ .name = "history", .summary = "list the generations", .handler = rollback.historyCmd },
    .{ .name = "diff", .summary = "what differs between two generations: packages and config", .handler = diff_cmd.diffCmd },
    .{ .name = "why", .summary = "say which config line brings in a package, file, or unit", .handler = inspect.whyCmd },
    .{ .name = "config", .summary = "show the merged config (config show [--resolved])", .handler = inspect.configCmd },
    .{ .name = "facts", .summary = "show what os knows about this machine", .handler = inspect.factsCmd },
    .{ .name = "build", .summary = "build a root from the config and lock alone, and list what they don't explain here", .handler = build_cmd.buildCmd, .hidden = true },
    .{ .name = "docs", .summary = "print the whole reference, as it came with this os", .handler = docs.docsCmd, .hidden = true },
    .{ .name = "carry", .summary = "carry this machine's state into a generation waiting for the reboot (yoq-carry.service runs this)", .handler = rollback.carryCmd, .hidden = true },
    .{ .name = "health", .summary = "check a generation on trial, at boot (yoq-health.service runs this)", .handler = health.healthCmd, .hidden = true },
    .{ .name = "record-pacman", .summary = "record a pacman transaction (the drift hook runs this)", .handler = hook.recordPacmanCmd, .hidden = true },
    .{ .name = "explain", .summary = "explain an error code, like E0213", .handler = explain },
    .{ .name = "schema", .summary = "print the json schema for the config or a json document", .handler = schemaCmd, .hidden = true },
    .{ .name = "events", .summary = "print what os did here, and pacman outside it, as json lines (--follow for new ones)", .handler = events_cmd.eventsCmd, .hidden = true },
};

/// walks a command's own arguments. after `--`, every argument is a
/// name, even one that starts with `-`, like `os add -- -weird-name`.
pub const ArgIter = struct {
    args: []const [:0]const u8,
    i: usize = 0,
    /// `--` has gone by.
    names_only: bool = false,

    pub fn next(it: *ArgIter) ?[]const u8 {
        if (!it.names_only and it.i < it.args.len and eql(it.args[it.i], "--")) {
            it.names_only = true;
            it.i += 1;
        }
        return it.value();
    }

    /// the next argument as it is, `--` or not: the value of a flag.
    pub fn value(it: *ArgIter) ?[]const u8 {
        if (it.i == it.args.len) return null;
        defer it.i += 1;
        return it.args[it.i];
    }

    /// whether `arg`, from `next`, is a flag rather than a name.
    pub fn isFlag(it: *const ArgIter, arg: []const u8) bool {
        return !it.names_only and std.mem.startsWith(u8, arg, "-");
    }

    /// the rest of a command's arguments when it takes only names, up to
    /// `buf.len` of them. null for a flag, an empty name, or too many.
    pub fn names(it: *ArgIter, buf: [][]const u8) ?[]const []const u8 {
        var n: usize = 0;
        while (it.next()) |arg| : (n += 1) {
            if (it.isFlag(arg) or arg.len == 0 or n == buf.len) return null;
            buf[n] = arg;
        }
        return buf[0..n];
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
    while (it.value()) |arg| {
        // the command sees `--` too, so what follows stays names there.
        if (eql(arg, "--")) {
            try rest.appendSlice(ctx.gpa, raw[it.i - 1 ..]);
            break;
        }
        if (eql(arg, "--json")) {
            ctx.json = true;
        } else if (!try valueFlag(ctx, arg, &it)) {
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

/// sets the context field for a global flag with a value. false if `arg`
/// isn't one.
fn valueFlag(ctx: *Context, arg: []const u8, it: *ArgIter) !bool {
    inline for (value_flags) |f| {
        // a value can't be empty, or another flag.
        if (eql(arg, f[0])) {
            const v = it.value() orelse return error.MissingFlagValue;
            if (v.len == 0 or v[0] == '-') return error.MissingFlagValue;
            @field(ctx, f[1]) = v;
            return true;
        }
        if (std.mem.startsWith(u8, arg, f[0] ++ "=")) {
            if (arg.len == f[0].len + 1) return error.MissingFlagValue;
            @field(ctx, f[1]) = arg[f[0].len + 1 ..];
            return true;
        }
    }
    return false;
}

fn usage(w: *std.Io.Writer) !void {
    try w.writeAll("usage: os <command> [args]\n\ncommands:\n");
    for (commands) |c| {
        if (!c.hidden) try w.print("  {s:<17}{s}\n", .{ c.name, c.summary });
    }
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

fn help(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (try noArgs(ctx, args, "os help")) |code| return code;
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

fn version(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (try noArgs(ctx, args, "os version")) |code| return code;
    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.version/1", .{ .version = build_options.version });
        return 0;
    }
    try ctx.out.print("os {s}\n", .{build_options.version});
    return 0;
}

fn schemaCmd(ctx: *Context, raw: []const [:0]const u8) !u8 {
    var buf: [1][]const u8 = undefined;
    var it: ArgIter = .{ .args = raw };
    const args = it.names(&buf) orelse return usageError(ctx, "os schema [<name>]");
    if (args.len == 0) {
        const Entry = struct { name: []const u8, what: []const u8 };
        var list: [schemas.docs.len]Entry = undefined;
        for (schemas.docs, &list) |d, *e| e.* = .{ .name = d.name, .what = d.what };
        if (ctx.json) {
            try output.writeDoc(ctx.out, "yoq.schemas/1", .{ .schemas = &list });
        } else for (list) |e| try ctx.out.print("{s: <8}{s}\n", .{ e.name, e.what });
        return 0;
    }
    const d = schemas.find(args[0]) orelse return fail(ctx, "there's no schema called {s}. `os schema` lists them.", .{args[0]});
    try d.write(ctx.out);
    return 0;
}

fn explain(ctx: *Context, raw: []const [:0]const u8) !u8 {
    var buf: [1][]const u8 = undefined;
    var it: ArgIter = .{ .args = raw };
    const args = it.names(&buf) orelse return usageError(ctx, "os explain [code]");
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
        if (!w.failed()) return 1;
        // with --json, the problems are the one document on stdout.
        if (w.ctx.json) try w.diags.writeJson(w.ctx.out) else try w.diags.render(w.ctx.err);
        return 1;
    }

    /// facts from --facts, or observed from the machine. null if they
    /// couldn't be read in full: a bad facts file is reported here, and
    /// observer problems are in `diags`.
    pub fn facts(w: *Work) !?facts_mod.Facts {
        const ctx = w.ctx;
        const f = pipeline.getFacts(ctx.files, ctx.io, w.allocator(), ctx.facts_path, .{ .root = ctx.root }, &w.diags) catch |e| {
            try factsError(ctx, e, ctx.facts_path);
            return null;
        };
        return if (w.failed()) null else f;
    }

    /// the running machine's boot facts, when it runs a generation.
    pub fn generations(w: *Work) !?facts_mod.Boot {
        if (!eql(w.ctx.root, "/") or w.ctx.facts_path != null) return null;
        // only how the machine boots: no packages or units to read.
        const f = try observe.observe(w.allocator(), w.ctx.io, .{ .packages = false, .units = false }, &w.diags);
        return if (generation.running(f.boot.root_subvol)) f.boot else null;
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
    switch (try ctx.history.commit(a, dir, message, &why)) {
        .made => try note(ctx, a, .{ .time = journal.now(ctx.io), .kind = .commit, .message = message }),
        .unchanged => {},
        .failed => try ctx.err.print("os: saved, but couldn't record it in git: {s}\n", .{why}),
    }
}

/// adds an event for `os events` to the machine's journal. tests never
/// write the machine they run on.
pub fn note(ctx: *Context, a: std.mem.Allocator, e: events.Event) !void {
    if (builtin.is_test and eql(ctx.root, "/")) return;
    try events.record(a, ctx.io, ctx.root, e);
}

/// writes a file through `ctx.files`. returns false after saying it
/// couldn't.
pub fn writeFile(ctx: *Context, path: []const u8, bytes: []const u8) !bool {
    ctx.files.write(path, bytes) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.WriteFailed => {
            try ctx.err.print("os: can't write {s}\n", .{path});
            return false;
        },
    };
    return true;
}

/// reads a file through `ctx.files`, or null after saying it couldn't.
pub fn readFile(ctx: *Context, a: std.mem.Allocator, path: []const u8) !?[]const u8 {
    return ctx.files.read(a, path) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            try ctx.err.print("os: can't read {s}\n", .{path});
            return null;
        },
    };
}

/// fails a command that takes no arguments of its own if it got some.
pub fn noArgs(ctx: *Context, args: []const [:0]const u8, usage_text: []const u8) !?u8 {
    var it: ArgIter = .{ .args = args };
    return if (it.next() == null) null else try usageError(ctx, usage_text);
}

pub fn isYes(arg: []const u8) bool {
    return eql(arg, "--yes") or eql(arg, "-y");
}

/// says what went wrong, as "os: ...", and returns the exit code for a
/// failed command.
pub fn fail(ctx: *Context, comptime fmt: []const u8, args: anytype) !u8 {
    try ctx.err.print("os: " ++ fmt ++ "\n", args);
    return 1;
}

/// says `why`, if there is one, for commands that can't do anything else.
pub fn refused(ctx: *Context, why: ?[]const u8) !bool {
    try ctx.err.print("os: {s}.\n", .{why orelse return false});
    return true;
}

/// the btrfs top level of a machine with generations, or null after
/// saying why it can't be opened.
pub fn openMachine(ctx: *Context, a: std.mem.Allocator, boot: facts_mod.Boot) !?gens.Machine {
    var why: []const u8 = "";
    return try gens.Machine.open(a, ctx.io, boot, &why) orelse {
        try ctx.err.print("os: {s}\n", .{why});
        return null;
    };
}

pub fn noGenerations(ctx: *Context) !u8 {
    return fail(ctx, "this machine has no generations. `os enable-rollback` turns them on.", .{});
}

pub fn noGeneration(ctx: *Context, n: u32) !u8 {
    return fail(ctx, "there's no generation {d}. `os history` lists them.", .{n});
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
    return .{ .config_path = ctx.config_path, .root = ctx.root, .facts_path = ctx.facts_path, .secrets = ctx.secrets };
}

/// a path under the machine's root, like /etc/pacman.conf.
pub fn machinePath(ctx: *const Context, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ ctx.root, path });
}

/// asks before `what`, unless `yes`. null to go ahead, or the exit code:
/// 2 with no terminal to ask on, 0 when the answer is no.
pub fn approve(ctx: *Context, yes: bool, what: []const u8, question: []const u8) !?u8 {
    if (yes) return null;
    if (!ctx.interactive) {
        try ctx.err.print("os: pass --yes to {s} without a terminal.\n", .{what});
        return 2;
    }
    try ctx.out.writeByte('\n');
    if (try confirm(ctx, question)) return null;
    try ctx.out.writeAll("the machine is as it was.\n");
    return 0;
}

/// commands that change the running machine itself, like its disk and
/// boot menu, need root and no --root. says so and returns true when
/// either is missing. `what` says why, like "uninstall changes the
/// running machine".
pub fn needsHost(ctx: *Context, what: []const u8) !bool {
    if (eql(ctx.root, "/") and std.os.linux.geteuid() == 0) return refused(ctx, lockMachine());
    try ctx.err.print("os: {s}, so it needs root and no --root.\n", .{what});
    return true;
}

/// takes the machine lock before root edits the config or lock, so two
/// runs can't both read the old file and each write over the other.
/// says who has it when another os does.
pub fn lockForEdit(ctx: *Context) ?[]const u8 {
    if (!eql(ctx.root, "/") or std.os.linux.geteuid() != 0) return null;
    return lockMachine();
}

/// where os locks the running machine while it changes it.
const lock_path = "/run/yoq/lock";
var lock_held = false;
var lock_message: [128]u8 = undefined;

/// makes this os the only one changing the running machine, until it
/// exits: the lock goes with the process, however it ends. says who has
/// it when another os does.
pub fn lockMachine() ?[]const u8 {
    const linux = std.os.linux;
    if (lock_held) return null;
    _ = linux.mkdir("/run/yoq", 0o755);
    const opened = linux.open(lock_path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true }, 0o644);
    if (linux.errno(opened) != .SUCCESS) return "can't open " ++ lock_path;
    const fd: linux.fd_t = @intCast(opened);
    const exclusive = 2;
    const nonblocking = 4;
    if (linux.errno(linux.flock(fd, exclusive | nonblocking)) != .SUCCESS) {
        var pid_buf: [32]u8 = undefined;
        const n = linux.read(fd, &pid_buf, pid_buf.len);
        const pid = if (linux.errno(n) == .SUCCESS) std.mem.trim(u8, pid_buf[0..n], " \n") else "";
        _ = linux.close(fd);
        return std.fmt.bufPrint(&lock_message, "another os, process {s}, is changing this machine. wait for it to finish", .{if (pid.len > 0) pid else "?"}) catch "another os is changing this machine";
    }
    // the fd stays open for as long as this process runs.
    _ = linux.ftruncate(fd, 0);
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{linux.getpid()}) catch "";
    _ = linux.write(fd, text.ptr, text.len);
    lock_held = true;
    return null;
}

/// asks for a line of text, with `default` for an empty answer. null at
/// the end of input.
pub fn ask(ctx: *Context, a: std.mem.Allocator, question: []const u8, default: ?[]const u8) !?[]const u8 {
    if (default) |d| try ctx.out.print("{s} [{s}] ", .{ question, d }) else try ctx.out.print("{s} ", .{question});
    const answer = try readAnswer(ctx) orelse return null;
    if (answer.len == 0) return default;
    return try a.dupe(u8, answer);
}

/// asks a yes or no question. anything but y or yes is no.
pub fn confirm(ctx: *Context, question: []const u8) !bool {
    try ctx.out.print("{s} [y/N] ", .{question});
    const answer = try readAnswer(ctx) orelse return false;
    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}

/// asks the user to pick one of `options` and returns its index. empty
/// input picks the first. returns null at the end of input.
pub fn choose(ctx: *Context, question: []const u8, options: []const []const u8) !?usize {
    try ctx.out.print("{s}\n", .{question});
    for (options, 1..) |o, i| try ctx.out.print("  {d}) {s}\n", .{ i, o });
    while (true) {
        try ctx.out.writeAll("pick one [1]: ");
        const answer = try readAnswer(ctx) orelse return null;
        if (answer.len == 0) return 0;
        const n = std.fmt.parseInt(usize, answer, 10) catch 0;
        if (n >= 1 and n <= options.len) return n - 1;
        try ctx.out.print("pick a number from 1 to {d}.\n", .{options.len});
    }
}

/// flushes the question and reads one answer, trimmed. null at the end of
/// input.
fn readAnswer(ctx: *Context) !?[]const u8 {
    try ctx.out.flush();
    const line = ctx.in.?.takeDelimiter('\n') catch return null;
    return std.mem.trim(u8, line orelse return null, " \t\r");
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
    /// or a reader of the test's own for them, which does the same.
    in: ?*std.Io.Reader = null,
    /// stdin from a pipe rather than a terminal: no questions get asked.
    piped: ?[]const u8 = null,
    /// answers downloads. by default every download fails, so no test
    /// touches the network by accident.
    fetcher: ?sync.Fetcher = null,
    /// the commits commands made.
    recorder: history.Recorder = .{ .gpa = std.testing.allocator },
    /// run as if under one of os's own transactions.
    in_own_transaction: bool = false,
    /// the secrets commands see, if any.
    secrets: ?*secrets.Memory = null,
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
            .in_own_transaction = t.in_own_transaction,
            .secrets = if (t.secrets) |m| m.store() else null,
        };
        t.recorder.fs = &t.fs;
        if (t.input) |text| {
            t.reader = .fixed(text);
            t.ctx.in = &t.reader;
            t.ctx.interactive = true;
            t.ctx.in_tty = true;
        }
        if (t.in) |r| {
            t.ctx.in = r;
            t.ctx.interactive = true;
            t.ctx.in_tty = true;
        }
        if (t.piped) |text| {
            t.reader = .fixed(text);
            t.ctx.in = &t.reader;
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

test {
    _ = init_cmd;
    _ = apply_cmd;
    _ = rollback;
    _ = hook;
    _ = health;
    _ = uninstall;
    _ = build_cmd;
    _ = install_cmd;
    _ = enable_rollback;
    _ = inspect;
    _ = edit;
    _ = diff_cmd;
    _ = doctor;
    _ = docs;
    _ = update;
    _ = events_cmd;
    _ = secret_cmd;
    _ = @import("cmd/lock.zig");
    _ = @import("cmd/stage.zig");
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

test "after --, every argument is a name" {
    var it: ArgIter = .{ .args = &.{ "-v", "--", "-x", "--" } };
    try std.testing.expect(it.isFlag(it.next().?));
    for ([_][]const u8{ "-x", "--" }) |want| {
        const arg = it.next().?;
        try std.testing.expectEqualStrings(want, arg);
        try std.testing.expect(!it.isFlag(arg));
    }
    try std.testing.expectEqual(null, it.next());

    var t: TestRun = .{};
    try t.exec(&.{ "explain", "--", "E0213" });
    try std.testing.expectEqual(0, t.code);
    try t.exec(&.{ "explain", "--", "--json" });
    try std.testing.expectEqual(2, t.code);
    try std.testing.expect(!t.ctx.json);
    try t.exec(&.{ "version", "--" });
    try std.testing.expectEqual(0, t.code);
    // a name isn't a flag, so a command without names turns it down.
    try t.exec(&.{ "plan", "--", "-v" });
    try std.testing.expectEqual(2, t.code);
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

test "a config commit is an event, and one with nothing to commit isn't" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/machine.toml", "packages = []\n");
    try t.exec(&.{ "--root", root, "version" });
    try record(&t.ctx, a, "/etc/yoq/machine.toml", "add fd");
    try record(&t.ctx, a, "/etc/yoq/machine.toml", "nothing new");
    var offsets: events.Offsets = @splat(0);
    const got = try events.poll(a, std.testing.io, root, &offsets);
    try std.testing.expectEqual(1, got.len);
    try std.testing.expectEqual(.commit, got[0].kind);
    try std.testing.expectEqualStrings("add fd", got[0].message.?);
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
