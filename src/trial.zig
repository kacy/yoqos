//! a generation on trial: the next boot tries it once, the default stays
//! on the generation before, and `os health` ends the trial one way or the
//! other. grub reads these choices from an env file on the esp, since it
//! can write fat but not btrfs. limine and systemd-boot read them from
//! efi variables, which bootctl sets. refind has no one-shot boot, so the
//! firmware's own, BootNext, starts it with a config of os's. whatever
//! the loader, os keeps the trial itself in /var, where only root can
//! write it.

const std = @import("std");
const exec = @import("exec.zig");
const rootfs = @import("rootfs.zig");
const generation = @import("generation.zig");
const facts = @import("facts.zig");
const menu = @import("menu.zig");
const events = @import("events.zig");
const bootcheck = @import("bootcheck.zig");
const Allocator = std.mem.Allocator;

pub const Trial = struct {
    /// the generation on trial.
    n: u32,
    /// the generation a failed trial falls back to, or 0.
    fallback: u32,
    /// the boot that tries it has started.
    tried: bool,
    /// os noted the trial in /var when it armed it. one only grub's env
    /// file names, which anything that can write the esp can set, may
    /// pass, as one armed before os noted grub's there did, but never
    /// makes the machine fall back.
    noted: bool = true,
    /// how far os got with it.
    phase: Phase = .armed,
};

/// how far a trial got, by os's note of it. a power cut can stop os
/// between any two steps, and the note says where.
pub const Phase = enum {
    /// the note went in before the menu that holds the default on the
    /// fallback, and the bootloader may not be set up yet. the next boot
    /// sets the trial up again.
    arming,
    /// the next boot tries it.
    armed,
    /// it came up healthy, and is on its way to being the default. the
    /// next boot finishes that, whichever generation it runs.
    passed,
};

/// os's note of a trial: its phase, then its generation, the one before
/// it, and for refind, the firmware entry. a note without a phase, like
/// one from an older os, is an armed trial.
const Note = struct {
    phase: Phase,
    words: [3][]const u8,
};

fn parseNote(text: []const u8) ?Note {
    var words = std.mem.tokenizeAny(u8, text, " \n");
    var first = words.next() orelse return null;
    var phase: Phase = .armed;
    if (std.meta.stringToEnum(Phase, first)) |p| {
        phase = p;
        first = words.next() orelse return null;
    }
    return .{ .phase = phase, .words = .{ first, words.next() orelse "0", words.next() orelse "" } };
}

fn formatNote(a: Allocator, phase: Phase, words: [3][]const u8) ![]const u8 {
    const entry = if (words[2].len > 0) try std.fmt.allocPrint(a, " {s}", .{words[2]}) else "";
    return std.fmt.allocPrint(a, "{s} {s} {s}{s}\n", .{ @tagName(phase), words[0], words[1], entry });
}

