//! generations on the rollback rung: where they live on btrfs, and what
//! os keeps about each one. this part is pure; menu.zig has the boot menu,
//! and cmd/enable_rollback.zig and apply do the work.
//!
//! the layout, under the btrfs top level:
//!   @roots/<n>       writable roots: the one running, and the one before it
//!   @roots/boot-<n>  a fresh writable copy of generation n, for its menu
//!                    entry, remade whenever the menu is written
//!   @gens/<n>        a read-only record of every generation
//!   @var             /var, which never rolls back

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const roots_dir = "@roots";
pub const gens_dir = "@gens";
pub const var_subvol = "@var";

/// data directories besides /var that no generation holds, and the
/// subvolume each gets when it's inside the root.
pub const DataDir = struct { dir: []const u8, subvol: []const u8 };

pub const data_dirs = [_]DataDir{
    .{ .dir = "home", .subvol = "@home" },
    .{ .dir = "root", .subvol = "@root" },
    .{ .dir = "srv", .subvol = "@srv" },
    .{ .dir = "usr/local", .subvol = "@usrlocal" },
};

/// where the btrfs top level is mounted while os works on it.
pub const top_mount = @import("rootfs.zig").private_dir ++ "/top";

/// generation records, one json file each, under /var so they outlive
/// every rollback. relative to a var directory.
pub const records_dir = "lib/yoq/generations";

/// where the rollback rung keeps the pacman database, in /usr beside the
/// packages it describes. /var/lib/pacman links to it.
pub const pacman_db = "usr/lib/sysimage/pacman";

/// grub's env file, from the top of the esp.
pub const grubenv = "yoq/grubenv";

/// where a staged root is noted until it has booted well: with /boot as
/// the esp, it boots its own kernel till then, and moves it onto the esp.
/// a rollback whose boot files didn't fit on the esp notes its root too.
pub const unsettled_path = "/var/lib/yoq/unsettled";

/// where enable-rollback notes the root the next boot runs, in the /var
/// the machine runs now, so nothing changes the root it's leaving.
pub const pending_path = "/var/lib/yoq/pending";

/// the sha-256 of the grub binary os last built and signed for secure
/// boot.
pub const grub_signed_path = "/var/lib/yoq/grub-signed";

/// whether a machine runs a generation: its root is one of @roots.
pub fn running(root_subvol: ?[]const u8) bool {
    const sv = root_subvol orelse return false;
    return std.mem.startsWith(u8, sv, "/" ++ roots_dir ++ "/");
}

/// what os keeps about a generation.
pub const Record = struct {
    n: u32,
    /// unix seconds.
    time: i64,
    /// its writable root, under the top level.
    root: []const u8,
    /// what made it, like "enable-rollback" or "add fd".
    reason: []const u8,
    /// for the first generation: the root the machine ran before, still
    /// bootable from the menu.
    from: ?[]const u8 = null,
    /// the config directory and its commit when the generation was made,
    /// so a rollback can put that config back.
    config_dir: ?[]const u8 = null,
    config_rev: ?[]const u8 = null,
    /// kept by garbage collection however old it gets.
    pinned: bool = false,
};

/// the generation a trial of the newest of `records` falls back to, which
/// stays the menu's default until the trial passes: with a trial already
/// waiting for a reboot, the one that trial falls back to, `pending`, the
/// last that booted, while it's there; otherwise the one before the
/// newest. null with no generation before it.
pub fn trialFallback(records: []const Record, pending: u32) ?u32 {
    if (records.len < 2) return null;
    if (pending != 0 and pending != records[records.len - 1].n and find(records, pending) != null) return pending;
    return records[records.len - 2].n;
}

/// the generation a fallback from trial `tried` made already, with
/// `reason`, as when a power cut stopped it before the trial ended. only
/// one newer than the trial counts, so a fallback from an earlier trial
/// of the same number, since collected and made again, doesn't.
pub fn made(records: []const Record, tried: u32, reason: []const u8) ?u32 {
    var i = records.len;
    while (i > 0) {
        i -= 1;
        const r = records[i];
        if (r.n <= tried) return null;
        if (std.mem.eql(u8, r.reason, reason)) return r.n;
    }
    return null;
}

