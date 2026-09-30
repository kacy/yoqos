//! what `os enable-rollback` checks and does, worked out from facts alone:
//! whether this machine can have generations, and the steps to get there.
//! like the planner, it reads no files and runs nothing.

const std = @import("std");
const generation = @import("generation.zig");
const facts = @import("facts.zig");
const menu = @import("menu.zig");
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
    /// the step is done now, and takes effect at the next boot.
    at_boot: bool = false,
};

/// what the executor does for a step.
pub const Kind = enum { var_subvol, data_subvols, pacman_db, config_dir, snapper, default_subvol, snapshot, boot_files, boot_entry };

/// where the config lives on the rollback rung: in /var, so no rollback
/// takes it, and bind-mounted at /etc/yoq.
pub const config_home = "/var/lib/yoq/config";

pub const Plan = struct {
    checks: []const Check,
    steps: []const Step,
    /// the running root is a generation already, like "/@roots/1".
    running: ?[]const u8 = null,

    pub fn ready(p: *const Plan) bool {
        return allOk(p.checks);
    }
};

pub fn allOk(checks: []const Check) bool {
    for (checks) |c| {
        if (!c.ok) return false;
    }
    return true;
}

/// each check, with its fix when it fails.
pub fn writeChecks(w: *std.Io.Writer, checks: []const Check) !void {
    try w.writeAll("checks\n");
    for (checks) |c| {
        try w.print("  {s}  {s}: {s}\n", .{ if (c.ok) "ok" else "no", c.what, c.found });
        if (!c.ok) try w.print("        {s}\n", .{c.fix.?});
    }
}

/// whether enable-rollback knows how to convert a root at `subvol`:
/// everything in the top level, as arch's cloud image has it, archinstall's
/// @, or a snapshot snapper's rollback made the root, like
/// /@/.snapshots/2/snapshot.
pub fn knownLayout(subvol: []const u8) bool {
    if (std.mem.eql(u8, subvol, "/") or std.mem.eql(u8, subvol, "/@")) return true;
    var parts = std.mem.splitBackwardsScalar(u8, subvol, '/');
    if (!std.mem.eql(u8, parts.first(), "snapshot")) return false;
    _ = std.fmt.parseInt(u32, parts.next() orelse return false, 10) catch return false;
    return std.mem.endsWith(u8, parts.next() orelse return false, "snapshots");
}