/// where a machine keeps its trial.
pub const Store = struct {
    a: Allocator,
    io: std.Io,
    loader: menu.Loader,
    esp: []const u8,
    /// refind's config, and the esp's partition, for its trial boots.
    conf: ?[]const u8 = null,
    esp_device: ?[]const u8 = null,
    /// where the btrfs top level is mounted, for refind's trial, which
    /// loads its kernel from its root. null when it isn't.
    top: ?[]const u8 = null,

    /// null for a machine without an esp or a bootloader os knows.
    pub fn of(a: Allocator, io: std.Io, boot: facts.Boot) ?Store {
        return .{
            .a = a,
            .io = io,
            .loader = menu.Loader.of(boot) orelse return null,
            .esp = boot.esp orelse return null,
            .conf = boot.loader_conf,
            .esp_device = boot.esp_device,
        };
    }

    /// the trial waiting for its boot, or running, if there is one.
    pub fn current(s: Store) !?Trial {
        if (s.loader == .grub) {
            const env_trial = try s.number("yoq_trial");
            const env_default = try s.number("yoq_default");
            const noted = try s.state() orelse try s.journalNote(env_trial, env_default);
            return grubTrial(noted, env_trial, env_default, try s.value("yoq_tried") != null);
        }
        const note = try s.state() orelse return null;
        // the bootloader, or for refind the firmware, clears the one-shot
        // variable when it reads it, whatever then boots. an entry picked
        // by hand in its place didn't try the trial.
        const cleared = !rootfs.pathExists(s.io, if (s.loader == .refind) bootnext_var else oneshot_var);
        return .{
            .n = std.fmt.parseInt(u32, note.words[0], 10) catch return null,
            .fallback = std.fmt.parseInt(u32, note.words[1], 10) catch 0,
            .tried = cleared and !byHand(s.loader, .{
                .selected = try s.efiText(selected_var),
                .default = try s.efiText(default_var),
                .boot_current = try s.efiNumber(bootcurrent_var),
                .trial_entry = note.words[2],
            }),
            .phase = note.phase,
        };
    }

    /// notes that generation `n` is about to go on trial, falling back to
    /// `fallback`. it goes in before the menu that holds the default on
    /// `fallback` (see gens.Machine.add), so a power cut from there on
    /// leaves a note that says the trial was never set up.
    pub fn prepare(s: Store, n: u32, fallback: u32) !?[]const u8 {
        return s.write(state_path, try std.fmt.allocPrint(s.a, "{s} {d} {d}\n", .{ @tagName(Phase.arming), n, fallback }));
    }

    /// notes that the trial passed, before it's made the default.
    pub fn pass(s: Store) !?[]const u8 {
        const note = try s.state() orelse return "no trial to pass";
        return s.write(state_path, try formatNote(s.a, .passed, note.words));
    }

    /// an efi variable's text, as the boot loader interface stores it:
    /// utf-16 after 4 bytes of attributes, read as ascii, which is all
    /// os's entry names are.
    fn efiText(s: Store, path: []const u8) !?[]const u8 {
        const bytes = std.Io.Dir.cwd().readFileAlloc(s.io, path, s.a, .limited(4096)) catch return null;
        return try efiString(s.a, bytes);
    }

    /// an efi variable's 16-bit number, like BootCurrent's.
    fn efiNumber(s: Store, path: []const u8) !?u16 {
        var buf: [8]u8 = undefined;
        const bytes = std.Io.Dir.cwd().readFile(s.io, path, &buf) catch return null;
        if (bytes.len < 6) return null;
        return std.mem.readInt(u16, bytes[4..6], .little);
    }

    /// makes the next boot try the newest generation, `n`, once, and
    /// fall back to `fallback` if it doesn't come up.
    pub fn arm(s: Store, n: u32, fallback: generation.Record) !?[]const u8 {
        if (try s.prepare(n, fallback.n)) |w| return w;
        const why = switch (s.loader) {
            .grub => blk: {
                _ = try s.edit("unset", &.{"yoq_tried"});
                if (try s.edit("set", &.{
                    "yoq_next=head",
                    try std.fmt.allocPrint(s.a, "yoq_default={s}", .{try menu.genId(s.a, fallback.n)}),
                    try std.fmt.allocPrint(s.a, "yoq_trial={d}", .{n}),
                })) |w| break :blk w;
                break :blk try s.write(state_path, try std.fmt.allocPrint(s.a, "{d} {d}\n", .{ n, fallback.n }));
            },
            .limine, .@"systemd-boot" => try s.armBootctl(n, fallback),
            .refind => try s.armRefind(n, fallback),
        } orelse return null;
        // a trial armed halfway is taken back.
        _ = try s.end();
        return why;
    }

    /// the one-shot first, and the note of the trial last: a fallback
    /// default or a note without a one-shot would make the next boot look
    /// like a failed trial.
    fn armBootctl(s: Store, n: u32, fallback: generation.Record) !?[]const u8 {
        const id = if (s.loader == .limine)
            try menu.limineId(s.a, try generation.title(s.a, fallback))
        else
            try menu.sdbootName(s.a, try menu.genId(s.a, fallback.n));
        if (try s.retry()) |w| return w;
        if (try s.bootctl("set-default", id)) |w| return w;
        return s.write(state_path, try std.fmt.allocPrint(s.a, "{d} {d}\n", .{ n, fallback.n }));
    }

    /// refind has no one-shot boot of its own, so the firmware's does it:
    /// a boot entry, made the next boot with BootNext, that starts a copy
    /// of refind in a directory of its own. refind reads the refind.conf
    /// beside it, and that one's default is the trial entry. refind's own
    /// config meanwhile defaults to the generation before, which the boot
    /// after a failed trial gets.
    fn armRefind(s: Store, n: u32, fallback: generation.Record) !?[]const u8 {
        const conf = s.conf orelse return "can't find refind.conf";
        const dir = std.fs.path.dirnamePosix(conf).?;
        const yoq_path = try std.fs.path.join(s.a, &.{ dir, menu.refind_file });
        const cwd = std.Io.Dir.cwd();
        const yoq = cwd.readFileAlloc(s.io, yoq_path, s.a, .limited(1 << 20)) catch return "can't read yoq.conf";
        const main = cwd.readFileAlloc(s.io, conf, s.a, .limited(1 << 20)) catch return "can't read refind.conf";
        const binary = try refindBinary(s.a, s.io, dir) orelse return "can't find refind's efi binary";
        const trial_dir = try s.refindTrialDir();
        if (try exec.runAll(s.a, s.io, &.{
            &.{ "rm", "-rf", trial_dir },
            &.{ "mkdir", "-p", trial_dir },
            &.{ "cp", try std.fs.path.join(s.a, &.{ dir, binary }), trial_dir },
        })) |w| return w;
        // its drivers too, since refind reads btrfs through one; its icons
        // if it has them.
        for ([_][]const u8{ "drivers_x64", "icons" }) |sub| {
            const from = try std.fs.path.join(s.a, &.{ dir, sub });
            if (!rootfs.pathExists(s.io, from)) continue;
            if (try exec.run(s.a, s.io, &.{ "cp", "-a", from, trial_dir })) |w| return w;
        }
        if (try s.write(try std.fs.path.join(s.a, &.{ trial_dir, "refind.conf" }), try menu.refindTrialConf(s.a, main, yoq))) |w| return w;
        // one entry at a time: an earlier trial's, or one a failed arm
        // left, would stay in nvram and be the one found by its label.
        try s.dropFirmwareEntries();
        const entry = try s.firmwareEntry(trial_dir, binary) orelse return "can't add a boot entry for the trial";
        if (try exec.run(s.a, s.io, &.{ "efibootmgr", "-q", "-n", entry })) |w| return w;
        if (try s.write(yoq_path, try menu.refindDefault(s.a, yoq, try generation.title(s.a, fallback)))) |w| return w;
        return s.write(state_path, try std.fmt.allocPrint(s.a, "{d} {d} {s}\n", .{ n, fallback.n, entry }));
    }

    /// where a trial's copy of refind lives, on the esp.
    fn refindTrialDir(s: Store) ![]const u8 {
        return std.fs.path.join(s.a, &.{ s.esp, "EFI", menu.refind_trial_dir });
    }

    /// makes the firmware entry that starts `binary` in `dir`, without
    /// changing the boot order, and returns its number, like "0004".
    fn firmwareEntry(s: Store, dir: []const u8, binary: []const u8) !?[]const u8 {
        const device = s.esp_device orelse return null;
        const disk = try s.lsblk("PKNAME", device) orelse return null;
        const part = try s.lsblk("PARTN", device) orelse return null;
        // as the firmware names it: \EFI\yoq-trial\refind_x64.efi.
        const loader = try std.fs.path.join(s.a, &.{ dir[s.esp.len..], binary });
        std.mem.replaceScalar(u8, loader, '/', '\\');
        const out = switch (try exec.output(s.a, s.io, &.{ "efibootmgr", "-C", "-d", try std.fmt.allocPrint(s.a, "/dev/{s}", .{disk}), "-p", part, "-l", loader, "-L", firmware_label })) {
            .ok => |t| t,
            .failed => return null,
        };
        return firmwareNumber(out);
    }

    /// one of lsblk's columns for `device`.
    fn lsblk(s: Store, column: []const u8, device: []const u8) !?[]const u8 {
        return switch (try exec.output(s.a, s.io, &.{ "lsblk", "-no", column, device })) {
            .ok => |t| std.mem.trim(u8, t, " \n"),
            .failed => null,
        };
    }

    /// removes every firmware entry with the trial's label.
    fn dropFirmwareEntries(s: Store) !void {
        const listing = switch (try exec.output(s.a, s.io, &.{"efibootmgr"})) {
            .ok => |t| t,
            .failed => return,
        };
        var lines = std.mem.splitScalar(u8, listing, '\n');
        while (lines.next()) |line| {
            const id = firmwareNumber(line) orelse continue;
            _ = try exec.run(s.a, s.io, &.{ "efibootmgr", "-q", "-b", id, "-B" });
        }
    }

    /// what's wrong with a file the trial entry loads, as "<path>: <why>",
    /// or null when each one looks loadable. limine stops at an error
    /// screen until someone presses a key when it can't load one, and so
    /// do refind and systemd-boot before 258, so a trial with a broken
    /// file is better not tried. grub falls back by itself.
    pub fn brokenFile(s: Store) !?[]const u8 {
        const found = try s.trialFiles() orelse return null;
        for (found.files) |f| {
            const path = try std.fs.path.join(s.a, &.{ found.base, f.path });
            if (try fileProblem(s.a, s.io, path, f.kernel)) |why| return try std.fmt.allocPrint(s.a, "{s}: {s}", .{ path, why });
        }
        return null;
    }

    const TrialFiles = struct { base: []const u8, files: []const menu.Loaded };

    /// the files the trial entry loads, as paths under `base`, or null
    /// when there's nothing to look at.
    fn trialFiles(s: Store) !?TrialFiles {
        const cwd = std.Io.Dir.cwd();
        switch (s.loader) {
            .limine => {
                const text = cwd.readFileAlloc(s.io, s.conf orelse return null, s.a, .limited(1 << 20)) catch return null;
                return .{ .base = s.esp, .files = try menu.limineTrialFiles(s.a, text) };
            },
            .@"systemd-boot" => {
                const conf = s.conf orelse try std.fs.path.join(s.a, &.{ s.esp, "loader/loader.conf" });
                const dir_path = try std.fs.path.join(s.a, &.{ std.fs.path.dirnamePosix(conf).?, "entries" });
                var dir = cwd.openDir(s.io, dir_path, .{ .iterate = true }) catch return null;
                defer dir.close(s.io);
                var it = dir.iterate();
                // the counter in its name changes once it has booted.
                while (it.next(s.io) catch null) |f| {
                    if (!std.mem.startsWith(u8, f.name, "yoq-trial") or !std.mem.endsWith(u8, f.name, ".conf")) continue;
                    const text = dir.readFileAlloc(s.io, f.name, s.a, .limited(1 << 16)) catch return null;
                    return .{ .base = s.esp, .files = try menu.sdbootFiles(s.a, text) };
                }
                return null;
            },
            // the trial's copy of refind reads its own refind.conf. its
            // entry loads from the esp, or from the root's partition,
            // where paths start at the btrfs top level.
            .refind => {
                const conf = try std.fs.path.join(s.a, &.{ try s.refindTrialDir(), "refind.conf" });
                const text = cwd.readFileAlloc(s.io, conf, s.a, .limited(1 << 20)) catch return null;
                const t = try menu.refindTrialFiles(s.a, text) orelse return null;
                const esp_part = try s.lsblk("PARTUUID", s.esp_device orelse return null) orelse return null;
                const base = if (std.ascii.eqlIgnoreCase(t.volume, esp_part)) s.esp else s.top orelse return null;
                return .{ .base = base, .files = t.files };
            },
            .grub => return null,
        }
    }

    /// leaves the trial untried: the next boot runs the default, the
    /// generation before, and the health check takes that as the trial
    /// failing.
    pub fn skip(s: Store) !?[]const u8 {
        return switch (s.loader) {
            .limine, .@"systemd-boot" => s.bootctl("set-oneshot", ""),
            .refind => exec.run(s.a, s.io, &.{ "efibootmgr", "-q", "-N" }),
            .grub => null,
        };
    }

    /// the trial hasn't booted yet: the next boot tries it again.
    pub fn retry(s: Store) !?[]const u8 {
        return switch (s.loader) {
            .grub => s.edit("set", &.{"yoq_next=head"}),
            .limine => s.bootctl("set-oneshot", try menu.limineId(s.a, menu.trial_title)),
            .@"systemd-boot" => s.bootctl("set-oneshot", menu.sdboot_trial),
            .refind => {
                const note = try s.state() orelse return "no trial to try again";
                return exec.run(s.a, s.io, &.{ "efibootmgr", "-q", "-n", note.words[2] });
            },
        };
    }

    /// ends a trial, however it went: the newest generation is the
    /// default again.
    pub fn end(s: Store) !?[]const u8 {
        switch (s.loader) {
            .grub => if (try s.edit("unset", &.{ "yoq_default", "yoq_trial", "yoq_tried" })) |w| return w,
            .limine, .@"systemd-boot" => {
                // empty removes the one-shot. limine's first entry is the
                // newest generation, so it needs no default; systemd-boot
                // is pointed at it, past loader.conf's own.
                if (try s.bootctl("set-oneshot", "")) |w| return w;
                if (try s.bootctl("set-default", if (s.loader == .limine) "" else try menu.sdbootName(s.a, "head"))) |w| return w;
            },
            .refind => if (try s.endRefind()) |w| return w,
        }
        std.Io.Dir.cwd().deleteFile(s.io, state_path) catch {};
        return null;
    }

    /// removes the trial's firmware entry and copy of refind, and makes
    /// the newest generation refind's default again.
    fn endRefind(s: Store) !?[]const u8 {
        try s.dropFirmwareEntries();
        _ = try exec.run(s.a, s.io, &.{ "rm", "-rf", try s.refindTrialDir() });
        const conf = s.conf orelse return null;
        const yoq_path = try std.fs.path.join(s.a, &.{ std.fs.path.dirnamePosix(conf).?, menu.refind_file });
        const yoq = std.Io.Dir.cwd().readFileAlloc(s.io, yoq_path, s.a, .limited(1 << 20)) catch "";
        const head = menu.refindHead(yoq) orelse return null;
        return s.write(yoq_path, try menu.refindDefault(s.a, yoq, head));
    }

    /// os's note of the trial.
    fn state(s: Store) !?Note {
        const text = std.Io.Dir.cwd().readFileAlloc(s.io, state_path, s.a, .limited(128)) catch return null;
        return parseNote(text);
    }

    /// a grub trial os armed before 0.1.4, which noted it only as an
    /// armed event in the journal, as the words of a note. the journal is
    /// root's alone, like the note, so a trial armed just before os was
    /// upgraded still falls back if it fails.
    fn journalNote(s: Store, n: ?u32, fallback: ?u32) !?Note {
        const t = n orelse return null;
        if (!try events.armedLast(s.a, s.io, "/", t)) return null;
        return .{ .phase = .armed, .words = .{ try std.fmt.allocPrint(s.a, "{d}", .{t}), try std.fmt.allocPrint(s.a, "{d}", .{fallback orelse 0}), "" } };
    }

    fn write(s: Store, path: []const u8, text: []const u8) !?[]const u8 {
        return rootfs.writeWhole(s.a, s.io, path, text);
    }

    fn bootctl(s: Store, verb: []const u8, id: []const u8) !?[]const u8 {
        return exec.run(s.a, s.io, &.{ "bootctl", verb, id });
    }

    /// where os keeps a trial: its generation, the one before it, and
    /// refind's firmware entry.
    const state_path = "/var/lib/yoq/trial";
    /// the variable limine and systemd-boot boot once from, under the
    /// boot loader interface's vendor guid; the one they boot by default,
    /// which bootctl sets too; and the one they set to the entry this boot
    /// runs.
    const oneshot_var = "/sys/firmware/efi/efivars/LoaderEntryOneShot-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f";
    const default_var = "/sys/firmware/efi/efivars/LoaderEntryDefault-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f";
    const selected_var = "/sys/firmware/efi/efivars/LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f";
    /// the firmware's own one-shot boot, and the boot entry this boot
    /// started from, under the global uefi guid.
    const bootnext_var = "/sys/firmware/efi/efivars/BootNext-8be4df61-93ca-11d2-aa0d-00e098032b8c";
    const bootcurrent_var = "/sys/firmware/efi/efivars/BootCurrent-8be4df61-93ca-11d2-aa0d-00e098032b8c";

    /// the env file on the esp that grub reads the menu's choices from.
    fn envPath(s: Store) ![]const u8 {
        return std.fs.path.join(s.a, &.{ s.esp, generation.grubenv });
    }

    /// a generation number from the env file: "12", or "gen-12".
    fn number(s: Store, name: []const u8) !?u32 {
        const v = try s.value(name) orelse return null;
        const digits = if (std.mem.startsWith(u8, v, "gen-")) v["gen-".len..] else v;
        return std.fmt.parseInt(u32, digits, 10) catch null;
    }

    fn value(s: Store, name: []const u8) !?[]const u8 {
        const text = switch (try exec.output(s.a, s.io, &.{ "grub-editenv", try s.envPath(), "list" })) {
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

    /// sets `name=value` pairs, or with "unset", removes names.
    fn edit(s: Store, verb: []const u8, args: []const []const u8) !?[]const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(s.a, &.{ "grub-editenv", try s.envPath(), verb });
        try argv.appendSlice(s.a, args);
        return exec.run(s.a, s.io, argv.items);
    }
};

/// grub's trial, from os's note of it, `noted`, or without one, from the
/// env file's `env_trial` and `env_default`. whether the boot has started
/// is the env file's either way: grub sets it.
fn grubTrial(noted: ?Note, env_trial: ?u32, env_default: ?u32, tried: bool) ?Trial {
    const note = noted orelse return .{ .n = env_trial orelse return null, .fallback = env_default orelse 0, .tried = tried, .noted = false };
    return .{
        .n = std.fmt.parseInt(u32, note.words[0], 10) catch return null,
        .fallback = std.fmt.parseInt(u32, note.words[1], 10) catch 0,
        .tried = tried,
        .phase = note.phase,
    };
}

test "a trial's note says how far it got" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // one from an older os has no phase, and was armed.
    const old = parseNote("7 6\n").?;
    try std.testing.expectEqual(Phase.armed, old.phase);
    try std.testing.expectEqualStrings("6", old.words[1]);
    const refind = parseNote("arming 7 6 0004\n").?;
    try std.testing.expectEqual(Phase.arming, refind.phase);
    try std.testing.expectEqualStrings("0004", refind.words[2]);
    try std.testing.expectEqualStrings("passed 7 6 0004\n", try formatNote(a, .passed, refind.words));
    try std.testing.expectEqualStrings("passed 7 6\n", try formatNote(a, .passed, old.words));
    try std.testing.expectEqual(null, parseNote(""));
    try std.testing.expectEqual(null, parseNote("arming\n"));
}

