//! `os doctor`: how os is set up on this machine, as checks with what to
//! do about each one that fails. it changes nothing.

const std = @import("std");
const rootfs = @import("../rootfs.zig");
const cli = @import("../cli.zig");
const enable = @import("../enable.zig");
const exec = @import("../exec.zig");
const generation = @import("../generation.zig");
const journal = @import("../journal.zig");
const output = @import("../output.zig");
const status = @import("../status.zig");
const locking = @import("lock.zig");
const facts = @import("../facts.zig");
const secureboot = @import("../secureboot.zig");
const Context = cli.Context;
const Allocator = std.mem.Allocator;

/// the least room an esp should have for the next kernel and initramfs.
const esp_room: u64 = 200 << 20;

pub fn doctorCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (try cli.noArgs(ctx, args, "os doctor")) |code| return code;
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    var checks: std.ArrayList(enable.Check) = .empty;

    const loaded = try w.config();
    try checks.append(a, .{
        .what = "config",
        .ok = loaded != null,
        .found = ctx.config_path,
        .fix = "it doesn't load. `os plan` says what's wrong, and where.",
    });
    const dir = std.fs.path.dirnamePosix(ctx.config_path) orelse "/";
    try checks.append(a, .{
        .what = "config history",
        .ok = try exec.run(a, ctx.io, &.{ "git", "-C", dir, "rev-parse", "--git-dir" }) == null,
        .found = dir,
        .fix = "it isn't a git repository, so changes aren't recorded. `os init` makes one, or `git init` there.",
    });
    if (loaded != null) {
        const l = try locking.readLock(ctx, a, ctx.config_path);
        const age = if (l) |lk| try lockAge(ctx, a, lk.sync_date) else null;
        try checks.append(a, .{
            .what = "lock",
            .ok = age != null and age.? <= status.stale_days,
            .found = if (l) |lk| try std.fmt.allocPrint(a, "from {s}", .{lk.sync_date}) else "missing",
            .fix = if (l == null) "there's no machine.lock beside the config. `os update` makes one." else "it's over two weeks old, so it's missing security fixes. `os update` moves it to today.",
        });
    }
    const hook = hookInstalled(ctx);
    try checks.append(a, .{
        .what = "pacman hook",
        .ok = hook,
        .found = if (hook) "installed" else "missing",
        .fix = "without yoq-drift.hook, changes made with pacman directly go unnoticed. installing the yoq-os package puts it in place.",
    });
    const unfinished = try journal.unfinished(a, ctx.io, ctx.root);
    try checks.append(a, .{
        .what = "last apply",
        .ok = unfinished == null,
        .found = if (unfinished == null) "finished" else "didn't finish",
        .fix = "it stopped partway. `os apply` starts again from the machine as it is.",
    });
    if (cli.eql(ctx.root, "/")) {
        const f = try w.facts() orelse return w.fail();
        const b = f.boot;
        if (generation.running(b.root_subvol)) {
            try checks.append(a, .{
                .what = "boot menu",
                .ok = b.menu_missing == null,
                .found = b.menu_missing orelse "has os's generations",
                .fix = "another tool rewrote it without os's generations. `os gc` writes them again.",
            });
            var missing: std.ArrayList([]const u8) = .empty;
            for (try enable.units(a, "")) |u| {
                if (!rootfs.pathExists(ctx.io, try std.fs.path.join(a, &.{ "/etc/systemd/system", u.name }))) try missing.append(a, u.name);
            }
            try checks.append(a, .{
                .what = "units",
                .ok = missing.items.len == 0,
                .found = if (missing.items.len == 0) "all in place" else try std.mem.join(a, ", ", missing.items),
                .fix = "trial boots need these. `os uninstall` then `os enable-rollback` puts them back, or copy them from an older generation.",
            });
        }
        if (try enable.luksCheck(a, &b)) |c| try checks.append(a, c);
        if (b.luks_uuid) |uuid| {
            const device = b.luks_device orelse try std.fmt.allocPrint(a, "/dev/disk/by-uuid/{s}", .{uuid});
            // the header needs root to read; the command line doesn't.
            const dump = switch (try exec.output(a, ctx.io, &.{ "cryptsetup", "luksDump", "--dump-json-metadata", device })) {
                .ok => |t| t,
                .failed => null,
            };
            const tpm = try tpmToken(a, dump) orelse cmdlineTpm(try rootfs.readProc(a, ctx.io, "/proc/cmdline"));
            if (tpmCheck(&b, tpm)) |c| try checks.append(a, c);
        }
        const wants = if (loaded) |l| if (l.config.boot.secure_boot) |v| v.v else false else false;
        if (wants or (b.secure_boot orelse false)) {
            try secureBootChecks(a, &b, wants, rootfs.pathExists(ctx.io, "/usr/bin/sbctl"), &checks);
        }
        if (b.esp) |esp| {
            const room = try freeBytes(ctx, a, esp);
            try checks.append(a, .{
                .what = "esp space",
                .ok = room == null or room.? >= esp_room,
                .found = if (room) |r| try std.fmt.allocPrint(a, "{d} MiB free on {s}", .{ r >> 20, esp }) else esp,
                .fix = "a new kernel and initramfs may not fit. `os gc --keep 2` removes older generations and their copies there.",
            });
        }
        if (try passwordlessSudo(ctx, a)) |where| try checks.append(a, .{
            .what = "sudo",
            .ok = false,
            .found = try std.fmt.allocPrint(a, "passwordless in {s}", .{where}),
            .fix = "anything running as that user can change the machine without asking anyone. take out NOPASSWD unless that's what you want.",
        });
    }
    const ok = enable.allOk(checks.items);
    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.doctor/1", .{ .ok = ok, .checks = checks.items });
    } else {
        try enable.writeChecks(ctx.out, checks.items);
        const end = if (!ok) "\nthe lines under each \"no\" say what to do.\n" else if (enable.anyWarning(checks.items)) "\nnothing to fix, but read the lines under each \"warn\".\n" else "\nnothing to fix.\n";
        try ctx.out.writeAll(end);
    }
    return if (ok) 0 else 1;
}

