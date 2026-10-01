//! the package backend, over libalpm. it reads the local database into
//! facts and resolves wanted packages against sync databases into a lock.
//!
//! build with `-Dalpm` to link libalpm; the work happens in alpm_c.zig.
//! without it, every call returns `error.AlpmUnavailable` and the tests
//! skip, so hosts without libalpm still build and test everything else.

const std = @import("std");
const build_options = @import("build_options");
const facts = @import("facts.zig");
const lock = @import("lock.zig");
const diag = @import("diag.zig");
const rootfs = @import("rootfs.zig");
const progress = @import("progress.zig");
const Allocator = std.mem.Allocator;

pub const available = build_options.alpm;

/// set in the environment of os's own transactions, so the drift hook,
/// which pacman runs as a child, can tell them from pacman run by hand.
pub const own_env = "YOQ_APPLY";
const impl = if (available) @import("alpm_c.zig") else struct {};

/// package hooks os turns off in a transaction into a root other than the
/// running system: a staged generation, a clean build, an install.
/// sbctl's signs the files in its database at their paths on the esp,
/// which isn't mounted in such a root, so it fails there; and os signs
/// everything it puts on the esp itself.
pub const masked_hooks = [_][]const u8{"zz-sbctl.hook"};

/// where the links that mask them go, under the target root, in a hook
/// directory libalpm reads after the root's own. a link to /dev/null is
/// pacman's way to turn a hook off.
pub const masked_dir = "run/yoq-masked-hooks";

/// the hooks masked in a transaction into `root`: none for the running
/// system, where the esp is mounted and the hooks work.
pub fn maskedFor(root: []const u8) []const []const u8 {
    return if (std.mem.trimEnd(u8, root, "/").len == 0) &.{} else &masked_hooks;
}

pub const Error = error{ AlpmUnavailable, OutOfMemory };

pub const SyncDb = struct {
    /// the repository name, like "core".
    name: []const u8,
    /// a `<name>.db` file.
    path: []const u8,
    /// where the repository's packages download from, most preferred first:
    /// directories like https://geo.mirror.pkgbuild.com/core/os/x86_64.
    servers: []const []const u8 = &.{},
    /// its packages are signed and checked. a repository that isn't, like
    /// os's own aur builds, is read as pacman's `Optional TrustAll`.
    signed: bool = true,
};

pub const ResolveInput = struct {
    dbs: []const SyncDb,
    wants: []const []const u8,
    /// choices for virtual packages, from `[providers]` in the config.
    providers: []const lock.Provider = &.{},
    sync_date: []const u8,
    /// an empty directory libalpm can use as a scratch root.
    scratch: []const u8,
};

/// the packages installed in `root`, read from the local database in
/// `dbpath`. strings are copied into `a`.
pub fn localPackages(a: Allocator, root: []const u8, dbpath: []const u8, diags: *diag.List) Error!?[]facts.Package {
    return if (comptime available) impl.localPackages(a, root, dbpath, diags) else error.AlpmUnavailable;
}

/// a virtual package with several providers and no choice in the config.
pub const Choice = struct {
    name: []const u8,
    options: []const []const u8,
};

pub const Resolved = union(enum) {
    lock: lock.Lock,
    /// resolving needs these choices first. nothing went to `diags`.
    choose: []const Choice,
    /// the reasons are in `diags`.
    failed,
};

/// resolves `in.wants` and everything they depend on against the sync
/// databases, the way pacman would install them into an empty root.
pub fn resolve(a: Allocator, io: std.Io, in: ResolveInput, diags: *diag.List) Error!Resolved {
    return if (comptime available) impl.resolve(a, io, in, diags) else error.AlpmUnavailable;
}

/// the names in `in.wants` that no package in the sync databases is
/// called or provides. null, with the reason in `diags`, if the databases
/// can't be read.
pub fn unsatisfied(a: Allocator, io: std.Io, in: ResolveInput, diags: *diag.List) Error!?[]const []const u8 {
    return if (comptime available) impl.unsatisfied(a, io, in, diags) else error.AlpmUnavailable;
}

/// the parts of libalpm's download sandbox to turn off.
pub const Sandbox = struct {
    no_filesystem: bool = false,
    no_syscalls: bool = false,
};

