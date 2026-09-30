//! `os build --clean <dir>`: builds a root from nothing but the config and
//! the lock, the way pacstrap would, then lists what this machine has in
//! /etc and /usr that the build doesn't explain. the installer will be the
//! same build, aimed at a blank disk.

const std = @import("std");
const rootfs = @import("../rootfs.zig");
const cli = @import("../cli.zig");
const exec = @import("../exec.zig");
const lists = @import("../lists.zig");
const output = @import("../output.zig");
const planner = @import("../planner.zig");
const pipeline = @import("../pipeline.zig");
const facts = @import("../facts.zig");
const applying = @import("apply.zig");
const Context = cli.Context;
const Allocator = std.mem.Allocator;

const usage_text = "os build --clean <dir>";

/// the mkinitcpio drop-in a build uses while it runs. the observer skips
/// files named 10-yoq-, so it doesn't show up in a plan.
const no_autodetect = "etc/mkinitcpio.conf.d/10-yoq-build.conf";

/// what a new root takes from this machine before anything installs: how
/// pacman is set up, its keyring, the config, and the uid map, so users
/// get the same ids. os's own repositories aren't among them: the config
/// brings those, and pacman.conf comes without the line that reads them.
const seeded = [_][]const u8{
    "etc/pacman.conf",
    "etc/pacman.d/mirrorlist",
    "etc/pacman.d/gnupg",
    "etc/yoq",
    "var/lib/yoq/ids",
};

/// files every build makes again, or that hold this machine's own state,
/// so they can't explain or be explained.
const ignored = [_][]const u8{
    "etc/machine-id",
    "etc/adjtime",
    "etc/shadow",
    "etc/gshadow",
    "etc/passwd-",
    "etc/group-",
    "etc/shadow-",
    "etc/gshadow-",
    "etc/subuid",
    "etc/subgid",
    "etc/resolv.conf",
    "etc/ld.so.cache",
    "etc/pacman.d/gnupg/",
    "etc/ssh/ssh_host_",
    "etc/yoq/",
    "etc/.pwd.lock",
    "etc/.updated",
    "usr/.updated",
    "usr/local/",
    "usr/lib/sysimage/pacman/",
};

pub fn buildCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (args.len != 2 or !cli.eql(args[0], "--clean")) return cli.usageError(ctx, usage_text);
    const dir: []const u8 = args[1];
    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    if (try cli.needsHost(ctx, "a build installs packages and mounts filesystems")) return 1;
    if (try cli.refused(ctx, applying.blocker(ctx))) return 1;
    if (dir.len == 0 or dir[0] != '/' or std.mem.trimEnd(u8, dir, "/").len == 0) {
        return cli.fail(ctx, "{s} has to be an absolute path, and not /.", .{dir});
    }
    // made here, only root can write in it: a directory someone else made
    // could have hooks or symlinks planted in it while the build runs.
    // others can still read it, since pacman downloads as its own user
    // into the caches inside.
    var z: [std.fs.max_path_bytes]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&z, "{s}", .{dir}) catch return cli.usageError(ctx, usage_text);
    if (std.os.linux.errno(std.os.linux.mkdir(dir_z, 0o755)) != .SUCCESS) {
        return cli.fail(ctx, "can't make {s}. a clean build starts from nothing, in a directory it makes itself, so it can't be there already.", .{dir});
    }
    // unmounting finds the mounts by this path in mountinfo, which has it
    // resolved and escapes spaces and the like, so it has to match that.
    const real = std.Io.Dir.cwd().realPathFileAlloc(ctx.io, dir, a) catch {
        try ctx.err.print("os: can't resolve {s}.\n", .{dir});
        return 1;
    };
    if (std.mem.indexOfAny(u8, real, " \t\n\\") != null) {
        try ctx.err.print("os: {s} can't have spaces or backslashes in it.\n", .{real});
        return 1;
    }
    var b: Builder = .{ .ctx = ctx, .a = a, .dir = real };
    // on every way out: a bind of /dev left behind would take the host's
    // device nodes with it when someone removes the directory.
    {
        defer b.unmount();
        if (try b.prepare()) |why| return cli.fail(ctx, "{s}", .{why});
        const code = try b.install();
        if (code != 0) return code;
    }
    return b.report();
}

