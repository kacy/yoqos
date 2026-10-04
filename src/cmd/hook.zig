//! `yos record-pacman`: what the pacman hook in dist/ runs after every
//! transaction, with the packages it touched on stdin, one per line. it
//! never fails, since a failing hook would worry pacman's user for nothing.
//! when the transaction changed the running root's boot files, it writes
//! the boot menu again, on a machine whose menu boots copies of them.

const std = @import("std");
const cli = @import("../cli.zig");
const drift = @import("../drift.zig");
const journal = @import("../journal.zig");
const catalog = @import("../catalog.zig");
const lists = @import("../lists.zig");
const modules = @import("../modules.zig");
const gens = @import("../gens.zig");
const applying = @import("apply.zig");
const rollback = @import("rollback.zig");
const Context = cli.Context;

pub fn recordPacmanCmd(ctx: *Context, _: []const [:0]const u8) !u8 {
    // yos's own transactions run the hook too; those aren't drift.
    if (ctx.in_own_transaction) return 0;
    const in = ctx.in orelse return 0;
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    while (in.takeDelimiter('\n') catch null) |line| {
        const name = std.mem.trim(u8, line, " \t\r");
        if (name.len > 0) try names.append(a, try a.dupe(u8, name));
    }
    try drift.record(a, ctx.io, ctx.root, journal.now(ctx.io), names.items);
    if (touchesBoot(names.items, try modules.kernelPackages(a, ctx.io, ctx.root))) refreshMenu(ctx, &w) catch {};
    return 0;
}

/// whether a transaction that touched `packages` can change the running
/// root's kernel, initramfs, microcode, or the stub its images start
/// with: a package whose change otherwise needs a reboot, or one of
/// `kernels`, the kernel packages installed, whatever they're called.
pub fn touchesBoot(packages: []const []const u8, kernels: []const []const u8) bool {
    for (packages) |p| {
        if (catalog.rebootReason(p) != null or lists.contains(kernels, p)) return true;
    }
    return false;
}

/// on a machine with generations, the menu's newest entry boots the
/// running root, but with the esp elsewhere than /boot it boots copies of
/// its boot files on the esp, or with `[boot] uki` an image of them, made
/// when the menu was written. a kernel pacman installed outside yos would
/// then boot only after the next generation, and the old kernel, whose
/// modules pacman removed, boots meanwhile. so the menu is written again,
/// as `yos gc` would. with /boot as the esp and no image, the entry boots
/// the esp's own files, which pacman changed already. a menu that can't
/// sign goes on unsigned, with a warning, as on a way back.
fn refreshMenu(ctx: *Context, w: *cli.Work) !void {
    const a = w.allocator();
    const boot = try w.generations() orelse return;
    // a copy of an older generation, or one waiting for the next boot:
    // the newest entry isn't this root.
    if (applying.bootBlocker(ctx.io) != null) return;
    if (cli.lockForEdit(ctx) != null) return;
    const running = boot.root_subvol.?;
    var left: std.ArrayList([]const u8) = .empty;
    const m = try rollback.openWayBack(ctx, a, boot, &left) orelse return;
    defer m.close();
    if (!try m.headCopied(running)) return;
    const records = try gens.readRecords(a, ctx.io, "/var");
    if (records.len == 0) return;
    // with /boot as the esp, pacman put the new files there; an image is
    // built from the root's own copies, as when a generation is recorded.
    const why = try m.keepBoot(running) orelse try m.writeMenu(running, records);
    if (why) |problem| {
        try ctx.err.print("yos: the boot menu still boots the kernel from before this transaction: {s}. `yos gc` writes it again.\n", .{problem});
        return;
    }
    try rollback.warnUnsigned(ctx, a, left.items);
    try ctx.err.writeAll("yos: wrote the boot menu again, so its newest entry boots the new boot files.\n");
}

test "the hook's targets land in the drift log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try std.fmt.allocPrintSentinel(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    var t: cli.TestRun = .{ .input = "htop\nbtop\n" };
    defer t.deinit();
    try t.exec(&.{ "--root", root, "record-pacman" });
    try std.testing.expectEqual(0, t.code);
    const got = try drift.since(arena.allocator(), std.testing.io, root);
    try std.testing.expectEqual(1, got.len);
    try std.testing.expectEqualStrings("htop", got[0].packages[0]);
    try std.testing.expectEqualStrings("btop", got[0].packages[1]);
}

test "yos's own transactions aren't drift" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try std.fmt.allocPrintSentinel(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    var t: cli.TestRun = .{ .input = "git\n", .in_own_transaction = true };
    defer t.deinit();
    try t.exec(&.{ "--root", root, "record-pacman" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqual(0, (try drift.since(arena.allocator(), std.testing.io, root)).len);
}

test "a kernel, microcode, or initramfs tool from pacman touches the boot files" {
    try std.testing.expect(touchesBoot(&.{ "htop", "linux" }, &.{}));
    try std.testing.expect(touchesBoot(&.{"amd-ucode"}, &.{}));
    try std.testing.expect(touchesBoot(&.{"mkinitcpio"}, &.{}));
    try std.testing.expect(touchesBoot(&.{"systemd"}, &.{}));
    try std.testing.expect(touchesBoot(&.{"linux-cachyos"}, &.{"linux-cachyos"}));
    try std.testing.expect(!touchesBoot(&.{ "htop", "btop" }, &.{"linux"}));
    try std.testing.expect(!touchesBoot(&.{}, &.{}));
}
