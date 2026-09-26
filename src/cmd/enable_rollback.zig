//! `os enable-rollback`: moves a machine to the rollback rung. it shows
//! the checks and the steps, asks, and then builds generation 1 from one
//! snapshot of the running root, which becomes the root at the next boot.

const std = @import("std");
const cli = @import("../cli.zig");
const btrfs = @import("../btrfs.zig");
const enable = @import("../enable.zig");
const exec = @import("../exec.zig");
const facts = @import("../facts.zig");
const generation = @import("../generation.zig");
const output = @import("../output.zig");
const Context = cli.Context;
const Allocator = std.mem.Allocator;

pub fn enableRollbackCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    var yes = false;
    for (args) |arg| {
        if (@import("apply.zig").isYes(arg)) yes = true else return cli.usageError(ctx, "os enable-rollback [--yes]");
    }
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const f = try cli.facts(&w) orelse return w.fail();
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
    if (!cli.eql(ctx.root, "/") or std.os.linux.geteuid() != 0) {
        try ctx.err.writeAll("os: enable-rollback changes the running machine's disk and boot menu, so it needs root and no --root.\n");
        return 1;
    }
    if (!yes) {
        if (!ctx.interactive) {
            try ctx.err.writeAll("os: pass --yes to enable rollback without a terminal.\n");
            return 2;
        }
        try ctx.out.writeByte('\n');
        if (!try cli.confirm(ctx, "enable rollback?")) {
            try ctx.out.writeAll("nothing changed.\n");
            return 0;
        }
    }
    try ctx.out.writeByte('\n');
    var e: Enabler = .{ .ctx = ctx, .a = a, .boot = f.boot, .time = std.Io.Timestamp.now(ctx.io, .real).toSeconds() };
    if (!try e.run(&p)) return 1;
    try ctx.out.writeAll("\ngeneration 1 is ready. reboot to start it; the boot menu also keeps the system as it is now.\n");
    return 0;
}

