//! generations on a running machine: the btrfs top level, the records in
//! /var/lib/yoq/generations, and the boot menu on the esp. generation.zig
//! has the pure parts. functions that change something return null when
//! it worked, or what went wrong.

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
const uki = @import("uki.zig");
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

    /// mounts the top level of the root's filesystem. `close` unmounts it.
    pub fn open(a: Allocator, io: std.Io, boot: facts.Boot, why: *[]const u8) !?Machine {
        var m: Machine = .{
            .a = a,
            .io = io,
            .boot = boot,
            .loader = menu.Loader.of(boot) orelse return fail(why, "no bootloader os can write a menu for"),
            .root_uuid = try blkid(a, io, boot.root_device.?, "UUID", why) orelse return null,
            .esp_uuid = try blkid(a, io, boot.esp_device.?, "UUID", why) orelse return null,
        };
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
    pub fn record(m: *const Machine, reason: []const u8, time: i64, config: ?generation.Config) !?[]const u8 {
        std.Io.Dir.cwd().deleteFile(m.io, notice_path) catch {};
        const records = try readRecords(m.a, m.io, "/var");
        if (try m.keepBoot(m.boot.root_subvol.?)) |w| return w;
        return m.add(records, try m.free(records), m.boot.root_subvol.?, reason, time, config);
    }

    /// records the root at `root`, a staged one built beside the running
    /// root, as the next generation, with the menu booting it first.
    pub fn recordStaged(m: *const Machine, root: []const u8, reason: []const u8, time: i64, config: ?generation.Config) !?[]const u8 {
        std.Io.Dir.cwd().deleteFile(m.io, notice_path) catch {};
        const records = try readRecords(m.a, m.io, "/var");
        const prefix = "/" ++ generation.roots_dir ++ "/";
        const not_staged = try std.fmt.allocPrint(m.a, "{s} isn't a root os staged", .{root});
        if (!std.mem.startsWith(u8, root, prefix)) return not_staged;
        const n = std.fmt.parseInt(u32, root[prefix.len..], 10) catch return not_staged;
        const why = try m.add(records, n, root, reason, time, config) orelse return null;
        // unrecorded, nothing boots the staged root: it goes, and so does
        // its note, rather than wait forever.
        _ = try m.forget(n);
        _ = try m.drop(try m.at(&.{root}));
        std.Io.Dir.cwd().deleteFile(m.io, generation.unsettled_path) catch {};
        _ = try m.writeMenu(m.boot.root_subvol.?, records);
        return why;
    }

    /// starts a new generation from `source`, a generation's record or a
    /// copy of one: a writable root of its own, recorded and at the top of
    /// the menu, so the next boot runs it. its number goes in `made`. if a
    /// step fails, the new generation goes, and the menu is as it was.
    /// if its boot files don't fit on the esp, it's started all the same,
    /// booting the kernel in its own root, and `later` says why.
    pub fn start(m: *const Machine, source: []const u8, reason: []const u8, time: i64, config: ?generation.Config, made: *u32, later: *?[]const u8) !?[]const u8 {
        const records = try readRecords(m.a, m.io, "/var");
        const n = try m.free(records);
        const root = try std.fmt.allocPrint(m.a, "/{s}/{d}", .{ generation.roots_dir, n });
        btrfs.snapshot(try m.at(&.{source}), try m.at(&.{root}), false) catch |e| return try std.fmt.allocPrint(m.a, "can't copy {s}: {s}", .{ source, @errorName(e) });
        // the esp's boot files change last, once the new root is recorded.
        const why = try m.carry(root) orelse try m.add(records, n, root, reason, time, config) orelse try m.startBoot(root, later) orelse {
            made.* = n;
            return null;
        };
        // what cleaning up couldn't do matters too: a menu left as it was
        // written for the new root points at one that's gone.
        const left = try m.forget(n) orelse try m.drop(try m.at(&.{root}));
        const running = m.boot.root_subvol.?;
        const menu_left = try m.writeMenu(running, records);
        // the running root's kernel goes back on the esp, if it left.
        const boot_left = if (m.unsettled(running)) null else (try m.restoreBoot(running)).problem();
        if (menu_left orelse boot_left) |w| return try std.fmt.allocPrint(m.a, "{s}. putting the boot menu back failed too, so it may still name the root that was removed: {s}", .{ why, w });
        if (left) |w| return try std.fmt.allocPrint(m.a, "{s}. generation {d} couldn't be removed either: {s}", .{ why, n, w });
        return why;
    }

    /// puts a new generation's boot files, in the root at `root`, on the
    /// esp. if they don't fit, it boots the ones in its root until a good
    /// boot finds room, and `later` says why.
    fn startBoot(m: *const Machine, root: []const u8, later: *?[]const u8) !?[]const u8 {
        switch (try m.restoreBoot(root)) {
            .done => return null,
            .failed => |w| return w,
            .full => |w| {
                // the note keeps its kernel off the esp's entry, and keeps
                // the esp's older kernel out of its /boot.
                rootfs.writeAtomic(m.io, generation.unsettled_path, root, null) catch
                    return try std.fmt.allocPrint(m.a, "{s}. can't write {s} either", .{ w, generation.unsettled_path });
                later.* = w;
                return null;
            },
        }
    }

    /// the next generation, from the root at `root`: its read-only record,
    /// the record file, and the menu with `root` at the top.
    fn add(m: *const Machine, records: []const generation.Record, n: u32, root: []const u8, reason: []const u8, time: i64, config: ?generation.Config) !?[]const u8 {
        btrfs.snapshot(try m.at(&.{root}), try m.numbered(generation.gens_dir, n), true) catch |e| return try std.fmt.allocPrint(m.a, "can't snapshot {s}: {s}", .{ root, @errorName(e) });
        const rec: generation.Record = .{
            .n = n,
            .time = time,
            .root = root[1..],
            .reason = reason,
            .config_dir = if (config) |c| c.dir else null,
            .config_rev = if (config) |c| c.rev else null,
        };
        if (try writeRecord(m.a, m.io, "/var", rec)) |w| return w;
        const all = try std.mem.concat(m.a, generation.Record, &.{ records, &.{rec} });
        return m.writeMenu(root, all);
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
        if (old.items.len == 0) return null;
        const head = try std.fmt.allocPrint(m.a, "/{s}", .{records[records.len - 1].root});
        const failed = try m.dropOld(old.items, running, &roots, removed);
        // the menu follows what's left, even after a failure halfway.
        const left = try readRecords(m.a, m.io, "/var");
        if (try m.writeMenu(head, left)) |w| return failed orelse w;
        return failed;
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

    /// the boot menu: the running root, labelled with the newest
    /// generation, then every older one, from a fresh writable copy of its
    /// record, then the system from before generations.
    pub fn writeMenu(m: *const Machine, head: []const u8, records: []const generation.Record) !?[]const u8 {
        if (records.len == 0) return "no generations to put in the menu";
        const cmdline = m.cmdline orelse try rootfs.readProc(m.a, m.io, "/proc/cmdline");
        var entries: std.ArrayList(menu.Entry) = .empty;
        // records come sorted by number.
        const latest = records[records.len - 1];
        if (try generation.spareCopy(m.a, records, m.boot.root_subvol orelse "")) |spare| {
            if (try m.drop(try m.at(&.{spare}))) |w| return w;
        }
        var newest = try m.entry("head", try generation.title(m.a, latest), head, cmdline);
        if (m.headOnEsp(head)) newest.esp_dir = "";
        try entries.append(m.a, newest);
        var i = records.len;
        while (i > 0) {
            i -= 1;
            const r = records[i];
            if (r.n == latest.n) continue;
            const copy = try generation.bootCopy(m.a, r.n);
            if (try m.freshCopy(r.n, copy)) |w| return w;
            try entries.append(m.a, try m.entry(try menu.genId(m.a, r.n), try generation.title(m.a, r), copy, cmdline));
        }
        for (records) |r| {
            const from = r.from orelse continue;
            try entries.append(m.a, try m.entry("before", "the system before generations", from, cmdline));
        }
        const put: MenuWriter = switch (m.loader) {
            .grub => writeGrub,
            .limine => writeLimine,
            .@"systemd-boot" => writeSdboot,
            .refind => writeRefind,
        };
        return m.writeOnEsp(entries.items, records, put);
    }

    /// puts the menu in place, for entries whose files are where it says.
    const MenuWriter = *const fn (*const Machine, []menu.Entry) anyerror!?[]const u8;

    fn writeGrub(m: *const Machine, entries: []menu.Entry) anyerror!?[]const u8 {
        return m.write(try std.fs.path.join(m.a, &.{ m.boot.esp.?, "grub/grub.cfg" }), try menu.grub(m.a, .{ .esp_uuid = m.esp_uuid, .root_uuid = m.root_uuid, .default = "head", .entries = entries }));
    }

    fn write(m: *const Machine, path: []const u8, text: []const u8) !?[]const u8 {
        return writeFile(m.a, m.io, path, text);
    }

    /// the loader's own config, which os adds its entries to.
    fn loaderConf(m: *const Machine) !?[]const u8 {
        const path = m.boot.loader_conf orelse return null;
        return std.Io.Dir.cwd().readFileAlloc(m.io, path, m.a, .limited(1 << 20)) catch null;
    }

    /// puts the boot files entries need on the esp, then the menu. for a
    /// bootloader that can't read the roots (see menu.copiesOnEsp),
    /// entries whose files are in a root's /boot get copies on the esp,
    /// named by content so generations share them. an entry for a root
    /// with os's ukify config starts a unified kernel image there instead,
    /// on every bootloader, built from the same files and shared the same
    /// way. files that don't fit leave everything as it was, and say which
    /// of `records` to remove to make room. `put` puts the menu in place;
    /// then copies and images no entry uses any more go.
    fn writeOnEsp(m: *const Machine, entries: []menu.Entry, records: []const generation.Record, put: MenuWriter) !?[]const u8 {
        const dir = try std.fs.path.join(m.a, &.{ m.boot.esp.?, esp_boot_dir });
        const copies = menu.copiesOnEsp(m.boot);
        const images = try m.a.alloc(bool, entries.len);
        var any_image = false;
        for (entries, images) |e, *u| {
            u.* = rootfs.pathExists(m.io, try m.at(&.{ e.subvol, uki.config_rel }));
            any_image = any_image or u.*;
        }
        if (!copies and !any_image) {
            if (try put(m, entries)) |w| return w;
            // images from before `[boot] uki` went off.
            m.removeUnused(dir, &.{}, "", "");
            return null;
        }
        if (try m.run(&.{ "mkdir", "-p", dir })) |w| return w;
        var used: std.ArrayList([]const u8) = .empty;
        var missing: std.ArrayList(EspCopy) = .empty;
        var builds: std.ArrayList(UkiBuild) = .empty;
        for (entries, images) |*e, image| {
            if (image) {
                if (try m.ukiName(e, &used, &builds)) |w| return w;
                continue;
            }
            if (!copies or e.esp_dir != null) continue;
            const from = try m.at(&.{ e.subvol, "boot" });
            if (try m.espName(from, &e.kernel, &used, &missing)) |w| return w;
            const initrds = try m.a.dupe([]const u8, e.initrds);
            for (initrds) |*i| {
                if (try m.espName(from, i, &used, &missing)) |w| return w;
            }
            e.initrds = initrds;
            e.esp_dir = esp_boot_dir;
        }
        var need: u64 = 0;
        for (missing.items) |c| need += c.size;
        for (builds.items) |b| need += b.size;
        if (need > 0) {
            if (rootfs.freeBytes(dir)) |room| {
                if (try generation.espRoom(m.a, m.boot.esp.?, need, room, records, m.boot.root_subvol orelse "", true)) |w| return w;
            }
        }
        for (missing.items) |c| {
            if (try m.replaceFile(c.src, c.dest)) |w| return w;
        }
        for (builds.items) |b| {
            if (try m.buildUki(b)) |w| return w;
        }
        if (try put(m, entries)) |w| return w;
        m.removeUnused(dir, used.items, "", "");
        return null;
    }

    /// a unified kernel image the esp doesn't have yet: the root whose
    /// tools build it, its files, kernel first, and where it goes.
    const UkiBuild = struct { root: []const u8, files: []const []const u8, dest: []const u8, size: u64 };

    /// makes `e` start a unified kernel image of its kernel and initrds,
    /// named by their content, and adds the name to `used`. if the esp
    /// doesn't have it yet, it goes in `builds`.
    fn ukiName(m: *const Machine, e: *menu.Entry, used: *std.ArrayList([]const u8), builds: *std.ArrayList(UkiBuild)) !?[]const u8 {
        // the newest entry's files may be the esp's own, with /boot there.
        const from = if (e.esp_dir) |d| try std.fs.path.join(m.a, &.{ m.boot.esp.?, d }) else try m.at(&.{ e.subvol, "boot" });
        var files: std.ArrayList([]const u8) = .empty;
        var sums: std.ArrayList([]const u8) = .empty;
        var size: u64 = uki.stub_size;
        for (try std.mem.concat(m.a, []const u8, &.{ &.{e.kernel}, e.initrds })) |name| {
            const src = try std.fs.path.join(m.a, &.{ from, name });
            const sum = switch (try exec.output(m.a, m.io, &.{ "sha256sum", src })) {
                .ok => |t| t,
                .failed => |w| return w,
            };
            if (sum.len < 64) return try std.fmt.allocPrint(m.a, "can't hash {s}", .{src});
            const st = std.Io.Dir.cwd().statFile(m.io, src, .{}) catch return try std.fmt.allocPrint(m.a, "can't read {s}", .{src});
            try files.append(m.a, src);
            try sums.append(m.a, sum[0..64]);
            size += st.size;
        }
        const name = try uki.name(m.a, sums.items);
        e.uki = name;
        e.esp_dir = esp_boot_dir;
        if (lists.contains(used.items, name)) return null;
        try used.append(m.a, name);
        const dest = try std.fs.path.join(m.a, &.{ m.boot.esp.?, esp_boot_dir, name });
        if (rootfs.pathExists(m.io, dest)) return null;
        try builds.append(m.a, .{ .root = try m.at(&.{e.subvol}), .files = files.items, .dest = dest, .size = size });
        return null;
    }

    /// builds a unified kernel image with ukify, chrooted into the root
    /// it's for, so it's that root's ukify and stub, which a root staged
    /// with `[boot] uki` has even when the running one doesn't. its files
    /// go into a directory in the root first, since the esp isn't in
    /// there, and nothing has to be mounted for this. reflinks keep that
    /// cheap for files from the root's own /boot.
    fn buildUki(m: *const Machine, b: UkiBuild) !?[]const u8 {
        const work = try std.fs.path.join(m.a, &.{ b.root, uki.work_dir });
        if (try exec.runAll(m.a, m.io, &.{ &.{ "rm", "-rf", work }, &.{ "mkdir", "-p", work } })) |w| return w;
        defer _ = exec.run(m.a, m.io, &.{ "rm", "-rf", work }) catch null;
        var inside: std.ArrayList([]const u8) = .empty;
        for (b.files) |f| {
            const base = std.fs.path.basename(f);
            if (try m.run(&.{ "cp", "--reflink=auto", f, try std.fs.path.join(m.a, &.{ work, base }) })) |w| return w;
            try inside.append(m.a, try std.fmt.allocPrint(m.a, "/{s}/{s}", .{ uki.work_dir, base }));
        }
        const out = "/" ++ uki.work_dir ++ "/yoq.efi";
        if (try m.run(try uki.ukifyArgv(m.a, b.root, inside.items[0], inside.items[1..], out))) |w| {
            return try std.fmt.allocPrint(m.a, "can't build a unified kernel image in {s}: {s}", .{ b.root, w });
        }
        return m.replaceFile(try std.fs.path.join(m.a, &.{ work, "yoq.efi" }), b.dest);
    }

    /// a boot file the esp doesn't have yet, and where it goes.
    const EspCopy = struct { src: []const u8, dest: []const u8, size: u64 };

    /// deletes the files in `dir` named `prefix`*`suffix` that aren't in
    /// `used`.
    fn removeUnused(m: *const Machine, dir: []const u8, used: []const []const u8, prefix: []const u8, suffix: []const u8) void {
        var d = std.Io.Dir.cwd().openDir(m.io, dir, .{ .iterate = true }) catch return;
        defer d.close(m.io);
        var it = d.iterate();
        while (it.next(m.io) catch null) |f| {
            if (!std.mem.startsWith(u8, f.name, prefix) or !std.mem.endsWith(u8, f.name, suffix)) continue;
            if (!lists.contains(used, f.name)) d.deleteFile(m.io, f.name) catch {};
        }
    }

    fn writeLimine(m: *const Machine, entries: []menu.Entry) anyerror!?[]const u8 {
        const conf = try m.loaderConf() orelse return "can't read limine.conf";
        return m.write(m.boot.loader_conf.?, try menu.spliceLimine(m.a, conf, try menu.limine(m.a, entries)));
    }

    /// os's entry files in systemd-boot's loader/entries, beside
    /// loader.conf. yoq-*.conf files no entry needs any more go.
    fn writeSdboot(m: *const Machine, entries: []menu.Entry) anyerror!?[]const u8 {
        const dir = try m.sdbootEntries();
        if (try m.run(&.{ "mkdir", "-p", dir })) |w| return w;
        const files = try menu.sdboot(m.a, entries);
        var names: std.ArrayList([]const u8) = .empty;
        for (files) |f| {
            if (try m.write(try std.fs.path.join(m.a, &.{ dir, f.name }), f.text)) |w| return w;
            try names.append(m.a, f.name);
        }
        m.removeUnused(dir, names.items, "yoq-", ".conf");
        return null;
    }

    /// systemd-boot's entries directory, beside its loader.conf.
    pub fn sdbootEntries(m: *const Machine) ![]const u8 {
        const conf = m.boot.loader_conf orelse try std.fs.path.join(m.a, &.{ m.boot.esp.?, "loader/loader.conf" });
        return std.fs.path.join(m.a, &.{ std.fs.path.dirnamePosix(conf).?, "entries" });
    }

    /// makes `name`, a file in `from`, the name of its copy in the esp's
    /// boot directory, "<hash>-<name>", and adds that to `used`. if the
    /// esp doesn't have it yet, it goes in `missing`.
    fn espName(m: *const Machine, from: []const u8, name: *[]const u8, used: *std.ArrayList([]const u8), missing: *std.ArrayList(EspCopy)) !?[]const u8 {
        const src = try std.fs.path.join(m.a, &.{ from, name.* });
        const sum = switch (try exec.output(m.a, m.io, &.{ "sha256sum", src })) {
            .ok => |t| t,
            .failed => |w| return w,
        };
        if (sum.len < 16) return try std.fmt.allocPrint(m.a, "can't hash {s}", .{src});
        const copy = try std.fmt.allocPrint(m.a, "{s}-{s}", .{ sum[0..16], name.* });
        name.* = copy;
        if (lists.contains(used.items, copy)) return null;
        try used.append(m.a, copy);
        const dest = try std.fs.path.join(m.a, &.{ m.boot.esp.?, esp_boot_dir, copy });
        if (rootfs.pathExists(m.io, dest)) return null;
        const st = std.Io.Dir.cwd().statFile(m.io, src, .{}) catch return try std.fmt.allocPrint(m.a, "can't read {s}", .{src});
        try missing.append(m.a, .{ .src = src, .dest = dest, .size = st.size });
        return null;
    }

    /// copies `src` beside `dest` and renames it into place, so `dest`
    /// is never half written. the copy is synced before the rename: a
    /// kernel copy on the esp is reused by its name, and the menu that
    /// boots it is synced too.
    fn replaceFile(m: *const Machine, src: []const u8, dest: []const u8) !?[]const u8 {
        const tmp = try std.fmt.allocPrint(m.a, "{s}.yoq-new", .{dest});
        const why = try exec.runAll(m.a, m.io, &.{ &.{ "cp", src, tmp }, &.{ "sync", tmp }, &.{ "mv", "-f", tmp, dest } }) orelse return null;
        // a copy cut short, by a full esp say, would only take up room.
        std.Io.Dir.cwd().deleteFile(m.io, tmp) catch {};
        return why;
    }

    /// refind reads btrfs through its driver, so entries boot from each
    /// root's own /boot, unless the root is on luks. os's entries go in
    /// yoq.conf beside refind.conf, which includes it, and the driver goes
    /// in if it's missing.
    fn writeRefind(m: *const Machine, entries: []menu.Entry) anyerror!?[]const u8 {
        const conf = try m.loaderConf() orelse return "can't read refind.conf";
        for (entries) |e| {
            if (try menu.refindArgsProblem(m.a, e.args)) |w| return w;
        }
        const dir = std.fs.path.dirnamePosix(m.boot.loader_conf.?).?;
        const driver = try std.fs.path.join(m.a, &.{ dir, "drivers_x64/btrfs_x64.efi" });
        if (!rootfs.pathExists(m.io, driver)) {
            if (try m.run(&.{ "install", "-D", "-m", "0644", "/usr/share/refind/drivers_x64/btrfs_x64.efi", driver })) |w| return w;
        }
        var why: []const u8 = "";
        // a device mapper root, as on luks, has no partition guid, and
        // every entry is on the esp then.
        const root_part = for (entries) |e| {
            if (e.esp_dir == null) break try blkid(m.a, m.io, m.boot.root_device.?, "PARTUUID", &why) orelse return why;
        } else "";
        const text = try menu.refind(m.a, .{
            .esp_part = try blkid(m.a, m.io, m.boot.esp_device.?, "PARTUUID", &why) orelse return why,
            .root_part = root_part,
            .entries = entries,
        });
        // with a trial waiting, refind's own default stays the generation
        // a failed trial falls back to.
        var file = text;
        if (trial.Store.of(m.a, m.io, m.boot)) |store| if (try store.current()) |t| {
            if (lists.find(entries, "id", try menu.genId(m.a, t.fallback))) |e| file = try menu.refindDefault(m.a, text, e.title);
        };
        if (try m.write(try std.fs.path.join(m.a, &.{ dir, menu.refind_file }), file)) |w| return w;
        return m.write(m.boot.loader_conf.?, try menu.spliceRefind(m.a, conf));
    }

    /// remakes generation `n`'s writable copy from its record, so booting
    /// it always starts from the generation as it was. the copy that's
    /// running, if it's this one, is left alone.
    fn freshCopy(m: *const Machine, n: u32, copy: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, m.boot.root_subvol.?, copy)) return null;
        const path = try m.at(&.{copy});
        if (try m.drop(path)) |w| return w;
        btrfs.snapshot(try m.numbered(generation.gens_dir, n), path, false) catch |e| return try std.fmt.allocPrint(m.a, "can't copy generation {d}: {s}", .{ n, @errorName(e) });
        return m.carry(copy);
    }

    /// carries the running machine's own state into the root at `subvol`:
    /// its identity, host keys, clock, id ranges, keyring, passwords, and
    /// the system accounts it lacks. a generation holds the system, not
    /// these.
    pub fn carry(m: *const Machine, subvol: []const u8) !?[]const u8 {
        const root = try m.at(&.{subvol});
        var paths: std.ArrayList([]const u8) = .empty;
        try paths.appendSlice(m.a, &carried);
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

    /// whether the newest entry, for the root at `head`, boots the kernel
    /// on the esp: when /boot is the esp and `head` is the root running.
    /// a root not booted yet, like a staged one, keeps its own until a
    /// good boot puts it on the esp, so the running kernel stays there.
    fn headOnEsp(m: *const Machine, head: []const u8) bool {
        return m.bootOnEsp() and std.mem.eql(u8, head, m.boot.root_subvol orelse "") and !m.unsettled(head);
    }

    /// whether /boot is the esp, as archinstall sets it up. kernels then
    /// live outside every root, so each root keeps copies of its own in
    /// its /boot directory, under the mount, where grub and refind read
    /// them, and limine copies them from.
    pub fn bootOnEsp(m: *const Machine) bool {
        return m.esp_is_boot orelse std.mem.eql(u8, m.boot.esp orelse "", "/boot");
    }

    /// copies the esp's boot files into the root at `subvol`, so its
    /// snapshots boot the kernel that matches their modules. a root whose
    /// own files aren't on the esp yet keeps them.
    pub fn keepBoot(m: *const Machine, subvol: []const u8) !?[]const u8 {
        if (!m.bootOnEsp() or m.unsettled(subvol)) return null;
        var why: []const u8 = "";
        const from = m.boot.esp.?;
        const to = try m.at(&.{ subvol, "boot" });
        return m.syncBoot(from, to, try m.bootSync(from, to, &why) orelse return why);
    }

    /// puts the boot files kept in the root at `subvol` back on the esp,
    /// for a root that's about to be the newest. when they don't all fit,
    /// none are copied.
    pub fn restoreBoot(m: *const Machine, subvol: []const u8) !Put {
        if (!m.bootOnEsp()) return .done;
        var why: []const u8 = "";
        const from = try m.at(&.{ subvol, "boot" });
        const esp = m.boot.esp.?;
        const s = try m.bootSync(from, esp, &why) orelse return .{ .failed = why };
        if (rootfs.freeBytes(esp)) |room| {
            // older generations' copies may be there too, which `os gc`
            // frees.
            const collectable = menu.copiesOnEsp(m.boot);
            const records = try readRecords(m.a, m.io, "/var");
            if (try generation.espRoom(m.a, esp, generation.copyPeak(s.sizes.items), room, records, m.boot.root_subvol orelse "", collectable)) |w| return .{ .full = w };
        }
        if (try m.syncBoot(from, esp, s)) |w| return .{ .failed = w };
        return .done;
    }

    /// whether the root at `subvol` boots the kernel in its own /boot,
    /// since its boot files aren't on the esp yet: it was staged, or they
    /// didn't fit there, and no good boot has put them there since.
    pub fn unsettled(m: *const Machine, subvol: []const u8) bool {
        const note = std.Io.Dir.cwd().readFileAlloc(m.io, generation.unsettled_path, m.a, .limited(256)) catch return false;
        return std.mem.eql(u8, std.mem.trim(u8, note, " \n"), subvol);
    }

    /// what making the boot files in `to` match the ones in `from` takes:
    /// the files to copy, with the room each takes, and the stale ones to
    /// remove. files that already match stay, so snapshots keep sharing
    /// them. null after saying why in `why`.
    fn bootSync(m: *const Machine, from: []const u8, to: []const u8, why: *[]const u8) !?BootSync {
        const old = try m.bootFiles(to) orelse return try m.syncFailed(why, "can't read {s}", .{to});
        const new = try m.bootFiles(from) orelse return try m.syncFailed(why, "can't read {s}", .{from});
        var s: BootSync = .{};
        for (new) |f| {
            const src = try std.fs.path.join(m.a, &.{ from, f });
            const dest = try std.fs.path.join(m.a, &.{ to, f });
            var replaces: u64 = 0;
            if (std.Io.Dir.cwd().statFile(m.io, dest, .{})) |st| {
                if (try m.run(&.{ "cmp", "-s", src, dest }) == null) continue;
                replaces = st.size;
            } else |_| {}
            const st = std.Io.Dir.cwd().statFile(m.io, src, .{}) catch return try m.syncFailed(why, "can't read {s}", .{src});
            try s.copy.append(m.a, f);
            try s.sizes.append(m.a, .{ .size = st.size, .replaces = replaces });
        }
        for (old) |f| {
            if (!lists.contains(new, f)) try s.stale.append(m.a, f);
        }
        return s;
    }

    /// makes the boot files in `to` match the ones in `from`, as `s` says.
    /// each new one is copied beside its place and renamed in, and stale
    /// ones go last, so a failure halfway never leaves a file cut short.
    fn syncBoot(m: *const Machine, from: []const u8, to: []const u8, s: BootSync) !?[]const u8 {
        for (s.copy.items) |f| {
            if (try m.replaceFile(try std.fs.path.join(m.a, &.{ from, f }), try std.fs.path.join(m.a, &.{ to, f }))) |w| return w;
        }
        for (s.stale.items) |f| {
            if (try m.run(&.{ "rm", "-f", try std.fs.path.join(m.a, &.{ to, f }) })) |w| return w;
        }
        return null;
    }

    const BootSync = struct {
        copy: std.ArrayList([]const u8) = .empty,
        sizes: std.ArrayList(generation.Copy) = .empty,
        stale: std.ArrayList([]const u8) = .empty,
    };

    fn syncFailed(m: *const Machine, why: *[]const u8, comptime fmt: []const u8, args: anytype) !?BootSync {
        why.* = try std.fmt.allocPrint(m.a, fmt, args);
        return null;
    }

    fn bootFiles(m: *const Machine, path: []const u8) !?[]const []const u8 {
        var dir = std.Io.Dir.cwd().openDir(m.io, path, .{ .iterate = true }) catch return null;
        defer dir.close(m.io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (it.next(m.io) catch null) |f| {
            if (f.kind == .file and generation.bootFile(f.name)) try names.append(m.a, try m.a.dupe(u8, f.name));
        }
        return names.items;
    }

    /// a menu entry for the root at `subvol`: its kernel, microcode, and
    /// initramfs, from its own /boot, or the esp's for the newest.
    pub fn entry(m: *const Machine, id: []const u8, name: []const u8, subvol: []const u8, cmdline: []const u8) !menu.Entry {
        var kernels: std.ArrayList([]const u8) = .empty;
        var initrds: std.ArrayList([]const u8) = .empty;
        const dir = if (std.mem.eql(u8, id, "head") and m.headOnEsp(subvol)) m.boot.esp.? else try m.at(&.{ subvol, "boot" });
        var boot = std.Io.Dir.cwd().openDir(m.io, dir, .{ .iterate = true }) catch null;
        if (boot) |*b| {
            defer b.close(m.io);
            var it = b.iterate();
            while (it.next(m.io) catch null) |f| {
                if (std.mem.startsWith(u8, f.name, "vmlinuz-")) try kernels.append(m.a, try m.a.dupe(u8, f.name));
                if (std.mem.endsWith(u8, f.name, "-ucode.img")) try initrds.append(m.a, try m.a.dupe(u8, f.name));
            }
        }
        // the same pick every time the menu is written: arch's own kernel
        // if it's there, or the first by name.
        lists.sortStrings(kernels.items);
        lists.sortStrings(initrds.items);
        const kernel = if (lists.contains(kernels.items, "vmlinuz-linux") or kernels.items.len == 0) "vmlinuz-linux" else kernels.items[0];
        try initrds.append(m.a, try std.fmt.allocPrint(m.a, "initramfs-{s}.img", .{kernel["vmlinuz-".len..]}));
        return .{
            .id = id,
            .title = name,
            .subvol = subvol,
            .kernel = kernel,
            .initrds = initrds.items,
            .args = try generation.kernelArgs(m.a, cmdline, m.root_uuid, subvol),
        };
    }
};

/// how putting a root's boot files on the esp went.
pub const Put = union(enum) {
    done,
    /// they don't fit, so none were copied: what to say.
    full: []const u8,
    failed: []const u8,

    pub fn problem(p: Put) ?[]const u8 {
        return switch (p) {
            .done => null,
            .full, .failed => |w| w,
        };
    }
};

/// a notice for `os status`, about something os did on its own, like
/// falling back from a generation that didn't start. the next generation
/// recorded clears it.
pub const notice_path = "/var/lib/yoq/notice";

pub fn writeNotice(a: Allocator, io: std.Io, text: []const u8) !?[]const u8 {
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = notice_path, .data = text }) catch return try std.fmt.allocPrint(a, "can't write {s}", .{notice_path});
    return null;
}

