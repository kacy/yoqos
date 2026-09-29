//! packages from the aur. `os update` fetches each one's recipe with git,
//! shows what changed since the locked commit for review, builds it in a
//! clean chroot with devtools' makechrootpkg, and adds the result to a
//! local repository, `yoq-aur`, that resolution reads like any other.
//! every function that changes something returns null when it worked, or
//! what went wrong.

const std = @import("std");
const exec = @import("exec.zig");
const lists = @import("lists.zig");
const rootfs = @import("rootfs.zig");
const lock = @import("lock.zig");
const Allocator = std.mem.Allocator;

/// the local repository's name, as pacman and the lock see it.
pub const repo_name = "yoq-aur";

/// the unprivileged user recipes build as, inside the chroot.
pub const build_user = "yoq-build";

/// the local repository's directory on the machine.
pub const repo_dir = "/var/cache/yoq/aur/repo";

/// where the aur's recipes come from, unless the context says otherwise.
pub const default_url = "https://aur.archlinux.org";

/// what a recipe's .SRCINFO says about what it builds and needs.
pub const SrcInfo = struct {
    pkgbase: []const u8,
    pkgver: []const u8 = "",
    pkgrel: []const u8 = "",
    /// the packages it builds: one, or several for a split package.
    pkgnames: []const []const u8 = &.{},
    /// what it needs to build and run, by name, without version bounds.
    needs: []const []const u8 = &.{},
    /// the recipe commit this came from, once fetched.
    commit: []const u8 = "",
};

pub fn parseSrcInfo(a: Allocator, text: []const u8) !?SrcInfo {
    var out: SrcInfo = .{ .pkgbase = "" };
    var names: std.ArrayList([]const u8) = .empty;
    var needs: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOf(u8, line, " = ") orelse continue;
        const key = line[0..eq];
        const value = line[eq + 3 ..];
        if (std.mem.eql(u8, key, "pkgbase")) out.pkgbase = value;
        if (std.mem.eql(u8, key, "pkgver")) out.pkgver = value;
        if (std.mem.eql(u8, key, "pkgrel")) out.pkgrel = value;
        if (std.mem.eql(u8, key, "pkgname")) try names.append(a, value);
        // depends_x86_64 and the like count too.
        for ([_][]const u8{ "depends", "makedepends", "checkdepends" }) |k| {
            if (!std.mem.startsWith(u8, key, k)) continue;
            const name = value[0 .. std.mem.indexOfAny(u8, value, "<>=:") orelse value.len];
            if (!lists.contains(needs.items, name)) try needs.append(a, name);
        }
    }
    if (out.pkgbase.len == 0) return null;
    out.pkgnames = names.items;
    out.needs = needs.items;
    return out;
}

/// `recipes` ordered so each comes after the ones among them it needs.
/// returns null, with the loop's names in `why`, if they need each other.
pub fn buildOrder(a: Allocator, recipes: []const SrcInfo, why: *[]const u8) !?[]const SrcInfo {
    var out: std.ArrayList(SrcInfo) = .empty;
    var done: std.ArrayList([]const u8) = .empty;
    while (out.items.len < recipes.len) {
        var progressed = false;
        for (recipes) |r| {
            if (lists.contains(done.items, r.pkgbase)) continue;
            const ready = for (r.needs) |n| {
                const from = providerOf(recipes, n) orelse continue;
                if (!std.mem.eql(u8, from, r.pkgbase) and !lists.contains(done.items, from)) break false;
            } else true;
            if (!ready) continue;
            try out.append(a, r);
            try done.append(a, r.pkgbase);
            progressed = true;
        }
        if (!progressed) {
            var left: std.ArrayList([]const u8) = .empty;
            for (recipes) |r| {
                if (!lists.contains(done.items, r.pkgbase)) try left.append(a, r.pkgbase);
            }
            why.* = try std.mem.join(a, ", ", left.items);
            return null;
        }
    }
    return out.items;
}

/// the recipe among `recipes` that builds `name`, by its pkgbase.
fn providerOf(recipes: []const SrcInfo, name: []const u8) ?[]const u8 {
    for (recipes) |r| {
        if (lists.contains(r.pkgnames, name)) return r.pkgbase;
    }
    return null;
}