test "a fallback that made its generation already isn't made twice" {
    const recs = [_]Record{
        .{ .n = 4, .time = 4, .root = "@roots/1", .reason = "apply" },
        .{ .n = 5, .time = 5, .root = "@roots/2", .reason = "update" },
        .{ .n = 6, .time = 6, .root = "@roots/3", .reason = "fell back from 5 to 4" },
    };
    try testing.expectEqual(6, made(&recs, 5, "fell back from 5 to 4"));
    try testing.expectEqual(null, made(recs[0..2], 5, "fell back from 5 to 4"));
    // one from an older trial doesn't count.
    try testing.expectEqual(null, made(&recs, 7, "fell back from 5 to 4"));
}

test "a trial falls back to the generation that booted last" {
    const r = struct {
        fn at(n: u32) Record {
            return .{ .n = n, .time = n, .root = "@roots/1", .reason = "apply" };
        }
    }.at;
    try testing.expectEqual(null, trialFallback(&.{r(1)}, 0));
    try testing.expectEqual(3, trialFallback(&.{ r(1), r(3), r(4) }, 0));
    // a trial for 4 waits still, from 3: 5 replaces it, and falls back to 3.
    try testing.expectEqual(3, trialFallback(&.{ r(1), r(3), r(4), r(5) }, 3));
    // unless gc took 3, or the pending one is the newest itself.
    try testing.expectEqual(4, trialFallback(&.{ r(1), r(4), r(5) }, 3));
    try testing.expectEqual(4, trialFallback(&.{ r(1), r(4), r(5) }, 5));
}

/// the subvolumes among `roots` (names in @roots) and `gens` (names in
/// @gens) that belong to no generation in `records`, as paths from the
/// top level. a run cut off leaves these: a staged build stopped with
/// ctrl-c, a rollback between its snapshot and its record, or gc between
/// a record and its snapshots. nothing would ever remove them, and a
/// staged root can hold gigabytes. the root `running` runs stays, and so
/// do names os doesn't make.
pub fn strays(a: Allocator, records: []const Record, roots: []const []const u8, gens: []const []const u8, running_root: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (records.len == 0) return out.items;
    for (gens) |name| {
        const n = std.fmt.parseInt(u32, name, 10) catch continue;
        if (find(records, n) == null) try out.append(a, try std.fmt.allocPrint(a, gens_dir ++ "/{s}", .{name}));
    }
    for (roots) |name| {
        const path = try std.fmt.allocPrint(a, roots_dir ++ "/{s}", .{name});
        if (std.mem.eql(u8, std.mem.trimStart(u8, running_root, "/"), path)) continue;
        const used = if (std.mem.startsWith(u8, name, "boot-")) blk: {
            const n = std.fmt.parseInt(u32, name["boot-".len..], 10) catch continue;
            break :blk find(records, n) != null;
        } else blk: {
            _ = std.fmt.parseInt(u32, name, 10) catch continue;
            for (records) |r| {
                if (std.mem.eql(u8, r.root, path)) break :blk true;
                if (r.from) |f| if (std.mem.eql(u8, std.mem.trimStart(u8, f, "/"), path)) break :blk true;
            }
            break :blk false;
        };
        if (!used) try out.append(a, path);
    }
    return out.items;
}

test "subvolumes no generation uses" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const records = [_]Record{
        .{ .n = 1, .time = 1, .root = "@roots/1", .reason = "enable-rollback", .from = "/" },
        .{ .n = 3, .time = 3, .root = "@roots/1", .reason = "add fd" },
        .{ .n = 4, .time = 4, .root = "@roots/4", .reason = "update" },
    };
    const got = try strays(a, &records, &.{
        "1",
        "4",
        // a staged build stopped with ctrl-c, and a rollback cut off
        // before its record.
        "5",
        "6",
        // copies for the menu, and one gc removed the record of.
        "boot-1",
        "boot-3",
        "boot-2",
        // the copy the machine runs, after a fallback took its record.
        "boot-7",
        // not os's.
        "mine",
    }, &.{ "1", "2", "3", "4", "keep" }, "/@roots/boot-7");
    try testing.expectEqual(4, got.len);
    try testing.expectEqualStrings("@gens/2", got[0]);
    try testing.expectEqualStrings("@roots/5", got[1]);
    try testing.expectEqualStrings("@roots/6", got[2]);
    try testing.expectEqualStrings("@roots/boot-2", got[3]);
    try testing.expectEqual(0, (try strays(a, &records, &.{ "1", "4" }, &.{ "1", "3", "4" }, "/@roots/4")).len);
    // with no records in this /var, as before enable-rollback's reboot,
    // nothing is a stray.
    try testing.expectEqual(0, (try strays(a, &.{}, &.{ "1", "boot-1" }, &.{"1"}, "/")).len);
}

