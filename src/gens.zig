//! generations on a running machine: the btrfs top level, the records in
//! /var/lib/yos/generations, and what each root carries. generation.zig
//! has the pure parts. the menu is bootmenu.zig's, the files it boots
//! bootfiles.zig's, and images and signing images.zig's; `Machine` names
//! the parts other commands use. functions that change something return
//! null when it worked, or what went wrong.

const std = @import("std");
const lists = @import("lists.zig");
const rootfs = @import("rootfs.zig");
const btrfs = @import("btrfs.zig");
const exec = @import("exec.zig");
const facts = @import("facts.zig");
const generation = @import("generation.zig");
const menu = @import("menu.zig");
const enable = @import("enable.zig");
const accounts = @import("accounts.zig");
const trial = @import("trial.zig");
const secureboot = @import("secureboot.zig");
const bootmenu = @import("bootmenu.zig");
const bootfiles = @import("bootfiles.zig");
const images = @import("images.zig");
const Allocator = std.mem.Allocator;

/// a machine on the rollback rung, with its btrfs top level mounted.
pub const Machine = struct {
    a: Allocator,
    io: std.Io,
    boot: facts.Boot,
    loader: menu.Loader,
    root_uuid: []const u8,
    esp_uuid: []const u8,
    top: []const u8 = generation.top_mount,
    /// the kernel command line entries start from, when it isn't the
    /// running one's: an install boots from a live system's.
    cmdline: ?[]const u8 = null,
    /// the esp is the root's /boot, when the esp is mounted somewhere
    /// else for now: an install's, under its target.
    esp_is_boot: ?bool = null,
    /// what signs an efi binary for secure boot, given "sign" and the
    /// file: sbctl, or a stand-in in tests.
    signer: []const []const u8 = &.{secureboot.package},
    /// sbctl's db certificate, which images yos signs must be signed with.
    db_cert: []const u8 = "/" ++ secureboot.db_cert_rel,
    /// what runs ukify in a root, given the root: chroot, or a stand-in
    /// in tests.
    chroot: []const []const u8 = &.{"chroot"},
    /// what runs mkinitcpio in a root, given the root: chroot, with /proc,
    /// /sys, /dev, and /run mounted there in a mount namespace of its own,
    /// so they go when it ends, or a stand-in in tests.
    api_chroot: []const []const u8 = &.{ "unshare", "--mount", "--propagation", "private", "--", "sh", "-c", images.api_chroot_script, "sh" },
    /// refind's btrfs driver as its package installs it, which yos copies
    /// to the esp, and signs there for secure boot.
    refind_driver_src: []const u8 = "/usr/share/refind/" ++ images.refind_driver,
    /// what installs grub, given grub-install's arguments: grub-install,
    /// or a stand-in in tests.
    grub_install: []const []const u8 = &.{"grub-install"},
    /// the hash of the grub binary yos signed last (see images.signGrub).
    grub_signed: []const u8 = generation.grub_signed_path,
    /// set on a way back, like a rollback, a fallback, or gc: a file the
    /// menu can't sign goes on the esp unsigned, or stays as it is there,
    /// and its path goes here, instead of the menu write stopping.
    left_unsigned: ?*std.ArrayList([]const u8) = null,
    /// the note naming the root whose boot files aren't on the esp yet
    /// (see `unsettled`), or a test's stand-in.
    unsettled_note: []const u8 = generation.unsettled_path,
    /// what sets limine's and systemd-boot's efi variables, given its
    /// verb and an entry: bootctl, or a stand-in in tests.
    bootctl: []const []const u8 = &.{"bootctl"},

    // the menu, the files it boots, and images live in files of their
    // own; these are the parts commands call on a machine.
    pub const writeMenu = bootmenu.writeMenu;
    pub const writeMenuHolding = bootmenu.writeMenuHolding;
    pub const entry = bootmenu.entry;
    pub const headCopied = bootmenu.headCopied;
    pub const sdbootEntries = bootmenu.sdbootEntries;
    pub const bootOnEsp = bootfiles.bootOnEsp;
    pub const keepBoot = bootfiles.keepBoot;
    pub const restoreBoot = bootfiles.restoreBoot;
    pub const bootsImage = images.bootsImage;
    pub const signs = images.signs;

    /// mounts the top level of the root's filesystem. `close` unmounts it.
    pub fn open(a: Allocator, io: std.Io, boot: facts.Boot, why: *[]const u8) !?Machine {
        var m: Machine = .{
            .a = a,
            .io = io,
            .boot = boot,
            .loader = menu.Loader.of(boot) orelse return fail(why, "no bootloader yos can write a menu for"),
            .root_uuid = try blkid(a, io, boot.root_device.?, "UUID", why) orelse return null,
            .esp_uuid = try blkid(a, io, boot.esp_device orelse return fail(why, "the esp isn't mounted. mount it, as fstab says, and run this again"), "UUID", why) orelse return null,
        };
        if (std.mem.startsWith(u8, m.top, rootfs.private_dir ++ "/") and !rootfs.makePrivateDir()) return fail(why, "can't make " ++ rootfs.private_dir ++ ", a directory only root can go into");
        if (try m.run(&.{ "mkdir", "-p", m.top })) |w| return fail(why, w);
        if (try m.run(&.{ "mount", "-o", "subvolid=5", boot.root_device.?, m.top })) |w| return fail(why, w);
        return m;
    }

    pub fn close(m: *const Machine) void {
        _ = exec.run(m.a, m.io, &.{ "umount", m.top }) catch {};
    }

    pub fn at(m: *const Machine, parts: []const []const u8) ![]const u8 {
        var all: std.ArrayList([]const u8) = .empty;
        try all.append(m.a, m.top);
        try all.appendSlice(m.a, parts);
        return std.fs.path.join(m.a, all.items);
    }

    pub fn run(m: *const Machine, argv: []const []const u8) !?[]const u8 {
        return exec.run(m.a, m.io, argv);
    }

    /// records the running root as the next generation: a read-only
    /// snapshot, its record in /var, and the boot menu with it at the top.
    pub fn record(m: *const Machine, stamp: generation.Stamp) !?[]const u8 {
        std.Io.Dir.cwd().deleteFile(m.io, notice_path) catch {};
        const records = try readRecords(m.a, m.io, "/var");
        if (try m.keepBoot(m.boot.root_subvol.?)) |w| return w;
        return m.add(records, try m.free(records), m.boot.root_subvol.?, stamp, false);
    }

    /// records the root at `root`, a staged one built beside the running
    /// root, as the next generation, with the menu booting it first.
    pub fn recordStaged(m: *const Machine, root: []const u8, stamp: generation.Stamp) !?[]const u8 {
        std.Io.Dir.cwd().deleteFile(m.io, notice_path) catch {};
        const records = try readRecords(m.a, m.io, "/var");
        const prefix = "/" ++ generation.roots_dir ++ "/";
        const not_staged = try std.fmt.allocPrint(m.a, "{s} isn't a root yos staged", .{root});
        if (!std.mem.startsWith(u8, root, prefix)) return not_staged;
        const n = std.fmt.parseInt(u32, root[prefix.len..], 10) catch return not_staged;
        // it boots the kernel in its own root until a good boot puts it on
        // the esp, and the note that says so is on disk before the menu
        // boots it: without it, the next menu write would boot the esp's
        // older kernel for it, and copy that into its /boot.
        const before = try m.note();
        if (try m.setNote(root)) |w| return w;
        const why = try m.add(records, n, root, stamp, true) orelse return null;
        // unrecorded, nothing boots the staged root: it goes, and the note
        // says what it said before, rather than wait forever.
        _ = try m.forget(n);
        _ = try m.drop(try m.at(&.{root}));
        _ = try m.setNote(before);
        _ = try m.writeMenu(m.boot.root_subvol.?, records);
        return why;
    }

    /// starts a new generation from `source`, a generation's record or a
    /// copy of one: a writable root of its own, recorded and at the top of
    /// the menu, so the next boot runs it. its number goes in `made`. if a
    /// step fails, the new generation goes, and the menu is as it was.
    /// if its boot files don't fit on the esp, it's started all the same,
    /// booting the kernel in its own root, and `later` says why.
    pub fn start(m: *const Machine, source: []const u8, stamp: generation.Stamp, made: *u32, later: *?[]const u8) !?[]const u8 {
        const records = try readRecords(m.a, m.io, "/var");
        const n = try m.free(records);
        const root = try std.fmt.allocPrint(m.a, "/{s}/{d}", .{ generation.roots_dir, n });
        btrfs.snapshot(try m.at(&.{source}), try m.at(&.{root}), false) catch |e| return try std.fmt.allocPrint(m.a, "can't copy {s}: {s}", .{ source, @errorName(e) });
        const before = try m.note();
        // the esp's boot files change last, once the new root is recorded.
        const why = try m.carry(root, false) orelse try m.add(records, n, root, stamp, false) orelse try m.startBoot(root, before, later) orelse {
            made.* = n;
            return null;
        };
        // what cleaning up couldn't do matters too: a menu left as it was
        // written for the new root points at one that's gone.
        const left = try m.forget(n) orelse try m.drop(try m.at(&.{root}));
        const running = m.boot.root_subvol.?;
        const note_left = try m.setNote(before);
        // the running root's kernel goes back on the esp, if it left,
        // before the menu boots it from there again.
        const boot_left = if (m.unsettled(running)) null else (try m.restoreBoot(running)).problem();
        const menu_left = try m.writeMenu(running, records);
        if (menu_left orelse boot_left orelse note_left) |w| return try std.fmt.allocPrint(m.a, "{s}. putting the boot menu back failed too, so it may still name the root that was removed: {s}", .{ why, w });
        if (left) |w| return try std.fmt.allocPrint(m.a, "{s}. generation {d} couldn't be removed either: {s}", .{ why, n, w });
        return why;
    }

    /// puts a new generation's boot files, in the root at `root`, on the
    /// esp. if they don't fit, it boots the ones in its root until a good
    /// boot finds room, and `later` says why. while they're copied, the
    /// note names `root`, so a copy a power cut stops halfway is neither
    /// booted from the esp nor kept in its /boot, and the boot that runs
    /// it finishes the copy (see `unsettled`). once they're all there, the
    /// note says what it said `before`.
    fn startBoot(m: *const Machine, root: []const u8, before: ?[]const u8, later: *?[]const u8) !?[]const u8 {
        if (!m.bootOnEsp()) return null;
        if (try m.setNote(root)) |w| return w;
        switch (try m.restoreBoot(root)) {
            .done => return m.setNote(before),
            .failed => |w| return w,
            .full => |w| {
                // the note keeps its kernel off the esp's entry, and keeps
                // the esp's older kernel out of its /boot.
                later.* = w;
                return null;
            },
        }
    }

    /// the root the unsettled note names, if there is one.
    fn note(m: *const Machine) !?[]const u8 {
        const text = std.Io.Dir.cwd().readFileAlloc(m.io, m.unsettled_note, m.a, .limited(256)) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return null,
        };
        const root = std.mem.trim(u8, text, " \n");
        return if (root.len == 0) null else root;
    }

    /// makes the unsettled note name `root`, or with null, removes it.
    fn setNote(m: *const Machine, root: ?[]const u8) !?[]const u8 {
        const r = root orelse {
            std.Io.Dir.cwd().deleteFile(m.io, m.unsettled_note) catch |e| switch (e) {
                error.FileNotFound => {},
                else => return try std.fmt.allocPrint(m.a, "can't remove {s}", .{m.unsettled_note}),
            };
            return null;
        };
        return rootfs.writeWhole(m.a, m.io, m.unsettled_note, r);
    }

    /// the next generation, from the root at `root`: its read-only record,
    /// the record file, and the menu with `root` at the top. one that goes
    /// `on_trial` next leaves the default on the generation its trial
    /// falls back to (see writeMenuHolding), so a power cut before the
    /// trial is armed boots that one, not a generation nothing has tried.
    fn add(m: *const Machine, records: []const generation.Record, n: u32, root: []const u8, stamp: generation.Stamp, on_trial: bool) !?[]const u8 {
        try m.refreshUnits(root);
        btrfs.snapshot(try m.at(&.{root}), try m.numbered(generation.gens_dir, n), true) catch |e| return try std.fmt.allocPrint(m.a, "can't snapshot {s}: {s}", .{ root, @errorName(e) });
        const rec: generation.Record = .{
            .n = n,
            .time = stamp.time,
            .root = root[1..],
            .reason = stamp.reason,
            .config_dir = if (stamp.config) |c| c.dir else null,
            .config_rev = if (stamp.config) |c| c.rev else null,
        };
        if (try writeRecord(m.a, m.io, "/var", rec)) |w| return w;
        const all = try std.mem.concat(m.a, generation.Record, &.{ records, &.{rec} });
        const hold = if (on_trial) generation.trialFallback(all, try m.pendingFallback()) else null;
        // the trial's note goes in before the menu that holds the default,
        // so a power cut before the trial is armed leaves a note saying so,
        // and the next boot arms it (see `yos health`).
        // as it was before, for a menu that can't be written: a note for a
        // generation that's gone would misdirect the next fallback.
        const note_before = std.Io.Dir.cwd().readFileAlloc(m.io, trial.Store.state_path, m.a, .limited(4096)) catch null;
        if (hold) |fallback| {
            if (trial.Store.of(m.a, m.io, m.boot)) |store| {
                if (try store.prepare(n, fallback)) |w| return w;
            }
        }
        const why = try m.writeMenuHolding(root, all, hold) orelse return null;
        if (hold != null) {
            if (note_before) |text| {
                _ = try rootfs.writeWhole(m.a, m.io, trial.Store.state_path, text);
            } else std.Io.Dir.cwd().deleteFile(m.io, trial.Store.state_path) catch {};
        }
        return why;
    }

    /// the generation a trial waiting for a reboot falls back to, or 0.
    pub fn pendingFallback(m: *const Machine) !u32 {
        const store = trial.Store.of(m.a, m.io, m.boot) orelse return 0;
        const t = try store.current() orelse return 0;
        return t.fallback;
    }

    /// removes the generations `generation.keeps` doesn't keep: their
    /// records, read-only snapshots, and boot copies, and the writable
    /// roots nothing kept or running uses. then rewrites the menu. the
    /// numbers removed go in `removed`.
    pub fn collect(m: *const Machine, keep: usize, removed: *std.ArrayList(u32)) !?[]const u8 {
        const records = try readRecords(m.a, m.io, "/var");
        if (records.len == 0) return null;
        const running = m.boot.root_subvol.?;
        // a pending trial falls back to this one, so it stays too.
        const pending = if (trial.Store.of(m.a, m.io, m.boot)) |s| try s.current() else null;
        const fallback = if (pending) |t| t.fallback else 0;
        // the roots still in use: the running one, and every kept one's.
        var roots: std.ArrayList([]const u8) = .empty;
        try roots.append(m.a, running[1..]);
        var old: std.ArrayList(generation.Record) = .empty;
        for (records) |r| {
            if (generation.keeps(r, records, keep) or r.n == fallback) {
                try roots.append(m.a, r.root);
            } else try old.append(m.a, r);
        }
        const swept = try m.dropStrays(records, running);
        if (old.items.len == 0 and !swept) return null;
        const head = try std.fmt.allocPrint(m.a, "/{s}", .{records[records.len - 1].root});
        const failed = try m.dropOld(old.items, running, &roots, removed);
        // the menu follows what's left, even after a failure halfway.
        const left = try readRecords(m.a, m.io, "/var");
        if (try m.writeMenu(head, left)) |w| return failed orelse w;
        return failed;
    }

    /// rewrites yos's boot units in the root at `subvol` that an older yos
    /// wrote differently, like a watchdog timer counting its five minutes
    /// from the kernel's start, which a slow luks passphrase used up. only
    /// units that don't name the yos they run are rewritten, since those
    /// read the same whichever yos wrote them, and only ones yos wrote.
    /// units an older yos didn't write at all, like yos-carry.service on a
    /// machine that turned generations on with 0.1.0, go in and are turned
    /// on, running the yos the health service there runs. once the root
    /// has the yos package, the units that name a yos run its: a copy
    /// `yos install` left in /usr/local would outlast every upgrade.
    fn refreshUnits(m: *const Machine, subvol: []const u8) !void {
        const dir = try m.at(&.{ subvol, "etc/systemd/system" });
        const health = std.Io.Dir.cwd().readFileAlloc(m.io, try std.fs.path.join(m.a, &.{ dir, "yos-health.service" }), m.a, .limited(64 << 10)) catch "";
        const a = try enable.units(m.a, "a");
        const b = try enable.units(m.a, "b");
        const runs: ?[]const u8 = if (ours(health)) execPath(health, " health") else null;
        // only the path changes in those: the rest is as the yos they run
        // reads it.
        const to_package = runs != null and !std.mem.eql(u8, runs.?, packaged_yos) and
            rootfs.pathExists(m.io, try m.at(&.{ subvol, packaged_yos[1..] }));
        const os_path = if (to_package) packaged_yos else runs;
        const named = try enable.units(m.a, os_path orelse "");
        for (a, b, named) |u, other, with_os| {
            const path = try std.fs.path.join(m.a, &.{ dir, u.name });
            const now = std.Io.Dir.cwd().readFileAlloc(m.io, path, m.a, .limited(64 << 10)) catch |e| switch (e) {
                error.FileNotFound => {
                    if (os_path != null) _ = try writeUnit(m.a, m.io, dir, with_os);
                    continue;
                },
                else => continue,
            };
            if (!std.mem.eql(u8, u.text, other.text)) {
                if (!to_package or !ours(now)) continue;
                rootfs.writeAtomic(m.io, path, try std.mem.replaceOwned(u8, m.a, now, runs.?, packaged_yos), null) catch {};
                continue;
            }
            const want = try std.fmt.allocPrint(m.a, "{s}{s}", .{ unit_header, u.text });
            if (!ours(now) or std.mem.eql(u8, now, want)) continue;
            rootfs.writeAtomic(m.io, path, want, null) catch {};
        }
        // the initramfs hook, on a machine whose units are yos's, goes in
        // where it's missing; the next initramfs built there has it.
        if (os_path == null) return;
        for (enable.trial_hook) |f| {
            const path = try m.at(&.{ subvol, f.path });
            if (rootfs.pathExists(m.io, path)) continue;
            _ = try rootfs.writeWhole(m.a, m.io, path, f.text);
        }
    }

    /// removes the subvolumes a cut-off run left that no generation uses
    /// (see generation.strays), as far as it can. returns whether any
    /// went, since a menu written before one went may still name it.
    fn dropStrays(m: *const Machine, records: []const generation.Record, running: []const u8) !bool {
        // a record that's there but won't read still names its generation:
        // with one, what looks like a stray may be its.
        if (recordFiles(m.io, "/var") != records.len) return false;
        var names: [2][]const []const u8 = undefined;
        for ([_][]const u8{ generation.roots_dir, generation.gens_dir }, &names) |dir, *out| {
            var list: std.ArrayList([]const u8) = .empty;
            var d = std.Io.Dir.cwd().openDir(m.io, try m.at(&.{dir}), .{ .iterate = true }) catch {
                out.* = list.items;
                continue;
            };
            defer d.close(m.io);
            var it = d.iterate();
            while (it.next(m.io) catch null) |e| {
                if (e.kind == .directory) try list.append(m.a, try m.a.dupe(u8, e.name));
            }
            out.* = list.items;
        }
        var any = false;
        for (try generation.strays(m.a, records, names[0], names[1], running)) |path| {
            const full = try m.at(&.{path});
            if (!(btrfs.isSubvolume(full) catch false)) continue;
            if (try m.drop(full) == null) any = true;
        }
        return any;
    }

    fn dropOld(m: *const Machine, old: []const generation.Record, running: []const u8, roots: *std.ArrayList([]const u8), removed: *std.ArrayList(u32)) !?[]const u8 {
        for (old) |r| {
            if (try m.forget(r.n)) |w| return w;
            const copy = try generation.bootCopy(m.a, r.n);
            if (!std.mem.eql(u8, copy, running)) {
                if (try m.drop(try m.at(&.{copy}))) |w| return w;
            }
            if (!lists.contains(roots.items, r.root) and std.mem.startsWith(u8, r.root, generation.roots_dir ++ "/")) {
                if (try m.drop(try m.at(&.{r.root}))) |w| return w;
                // several removed generations can share a root; drop it once.
                try roots.append(m.a, r.root);
            }
            try removed.append(m.a, r.n);
        }
        return null;
    }

    /// the next generation number no subvolume has yet. a crash between a
    /// snapshot and its record can leave one behind without a record.
    pub fn free(m: *const Machine, records: []const generation.Record) !u32 {
        var n = generation.next(records);
        while (true) : (n += 1) {
            if (!rootfs.pathExists(m.io, try m.numbered(generation.gens_dir, n)) and
                !rootfs.pathExists(m.io, try m.numbered(generation.roots_dir, n))) return n;
        }
    }

    /// generation `n`'s subvolume in `dir`, like @gens/3.
    fn numbered(m: *const Machine, dir: []const u8, n: u32) ![]const u8 {
        return m.at(&.{ dir, try std.fmt.allocPrint(m.a, "{d}", .{n}) });
    }

    /// removes generation `n`'s record, then its read-only snapshot, so
    /// a failure between the two leaves no record without a snapshot.
    fn forget(m: *const Machine, n: u32) !?[]const u8 {
        std.Io.Dir.cwd().deleteFile(m.io, try recordPath(m.a, "/var", n)) catch {};
        return m.drop(try m.numbered(generation.gens_dir, n));
    }

    /// deletes a subvolume if it's there, read-only or not.
    pub fn drop(m: *const Machine, path: []const u8) !?[]const u8 {
        if (!(btrfs.isSubvolume(path) catch false)) return null;
        btrfs.setReadOnly(path, false) catch {};
        btrfs.delete(path) catch |e| return try std.fmt.allocPrint(m.a, "can't remove {s}: {s}", .{ path, @errorName(e) });
        return null;
    }

    /// remakes generation `n`'s writable copy from its record, so booting
    /// it always starts from the generation as it was. the copy that's
    /// running, if it's this one, is left alone.
    pub fn freshCopy(m: *const Machine, n: u32, copy: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, m.boot.root_subvol.?, copy)) return null;
        const path = try m.at(&.{copy});
        if (try m.drop(path)) |w| return w;
        btrfs.snapshot(try m.numbered(generation.gens_dir, n), path, false) catch |e| return try std.fmt.allocPrint(m.a, "can't copy generation {d}: {s}", .{ n, @errorName(e) });
        return m.carry(copy, false);
    }

    /// carries the running machine's own state into the root at `subvol`:
    /// its identity, host keys, clock, id ranges, keyring, passwords, and
    /// the system accounts it lacks. a generation holds the system, not
    /// these. a `staged` root was built from this one and keeps what its
    /// build added to the keyring and id ranges.
    pub fn carry(m: *const Machine, subvol: []const u8, staged: bool) !?[]const u8 {
        const root = try m.at(&.{subvol});
        var paths: std.ArrayList([]const u8) = .empty;
        for (carried) |rel| {
            if (!staged or !lists.contains(&built, rel)) try paths.append(m.a, rel);
        }
        var ssh = std.Io.Dir.cwd().openDir(m.io, "/etc/ssh", .{ .iterate = true }) catch null;
        if (ssh) |*d| {
            defer d.close(m.io);
            var it = d.iterate();
            while (it.next(m.io) catch null) |f| {
                if (std.mem.startsWith(u8, f.name, "ssh_host_")) try paths.append(m.a, try std.fmt.allocPrint(m.a, "etc/ssh/{s}", .{f.name}));
            }
        }
        for (paths.items) |rel| {
            const src = try std.fmt.allocPrint(m.a, "/{s}", .{rel});
            if (!rootfs.pathExists(m.io, src)) continue;
            const dest = try std.fs.path.join(m.a, &.{ root, rel });
            if (try m.run(&.{ "rm", "-rf", dest })) |w| return w;
            if (try m.run(&.{ "cp", "-a", src, dest })) |w| return w;
        }
        const fs: rootfs.Root = .{ .a = m.a, .io = m.io, .dir = root };
        const here: rootfs.Root = .{ .a = m.a, .io = m.io, .dir = "/" };
        // system accounts it lacks, so an id given out once stays taken,
        // and a package installed again there gets its old one. a file
        // that's there but can't be read stops the carry: taken as empty,
        // it would be written back without its accounts.
        var text: [2][4][]const u8 = undefined;
        for ([_]rootfs.Root{ here, fs }, &text) |r, *out| {
            for ([_][]const u8{ "etc/passwd", "etc/group", "etc/shadow", "etc/gshadow" }, out) |rel, *t| {
                t.* = std.Io.Dir.cwd().readFileAlloc(m.io, try r.path(rel), m.a, .limited(64 << 20)) catch |e| switch (e) {
                    error.OutOfMemory => return e,
                    error.FileNotFound => "",
                    else => return try std.fmt.allocPrint(m.a, "can't read {s}: {s}", .{ try r.path(rel), @errorName(e) }),
                };
            }
        }
        const users = try accounts.merge(m.a, text[0][0], text[1][0]);
        const groups = try accounts.merge(m.a, text[0][1], text[1][1]);
        const shadow = try accounts.addLines(m.a, try generation.mergeShadow(m.a, text[0][2], text[1][2]), text[0][2], users.added, 7);
        const gshadow = try accounts.addLines(m.a, text[1][3], text[0][3], groups.added, 2);
        const files = [_]struct { []const u8, []const u8, u32 }{
            .{ "etc/passwd", users.text, 0o644 },
            .{ "etc/group", groups.text, 0o644 },
            .{ "etc/shadow", shadow, 0o600 },
            .{ "etc/gshadow", gshadow, 0o600 },
        };
        for (files) |f| {
            fs.writeMode(f[0], f[1], f[2]) catch return try std.fmt.allocPrint(m.a, "can't write {s}/{s}", .{ root, f[0] });
        }
        return null;
    }

    /// whether the root at `subvol` boots the kernel in its own /boot,
    /// since its boot files aren't on the esp yet: it was staged, or they
    /// didn't fit there, and no good boot has put them there since.
    pub fn unsettled(m: *const Machine, subvol: []const u8) bool {
        const named = (m.note() catch return false) orelse return false;
        return std.mem.eql(u8, named, subvol);
    }
};