test "grub's trial is os's note of it, not the esp's" {
    const t = grubTrial(.{ .phase = .armed, .words = .{ "7", "6", "" } }, 9, 2, true).?;
    try std.testing.expectEqual(7, t.n);
    try std.testing.expectEqual(6, t.fallback);
    try std.testing.expect(t.tried and t.noted);
    // one only the env file names can't make the machine fall back.
    const planted = grubTrial(null, 9, 2, true).?;
    try std.testing.expectEqual(9, planted.n);
    try std.testing.expect(!planted.noted);
    try std.testing.expectEqual(null, grubTrial(null, null, 2, true));
}

/// what a boot that cleared the trial's one-shot says about itself.
const Booted = struct {
    /// limine's and systemd-boot's entry for this boot, and the default
    /// os set, the generation the trial falls back to.
    selected: ?[]const u8 = null,
    default: ?[]const u8 = null,
    /// the firmware entry this boot started from, and the trial's, for
    /// refind, which starts a trial through a firmware entry of its own.
    boot_current: ?u16 = null,
    trial_entry: []const u8 = "",
};

/// whether a boot that isn't the trial's, though the one-shot that
/// would have started it is gone, ran an entry picked by hand: that
/// leaves the trial untried. a trial that didn't come up leaves the
/// machine on the default, the generation before, which limine and
/// systemd-boot name as this boot's entry; any other entry was picked.
/// refind's trial boots its own copy of refind, through a firmware entry
/// of its own, so this boot starting from that entry means an older one
/// was picked there. a hand pick of the generation before itself looks
/// just like a failed trial.
fn byHand(loader: menu.Loader, b: Booted) bool {
    return switch (loader) {
        .limine, .@"systemd-boot" => {
            const selected = b.selected orelse return false;
            const default = b.default orelse return false;
            return !std.mem.eql(u8, selected, default);
        },
        .refind => {
            const current = b.boot_current orelse return false;
            const entry = std.fmt.parseInt(u16, b.trial_entry, 16) catch return false;
            return current == entry;
        },
        .grub => false,
    };
}

