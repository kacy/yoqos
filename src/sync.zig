//! arch's package databases: which repositories to use and where to get
//! them, both read from pacman's own config, and a cache of downloaded
//! databases per date under /var/cache/yos/sync/<date>/.

const std = @import("std");
const rootfs = @import("rootfs.zig");
const lists = @import("lists.zig");
const builtin = @import("builtin");
const alpm = @import("alpm.zig");
const diag = @import("diag.zig");
const compose = @import("compose.zig");
const Allocator = std.mem.Allocator;

pub const Repo = struct {
    name: []const u8,
    /// server urls with `$repo` and `$arch` still in them, in order.
    servers: []const []const u8,
    /// its packages are signed and checked: false for `SigLevel = Optional`
    /// or `Never`.
    signed: bool = true,
    /// a repository yos keeps in a local directory, like its aur builds: its
    /// database is read where it is, not downloaded per date.
    local: bool = false,
};

/// arch's repositories in the order pacman.conf lists them.
const repo_order = [_][]const u8{ "core-testing", "core", "extra-testing", "extra", "multilib-testing", "multilib" };

/// where a repository sorts among arch's own. others come after them.
pub fn repoRank(name: []const u8) usize {
    for (repo_order, 0..) |r, i| {
        if (std.mem.eql(u8, r, name)) return i;
    }
    return repo_order.len;
}

/// used when pacman's config names no server for a repository.
const fallback_server = "https://geo.mirror.pkgbuild.com/$repo/os/$arch";

pub const arch = switch (builtin.cpu.arch) {
    .x86_64 => "x86_64",
    else => @tagName(builtin.cpu.arch),
};

/// what `yos` takes from the machine's pacman.conf: its repositories, in
/// order, with their servers, and how pacman downloads.
pub const Pacman = struct {
    repos: []const Repo,
    /// `DownloadUser`: the user libalpm's downloader runs as.
    download_user: ?[]const u8 = null,
    /// the parts of libalpm's download sandbox pacman.conf turns off, as
    /// some containers need: `DisableSandbox` is both.
    sandbox: alpm.Sandbox = .{},
};

/// reads pacman.conf under `root`, following `Include =` files there too.
/// with no pacman.conf, core and extra from arch's main mirror.
pub fn pacmanConf(a: Allocator, files: compose.Files, root: []const u8) !Pacman {
    const conf = try readUnder(a, files, root, "/etc/pacman.conf") orelse return .{ .repos = &.{
        .{ .name = "core", .servers = &.{} },
        .{ .name = "extra", .servers = &.{} },
    } };
    var r: ConfReader = .{ .a = a, .files = files, .root = root };
    try r.feed(conf, 0);
    try r.close();
    r.p.repos = r.out.items;
    return r.p;
}

/// pacman.conf's lines, in order. an included file reads as if its lines
/// were where the `Include` is, as pacman does: a mirrorlist adds servers,
/// and a file with sections adds repositories.
const ConfReader = struct {
    a: Allocator,
    files: compose.Files,
    root: []const u8,
    p: Pacman = .{ .repos = &.{} },
    out: std.ArrayList(Repo) = .empty,
    servers: std.ArrayList([]const u8) = .empty,
    section: []const u8 = "",
    signed: bool = true,

    fn feed(r: *ConfReader, text: []const u8, depth: usize) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len > 1 and line[0] == '[' and line[line.len - 1] == ']') {
                try r.close();
                r.section = line[1 .. line.len - 1];
                continue;
            }
            const key, const value = setting(line) orelse continue;
            if (std.mem.eql(u8, key, "Include")) {
                // deep enough for any real pacman.conf, and no loops.
                if (depth < 4) try r.feed(try readUnder(r.a, r.files, r.root, value) orelse continue, depth + 1);
            } else if (std.mem.eql(u8, r.section, "options")) {
                if (std.mem.eql(u8, key, "DownloadUser")) r.p.download_user = value;
                if (std.mem.eql(u8, key, "DisableSandbox")) r.p.sandbox = .{ .no_filesystem = true, .no_syscalls = true };
                if (std.mem.eql(u8, key, "DisableSandboxFilesystem")) r.p.sandbox.no_filesystem = true;
                if (std.mem.eql(u8, key, "DisableSandboxSyscalls")) r.p.sandbox.no_syscalls = true;
            } else if (isRepo(r.section) and std.mem.eql(u8, key, "Server")) {
                try r.servers.append(r.a, value);
            } else if (isRepo(r.section) and std.mem.eql(u8, key, "SigLevel")) {
                r.signed = packagesSigned(value);
            }
        }
    }

    /// whether a SigLevel value makes packages need a signature. only the
    /// package half counts: yos's own keyed repositories say `Required
    /// DatabaseOptional`.
    fn packagesSigned(value: []const u8) bool {
        var words = std.mem.tokenizeAny(u8, value, " \t");
        while (words.next()) |w| {
            for ([_][]const u8{ "Never", "Optional", "PackageNever", "PackageOptional" }) |off| {
                if (std.mem.eql(u8, w, off)) return false;
            }
        }
        return true;
    }

    /// ends the section being read, keeping it if it's a repository.
    fn close(r: *ConfReader) !void {
        if (isRepo(r.section)) try r.out.append(r.a, .{ .name = r.section, .servers = try r.servers.toOwnedSlice(r.a), .signed = r.signed });
        r.section = "";
        r.signed = true;
    }
};

