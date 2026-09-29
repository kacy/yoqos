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
const mount_point = "/run/yoq/next";

/// builds the next root from `in`, as the next generation will have it,
/// and returns its subvolume, like "/@roots/7". null after saying why, with
/// the running system as it was.
pub fn build(ctx: *Context, boot: facts.Boot, in: pipeline.Inputs) anyerror!?[]const u8 {
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    var why: []const u8 = "";
    const m = try gens.Machine.open(a, ctx.io, boot, &why) orelse return fail(ctx, why);
    defer m.close();
    const n = try m.free(try gens.readRecords(a, ctx.io, "/var"));
    const root = try std.fmt.allocPrint(a, "/{s}/{d}", .{ generation.roots_dir, n });
    if (!ctx.json) try ctx.out.print("building generation {d} beside the running system, which doesn't change.\n", .{n});
    btrfs.snapshot(try m.at(&.{boot.root_subvol.?}), try m.at(&.{root}), false) catch |e|
        return fail(ctx, try std.fmt.allocPrint(a, "can't snapshot the running root: {s}", .{@errorName(e)}));
    const code = try buildIn(ctx, a, boot, root, in);
    if (code != 0) {
        _ = try m.drop(try m.at(&.{root}));
        return fail(ctx, try std.fmt.allocPrint(a, "generation {d} didn't build, and is gone again", .{n}));
    }
    // its kernel moves onto the esp once it has booted well.
    rootfs.writeAtomic(ctx.io, generation.unsettled_path, root, null) catch {};
    // the root outlives this command's memory: its caller records it.
    return try std.heap.page_allocator.dupe(u8, root);
}

/// mounts the root at `root` and applies `in` to it, then unmounts it
/// however that went.
fn buildIn(ctx: *Context, a: std.mem.Allocator, boot: facts.Boot, root: []const u8, in: pipeline.Inputs) anyerror!u8 {
    if (try exec.runAll(a, ctx.io, &.{
        &.{ "mkdir", "-p", mount_point },
        &.{ "mount", "-o", try std.fmt.allocPrint(a, "subvol={s}", .{root}), boot.root_device.?, mount_point },
    })) |why| {
        try ctx.err.print("os: {s}\n", .{why});
        return 1;
    }
    defer _ = exec.run(a, ctx.io, &.{ "umount", "-R", "-l", mount_point }) catch {};
    var b: building.Builder = .{ .ctx = ctx, .a = a, .dir = mount_point, .staged = true, .inputs = in };
    defer b.unmount();
    if (try b.prepare()) |why| {
        try ctx.err.print("os: {s}\n", .{why});
        return 1;
    }
    return b.install();
}

fn fail(ctx: *Context, why: []const u8) !?[]const u8 {
    try ctx.err.print("os: {s}\n", .{why});
    return null;
}
