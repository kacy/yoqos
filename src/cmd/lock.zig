//! lock work shared by the commands that change what's installed:
//! resolving the config into machine.lock (asking for provider choices on
//! the way), reading and writing the lock, and where package databases come
//! from.

const std = @import("std");
const lists = @import("../lists.zig");
const cli = @import("../cli.zig");
const alpm = @import("../alpm.zig");
const aur = @import("../aur.zig");
const config = @import("../config.zig");
const lock = @import("../lock.zig");
const change = @import("../change.zig");
const edit = @import("../edit.zig");
const diag = @import("../diag.zig");
const facts = @import("../facts.zig");
const planner = @import("../planner.zig");
const sync = @import("../sync.zig");
const Context = cli.Context;
const Allocator = std.mem.Allocator;

/// resolves the config into a lock against `dbs`, asking for provider
/// choices when someone is there to answer and saving them to `top`. a
/// choice with exactly one option in `installed` is the machine's own
/// answer, and is saved without asking. returns null, with reasons in
/// `w.diags`, when it can't.
pub fn resolveLock(ctx: *Context, w: *cli.Work, c: *const config.Config, top: []const u8, dbs: []const alpm.SyncDb, sync_date: []const u8, installed: []const facts.Package) !?lock.Lock {
    const a = w.allocator();
    const scratch = try scratchDir(ctx, w) orelse return null;
    defer std.Io.Dir.cwd().deleteTree(ctx.io, scratch) catch {};

    var in = try resolveInput(a, c);
    in.dbs = dbs;
    in.sync_date = sync_date;
    in.scratch = scratch;

    // each round of choices can surface new ones, since a picked provider
    // brings its own dependencies.
    while (true) {
        const choices = switch (try alpm.resolve(a, ctx.io, in, &w.diags)) {
            .lock => |l| return l,
            .failed => return null,
            .choose => |choices| choices,
        };
        // what's installed already answers a choice; otherwise ask.
        const settled = try installedChoices(a, choices, installed);
        const picked = if (settled.len > 0) settled else if (ctx.interactive) try askProviders(ctx, a, choices) orelse return null else {
            try alpm.reportChoices(a, choices, &w.diags);
            return null;
        };
        if (!try saveProviders(ctx, w, top, picked)) return null;
        in.providers = try std.mem.concat(a, lock.Provider, &.{ in.providers, picked });
    }
}

/// the names among `names` that nothing in `dbs` is called or provides.
/// null, with reasons in `w.diags`, if the databases can't be read.
pub fn unsatisfied(ctx: *Context, w: *cli.Work, dbs: []const alpm.SyncDb, names: []const []const u8) !?[]const []const u8 {
    const a = w.allocator();
    const scratch = try scratchDir(ctx, w) orelse return null;
    defer std.Io.Dir.cwd().deleteTree(ctx.io, scratch) catch {};
    return alpm.unsatisfied(a, ctx.io, .{ .dbs = dbs, .wants = names, .sync_date = "", .scratch = scratch }, &w.diags);
}

/// a new directory for libalpm's scratch root, or null with the reason in
/// `w.diags`.
fn scratchDir(ctx: *Context, w: *cli.Work) !?[]const u8 {
    const a = w.allocator();
    const scratch = try std.fmt.allocPrintSentinel(a, "/tmp/yos-resolve-{d}", .{std.Io.Timestamp.now(ctx.io, .real).toNanoseconds()}, 0);
    // made fresh and private: one someone else made first could hold
    // symlinks that the writes into it would follow.
    if (std.os.linux.errno(std.os.linux.mkdir(scratch, 0o700)) != .SUCCESS) {
        try w.diags.add(.alpm_failed, null, "can't make a scratch directory for resolving at {s}", .{scratch}, null);
        return null;
    }
    return scratch;
}