/// a notice for `yos status`, about something yos did on its own, like
/// falling back from a generation that didn't start. the next generation
/// recorded clears it.
pub const notice_path = "/var/lib/yos/notice";

pub fn writeNotice(a: Allocator, io: std.Io, text: []const u8) !?[]const u8 {
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = notice_path, .data = text }) catch return try std.fmt.allocPrint(a, "can't write {s}", .{notice_path});
    return null;
}

/// where the yos package puts yos.
pub const packaged_yos = "/usr/bin/yos";

/// machine state every root gets from the running system. ssh host keys
/// are added by name, and passwords are merged into /etc/shadow.
const carried = [_][]const u8{ "etc/machine-id", "etc/adjtime", "etc/subuid", "etc/subgid", "etc/pacman.d/gnupg" };

/// carried state a staged build changes itself: repository keys it
/// imports, archlinux-keyring's populate, and id ranges for users it
/// makes. carrying the running root's older copies over them would undo
/// those.
const built = [_][]const u8{ "etc/subuid", "etc/subgid", "etc/pacman.d/gnupg" };

/// every generation's record under `var_dir`, by number.
pub fn readRecords(a: Allocator, io: std.Io, var_dir: []const u8) ![]const generation.Record {
    var out: std.ArrayList(generation.Record) = .empty;
    const dir_path = try std.fs.path.join(a, &.{ var_dir, generation.records_dir });
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |f| {
        if (!std.mem.endsWith(u8, f.name, ".json")) continue;
        const text = dir.readFileAlloc(io, f.name, a, .limited(1 << 16)) catch continue;
        const r = std.json.parseFromSliceLeaky(generation.Record, a, text, .{ .ignore_unknown_fields = true }) catch continue;
        try out.append(a, r);
    }
    std.mem.sort(generation.Record, out.items, {}, struct {
        fn lt(_: void, x: generation.Record, y: generation.Record) bool {
            return x.n < y.n;
        }
    }.lt);
    return out.items;
}

