//! the boot menu's entries, and each bootloader's way of writing them.
//! this part is pure; bootmenu.zig reads the machine and writes the files.

const std = @import("std");
const facts = @import("facts.zig");
const generation = @import("generation.zig");
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

/// whether every entry boots copies of its files on the esp, since the
/// bootloader can't read the roots: limine and systemd-boot read only
/// fat, and nothing reads btrfs inside luks before the initramfs unlocks
/// it.
pub fn copiesOnEsp(boot: facts.Boot) bool {
    const loader = Loader.of(boot) orelse return false;
    return loader == .limine or loader == .@"systemd-boot" or boot.luks_uuid != null;
}

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
    /// a unified kernel image in esp_dir, which the entry starts with its
    /// args instead of the kernel and initrds, which are in the image.
    uki: ?[]const u8 = null,
    /// the image has args in it, as with secure boot, so the entry passes
    /// no command line: the stub would ignore it.
    embedded: bool = false,
    /// with `embedded`, the image the trial entry starts: one with the
    /// trial's command line in it (see trialArgs).
    trial_uki: ?[]const u8 = null,

    /// where the root keeps its boot files, from the top of its filesystem.
    fn rootDir(e: Entry, a: Allocator) ![]const u8 {
        return if (std.mem.eql(u8, e.subvol, "/")) "/boot" else std.fmt.allocPrint(a, "{s}/boot", .{e.subvol});
    }

    /// the file the bootloader starts: the image, or the kernel.
    fn loaded(e: Entry) []const u8 {
        return e.uki orelse e.kernel;
    }

    /// the initrds the bootloader loads beside the kernel: none for an
    /// image, which has them inside.
    fn looseInitrds(e: Entry) []const []const u8 {
        return if (e.uki == null) e.initrds else &.{};
    }

    /// `file`'s path from the top of the esp, or of the root's filesystem
    /// for an entry without esp_dir.
    fn path(e: Entry, a: Allocator, file: []const u8) ![]u8 {
        const dir = e.esp_dir orelse return std.fmt.allocPrint(a, "{s}/{s}", .{ try e.rootDir(a), file });
        return if (dir.len == 0) std.fmt.allocPrint(a, "/{s}", .{file}) else std.fmt.allocPrint(a, "/{s}/{s}", .{ dir, file });
    }
};

/// the id of generation `n`'s entry, like "gen-2".
pub fn genId(a: Allocator, n: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "gen-{d}", .{n});
}

/// the title of the entry a trial boots, on limine, refind, and
/// systemd-boot.
pub const trial_title = "yoq trial boot";

/// the command line a trial boots with: an entry's, and the argument that
/// starts the watchdog.
pub fn trialArgs(a: Allocator, args: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s} yoq.trial", .{args});
}

/// the entry a trial boots: the newest generation, with the watchdog on.
/// an image with its command line in it has a twin for this, with the
/// trial's.
fn trialEntry(a: Allocator, entries: []const Entry) !?Entry {
    if (entries.len == 0) return null;
    var t = entries[0];
    t.title = trial_title;
    t.args = try trialArgs(a, t.args);
    if (t.trial_uki) |u| t.uki = u;
    t.trial_uki = null;
    return t;
}

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
    /// the root's filesystem, which entries without esp_dir read from.
    root_uuid: []const u8,
    default: []const u8,
    timeout: u32 = 3,
    entries: []const Entry,
};

