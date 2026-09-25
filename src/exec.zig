//! runs the few programs os uses as backends, like git and shadow's tools:
//! fixed arguments, never a shell.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// runs `argv` and waits. returns null when it succeeds, or what went
/// wrong: the program's own message, or why it couldn't start.
pub fn run(a: Allocator, io: std.Io, argv: []const []const u8) error{OutOfMemory}!?[]const u8 {
    const r = std.process.run(a, io, .{ .argv = argv }) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => try std.fmt.allocPrint(a, "can't run {s}: it isn't installed", .{argv[0]}),
        else => try std.fmt.allocPrint(a, "can't run {s}: {s}", .{ argv[0], @errorName(e) }),
    };
    if (r.term == .exited and r.term.exited == 0) return null;
    const out = std.mem.trim(u8, if (r.stderr.len > 0) r.stderr else r.stdout, " \n");
    return if (out.len > 0) out else try std.fmt.allocPrint(a, "{s} failed", .{argv[0]});
}

test "a missing program and a failing one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("can't run os-no-such-tool: it isn't installed", (try run(a, std.testing.io, &.{"os-no-such-tool"})).?);
    try std.testing.expectEqual(null, try run(a, std.testing.io, &.{"true"}));
    try std.testing.expectEqualStrings("false failed", (try run(a, std.testing.io, &.{"false"})).?);
}