/// how many record files are under `var_dir`, read or not.
fn recordFiles(io: std.Io, var_dir: []const u8) usize {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ var_dir, generation.records_dir }) catch return 0;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |f| n += @intFromBool(std.mem.endsWith(u8, f.name, ".json"));
    return n;
}

pub fn writeRecord(a: Allocator, io: std.Io, var_dir: []const u8, r: generation.Record) !?[]const u8 {
    var json: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(r, .{}, &json.writer);
    try json.writer.writeByte('\n');
    return rootfs.writeWhole(a, io, try recordPath(a, var_dir, r.n), json.written());
}

pub fn recordPath(a: Allocator, var_dir: []const u8, n: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}/{d}.json", .{ var_dir, generation.records_dir, n });
}

/// the first line of every unit yos writes.
const unit_header = "# written by yos.\n";

/// whether yos wrote the unit `text`: it starts with yos's line, or the one
/// enable-rollback wrote before 0.1.1.
fn ours(text: []const u8) bool {
    return std.mem.startsWith(u8, text, unit_header) or std.mem.startsWith(u8, text, "# written by yos enable-rollback.\n");
}

/// the program a unit's `ExecStart=<program><args>` line runs, if it has
/// one ending in `args`.
fn execPath(text: []const u8, args: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "ExecStart=") or !std.mem.endsWith(u8, line, args)) continue;
        const path = line["ExecStart=".len .. line.len - args.len];
        return if (path.len > 0 and path[0] == '/') path else null;
    }
    return null;
}