fn isRepo(section: []const u8) bool {
    return section.len > 0 and !std.mem.eql(u8, section, "options");
}

fn readUnder(a: Allocator, files: compose.Files, root: []const u8, path: []const u8) !?[]const u8 {
    return files.read(a, try std.fs.path.join(a, &.{ root, path })) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// a trimmed pacman.conf line as key and value: `Key = value`, or a bare
/// `Key` with an empty value. null for blank lines and comments.
fn setting(line: []const u8) ?struct { []const u8, []const u8 } {
    if (line.len == 0 or line[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return .{ line, "" };
    return .{ std.mem.trim(u8, line[0..eq], " \t"), std.mem.trim(u8, line[eq + 1 ..], " \t") };
}

/// a server url with `$repo` and `$arch` filled in: the repository's
/// directory.
fn serverUrl(a: Allocator, server: []const u8, repo: []const u8) ![]const u8 {
    const with_repo = try std.mem.replaceOwned(u8, a, server, "$repo", repo);
    const with_arch = try std.mem.replaceOwned(u8, a, with_repo, "$arch", arch);
    return std.mem.trimEnd(u8, with_arch, "/");
}

/// the repository's database on a server.
fn dbUrl(a: Allocator, server: []const u8, repo: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}.db", .{ try serverUrl(a, server, repo), repo });
}

/// downloads a url. returns null if the server can't be reached or doesn't
/// have it.
pub const Fetcher = struct {
    ctx: *anyopaque,
    fetchFn: *const fn (ctx: *anyopaque, a: Allocator, url: []const u8) error{OutOfMemory}!?[]const u8,

    pub fn fetch(f: Fetcher, a: Allocator, url: []const u8) !?[]const u8 {
        return f.fetchFn(f.ctx, a, url);
    }
};

/// fetches over http with std's client.
pub const HttpFetcher = struct {
    client: std.http.Client,

    pub fn init(a: Allocator, io: std.Io) HttpFetcher {
        return .{ .client = .{ .io = io, .allocator = a } };
    }

    pub fn deinit(h: *HttpFetcher) void {
        h.client.deinit();
    }

    pub fn fetcher(h: *HttpFetcher) Fetcher {
        return .{ .ctx = h, .fetchFn = fetch };
    }

    fn fetch(ctx: *anyopaque, a: Allocator, url: []const u8) error{OutOfMemory}!?[]const u8 {
        const h: *HttpFetcher = @ptrCast(@alignCast(ctx));
        var body: std.Io.Writer.Allocating = .init(a);
        const result = h.client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        if (result.status != .ok) return null;
        return body.written();
    }
};

/// arch's own repositories, which the arch linux archive keeps a copy of
/// for every day.
const archived_repos = [_][]const u8{ "core", "extra", "multilib", "core-testing", "extra-testing", "multilib-testing" };

/// whether `repo` is one of arch's own, which the archive keeps.
pub fn archivedRepo(repo: []const u8) bool {
    return lists.contains(&archived_repos, repo);
}

/// where the arch linux archive keeps one package file, whatever day it
/// was built: every version of every package of arch's own repositories
/// stays there.
pub fn archivedPackage(a: Allocator, name: []const u8, version: []const u8, package_arch: []const u8) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, "https://archive.archlinux.org/packages/{c}/{s}/{s}-{s}-{s}.pkg.tar.zst", .{ name[0], name, name, version, package_arch }, 0);
}

