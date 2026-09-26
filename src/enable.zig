//! what `os enable-rollback` checks and does, worked out from facts alone:
//! whether this machine can have generations, and the steps to get there.
//! like the planner, it reads no files and runs nothing.

const std = @import("std");
const facts = @import("facts.zig");
const Allocator = std.mem.Allocator;

pub const Check = struct {
    what: []const u8,
    ok: bool,
    /// what was found.
    found: []const u8,
    /// what to do about it, when it isn't ok.
    fix: ?[]const u8 = null,
};

pub const Step = struct {
    kind: Kind,
    what: []const u8,
    why: []const u8,
    /// the step runs during a reboot, before services start.
    at_boot: bool = false,
};

/// what the executor does for a step.
pub const Kind = enum { var_subvol, pacman_db, config_dir, snapshot, boot_files, boot_entry };

/// where the config lives on the rollback rung: in /var, so no rollback
/// takes it, and bind-mounted at /etc/yoq.
pub const config_home = "/var/lib/yoq/config";

pub const Plan = struct {
    checks: []const Check,
    steps: []const Step,
    /// the running root is a generation already, like "/@roots/1".
    running: ?[]const u8 = null,

    pub fn ready(p: *const Plan) bool {
        for (p.checks) |c| {
            if (!c.ok) return false;
        }
        return true;
    }
};

/// bootloaders with generations so far. systemd-boot, limine, and refind
/// come later.
pub const loaders = [_][]const u8{"grub"};

/// root layouts enable-rollback knows how to convert: everything in the
/// top level, as arch's cloud image has it, and archinstall's @.
pub const layouts = [_][]const u8{ "/", "/@" };

pub fn plan(a: Allocator, f: *const facts.Facts) !Plan {
    const b = f.boot;
    var checks: std.ArrayList(Check) = .empty;
    const fs = b.root_fs orelse "unknown";
    try checks.append(a, .{
        .what = "root filesystem",
        .ok = std.mem.eql(u8, fs, "btrfs"),
        .found = fs,
        .fix = "generations are btrfs snapshots, so the root has to be btrfs. everything else in os works on any filesystem.",
    });
    try checks.append(a, .{
        .what = "firmware",
        .ok = b.uefi,
        .found = if (b.uefi) "uefi" else "bios",
        .fix = "boot entries for generations need uefi. switch the firmware to uefi boot, if it can.",
    });
    try checks.append(a, .{
        .what = "esp",
        .ok = b.esp != null,
        .found = b.esp orelse "not mounted",
        .fix = "mount the efi system partition at /efi or /boot/efi. the boot menu's one-shot choice lives there.",
    });
    const loader = b.loader orelse "unknown";
    const supported = for (loaders) |l| {
        if (std.mem.eql(u8, l, loader)) break true;
    } else false;
    try checks.append(a, .{
        .what = "bootloader",
        .ok = supported,
        .found = loader,
        .fix = if (b.loader != null) "generations support grub so far; systemd-boot, limine, and refind come later." else "no bootloader os knows was found.",
    });
    const layout = b.root_subvol orelse "unknown";
    const known = for (layouts) |l| {
        if (std.mem.eql(u8, l, layout)) break true;
    } else false;
    const running_gen = @import("generation.zig").running(b.root_subvol);
    try checks.append(a, .{
        .what = "root layout",
        .ok = known or running_gen,
        .found = layout,
        .fix = "enable-rollback converts a root in the btrfs top level, or archinstall's @ subvolume. other layouts come later.",
    });
    const enabled = running_gen;
    try checks.append(a, .{
        .what = "generations",
        .ok = !enabled,
        .found = if (enabled) b.root_subvol.? else "none yet",
        .fix = "this machine has generations already.",
    });

    if (enabled) return .{ .checks = checks.items, .steps = &.{}, .running = b.root_subvol };

    // everything is built from one snapshot of the running root, taken
    // first: generation 1, its /var, and its pacman database all come from
    // the same moment.
    var steps: std.ArrayList(Step) = .empty;
    try steps.append(a, .{
        .kind = .snapshot,
        .what = "snapshot the running root as generation 1",
        .why = "the first generation to go back to. changes made after it and before the reboot are left behind",
    });
    if (!b.var_subvol) try steps.append(a, .{
        .kind = .var_subvol,
        .what = "give generation 1 a /var of its own, as a subvolume",
        .why = "data in /var never rolls back",
        .at_boot = true,
    });
    if (!b.pacman_moved) try steps.append(a, .{
        .kind = .pacman_db,
        .what = "move generation 1's pacman database to /usr/lib/sysimage/pacman, with a symlink at /var/lib/pacman",
        .why = "the database has to describe the /usr beside it, and /var doesn't roll back",
    });
    try steps.append(a, .{
        .kind = .config_dir,
        .what = "keep the config in " ++ config_home ++ ", mounted at /etc/yoq",
        .why = "the config and its history stay put when a rollback changes the root; a rollback puts back the config that generation had",
    });
    try steps.append(a, .{
        .kind = .boot_entry,
        .what = try std.fmt.allocPrint(a, "write {s}'s menu on the esp: generation 1 first, and the system as it is now", .{loader}),
        .why = "every generation can be booted, and so can the way back",
        .at_boot = true,
    });
    // last, so the machine boots the way it did until everything else is
    // in place. a failure before it undoes the steps above.
    try steps.append(a, .{
        .kind = .boot_files,
        .what = try std.fmt.allocPrint(a, "install {s}'s boot files on the esp ({s}), reading that menu", .{ loader, b.esp orelse "?" }),
        .why = "the boot menu has to live outside every generation",
    });
    return .{ .checks = checks.items, .steps = steps.items };
}

