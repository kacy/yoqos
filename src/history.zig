//! config history: every change os makes to the config directory becomes a
//! git commit there, so there's a record without anyone remembering git.

const std = @import("std");
const exec = @import("exec.zig");
const compose = @import("compose.zig");
const Allocator = std.mem.Allocator;

/// one commit in the config's history. `n` counts from 1 at the first,
/// and is what `os rollback` takes.
pub const Entry = struct { n: usize, rev: []const u8, message: []const u8 };

/// a file as a commit has it, by its path inside the config directory.
pub const File = struct { path: []const u8, bytes: []const u8 };

pub const History = struct {
    ctx: *anyopaque,
    /// commits everything in `dir`, making it a repository first if it
    /// isn't one. returns false, with a reason in `why`, if git failed.
    commitFn: *const fn (ctx: *anyopaque, a: Allocator, dir: []const u8, message: []const u8, why: *[]const u8) error{OutOfMemory}!bool,
    /// every commit, oldest first. null, with a reason in `why`, if there's
    /// no history to read.
    logFn: *const fn (ctx: *anyopaque, a: Allocator, dir: []const u8, why: *[]const u8) error{OutOfMemory}!?[]const Entry,
    /// the files in `dir` as commit `rev` had them.
    filesFn: *const fn (ctx: *anyopaque, a: Allocator, dir: []const u8, rev: []const u8, why: *[]const u8) error{OutOfMemory}!?[]const File,

    pub fn commit(h: History, a: Allocator, dir: []const u8, message: []const u8, why: *[]const u8) !bool {
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
        const text = switch (try exec.output(a, g.io, &.{ "git", "-C", dir, "log", "--reverse", "--format=%H %s" })) {
            .ok => |t| t,
            .failed => |w| {
                why.* = w;
                return null;
            },
        };
        var out: std.ArrayList(Entry) = .empty;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
            try out.append(a, .{ .n = out.items.len + 1, .rev = line[0..space], .message = std.mem.trimStart(u8, line[space..], " ") });
        }
        return out.items;
    }

    fn files(ctx: *anyopaque, a: Allocator, dir: []const u8, rev: []const u8, why: *[]const u8) error{OutOfMemory}!?[]const File {
        const g: *Git = @ptrCast(@alignCast(ctx));
        // ls-tree names paths from `dir`, and `rev:./path` reads them back.
        const names = switch (try exec.output(a, g.io, &.{ "git", "-C", dir, "ls-tree", "-r", "--name-only", rev })) {
            .ok => |t| t,
            .failed => |w| {
                why.* = w;
                return null;
            },
        };
        var out: std.ArrayList(File) = .empty;
        var lines = std.mem.tokenizeScalar(u8, names, '\n');
        while (lines.next()) |name| {
            const spec = try std.fmt.allocPrint(a, "{s}:./{s}", .{ rev, name });
            switch (try exec.output(a, g.io, &.{ "git", "-C", dir, "show", spec })) {
                .ok => |bytes| try out.append(a, .{ .path = name, .bytes = bytes }),
                .failed => |w| {
                    why.* = w;
                    return null;
                },
            }
        }
        return out.items;
    }

    fn commit(ctx: *anyopaque, a: Allocator, dir: []const u8, message: []const u8, why: *[]const u8) error{OutOfMemory}!bool {
        const g: *Git = @ptrCast(@alignCast(ctx));
        if (!try g.run(a, &.{ "git", "-C", dir, "init", "-q" }, why)) return false;
        if (!try g.run(a, &.{ "git", "-C", dir, "add", "-A" }, why)) return false;
        // nothing staged means nothing changed: done.
        if (try g.succeeds(a, &.{ "git", "-C", dir, "diff", "--cached", "--quiet" })) return true;
        // root's config often has no identity. commit as os then, rather
        // than fail.
        const named = try g.succeeds(a, &.{ "git", "-C", dir, "config", "user.email" });
        const argv: []const []const u8 = if (named)
            &.{ "git", "-C", dir, "commit", "-q", "-m", message }
        else
            &.{ "git", "-C", dir, "-c", "user.name=os", "-c", "user.email=os@localhost", "commit", "-q", "-m", message };
        return g.run(a, argv, why);
    }

    fn run(g: *Git, a: Allocator, argv: []const []const u8, why: *[]const u8) !bool {
        why.* = try exec.run(a, g.io, argv) orelse return true;
        return false;
    }

    fn succeeds(g: *Git, a: Allocator, argv: []const []const u8) !bool {
        var ignored: []const u8 = "";
        return g.run(a, argv, &ignored);
    }
};

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
            for (snap) |f| {
                r.gpa.free(f.path);
                r.gpa.free(f.bytes);
            }
            r.gpa.free(snap);
        }
        r.snapshots.deinit(r.gpa);
    }

    fn commit(ctx: *anyopaque, _: Allocator, dir: []const u8, message: []const u8, _: *[]const u8) error{OutOfMemory}!bool {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        try r.messages.append(r.gpa, try r.gpa.dupe(u8, message));
        var snap: std.ArrayList(File) = .empty;
        if (r.fs) |fs| {
            var it = fs.map.iterator();
            while (it.next()) |e| {
                if (!std.mem.startsWith(u8, e.key_ptr.*, dir) or e.key_ptr.len <= dir.len or e.key_ptr.*[dir.len] != '/') continue;
                try snap.append(r.gpa, .{ .path = try r.gpa.dupe(u8, e.key_ptr.*[dir.len + 1 ..]), .bytes = try r.gpa.dupe(u8, e.value_ptr.*) });
            }
        }
        try r.snapshots.append(r.gpa, try snap.toOwnedSlice(r.gpa));
        return true;
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
    if (!try h.commit(a, dir, "init: config", &why)) {
        // no git on this machine: nothing to check.
        if (std.mem.startsWith(u8, why, "can't run git")) return error.SkipZigTest;
        std.debug.print("git failed: {s}\n", .{why});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(try h.commit(a, dir, "nothing changed", &why));
    try tmp.dir.writeFile(io, .{ .sub_path = "machine.toml", .data = "packages = [\"git\"]\n" });
    try std.testing.expect(try h.commit(a, dir, "add git", &why));

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