/// the id in `btrfs subvolume get-default`'s output, like "ID 262 gen 31
/// top level 256 path @/.snapshots/2/snapshot".
pub fn defaultId(text: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    if (!std.mem.eql(u8, words.next() orelse return null, "ID")) return null;
    const id = words.next() orelse return null;
    _ = std.fmt.parseInt(u64, id, 10) catch return null;
    return id;
}

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
        .fix = "mount the efi system partition at /efi, /boot/efi, or /boot. the boot menu's one-shot choice lives there.",
    });
    const loader = b.loader orelse "unknown";
    // generations support the bootloaders menu.zig can write for.
    const known = menu.Loader.of(b);
    try checks.append(a, .{
        .what = "bootloader",
        .ok = known != null,
        .found = loader,
        .fix = if (b.loader != null) "generations support grub, limine, refind, and systemd-boot." else "no bootloader os knows was found.",
    });
    // every bootloader but grub keeps os's entries beside its own config.
    const own_conf = known != null and known.? != .grub;
    if (own_conf) try checks.append(a, .{
        .what = try std.fmt.allocPrint(a, "{s}'s config", .{loader}),
        .ok = b.loader_conf != null,
        .found = b.loader_conf orelse "not found",
        .fix = try std.fmt.allocPrint(a, "os adds its entries to the config {s} reads, on the esp, and couldn't find it.", .{loader}),
    });
    const layout = b.root_subvol orelse "unknown";
    const known_layout = knownLayout(layout);
    const running_gen = generation.running(b.root_subvol);
    try checks.append(a, .{
        .what = "root layout",
        .ok = known_layout or running_gen,
        .found = layout,
        .fix = "enable-rollback converts a root in the btrfs top level, archinstall's @ subvolume, or a snapshot snapper rolled back to. other layouts come later.",
    });
    try checks.append(a, .{
        .what = "generations",
        .ok = !running_gen,
        .found = if (running_gen) b.root_subvol.? else "none yet",
        .fix = "this machine has generations already.",
    });

    if (running_gen) return .{ .checks = checks.items, .steps = &.{}, .running = b.root_subvol };

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
    if (b.data_apart.len < generation.data_dirs.len) try steps.append(a, .{
        .kind = .data_subvols,
        .what = "give /home, /root, /srv, and /usr/local subvolumes of their own, where they aren't mounted apart already",
        .why = "what's in them is data, and never rolls back",
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
    if (b.snapper_root) try steps.append(a, .{
        .kind = .snapper,
        .what = "stop snap-pac's snapshots of the root around each pacman run",
        .why = "each change is a generation already. snapper keeps its other configs, like /home's",
    });
    // grub and refind find files on btrfs from the default subvolume, and
    // os's menu names each root from the top level. limine and
    // systemd-boot only read the esp, and their own entries may count on
    // the default, so it stays.
    if (!b.top_is_default and (known == .grub or known == .refind)) try steps.append(a, .{
        .kind = .default_subvol,
        .what = "make the btrfs top level the default subvolume again",
        .why = try std.fmt.allocPrint(a, "{s} reads each generation's files from the top level. snapper's rollback moved the default to the root it made", .{loader}),
    });
    // for all but grub, this step is the switch, so it goes last. a
    // failure before it undoes the steps above.
    try steps.append(a, .{
        .kind = .boot_entry,
        .what = if (own_conf)
            try std.fmt.allocPrint(a, "add generation 1, and the system as it is now, to {s}'s menu in {s}", .{ loader, b.loader_conf orelse "its config" })
        else
            try std.fmt.allocPrint(a, "write {s}'s menu on the esp: generation 1 first, and the system as it is now", .{loader}),
        .why = "every generation can be booted, and so can the way back",
        .at_boot = true,
    });
    // grub's menu moves to the esp, and grub has to be reinstalled to read
    // it there, last, so the machine boots the way it did until
    // everything else is in place.
    if (!own_conf) try steps.append(a, .{
        .kind = .boot_files,
        .what = try std.fmt.allocPrint(a, "install {s}'s boot files on the esp ({s}), reading that menu", .{ loader, b.esp orelse "?" }),
        .why = "the boot menu has to live outside every generation",
    });
    return .{ .checks = checks.items, .steps = steps.items };
}

/// a unit enable-rollback writes into generation 1, which uninstall takes
/// away again.
pub const Unit = struct {
    name: []const u8,
    text: []const u8,
    /// the target that wants it, if it's turned on.
    wanted_by: ?[]const u8,

    /// the link under /etc/systemd/system that turns it on.
    pub fn wantsLink(u: Unit, a: Allocator) !?[]const u8 {
        return try std.fmt.allocPrint(a, "{s}.wants/{s}", .{ u.wanted_by orelse return null, u.name });
    }
};

/// yoq-health.service runs `os health` at each boot, which ends a trial
/// one way or the other, yoq-watchdog.timer reboots a trial boot that
/// hangs before it, and yoq-carry.service carries passwords and the like
/// into a generation waiting for the reboot, as the machine shuts down.
/// `os_path` is the os they run.
pub fn units(a: Allocator, os_path: []const u8) ![4]Unit {
    return .{
        .{
            .name = "yoq-health.service",
            .text = try std.fmt.allocPrint(a,
                \\[Unit]
                \\Description=Check that a generation on trial came up healthy
                \\After=multi-user.target graphical.target
                \\
                \\[Service]
                \\Type=oneshot
                \\ExecStart={s} health
                \\
                \\[Install]
                \\WantedBy=multi-user.target
                \\
            , .{os_path}),
            .wanted_by = "multi-user.target",
        },
        .{
            .name = "yoq-watchdog.timer",
            .text =
            \\[Unit]
            \\Description=Reboot a generation on trial that doesn't finish booting
            \\ConditionKernelCommandLine=yoq.trial
            \\
            \\[Timer]
            \\OnBootSec=5min
            \\AccuracySec=10s
            \\
            \\[Install]
            \\WantedBy=timers.target
            \\
            ,
            .wanted_by = "timers.target",
        },
        .{
            .name = "yoq-watchdog.service",
            .text =
            \\[Unit]
            \\Description=Reboot a generation on trial that didn't finish booting
            \\SuccessAction=reboot-force
            \\
            \\[Service]
            \\Type=oneshot
            \\ExecStart=/usr/bin/true
            \\
            ,
            .wanted_by = null,
        },
        .{
            .name = "yoq-carry.service",
            // it does its work when it stops, at shutdown, after
            // everything that could still change a password, and before
            // the filesystems go.
            .text = try std.fmt.allocPrint(a,
                \\[Unit]
                \\Description=Carry passwords and machine state into a generation waiting for this reboot
                \\After=local-fs.target
                \\
                \\[Service]
                \\Type=oneshot
                \\RemainAfterExit=yes
                \\ExecStart=/usr/bin/true
                \\ExecStop={s} carry
                \\
                \\[Install]
                \\WantedBy=multi-user.target
                \\
            , .{os_path}),
            .wanted_by = "multi-user.target",
        },
    };
}

/// snap-pac's config, from `text`, with its snapshots of the root off.
/// a [root] section gets `snapshot = no` in place of its own setting.
pub fn snapPac(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_root = false;
    var found = false;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "[")) in_root = std.mem.eql(u8, t, "[root]");
        if (in_root and std.mem.startsWith(u8, t, "snapshot") and std.mem.indexOfScalar(u8, t, '=') != null) continue;
        if (line.len > 0 or out.items.len > 0) try out.print(a, "{s}\n", .{line});
        if (in_root and std.mem.eql(u8, t, "[root]")) {
            try out.appendSlice(a, "snapshot = no\n");
            found = true;
        }
    }
    if (!found) try out.print(a, "{s}[root]\nsnapshot = no\n", .{if (out.items.len > 0) "\n" else ""});
    return out.items;
}

