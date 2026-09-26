//! generations on a running machine: the btrfs top level, the records in
//! /var/lib/yoq/generations, and the boot menu on the esp. generation.zig
//! has the pure parts. every function here returns null when it worked,
//! or what went wrong.

const std = @import("std");
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
    pub fn record(m: *const Machine, reason: []const u8, time: i64) !?[]const u8 {
        const records = try readRecords(m.a, m.io, "/var");
        return m.add(records, m.boot.root_subvol.?, reason, time);
    }

    /// starts a new generation from `source`, a generation's record or a
    /// copy of one: a writable root of its own, recorded and at the top of
    /// the menu, so the next boot runs it. returns its number, or what
    /// went wrong in `why`.
    pub fn start(m: *const Machine, source: []const u8, reason: []const u8, time: i64, why: *[]const u8) !?u32 {
        const records = try readRecords(m.a, m.io, "/var");
        const n = next(records);
        const root = try std.fmt.allocPrint(m.a, "/{s}/{d}", .{ generation.roots_dir, n });
        btrfs.snapshot(try m.at(&.{source}), try m.at(&.{root}), false) catch |e| {
            why.* = try std.fmt.allocPrint(m.a, "can't copy {s}: {s}", .{ source, @errorName(e) });
            return null;
        };
        if (try m.add(records, root, reason, time)) |w| {
            why.* = w;
            return null;
        }
        return n;
    }

    /// the next generation, from the root at `root`: its read-only record,
    /// the record file, and the menu with `root` at the top.
    fn add(m: *const Machine, records: []const generation.Record, root: []const u8, reason: []const u8, time: i64) !?[]const u8 {
        const n = next(records);
        const dest = try m.at(&.{ generation.gens_dir, try std.fmt.allocPrint(m.a, "{d}", .{n}) });
        btrfs.snapshot(try m.at(&.{root}), dest, true) catch |e| return try std.fmt.allocPrint(m.a, "can't snapshot {s}: {s}", .{ root, @errorName(e) });
        const rec: generation.Record = .{ .n = n, .time = time, .root = root[1..], .reason = reason };
        if (try writeRecord(m.a, m.io, "/var", rec)) |w| return w;
        const all = try std.mem.concat(m.a, generation.Record, &.{ records, &.{rec} });
        return m.writeMenu(root, all);
    }

    /// the boot menu: the running root, labelled with the newest
    /// generation, then every older one, from a fresh writable copy of its
    /// record, then the system from before generations.
    pub fn writeMenu(m: *const Machine, head: []const u8, records: []const generation.Record) !?[]const u8 {
        const cmdline = std.Io.Dir.cwd().readFileAlloc(m.io, "/proc/cmdline", m.a, .limited(4096)) catch "";
        var entries: std.ArrayList(generation.Entry) = .empty;
        var newest: ?generation.Record = null;
        for (records) |r| {
            if (newest == null or r.n > newest.?.n) newest = r;
        }
        const latest = newest orelse return "no generations to put in the menu";
        try entries.append(m.a, try m.entry("head", try title(m.a, latest), head, cmdline));
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
        std.Io.Dir.cwd().writeFile(m.io, .{ .sub_path = path, .data = cfg }) catch return try std.fmt.allocPrint(m.a, "can't write {s}", .{path});
        return null;
    }

    /// remakes generation `n`'s writable copy from its record, so booting
    /// it always starts from the generation as it was. the copy that's
    /// running, if it's this one, is left alone.
    fn freshCopy(m: *const Machine, n: u32, copy: []const u8) !?[]const u8 {
        if (m.boot.root_subvol) |running| {
            if (std.mem.eql(u8, running, copy)) return null;
        }
        const path = try m.at(&.{copy});
        if (btrfs.isSubvolume(path) catch false) {
            btrfs.delete(path) catch |e| return try std.fmt.allocPrint(m.a, "can't remove the old copy {s}: {s}", .{ copy, @errorName(e) });
        }
        const saved = try m.at(&.{ generation.gens_dir, try std.fmt.allocPrint(m.a, "{d}", .{n}) });
        btrfs.snapshot(saved, path, false) catch |e| return try std.fmt.allocPrint(m.a, "can't copy generation {d}: {s}", .{ n, @errorName(e) });
        return null;
    }

    /// a menu entry for the root at `subvol`: its kernel, microcode, and
    /// initramfs, from its own /boot.
    fn entry(m: *const Machine, id: []const u8, name: []const u8, subvol: []const u8, cmdline: []const u8) !generation.Entry {
        var kernel: []const u8 = "vmlinuz-linux";
        var initrds: std.ArrayList([]const u8) = .empty;
        var boot = std.Io.Dir.cwd().openDir(m.io, try m.at(&.{ subvol, "boot" }), .{ .iterate = true }) catch null;
        if (boot) |*b| {
            defer b.close(m.io);
            var it = b.iterate();
            while (it.next(m.io) catch null) |f| {
                if (std.mem.startsWith(u8, f.name, "vmlinuz-")) kernel = try m.a.dupe(u8, f.name);
                if (std.mem.endsWith(u8, f.name, "-ucode.img")) try initrds.append(m.a, try m.a.dupe(u8, f.name));
            }
        }
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
    const dir_path = try std.fs.path.join(a, &.{ var_dir, "lib/yoq/generations" });
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
    const dir = try std.fs.path.join(a, &.{ var_dir, "lib/yoq/generations" });
    const path = try std.fmt.allocPrint(a, "{s}/{d}.json", .{ dir, r.n });
    std.Io.Dir.cwd().createDirPath(io, dir) catch return try std.fmt.allocPrint(a, "can't create {s}", .{dir});
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json.written() }) catch return try std.fmt.allocPrint(a, "can't write {s}", .{path});
    return null;
}

pub fn uuidOf(a: Allocator, io: std.Io, device: []const u8, why: *[]const u8) !?[]const u8 {
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
