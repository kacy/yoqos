//! the boot menu's entries, and each bootloader's way of writing them.
//! this part is pure; gens.zig reads the machine and writes the files.

const std = @import("std");
const facts = @import("facts.zig");
const Allocator = std.mem.Allocator;

/// the bootloaders generations work with.
pub const Loader = enum {
    grub,
    limine,
    refind,
    @"systemd-boot",

    pub fn of(boot: facts.Boot) ?Loader {
        return std.meta.stringToEnum(Loader, boot.loader orelse return null);
    }
};

/// one boot menu entry: a kernel and its initrds, from a root subvolume.
pub const Entry = struct {
    id: []const u8,
    title: []const u8,
    /// the root subvolume, like "/@roots/1", or "/" for the top level.
    subvol: []const u8,
    kernel: []const u8,
    initrds: []const []const u8,
    args: []const u8,
    /// the directory on the esp its files are in, "" for the top, when
    /// they aren't in the root's own /boot: the newest entry's, when /boot
    /// is the esp, and every entry's for a bootloader that reads only fat.
    esp_dir: ?[]const u8 = null,

    /// where the root keeps its boot files, from the top of its filesystem.
    fn rootDir(e: Entry, a: Allocator) ![]const u8 {
        return if (std.mem.eql(u8, e.subvol, "/")) "/boot" else std.fmt.allocPrint(a, "{s}/boot", .{e.subvol});
    }

    /// `file`'s path from the top of the esp, for an entry with esp_dir.
    fn onEsp(e: Entry, a: Allocator, file: []const u8) ![]const u8 {
        const dir = e.esp_dir.?;
        return if (dir.len == 0) std.fmt.allocPrint(a, "/{s}", .{file}) else std.fmt.allocPrint(a, "/{s}/{s}", .{ dir, file });
    }
};

/// a title every bootloader can show and match: ascii, and without the
/// characters limine's entry paths and refind's quotes treat specially.
/// "yoq 2 · 2026-09-26 · add fd" becomes "yoq 2 - 2026-09-26 - add fd".
pub fn plainTitle(a: Allocator, title: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < title.len) : (i += 1) {
        const ch = title[i];
        if (ch >= 0x80) {
            // one dash for each character, not each byte.
            while (i + 1 < title.len and title[i + 1] & 0xc0 == 0x80) i += 1;
            try out.append(a, '-');
        } else if (ch < 0x20 or ch == 0x7f or std.mem.indexOfScalar(u8, "/\\#\"", ch) != null) {
            try out.append(a, '-');
        } else try out.append(a, ch);
    }
    return out.items;
}

pub const Grub = struct {
    esp_uuid: []const u8,
    root_uuid: []const u8,
    default: []const u8,
    timeout: u32 = 3,
    entries: []const Entry,
};