/// snap-pac's config with the root's snapshots back on: `snapPac` taken
/// back. null when nothing else is left in it.
pub fn snapPacOn(a: Allocator, text: []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_root = false;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "[")) in_root = std.mem.eql(u8, t, "[root]");
        if (in_root and std.mem.eql(u8, t, "snapshot = no")) continue;
        try out.print(a, "{s}\n", .{line});
    }
    const left = std.mem.trim(u8, out.items, " \n");
    return if (left.len == 0 or std.mem.eql(u8, left, "[root]")) null else out.items;
}

pub fn writeText(w: *std.Io.Writer, p: *const Plan) !void {
    try writeChecks(w, p.checks);
    if (p.steps.len == 0) return;
    try w.writeAll("\nsteps\n");
    for (p.steps, 1..) |s, i| {
        try w.print("  {d}. {s}{s}\n     {s}\n", .{ i, s.what, if (s.at_boot) " (at the next boot)" else "", s.why });
    }
}

pub const Fstab = struct {
    uuid: []const u8,
    add_var: bool,
    /// data directories that moved into subvolumes of their own.
    data: []const generation.DataDir = &.{},
    /// /etc/yoq is a bind mount of the config in /var.
    bind_config: bool = false,
    /// the esp, which gets a line if none mounts it: without one it might
    /// only have been automounted, which a new root can't count on.
    esp: ?struct { uuid: []const u8, point: []const u8 } = null,
};

/// the new root's fstab: a btrfs line for / names no subvolume, /var gets
/// a line for @var when it moved, and the esp gets one if it had none.
pub fn rewriteFstab(a: Allocator, text: []const u8, f: Fstab) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var root_opts: []const u8 = "rw,relatime";
    var has_esp = false;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const spec = fields.next() orelse "";
        const point = fields.next() orelse "";
        const fstype = fields.next() orelse "";
        const opts = fields.next() orelse "";
        // a commented-out line doesn't mount anything.
        if (f.esp) |esp| has_esp = has_esp or (spec.len > 0 and spec[0] != '#' and std.mem.eql(u8, point, esp.point));
        if (spec.len == 0 or spec[0] == '#' or !std.mem.eql(u8, point, "/") or !std.mem.eql(u8, fstype, "btrfs")) {
            if (line.len > 0 or out.items.len > 0) try out.print(a, "{s}\n", .{line});
            continue;
        }
        // the kernel's rootflags pick which root it is, so the same fstab
        // works in every generation and every copy of one.
        root_opts = try withoutSubvol(a, opts);
        try out.print(a, "{s} / btrfs {s} 0 0\n", .{ spec, root_opts });
    }
    if (f.add_var) try out.print(a, "UUID={s} /var btrfs {s},subvol=/{s} 0 0\n", .{ f.uuid, root_opts, generation.var_subvol });
    for (f.data) |d| try out.print(a, "UUID={s} /{s} btrfs {s},subvol=/{s} 0 0\n", .{ f.uuid, d.dir, root_opts, d.subvol });
    if (f.bind_config) try out.print(a, "{s} /etc/yoq none bind,x-systemd.requires-mounts-for=/var 0 0\n", .{config_home});
    if (f.esp) |esp| {
        if (!has_esp) try out.print(a, "UUID={s} {s} vfat rw,relatime,fmask=0077,dmask=0077 0 2\n", .{ esp.uuid, esp.point });
    }
    return out.items;
}