/// whether a luks2 header, as `cryptsetup luksDump --dump-json-metadata`
/// prints it, has a key the tpm unlocks: a systemd-tpm2 token, as
/// systemd-cryptenroll leaves. null when there's no header to go by.
fn tpmToken(a: Allocator, dump: ?[]const u8) !?bool {
    const text = dump orelse return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return null,
    };
    if (v != .object) return null;
    const tokens = v.object.get("tokens") orelse return false;
    if (tokens != .object) return false;
    for (tokens.object.values()) |t| {
        if (t != .object) continue;
        const kind = t.object.get("type") orelse continue;
        if (kind == .string and std.mem.eql(u8, kind.string, "systemd-tpm2")) return true;
    }
    return false;
}

/// whether the kernel command line has the initramfs try the tpm, as
/// `os install --tpm` sets it up: rd.luks.options with tpm2-device.
fn cmdlineTpm(cmdline: []const u8) bool {
    var words: generation.Words = .{ .text = cmdline };
    while (words.next()) |w| {
        if (std.mem.startsWith(u8, w, "rd.luks.options=") and std.mem.indexOf(u8, w, "tpm2-device") != null) return true;
    }
    return false;
}

/// with the root unlocked by the tpm, whether secure boot keeps the boot
/// files that get the key from being changed. without it, it's a warning:
/// the tpm keeps a powered-off disk safe, not a machine left alone.
fn tpmCheck(b: *const facts.Boot, tpm: bool) ?enable.Check {
    if (!tpm) return null;
    const on = b.secure_boot orelse false;
    return .{
        .what = "tpm unlock",
        .ok = on,
        .warn = true,
        .found = if (on) "the tpm unlocks the root, and secure boot is on" else "the tpm unlocks the root, and secure boot is off",
        .fix = "without secure boot, someone who can change the boot files can get a shell with the disk unlocked, so the tpm protects a powered-off disk, not a machine left alone. turn on uki and secure_boot under [boot] to close that.",
    };
}

