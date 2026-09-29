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
    try checks.append(a, .{
        .what = "pacman hook",
        .ok = hookInstalled(ctx),
        .found = if (hookInstalled(ctx)) "installed" else "missing",
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
    var ok = true;
    for (checks.items) |c| ok = ok and c.ok;
    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.doctor/1", .{ .ok = ok, .checks = checks.items });
    } else {
        try enable.writeChecks(ctx.out, checks.items);
        try ctx.out.writeAll(if (ok) "\nnothing to fix.\n" else "\nthe lines under each \"no\" say what to do.\n");
    }
    return if (ok) 0 else 1;
}

/// how many days old the lock's date is.
fn lockAge(ctx: *Context, a: Allocator, date: []const u8) !?i64 {
    const today = try locking.today(ctx.io, a);
    const then = status.epochDay(date) orelse return null;
    const now = status.epochDay(today) orelse return null;
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
    var d = std.Io.Dir.cwd().openDir(ctx.io, "/etc/sudoers.d", .{ .iterate = true }) catch null;
    if (d) |*dir| {
        defer dir.close(ctx.io);
        var it = dir.iterate();
        while (it.next(ctx.io) catch null) |e| try files.append(a, try std.fmt.allocPrint(a, "/etc/sudoers.d/{s}", .{e.name}));
    }
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

test "a sudoers rule without a password, and a commented one" {
    try std.testing.expect(hasNoPasswd("root ALL=(ALL:ALL) ALL\nkacy ALL=(ALL) NOPASSWD: ALL\n"));
    try std.testing.expect(!hasNoPasswd("root ALL=(ALL:ALL) ALL\n# %wheel ALL=(ALL:ALL) NOPASSWD: ALL\n"));
}
