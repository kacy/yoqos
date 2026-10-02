//! the boot menu on a running machine: an entry for each generation,
//! from the boot files in its root, and each bootloader's way of putting
//! the menu in place. menu.zig has the pure parts. bootfiles.zig puts
//! what the entries boot on the esp first.

const std = @import("std");
const lists = @import("lists.zig");
const rootfs = @import("rootfs.zig");
const generation = @import("generation.zig");
const menu = @import("menu.zig");
const uki = @import("uki.zig");
const bootfiles = @import("bootfiles.zig");
const images = @import("images.zig");
const gens = @import("gens.zig");
const Machine = gens.Machine;
const Allocator = std.mem.Allocator;

/// the boot menu: the running root, labelled with the newest
/// generation, then every older one, from a fresh writable copy of its
/// record, then the system from before generations. the newest is the
/// default.
pub fn writeMenu(m: *const Machine, head: []const u8, records: []const generation.Record) !?[]const u8 {
    return m.writeMenuHolding(head, records, null);
}

/// `writeMenu`, with generation `hold` as the default instead of the
/// newest, when there's one: a newest generation that goes on trial
/// next isn't the default until it has booted well. the trial's
/// one-shot boot starts it, and the health check moves the default.
pub fn writeMenuHolding(m: *const Machine, head: []const u8, records: []const generation.Record, hold: ?u32) !?[]const u8 {
    if (records.len == 0) return "no generations to put in the menu";
    const cmdline = m.cmdline orelse try rootfs.readProc(m.a, m.io, "/proc/cmdline");
    var entries: std.ArrayList(menu.Entry) = .empty;
    // records come sorted by number.
    const latest = records[records.len - 1];
    if (try generation.spareCopy(m.a, records, m.boot.root_subvol orelse "")) |spare| {
        if (try m.drop(try m.at(&.{spare}))) |w| return w;
    }
    var newest = try m.entry("head", try generation.title(m.a, latest), head, cmdline);
    if (headOnEsp(m, head)) newest.esp_dir = "";
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
    const put: bootfiles.MenuWriter = switch (m.loader) {
        .grub => writeGrub,
        .limine => writeLimine,
        .@"systemd-boot" => writeSdboot,
        .refind => writeRefind,
    };
    const held = if (hold) |n| lists.indexOf(entries.items, "id", try menu.genId(m.a, n)) else null;
    return bootfiles.writeOnEsp(m, entries.items, records, put, held);
}

fn writeGrub(m: *const Machine, entries: []menu.Entry, held: ?usize) anyerror!?[]const u8 {
    const default = if (held) |i| entries[i].id else "head";
    return write(m, try std.fs.path.join(m.a, &.{ m.boot.esp.?, "grub/grub.cfg" }), try menu.grub(m.a, .{ .esp_uuid = m.esp_uuid, .root_uuid = m.root_uuid, .default = default, .entries = entries }));
}

fn write(m: *const Machine, path: []const u8, text: []const u8) !?[]const u8 {
    return rootfs.writeWhole(m.a, m.io, path, text);
}

/// the loader's own config, which os adds its entries to.
fn loaderConf(m: *const Machine) !?[]const u8 {
    const path = m.boot.loader_conf orelse return null;
    return std.Io.Dir.cwd().readFileAlloc(m.io, path, m.a, .limited(1 << 20)) catch null;
}

/// limine boots its first entry, the newest, unless the efi variable
/// bootctl sets names another. a held default is set there before the
/// new section goes in: the generation it names has the same title,
/// and so the same id, at the top of the old section.
fn writeLimine(m: *const Machine, entries: []menu.Entry, held: ?usize) anyerror!?[]const u8 {
    const conf = try loaderConf(m) orelse return "can't read limine.conf";
    if (held) |i| {
        if (try setDefault(m, try menu.limineId(m.a, entries[i].title))) |w| return w;
    }
    return write(m, m.boot.loader_conf.?, try menu.spliceLimine(m.a, conf, try menu.limine(m.a, entries)));
}

/// os's entry files in systemd-boot's loader/entries, beside
/// loader.conf. yoq-*.conf files no entry needs any more go.
///
/// with a held default, every file but the newest's goes in first, the
/// held entry, there now, becomes the default, and only then does
/// yoq-head.conf, the default until then, name the new generation.
fn writeSdboot(m: *const Machine, entries: []menu.Entry, held: ?usize) anyerror!?[]const u8 {
    const dir = try m.sdbootEntries();
    if (try m.run(&.{ "mkdir", "-p", dir })) |w| return w;
    const files = try menu.sdboot(m.a, entries);
    const head = try menu.sdbootName(m.a, "head");
    var names: std.ArrayList([]const u8) = .empty;
    for (files) |f| {
        if (held != null and std.mem.eql(u8, f.name, head)) continue;
        if (try write(m, try std.fs.path.join(m.a, &.{ dir, f.name }), f.text)) |w| return w;
        try names.append(m.a, f.name);
    }
    if (held) |i| {
        if (try setDefault(m, try menu.sdbootName(m.a, entries[i].id))) |w| return w;
        const f = lists.find(files, "name", head).?; // there's always a newest.
        if (try write(m, try std.fs.path.join(m.a, &.{ dir, f.name }), f.text)) |w| return w;
        try names.append(m.a, f.name);
    }
    bootfiles.removeUnused(m, dir, names.items, "yoq-", ".conf");
    return null;
}

