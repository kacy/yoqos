//! `os init`: write a config that describes this machine as it is. it
//! changes nothing on the machine; the first `os plan` afterwards should
//! be empty, or show only what's out of date.

const std = @import("std");
const exec = @import("../exec.zig");
const newconfig = @import("../newconfig.zig");
const cli = @import("../cli.zig");
const facts = @import("../facts.zig");
const alpm = @import("../alpm.zig");
const compose = @import("../compose.zig");
const config = @import("../config.zig");
const generate = @import("../generate.zig");
const sync = @import("../sync.zig");
const locking = @import("lock.zig");
const output = @import("../output.zig");
const Context = cli.Context;

pub fn initCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (args.len > 0 and cli.eql(args[0], "--new")) return initNew(ctx, args[1..]);
    if (try cli.noArgs(ctx, args, "os init")) |code| return code;
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const top = ctx.config_path;
    if (try exists(ctx, a, top)) return 1;
    const f = try w.facts() orelse return w.fail();

    const date = try locking.today(ctx.io, a);
    const c = try generate.fromFacts(a, &f);
    // nothing is written unless the config would load.
    try config.validate(&c, &w.diags);
    if (w.failed()) return w.fail();
    const imported = try generate.importedPackages(a, &c, &f);
    const dir = std.fs.path.dirnamePosix(top) orelse ".";
    const imported_path = try std.fs.path.join(a, &.{ dir, "imported.toml" });
    const machine = try generate.machineToml(a, &c, date);
    for ([_][2][]const u8{ .{ imported_path, try generate.importedToml(a, imported, date, null) }, .{ top, machine } }) |file| {
        if (!try cli.writeFile(ctx, file[0], file[1])) return 1;
    }

    // the generated config has to load cleanly, or it's a bug here.
    const loaded = try w.config() orelse return w.fail();

    var enabled: usize = 0;
    for (f.units) |u| enabled += @intFromBool(u.enabled);
    if (!ctx.json) {
        try ctx.out.print("read this machine: {d} explicit packages, {d} enabled units, {d} users", .{ explicitCount(&f), enabled, people(&f) });
        if (f.cpu) |cpu| try ctx.out.print(", {s} cpu", .{cpu});
        if (c.hardware.gpu) |g| try ctx.out.print(", {s} gpu", .{@tagName(g.v)});
        try ctx.out.print(".\n\nwrote {s}\nwrote {s}  ({d} packages)\n", .{ top, imported_path, imported.len });
    }

    const locked = try lockNew(ctx, &w, loaded, date, f.packages);
    // with a lock, the imported packages can be grouped by repository.
    if (locked != null) {
        if (try locking.readLock(ctx, a, top)) |l| {
            if (!try cli.writeFile(ctx, imported_path, try generate.importedToml(a, imported, date, &l))) return 1;
        }
    }
    try cli.record(ctx, a, top, try std.fmt.allocPrint(a, "init: {s} as found on {s}", .{ f.hostname orelse "this machine", date }));
    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.init/1", .{
            .config = top,
            .imported = imported_path,
            .imported_packages = imported.len,
            .lock = locked,
        });
        return 0;
    }
    if (locked) |path| try ctx.out.print("wrote {s}\n", .{path});
    try ctx.out.writeAll("\nnothing on this machine changed. next: os plan\n");
    return 0;
}

/// whether there's a config at `top` already, after saying so: init never
/// writes over one.
fn exists(ctx: *Context, a: std.mem.Allocator, top: []const u8) !bool {
    _ = ctx.files.read(a, top) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return false,
    };
    _ = try cli.fail(ctx, "{s} already exists. edit it, or move it away to start over.", .{top});
    return true;
}

/// resolves a first lock against today's databases when this build can.
/// returns the lock's path, or null after saying why there isn't one.
fn lockNew(ctx: *Context, w: *cli.Work, loaded: *const compose.Loaded, date: []const u8, installed: []const facts.Package) !?[]const u8 {
    const a = w.allocator();
    if (!alpm.available) {
        if (!ctx.json) try ctx.out.writeAll("this build can't resolve packages, so there's no machine.lock yet.\n");
        return null;
    }
    const top = loaded.files.items[0];
    const dbs = try sync.databases(a, ctx.io, ctx.fetcher, try locking.repos(ctx, a, &loaded.config), try locking.cacheDir(ctx, a), date, &w.diags) orelse return reportLater(ctx, w);
    const l = try locking.resolveLock(ctx, w, &loaded.config, top, dbs, date, installed) orelse return reportLater(ctx, w);
    return locking.writeLock(ctx, a, top, &l);
}

