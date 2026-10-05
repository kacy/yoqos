//! `yos install <config> --disk <dev>`: puts the machine a config
//! repository describes on a blank disk, from a live arch system. it
//! fetches the config, shows what it will do, asks, and then builds the
//! new machine the way `yos build --clean` builds a root, as generation 1
//! of the layout enable-rollback makes, with grub booting it. with
//! --encrypt, the btrfs filesystem goes inside luks2.

const std = @import("std");
const catalog = @import("../catalog.zig");
const history = @import("../history.zig");
const lists = @import("../lists.zig");
const rootfs = @import("../rootfs.zig");
const cli = @import("../cli.zig");
const btrfs = @import("../btrfs.zig");
const enable = @import("../enable.zig");
const exec = @import("../exec.zig");
const facts = @import("../facts.zig");
const generation = @import("../generation.zig");
const gens = @import("../gens.zig");
const bootmenu = @import("../bootmenu.zig");
const install = @import("../install.zig");
const lock = @import("../lock.zig");
const events = @import("../events.zig");
const journal = @import("../journal.zig");
const applying = @import("apply.zig");
const building = @import("build.zig");
const locking = @import("lock.zig");
const updating = @import("update.zig");
const health = @import("health.zig");
const planner = @import("../planner.zig");
const secrets = @import("../secrets.zig");
const Context = cli.Context;
const Allocator = std.mem.Allocator;

const usage_text = "yos install <config repository or directory> --disk <device> [--host <name>] [--update] [--encrypt] [--tpm] [--passphrase-file <file>] [--yes]";

/// where the config is fetched to before the disk is ready for it: in
/// the directory only root can go into, since git writes a url's password
/// or token into the clone's .git/config before yos takes it out again.
const staging = rootfs.private_dir ++ "/install/config";

pub fn installCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    var source: ?[]const u8 = null;
    var disk: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var update = false;
    var yes = false;
    var encrypt = false;
    var tpm = false;
    var passphrase_file: ?[]const u8 = null;
    var it: cli.ArgIter = .{ .args = args };
    while (it.next()) |arg| {
        if (!it.isFlag(arg)) {
            if (source != null or arg.len == 0) return cli.usageError(ctx, usage_text);
            source = arg;
        } else if (cli.eql(arg, "--disk")) {
            disk = it.value() orelse return cli.usageError(ctx, usage_text);
        } else if (cli.eql(arg, "--host")) {
            host = it.value() orelse return cli.usageError(ctx, usage_text);
        } else if (cli.eql(arg, "--update")) {
            update = true;
        } else if (cli.eql(arg, "--encrypt")) {
            encrypt = true;
        } else if (cli.eql(arg, "--tpm")) {
            // a tpm key is one more way into the luks volume.
            encrypt = true;
            tpm = true;
        } else if (cli.eql(arg, "--passphrase-file")) {
            passphrase_file = it.value() orelse return cli.usageError(ctx, usage_text);
        } else if (cli.isYes(arg)) {
            yes = true;
        } else return cli.usageError(ctx, usage_text);
    }
    if (source == null or disk == null) return cli.usageError(ctx, usage_text);
    if (passphrase_file != null and !encrypt) return cli.usageError(ctx, usage_text);
    if (host) |h| {
        // a name under hosts/, dotted or not, like atlas.lan.
        if (h.len == 0 or std.mem.indexOfScalar(u8, h, '/') != null or cli.eql(h, ".") or cli.eql(h, "..")) return cli.usageError(ctx, usage_text);
    }
    if (try cli.needsHost(ctx, "install erases a disk and builds a machine on it")) return 1;
    if (try cli.refused(ctx, applying.blocker(ctx))) return 1;

    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    // a /dev/disk/by-id link is the disk it points at.
    const device = std.Io.Dir.cwd().realPathFileAlloc(ctx.io, disk.?, a) catch disk.?;
    var in: Installer = .{ .ctx = ctx, .a = a, .disk = device, .encrypt = encrypt, .tpm = tpm };
    // read once, into this buffer only, and wiped when the install ends.
    var secret_buf: [install.max_passphrase + 1]u8 = undefined;
    defer std.crypto.secureZero(u8, &secret_buf);
    if (passphrase_file) |path| {
        secrets.keepPrivate();
        const text = readSecret(ctx.io, path, &secret_buf) catch |e|
            return cli.fail(ctx, "can't read the passphrase from {s}: {s}", .{ path, @errorName(e) });
        in.secret = switch (install.passphrase(text)) {
            .ok => |s| s,
            .problem => |why| return cli.fail(ctx, "{s} {s}", .{ path, why }),
        };
    }
    // nothing's on the disk yet, so it's as it was.
    if (try in.fetch(source.?, host)) |why| return cli.fail(ctx, "{s}", .{why});
    if (update) {
        // an aur list stops the install below; it shouldn't be fetched,
        // reviewed, and built on the live system first.
        var cw: cli.Work = .init(ctx);
        defer cw.deinit();
        if (try cw.config()) |l| if (l.config.aur.items.items.len > 0)
            return cli.fail(ctx, "the config has aur packages, and they build on a running machine. install without them, then add them back and run `yos update` there.", .{});
        try ctx.out.writeAll("resolving the config against today's packages...\n");
        const code = try updating.updateCmd(ctx, &.{"--no-apply"});
        if (code != 0) return code;
        try ctx.out.writeByte('\n');
    }
    const found = try in.look(host, update) orelse return 1;
    const p = try install.plan(a, found);
    try install.writeText(ctx.out, &p);
    if (!p.ready()) {
        try ctx.out.writeAll("\nyos can't install until the checks above pass.\n");
        return 1;
    }
    if (try cli.approve(ctx, yes, "install", "install?")) |code| return code;
    if (rootfs.privateMounts(ctx.io)) |why| return cli.fail(ctx, "{s}", .{why});
    try ctx.out.writeByte('\n');
    defer in.unmountAll();
    // ctrl-c, or a dropped ssh session, stops the install after the step
    // it's in, rather than killing yos with the disk mounted in a private
    // namespace, where the daemons the build started would keep it busy
    // for every run after.
    const stops = exec.Stops.note();
    defer stops.restore();
    for (steps) |s| {
        if (s.encrypted and !in.encrypt) continue;
        try ctx.out.print("  {s}\n", .{s.what});
        try ctx.out.flush();
        if (try s.run(&in)) |why| return fail(ctx, why);
        if (exec.Stops.asked()) return fail(ctx, "stopped, as asked");
    }
    if (!yes and ctx.interactive) try in.passwords() else try in.noPasswords();
    if (try in.recordFirst()) |why| return fail(ctx, why);
    // on the new machine's own /var, beside the build's apply events.
    try events.record(a, ctx.io, install.target, .{ .time = journal.now(ctx.io), .kind = .install, .generation = 1, .message = found.host });
    try ctx.out.print("\n{s} is installed as generation 1. remove the live medium and reboot.\n", .{found.host});
    return 0;
}