/// the whole grub.cfg os keeps on the esp. choices come from an env file
/// there, since grub can write fat but not btrfs: `yoq_next` boots an
/// entry once, and `yoq_default`, set while a generation is on trial, is
/// both the default and what grub falls back to if an entry won't boot.
pub fn grub(a: Allocator, c: Grub) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    w.print(
        \\# written by os: one entry per generation. edits here are overwritten.
        \\insmod part_gpt
        \\insmod fat
        \\insmod btrfs
        \\set timeout={d}
        \\set default="{s}"
        \\search --no-floppy --fs-uuid --set=yoq_esp {s}
        \\if [ -f (${{yoq_esp}})/yoq/grubenv ]; then
        \\  load_env -f (${{yoq_esp}})/yoq/grubenv yoq_next yoq_default
        \\  if [ "${{yoq_default}}" ]; then
        \\    set default="${{yoq_default}}"
        \\    set fallback="${{yoq_default}}"
        \\  fi
        \\  if [ "${{yoq_next}}" ]; then
        \\    if [ "${{yoq_default}}" ]; then set yoq_trial_arg="yoq.trial"; fi
        \\    set default="${{yoq_next}}"
        \\    set yoq_next=
        \\    save_env -f (${{yoq_esp}})/yoq/grubenv yoq_next
        \\  fi
        \\fi
        \\search --no-floppy --fs-uuid --set=root {s}
        \\
    , .{ c.timeout, c.default, c.esp_uuid, c.root_uuid }) catch return error.OutOfMemory;
    for (c.entries) |e| {
        const dir = if (e.esp_dir) |d| (if (d.len == 0) "(${yoq_esp})" else try std.fmt.allocPrint(a, "(${{yoq_esp}})/{s}", .{d})) else try e.rootDir(a);
        // ${yoq_trial_arg} is "yoq.trial" on a trial boot, which starts
        // the watchdog; empty otherwise. the newest entry notes that it
        // was tried, so a fallback after it counts, and an older entry
        // picked by hand doesn't.
        w.writeAll("\nmenuentry \"") catch return error.OutOfMemory;
        // a title is a quoted grub string: quotes, backslashes, and $ would
        // end it or expand.
        for (e.title) |ch| {
            if (ch == '"' or ch == '\\' or ch == '$') w.writeByte('\\') catch return error.OutOfMemory;
            w.writeByte(ch) catch return error.OutOfMemory;
        }
        w.print("\" --id {s} {{\n", .{e.id}) catch return error.OutOfMemory;
        if (std.mem.eql(u8, e.id, "head")) w.writeAll("  if [ \"${yoq_trial_arg}\" ]; then set yoq_tried=1; save_env -f (${yoq_esp})/yoq/grubenv yoq_tried; fi\n") catch return error.OutOfMemory;
        w.print("  linux {s}/{s} {s} ${{yoq_trial_arg}}\n  initrd", .{ dir, e.kernel, e.args }) catch return error.OutOfMemory;
        for (e.initrds) |i| w.print(" {s}/{s}", .{ dir, i }) catch return error.OutOfMemory;
        w.writeAll("\n}\n") catch return error.OutOfMemory;
    }
    return out.written();
}

/// the identifier limine gives an entry at the top of its menu, which
/// its efi variables can name: the title, with every character systemd
/// won't take in a boot entry's name made a dash.
pub fn limineId(a: Allocator, title: []const u8) ![]const u8 {
    const plain = try plainTitle(a, title);
    for (plain) |*ch| {
        if (!std.ascii.isAlphanumeric(ch.*) and std.mem.indexOfScalar(u8, "+_.@-", ch.*) == null) ch.* = '-';
    }
    // limine cuts identifiers there, leaving room for a suffix.
    return plain[0..@min(plain.len, 232)];
}

/// the lines around os's part of limine.conf.
pub const limine_begin = "# yoq: generations, written by os. edits from here to the end line are overwritten.";
pub const limine_end = "# yoq: end";
/// the entry a trial boots: the newest generation, with the watchdog on.
pub const limine_trial = "yoq trial boot";

/// os's part of limine.conf: an entry per generation, newest first, then
/// the one a trial boots. limine reads only fat, so every entry's files
/// are on the esp, and its path names the partition holding the config.
pub fn limine(a: Allocator, entries: []const Entry) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    w.print("{s}\n", .{limine_begin}) catch return error.OutOfMemory;
    for (entries) |e| try limineEntry(a, w, try plainTitle(a, e.title), e, e.args);
    if (entries.len > 0) try limineEntry(a, w, limine_trial, entries[0], try std.fmt.allocPrint(a, "{s} yoq.trial", .{entries[0].args}));
    w.print("{s}\n", .{limine_end}) catch return error.OutOfMemory;
    return out.written();
}

/// one entry, titled `title`, outside os's section: what `os uninstall`
/// leaves limine.
pub fn limineOne(a: Allocator, title: []const u8, e: Entry) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try limineEntry(a, &out.writer, title, e, e.args);
    return out.written();
}

