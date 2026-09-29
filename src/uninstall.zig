//! what `os uninstall` checks and does, worked out from facts alone. it
//! leaves plain arch on the generation that's running: the config stays in
//! /etc/yoq, the bootloader boots this root the way arch sets it up, and
//! os's own state goes. like enable.zig, it reads no files and runs nothing.

const std = @import("std");
const enable = @import("enable.zig");
const facts = @import("facts.zig");
const generation = @import("generation.zig");
const menu = @import("menu.zig");
const Allocator = std.mem.Allocator;

pub const Kind = enum { config_dir, units, pacman_db, boot_menu, snap_pac, generations, package, state };

pub const Step = struct {
    kind: Kind,
    what: []const u8,
};

pub const Plan = struct {
    checks: []const enable.Check,
    steps: []const Step,

    pub fn ready(p: *const Plan) bool {
        return enable.allOk(p.checks);
    }
};

/// os's own package, if pacman installed it.
pub fn ownPackage(f: *const facts.Facts) ?[]const u8 {
    for (f.packages) |p| {
        if (std.mem.eql(u8, p.name, "yoq-os") or std.mem.eql(u8, p.name, "yoq-os-git")) return p.name;
    }
    return null;
}

/// `drop_generations` adds the step that deletes every generation but the
/// running one.
pub fn plan(a: Allocator, f: *const facts.Facts, drop_generations: bool) !Plan {
    const b = f.boot;
    var checks: std.ArrayList(enable.Check) = .empty;
    var steps: std.ArrayList(Step) = .empty;
    if (generation.running(b.root_subvol)) {
        const loader = menu.Loader.of(b) orelse .grub;
        // a plain limine, refind, or systemd-boot finds arch's kernels in
        // /boot only when that's the esp, as archinstall sets them up.
        if (loader != .grub) try checks.append(a, .{
            .what = "esp",
            .ok = std.mem.eql(u8, b.esp orelse "", "/boot"),
            .found = b.esp orelse "not mounted",
            .fix = try std.fmt.allocPrint(a, "without os, {s} boots the kernel arch installs in /boot, so the esp has to be mounted there.", .{@tagName(loader)}),
        });
        try steps.append(a, .{ .kind = .config_dir, .what = "move the config from " ++ enable.config_home ++ " back into /etc/yoq" });
        try steps.append(a, .{ .kind = .units, .what = "remove os's units that run at boot: yoq-health.service and yoq-watchdog.timer" });
        if (b.pacman_moved) try steps.append(a, .{ .kind = .pacman_db, .what = "move the pacman database back to /var/lib/pacman" });
        try steps.append(a, .{ .kind = .boot_menu, .what = switch (loader) {
            .grub => "reinstall grub with a menu from grub-mkconfig in /boot/grub, booting this root",
            .limine => try std.fmt.allocPrint(a, "replace os's entries in {s} with one for this root", .{b.loader_conf orelse "limine.conf"}),
            .refind => "remove os's entries from refind, and boot this root through /boot/refind_linux.conf",
            .@"systemd-boot" => "replace os's entries in systemd-boot with one for this root, arch-linux.conf, as its default",
        } });
        if (b.snapper_root) try steps.append(a, .{ .kind = .snap_pac, .what = "turn snap-pac's snapshots of the root back on" });
        if (drop_generations) try steps.append(a, .{ .kind = .generations, .what = "delete every generation but this one, and their boot copies" });
    }
    // before the state, since pacman's hook would write to it.
    if (ownPackage(f)) |name| try steps.append(a, .{ .kind = .package, .what = try std.fmt.allocPrint(a, "remove the {s} package: os itself, and its pacman hook", .{name}) });
    try steps.append(a, .{ .kind = .state, .what = "remove os's own state: /var/lib/yoq, and its files on the esp" });
    return .{ .checks = checks.items, .steps = steps.items };
}

pub fn writeText(w: *std.Io.Writer, p: *const Plan) !void {
    if (p.checks.len > 0) {
        try enable.writeChecks(w, p.checks);
        try w.writeByte('\n');
    }
    try w.writeAll("steps\n");
    for (p.steps, 1..) |s, i| try w.print("  {d}. {s}\n", .{ i, s.what });
}

// -- tests --

const testing = std.testing;

test "the steps on each rung" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pkgs = [_]facts.Package{.{ .name = "yoq-os", .version = "0.1.0-1" }};
    const manage = try plan(a, &.{ .boot = .{ .root_subvol = "/@" }, .packages = &pkgs }, true);
    try testing.expectEqual(2, manage.steps.len);
    try testing.expectEqual(Kind.package, manage.steps[0].kind);
    try testing.expectEqual(Kind.state, manage.steps[1].kind);

    const gens = try plan(a, &.{ .boot = .{ .root_subvol = "/@roots/4", .loader = "grub", .esp = "/efi", .pacman_moved = true } }, false);
    try testing.expect(gens.ready());
    var kinds: [6]Kind = undefined;
    for (gens.steps, 0..) |s, i| kinds[i] = s.kind;
    try testing.expectEqualSlices(Kind, &.{ .config_dir, .units, .pacman_db, .boot_menu, .state }, kinds[0..gens.steps.len]);

    // limine without the esp at /boot can't boot arch's kernels on its own.
    const limine = try plan(a, &.{ .boot = .{ .root_subvol = "/@roots/2", .loader = "limine", .esp = "/efi", .snapper_root = true } }, true);
    try testing.expect(!limine.ready());
    try testing.expectEqual(Kind.generations, limine.steps[limine.steps.len - 2].kind);
}