/// the file at `path`, read straight into `buf`, so there's no other copy
/// to wipe. one that fills `buf` is too long.
fn readSecret(io: std.Io, path: []const u8, buf: []u8) ![]u8 {
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var n: usize = 0;
    while (n < buf.len) {
        n += f.readStreaming(io, &.{buf[n..]}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
    }
    if (n == buf.len) return error.FileTooBig;
    return buf[0..n];
}

test "a passphrase file is read into one buffer, and only so much" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "short", .data = "hunter2\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "long", .data = "x" ** 9 });
    var path_buf: [256]u8 = undefined;
    var buf: [9]u8 = undefined;
    const short = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/short", .{tmp.sub_path});
    const got = try readSecret(io, short, &buf);
    try std.testing.expectEqualStrings("hunter2\n", got);
    try std.testing.expectEqual(@intFromPtr(&buf), @intFromPtr(got.ptr));
    const long = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/long", .{tmp.sub_path});
    try std.testing.expectError(error.FileTooBig, readSecret(io, long, &buf));
}

/// the secrets among `names` that `store` has no value for, checked
/// before the disk is erased rather than when the build gets to them.
fn unsetSecrets(a: Allocator, store: ?secrets.Store, names: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (names) |name| {
        const found = if (store) |s| try s.get(a, name) else .unknown;
        switch (found) {
            .value => |v| secrets.wipe(v),
            // the names are the config's, which goes before they're read.
            else => try out.append(a, try a.dupe(u8, name)),
        }
    }
    return out.items;
}

fn fail(ctx: *Context, why: []const u8) !u8 {
    return cli.fail(ctx, "{s}\nyos: the install stopped there. the disk isn't bootable yet; run it again to start over.", .{why});
}

const Step = struct {
    what: []const u8,
    run: *const fn (in: *Installer) anyerror!?[]const u8,
    /// only with --encrypt.
    encrypted: bool = false,
};

const steps = [_]Step{
    .{ .what = "partition the disk: an esp and a btrfs filesystem", .run = Installer.partition },
    .{ .what = "encrypt the btrfs partition with luks2", .run = Installer.luks, .encrypted = true },
    .{ .what = "make the filesystems and their subvolumes", .run = Installer.filesystems },
    .{ .what = "mount them at " ++ install.target, .run = Installer.mount },
    .{ .what = "build the machine from the config and the lock", .run = Installer.build },
    .{ .what = "move the pacman database into /usr, write fstab, and add yos's units", .run = Installer.settle },
    .{ .what = "put the config in /var/lib/yos/config, mounted at /etc/yos", .run = Installer.config },
};

