//! `os uninstall`: leaves plain arch on the running generation. it shows
//! the checks and the steps, asks, and carries them out in order. every
//! step is safe to run twice, so after a failure, running it again
//! finishes the job.

const std = @import("std");
const rootfs = @import("../rootfs.zig");
const cli = @import("../cli.zig");
const enable = @import("../enable.zig");
const exec = @import("../exec.zig");
const facts = @import("../facts.zig");
const generation = @import("../generation.zig");
const gens = @import("../gens.zig");
const menu = @import("../menu.zig");
const output = @import("../output.zig");
const uninstall = @import("../uninstall.zig");
const trial = @import("../trial.zig");
const applying = @import("apply.zig");
const Context = cli.Context;
const Allocator = std.mem.Allocator;

const usage_text = "os uninstall [--yes] [--delete-generations]";

pub fn uninstallCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    var yes = false;
    var drop = false;
    var it: cli.ArgIter = .{ .args = args };
    while (it.next()) |arg| {
        if (!it.isFlag(arg)) {
            return cli.usageError(ctx, usage_text);
        } else if (cli.isYes(arg)) {
            yes = true;
        } else if (cli.eql(arg, "--delete-generations")) {
            drop = true;
        } else return cli.usageError(ctx, usage_text);
    }
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const f = try w.facts() orelse return w.fail();
    const running = generation.running(f.boot.root_subvol);
    var p = try uninstall.plan(a, &f, drop);
    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.uninstall/1", .{ .ready = p.ready(), .checks = p.checks, .steps = p.steps });
        return if (p.ready()) 0 else 1;
    }
    try uninstall.writeText(ctx.out, &p);
    if (!p.ready()) {
        try ctx.out.writeAll("\nos can't leave this machine until the checks above pass.\n");
        return 1;
    }
    if (try cli.needsHost(ctx, "uninstall changes the running machine")) return 1;
    if (try cli.refused(ctx, applying.bootBlocker(ctx.io))) return 1;
    if (try cli.approve(ctx, yes, "uninstall", "uninstall?")) |code| return code;
    // asked apart, since keeping them is the safe answer.
    if (running and !drop and !yes and try cli.confirm(ctx, "delete every generation but this one too? otherwise they stay as btrfs subvolumes.")) {
        p = try uninstall.plan(a, &f, true);
    }
    try ctx.out.writeByte('\n');
    var u: Uninstaller = .{ .ctx = ctx, .a = a, .boot = f.boot, .package = uninstall.ownPackage(&f) };
    if (running) u.m = try cli.openMachine(ctx, a, f.boot) orelse return 1;
    defer if (u.m) |*m| m.close();
    for (p.steps) |s| {
        try ctx.out.print("  {s}\n", .{s.what});
        try ctx.out.flush();
        if (try u.step(s.kind)) |why| return cli.fail(ctx, "{s}\nos: the steps above are done; `os uninstall` again finishes the rest.", .{why});
    }
    try ctx.out.writeAll("\nos is off this machine, and the config stays in /etc/yoq.\n");
    return 0;
}