/// what secure boot needs: sbctl, its keys, firmware that enforces it,
/// and signatures on every efi binary on the esp. `wants` is the
/// config's `[boot] secure_boot`; without it, the firmware's state is
/// only shown.
fn secureBootChecks(a: Allocator, b: *const facts.Boot, wants: bool, sbctl: bool, checks: *std.ArrayList(enable.Check)) !void {
    try checks.append(a, .{
        .what = "sbctl",
        .ok = sbctl,
        .found = if (sbctl) "installed" else "missing",
        .fix = "it makes, enrolls, and signs with the keys. `pacman -S sbctl` to make keys before the first apply; with secure_boot on, os installs it too.",
    });
    try checks.append(a, .{
        .what = "secure boot keys",
        .ok = b.sbctl_keys,
        .found = if (b.sbctl_keys) secureboot.keys_dir else "none",
        .fix = "`sbctl create-keys` makes them in " ++ secureboot.keys_dir ++ ". os never makes or enrolls keys itself.",
    });
    const on = b.secure_boot orelse false;
    try checks.append(a, .{
        .what = "firmware secure boot",
        .ok = on or !wants,
        .found = secureboot.describe(b.secure_boot, b.setup_mode),
        .fix = if (b.setup_mode orelse false)
            "the firmware takes new keys now. once `os doctor` finds nothing unsigned, `sbctl enroll-keys -m` enrolls sbctl's keys and microsoft's, and the next boot enforces them."
        else
            "in the firmware's setup, clear its secure boot keys (setup mode), boot, and run `sbctl enroll-keys -m`; then turn secure boot on there.",
    });
    const mine = if (b.esp) |esp| try secureboot.ours(a, b.unsigned, esp) else &.{};
    try checks.append(a, .{
        .what = "esp signatures",
        .ok = b.unsigned.len == 0,
        .found = if (b.unsigned.len == 0) "every efi file is signed" else try std.fmt.allocPrint(a, "unsigned: {s}", .{try std.mem.join(a, ", ", b.unsigned)}),
        .fix = if (mine.len == b.unsigned.len)
            "os signs its images in yoq/boot when it writes the boot menu; `os gc` writes it now."
        else
            "os signs its own images in yoq/boot when it writes the boot menu (`os gc` writes it now). sign the bootloader's files with `sbctl sign -s <file>`, which signs them again whenever their package updates them.",
    });
}

/// how many days old the lock's date is.
fn lockAge(ctx: *Context, a: Allocator, date: []const u8) !?i64 {
    const then = status.epochDay(date) orelse return null;
    const now = status.epochDay(try locking.today(ctx.io, a)) orelse return null;
    return now - then;
}

fn hookInstalled(ctx: *Context) bool {
    for ([_][]const u8{ "/usr/share/libalpm/hooks/yoq-drift.hook", "/etc/pacman.d/hooks/yoq-drift.hook" }) |p| {
        if (rootfs.pathExists(ctx.io, p)) return true;
    }
    return false;
}

/// bytes free on the filesystem at `path`, or null if df can't say.
fn freeBytes(ctx: *Context, a: Allocator, path: []const u8) !?u64 {
    const text = switch (try exec.output(a, ctx.io, &.{ "df", "--output=avail", "-B1", path })) {
        .ok => |t| t,
        .failed => return null,
    };
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    _ = lines.next();
    return std.fmt.parseInt(u64, std.mem.trim(u8, lines.next() orelse return null, " "), 10) catch null;
}

/// the sudoers file with a NOPASSWD rule in it, if there is one. files
/// os can't read are left out.
fn passwordlessSudo(ctx: *Context, a: Allocator) !?[]const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    try files.append(a, "/etc/sudoers");
    if (std.Io.Dir.cwd().openDir(ctx.io, "/etc/sudoers.d", .{ .iterate = true })) |dir| {
        defer dir.close(ctx.io);
        var it = dir.iterate();
        while (it.next(ctx.io) catch null) |e| try files.append(a, try std.fmt.allocPrint(a, "/etc/sudoers.d/{s}", .{e.name}));
    } else |_| {}
    for (files.items) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(1 << 20)) catch continue;
        if (hasNoPasswd(text)) return path;
    }
    return null;
}

fn hasNoPasswd(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (t.len == 0 or t[0] == '#') continue;
        if (std.mem.indexOf(u8, t, "NOPASSWD") != null) return true;
    }
    return false;
}