/// writes yos's units that run at boot (enable.units) into the root at
/// `root`, and turns them on there. `os_path` is the yos they run.
pub fn writeUnits(a: Allocator, io: std.Io, root: []const u8, os_path: []const u8) !?[]const u8 {
    const dir = try std.fs.path.join(a, &.{ root, "etc/systemd/system" });
    for (try enable.units(a, os_path)) |u| {
        if (try writeUnit(a, io, dir, u)) |w| return w;
    }
    for (enable.trial_hook) |f| {
        if (try rootfs.writeWhole(a, io, try std.fs.path.join(a, &.{ root, f.path }), f.text)) |w| return w;
    }
    return null;
}

/// writes the unit `u` into `dir`, a root's /etc/systemd/system, and turns
/// it on there.
fn writeUnit(a: Allocator, io: std.Io, dir: []const u8, u: enable.Unit) !?[]const u8 {
    const text = try std.fmt.allocPrint(a, "{s}{s}", .{ unit_header, u.text });
    if (try rootfs.writeWhole(a, io, try std.fs.path.join(a, &.{ dir, u.name }), text)) |w| return w;
    const link = try u.wantsLink(a) orelse return null;
    const at = try std.fs.path.join(a, &.{ dir, link });
    return exec.runAll(a, io, &.{
        &.{ "mkdir", "-p", std.fs.path.dirnamePosix(at).? },
        &.{ "ln", "-sf", try std.fmt.allocPrint(a, "../{s}", .{u.name}), at },
    });
}

