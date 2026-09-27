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
const Allocator = std.mem.Allocator;

/// a machine on the rollback rung, with its btrfs top level mounted.
pub const Machine = struct {
    a: Allocator,
    io: std.Io,
    boot: facts.Boot,
    root_uuid: []const u8,
    esp_uuid: []const u8,
    top: []const u8 = generation.top_mount,

    /// mounts the top level of the root's filesystem. `close` unmounts it.
    pub fn open(a: Allocator, io: std.Io, boot: facts.Boot, why: *[]const u8) !?Machine {
        var m: Machine = .{
            .a = a,
            .io = io,
            .boot = boot,
            .root_uuid = try uuidOf(a, io, boot.root_device.?, why) orelse return null,
            .esp_uuid = try uuidOf(a, io, boot.esp_device.?, why) orelse return null,
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
        _ = try m.forget(n);
        _ = try m.drop(try m.at(&.{root}));
        _ = try m.writeMenu(m.boot.root_subvol.?, records);
        // the running root's kernel goes back on the esp, if it left.
        _ = try m.restoreBoot(m.boot.root_subvol.?);
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
        const fallback = try trialFallback(m.a, m.io, m.boot.esp.?);
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
        var n = next(records);
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
    fn drop(m: *const Machine, path: []const u8) !?[]const u8 {
        if (!(btrfs.isSubvolume(path) catch false)) return null;
        btrfs.setReadOnly(path, false) catch {};
        btrfs.delete(path) catch |e| return try std.fmt.allocPrint(m.a, "can't remove {s}: {s}", .{ path, @errorName(e) });
        return null;
    }

    /// the boot menu: the running root, labelled with the newest
    /// generation, then every older one, from a fresh writable copy of its
    /// record, then the system from before generations.
    pub fn writeMenu(m: *const Machine, head: []const u8, records: []const generation.Record) !?[]const u8 {
        const cmdline = std.Io.Dir.cwd().readFileAlloc(m.io, "/proc/cmdline", m.a, .limited(4096)) catch "";
        var entries: std.ArrayList(generation.Entry) = .empty;
        if (records.len == 0) return "no generations to put in the menu";
        // records come sorted by number.
        const latest = records[records.len - 1];
        var newest_entry = try m.entry("head", try title(m.a, latest), head, cmdline);
        newest_entry.on_esp = m.bootOnEsp();
        try entries.append(m.a, newest_entry);
        var i = records.len;
        while (i > 0) {
            i -= 1;
            const r = records[i];
            if (r.n == latest.n) continue;
            const copy = try generation.bootCopy(m.a, r.n);
            if (try m.freshCopy(r.n, copy)) |w| return w;
            try entries.append(m.a, try m.entry(try std.fmt.allocPrint(m.a, "gen-{d}", .{r.n}), try title(m.a, r), copy, cmdline));
        }
        for (records) |r| {
            const from = r.from orelse continue;
            try entries.append(m.a, try m.entry("before", "the system before generations", from, cmdline));
        }
        const cfg = try generation.grubConfig(m.a, .{ .esp_uuid = m.esp_uuid, .root_uuid = m.root_uuid, .default = "head", .entries = entries.items });
        const path = try std.fs.path.join(m.a, &.{ m.boot.esp.?, "grub/grub.cfg" });
        rootfs.writeAtomic(m.io, path, cfg, null) catch return try std.fmt.allocPrint(m.a, "can't write {s}", .{path});
        return null;
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
        const merged = try mergeShadow(m.a, try here.read("etc/shadow"), try fs.read("etc/shadow"));
        fs.writeMode("etc/shadow", merged, 0o600) catch return try std.fmt.allocPrint(m.a, "can't write {s}/etc/shadow", .{root});
        return null;
    }

    /// whether /boot is the esp, as archinstall sets it up. kernels then
    /// live outside every root, so each root keeps copies of its own in
    /// its /boot directory, under the mount, where grub can read them.
    pub fn bootOnEsp(m: *const Machine) bool {
        return std.mem.eql(u8, m.boot.esp orelse "", "/boot");
    }

    /// copies the esp's boot files into the root at `subvol`, so its
    /// snapshots boot the kernel that matches their modules.
    pub fn keepBoot(m: *const Machine, subvol: []const u8) !?[]const u8 {
        if (!m.bootOnEsp()) return null;
        return m.copyBoot("/boot", try m.at(&.{ subvol, "boot" }));
    }

    /// puts the boot files kept in the root at `subvol` back on the esp,
    /// for a root that's about to be the newest.
    fn restoreBoot(m: *const Machine, subvol: []const u8) !?[]const u8 {
        if (!m.bootOnEsp()) return null;
        return m.copyBoot(try m.at(&.{ subvol, "boot" }), "/boot");
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
            const tmp = try std.fmt.allocPrint(m.a, "{s}.yoq-new", .{dest});
            if (try m.run(&.{ "cp", src, tmp })) |w| return w;
            if (try m.run(&.{ "mv", "-f", tmp, dest })) |w| return w;
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
    fn entry(m: *const Machine, id: []const u8, name: []const u8, subvol: []const u8, cmdline: []const u8) !generation.Entry {
        var kernels: std.ArrayList([]const u8) = .empty;
        var initrds: std.ArrayList([]const u8) = .empty;
        const dir = if (std.mem.eql(u8, id, "head") and m.bootOnEsp()) "/boot" else try m.at(&.{ subvol, "boot" });
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

/// the env file on the esp that grub reads the menu's choices from.
fn envPath(a: Allocator, esp: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ esp, "yoq/grubenv" });
}

/// one value from the esp's env file, or null.
pub fn envValue(a: Allocator, io: std.Io, esp: []const u8, name: []const u8) !?[]const u8 {
    const text = switch (try exec.output(a, io, &.{ "grub-editenv", try envPath(a, esp), "list" })) {
        .ok => |t| t,
        .failed => return null,
    };
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, line[0..eq], name) and eq + 1 < line.len) return line[eq + 1 ..];
    }
    return null;
}

