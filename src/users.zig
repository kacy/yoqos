//! changes users and their groups under a root with shadow's own tools
//! (useradd, usermod, gpasswd), which keep passwd, shadow, and group
//! consistent and lock them properly.
//!
//! every uid os gives out is kept in an append-only map at
//! /var/lib/yoq/ids, so a user created again gets the same uid, and files
//! it owns in /home stay its own.

const std = @import("std");
const diag = @import("diag.zig");
const observe = @import("observe.zig");
const planner = @import("planner.zig");
const Allocator = std.mem.Allocator;

/// makes one user change from a plan: "new user", "shell zsh",
/// "join wheel", or "leave docker". returns false after saying why in
/// `diags`.
pub fn apply(a: Allocator, io: std.Io, root: []const u8, c: planner.Change, diags: *diag.List) !bool {
    const r: Root = .{ .a = a, .io = io, .root = root, .diags = diags };
    const step = c.to orelse c.from.?;
    const name = c.subject;
    if (std.mem.eql(u8, step, "new user")) return r.create(name);
    if (std.mem.startsWith(u8, step, "shell ")) {
        const shell = try r.shellPath(step["shell ".len..]) orelse return false;
        return r.run(&.{ "usermod", "--root", root, "--shell", shell, name });
    }
    if (std.mem.startsWith(u8, step, "join ")) return r.run(&.{ "gpasswd", "--root", root, "--add", name, step["join ".len..] });
    if (std.mem.startsWith(u8, step, "leave ")) return r.run(&.{ "gpasswd", "--root", root, "--delete", name, step["leave ".len..] });
    try diags.add(.bad_value, null, "os doesn't know how to {s} for {s}", .{ step, name }, null);
    return false;
}

const Root = struct {
    a: Allocator,
    io: std.Io,
    root: []const u8,
    diags: *diag.List,

    fn path(r: Root, rel: []const u8) ![]const u8 {
        return std.fs.path.join(r.a, &.{ r.root, rel });
    }

    fn read(r: Root, rel: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(r.io, try r.path(rel), r.a, .limited(16 << 20)) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => "",
        };
    }

    /// runs a shadow tool. its own message says what went wrong.
    fn run(r: Root, argv: []const []const u8) !bool {
        const res = std.process.run(r.a, r.io, .{ .argv = argv }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try r.diags.add(.bad_value, null, "can't run {s}: {s}", .{ argv[0], @errorName(e) }, "it comes with the shadow package");
                return false;
            },
        };
        if (res.term == .exited and res.term.exited == 0) return true;
        const why = std.mem.trim(u8, if (res.stderr.len > 0) res.stderr else res.stdout, " \n");
        try r.diags.add(.bad_value, null, "{s} failed: {s}", .{ argv[0], why }, null);
        return false;
    }

    /// creates the user with its own group and a home, reusing the uid the
    /// id map has for it, then records the uid it got. a group already
    /// named after the user, as a userdel can leave behind, becomes its
    /// group.
    fn create(r: Root, name: []const u8) !bool {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(r.a, &.{ "useradd", "--root", r.root, "--create-home" });
        const group_line = try std.fmt.allocPrint(r.a, "\n{s}:", .{name});
        const groups = try std.mem.concat(r.a, u8, &.{ "\n", try r.read("etc/group") });
        if (std.mem.indexOf(u8, groups, group_line) != null) {
            try argv.appendSlice(r.a, &.{ "--gid", name });
        } else try argv.append(r.a, "--user-group");
        const ids = try r.read(ids_path);
        if (lookup(ids, name)) |uid| try argv.appendSlice(r.a, &.{ "--uid", uid });
        try argv.append(r.a, name);
        if (!try r.run(argv.items)) return false;
        if (lookup(ids, name) != null) return true;

        const users = try observe.users(r.a, try r.read("etc/passwd"), "");
        const u = for (users) |u| {
            if (std.mem.eql(u8, u.name, name)) break u;
        } else return true;
        const line = try std.fmt.allocPrint(r.a, "{s} {d}\n", .{ name, u.uid });
        const cwd = std.Io.Dir.cwd();
        const p = try r.path(ids_path);
        cwd.createDirPath(r.io, std.fs.path.dirnamePosix(p).?) catch {};
        cwd.writeFile(r.io, .{ .sub_path = p, .data = try std.mem.concat(r.a, u8, &.{ ids, line }) }) catch {
            try r.diags.add(.bad_value, null, "created {s}, but can't record its uid in {s}", .{ name, p }, null);
            return false;
        };
        return true;
    }

    /// a shell by name, like "zsh", is the binary of that name under the
    /// root. a path is used as it is.
    fn shellPath(r: Root, shell: []const u8) !?[]const u8 {
        if (std.mem.indexOfScalar(u8, shell, '/') != null) return shell;
        const full = try std.fmt.allocPrint(r.a, "/usr/bin/{s}", .{shell});
        std.Io.Dir.cwd().access(r.io, try r.path(full[1..]), .{}) catch {
            try r.diags.add(.bad_value, null, "the shell {s} isn't installed", .{shell}, try std.fmt.allocPrint(r.a, "add {s} to packages", .{shell}));
            return null;
        };
        return full;
    }
};