/// the lock is a separate step; its problems are worth showing, but the
/// config is written and init still worked. under --json they go to
/// stderr, since stdout gets the init document.
fn reportLater(ctx: *Context, w: *cli.Work) !?[]const u8 {
    try w.diags.render(ctx.err);
    w.diags.items.clearRetainingCapacity();
    if (!ctx.json) try ctx.out.writeAll("no machine.lock yet: fix the above, then `os update`.\n");
    return null;
}

fn people(f: *const facts.Facts) usize {
    var n: usize = 0;
    for (f.users) |u| n += @intFromBool(u.person());
    return n;
}

fn explicitCount(f: *const facts.Facts) usize {
    var n: usize = 0;
    for (f.packages) |p| n += @intFromBool(p.reason == .explicit);
    return n;
}

/// `os init --new`: a config for a machine with nothing on it yet, like one
/// booted from the live iso, from a few answers and the hardware the live
/// system sees. `os install` builds the machine from it.
fn initNew(ctx: *Context, args: []const [:0]const u8) !u8 {
    const usage_text = "os init --new [--hostname <name>] [--user <name>] [--timezone <zone>] [--ssh]";
    var hostname: ?[]const u8 = null;
    var user: ?[]const u8 = null;
    var timezone: ?[]const u8 = null;
    var ssh = false;
    var it: cli.ArgIter = .{ .args = args };
    while (it.next()) |arg| {
        if (cli.eql(arg, "--hostname")) {
            hostname = it.next() orelse return cli.usageError(ctx, usage_text);
        } else if (cli.eql(arg, "--user")) {
            user = it.next() orelse return cli.usageError(ctx, usage_text);
        } else if (cli.eql(arg, "--timezone")) {
            timezone = it.next() orelse return cli.usageError(ctx, usage_text);
        } else if (cli.eql(arg, "--ssh")) {
            ssh = true;
        } else return cli.usageError(ctx, usage_text);
    }
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const top = ctx.config_path;
    if (try exists(ctx, a, top)) return 1;
    const f = try w.facts() orelse return w.fail();
    const name = try answer(ctx, a, hostname, "a name for the machine:", null, hostnameProblem) orelse return 2;
    const person = try answer(ctx, a, user, "your user name:", null, userProblem) orelse return 2;
    const zone = try answer(ctx, a, timezone, "time zone:", f.timezone orelse "UTC", zoneProblem) orelse return 2;
    const virtual = try exec.run(a, ctx.io, &.{ "systemd-detect-virt", "-q" }) == null;
    const text = try newconfig.machineToml(a, .{
        .hostname = name,
        .user = person,
        .timezone = zone,
        .cpu = if (f.cpu) |c| (if (std.mem.eql(u8, c, "amd") or std.mem.eql(u8, c, "intel")) c else null) else null,
        .gpu = newconfig.gpuChoice(f.gpus),
        .firmware = !virtual,
        .ssh = ssh,
    });
    if (!try cli.writeFile(ctx, top, text)) return 1;
    // it has to load, or it's a bug here.
    _ = try w.config() orelse return w.fail();
    try cli.record(ctx, a, top, try std.fmt.allocPrint(a, "init: {s}, new", .{name}));
    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.init/1", .{ .config = top, .new = true });
        return 0;
    }
    try ctx.out.print("\nwrote {s}, for {s}. it has no lock yet: `os install {s} --disk <disk> --update` makes one and installs it.\n", .{ top, name, std.fs.path.dirnamePosix(top) orelse "." });
    return 0;
}