pub fn writeText(w: *std.Io.Writer, p: *const Plan) !void {
    try w.writeAll("checks\n");
    for (p.checks) |c| {
        try w.print("  {s}  {s}: {s}\n", .{ if (c.ok) "ok" else "no", c.what, c.found });
        if (!c.ok) try w.print("        {s}\n", .{c.fix.?});
    }
    if (p.steps.len == 0) return;
    try w.writeAll("\nsteps\n");
    for (p.steps, 1..) |s, i| {
        try w.print("  {d}. {s}{s}\n     {s}\n", .{ i, s.what, if (s.at_boot) " (at the next boot)" else "", s.why });
    }
}

// -- tests --

const testing = std.testing;

test "an archinstall machine on btrfs and grub is ready, with every step" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f: facts.Facts = .{ .boot = .{
        .uefi = true,
        .esp = "/efi",
        .loader = "grub",
        .root_fs = "btrfs",
        .root_subvol = "/@",
    } };
    const p = try plan(arena.allocator(), &f);
    try testing.expect(p.ready());
    try testing.expectEqual(6, p.steps.len);
    try testing.expectEqual(Kind.snapshot, p.steps[0].kind);
    try testing.expect(p.steps[1].at_boot);
    try testing.expectEqual(Kind.config_dir, p.steps[3].kind);
    try testing.expectEqual(Kind.boot_entry, p.steps[4].kind);
    try testing.expectEqualStrings("install grub's boot files on the esp (/efi), reading that menu", p.steps[5].what);
}

test "what stops a machine, and the steps it no longer needs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f: facts.Facts = .{ .boot = .{
        .uefi = true,
        .esp = "/boot/efi",
        .loader = "limine",
        .root_fs = "ext4",
        .var_subvol = true,
        .pacman_moved = true,
        .root_subvol = "/@/.snapshots/1/snapshot",
    } };
    const p = try plan(arena.allocator(), &f);
    try testing.expect(!p.ready());
    try testing.expectEqual(4, p.steps.len);

    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try writeText(&out.writer, &p);
    try testing.expectEqualStrings(
        \\checks
        \\  no  root filesystem: ext4
        \\        generations are btrfs snapshots, so the root has to be btrfs. everything else in os works on any filesystem.
        \\  ok  firmware: uefi
        \\  ok  esp: /boot/efi
        \\  no  bootloader: limine
        \\        generations support grub so far; systemd-boot, limine, and refind come later.
        \\  no  root layout: /@/.snapshots/1/snapshot
        \\        enable-rollback converts a root in the btrfs top level, or archinstall's @ subvolume. other layouts come later.
        \\  ok  generations: none yet
        \\
        \\steps
        \\  1. snapshot the running root as generation 1
        \\     the first generation to go back to. changes made after it and before the reboot are left behind
        \\  2. keep the config in /var/lib/yoq/config, mounted at /etc/yoq
        \\     the config and its history stay put when a rollback changes the root; a rollback puts back the config that generation had
        \\  3. write limine's menu on the esp: generation 1 first, and the system as it is now (at the next boot)
        \\     every generation can be booted, and so can the way back
        \\  4. install limine's boot files on the esp (/boot/efi), reading that menu
        \\     the boot menu has to live outside every generation
        \\
    , out.written());
}