/// `rs`, with arch's own repositories served from the arch linux archive
/// as they were on `date`: the databases, and the packages at the versions
/// in them. a lock from an earlier day builds from there, since mirrors
/// keep only today's. other repositories keep their own servers: they
/// have no history. so does a repository on this machine's own disk.
pub fn archived(a: Allocator, rs: []const Repo, date: []const u8) ![]const Repo {
    if (date.len != 10) return rs;
    const out = try a.dupe(Repo, rs);
    for (out) |*r| {
        if (!lists.contains(&archived_repos, r.name) or servedFromDisk(r.*)) continue;
        const server = try std.fmt.allocPrint(a, "https://archive.archlinux.org/repos/{s}/{s}/{s}/$repo/os/$arch", .{ date[0..4], date[5..7], date[8..10] });
        r.servers = try a.dupe([]const u8, &.{server});
    }
    return out;
}

/// `rs`, with where packages for a lock from `date` download from: the
/// archive as it was that day, then the day after, then the mirrors. the
/// archive's copy of a day can be from before a package that day's lock
/// has, and an apply just after midnight utc, of a lock from just before,
/// can come before the archive has that day at all, while the mirrors
/// still serve most of its packages. a package's name has its version,
/// so wherever it comes from, it's the one the lock names. databases come
/// from `archived` alone, since a mirror's are always today's.
pub fn pastServers(a: Allocator, rs: []const Repo, date: []const u8) ![]const Repo {
    if (date.len != 10) return rs;
    const after = nextDay(date) orelse return archived(a, rs, date);
    const out = try a.dupe(Repo, rs);
    for (out) |*r| {
        if (!lists.contains(&archived_repos, r.name) or servedFromDisk(r.*)) continue;
        var servers: std.ArrayList([]const u8) = .empty;
        for ([_][]const u8{ date, &after }) |d| {
            try servers.append(a, try std.fmt.allocPrint(a, "https://archive.archlinux.org/repos/{s}/{s}/{s}/$repo/os/$arch", .{ d[0..4], d[5..7], d[8..10] }));
        }
        try servers.appendSlice(a, serversOf(r.*));
        r.servers = servers.items;
    }
    return out;
}