/// the machine a transaction changes, and where its packages come from.
pub const Target = struct {
    root: []const u8,
    /// pacman's database directory for `root`.
    dbpath: []const u8,
    /// the sync databases the lock was resolved against. they replace the
    /// ones in `dbpath`, so libalpm sees exactly the locked versions.
    dbs: []const SyncDb,
    /// where downloaded packages are kept.
    cachedir: []const u8,
    /// pacman's keyring, to check package signatures. null skips checking,
    /// which only tests should do.
    gpgdir: ?[]const u8,
    /// how libalpm downloads, from pacman.conf.
    download_user: ?[]const u8 = null,
    sandbox: Sandbox = .{},
    /// where to show how the transaction is going, if anywhere.
    progress: ?*progress.Progress = null,
};

/// a change to the packages installed in a root: what `os apply` does.
pub const Transaction = struct {
    target: Target,
    /// packages to install or upgrade, at exactly these versions.
    install: []const lock.Package = &.{},
    remove: []const []const u8 = &.{},
    /// install reasons to set afterwards: installed on purpose or not.
    explicit: []const []const u8 = &.{},
    dependency: []const []const u8 = &.{},
};

/// runs `t`: installs and upgrades first, then removals, then reasons.
/// returns false, with reasons in `diags`, if any step failed; steps
/// already committed stay committed. a hook or package script that fails
/// doesn't stop a transaction: it returns true with the failure in `diags`.
pub fn transact(a: Allocator, io: std.Io, t: Transaction, diags: *diag.List) Error!bool {
    return if (comptime available) impl.transact(a, io, t, diags) else error.AlpmUnavailable;
}

/// libalpm's lock in a database directory, there while a transaction runs.
const lock_name = "db.lck";

/// whether a lock last changed at `changed`, in unix nanoseconds, is left
/// from before the boot that started at `boot`, in unix seconds. nothing
/// that held it then runs now: power lost in the middle of a transaction
/// leaves one like that.
pub fn staleLock(changed: i96, boot: i64) bool {
    return changed < @as(i96, boot) * std.time.ns_per_s;
}

/// removes libalpm's lock in `dbpath` if it's from before this boot, so a
/// transaction cut off by a crash doesn't block every one after it.
/// returns its path if it did.
pub fn clearStaleLock(a: Allocator, io: std.Io, dbpath: []const u8) error{OutOfMemory}!?[]const u8 {
    const path = try std.fs.path.join(a, &.{ dbpath, lock_name });
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    const boot = try rootfs.bootTime(a, io) orelse return null;
    if (!staleLock(st.mtime.nanoseconds, boot)) return null;
    std.Io.Dir.cwd().deleteFile(io, path) catch return null;
    return path;
}

/// reports choices nobody made, for when there's no one to ask.
pub fn reportChoices(a: Allocator, choices: []const Choice, diags: *diag.List) !void {
    for (choices) |ch| {
        const options = try std.mem.join(a, ", ", ch.options);
        try diags.addHint(.provider_choice, null, "{s} has more than one provider: {s}", .{ ch.name, options }, "pick one in [providers], like {s} = \"{s}\"", .{ ch.name, ch.options[0] });
    }
}

// -- tests --

const testing = std.testing;

const fixture_dbs = [_]SyncDb{
    .{ .name = "core", .path = "tests/alpm/repos/core.db" },
    .{ .name = "extra", .path = "tests/alpm/repos/extra.db" },
};

const Fixture = struct {
    arena: std.heap.ArenaAllocator = .init(testing.allocator),
    diags: diag.List = .init(testing.allocator),
    tmp: std.testing.TmpDir = undefined,
    scratch: []const u8 = "",

    fn init(t: *Fixture) !void {
        t.tmp = std.testing.tmpDir(.{});
        t.scratch = try std.fmt.allocPrint(t.arena.allocator(), ".zig-cache/tmp/{s}", .{t.tmp.sub_path});
    }

    fn deinit(t: *Fixture) void {
        t.tmp.cleanup();
        t.diags.deinit();
        t.arena.deinit();
    }

    fn resolve(t: *Fixture, wants: []const []const u8, providers: []const lock.Provider) !Resolved {
        return alpm.resolve(t.arena.allocator(), testing.io, .{
            .dbs = &fixture_dbs,
            .wants = wants,
            .providers = providers,
            .sync_date = "2026-09-25",
            .scratch = t.scratch,
        }, &t.diags);
    }

    /// runs `tx`, and fails the test with its diagnostics if it fails.
    fn transactOk(t: *Fixture, tx: Transaction) !void {
        if (try transact(t.arena.allocator(), testing.io, tx, &t.diags)) return;
        for (t.diags.items.items) |d| std.debug.print("{s}\n", .{d.message});
        return error.TestUnexpectedResult;
    }

    fn expectDiag(t: *Fixture, code: diag.Code, message: []const u8) !void {
        for (t.diags.items.items) |d| {
            if (d.code == code and std.mem.eql(u8, d.message, message)) return;
        }
        for (t.diags.items.items) |d| std.debug.print("have: {s}\n", .{d.message});
        return error.TestExpectedDiagnostic;
    }
};

