//! how a plan looks: the screen `os plan`, `os apply`, and `os update`
//! show, and the json document `os plan --json` prints and `os plan -o`
//! saves.

const std = @import("std");
const catalog = @import("catalog.zig");
const output = @import("output.zig");
const planner = @import("planner.zig");
const Plan = planner.Plan;
const Change = planner.Change;
const Kind = planner.Kind;
const Op = planner.Op;
const Summary = planner.Summary;
const Allocator = std.mem.Allocator;

pub const RenderOptions = struct {
    /// list each dependency instead of counting them.
    verbose: bool = false,
    /// packages as counts and the notable few, for big updates.
    summary: bool = false,
    /// the plan was shown already, so it isn't again.
    quiet: bool = false,
};

pub fn writeText(w: *std.Io.Writer, a: Allocator, p: *const Plan, opts: RenderOptions) !void {
    if (p.empty()) {
        try w.writeAll("nothing to do. this machine matches its config.\n");
        return;
    }

    if (opts.summary and !opts.verbose) {
        try packageSummary(w, p);
    } else if (has(p, .package) or has(p, .dependency) or has(p, .reason)) {
        try w.writeAll("packages\n");
        try lines(w, p, &.{.package});
        if (opts.verbose) {
            try lines(w, p, &.{ .dependency, .reason });
        } else {
            try depSummary(w, p);
        }
    }
    inline for (.{ .{ "system", Kind.setting }, .{ "users", Kind.user }, .{ "services", Kind.unit }, .{ "files", Kind.file }, .{ "repositories", Kind.pacman_conf }, .{ "keys", Kind.key } }) |section| {
        if (has(p, section[1])) {
            try w.writeAll(section[0] ++ "\n");
            try lines(w, p, &.{section[1]});
        }
    }

    const n = p.summary();
    try w.print("\nplan: {d} to add, {d} to change, {d} to remove", .{ n.add, n.change, n.remove });
    const reasons = try p.rebootReasons(a);
    if (reasons.len == 0) {
        try w.writeAll(" · no reboot\n");
    } else {
        try w.print(" · reboot needed: {s}\n", .{try std.mem.join(a, ", ", reasons)});
    }
}

fn has(p: *const Plan, kind: Kind) bool {
    for (p.changes) |c| {
        if (c.kind == kind) return true;
    }
    return false;
}

fn mark(op: Op) u8 {
    return switch (op) {
        .add => '+',
        .change => '~',
        .remove => '-',
    };
}

/// a line for each change of one of `kinds`, in plan order.
fn lines(w: *std.Io.Writer, p: *const Plan, kinds: []const Kind) !void {
    for (p.changes) |c| {
        if (std.mem.indexOfScalar(Kind, kinds, c.kind) != null) try line(w, c);
    }
}

fn line(w: *std.Io.Writer, c: Change) !void {
    try w.print("  {c} ", .{mark(c.op)});
    switch (c.kind) {
        .package, .dependency => {
            try w.writeAll(c.subject);
            if (c.from != null and c.to != null) {
                try w.print(" {s} -> {s}", .{ c.from.?, c.to.? });
            } else if (c.to orelse c.from) |v| {
                try w.print(" {s}", .{v});
            }
            if (c.kind == .dependency) try w.writeAll(" (dependency)");
        },
        .reason => try w.print("{s}: mark as {s}", .{ c.subject, c.to.? }),
        .setting => {
            const key = c.subject["system.".len..];
            if (c.from) |from| {
                try w.print("{s}: {s} -> {s}", .{ key, from, c.to.? });
            } else {
                try w.print("{s}: {s}", .{ key, c.to.? });
            }
        },
        .unit, .file, .key, .pacman_conf => try w.print("{s}: {s}", .{ c.subject, c.to.? }),
        .user => if (c.from != null and c.to != null) {
            // "shell bash -> shell zsh" reads better as "shell bash -> zsh".
            const from = c.from.?;
            const to = c.to.?;
            const space = std.mem.indexOfScalar(u8, to, ' ');
            const shared = space != null and std.mem.startsWith(u8, from, to[0 .. space.? + 1]);
            try w.print("{s}: {s} -> {s}", .{ c.subject, from, if (shared) to[space.? + 1 ..] else to });
        } else try w.print("{s}: {s}", .{ c.subject, c.to orelse c.from.? }),
    }
    if (c.cause) |cause| {
        if (c.kind != .user) try w.print("  ({s})", .{cause});
    }
    try w.writeByte('\n');
}

/// the update screen's packages: how many move, and the ones worth a look
/// before saying yes.
fn packageSummary(w: *std.Io.Writer, p: *const Plan) !void {
    const n = p.tally(&.{ .package, .dependency });
    if (n.total() == 0) return;
    try w.print("packages\n  upgrades {d}    new {d}    removed {d}   (-v lists them)\n", .{ n.change, n.add, n.remove });
    // what needs a reboot first, so the kernel is never among "and n more".
    var shown: usize = 0;
    for (std.enums.values(Notable)) |rank| {
        for (p.changes) |c| {
            if ((c.kind != .package and c.kind != .dependency) or c.op != .change or notable(c) != rank) continue;
            if (shown < max_notable) {
                try w.print("  {s:<9}{s} {s} -> {s}\n", .{ if (shown == 0) "notable" else "", c.subject, c.from.?, c.to.? });
            }
            shown += 1;
        }
    }
    if (shown > max_notable) try w.print("           and {d} more\n", .{shown - max_notable});
}

/// enough to see what matters and still fit the screen with the news and
/// the prompt.
const max_notable = 8;