/// a root built from the config and lock in a directory, by `os build
/// --clean` here and by `os install` on a new disk.
pub const Builder = struct {
    ctx: *Context,
    a: Allocator,
    dir: []const u8,
    /// packages and databases come from this machine's cache, bound in.
    /// an install from a live system keeps them on the new disk instead,
    /// since the live system's /var is memory.
    share_cache: bool = true,
    /// this machine's config and uid map go in too. an install brings
    /// its own config.
    seed_config: bool = true,
    /// mounts under `dir` that were there before, which stay.
    keep: []const []const u8 = &.{},
    /// the next generation, staged from a snapshot of the running root: it
    /// has pacman's setup and the config already, and the running /var is
    /// bound in whole, as a live apply would see it. its initramfs can
    /// autodetect, since it's for this machine.
    staged: bool = false,
    /// what the build plans from, when not the command's own: an update's
    /// pending lock, say.
    inputs: ?pipeline.Inputs = null,

    fn in(b: *Builder, rel: []const u8) ![]const u8 {
        return std.fs.path.join(b.a, &.{ b.dir, rel });
    }

    fn run(b: *Builder, argv: []const []const u8) !?[]const u8 {
        return exec.run(b.a, b.ctx.io, argv);
    }

    /// the new root's first files, and the filesystems package scripts and
    /// hooks expect, mounted as pacstrap mounts them. os's caches are this
    /// machine's, so packages it has already come from there.
    pub fn prepare(b: *Builder) !?[]const u8 {
        if (b.staged) return b.mountAll(&(api_mounts ++ .{.{ "var", &.{ "--rbind", "--make-rslave", "/var" } }}));
        for ([_][]const u8{ "var/lib/pacman", "var/cache/yoq", "proc", "sys", "dev", "run", "tmp", "etc/pacman.d" }) |d| {
            if (try b.run(&.{ "mkdir", "-p", try b.in(d) })) |w| return w;
        }
        for (seeded) |rel| {
            if (!b.seed_config and (std.mem.eql(u8, rel, "etc/yoq") or std.mem.eql(u8, rel, "var/lib/yoq/ids"))) continue;
            const src = try std.fmt.allocPrint(b.a, "/{s}", .{rel});
            if (!rootfs.pathExists(b.ctx.io, src)) continue;
            const dest = try b.in(rel);
            if (try b.run(&.{ "mkdir", "-p", std.fs.path.dirnamePosix(dest).? })) |w| return w;
            if (try b.run(&.{ "cp", "-a", src, dest })) |w| return w;
        }
        const conf = try b.in("etc/pacman.conf");
        if (std.Io.Dir.cwd().readFileAlloc(b.ctx.io, conf, b.a, .limited(1 << 20)) catch null) |text| {
            rootfs.writeAtomic(b.ctx.io, conf, try withoutReposInclude(b.a, text), null) catch return "can't write the build's pacman.conf";
        }
        if (try b.run(&.{ "mkdir", "-p", "/var/cache/yoq" })) |w| return w;
        // mkinitcpio's autodetect looks at the machine the build runs on,
        // not the root it builds, so the first initramfs leaves it out: a
        // generic image, which boots anywhere. `install` takes it away.
        rootfs.writeAtomic(b.ctx.io, try b.in(no_autodetect),
            \\# written by os while it builds this root, and removed after.
            \\_yoq_hooks=()
            \\for _yoq_hook in "${HOOKS[@]}"; do [[ $_yoq_hook == autodetect ]] || _yoq_hooks+=("$_yoq_hook"); done
            \\HOOKS=("${_yoq_hooks[@]}")
            \\unset _yoq_hooks _yoq_hook
            \\
        , null) catch return "can't write the build's mkinitcpio drop-in";
        return b.mountAll(if (b.share_cache)
            &(api_mounts ++ .{.{ "var/cache/yoq", &.{ "--bind", "/var/cache/yoq" } }})
        else
            &api_mounts);
    }

    /// a place under the new root, and the arguments that mount it there.
    const Mount = struct { []const u8, []const []const u8 };

    /// the filesystems package scripts and hooks expect, as pacstrap
    /// mounts them.
    const api_mounts = [_]Mount{
        .{ "proc", &.{ "-t", "proc", "proc" } },
        .{ "sys", &.{ "-t", "sysfs", "-o", "ro", "sys" } },
        .{ "dev", &.{ "--rbind", "--make-rslave", "/dev" } },
        .{ "run", &.{ "-t", "tmpfs", "-o", "mode=0755,nosuid,nodev", "run" } },
    };

    /// mounts each of `mounts` at its place under the new root.
    fn mountAll(b: *Builder, mounts: []const Mount) !?[]const u8 {
        for (mounts) |m| {
            const point = try b.in(m[0]);
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(b.a, "mount");
            try argv.appendSlice(b.a, m[1]);
            try argv.append(b.a, point);
            if (try b.run(argv.items)) |w| return w;
        }
        return null;
    }

    /// unmounts everything under the new root, deepest first, including
    /// what package scripts mounted there. a mount something still holds
    /// is detached lazily, so it goes once that lets go.
    pub fn unmount(b: *Builder) void {
        const text = rootfs.readProc(b.a, b.ctx.io, "/proc/self/mountinfo") catch return;
        const points = mountsUnder(b.a, text, b.dir) catch return;
        for (points) |p| {
            if (lists.contains(b.keep, p)) continue;
            const failed = exec.run(b.a, b.ctx.io, &.{ "umount", p }) catch return;
            if (failed != null) _ = exec.run(b.a, b.ctx.io, &.{ "umount", "-l", p }) catch return;
        }
    }

    /// the config applied to the new root, then its units turned on
    /// there, since no systemd runs it to start them.
    pub fn install(b: *Builder) anyerror!u8 {
        const ctx = b.ctx;
        const host = ctx.root;
        ctx.root = b.dir;
        defer ctx.root = host;
        var from = b.inputs orelse cli.inputs(ctx);
        from.root = b.dir;
        const done = try applying.run(ctx, true, from, .{ .render = .{ .quiet = b.staged } });
        if (!b.staged) std.Io.Dir.cwd().deleteFile(ctx.io, try b.in(no_autodetect)) catch {};
        if (done.code != 0) return done.code;
        var w: cli.Work = .init(ctx);
        defer w.deinit();
        const result = try w.plan(from) orelse return w.fail();
        for (result.plan.changes) |c| {
            if (c.kind != .unit) continue;
            const verb = if (c.op == .remove) "disable" else "enable";
            if (try b.run(&.{ "systemctl", try std.fmt.allocPrint(b.a, "--root={s}", .{b.dir}), verb, "--", c.subject })) |why| {
                return cli.fail(ctx, "couldn't {s} {s} in the build: {s}", .{ verb, c.subject, why });
            }
        }
        return 0;
    }

    /// what this machine has that the build doesn't: files in /etc and
    /// /usr it lacks, and files in /etc whose content differs.
    fn report(b: *Builder) !u8 {
        const ctx = b.ctx;
        const here = try b.files("/");
        const built = try b.files(b.dir);
        var only_here: std.ArrayList([]const u8) = .empty;
        var differ: std.ArrayList([]const u8) = .empty;
        for (here) |rel| {
            if (ignoredPath(rel)) continue;
            if (!sortedHas(built, rel)) {
                try only_here.append(b.a, rel);
                continue;
            }
            if (!std.mem.startsWith(u8, rel, "etc/")) continue;
            if (!try b.same(rel)) try differ.append(b.a, rel);
        }
        if (ctx.json) {
            try output.writeDoc(ctx.out, "yoq.build/1", .{ .root = b.dir, .only_here = only_here.items, .differ = differ.items });
            return 0;
        }
        try ctx.out.print("\nbuilt {s} from the config and the lock.\n", .{b.dir});
        if (only_here.items.len == 0 and differ.items.len == 0) {
            try ctx.out.writeAll("everything in this machine's /etc and /usr is explained by a package or the config.\n");
            return 0;
        }
        try list(ctx, "only on this machine", only_here.items);
        try list(ctx, "different on this machine", differ.items);
        try ctx.out.writeAll("nothing in the config or its packages explains these. `os build --clean <dir> --json` lists them all.\n");
        return 0;
    }

    /// every file and symlink under etc and usr in `root`, relative and
    /// sorted, from one filesystem, since a mount there isn't the root's.
    fn files(b: *Builder, root: []const u8) ![]const []const u8 {
        const prefix = if (std.mem.eql(u8, root, "/")) "/" else try std.fmt.allocPrint(b.a, "{s}/", .{root});
        const argv = [_][]const u8{ "find", try std.fmt.allocPrint(b.a, "{s}etc", .{prefix}), try std.fmt.allocPrint(b.a, "{s}usr", .{prefix}), "-xdev", "(", "-type", "f", "-o", "-type", "l", ")", "-print0" };
        const text = switch (try exec.output(b.a, b.ctx.io, &argv)) {
            .ok, .failed => |t| t,
        };
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, text, 0);
        while (it.next()) |p| {
            if (std.mem.startsWith(u8, p, prefix)) try out.append(b.a, p[prefix.len..]);
        }
        lists.sortStrings(out.items);
        return out.items;
    }

    fn same(b: *Builder, rel: []const u8) !bool {
        const cwd = std.Io.Dir.cwd();
        const mine = cwd.readFileAlloc(b.ctx.io, try std.fmt.allocPrint(b.a, "/{s}", .{rel}), b.a, .limited(1 << 24)) catch return true;
        const theirs = cwd.readFileAlloc(b.ctx.io, try b.in(rel), b.a, .limited(1 << 24)) catch return true;
        return std.mem.eql(u8, mine, theirs);
    }
};