fn limineEntry(a: Allocator, w: *std.Io.Writer, title: []const u8, e: Entry, args: []const u8) !void {
    w.print("/{s}\n    protocol: linux\n    path: boot():{s}\n", .{ title, try e.onEsp(a, e.kernel) }) catch return error.OutOfMemory;
    for (e.initrds) |i| w.print("    module_path: boot():{s}\n", .{try e.onEsp(a, i)}) catch return error.OutOfMemory;
    w.print("    cmdline: {s}\n", .{args}) catch return error.OutOfMemory;
}

/// limine.conf with `section` in place of os's old one, before the first
/// entry, so the newest generation is entry 1 and limine's default.
/// default_entry and remember_last_entry go, since either would outrank
/// the LoaderEntryDefault variable a trial sets.
pub fn spliceLimine(a: Allocator, conf: []const u8, section: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var placed = false;
    var in_section = false;
    // the blank line os puts after its section goes with it.
    var after_section = false;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, conf, "\n"), '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (in_section) {
            in_section = !std.mem.eql(u8, t, limine_end);
            after_section = !in_section;
            continue;
        }
        if (after_section) {
            after_section = false;
            if (t.len == 0) continue;
        }
        if (std.mem.eql(u8, t, limine_begin)) {
            in_section = true;
            continue;
        }
        if (std.mem.startsWith(u8, t, "default_entry:") or std.mem.startsWith(u8, t, "remember_last_entry:")) continue;
        if (!placed and std.mem.startsWith(u8, t, "/")) {
            try out.appendSlice(a, section);
            try out.append(a, '\n');
            placed = true;
        }
        try out.print(a, "{s}\n", .{line});
    }
    if (!placed) {
        if (out.items.len > 0) try out.append(a, '\n');
        try out.appendSlice(a, section);
    }
    return out.items;
}

/// a file os writes whole: a name and its content.
pub const Named = struct { name: []const u8, text: []const u8 };

/// systemd-boot's entry for os's entry `id`, like "yoq-head.conf".
pub fn sdbootName(a: Allocator, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "yoq-{s}.conf", .{id});
}

/// the entry a trial boots on systemd-boot.
pub const sdboot_trial = "yoq-trial.conf";

/// os's entry files for systemd-boot, in loader/entries on the esp: one
/// per generation, and the one a trial boots. versions put the newest
/// first. like limine, systemd-boot reads only fat, so every entry's files
/// are on the esp.
pub fn sdboot(a: Allocator, entries: []const Entry) ![]const Named {
    var out: std.ArrayList(Named) = .empty;
    for (entries, 0..) |e, i| {
        try out.append(a, .{ .name = try sdbootName(a, e.id), .text = try sdbootEntry(a, e.title, "yoq", entries.len - i, e, e.args) });
    }
    if (entries.len > 0) {
        const head = entries[0];
        try out.append(a, .{ .name = sdboot_trial, .text = try sdbootEntry(a, "yoq trial boot", "yoq-trial", entries.len, head, try std.fmt.allocPrint(a, "{s} yoq.trial", .{head.args})) });
    }
    return out.items;
}

/// one entry file, for `os uninstall` too, which leaves one of its own.
pub fn sdbootEntry(a: Allocator, title: []const u8, sort_key: []const u8, version: usize, e: Entry, args: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "# written by os. edits here are overwritten.\ntitle {s}\nsort-key {s}\nversion {d}\nlinux {s}\n", .{ try plainTitle(a, title), sort_key, version, try e.onEsp(a, e.kernel) });
    for (e.initrds) |i| try out.print(a, "initrd {s}\n", .{try e.onEsp(a, i)});
    try out.print(a, "options {s}\n", .{args});
    return out.items;
}

pub const Refind = struct {
    /// partition guids: the esp's, and the root's.
    esp_part: []const u8,
    root_part: []const u8,
    entries: []const Entry,
};