/// an upgrade worth a look: one that needs a reboot, one the catalog
/// flags, like graphics and boot, or a new major version.
/// why an upgrade is worth a look, in the order the screen lists them.
const Notable = enum { reboot, named, major };

fn notable(c: Change) ?Notable {
    if (c.reboot != null or catalog.rebootReason(c.subject) != null) return .reboot;
    if (catalog.notable(c.subject)) return .named;
    return if (std.mem.eql(u8, majorOf(c.from.?), majorOf(c.to.?))) null else .major;
}

/// "1:2.3.4-1" and "2.3.4-1" are both major version "2".
fn majorOf(version: []const u8) []const u8 {
    const v = if (std.mem.indexOfScalar(u8, version, ':')) |i| version[i + 1 ..] else version;
    return v[0 .. std.mem.indexOfAny(u8, v, ".-+_") orelse v.len];
}

/// "+2, -1 dependencies": the counts that aren't zero.
fn depSummary(w: *std.Io.Writer, p: *const Plan) !void {
    const n = p.tally(&.{ .dependency, .reason });
    if (n.total() == 0) return;
    try w.writeAll("  ");
    var first = true;
    for (std.enums.values(Op)) |op| {
        const count = n.of(op);
        if (count == 0) continue;
        if (!first) try w.writeAll(", ");
        first = false;
        try w.print("{c}{d}", .{ mark(op), count });
    }
    try w.writeAll(" dependencies (-v to list)\n");
}

/// a plan as json: what `os plan --json` prints, and `os plan -o` saves.
pub const Doc = struct {
    hash: []const u8,
    summary: Summary,
    reboot: struct { needed: bool, because: []const []const u8 },
    changes: []const Change,
};

pub fn writeJson(w: *std.Io.Writer, a: Allocator, p: *const Plan) !void {
    const h = try p.hash();
    const reasons = try p.rebootReasons(a);
    const doc: Doc = .{
        .hash = &h,
        .summary = p.summary(),
        .reboot = .{ .needed = reasons.len > 0, .because = reasons },
        .changes = p.changes,
    };
    try output.writeDoc(w, planner.schema, doc);
}

const testing = std.testing;
const helpers = @import("test_helpers.zig");
const T = helpers.Scratch;

test "the update summary counts packages and names the notable ones" {
    var t: T = .{};
    defer t.deinit();
    const p: Plan = .{ .changes = &.{
        .{ .op = .change, .kind = .package, .subject = "git", .from = "2.51.0-1", .to = "2.51.1-1" },
        .{ .op = .change, .kind = .package, .subject = "linux", .from = "6.16.8-1", .to = "6.17.1-1", .reboot = "kernel" },
        .{ .op = .change, .kind = .dependency, .subject = "mesa", .from = "1:25.1.0-1", .to = "1:25.2.0-1" },
        .{ .op = .change, .kind = .dependency, .subject = "icu", .from = "76.1-1", .to = "77.1-1" },
        .{ .op = .add, .kind = .dependency, .subject = "libnew", .to = "1.0-1" },
        .{ .op = .remove, .kind = .dependency, .subject = "libold", .from = "0.9-1" },
    } };
    var out: std.Io.Writer.Allocating = .init(t.a());
    try writeText(&out.writer, t.a(), &p, .{ .summary = true });
    try testing.expectEqualStrings(
        \\packages
        \\  upgrades 4    new 1    removed 1   (-v lists them)
        \\  notable  linux 6.16.8-1 -> 6.17.1-1
        \\           mesa 1:25.1.0-1 -> 1:25.2.0-1
        \\           icu 76.1-1 -> 77.1-1
        \\
        \\plan: 1 to add, 4 to change, 1 to remove · reboot needed: kernel
        \\
    , out.written());
}

test "the kernel comes first among notable packages, ahead of major versions" {
    var t: T = .{};
    defer t.deinit();
    var changes: [11]Change = undefined;
    for (changes[0..10], 0..) |*c, i| {
        c.* = .{ .op = .change, .kind = .dependency, .subject = try std.fmt.allocPrint(t.a(), "lib{d}", .{i}), .from = "1.0-1", .to = "2.0-1" };
    }
    changes[10] = .{ .op = .change, .kind = .package, .subject = "linux", .from = "6.16.8-1", .to = "6.16.9-1", .reboot = "kernel" };
    const p: Plan = .{ .changes = &changes };
    var out: std.Io.Writer.Allocating = .init(t.a());
    try writeText(&out.writer, t.a(), &p, .{ .summary = true });
    try testing.expect(std.mem.indexOf(u8, out.written(), "  notable  linux 6.16.8-1 -> 6.16.9-1\n           lib0 1.0-1 -> 2.0-1\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "           and 3 more\n") != null);
}

test "the update summary stops naming notable packages after a screenful" {
    var t: T = .{};
    defer t.deinit();
    var changes: [10]Change = undefined;
    for (&changes, 0..) |*c, i| {
        c.* = .{ .op = .change, .kind = .dependency, .subject = try std.fmt.allocPrint(t.a(), "lib{d}", .{i}), .from = "1.0-1", .to = "2.0-1" };
    }
    const p: Plan = .{ .changes = &changes };
    var out: std.Io.Writer.Allocating = .init(t.a());
    try writeText(&out.writer, t.a(), &p, .{ .summary = true });
    try testing.expect(std.mem.endsWith(u8, out.written(),
        \\           lib7 1.0-1 -> 2.0-1
        \\           and 2 more
        \\
        \\plan: 0 to add, 10 to change, 0 to remove · no reboot
        \\
    ));
}