/// carries out the plan's steps. the btrfs top level is mounted for the
/// duration, and every step works inside it.
const Enabler = struct {
    ctx: *Context,
    a: Allocator,
    boot: facts.Boot,
    time: i64,
    top: []const u8 = generation.top_mount,
    root_uuid: []const u8 = "",
    /// where generation 1's /var is being built: the new subvolume, or the
    /// running /var if it's a subvolume already.
    var_dir: []const u8 = "/var",
    moved_var: bool = false,

    fn run(e: *Enabler, p: *const enable.Plan) !bool {
        e.root_uuid = try e.uuidOf(e.boot.root_device.?) orelse return false;
        if (!try e.sh(&.{ "mkdir", "-p", e.top })) return false;
        if (!try e.sh(&.{ "mount", "-o", "subvolid=5", e.boot.root_device.?, e.top })) return false;
        defer _ = exec.run(e.a, e.ctx.io, &.{ "umount", e.top }) catch {};

        for (p.steps) |s| {
            try e.ctx.out.print("  {s}\n", .{s.what});
            try e.ctx.out.flush();
            const ok = switch (s.kind) {
                .snapshot => try e.snapshot(),
                .var_subvol => try e.moveVar(),
                .pacman_db => try e.movePacmanDb(),
                .boot_files => try e.seal() and try e.bootFiles(),
                .boot_entry => try e.bootEntry(),
            };
            if (!ok) return false;
        }
        return true;
    }

    fn at(e: *Enabler, parts: []const []const u8) ![]const u8 {
        return std.fs.path.join(e.a, parts);
    }

    fn newRoot(e: *Enabler) ![]const u8 {
        return e.at(&.{ e.top, generation.roots_dir, "1" });
    }

    /// the running root's writable copy, @roots/1.
    fn snapshot(e: *Enabler) !bool {
        for ([_][]const u8{ generation.roots_dir, generation.gens_dir }) |d| {
            if (!try e.sh(&.{ "mkdir", "-p", try e.at(&.{ e.top, d }) })) return false;
        }
        return e.tried(btrfs.snapshot(try e.at(&.{ e.top, e.boot.root_subvol.? }), try e.newRoot(), false), "snapshot the running root");
    }

    /// generation 1's /var becomes @var: its contents move there, and
    /// fstab mounts it.
    fn moveVar(e: *Enabler) !bool {
        const root = try e.newRoot();
        const dest = try e.at(&.{ e.top, generation.var_subvol });
        if (!try e.tried(btrfs.create(dest), "create @var")) return false;
        const var_dir = try e.at(&.{ root, "var" });
        // reflink where it can: journald's files are nocow, and btrfs won't
        // clone those, so they're copied.
        if (!try e.sh(&.{ "cp", "-a", "--reflink=auto", try e.at(&.{ var_dir, "." }), dest })) return false;
        if (!try e.sh(&.{ "find", var_dir, "-mindepth", "1", "-maxdepth", "1", "-exec", "rm", "-rf", "{}", "+" })) return false;
        e.var_dir = dest;
        e.moved_var = true;
        return true;
    }

    /// the pacman database moves into generation 1's /usr, and /var keeps
    /// a symlink to it.
    fn movePacmanDb(e: *Enabler) !bool {
        const root = try e.newRoot();
        const sysimage = try e.at(&.{ root, "usr/lib/sysimage" });
        const db = try e.at(&.{ e.var_dir, "lib/pacman" });
        if (!try e.sh(&.{ "mkdir", "-p", sysimage })) return false;
        if (!try e.sh(&.{ "mv", db, try e.at(&.{ sysimage, "pacman" }) })) return false;
        return e.sh(&.{ "ln", "-s", "/usr/lib/sysimage/pacman", db });
    }

    /// the new root's fstab mounts its own subvolume, and @var at /var;
    /// then it's recorded, read-only, as @gens/1.
    fn seal(e: *Enabler) !bool {
        const root = try e.newRoot();
        const fstab_path = try e.at(&.{ root, "etc/fstab" });
        const old = std.Io.Dir.cwd().readFileAlloc(e.ctx.io, fstab_path, e.a, .limited(1 << 20)) catch "";
        const esp_uuid = try e.uuidOf(e.boot.esp_device.?) orelse return false;
        const fstab = try rewriteFstab(e.a, old, .{
            .uuid = e.root_uuid,
            .subvol = "/" ++ generation.roots_dir ++ "/1",
            .add_var = e.moved_var,
            .esp = .{ .uuid = esp_uuid, .point = e.boot.esp.? },
        });
        std.Io.Dir.cwd().writeFile(e.ctx.io, .{ .sub_path = fstab_path, .data = fstab }) catch return e.failed("write {s}", .{fstab_path});

        if (!try e.tried(btrfs.snapshot(root, try e.at(&.{ e.top, generation.gens_dir, "1" }), true), "record generation 1")) return false;
        const record: generation.Record = .{ .n = 1, .time = e.time, .root = generation.roots_dir ++ "/1", .reason = "enable-rollback" };
        var json: std.Io.Writer.Allocating = .init(e.a);
        try std.json.Stringify.value(record, .{}, &json.writer);
        try json.writer.writeByte('\n');
        const dir = try e.at(&.{ e.var_dir, "lib/yoq/generations" });
        if (!try e.sh(&.{ "mkdir", "-p", dir })) return false;
        std.Io.Dir.cwd().writeFile(e.ctx.io, .{ .sub_path = try e.at(&.{ dir, "1.json" }), .data = json.written() }) catch return e.failed("write generation 1's record in {s}", .{dir});
        return true;
    }

    /// grub's files on the esp, so the menu lives outside every
    /// generation. it keeps the efi path the machine boots from now.
    fn bootFiles(e: *Enabler) !bool {
        const esp = e.boot.esp.?;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(e.a, &.{ "grub-install", "--target=x86_64-efi", try std.fmt.allocPrint(e.a, "--efi-directory={s}", .{esp}), try std.fmt.allocPrint(e.a, "--boot-directory={s}", .{esp}) });
        if (try e.grubId(esp)) |id| {
            try argv.append(e.a, try std.fmt.allocPrint(e.a, "--bootloader-id={s}", .{id}));
        } else try argv.append(e.a, "--removable");
        return e.sh(argv.items);
    }

    /// the directory under EFI/ that holds grub, if grub has one of its
    /// own. without one it boots from the removable path, EFI/BOOT.
    fn grubId(e: *Enabler, esp: []const u8) !?[]const u8 {
        var dir = std.Io.Dir.cwd().openDir(e.ctx.io, try e.at(&.{ esp, "EFI" }), .{ .iterate = true }) catch return null;
        defer dir.close(e.ctx.io);
        var it = dir.iterate();
        while (it.next(e.ctx.io) catch null) |d| {
            if (d.kind != .directory or std.ascii.eqlIgnoreCase(d.name, "BOOT")) continue;
            dir.access(e.ctx.io, try e.at(&.{ d.name, "grubx64.efi" }), .{}) catch continue;
            return try e.a.dupe(u8, d.name);
        }
        return null;
    }

    /// the menu: generation 1 by default, and the system as it is now.
    fn bootEntry(e: *Enabler) !bool {
        const esp = e.boot.esp.?;
        const esp_uuid = try e.uuidOf(e.boot.esp_device.?) orelse return false;
        const cmdline = std.Io.Dir.cwd().readFileAlloc(e.ctx.io, "/proc/cmdline", e.a, .limited(4096)) catch "";
        const gen_subvol = "/" ++ generation.roots_dir ++ "/1";
        const before = e.boot.root_subvol.?;
        const date = try dateOf(e.a, e.time);
        const entries = [_]generation.Entry{
            try e.entry("gen-1", try std.fmt.allocPrint(e.a, "yoq 1 · {s} · enable-rollback", .{date}), gen_subvol, try e.newRoot(), cmdline),
            try e.entry("before", "the system before generations", before, try e.at(&.{ e.top, before }), cmdline),
        };
        const cfg = try generation.grubConfig(e.a, .{ .esp_uuid = esp_uuid, .root_uuid = e.root_uuid, .default = "gen-1", .entries = &entries });
        const cfg_path = try e.at(&.{ esp, "grub/grub.cfg" });
        std.Io.Dir.cwd().writeFile(e.ctx.io, .{ .sub_path = cfg_path, .data = cfg }) catch return e.failed("write {s}", .{cfg_path});
        if (!try e.sh(&.{ "mkdir", "-p", try e.at(&.{ esp, "yoq" }) })) return false;
        return e.sh(&.{ "grub-editenv", try e.at(&.{ esp, "yoq/grubenv" }), "create" });
    }

    /// a menu entry for the root at `dir` (`subvol` under the top level):
    /// its kernel, microcode, and initramfs from its own /boot.
    fn entry(e: *Enabler, id: []const u8, title: []const u8, subvol: []const u8, dir: []const u8, cmdline: []const u8) !generation.Entry {
        var kernel: []const u8 = "vmlinuz-linux";
        var initrds: std.ArrayList([]const u8) = .empty;
        var boot = std.Io.Dir.cwd().openDir(e.ctx.io, try e.at(&.{ dir, "boot" }), .{ .iterate = true }) catch null;
        if (boot) |*b| {
            defer b.close(e.ctx.io);
            var it = b.iterate();
            while (it.next(e.ctx.io) catch null) |f| {
                if (std.mem.startsWith(u8, f.name, "vmlinuz-")) kernel = try e.a.dupe(u8, f.name);
                if (std.mem.endsWith(u8, f.name, "-ucode.img")) try initrds.append(e.a, try e.a.dupe(u8, f.name));
            }
        }
        try initrds.append(e.a, try std.fmt.allocPrint(e.a, "initramfs-{s}.img", .{kernel["vmlinuz-".len..]}));
        return .{ .id = id, .title = title, .subvol = subvol, .kernel = kernel, .initrds = initrds.items, .args = try generation.kernelArgs(e.a, cmdline, e.root_uuid, subvol) };
    }

    fn uuidOf(e: *Enabler, device: []const u8) !?[]const u8 {
        return switch (try exec.output(e.a, e.ctx.io, &.{ "blkid", "-s", "UUID", "-o", "value", device })) {
            .ok => |out| std.mem.trim(u8, out, " \n"),
            .failed => |why| {
                _ = try e.failed("can't read {s}'s uuid: {s}", .{ device, why });
                return null;
            },
        };
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
        try e.ctx.err.print("os: stopped partway. {s} still has whatever the steps above made.\n", .{e.top});
        return false;
    }
};

