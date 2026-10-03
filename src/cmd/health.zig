//! `os health`: runs at boot from yoq-health.service. when a generation
//! is on trial and this boot runs it, it checks the machine came up
//! healthy: systemd isn't in maintenance or on its way down, the display
//! manager is up if there is one, and every service the config turns on is
//! running. healthy makes it the default; unhealthy reboots into the
//! generation before, which is still the default.

const std = @import("std");
const rootfs = @import("../rootfs.zig");
const cli = @import("../cli.zig");
const exec = @import("../exec.zig");
const config = @import("../config.zig");
const lists = @import("../lists.zig");
const facts = @import("../facts.zig");
const generation = @import("../generation.zig");
const gens = @import("../gens.zig");
const trial = @import("../trial.zig");
const menu = @import("../menu.zig");
const rollback = @import("rollback.zig");
const journal = @import("../journal.zig");
const pipeline = @import("../pipeline.zig");
const Context = cli.Context;
const Allocator = std.mem.Allocator;

pub fn healthCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (try cli.noArgs(ctx, args, "os health")) |code| return code;
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const boot = try w.generations() orelse return 0;
    // the boot finished, so a trial's watchdog stands down. this runs on
    // every boot, so a stray one can't reboot a healthy machine.
    _ = try exec.run(a, ctx.io, &.{ "systemctl", "stop", "yoq-watchdog.timer" });
    // someone may run os as soon as they log in. ending a trial, falling
    // back, or settling a kernel waits for that to finish, rather than
    // both writing the menu and records at once.
    if (try cli.refused(ctx, cli.waitForMachine(ctx))) return 1;
    try rollback.finishRestore(ctx, a, boot);
    const store = trial.Store.of(a, ctx.io, boot) orelse return 0;
    const t = try store.current() orelse {
        try ctx.out.writeAll("no generation on trial.\n");
        // a staged root that booted without a trial settles now.
        if (try settleBoot(ctx, a, boot)) |why| try ctx.err.print("os: {s}\n", .{why});
        return 0;
    };
    const record = generation.find(try gens.readRecords(a, ctx.io, "/var"), t.n) orelse {
        // a trial whose generation is gone can't be judged; end it.
        _ = try store.end();
        return 0;
    };
    // a power cut stopped os partway: after the trial passed, or before
    // it was armed.
    if (t.phase == .passed) return finishPass(ctx, a, store, boot, record, false);
    const on_trial_root = std.mem.eql(u8, boot.root_subvol.?[1..], record.root);
    if (t.phase == .arming and !on_trial_root) return rearm(ctx, a, store, boot, t, record);
    if (!on_trial_root) {
        // an older entry picked by hand before the trial ran isn't a
        // failed trial: the next boot tries it again.
        if (!t.tried) {
            _ = try store.retry();
            try ctx.out.print("generation {d} hasn't been tried yet; the next boot tries it.\n", .{t.n});
            return 0;
        }
        // a trial os never noted, only grub's env file on the esp, could
        // be anyone's who can write there. falling back would make this
        // boot's generation the newest, config and all, for good.
        if (!t.noted) {
            _ = try store.end();
            try ctx.err.print("os: grub's env file on the esp says generation {d} is on trial, but os never armed one. the trial is ended, and nothing rolls back. `os rollback --to-booted` keeps the generation this boot runs.\n", .{t.n});
            return 1;
        }
        return fellBack(ctx, a, store, boot, t.n);
    }

    const problems = try check(ctx, a, try trialInputs(ctx, a, record));
    if (problems.len == 0) {
        // noted first: the default moves in more than one step, and a
        // power cut between them mustn't look like a failed trial.
        if (try store.pass()) |why| try ctx.err.print("os: couldn't note that generation {d} passed: {s}\n", .{ t.n, why });
        return finishPass(ctx, a, store, boot, record, true);
    }
    try ctx.out.print("generation {d} isn't healthy: {s}. going back to the generation before.\n", .{ t.n, try std.mem.join(a, "; ", problems) });
    // a trial that was never armed may still be the default, so it's
    // armed first, and the next boot tries it once more before it falls
    // back.
    if (t.phase == .arming) _ = try rearm(ctx, a, store, boot, t, record);
    // the trial stays marked, so the boot that falls back knows why.
    try ctx.out.flush();
    _ = try exec.run(a, ctx.io, &.{ "systemctl", "reboot" });
    return 1;
}

