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
const trial = @import("trial.zig");
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

    /// starts a new generation from `source`, a generation's record or a
    /// copy of one: a writable root of its own, recorded and at the top of
    /// the menu, so the next boot runs it. its number goes in `made`. if a
    /// step fails, the new generation goes, and the menu is as it was.
    pub fn start(m: *const Machine, source: []const u8, reason: []const u8, time: i64, config: ?generation.Config, made: *u32) !?[]const u8 {
        const records = try readRecords(m.a, m.io, "/var");
        const n = try m.free(records);
        const root = try std.fmt.allocPrint(m.a, "/{s}/{d}", .{ generation.roots_dir, n });
        btrfs.snapshot(try m.at(&.{source}), try m.at(&.{root}), false) catch |e| return try std.fmt.allocPrint(m.a, "can't copy {s}: {s}", .{ source, @errorName(e) });
        // the esp's boot files change last, once the new root is recorded.
        const why = try m.carry(root) orelse try m.add(records, n, root, reason, time, config) orelse try m.restoreBoot(root) orelse {
            made.* = n;
            return null;
        };
        // what cleaning up couldn't do matters too: a menu left as it was
        // written for the new root points at one that's gone.
        const left = try m.forget(n) orelse try m.drop(try m.at(&.{root}));
        const menu_left = try m.writeMenu(m.boot.root_subvol.?, records);
        // the running root's kernel goes back on the esp, if it left.
        const boot_left = try m.restoreBoot(m.boot.root_subvol.?);
        if (menu_left orelse boot_left) |w| return try std.fmt.allocPrint(m.a, "{s}. putting the boot menu back failed too, so it may still name the root that was removed: {s}", .{ why, w });
        if (left) |w| return try std.fmt.allocPrint(m.a, "{s}. generation {d} couldn't be removed either: {s}", .{ why, n, w });
        return why;
    }

    /// the next generation, from the root at `root`: its read-only record,
    /// the record file, and the menu with `root` at the top.
    fn add(m: *const Machine, records: []const generation.Record, n: u32, root: []const u8, reason: []const u8, time: i64, config: ?generation.Config) !?[]const u8 {
        const dest = try m.at(&.{ generation.gens_dir, try std.fmt.allocPrint(m.a, "{d}", .{n}) });
        btrfs.snapshot(try m.at(&.{root}), dest, true) catch |e| return try std.fmt.allocPrint(m.a, "can't snapshot {s}: {s}", .{ root, @errorName(e) });
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
        var kept: std.ArrayList(generation.Record) = .empty;
        var roots: std.ArrayList([]const u8) = .empty;
        try roots.append(m.a, running[1..]);
        for (records) |r| {
            if (!generation.keeps(r, records, keep) and r.n != fallback) continue;
            try kept.append(m.a, r);
            try roots.append(m.a, r.root);
        }
        if (kept.items.len == records.len) return null;
        const head = try std.fmt.allocPrint(m.a, "/{s}", .{records[records.len - 1].root});
        const failed = try m.dropOld(records, keep, fallback, running, &roots, removed);
        // the menu follows what's left, even after a failure halfway.
        const left = try readRecords(m.a, m.io, "/var");
        if (try m.writeMenu(head, left)) |w| return failed orelse w;
        return failed;
    }

    fn dropOld(m: *const Machine, records: []const generation.Record, keep: usize, fallback: u32, running: []const u8, roots: *std.ArrayList([]const u8), removed: *std.ArrayList(u32)) !?[]const u8 {
        for (records) |r| {
            if (generation.keeps(r, records, keep) or r.n == fallback) continue;
            if (try m.forget(r.n)) |w| return w;
            const copy = try generation.bootCopy(m.a, r.n);
            if (!std.mem.eql(u8, copy, running)) {
                if (try m.drop(try m.at(&.{copy}))) |w| return w;
            }
            var used = false;
            for (roots.items) |root| used = used or std.mem.eql(u8, root, r.root);
            if (!used and std.mem.startsWith(u8, r.root, generation.roots_dir ++ "/")) {
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
    fn free(m: *const Machine, records: []const generation.Record) !u32 {
        var n = generation.next(records);
        while (true) : (n += 1) {
            const name = try std.fmt.allocPrint(m.a, "{d}", .{n});
            if (!rootfs.pathExists(m.io, try m.at(&.{ generation.gens_dir, name })) and
                !rootfs.pathExists(m.io, try m.at(&.{ generation.roots_dir, name }))) return n;
        }
    }

    /// removes generation `n`'s record, then its read-only snapshot, so
    /// a failure between the two leaves no record without a snapshot.
    fn forget(m: *const Machine, n: u32) !?[]const u8 {
        std.Io.Dir.cwd().deleteFile(m.io, try recordPath(m.a, "/var", n)) catch {};
        return m.drop(try m.at(&.{ generation.gens_dir, try std.fmt.allocPrint(m.a, "{d}", .{n}) }));
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
        const cmdline = m.cmdline orelse try rootfs.readProc(m.a, m.io, "/proc/cmdline");
        var entries: std.ArrayList(menu.Entry) = .empty;
        if (records.len == 0) return "no generations to put in the menu";
        // records come sorted by number.
        const latest = records[records.len - 1];
        var newest_entry = try m.entry("head", try generation.title(m.a, latest), head, cmdline);
        if (m.bootOnEsp()) newest_entry.esp_dir = "";
        try entries.append(m.a, newest_entry);
        var i = records.len;
        while (i > 0) {
            i -= 1;
            const r = records[i];
            if (r.n == latest.n) continue;
            const copy = try generation.bootCopy(m.a, r.n);
            if (try m.freshCopy(r.n, copy)) |w| return w;
            try entries.append(m.a, try m.entry(try std.fmt.allocPrint(m.a, "gen-{d}", .{r.n}), try generation.title(m.a, r), copy, cmdline));
        }
        for (records) |r| {
            const from = r.from orelse continue;
            try entries.append(m.a, try m.entry("before", "the system before generations", from, cmdline));
        }
        return switch (m.loader) {
            .grub => m.write(try std.fs.path.join(m.a, &.{ m.boot.esp.?, "grub/grub.cfg" }), try menu.grub(m.a, .{ .esp_uuid = m.esp_uuid, .root_uuid = m.root_uuid, .default = "head", .entries = entries.items })),
            .limine => m.writeOnEsp(entries.items, writeLimine),
            .@"systemd-boot" => m.writeOnEsp(entries.items, writeSdboot),
            .refind => m.writeRefind(entries.items),
        };
    }

    fn write(m: *const Machine, path: []const u8, text: []const u8) !?[]const u8 {
        rootfs.writeAtomic(m.io, path, text, null) catch return try std.fmt.allocPrint(m.a, "can't write {s}", .{path});
        return null;
    }

    /// the loader's own config, which os adds its entries to.
    fn loaderConf(m: *const Machine) !?[]const u8 {
        const path = m.boot.loader_conf orelse return null;
        return std.Io.Dir.cwd().readFileAlloc(m.io, path, m.a, .limited(1 << 20)) catch null;
    }

    /// limine and systemd-boot read only fat, so entries whose files are
    /// in a root's /boot get copies on the esp, named by content so
    /// generations share them. `write` puts the menu in place; then copies
    /// no entry uses any more go.
    fn writeOnEsp(m: *const Machine, entries: []menu.Entry, comptime put: fn (*const Machine, []menu.Entry) anyerror!?[]const u8) !?[]const u8 {
        const dir = try std.fs.path.join(m.a, &.{ m.boot.esp.?, esp_boot_dir });
        if (try m.run(&.{ "mkdir", "-p", dir })) |w| return w;
        var used: std.ArrayList([]const u8) = .empty;
        var why: []const u8 = "";
        for (entries) |*e| {
            if (e.esp_dir != null) continue;
            const from = try m.at(&.{ e.subvol, "boot" });
            e.kernel = try m.espCopy(from, e.kernel, &used, &why) orelse return why;
            const initrds = try m.a.alloc([]const u8, e.initrds.len);
            for (e.initrds, initrds) |i, *out| out.* = try m.espCopy(from, i, &used, &why) orelse return why;
            e.initrds = initrds;
            e.esp_dir = esp_boot_dir;
        }
        if (try put(m, entries)) |w| return w;
        var d = std.Io.Dir.cwd().openDir(m.io, dir, .{ .iterate = true }) catch return null;
        defer d.close(m.io);
        var it = d.iterate();
        while (it.next(m.io) catch null) |f| {
            if (!lists.contains(used.items, f.name)) d.deleteFile(m.io, f.name) catch {};
        }
        return null;
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
        for (files) |f| {
            if (try m.write(try std.fs.path.join(m.a, &.{ dir, f.name }), f.text)) |w| return w;
        }
        var d = std.Io.Dir.cwd().openDir(m.io, dir, .{ .iterate = true }) catch return null;
        defer d.close(m.io);
        var it = d.iterate();
        while (it.next(m.io) catch null) |f| {
            if (!std.mem.startsWith(u8, f.name, "yoq-") or !std.mem.endsWith(u8, f.name, ".conf")) continue;
            if (lists.find(files, "name", f.name) == null) d.deleteFile(m.io, f.name) catch {};
        }
        return null;
    }

    /// systemd-boot's entries directory, beside its loader.conf.
    pub fn sdbootEntries(m: *const Machine) ![]const u8 {
        const conf = m.boot.loader_conf orelse try std.fs.path.join(m.a, &.{ m.boot.esp.?, "loader/loader.conf" });
        return std.fs.path.join(m.a, &.{ std.fs.path.dirnamePosix(conf).?, "entries" });
    }

    /// copies `name` from `from` into the esp's boot directory, as
    /// "<hash>-<name>", unless it's there already, and returns that name.
    fn espCopy(m: *const Machine, from: []const u8, name: []const u8, used: *std.ArrayList([]const u8), why: *[]const u8) !?[]const u8 {
        const src = try std.fs.path.join(m.a, &.{ from, name });
        const sum = switch (try exec.output(m.a, m.io, &.{ "sha256sum", src })) {
            .ok => |t| t,
            .failed => |w| {
                why.* = w;
                return null;
            },
        };
        if (sum.len < 16) {
            why.* = try std.fmt.allocPrint(m.a, "can't hash {s}", .{src});
            return null;
        }
        const copy = try std.fmt.allocPrint(m.a, "{s}-{s}", .{ sum[0..16], name });
        try used.append(m.a, copy);
        const dest = try std.fs.path.join(m.a, &.{ m.boot.esp.?, esp_boot_dir, copy });
        if (rootfs.pathExists(m.io, dest)) return copy;
        if (try m.replaceFile(src, dest)) |w| {
            why.* = w;
            return null;
        }
        return copy;
    }

    /// copies `src` beside `dest` and renames it into place, so `dest`
    /// is never half written.
    fn replaceFile(m: *const Machine, src: []const u8, dest: []const u8) !?[]const u8 {
        const tmp = try std.fmt.allocPrint(m.a, "{s}.yoq-new", .{dest});
        return exec.runAll(m.a, m.io, &.{ &.{ "cp", src, tmp }, &.{ "mv", "-f", tmp, dest } });
    }

    /// refind reads btrfs through its driver, so entries boot from each
    /// root's own /boot. os's entries go in yoq.conf beside refind.conf,
    /// which includes it, and the driver goes in if it's missing.
    fn writeRefind(m: *const Machine, entries: []const menu.Entry) !?[]const u8 {
        const conf = try m.loaderConf() orelse return "can't read refind.conf";
        const dir = std.fs.path.dirnamePosix(m.boot.loader_conf.?).?;
        const driver = try std.fs.path.join(m.a, &.{ dir, "drivers_x64/btrfs_x64.efi" });
        if (!rootfs.pathExists(m.io, driver)) {
            if (try m.run(&.{ "install", "-D", "-m", "0644", "/usr/share/refind/drivers_x64/btrfs_x64.efi", driver })) |w| return w;
        }
        var why: []const u8 = "";
        const text = try menu.refind(m.a, .{
            .esp_part = try blkid(m.a, m.io, m.boot.esp_device.?, "PARTUUID", &why) orelse return why,
            .root_part = try blkid(m.a, m.io, m.boot.root_device.?, "PARTUUID", &why) orelse return why,
            .entries = entries,
        });
        if (try m.write(try std.fs.path.join(m.a, &.{ dir, "yoq.conf" }), text)) |w| return w;
        return m.write(m.boot.loader_conf.?, try menu.spliceRefind(m.a, conf));
    }

    /// remakes generation `n`'s writable copy from its record, so booting
    /// it always starts from the generation as it was. the copy that's
    /// running, if it's this one, is left alone.
    fn freshCopy(m: *const Machine, n: u32, copy: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, m.boot.root_subvol.?, copy)) return null;
        const path = try m.at(&.{copy});
        if (try m.drop(path)) |w| return w;
        const saved = try m.at(&.{ generation.gens_dir, try std.fmt.allocPrint(m.a, "{d}", .{n}) });
        btrfs.snapshot(saved, path, false) catch |e| return try std.fmt.allocPrint(m.a, "can't copy generation {d}: {s}", .{ n, @errorName(e) });
        return m.carry(copy);
    }

    /// carries the running machine's own state into the root at `subvol`:
    /// its identity, host keys, clock, id ranges, keyring, and passwords.
    /// a generation holds the system, not these.
    fn carry(m: *const Machine, subvol: []const u8) !?[]const u8 {
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
        const merged = try generation.mergeShadow(m.a, try here.read("etc/shadow"), try fs.read("etc/shadow"));
        fs.writeMode("etc/shadow", merged, 0o600) catch return try std.fmt.allocPrint(m.a, "can't write {s}/etc/shadow", .{root});
        return null;
    }

    /// whether /boot is the esp, as archinstall sets it up. kernels then
    /// live outside every root, so each root keeps copies of its own in
    /// its /boot directory, under the mount, where grub and refind read
    /// them, and limine copies them from.
    pub fn bootOnEsp(m: *const Machine) bool {
        return m.esp_is_boot orelse std.mem.eql(u8, m.boot.esp orelse "", "/boot");
    }

    /// copies the esp's boot files into the root at `subvol`, so its
    /// snapshots boot the kernel that matches their modules.
    pub fn keepBoot(m: *const Machine, subvol: []const u8) !?[]const u8 {
        if (!m.bootOnEsp()) return null;
        return m.copyBoot(m.boot.esp.?, try m.at(&.{ subvol, "boot" }));
    }

    /// puts the boot files kept in the root at `subvol` back on the esp,
    /// for a root that's about to be the newest.
    fn restoreBoot(m: *const Machine, subvol: []const u8) !?[]const u8 {
        if (!m.bootOnEsp()) return null;
        return m.copyBoot(try m.at(&.{ subvol, "boot" }), m.boot.esp.?);
    }

    /// makes the boot files in `to` match the ones in `from`. files that
    /// already match stay, so snapshots keep sharing them. each new one is
    /// copied beside its place and renamed in, and stale ones go last, so
    /// a failure halfway never leaves a file cut short.
    fn copyBoot(m: *const Machine, from: []const u8, to: []const u8) !?[]const u8 {
        const old = try m.bootFiles(to) orelse return try std.fmt.allocPrint(m.a, "can't read {s}", .{to});
        const new = try m.bootFiles(from) orelse return try std.fmt.allocPrint(m.a, "can't read {s}", .{from});
        for (new) |f| {
            const src = try std.fs.path.join(m.a, &.{ from, f });
            const dest = try std.fs.path.join(m.a, &.{ to, f });
            if (rootfs.pathExists(m.io, dest) and try m.run(&.{ "cmp", "-s", src, dest }) == null) continue;
            if (try m.replaceFile(src, dest)) |w| return w;
        }
        for (old) |f| {
            if (lists.contains(new, f)) continue;
            if (try m.run(&.{ "rm", "-f", try std.fs.path.join(m.a, &.{ to, f }) })) |w| return w;
        }
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
        const dir = if (std.mem.eql(u8, id, "head") and m.bootOnEsp()) m.boot.esp.? else try m.at(&.{ subvol, "boot" });
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
    const path = try recordPath(a, var_dir, r.n);
    rootfs.writeAtomic(io, path, json.written(), null) catch return try std.fmt.allocPrint(a, "can't write {s}", .{path});
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
        const path = try std.fs.path.join(a, &.{ dir, u.name });
        const text = try std.fmt.allocPrint(a, "# written by os.\n{s}", .{u.text});
        rootfs.writeAtomic(io, path, text, null) catch return try std.fmt.allocPrint(a, "can't write {s}", .{path});
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

/// where limine's copies of boot files go, on the esp.
pub const esp_boot_dir = "yoq/boot";

/// grub-install's arguments for grub on `esp`, reading its menu from
/// `boot_dir`, on the efi path grub boots from now: its own directory
/// under EFI/, or the removable path, EFI/BOOT.
pub fn grubInstall(a: Allocator, io: std.Io, esp: []const u8, boot_dir: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "grub-install", "--target=x86_64-efi", try std.fmt.allocPrint(a, "--efi-directory={s}", .{esp}), try std.fmt.allocPrint(a, "--boot-directory={s}", .{boot_dir}) });
    var dir = std.Io.Dir.cwd().openDir(io, try std.fs.path.join(a, &.{ esp, "EFI" }), .{ .iterate = true }) catch {
        try argv.append(a, "--removable");
        return argv.items;
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |d| {
        if (d.kind != .directory or std.ascii.eqlIgnoreCase(d.name, "BOOT")) continue;
        dir.access(io, try std.fs.path.join(a, &.{ d.name, "grubx64.efi" }), .{}) catch continue;
        try argv.append(a, try std.fmt.allocPrint(a, "--bootloader-id={s}", .{d.name}));
        return argv.items;
    }
    try argv.append(a, "--removable");
    return argv.items;
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