/// the file refind.conf includes, next to it: an entry per generation,
/// newest first and the default. refind reads btrfs through its driver,
/// from the top level, so older roots keep their kernels.
pub fn refind(a: Allocator, c: Refind) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    w.writeAll("# written by os: one entry per generation. edits here are overwritten.\n") catch return error.OutOfMemory;
    for (c.entries) |e| {
        const volume = if (e.esp_dir != null) c.esp_part else c.root_part;
        const kernel = if (e.esp_dir != null) try e.onEsp(a, e.kernel) else try std.fmt.allocPrint(a, "{s}/{s}", .{ try e.rootDir(a), e.kernel });
        w.print("\nmenuentry \"{s}\" {{\n    volume {s}\n    loader {s}\n    options \"{s}", .{ try plainTitle(a, e.title), volume, kernel, e.args }) catch return error.OutOfMemory;
        // the kernel loads its initrds itself, from its own volume; refind's
        // initrd line takes only one.
        for (e.initrds) |i| {
            const path = if (e.esp_dir != null) try e.onEsp(a, i) else try std.fmt.allocPrint(a, "{s}/{s}", .{ try e.rootDir(a), i });
            const back = try a.dupe(u8, path);
            std.mem.replaceScalar(u8, back, '/', '\\');
            w.print(" initrd={s}", .{back}) catch return error.OutOfMemory;
        }
        w.writeAll("\"\n}\n") catch return error.OutOfMemory;
    }
    if (c.entries.len > 0) w.print("\ndefault_selection \"{s}\"\n", .{try plainTitle(a, c.entries[0].title)}) catch return error.OutOfMemory;
    return out.written();
}

/// the line in refind.conf that reads os's file.
pub const refind_include = "include yoq.conf";

/// refind.conf with os's include as its last line, so the default os
/// sets outranks any earlier one.
pub fn spliceRefind(a: Allocator, conf: []const u8) ![]const u8 {
    const out = try unspliceRefind(a, conf);
    return std.fmt.allocPrint(a, "{s}{s}\n", .{ out, refind_include });
}

/// refind.conf without os's include.
pub fn unspliceRefind(a: Allocator, conf: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, conf, "\n"), '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), refind_include)) continue;
        try out.print(a, "{s}\n", .{line});
    }
    return out.items;
}

/// the refind_linux.conf beside the kernel of an entry on the esp's top,
/// which refind reads when it finds that kernel itself: a title, and the
/// kernel's arguments with its initrds.
pub fn refindLinux(a: Allocator, e: Entry) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "\"Arch Linux\" \"{s}", .{e.args});
    for (e.initrds) |i| try out.print(a, " initrd=\\{s}", .{i});
    try out.appendSlice(a, "\"\n");
    return out.items;
}

// -- tests --

const testing = std.testing;

test "grub's config on the esp" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = try grub(arena.allocator(), .{
        .esp_uuid = "41B2-0FB5",
        .root_uuid = "1df77bf6",
        .default = "gen-1",
        .entries = &.{
            .{ .id = "gen-1", .title = "yoq 1 · 2026-09-26 · enable-rollback", .subvol = "/@roots/1", .kernel = "vmlinuz-linux", .initrds = &.{ "amd-ucode.img", "initramfs-linux.img" }, .args = "root=UUID=1df77bf6 rootflags=subvol=/@roots/1 rw" },
            .{ .id = "before", .title = "the system before generations", .subvol = "/", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "root=UUID=1df77bf6 rootflags=subvol=/ rw" },
        },
    });
    const on_esp = try grub(arena.allocator(), .{
        .esp_uuid = "41B2-0FB5",
        .root_uuid = "1df77bf6",
        .default = "head",
        .entries = &.{
            .{ .id = "head", .title = "yoq 2", .subvol = "/@roots/1", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "rw", .esp_dir = "" },
        },
    });
    try testing.expect(std.mem.endsWith(u8, on_esp, "  linux (${yoq_esp})/vmlinuz-linux rw ${yoq_trial_arg}\n  initrd (${yoq_esp})/initramfs-linux.img\n}\n"));
    try testing.expect(std.mem.indexOf(u8, text, "set default=\"gen-1\"\nsearch --no-floppy --fs-uuid --set=yoq_esp 41B2-0FB5\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "load_env -f (${yoq_esp})/yoq/grubenv yoq_next yoq_default\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "set fallback=\"${yoq_default}\"") != null);
    try testing.expect(std.mem.endsWith(u8, text,
        \\search --no-floppy --fs-uuid --set=root 1df77bf6
        \\
        \\menuentry "yoq 1 · 2026-09-26 · enable-rollback" --id gen-1 {
        \\  linux /@roots/1/boot/vmlinuz-linux root=UUID=1df77bf6 rootflags=subvol=/@roots/1 rw ${yoq_trial_arg}
        \\  initrd /@roots/1/boot/amd-ucode.img /@roots/1/boot/initramfs-linux.img
        \\}
        \\
        \\menuentry "the system before generations" --id before {
        \\  linux /boot/vmlinuz-linux root=UUID=1df77bf6 rootflags=subvol=/ rw ${yoq_trial_arg}
        \\  initrd /boot/initramfs-linux.img
        \\}
        \\
    ));
}