pub const Fstab = struct {
    uuid: []const u8,
    subvol: []const u8,
    add_var: bool,
    /// the esp, which gets a line if none mounts it: without one it might
    /// only have been automounted, which a new root can't count on.
    esp: ?struct { uuid: []const u8, point: []const u8 } = null,
};

/// the new root's fstab: a btrfs line for / mounts `subvol`, /var gets a
/// line for @var when it moved, and the esp gets one if it had none.
pub fn rewriteFstab(a: Allocator, text: []const u8, f: Fstab) ![]const u8 {
    const uuid = f.uuid;
    const subvol = f.subvol;
    var out: std.ArrayList(u8) = .empty;
    var root_opts: []const u8 = "rw,relatime";
    var has_esp = false;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const spec = fields.next() orelse "";
        const point = fields.next() orelse "";
        const fstype = fields.next() orelse "";
        const opts = fields.next() orelse "";
        if (f.esp) |esp| has_esp = has_esp or std.mem.eql(u8, point, esp.point);
        if (spec.len == 0 or spec[0] == '#' or !std.mem.eql(u8, point, "/") or !std.mem.eql(u8, fstype, "btrfs")) {
            if (line.len > 0 or out.items.len > 0) try out.print(a, "{s}\n", .{line});
            continue;
        }
        root_opts = try withoutSubvol(a, opts);
        try out.print(a, "{s} / btrfs {s},subvol={s} 0 0\n", .{ spec, root_opts, subvol });
    }
    if (f.add_var) try out.print(a, "UUID={s} /var btrfs {s},subvol=/{s} 0 0\n", .{ uuid, root_opts, generation.var_subvol });
    if (f.esp) |esp| {
        if (!has_esp) try out.print(a, "UUID={s} {s} vfat rw,relatime,fmask=0077,dmask=0077 0 2\n", .{ esp.uuid, esp.point });
    }
    return out.items;
}