/// where the hibernation block goes: in /run, so the next boot, whichever
/// generation it runs, lifts it.
pub const no_hibernate = "/run/systemd/sleep.conf.d/yos.conf";

/// keeps the machine from hibernating until it reboots. resuming goes
/// through the bootloader, which would start the next generation's kernel
/// with the memory of the one running now.
pub fn blockHibernation(io: std.Io) void {
    rootfs.writeAtomic(io, no_hibernate,
        \\# written by yos: a new generation is waiting for the next boot.
        \\[Sleep]
        \\AllowHibernation=no
        \\AllowHybridSleep=no
        \\AllowSuspendThenHibernate=no
        \\
    , null) catch {};
}

/// one of blkid's tags for a device, like its "UUID" or "PARTUUID".
pub fn blkid(a: Allocator, io: std.Io, device: []const u8, tag: []const u8, why: *[]const u8) !?[]const u8 {
    return switch (try exec.output(a, io, &.{ "blkid", "-s", tag, "-o", "value", device })) {
        .ok => |out| std.mem.trim(u8, out, " \n"),
        .failed => |w| {
            why.* = try std.fmt.allocPrint(a, "can't read {s}'s {s}: {s}", .{ device, tag, w });
            return null;
        },
    };
}

fn fail(why: *[]const u8, message: []const u8) ?Machine {
    why.* = message;
    return null;
}