test "a menu title can't end its quotes or expand" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = try grub(arena.allocator(), .{
        .esp_uuid = "e",
        .root_uuid = "r",
        .default = "head",
        .entries = &.{.{ .id = "gen-2", .title = "add \"x\" $y", .subvol = "/@roots/2", .kernel = "vmlinuz-linux", .initrds = &.{}, .args = "rw" }},
    });
    try testing.expect(std.mem.indexOf(u8, text, "menuentry \"add \\\"x\\\" \\$y\" --id gen-2 {") != null);
}

test "titles every bootloader can take" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("yoq-2---2026-09-26---add-fd", try limineId(arena.allocator(), "yoq 2 · 2026-09-26 · add fd"));
    try testing.expectEqualStrings("yoq-trial-boot", try limineId(arena.allocator(), limine_trial));
    try testing.expectEqualStrings("yoq 2 - 2026-09-26 - add fd", try plainTitle(arena.allocator(), "yoq 2 · 2026-09-26 · add fd"));
    try testing.expectEqualStrings("a-b-c-d-e", try plainTitle(arena.allocator(), "a/b\\c#d\"e"));
}

const test_entries = [_]Entry{
    .{ .id = "head", .title = "yoq 2 · add fd", .subvol = "/@roots/1", .kernel = "vmlinuz-linux", .initrds = &.{ "amd-ucode.img", "initramfs-linux.img" }, .args = "root=UUID=r rw", .esp_dir = "" },
    .{ .id = "gen-1", .title = "yoq 1 · enable-rollback", .subvol = "/@roots/boot-1", .kernel = "ab12-vmlinuz-linux", .initrds = &.{"cd34-initramfs-linux.img"}, .args = "root=UUID=r rootflags=subvol=/@roots/boot-1 rw", .esp_dir = "yoq/boot" },
};

