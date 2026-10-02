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
};

/// where a machine keeps its trial.
pub const Store = struct {
    a: Allocator,
    io: std.Io,
    loader: menu.Loader,
    esp: []const u8,
    /// refind's config, and the esp's partition, for its trial boots.
    conf: ?[]const u8 = null,
    esp_device: ?[]const u8 = null,

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
        if (s.loader == .grub) return grubTrial(try s.state(), try s.number("yoq_trial"), try s.number("yoq_default"), try s.value("yoq_tried") != null);
        const words = try s.state() orelse return null;
        return .{
            .n = std.fmt.parseInt(u32, words[0], 10) catch return null,
            .fallback = std.fmt.parseInt(u32, words[1], 10) catch 0,
            // the bootloader, or for refind the firmware, clears the
            // one-shot variable when it reads it.
            .tried = !rootfs.pathExists(s.io, if (s.loader == .refind) bootnext_var else oneshot_var),
        };
    }

    /// makes the next boot try the newest generation, `n`, once, and
    /// fall back to `fallback` if it doesn't come up.
    pub fn arm(s: Store, n: u32, fallback: generation.Record) !?[]const u8 {
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

    /// the trial hasn't booted yet: the next boot tries it again.
    pub fn retry(s: Store) !?[]const u8 {
        return switch (s.loader) {
            .grub => s.edit("set", &.{"yoq_next=head"}),
            .limine => s.bootctl("set-oneshot", try menu.limineId(s.a, menu.trial_title)),
            .@"systemd-boot" => s.bootctl("set-oneshot", menu.sdboot_trial),
            .refind => {
                const words = try s.state() orelse return "no trial to try again";
                return exec.run(s.a, s.io, &.{ "efibootmgr", "-q", "-n", words[2] });
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

    /// the words of the trial's note: its generation, the one before it,
    /// and for refind, the firmware entry.
    fn state(s: Store) !?[3][]const u8 {
        const text = std.Io.Dir.cwd().readFileAlloc(s.io, state_path, s.a, .limited(128)) catch return null;
        var words = std.mem.tokenizeAny(u8, text, " \n");
        return .{ words.next() orelse return null, words.next() orelse "0", words.next() orelse "" };
    }

    fn write(s: Store, path: []const u8, text: []const u8) !?[]const u8 {
        rootfs.writeAtomic(s.io, path, text, null) catch return try std.fmt.allocPrint(s.a, "can't write {s}", .{path});
        return null;
    }

    fn bootctl(s: Store, verb: []const u8, id: []const u8) !?[]const u8 {
        return exec.run(s.a, s.io, &.{ "bootctl", verb, id });
    }

    /// where os keeps a trial: its generation, the one before it, and
    /// refind's firmware entry.
    const state_path = "/var/lib/yoq/trial";
    /// the variable limine and systemd-boot boot once from, under the
    /// boot loader interface's vendor guid.
    const oneshot_var = "/sys/firmware/efi/efivars/LoaderEntryOneShot-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f";
    /// the firmware's own one-shot boot, under the global uefi guid.
    const bootnext_var = "/sys/firmware/efi/efivars/BootNext-8be4df61-93ca-11d0-aa0d-00e098032b8c";

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
fn grubTrial(noted: ?[3][]const u8, env_trial: ?u32, env_default: ?u32, tried: bool) ?Trial {
    const words = noted orelse return .{ .n = env_trial orelse return null, .fallback = env_default orelse 0, .tried = tried, .noted = false };
    return .{
        .n = std.fmt.parseInt(u32, words[0], 10) catch return null,
        .fallback = std.fmt.parseInt(u32, words[1], 10) catch 0,
        .tried = tried,
    };
}

test "grub's trial is os's note of it, not the esp's" {
    const t = grubTrial(.{ "7", "6", "" }, 9, 2, true).?;
    try std.testing.expectEqual(7, t.n);
    try std.testing.expectEqual(6, t.fallback);
    try std.testing.expect(t.tried and t.noted);
    // one only the env file names can't make the machine fall back.
    const planted = grubTrial(null, 9, 2, true).?;
    try std.testing.expectEqual(9, planted.n);
    try std.testing.expect(!planted.noted);
    try std.testing.expectEqual(null, grubTrial(null, null, 2, true));
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