/// the whole grub.cfg os keeps on the esp. choices come from an env file
/// there, since grub can write fat but not btrfs: `yoq_next` boots an
/// entry once, and `yoq_default`, set while a generation is on trial, is
/// both the default and what grub falls back to if an entry won't boot.
/// `yoq_trial_arg` is "yoq.trial" on a trial boot, which starts the
/// watchdog, and empty otherwise.
pub fn grub(a: Allocator, c: Grub) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a,
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
        \\
    , .{ c.timeout, c.default, c.esp_uuid });
    // with every entry's files on the esp, as on a luks root, grub never
    // looks for the root's filesystem; it couldn't find it there anyway.
    for (c.entries) |e| {
        if (e.esp_dir == null) {
            try out.print(a, "search --no-floppy --fs-uuid --set=root {s}\n", .{c.root_uuid});
            break;
        }
    }
    for (c.entries) |e| {
        const dir = if (e.esp_dir) |d| (if (d.len == 0) "(${yoq_esp})" else try std.fmt.allocPrint(a, "(${{yoq_esp}})/{s}", .{d})) else try e.rootDir(a);
        // a title is a quoted grub string: quotes, backslashes, and $ would
        // end it or expand.
        try out.appendSlice(a, "\nmenuentry \"");
        for (e.title) |ch| {
            if (ch == '"' or ch == '\\' or ch == '$') try out.append(a, '\\');
            try out.append(a, ch);
        }
        try out.print(a, "\" --id {s} {{\n", .{e.id});
        // the newest entry notes that it was tried, so a fallback after it
        // counts, and an older entry picked by hand doesn't.
        if (std.mem.eql(u8, e.id, "head")) try out.appendSlice(a, "  if [ \"${yoq_trial_arg}\" ]; then set yoq_tried=1; save_env -f (${yoq_esp})/yoq/grubenv yoq_tried; fi\n");
        if (e.uki == null) {
            try out.print(a, "  linux {s}/{s} {s} ${{yoq_trial_arg}}\n", .{ dir, e.kernel, e.args });
        } else if (e.embedded) {
            // the image ignores what grub passes, so a trial starts the
            // image with the trial's command line in it instead.
            try out.appendSlice(a, "  insmod chain\n");
            if (e.trial_uki) |t| {
                try out.print(a, "  if [ \"${{yoq_trial_arg}}\" ]; then\n    chainloader {s}/{s}\n  else\n    chainloader {s}/{s}\n  fi\n", .{ dir, t, dir, e.uki.? });
            } else try out.print(a, "  chainloader {s}/{s}\n", .{ dir, e.uki.? });
        } else {
            // grub's chainloader passes what follows the file to it as its
            // load options, which the image's stub makes the command line.
            // it joins the words as grub read them, so a word with quotes
            // in it goes in single quotes, which keep it as it is. `linux`
            // puts quotes back by itself.
            try out.print(a, "  insmod chain\n  chainloader {s}/{s}", .{ dir, e.uki.? });
            var words: generation.Words = .{ .text = e.args };
            while (words.next()) |w| try grubWord(a, &out, w);
            try out.appendSlice(a, " ${yoq_trial_arg}\n");
        }
        if (e.uki == null) {
            try out.appendSlice(a, "  initrd");
            for (e.initrds) |i| try out.print(a, " {s}/{s}", .{ dir, i });
            try out.append(a, '\n');
        }
        try out.appendSlice(a, "}\n");
    }
    return out.items;
}

/// a space, then `word` as grub reads it back: as it is, or in single
/// quotes when grub would change it, with each quote in it closed,
/// escaped, and opened again.
fn grubWord(a: Allocator, out: *std.ArrayList(u8), word: []const u8) !void {
    try out.append(a, ' ');
    if (std.mem.indexOfAny(u8, word, "\"'\\$;|&<>{} \t") == null) return out.appendSlice(a, word);
    try out.append(a, '\'');
    for (word) |ch| {
        if (ch == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, ch);
    }
    try out.append(a, '\'');
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

/// os's part of limine.conf: an entry per generation, newest first, then
/// the one a trial boots. limine reads only fat, so every entry's files
/// are on the esp, and its path names the partition holding the config.
pub fn limine(a: Allocator, entries: []const Entry) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{s}\n", .{limine_begin});
    for (entries) |e| try limineEntry(a, &out, e);
    if (try trialEntry(a, entries)) |t| try limineEntry(a, &out, t);
    try out.print(a, "{s}\n", .{limine_end});
    return out.items;
}

/// one entry outside os's section: what `os uninstall` leaves limine.
pub fn limineOne(a: Allocator, e: Entry) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try limineEntry(a, &out, e);
    return out.items;
}