/// the trial passed: grub.cfg's default and the bootloader's choices
/// move to it, and the trial ends. `fresh` is false when an earlier boot
/// passed it and a power cut stopped os before it finished, and this boot
/// may run another generation.
fn finishPass(ctx: *Context, a: Allocator, store: trial.Store, boot: facts.Boot, record: generation.Record, fresh: bool) !u8 {
    const head = try std.fmt.allocPrint(a, "/{s}", .{record.root});
    if (try headDefault(ctx, a, boot, head)) |why| try ctx.err.print("os: generation {d} is healthy, but couldn't make it grub.cfg's default: {s}. `os gc` writes the menu again.\n", .{ record.n, why });
    if (try store.end()) |why| return cli.fail(ctx, "generation {d} is healthy, but couldn't make it the default: {s}", .{ record.n, why });
    const on_it = std.mem.eql(u8, boot.root_subvol.?, head);
    if (fresh) {
        try cli.note(ctx, a, .{ .time = journal.now(ctx.io), .kind = .trial, .step = .passed, .generation = record.n });
        try ctx.out.print("generation {d} came up healthy. it's the default now.\n", .{record.n});
    } else if (on_it) {
        try ctx.out.print("generation {d} came up healthy before the machine went down. it's the default now.\n", .{record.n});
    } else {
        // its boot files settle when it runs, at the next boot.
        try ctx.out.print("generation {d} came up healthy, but the machine went down before it was the default. it is now; reboot to run it.\n", .{record.n});
        return 0;
    }
    if (try settleBoot(ctx, a, boot)) |why| try ctx.err.print("os: {s}\n", .{why});
    return 0;
}

/// a trial whose note went in, but whose bootloader setup a power cut may
/// have stopped: the menu that holds the default on its fallback is
/// written again, and the trial is armed, so the next boot tries it.
fn rearm(ctx: *Context, a: Allocator, store: trial.Store, boot: facts.Boot, t: trial.Trial, record: generation.Record) !u8 {
    const records = try gens.readRecords(a, ctx.io, "/var");
    const fallback = generation.find(records, t.fallback) orelse {
        _ = try store.end();
        try ctx.err.print("os: generation {d}'s trial was never set up, and the generation it falls back to, {d}, is gone. it's ended; the next boot runs {d}.\n", .{ t.n, t.fallback, t.n });
        return 1;
    };
    var why: []const u8 = "";
    const m = try gens.Machine.open(a, ctx.io, boot, &why) orelse return cli.fail(ctx, "generation {d}'s trial was never set up, and can't be now: {s}", .{ t.n, why });
    defer m.close();
    const head = try std.fmt.allocPrint(a, "/{s}", .{record.root});
    if (try m.writeMenuHolding(head, records, t.fallback)) |w| return cli.fail(ctx, "generation {d}'s trial was never set up, and the menu for it can't be written: {s}", .{ t.n, w });
    if (try store.arm(t.n, fallback)) |w| return cli.fail(ctx, "generation {d}'s trial was never set up, and can't be now: {s}", .{ t.n, w });
    try ctx.out.print("generation {d}'s trial wasn't set up before the machine went down. the next boot tries it once; if it doesn't come up healthy, the machine goes back to generation {d}.\n", .{ t.n, t.fallback });
    return 0;
}

/// the trial didn't come up healthy, and this boot runs the generation
/// before it, from its copy. that becomes the newest generation, with its
/// config, the trial ends, and a notice says what happened. a fallback a
/// power cut stopped after it made its generation isn't made twice: the
/// trial just ends.
fn fellBack(ctx: *Context, a: Allocator, store: trial.Store, boot: facts.Boot, tried: u32) !u8 {
    const running = boot.root_subvol.?;
    const n = generation.bootCopyOf(running) orelse 0;
    const records = try gens.readRecords(a, ctx.io, "/var");
    const target = generation.find(records, n) orelse {
        try ctx.err.print("os: generation {d} didn't start, and this boot isn't one os knows ({s}).\n", .{ tried, running });
        _ = try store.end();
        return 1;
    };
    const reason = try std.fmt.allocPrint(a, "fell back from {d} to {d}", .{ tried, n });
    if (generation.made(records, tried, reason)) |made| {
        if (try store.end()) |why| try ctx.err.print("os: couldn't end generation {d}'s trial: {s}\n", .{ tried, why });
        return fellBackNotice(ctx, a, tried, n, made);
    }
    try cli.note(ctx, a, .{ .time = journal.now(ctx.io), .kind = .trial, .step = .failed, .generation = tried });
    var left: std.ArrayList([]const u8) = .empty;
    const m = try rollback.openWayBack(ctx, a, boot, &left) orelse return 1;
    defer m.close();
    const made = try rollback.startFrom(ctx, a, &m, boot, target, running, reason) orelse return 1;
    try rollback.warnUnsigned(ctx, a, left.items);
    return fellBackNotice(ctx, a, tried, n, made);
}

