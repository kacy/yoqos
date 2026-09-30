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
const rollback = @import("rollback.zig");
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
    if (!std.mem.eql(u8, boot.root_subvol.?[1..], record.root)) {
        // an older entry picked by hand before the trial ran isn't a
        // failed trial: the next boot tries it again.
        if (!t.tried) {
            _ = try store.retry();
            try ctx.out.print("generation {d} hasn't been tried yet; the next boot tries it.\n", .{t.n});
            return 0;
        }
        return fellBack(ctx, a, store, boot, t.n);
    }

    const problems = try check(ctx, a);
    if (problems.len == 0) {
        if (try store.end()) |why| return cli.fail(ctx, "generation {d} is healthy, but couldn't make it the default: {s}", .{ t.n, why });
        try ctx.out.print("generation {d} came up healthy. it's the default now.\n", .{t.n});
        if (try settleBoot(ctx, a, boot)) |why| try ctx.err.print("os: {s}\n", .{why});
        return 0;
    }
    try ctx.out.print("generation {d} isn't healthy: {s}. going back to the generation before.\n", .{ t.n, try std.mem.join(a, "; ", problems) });
    // the trial stays marked, so the boot that falls back knows why.
    try ctx.out.flush();
    _ = try exec.run(a, ctx.io, &.{ "systemctl", "reboot" });
    return 1;
}

/// the trial didn't come up healthy, and this boot runs the generation
/// before it, from its copy. that becomes the newest generation, with its
/// config, the trial ends, and a notice says what happened.
fn fellBack(ctx: *Context, a: Allocator, store: trial.Store, boot: facts.Boot, tried: u32) !u8 {
    const running = boot.root_subvol.?;
    const n = generation.bootCopyOf(running) orelse 0;
    const target = generation.find(try gens.readRecords(a, ctx.io, "/var"), n) orelse {
        try ctx.err.print("os: generation {d} didn't start, and this boot isn't one os knows ({s}).\n", .{ tried, running });
        _ = try store.end();
        return 1;
    };
    const reason = try std.fmt.allocPrint(a, "fell back from {d} to {d}", .{ tried, n });
    const made = try rollback.startFrom(ctx, a, boot, target, running, reason) orelse return 1;
    const notice = try std.fmt.allocPrint(a, "generation {d} didn't come up healthy, so this machine went back to generation {d}. it's generation {d} now, with its config. `os rollback {d}` tries {d} again.\n", .{ tried, n, made, tried, tried });
    if (try gens.writeNotice(a, ctx.io, notice)) |why| try ctx.err.print("os: {s}\n", .{why});
    try ctx.out.writeAll(notice);
    return 1;
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
    if (m.bootOnEsp()) {
        if (try m.restoreBoot(running)) |w| return w;
        if (try m.writeMenu(running, try gens.readRecords(a, ctx.io, "/var"))) |w| return w;
    }
    std.Io.Dir.cwd().deleteFile(ctx.io, generation.unsettled_path) catch {};
    return null;
}

/// what's wrong with the running machine, if anything.
fn check(ctx: *Context, a: Allocator) ![]const []const u8 {
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
    if (try w.plan(cli.inputs(ctx))) |result| {
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