const Installer = struct {
    ctx: *Context,
    a: Allocator,
    disk: []const u8,
    /// where the host's machine.toml is, under the staged config.
    config_rel: []const u8 = "machine.toml",
    esp: []const u8 = "",
    /// the device btrfs goes on: the partition, or with --encrypt, the
    /// luks volume on it, opened.
    root: []const u8 = "",
    encrypt: bool = false,
    tpm: bool = false,
    /// the passphrase from --passphrase-file. it only ever goes to
    /// cryptsetup and systemd-cryptenroll on their standard input.
    secret: ?[]const u8 = null,
    /// the luks volume's uuid, which the kernel's command line names.
    luks_uuid: []const u8 = "",
    luks_device: []const u8 = "",
    /// the config's url, shown in the plan, or null for a local directory.
    source: ?[]const u8 = null,

    /// how to give the accounts passwords after an install that didn't ask:
    /// the new root is mounted only inside this run, and goes with it.
    fn noPasswords(in: *Installer) !void {
        const out = in.ctx.out;
        try out.writeAll("\naccounts have no passwords yet, so no one can log in on the console. an ssh key in the config's [files] gets you in; or, before rebooting:\n");
        const root = if (in.encrypt) "/dev/mapper/newroot" else in.root;
        if (in.encrypt) try out.print("  cryptsetup open {s} newroot\n", .{in.luks_device});
        try out.print("  mount -o subvol=/" ++ generation.roots_dir ++ "/1 {s} /mnt\n  passwd -R /mnt <user>\n  umount /mnt\n", .{root});
        if (in.encrypt) try out.writeAll("  cryptsetup close newroot\n");
    }

    fn run(in: *Installer, argv: []const []const u8) !?[]const u8 {
        return exec.run(in.a, in.ctx.io, argv);
    }

    fn at(in: *Installer, rel: []const u8) ![]const u8 {
        return std.fs.path.join(in.a, &.{ install.target, rel });
    }

    /// the config, cloned if it's a git repository or a url, and copied
    /// if it's a plain directory. the host's machine.toml becomes the
    /// config this run reads.
    fn fetch(in: *Installer, source: []const u8, host: ?[]const u8) !?[]const u8 {
        if (!rootfs.makePrivateDir()) return "can't make " ++ rootfs.private_dir;
        if (try in.run(&.{ "rm", "-rf", staging })) |w| return w;
        if (try in.run(&.{ "mkdir", "-p", std.fs.path.dirnamePosix(staging).? })) |w| return w;
        const local = rootfs.pathExists(in.ctx.io, source);
        const git = !local or rootfs.pathExists(in.ctx.io, try std.fs.path.join(in.a, &.{ source, ".git" }));
        // a password or token in the url stays out of the new machine's
        // config repository, which anyone there can read, and out of
        // messages.
        const shown = try withoutCredentials(in.a, source);
        if (!local and plainTransport(source)) {
            return try std.fmt.allocPrint(in.a, "{s} comes over a connection anything on the way could change, and a config says what runs as root. fetch it with https or ssh", .{shown});
        }
        // the same goes for a redirect from an https url to one of them.
        const why = if (git)
            try in.run(try history.gitArgv(in.a, &.{ "-c", "protocol.http.allow=never", "-c", "protocol.git.allow=never", "-c", "protocol.ftp.allow=never", "clone", "-q", "--", source, staging })) orelse
                if (shown.len != source.len) try in.run(try history.gitArgv(in.a, &.{ "-C", staging, "remote", "set-url", "origin", shown })) else null
        else
            // the copy is root's, as a clone is: the source's owner, a
            // user, would own the new machine's /etc/yos.
            try exec.runAll(in.a, in.ctx.io, &.{
                &.{ "mkdir", "-p", staging },
                &.{ "cp", "-a", "--no-preserve=ownership", try std.fmt.allocPrint(in.a, "{s}/.", .{source}), staging },
                &.{ "chmod", "0755", staging },
            });
        if (why) |w| return try std.fmt.allocPrint(in.a, "can't fetch the config from {s}: {s}", .{ shown, try std.mem.replaceOwned(u8, in.a, w, source, shown) });
        if (!local) in.source = shown;
        if (host) |h| in.config_rel = try std.fmt.allocPrint(in.a, "hosts/{s}/machine.toml", .{h});
        const path = try std.fs.path.join(in.a, &.{ staging, in.config_rel });
        if (!rootfs.pathExists(in.ctx.io, path)) return try std.fmt.allocPrint(in.a, "{s} has no {s}", .{ shown, in.config_rel });
        in.ctx.config_path = path;
        return null;
    }

    /// what the checks and the summary need: the disk, the firmware, and
    /// what the config and its lock ask for.
    fn look(in: *Installer, host: ?[]const u8, update: bool) !?install.Found {
        const ctx = in.ctx;
        var w: cli.Work = .init(ctx);
        defer w.deinit();
        const loaded = try w.config() orelse {
            _ = try w.fail();
            return null;
        };
        const c = &loaded.config;
        const l = try locking.readLock(ctx, in.a, ctx.config_path) orelse {
            try ctx.err.writeAll("yos: the config has no machine.lock beside it. make one with `yos update` on a machine it describes, or install with --update.\n");
            return null;
        };
        var users: std.ArrayList([]const u8) = .empty;
        for (c.users.entries.items) |u| try users.append(in.a, try in.a.dupe(u8, u.name));
        // one of the kernels arch ships, or the one the config names.
        var has_kernel = if (c.boot.kernel) |k| l.package(k.v) != null else false;
        for (catalog.kernels) |k| has_kernel = has_kernel or l.package(k) != null;
        const name = std.fs.path.basename(in.disk);
        const size = switch (try exec.output(in.a, ctx.io, &.{ "blockdev", "--getsize64", in.disk })) {
            .ok => |t| std.fmt.parseInt(u64, std.mem.trim(u8, t, " \n"), 10) catch 0,
            .failed => 0,
        };
        const mounts = switch (try exec.output(in.a, ctx.io, &.{ "lsblk", "-nro", "MOUNTPOINTS", in.disk })) {
            .ok => |t| std.mem.trim(u8, t, " \n"),
            .failed => "",
        };
        var tpm_version: [8]u8 = undefined;
        var sudo_user = false;
        if (l.package("sudo") != null) {
            for (c.users.entries.items) |u| sudo_user = sudo_user or u.value.groups.contains("wheel");
        }
        return .{
            .missing = try in.missingTools(),
            .virtual = try exec.run(in.a, ctx.io, &.{ "systemd-detect-virt", "-q" }) == null,
            .firmware = l.package("linux-firmware") != null,
            .network = health.networked(c),
            .sudo_user = sudo_user,
            .source = in.source,
            .disk = in.disk,
            .size = size,
            .whole = rootfs.pathExists(ctx.io, try std.fmt.allocPrint(in.a, "/sys/class/block/{s}", .{name})) and
                !rootfs.pathExists(ctx.io, try std.fmt.allocPrint(in.a, "/sys/class/block/{s}/partition", .{name})),
            .mounted = mounts.len > 0,
            .holders = try holders(in.a, ctx.io, "/sys/class/block", name),
            .uefi = rootfs.pathExists(ctx.io, "/sys/firmware/efi"),
            .host = host orelse if (c.system.hostname) |h| try in.a.dupe(u8, h.v) else "this machine",
            .host_flag = host != null,
            .hostname = if (c.system.hostname) |h| try in.a.dupe(u8, h.v) else null,
            .packages = l.packages.len,
            .users = users.items,
            .services = c.services.entries.items.len,
            .aur = c.aur.items.items.len,
            .lock_date = try in.a.dupe(u8, l.sync_date),
            .today = try locking.today(ctx.io, in.a),
            .update = update,
            .has_kernel = has_kernel,
            .has_grub = l.package("grub") != null,
            .has_btrfs_progs = l.package("btrfs-progs") != null,
            .encrypt = in.encrypt,
            .secure_boot = if (c.boot.secure_boot) |v| v.v else false,
            .tpm = in.tpm,
            .passphrase_file = in.secret != null,
            .interactive = ctx.interactive,
            .config_encrypt = if (c.boot.encrypt) |e| e.v else false,
            .has_tpm = facts.isTpm2(rootfs.readHead(ctx.io, "/" ++ facts.tpm_version_rel, &tpm_version)),
            .has_tpm2_tss = l.package("tpm2-tss") != null,
            .secrets_unset = try unsetSecrets(in.a, ctx.secrets, (try planner.wanted(in.a, c)).secrets),
        };
    }

    /// what the install runs and the live system lacks.
    fn missingTools(in: *Installer) ![]const []const u8 {
        var missing: std.ArrayList([]const u8) = .empty;
        var wanted: std.ArrayList([]const u8) = .empty;
        try wanted.appendSlice(in.a, &install.tools);
        if (in.encrypt) try wanted.appendSlice(in.a, &install.encrypt_tools);
        if (in.tpm) try wanted.appendSlice(in.a, &install.tpm_tools);
        for (wanted.items) |t| {
            if (!rootfs.pathExists(in.ctx.io, try std.fmt.allocPrint(in.a, "/usr/bin/{s}", .{t}))) try missing.append(in.a, t);
        }
        if (in.tpm and !rootfs.pathExists(in.ctx.io, install.tpm_library)) try missing.append(in.a, "tpm2-tss");
        return missing.items;
    }

    fn partition(in: *Installer) !?[]const u8 {
        const script = "/run/yos/install/partitions";
        rootfs.writeAtomic(in.ctx.io, script, try install.partitionScript(in.a), null) catch return "can't write the partition table's script";
        // an earlier run that stopped may have left its luks volume open,
        // which holds the disk.
        in.closeLuks();
        if (try in.run(&.{ "wipefs", "-q", "-a", in.disk })) |w| return w;
        if (try exec.runFrom(in.a, in.ctx.io, &.{ "sfdisk", "-q", in.disk }, script)) |w| return w;
        in.esp = try install.partition(in.a, in.disk, 1);
        in.root = try install.partition(in.a, in.disk, 2);
        return in.run(&.{ "udevadm", "settle" });
    }

    /// luks2 on the btrfs partition, with a tpm key beside the passphrase
    /// for --tpm, opened for the rest of the install. the passphrase comes
    /// from --passphrase-file, or cryptsetup asks for it.
    fn luks(in: *Installer) !?[]const u8 {
        const part = in.root;
        const made = if (in.secret) |s| try in.luksFromFile(part, s) else try in.luksAsking(part);
        if (made) |w| return w;
        in.luks_uuid = switch (try exec.output(in.a, in.ctx.io, &.{ "cryptsetup", "luksUUID", part })) {
            .ok => |t| std.mem.trim(u8, t, " \n"),
            .failed => |w| return w,
        };
        in.luks_device = part;
        in.root = "/dev/mapper/" ++ install.luks_install_name;
        return null;
    }

    /// luks on `part` with the passphrase `secret`, which each program
    /// reads on its standard input.
    fn luksFromFile(in: *Installer, part: []const u8, secret: []const u8) !?[]const u8 {
        const io = in.ctx.io;
        if (try exec.runInput(in.a, io, &.{ "cryptsetup", "luksFormat", "--type", "luks2", "--batch-mode", "--key-file=-", part }, secret)) |w| return w;
        if (in.tpm) {
            if (try exec.runInput(in.a, io, try install.enrollArgv(in.a, part, true), secret)) |w| return w;
        }
        return exec.runInput(in.a, io, &.{ "cryptsetup", "open", "--key-file=-", part, install.luks_install_name }, secret);
    }

    /// luks on `part`, with cryptsetup and systemd-cryptenroll asking for
    /// the passphrase on the terminal.
    fn luksAsking(in: *Installer, part: []const u8) !?[]const u8 {
        const io = in.ctx.io;
        try in.say(if (in.tpm)
            "\ncryptsetup asks for the disk's passphrase, twice. the tpm unlocks the disk at boot, and the passphrase is the way in when it can't, so keep it safe:\n"
        else
            "\ncryptsetup asks for the disk's passphrase, twice. it's typed at every boot:\n");
        if (try exec.interactive(in.a, io, &.{ "cryptsetup", "luksFormat", "--type", "luks2", "--batch-mode", "--verify-passphrase", part })) |w| return w;
        if (in.tpm) {
            try in.say("\nonce more, to add a key the tpm keeps:\n");
            if (try exec.interactive(in.a, io, try install.enrollArgv(in.a, part, false))) |w| return w;
        }
        try in.say("\nand once more, to open it for the install:\n");
        return exec.interactive(in.a, io, &.{ "cryptsetup", "open", part, install.luks_install_name });
    }

    /// `text`, on the terminal before the program that asks runs.
    fn say(in: *Installer, text: []const u8) !void {
        try in.ctx.out.writeAll(text);
        try in.ctx.out.flush();
    }

    /// the luks volume an install opens, closed, if it's open: this one's,
    /// or one an earlier --encrypt run left when it was cut off, which
    /// holds the disk even for an install without --encrypt. right after
    /// an unmount the kernel can still hold it for a moment, so a busy
    /// close is tried again. one that never closes is said, since the
    /// disk stays in use until it does.
    fn closeLuks(in: *Installer) void {
        const mapped = "/dev/mapper/" ++ install.luks_install_name;
        var why: []const u8 = "";
        for (0..close_tries) |_| {
            if (!rootfs.pathExists(in.ctx.io, mapped)) return;
            why = (exec.run(in.a, in.ctx.io, &.{ "cryptsetup", "close", install.luks_install_name }) catch return) orelse return;
            in.ctx.io.sleep(.fromSeconds(1), .awake) catch {};
        }
        in.ctx.err.print("yos: {s} is still open ({s}). `cryptsetup close {s}` closes it once nothing uses it.\n", .{ mapped, why, install.luks_install_name }) catch {};
    }

    const close_tries = 5;

    /// the esp, and btrfs with every subvolume generation 1 and its data
    /// live in.
    fn filesystems(in: *Installer) !?[]const u8 {
        const top = "/run/yos/install/top";
        if (try exec.runAll(in.a, in.ctx.io, &.{
            &.{ "mkfs.fat", "-F", "32", "-n", "ESP", in.esp },
            &.{ "mkfs.btrfs", "-q", "-f", "-L", "yos", in.root },
            &.{ "mkdir", "-p", top },
            &.{ "mount", "-o", "subvolid=5", in.root, top },
        })) |w| return w;
        defer _ = exec.run(in.a, in.ctx.io, &.{ "umount", top }) catch {};
        var subvols: std.ArrayList([]const u8) = .empty;
        try subvols.appendSlice(in.a, &.{ generation.roots_dir, generation.roots_dir ++ "/1", generation.gens_dir, generation.var_subvol });
        for (generation.data_dirs) |d| try subvols.append(in.a, d.subvol);
        for (subvols.items) |sv| {
            const path = try std.fs.path.join(in.a, &.{ top, sv });
            // @roots and @gens only hold the others.
            const made = if (std.mem.eql(u8, sv, generation.roots_dir) or std.mem.eql(u8, sv, generation.gens_dir))
                std.Io.Dir.cwd().createDirPath(in.ctx.io, path)
            else
                btrfs.create(path);
            made catch |e| return try std.fmt.allocPrint(in.a, "can't make {s}: {s}", .{ sv, @errorName(e) });
        }
        // pacman leaves a directory that's there already as it is, so the
        // data subvolumes' tops get the filesystem package's modes now:
        // /root isn't for everyone to read.
        for (generation.data_dirs) |d| {
            if (try in.run(&.{ "chmod", d.mode, try std.fs.path.join(in.a, &.{ top, d.subvol }) })) |w| return w;
        }
        return null;
    }

    /// generation 1 at the target, its data subvolumes and the esp in it.
    fn mount(in: *Installer) !?[]const u8 {
        if (try in.run(&.{ "mkdir", "-p", install.target })) |w| return w;
        if (try in.run(&.{ "mount", "-o", "compress=zstd,subvol=/" ++ generation.roots_dir ++ "/1", in.root, install.target })) |w| return w;
        var subs: std.ArrayList([2][]const u8) = .empty;
        try subs.append(in.a, .{ "var", generation.var_subvol });
        for (generation.data_dirs) |d| try subs.append(in.a, .{ d.dir, d.subvol });
        for (subs.items) |s| {
            const point = try in.at(s[0]);
            if (try exec.runAll(in.a, in.ctx.io, &.{
                &.{ "mkdir", "-p", point },
                &.{ "mount", "-o", try std.fmt.allocPrint(in.a, "compress=zstd,subvol=/{s}", .{s[1]}), in.root, point },
            })) |w| return w;
        }
        const boot = try in.at("boot");
        return exec.runAll(in.a, in.ctx.io, &.{
            &.{ "mkdir", "-p", boot },
            &.{ "mount", "-o", "fmask=0077,dmask=0077", in.esp, boot },
        });
    }

    /// the clean build, into the mounted disk. packages download onto it,
    /// not into the live system's memory.
    fn build(in: *Installer) !?[]const u8 {
        var keep: std.ArrayList([]const u8) = .empty;
        for ([_][]const u8{ "var", "home", "root", "srv", "usr/local", "boot" }) |d| try keep.append(in.a, try in.at(d));
        var b: building.Builder = .{ .ctx = in.ctx, .a = in.a, .dir = install.target, .share_cache = false, .seed_config = false, .keep = keep.items };
        defer b.unmount();
        if (try b.prepare()) |w| return w;
        if (try b.install() != 0) return "building the machine failed; the lines above say why";
        return null;
    }

    /// what enable-rollback would have done: the pacman database beside
    /// the /usr it describes, fstab, yos's units, and yos itself.
    fn settle(in: *Installer) !?[]const u8 {
        const db = try in.at("var/lib/pacman");
        const moved = try in.at(generation.pacman_db);
        if (try exec.runAll(in.a, in.ctx.io, &.{
            &.{ "mkdir", "-p", std.fs.path.dirnamePosix(moved).? },
            &.{ "mv", db, moved },
            &.{ "ln", "-s", "/" ++ generation.pacman_db, db },
        })) |w| return w;
        var why: []const u8 = "";
        const root_uuid = try in.uuid(in.root, &why) orelse return why;
        const fstab = try enable.rewriteFstab(in.a, try std.fmt.allocPrint(in.a, "UUID={s} / btrfs rw,relatime,compress=zstd 0 0\n", .{root_uuid}), .{
            .uuid = root_uuid,
            .add_var = true,
            .data = &generation.data_dirs,
            .bind_config = true,
            .esp = .{ .uuid = try in.uuid(in.esp, &why) orelse return why, .point = "/boot" },
        });
        rootfs.writeAtomic(in.ctx.io, try in.at("etc/fstab"), fstab, null) catch return "can't write fstab";
        // yos comes along as it runs here, in /usr/local, which is data.
        const self = try std.process.executablePathAlloc(in.ctx.io, in.a);
        const os_path = "/usr/local/bin/yos";
        if (try in.run(&.{ "install", "-D", "-m", "0755", self, try in.at(os_path[1..]) })) |w| return w;
        return gens.writeUnits(in.a, in.ctx.io, install.target, os_path);
    }

    fn config(in: *Installer) !?[]const u8 {
        return exec.runAll(in.a, in.ctx.io, &.{
            &.{ "mkdir", "-p", try in.at("etc/yos"), try in.at(enable.config_home[1..]) },
            &.{ "cp", "-a", staging ++ "/.", try in.at(enable.config_home[1..]) },
        });
    }

    /// a password for root and each user the config has, typed at passwd.
    fn passwords(in: *Installer) !void {
        var w: cli.Work = .init(in.ctx);
        defer w.deinit();
        var names: std.ArrayList([]const u8) = .empty;
        try names.append(in.a, "root");
        if (try w.config()) |loaded| {
            for (loaded.config.users.entries.items) |u| try names.append(in.a, try in.a.dupe(u8, u.name));
        }
        for (names.items) |n| {
            try in.ctx.out.print("\na password for {s}:\n", .{n});
            try in.ctx.out.flush();
            if (try exec.interactive(in.a, in.ctx.io, &.{ "passwd", "-R", install.target, n })) |why| {
                try in.ctx.err.print("yos: {s}; {s} has no password yet. `passwd {s}` sets one later.\n", .{ why, n, n });
            }
        }
    }

    /// generation 1: its read-only record, the record file, the menu,
    /// and grub, both at the removable path every firmware looks at and,
    /// where efibootmgr can, as a boot entry of its own.
    fn recordFirst(in: *Installer) !?[]const u8 {
        try in.say("  record generation 1, and install grub with its menu\n");
        const boot = in.bootFacts();
        var why: []const u8 = "";
        var m = try gens.Machine.open(in.a, in.ctx.io, boot, &why) orelse return why;
        defer m.close();
        m.cmdline = try in.kernelArgs();
        m.esp_is_boot = true;
        if (try m.keepBoot(boot.root_subvol.?)) |w| return w;
        btrfs.snapshot(try m.at(&.{boot.root_subvol.?}), try m.at(&.{ generation.gens_dir, "1" }), true) catch |e|
            return try std.fmt.allocPrint(in.a, "can't record generation 1: {s}", .{@errorName(e)});
        const rev = switch (try exec.output(in.a, in.ctx.io, try history.gitArgv(in.a, &.{ "-C", staging, "rev-parse", "HEAD" }))) {
            .ok => |t| std.mem.trim(u8, t, " \n"),
            .failed => null,
        };
        const record: generation.Record = .{
            .n = 1,
            .time = std.Io.Timestamp.now(in.ctx.io, .real).toSeconds(),
            .root = boot.root_subvol.?[1..],
            .reason = "install",
            .config_dir = try std.fs.path.join(in.a, &.{ "/etc/yos", std.fs.path.dirnamePosix(in.config_rel) orelse "" }),
            .config_rev = rev,
        };
        if (try gens.writeRecord(in.a, in.ctx.io, try in.at("var"), record)) |w| return w;
        if (try m.writeMenu(boot.root_subvol.?, &.{record})) |w| return w;
        const esp = boot.esp.?;
        if (try exec.runAll(in.a, in.ctx.io, &.{
            &.{ "mkdir", "-p", try std.fs.path.join(in.a, &.{ esp, "yos" }) },
            &.{ "grub-editenv", try std.fs.path.join(in.a, &.{ esp, generation.grubenv }), "create" },
            try bootmenu.grubInstallAt(in.a, esp, esp, "--removable"),
        })) |w| return w;
        if (try in.run(&.{ "efibootmgr", "--version" }) == null) {
            if (try in.run(try bootmenu.grubInstallAt(in.a, esp, esp, "--bootloader-id=yos"))) |w| {
                try in.ctx.err.print("yos: no boot entry of its own ({s}); the disk still boots from the removable path.\n", .{w});
            }
        }
        return null;
    }

    /// how the new machine boots, as its facts will say once it runs.
    fn bootFacts(in: *Installer) facts.Boot {
        var boot: facts.Boot = .{
            .uefi = true,
            .esp = install.target ++ "/boot",
            .esp_device = in.esp,
            .loader = "grub",
            .root_fs = "btrfs",
            .root_device = in.root,
            .root_subvol = "/" ++ generation.roots_dir ++ "/1",
        };
        if (in.encrypt) {
            boot.luks_uuid = in.luks_uuid;
            boot.luks_name = install.luks_name;
            boot.luks_device = in.luks_device;
        }
        return boot;
    }

    /// the new machine's kernel arguments: the live system's consoles, and
    /// with --encrypt, what unlocks its root.
    fn kernelArgs(in: *Installer) ![]const u8 {
        const args = try install.consoleArgs(in.a, try rootfs.readProc(in.a, in.ctx.io, "/proc/cmdline"));
        if (!in.encrypt) return args;
        return std.fmt.allocPrint(in.a, "{s} {s}", .{ args, try install.luksArgs(in.a, in.luks_uuid, in.tpm) });
    }

    fn uuid(in: *Installer, device: []const u8, why: *[]const u8) !?[]const u8 {
        return switch (try exec.output(in.a, in.ctx.io, &.{ "blkid", "-s", "UUID", "-o", "value", device })) {
            .ok => |t| std.mem.trim(u8, t, " \n"),
            .failed => |w| {
                why.* = try std.fmt.allocPrint(in.a, "can't read {s}'s uuid: {s}", .{ device, w });
                return null;
            },
        };
    }

    /// everything under the target, however the install ended, deepest
    /// first and not lazily where it can be, then the luks volume under
    /// it, which a lazily detached mount would keep busy.
    fn unmountAll(in: *Installer) void {
        // cleaning up, cut off, would leave the disk held.
        const stops = exec.Stops.ignore();
        defer stops.restore();
        // what the install said goes out before any warning from here.
        in.ctx.out.flush() catch {};
        const lazy = building.unmountTree(in.a, in.ctx.io, install.target, &.{}, true) catch &.{};
        for (lazy) |p| in.ctx.err.print("yos: {s} was busy, so it was detached lazily; its disk stays in use until whatever holds it stops.\n", .{p}) catch {};
        in.closeLuks();
    }
};