/// the mount points under `dir` in mountinfo's `text`, deepest first.
/// mountinfo escapes spaces and the like as octal, which build paths
/// don't have.
fn mountsUnder(a: Allocator, text: []const u8, dir: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        for (0..4) |_| _ = fields.next();
        const point = fields.next() orelse continue;
        if (point.len > dir.len and std.mem.startsWith(u8, point, dir) and point[dir.len] == '/') try out.append(a, point);
    }
    // a mount under another sorts after it, so reversed, it comes first.
    lists.sortStrings(out.items);
    std.mem.reverse([]const u8, out.items);
    return out.items;
}

/// pacman.conf without the line that includes os's repositories.
fn withoutReposInclude(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), facts.repos_include)) continue;
        try out.print(a, "{s}\n", .{line});
    }
    return out.items;
}

fn sortedHas(sorted: []const []const u8, s: []const u8) bool {
    const Ctx = struct {
        fn order(key: []const u8, item: []const u8) std.math.Order {
            return std.mem.order(u8, key, item);
        }
    };
    return std.sort.binarySearch([]const u8, sorted, s, Ctx.order) != null;
}

fn ignoredPath(rel: []const u8) bool {
    for (ignored) |i| {
        if (std.mem.endsWith(u8, i, "/") or std.mem.endsWith(u8, i, "_")) {
            if (std.mem.startsWith(u8, rel, i)) return true;
        } else if (std.mem.eql(u8, rel, i)) return true;
    }
    return false;
}

