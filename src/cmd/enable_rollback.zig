//! `yos enable-rollback`: moves a machine to the rollback rung. it shows
//! the checks and the steps, asks, and then builds generation 1 from one
//! snapshot of the running root, which becomes the root at the next boot.

const std = @import("std");
const lists = @import("../lists.zig");
const rootfs = @import("../rootfs.zig");
const cli = @import("../cli.zig");
const applying = @import("apply.zig");
const btrfs = @import("../btrfs.zig");
const enable = @import("../enable.zig");
const exec = @import("../exec.zig");
const facts = @import("../facts.zig");
const generation = @import("../generation.zig");
const gens = @import("../gens.zig");
const bootmenu = @import("../bootmenu.zig");
const menu = @import("../menu.zig");
const output = @import("../output.zig");
const events = @import("../events.zig");
const journal = @import("../journal.zig");
const Context = cli.Context;
const Allocator = std.mem.Allocator;

pub fn enableRollbackCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    var yes = false;
    var it: cli.ArgIter = .{ .args = args };
    while (it.next()) |arg| {
        if (it.isFlag(arg) and cli.isYes(arg)) yes = true else return cli.usageError(ctx, "yos enable-rollback [--yes]");
    }
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const f = try w.facts() orelse return w.fail();
    const p = try enable.plan(a, &f);
    if (ctx.json) {
        try output.writeDoc(ctx.out, "yos.enable-rollback/1", .{ .ready = p.ready(), .running = p.running, .checks = p.checks, .steps = p.steps });
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
    // a first generation already waiting for its boot: another would undo
    // that one's boot files.
    if (try cli.refused(ctx, applying.bootBlocker(ctx.io))) return 1;
    const os_path = try unitYos(ctx, a);
    // root runs it at every boot and shutdown, in every generation.
    if (!rootfs.rootOnly(os_path)) return cli.fail(ctx, "{s}, or a directory it's in, can be changed by someone other than root, and every generation would run it as root at boot. install the yos package, or copy yos where only root can write, like /usr/local/bin, and run that.", .{os_path});
    if (try cli.approve(ctx, yes, "enable rollback", "enable rollback?")) |code| return code;
    try ctx.out.writeByte('\n');
    var e: Enabler = .{ .ctx = ctx, .a = a, .boot = f.boot, .os_path = os_path, .time = std.Io.Timestamp.now(ctx.io, .real).toSeconds() };
    if (!try e.run(&p)) return 1;
    gens.blockHibernation(ctx.io);
    try ctx.out.print("\ngeneration {d} is ready. reboot to start it; the boot menu also keeps the system as it is now.\n", .{e.n});
    return 0;
}

/// the yos generation 1's units run: the packaged one, which outlasts a
/// copy run from somewhere else, or this one.
fn unitYos(ctx: *Context, a: Allocator) ![]const u8 {
    if (rootfs.pathExists(ctx.io, gens.packaged_yos)) return gens.packaged_yos;
    return std.process.executablePathAlloc(ctx.io, a);
}

/// carries out the plan's steps, inside the btrfs top level.
/// the first generation's number: one past the highest that roots or
/// records under `roots` and `gens` already use, like the root an
/// uninstall left running, or 1 when there are none. names that aren't a
/// number, like boot copies (boot-<n>), count by their number too.
fn firstFree(io: std.Io, roots: []const u8, gens_dir: []const u8) u32 {
    var top: u32 = 0;
    for ([_][]const u8{ roots, gens_dir }) |path| {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |d| {
            const name = if (std.mem.startsWith(u8, d.name, "boot-")) d.name[5..] else d.name;
            const n = std.fmt.parseInt(u32, name, 10) catch continue;
            top = @max(top, n);
        }
    }
    return top + 1;
}

test "the first generation's number comes after roots an uninstall left" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var buf: [2][128]u8 = undefined;
    const roots = try std.fmt.bufPrint(&buf[0], ".zig-cache/tmp/{s}/@roots", .{tmp.sub_path});
    const gens_dir = try std.fmt.bufPrint(&buf[1], ".zig-cache/tmp/{s}/@gens", .{tmp.sub_path});
    // a clean disk: generation 1.
    try std.testing.expectEqual(1, firstFree(io, roots, gens_dir));
    // an uninstall left the root it ran from, and a boot copy, and records.
    try tmp.dir.createDirPath(io, "@roots/3");
    try tmp.dir.createDirPath(io, "@roots/boot-2");
    try tmp.dir.createDirPath(io, "@gens/4");
    try tmp.dir.createDirPath(io, "@roots/not-a-number");
    try std.testing.expectEqual(5, firstFree(io, roots, gens_dir));
}

