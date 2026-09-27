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
const facts = @import("../facts.zig");
const generation = @import("../generation.zig");
const gens = @import("../gens.zig");
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
    const esp = boot.esp orelse return 0;
    const trial_text = try gens.envValue(a, ctx.io, esp, "yoq_trial") orelse {
        try ctx.out.writeAll("no generation on trial.\n");
        return 0;
    };
    const trial = std.fmt.parseInt(u32, trial_text, 10) catch return 0;
    const record = generation.find(try gens.readRecords(a, ctx.io, "/var"), trial) orelse {
        // a trial whose generation is gone can't be judged; end it.
        _ = try gens.endTrial(a, ctx.io, esp);
        return 0;
    };
    if (!std.mem.eql(u8, boot.root_subvol.?[1..], record.root)) {
        // an older entry picked by hand before the trial ran isn't a
        // failed trial: the next boot tries it again.
        if (try gens.envValue(a, ctx.io, esp, "yoq_tried") == null) {
            _ = try gens.editEnv(a, ctx.io, esp, "set", &.{"yoq_next=head"});
            try ctx.out.print("generation {d} hasn't been tried yet; the next boot tries it.\n", .{trial});
            return 0;
        }
        return fellBack(ctx, a, boot, trial);
    }

    const problems = try check(ctx, a);
    if (problems.len == 0) {
        if (try gens.endTrial(a, ctx.io, esp)) |why| {
            try ctx.err.print("os: generation {d} is healthy, but couldn't make it the default: {s}\n", .{ trial, why });
            return 1;
        }
        try ctx.out.print("generation {d} came up healthy. it's the default now.\n", .{trial});
        return 0;
    }
    try ctx.out.print("generation {d} isn't healthy: {s}. going back to the generation before.\n", .{ trial, try std.mem.join(a, "; ", problems) });
    // the trial stays marked, so the boot that falls back knows why.
    try ctx.out.flush();
    _ = try exec.run(a, ctx.io, &.{ "systemctl", "reboot" });
    return 1;
}

/// the trial didn't come up healthy, and this boot runs the generation
/// before it, from its copy. that becomes the newest generation, with its
/// config, the trial ends, and a notice says what happened.
fn fellBack(ctx: *Context, a: Allocator, boot: facts.Boot, trial: u32) !u8 {
    const running = boot.root_subvol.?;
    const n = generation.bootCopyOf(running) orelse 0;
    const target = generation.find(try gens.readRecords(a, ctx.io, "/var"), n) orelse {
        try ctx.err.print("os: generation {d} didn't start, and this boot isn't one os knows ({s}).\n", .{ trial, running });
        _ = try gens.endTrial(a, ctx.io, boot.esp.?);
        return 1;
    };
    const reason = try std.fmt.allocPrint(a, "fell back from {d} to {d}", .{ trial, n });
    const made = try rollback.startFrom(ctx, a, boot, target, running, reason) orelse return 1;
    const notice = try std.fmt.allocPrint(a, "generation {d} didn't come up healthy, so this machine went back to generation {d}. it's generation {d} now, with its config. `os rollback {d}` tries {d} again.\n", .{ trial, n, made, trial, trial });
    if (try gens.writeNotice(a, ctx.io, notice)) |why| try ctx.err.print("os: {s}\n", .{why});
    try ctx.out.writeAll(notice);
    return 1;
}

/// what's wrong with the running machine, if anything.
fn check(ctx: *Context, a: Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    // no --wait: this runs as part of the boot, which isn't finished until
    // it is, so waiting would wait for itself. it runs after
    // multi-user.target, so "starting" means only jobs like this one are
    // left.
    const state = switch (try exec.output(a, ctx.io, &.{ "systemctl", "is-system-running" })) {
        .ok => |t| std.mem.trim(u8, t, " \n"),
        // it exits non-zero for anything but "running", like "degraded".
        .failed => |t| std.mem.trim(u8, t, " \n"),
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
    }
    return out.items;
}