/// up to 40 of `paths`, under a heading.
fn list(ctx: *Context, heading: []const u8, paths: []const []const u8) !void {
    if (paths.len == 0) return;
    try ctx.out.print("\n{s} ({d}):\n", .{ heading, paths.len });
    for (paths[0..@min(paths.len, 40)]) |p| try ctx.out.print("  /{s}\n", .{p});
    if (paths.len > 40) try ctx.out.print("  and {d} more\n", .{paths.len - 40});
    try ctx.out.writeByte('\n');
}

test "mounts under a build, deepest first" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const info =
        \\22 1 0:21 / /proc rw - proc proc rw
        \\90 1 0:5 / /var/tmp/clean/dev rw - devtmpfs dev rw
        \\91 90 0:6 / /var/tmp/clean/dev/pts rw - devpts devpts rw
        \\92 1 0:30 / /var/tmp/clean/proc rw - proc proc rw
        \\93 1 0:31 / /var/tmp/cleaner rw - tmpfs t rw
    ;
    const got = try mountsUnder(arena.allocator(), info, "/var/tmp/clean");
    try std.testing.expectEqual(3, got.len);
    try std.testing.expectEqualStrings("/var/tmp/clean/proc", got[0]);
    try std.testing.expectEqualStrings("/var/tmp/clean/dev/pts", got[1]);
    try std.testing.expectEqualStrings("/var/tmp/clean/dev", got[2]);
}

test "a build's pacman.conf leaves out os's repositories" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("[core]\nInclude = /etc/pacman.d/mirrorlist\n", try withoutReposInclude(arena.allocator(), "[core]\nInclude = /etc/pacman.d/mirrorlist\n" ++ facts.repos_include ++ "\n"));
}

test "paths a build can't explain or be explained by" {
    try std.testing.expect(ignoredPath("etc/machine-id"));
    try std.testing.expect(ignoredPath("etc/ssh/ssh_host_ed25519_key"));
    try std.testing.expect(ignoredPath("usr/local/bin/os"));
    try std.testing.expect(!ignoredPath("etc/hostname"));
    try std.testing.expect(!ignoredPath("usr/local"));
}
