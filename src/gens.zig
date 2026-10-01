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
const secureboot = @import("secureboot.zig");
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
    /// sbctl's db certificate, which images os signs must be signed with.
    db_cert: []const u8 = "/" ++ secureboot.db_cert_rel,
    /// set on a way back, like a rollback, a fallback, or gc: a file the
    /// menu can't sign goes on the esp unsigned, or stays as it is there,
    /// and its path goes here, instead of the menu write stopping.
    left_unsigned: ?*std.ArrayList([]const u8) = null,
    /// the note naming the root whose boot files aren't on the esp yet
    /// (see `unsettled`), or a test's stand-in.
    unsettled_note: []const u8 = generation.unsettled_path,

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
        // it boots the kernel in its own root until a good boot puts it on
        // the esp, and the note that says so is on disk before the menu
        // boots it: without it, the next menu write would boot the esp's
        // older kernel for it, and copy that into its /boot.
        const before = try m.note();
        if (try m.setNote(root)) |w| return w;
        const why = try m.add(records, n, root, reason, time, config) orelse return null;
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
    pub fn start(m: *const Machine, source: []const u8, reason: []const u8, time: i64, config: ?generation.Config, made: *u32, later: *?[]const u8) !?[]const u8 {
        const records = try readRecords(m.a, m.io, "/var");
        const n = try m.free(records);
        const root = try std.fmt.allocPrint(m.a, "/{s}/{d}", .{ generation.roots_dir, n });
        btrfs.snapshot(try m.at(&.{source}), try m.at(&.{root}), false) catch |e| return try std.fmt.allocPrint(m.a, "can't copy {s}: {s}", .{ source, @errorName(e) });
        const before = try m.note();
        // the esp's boot files change last, once the new root is recorded.
        const why = try m.carry(root) orelse try m.add(records, n, root, reason, time, config) orelse try m.startBoot(root, before, later) orelse {
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
        rootfs.writeAtomic(m.io, m.unsettled_note, r, null) catch return try std.fmt.allocPrint(m.a, "can't write {s}", .{m.unsettled_note});
        return null;
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
    ///
    /// when `signs` says so, every image the menu uses is signed before it
    /// goes on the esp, and an unsigned one there already is signed again,
    /// so a fallback to an older generation boots too.
    fn writeOnEsp(m: *const Machine, entries: []menu.Entry, records: []const generation.Record, put: MenuWriter) !?[]const u8 {
        const dir = try std.fs.path.join(m.a, &.{ m.boot.esp.?, esp_boot_dir });
        const sign = entries.len > 0 and m.signs(entries[0].subvol);
        const work = if (entries.len > 0) try m.at(&.{ entries[0].subvol, sign_dir }) else "";
        var files: EspFiles = .{};
        if (menu.copiesOnEsp(m.boot) or try m.anyImage(entries)) {
            if (try m.run(&.{ "mkdir", "-p", dir })) |w| return w;
            if (try m.espFiles(entries, &files)) |w| return w;
            if (try m.fillEsp(dir, &files, records, sign, work)) |w| return w;
        }
        if (try put(m, entries)) |w| return w;
        // with no entry using it, everything goes, like images from before
        // `[boot] uki` went off.
        m.removeUnused(dir, files.used.items, "", "");
        return if (sign) m.signLoader(work) else null;
    }

    /// what a menu's entries need in the esp's boot directory: the names
    /// they use there, and the copies and images it doesn't have yet.
    const EspFiles = struct {
        used: std.ArrayList([]const u8) = .empty,
        missing: std.ArrayList(EspCopy) = .empty,
        builds: std.ArrayList(UkiBuild) = .empty,

        /// the room the ones it doesn't have take.
        fn size(f: *const EspFiles) u64 {
            var n: u64 = 0;
            for (f.missing.items) |c| n += c.size;
            for (f.builds.items) |b| n += b.size;
            return n;
        }
    };

    /// points each entry at its files on the esp, and notes them in
    /// `files`: an image for an entry whose root boots one, and, for a
    /// bootloader that can't read the roots, copies of the rest.
    fn espFiles(m: *const Machine, entries: []menu.Entry, files: *EspFiles) !?[]const u8 {
        const copies = menu.copiesOnEsp(m.boot);
        for (entries) |*e| {
            if (try m.bootsImage(e.subvol)) {
                if (try m.ukiName(e, files)) |w| return w;
                continue;
            }
            if (!copies or e.esp_dir != null) continue;
            const from = try m.at(&.{ e.subvol, "boot" });
            if (try m.espName(from, &e.kernel, files)) |w| return w;
            const initrds = try m.a.dupe([]const u8, e.initrds);
            for (initrds) |*i| {
                if (try m.espName(from, i, files)) |w| return w;
            }
            e.initrds = initrds;
            e.esp_dir = esp_boot_dir;
        }
        return null;
    }

    /// puts what `files` says the esp at `dir` lacks there: copies and new
    /// images, and with `sign`, signatures on the images there without
    /// one. if it doesn't all fit, nothing changes.
    fn fillEsp(m: *const Machine, dir: []const u8, files: *const EspFiles, records: []const generation.Record, sign: bool, work: []const u8) !?[]const u8 {
        var unsigned: std.ArrayList([]const u8) = .empty;
        // each one is signed in a copy that goes in beside it, one at a
        // time.
        const largest = if (sign) try m.unsignedImages(dir, files, &unsigned) else 0;
        if (try m.checkRoom(dir, files.size() + largest, records)) |w| return w;
        for (files.missing.items) |c| {
            if (try m.replaceFile(c.src, c.dest)) |w| return w;
        }
        for (files.builds.items) |b| {
            if (try m.buildUki(b, sign)) |w| return w;
        }
        if (unsigned.items.len == 0) return null;
        if (try m.freshDir(work)) |w| return w;
        defer m.removeDir(work);
        for (unsigned.items) |dest| {
            if (try m.signCopy(dest, work)) |w| return w;
        }
        return null;
    }

    /// says which of `records` to remove when `need` more bytes don't fit
    /// on the esp, which `dir` is on.
    fn checkRoom(m: *const Machine, dir: []const u8, need: u64, records: []const generation.Record) !?[]const u8 {
        if (need == 0) return null;
        const room = rootfs.freeBytes(dir) orelse return null;
        return generation.espRoom(m.a, m.boot.esp.?, need, room, records, m.boot.root_subvol orelse "", true);
    }

    /// adds the images `files` uses that are in `dir` without a signature
    /// to `out`, except the ones about to be built, which are signed as
    /// they're made. returns the size of the largest.
    fn unsignedImages(m: *const Machine, dir: []const u8, files: *const EspFiles, out: *std.ArrayList([]const u8)) !u64 {
        var largest: u64 = 0;
        for (files.used.items) |name| {
            if (!std.mem.endsWith(u8, name, uki.suffix)) continue;
            const dest = try std.fs.path.join(m.a, &.{ dir, name });
            if (lists.find(files.builds.items, "dest", dest) != null or try m.signedNow(dest)) continue;
            try out.append(m.a, dest);
            const st = std.Io.Dir.cwd().statFile(m.io, dest, .{}) catch continue;
            largest = @max(largest, st.size);
        }
        return largest;
    }

    /// whether the efi binary at `path` is signed with sbctl's db key, or
    /// signed at all when there's no key to compare with. one signed with
    /// another key, like one from before `sbctl create-keys` was run
    /// again, isn't, so it gets signed again.
    fn signedNow(m: *const Machine, path: []const u8) !bool {
        return fileSigned(m.io, path, try dbKey(m.a, m.io, m.db_cert));
    }

    /// whether the root at `subvol` has `rel`, a path inside it.
    fn has(m: *const Machine, subvol: []const u8, rel: []const u8) !bool {
        return rootfs.pathExists(m.io, try m.at(&.{ subvol, rel }));
    }

    /// whether the root at `subvol` boots a unified kernel image: it has
    /// os's ukify config from `[boot] uki`.
    pub fn bootsImage(m: *const Machine, subvol: []const u8) !bool {
        return m.has(subvol, uki.config_rel);
    }

    fn anyImage(m: *const Machine, entries: []const menu.Entry) !bool {
        for (entries) |e| {
            if (try m.bootsImage(e.subvol)) return true;
        }
        return false;
    }

    /// whether menus written now sign what they boot: the root at the top,
    /// `head`, or the running one has os's file from `[boot] secure_boot`,
    /// or the firmware enforces secure boot and sbctl has keys. the
    /// running one counts since its firmware may enforce secure boot
    /// already, whatever generation goes on top.
    pub fn signs(m: *const Machine, head: []const u8) bool {
        if (secureboot.enforcedWithKeys(m.boot.secure_boot, m.boot.sbctl_keys)) return true;
        if (m.has(head, secureboot.config_rel) catch false) return true;
        const running = m.boot.root_subvol orelse return false;
        return m.has(running, secureboot.config_rel) catch false;
    }

    /// signs the efi binary at `path` in place, with sbctl's keys.
    fn signFile(m: *const Machine, path: []const u8) !?[]const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(m.a, m.signer);
        try argv.appendSlice(m.a, &.{ "sign", path });
        const why = try m.run(argv.items) orelse return null;
        return try std.fmt.allocPrint(m.a, "can't sign {s} for secure boot: {s}", .{ path, why });
    }

    const Signing = union(enum) {
        signed,
        /// it couldn't be, and on a way back that's noted, not a stop.
        unsigned,
        failed: []const u8,
    };

    /// signs `src`, which goes to `dest` on the esp.
    fn trySign(m: *const Machine, src: []const u8, dest: []const u8) !Signing {
        const why = try m.signFile(src) orelse return .signed;
        if (!secureboot.goesOnUnsigned(m.left_unsigned != null)) return .{ .failed = why };
        // a rollback writes the menu more than once.
        const left = m.left_unsigned.?;
        if (!lists.contains(left.items, dest)) try left.append(m.a, dest);
        return .unsigned;
    }

    /// signs `src`, a file in a work directory, then puts it at `dest` on
    /// the esp, so the esp never has it unsigned, unless a way back
    /// couldn't sign it.
    fn signInto(m: *const Machine, src: []const u8, dest: []const u8) !?[]const u8 {
        return switch (try m.trySign(src, dest)) {
            .failed => |w| w,
            .signed, .unsigned => m.replaceFile(src, dest),
        };
    }

    /// signs a file on the esp: a copy in `work`, signed, replaces it. one
    /// a way back can't sign stays as it is.
    fn signCopy(m: *const Machine, dest: []const u8, work: []const u8) !?[]const u8 {
        const copy = try std.fs.path.join(m.a, &.{ work, std.fs.path.basename(dest) });
        if (try m.run(&.{ "cp", dest, copy })) |w| return w;
        return switch (try m.trySign(copy, dest)) {
            .failed => |w| w,
            .signed => m.replaceFile(copy, dest),
            .unsigned => null,
        };
    }

    /// signs the loader files os puts on the esp itself, when they aren't
    /// signed yet: refind's btrfs driver. the bootloader's own binaries
    /// come from its install, and `os doctor` says if they're unsigned.
    fn signLoader(m: *const Machine, work: []const u8) !?[]const u8 {
        if (m.loader != .refind) return null;
        const conf = m.boot.loader_conf orelse return null;
        const driver = try std.fs.path.join(m.a, &.{ std.fs.path.dirnamePosix(conf).?, refind_driver });
        if (!rootfs.pathExists(m.io, driver) or try m.signedNow(driver)) return null;
        if (try m.freshDir(work)) |w| return w;
        defer m.removeDir(work);
        return m.signCopy(driver, work);
    }

    /// empties the directory at `path`, making it if it isn't there.
    fn freshDir(m: *const Machine, path: []const u8) !?[]const u8 {
        return exec.runAll(m.a, m.io, &.{ &.{ "rm", "-rf", path }, &.{ "mkdir", "-p", path } });
    }

    fn removeDir(m: *const Machine, path: []const u8) void {
        _ = exec.run(m.a, m.io, &.{ "rm", "-rf", path }) catch {};
    }

    /// a unified kernel image the esp doesn't have yet: the root whose
    /// tools build it, its files, kernel first, and where it goes.
    const UkiBuild = struct { root: []const u8, files: []const []const u8, dest: []const u8, size: u64 };

    /// makes `e` start a unified kernel image of its kernel and initrds,
    /// named by their content and the stub of the root that builds it,
    /// and notes the name in `files`, along with the build if the esp
    /// doesn't have it yet.
    fn ukiName(m: *const Machine, e: *menu.Entry, files: *EspFiles) !?[]const u8 {
        // the newest entry's files may be the esp's own, with /boot there.
        const from = if (e.esp_dir) |d| try std.fs.path.join(m.a, &.{ m.boot.esp.?, d }) else try m.at(&.{ e.subvol, "boot" });
        var inputs: std.ArrayList([]const u8) = .empty;
        var sums: std.ArrayList([]const u8) = .empty;
        var size: u64 = uki.stub_size;
        var why: []const u8 = "";
        for (try std.mem.concat(m.a, []const u8, &.{ &.{e.kernel}, e.initrds })) |name| {
            const src = try std.fs.path.join(m.a, &.{ from, name });
            const h = try m.hash(src, &why) orelse return why;
            try inputs.append(m.a, src);
            try sums.append(m.a, h.sum);
            size += h.size;
        }
        const stub = try m.hash(try m.at(&.{ e.subvol, uki.stub_rel }), &why) orelse return why;
        try sums.append(m.a, stub.sum);
        const name = try uki.name(m.a, sums.items);
        e.uki = name;
        e.esp_dir = esp_boot_dir;
        const dest = try m.newOnEsp(name, files) orelse return null;
        try files.builds.append(m.a, .{ .root = try m.at(&.{e.subvol}), .files = inputs.items, .dest = dest, .size = size });
        return null;
    }

    /// builds a unified kernel image with ukify, chrooted into the root
    /// it's for, so it's that root's ukify and stub, which a root staged
    /// with `[boot] uki` has even when the running one doesn't. its files
    /// go into a directory in the root first, since the esp isn't in
    /// there, and nothing has to be mounted for this. reflinks keep that
    /// cheap for files from the root's own /boot.
    fn buildUki(m: *const Machine, b: UkiBuild, signed: bool) !?[]const u8 {
        const work = try std.fs.path.join(m.a, &.{ b.root, uki.work_dir });
        if (try m.freshDir(work)) |w| return w;
        defer m.removeDir(work);
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
        const image = try std.fs.path.join(m.a, &.{ work, "yoq.efi" });
        // signed from here, with the running system's sbctl and keys: the
        // keys live in /var, which no root holds.
        return if (signed) m.signInto(image, b.dest) else m.replaceFile(image, b.dest);
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
    /// boot directory, "<hash>-<name>", and notes it in `files`, along
    /// with the copy if the esp doesn't have it yet.
    fn espName(m: *const Machine, from: []const u8, name: *[]const u8, files: *EspFiles) !?[]const u8 {
        const src = try std.fs.path.join(m.a, &.{ from, name.* });
        var why: []const u8 = "";
        const h = try m.hash(src, &why) orelse return why;
        name.* = try std.fmt.allocPrint(m.a, "{s}-{s}", .{ h.sum[0..16], name.* });
        const dest = try m.newOnEsp(name.*, files) orelse return null;
        try files.missing.append(m.a, .{ .src = src, .dest = dest, .size = h.size });
        return null;
    }

    /// notes `name` as used in the esp's boot directory, and returns its
    /// path there when the esp doesn't have it and `files` didn't have
    /// it already.
    fn newOnEsp(m: *const Machine, name: []const u8, files: *EspFiles) !?[]const u8 {
        if (lists.contains(files.used.items, name)) return null;
        try files.used.append(m.a, name);
        const dest = try std.fs.path.join(m.a, &.{ m.boot.esp.?, esp_boot_dir, name });
        return if (rootfs.pathExists(m.io, dest)) null else dest;
    }

    /// a boot file's sha256 sum, in hex, and its size.
    const Hashed = struct { sum: []const u8, size: u64 };

    /// hashes the file at `path`, or says why it can't in `why`.
    fn hash(m: *const Machine, path: []const u8, why: *[]const u8) !?Hashed {
        const out = switch (try exec.output(m.a, m.io, &.{ "sha256sum", path })) {
            .ok => |t| t,
            .failed => |w| {
                why.* = w;
                return null;
            },
        };
        const st = std.Io.Dir.cwd().statFile(m.io, path, .{}) catch {
            why.* = try std.fmt.allocPrint(m.a, "can't read {s}", .{path});
            return null;
        };
        if (out.len < 64) {
            why.* = try std.fmt.allocPrint(m.a, "can't hash {s}", .{path});
            return null;
        }
        return .{ .sum = out[0..64], .size = st.size };
    }

    /// copies `src` beside `dest` and renames it into place, so `dest`
    /// is never half written. the copy is synced before the rename: a
    /// kernel copy on the esp is reused by its name, and the menu that
    /// boots it is synced too.
    fn replaceFile(m: *const Machine, src: []const u8, dest: []const u8) !?[]const u8 {
        const why = try exec.runAll(m.a, m.io, try replaceSteps(m.a, src, dest)) orelse return null;
        // a copy cut short, by a full esp say, would only take up room.
        std.Io.Dir.cwd().deleteFile(m.io, try std.fmt.allocPrint(m.a, "{s}.yoq-new", .{dest})) catch {};
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
        const driver = try std.fs.path.join(m.a, &.{ dir, refind_driver });
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
        const named = (m.note() catch return false) orelse return false;
        return std.mem.eql(u8, named, subvol);
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

/// the commands that put a copy of `src` at `dest` whole: a copy beside
/// it, synced, renamed into place, and then its directory synced, so the
/// new name is on disk before a menu written after it names the file. on
/// fat, syncing the file and the menu's own directory leaves the rename
/// in memory, and a power cut then leaves a menu whose file isn't there.
fn replaceSteps(a: Allocator, src: []const u8, dest: []const u8) ![]const []const []const u8 {
    const tmp = try std.fmt.allocPrint(a, "{s}.yoq-new", .{dest});
    const dir = std.fs.path.dirnamePosix(dest) orelse ".";
    return a.dupe([]const []const u8, &.{
        try a.dupe([]const u8, &.{ "cp", src, tmp }),
        try a.dupe([]const u8, &.{ "sync", tmp }),
        try a.dupe([]const u8, &.{ "mv", "-f", tmp, dest }),
        try a.dupe([]const u8, &.{ "sync", dir }),
    });
}

test "a file put on the esp is renamed in, and its directory synced after" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const steps = try replaceSteps(a, "/x/vmlinuz-linux", "/efi/yoq/boot/ab-vmlinuz-linux");
    try std.testing.expectEqual(4, steps.len);
    try std.testing.expectEqualStrings("mv", steps[2][0]);
    try std.testing.expectEqualStrings("sync", steps[3][0]);
    try std.testing.expectEqualStrings("/efi/yoq/boot", steps[3][1]);
    // and the steps work: the file's there whole, with nothing beside it.
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src", .data = "kernel" });
    const dest = try std.fmt.allocPrint(a, "{s}/dest", .{base});
    try std.testing.expectEqual(null, try exec.runAll(a, std.testing.io, try replaceSteps(a, try std.fmt.allocPrint(a, "{s}/src", .{base}), dest)));
    try std.testing.expectEqualStrings("kernel", try tmp.dir.readFileAlloc(std.testing.io, "dest", a, .limited(16)));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "dest.yoq-new", .{}));
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

/// where images are signed, inside the root at the top of the menu.
const sign_dir = "tmp/yoq-sign";

/// refind's btrfs driver, beside refind.conf, which os installs.
const refind_driver = "drivers_x64/btrfs_x64.efi";

/// whether the efi binary at `path` has a signature: one from the key
/// `key` names (see secureboot.signerKey), or with no key, any. one that
/// can't be read, or isn't an efi binary, hasn't.
pub fn fileSigned(io: std.Io, path: []const u8, key: ?[]const u8) bool {
    var head: [secureboot.header_bytes]u8 = undefined;
    const t = secureboot.certTable(rootfs.readHead(io, path, &head) orelse return false) orelse return false;
    if (t.size == 0) return false;
    const k = key orelse return true;
    // a signature or two, with their certificates, takes a few KiB.
    var table: [64 << 10]u8 = undefined;
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer f.close(io);
    const n = f.readPositionalAll(io, table[0..@min(t.size, table.len)], t.offset) catch return false;
    return secureboot.signedBy(table[0..n], k);
}

/// what names sbctl's db key as a signer, from its certificate at
/// `cert_path`. null without one.
pub fn dbKey(a: Allocator, io: std.Io, cert_path: []const u8) !?[]const u8 {
    const pem = std.Io.Dir.cwd().readFileAlloc(io, cert_path, a, .limited(64 << 10)) catch return null;
    return secureboot.signerKey(a, pem);
}

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
    try writeTestStub(tmp.dir, io, "top/@roots/2", "stub");
    const name = try uki.name(a, &.{ &facts.sha256Hex("kernel"), &facts.sha256Hex("initramfs"), &facts.sha256Hex("stub") });
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

    // a new stub makes a new image, here one the esp has already, and the
    // old one goes.
    try writeTestStub(tmp.dir, io, "top/@roots/2", "stub 2");
    const renamed = try uki.name(a, &.{ &facts.sha256Hex("kernel"), &facts.sha256Hex("initramfs"), &facts.sha256Hex("stub 2") });
    try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "esp/yoq/boot/{s}", .{renamed}), .data = "image" });
    entries[0] = .{ .id = "head", .title = "yoq 2", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" };
    try std.testing.expectEqual(null, try m.writeOnEsp(&entries, &.{}, testPut));
    try std.testing.expectEqualStrings(renamed, test_put[0].uki.?);
    try std.testing.expectError(error.FileNotFound, esp.access(io, name, .{}));
    try esp.access(io, renamed, .{});

    // with [boot] uki off everywhere, the last image goes too.
    try tmp.dir.deleteFile(io, "top/@roots/2/" ++ uki.config_rel);
    entries[0] = .{ .id = "head", .title = "yoq 3", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" };
    try std.testing.expectEqual(null, try m.writeOnEsp(&entries, &.{}, testPut));
    try std.testing.expectEqual(null, test_put[0].uki);
    try std.testing.expectError(error.FileNotFound, esp.access(io, renamed, .{}));
}

/// systemd's stub in the test root at `root`, holding `text`.
fn writeTestStub(dir: std.Io.Dir, io: std.Io, root: []const u8, text: []const u8) !void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, uki.stub_rel });
    try dir.createDirPath(io, std.fs.path.dirnamePosix(path).?);
    try dir.writeFile(io, .{ .sub_path = path, .data = text });
}