/// the ascii text of an efi variable's bytes: 4 bytes of attributes,
/// then utf-16 up to a nul. null for anything else.
fn efiString(a: Allocator, bytes: []const u8) !?[]const u8 {
    if (bytes.len < 4) return null;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 4;
    while (i + 1 < bytes.len) : (i += 2) {
        const ch = std.mem.readInt(u16, bytes[i..][0..2], .little);
        if (ch == 0) break;
        if (ch >= 0x80) return null;
        try out.append(a, @intCast(ch));
    }
    return out.items;
}

test "an older entry picked by hand isn't a failed trial" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // "yoq-gen-2.conf" as the boot loader interface stores it.
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(a, &.{ 6, 0, 0, 0 });
    for ("yoq-gen-2.conf") |ch| try bytes.appendSlice(a, &.{ ch, 0 });
    try bytes.appendSlice(a, &.{ 0, 0 });
    const gen2 = (try efiString(a, bytes.items)).?;
    try std.testing.expectEqualStrings("yoq-gen-2.conf", gen2);
    // the default, after a trial that didn't come up, or another entry.
    try std.testing.expect(!byHand(.@"systemd-boot", .{ .selected = gen2, .default = "yoq-gen-2.conf" }));
    try std.testing.expect(byHand(.@"systemd-boot", .{ .selected = "yoq-gen-1.conf", .default = "yoq-gen-2.conf" }));
    try std.testing.expect(byHand(.limine, .{ .selected = "yoq-1-enable-rollback", .default = "yoq-2-add-fd" }));
    // without the variables, nothing says it was.
    try std.testing.expect(!byHand(.limine, .{ .default = "yoq-2-add-fd" }));
    // refind: this boot started from the trial's firmware entry.
    try std.testing.expect(byHand(.refind, .{ .boot_current = 4, .trial_entry = "0004" }));
    try std.testing.expect(!byHand(.refind, .{ .boot_current = 1, .trial_entry = "0004" }));
    try std.testing.expect(!byHand(.grub, .{ .selected = "x", .default = "y" }));
}

