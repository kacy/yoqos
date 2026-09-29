//! runs the few programs os uses as backends, like git and shadow's tools:
//! fixed arguments, never a shell.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// what a program printed when it succeeded, or what went wrong.
pub const Output = union(enum) {
    /// its standard output, byte for byte.
    ok: []const u8,
    /// its own message, or why it couldn't start.
    failed: []const u8,
};

/// runs `argv` and waits for it.
pub fn output(a: Allocator, io: std.Io, argv: []const []const u8) error{OutOfMemory}!Output {
    const r = std.process.run(a, io, .{ .argv = argv }) catch |e| return .{ .failed = try spawnFailed(a, argv, e) };
    if (r.term == .exited and r.term.exited == 0) return .{ .ok = r.stdout };
    const out = std.mem.trim(u8, if (r.stderr.len > 0) r.stderr else r.stdout, " \n");
    return .{ .failed = if (out.len > 0) out else try std.fmt.allocPrint(a, "{s} failed", .{argv[0]}) };
}

/// runs `argv` like `run`, and keeps everything it printed, both streams,
/// in the file at `log`. a failure says where the log is, with its last
/// lines, since a build's reason can be on either stream.
pub fn runLogged(a: Allocator, io: std.Io, argv: []const []const u8, log: []const u8) error{OutOfMemory}!?[]const u8 {
    const r = std.process.run(a, io, .{ .argv = argv }) catch |e| return try spawnFailed(a, argv, e);
    const both = try std.mem.concat(a, u8, &.{ r.stdout, r.stderr });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = log, .data = both }) catch {};
    if (r.term == .exited and r.term.exited == 0) return null;
    return try std.fmt.allocPrint(a, "{s} failed; its whole output is in {s}. the end of it:\n{s}", .{ argv[0], log, lastLines(both, 20) });
}

/// why `argv` couldn't start.
fn spawnFailed(a: Allocator, argv: []const []const u8, e: anyerror) error{OutOfMemory}![]const u8 {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => try std.fmt.allocPrint(a, "can't run {s}: it isn't installed", .{argv[0]}),
        else => try std.fmt.allocPrint(a, "can't run {s}: {s}", .{ argv[0], @errorName(e) }),
    };
}

/// the last `n` lines of `text`.
fn lastLines(text: []const u8, n: usize) []const u8 {
    const t = std.mem.trimEnd(u8, text, "\n");
    var start = t.len;
    var seen: usize = 0;
    while (start > 0) : (start -= 1) {
        if (t[start - 1] == '\n') {
            seen += 1;
            if (seen == n) break;
        }
    }
    return t[start..];
}

/// runs `argv` for its effect. returns null when it succeeds, or what went
/// wrong.
pub fn run(a: Allocator, io: std.Io, argv: []const []const u8) error{OutOfMemory}!?[]const u8 {
    return switch (try output(a, io, argv)) {
        .ok => null,
        .failed => |why| why,
    };
}

/// runs `argv` on the terminal os runs on, for a program that asks the
/// person there something itself, like passwd. null when it succeeds.
pub fn interactive(a: Allocator, io: std.Io, argv: []const []const u8) error{OutOfMemory}!?[]const u8 {
    var child = std.process.spawn(io, .{ .argv = argv }) catch |e| return try spawnFailed(a, argv, e);
    const term = child.wait(io) catch |e| return try std.fmt.allocPrint(a, "{s} didn't finish: {s}", .{ argv[0], @errorName(e) });
    if (term == .exited and term.exited == 0) return null;
    return try std.fmt.allocPrint(a, "{s} failed", .{argv[0]});
}

/// runs `argv` with the file at `input` as its standard input, for a
/// program that reads a script there, like sfdisk. what it prints goes
/// nowhere; a failure says it failed.
pub fn runFrom(a: Allocator, io: std.Io, argv: []const []const u8, input: []const u8) error{OutOfMemory}!?[]const u8 {
    var f = std.Io.Dir.cwd().openFile(io, input, .{}) catch return try std.fmt.allocPrint(a, "can't read {s}", .{input});
    defer f.close(io);
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .{ .file = f }, .stdout = .ignore, .stderr = .ignore }) catch |e| return try spawnFailed(a, argv, e);
    const term = child.wait(io) catch |e| return try std.fmt.allocPrint(a, "{s} didn't finish: {s}", .{ argv[0], @errorName(e) });
    if (term == .exited and term.exited == 0) return null;
    return try std.fmt.allocPrint(a, "{s} failed", .{argv[0]});
}

/// runs each command in turn, stopping at the first that fails, and says
/// why it failed.
pub fn runAll(a: Allocator, io: std.Io, argvs: []const []const []const u8) error{OutOfMemory}!?[]const u8 {
    for (argvs) |argv| {
        if (try run(a, io, argv)) |why| return why;
    }
    return null;
}

test "a missing program and a failing one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("can't run os-no-such-tool: it isn't installed", (try run(a, std.testing.io, &.{"os-no-such-tool"})).?);
    try std.testing.expectEqual(null, try run(a, std.testing.io, &.{"true"}));
    try std.testing.expectEqualStrings("false failed", (try run(a, std.testing.io, &.{"false"})).?);
    try std.testing.expectEqualStrings("hi\n", (try output(a, std.testing.io, &.{ "echo", "hi" })).ok);
    try std.testing.expectEqualStrings("false failed", (try runAll(a, std.testing.io, &.{ &.{"true"}, &.{"false"}, &.{"os-no-such-tool"} })).?);
}
