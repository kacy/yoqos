//! a generation on trial: the next boot tries it once, the default stays
//! on the generation before, and `os health` ends the trial one way or the
//! other. grub reads these choices from an env file on the esp, since it
//! can write fat but not btrfs. limine and systemd-boot read them from
//! efi variables, which bootctl sets, and os keeps the trial itself in
//! /var. refind has no one-shot boot, so the firmware's own, BootNext,
//! starts it with a config of os's.

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
        switch (s.loader) {
            .grub => {},
            .limine, .@"systemd-boot", .refind => {
                const words = try s.state() orelse return null;
                return .{
                    .n = std.fmt.parseInt(u32, words[0], 10) catch return null,
                    .fallback = std.fmt.parseInt(u32, words[1], 10) catch 0,
                    // the bootloader, or for refind the firmware, clears
                    // the one-shot variable when it reads it.
                    .tried = !rootfs.pathExists(s.io, if (s.loader == .refind) bootnext_var else oneshot_var),
                };
            },
        }
        const n = try s.number("yoq_trial") orelse return null;
        return .{
            .n = n,
            .fallback = try s.number("yoq_default") orelse 0,
            .tried = try s.value("yoq_tried") != null,
        };
    }

    /// makes the next boot try the newest generation, `n`, once, and
    /// fall back to `fallback` if it doesn't come up.
    pub fn arm(s: Store, n: u32, fallback: generation.Record) !?[]const u8 {
        switch (s.loader) {
            .grub => {
                _ = try s.edit("unset", &.{"yoq_tried"});
                return s.edit("set", &.{
                    "yoq_next=head",
                    try std.fmt.allocPrint(s.a, "yoq_default=gen-{d}", .{fallback.n}),
                    try std.fmt.allocPrint(s.a, "yoq_trial={d}", .{n}),
                });
            },
            .limine, .@"systemd-boot" => {
                // the one-shot first, and the note of the trial last: a
                // fallback default or a note without a one-shot would make
                // the next boot look like a failed trial.
                const id = if (s.loader == .limine)
                    try menu.limineId(s.a, try generation.title(s.a, fallback))
                else
                    try menu.sdbootName(s.a, try std.fmt.allocPrint(s.a, "gen-{d}", .{fallback.n}));
                const why = try s.retry() orelse
                    try s.bootctl("set-default", id) orelse
                    blk: {
                        const note = try std.fmt.allocPrint(s.a, "{d} {d}\n", .{ n, fallback.n });
                        rootfs.writeAtomic(s.io, state_path, note, null) catch break :blk try std.fmt.allocPrint(s.a, "can't write {s}", .{state_path});
                        break :blk null;
                    } orelse return null;
                _ = try s.end();
                return why;
            },
            .refind => {
                const why = try s.armRefind(n, fallback) orelse return null;
                _ = try s.end();
                return why;
            },
        }
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
        const yoq_path = try std.fs.path.join(s.a, &.{ dir, "yoq.conf" });
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
        const trial_conf = try std.fs.path.join(s.a, &.{ trial_dir, "refind.conf" });
        rootfs.writeAtomic(s.io, trial_conf, try menu.refindTrialConf(s.a, main, yoq), null) catch return try std.fmt.allocPrint(s.a, "can't write {s}", .{trial_conf});
        const entry = try s.firmwareEntry(trial_dir, binary) orelse return "can't add a boot entry for the trial";
        if (try exec.run(s.a, s.io, &.{ "efibootmgr", "-q", "-n", entry })) |w| return w;
        rootfs.writeAtomic(s.io, yoq_path, try menu.refindDefault(s.a, yoq, try generation.title(s.a, fallback)), null) catch return try std.fmt.allocPrint(s.a, "can't write {s}", .{yoq_path});
        const note = try std.fmt.allocPrint(s.a, "{d} {d} {s}\n", .{ n, fallback.n, entry });
        rootfs.writeAtomic(s.io, state_path, note, null) catch return try std.fmt.allocPrint(s.a, "can't write {s}", .{state_path});
        return null;
    }

    /// where a trial's copy of refind lives, on the esp.
    fn refindTrialDir(s: Store) ![]const u8 {
        return std.fs.path.join(s.a, &.{ s.esp, "EFI", menu.refind_trial_dir });
    }

    /// makes the firmware entry that starts `binary` in `dir`, without
    /// changing the boot order, and returns its number, like "0004".
    fn firmwareEntry(s: Store, dir: []const u8, binary: []const u8) !?[]const u8 {
        const device = s.esp_device orelse return null;
        const disk = switch (try exec.output(s.a, s.io, &.{ "lsblk", "-no", "PKNAME", device })) {
            .ok => |t| std.mem.trim(u8, t, " \n"),
            .failed => return null,
        };
        const part = switch (try exec.output(s.a, s.io, &.{ "lsblk", "-no", "PARTN", device })) {
            .ok => |t| std.mem.trim(u8, t, " \n"),
            .failed => return null,
        };
        // as the firmware names it: \EFI\yoq-trial\refind_x64.efi.
        const loader = try std.fs.path.join(s.a, &.{ dir[s.esp.len..], binary });
        std.mem.replaceScalar(u8, loader, '/', '\\');
        const out = switch (try exec.output(s.a, s.io, &.{ "efibootmgr", "-C", "-d", try std.fmt.allocPrint(s.a, "/dev/{s}", .{disk}), "-p", part, "-l", loader, "-L", firmware_label })) {
            .ok => |t| t,
            .failed => return null,
        };
        return firmwareNumber(out);
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
            .grub => return s.edit("unset", &.{ "yoq_default", "yoq_trial", "yoq_tried" }),
            .limine, .@"systemd-boot" => {
                // empty removes the one-shot. limine's first entry is the
                // newest generation, so it needs no default; systemd-boot
                // is pointed at it, past loader.conf's own.
                if (try s.bootctl("set-oneshot", "")) |w| return w;
                if (try s.bootctl("set-default", if (s.loader == .limine) "" else try menu.sdbootName(s.a, "head"))) |w| return w;
                std.Io.Dir.cwd().deleteFile(s.io, state_path) catch {};
                return null;
            },
            .refind => {
                if (try s.state()) |words| {
                    if (words[2].len > 0) _ = try exec.run(s.a, s.io, &.{ "efibootmgr", "-q", "-b", words[2], "-B" });
                }
                _ = try exec.run(s.a, s.io, &.{ "rm", "-rf", try s.refindTrialDir() });
                if (s.conf) |conf| {
                    const dir = std.fs.path.dirnamePosix(conf).?;
                    const yoq_path = try std.fs.path.join(s.a, &.{ dir, "yoq.conf" });
                    const yoq = std.Io.Dir.cwd().readFileAlloc(s.io, yoq_path, s.a, .limited(1 << 20)) catch "";
                    if (menu.refindHead(yoq)) |head| {
                        rootfs.writeAtomic(s.io, yoq_path, try menu.refindDefault(s.a, yoq, head), null) catch return try std.fmt.allocPrint(s.a, "can't write {s}", .{yoq_path});
                    }
                }
                std.Io.Dir.cwd().deleteFile(s.io, state_path) catch {};
                return null;
            },
        }
    }

    /// the words of the trial's note: its generation, the one before it,
    /// and for refind, the firmware entry.
    fn state(s: Store) !?[3][]const u8 {
        const text = std.Io.Dir.cwd().readFileAlloc(s.io, state_path, s.a, .limited(128)) catch return null;
        var words = std.mem.tokenizeAny(u8, text, " \n");
        return .{ words.next() orelse return null, words.next() orelse "0", words.next() orelse "" };
    }

    fn bootctl(s: Store, verb: []const u8, id: []const u8) !?[]const u8 {
        return exec.run(s.a, s.io, &.{ "bootctl", verb, id });
    }

    /// where os keeps a trial on limine, systemd-boot, and refind: its
    /// generation, the one before it, and refind's firmware entry.
    const state_path = "/var/lib/yoq/trial";
    /// the variable limine boots once from, under the boot loader
    /// interface's vendor guid.
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