/// what's wrong with the boot file at `path`, a `kernel` or not (see
/// bootcheck.problem), or null if it looks loadable.
fn fileProblem(a: Allocator, io: std.Io, path: []const u8, kernel: bool) !?[]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return "it's missing";
    defer file.close(io);
    const size = (file.stat(io) catch return "it can't be read").size;
    var head: [bootcheck.head_bytes]u8 = undefined;
    const n = file.readPositionalAll(io, &head, 0) catch return "it can't be read";
    var sum: ?[]const u8 = null;
    if (!kernel and bootcheck.hashedName(path) != null) {
        var h: std.crypto.hash.sha2.Sha256 = .init(.{});
        var buf: [64 << 10]u8 = undefined;
        var at: u64 = 0;
        while (true) {
            const got = file.readPositionalAll(io, &buf, at) catch return "it can't be read";
            if (got == 0) break;
            h.update(buf[0..got]);
            at += got;
        }
        var digest: [32]u8 = undefined;
        h.final(&digest);
        sum = try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
    }
    return bootcheck.problem(kernel, path, head[0..n], size, sum);
}

test "a trial's files that limine couldn't load" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const esp = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "yoq/boot");
    const pe = bootcheck.testPe(0x200, 0x200);
    var kernel: [0x400]u8 = undefined;
    @memcpy(kernel[0..512], &pe);
    @memset(kernel[512..], 0);
    const initrd = "an initramfs";
    const initrd_name = try std.fmt.allocPrint(a, "yoq/boot/{s}-initramfs-linux.img", .{facts.sha256Hex(initrd)[0..16]});
    try tmp.dir.writeFile(io, .{ .sub_path = "yoq/boot/0123456789abcdef-vmlinuz-linux", .data = &kernel });
    try tmp.dir.writeFile(io, .{ .sub_path = initrd_name, .data = initrd });
    const conf = try std.fmt.allocPrint(a, "{s}\n/yoq trial boot\n    protocol: linux\n    path: boot():/yoq/boot/0123456789abcdef-vmlinuz-linux\n    module_path: boot():/{s}\n    cmdline: rw\n{s}\n", .{ menu.limine_begin, initrd_name, menu.limine_end });
    try tmp.dir.writeFile(io, .{ .sub_path = "limine.conf", .data = conf });
    const s: Store = .{ .a = a, .io = io, .loader = .limine, .esp = esp, .conf = try std.fmt.allocPrint(a, "{s}/limine.conf", .{esp}) };
    try std.testing.expectEqual(null, try s.brokenFile());
    // cut off, the kernel isn't whole.
    try tmp.dir.writeFile(io, .{ .sub_path = "yoq/boot/0123456789abcdef-vmlinuz-linux", .data = kernel[0..0x300] });
    try std.testing.expect(std.mem.endsWith(u8, (try s.brokenFile()).?, "0123456789abcdef-vmlinuz-linux: it isn't a whole efi binary"));
    try tmp.dir.writeFile(io, .{ .sub_path = "yoq/boot/0123456789abcdef-vmlinuz-linux", .data = &kernel });
    // an initramfs that changed after os named it.
    try tmp.dir.writeFile(io, .{ .sub_path = initrd_name, .data = "something else" });
    try std.testing.expect(std.mem.endsWith(u8, (try s.brokenFile()).?, "-initramfs-linux.img: its content doesn't match the hash in its name"));
    try tmp.dir.deleteFile(io, initrd_name);
    try std.testing.expect(std.mem.endsWith(u8, (try s.brokenFile()).?, "-initramfs-linux.img: it's missing"));
}