/// machine state every root gets from the running system. ssh host keys
/// are added by name, and passwords are merged into /etc/shadow.
const carried = [_][]const u8{ "etc/machine-id", "etc/adjtime", "etc/subuid", "etc/subgid", "etc/pacman.d/gnupg" };

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

pub fn writeRecord(a: Allocator, io: std.Io, var_dir: []const u8, r: generation.Record) !?[]const u8 {
    var json: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(r, .{}, &json.writer);
    try json.writer.writeByte('\n');
    return writeFile(a, io, try recordPath(a, var_dir, r.n), json.written());
}

/// writes `text` to `path` whole, or says it couldn't.
fn writeFile(a: Allocator, io: std.Io, path: []const u8, text: []const u8) !?[]const u8 {
    rootfs.writeAtomic(io, path, text, null) catch return try std.fmt.allocPrint(a, "can't write {s}", .{path});
    return null;
}

pub fn recordPath(a: Allocator, var_dir: []const u8, n: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}/{d}.json", .{ var_dir, generation.records_dir, n });
}

/// writes os's units that run at boot (enable.units) into the root at
/// `root`, and turns them on there. `os_path` is the os they run.
pub fn writeUnits(a: Allocator, io: std.Io, root: []const u8, os_path: []const u8) !?[]const u8 {
    const dir = try std.fs.path.join(a, &.{ root, "etc/systemd/system" });
    for (try enable.units(a, os_path)) |u| {
        const text = try std.fmt.allocPrint(a, "# written by os.\n{s}", .{u.text});
        if (try writeFile(a, io, try std.fs.path.join(a, &.{ dir, u.name }), text)) |w| return w;
        const link = try u.wantsLink(a) orelse continue;
        const at = try std.fs.path.join(a, &.{ dir, link });
        if (try exec.runAll(a, io, &.{
            &.{ "mkdir", "-p", std.fs.path.dirnamePosix(at).? },
            &.{ "ln", "-sf", try std.fmt.allocPrint(a, "../{s}", .{u.name}), at },
        })) |w| return w;
    }
    return null;
}