const ids_path = "var/lib/yoq/ids";

/// the uid the id map has for `name`. lines are "<name> <uid>".
fn lookup(ids: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, ids, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const n = parts.next() orelse continue;
        const uid = parts.next() orelse continue;
        if (std.mem.eql(u8, n, name)) return uid;
    }
    return null;
}

// -- tests --

const testing = std.testing;

fn expectOk(ok: bool, diags: *const diag.List) !void {
    if (ok) return;
    for (diags.items.items) |d| std.debug.print("{s}\n", .{d.message});
    return error.TestUnexpectedResult;
}

test "the id map" {
    try testing.expectEqualStrings("1001", lookup("kacy 1000\nguest 1001\n", "guest").?);
    try testing.expectEqual(null, lookup("kacy 1000\n", "guest"));
}

test "users under a root: create, shell, groups, and the same uid again" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var diags: diag.List = .init(testing.allocator);
    defer diags.deinit();

    // just enough of a system for shadow's tools.
    try tmp.dir.createDirPath(io, "etc");
    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.createDirPath(io, "usr/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/passwd", .data = "root:x:0:0::/root:/bin/sh\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/shadow", .data = "root:!:1::::::\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/group", .data = "root:x:0:\nwheel:x:998:\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/gshadow", .data = "root:::\nwheel:::\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/bin/zsh", .data = "" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const here = buf[0..try std.process.currentPath(io, &buf)];
    const root = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}", .{ here, tmp.sub_path });

    const step = struct {
        fn change(subject: []const u8, op: planner.Op, text: []const u8) planner.Change {
            return .{ .op = op, .kind = .user, .subject = subject, .to = if (op == .remove) null else text, .from = if (op == .remove) text else null };
        }
    }.change;
    for ([_]planner.Change{
        step("guest", .add, "new user"),
        step("guest", .change, "shell zsh"),
        step("guest", .add, "join wheel"),
    }) |c| try expectOk(try apply(a, io, root, c, &diags), &diags);
    const r: Root = .{ .a = a, .io = io, .root = root, .diags = &diags };
    const us = try observe.users(a, try r.read("etc/passwd"), try r.read("etc/group"));
    try testing.expectEqual(1, us.len);
    try testing.expectEqualStrings("guest", us[0].name);
    try testing.expectEqualStrings("/usr/bin/zsh", us[0].shell.?);
    try testing.expectEqualStrings("wheel", us[0].groups[0]);
    const uid = lookup(try r.read(ids_path), "guest").?;

    try expectOk(try apply(a, io, root, step("guest", .remove, "leave wheel"), &diags), &diags);
    try testing.expect(!try apply(a, io, root, step("guest", .change, "shell fish"), &diags));
    try testing.expectEqualStrings("the shell fish isn't installed", diags.items.items[0].message);

    // gone and back: the same uid, where useradd alone would take the
    // next one after other's.
    try expectOk(try r.run(&.{ "userdel", "--root", root, "guest" }), &diags);
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/passwd", .data = "root:x:0:0::/root:/bin/sh\nother:x:1001:1001::/:/bin/sh\n" });
    diags.items.clearRetainingCapacity();
    try expectOk(try apply(a, io, root, step("guest", .add, "new user"), &diags), &diags);
    const again = try observe.users(a, try r.read("etc/passwd"), "");
    try testing.expectEqualStrings("guest", again[1].name);
    try testing.expectEqualStrings(uid, try std.fmt.allocPrint(a, "{d}", .{again[1].uid}));
}
