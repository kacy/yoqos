//! `os enable-rollback`: moves a machine to the rollback rung. it shows
//! the checks and the steps, asks, and then builds generation 1 from one
//! snapshot of the running root, which becomes the root at the next boot.

const std = @import("std");
const lists = @import("../lists.zig");
const rootfs = @import("../rootfs.zig");
const cli = @import("../cli.zig");
const btrfs = @import("../btrfs.zig");
const enable = @import("../enable.zig");
const exec = @import("../exec.zig");
const facts = @import("../facts.zig");
const generation = @import("../generation.zig");
const gens = @import("../gens.zig");
const output = @import("../output.zig");
const applying = @import("apply.zig");
const Context = cli.Context;
const Allocator = std.mem.Allocator;

pub fn enableRollbackCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    var yes = false;
    for (args) |arg| {
        if (applying.isYes(arg)) yes = true else return cli.usageError(ctx, "os enable-rollback [--yes]");
    }
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const f = try w.facts() orelse return w.fail();
    const p = try enable.plan(a, &f);
    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.enable-rollback/1", .{ .ready = p.ready(), .running = p.running, .checks = p.checks, .steps = p.steps });
        return if (p.ready() or p.running != null) 0 else 1;
    }
    if (p.running) |root| {
        try ctx.out.print("generations are on: this machine runs {s}.\n", .{root});
        return 0;
    }
    try enable.writeText(ctx.out, &p);
    if (!p.ready()) {
        try ctx.out.writeAll("\nthis machine can't have generations until the checks above pass.\n");
        return 1;
    }
    if (try cli.needsHost(ctx, "enable-rollback changes the running machine's disk and boot menu")) return 1;
    if (try cli.approve(ctx, yes, "enable rollback", "enable rollback?")) |code| return code;
    try ctx.out.writeByte('\n');
    var e: Enabler = .{ .ctx = ctx, .a = a, .boot = f.boot, .time = std.Io.Timestamp.now(ctx.io, .real).toSeconds() };
    if (!try e.run(&p)) return 1;
    gens.blockHibernation(ctx.io);
    try ctx.out.writeAll("\ngeneration 1 is ready. reboot to start it; the boot menu also keeps the system as it is now.\n");
    return 0;
}