/// `url` without a user and password before its host, like
/// "https://user:token@host/repo" as "https://host/repo". an ssh url's
/// user is only a name, and ssh needs it.
/// the devices that hold the disk `name` or one of its partitions, from
/// sysfs at `block`: lvm's volumes and open luks devices (dm-*), and md
/// arrays. the live iso starts lvm and md on the disks it finds without
/// mounting anything, and wipefs can't erase a disk they hold.
fn holders(a: Allocator, io: std.Io, block: []const u8, name: []const u8) ![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    const disk = try std.fs.path.join(a, &.{ block, name });
    try holdersOf(a, io, disk, &found);
    var dir = std.Io.Dir.cwd().openDir(io, disk, .{ .iterate = true }) catch return found.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (!std.mem.startsWith(u8, e.name, name)) continue;
        const part = try std.fs.path.join(a, &.{ disk, e.name });
        if (!rootfs.pathExists(io, try std.fs.path.join(a, &.{ part, "partition" }))) continue;
        try holdersOf(a, io, part, &found);
    }
    lists.sortStrings(found.items);
    return found.items;
}

fn holdersOf(a: Allocator, io: std.Io, dev: []const u8, found: *std.ArrayList([]const u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, try std.fs.path.join(a, &.{ dev, "holders" }), .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (!lists.contains(found.items, e.name)) try found.append(a, try a.dupe(u8, e.name));
    }
}