test "limine's entries, and where they go in its config" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const section = try limine(a, &test_entries);
    try testing.expectEqualStrings(limine_begin ++
        \\
        \\/yoq 2 - add fd
        \\    protocol: linux
        \\    path: boot():/vmlinuz-linux
        \\    module_path: boot():/amd-ucode.img
        \\    module_path: boot():/initramfs-linux.img
        \\    cmdline: root=UUID=r rw
        \\/yoq 1 - enable-rollback
        \\    protocol: linux
        \\    path: boot():/yoq/boot/ab12-vmlinuz-linux
        \\    module_path: boot():/yoq/boot/cd34-initramfs-linux.img
        \\    cmdline: root=UUID=r rootflags=subvol=/@roots/boot-1 rw
        \\/yoq trial boot
        \\    protocol: linux
        \\    path: boot():/vmlinuz-linux
        \\    module_path: boot():/amd-ucode.img
        \\    module_path: boot():/initramfs-linux.img
        \\    cmdline: root=UUID=r rw yoq.trial
        \\
    ++ limine_end ++ "\n", section);
    const conf =
        \\timeout: 5
        \\default_entry: 2
        \\
        \\/Arch Linux (linux)
        \\    protocol: linux
        \\
    ;
    const once = try spliceLimine(a, conf, "S\n");
    try testing.expectEqualStrings("timeout: 5\n\nS\n\n/Arch Linux (linux)\n    protocol: linux\n", once);
    // a second write replaces the section rather than adding another.
    const section2 = limine_begin ++ "\nnew\n" ++ limine_end ++ "\n";
    const twice = try spliceLimine(a, try spliceLimine(a, conf, section2), section2);
    try testing.expectEqualStrings("timeout: 5\n\n" ++ section2 ++ "\n/Arch Linux (linux)\n    protocol: linux\n", twice);
    // a config with no entries gets the section at the end.
    try testing.expectEqualStrings("timeout: 5\n\nS\n", try spliceLimine(a, "timeout: 5\nremember_last_entry: yes\n", "S\n"));
}

test "systemd-boot's entry files" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const files = try sdboot(arena.allocator(), &test_entries);
    try testing.expectEqual(3, files.len);
    try testing.expectEqualStrings("yoq-head.conf", files[0].name);
    try testing.expectEqualStrings("yoq-gen-1.conf", files[1].name);
    try testing.expectEqualStrings(sdboot_trial, files[2].name);
    try testing.expectEqualStrings(
        \\# written by os. edits here are overwritten.
        \\title yoq 1 - enable-rollback
        \\sort-key yoq
        \\version 1
        \\linux /yoq/boot/ab12-vmlinuz-linux
        \\initrd /yoq/boot/cd34-initramfs-linux.img
        \\options root=UUID=r rootflags=subvol=/@roots/boot-1 rw
        \\
    , files[1].text);
    try testing.expect(std.mem.indexOf(u8, files[2].text, "sort-key yoq-trial\n") != null);
    try testing.expect(std.mem.endsWith(u8, files[2].text, "options root=UUID=r rw yoq.trial\n"));
}

test "refind's entries, and its include" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const older: Entry = .{ .id = "gen-1", .title = "yoq 1 · enable-rollback", .subvol = "/@roots/boot-1", .kernel = "vmlinuz-linux", .initrds = &.{ "amd-ucode.img", "initramfs-linux.img" }, .args = "rw" };
    try testing.expectEqualStrings(
        \\# written by os: one entry per generation. edits here are overwritten.
        \\
        \\menuentry "yoq 2 - add fd" {
        \\    volume esp-guid
        \\    loader /vmlinuz-linux
        \\    options "root=UUID=r rw initrd=\amd-ucode.img initrd=\initramfs-linux.img"
        \\}
        \\
        \\menuentry "yoq 1 - enable-rollback" {
        \\    volume root-guid
        \\    loader /@roots/boot-1/boot/vmlinuz-linux
        \\    options "rw initrd=\@roots\boot-1\boot\amd-ucode.img initrd=\@roots\boot-1\boot\initramfs-linux.img"
        \\}
        \\
        \\default_selection "yoq 2 - add fd"
        \\
    , try refind(a, .{ .esp_part = "esp-guid", .root_part = "root-guid", .entries = &.{ test_entries[0], older } }));
    try testing.expectEqualStrings("\"Arch Linux\" \"root=UUID=r rw initrd=\\amd-ucode.img initrd=\\initramfs-linux.img\"\n", try refindLinux(a, test_entries[0]));
    try testing.expectEqualStrings("timeout 20\n", try unspliceRefind(a, "timeout 20\ninclude yoq.conf\n"));
    const conf = "timeout 20\ninclude yoq.conf\ndefault_selection 1\n";
    try testing.expectEqualStrings("timeout 20\ndefault_selection 1\ninclude yoq.conf\n", try spliceRefind(a, conf));
}