/// puts `backup` back at `dir`. the copy goes beside `dir` first, on the
/// same filesystem, and two renames swap it in, so a cut-off undo leaves
/// the old one or the restored one on disk, never neither: the backup
/// is in /run, which a power cut takes with it.
fn restoreArgv(a: Allocator, backup: []const u8, dir: []const u8) ![]const []const u8 {
    return a.dupe([]const u8, &.{ "sh", "-c", restore_script, "sh", backup, dir });
}

const restore_script =
    \\set -e
    \\rm -rf "$2.yos-restore" "$2.yos-old"
    \\cp -a "$1" "$2.yos-restore"
    \\sync
    \\if [ -e "$2" ] || [ -L "$2" ]; then mv "$2" "$2.yos-old"; fi
    \\mv "$2.yos-restore" "$2"
    \\sync
    \\rm -rf "$2.yos-old"
;

test "taking back a kept directory swaps the backup in" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "backup/BOOT");
    try tmp.dir.writeFile(io, .{ .sub_path = "backup/BOOT/BOOTX64.EFI", .data = "old" });
    try tmp.dir.createDirPath(io, "EFI/yos");
    try tmp.dir.writeFile(io, .{ .sub_path = "EFI/yos/grubx64.efi", .data = "new" });
    const backup = try std.fmt.allocPrint(a, "{s}/backup", .{base});
    const dir = try std.fmt.allocPrint(a, "{s}/EFI", .{base});
    try std.testing.expectEqual(null, try exec.run(a, io, try restoreArgv(a, backup, dir)));
    try std.testing.expectEqualStrings("old", try tmp.dir.readFileAlloc(io, "EFI/BOOT/BOOTX64.EFI", a, .limited(64)));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "EFI/yos", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "EFI.yos-old", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "EFI.yos-restore", .{}));
    // a file, like limine.conf, and one that's gone already.
    try tmp.dir.writeFile(io, .{ .sub_path = "limine.bak", .data = "old conf" });
    const conf = try std.fmt.allocPrint(a, "{s}/limine.conf", .{base});
    try std.testing.expectEqual(null, try exec.run(a, io, try restoreArgv(a, try std.fmt.allocPrint(a, "{s}/limine.bak", .{base}), conf)));
    try std.testing.expectEqualStrings("old conf", try tmp.dir.readFileAlloc(io, "limine.conf", a, .limited(64)));
    try tmp.dir.writeFile(io, .{ .sub_path = "limine.conf", .data = "new conf" });
    try std.testing.expectEqual(null, try exec.run(a, io, try restoreArgv(a, try std.fmt.allocPrint(a, "{s}/limine.bak", .{base}), conf)));
    try std.testing.expectEqualStrings("old conf", try tmp.dir.readFileAlloc(io, "limine.conf", a, .limited(64)));
}