test "a disk held by lvm, md, or luks without a mount is found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const block = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "vdb/holders");
    try std.testing.expectEqual(0, (try holders(a, io, block, "vdb")).len);
    // lvm on the second partition, and md on the whole disk.
    try tmp.dir.createDirPath(io, "vdb/vdb1/holders");
    try tmp.dir.writeFile(io, .{ .sub_path = "vdb/vdb1/partition", .data = "1\n" });
    try tmp.dir.createDirPath(io, "vdb/vdb2/holders/dm-1");
    try tmp.dir.createDirPath(io, "vdb/vdb2/holders/dm-0");
    try tmp.dir.writeFile(io, .{ .sub_path = "vdb/vdb2/partition", .data = "2\n" });
    try tmp.dir.createDirPath(io, "vdb/holders/md127");
    // a directory that isn't a partition doesn't count.
    try tmp.dir.createDirPath(io, "vdb/vdbx/holders/dm-9");
    const got = try holders(a, io, block, "vdb");
    try std.testing.expectEqual(3, got.len);
    try std.testing.expectEqualStrings("dm-0", got[0]);
    try std.testing.expectEqualStrings("dm-1", got[1]);
    try std.testing.expectEqualStrings("md127", got[2]);
    try std.testing.expectEqual(0, (try holders(a, io, block, "missing")).len);
}