const alpm = @This();

test "a lock from before this boot is stale, and goes" {
    try testing.expect(staleLock(99 * std.time.ns_per_s, 100));
    try testing.expect(!staleLock(100 * std.time.ns_per_s, 100));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try testing.expectEqual(null, try clearStaleLock(a, io, dir));
    // one made in this boot belongs to something running now.
    const f = try tmp.dir.createFile(io, lock_name, .{});
    defer f.close(io);
    try testing.expectEqual(null, try clearStaleLock(a, io, dir));
    try tmp.dir.access(io, lock_name, .{});
    try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 0 } } });
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ dir, lock_name }), (try clearStaleLock(a, io, dir)).?);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, lock_name, .{}));
}

test "resolve pulls in the whole closure with resolved dependencies" {
    if (!available) return error.SkipZigTest;
    var t: Fixture = .{};
    defer t.deinit();
    try t.init();
    const l = (try t.resolve(&.{ "git", "linux" }, &.{})).lock;
    const names = [_][]const u8{ "bash", "curl", "filesystem", "git", "glibc", "linux", "mkinitcpio", "openssl", "perl", "perl-error", "readline" };
    try testing.expectEqual(names.len, l.packages.len);
    for (names, l.packages) |n, p| try testing.expectEqualStrings(n, p.name);

    const git = l.package("git").?;
    try testing.expectEqualStrings("2.51.0-1", git.version);
    try testing.expectEqualStrings("extra", git.repo);
    try testing.expectEqual(64, git.sha256.len);
    try testing.expectEqualStrings("curl", git.depends[0]);
    try testing.expectEqualStrings("glibc", git.depends[1]);
    // `sh` is a virtual package with one provider, so it resolves to bash
    // without asking.
    const mk = l.package("mkinitcpio").?;
    try testing.expectEqual(1, mk.depends.len);
    try testing.expectEqualStrings("bash", mk.depends[0]);

    // the result round-trips through the lock format.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try lock.write(&out.writer, &l);
    const back = (try lock.parse(t.arena.allocator(), "machine.lock", out.written(), &t.diags)).?;
    try testing.expectEqual(l.packages.len, back.packages.len);
}

test "a dependency that names a package gets it, even when something provides the name" {
    if (!available) return error.SkipZigTest;
    var t: Fixture = .{};
    defer t.deinit();
    try t.init();
    const l = (try t.resolve(&.{"fetcher"}, &.{})).lock;
    try testing.expect(l.package("certs") != null);
    const f = l.package("fetcher").?;
    try testing.expectEqual(2, f.depends.len);
    try testing.expectEqualStrings("certs", f.depends[0]);
    try testing.expectEqualStrings("certs-utils", f.depends[1]);
}

test "a virtual package with several providers needs a choice" {
    if (!available) return error.SkipZigTest;
    var t: Fixture = .{};
    defer t.deinit();
    try t.init();
    const choices = (try t.resolve(&.{"jdk-tool"}, &.{})).choose;
    try testing.expectEqual(1, choices.len);
    try testing.expectEqualStrings("java-runtime", choices[0].name);
    try testing.expectEqualStrings("jre17-openjdk", choices[0].options[1]);
    try reportChoices(t.arena.allocator(), choices, &t.diags);
    try t.expectDiag(.provider_choice, "java-runtime has more than one provider: jre-openjdk, jre17-openjdk");

    var t2: Fixture = .{};
    defer t2.deinit();
    try t2.init();
    const l = (try t2.resolve(&.{"jdk-tool"}, &.{.{ .name = "java-runtime", .chosen = "jre17-openjdk" }})).lock;
    try testing.expect(l.package("jre17-openjdk") != null);
    try testing.expect(l.package("jre-openjdk") == null);
    try testing.expectEqualStrings("jre17-openjdk", l.package("jdk-tool").?.depends[0]);
    try testing.expectEqualStrings("jre17-openjdk", l.providers[0].chosen);
}

