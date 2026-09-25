//! reads the three planner inputs and builds a plan. `os plan` and the
//! golden tests both go through here, so the tests cover the same path
//! users run.

const std = @import("std");
const compose = @import("compose.zig");
const config = @import("config.zig");
const lock = @import("lock.zig");
const facts = @import("facts.zig");
const planner = @import("planner.zig");
const diag = @import("diag.zig");
const Allocator = std.mem.Allocator;

pub const Inputs = struct {
    config_path: []const u8,
    /// defaults to machine.lock next to the config.
    lock_path: ?[]const u8 = null,
    facts_path: []const u8,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    plan: planner.Plan,

    pub fn deinit(r: *Result) void {
        r.arena.deinit();
    }
};

pub const Error = error{ OutOfMemory, BadFacts, FactsUnreadable };

/// builds the plan, or returns null with the reasons in `diags`.
pub fn buildPlan(gpa: Allocator, files: compose.Files, in: Inputs, diags: *diag.List) Error!?Result {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var loaded = try compose.load(gpa, files, in.config_path, diags);
    defer loaded.deinit();

    const lock_path = in.lock_path orelse try std.fs.path.join(a, &.{ std.fs.path.dirnamePosix(in.config_path) orelse ".", "machine.lock" });
    const lock_bytes = files.readFn(files.ctx, a, lock_path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            try diags.add(.lock_stale, null, "{s} can't be read", .{lock_path}, "run `os update` to resolve the config into a lock");
            break :blk null;
        },
    };
    const l = if (lock_bytes) |b| try lock.parse(a, lock_path, b, diags) else null;

    const f = try readFacts(files, a, in.facts_path);

    if (diags.items.items.len > 0 or l == null) {
        arena.deinit();
        return null;
    }
    // the plan borrows strings from the config, so it has to be built while
    // `loaded` is alive and then copied into our arena.
    const p = try planner.plan(a, &loaded.config, &l.?, &f, diags) orelse {
        arena.deinit();
        return null;
    };
    return .{ .arena = arena, .plan = try dupePlan(a, p) };
}

/// reads and parses a facts file into `a`.
pub fn readFacts(files: compose.Files, a: Allocator, path: []const u8) Error!facts.Facts {
    const bytes = files.readFn(files.ctx, a, path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.FactsUnreadable,
    };
    return facts.parse(a, bytes);
}

fn dupePlan(a: Allocator, p: planner.Plan) !planner.Plan {
    const changes = try a.dupe(planner.Change, p.changes);
    for (changes) |*c| {
        c.subject = try a.dupe(u8, c.subject);
        if (c.from) |v| c.from = try a.dupe(u8, v);
        if (c.to) |v| c.to = try a.dupe(u8, v);
        if (c.cause) |v| c.cause = try a.dupe(u8, v);
    }
    return .{ .changes = changes };
}