fn withoutCredentials(a: std.mem.Allocator, url: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return url;
    const scheme = std.mem.indexOf(u8, url, "://").?;
    const host = scheme + 3;
    const end = std.mem.indexOfScalarPos(u8, url, host, '/') orelse url.len;
    const at = std.mem.lastIndexOfScalar(u8, url[host..end], '@') orelse return url;
    return std.mem.concat(a, u8, &.{ url[0..host], url[host + at + 1 ..] });
}

/// whether git fetches `url` without checking who sent it: http, git's
/// own protocol, and ftp.
fn plainTransport(url: []const u8) bool {
    for ([_][]const u8{ "http://", "git://", "ftp://" }) |scheme| {
        if (std.ascii.startsWithIgnoreCase(url, scheme)) return true;
    }
    return false;
}

test "a config only comes over a connection that's checked" {
    try std.testing.expect(plainTransport("http://example.com/config.git"));
    try std.testing.expect(plainTransport("git://example.com/config.git"));
    try std.testing.expect(plainTransport("FTP://example.com/config.git"));
    try std.testing.expect(!plainTransport("https://example.com/config.git"));
    try std.testing.expect(!plainTransport("ssh://git@example.com/config.git"));
    try std.testing.expect(!plainTransport("git@example.com:config.git"));
}

