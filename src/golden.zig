//! golden tests. each directory in tests/golden holds a machine.toml (and
//! any files it includes), a machine.lock, and a facts.json. the test builds
//! the plan and compares it with plan.txt and plan.json, or with errors.txt
//! when the inputs are meant to fail.
//!
//! `zig build test -Dupdate-golden` rewrites the expected files instead of
//! comparing, for when a change to the output is intended.

const std = @import("std");
const build_options = @import("build_options");
const disk = @import("disk.zig");
const diag = @import("diag.zig");
const pipeline = @import("pipeline.zig");
const planner = @import("planner.zig");
const status = @import("status.zig");
const sort = @import("sort.zig");

const root = "tests/golden";

test "golden plans" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |e| {
        std.debug.print("can't open {s}: {s}\n", .{ root, @errorName(e) });
        return e;
    };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    sort.strings(names.items);
    try std.testing.expect(names.items.len > 0);

    var failed: usize = 0;
    for (names.items) |name| {
        runCase(gpa, io, dir, name) catch |e| {
            std.debug.print("golden case {s} failed: {s}\n", .{ name, @errorName(e) });
            failed += 1;
        };
    }
    if (failed > 0) return error.GoldenMismatch;
}

fn runCase(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var files: disk.Files = .{ .io = io };
    var diags: diag.List = .init(gpa);
    defer diags.deinit();
    const in: pipeline.Inputs = .{
        .config_path = try std.fmt.allocPrint(a, "{s}/{s}/machine.toml", .{ root, name }),
        .facts_path = try std.fmt.allocPrint(a, "{s}/{s}/facts.json", .{ root, name }),
    };

    var outputs: std.ArrayList(struct { []const u8, []const u8 }) = .empty;
    if (try pipeline.buildPlan(gpa, io, files.files(), in, &diags)) |r| {
        var result = r;
        defer result.deinit();
        var text: std.Io.Writer.Allocating = .init(a);
        try planner.writeText(&text.writer, a, &result.plan, .{ .verbose = true });
        var json: std.Io.Writer.Allocating = .init(a);
        try planner.writeJson(&json.writer, a, &result.plan);
        var st: std.Io.Writer.Allocating = .init(a);
        const s = try status.summarize(a, result.state.config(), &result.state.lock, &result.facts, &result.plan);
        try status.writeText(&st.writer, &s);
        try outputs.append(a, .{ "plan.txt", text.written() });
        try outputs.append(a, .{ "plan.json", json.written() });
        try outputs.append(a, .{ "status.txt", st.written() });
    } else {
        var text: std.Io.Writer.Allocating = .init(a);
        try diags.render(&text.writer);
        try outputs.append(a, .{ "errors.txt", text.written() });
    }

    var case = try dir.openDir(io, name, .{});
    defer case.close(io);
    for (outputs.items) |o| {
        if (build_options.update_golden) {
            try case.writeFile(io, .{ .sub_path = o[0], .data = o[1] });
            continue;
        }
        const want = case.readFileAlloc(io, o[0], a, .limited(1 << 20)) catch |e| {
            std.debug.print("{s}/{s}: missing {s}. run `zig build test -Dupdate-golden` to create it.\n", .{ root, name, o[0] });
            return e;
        };
        if (!std.mem.eql(u8, want, o[1])) {
            std.debug.print("{s}/{s}/{s} differs.\n--- expected\n{s}--- got\n{s}", .{ root, name, o[0], want, o[1] });
            return error.GoldenMismatch;
        }
    }
}
