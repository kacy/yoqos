//! reads the planner inputs from disk (or wherever `Files` points). `os
//! plan`, `os why`, and the golden tests all go through here, so the tests
//! cover the same path users run.

const std = @import("std");
const compose = @import("compose.zig");
const Config = @import("config.zig").Config;
const lock = @import("lock.zig");
const facts = @import("facts.zig");
const planner = @import("planner.zig");
const diag = @import("diag.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{ OutOfMemory, BadFacts, FactsUnreadable };

/// a loaded config and its lock. `arena` owns the lock and anything built
/// from both, like a plan.
pub const State = struct {
    loaded: compose.Loaded,
    arena: std.heap.ArenaAllocator,
    lock: lock.Lock,

    pub fn config(s: *const State) *const Config {
        return &s.loaded.config;
    }

    pub fn deinit(s: *State) void {
        s.arena.deinit();
        s.loaded.deinit();
    }
};

/// loads the config and the lock. `lock_path` defaults to machine.lock
/// next to the config. returns null with the reasons in `diags`.
pub fn load(gpa: Allocator, files: compose.Files, config_path: []const u8, lock_path: ?[]const u8, diags: *diag.List) error{OutOfMemory}!?State {
    var loaded = try compose.load(gpa, files, config_path, diags);
    errdefer loaded.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const path = lock_path orelse try std.fs.path.join(a, &.{ std.fs.path.dirnamePosix(config_path) orelse ".", "machine.lock" });
    const bytes = files.readFn(files.ctx, a, path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            try diags.add(.lock_stale, null, "{s} can't be read", .{path}, "run `os update` to resolve the config into a lock");
            break :blk null;
        },
    };
    const l = if (bytes) |b| try lock.parse(a, path, b, diags) else null;

    if (diags.items.items.len > 0 or l == null) {
        arena.deinit();
        loaded.deinit();
        return null;
    }
    return .{ .loaded = loaded, .arena = arena, .lock = l.? };
}

/// reads and parses a facts file into `a`.
pub fn readFacts(files: compose.Files, a: Allocator, path: []const u8) Error!facts.Facts {
    const bytes = files.readFn(files.ctx, a, path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.FactsUnreadable,
    };
    return facts.parse(a, bytes);
}

pub const Inputs = struct {
    config_path: []const u8,
    lock_path: ?[]const u8 = null,
    facts_path: []const u8,
};

pub const Result = struct {
    state: State,
    plan: planner.Plan,

    pub fn allocator(r: *Result) Allocator {
        return r.state.arena.allocator();
    }

    pub fn deinit(r: *Result) void {
        r.state.deinit();
    }
};

/// builds the plan, or returns null with the reasons in `diags`.
pub fn buildPlan(gpa: Allocator, files: compose.Files, in: Inputs, diags: *diag.List) Error!?Result {
    var state = try load(gpa, files, in.config_path, in.lock_path, diags) orelse return null;
    errdefer state.deinit();
    const a = state.arena.allocator();
    const f = try readFacts(files, a, in.facts_path);
    const p = try planner.plan(a, state.config(), &state.lock, &f, diags) orelse {
        state.deinit();
        return null;
    };
    return .{ .state = state, .plan = p };
}
