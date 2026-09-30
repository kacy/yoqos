//! what a package transaction is doing, while it does it: downloads,
//! checks, installs, removals, and hooks. libalpm's callbacks turn into
//! `Event`s in alpm_c.zig, and `Progress` decides what to print.
//!
//! on a terminal, a phase that counts things is one line redrawn in place.
//! anywhere else, like a log, it's a line when it starts and one at each
//! quarter of a long one, so a big update stays a few lines.

const std = @import("std");

/// how a command shows progress: not at all, as a log would want it, or
/// redrawn on a terminal.
pub const Mode = enum { off, log, terminal };

/// a phase that counts packages or hooks as they go.
pub const Phase = enum { download, install, remove, hooks };

/// a check libalpm runs over every package before changing any.
pub const Check = enum { keys, integrity, load, conflicts, diskspace };

pub const Event = union(enum) {
    /// downloading starts. `bytes` is 0 or less when it isn't known.
    download: struct { count: usize, bytes: i64 },
    /// one package finished downloading.
    downloaded,
    /// libalpm is `current` of `total` packages into installing or
    /// removing, on `name` now.
    step: struct { phase: Phase, name: []const u8, current: usize, total: usize },
    check: Check,
    /// a hook starts, `current` of `total`.
    hook: struct { name: []const u8, current: usize, total: usize },
    /// the running phase is over.
    end,
};

/// a long phase in a log gets a line at each quarter; a short one only
/// its first line.
const quarters_from = 20;
/// how much of a package or hook name the redrawn line shows, so it stays
/// on one line and `\r` can go back to its start.
const name_max = 40;

pub const Progress = struct {
    w: *std.Io.Writer,
    tty: bool,
    phase: ?Phase = null,
    check: ?Check = null,
    current: usize = 0,
    total: usize = 0,
    /// a download's size, 0 when it isn't known.
    bytes: u64 = 0,
    /// how many quarters of the phase a log has had a line for.
    quarter: usize = 0,
    /// a redrawn line is on the terminal without its newline.
    open: bool = false,

    /// prints what `e` means, if anything. output is best effort: a write
    /// that fails is dropped, since progress must never stop a transaction.
    pub fn feed(p: *Progress, e: Event) void {
        p.apply(e) catch {};
        p.w.flush() catch {};
    }

    fn apply(p: *Progress, e: Event) !void {
        switch (e) {
            .download => |d| try p.start(.download, d.count, if (d.bytes > 0) @intCast(d.bytes) else 0),
            .downloaded => {
                if (p.phase != .download) return;
                try p.advance(p.current + 1, "");
            },
            .step => |s| {
                if (p.phase != s.phase) try p.start(s.phase, s.total, 0);
                // libalpm reports each package many times on its way from
                // 0 to 100 percent; only a new one is news.
                if (s.current != p.current) try p.advance(s.current, s.name);
            },
            .check => |c| {
                if (p.check == c) return;
                try p.end();
                p.check = c;
                try p.w.print("{s}\n", .{switch (c) {
                    .keys => "checking keys",
                    .integrity => "checking packages",
                    .load => "loading packages",
                    .conflicts => "checking file conflicts",
                    .diskspace => "checking disk space",
                }});
            },
            .hook => |h| {
                if (p.phase != .hooks) try p.start(.hooks, h.total, 0);
                try p.advance(h.current, h.name);
            },
            .end => try p.end(),
        }
    }

    fn start(p: *Progress, phase: Phase, total: usize, bytes: u64) !void {
        try p.end();
        p.* = .{ .w = p.w, .tty = p.tty, .phase = phase, .total = total, .bytes = bytes, .open = p.tty };
        if (p.tty) return p.draw("");
        try p.head();
        try p.w.writeByte('\n');
    }

    fn advance(p: *Progress, current: usize, name: []const u8) !void {
        p.current = current;
        if (p.tty) return p.draw(name);
        if (p.total < quarters_from) return;
        const q = @min(p.current, p.total) * 4 / p.total;
        if (q <= p.quarter or q >= 4) return;
        p.quarter = q;
        try p.w.print("  {d}/{d}\n", .{ p.current, p.total });
    }

    /// redraws a terminal's line: the phase, how far it got, and what it's
    /// on now.
    fn draw(p: *Progress, name: []const u8) !void {
        if (!p.tty) return;
        try p.w.writeAll("\r\x1b[K");
        try p.head();
        if (p.current == 0) return;
        try p.w.print("  {d}", .{p.current});
        if (p.total > 0) try p.w.print("/{d}", .{p.total});
        if (name.len == 0) return;
        try p.w.writeByte(' ');
        for (name[0..@min(name.len, name_max)]) |ch| try p.w.writeByte(if (ch < 0x20 or ch == 0x7f) '?' else ch);
    }

    /// what the phase is: how many of what, and a download's size.
    fn head(p: *Progress) !void {
        const phase = p.phase orelse return;
        try p.w.writeAll(switch (phase) {
            .download => "downloading ",
            .install => "installing ",
            .remove => "removing ",
            .hooks => "running ",
        });
        try count(p.w, p.total, if (phase == .hooks) "hook" else "package");
        if (p.bytes > 0) {
            try p.w.writeAll(", ");
            try size(p.w, p.bytes);
        }
    }

    /// ends the running phase. a terminal's line is left showing how far
    /// it got, without a name.
    pub fn end(p: *Progress) !void {
        if (p.open) {
            try p.draw("");
            try p.w.writeByte('\n');
        }
        p.* = .{ .w = p.w, .tty = p.tty, .check = p.check };
    }
};

fn count(w: *std.Io.Writer, n: usize, noun: []const u8) !void {
    if (n == 0) return w.print("{s}s", .{noun});
    try w.print("{d} {s}{s}", .{ n, noun, if (n == 1) "" else "s" });
}