fn limineEntry(a: Allocator, out: *std.ArrayList(u8), e: Entry) !void {
    const protocol = if (e.uki == null) "linux" else "efi";
    try out.print(a, "/{s}\n    protocol: {s}\n    path: boot():{s}\n", .{ try plainTitle(a, e.title), protocol, try e.path(a, e.loaded()) });
    for (e.looseInitrds()) |i| try out.print(a, "    module_path: boot():{s}\n", .{try e.path(a, i)});
    if (!e.embedded) try out.print(a, "    cmdline: {s}\n", .{e.args});
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
        try out.append(a, .{ .name = try sdbootName(a, e.id), .text = try sdbootEntry(a, e, "yoq", entries.len - i) });
    }
    if (try trialEntry(a, entries)) |t| {
        try out.append(a, .{ .name = sdboot_trial, .text = try sdbootEntry(a, t, "yoq-trial", entries.len) });
    }
    return out.items;
}

/// one entry file, for `os uninstall` too, which leaves one of its own.
pub fn sdbootEntry(a: Allocator, e: Entry, sort_key: []const u8, version: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "# written by os. edits here are overwritten.\ntitle {s}\nsort-key {s}\nversion {d}\n", .{ try plainTitle(a, e.title), sort_key, version });
    try out.print(a, "{s} {s}\n", .{ if (e.uki == null) "linux" else "efi", try e.path(a, e.loaded()) });
    for (e.looseInitrds()) |i| try out.print(a, "initrd {s}\n", .{try e.path(a, i)});
    if (!e.embedded) try out.print(a, "options {s}\n", .{e.args});
    return out.items;
}

pub const Refind = struct {
    /// partition guids: the esp's, and the root's, which only entries
    /// without esp_dir use.
    esp_part: []const u8,
    root_part: []const u8,
    entries: []const Entry,
};

/// the file refind.conf includes, next to it: an entry per generation,
/// newest first and the default, then the one a trial boots. refind reads
/// btrfs through its driver, from the top level, so older roots keep their
/// kernels.
pub fn refind(a: Allocator, c: Refind) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "# written by os: one entry per generation. edits here are overwritten.\n");
    const all = if (try trialEntry(a, c.entries)) |t| try std.mem.concat(a, Entry, &.{ c.entries, &.{t} }) else c.entries;
    for (all) |e| {
        const volume = if (e.esp_dir != null) c.esp_part else c.root_part;
        try out.print(a, "\nmenuentry \"{s}\" {{\n    volume {s}\n    loader {s}\n", .{ try plainTitle(a, e.title), volume, try e.path(a, e.loaded()) });
        if (!e.embedded) {
            try out.print(a, "    options \"{s}", .{e.args});
            // the kernel loads its initrds itself, from its own volume;
            // refind's initrd line takes only one.
            for (e.looseInitrds()) |i| {
                const back = try e.path(a, i);
                std.mem.replaceScalar(u8, back, '/', '\\');
                try out.print(a, " initrd={s}", .{back});
            }
            try out.appendSlice(a, "\"\n");
        }
        try out.appendSlice(a, "}\n");
    }
    if (c.entries.len > 0) try out.print(a, "\ndefault_selection \"{s}\"\n", .{try plainTitle(a, c.entries[0].title)});
    return out.items;
}

/// why refind can't boot with `args`, or null if it can. refind reads the
/// options as one quoted string, and a quote in them would end it early.
pub fn refindArgsProblem(a: Allocator, args: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, args, '"') == null) return null;
    return try std.fmt.allocPrint(a, "refind can't take kernel arguments with a double quote in them: {s}", .{args});
}

/// os's refind file, beside refind.conf, and the line there that reads it.
pub const refind_file = "yoq.conf";
pub const refind_include = "include " ++ refind_file;

/// the directory under EFI/ on the esp where a copy of refind boots the
/// trial entry by default.
pub const refind_trial_dir = "yoq-trial";

/// os's refind file, from `text`, with `title` as the default.
pub fn refindDefault(a: Allocator, text: []const u8, title: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "default_selection ")) {
            try out.print(a, "default_selection \"{s}\"\n", .{try plainTitle(a, title)});
        } else try out.print(a, "{s}\n", .{line});
    }
    return out.items;
}

/// the newest generation's title in os's refind file: its first entry.
pub fn refindHead(text: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, "menuentry \"") orelse return null;
    const rest = text[start + "menuentry \"".len ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse return null];
}