/// the day after `date`, both yyyy-mm-dd.
fn nextDay(date: []const u8) ?[10]u8 {
    const y = std.fmt.parseInt(u16, date[0..4], 10) catch return null;
    const m = std.fmt.parseInt(u8, date[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u8, date[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1) return null;
    const days = std.time.epoch.getDaysInMonth(y, @enumFromInt(m));
    var out: [10]u8 = undefined;
    const ny, const nm, const nd = if (d < days) .{ y, m, d + 1 } else if (m < 12) .{ y, m + 1, 1 } else .{ y + 1, 1, 1 };
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}", .{ ny, nm, nd }) catch return null;
    return out;
}

/// the databases for `date`, from the cache if they're there, else
/// downloaded into it. returns null, with reasons in `diags`, if a
/// repository can't be fetched from any of its servers.
pub fn databases(a: Allocator, io: std.Io, fetcher: Fetcher, rs: []const Repo, cache: []const u8, date: []const u8, diags: *diag.List) !?[]const alpm.SyncDb {
    const cwd = std.Io.Dir.cwd();
    const dir = try std.fs.path.join(a, &.{ cache, date });
    cwd.createDirPath(io, dir) catch {
        try diags.add(.alpm_failed, null, "can't create the package database cache at {s}", .{dir}, null);
        return null;
    };
    const out = try a.alloc(alpm.SyncDb, rs.len);
    for (rs, out) |r, *db| {
        if (try localDb(a, r)) |path| {
            db.* = .{ .name = r.name, .path = path };
            if (rootfs.pathExists(io, path)) continue;
            try diags.add(.alpm_failed, null, "the local repository {s} has no database at {s}", .{ r.name, path }, null);
            return null;
        }
        db.* = .{ .name = r.name, .path = try cachePath(a, cache, date, r.name) };
        if (rootfs.pathExists(io, db.path)) continue;
        const bytes = try fetchRepo(a, fetcher, r) orelse {
            try diags.add(.alpm_failed, null, "can't download the {s} database from any server", .{r.name}, "check the network and the servers in pacman.conf and its mirrorlist");
            return null;
        };
        rootfs.writeAtomic(io, db.path, bytes, null) catch {
            try diags.add(.alpm_failed, null, "can't write {s}", .{db.path}, null);
            return null;
        };
    }
    return out;
}

/// `dbs` with each repository's servers from `rs` filled in, as the
/// repository directories packages download from.
pub fn withServers(a: Allocator, dbs: []const alpm.SyncDb, rs: []const Repo) ![]const alpm.SyncDb {
    const out = try a.dupe(alpm.SyncDb, dbs);
    for (out) |*db| {
        for (rs) |r| {
            if (!std.mem.eql(u8, r.name, db.name)) continue;
            db.signed = r.signed;
            const templates = serversOf(r);
            const urls = try a.alloc([]const u8, templates.len);
            for (templates, urls) |t, *u| u.* = try serverUrl(a, t, r.name);
            db.servers = urls;
        }
    }
    return out;
}

/// the cached databases for `date`, or null if any is missing. never
/// downloads.
pub fn cached(a: Allocator, io: std.Io, rs: []const Repo, cache: []const u8, date: []const u8) !?[]const alpm.SyncDb {
    const out = try a.alloc(alpm.SyncDb, rs.len);
    for (rs, out) |r, *db| {
        db.* = .{ .name = r.name, .path = try localDb(a, r) orelse try cachePath(a, cache, date, r.name) };
        if (!rootfs.pathExists(io, db.path)) return null;
    }
    return out;
}

/// whether every server `r` has is a directory on this machine.
pub fn servedFromDisk(r: Repo) bool {
    for (r.servers) |sv| {
        if (!std.mem.startsWith(u8, sv, "file://")) return false;
    }
    return r.servers.len > 0;
}

/// the database of a repository on this machine's own disk, like yos's
/// aur builds or one aurutils keeps, where it is. it's read there, not
/// downloaded per date: the http client has no file://.
fn localDb(a: Allocator, r: Repo) !?[]const u8 {
    if (!servedFromDisk(r)) return null;
    const dir = try serverUrl(a, r.servers[0], r.name);
    return try std.fmt.allocPrint(a, "{s}/{s}.db", .{ dir["file://".len..], r.name });
}

/// the repository's servers, or the fallback if pacman.conf names none.
pub fn serversOf(r: Repo) []const []const u8 {
    return if (r.servers.len > 0) r.servers else &.{fallback_server};
}

/// where the cache keeps a repository's database for a date.
fn cachePath(a: Allocator, cache: []const u8, date: []const u8, repo: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}/{s}.db", .{ cache, date, repo });
}

fn fetchRepo(a: Allocator, fetcher: Fetcher, r: Repo) !?[]const u8 {
    for (serversOf(r)) |s| {
        if (try fetcher.fetch(a, try dbUrl(a, s, r.name))) |bytes| return bytes;
    }
    return null;
}

// -- tests --

const testing = std.testing;