fn fellBackNotice(ctx: *Context, a: Allocator, tried: u32, n: u32, made: u32) !u8 {
    const notice = try std.fmt.allocPrint(a, "generation {d} didn't come up healthy, so this machine went back to generation {d}. it's generation {d} now, with its config. `os rollback {d}` tries {d} again.\n", .{ tried, n, made, tried, tried });
    if (try gens.writeNotice(a, ctx.io, notice)) |why| try ctx.err.print("os: {s}\n", .{why});
    try ctx.out.writeAll(notice);
    return 1;
}

/// grub.cfg's own default, for a generation that passed its trial: the
/// menu that recorded it kept the generation before as the default (see
/// gens.Machine.writeMenuHolding), which the trial's env file overrode
/// while it lasted. it's written before the trial ends, so a power cut in
/// between still leaves the trial's fallback as the default. the other
/// bootloaders keep the default outside their menu, where ending the trial
/// moves it. `head` is the trial's root, which the boot finishing this may
/// not run.
fn headDefault(ctx: *Context, a: Allocator, boot: facts.Boot, head: []const u8) !?[]const u8 {
    if (menu.Loader.of(boot) != .grub) return null;
    var why: []const u8 = "";
    const m = try gens.Machine.open(a, ctx.io, boot, &why) orelse return why;
    defer m.close();
    return m.writeMenu(head, try gens.readRecords(a, ctx.io, "/var"));
}

/// with /boot as the esp, a generation that was staged booted its kernel
/// from its own root. now that it's good, its kernel goes on the esp, where
/// the menu's first entry boots it from again. the note that it was staged
/// goes either way; a root that isn't running, after a fallback, no longer
/// needs it.
fn settleBoot(ctx: *Context, a: Allocator, boot: facts.Boot) !?[]const u8 {
    const note = std.Io.Dir.cwd().readFileAlloc(ctx.io, generation.unsettled_path, a, .limited(256)) catch return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, note, " \n"), boot.root_subvol.?)) {
        std.Io.Dir.cwd().deleteFile(ctx.io, generation.unsettled_path) catch {};
        return null;
    }
    // the note stays until the kernel is on the esp, so a boot where that
    // failed tries again.
    var why: []const u8 = "";
    const m = try gens.Machine.open(a, ctx.io, boot, &why) orelse return why;
    defer m.close();
    const running = boot.root_subvol.?;
    if (m.bootOnEsp()) switch (try m.restoreBoot(running)) {
        .done => {},
        .failed => |w| return w,
        .full => |w| {
            const text = try std.fmt.allocPrint(a, "the running generation's boot files don't fit on the esp, so it boots the kernel in its own root until they do. {s}. the next boot tries again.", .{w});
            if (try gens.writeNotice(a, ctx.io, try std.fmt.allocPrint(a, "{s}\n", .{text}))) |problem| return problem;
            return text;
        },
    };
    // gone before the menu is written: while it's there, the menu's first
    // entry boots the kernel in the root.
    std.Io.Dir.cwd().deleteFile(ctx.io, generation.unsettled_path) catch {};
    if (m.bootOnEsp()) {
        if (try m.writeMenu(running, try gens.readRecords(a, ctx.io, "/var"))) |w| return w;
    }
    return null;
}

/// what to judge a trial by: the config and lock its generation was made
/// with, from the config's history, or the config as it is when that's
/// gone. after a staged apply, `os enable` and the like still edit the
/// config, and a service turned on since then isn't in the generation on
/// trial. it's not running, but that's no reason to fall back.
pub fn trialInputs(ctx: *Context, a: Allocator, r: generation.Record) !pipeline.Inputs {
    var in = cli.inputs(ctx);
    const dir = r.config_dir orelse return in;
    const rev = r.config_rev orelse return in;
    if (!cli.eql(std.fs.path.dirnamePosix(ctx.config_path) orelse ".", dir)) return in;
    var why: []const u8 = "";
    const files = try ctx.history.files(a, dir, rev, &why) orelse return in;
    const staging = try cli.machinePath(ctx, a, health_dir);
    for (files) |f| {
        if (!try cli.writeFile(ctx, try std.fs.path.join(a, &.{ staging, f.path }), f.bytes)) return in;
    }
    in.config_path = try std.fs.path.join(a, &.{ staging, std.fs.path.basenamePosix(ctx.config_path) });
    return in;
}

/// where the trial's config goes while it's checked. /run goes at the
/// next boot.
const health_dir = "/run/yoq/health";