/// where the hibernation block goes: in /run, so the next boot, whichever
/// generation it runs, lifts it.
pub const no_hibernate = "/run/systemd/sleep.conf.d/yoq.conf";

/// keeps the machine from hibernating until it reboots. resuming goes
/// through the bootloader, which would start the next generation's kernel
/// with the memory of the one running now.
pub fn blockHibernation(io: std.Io) void {
    rootfs.writeAtomic(io, no_hibernate,
        \\# written by os: a new generation is waiting for the next boot.
        \\[Sleep]
        \\AllowHibernation=no
        \\AllowHybridSleep=no
        \\AllowSuspendThenHibernate=no
        \\
    , null) catch {};
}

/// where copies of boot files, and unified kernel images, go on the esp.
pub const esp_boot_dir = "yoq/boot";

/// grub-install's arguments for grub on `esp`, reading its menu from
/// `boot_dir`, on the efi path grub boots from now: its own directory
/// under EFI/, or the removable path, EFI/BOOT.
pub fn grubInstall(a: Allocator, io: std.Io, esp: []const u8, boot_dir: []const u8) ![]const []const u8 {
    return a.dupe([]const u8, &.{
        "grub-install",
        "--target=x86_64-efi",
        try std.fmt.allocPrint(a, "--efi-directory={s}", .{esp}),
        try std.fmt.allocPrint(a, "--boot-directory={s}", .{boot_dir}),
        try grubEfiPath(a, io, esp),
    });
}