fn withoutSubvol(a: Allocator, opts: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, opts, ',');
    while (it.next()) |o| {
        if (std.mem.startsWith(u8, o, "subvol=") or std.mem.startsWith(u8, o, "subvolid=")) continue;
        if (out.items.len > 0) try out.append(a, ',');
        try out.appendSlice(a, o);
    }
    return if (out.items.len > 0) out.items else "rw,relatime";
}

/// "2026-09-26" for unix seconds.
fn dateOf(a: Allocator, secs: i64) ![]const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    return std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2}", .{ day.year, md.month.numeric(), md.day_index + 1 });
}

test "the new root's fstab" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        \\# /dev/vda3
        \\UUID=abc / btrfs rw,relatime,compress=zstd:1,subvol=/@roots/1 0 0
        \\UUID=efi /efi vfat rw 0 2
        \\UUID=abc /var btrfs rw,relatime,compress=zstd:1,subvol=/@var 0 0
        \\
    , try rewriteFstab(a,
        \\# /dev/vda3
        \\UUID=abc / btrfs rw,relatime,compress=zstd:1,subvol=/@ 0 0
        \\UUID=efi /efi vfat rw 0 2
        \\
    , .{ .uuid = "abc", .subvol = "/@roots/1", .add_var = true, .esp = .{ .uuid = "efi", .point = "/efi" } }));
    // no lines at all, as on an image that relies on automounts.
    try std.testing.expectEqualStrings(
        \\UUID=abc /var btrfs rw,relatime,subvol=/@var 0 0
        \\UUID=41B2-0FB5 /efi vfat rw,relatime,fmask=0077,dmask=0077 0 2
        \\
    , try rewriteFstab(a, "", .{ .uuid = "abc", .subvol = "/@roots/1", .add_var = true, .esp = .{ .uuid = "41B2-0FB5", .point = "/efi" } }));
    try std.testing.expectEqualStrings("2026-09-26", try dateOf(a, 1790380800));
}