/// makes the entry `id` the default of limine or systemd-boot, through
/// the efi variable bootctl sets.
fn setDefault(m: *const Machine, id: []const u8) !?[]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(m.a, m.bootctl);
    try argv.appendSlice(m.a, &.{ "set-default", id });
    return m.run(argv.items);
}

/// systemd-boot's entries directory, beside its loader.conf.
pub fn sdbootEntries(m: *const Machine) ![]const u8 {
    const conf = m.boot.loader_conf orelse try std.fs.path.join(m.a, &.{ m.boot.esp.?, "loader/loader.conf" });
    return std.fs.path.join(m.a, &.{ std.fs.path.dirnamePosix(conf).?, "entries" });
}

/// refind reads btrfs through its driver, so entries boot from each
/// root's own /boot, unless the root is on luks. os's entries go in
/// yoq.conf beside refind.conf, which includes it, and the driver goes
/// in if it's missing.
fn writeRefind(m: *const Machine, entries: []menu.Entry, held: ?usize) anyerror!?[]const u8 {
    const conf = try loaderConf(m) orelse return "can't read refind.conf";
    for (entries) |e| {
        // an image with its command line in it needs none from refind.
        if (e.embedded) continue;
        if (try menu.refindArgsProblem(m.a, e.args)) |w| return w;
    }
    const dir = std.fs.path.dirnamePosix(m.boot.loader_conf.?).?;
    const driver = try std.fs.path.join(m.a, &.{ dir, images.refind_driver });
    if (!rootfs.pathExists(m.io, driver)) {
        if (try m.run(&.{ "install", "-D", "-m", "0644", m.refind_driver_src, driver })) |w| return w;
    }
    var why: []const u8 = "";
    // a device mapper root, as on luks, has no partition guid, and
    // every entry is on the esp then.
    const root_part = for (entries) |e| {
        if (e.esp_dir == null) break try gens.blkid(m.a, m.io, m.boot.root_device.?, "PARTUUID", &why) orelse return why;
    } else "";
    const text = try menu.refind(m.a, .{
        .esp_part = try gens.blkid(m.a, m.io, m.boot.esp_device.?, "PARTUUID", &why) orelse return why,
        .root_part = root_part,
        .entries = entries,
    });
    // a held default, or with a trial waiting, the generation a failed
    // trial falls back to, stays refind's own default.
    const file = if (try heldTitle(m.a, entries, held, try m.pendingFallback())) |title| try menu.refindDefault(m.a, text, title) else text;
    if (try write(m, try std.fs.path.join(m.a, &.{ dir, menu.refind_file }), file)) |w| return w;
    return write(m, m.boot.loader_conf.?, try menu.spliceRefind(m.a, conf));
}

/// whether the newest entry, for the root at `head`, boots the kernel
/// on the esp: when /boot is the esp and `head` is the root running.
/// a root not booted yet, like a staged one, keeps its own until a
/// good boot puts it on the esp, so the running kernel stays there.
fn headOnEsp(m: *const Machine, head: []const u8) bool {
    return m.bootOnEsp() and std.mem.eql(u8, head, m.boot.root_subvol orelse "") and !m.unsettled(head);
}

/// whether the menu's newest entry, for the root at `head`, boots
/// copies of its boot files on the esp, or an image of them, made as
/// the menu was written, rather than the files themselves: the
/// bootloader can't read the root, or it boots an image. a root whose
/// files aren't on the esp yet (see `unsettled`) counts as not, since
/// with /boot as the esp, pacman puts a new kernel on the esp, not in
/// that root's own /boot.
pub fn headCopied(m: *const Machine, head: []const u8) !bool {
    if (headOnEsp(m, head) and !try m.bootsImage(head)) return false;
    if (m.unsettled(head)) return false;
    return menu.copiesOnEsp(m.boot) or try m.bootsImage(head);
}