test "with secure boot, images are signed in the root before they replace the esp's" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "top/@roots/2/boot");
    try tmp.dir.createDirPath(io, "top/@roots/2/etc/kernel");
    try tmp.dir.createDirPath(io, "esp/yoq/boot");
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ uki.config_rel, .data = uki.config_content });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/vmlinuz-linux", .data = "kernel" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/initramfs-linux.img", .data = "initramfs" });
    try writeTestStub(tmp.dir, io, "top/@roots/2", "stub");
    const name = try uki.name(a, &.{ &facts.sha256Hex("kernel"), &facts.sha256Hex("initramfs"), &facts.sha256Hex("stub") });
    const image = try std.fmt.allocPrint(a, "esp/yoq/boot/{s}", .{name});
    try tmp.dir.writeFile(io, .{ .sub_path = image, .data = "image" });
    // a stand-in for sbctl, which notes what it signed.
    try tmp.dir.writeFile(io, .{ .sub_path = "sign.sh", .data =
        \\[ "$1" = sign ] || exit 1
        \\printf ' signed' >> "$2"
        \\echo "$2" >> "$(dirname "$0")/signed.log"
        \\
    });
    const m: Machine = .{
        .a = a,
        .io = io,
        .boot = .{ .esp = try std.fmt.allocPrint(a, "{s}/esp", .{base}), .loader = "grub", .root_subvol = "/@roots/2" },
        .loader = .grub,
        .root_uuid = "r",
        .esp_uuid = "e",
        .top = try std.fmt.allocPrint(a, "{s}/top", .{base}),
        .signer = &.{ "sh", try std.fmt.allocPrint(a, "{s}/sign.sh", .{base}) },
    };
    var entries = [_]menu.Entry{
        .{ .id = "head", .title = "yoq 2", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" },
    };
    // without the key, nothing's signed.
    try std.testing.expectEqual(null, try m.writeOnEsp(&entries, &.{}, testPut));
    try std.testing.expectEqualStrings("image", try tmp.dir.readFileAlloc(io, image, a, .limited(64)));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "signed.log", .{}));

    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ secureboot.config_rel, .data = secureboot.config_content });
    entries[0] = .{ .id = "head", .title = "yoq 3", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" };
    try std.testing.expectEqual(null, try m.writeOnEsp(&entries, &.{}, testPut));
    try std.testing.expectEqualStrings(name, test_put[0].uki.?);
    try std.testing.expectEqualStrings("image signed", try tmp.dir.readFileAlloc(io, image, a, .limited(64)));
    // the copy in the root was signed, never the esp's own file, and the
    // work directory is gone again.
    const log = try tmp.dir.readFileAlloc(io, "signed.log", a, .limited(1024));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/top/@roots/2/{s}/{s}\n", .{ base, sign_dir, name }), log);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "top/@roots/2/" ++ sign_dir, .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, try std.fmt.allocPrint(a, "{s}.yoq-new", .{image}), .{}));

    // a signer that fails leaves the esp's image as it was.
    const failing: Machine = .{ .a = a, .io = io, .boot = m.boot, .loader = .grub, .root_uuid = "r", .esp_uuid = "e", .top = m.top, .signer = &.{"false"} };
    try tmp.dir.writeFile(io, .{ .sub_path = image, .data = "image" });
    entries[0] = .{ .id = "head", .title = "yoq 4", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" };
    const why = (try failing.writeOnEsp(&entries, &.{}, testPut)).?;
    try std.testing.expect(std.mem.startsWith(u8, why, "can't sign "));
    try std.testing.expectEqualStrings("image", try tmp.dir.readFileAlloc(io, image, a, .limited(64)));
}

test "firmware that enforces secure boot has images signed without the config's key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    // a generation rolled back to from before `[boot] secure_boot`: an
    // image, but no file that asks for signing.
    try tmp.dir.createDirPath(io, "top/@roots/2/boot");
    try tmp.dir.createDirPath(io, "top/@roots/2/etc/kernel");
    try tmp.dir.createDirPath(io, "esp/yoq/boot");
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ uki.config_rel, .data = uki.config_content });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/vmlinuz-linux", .data = "kernel" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/initramfs-linux.img", .data = "initramfs" });
    try writeTestStub(tmp.dir, io, "top/@roots/2", "stub");
    const name = try uki.name(a, &.{ &facts.sha256Hex("kernel"), &facts.sha256Hex("initramfs"), &facts.sha256Hex("stub") });
    const image = try std.fmt.allocPrint(a, "esp/yoq/boot/{s}", .{name});
    try tmp.dir.writeFile(io, .{ .sub_path = "sign.sh", .data = "[ \"$1\" = sign ] && printf ' signed' >> \"$2\"\n" });
    var m: Machine = .{
        .a = a,
        .io = io,
        .boot = .{ .esp = try std.fmt.allocPrint(a, "{s}/esp", .{base}), .loader = "grub", .root_subvol = "/@roots/2", .secure_boot = false, .sbctl_keys = true },
        .loader = .grub,
        .root_uuid = "r",
        .esp_uuid = "e",
        .top = try std.fmt.allocPrint(a, "{s}/top", .{base}),
        .signer = &.{ "sh", try std.fmt.allocPrint(a, "{s}/sign.sh", .{base}) },
    };
    var entries = [_]menu.Entry{
        .{ .id = "head", .title = "yoq 2", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" },
    };
    // secure boot off in the firmware: nothing to sign for.
    try tmp.dir.writeFile(io, .{ .sub_path = image, .data = "image" });
    try std.testing.expectEqual(null, try m.writeOnEsp(&entries, &.{}, testPut));
    try std.testing.expectEqualStrings("image", try tmp.dir.readFileAlloc(io, image, a, .limited(64)));
    // enforced, with keys: the image is signed, or it wouldn't start.
    m.boot.secure_boot = true;
    entries[0] = .{ .id = "head", .title = "yoq 3", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" };
    try std.testing.expectEqual(null, try m.writeOnEsp(&entries, &.{}, testPut));
    try std.testing.expectEqualStrings("image signed", try tmp.dir.readFileAlloc(io, image, a, .limited(64)));
}

test "a way back that can't sign writes the menu anyway" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "top/@roots/2/boot");
    try tmp.dir.createDirPath(io, "top/@roots/2/etc/kernel");
    try tmp.dir.createDirPath(io, "esp/yoq/boot");
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ uki.config_rel, .data = uki.config_content });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ secureboot.config_rel, .data = secureboot.config_content });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/vmlinuz-linux", .data = "kernel" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/initramfs-linux.img", .data = "initramfs" });
    try writeTestStub(tmp.dir, io, "top/@roots/2", "stub");
    const name = try uki.name(a, &.{ &facts.sha256Hex("kernel"), &facts.sha256Hex("initramfs"), &facts.sha256Hex("stub") });
    const image = try std.fmt.allocPrint(a, "esp/yoq/boot/{s}", .{name});
    try tmp.dir.writeFile(io, .{ .sub_path = image, .data = "image" });
    // sbctl without its keys.
    var m: Machine = .{
        .a = a,
        .io = io,
        .boot = .{ .esp = try std.fmt.allocPrint(a, "{s}/esp", .{base}), .loader = "grub", .root_subvol = "/@roots/2" },
        .loader = .grub,
        .root_uuid = "r",
        .esp_uuid = "e",
        .top = try std.fmt.allocPrint(a, "{s}/top", .{base}),
        .signer = &.{"false"},
    };
    var entries = [_]menu.Entry{
        .{ .id = "head", .title = "yoq 2", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" },
    };
    // apply stops.
    test_put = &.{};
    try std.testing.expect(std.mem.startsWith(u8, (try m.writeOnEsp(&entries, &.{}, testPut)).?, "can't sign "));
    try std.testing.expectEqual(0, test_put.len);
    // a way back writes the menu, keeps the image as it is, and notes it.
    var left: std.ArrayList([]const u8) = .empty;
    m.left_unsigned = &left;
    entries[0] = .{ .id = "head", .title = "yoq 3", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" };
    try std.testing.expectEqual(null, try m.writeOnEsp(&entries, &.{}, testPut));
    try std.testing.expectEqualStrings(name, test_put[0].uki.?);
    try std.testing.expectEqualStrings("image", try tmp.dir.readFileAlloc(io, image, a, .limited(64)));
    try std.testing.expectEqual(1, left.items.len);
    try std.testing.expect(std.mem.endsWith(u8, left.items[0], name));
}

/// an efi binary signed by the key `key` names: pe headers whose
/// certificate table, at 0x1000, names it.
fn testSignedEfi(a: Allocator, key: []const u8) ![]const u8 {
    const table = try std.mem.concat(a, u8, &.{ &.{ 0, 1, 0, 0, 0, 2, 2, 0 }, try secureboot.testDer(a, 0x30, key) });
    const head = secureboot.testPe(0x20b, @intCast(table.len));
    return std.mem.concat(a, u8, &.{ &head, &([_]u8{0} ** (0x1000 - 512)), table });
}

test "images signed with another key are signed again" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const db = try secureboot.testCert(a, "yoq db", &.{ 0x01, 0x02 });
    const old = try secureboot.testCert(a, "yoq db", &.{ 0x01, 0x01 });
    try tmp.dir.writeFile(io, .{ .sub_path = "db.pem", .data = db.pem });
    const key = (try dbKey(a, io, try std.fmt.allocPrint(a, "{s}/db.pem", .{base}))).?;
    try std.testing.expectEqualSlices(u8, db.key, key);
    try std.testing.expectEqual(null, try dbKey(a, io, try std.fmt.allocPrint(a, "{s}/missing.pem", .{base})));

    try tmp.dir.createDirPath(io, "top/@roots/2/boot");
    try tmp.dir.createDirPath(io, "top/@roots/2/etc/kernel");
    try tmp.dir.createDirPath(io, "esp/yoq/boot");
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ uki.config_rel, .data = uki.config_content });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/" ++ secureboot.config_rel, .data = secureboot.config_content });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/vmlinuz-linux", .data = "kernel" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/2/boot/initramfs-linux.img", .data = "initramfs" });
    try writeTestStub(tmp.dir, io, "top/@roots/2", "stub");
    const name = try uki.name(a, &.{ &facts.sha256Hex("kernel"), &facts.sha256Hex("initramfs"), &facts.sha256Hex("stub") });
    const image = try std.fmt.allocPrint(a, "esp/yoq/boot/{s}", .{name});
    const image_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, image });
    try tmp.dir.writeFile(io, .{ .sub_path = "sign.sh", .data = "[ \"$1\" = sign ] && echo \"$2\" >> \"$(dirname \"$0\")/signed.log\"\n" });
    const m: Machine = .{
        .a = a,
        .io = io,
        .boot = .{ .esp = try std.fmt.allocPrint(a, "{s}/esp", .{base}), .loader = "grub", .root_subvol = "/@roots/2" },
        .loader = .grub,
        .root_uuid = "r",
        .esp_uuid = "e",
        .top = try std.fmt.allocPrint(a, "{s}/top", .{base}),
        .signer = &.{ "sh", try std.fmt.allocPrint(a, "{s}/sign.sh", .{base}) },
        .db_cert = try std.fmt.allocPrint(a, "{s}/db.pem", .{base}),
    };
    var entries = [_]menu.Entry{
        .{ .id = "head", .title = "yoq 2", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" },
    };
    // signed with the db key: it stays.
    try tmp.dir.writeFile(io, .{ .sub_path = image, .data = try testSignedEfi(a, db.key) });
    try std.testing.expect(fileSigned(io, image_path, key));
    try std.testing.expectEqual(null, try m.writeOnEsp(&entries, &.{}, testPut));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "signed.log", .{}));
    // signed with the key from before: signed, but not by this one, so it's
    // signed again.
    try tmp.dir.writeFile(io, .{ .sub_path = image, .data = try testSignedEfi(a, old.key) });
    try std.testing.expect(fileSigned(io, image_path, null));
    try std.testing.expect(!fileSigned(io, image_path, key));
    entries[0] = .{ .id = "head", .title = "yoq 3", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw" };
    try std.testing.expectEqual(null, try m.writeOnEsp(&entries, &.{}, testPut));
    const log = try tmp.dir.readFileAlloc(io, "signed.log", a, .limited(1024));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/top/@roots/2/{s}/{s}\n", .{ base, sign_dir, name }), log);
}

test "an efi binary without a certificate table isn't signed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(io, .{ .sub_path = "plain.efi", .data = "not an efi binary" });
    try std.testing.expect(!fileSigned(io, try std.fmt.allocPrint(a, "{s}/plain.efi", .{base}), null));
    try std.testing.expect(!fileSigned(io, try std.fmt.allocPrint(a, "{s}/missing.efi", .{base}), null));
}
