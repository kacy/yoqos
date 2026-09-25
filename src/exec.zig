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
    const r = std.process.run(a, io, .{ .argv = argv }) catch |e| return .{ .failed = switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => try std.fmt.allocPrint(a, "can't run {s}: it isn't installed", .{argv[0]}),
        else => try std.fmt.allocPrint(a, "can't run {s}: {s}", .{ argv[0], @errorName(e) }),
    } };
    if (r.term == .exited and r.term.exited == 0) return .{ .ok = r.stdout };
    const out = std.mem.trim(u8, if (r.stderr.len > 0) r.stderr else r.stdout, " \n");
    return .{ .failed = if (out.len > 0) out else try std.fmt.allocPrint(a, "{s} failed", .{argv[0]}) };
}

/// runs `argv` for its effect. returns null when it succeeds, or what went
/// wrong.
pub fn run(a: Allocator, io: std.Io, argv: []const []const u8) error{OutOfMemory}!?[]const u8 {
    return switch (try output(a, io, argv)) {
        .ok => null,
        .failed => |why| why,
    };
}

test "a missing program and a failing one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("can't run os-no-such-tool: it isn't installed", (try run(a, std.testing.io, &.{"os-no-such-tool"})).?);
    try std.testing.expectEqual(null, try run(a, std.testing.io, &.{"true"}));
    try std.testing.expectEqualStrings("false failed", (try run(a, std.testing.io, &.{"false"})).?);
    try std.testing.expectEqualStrings("hi\n", (try output(a, std.testing.io, &.{ "echo", "hi" })).ok);
}