/// a size in MiB, or KiB below one MiB, rounded up so it's never 0.
fn size(w: *std.Io.Writer, bytes: u64) !void {
    if (bytes < 1 << 20) return w.print("{d} KiB", .{(bytes + 1023) / 1024});
    try w.print("{d} MiB", .{(bytes + (1 << 19)) >> 20});
}

// -- tests --

const testing = std.testing;

fn run(tty: bool, events: []const Event) ![]const u8 {
    const S = struct {
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = undefined;
    };
    S.w = .fixed(&S.buf);
    var p: Progress = .{ .w = &S.w, .tty = tty };
    for (events) |e| p.feed(e);
    p.feed(.end);
    return S.w.buffered();
}

/// a transaction the way libalpm reports it: `n` packages downloaded,
/// checked, and installed, reporting each one at 0 and 100 percent.
fn transaction(a: std.mem.Allocator, n: usize) ![]const Event {
    var out: std.ArrayList(Event) = .empty;
    try out.append(a, .{ .download = .{ .count = n, .bytes = 612 << 20 } });
    for (0..n) |_| try out.append(a, .downloaded);
    try out.append(a, .end);
    try out.append(a, .{ .check = .keys });
    try out.append(a, .{ .check = .keys });
    try out.append(a, .{ .check = .integrity });
    for (1..n + 1) |i| {
        try out.append(a, .{ .step = .{ .phase = .install, .name = "linux", .current = i, .total = n } });
        try out.append(a, .{ .step = .{ .phase = .install, .name = "linux", .current = i, .total = n } });
    }
    try out.append(a, .end);
    try out.append(a, .{ .hook = .{ .name = "20-systemd-sysusers", .current = 1, .total = 2 } });
    try out.append(a, .{ .hook = .{ .name = "90-mkinitcpio-install", .current = 2, .total = 2 } });
    try out.append(a, .end);
    return out.items;
}

test "a log gets a line per phase and one per quarter of a long one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        \\downloading 168 packages, 612 MiB
        \\  42/168
        \\  84/168
        \\  126/168
        \\checking keys
        \\checking packages
        \\installing 168 packages
        \\  42/168
        \\  84/168
        \\  126/168
        \\running 2 hooks
        \\
    , try run(false, try transaction(arena.allocator(), 168)));
}

test "a short phase in a log is one line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        \\downloading 3 packages, 612 MiB
        \\checking keys
        \\checking packages
        \\installing 3 packages
        \\running 2 hooks
        \\
    , try run(false, try transaction(arena.allocator(), 3)));
}

test "a terminal redraws one line per phase and ends it with how far it got" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try run(true, try transaction(arena.allocator(), 2));
    const clear = "\r\x1b[K";
    try testing.expectEqualStrings(
        clear ++ "downloading 2 packages, 612 MiB" ++
            clear ++ "downloading 2 packages, 612 MiB  1/2" ++
            clear ++ "downloading 2 packages, 612 MiB  2/2" ++
            clear ++ "downloading 2 packages, 612 MiB  2/2\n" ++
            "checking keys\nchecking packages\n" ++
            clear ++ "installing 2 packages" ++
            clear ++ "installing 2 packages  1/2 linux" ++
            clear ++ "installing 2 packages  2/2 linux" ++
            clear ++ "installing 2 packages  2/2\n" ++
            clear ++ "running 2 hooks" ++
            clear ++ "running 2 hooks  1/2 20-systemd-sysusers" ++
            clear ++ "running 2 hooks  2/2 90-mkinitcpio-install" ++
            clear ++ "running 2 hooks  2/2\n",
        got,
    );
}

test "odd inputs don't trip it" {
    const long = "a" ** 100;
    const got = try run(true, &.{
        // downloads of unknown size and count, and more than announced.
        .{ .download = .{ .count = 0, .bytes = -1 } },
        .downloaded,
        .downloaded,
        .{ .download = .{ .count = 1, .bytes = 0 } },
        .downloaded,
        .downloaded,
        // a step with no name or total, and a name with control bytes.
        .{ .step = .{ .phase = .remove, .name = "", .current = 0, .total = 0 } },
        .{ .step = .{ .phase = .remove, .name = "x\x1b]0;y\x07", .current = 1, .total = 0 } },
        .{ .hook = .{ .name = long, .current = 5, .total = 1 } },
        .end,
        .end,
    });
    try testing.expect(std.mem.indexOf(u8, got, "downloading packages  2") != null);
    try testing.expect(std.mem.indexOf(u8, got, "downloading 1 package  2/1") != null);
    try testing.expect(std.mem.indexOf(u8, got, "removing packages  1 x?]0;y?") != null);
    try testing.expect(std.mem.indexOf(u8, got, "a" ** 41) == null);
    try testing.expect(std.mem.endsWith(u8, got, "running 1 hook  5/1\n"));
    // a log doesn't divide by a total of 0.
    _ = try run(false, &.{
        .{ .download = .{ .count = 0, .bytes = 0 } },
        .downloaded,
        .{ .step = .{ .phase = .install, .name = "", .current = 3, .total = 0 } },
    });
}

test "sizes" {
    var buf: [32]u8 = undefined;
    for ([_]struct { u64, []const u8 }{
        .{ 1, "1 KiB" },
        .{ 1024, "1 KiB" },
        .{ 1 << 20, "1 MiB" },
        .{ 612 << 20, "612 MiB" },
        .{ (3 << 20) + (1 << 19), "4 MiB" },
    }) |case| {
        var w: std.Io.Writer = .fixed(&buf);
        try size(&w, case[0]);
        try testing.expectEqualStrings(case[1], w.buffered());
    }
}
