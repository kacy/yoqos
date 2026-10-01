//! config history: every change os makes to the config directory becomes a
//! git commit there, so there's a record without anyone remembering git.

const std = @import("std");
const exec = @import("exec.zig");
const compose = @import("compose.zig");
const news = @import("news.zig");
const Allocator = std.mem.Allocator;

/// one commit in the config's history. `n` counts from 1 at the first,
/// and is what `os rollback` takes.
pub const Entry = struct { n: usize, rev: []const u8, message: []const u8 };

/// what a commit came to. `unchanged` is nothing to commit, like git.
pub const Commit = enum { made, unchanged, failed };

/// a file as a commit has it, by its path inside the config directory.
pub const File = struct { path: []const u8, bytes: []const u8 };

pub const History = struct {
    ctx: *anyopaque,
    /// commits everything in `dir`, making it a repository first if it
    /// isn't one. a reason goes in `why` if git failed.
    commitFn: *const fn (ctx: *anyopaque, a: Allocator, dir: []const u8, message: []const u8, why: *[]const u8) error{OutOfMemory}!Commit,
    /// every commit, oldest first. null, with a reason in `why`, if there's
    /// no history to read.
    logFn: *const fn (ctx: *anyopaque, a: Allocator, dir: []const u8, why: *[]const u8) error{OutOfMemory}!?[]const Entry,
    /// the files in `dir` as commit `rev` had them.
    filesFn: *const fn (ctx: *anyopaque, a: Allocator, dir: []const u8, rev: []const u8, why: *[]const u8) error{OutOfMemory}!?[]const File,

    pub fn commit(h: History, a: Allocator, dir: []const u8, message: []const u8, why: *[]const u8) !Commit {
        return h.commitFn(h.ctx, a, dir, message, why);
    }

    pub fn log(h: History, a: Allocator, dir: []const u8, why: *[]const u8) !?[]const Entry {
        return h.logFn(h.ctx, a, dir, why);
    }

    pub fn files(h: History, a: Allocator, dir: []const u8, rev: []const u8, why: *[]const u8) !?[]const File {
        return h.filesFn(h.ctx, a, dir, rev, why);
    }
};

/// history through the `git` program: a narrow backend with fixed
/// arguments, never a shell.
pub const Git = struct {
    io: std.Io,

    pub fn history(g: *Git) History {
        return .{ .ctx = g, .commitFn = commit, .logFn = log, .filesFn = files };
    }

    fn log(ctx: *anyopaque, a: Allocator, dir: []const u8, why: *[]const u8) error{OutOfMemory}!?[]const Entry {
        const g: *Git = @ptrCast(@alignCast(ctx));
        const text = try g.output(a, &.{ "git", "-C", dir, "log", "--reverse", "--format=%H %s", "--", "." }, why) orelse return null;
        return try parseLog(a, text);
    }

    fn files(ctx: *anyopaque, a: Allocator, dir: []const u8, rev: []const u8, why: *[]const u8) error{OutOfMemory}!?[]const File {
        const g: *Git = @ptrCast(@alignCast(ctx));
        // ls-tree names paths from `dir`, and `rev:./path` reads them back.
        // -z, so a name with odd characters comes back as it is, unquoted.
        const names = try g.output(a, &.{ "git", "-C", dir, "ls-tree", "-r", "-z", "--name-only", rev }, why) orelse return null;
        var out: std.ArrayList(File) = .empty;
        var lines = std.mem.tokenizeScalar(u8, names, 0);
        while (lines.next()) |name| {
            const spec = try std.fmt.allocPrint(a, "{s}:./{s}", .{ rev, name });
            const bytes = try g.output(a, &.{ "git", "-C", dir, "show", spec }, why) orelse return null;
            try out.append(a, .{ .path = name, .bytes = bytes });
        }
        return out.items;
    }

    fn commit(ctx: *anyopaque, a: Allocator, dir: []const u8, message: []const u8, why: *[]const u8) error{OutOfMemory}!Commit {
        const g: *Git = @ptrCast(@alignCast(ctx));
        // a config inside another repository, like a dotfiles one, is
        // committed there, and only what's in its own directory. one that
        // repository ignores gets its own.
        const inside = try g.succeeds(a, &.{ "git", "-C", dir, "rev-parse", "--is-inside-work-tree" }) and
            !try g.succeeds(a, &.{ "git", "-C", dir, "check-ignore", "-q", "." });
        if (!inside) {
            if (!try g.run(a, &.{ "git", "-C", dir, "init", "-q" }, why)) return .failed;
        }
        if (!try g.run(a, &.{ "git", "-C", dir, "add", "-A", "--", "." }, why)) return .failed;
        // nothing staged here means nothing changed: done.
        if (try g.succeeds(a, &.{ "git", "-C", dir, "diff", "--cached", "--quiet", "--", "." })) return .unchanged;
        // root's config often has no identity. commit as os then, rather
        // than fail.
        const named = try g.succeeds(a, &.{ "git", "-C", dir, "config", "user.email" });
        const argv: []const []const u8 = if (named)
            &.{ "git", "-C", dir, "commit", "-q", "-m", message, "--", "." }
        else
            &.{ "git", "-C", dir, "-c", "user.name=os", "-c", "user.email=os@localhost", "commit", "-q", "-m", message, "--", "." };
        return if (try g.run(a, argv, why)) .made else .failed;
    }

    fn run(g: *Git, a: Allocator, argv: []const []const u8, why: *[]const u8) !bool {
        why.* = try exec.run(a, g.io, try cleanEnv(a, argv)) orelse return true;
        return false;
    }

    /// what `argv` printed, or null with the reason in `why`.
    fn output(g: *Git, a: Allocator, argv: []const []const u8, why: *[]const u8) !?[]const u8 {
        return switch (try exec.output(a, g.io, try cleanEnv(a, argv))) {
            .ok => |text| text,
            .failed => |w| {
                why.* = w;
                return null;
            },
        };
    }

    fn succeeds(g: *Git, a: Allocator, argv: []const []const u8) !bool {
        var ignored: []const u8 = "";
        return g.run(a, argv, &ignored);
    }
};