/// grub-install's argument for the efi path grub boots from on `esp`.
fn grubEfiPath(a: Allocator, io: std.Io, esp: []const u8) ![]const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, try std.fs.path.join(a, &.{ esp, "EFI" }), .{ .iterate = true }) catch return "--removable";
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |d| {
        if (d.kind != .directory or std.ascii.eqlIgnoreCase(d.name, "BOOT")) continue;
        dir.access(io, try std.fs.path.join(a, &.{ d.name, "grubx64.efi" }), .{}) catch continue;
        return std.fmt.allocPrint(a, "--bootloader-id={s}", .{d.name});
    }
    return "--removable";
}

/// one of blkid's tags for a device, like its "UUID" or "PARTUUID".
fn blkid(a: Allocator, io: std.Io, device: []const u8, tag: []const u8, why: *[]const u8) !?[]const u8 {
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
    try std.testing.expectEqualStrings("yoq 2 · 2026-09-26 · add fd", try generation.title(a, got[1]));
}

test "grub-install keeps grub's efi path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const esp = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const argv = try grubInstall(a, io, esp, "/boot");
    try std.testing.expectEqualStrings("--boot-directory=/boot", argv[3]);
    try std.testing.expectEqualStrings("--removable", argv[4]);
    try tmp.dir.createDirPath(io, "EFI/BOOT");
    try tmp.dir.writeFile(io, .{ .sub_path = "EFI/BOOT/grubx64.efi", .data = "" });
    try std.testing.expectEqualStrings("--removable", try grubEfiPath(a, io, esp));
    try tmp.dir.createDirPath(io, "EFI/arch");
    try tmp.dir.writeFile(io, .{ .sub_path = "EFI/arch/grubx64.efi", .data = "" });
    try std.testing.expectEqualStrings("--bootloader-id=arch", try grubEfiPath(a, io, esp));
}