/// how many generations garbage collection keeps, besides pinned ones and
/// the first.
pub const default_keep = 5;

/// the generations to keep of `records`, sorted by number: the newest
/// `keep`, the first, and every pinned one.
pub fn keeps(r: Record, records: []const Record, keep: usize) bool {
    if (r.n == 1 or r.pinned) return true;
    var newer: usize = 0;
    for (records) |o| newer += @intFromBool(o.n > r.n);
    return newer < keep;
}

/// a config directory at one commit.
pub const Config = struct { dir: []const u8, rev: []const u8 };

/// what a new generation's record says about where it came from: what
/// made it, when, in unix seconds, and the config commit it matches, when
/// there is one.
pub const Stamp = struct { reason: []const u8, time: i64, config: ?Config };

/// a file in /boot that belongs to the root beside it: a kernel, a
/// microcode image, or an initramfs. fallback images are left out; they're
/// large and no menu entry uses them. so is a name with anything but
/// letters, digits, and ._+-: the names go into menus, unquoted in
/// grub.cfg, and the esp's files can be named anything fat allows, like
/// "x;set root=...;-ucode.img".
pub fn bootFile(name: []const u8) bool {
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "._+-", ch) == null) return false;
    }
    if (std.mem.startsWith(u8, name, "vmlinuz-") or std.mem.endsWith(u8, name, "-ucode.img")) return true;
    return std.mem.startsWith(u8, name, "initramfs-") and std.mem.endsWith(u8, name, ".img") and !std.mem.endsWith(u8, name, "-fallback.img");
}

/// the writable copy the menu boots for an older generation.
pub fn bootCopy(a: Allocator, n: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "/{s}/boot-{d}", .{ roots_dir, n });
}

/// the writable copy a menu for `records` has no use for: the newest
/// generation's, since the newest boots its own root. a menu written for a
/// newer generation that then went, like a staged one that couldn't be
/// recorded, leaves one. null if there are no records, or if the copy is
/// `running_root`, the root this machine runs.
pub fn spareCopy(a: Allocator, records: []const Record, running_root: []const u8) !?[]const u8 {
    if (records.len == 0) return null;
    const copy = try bootCopy(a, records[records.len - 1].n);
    return if (std.mem.eql(u8, copy, running_root)) null else copy;
}

/// the generation whose copy the root at `subvol` is, if it's one.
pub fn bootCopyOf(subvol: []const u8) ?u32 {
    const prefix = "/" ++ roots_dir ++ "/boot-";
    if (!std.mem.startsWith(u8, subvol, prefix)) return null;
    return std.fmt.parseInt(u32, subvol[prefix.len..], 10) catch null;
}

pub fn find(records: []const Record, n: u32) ?Record {
    for (records) |r| {
        if (r.n == n) return r;
    }
    return null;
}

/// a btrfs mount option that picks the subvolume, which each root sets
/// for itself.
pub fn subvolOption(o: []const u8) bool {
    return std.mem.startsWith(u8, o, "subvol=") or std.mem.startsWith(u8, o, "subvolid=");
}

/// the words of a kernel command line, split the way the kernel splits
/// them: at spaces, but not inside double quotes, so a word like
/// acpi_osi="!Windows 2012" stays one word, spacing and all.
pub const Words = struct {
    text: []const u8,
    i: usize = 0,

    pub fn next(w: *Words) ?[]const u8 {
        while (w.i < w.text.len and std.ascii.isWhitespace(w.text[w.i])) w.i += 1;
        if (w.i == w.text.len) return null;
        const start = w.i;
        var quoted = false;
        while (w.i < w.text.len) : (w.i += 1) {
            const ch = w.text[w.i];
            if (ch == '"') quoted = !quoted;
            if (!quoted and std.ascii.isWhitespace(ch)) break;
        }
        return w.text[start..w.i];
    }
};