test "a cloned config waits where only root can read it" {
    try std.testing.expect(std.mem.startsWith(u8, staging, rootfs.private_dir ++ "/"));
}

test "a url's credentials stay out" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("https://host/repo.git", try withoutCredentials(a, "https://user:tok@en@host/repo.git"));
    try std.testing.expectEqualStrings("https://host/a@b", try withoutCredentials(a, "https://host/a@b"));
    try std.testing.expectEqualStrings("git@host:repo", try withoutCredentials(a, "git@host:repo"));
    try std.testing.expectEqualStrings("ssh://git@host/repo", try withoutCredentials(a, "ssh://git@host/repo"));
    try std.testing.expectEqualStrings("/srv/config", try withoutCredentials(a, "/srv/config"));
}

test {
    _ = lock;
}

test "the secrets an install would stop at" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem: secrets.Memory = .init(std.testing.allocator);
    defer mem.deinit();
    _ = try mem.store().set(a, "wifi/home", "hunter2");
    const unset = try unsetSecrets(a, mem.store(), &.{ "vpn", "wifi/home" });
    try std.testing.expectEqual(1, unset.len);
    try std.testing.expectEqualStrings("vpn", unset[0]);
    try std.testing.expectEqual(2, (try unsetSecrets(a, null, &.{ "vpn", "wifi/home" })).len);
}