/// the refind.conf a trial's copy of refind reads: refind.conf and os's
/// entries in one file, with the trial entry as the default.
pub fn refindTrialConf(a: Allocator, conf: []const u8, yoq: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}\n{s}", .{ try unspliceRefind(a, conf), try refindDefault(a, yoq, trial_title) });
}

/// refind.conf with os's include as its last line, so the default os
/// sets outranks any earlier one.
pub fn spliceRefind(a: Allocator, conf: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}{s}\n", .{ try unspliceRefind(a, conf), refind_include });
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

test "which bootloaders boot copies on the esp" {
    try testing.expect(!copiesOnEsp(.{ .loader = "grub" }));
    try testing.expect(!copiesOnEsp(.{ .loader = "refind" }));
    try testing.expect(copiesOnEsp(.{ .loader = "limine" }));
    try testing.expect(copiesOnEsp(.{ .loader = "systemd-boot" }));
    try testing.expect(copiesOnEsp(.{ .loader = "grub", .luks_uuid = "u" }));
    try testing.expect(copiesOnEsp(.{ .loader = "refind", .luks_uuid = "u" }));
    try testing.expect(!copiesOnEsp(.{ .luks_uuid = "u" }));
}

/// entries on a luks root: every one's files on the esp, and the
/// arguments that unlock the root in each.
const luks_args = "root=UUID=b rootflags=subvol=/@roots/1 rw rd.luks.name=0f7a1c2e-9b3d-4e5f-8a6b-7c8d9e0f1a2b=root rd.luks.options=tpm2-device=auto panic=10";
const luks_entries = [_]Entry{
    .{ .id = "head", .title = "yoq 2", .subvol = "/@roots/1", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = luks_args, .esp_dir = "" },
    .{ .id = "gen-1", .title = "yoq 1", .subvol = "/@roots/boot-1", .kernel = "ab12-vmlinuz-linux", .initrds = &.{"cd34-initramfs-linux.img"}, .args = luks_args, .esp_dir = "yoq/boot" },
};

test "entries on a luks root, for each bootloader" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try grub(a, .{ .esp_uuid = "41B2-0FB5", .root_uuid = "b", .default = "head", .entries = &luks_entries });
    // grub can't read the root, so it never looks for it.
    try testing.expect(std.mem.indexOf(u8, g, "--set=root") == null);
    try testing.expect(std.mem.indexOf(u8, g, "  linux (${yoq_esp})/yoq/boot/ab12-vmlinuz-linux " ++ luks_args ++ " ${yoq_trial_arg}\n  initrd (${yoq_esp})/yoq/boot/cd34-initramfs-linux.img\n") != null);
    try testing.expect(std.mem.indexOf(u8, g, "  linux (${yoq_esp})/vmlinuz-linux " ++ luks_args ++ " ${yoq_trial_arg}\n") != null);
    const l = try limine(a, &luks_entries);
    try testing.expectEqual(3, std.mem.count(u8, l, "    cmdline: " ++ luks_args));
    try testing.expect(std.mem.indexOf(u8, l, "    cmdline: " ++ luks_args ++ " yoq.trial\n") != null);
    const sd = try sdboot(a, &luks_entries);
    for (sd) |f| try testing.expect(std.mem.indexOf(u8, f.text, "options " ++ luks_args) != null);
    try testing.expectEqualStrings("# written by os. edits here are overwritten.\ntitle yoq 1\nsort-key yoq\nversion 1\nlinux /yoq/boot/ab12-vmlinuz-linux\ninitrd /yoq/boot/cd34-initramfs-linux.img\noptions " ++ luks_args ++ "\n", sd[1].text);
    // refind needs no partition guid for the root.
    const r = try refind(a, .{ .esp_part = "esp-guid", .root_part = "", .entries = &luks_entries });
    try testing.expectEqual(3, std.mem.count(u8, r, "    volume esp-guid\n"));
    try testing.expect(std.mem.indexOf(u8, r, "    loader /yoq/boot/ab12-vmlinuz-linux\n    options \"" ++ luks_args ++ " initrd=\\yoq\\boot\\cd34-initramfs-linux.img\"\n") != null);
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
    try testing.expectEqualStrings("yoq-trial-boot", try limineId(arena.allocator(), trial_title));
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