test "secure boot checks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var checks: std.ArrayList(enable.Check) = .empty;
    var b: facts.Boot = .{ .esp = "/boot", .secure_boot = false, .setup_mode = true, .unsigned = &.{ "/boot/EFI/systemd/systemd-bootx64.efi", "/boot/yoq/boot/0123456789abcdef-yoq.efi" } };
    try secureBootChecks(a, &b, true, false, &checks);
    try std.testing.expectEqual(4, checks.items.len);
    for (checks.items) |c| try std.testing.expect(!c.ok);
    try std.testing.expectEqualStrings("off, in setup mode", checks.items[2].found);
    try std.testing.expect(std.mem.indexOf(u8, checks.items[2].fix.?, "sbctl enroll-keys -m") != null);
    try std.testing.expectEqualStrings("unsigned: /boot/EFI/systemd/systemd-bootx64.efi, /boot/yoq/boot/0123456789abcdef-yoq.efi", checks.items[3].found);
    try std.testing.expect(std.mem.indexOf(u8, checks.items[3].fix.?, "sbctl sign -s") != null);

    b = .{ .esp = "/boot", .secure_boot = true, .setup_mode = false, .sbctl_keys = true };
    checks.clearRetainingCapacity();
    try secureBootChecks(a, &b, true, true, &checks);
    for (checks.items) |c| try std.testing.expect(c.ok);
    try std.testing.expectEqualStrings("on", checks.items[2].found);

    // with secure boot off and not asked for, the firmware is only shown.
    b = .{ .secure_boot = false, .setup_mode = false, .sbctl_keys = true };
    checks.clearRetainingCapacity();
    try secureBootChecks(a, &b, false, true, &checks);
    try std.testing.expect(checks.items[2].ok);
}

test "a root the tpm unlocks without secure boot is a warning" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // systemd-cryptenroll's token, beside a passphrase's keyslot.
    const enrolled =
        \\{"keyslots":{"0":{"type":"luks2"},"1":{"type":"luks2"}},
        \\ "tokens":{"0":{"type":"systemd-tpm2","keyslots":["1"],"tpm2-pcrs":[7]}},
        \\ "segments":{},"digests":{},"config":{}}
    ;
    try std.testing.expectEqual(true, try tpmToken(a, enrolled));
    try std.testing.expectEqual(false, try tpmToken(a, "{\"keyslots\":{\"0\":{\"type\":\"luks2\"}},\"tokens\":{}}"));
    try std.testing.expectEqual(false, try tpmToken(a, "{\"tokens\":{\"0\":{\"type\":\"systemd-fido2\"}}}"));
    try std.testing.expectEqual(false, try tpmToken(a, "{\"keyslots\":{}}"));
    // no header to read, as without root: the command line decides.
    try std.testing.expectEqual(null, try tpmToken(a, null));
    try std.testing.expectEqual(null, try tpmToken(a, "not json"));
    try std.testing.expect(cmdlineTpm("root=UUID=b rootflags=subvol=/@roots/1 rw rd.luks.name=u=root rd.luks.options=tpm2-device=auto panic=10"));
    try std.testing.expect(cmdlineTpm("rd.luks.options=0f7a1c2e=tpm2-device=auto,discard"));
    try std.testing.expect(!cmdlineTpm("root=UUID=b rw rd.luks.name=u=root"));
    try std.testing.expect(!cmdlineTpm(""));

    var b: facts.Boot = .{ .luks_uuid = "u", .secure_boot = false };
    const c = tpmCheck(&b, true).?;
    try std.testing.expect(!c.ok and c.warn);
    try std.testing.expectEqualStrings("the tpm unlocks the root, and secure boot is off", c.found);
    // a warning stops nothing.
    try std.testing.expect(enable.allOk(&.{c}));
    try std.testing.expect(enable.anyWarning(&.{c}));
    var out: std.Io.Writer.Allocating = .init(a);
    try enable.writeChecks(&out.writer, &.{c});
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "checks\nwarn  tpm unlock: the tpm unlocks the root, and secure boot is off\n        without secure boot, "));
    b.secure_boot = null;
    try std.testing.expect(!tpmCheck(&b, true).?.ok);
    b.secure_boot = true;
    try std.testing.expect(tpmCheck(&b, true).?.ok);
    try std.testing.expectEqual(null, tpmCheck(&b, false));
}

test "a sudoers rule without a password, and a commented one" {
    try std.testing.expect(hasNoPasswd("root ALL=(ALL:ALL) ALL\nkacy ALL=(ALL) NOPASSWD: ALL\n"));
    try std.testing.expect(!hasNoPasswd("root ALL=(ALL:ALL) ALL\n# %wheel ALL=(ALL:ALL) NOPASSWD: ALL\n"));
}
