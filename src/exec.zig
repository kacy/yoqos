//! runs the few programs yos uses as backends, like git and shadow's tools:
//! fixed arguments, never a shell.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Child = std.process.Child;

/// what a program printed when it succeeded, or what went wrong.
pub const Output = union(enum) {
    /// its standard output, byte for byte.
    ok: []const u8,
    /// its own message, or why it couldn't start.
    failed: []const u8,
};

/// what ends a run from outside: ctrl-c, a dropped ssh session, a kill,
/// and ctrl-\.
const stop_signals = [_]std.posix.SIG{ .INT, .TERM, .HUP, .QUIT };

var stop_asked = std.atomic.Value(bool).init(false);

/// how the stop signals are handled for a while, until `restore`.
pub const Stops = struct {
    old: [stop_signals.len]std.posix.Sigaction,

    /// ignored, by yos and by what it runs meanwhile, which inherits
    /// that: for work that's worse cut off than finished, like a package
    /// transaction and its hooks.
    pub fn ignore() Stops {
        return set(std.posix.SIG.IGN);
    }

    /// noted rather than ending yos: a program it runs then still gets
    /// one, and fails, and `asked` says it came, so yos can take back
    /// what it did, step by step, before it stops.
    pub fn note() Stops {
        stop_asked.store(false, .seq_cst);
        return set(noteStop);
    }

    pub fn restore(s: Stops) void {
        for (stop_signals, s.old) |sig, o| std.posix.sigaction(sig, &o, null);
    }

    /// whether a stop signal came since `note`.
    pub fn asked() bool {
        return stop_asked.load(.seq_cst);
    }

    fn set(handler: ?std.posix.Sigaction.handler_fn) Stops {
        const act: std.posix.Sigaction = .{ .handler = .{ .handler = handler }, .mask = std.posix.sigemptyset(), .flags = 0 };
        var s: Stops = undefined;
        for (stop_signals, &s.old) |sig, *o| std.posix.sigaction(sig, &act, o);
        return s;
    }

    fn noteStop(_: std.posix.SIG) callconv(.c) void {
        stop_asked.store(true, .seq_cst);
    }
};

/// runs `argv` and waits for it.
pub fn output(a: Allocator, io: std.Io, argv: []const []const u8) error{OutOfMemory}!Output {
    const r = std.process.run(a, io, .{ .argv = argv }) catch |e| return .{ .failed = try spawnFailed(a, argv, e) };
    if (succeeded(r.term)) return .{ .ok = r.stdout };
    const out = std.mem.trim(u8, if (r.stderr.len > 0) r.stderr else r.stdout, " \n");
    return .{ .failed = if (out.len > 0) out else try failed(a, argv) };
}

/// runs `argv` for its effect. returns null when it succeeds, or what went
/// wrong.
pub fn run(a: Allocator, io: std.Io, argv: []const []const u8) error{OutOfMemory}!?[]const u8 {
    return switch (try output(a, io, argv)) {
        .ok => null,
        .failed => |why| why,
    };
}

/// runs each command in turn, stopping at the first that fails, and says
/// why it failed.
pub fn runAll(a: Allocator, io: std.Io, argvs: []const []const []const u8) error{OutOfMemory}!?[]const u8 {
    for (argvs) |argv| {
        if (try run(a, io, argv)) |why| return why;
    }
    return null;
}

/// runs `argv` like `run`, and keeps everything it printed, both streams,
/// in the file at `log`. a failure says where the log is, with its last
/// lines, since a build's reason can be on either stream.
pub fn runLogged(a: Allocator, io: std.Io, argv: []const []const u8, log: []const u8) error{OutOfMemory}!?[]const u8 {
    const r = std.process.run(a, io, .{ .argv = argv }) catch |e| return try spawnFailed(a, argv, e);
    const both = try std.mem.concat(a, u8, &.{ r.stdout, r.stderr });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = log, .data = both }) catch {};
    if (succeeded(r.term)) return null;
    return try std.fmt.allocPrint(a, "{s} failed; its whole output is in {s}. the end of it:\n{s}", .{ argv[0], log, lastLines(both, 20) });
}

/// runs `argv` on the terminal yos runs on, for a program that asks the
/// person there something itself, like passwd. null when it succeeds.
pub fn interactive(a: Allocator, io: std.Io, argv: []const []const u8) error{OutOfMemory}!?[]const u8 {
    var child = std.process.spawn(io, .{ .argv = argv }) catch |e| return try spawnFailed(a, argv, e);
    return wait(a, io, &child, argv);
}

/// runs `argv` with `input` written to its standard input, for a secret
/// that mustn't go on its command line or into a file. what it prints
/// goes nowhere, and what it says when it fails goes to yos's standard
/// error.
pub fn runInput(a: Allocator, io: std.Io, argv: []const []const u8, input: []const u8) error{OutOfMemory}!?[]const u8 {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .ignore }) catch |e| return try spawnFailed(a, argv, e);
    const sent = if (child.stdin.?.writeStreamingAll(io, input)) true else |_| false;
    child.stdin.?.close(io);
    child.stdin = null;
    const why = try wait(a, io, &child, argv);
    return why orelse if (sent) null else try failed(a, argv);
}

/// runs `argv` with the file at `input` as its standard input, for a
/// program that reads a script there, like sfdisk. what it prints goes
/// nowhere; a failure says it failed.
pub fn runFrom(a: Allocator, io: std.Io, argv: []const []const u8, input: []const u8) error{OutOfMemory}!?[]const u8 {
    var f = std.Io.Dir.cwd().openFile(io, input, .{}) catch return try std.fmt.allocPrint(a, "can't read {s}", .{input});
    defer f.close(io);
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .{ .file = f }, .stdout = .ignore, .stderr = .ignore }) catch |e| return try spawnFailed(a, argv, e);
    return wait(a, io, &child, argv);
}