/// the directories os keeps aur work in, under a machine's root.
pub const Dirs = struct {
    /// the recipes, one git clone each, and build logs.
    src: []const u8,
    /// a copy of each recipe to build in, owned by the build user.
    build: []const u8,
    /// the chroot builds run in.
    chroot: []const u8,
    /// the local repository: built packages and yoq-aur.db.
    repo: []const u8,

    pub fn under(a: Allocator, root: []const u8) !Dirs {
        const base = try std.fs.path.join(a, &.{ root, "var/cache/yoq/aur" });
        return .{
            .src = try std.fs.path.join(a, &.{ base, "src" }),
            .build = try std.fs.path.join(a, &.{ base, "build" }),
            .chroot = try std.fs.path.join(a, &.{ base, "chroot" }),
            .repo = try std.fs.path.join(a, &.{ root, repo_dir }),
        };
    }
};

/// `text` with control characters other than newlines and tabs written
/// as escapes, like "\\x1b".
fn visible(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |ch| {
        if ((ch < 0x20 and ch != '\n' and ch != '\t') or ch == 0x7f) {
            try out.print(a, "\\x{x:0>2}", .{ch});
        } else try out.append(a, ch);
    }
    return out.items;
}

/// the aur's recipes, fetched and built on a machine.
pub const Builder = struct {
    a: Allocator,
    io: std.Io,
    dirs: Dirs,
    /// the aur's address, or a stand-in, like a local directory in tests.
    url: []const u8 = default_url,

    fn recipeDir(b: Builder, name: []const u8) ![]const u8 {
        return std.fs.path.join(b.a, &.{ b.dirs.src, name });
    }

    /// clones or fetches `name`'s recipe. returns the newest commit, or
    /// null with the reason in `why`.
    pub fn fetch(b: Builder, name: []const u8, why: *[]const u8) !?[]const u8 {
        const dir = try b.recipeDir(name);
        if (rootfs.pathExists(b.io, try std.fs.path.join(b.a, &.{ dir, ".git" }))) {
            if (try b.git(&.{ "-C", dir, "fetch", "-q", "origin" })) |w| return fail(why, w);
        } else {
            b.createDir(b.dirs.src) orelse return fail(why, try std.fmt.allocPrint(b.a, "can't create {s}", .{b.dirs.src}));
            const url = try std.fmt.allocPrint(b.a, "{s}/{s}.git", .{ b.url, name });
            if (try b.git(&.{ "clone", "-q", url, dir })) |w| return fail(why, w);
        }
        // the remote's newest commit, after a clone or a fetch alike.
        const out = try b.gitOutput(&.{ "-C", dir, "rev-parse", "origin/HEAD" }) orelse
            return fail(why, try std.fmt.allocPrint(b.a, "{s}'s recipe has no commits: is it on the aur?", .{name}));
        const commit = std.mem.trim(u8, out, " \n");
        if (!lock.validCommit(commit)) return fail(why, try std.fmt.allocPrint(b.a, "{s}'s recipe gave a commit that isn't one: {s}", .{ name, commit }));
        return commit;
    }

    /// the recipe's .SRCINFO at `commit`, with the commit.
    pub fn srcInfo(b: Builder, name: []const u8, commit: []const u8) !?SrcInfo {
        const text = try b.gitOutput(&.{ "-C", try b.recipeDir(name), "show", try std.fmt.allocPrint(b.a, "{s}:.SRCINFO", .{commit}) }) orelse return null;
        var info = try parseSrcInfo(b.a, text) orelse return null;
        info.commit = commit;
        return info;
    }

    /// what to review before building `commit`: what changed since
    /// `from`, or for a recipe never built, every file in it whole, since
    /// any of them can run. binary files are only named. control
    /// characters show as escapes, so nothing in a recipe can move the
    /// terminal's cursor and hide a line from the review.
    pub fn review(b: Builder, name: []const u8, from: ?[]const u8, commit: []const u8) ![]const u8 {
        const dir = try b.recipeDir(name);
        if (from) |f| {
            if (try b.gitOutput(&.{ "-C", dir, "diff", "--stat", "-p", f, commit, "--", "." })) |d| return visible(b.a, d);
        }
        const files = try b.gitOutput(&.{ "-C", dir, "ls-tree", "-r", "--name-only", commit }) orelse "";
        var out: std.ArrayList(u8) = .empty;
        try out.print(b.a, "files in the recipe:\n{s}", .{files});
        var names = std.mem.tokenizeScalar(u8, files, '\n');
        while (names.next()) |f| {
            const text = try b.gitOutput(&.{ "-C", dir, "show", try std.fmt.allocPrint(b.a, "{s}:{s}", .{ commit, f }) }) orelse continue;
            if (std.mem.indexOfScalar(u8, text, 0) != null) {
                try out.print(b.a, "\n--- {s} (binary, {d} bytes)\n", .{ f, text.len });
                continue;
            }
            try out.print(b.a, "\n--- {s}\n{s}", .{ f, text });
        }
        return visible(b.a, out.items);
    }

    /// builds the recipe `info` names, at its commit, in the chroot, with
    /// the aur packages it needs from the local repository installed there
    /// first, and adds what it builds to the local repository. a commit
    /// built before isn't built again.
    pub fn build(b: Builder, info: SrcInfo) !?[]const u8 {
        const name = info.pkgbase;
        const commit = info.commit;
        const with = try b.packageFiles(info.needs);
        const marker = try std.fmt.allocPrint(b.a, "{s}/.built/{s}-{s}", .{ b.dirs.repo, name, commit });
        if (rootfs.pathExists(b.io, marker)) return null;
        const dir = try b.recipeDir(name);
        if (try b.git(&.{ "-C", dir, "checkout", "-q", "--detach", commit })) |w| return w;
        if (try b.git(&.{ "-C", dir, "clean", "-q", "-fdx" })) |w| return w;
        // one chroot for every build, with base-devel, made once.
        const chroot_root = try std.fs.path.join(b.a, &.{ b.dirs.chroot, "root" });
        if (!rootfs.pathExists(b.io, chroot_root)) {
            b.createDir(b.dirs.chroot) orelse return try std.fmt.allocPrint(b.a, "can't create {s}", .{b.dirs.chroot});
            if (try b.run(&.{ "mkarchroot", chroot_root, "base-devel" })) |w| return w;
        }
        // makechrootpkg won't build as root; it builds as this user.
        if (try b.run(&.{ "id", "-u", build_user }) != null) {
            if (try b.run(&.{ "useradd", "--system", "--no-create-home", "--shell", "/usr/bin/nologin", build_user })) |w| return w;
        }
        // the build user writes where it builds, so it gets a copy of the
        // recipe of its own; the clone stays root's, as git wants.
        const work = try std.fs.path.join(b.a, &.{ b.dirs.build, name });
        if (try b.run(&.{ "rm", "-rf", work })) |w| return w;
        b.createDir(b.dirs.build) orelse return try std.fmt.allocPrint(b.a, "can't create {s}", .{b.dirs.build});
        if (try b.run(&.{ "cp", "-a", dir, work })) |w| return w;
        if (try b.run(&.{ "chown", "-R", build_user, work })) |w| return w;
        var argv: std.ArrayList([]const u8) = .empty;
        // -c starts from a clean copy of the chroot; -u brings it up to date.
        try argv.appendSlice(b.a, &.{ "env", "-C", work, "makechrootpkg", "-c", "-u", "-U", build_user, "-r", b.dirs.chroot });
        for (with) |pkg| try argv.appendSlice(b.a, &.{ "-I", pkg });
        const log = try std.fmt.allocPrint(b.a, "{s}/{s}.log", .{ b.dirs.src, name });
        if (try exec.runLogged(b.a, b.io, argv.items, log)) |w| return w;
        // what it built lands beside the recipe; into the repository with it.
        b.createDir(try std.fs.path.join(b.a, &.{ b.dirs.repo, ".built" })) orelse return try std.fmt.allocPrint(b.a, "can't create {s}", .{b.dirs.repo});
        const built = try b.packagesIn(work);
        if (built.len == 0) return try std.fmt.allocPrint(b.a, "building {s} made no package", .{name});
        const db = try std.fmt.allocPrint(b.a, "{s}/{s}.db.tar.gz", .{ b.dirs.repo, repo_name });
        for (built) |file| {
            const dest = try std.fs.path.join(b.a, &.{ b.dirs.repo, std.fs.path.basename(file) });
            if (try b.run(&.{ "mv", "-f", file, dest })) |w| return w;
            if (try b.run(&.{ "repo-add", "-q", "-R", db, dest })) |w| return w;
        }
        rootfs.writeAtomic(b.io, marker, commit, null) catch return try std.fmt.allocPrint(b.a, "can't write {s}", .{marker});
        return null;
    }

    /// the package files in the local repository that `names` are in, for
    /// installing into the chroot before a build that needs them.
    fn packageFiles(b: Builder, names: []const []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (try b.packagesIn(b.dirs.repo)) |file| {
            const pn = packageName(std.fs.path.basename(file)) orelse continue;
            if (lists.contains(names, pn)) try out.append(b.a, file);
        }
        return out.items;
    }

    fn packagesIn(b: Builder, dir_path: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var dir = std.Io.Dir.cwd().openDir(b.io, dir_path, .{ .iterate = true }) catch return out.items;
        defer dir.close(b.io);
        var it = dir.iterate();
        while (it.next(b.io) catch null) |f| {
            if (f.kind == .file and std.mem.indexOf(u8, f.name, ".pkg.tar") != null and !std.mem.endsWith(u8, f.name, ".sig")) {
                try out.append(b.a, try std.fs.path.join(b.a, &.{ dir_path, f.name }));
            }
        }
        lists.sortStrings(out.items);
        return out.items;
    }

    fn createDir(b: Builder, path: []const u8) ?void {
        std.Io.Dir.cwd().createDirPath(b.io, path) catch return null;
    }

    fn git(b: Builder, args: []const []const u8) !?[]const u8 {
        return b.run(try std.mem.concat(b.a, []const u8, &.{ &.{"git"}, args }));
    }

    fn gitOutput(b: Builder, args: []const []const u8) !?[]const u8 {
        return switch (try exec.output(b.a, b.io, try std.mem.concat(b.a, []const u8, &.{ &.{"git"}, args }))) {
            .ok => |t| t,
            .failed => null,
        };
    }

    fn run(b: Builder, argv: []const []const u8) !?[]const u8 {
        return exec.run(b.a, b.io, argv);
    }
};