test "missing packages, missing dependencies, and conflicts" {
    if (!available) return error.SkipZigTest;
    var t: Fixture = .{};
    defer t.deinit();
    try t.init();
    try testing.expect(try t.resolve(&.{ "git", "nope" }, &.{}) == .failed);
    try t.expectDiag(.unresolvable, "no package called nope in the sync databases");

    var t2: Fixture = .{};
    defer t2.deinit();
    try t2.init();
    try testing.expect(try t2.resolve(&.{"broken"}, &.{}) == .failed);
    try t2.expectDiag(.unresolvable, "broken needs no-such-package, which no sync database provides");

    var t3: Fixture = .{};
    defer t3.deinit();
    try t3.init();
    try testing.expect(try t3.resolve(&.{ "vim", "neovim" }, &.{}) == .failed);
    try t3.expectDiag(.unresolvable, "vim and neovim conflict");
}

test "names no sync database has, by package name or what packages provide" {
    if (!available) return error.SkipZigTest;
    var t: Fixture = .{};
    defer t.deinit();
    try t.init();
    const got = (try unsatisfied(t.arena.allocator(), testing.io, .{
        .dbs = &fixture_dbs,
        .wants = &.{ "git", "sh", "java-runtime", "yay", "nope" },
        .sync_date = "2026-09-25",
        .scratch = t.scratch,
    }, &t.diags)).?;
    try testing.expectEqual(2, got.len);
    try testing.expectEqualStrings("yay", got[0]);
    try testing.expectEqualStrings("nope", got[1]);
}

test "copied sync databases look old to pacman -Sy, with no stale signature" {
    if (!available) return error.SkipZigTest;
    var t: Fixture = .{};
    defer t.deinit();
    try t.init();
    const a = t.arena.allocator();
    const cwd = std.Io.Dir.cwd();
    const sync_dir = try std.fs.path.join(a, &.{ t.scratch, "db", "sync" });
    try cwd.createDirPath(testing.io, sync_dir);
    const sig = try std.fs.path.join(a, &.{ sync_dir, "core.db.sig" });
    try cwd.writeFile(testing.io, .{ .sub_path = sig, .data = "old" });
    _ = (try t.resolve(&.{"git"}, &.{})).lock;
    const st = try cwd.statFile(testing.io, try std.fs.path.join(a, &.{ sync_dir, "core.db" }), .{});
    try testing.expectEqual(0, st.mtime.nanoseconds);
    try testing.expectError(error.FileNotFound, cwd.access(testing.io, sig, .{}));
}

test "local packages from a database directory" {
    if (!available) return error.SkipZigTest;
    var t: Fixture = .{};
    defer t.deinit();
    try t.init();
    const a = t.arena.allocator();
    const local = try std.fs.path.join(a, &.{ t.scratch, "db", "local" });
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(testing.io, local);
    try cwd.writeFile(testing.io, .{ .sub_path = try std.fs.path.join(a, &.{ local, "ALPM_DB_VERSION" }), .data = "9\n" });
    const entries = [_]struct { []const u8, []const u8, ?[]const u8 }{
        .{ "git", "2.51.0-1", null },
        .{ "glibc", "2.42-1", "1" },
    };
    for (entries) |e| {
        const dir = try std.fmt.allocPrint(a, "{s}/{s}-{s}", .{ local, e[0], e[1] });
        try cwd.createDirPath(testing.io, dir);
        const desc = try std.fmt.allocPrint(a, "%NAME%\n{s}\n\n%VERSION%\n{s}\n\n{s}", .{ e[0], e[1], if (e[2]) |r| try std.fmt.allocPrint(a, "%REASON%\n{s}\n\n", .{r}) else "" });
        try cwd.writeFile(testing.io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "desc" }), .data = desc });
    }
    const pkgs = (try localPackages(a, t.scratch, try std.fs.path.join(a, &.{ t.scratch, "db" }), &t.diags)).?;
    try testing.expectEqual(2, pkgs.len);
    var f: facts.Facts = .{ .packages = pkgs };
    f.normalize();
    try testing.expectEqualStrings("git", f.packages[0].name);
    try testing.expectEqual(facts.Package.Reason.explicit, f.packages[0].reason);
    try testing.expectEqual(facts.Package.Reason.dependency, f.packages[1].reason);
}