/// runs `argv` with `input` on its standard input, through a pipe, so
/// the bytes never touch the disk. null when it succeeds, or what it said
/// went wrong.
pub fn feed(a: Allocator, io: std.Io, argv: []const []const u8, input: []const u8) error{OutOfMemory}!?[]const u8 {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .ignore, .stderr = .pipe }) catch |e| return try spawnFailed(a, argv, e);
    // a program that quits early closes its end; what it said explains why.
    child.stdin.?.writeStreamingAll(io, input) catch {};
    child.stdin.?.close(io);
    child.stdin = null;
    return finish(a, io, &child, argv);
}

/// what a program printed into a buffer of the caller's, or what went
/// wrong.
pub const Captured = union(enum) {
    ok: []u8,
    failed: []const u8,
};

/// runs `argv` and reads what it prints into `out`, which is never grown
/// or copied, so the caller can wipe the only copy. more than fits is a
/// failure.
pub fn capture(a: Allocator, io: std.Io, argv: []const []const u8, out: []u8) error{OutOfMemory}!Captured {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe }) catch |e| return .{ .failed = try spawnFailed(a, argv, e) };
    var n: usize = 0;
    while (n < out.len) {
        // a read that fails isn't the end: what came so far is cut short.
        const got = child.stdout.?.readStreaming(io, &.{out[n..]}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => {
                child.kill(io);
                return .{ .failed = try std.fmt.allocPrint(a, "can't read what {s} printed", .{argv[0]}) };
            },
        };
        if (got == 0) break;
        n += got;
    }
    if (n == out.len) {
        child.kill(io);
        return .{ .failed = try std.fmt.allocPrint(a, "{s} printed more than {d} bytes", .{ argv[0], out.len - 1 }) };
    }
    if (try finish(a, io, &child, argv)) |why| return .{ .failed = why };
    return .{ .ok = out[0..n] };
}

/// reads what a spawned `argv` says on its standard error, then waits for
/// it. null when it succeeds.
fn finish(a: Allocator, io: std.Io, child: *Child, argv: []const []const u8) error{OutOfMemory}!?[]const u8 {
    var buf: [1024]u8 = undefined;
    var r = child.stderr.?.readerStreaming(io, &buf);
    const said = r.interface.allocRemaining(a, .limited(64 << 10)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => "",
    };
    if (try wait(a, io, child, argv)) |why| {
        const trimmed = std.mem.trim(u8, said, " \n");
        return if (trimmed.len > 0) trimmed else why;
    }
    return null;
}

/// waits for a spawned `argv` to exit. null when it succeeds.
fn wait(a: Allocator, io: std.Io, child: *Child, argv: []const []const u8) error{OutOfMemory}!?[]const u8 {
    const term = child.wait(io) catch |e| return try std.fmt.allocPrint(a, "{s} didn't finish: {s}", .{ argv[0], @errorName(e) });
    return if (succeeded(term)) null else try failed(a, argv);
}

fn succeeded(term: Child.Term) bool {
    return term == .exited and term.exited == 0;
}

fn failed(a: Allocator, argv: []const []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(a, "{s} failed", .{argv[0]});
}

/// why `argv` couldn't start.
fn spawnFailed(a: Allocator, argv: []const []const u8, e: anyerror) error{OutOfMemory}![]const u8 {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => try std.fmt.allocPrint(a, "can't run {s}: it isn't installed", .{argv[0]}),
        else => try std.fmt.allocPrint(a, "can't run {s}: {s}", .{ argv[0], @errorName(e) }),
    };
}

test "a program reads what's written to its standard input" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    try std.testing.expectEqual(null, try runInput(arena.allocator(), io, &.{ "grep", "-qx", "secret" }, "secret"));
    try std.testing.expect(try runInput(arena.allocator(), io, &.{ "grep", "-qx", "other" }, "secret") != null);
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

test "a missing program and a failing one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("can't run yos-no-such-tool: it isn't installed", (try run(a, std.testing.io, &.{"yos-no-such-tool"})).?);
    try std.testing.expectEqual(null, try run(a, std.testing.io, &.{"true"}));
    try std.testing.expectEqualStrings("false failed", (try run(a, std.testing.io, &.{"false"})).?);
    try std.testing.expectEqualStrings("hi\n", (try output(a, std.testing.io, &.{ "echo", "hi" })).ok);
    try std.testing.expectEqualStrings("false failed", (try runAll(a, std.testing.io, &.{ &.{"true"}, &.{"false"}, &.{"yos-no-such-tool"} })).?);
}

test "input through a pipe, and output into a buffer" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    try std.testing.expectEqual(null, try feed(a, io, &.{ "sh", "-c", "test \"$(cat)\" = hunter2" }, "hunter2"));
    try std.testing.expectEqualStrings("no", (try feed(a, io, &.{ "sh", "-c", "cat >/dev/null; echo no >&2; exit 1" }, "x")).?);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("abc", (try capture(a, io, &.{ "printf", "abc" }, &buf)).ok);
    try std.testing.expectEqualStrings("printf printed more than 7 bytes", (try capture(a, io, &.{ "printf", "abcdefghij" }, &buf)).failed);
    try std.testing.expectEqualStrings("bad", (try capture(a, io, &.{ "sh", "-c", "echo bad >&2; exit 3" }, &buf)).failed);
}

test "a log's last lines" {
    try std.testing.expectEqualStrings("b\nc", lastLines("a\nb\nc\n", 2));
    try std.testing.expectEqualStrings("a\nb", lastLines("a\nb\n", 5));
}
