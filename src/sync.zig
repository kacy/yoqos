//! arch's package databases: which repositories to use and where to get
//! them, both read from pacman's own config, and a cache of downloaded
//! databases per date under /var/cache/yoq/sync/<date>/.

const std = @import("std");
const builtin = @import("builtin");
const alpm = @import("alpm.zig");
const diag = @import("diag.zig");
const Allocator = std.mem.Allocator;

pub const Repo = struct {
    name: []const u8,
    /// server urls with `$repo` and `$arch` still in them, in order.
    servers: []const []const u8,
};

/// used when pacman's config names no server for a repository.
pub const fallback_server = "https://geo.mirror.pkgbuild.com/$repo/os/$arch";

pub const arch = switch (builtin.cpu.arch) {
    .x86_64 => "x86_64",
    else => @tagName(builtin.cpu.arch),
};

/// reads a file under the machine's root. returns null if it's missing.
pub const ReadFn = *const fn (ctx: *anyopaque, a: Allocator, path: []const u8) error{OutOfMemory}!?[]const u8;

/// the repositories in pacman.conf, in order, with their servers. `read`
/// resolves `Include =` files.
pub fn repos(a: Allocator, conf: []const u8, ctx: *anyopaque, read: ReadFn) ![]const Repo {
    var out: std.ArrayList(Repo) = .empty;
    var servers: std.ArrayList([]const u8) = .empty;
    var current: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, conf, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            if (current) |name| try out.append(a, .{ .name = name, .servers = try servers.toOwnedSlice(a) });
            const name = line[1 .. line.len - 1];
            current = if (std.mem.eql(u8, name, "options")) null else name;
            continue;
        }
        if (current == null) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "Server")) {
            try servers.append(a, value);
        } else if (std.mem.eql(u8, key, "Include")) {
            const text = try read(ctx, a, value) orelse continue;
            try mirrorlist(a, text, &servers);
        }
    }
    if (current) |name| try out.append(a, .{ .name = name, .servers = try servers.toOwnedSlice(a) });
    return out.items;
}

/// the `Server =` lines of a mirrorlist file.
fn mirrorlist(a: Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "Server")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), "Server")) continue;
        try out.append(a, std.mem.trim(u8, line[eq + 1 ..], " \t"));
    }
}

/// a server url with `$repo` and `$arch` filled in, pointing at the
/// repository's database.
pub fn dbUrl(a: Allocator, server: []const u8, repo: []const u8) ![]const u8 {
    const with_repo = try std.mem.replaceOwned(u8, a, server, "$repo", repo);
    const with_arch = try std.mem.replaceOwned(u8, a, with_repo, "$arch", arch);
    return std.fmt.allocPrint(a, "{s}/{s}.db", .{ std.mem.trimEnd(u8, with_arch, "/"), repo });
}

/// downloads a url. returns null, after saying why in `diags`, if the
/// server can't be reached or doesn't have it.
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
        db.* = .{ .name = r.name, .path = try std.fmt.allocPrint(a, "{s}/{s}.db", .{ dir, r.name }) };
        if (cwd.access(io, db.path, .{})) |_| continue else |_| {}
        const bytes = try fetchRepo(a, fetcher, r) orelse {
            try diags.add(.alpm_failed, null, "can't download the {s} database from any server", .{r.name}, "check the network and the servers in pacman.conf and its mirrorlist");
            return null;
        };
        const tmp = try std.fmt.allocPrint(a, "{s}.part", .{db.path});
        cwd.writeFile(io, .{ .sub_path = tmp, .data = bytes }) catch return writeFailed(diags, db.path);
        cwd.rename(tmp, cwd, db.path, io) catch return writeFailed(diags, db.path);
    }
    return out;
}

/// the cached databases for `date`, or null if any is missing. never
/// downloads.
pub fn cached(a: Allocator, io: std.Io, rs: []const Repo, cache: []const u8, date: []const u8) !?[]const alpm.SyncDb {
    const out = try a.alloc(alpm.SyncDb, rs.len);
    for (rs, out) |r, *db| {
        db.* = .{ .name = r.name, .path = try std.fmt.allocPrint(a, "{s}/{s}/{s}.db", .{ cache, date, r.name }) };
        std.Io.Dir.cwd().access(io, db.path, .{}) catch return null;
    }
    return out;
}

fn fetchRepo(a: Allocator, fetcher: Fetcher, r: Repo) !?[]const u8 {
    const servers: []const []const u8 = if (r.servers.len > 0) r.servers else &.{fallback_server};
    for (servers) |s| {
        if (try fetcher.fetch(a, try dbUrl(a, s, r.name))) |bytes| return bytes;
    }
    return null;
}

fn writeFailed(diags: *diag.List, path: []const u8) !?[]const alpm.SyncDb {
    try diags.add(.alpm_failed, null, "can't write {s}", .{path}, null);
    return null;
}

// -- tests --

const testing = std.testing;

const FakeFiles = struct {
    files: []const struct { []const u8, []const u8 },

    fn read(ctx: *anyopaque, a: Allocator, path: []const u8) error{OutOfMemory}!?[]const u8 {
        const f: *FakeFiles = @ptrCast(@alignCast(ctx));
        for (f.files) |kv| {
            if (std.mem.eql(u8, kv[0], path)) return try a.dupe(u8, kv[1]);
        }
        return null;
    }
};

test "repositories and servers from pacman.conf" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fake: FakeFiles = .{ .files = &.{.{ "/etc/pacman.d/mirrorlist", "## worldwide\n#Server = https://off.example/$repo/os/$arch\nServer = https://geo.mirror.pkgbuild.com/$repo/os/$arch\nServer=https://two.example/$repo/os/$arch/\n" }} };
    const rs = try repos(arena.allocator(),
        \\[options]
        \\HoldPkg = pacman glibc
        \\Architecture = auto
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
    , &fake, FakeFiles.read);
    try testing.expectEqual(3, rs.len);
    try testing.expectEqualStrings("core", rs[0].name);
    try testing.expectEqual(2, rs[0].servers.len);
    try testing.expectEqualStrings("omarchy", rs[2].name);
    try testing.expectEqualStrings("https://pkgs.omarchy.org/$arch", rs[2].servers[0]);

    const a = arena.allocator();
    try testing.expectEqualStrings("https://two.example/extra/os/" ++ arch ++ "/extra.db", try dbUrl(a, rs[1].servers[1], "extra"));
    try testing.expectEqualStrings("https://pkgs.omarchy.org/" ++ arch ++ "/omarchy.db", try dbUrl(a, rs[2].servers[0], "omarchy"));
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
