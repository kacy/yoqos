//! lock work shared by the commands that change what's installed:
//! resolving the config into machine.lock (asking for provider choices on
//! the way), reading and writing the lock, and where package databases come
//! from.

const std = @import("std");
const cli = @import("../cli.zig");
const alpm = @import("../alpm.zig");
const config = @import("../config.zig");
const lock = @import("../lock.zig");
const change = @import("../change.zig");
const edit = @import("../edit.zig");
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
    const scratch = try std.fmt.allocPrint(a, "/tmp/os-resolve-{d}", .{std.Io.Timestamp.now(ctx.io, .real).toNanoseconds()});
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
        const settled = try installedChoices(a, choices, installed);
        if (settled.len > 0) {
            if (!try saveProviders(ctx, w, top, settled)) return null;
            in.providers = try std.mem.concat(a, lock.Provider, &.{ in.providers, settled });
            continue;
        }
        if (!ctx.interactive) {
            try alpm.reportChoices(a, choices, &w.diags);
            return null;
        }
        const picked = try askProviders(ctx, a, choices) orelse return null;
        if (!try saveProviders(ctx, w, top, picked)) return null;
        in.providers = try std.mem.concat(a, lock.Provider, &.{ in.providers, picked });
    }
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
    var text: []const u8 = ctx.files.read(a, top) catch {
        try ctx.err.print("os: can't read {s}\n", .{top});
        return false;
    };
    const notes = try a.alloc(change.Note, picked.len);
    for (picked, notes) |p, *n| {
        text = try edit.setProvider(a, text, p.name, p.chosen) orelse text;
        n.* = .{ .name = p.name, .what = .chosen, .detail = p.chosen };
    }
    if (!try change.check(ctx.gpa, ctx.files, top, text, notes, &w.diags)) return false;
    ctx.files.write(top, text) catch {
        try ctx.err.print("os: can't write {s}\n", .{top});
        return false;
    };
    if (!ctx.json) for (picked) |p| try ctx.out.print("+ providers.{s} = \"{s}\"\n", .{ p.name, p.chosen });
    return true;
}

/// the current lock, or null if there isn't a readable one.
pub fn readLock(ctx: *Context, a: Allocator, top: []const u8) !?lock.Lock {
    const path = try lock.pathFor(a, top);
    const bytes = ctx.files.read(a, path) catch return null;
    var ignored: @import("../diag.zig").List = .init(a);
    return lock.parse(a, path, bytes, &ignored);
}

/// writes `l` next to `top`. returns the path, or null after saying why.
pub fn writeLock(ctx: *Context, a: Allocator, top: []const u8, l: *const lock.Lock) !?[]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try lock.write(&out.writer, l);
    const path = try lock.pathFor(a, top);
    ctx.files.write(path, out.written()) catch {
        try ctx.err.print("os: can't write {s}\n", .{path});
        return null;
    };
    return path;
}

/// "<what>: +2 -1. next: os plan, then os apply" after the lock changes.
pub fn reportLock(ctx: *Context, what: []const u8, d: lock.Diff) !void {
    try ctx.out.print("{s}: ", .{what});
    try d.write(ctx.out);
    try ctx.out.writeAll(". next: os plan, then os apply\n");
}

/// the repositories in the machine's pacman.conf, or core and extra from
/// arch's main mirror if there isn't one.
pub fn repos(ctx: *Context, a: Allocator) ![]const sync.Repo {
    return (try pacman(ctx, a)).repos;
}

/// the machine's pacman.conf, as far as `os` uses it.
pub fn pacman(ctx: *Context, a: Allocator) !sync.Pacman {
    return sync.pacmanConf(a, ctx.files, ctx.root);
}

/// where downloaded package databases are kept, one directory per date.
pub fn cacheDir(ctx: *Context, a: Allocator) ![]const u8 {
    return cli.machinePath(ctx, a, "/var/cache/yoq/sync");
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