test "repositories and servers from pacman.conf" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fs: compose.MemFiles = .{};
    defer fs.deinit();
    try fs.put("/root/etc/pacman.d/mirrorlist", "## worldwide\n#Server = https://off.example/$repo/os/$arch\nServer = https://geo.mirror.pkgbuild.com/$repo/os/$arch\nServer=https://two.example/$repo/os/$arch/\n");
    try fs.put("/root/etc/pacman.conf",
        \\[options]
        \\HoldPkg = pacman glibc
        \\Architecture = auto
        \\DownloadUser = alpm
        \\DisableSandbox
        \\
        \\[core]
        \\Include = /etc/pacman.d/mirrorlist
        \\
        \\[extra]
        \\Include = /etc/pacman.d/mirrorlist
        \\
        \\#[multilib]
        \\#Include = /etc/pacman.d/mirrorlist
        \\
        \\[omarchy]
        \\SigLevel = Optional TrustAll
        \\Server = https://pkgs.omarchy.org/$arch
        \\
    );
    const pc = try pacmanConf(arena.allocator(), fs.files(), "/root");
    const rs = pc.repos;
    try testing.expectEqualStrings("alpm", pc.download_user.?);
    try testing.expect(pc.sandbox.no_filesystem and pc.sandbox.no_syscalls);
    try testing.expectEqual(3, rs.len);
    try testing.expectEqualStrings("core", rs[0].name);
    try testing.expectEqual(2, rs[0].servers.len);
    try testing.expectEqualStrings("omarchy", rs[2].name);
    try testing.expect(rs[0].signed and !rs[2].signed);
    try testing.expectEqualStrings("https://pkgs.omarchy.org/$arch", rs[2].servers[0]);

    const a = arena.allocator();
    try testing.expectEqualStrings("https://two.example/extra/os/" ++ arch ++ "/extra.db", try dbUrl(a, rs[1].servers[1], "extra"));
    try testing.expectEqualStrings("https://pkgs.omarchy.org/" ++ arch ++ "/omarchy.db", try dbUrl(a, rs[2].servers[0], "omarchy"));

    // an included file with sections of its own adds repositories, the
    // way yos's /etc/pacman.d/yos-repos.conf does.
    try fs.put("/inc/etc/pacman.d/yos-repos.conf", "[chaotic-aur]\nSigLevel = Required DatabaseOptional\nServer = https://cdn.example/$repo/$arch\n");
    try fs.put("/inc/etc/pacman.conf", "[options]\n[core]\nServer = https://a.example/$repo\nInclude = /etc/pacman.d/yos-repos.conf\n");
    const inc = (try pacmanConf(a, fs.files(), "/inc")).repos;
    try testing.expectEqual(2, inc.len);
    try testing.expectEqual(1, inc[0].servers.len);
    try testing.expectEqualStrings("chaotic-aur", inc[1].name);
    try testing.expectEqualStrings("https://cdn.example/$repo/$arch", inc[1].servers[0]);
    // a keyed repository's packages still need its signature.
    try testing.expect(inc[1].signed);
    try testing.expect(!ConfReader.packagesSigned("PackageOptional DatabaseRequired"));

    // no pacman.conf: core and extra, from the fallback server.
    const bare = (try pacmanConf(a, fs.files(), "/elsewhere")).repos;
    try testing.expectEqualStrings("extra", bare[1].name);
    try testing.expectEqual(0, bare[1].servers.len);
}

test "arch's own repositories from the archive, as they were that day" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rs = [_]Repo{ .{ .name = "core", .servers = &.{"https://m/$repo/os/$arch"} }, .{ .name = "chaotic-aur", .servers = &.{"https://c/$repo"} }, .{ .name = "extra", .servers = &.{"file:///srv/extra"} } };
    const got = try archived(a, &rs, "2026-09-20");
    try testing.expectEqualStrings("https://archive.archlinux.org/repos/2026/09/20/$repo/os/$arch", got[0].servers[0]);
    try testing.expectEqualStrings("https://c/$repo", got[1].servers[0]);
    try testing.expectEqualStrings("file:///srv/extra", got[2].servers[0]);
    try testing.expectEqualStrings("https://m/$repo/os/$arch", rs[0].servers[0]);
}

