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
const Allocator = std.mem.Allocator;

pub const available = build_options.alpm;
const impl = if (available) @import("alpm_c.zig") else struct {};

pub const Error = error{ AlpmUnavailable, AlpmFailed, OutOfMemory };

pub const SyncDb = struct {
    /// the repository name, like "core".
    name: []const u8,
    /// a `<name>.db` file.
    path: []const u8,
};

pub const ResolveInput = struct {
    dbs: []const SyncDb,
    wants: []const []const u8,
    /// choices for virtual packages, from `[providers]` in the config.
    providers: []const lock.Provider = &.{},
    sync_date: []const u8,
    /// the archlinux-keyring version to record. empty means look it up in
    /// the sync databases.
    keyring: []const u8 = "",
    /// an empty directory libalpm can use as a scratch root.
    scratch: []const u8,
};

/// the packages installed in `root`, read from the local database in
/// `dbpath`. strings are copied into `a`.
pub fn localPackages(a: Allocator, root: []const u8, dbpath: []const u8, diags: *diag.List) Error!?[]facts.Package {
    return if (comptime available) impl.localPackages(a, root, dbpath, diags) else error.AlpmUnavailable;
}

/// resolves `in.wants` and everything they depend on against the sync
/// databases, the way pacman would install them into an empty root. returns
/// null, with the reasons in `diags`, if that can't be done without a
/// choice or at all.
pub fn resolve(a: Allocator, io: std.Io, in: ResolveInput, diags: *diag.List) Error!?lock.Lock {
    return if (comptime available) impl.resolve(a, io, in, diags) else error.AlpmUnavailable;
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

    fn resolve(t: *Fixture, wants: []const []const u8, providers: []const lock.Provider) !?lock.Lock {
        return alpm.resolve(t.arena.allocator(), testing.io, .{
            .dbs = &fixture_dbs,
            .wants = wants,
            .providers = providers,
            .sync_date = "2026-09-25",
            .keyring = "20260901-1",
            .scratch = t.scratch,
        }, &t.diags);
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

test "resolve pulls in the whole closure with resolved dependencies" {
    if (!available) return error.SkipZigTest;
    var t: Fixture = .{};
    defer t.deinit();
    try t.init();
    const l = (try t.resolve(&.{ "git", "linux" }, &.{})).?;
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

test "a virtual package with several providers needs a choice" {
    if (!available) return error.SkipZigTest;
    var t: Fixture = .{};
    defer t.deinit();
    try t.init();
    try testing.expectEqual(null, try t.resolve(&.{"jdk-tool"}, &.{}));
    try t.expectDiag(.provider_choice, "java-runtime has more than one provider: jre-openjdk, jre17-openjdk");

    var t2: Fixture = .{};
    defer t2.deinit();
    try t2.init();
    const l = (try t2.resolve(&.{"jdk-tool"}, &.{.{ .name = "java-runtime", .chosen = "jre17-openjdk" }})).?;
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
    try testing.expectEqual(null, try t.resolve(&.{ "git", "nope" }, &.{}));
    try t.expectDiag(.unresolvable, "no package called nope in the sync databases");

    var t2: Fixture = .{};
    defer t2.deinit();
    try t2.init();
    try testing.expectEqual(null, try t2.resolve(&.{"broken"}, &.{}));
    try t2.expectDiag(.unresolvable, "broken needs no-such-package, which no sync database provides");

    var t3: Fixture = .{};
    defer t3.deinit();
    try t3.init();
    try testing.expectEqual(null, try t3.resolve(&.{ "vim", "neovim" }, &.{}));
    try t3.expectDiag(.unresolvable, "vim and neovim conflict");
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
