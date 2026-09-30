//! what os did, and what pacman did outside it, as `os events` prints it:
//! one `yoq.event/1` json document a line. there's no store of its own.
//! the events come from the two logs os keeps anyway: the journal, which
//! has applies and os's other changes, and the drift log of pacman runs.

const std = @import("std");
const facts = @import("facts.zig");
const journal = @import("journal.zig");
const drift = @import("drift.zig");
const rootfs = @import("rootfs.zig");
const Allocator = std.mem.Allocator;

pub const schema = "yoq.event/1";

pub const Kind = enum {
    /// an apply began, finished, or failed.
    apply,
    /// os committed the config.
    commit,
    /// a new generation was recorded.
    generation,
    /// `os rollback` went back to an earlier generation.
    rollback,
    /// a generation on trial was set up for the next boot, came up
    /// healthy, or didn't.
    trial,
    /// pacman ran outside os.
    pacman,
};

pub const Step = enum { begin, done, failed, armed, passed };

pub const Event = struct {
    schema: []const u8 = schema,
    /// unix milliseconds.
    time: i64,
    kind: Kind,
    /// apply: begin, done, or failed. trial: armed, passed, or failed.
    step: ?Step = null,
    /// apply: the plan's hash.
    plan: ?[]const u8 = null,
    /// generation, trial, and rollback: the generation's number. without
    /// generations, a rollback's is the config commit's, as `os history`
    /// numbers them.
    generation: ?u32 = null,
    /// commit: its message. generation: what made it.
    message: ?[]const u8 = null,
    /// pacman: the packages it touched.
    packages: ?[]const []const u8 = null,
};

/// writes `e` as one line of json, without its empty fields.
pub fn encode(w: *std.Io.Writer, e: Event) !void {
    try std.json.Stringify.value(e, .{ .emit_null_optional_fields = false }, w);
    try w.writeByte('\n');
}

/// adds `e` to the journal. like the journal's own lines, one that can't
/// be written is dropped.
pub fn record(a: Allocator, io: std.Io, root: []const u8, e: Event) !void {
    try journal.appendLine(a, io, root, journal.path, e);
}

/// the event a line of the journal or the drift log holds, or null for a
/// line that isn't one.
pub fn decode(a: Allocator, line: []const u8) ?Event {
    const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    if (std.json.parseFromSliceLeaky(Event, a, line, opts)) |e| return e else |_| {}
    if (std.json.parseFromSliceLeaky(journal.Line, a, line, opts)) |l| {
        const step = std.meta.stringToEnum(Step, l.event) orelse return null;
        return .{ .time = l.time, .kind = .apply, .step = step, .plan = l.plan };
    } else |_| {}
    if (std.json.parseFromSliceLeaky(facts.PacmanChange, a, line, opts)) |c| {
        return .{ .time = c.time, .kind = .pacman, .packages = c.packages };
    } else |_| {}
    return null;
}

/// the finished lines in `bytes` from `offset` on, and the offset to read
/// from next time. a last line without its newline is still being
/// written, so it waits for the next read. a file shorter than `offset`
/// was started over, and is read from the top.
pub fn newLines(bytes: []const u8, offset: usize) struct { lines: []const u8, next: usize } {
    const from = if (offset > bytes.len) 0 else offset;
    const end = if (std.mem.lastIndexOfScalar(u8, bytes[from..], '\n')) |i| from + i + 1 else from;
    return .{ .lines = bytes[from..end], .next = end };
}

/// the logs events come from, under a machine's root.
pub const sources = [_][]const u8{ journal.path, drift.path };

/// where each of `sources` has been read up to.
pub const Offsets = [sources.len]usize;

/// the events added to the logs under `root` since `offsets`, oldest
/// first, and moves `offsets` past them.
pub fn poll(a: Allocator, io: std.Io, root: []const u8, offsets: *Offsets) ![]Event {
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    var out: std.ArrayList(Event) = .empty;
    for (sources, offsets) |path, *offset| {
        const got = newLines(try fs.read(path), offset.*);
        offset.* = got.next;
        var lines = std.mem.tokenizeScalar(u8, got.lines, '\n');
        while (lines.next()) |line| {
            if (decode(a, line)) |e| try out.append(a, e);
        }
    }
    // stable, so events with the same time keep their order in a log.
    std.mem.sort(Event, out.items, {}, struct {
        fn lt(_: void, x: Event, y: Event) bool {
            return x.time < y.time;
        }
    }.lt);
    return out.items;
}