/// a generation's kernel command line, from the running one: the root is
/// the btrfs filesystem by uuid, mounted from `subvol`; other rootflags
/// and arguments stay as they are. on luks, that's the filesystem inside,
/// and the arguments that unlock it, like rd.luks.name= or cryptdevice=,
/// come along with the rest.
pub fn kernelArgs(a: Allocator, cmdline: []const u8, root_uuid: []const u8, subvol: []const u8) ![]const u8 {
    var flags: std.ArrayList(u8) = .empty;
    try flags.print(a, "subvol={s}", .{subvol});
    var rest: std.ArrayList(u8) = .empty;
    var words: Words = .{ .text = cmdline };
    while (words.next()) |w| {
        if (std.mem.startsWith(u8, w, "BOOT_IMAGE=") or std.mem.startsWith(u8, w, "initrd=") or std.mem.startsWith(u8, w, "root=")) continue;
        // a trial boot adds this; it's never part of an entry.
        if (std.mem.eql(u8, w, "yoq.trial")) continue;
        if (std.mem.startsWith(u8, w, "rootflags=")) {
            var opts = std.mem.tokenizeScalar(u8, w["rootflags=".len..], ',');
            while (opts.next()) |o| {
                if (subvolOption(o)) continue;
                try flags.print(a, ",{s}", .{o});
            }
            continue;
        }
        try rest.print(a, " {s}", .{w});
    }
    // a kernel that panics reboots, so a generation on trial falls back.
    const panic = if (std.mem.indexOf(u8, rest.items, " panic=") == null) " panic=10" else "";
    // the initramfs waits as long as the passphrase takes. by default its
    // devices time out after 90 seconds, and a passphrase typed later
    // lands in emergency mode, where a trial's watchdog never starts.
    const wait = if (std.mem.indexOf(u8, rest.items, " rd.luks.") != null and std.mem.indexOf(u8, rest.items, " " ++ luks_wait_key) == null) " " ++ luks_wait else "";
    return std.fmt.allocPrint(a, "root=UUID={s} rootflags={s}{s}{s}{s}", .{ root_uuid, flags.items, rest.items, panic, wait });
}

/// what keeps sd-encrypt's initramfs at the passphrase prompt for good.
pub const luks_wait_key = "rd.systemd.default_device_timeout_sec=";
pub const luks_wait = luks_wait_key ++ "infinity";