fn withoutSubvol(a: Allocator, opts: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, opts, ',');
    while (it.next()) |o| {
        if (generation.subvolOption(o)) continue;
        if (out.items.len > 0) try out.append(a, ',');
        try out.appendSlice(a, o);
    }
    return if (out.items.len > 0) out.items else "rw,relatime";
}

// -- tests --

const testing = std.testing;

test "a machine on btrfs and grub is ready, with every step" {
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
    try testing.expectEqual(7, p.steps.len);
    try testing.expectEqual(Kind.snapshot, p.steps[0].kind);
    try testing.expect(p.steps[1].at_boot);
    try testing.expectEqual(Kind.data_subvols, p.steps[2].kind);
    try testing.expectEqual(Kind.config_dir, p.steps[4].kind);
    try testing.expectEqual(Kind.boot_entry, p.steps[5].kind);
    try testing.expectEqualStrings("install grub's boot files on the esp (/efi), reading that menu", p.steps[6].what);
}

test "limine and refind keep their own config, and refind gets the top level back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f: facts.Facts = .{ .boot = .{
        .uefi = true,
        .esp = "/boot",
        .loader = "limine",
        .loader_conf = "/boot/EFI/arch-limine/limine.conf",
        .root_fs = "btrfs",
        .root_subvol = "/@",
        .snapper_root = true,
        .top_is_default = false,
    } };
    var p = try plan(arena.allocator(), &f);
    try testing.expect(p.ready());
    const last = p.steps[p.steps.len - 1];
    try testing.expectEqual(Kind.boot_entry, last.kind);
    try testing.expectEqualStrings("add generation 1, and the system as it is now, to limine's menu in /boot/EFI/arch-limine/limine.conf", last.what);
    try testing.expectEqual(Kind.snapper, p.steps[p.steps.len - 2].kind);
    f.boot.loader = "refind";
    f.boot.loader_conf = null;
    p = try plan(arena.allocator(), &f);
    try testing.expect(!p.ready());
    var failed: usize = 0;
    for (p.checks) |c| failed += @intFromBool(!c.ok);
    try testing.expectEqual(1, failed);
    try testing.expectEqual(Kind.default_subvol, p.steps[p.steps.len - 2].kind);
}

test "a root snapper rolled back to converts, with the top level made the default" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f: facts.Facts = .{ .boot = .{
        .uefi = true,
        .esp = "/boot",
        .loader = "grub",
        .root_fs = "btrfs",
        .root_subvol = "/@/.snapshots/2/snapshot",
        .snapper_root = true,
        .top_is_default = false,
    } };
    const p = try plan(arena.allocator(), &f);
    try testing.expect(p.ready());
    try testing.expectEqual(Kind.default_subvol, p.steps[p.steps.len - 3].kind);
    try testing.expectEqualStrings("grub reads each generation's files from the top level. snapper's rollback moved the default to the root it made", p.steps[p.steps.len - 3].why);
    for ([_][]const u8{ "/", "/@", "/@/.snapshots/12/snapshot", "/@snapshots/3/snapshot", "/@.snapshots/3/snapshot" }) |l| try testing.expect(knownLayout(l));
    try testing.expectEqualStrings("262", defaultId("ID 262 gen 31 top level 256 path @/.snapshots/2/snapshot\n").?);
    try testing.expectEqualStrings("5", defaultId("ID 5 (FS_TREE)\n").?);
    try testing.expectEqual(null, defaultId("ERROR: can't access"));
    for ([_][]const u8{ "/@arch", "/@/.snapshots/x/snapshot", "/snapshot", "/@/.snapshots/2/snapshot/var" }) |l| try testing.expect(!knownLayout(l));
}

