//! boot files on the esp: copies of each root's kernels and initramfs
//! images, named by their content so generations share them, the unified
//! kernel images images.zig builds, and, with /boot as the esp, the copies
//! each root keeps in its own /boot. every file goes in whole or not at
//! all.

const std = @import("std");
const lists = @import("lists.zig");
const rootfs = @import("rootfs.zig");
const exec = @import("exec.zig");
const generation = @import("generation.zig");
const menu = @import("menu.zig");
const images = @import("images.zig");
const gens = @import("gens.zig");
const Machine = gens.Machine;
const Allocator = std.mem.Allocator;

/// where copies of boot files, and unified kernel images, go on the esp.
pub const esp_boot_dir = "yoq/boot";

/// puts the menu in place, for entries whose files are where it says,
/// with `entries[held]` as the default when it's given, and the first
/// entry otherwise.
pub const MenuWriter = *const fn (*const Machine, []menu.Entry, held: ?usize) anyerror!?[]const u8;

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
/// goes on the esp, and one there without sbctl's signature is built
/// again and signed, so a fallback to an older generation boots too.
/// what's on the esp is never signed as it is: whoever can write to
/// it, like another system on the disk, could have put it there. each
/// image has its entry's command line in it then, so images are per
/// entry, shared only by entries with the same command line, and the
/// entry a trial boots has one of its own (see images.ukiName).
pub fn writeOnEsp(m: *const Machine, entries: []menu.Entry, records: []const generation.Record, put: MenuWriter, held: ?usize) !?[]const u8 {
    const dir = try std.fs.path.join(m.a, &.{ m.boot.esp.?, esp_boot_dir });
    const sign = entries.len > 0 and m.signs(entries[0].subvol);
    const work = if (entries.len > 0) try m.at(&.{ entries[0].subvol, images.sign_dir }) else "";
    var files: EspFiles = .{};
    if (menu.copiesOnEsp(m.boot) or try images.anyImage(m, entries)) {
        if (try m.run(&.{ "mkdir", "-p", dir })) |w| return w;
        if (try espFiles(m, entries, &files, sign)) |w| return w;
        if (try fillEsp(m, dir, &files, records, sign)) |w| return w;
    }
    if (try put(m, entries, held)) |w| return w;
    // with no entry using it, everything goes, like images from before
    // `[boot] uki` went off.
    removeUnused(m, dir, files.used.items, "", "");
    return if (sign) images.signLoader(m, work) else null;
}

/// what a menu's entries need in the esp's boot directory: the names
/// they use there, and the copies and images it doesn't have yet.
pub const EspFiles = struct {
    used: std.ArrayList([]const u8) = .empty,
    missing: std.ArrayList(EspCopy) = .empty,
    builds: std.ArrayList(images.UkiBuild) = .empty,

    /// the room the ones it doesn't have take, and the largest image
    /// built again, which needs room for its new copy beside the old
    /// one while it replaces it.
    fn size(f: *const EspFiles) u64 {
        var n: u64 = 0;
        var largest: u64 = 0;
        for (f.missing.items) |c| n += c.size;
        for (f.builds.items) |b| {
            if (b.again) largest = @max(largest, b.size) else n += b.size;
        }
        return n + largest;
    }
};

/// points each entry at its files on the esp, and notes them in
/// `files`: an image for an entry whose root boots one, and, for a
/// bootloader that can't read the roots, copies of the rest. with
/// `sign`, an image there without sbctl's signature is built again.
fn espFiles(m: *const Machine, entries: []menu.Entry, files: *EspFiles, sign: bool) !?[]const u8 {
    const copies = menu.copiesOnEsp(m.boot);
    for (entries, 0..) |*e, n| {
        if (try m.bootsImage(e.subvol)) {
            // the first entry is the one a trial boots.
            if (try images.ukiName(m, e, files, sign, n == 0)) |w| return w;
            continue;
        }
        if (!copies or e.esp_dir != null) continue;
        const from = try m.at(&.{ e.subvol, "boot" });
        if (try espName(m, from, &e.kernel, files)) |w| return w;
        const initrds = try m.a.dupe([]const u8, e.initrds);
        for (initrds) |*i| {
            if (try espName(m, from, i, files)) |w| return w;
        }
        e.initrds = initrds;
        e.esp_dir = esp_boot_dir;
    }
    return null;
}