test "a rollback's kernel copied onto a /boot esp is noted until it's all there" {
    // root reads the file anyway, so the copy can't be made to fail.
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "esp");
    try tmp.dir.createDirPath(io, "top/@roots/2/boot");
    try tmp.dir.writeFile(io, .{ .sub_path = "esp/vmlinuz-linux", .data = "old kernel" });
    try tmp.dir.writeFile(io, .{ .sub_path = "esp/initramfs-linux.img", .data = "old initramfs" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/vmlinuz-linux", .data = "new kernel" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/initramfs-linux.img", .data = "new initramfs" });
    try tmp.dir.writeFile(io, .{ .sub_path = "note", .data = "/@roots/1" });
    const m: Machine = .{
        .a = a,
        .io = io,
        .boot = .{ .esp = try std.fmt.allocPrint(a, "{s}/esp", .{base}), .loader = "grub", .root_subvol = "/@roots/1" },
        .loader = .grub,
        .root_uuid = "r",
        .esp_uuid = "e",
        .top = try std.fmt.allocPrint(a, "{s}/top", .{base}),
        .esp_is_boot = true,
        .unsettled_note = try std.fmt.allocPrint(a, "{s}/note", .{base}),
    };
    // a copy that stops halfway, as a power cut would leave it: the note
    // names the new root, so nothing boots its files from the esp or keeps
    // the esp's in its /boot, and the boot that runs it copies them again.
    const initramfs = try std.fmt.allocPrint(a, "{s}/top/@roots/2/boot/initramfs-linux.img", .{base});
    try std.testing.expectEqual(null, try exec.run(a, io, &.{ "chmod", "000", initramfs }));
    var later: ?[]const u8 = null;
    try std.testing.expect(try m.startBoot("/@roots/2", "/@roots/1", &later) != null);
    try std.testing.expect(m.unsettled("/@roots/2"));
    try std.testing.expect(!m.unsettled("/@roots/1"));
    // once it's all there, the note says what it said before.
    try std.testing.expectEqual(null, try exec.run(a, io, &.{ "chmod", "644", initramfs }));
    try std.testing.expectEqual(null, try m.startBoot("/@roots/2", "/@roots/1", &later));
    try std.testing.expectEqual(null, later);
    try std.testing.expect(m.unsettled("/@roots/1"));
    try std.testing.expectEqualStrings("new initramfs", try tmp.dir.readFileAlloc(io, "esp/initramfs-linux.img", a, .limited(64)));
    try std.testing.expectEqualStrings("new kernel", try tmp.dir.readFileAlloc(io, "esp/vmlinuz-linux", a, .limited(64)));
    // with no note before, there's none after.
    try std.testing.expectEqual(null, try m.startBoot("/@roots/2", null, &later));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "note", .{}));
}

