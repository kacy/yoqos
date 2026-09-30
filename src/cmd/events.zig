//! `os events [--follow] [--since <when>]`: what os did on this machine,
//! and what pacman did outside it, oldest first, one `yoq.event/1` json
//! document a line. --follow keeps watching the logs and prints new events
//! as they come. --since leaves out events from before a time.

const std = @import("std");
const cli = @import("../cli.zig");
const events = @import("../events.zig");
const journal = @import("../journal.zig");
const Context = cli.Context;

/// how often --follow looks at the logs again. they only grow a few lines
/// an apply, so polling is plenty.
const poll_ms = 500;

pub fn eventsCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    const usage_text = "os events [--follow] [--since <unix ms, yyyy-mm-dd, or yyyy-mm-ddThh:mm[:ss]>]";
    var follow = false;
    var since: i64 = std.math.minInt(i64);
    var it: cli.ArgIter = .{ .args = args };
    while (it.next()) |arg| {
        if (cli.eql(arg, "--follow") or cli.eql(arg, "-f")) {
            follow = true;
        } else if (cli.eql(arg, "--since")) {
            since = events.parseSince(it.next() orelse return cli.usageError(ctx, usage_text)) orelse return cli.usageError(ctx, usage_text);
        } else return cli.usageError(ctx, usage_text);
    }
    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena.deinit();
    var offsets: events.Offsets = @splat(0);
    while (true) {
        _ = arena.reset(.retain_capacity);
        const batch = try events.poll(arena.allocator(), ctx.io, ctx.root, &offsets);
        // a reader that went away, like `head`, ends the command.
        write(ctx.out, batch, since) catch return 0;
        if (!follow) return 0;
        try ctx.io.sleep(.fromMilliseconds(poll_ms), .awake);
    }
}

fn write(out: *std.Io.Writer, batch: []const events.Event, since: i64) !void {
    for (batch) |e| if (e.time >= since) try events.encode(out, e);
    try out.flush();
}

test "os events prints the logs as json lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    try journal.record(a, std.testing.io, root, 1, "begin", "abc");
    try journal.record(a, std.testing.io, root, 2, "done", "abc");

    var t: cli.TestRun = .{};
    defer t.deinit();
    try t.exec(&.{ "--root", root, "events" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqualStrings(
        \\{"schema":"yoq.event/1","time":1,"kind":"apply","step":"begin","plan":"abc"}
        \\{"schema":"yoq.event/1","time":2,"kind":"apply","step":"done","plan":"abc"}
        \\
    , t.out.buffered());

    try t.exec(&.{ "--root", root, "events", "--since" });
    try std.testing.expectEqual(2, t.code);
    try t.exec(&.{ "--root", root, "events", "--since", "last week" });
    try std.testing.expectEqual(2, t.code);
}

test "os events --since leaves out what came before" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    const day = events.parseSince("2026-09-30").?;
    try journal.record(a, std.testing.io, root, day - 1, "begin", "abc");
    try journal.record(a, std.testing.io, root, day, "done", "abc");

    var t: cli.TestRun = .{};
    defer t.deinit();
    try t.exec(&.{ "--root", root, "events", "--since", "2026-09-30" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqualStrings(
        \\{"schema":"yoq.event/1","time":1790726400000,"kind":"apply","step":"done","plan":"abc"}
        \\
    , t.out.buffered());
}