/// the commits in `git log --format="%H %s"` output. a subject loses its
/// control characters, so one from a cloned repository can't move the
/// cursor or rewrite the terminal when `os history` prints it.
fn parseLog(a: Allocator, text: []const u8) ![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        const message = try news.plain(a, std.mem.trimStart(u8, line[space..], " "));
        try out.append(a, .{ .n = out.items.len + 1, .rev = line[0..space], .message = message });
    }
    return out.items;
}

test "commit subjects lose control characters" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try parseLog(arena.allocator(), "aaa add fd\nbbb \x1b[2J\x1b[31mremove\x07 x\xc2\x9b2Jy\n");
    try std.testing.expectEqual(2, got.len);
    try std.testing.expectEqualStrings("add fd", got[0].message);
    try std.testing.expectEqualStrings("bbb", got[1].rev);
    try std.testing.expectEqual(2, got[1].n);
    try std.testing.expectEqualStrings("remove  x2Jy", got[1].message);
}

/// `argv` run without the variables that point git at another repository.
/// os run from a git hook, or under `git rebase --exec`, inherits GIT_DIR,
/// and git would then commit there instead of in the config directory.
fn cleanEnv(a: Allocator, argv: []const []const u8) ![]const []const u8 {
    const prefix = [_][]const u8{ "env", "-u", "GIT_DIR", "-u", "GIT_WORK_TREE", "-u", "GIT_INDEX_FILE", "-u", "GIT_OBJECT_DIRECTORY", "-u", "GIT_COMMON_DIR", "--" };
    return std.mem.concat(a, []const u8, &.{ &prefix, argv });
}

fn sameFiles(x: []const File, y: []const File) bool {
    if (x.len != y.len) return false;
    for (x) |f| {
        const other = for (y) |g| {
            if (std.mem.eql(u8, f.path, g.path)) break g;
        } else return false;
        if (!std.mem.eql(u8, f.bytes, other.bytes)) return false;
    }
    return true;
}

fn freeFiles(gpa: Allocator, fs: []const File) void {
    for (fs) |f| {
        gpa.free(f.path);
        gpa.free(f.bytes);
    }
}