test "a watchdog timer an older yos wrote is brought up to date in a new generation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const dir = "top/@roots/1/etc/systemd/system";
    try tmp.dir.createDirPath(io, dir);
    const units = try enable.units(a, "/usr/bin/yos");
    const timer = units[1];
    try std.testing.expectEqualStrings("yos-watchdog.timer", timer.name);
    const old = try std.mem.replaceOwned(u8, a, timer.text, "OnActiveSec=", "OnBootSec=");
    try tmp.dir.writeFile(io, .{ .sub_path = dir ++ "/yos-watchdog.timer", .data = try std.fmt.allocPrint(a, "{s}{s}", .{ unit_header, old }) });
    // the health service names its yos, which stays as it is, and so does
    // a unit someone wrote over.
    const health = try std.fmt.allocPrint(a, "{s}{s}", .{ unit_header, try std.mem.replaceOwned(u8, a, units[0].text, "/usr/bin/yos", "/usr/local/bin/yos") });
    try tmp.dir.writeFile(io, .{ .sub_path = dir ++ "/yos-health.service", .data = health });
    try tmp.dir.writeFile(io, .{ .sub_path = dir ++ "/yos-watchdog.service", .data = "[Service]\nExecStart=/usr/bin/mine\n" });
    const m: Machine = .{
        .a = a,
        .io = io,
        .boot = .{ .loader = "grub", .root_subvol = "/@roots/1" },
        .loader = .grub,
        .root_uuid = "r",
        .esp_uuid = "e",
        .top = try std.fmt.allocPrint(a, "{s}/top", .{base}),
    };
    try m.refreshUnits("/@roots/1");
    const now = try tmp.dir.readFileAlloc(io, dir ++ "/yos-watchdog.timer", a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, now, "OnActiveSec=5min") != null);
    try std.testing.expect(std.mem.indexOf(u8, now, "OnBootSec") == null);
    try std.testing.expectEqualStrings(health, try tmp.dir.readFileAlloc(io, dir ++ "/yos-health.service", a, .limited(4096)));
    try std.testing.expectEqualStrings("[Service]\nExecStart=/usr/bin/mine\n", try tmp.dir.readFileAlloc(io, dir ++ "/yos-watchdog.service", a, .limited(4096)));
    // once the package is in, the health service runs its yos.
    try tmp.dir.createDirPath(io, "top/@roots/1/usr/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/1/usr/bin/yos", .data = "" });
    try m.refreshUnits("/@roots/1");
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}{s}", .{ unit_header, units[0].text }), try tmp.dir.readFileAlloc(io, dir ++ "/yos-health.service", a, .limited(4096)));
}