/// a package file's name part, what's left before the last three dashes:
/// "yay-bin-12.5.0-1-x86_64.pkg.tar.zst" is "yay-bin".
pub fn packageName(file: []const u8) ?[]const u8 {
    const end = std.mem.indexOf(u8, file, ".pkg.tar") orelse return null;
    var stem = file[0..end];
    for (0..3) |_| stem = stem[0 .. std.mem.lastIndexOfScalar(u8, stem, '-') orelse return null];
    return stem;
}

fn fail(why: *[]const u8, message: []const u8) ?[]const u8 {
    why.* = message;
    return null;
}

// -- tests --

const testing = std.testing;

test "what a .SRCINFO builds and needs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const info = (try parseSrcInfo(arena.allocator(),
        \\pkgbase = yay
        \\    pkgdesc = yet another yogurt
        \\    pkgver = 12.5.0
        \\    pkgrel = 1
        \\    makedepends = go>=1.21
        \\    depends = pacman>6.1
        \\    depends = git
        \\    depends_x86_64 = glibc
        \\
        \\pkgname = yay
        \\
    )).?;
    try testing.expectEqualStrings("yay", info.pkgbase);
    try testing.expectEqualStrings("12.5.0", info.pkgver);
    try testing.expectEqual(1, info.pkgnames.len);
    try testing.expectEqual(4, info.needs.len);
    try testing.expectEqualStrings("go", info.needs[0]);
    try testing.expectEqualStrings("glibc", info.needs[3]);
    try testing.expectEqual(null, try parseSrcInfo(arena.allocator(), "no recipe here"));
}