/// a flag's value, or the answer to `question` at a terminal, asked again
/// until `problem` finds none. null after saying why when there's no
/// terminal to ask at.
fn answer(ctx: *Context, a: std.mem.Allocator, given: ?[]const u8, question: []const u8, default: ?[]const u8, comptime problem: fn ([]const u8) ?[]const u8) !?[]const u8 {
    if (given) |g| {
        if (problem(g)) |why| {
            try ctx.err.print("os: \"{s}\": {s}\n", .{ g, why });
            return null;
        }
        return g;
    }
    if (!ctx.interactive) {
        try ctx.err.writeAll("os: without a terminal to ask at, `os init --new` needs --hostname, --user, and --timezone.\n");
        return null;
    }
    while (true) {
        const got = try cli.ask(ctx, a, question, default) orelse return null;
        const why = problem(got) orelse return got;
        try ctx.out.print("  {s}\n", .{why});
    }
}

fn hostnameProblem(v: []const u8) ?[]const u8 {
    return config.systemProblem("hostname", v);
}

fn userProblem(v: []const u8) ?[]const u8 {
    return if (config.validUserName(v)) null else "a user name is lowercase letters, digits, - and _, starting with a letter";
}

fn zoneProblem(v: []const u8) ?[]const u8 {
    return config.systemProblem("timezone", v);
}

// -- tests --

const TestRun = cli.TestRun;

test "init writes a config that loads, and refuses to overwrite one" {
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("f.json",
        \\{"schema":"yoq.facts/1","hostname":"atlas.lan","timezone":"UTC","cpu":"intel",
        \\ "packages":[{"name":"base","version":"3"},{"name":"linux","version":"6"},{"name":"intel-ucode","version":"1"},
        \\             {"name":"git","version":"2"},{"name":"glibc","version":"2","reason":"dependency"}],
        \\ "units":[{"name":"sshd.service","enabled":true,"active":true}],
        \\ "users":[{"name":"kacy","uid":1000,"shell":"/bin/bash","primary_group":"kacy","groups":["wheel"]}]}
    );
    try t.exec(&.{ "--facts", "f.json", "init" });
    // with libalpm, init also tries to lock, and this test is offline.
    if (!alpm.available) try std.testing.expectEqualStrings("", t.err.buffered());
    try std.testing.expectEqual(0, t.code);
    try std.testing.expect(std.mem.startsWith(u8, t.out.buffered(), "read this machine: 4 explicit packages, 1 enabled units, 1 users, intel cpu.\n"));

    const imported = t.fs.get("/etc/yoq/imported.toml").?;
    try std.testing.expect(std.mem.indexOf(u8, imported, "  \"base\",\n  \"git\",\n]") != null);
    const machine = t.fs.get("/etc/yoq/machine.toml").?;
    try std.testing.expect(std.mem.indexOf(u8, machine, "[services.ssh]\nenabled = true\n") != null);
    try std.testing.expect(std.mem.startsWith(u8, t.recorder.messages.items[0], "init: atlas.lan as found on "));

    try t.exec(&.{ "--facts", "f.json", "init" });
    try std.testing.expectEqual(1, t.code);
    try std.testing.expectEqualStrings("os: /etc/yoq/machine.toml already exists. edit it, or move it away to start over.\n", t.err.buffered());
}

test "init locks against today's databases" {
    if (!alpm.available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);

    var mirror: cli.FixtureMirror = .{};
    var t: TestRun = .{ .fetcher = mirror.fetcher() };
    defer t.deinit();
    try t.fs.put(try std.fs.path.join(a, &.{ root, "etc/pacman.conf" }), "[core]\nServer = https://m.example/$repo\n[extra]\nServer = https://m.example/$repo\n");
    try t.fs.put("f.json",
        \\{"schema":"yoq.facts/1","hostname":"atlas",
        \\ "packages":[{"name":"linux","version":"6.16.8.arch1-1"},{"name":"git","version":"2.51.0-1"}]}
    );
    try t.exec(&.{ "--root", root, "--facts", "f.json", "init" });
    try std.testing.expectEqualStrings("", t.err.buffered());
    try std.testing.expect(std.mem.indexOf(u8, t.out.buffered(), "wrote /etc/yoq/machine.lock\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.fs.get("/etc/yoq/machine.lock").?, "[packages.perl-error]") != null);
}