test "without -Dalpm everything says so" {
    if (available) return error.SkipZigTest;
    var diags: diag.List = .init(testing.allocator);
    defer diags.deinit();
    try testing.expectError(error.AlpmUnavailable, localPackages(testing.allocator, "/", "/var/lib/pacman", &diags));
}

/// an empty root with a local database, and a transaction on it that gets
/// packages from the fixture repos.
fn fixtureRoot(t: *Fixture) !Transaction {
    const a = t.arena.allocator();
    const io = testing.io;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = buf[0..try std.process.currentPath(io, &buf)];
    const root = try std.fs.path.join(a, &.{ cwd, t.scratch, "target" });
    const dbpath = try std.fs.path.join(a, &.{ root, "var/lib/pacman" });
    const local = try std.fs.path.join(a, &.{ dbpath, "local" });
    try std.Io.Dir.cwd().createDirPath(io, local);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ local, "ALPM_DB_VERSION" }), .data = "9\n" });

    const dbs = try a.alloc(SyncDb, fixture_dbs.len);
    for (fixture_dbs, dbs) |f, *d| {
        const server = try std.fmt.allocPrint(a, "file://{s}/tests/alpm/repos/{s}", .{ cwd, f.name });
        d.* = .{ .name = f.name, .path = f.path, .servers = try a.dupe([]const u8, &.{server}) };
    }
    return .{ .target = .{
        .root = root,
        .dbpath = dbpath,
        .dbs = dbs,
        .cachedir = try std.fs.path.join(a, &.{ root, "var/cache/pkg" }),
        .gpgdir = null,
    } };
}

/// installs `wants` and what they need into the fixture root.
fn installFixture(t: *Fixture, base: Transaction, wants: []const []const u8) !void {
    var install = base;
    install.install = (try t.resolve(wants, &.{})).lock.packages;
    install.explicit = wants;
    try t.transactOk(install);
}

test "install a locked closure into a root, then remove part of it" {
    if (!available) return error.SkipZigTest;
    // installing sets file ownership, which takes root.
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    var t: Fixture = .{};
    defer t.deinit();
    try t.init();
    const a = t.arena.allocator();
    const io = testing.io;
    const l = (try t.resolve(&.{"git"}, &.{})).lock;
    const base = try fixtureRoot(&t);
    const root = base.target.root;
    const dbpath = base.target.dbpath;

    var deps: std.ArrayList([]const u8) = .empty;
    for (l.packages) |p| {
        if (!std.mem.eql(u8, p.name, "git")) try deps.append(a, p.name);
    }
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var shown: progress.Progress = .{ .w = &w, .tty = false };
    var install = base;
    install.install = l.packages;
    install.explicit = &.{"git"};
    install.dependency = deps.items;
    install.target.progress = &shown;
    try t.transactOk(install);
    const installing = try std.fmt.allocPrint(a, "installing {d} packages\n", .{l.packages.len});
    try testing.expect(std.mem.indexOf(u8, w.buffered(), installing) != null);
    try testing.expect(std.mem.indexOfScalar(u8, w.buffered(), '\r') == null);
    var have = (try localPackages(a, root, dbpath, &t.diags)).?;
    try testing.expectEqual(l.packages.len, have.len);
    var f: facts.Facts = .{ .packages = have };
    f.normalize();
    try testing.expectEqual(facts.Package.Reason.explicit, f.package("git").?.reason);
    try testing.expectEqual(facts.Package.Reason.dependency, f.package("glibc").?.reason);
    try testing.expectEqualStrings("2.51.0-1", f.package("git").?.version);
    // the package's files are on disk.
    try std.Io.Dir.cwd().access(io, try std.fs.path.join(a, &.{ root, "usr/share/doc/git/README" }), .{});

    var remove = base;
    remove.remove = &.{ "git", "perl-error", "perl", "curl", "openssl" };
    remove.target.progress = &shown;
    try testing.expect(try transact(a, io, remove, &t.diags));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "removing 5 packages\n") != null);
    have = (try localPackages(a, root, dbpath, &t.diags)).?;
    try testing.expectEqual(l.packages.len - 5, have.len);
}