test "aur packages build after the aur packages they need" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const app: SrcInfo = .{ .pkgbase = "app", .pkgnames = &.{"app"}, .needs = &.{ "lib-a", "glibc" } };
    const lib: SrcInfo = .{ .pkgbase = "lib", .pkgnames = &.{ "lib-a", "lib-b" }, .needs = &.{"glibc"} };
    var why: []const u8 = "";
    const order = (try buildOrder(a, &.{ app, lib }, &why)).?;
    try testing.expectEqualStrings("lib", order[0].pkgbase);
    try testing.expectEqualStrings("app", order[1].pkgbase);

    const x: SrcInfo = .{ .pkgbase = "x", .pkgnames = &.{"x"}, .needs = &.{"y"} };
    const y: SrcInfo = .{ .pkgbase = "y", .pkgnames = &.{"y"}, .needs = &.{"x"} };
    try testing.expectEqual(null, try buildOrder(a, &.{ x, y }, &why));
    try testing.expectEqualStrings("x, y", why);
}

test "a package file's name" {
    try testing.expectEqualStrings("yay-bin", packageName("yay-bin-12.5.0-1-x86_64.pkg.tar.zst").?);
    try testing.expectEqualStrings("lib-a", packageName("lib-a-1:2.0-3-any.pkg.tar.xz").?);
    try testing.expectEqual(null, packageName("yoq-aur.db.tar.gz"));
}