/// what the config asks the resolver for: its wanted packages and provider
/// choices. the caller fills in the databases, date, and scratch space.
fn resolveInput(a: Allocator, c: *const config.Config) !alpm.ResolveInput {
    const ws = try planner.wants(a, c);
    const names = try a.alloc([]const u8, ws.len);
    for (ws, names) |w, *n| n.* = w.name;
    const providers = try a.alloc(lock.Provider, c.providers.entries.items.len);
    for (c.providers.entries.items, providers) |e, *p| p.* = .{ .name = e.name, .chosen = e.value.v };
    return .{ .dbs = &.{}, .wants = names, .providers = providers, .sync_date = "", .scratch = "" };
}

/// the choices that exactly one installed package answers.
fn installedChoices(a: Allocator, choices: []const alpm.Choice, installed: []const facts.Package) ![]const lock.Provider {
    var out: std.ArrayList(lock.Provider) = .empty;
    for (choices) |ch| {
        var found: ?[]const u8 = null;
        var count: usize = 0;
        for (ch.options) |o| {
            for (installed) |p| {
                if (!std.mem.eql(u8, p.name, o)) continue;
                found = o;
                count += 1;
            }
        }
        if (count == 1) try out.append(a, .{ .name = ch.name, .chosen = found.? });
    }
    return out.items;
}

fn askProviders(ctx: *Context, a: Allocator, choices: []const alpm.Choice) !?[]const lock.Provider {
    const picked = try a.alloc(lock.Provider, choices.len);
    for (choices, picked) |ch, *p| {
        const q = try std.fmt.allocPrint(a, "{s} has more than one provider:", .{ch.name});
        const i = try cli.choose(ctx, q, ch.options) orelse return null;
        p.* = .{ .name = ch.name, .chosen = ch.options[i] };
    }
    return picked;
}

/// writes provider picks into `[providers]` of the top config file, so the
/// question isn't asked again.
fn saveProviders(ctx: *Context, w: *cli.Work, top: []const u8, picked: []const lock.Provider) !bool {
    const a = w.allocator();
    var text: []const u8 = try cli.readFile(ctx, a, top) orelse return false;
    const notes = try a.alloc(change.Note, picked.len);
    for (picked, notes) |p, *n| {
        text = try edit.setProvider(a, text, p.name, p.chosen) orelse text;
        n.* = .{ .name = p.name, .what = .chosen, .detail = p.chosen };
    }
    if (!try change.check(ctx.gpa, ctx.files, top, text, null, notes, &w.diags)) return false;
    if (!try cli.writeFile(ctx, top, text)) return false;
    if (!ctx.json) for (picked) |p| try ctx.out.print("+ providers.{s} = \"{s}\"\n", .{ p.name, p.chosen });
    // a choice is kept, and committed, whatever happens after it.
    try cli.record(ctx, a, top, "choose providers");
    return true;
}

/// the recipe commit each aur package was built from, by package name.
pub const Recipes = std.StringHashMapUnmanaged([]const u8);

/// gives each package from yos's aur repository its recipe commit: the one
/// it was just built from, or else the one the old lock has for it.
pub fn pinRecipes(a: Allocator, l: *lock.Lock, built: Recipes, old: ?*const lock.Lock) !void {
    const pkgs = try a.dupe(lock.Package, l.packages);
    for (pkgs) |*p| {
        if (!std.mem.eql(u8, p.repo, aur.repo_name)) continue;
        p.recipe = built.get(p.name) orelse if (old) |o| if (o.package(p.name)) |op| op.recipe else null else null;
    }
    l.packages = pkgs;
}

/// the current lock, or null if there isn't a readable one. a lock that
/// doesn't parse is treated as missing, with a warning: it's generated,
/// so resolving a new one replaces it.
pub fn readLock(ctx: *Context, a: Allocator, top: []const u8) !?lock.Lock {
    const path = try lock.pathFor(a, top);
    const bytes = ctx.files.read(a, path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    var ignored: diag.List = .init(a);
    return try lock.parse(a, path, bytes, &ignored) orelse {
        try ctx.err.print("yos: {s} doesn't parse, so it's treated as missing. `yos plan` says what's wrong with it.\n", .{path});
        return null;
    };
}

/// writes `l` next to `top`. returns the path, or null after saying why.
pub fn writeLock(ctx: *Context, a: Allocator, top: []const u8, l: *const lock.Lock) !?[]const u8 {
    return writeLockTo(ctx, a, try lock.pathFor(a, top), l);
}

/// writes `l` to `path`. returns the path, or null after saying why.
pub fn writeLockTo(ctx: *Context, a: Allocator, path: []const u8, l: *const lock.Lock) !?[]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try lock.write(&out.writer, l);
    return if (try cli.writeFile(ctx, path, out.written())) path else null;
}