/// entries that start unified kernel images on the esp: the newest one,
/// and an older generation's, each with its own command line.
const uki_entries = [_]Entry{
    .{ .id = "head", .title = "yoq 3 · uki", .subvol = "/@roots/3", .kernel = "vmlinuz-linux", .initrds = &.{ "amd-ucode.img", "initramfs-linux.img" }, .args = "root=UUID=r rootflags=subvol=/@roots/3 rw", .esp_dir = "yoq/boot", .uki = "0123456789abcdef-yoq.efi" },
    .{ .id = "gen-2", .title = "yoq 2", .subvol = "/@roots/boot-2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "root=UUID=r rootflags=subvol=/@roots/boot-2 rw", .esp_dir = "yoq/boot", .uki = "fedcba9876543210-yoq.efi" },
};

test "entries that start unified kernel images" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try grub(a, .{ .esp_uuid = "41B2-0FB5", .root_uuid = "r", .default = "head", .entries = &uki_entries });
    try testing.expect(std.mem.indexOf(u8, g, "--set=root") == null);
    try testing.expect(std.mem.endsWith(u8, g,
        \\menuentry "yoq 3 · uki" --id head {
        \\  if [ "${yoq_trial_arg}" ]; then set yoq_tried=1; save_env -f (${yoq_esp})/yoq/grubenv yoq_tried; fi
        \\  insmod chain
        \\  chainloader (${yoq_esp})/yoq/boot/0123456789abcdef-yoq.efi root=UUID=r rootflags=subvol=/@roots/3 rw ${yoq_trial_arg}
        \\}
        \\
        \\menuentry "yoq 2" --id gen-2 {
        \\  insmod chain
        \\  chainloader (${yoq_esp})/yoq/boot/fedcba9876543210-yoq.efi root=UUID=r rootflags=subvol=/@roots/boot-2 rw ${yoq_trial_arg}
        \\}
        \\
    ));

    try testing.expectEqualStrings(limine_begin ++
        \\
        \\/yoq 3 - uki
        \\    protocol: efi
        \\    path: boot():/yoq/boot/0123456789abcdef-yoq.efi
        \\    cmdline: root=UUID=r rootflags=subvol=/@roots/3 rw
        \\/yoq 2
        \\    protocol: efi
        \\    path: boot():/yoq/boot/fedcba9876543210-yoq.efi
        \\    cmdline: root=UUID=r rootflags=subvol=/@roots/boot-2 rw
        \\/yoq trial boot
        \\    protocol: efi
        \\    path: boot():/yoq/boot/0123456789abcdef-yoq.efi
        \\    cmdline: root=UUID=r rootflags=subvol=/@roots/3 rw yoq.trial
        \\
    ++ limine_end ++ "\n", try limine(a, &uki_entries));

    const sd = try sdboot(a, &uki_entries);
    try testing.expectEqualStrings(
        \\# written by os. edits here are overwritten.
        \\title yoq 2
        \\sort-key yoq
        \\version 1
        \\efi /yoq/boot/fedcba9876543210-yoq.efi
        \\options root=UUID=r rootflags=subvol=/@roots/boot-2 rw
        \\
    , sd[1].text);
    try testing.expectEqualStrings(
        \\# written by os. edits here are overwritten.
        \\title yoq trial boot
        \\sort-key yoq-trial
        \\version 2
        \\efi /yoq/boot/0123456789abcdef-yoq.efi
        \\options root=UUID=r rootflags=subvol=/@roots/3 rw yoq.trial
        \\
    , sd[2].text);
    try testing.expectEqualStrings(sdboot_trial, sd[2].name);
    // one options line, since systemd-boot joins several, and the trial's
    // argument once.
    try testing.expectEqual(1, std.mem.count(u8, sd[2].text, "\noptions "));
    try testing.expectEqual(1, std.mem.count(u8, sd[2].text, "yoq.trial"));

    const r = try refind(a, .{ .esp_part = "esp-guid", .root_part = "", .entries = &uki_entries });
    try testing.expectEqualStrings(
        \\# written by os: one entry per generation. edits here are overwritten.
        \\
        \\menuentry "yoq 3 - uki" {
        \\    volume esp-guid
        \\    loader /yoq/boot/0123456789abcdef-yoq.efi
        \\    options "root=UUID=r rootflags=subvol=/@roots/3 rw"
        \\}
        \\
        \\menuentry "yoq 2" {
        \\    volume esp-guid
        \\    loader /yoq/boot/fedcba9876543210-yoq.efi
        \\    options "root=UUID=r rootflags=subvol=/@roots/boot-2 rw"
        \\}
        \\
        \\menuentry "yoq trial boot" {
        \\    volume esp-guid
        \\    loader /yoq/boot/0123456789abcdef-yoq.efi
        \\    options "root=UUID=r rootflags=subvol=/@roots/3 rw yoq.trial"
        \\}
        \\
        \\default_selection "yoq 3 - uki"
        \\
    , r);
}