/// a menu entry for the root at `subvol`: its kernel, microcode, and
/// initramfs, from its own /boot, or the esp's for the newest.
pub fn entry(m: *const Machine, id: []const u8, name: []const u8, subvol: []const u8, cmdline: []const u8) !menu.Entry {
    var kernels: std.ArrayList([]const u8) = .empty;
    var initrds: std.ArrayList([]const u8) = .empty;
    const dir = if (std.mem.eql(u8, id, "head") and headOnEsp(m, subvol)) m.boot.esp.? else try m.at(&.{ subvol, "boot" });
    var boot = std.Io.Dir.cwd().openDir(m.io, dir, .{ .iterate = true }) catch null;
    if (boot) |*b| {
        defer b.close(m.io);
        var it = b.iterate();
        while (it.next(m.io) catch null) |f| {
            if (!generation.bootFile(f.name)) continue;
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

/// the title of the entry refind's own config defaults to, when it isn't
/// the newest: `entries[held]`, or with a trial waiting, the generation it
/// falls back to, `pending`. refind keeps its default in os's file.
fn heldTitle(a: Allocator, entries: []const menu.Entry, held: ?usize, pending: u32) !?[]const u8 {
    if (held) |i| return entries[i].title;
    if (pending == 0) return null;
    const e = lists.find(entries, "id", try menu.genId(a, pending)) orelse return null;
    return e.title;
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

/// a menu for generation 3, which goes on trial, and generation 2, the
/// one it falls back to, for the tests of a held default.
const held_entries = [_]menu.Entry{
    .{ .id = "head", .title = "yoq 3", .subvol = "/@roots/3", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw", .esp_dir = "yoq/boot" },
    .{ .id = "gen-2", .title = "yoq 2", .subvol = "/@roots/boot-2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw", .esp_dir = "yoq/boot" },
};

/// a machine whose esp, loader config, and bootctl are in `base`: the
/// stand-in bootctl notes its arguments in `base`/log, then `watch` as it
/// was when it ran.
fn heldMachine(a: Allocator, base: []const u8, loader: menu.Loader, conf: []const u8, watch: []const u8) !Machine {
    const script = try std.fmt.allocPrint(a, "echo \"$1 $2\" >> {s}/log; cat {s} >> {s}/log 2>/dev/null || echo missing >> {s}/log", .{ base, watch, base, base });
    return .{
        .a = a,
        .io = std.testing.io,
        .boot = .{ .esp = try std.fmt.allocPrint(a, "{s}/esp", .{base}), .loader = @tagName(loader), .loader_conf = conf, .root_subvol = "/@roots/2" },
        .loader = loader,
        .root_uuid = "r",
        .esp_uuid = "e",
        .bootctl = try a.dupe([]const u8, &.{ "sh", "-c", script, "bootctl" }),
    };
}

test "a generation going on trial leaves the default on the one before, for each bootloader" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "esp/grub");
    var entries = held_entries;

    // grub: grub.cfg's own default, which the trial's env file overrides
    // with a one-shot boot of the newest.
    const grub = try heldMachine(a, base, .grub, "", "");
    try std.testing.expectEqual(null, try writeGrub(&grub, &entries, 1));
    const cfg = try tmp.dir.readFileAlloc(io, "esp/grub/grub.cfg", a, .limited(1 << 16));
    try std.testing.expect(std.mem.indexOf(u8, cfg, "set default=\"gen-2\"\n") != null);
    try std.testing.expectEqual(null, try writeGrub(&grub, &entries, null));
    try std.testing.expect(std.mem.indexOf(u8, try tmp.dir.readFileAlloc(io, "esp/grub/grub.cfg", a, .limited(1 << 16)), "set default=\"head\"\n") != null);

    // limine: the efi variable names generation 2 before the section that
    // puts 3 first goes in; until then 2 is the first entry, by that name.
    const old_limine = "timeout: 3\n" ++ menu.limine_begin ++ "\n/yoq 2\n    protocol: linux\n" ++ menu.limine_end ++ "\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "limine.conf", .data = old_limine });
    const limine_conf = try std.fmt.allocPrint(a, "{s}/limine.conf", .{base});
    const limine = try heldMachine(a, base, .limine, limine_conf, limine_conf);
    try std.testing.expectEqual(null, try writeLimine(&limine, &entries, 1));
    try std.testing.expectEqualStrings("set-default yoq-2\n" ++ old_limine, try tmp.dir.readFileAlloc(io, "log", a, .limited(1 << 16)));
    try std.testing.expect(std.mem.indexOf(u8, try tmp.dir.readFileAlloc(io, "limine.conf", a, .limited(1 << 16)), "\n/yoq 3\n") != null);
    // without a held default, the variable is left alone.
    try tmp.dir.deleteFile(io, "log");
    try std.testing.expectEqual(null, try writeLimine(&limine, &entries, null));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "log", .{}));

    // systemd-boot: generation 2's file goes in, becomes the default, and
    // only then does yoq-head.conf, the default till then, name 3.
    try tmp.dir.createDirPath(io, "esp/loader/entries");
    try tmp.dir.writeFile(io, .{ .sub_path = "esp/loader/entries/yoq-head.conf", .data = "old head\n" });
    const sd_conf = try std.fmt.allocPrint(a, "{s}/esp/loader/loader.conf", .{base});
    const sd = try heldMachine(a, base, .@"systemd-boot", sd_conf, try std.fmt.allocPrint(a, "{s}/esp/loader/entries/yoq-head.conf {s}/esp/loader/entries/yoq-gen-2.conf", .{ base, base }));
    try std.testing.expectEqual(null, try writeSdboot(&sd, &entries, 1));
    const log = try tmp.dir.readFileAlloc(io, "log", a, .limited(1 << 16));
    try std.testing.expect(std.mem.startsWith(u8, log, "set-default yoq-gen-2.conf\nold head\n# written by os. edits here are overwritten.\ntitle yoq 2\n"));
    const head = try tmp.dir.readFileAlloc(io, "esp/loader/entries/yoq-head.conf", a, .limited(1 << 16));
    try std.testing.expect(std.mem.indexOf(u8, head, "title yoq 3\n") != null);
    _ = try tmp.dir.statFile(io, "esp/loader/entries/yoq-trial.conf", .{});

    // refind: os's file defaults to generation 2, held or with a trial
    // waiting that falls back to it.
    try std.testing.expectEqualStrings("yoq 2", (try heldTitle(a, &entries, 1, 0)).?);
    try std.testing.expectEqualStrings("yoq 2", (try heldTitle(a, &entries, null, 2)).?);
    try std.testing.expectEqual(null, try heldTitle(a, &entries, null, 0));
    try std.testing.expectEqual(null, try heldTitle(a, &entries, null, 7));
}

test "which menus boot copies of the running root's boot files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var m: Machine = .{
        .a = a,
        .io = io,
        .boot = .{ .loader = "limine", .esp = "/efi", .root_subvol = "/@roots/3" },
        .loader = .limine,
        .root_uuid = "r",
        .esp_uuid = "e",
        .top = try std.fmt.allocPrint(a, "{s}/top", .{base}),
        .unsettled_note = try std.fmt.allocPrint(a, "{s}/note", .{base}),
    };
    // limine reads only the esp.
    try std.testing.expect(try m.headCopied("/@roots/3"));
    // with /boot as the esp, the newest entry boots the esp's own files.
    m.boot.esp = "/boot";
    try std.testing.expect(!try m.headCopied("/@roots/3"));
    // grub reads the root, unless it's on luks.
    m.boot.loader = "grub";
    m.loader = .grub;
    m.boot.esp = "/efi";
    try std.testing.expect(!try m.headCopied("/@roots/3"));
    m.boot.luks_uuid = "u";
    try std.testing.expect(try m.headCopied("/@roots/3"));
    m.boot.luks_uuid = null;
    // an image is a copy, wherever the esp is.
    try tmp.dir.createDirPath(io, "top/@roots/3/etc/kernel");
    try tmp.dir.writeFile(io, .{ .sub_path = "top/@roots/3/" ++ uki.config_rel, .data = "" });
    try std.testing.expect(try m.headCopied("/@roots/3"));
    m.boot.esp = "/boot";
    try std.testing.expect(try m.headCopied("/@roots/3"));
    // unless the root's files aren't on the esp yet.
    try tmp.dir.writeFile(io, .{ .sub_path = "note", .data = "/@roots/3\n" });
    try std.testing.expect(!try m.headCopied("/@roots/3"));
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

test "a boot file named with more than letters, digits, and ._+- stays out of the menu" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "top/@roots/2/boot");
    for ([_][]const u8{ "vmlinuz-linux", "initramfs-linux.img", "amd-ucode.img", "x;set root=(hd9);-ucode.img", "vmlinuz-a{b}" }) |f| {
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "top/@roots/2/boot/{s}", .{f}), .data = "x" });
    }
    const m: Machine = .{
        .a = a,
        .io = io,
        .boot = .{ .loader = "grub", .root_subvol = "/@roots/1" },
        .loader = .grub,
        .root_uuid = "r",
        .esp_uuid = "e",
        .top = try std.fmt.allocPrint(a, "{s}/top", .{base}),
        .unsettled_note = try std.fmt.allocPrint(a, "{s}/note", .{base}),
    };
    const e = try m.entry("gen-2", "yoq 2", "/@roots/2", "");
    try std.testing.expectEqualStrings("vmlinuz-linux", e.kernel);
    try std.testing.expectEqual(2, e.initrds.len);
    try std.testing.expectEqualStrings("amd-ucode.img", e.initrds[0]);
    try std.testing.expectEqualStrings("initramfs-linux.img", e.initrds[1]);
}