/// puts what `files` says the esp at `dir` lacks there: copies and
/// images, signed with `sign`. if it doesn't all fit, nothing changes.
/// on a way back, an image that can't be built again stays as it is,
/// noted as unsigned.
fn fillEsp(m: *const Machine, dir: []const u8, files: *const EspFiles, records: []const generation.Record, sign: bool) !?[]const u8 {
    if (try checkRoom(m, dir, files.size(), records)) |w| return w;
    for (files.missing.items) |c| {
        if (try replaceFile(m, c.src, c.dest)) |w| return w;
    }
    for (files.builds.items) |b| {
        const why = try images.buildUki(m, b, sign) orelse continue;
        const left = m.left_unsigned orelse return why;
        if (!b.again) return why;
        if (!lists.contains(left.items, b.dest)) try left.append(m.a, b.dest);
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

/// a boot file the esp doesn't have yet, and where it goes.
const EspCopy = struct { src: []const u8, dest: []const u8, size: u64 };

/// deletes the files in `dir` named `prefix`*`suffix` that aren't in
/// `used`.
pub fn removeUnused(m: *const Machine, dir: []const u8, used: []const []const u8, prefix: []const u8, suffix: []const u8) void {
    var d = std.Io.Dir.cwd().openDir(m.io, dir, .{ .iterate = true }) catch return;
    defer d.close(m.io);
    var it = d.iterate();
    while (it.next(m.io) catch null) |f| {
        if (!std.mem.startsWith(u8, f.name, prefix) or !std.mem.endsWith(u8, f.name, suffix)) continue;
        if (!lists.contains(used, f.name)) d.deleteFile(m.io, f.name) catch {};
    }
}

/// makes `name`, a file in `from`, the name of its copy in the esp's
/// boot directory, "<hash>-<name>", and notes it in `files`, along
/// with the copy if the esp doesn't have it yet.
fn espName(m: *const Machine, from: []const u8, name: *[]const u8, files: *EspFiles) !?[]const u8 {
    const src = try std.fs.path.join(m.a, &.{ from, name.* });
    var why: []const u8 = "";
    const h = try hash(m, src, &why) orelse return why;
    name.* = try std.fmt.allocPrint(m.a, "{s}-{s}", .{ h.sum[0..16], name.* });
    const dest = try newOnEsp(m, name.*, files) orelse return null;
    try files.missing.append(m.a, .{ .src = src, .dest = dest, .size = h.size });
    return null;
}

/// notes `name` as used in the esp's boot directory, and returns its
/// path there when the esp doesn't have it and `files` didn't have
/// it already.
pub fn newOnEsp(m: *const Machine, name: []const u8, files: *EspFiles) !?[]const u8 {
    if (lists.contains(files.used.items, name)) return null;
    try files.used.append(m.a, name);
    const dest = try std.fs.path.join(m.a, &.{ m.boot.esp.?, esp_boot_dir, name });
    return if (rootfs.pathExists(m.io, dest)) null else dest;
}

/// a boot file's sha256 sum, in hex, and its size.
const Hashed = struct { sum: []const u8, size: u64 };

/// hashes the file at `path`, or says why it can't in `why`.
pub fn hash(m: *const Machine, path: []const u8, why: *[]const u8) !?Hashed {
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
pub fn replaceFile(m: *const Machine, src: []const u8, dest: []const u8) !?[]const u8 {
    const why = try exec.runAll(m.a, m.io, try replaceSteps(m.a, src, dest)) orelse return null;
    // a copy cut short, by a full esp say, would only take up room.
    std.Io.Dir.cwd().deleteFile(m.io, try std.fmt.allocPrint(m.a, "{s}.yoq-new", .{dest})) catch {};
    return why;
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
    return syncBoot(m, from, to, try bootSync(m, from, to, &why) orelse return why);
}

/// puts the boot files kept in the root at `subvol` back on the esp,
/// for a root that's about to be the newest. when they don't all fit,
/// none are copied.
pub fn restoreBoot(m: *const Machine, subvol: []const u8) !Put {
    if (!m.bootOnEsp()) return .done;
    var why: []const u8 = "";
    const from = try m.at(&.{ subvol, "boot" });
    const esp = m.boot.esp.?;
    const s = try bootSync(m, from, esp, &why) orelse return .{ .failed = why };
    if (rootfs.freeBytes(esp)) |room| {
        // older generations' copies may be there too, which `os gc`
        // frees.
        const collectable = menu.copiesOnEsp(m.boot);
        const records = try gens.readRecords(m.a, m.io, "/var");
        if (try generation.espRoom(m.a, esp, generation.copyPeak(s.sizes.items), room, records, m.boot.root_subvol orelse "", collectable)) |w| return .{ .full = w };
    }
    if (try syncBoot(m, from, esp, s)) |w| return .{ .failed = w };
    return .done;
}

/// what making the boot files in `to` match the ones in `from` takes:
/// the files to copy, with the room each takes, and the stale ones to
/// remove. files that already match stay, so snapshots keep sharing
/// them. null after saying why in `why`.
fn bootSync(m: *const Machine, from: []const u8, to: []const u8, why: *[]const u8) !?BootSync {
    const old = try bootFiles(m, to) orelse return try syncFailed(m, why, "can't read {s}", .{to});
    const new = try bootFiles(m, from) orelse return try syncFailed(m, why, "can't read {s}", .{from});
    var s: BootSync = .{};
    for (new) |f| {
        const src = try std.fs.path.join(m.a, &.{ from, f });
        const dest = try std.fs.path.join(m.a, &.{ to, f });
        var replaces: u64 = 0;
        if (std.Io.Dir.cwd().statFile(m.io, dest, .{})) |st| {
            if (try m.run(&.{ "cmp", "-s", src, dest }) == null) continue;
            replaces = st.size;
        } else |_| {}
        const st = std.Io.Dir.cwd().statFile(m.io, src, .{}) catch return try syncFailed(m, why, "can't read {s}", .{src});
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
        if (try replaceFile(m, try std.fs.path.join(m.a, &.{ from, f }), try std.fs.path.join(m.a, &.{ to, f }))) |w| return w;
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