/// `target`'s shadow file with the password hash, and when it last
/// changed, taken from `current` for every user both have. users only in
/// one of them stay as they are.
pub fn mergeShadow(a: Allocator, current: []const u8, target: []const u8) ![]const u8 {
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
        var ours = std.mem.splitScalar(u8, now, ':');
        _ = ours.next();
        const hash = ours.next() orelse "";
        const changed = ours.next() orelse "";
        var theirs = std.mem.splitScalar(u8, line, ':');
        for (0..3) |_| _ = theirs.next();
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
pub fn next(records: []const Record) u32 {
    var n: u32 = 1;
    for (records) |r| n = @max(n, r.n + 1);
    return n;
}

/// "yoq 2 · 2026-09-26 · add fd".
pub fn title(a: Allocator, r: Record) ![]const u8 {
    return std.fmt.allocPrint(a, "yoq {d} · {s} · {s}", .{ r.n, try dateOf(a, r.time), r.reason });
}

/// room left over on the esp besides new boot files: fat rounds every
/// file up to a whole cluster, and a copy goes in beside its name before
/// it's renamed there.
pub const esp_slack = 1 << 20;

/// whether new boot files of `need` bytes fit in the `free` bytes of an
/// esp.
pub fn fits(need: u64, free: u64) bool {
    return need +| esp_slack <= free;
}

/// null if new boot files of `need` bytes fit in the `free` bytes of the
/// esp at `esp`, or else what to say: how far short it is, and how to
/// make room. when older generations keep boot files there, that's which
/// of `records` `os gc --keep 1` would remove (see `gcHint`).
pub fn espRoom(a: Allocator, esp: []const u8, need: u64, free: u64, records: anytype, running_root: []const u8, collectable: bool) !?[]const u8 {
    if (fits(need, free)) return null;
    const mib = 1 << 20;
    const hint = if (collectable) try gcHint(a, records, running_root) else manual_hint;
    return try std.fmt.allocPrint(a, "the esp at {s} has {d} MiB free, and the new boot files need {d} MiB. {s}", .{ esp, free / mib, (need + mib - 1) / mib, hint });
}

/// which of `records` `os gc --keep 1` would remove, with the boot files
/// on the esp only they use: all but the first, the pinned ones, the
/// newest, and the one whose root is `running_root`, the root this
/// machine runs. `records` are sorted by number and have `n`, `root`, and
/// `pinned`, like a `Record`.
pub fn gcHint(a: Allocator, records: anytype, running_root: []const u8) ![]const u8 {
    var runs: u32 = 0;
    for (records) |r| {
        if (std.mem.eql(u8, r.root, std.mem.trimStart(u8, running_root, "/"))) runs = r.n;
    }
    var old: std.ArrayList(u32) = .empty;
    for (records, 0..) |r, i| {
        if (r.n == 1 or r.pinned or r.n == runs or i == records.len - 1) continue;
        try old.append(a, r.n);
    }
    const n = old.items.len;
    if (n == 0) return "no generation is left to remove, so make room there by hand";
    // "2", "2 and 4", "2, 4, and 5".
    var list: std.ArrayList(u8) = .empty;
    for (old.items, 0..) |g, i| {
        const sep = if (i == 0) "" else if (n == 2) " and " else if (i == n - 1) ", and " else ", ";
        try list.print(a, "{s}{d}", .{ sep, g });
    }
    return std.fmt.allocPrint(a, "`os gc --keep 1` removes generation{s} {s}, with the boot files only {s}", .{
        if (n == 1) "" else "s",
        list.items,
        if (n == 1) "it uses" else "they use",
    });
}

/// what to do about a full esp that holds only the running root's boot
/// files, as with grub or refind and the esp at /boot: older generations
/// boot theirs from their own roots, so removing them frees nothing there.
pub const manual_hint = "only the running system's boot files are there, so removing generations won't help. make room by hand, like removing the fallback initramfs images, which no entry in os's menu boots";

/// a boot file to copy: its size, and the size of the file it replaces,
/// 0 if none.
pub const Copy = struct { size: u64, replaces: u64 = 0 };

/// the most room `copies`, made in order, take at once. each goes in
/// beside the file it replaces, which is freed only once the copy is
/// renamed over it.
pub fn copyPeak(copies: []const Copy) u64 {
    var grown: i128 = 0;
    var peak: i128 = 0;
    for (copies) |c| {
        peak = @max(peak, grown + c.size);
        grown += @as(i128, c.size) - c.replaces;
    }
    return @intCast(peak);
}

/// under this much free space, a new root that didn't build likely ran
/// out of room: a kernel's modules and initramfs images take a few
/// hundred MiB.
pub const build_room = 1 << 30;

/// what to add when a new root didn't build on a filesystem with `free`
/// bytes left, or null when that's plenty.
pub fn lowSpace(a: Allocator, free: u64) !?[]const u8 {
    if (free >= build_room) return null;
    return try std.fmt.allocPrint(a, "the root filesystem has {d} MiB free, which is likely why. `os gc` removes old generations and the space only they use; make room and try again", .{free >> 20});
}

/// "2026-09-26" for unix seconds.
pub fn dateOf(a: Allocator, secs: i64) ![]const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    return std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2}", .{ day.year, md.month.numeric(), md.day_index + 1 });
}

// -- tests --

const testing = std.testing;

test "which generations collection keeps" {
    const recs = [_]Record{
        .{ .n = 1, .time = 0, .root = "@roots/1", .reason = "enable-rollback" },
        .{ .n = 2, .time = 0, .root = "@roots/1", .reason = "a" },
        .{ .n = 3, .time = 0, .root = "@roots/1", .reason = "b", .pinned = true },
        .{ .n = 4, .time = 0, .root = "@roots/1", .reason = "c" },
        .{ .n = 5, .time = 0, .root = "@roots/1", .reason = "d" },
        .{ .n = 6, .time = 0, .root = "@roots/1", .reason = "e" },
    };
    var kept: [6]bool = undefined;
    for (recs, &kept) |r, *k| k.* = keeps(r, &recs, 2);
    try testing.expectEqualSlices(bool, &.{ true, false, true, false, true, true }, &kept);
}