test "units from enable-rollback in 0.1.0 are brought up to date, and the missing one goes in" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const dir = "top/@roots/1/etc/systemd/system";
    try tmp.dir.createDirPath(io, dir);
    const units = try enable.units(a, "/usr/bin/yos");
    const old_header = "# written by yos enable-rollback.\n";
    const old_timer = try std.mem.replaceOwned(u8, a, units[1].text, "OnActiveSec=", "OnBootSec=");
    try tmp.dir.writeFile(io, .{ .sub_path = dir ++ "/yos-health.service", .data = try std.fmt.allocPrint(a, "{s}{s}", .{ old_header, units[0].text }) });
    try tmp.dir.writeFile(io, .{ .sub_path = dir ++ "/yos-watchdog.timer", .data = try std.fmt.allocPrint(a, "{s}{s}", .{ old_header, old_timer }) });
    try tmp.dir.writeFile(io, .{ .sub_path = dir ++ "/yos-watchdog.service", .data = try std.fmt.allocPrint(a, "{s}{s}", .{ old_header, units[2].text }) });
    const m: Machine = .{
        .a = a,
        .io = io,
        .boot = .{ .loader = "grub", .root_subvol = "/@roots/1" },
        .loader = .grub,
        .root_uuid = "r",
        .esp_uuid = "e",
        .top = try std.fmt.allocPrint(a, "{s}/top", .{base}),
    };
    try m.refreshUnits("/@roots/1");
    const timer = try tmp.dir.readFileAlloc(io, dir ++ "/yos-watchdog.timer", a, .limited(4096));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}{s}", .{ unit_header, units[1].text }), timer);
    const carry = try tmp.dir.readFileAlloc(io, dir ++ "/yos-carry.service", a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, carry, "ExecStop=/usr/bin/yos carry\n") != null);
    _ = try tmp.dir.statFile(io, dir ++ "/multi-user.target.wants/yos-carry.service", .{});
    // the unit for emergency shells, and the hook that puts it in the
    // initramfs.
    _ = try tmp.dir.statFile(io, dir ++ "/emergency.target.wants/" ++ enable.emergency_unit, .{});
    try std.testing.expectEqualStrings(enable.trial_hook[2].text, try tmp.dir.readFileAlloc(io, "top/@roots/1/etc/mkinitcpio.conf.d/" ++ facts.trial_dropin, a, .limited(4096)));
    _ = try tmp.dir.statFile(io, "top/@roots/1/etc/initcpio/install/yos-trial", .{});
    _ = try tmp.dir.statFile(io, "top/@roots/1/etc/initcpio/hooks/yos-trial", .{});
    // a root yos never set up gets nothing.
    try tmp.dir.createDirPath(io, "top/@roots/2/etc/systemd/system");
    try m.refreshUnits("/@roots/2");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "top/@roots/2/etc/systemd/system/yos-carry.service", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "top/@roots/2/etc/initcpio/install/yos-trial", .{}));
}

test "records by number, and dates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const var_dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try std.testing.expectEqual(0, (try readRecords(a, io, var_dir)).len);
    try std.testing.expectEqual(null, try writeRecord(a, io, var_dir, .{ .n = 2, .time = 1790380800, .root = "@roots/1", .reason = "add fd" }));
    try std.testing.expectEqual(null, try writeRecord(a, io, var_dir, .{ .n = 1, .time = 1790300000, .root = "@roots/1", .reason = "enable-rollback", .from = "/" }));
    const got = try readRecords(a, io, var_dir);
    try std.testing.expectEqual(2, got.len);
    try std.testing.expectEqual(1, got[0].n);
    try std.testing.expectEqualStrings("/", got[0].from.?);
    try std.testing.expectEqualStrings("yos 2 · 2026-09-26 · add fd", try generation.title(a, got[1]));
}