/// entries whose images have their command lines in them, as with secure
/// boot: the newest, with a twin image for its trial, and an older one.
const embedded_entries = [_]Entry{
    .{ .id = "head", .title = "yoq 3", .subvol = "/@roots/3", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "root=UUID=r rootflags=subvol=/@roots/3 rw", .esp_dir = "yoq/boot", .uki = "0123456789abcdef-yoq.efi", .embedded = true, .trial_uki = "1111111111111111-yoq.efi" },
    .{ .id = "gen-2", .title = "yoq 2", .subvol = "/@roots/boot-2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "root=UUID=r rootflags=subvol=/@roots/boot-2 rw", .esp_dir = "yoq/boot", .uki = "fedcba9876543210-yoq.efi", .embedded = true },
};

test "entries whose images have their command line pass none" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // grub: a trial starts the twin, since the image ignores
    // ${yoq_trial_arg}.
    const g = try grub(a, .{ .esp_uuid = "41B2-0FB5", .root_uuid = "r", .default = "head", .entries = &embedded_entries });
    try testing.expect(std.mem.endsWith(u8, g,
        \\menuentry "yoq 3" --id head {
        \\  if [ "${yoq_trial_arg}" ]; then set yoq_tried=1; save_env -f (${yoq_esp})/yoq/grubenv yoq_tried; fi
        \\  insmod chain
        \\  if [ "${yoq_trial_arg}" ]; then
        \\    chainloader (${yoq_esp})/yoq/boot/1111111111111111-yoq.efi
        \\  else
        \\    chainloader (${yoq_esp})/yoq/boot/0123456789abcdef-yoq.efi
        \\  fi
        \\}
        \\
        \\menuentry "yoq 2" --id gen-2 {
        \\  insmod chain
        \\  chainloader (${yoq_esp})/yoq/boot/fedcba9876543210-yoq.efi
        \\}
        \\
    ));

    try testing.expectEqualStrings(limine_begin ++
        \\
        \\/yoq 3
        \\    protocol: efi
        \\    path: boot():/yoq/boot/0123456789abcdef-yoq.efi
        \\/yoq 2
        \\    protocol: efi
        \\    path: boot():/yoq/boot/fedcba9876543210-yoq.efi
        \\/yoq trial boot
        \\    protocol: efi
        \\    path: boot():/yoq/boot/1111111111111111-yoq.efi
        \\
    ++ limine_end ++ "\n", try limine(a, &embedded_entries));

    const sd = try sdboot(a, &embedded_entries);
    try testing.expectEqualStrings(
        \\# written by os. edits here are overwritten.
        \\title yoq 3
        \\sort-key yoq
        \\version 2
        \\efi /yoq/boot/0123456789abcdef-yoq.efi
        \\
    , sd[0].text);
    try testing.expectEqualStrings(
        \\# written by os. edits here are overwritten.
        \\title yoq trial boot
        \\sort-key yoq-trial
        \\version 2
        \\efi /yoq/boot/1111111111111111-yoq.efi
        \\
    , sd[2].text);
    for (sd) |f| try testing.expect(std.mem.indexOf(u8, f.text, "options") == null);

    const r = try refind(a, .{ .esp_part = "esp-guid", .root_part = "", .entries = &embedded_entries });
    try testing.expectEqualStrings(
        \\# written by os: one entry per generation. edits here are overwritten.
        \\
        \\menuentry "yoq 3" {
        \\    volume esp-guid
        \\    loader /yoq/boot/0123456789abcdef-yoq.efi
        \\}
        \\
        \\menuentry "yoq 2" {
        \\    volume esp-guid
        \\    loader /yoq/boot/fedcba9876543210-yoq.efi
        \\}
        \\
        \\menuentry "yoq trial boot" {
        \\    volume esp-guid
        \\    loader /yoq/boot/1111111111111111-yoq.efi
        \\}
        \\
        \\default_selection "yoq 3"
        \\
    , r);
    try testing.expectEqualStrings("root=UUID=r rw yoq.trial", try trialArgs(a, "root=UUID=r rw"));
}