/// the entries a test's menu writer was given.
var test_put: []const menu.Entry = &.{};

fn testPut(_: *const Machine, entries: []menu.Entry) anyerror!?[]const u8 {
    test_put = entries;
    return null;
}

test "entries for a root with os's ukify config start its image, and unused images go" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    // generation 2 boots an image, and generation 1 its root's own files.
    try tmp.dir.createDirPath(io, "top/@roots/2/boot");
    try tmp.dir.createDirPath(io, "top/@roots/2/etc/kernel");
    try tmp.dir.createDirPath(io, "top/@roots/1/boot");
    try tmp.dir.createDirPath(io, "esp/yoq/boot");
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ uki.config_rel, .data = uki.config_content });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/vmlinuz-linux", .data = "kernel" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/initramfs-linux.img", .data = "initramfs" });
    const name = try uki.name(a, &.{ &facts.sha256Hex("kernel"), &facts.sha256Hex("initramfs") });
    // the image is there already, so nothing's built; an older one isn't
    // used any more.
    try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "esp/yoq/boot/{s}", .{name}), .data = "image" });
    try tmp.dir.writeFile(io, .{ .sub_path = "esp/yoq/boot/0123456789abcdef-yoq.efi", .data = "old" });
    const m: Machine = .{
        .a = a,
        .io = io,
        .boot = .{ .esp = try std.fmt.allocPrint(a, "{s}/esp", .{base}), .loader = "grub", .root_subvol = "/@roots/2" },
        .loader = .grub,
        .root_uuid = "r",
        .esp_uuid = "e",
        .top = try std.fmt.allocPrint(a, "{s}/top", .{base}),
    };
    var entries = [_]menu.Entry{
        .{ .id = "head", .title = "yoq 2", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" },
        .{ .id = "gen-1", .title = "yoq 1", .subvol = "/@roots/1", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" },
    };
    try std.testing.expectEqual(null, try m.writeOnEsp(&entries, &.{}, testPut));
    try std.testing.expectEqualStrings(name, test_put[0].uki.?);
    try std.testing.expectEqualStrings(esp_boot_dir, test_put[0].esp_dir.?);
    // grub reads generation 1's files in its root, as without images.
    try std.testing.expectEqual(null, test_put[1].uki);
    try std.testing.expectEqual(null, test_put[1].esp_dir);
    var esp = try tmp.dir.openDir(io, "esp/yoq/boot", .{ .iterate = true });
    defer esp.close(io);
    var it = esp.iterate();
    var left: std.ArrayList([]const u8) = .empty;
    while (try it.next(io)) |f| try left.append(a, try a.dupe(u8, f.name));
    try std.testing.expectEqual(1, left.items.len);
    try std.testing.expectEqualStrings(name, left.items[0]);

    // with [boot] uki off everywhere, the last image goes too.
    try tmp.dir.deleteFile(io, "top/@roots/2/" ++ uki.config_rel);
    entries[0] = .{ .id = "head", .title = "yoq 3", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" };
    try std.testing.expectEqual(null, try m.writeOnEsp(&entries, &.{}, testPut));
    try std.testing.expectEqual(null, test_put[0].uki);
    try std.testing.expectError(error.FileNotFound, esp.access(io, name, .{}));
}