/// sets values in the esp's env file: "name=value" each.
/// sets `name=value` pairs, or with "unset", removes names.
pub fn editEnv(a: Allocator, io: std.Io, esp: []const u8, verb: []const u8, args: []const []const u8) !?[]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "grub-editenv", try envPath(a, esp), verb });
    try argv.appendSlice(a, args);
    return exec.run(a, io, argv.items);
}

/// the generation a pending trial falls back to, or 0 with no trial.
pub fn trialFallback(a: Allocator, io: std.Io, esp: []const u8) !u32 {
    const default = try envValue(a, io, esp, "yoq_default") orelse return 0;
    if (!std.mem.startsWith(u8, default, "gen-")) return 0;
    return std.fmt.parseInt(u32, default["gen-".len..], 10) catch 0;
}

/// ends a trial boot, however it went: no fallback default any more.
pub fn endTrial(a: Allocator, io: std.Io, esp: []const u8) !?[]const u8 {
    return editEnv(a, io, esp, "unset", &.{ "yoq_default", "yoq_trial", "yoq_tried" });
}

/// machine state every root gets from the running system. ssh host keys
/// are added by name, and passwords are merged into /etc/shadow.
const carried = [_][]const u8{ "etc/machine-id", "etc/adjtime", "etc/subuid", "etc/subgid", "etc/pacman.d/gnupg" };

/// `target`'s shadow file with the password hash, and when it last
/// changed, taken from `current` for every user both have. users only in
/// one of them stay as they are.
fn mergeShadow(a: Allocator, current: []const u8, target: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, target, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const name = line[0 .. std.mem.indexOfScalar(u8, line, ':') orelse line.len];
        const now = findUser(current, name) orelse {
            try out.print(a, "{s}\n", .{line});
            continue;
        };
        // name:hash:lastchange:rest
        var theirs = std.mem.splitScalar(u8, line, ':');
        var ours = std.mem.splitScalar(u8, now, ':');
        _ = theirs.next();
        _ = ours.next();
        const hash = ours.next() orelse "";
        const changed = ours.next() orelse "";
        _ = theirs.next();
        _ = theirs.next();
        try out.print(a, "{s}:{s}:{s}:{s}\n", .{ name, hash, changed, theirs.rest() });
    }
    return out.items;
}

fn findUser(shadow: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, shadow, '\n');
    while (lines.next()) |line| {
        if (line.len > name.len and std.mem.startsWith(u8, line, name) and line[name.len] == ':') return line;
    }
    return null;
}

/// the number the next generation gets.
pub fn next(records: []const generation.Record) u32 {
    var n: u32 = 1;
    for (records) |r| n = @max(n, r.n + 1);
    return n;
}

/// "yoq 2 · 2026-09-26 · add fd".
fn title(a: Allocator, r: generation.Record) ![]const u8 {
    return std.fmt.allocPrint(a, "yoq {d} · {s} · {s}", .{ r.n, try dateOf(a, r.time), r.reason });
}

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

fn uuidOf(a: Allocator, io: std.Io, device: []const u8, why: *[]const u8) !?[]const u8 {
    return switch (try exec.output(a, io, &.{ "blkid", "-s", "UUID", "-o", "value", device })) {
        .ok => |out| std.mem.trim(u8, out, " \n"),
        .failed => |w| {
            why.* = try std.fmt.allocPrint(a, "can't read {s}'s uuid: {s}", .{ device, w });
            return null;
        },
    };
}

fn fail(why: *[]const u8, message: []const u8) ?Machine {
    why.* = message;
    return null;
}

/// "2026-09-26" for unix seconds.
pub fn dateOf(a: Allocator, secs: i64) ![]const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    return std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2}", .{ day.year, md.month.numeric(), md.day_index + 1 });
}

test "passwords carry over, users don't" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const merged = try mergeShadow(arena.allocator(),
        \\root:$6$new$root:20000::::::
        \\kacy:$6$new$kacy:20001:0:99999:7:::
        \\newuser:$6$x:20002::::::
        \\
    ,
        \\root:$6$old$root:19000::::::
        \\kacy:!:19001:0:99999:7:::
        \\olduser:$6$y:19002::::::
        \\
    );
    try std.testing.expectEqualStrings(
        \\root:$6$new$root:20000::::::
        \\kacy:$6$new$kacy:20001:0:99999:7:::
        \\olduser:$6$y:19002::::::
        \\
    , merged);
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
    try std.testing.expectEqualStrings("yoq 2 · 2026-09-26 · add fd", try title(a, got[1]));
}