test "grub's chainloader gets quoted kernel arguments as they are" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = "root=UUID=r rw acpi_osi=\"!Windows  2012\" it's";
    const entries = [_]Entry{
        .{ .id = "head", .title = "yoq 3", .subvol = "/@roots/3", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = args, .esp_dir = "yoq/boot", .uki = "0123456789abcdef-yoq.efi" },
        .{ .id = "gen-2", .title = "yoq 2", .subvol = "/@roots/boot-2", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = args, .esp_dir = "yoq/boot" },
    };
    const g = try grub(a, .{ .esp_uuid = "e", .root_uuid = "r", .default = "head", .entries = &entries });
    try testing.expect(std.mem.indexOf(u8, g, "  chainloader (${yoq_esp})/yoq/boot/0123456789abcdef-yoq.efi root=UUID=r rw 'acpi_osi=\"!Windows  2012\"' 'it'\\''s' ${yoq_trial_arg}\n") != null);
    // grub's linux command quotes the arguments again by itself.
    try testing.expect(std.mem.indexOf(u8, g, "  linux (${yoq_esp})/yoq/boot/vmlinuz-linux " ++ args ++ " ${yoq_trial_arg}\n") != null);
}

test "refind can't take a quote in the kernel arguments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(null, try refindArgsProblem(arena.allocator(), "root=UUID=r rw quiet"));
    try testing.expect(try refindArgsProblem(arena.allocator(), "rw acpi_osi=\"!Windows 2012\"") != null);
}

test "refind's entries, and its include" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const older: Entry = .{ .id = "gen-1", .title = "yoq 1 · enable-rollback", .subvol = "/@roots/boot-1", .kernel = "vmlinuz-linux", .initrds = &.{ "amd-ucode.img", "initramfs-linux.img" }, .args = "rw" };
    const yoq = try refind(a, .{ .esp_part = "esp-guid", .root_part = "root-guid", .entries = &.{ test_entries[0], older } });
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
        \\menuentry "yoq trial boot" {
        \\    volume esp-guid
        \\    loader /vmlinuz-linux
        \\    options "root=UUID=r rw yoq.trial initrd=\amd-ucode.img initrd=\initramfs-linux.img"
        \\}
        \\
        \\default_selection "yoq 2 - add fd"
        \\
    , yoq);
    try testing.expectEqualStrings("yoq 2 - add fd", refindHead(yoq).?);
    const moved = try refindDefault(a, yoq, "yoq 1 · enable-rollback");
    try testing.expect(std.mem.endsWith(u8, moved, "default_selection \"yoq 1 - enable-rollback\"\n"));
    const trial = try refindTrialConf(a, "timeout 3\ninclude yoq.conf\n", yoq);
    try testing.expect(std.mem.startsWith(u8, trial, "timeout 3\n\n# written by os"));
    try testing.expect(std.mem.indexOf(u8, trial, "include yoq.conf") == null);
    try testing.expect(std.mem.endsWith(u8, trial, "default_selection \"yoq trial boot\"\n"));
    try testing.expectEqualStrings("\"Arch Linux\" \"root=UUID=r rw initrd=\\amd-ucode.img initrd=\\initramfs-linux.img\"\n", try refindLinux(a, test_entries[0]));
    try testing.expectEqualStrings("timeout 20\n", try unspliceRefind(a, "timeout 20\ninclude yoq.conf\n"));
    const conf = "timeout 20\ninclude yoq.conf\ndefault_selection 1\n";
    try testing.expectEqualStrings("timeout 20\ndefault_selection 1\ninclude yoq.conf\n", try spliceRefind(a, conf));
}