/// "<what>: +2 -1." after the lock changes, then what's next unless
/// applying follows right away.
pub fn reportLock(ctx: *Context, what: []const u8, d: lock.Diff, next: bool) !void {
    try ctx.out.print("{s}: ", .{what});
    try d.write(ctx.out);
    try ctx.out.writeAll(if (next) ". next: yos plan, then yos apply\n" else ".\n");
}

/// the repositories in the machine's pacman.conf, or core and extra from
/// arch's main mirror if there isn't one.
pub fn repos(ctx: *Context, a: Allocator, c: *const config.Config) ![]const sync.Repo {
    return (try pacman(ctx, a, c)).repos;
}

/// the machine's pacman.conf, as far as `yos` uses it, with the config's
/// own repositories after arch's: the ones pacman.conf doesn't list yet,
/// before an apply writes them there.
pub fn pacman(ctx: *Context, a: Allocator, c: *const config.Config) !sync.Pacman {
    var p = try sync.pacmanConf(a, ctx.files, ctx.root);
    var all: std.ArrayList(sync.Repo) = .empty;
    // yos's aur repository, which pacman.conf may name through yos's own
    // file, is always the local one below, when there's one at all.
    for (p.repos) |r| {
        if (!std.mem.eql(u8, r.name, aur.repo_name)) try all.append(a, r);
    }
    for (c.repos.entries.items) |e| {
        const server = e.value.server orelse continue;
        if (lists.find(all.items, "name", e.name) != null) continue;
        try all.append(a, .{ .name = e.name, .servers = try a.dupe([]const u8, &.{server.v}), .signed = e.value.key != null });
    }
    // aur packages come from the local repository yos builds them into.
    if (c.aur.items.items.len > 0) {
        const dir = try cli.machinePath(ctx, a, aur.repo_dir);
        try all.append(a, .{ .name = aur.repo_name, .servers = try a.dupe([]const u8, &.{try std.fmt.allocPrint(a, "file://{s}", .{dir})}), .signed = false, .local = true });
    }
    p.repos = all.items;
    return p;
}

/// where downloaded package databases are kept, one directory per date.
pub fn cacheDir(ctx: *Context, a: Allocator) ![]const u8 {
    return cli.machinePath(ctx, a, "/var/cache/yos/sync");
}

/// today's date as yyyy-mm-dd, in utc.
pub fn today(io: std.Io, a: Allocator) ![]const u8 {
    const secs: u64 = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());
    const day = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = day.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 });
}

// -- tests --

test "a choice with one installed option is already answered" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const choices = [_]alpm.Choice{
        .{ .name = "initramfs", .options = &.{ "mkinitcpio", "booster", "dracut" } },
        .{ .name = "java-runtime", .options = &.{ "jre-openjdk", "jre17-openjdk" } },
        .{ .name = "dhcp-client", .options = &.{ "dhclient", "dhcpcd" } },
    };
    const installed = [_]facts.Package{
        .{ .name = "booster", .version = "1" },
        .{ .name = "jre-openjdk", .version = "24" },
        .{ .name = "jre17-openjdk", .version = "17" },
    };
    const got = try installedChoices(arena.allocator(), &choices, &installed);
    // java-runtime has two installed, so it still needs asking.
    try std.testing.expectEqual(1, got.len);
    try std.testing.expectEqualStrings("initramfs", got[0].name);
    try std.testing.expectEqualStrings("booster", got[0].chosen);
}