const Enabler = struct {
    ctx: *Context,
    a: Allocator,
    boot: facts.Boot,
    /// the yos generation 1's boot and shutdown units run.
    os_path: []const u8,
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
    /// /etc/yos's commit before it moves, for generation 1's record.
    config: ?generation.Config = null,
    /// the first generation's number, and its root: 1 and @roots/1, unless
    /// roots an uninstall left are there already, like the one running.
    n: u32 = 1,
    new_root: []const u8 = "",

    fn run(e: *Enabler, p: *const enable.Plan) !bool {
        var why: []const u8 = "";
        const entries = try e.ctx.history.log(e.a, "/etc/yos", &why) orelse &.{};
        if (entries.len > 0) e.config = .{ .dir = "/etc/yos", .rev = entries[entries.len - 1].rev };
        e.m = try gens.Machine.open(e.a, e.ctx.io, e.boot, &why) orelse return e.failed("{s}", .{why});
        defer e.m.close();
        e.n = firstFree(e.ctx.io, try e.m.at(&.{generation.roots_dir}), try e.m.at(&.{generation.gens_dir}));
        e.new_root = try std.fmt.allocPrint(e.a, "/{s}/{d}", .{ generation.roots_dir, e.n });

        // a step that fails with an error rather than false, like output
        // to a closed pipe, takes the others back all the same.
        errdefer e.takeBack() catch {};
        // ctrl-c, or a dropped ssh session, stops it after the step it's
        // in, or with that step, as the program the step runs gets it
        // too, and what's done is taken back, rather than leaving
        // subvolumes that stop every run after.
        const stops = exec.Stops.note();
        defer stops.restore();
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
                .default_subvol => try e.topDefault(),
                .boot_entry => try e.seal() and try e.bootEntry(),
                .boot_files => try e.bootFiles(),
            };
            if (!ok or exec.Stops.asked()) {
                if (ok) try e.ctx.err.writeAll("yos: stopped, as asked.\n");
                try e.takeBack();
                return false;
            }
        }
        // the note that a first generation waits goes in last, once the
        // bootloader boots it: a run cut off before then leaves the old
        // root booting, and nothing refusing changes to it.
        rootfs.writeAtomic(e.ctx.io, generation.pending_path, e.new_root[1..], null) catch {
            _ = try e.failed("can't write {s}", .{generation.pending_path});
            try e.takeBack();
            return false;
        };
        // into the /var the next boot mounts, while it's still reachable.
        try events.recordIn(e.a, e.ctx.io, e.var_dir, .{ .time = journal.now(e.ctx.io), .kind = .@"enable-rollback", .step = .done, .generation = e.n });
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
        // taking back, cut off, would leave things worse.
        const stops = exec.Stops.ignore();
        defer stops.restore();
        var clean = true;
        var i = e.undo.items.len;
        while (i > 0) {
            i -= 1;
            switch (e.undo.items[i]) {
                .subvol => |path| {
                    btrfs.setReadOnly(path, false) catch {};
                    btrfs.delete(path) catch |err| {
                        try e.ctx.err.print("yos: couldn't remove {s}: {s}\n", .{ path, @errorName(err) });
                        clean = false;
                    };
                },
                .run => |argv| if (try exec.run(e.a, e.ctx.io, argv)) |why| {
                    try e.ctx.err.print("yos: couldn't undo with {s}: {s}\n", .{ argv[0], why });
                    clean = false;
                },
            }
        }
        try e.ctx.err.writeAll(if (clean) "yos: took back the steps above; the machine is as it was.\n" else "yos: took back what it could; see the lines above.\n");
    }

    /// the running root's writable copy, @roots/<n>.
    fn snapshot(e: *Enabler) !bool {
        for ([_][]const u8{ generation.roots_dir, generation.gens_dir }) |d| {
            const dir = try e.m.at(&.{d});
            const had = rootfs.pathExists(e.ctx.io, dir);
            if (!try e.sh(&.{ "mkdir", "-p", dir })) return false;
            if (!had) try e.later(&.{ "rmdir", dir });
        }
        const root = try e.m.at(&.{e.new_root});
        if (!try e.tried(btrfs.snapshot(try e.m.at(&.{e.boot.root_subvol.?}), root, false), "snapshot the running root")) return false;
        try e.laterDrop(root);
        // with the esp at /boot, both roots in the menu keep the kernel
        // they boot with. the running root's /boot was an empty mount point.
        if (try e.m.keepBoot(e.new_root)) |why| return e.failed("{s}", .{why});
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
        btrfs.create(dest) catch |err| switch (err) {
            error.AlreadyExists => return e.failed("{s} is in the btrfs top level already, but nothing mounts it: an enable-rollback cut off partway left it. once you've checked there's nothing of yours in it, delete it with `btrfs subvolume delete` (the top level mounts with -o subvolid=5), along with any @roots or @gens that run left, and run this again", .{subvol}),
            else => return e.failed("can't create {s}: {s}", .{ subvol, @errorName(err) }),
        };
        try e.laterDrop(dest);
        const src = try e.m.at(&.{ e.new_root, dir });
        // a missing one, often /srv, still needs a place to mount.
        if (!rootfs.pathExists(e.ctx.io, src) and !try e.sh(&.{ "mkdir", "-p", src })) return false;
        if (!try e.sh(&.{ "cp", "-a", "--reflink=auto", try std.fs.path.join(e.a, &.{ src, "." }), dest })) return false;
        if (!try e.moveNested(try e.m.at(&.{ e.boot.root_subvol.?, dir }), src, dest)) return false;
        // the subvolume's top is what's mounted, so it takes the directory's
        // owner and mode: /root stays 0700.
        if (!try e.sh(&.{ "chown", "--reference", src, dest })) return false;
        if (!try e.sh(&.{ "chmod", "--reference", src, dest })) return false;
        return e.sh(&.{ "find", src, "-mindepth", "1", "-maxdepth", "1", "-exec", "rm", "-rf", "{}", "+" });
    }

    /// subvolumes nested in the running root's `live` directory, like
    /// /var/lib/machines or docker's, which `scan`, its snapshot, holds
    /// only as empty directories with inode 2, and `cp -a` copied into
    /// `dest` as plain ones. each is snapshotted into its place in `dest`,
    /// and then the ones nested in it, so nothing in them is left behind.
    fn moveNested(e: *Enabler, live: []const u8, scan: []const u8, dest: []const u8) !bool {
        const found = switch (try exec.output(e.a, e.ctx.io, &.{ "find", scan, "-type", "d", "-inum", "2", "-empty", "-printf", "%P\n" })) {
            .ok => |out| out,
            .failed => |why| return e.failed("{s}", .{why}),
        };
        var lines = std.mem.tokenizeScalar(u8, found, '\n');
        while (lines.next()) |rel| {
            const from = try std.fs.path.join(e.a, &.{ live, rel });
            if (!(btrfs.isSubvolume(from) catch false)) continue;
            const to = try std.fs.path.join(e.a, &.{ dest, rel });
            if (!try e.sh(&.{ "rmdir", to })) return false;
            if (!try e.tried(btrfs.snapshot(from, to, false), try std.fmt.allocPrint(e.a, "snapshot {s}", .{from}))) return false;
            // taken back before the subvolume it's in, which can't go
            // while it holds one.
            try e.laterDrop(to);
            // a snapshot holds the subvolumes nested in it as placeholders
            // too, and those are in place already.
            if (!try e.moveNested(from, to, to)) return false;
        }
        return true;
    }

    /// the pacman database moves into generation 1's /usr, and /var keeps
    /// a symlink to it. a /var the running root shares gets that symlink
    /// now, so the running root gets its own copy of the database too.
    fn movePacmanDb(e: *Enabler) !bool {
        const db = try std.fs.path.join(e.a, &.{ e.var_dir, "lib/pacman" });
        const moved = try e.m.at(&.{ e.new_root, generation.pacman_db });
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

    /// generation 1's /etc/yos moves into its /var, and fstab mounts it
    /// back where it was.
    fn moveConfig(e: *Enabler) !bool {
        const src = try e.m.at(&.{ e.new_root, "etc/yos" });
        const dest = try std.fs.path.join(e.a, &.{ e.var_dir, "lib/yos/config" });
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
        const path = try e.m.at(&.{ e.new_root, "etc/snap-pac.ini" });
        const old = std.Io.Dir.cwd().readFileAlloc(e.ctx.io, path, e.a, .limited(1 << 16)) catch "";
        rootfs.writeAtomic(e.ctx.io, path, try enable.snapPac(e.a, old), null) catch return e.failed("can't write {s}", .{path});
        return true;
    }

    /// the btrfs top level becomes the default subvolume again, where grub
    /// and refind start their paths. taking it back restores the default
    /// that was there.
    fn topDefault(e: *Enabler) !bool {
        const was = switch (try exec.output(e.a, e.ctx.io, &.{ "btrfs", "subvolume", "get-default", e.m.top })) {
            .ok => |t| enable.defaultId(t) orelse return e.failed("can't read the default subvolume from: {s}", .{t}),
            .failed => |why| return e.failed("can't read the default subvolume: {s}", .{why}),
        };
        if (!try e.sh(&.{ "btrfs", "subvolume", "set-default", "5", e.m.top })) return false;
        try e.later(&.{ "btrfs", "subvolume", "set-default", was, e.m.top });
        return true;
    }

    /// the new root's fstab mounts its own subvolume, @var at /var, and
    /// the esp; then it's recorded, read-only, as @gens/1.
    fn seal(e: *Enabler) !bool {
        const fstab_path = try e.m.at(&.{ e.new_root, "etc/fstab" });
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
        const gen = try e.m.at(&.{ generation.gens_dir, try std.fmt.allocPrint(e.a, "{d}", .{e.n}) });
        if (!try e.tried(btrfs.snapshot(try e.m.at(&.{e.new_root}), gen, true), "record the first generation")) return false;
        try e.laterDrop(gen);
        const record: generation.Record = .{
            .n = e.n,
            .time = e.time,
            .root = e.new_root[1..],
            .reason = "enable-rollback",
            .from = e.boot.root_subvol.?,
            .config_dir = if (e.config) |c| c.dir else null,
            .config_rev = if (e.config) |c| c.rev else null,
        };
        if (try gens.writeRecord(e.a, e.ctx.io, e.var_dir, record)) |why| return e.failed("{s}", .{why});
        if (!e.moved_var) try e.later(&.{ "rm", "-f", try gens.recordPath(e.a, e.var_dir, e.n) });
        return true;
    }

    /// the units generation 1 gets (see enable.units), turned on.
    fn healthUnit(e: *Enabler) !bool {
        const why = try gens.writeUnits(e.a, e.ctx.io, try e.m.at(&.{e.new_root}), e.os_path) orelse return true;
        return e.failed("{s}", .{why});
    }

    /// grub's files on the esp, so the menu lives outside every
    /// generation. it keeps the efi path the machine boots from now.
    fn bootFiles(e: *Enabler) !bool {
        const esp = e.boot.esp.?;
        // what the firmware boots now, kept until grub-install is done.
        if (!try e.keep(try std.fs.path.join(e.a, &.{ esp, "EFI" }), "/run/yos/efi-backup")) return false;
        return e.sh(try bootmenu.grubInstall(e.a, e.ctx.io, esp, esp));
    }

    /// the menu, with generation 1 and the system as it is now. grub's goes
    /// where grub-install will point grub, with the env file for one-shot
    /// boots; nothing reads it until then. limine and refind read theirs
    /// already, so for them this is the switch. systemd-boot gets yos's
    /// entries beside its own, and the switch is making yos's newest the
    /// default.
    fn bootEntry(e: *Enabler) !bool {
        const esp = e.boot.esp.?;
        switch (e.m.loader) {
            .grub => {
                // with the esp at /boot, grub's own menu is already there.
                const grub_dir = try std.fs.path.join(e.a, &.{ esp, "grub" });
                if (!try e.keep(grub_dir, "/run/yos/grub-backup")) return false;
                if (!try e.sh(&.{ "mkdir", "-p", grub_dir })) return false;
            },
            .limine => if (!try e.keep(e.boot.loader_conf.?, "/run/yos/loader-backup")) return false,
            .@"systemd-boot" => if (!try e.keep(try e.m.sdbootEntries(), "/run/yos/entries-backup")) return false,
            .refind => {
                const dir = std.fs.path.dirnamePosix(e.boot.loader_conf.?).?;
                if (!try e.keep(e.boot.loader_conf.?, "/run/yos/loader-backup")) return false;
                if (!try e.keep(try std.fs.path.join(e.a, &.{ dir, "yos.conf" }), "/run/yos/yos-conf-backup")) return false;
                if (!try e.keep(try std.fs.path.join(e.a, &.{ dir, "drivers_x64" }), "/run/yos/drivers-backup")) return false;
            },
        }
        // the env file, and limine's copies of boot files.
        const own_dir = try std.fs.path.join(e.a, &.{ esp, "yos" });
        if (!try e.keep(own_dir, "/run/yos/esp-backup")) return false;
        const records = try gens.readRecords(e.a, e.ctx.io, e.var_dir);
        if (try e.m.writeMenu(e.new_root, records)) |why| return e.failed("{s}", .{why});
        if (e.m.loader == .@"systemd-boot") {
            // taken back, the variable goes, and loader.conf's default is
            // the default again.
            try e.later(&.{ "bootctl", "set-default", "" });
            return e.sh(&.{ "bootctl", "set-default", try menu.sdbootName(e.a, "head") });
        }
        if (e.m.loader != .grub) return true;
        if (!try e.sh(&.{ "mkdir", "-p", own_dir })) return false;
        return e.sh(&.{ "grub-editenv", try std.fs.path.join(e.a, &.{ esp, generation.grubenv }), "create" });
    }

    /// copies `dir` to `backup`, if it's there, so taking back the steps
    /// puts it back as it was (see restoreArgv); if it isn't, taking back
    /// removes it.
    fn keep(e: *Enabler, dir: []const u8, backup: []const u8) !bool {
        if (rootfs.pathExists(e.ctx.io, dir)) {
            if (!try e.sh(&.{ "rm", "-rf", backup })) return false;
            if (!try e.sh(&.{ "cp", "-a", dir, backup })) return false;
            try e.later(try restoreArgv(e.a, backup, dir));
            return true;
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
        try e.ctx.err.print("yos: " ++ fmt ++ "\n", args);
        return false;
    }
};