test "packages for an older lock come from the archive, the day after, then the mirrors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rs = [_]Repo{ .{ .name = "core", .servers = &.{"https://m/$repo/os/$arch"} }, .{ .name = "extra", .servers = &.{} }, .{ .name = "chaotic-aur", .servers = &.{"https://c/$repo"} } };
    const got = try pastServers(a, &rs, "2026-12-31");
    try testing.expectEqual(3, got[0].servers.len);
    try testing.expectEqualStrings("https://archive.archlinux.org/repos/2026/12/31/$repo/os/$arch", got[0].servers[0]);
    try testing.expectEqualStrings("https://archive.archlinux.org/repos/2027/01/01/$repo/os/$arch", got[0].servers[1]);
    try testing.expectEqualStrings("https://m/$repo/os/$arch", got[0].servers[2]);
    // without a server of its own, the fallback mirror.
    try testing.expectEqualStrings(fallback_server, got[1].servers[2]);
    try testing.expectEqualStrings("https://c/$repo", got[2].servers[0]);
    try testing.expectEqualStrings("2024-02-29", &nextDay("2024-02-28").?);
    try testing.expectEqualStrings("2026-03-01", &nextDay("2026-02-28").?);
    try testing.expectEqualStrings("2026-10-01", &nextDay("2026-09-30").?);
}

const FakeFetcher = struct {
    urls: std.ArrayList([]const u8) = .empty,
    /// urls that answer, and with what.
    answers: []const struct { []const u8, []const u8 },

    fn fetcher(f: *FakeFetcher) Fetcher {
        return .{ .ctx = f, .fetchFn = fetch };
    }

    fn fetch(ctx: *anyopaque, a: Allocator, url: []const u8) error{OutOfMemory}!?[]const u8 {
        const f: *FakeFetcher = @ptrCast(@alignCast(ctx));
        try f.urls.append(a, try a.dupe(u8, url));
        for (f.answers) |kv| {
            if (std.mem.eql(u8, kv[0], url)) return try a.dupe(u8, kv[1]);
        }
        return null;
    }
};

test "one package file in the archive" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("https://archive.archlinux.org/packages/g/git/git-2.51.0-1-x86_64.pkg.tar.zst", try archivedPackage(arena.allocator(), "git", "2.51.0-1", "x86_64"));
    try testing.expect(archivedRepo("core") and !archivedRepo("chaotic-aur"));
}

test "a repository on this machine's disk is read where it is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/srv/repo/custom/custom.db", (try localDb(a, .{ .name = "custom", .servers = &.{"file:///srv/repo/$repo/"} })).?);
    try testing.expectEqual(null, try localDb(a, .{ .name = "core", .servers = &.{ "file:///srv/core", "https://m.example/$repo" } }));
}

test "download tries servers in order, then uses the cache" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/sync", .{tmp.sub_path});
    var diags: diag.List = .init(testing.allocator);
    defer diags.deinit();

    const rs = [_]Repo{
        .{ .name = "core", .servers = &.{ "https://down.example/$repo/os/$arch", "https://up.example/$repo/os/$arch" } },
        .{ .name = "extra", .servers = &.{"https://up.example/$repo/os/$arch"} },
    };
    var fake: FakeFetcher = .{ .answers = &.{
        .{ "https://up.example/core/os/" ++ arch ++ "/core.db", "core bytes" },
        .{ "https://up.example/extra/os/" ++ arch ++ "/extra.db", "extra bytes" },
    } };
    const dbs = (try databases(a, testing.io, fake.fetcher(), &rs, cache, "2026-09-25", &diags)).?;
    try testing.expectEqual(3, fake.urls.items.len);
    try testing.expectEqualStrings("core", dbs[0].name);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, dbs[1].path, a, .limited(1024));
    try testing.expectEqualStrings("extra bytes", bytes);

    // a second run finds everything in the cache.
    _ = (try databases(a, testing.io, fake.fetcher(), &rs, cache, "2026-09-25", &diags)).?;
    try testing.expectEqual(3, fake.urls.items.len);
    try testing.expect(try cached(a, testing.io, &rs, cache, "2026-09-25") != null);
    try testing.expect(try cached(a, testing.io, &rs, cache, "2026-09-24") == null);

    // nothing answers for another repo.
    const broken = [_]Repo{.{ .name = "gone", .servers = &.{"https://down.example/$repo"} }};
    try testing.expect(try databases(a, testing.io, fake.fetcher(), &broken, cache, "2026-09-25", &diags) == null);
    try testing.expectEqualStrings("can't download the gone database from any server", diags.items.items[0].message);
}