/// refind's efi binary in `dir`, like refind_x64.efi.
fn refindBinary(a: Allocator, io: std.Io, dir: []const u8) !?[]const u8 {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return null;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |f| {
        if (std.mem.startsWith(u8, f.name, "refind_") and std.mem.endsWith(u8, f.name, ".efi")) return try a.dupe(u8, f.name);
    }
    return null;
}

/// the label of the firmware entry a refind trial boots.
const firmware_label = "yoq trial";

/// the number of the entry labelled `firmware_label` in efibootmgr's
/// listing, like "0004" from "Boot0004* yoq trial".
fn firmwareNumber(listing: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (line.len < 10 or !std.mem.startsWith(u8, line, "Boot") or !std.ascii.isHex(line[4])) continue;
        const name = std.mem.trimStart(u8, line[8..], "* ");
        if (std.mem.startsWith(u8, name, firmware_label)) return line[4..8];
    }
    return null;
}

test "the firmware entry a refind trial made" {
    const listing =
        \\BootCurrent: 0001
        \\BootOrder: 0001,0000
        \\Boot0000* UiApp\tFvVol(7cb8bdc9)
        \\Boot0001* rEFInd Boot Manager\tHD(1,GPT)
        \\Boot0004* yoq trial\tHD(1,GPT)/\\EFI\\refind\\refind_x64.efi
        \\
    ;
    try std.testing.expectEqualStrings("0004", firmwareNumber(listing).?);
    try std.testing.expectEqual(null, firmwareNumber("BootOrder: 0001\n"));
}