test "a package replaces one it conflicts with that the plan removes" {
    if (!available) return error.SkipZigTest;
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    var t: Fixture = .{};
    defer t.deinit();
    try t.init();
    const a = t.arena.allocator();
    const base = try fixtureRoot(&t);
    try installFixture(&t, base, &.{"neovim"});

    var swap = base;
    swap.install = (try t.resolve(&.{"vim"}, &.{})).lock.packages;
    swap.remove = &.{ "neovim", "luajit", "libuv" };
    try t.transactOk(swap);
    var f: facts.Facts = .{ .packages = (try localPackages(a, base.target.root, base.target.dbpath, &t.diags)).? };
    f.normalize();
    try testing.expect(f.package("vim") != null);
    try testing.expect(f.package("neovim") == null);
    try testing.expect(f.package("luajit") == null);

    // a conflict with a package the plan keeps still fails.
    var t2: Fixture = .{};
    defer t2.deinit();
    try t2.init();
    const base2 = try fixtureRoot(&t2);
    try installFixture(&t2, base2, &.{"neovim"});
    var keep = base2;
    keep.install = (try t2.resolve(&.{"vim"}, &.{})).lock.packages;
    try testing.expect(!try transact(t2.arena.allocator(), testing.io, keep, &t2.diags));
}

test "hooks masked in other roots" {
    try testing.expectEqual(0, maskedFor("/").len);
    try testing.expectEqual(0, maskedFor("//").len);
    for ([_][]const u8{ "/run/yoq/next", "/mnt/yoq", "/var/tmp/clean/" }) |root| {
        try testing.expectEqual(1, maskedFor(root).len);
        try testing.expectEqualStrings("zz-sbctl.hook", maskedFor(root)[0]);
    }
}

test "a hook that fails after packages change is reported, with its output" {
    if (!available) return error.SkipZigTest;
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    var t: Fixture = .{};
    defer t.deinit();
    try t.init();
    const a = t.arena.allocator();
    const base = try fixtureRoot(&t);
    const hooks = try std.fs.path.join(a, &.{ base.target.root, "etc/pacman.d/hooks" });
    try std.Io.Dir.cwd().createDirPath(testing.io, hooks);
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = try std.fs.path.join(a, &.{ hooks, "90-fails.hook" }),
        .data = "[Trigger]\nOperation = Install\nType = Package\nTarget = glibc\n\n[Action]\nWhen = PostTransaction\nExec = /usr/bin/no-such-command\n",
    });
    var install = base;
    install.install = (try t.resolve(&.{"glibc"}, &.{})).lock.packages;
    // the packages are in; the hook's failure is left in diags.
    try testing.expect(try transact(a, testing.io, install, &t.diags));
    try testing.expectEqual(1, t.diags.items.items.len);
    const d = t.diags.items.items[0];
    try testing.expectEqualStrings("hook 90-fails.hook: command failed to execute correctly", d.message);
    try testing.expect(std.mem.startsWith(u8, d.hint.?, "call to execv failed"));
    try std.Io.Dir.cwd().access(testing.io, try std.fs.path.join(a, &.{ base.target.root, "usr/share/doc/glibc/README" }), .{});
}

test "sbctl's hook stays off in a root other than the running one" {
    if (!available) return error.SkipZigTest;
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    var t: Fixture = .{};
    defer t.deinit();
    try t.init();
    const a = t.arena.allocator();
    const base = try fixtureRoot(&t);
    const hooks = try std.fs.path.join(a, &.{ base.target.root, "usr/share/libalpm/hooks" });
    try std.Io.Dir.cwd().createDirPath(testing.io, hooks);
    // a stand-in for sbctl's hook that would fail if it ran.
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = try std.fs.path.join(a, &.{ hooks, "zz-sbctl.hook" }),
        .data = "[Trigger]\nOperation = Install\nType = Package\nTarget = glibc\n\n[Action]\nWhen = PostTransaction\nExec = /usr/bin/no-such-command\n",
    });
    var install = base;
    install.install = (try t.resolve(&.{"glibc"}, &.{})).lock.packages;
    try testing.expect(try transact(a, testing.io, install, &t.diags));
    try testing.expectEqual(0, t.diags.items.items.len);
    var buf: [64]u8 = undefined;
    const link = try std.fs.path.join(a, &.{ base.target.root, masked_dir, "zz-sbctl.hook" });
    const n = try std.Io.Dir.cwd().readLink(testing.io, link, &buf);
    try testing.expectEqualStrings("/dev/null", buf[0..n]);
}