/// remembers commits instead of making them, for tests. with `fs` set,
/// each commit also keeps a copy of the files under its directory, so the
/// log and old files read back the way git's would.
pub const Recorder = struct {
    messages: std.ArrayList([]const u8) = .empty,
    snapshots: std.ArrayList([]const File) = .empty,
    fs: ?*compose.MemFiles = null,
    gpa: Allocator,

    pub fn history(r: *Recorder) History {
        return .{ .ctx = r, .commitFn = commit, .logFn = log, .filesFn = files };
    }

    pub fn deinit(r: *Recorder) void {
        for (r.messages.items) |m| r.gpa.free(m);
        r.messages.deinit(r.gpa);
        for (r.snapshots.items) |snap| {
            freeFiles(r.gpa, snap);
            r.gpa.free(snap);
        }
        r.snapshots.deinit(r.gpa);
    }

    fn commit(ctx: *anyopaque, _: Allocator, dir: []const u8, message: []const u8, _: *[]const u8) error{OutOfMemory}!Commit {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        var snap: std.ArrayList(File) = .empty;
        if (r.fs) |fs| {
            var it = fs.map.iterator();
            while (it.next()) |e| {
                if (!std.mem.startsWith(u8, e.key_ptr.*, dir) or e.key_ptr.len <= dir.len or e.key_ptr.*[dir.len] != '/') continue;
                try snap.append(r.gpa, .{ .path = try r.gpa.dupe(u8, e.key_ptr.*[dir.len + 1 ..]), .bytes = try r.gpa.dupe(u8, e.value_ptr.*) });
            }
        }
        // like git: nothing changed, nothing to commit.
        if (r.snapshots.items.len > 0 and sameFiles(r.snapshots.items[r.snapshots.items.len - 1], snap.items)) {
            freeFiles(r.gpa, snap.items);
            snap.deinit(r.gpa);
            return .unchanged;
        }
        try r.messages.append(r.gpa, try r.gpa.dupe(u8, message));
        try r.snapshots.append(r.gpa, try snap.toOwnedSlice(r.gpa));
        return .made;
    }

    fn log(ctx: *anyopaque, a: Allocator, _: []const u8, _: *[]const u8) error{OutOfMemory}!?[]const Entry {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        const out = try a.alloc(Entry, r.messages.items.len);
        for (r.messages.items, out, 1..) |m, *e, n| e.* = .{ .n = n, .rev = try std.fmt.allocPrint(a, "{d}", .{n}), .message = m };
        return out;
    }

    fn files(ctx: *anyopaque, _: Allocator, _: []const u8, rev: []const u8, why: *[]const u8) error{OutOfMemory}!?[]const File {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        const n = std.fmt.parseInt(usize, rev, 10) catch 0;
        if (n == 0 or n > r.snapshots.items.len) {
            why.* = "no such commit";
            return null;
        }
        return r.snapshots.items[n - 1];
    }
};

test "git commits changes and skips empty ones" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var git: Git = .{ .io = io };
    const h = git.history();
    var why: []const u8 = "";
    try tmp.dir.writeFile(io, .{ .sub_path = "machine.toml", .data = "packages = []\n" });
    if (try h.commit(a, dir, "init: config", &why) == .failed) {
        // no git on this machine: nothing to check.
        if (std.mem.startsWith(u8, why, "can't run git")) return error.SkipZigTest;
        std.debug.print("git failed: {s}\n", .{why});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(.unchanged, try h.commit(a, dir, "nothing changed", &why));
    try tmp.dir.writeFile(io, .{ .sub_path = "machine.toml", .data = "packages = [\"git\"]\n" });
    try std.testing.expectEqual(.made, try h.commit(a, dir, "add git", &why));

    var why2: []const u8 = "";
    const entries = (try h.log(a, dir, &why2)).?;
    try std.testing.expectEqual(2, entries.len);
    try std.testing.expectEqualStrings("init: config", entries[0].message);
    try std.testing.expectEqualStrings("add git", entries[1].message);
    const old = (try h.files(a, dir, entries[0].rev, &why2)).?;
    try std.testing.expectEqual(1, old.len);
    try std.testing.expectEqualStrings("machine.toml", old[0].path);
    try std.testing.expectEqualStrings("packages = []\n", old[0].bytes);
}
