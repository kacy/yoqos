//! `os health`: runs at boot from yoq-health.service. when a generation
//! is on trial and this boot runs it, it checks the machine came up
//! healthy: systemd isn't in maintenance, and every service the config
//! turns on is running. healthy makes it the default; unhealthy reboots
//! into the generation before, which is still the default.

const std = @import("std");
const cli = @import("../cli.zig");
const exec = @import("../exec.zig");
const gens = @import("../gens.zig");
const rollback = @import("rollback.zig");
const Context = cli.Context;
const Allocator = std.mem.Allocator;

pub fn healthCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (try cli.noArgs(ctx, args, "os health")) |code| return code;
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const boot = try rollback.generationsHere(&w) orelse return 0;
    const esp = boot.esp orelse return 0;
    const trial_text = try gens.envValue(a, ctx.io, esp, "yoq_trial") orelse {
        try ctx.out.writeAll("no generation on trial.\n");
        return 0;
    };
    const trial = std.fmt.parseInt(u32, trial_text, 10) catch return 0;
    const record = for (try gens.readRecords(a, ctx.io, "/var")) |r| {
        if (r.n == trial) break r;
    } else return 0;
    if (!std.mem.eql(u8, boot.root_subvol.?[1..], record.root)) {
        // the trial didn't boot: grub fell back. what to do then comes
        // with fallback handling; for now, say so and end the trial.
        try ctx.out.print("generation {d} didn't start; this boot fell back.\n", .{trial});
        _ = try gens.unsetEnv(a, ctx.io, esp, &.{"yoq_trial"});
        return 1;
    }

    const problems = try check(ctx, a);
    if (problems.len == 0) {
        if (try gens.unsetEnv(a, ctx.io, esp, &.{ "yoq_default", "yoq_trial" })) |why| {
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

/// what's wrong with the running machine, if anything.
fn check(ctx: *Context, a: Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    // waits until boot has finished, one way or the other.
    const state = switch (try exec.output(a, ctx.io, &.{ "systemctl", "is-system-running", "--wait" })) {
        .ok => |t| std.mem.trim(u8, t, " \n"),
        // it exits non-zero for anything but "running", like "degraded".
        .failed => |t| std.mem.trim(u8, t, " \n"),
    };
    for ([_][]const u8{ "maintenance", "offline", "stopping", "unknown" }) |bad| {
        if (std.mem.eql(u8, state, bad)) try out.append(a, try std.fmt.allocPrint(a, "systemd is in {s}", .{state}));
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