test "boot files that don't fit on the esp name what gc would remove" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mib = 1 << 20;
    var recs = [_]Record{
        .{ .n = 1, .time = 0, .root = "@roots/1", .reason = "enable-rollback" },
        .{ .n = 2, .time = 0, .root = "@roots/1", .reason = "a" },
        .{ .n = 3, .time = 0, .root = "@roots/1", .reason = "b", .pinned = true },
        .{ .n = 4, .time = 0, .root = "@roots/1", .reason = "c" },
        .{ .n = 5, .time = 0, .root = "@roots/5", .reason = "d" },
        .{ .n = 6, .time = 0, .root = "@roots/6", .reason = "e" },
    };
    try testing.expectEqual(null, try espRoom(a, "/boot", 30 * mib, 64 * mib, &recs, "/@roots/5", true));
    // the room to spare counts too.
    try testing.expect(try espRoom(a, "/boot", 30 * mib, 30 * mib, &recs, "/@roots/5", true) != null);
    try testing.expectEqualStrings(
        "the esp at /boot has 2 MiB free, and the new boot files need 31 MiB. `os gc --keep 1` removes generations 2 and 4, with the boot files only they use",
        (try espRoom(a, "/boot", 30 * mib + 1, 2 * mib + 5, &recs, "/@roots/5", true)).?,
    );
    // several generations share a root; the newest of them is the one running.
    try testing.expectEqualStrings(
        "the esp at /boot has 0 MiB free, and the new boot files need 1 MiB. `os gc --keep 1` removes generations 2 and 5, with the boot files only they use",
        (try espRoom(a, "/boot", 10, 0, &recs, "/@roots/1", true)).?,
    );
    try testing.expectEqualStrings(
        "the esp at /boot has 0 MiB free, and the new boot files need 1 MiB. `os gc --keep 1` removes generations 2, 4, and 5, with the boot files only they use",
        (try espRoom(a, "/boot", 10, 0, &recs, "/@roots/6", true)).?,
    );
    recs[1].pinned = true;
    try testing.expectEqualStrings(
        "the esp at /boot has 0 MiB free, and the new boot files need 1 MiB. `os gc --keep 1` removes generation 4, with the boot files only it uses",
        (try espRoom(a, "/boot", 10, 0, &recs, "/@roots/5", true)).?,
    );
    try testing.expectEqualStrings(
        "the esp at /efi has 0 MiB free, and the new boot files need 1 MiB. no generation is left to remove, so make room there by hand",
        (try espRoom(a, "/efi", 10, 0, recs[0..2], "/@roots/1", true)).?,
    );
    // with only the running system's files there, collecting frees nothing.
    try testing.expectEqualStrings(
        "the esp at /boot has 0 MiB free, and the new boot files need 1 MiB. " ++ manual_hint,
        (try espRoom(a, "/boot", 10, 0, &recs, "/@roots/5", false)).?,
    );
}

test "copies take the most room partway" {
    try testing.expectEqual(0, copyPeak(&.{}));
    // new files add up.
    try testing.expectEqual(30, copyPeak(&.{ .{ .size = 10 }, .{ .size = 20 } }));
    // a replaced file is freed once its copy is in place, not before.
    try testing.expectEqual(22, copyPeak(&.{ .{ .size = 12, .replaces = 10 }, .{ .size = 20, .replaces = 20 } }));
    try testing.expectEqual(20, copyPeak(&.{ .{ .size = 20, .replaces = 20 }, .{ .size = 12, .replaces = 10 } }));
    // a smaller file makes room for the next.
    try testing.expectEqual(10, copyPeak(&.{ .{ .size = 5, .replaces = 15 }, .{ .size = 20 } }));
}

test "a build that failed on a nearly full filesystem says so" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(null, try lowSpace(a, build_room));
    try testing.expectEqualStrings(
        "the root filesystem has 12 MiB free, which is likely why. `os gc` removes old generations and the space only they use; make room and try again",
        (try lowSpace(a, 12 << 20 | 5)).?,
    );
}