test "what stops a machine, and the steps it no longer needs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f: facts.Facts = .{ .boot = .{
        .uefi = true,
        .esp = "/boot/efi",
        .loader = "efistub",
        .root_fs = "ext4",
        .var_subvol = true,
        .data_apart = &.{ "home", "root", "srv", "usr/local" },
        .pacman_moved = true,
        .root_subvol = "/@arch",
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
        \\  no  bootloader: efistub
        \\        generations support grub, limine, refind, and systemd-boot.
        \\  no  root layout: /@arch
        \\        enable-rollback converts a root in the btrfs top level, archinstall's @ subvolume, or a snapshot snapper rolled back to. other layouts come later.
        \\  ok  generations: none yet
        \\
        \\steps
        \\  1. snapshot the running root as generation 1
        \\     the first generation to go back to. changes made after it and before the reboot are left behind
        \\  2. keep the config in /var/lib/yoq/config, mounted at /etc/yoq
        \\     the config and its history stay put when a rollback changes the root; a rollback puts back the config that generation had
        \\  3. write efistub's menu on the esp: generation 1 first, and the system as it is now (at the next boot)
        \\     every generation can be booted, and so can the way back
        \\  4. install efistub's boot files on the esp (/boot/efi), reading that menu
        \\     the boot menu has to live outside every generation
        \\
    , out.written());
}

test "snap-pac stops snapshotting the root" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("[root]\nsnapshot = no\n", try snapPac(a, ""));
    try testing.expectEqual(null, try snapPacOn(a, try snapPac(a, "")));
    try testing.expectEqualStrings("[home]\nsnapshot = yes\n\n[root]\n", (try snapPacOn(a, try snapPac(a, "[home]\nsnapshot = yes\n"))).?);
    try testing.expectEqualStrings("[home]\nsnapshot = yes\n\n[root]\nsnapshot = no\n", try snapPac(a, "[home]\nsnapshot = yes\n"));
    try testing.expectEqualStrings("[root]\nsnapshot = no\ndesc_limit = 72\n[home]\nsnapshot = yes\n", try snapPac(a, "[root]\nsnapshot = yes\ndesc_limit = 72\n[home]\nsnapshot = yes\n"));
}

test "the new root's fstab" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        \\# /dev/vda3
        \\UUID=abc / btrfs rw,relatime,compress=zstd:1 0 0
        \\UUID=efi /efi vfat rw 0 2
        \\UUID=abc /var btrfs rw,relatime,compress=zstd:1,subvol=/@var 0 0
        \\UUID=abc /home btrfs rw,relatime,compress=zstd:1,subvol=/@home 0 0
        \\/var/lib/yoq/config /etc/yoq none bind,x-systemd.requires-mounts-for=/var 0 0
        \\
    , try rewriteFstab(a,
        \\# /dev/vda3
        \\UUID=abc / btrfs rw,relatime,compress=zstd:1,subvol=/@ 0 0
        \\UUID=efi /efi vfat rw 0 2
        \\
    , .{ .uuid = "abc", .add_var = true, .data = &.{generation.data_dirs[0]}, .bind_config = true, .esp = .{ .uuid = "efi", .point = "/efi" } }));
    // no lines at all, as on an image that relies on automounts.
    try testing.expectEqualStrings(
        \\UUID=abc /var btrfs rw,relatime,subvol=/@var 0 0
        \\UUID=41B2-0FB5 /efi vfat rw,relatime,fmask=0077,dmask=0077 0 2
        \\
    , try rewriteFstab(a, "", .{ .uuid = "abc", .add_var = true, .esp = .{ .uuid = "41B2-0FB5", .point = "/efi" } }));
    // a commented-out esp line doesn't count; the esp still gets its own.
    try testing.expect(std.mem.endsWith(u8, try rewriteFstab(a, "#UUID=old /efi vfat rw 0 2\n", .{ .uuid = "abc", .add_var = false, .esp = .{ .uuid = "e", .point = "/efi" } }), "UUID=e /efi vfat rw,relatime,fmask=0077,dmask=0077 0 2\n"));
}
