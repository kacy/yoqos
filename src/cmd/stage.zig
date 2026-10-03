//! staged apply: a change that needs a reboot, on a machine with
//! generations, is built into the next root, a snapshot of the running
//! one, rather than into the running system. the session keeps its
//! kernel, libraries, and services until the reboot, which boots the new
//! root once on trial.

const std = @import("std");
const cli = @import("../cli.zig");
const btrfs = @import("../btrfs.zig");
const exec = @import("../exec.zig");
const rootfs = @import("../rootfs.zig");
const facts = @import("../facts.zig");
const generation = @import("../generation.zig");
const gens = @import("../gens.zig");
const pipeline = @import("../pipeline.zig");
const building = @import("build.zig");
const Context = cli.Context;

/// where the next root is mounted while it's built: a mount of its own
/// subvolume, so mkinitcpio finds the root filesystem it's built for.
const mount_point = "/run/yos/next";

/// builds the next root from `in`, as the next generation will have it,
/// and returns its subvolume, like "/@roots/7". null after saying why, with
/// the running system as it was.
pub fn build(ctx: *Context, boot: facts.Boot, in: pipeline.Inputs) anyerror!?[]const u8 {
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    if (rootfs.privateMounts(ctx.io)) |why| return fail(ctx, why);
    const m = try cli.openMachine(ctx, a, boot) orelse return null;
    defer m.close();
    const n = try m.free(try gens.readRecords(a, ctx.io, "/var"));
    const root = try std.fmt.allocPrint(a, "/{s}/{d}", .{ generation.roots_dir, n });
    if (!ctx.json) try ctx.out.print("building generation {d} beside the running system, which doesn't change.\n", .{n});
    btrfs.snapshot(try m.at(&.{boot.root_subvol.?}), try m.at(&.{root}), false) catch |e|
        return fail(ctx, try withRoom(a, &m, try std.fmt.allocPrint(a, "can't snapshot the running root: {s}", .{@errorName(e)})));
    const code = buildIn(ctx, a, boot, root, in) catch |e| {
        _ = m.drop(try m.at(&.{root})) catch {};
        return e;
    };
    if (code != 0) {
        _ = try m.drop(try m.at(&.{root}));
        return fail(ctx, try withRoom(a, &m, try std.fmt.allocPrint(a, "generation {d} didn't build, and is gone again", .{n})));
    }
    // the root outlives this command's memory: its caller records it.
    return try std.heap.page_allocator.dupe(u8, root);
}

/// mounts the root at `root` and applies `in` to it, then unmounts it
/// however that went.
fn buildIn(ctx: *Context, a: std.mem.Allocator, boot: facts.Boot, root: []const u8, in: pipeline.Inputs) anyerror!u8 {
    if (try exec.runAll(a, ctx.io, &.{
        &.{ "mkdir", "-p", mount_point },
        &.{ "mount", "-o", try std.fmt.allocPrint(a, "subvol={s}", .{root}), boot.root_device.?, mount_point },
    })) |why| return cli.fail(ctx, "{s}", .{why});
    defer _ = exec.run(a, ctx.io, &.{ "umount", "-R", "-l", mount_point }) catch {};
    var b: building.Builder = .{ .ctx = ctx, .a = a, .dir = mount_point, .staged = true, .inputs = in };
    defer b.unmount();
    if (try b.prepare()) |why| return cli.fail(ctx, "{s}", .{why});
    return b.install();
}

/// `why`, and that the filesystem is nearly full, when it is.
fn withRoom(a: std.mem.Allocator, m: *const gens.Machine, why: []const u8) ![]const u8 {
    const hint = try generation.lowSpace(a, rootfs.freeBytes(m.top) orelse return why) orelse return why;
    return std.fmt.allocPrint(a, "{s}. {s}", .{ why, hint });
}

fn fail(ctx: *Context, why: []const u8) !?[]const u8 {
    _ = try cli.fail(ctx, "{s}", .{why});
    return null;
}