// -- tests --

const testing = std.testing;

fn encoded(a: Allocator, e: Event) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try encode(&out.writer, e);
    return out.written();
}

test "an event goes out as one line, without its empty fields, and comes back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line = try encoded(a, .{ .time = 5, .kind = .trial, .step = .armed, .generation = 4 });
    try testing.expectEqualStrings(
        \\{"schema":"yoq.event/1","time":5,"kind":"trial","step":"armed","generation":4}
        \\
    , line);
    const back = decode(a, line[0 .. line.len - 1]).?;
    try testing.expectEqual(.trial, back.kind);
    try testing.expectEqual(.armed, back.step.?);
    try testing.expectEqual(4, back.generation.?);
    try testing.expectEqual(null, back.plan);
}

test "the journal's apply lines and the drift log's lines are events too" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const apply = decode(a, "{\"time\":1,\"event\":\"done\",\"plan\":\"abc\"}").?;
    try testing.expectEqual(.apply, apply.kind);
    try testing.expectEqual(.done, apply.step.?);
    try testing.expectEqualStrings("abc", apply.plan.?);
    try testing.expectEqualStrings(
        \\{"schema":"yoq.event/1","time":1,"kind":"apply","step":"done","plan":"abc"}
        \\
    , try encoded(a, apply));

    const pacman = decode(a, "{\"time\":2,\"packages\":[\"htop\"]}").?;
    try testing.expectEqual(.pacman, pacman.kind);
    try testing.expectEqualStrings("htop", pacman.packages.?[0]);

    try testing.expectEqual(null, decode(a, "{\"time\":3,\"event\":\"odd\",\"plan\":\"x\"}"));
    try testing.expectEqual(null, decode(a, "{\"time\":3,\"kind\":\"odd\"}"));
    try testing.expectEqual(null, decode(a, "{\"time\":"));
}

test "new lines wait for their newline, and a file started over is read again" {
    const got = newLines("one\ntwo\nthr", 0);
    try testing.expectEqualStrings("one\ntwo\n", got.lines);
    try testing.expectEqual(8, got.next);
    const more = newLines("one\ntwo\nthree\n", got.next);
    try testing.expectEqualStrings("three\n", more.lines);
    try testing.expectEqual(14, more.next);
    const none = newLines("one\ntwo\nthree\n", more.next);
    try testing.expectEqualStrings("", none.lines);
    try testing.expectEqual(14, none.next);
    const over = newLines("four\n", 14);
    try testing.expectEqualStrings("four\n", over.lines);
    try testing.expectEqual(5, over.next);
    try testing.expectEqual(0, newLines("", 0).next);
}

test "polling reads both logs in time order, then only what's new" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var offsets: Offsets = @splat(0);
    try testing.expectEqual(0, (try poll(a, io, root, &offsets)).len);
    try journal.record(a, io, root, 10, "begin", "abc");
    try drift.record(a, io, root, 15, &.{"htop"});
    try journal.record(a, io, root, 20, "done", "abc");
    try record(a, io, root, .{ .time = 30, .kind = .commit, .message = "add fd" });

    const first = try poll(a, io, root, &offsets);
    try testing.expectEqual(4, first.len);
    try testing.expectEqual(.apply, first[0].kind);
    try testing.expectEqual(.pacman, first[1].kind);
    try testing.expectEqual(.done, first[2].step.?);
    try testing.expectEqualStrings("add fd", first[3].message.?);

    try testing.expectEqual(0, (try poll(a, io, root, &offsets)).len);
    try record(a, io, root, .{ .time = 40, .kind = .generation, .generation = 3, .message = "add fd" });
    const next = try poll(a, io, root, &offsets);
    try testing.expectEqual(1, next.len);
    try testing.expectEqual(3, next[0].generation.?);
}