/// what's wrong with the running machine, if anything, by the config in
/// `in`.
fn check(ctx: *Context, a: Allocator, in: pipeline.Inputs) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    // no --wait: this runs as part of the boot, which isn't finished until
    // it is, so waiting would wait for itself. it runs after
    // multi-user.target, so "starting" means only jobs like this one are
    // left.
    // it exits non-zero for anything but "running", like "degraded".
    const state = switch (try exec.output(a, ctx.io, &.{ "systemctl", "is-system-running" })) {
        .ok, .failed => |t| std.mem.trim(u8, t, " \n"),
    };
    for ([_][]const u8{ "maintenance", "offline", "stopping", "unknown" }) |bad| {
        if (std.mem.eql(u8, state, bad)) try out.append(a, try std.fmt.allocPrint(a, "systemd is in {s}", .{state}));
    }
    // a machine with a display manager has to have it running.
    if (rootfs.pathExists(ctx.io, "/etc/systemd/system/display-manager.service")) {
        const dm = switch (try exec.output(a, ctx.io, &.{ "systemctl", "is-active", "display-manager.service" })) {
            .ok, .failed => |t| std.mem.trim(u8, t, " \n"),
        };
        if (!std.mem.eql(u8, dm, "active")) try out.append(a, try std.fmt.allocPrint(a, "the display manager is {s}", .{dm}));
    }
    // configured services that aren't running show up as unit changes.
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    if (try w.plan(in)) |result| {
        var down: std.ArrayList([]const u8) = .empty;
        for (result.plan.changes) |c| {
            if (c.kind == .unit and c.op != .remove) try down.append(a, try a.dupe(u8, c.subject));
        }
        if (down.items.len > 0) try out.append(a, try std.fmt.allocPrint(a, "not running: {s}", .{try std.mem.join(a, ", ", down.items)}));
        // a machine the config puts on a network has to get there.
        if (networked(result.state.config()) and !try hasRoute(ctx, a)) try out.append(a, "no network: no default route a minute into the boot");
    }
    return out.items;
}

/// units that bring a machine onto a network.
const network_units = [_][]const u8{ "NetworkManager.service", "systemd-networkd.service", "iwd.service", "dhcpcd.service", "connman.service" };

/// whether the config turns on a service that brings up a network.
pub fn networked(c: *const config.Config) bool {
    for (c.services.entries.items) |e| {
        if (!e.value.isEnabled()) continue;
        if (lists.contains(&network_units, e.value.unitFor(e.name))) return true;
    }
    return false;
}

/// whether the machine has a default route, ipv4 or ipv6, waiting up to
/// a minute for one: a network that's slow to come up isn't a failure.
fn hasRoute(ctx: *Context, a: Allocator) !bool {
    for (0..30) |i| {
        if (i > 0) _ = try exec.run(a, ctx.io, &.{ "sleep", "2" });
        for ([_][]const u8{ "-4", "-6" }) |family| {
            switch (try exec.output(a, ctx.io, &.{ "ip", family, "route", "show", "default" })) {
                .ok => |t| if (std.mem.trim(u8, t, " \n").len > 0) return true,
                .failed => {},
            }
        }
    }
    return false;
}

test "a config puts the machine on a network when it turns on a network service" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src: config.Src = .{ .file = "machine.toml", .line = 1, .column = 1 };
    var c: config.Config = .{};
    try std.testing.expect(!networked(&c));
    try c.services.entries.append(a, .{ .name = "networkmanager", .value = .{ .src = src } });
    try std.testing.expect(networked(&c));
    c.services.entries.items[0].value.enabled = .{ .v = false, .src = src };
    try std.testing.expect(!networked(&c));
}

test "a trial is judged by the config its generation was made with" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t: cli.TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"git\"]\n");
    try t.exec(&.{ "add", "--no-apply", "ripgrep" });
    // made while the staged generation waits for its reboot.
    try t.exec(&.{ "enable", "--no-apply", "ssh" });
    const r: generation.Record = .{ .n = 5, .time = 0, .root = "@roots/5", .reason = "update", .config_dir = "/etc/yoq", .config_rev = "1" };
    const in = try trialInputs(&t.ctx, a, r);
    try std.testing.expectEqualStrings(health_dir ++ "/machine.toml", in.config_path);
    const text = t.fs.get(in.config_path).?;
    try std.testing.expect(std.mem.indexOf(u8, text, "ripgrep") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ssh") == null);
    try std.testing.expect(std.mem.indexOf(u8, t.fs.get("/etc/yoq/machine.toml").?, "ssh") != null);
    // a record from before configs were kept, or one whose commit is
    // gone, goes by the config as it is.
    try std.testing.expectEqualStrings("/etc/yoq/machine.toml", (try trialInputs(&t.ctx, a, .{ .n = 5, .time = 0, .root = "@roots/5", .reason = "x" })).config_path);
    try std.testing.expectEqualStrings("/etc/yoq/machine.toml", (try trialInputs(&t.ctx, a, .{ .n = 5, .time = 0, .root = "@roots/5", .reason = "x", .config_dir = "/etc/yoq", .config_rev = "9" })).config_path);
}