test "a generation's kernel command line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cmdline = "BOOT_IMAGE=/boot/vmlinuz-linux root=UUID=abc rw net.ifnames=0 rootflags=compress=zstd:1,subvol=/@ console=ttyS0,115200 yoq.trial\n";
    try testing.expectEqualStrings("root=UUID=abc rootflags=subvol=/@roots/1,compress=zstd:1 rw net.ifnames=0 console=ttyS0,115200 panic=10", try kernelArgs(arena.allocator(), cmdline, "abc", "/@roots/1"));
    try testing.expectEqualStrings("root=UUID=abc rootflags=subvol=/ rw panic=30", try kernelArgs(arena.allocator(), "rw panic=30", "abc", "/"));
    // on luks, what unlocks the root comes along, for sd-encrypt and for
    // busybox's encrypt hook, and the root is the btrfs inside it.
    const sd = "root=/dev/mapper/root rootflags=subvol=/@ rd.luks.name=0f7a1c2e-9b3d-4e5f-8a6b-7c8d9e0f1a2b=root rd.luks.options=tpm2-device=auto rw";
    try testing.expectEqualStrings("root=UUID=abc rootflags=subvol=/@roots/2 rd.luks.name=0f7a1c2e-9b3d-4e5f-8a6b-7c8d9e0f1a2b=root rd.luks.options=tpm2-device=auto rw panic=10 rd.systemd.default_device_timeout_sec=infinity", try kernelArgs(arena.allocator(), sd, "abc", "/@roots/2"));
    // the wait goes in once, and only for sd-encrypt's initramfs.
    const waits = try kernelArgs(arena.allocator(), sd ++ " rd.systemd.default_device_timeout_sec=600", "abc", "/@roots/2");
    try testing.expect(std.mem.endsWith(u8, waits, " rd.systemd.default_device_timeout_sec=600 panic=10"));
    const busybox = "cryptdevice=PARTUUID=5e1f:root cryptkey=rootfs:/crypto_keyfile.bin root=/dev/mapper/root rw rootflags=subvol=@";
    try testing.expectEqualStrings("root=UUID=abc rootflags=subvol=/@roots/2 cryptdevice=PARTUUID=5e1f:root cryptkey=rootfs:/crypto_keyfile.bin rw panic=10", try kernelArgs(arena.allocator(), busybox, "abc", "/@roots/2"));
    // a quoted argument stays as it was, spaces and all, and a word in
    // its quotes isn't taken for one of the root's.
    try testing.expectEqualStrings("root=UUID=abc rootflags=subvol=/@roots/2 rw acpi_osi=\"!Windows  2012\" dyndbg=\"file x.c root=y\" panic=10", try kernelArgs(arena.allocator(), "root=/dev/vda2 rw acpi_osi=\"!Windows  2012\" dyndbg=\"file x.c root=y\"\n", "abc", "/@roots/2"));
    try testing.expectEqualStrings("/@roots/boot-2", try bootCopy(arena.allocator(), 2));
    try testing.expectEqual(2, bootCopyOf("/@roots/boot-2"));
    try testing.expectEqual(null, bootCopyOf("/@roots/2"));
}

test "the newest generation's copy is spare, unless it's running" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const recs = [_]Record{
        .{ .n = 1, .time = 0, .root = "@roots/1", .reason = "enable-rollback" },
        .{ .n = 14, .time = 0, .root = "@roots/14", .reason = "add tree" },
    };
    try testing.expectEqualStrings("/@roots/boot-14", (try spareCopy(a, &recs, "/@roots/14")).?);
    try testing.expectEqual(null, try spareCopy(a, &recs, "/@roots/boot-14"));
    try testing.expectEqual(null, try spareCopy(a, &.{}, "/@roots/1"));
}

test "which files in /boot a root keeps" {
    for ([_][]const u8{ "vmlinuz-linux", "vmlinuz-linux-lts", "amd-ucode.img", "initramfs-linux.img" }) |f| try testing.expect(bootFile(f));
    for ([_][]const u8{ "initramfs-linux-fallback.img", "grub", "EFI", "loader.conf" }) |f| try testing.expect(!bootFile(f));
    for ([_][]const u8{ "x;set root=(hd9);-ucode.img", "vmlinuz-a b", "vmlinuz-\x1b[2J", "initramfs-$x.img" }) |f| try testing.expect(!bootFile(f));
}

test "passwords carry over, users don't" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
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
    try testing.expectEqualStrings(
        \\root:$6$new$root:20000::::::
        \\kacy:$6$new$kacy:20001:0:99999:7:::
        \\olduser:$6$y:19002::::::
        \\
    , merged);
}
