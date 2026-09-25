//! config history: every change os makes to the config directory becomes a
//! git commit there, so there's a record without anyone remembering git.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const History = struct {
    ctx: *anyopaque,
    /// commits everything in `dir`, making it a repository first if it
    /// isn't one. returns false, with a reason in `why`, if git failed.
    commitFn: *const fn (ctx: *anyopaque, a: Allocator, dir: []const u8, message: []const u8, why: *[]const u8) error{OutOfMemory}!bool,

    pub fn commit(h: History, a: Allocator, dir: []const u8, message: []const u8, why: *[]const u8) !bool {
        return h.commitFn(h.ctx, a, dir, message, why);
    }
};

/// history through the `git` program: a narrow backend with fixed
/// arguments, never a shell.
pub const Git = struct {
    io: std.Io,

    pub fn history(g: *Git) History {
        return .{ .ctx = g, .commitFn = commit };
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
        const r = std.process.run(a, g.io, .{ .argv = argv }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => {
                why.* = "can't run git: it isn't installed (pacman -S git)";
                return false;
            },
            else => {
                why.* = try std.fmt.allocPrint(a, "can't run git: {s}", .{@errorName(e)});
                return false;
            },
        };
        if (r.term == .exited and r.term.exited == 0) return true;
        why.* = std.mem.trim(u8, if (r.stderr.len > 0) r.stderr else r.stdout, " \n");
        return false;
    }

    fn succeeds(g: *Git, a: Allocator, argv: []const []const u8) !bool {
        var ignored: []const u8 = "";
        return g.run(a, argv, &ignored);
    }
};

/// remembers commits instead of making them, for tests.
pub const Recorder = struct {
    messages: std.ArrayList([]const u8) = .empty,
    gpa: Allocator,

    pub fn history(r: *Recorder) History {
        return .{ .ctx = r, .commitFn = commit };
    }

    pub fn deinit(r: *Recorder) void {
        for (r.messages.items) |m| r.gpa.free(m);
        r.messages.deinit(r.gpa);
    }

    fn commit(ctx: *anyopaque, _: Allocator, _: []const u8, message: []const u8, _: *[]const u8) error{OutOfMemory}!bool {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        try r.messages.append(r.gpa, try r.gpa.dupe(u8, message));
        return true;
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

    const log = try std.process.run(a, io, .{ .argv = &.{ "git", "-C", dir, "log", "--format=%s" } });
    try std.testing.expectEqualStrings("add git\ninit: config\n", log.stdout);
}