const Uninstaller = struct {
    ctx: *Context,
    a: Allocator,
    boot: facts.Boot,
    package: ?[]const u8 = null,
    /// the btrfs top level, on the rollback rung.
    m: ?gens.Machine = null,

    fn step(u: *Uninstaller, kind: uninstall.Kind) !?[]const u8 {
        return switch (kind) {
            .config_dir => u.configDir(),
            .units => u.units(),
            .pacman_db => u.pacmanDb(),
            .boot_menu => u.bootMenu(),
            .snap_pac => u.snapPac(),
            .generations => u.generations(),
            .package => u.run(&.{ "pacman", "-R", "--noconfirm", u.package.? }),
            .state => u.state(),
        };
    }

    fn run(u: *Uninstaller, argv: []const []const u8) !?[]const u8 {
        return exec.run(u.a, u.ctx.io, argv);
    }

    fn exists(u: *Uninstaller, path: []const u8) bool {
        return rootfs.pathExists(u.ctx.io, path);
    }

    /// the running root, under the top level: what's under its mounts.
    fn root(u: *Uninstaller, rel: []const u8) ![]const u8 {
        const m = &u.m.?;
        return m.at(&.{ u.boot.root_subvol.?, rel });
    }

    /// the config goes into the running root's own /etc/yoq, under the
    /// bind mount, which then goes, so /etc/yoq is that directory.
    fn configDir(u: *Uninstaller) !?[]const u8 {
        const home = enable.config_home;
        if (u.exists(home)) {
            const dest = try u.root("etc/yoq");
            if (try u.run(&.{ "mkdir", "-p", dest })) |w| return w;
            if (try u.run(&.{ "cp", "-a", "--reflink=auto", home ++ "/.", dest })) |w| return w;
        }
        _ = try u.run(&.{ "umount", "/etc/yoq" });
        const text = std.Io.Dir.cwd().readFileAlloc(u.ctx.io, "/etc/fstab", u.a, .limited(1 << 20)) catch return "can't read /etc/fstab";
        var out: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, home ++ " /etc/yoq ")) continue;
            try out.print(u.a, "{s}\n", .{line});
        }
        rootfs.writeAtomic(u.ctx.io, "/etc/fstab", out.items, null) catch return "can't write /etc/fstab";
        return null;
    }

    fn units(u: *Uninstaller) !?[]const u8 {
        for (try enable.units(u.a, "")) |unit| {
            const link = try unit.wantsLink(u.a) orelse unit.name;
            for ([_][]const u8{ link, unit.name }) |rel| {
                if (try u.run(&.{ "rm", "-f", try std.fs.path.join(u.a, &.{ "/etc/systemd/system", rel }) })) |w| return w;
            }
        }
        return u.run(&.{ "systemctl", "daemon-reload" });
    }

    /// the database goes back to /var, in place of the symlink to it.
    fn pacmanDb(u: *Uninstaller) !?[]const u8 {
        const moved = "/" ++ generation.pacman_db;
        const db = "/var/lib/pacman";
        const fresh = db ++ ".yoq-new";
        if (!u.exists(moved)) return null;
        // a run that stopped after the move left a real directory at db;
        // mv would put the copy inside it.
        const st = std.Io.Dir.cwd().statFile(u.ctx.io, db, .{ .follow_symlinks = false }) catch null;
        if (st != null and st.?.kind == .directory) return u.run(&.{ "rm", "-rf", moved });
        return exec.runAll(u.a, u.ctx.io, &.{
            &.{ "rm", "-rf", fresh },
            &.{ "cp", "-a", "--reflink=auto", moved, fresh },
            &.{ "rm", "-f", db },
            &.{ "mv", fresh, db },
            &.{ "rm", "-rf", moved },
        });
    }

    fn bootMenu(u: *Uninstaller) !?[]const u8 {
        const m = &u.m.?;
        const esp = u.boot.esp.?;
        // plain arch boots the kernel on the esp, so a root still booting
        // its own puts it there first.
        const running = u.boot.root_subvol.?;
        if (m.unsettled(running)) {
            if ((try m.restoreBoot(running)).problem()) |w| return w;
        }
        switch (m.loader) {
            // grub reads its menu from /boot again, the way arch sets it up,
            // and grub-mkconfig names this root's subvolume.
            .grub => {
                // grub-mkconfig's entries take their arguments from grub's
                // defaults, which may lack what unlocks a luks root: os
                // passed it in its own entries, as after `os install
                // --encrypt`.
                const defaults = "/etc/default/grub";
                if (std.Io.Dir.cwd().readFileAlloc(u.ctx.io, defaults, u.a, .limited(1 << 20))) |text| {
                    if (try uninstall.grubDefaults(u.a, text, try rootfs.readProc(u.a, u.ctx.io, "/proc/cmdline"))) |more| {
                        rootfs.writeAtomic(u.ctx.io, defaults, more, null) catch return "can't write " ++ defaults;
                    }
                } else |_| {}
                if (try u.run(try gens.grubInstall(u.a, u.ctx.io, esp, "/boot"))) |w| return w;
                if (try u.run(&.{ "grub-mkconfig", "-o", "/boot/grub/grub.cfg" })) |w| return w;
                if (!std.mem.eql(u8, esp, "/boot")) return u.run(&.{ "rm", "-rf", try std.fs.path.join(u.a, &.{ esp, "grub" }) });
                return null;
            },
            .limine => {
                const conf_path = u.boot.loader_conf orelse return "can't find limine.conf";
                const conf = std.Io.Dir.cwd().readFileAlloc(u.ctx.io, conf_path, u.a, .limited(1 << 20)) catch return "can't read limine.conf";
                // an earlier run may have replaced os's section already.
                if (std.mem.indexOf(u8, conf, menu.limine_begin) != null) {
                    const text = try menu.spliceLimine(u.a, conf, try menu.limineOne(u.a, try u.plainEntry()));
                    rootfs.writeAtomic(u.ctx.io, conf_path, text, null) catch return "can't write limine.conf";
                }
                // no one-shot or default left behind: the first entry boots.
                const store = trial.Store.of(u.a, u.ctx.io, u.boot) orelse return null;
                return store.end();
            },
            .@"systemd-boot" => {
                const dir = try m.sdbootEntries();
                const text = try menu.sdbootEntry(u.a, try u.plainEntry(), "arch", 1);
                rootfs.writeAtomic(u.ctx.io, try std.fs.path.join(u.a, &.{ dir, "arch-linux.conf" }), text, null) catch return "can't write arch-linux.conf";
                if (try exec.runAll(u.a, u.ctx.io, &.{
                    &.{ "bootctl", "set-oneshot", "" },
                    &.{ "bootctl", "set-default", "arch-linux.conf" },
                })) |w| return w;
                var d = std.Io.Dir.cwd().openDir(u.ctx.io, dir, .{ .iterate = true }) catch return null;
                defer d.close(u.ctx.io);
                var it = d.iterate();
                while (it.next(u.ctx.io) catch null) |f| {
                    if (std.mem.startsWith(u8, f.name, "yoq-")) d.deleteFile(u.ctx.io, f.name) catch {};
                }
                return null;
            },
            .refind => {
                const conf_path = u.boot.loader_conf orelse return "can't find refind.conf";
                const conf = std.Io.Dir.cwd().readFileAlloc(u.ctx.io, conf_path, u.a, .limited(1 << 20)) catch return "can't read refind.conf";
                const plain = try u.plainEntry();
                if (try menu.refindArgsProblem(u.a, plain.args)) |w| return w;
                const text = try menu.refindLinux(u.a, plain);
                rootfs.writeAtomic(u.ctx.io, try std.fs.path.join(u.a, &.{ esp, "refind_linux.conf" }), text, null) catch return "can't write refind_linux.conf";
                rootfs.writeAtomic(u.ctx.io, conf_path, try menu.unspliceRefind(u.a, conf), null) catch return "can't write refind.conf";
                const dir = std.fs.path.dirnamePosix(conf_path).?;
                // a trial waiting: its firmware entry and copy of refind go.
                if (trial.Store.of(u.a, u.ctx.io, u.boot)) |store| _ = try store.end();
                return u.run(&.{ "rm", "-f", try std.fs.path.join(u.a, &.{ dir, "yoq.conf" }) });
            },
        }
    }

    /// the running root's entry, with its kernel on the esp's top, where
    /// arch installs it when the esp is /boot.
    fn plainEntry(u: *Uninstaller) !menu.Entry {
        const cmdline = try rootfs.readProc(u.a, u.ctx.io, "/proc/cmdline");
        var e = try u.m.?.entry("head", "Arch Linux", u.boot.root_subvol.?, cmdline);
        e.esp_dir = "";
        return e;
    }

    fn snapPac(u: *Uninstaller) !?[]const u8 {
        const path = "/etc/snap-pac.ini";
        const text = std.Io.Dir.cwd().readFileAlloc(u.ctx.io, path, u.a, .limited(1 << 16)) catch return null;
        const on = try enable.snapPacOn(u.a, text) orelse return u.run(&.{ "rm", "-f", path });
        rootfs.writeAtomic(u.ctx.io, path, on, null) catch return "can't write " ++ path;
        return null;
    }

    /// every generation's record, and every root but the running one.
    fn generations(u: *Uninstaller) !?[]const u8 {
        const m = &u.m.?;
        const keep = u.boot.root_subvol.?[1..];
        for ([_][]const u8{ generation.gens_dir, generation.roots_dir }) |d| {
            var dir = std.Io.Dir.cwd().openDir(u.ctx.io, try m.at(&.{d}), .{ .iterate = true }) catch continue;
            defer dir.close(u.ctx.io);
            var names: std.ArrayList([]const u8) = .empty;
            var it = dir.iterate();
            while (it.next(u.ctx.io) catch null) |e| try names.append(u.a, try std.fmt.allocPrint(u.a, "{s}/{s}", .{ d, e.name }));
            for (names.items) |n| {
                if (std.mem.eql(u8, n, keep)) continue;
                if (try m.drop(try m.at(&.{n}))) |w| return w;
            }
        }
        // @gens is empty now; @roots still holds the running root.
        std.Io.Dir.cwd().deleteDir(u.ctx.io, try m.at(&.{generation.gens_dir})) catch {};
        return null;
    }

    /// os's state in /var, and on the esp its env file and limine's
    /// copies of boot files. with the esp at /boot, the running root's
    /// copies of its own boot files go too.
    fn state(u: *Uninstaller) !?[]const u8 {
        if (try u.run(&.{ "rm", "-rf", "/var/lib/yoq" })) |w| return w;
        const esp = u.boot.esp orelse return null;
        if (try u.run(&.{ "rm", "-rf", try std.fs.path.join(u.a, &.{ esp, "yoq" }) })) |w| return w;
        const m = &(u.m orelse return null);
        if (!m.bootOnEsp()) return null;
        return u.run(&.{ "find", try u.root("boot"), "-maxdepth", "1", "-type", "f", "-delete" });
    }
};