/// carries out the plan's steps, inside the btrfs top level.
const Enabler = struct {
    ctx: *Context,
    a: Allocator,
    boot: facts.Boot,
    time: i64,
    m: gens.Machine = undefined,
    /// where generation 1's /var is being built: the new subvolume, or the
    /// running /var if it's a subvolume already.
    var_dir: []const u8 = "/var",
    moved_var: bool = false,
    /// the data directories moved into subvolumes, for fstab.
    moved_data: std.ArrayList(generation.DataDir) = .empty,
    moved_config: bool = false,
    /// how to take back what the steps did, newest last.
    undo: std.ArrayList(Undo) = .empty,
    /// /etc/yoq's commit before it moves, for generation 1's record.
    config: ?generation.Config = null,

    fn run(e: *Enabler, p: *const enable.Plan) !bool {
        var why: []const u8 = "";
        const entries = try e.ctx.history.log(e.a, "/etc/yoq", &why) orelse &.{};
        if (entries.len > 0) e.config = .{ .dir = "/etc/yoq", .rev = entries[entries.len - 1].rev };
        e.m = try gens.Machine.open(e.a, e.ctx.io, e.boot, &why) orelse return e.failed("{s}", .{why});
        defer e.m.close();

        for (p.steps) |s| {
            try e.ctx.out.print("  {s}\n", .{s.what});
            try e.ctx.out.flush();
            const ok = switch (s.kind) {
                .snapshot => try e.snapshot(),
                .var_subvol => try e.moveVar(),
                .data_subvols => try e.moveData(),
                .pacman_db => try e.movePacmanDb(),
                .config_dir => try e.moveConfig(),
                .snapper => try e.stopSnapPac(),
                .boot_entry => try e.seal() and try e.bootEntry(),
                .boot_files => try e.bootFiles(),
            };
            if (!ok) {
                try e.takeBack();
                return false;
            }
        }
        return true;
    }

    /// what a step left that taking it back removes or puts back.
    const Undo = union(enum) {
        /// a subvolume it created, read-only or not.
        subvol: []const u8,
        /// a command that reverses it.
        run: []const []const u8,
    };

    /// runs `argv` if the steps are taken back.
    fn later(e: *Enabler, argv: []const []const u8) !void {
        try e.undo.append(e.a, .{ .run = try e.a.dupe([]const u8, argv) });
    }

    /// deletes the subvolume at `path` if the steps are taken back.
    fn laterDrop(e: *Enabler, path: []const u8) !void {
        try e.undo.append(e.a, .{ .subvol = path });
    }

    /// reverses every step done so far, newest first, and says whether
    /// the machine is back as it was.
    fn takeBack(e: *Enabler) !void {
        var clean = true;
        var i = e.undo.items.len;
        while (i > 0) {
            i -= 1;
            switch (e.undo.items[i]) {
                .subvol => |path| {
                    btrfs.setReadOnly(path, false) catch {};
                    btrfs.delete(path) catch |err| {
                        try e.ctx.err.print("os: couldn't remove {s}: {s}\n", .{ path, @errorName(err) });
                        clean = false;
                    };
                },
                .run => |argv| if (try exec.run(e.a, e.ctx.io, argv)) |why| {
                    try e.ctx.err.print("os: couldn't undo with {s}: {s}\n", .{ argv[0], why });
                    clean = false;
                },
            }
        }
        try e.ctx.err.writeAll(if (clean) "os: took back the steps above; the machine is as it was.\n" else "os: took back what it could; see the lines above.\n");
    }

    const new_root = "/" ++ generation.roots_dir ++ "/1";

    /// the running root's writable copy, @roots/1.
    fn snapshot(e: *Enabler) !bool {
        for ([_][]const u8{ generation.roots_dir, generation.gens_dir }) |d| {
            const dir = try e.m.at(&.{d});
            const had = rootfs.pathExists(e.ctx.io, dir);
            if (!try e.sh(&.{ "mkdir", "-p", dir })) return false;
            if (!had) try e.later(&.{ "rmdir", dir });
        }
        const root = try e.m.at(&.{new_root});
        if (!try e.tried(btrfs.snapshot(try e.m.at(&.{e.boot.root_subvol.?}), root, false), "snapshot the running root")) return false;
        try e.laterDrop(root);
        // with the esp at /boot, both roots in the menu keep the kernel
        // they boot with. the running root's /boot was an empty mount point.
        if (try e.m.keepBoot(new_root)) |why| return e.failed("{s}", .{why});
        if (e.m.bootOnEsp()) try e.later(&.{ "find", try e.m.at(&.{ e.boot.root_subvol.?, "boot" }), "-maxdepth", "1", "-type", "f", "-delete" });
        if (try e.m.keepBoot(e.boot.root_subvol.?)) |why| return e.failed("{s}", .{why});
        return true;
    }

    /// generation 1's /var becomes @var: its contents move there, and
    /// fstab mounts it.
    fn moveVar(e: *Enabler) !bool {
        if (!try e.moveInto("var", generation.var_subvol)) return false;
        e.var_dir = try e.m.at(&.{generation.var_subvol});
        e.moved_var = true;
        return true;
    }

    /// generation 1's /home, /root, /srv, and /usr/local, where they're
    /// inside the root, become subvolumes, and fstab mounts them.
    fn moveData(e: *Enabler) !bool {
        for (generation.data_dirs) |d| {
            if (lists.contains(e.boot.data_apart, d.dir)) continue;
            if (!try e.moveInto(d.dir, d.subvol)) return false;
            try e.moved_data.append(e.a, d);
        }
        return true;
    }

    /// moves generation 1's `dir` into a new subvolume, `subvol`, in the
    /// top level. reflinks where it can: journald's files are nocow, and
    /// btrfs won't clone those, so they're copied.
    fn moveInto(e: *Enabler, dir: []const u8, subvol: []const u8) !bool {
        const dest = try e.m.at(&.{subvol});
        if (!try e.tried(btrfs.create(dest), try std.fmt.allocPrint(e.a, "create {s}", .{subvol}))) return false;
        try e.laterDrop(dest);
        const src = try e.m.at(&.{ new_root, dir });
        // a missing one, often /srv, still needs a place to mount.
        if (!rootfs.pathExists(e.ctx.io, src) and !try e.sh(&.{ "mkdir", "-p", src })) return false;
        if (!try e.sh(&.{ "cp", "-a", "--reflink=auto", try std.fs.path.join(e.a, &.{ src, "." }), dest })) return false;
        // the subvolume's top is what's mounted, so it takes the directory's
        // owner and mode: /root stays 0700.
        if (!try e.sh(&.{ "chown", "--reference", src, dest })) return false;
        if (!try e.sh(&.{ "chmod", "--reference", src, dest })) return false;
        return e.sh(&.{ "find", src, "-mindepth", "1", "-maxdepth", "1", "-exec", "rm", "-rf", "{}", "+" });
    }

    /// the pacman database moves into generation 1's /usr, and /var keeps
    /// a symlink to it. a /var the running root shares gets that symlink
    /// now, so the running root gets its own copy of the database too.
    fn movePacmanDb(e: *Enabler) !bool {
        const db = try std.fs.path.join(e.a, &.{ e.var_dir, "lib/pacman" });
        const moved = try e.m.at(&.{ new_root, generation.pacman_db });
        if (!try e.sh(&.{ "mkdir", "-p", std.fs.path.dirnamePosix(moved).? })) return false;
        if (e.moved_var) {
            if (!try e.sh(&.{ "mv", db, moved })) return false;
        } else {
            const here = try e.m.at(&.{ e.boot.root_subvol.?, generation.pacman_db });
            if (!try e.sh(&.{ "mkdir", "-p", std.fs.path.dirnamePosix(here).? })) return false;
            if (!try e.sh(&.{ "cp", "-a", "--reflink=auto", db, moved })) return false;
            if (!try e.sh(&.{ "cp", "-a", "--reflink=auto", db, here })) return false;
            // taken back newest first: the symlink goes, the database
            // returns from the running root's copy, and that copy goes.
            try e.later(&.{ "rm", "-rf", here });
            try e.later(&.{ "cp", "-a", here, db });
            try e.later(&.{ "rm", "-f", db });
            if (!try e.sh(&.{ "rm", "-rf", db })) return false;
        }
        return e.sh(&.{ "ln", "-s", "/" ++ generation.pacman_db, db });
    }

    /// generation 1's /etc/yoq moves into its /var, and fstab mounts it
    /// back where it was.
    fn moveConfig(e: *Enabler) !bool {
        const src = try e.m.at(&.{ new_root, "etc/yoq" });
        const dest = try std.fs.path.join(e.a, &.{ e.var_dir, "lib/yoq/config" });
        if (!try e.sh(&.{ "mkdir", "-p", std.fs.path.dirnamePosix(dest).? })) return false;
        if (rootfs.pathExists(e.ctx.io, src)) {
            if (!try e.sh(&.{ "mv", src, dest })) return false;
        } else if (!try e.sh(&.{ "mkdir", "-p", dest })) return false;
        if (!e.moved_var) try e.later(&.{ "rm", "-rf", dest });
        if (!try e.sh(&.{ "mkdir", "-p", src })) return false;
        e.moved_config = true;
        return true;
    }

    /// generation 1's snap-pac leaves the root alone: every change is a
    /// generation, so a snapshot before and after each pacman run is two
    /// more of the same.
    fn stopSnapPac(e: *Enabler) !bool {
        const path = try e.m.at(&.{ new_root, "etc/snap-pac.ini" });
        const old = std.Io.Dir.cwd().readFileAlloc(e.ctx.io, path, e.a, .limited(1 << 16)) catch "";
        rootfs.writeAtomic(e.ctx.io, path, try enable.snapPac(e.a, old), null) catch return e.failed("can't write {s}", .{path});
        return true;
    }

    /// the new root's fstab mounts its own subvolume, @var at /var, and
    /// the esp; then it's recorded, read-only, as @gens/1.
    fn seal(e: *Enabler) !bool {
        const fstab_path = try e.m.at(&.{ new_root, "etc/fstab" });
        const old = std.Io.Dir.cwd().readFileAlloc(e.ctx.io, fstab_path, e.a, .limited(1 << 20)) catch "";
        const fstab = try enable.rewriteFstab(e.a, old, .{
            .uuid = e.m.root_uuid,
            .add_var = e.moved_var,
            .data = e.moved_data.items,
            .bind_config = e.moved_config,
            .esp = .{ .uuid = e.m.esp_uuid, .point = e.boot.esp.? },
        });
        rootfs.writeAtomic(e.ctx.io, fstab_path, fstab, null) catch return e.failed("can't write {s}", .{fstab_path});
        if (!try e.healthUnit()) return false;
        const gen = try e.m.at(&.{ generation.gens_dir, "1" });
        if (!try e.tried(btrfs.snapshot(try e.m.at(&.{new_root}), gen, true), "record generation 1")) return false;
        try e.laterDrop(gen);
        const record: generation.Record = .{
            .n = 1,
            .time = e.time,
            .root = new_root[1..],
            .reason = "enable-rollback",
            .from = e.boot.root_subvol.?,
            .config_dir = if (e.config) |c| c.dir else null,
            .config_rev = if (e.config) |c| c.rev else null,
        };
        if (try gens.writeRecord(e.a, e.ctx.io, e.var_dir, record)) |why| return e.failed("{s}", .{why});
        if (!e.moved_var) try e.later(&.{ "rm", "-f", try gens.recordPath(e.a, e.var_dir, 1) });
        rootfs.writeAtomic(e.ctx.io, generation.pending_path, new_root[1..], null) catch return e.failed("can't write {s}", .{generation.pending_path});
        try e.later(&.{ "rm", "-f", generation.pending_path });
        return true;
    }

    /// the units generation 1 gets (see enable.units), turned on.
    fn healthUnit(e: *Enabler) !bool {
        // the packaged os outlasts a copy run from a build directory.
        const os_path = if (rootfs.pathExists(e.ctx.io, "/usr/bin/os")) "/usr/bin/os" else try std.process.executablePathAlloc(e.ctx.io, e.a);
        const why = try gens.writeUnits(e.a, e.ctx.io, try e.m.at(&.{new_root}), os_path) orelse return true;
        return e.failed("{s}", .{why});
    }

    /// grub's files on the esp, so the menu lives outside every
    /// generation. it keeps the efi path the machine boots from now.
    fn bootFiles(e: *Enabler) !bool {
        const esp = e.boot.esp.?;
        // what the firmware boots now, kept until grub-install is done.
        if (!try e.keep(try std.fs.path.join(e.a, &.{ esp, "EFI" }), "/run/yoq/efi-backup")) return false;
        return e.sh(try gens.grubInstall(e.a, e.ctx.io, esp, esp));
    }

    /// the menu, with generation 1 and the system as it is now. grub's goes
    /// where grub-install will point grub, with the env file for one-shot
    /// boots; nothing reads it until then. limine and refind read theirs
    /// already, so for them this is the switch.
    fn bootEntry(e: *Enabler) !bool {
        const esp = e.boot.esp.?;
        switch (e.m.loader) {
            .grub => {
                // with the esp at /boot, grub's own menu is already there.
                const grub_dir = try std.fs.path.join(e.a, &.{ esp, "grub" });
                if (!try e.keep(grub_dir, "/run/yoq/grub-backup")) return false;
                if (!try e.sh(&.{ "mkdir", "-p", grub_dir })) return false;
            },
            .limine => if (!try e.keep(e.boot.loader_conf.?, "/run/yoq/loader-backup")) return false,
            .refind => {
                const dir = std.fs.path.dirnamePosix(e.boot.loader_conf.?).?;
                if (!try e.keep(e.boot.loader_conf.?, "/run/yoq/loader-backup")) return false;
                if (!try e.keep(try std.fs.path.join(e.a, &.{ dir, "yoq.conf" }), "/run/yoq/yoq-conf-backup")) return false;
                if (!try e.keep(try std.fs.path.join(e.a, &.{ dir, "drivers_x64" }), "/run/yoq/drivers-backup")) return false;
            },
        }
        // the env file, and limine's copies of boot files.
        const own_dir = try std.fs.path.join(e.a, &.{ esp, "yoq" });
        if (!try e.keep(own_dir, "/run/yoq/esp-backup")) return false;
        const records = try gens.readRecords(e.a, e.ctx.io, e.var_dir);
        if (try e.m.writeMenu(new_root, records)) |why| return e.failed("{s}", .{why});
        if (e.m.loader != .grub) return true;
        if (!try e.sh(&.{ "mkdir", "-p", own_dir })) return false;
        return e.sh(&.{ "grub-editenv", try std.fs.path.join(e.a, &.{ esp, generation.grubenv }), "create" });
    }

    /// copies `dir` to `backup`, if it's there, so taking back the steps
    /// puts it back as it was; if it isn't, taking back removes it.
    fn keep(e: *Enabler, dir: []const u8, backup: []const u8) !bool {
        if (rootfs.pathExists(e.ctx.io, dir)) {
            if (!try e.sh(&.{ "rm", "-rf", backup })) return false;
            if (!try e.sh(&.{ "cp", "-a", dir, backup })) return false;
            // taken back newest first: the new one goes, then the copy returns.
            try e.later(&.{ "cp", "-a", backup, dir });
        }
        try e.later(&.{ "rm", "-rf", dir });
        return true;
    }

    fn sh(e: *Enabler, argv: []const []const u8) !bool {
        const why = try exec.run(e.a, e.ctx.io, argv) orelse return true;
        return e.failed("{s}", .{why});
    }

    fn tried(e: *Enabler, result: btrfs.Error!void, what: []const u8) !bool {
        result catch |err| return e.failed("can't {s}: {s}", .{ what, @errorName(err) });
        return true;
    }

    fn failed(e: *Enabler, comptime fmt: []const u8, args: anytype) !bool {
        try e.ctx.err.print("os: " ++ fmt ++ "\n", args);
        return false;
    }
};
