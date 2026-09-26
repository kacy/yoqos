//! reads the planner inputs from disk (or wherever `Files` points). the
//! commands that plan or inspect, and the golden tests, all go through
//! here, so the tests cover the same path users run.

const std = @import("std");
const compose = @import("compose.zig");
const Config = @import("config.zig").Config;
const lock = @import("lock.zig");
const facts = @import("facts.zig");
const planner = @import("planner.zig");
const diag = @import("diag.zig");
const observe = @import("observe.zig");
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

    const path = lock_path orelse try lock.pathFor(a, config_path);
    const bytes = files.read(a, path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            const why = if (e == error.FileNotFound) "doesn't exist yet" else "can't be read";
            try diags.add(.lock_stale, null, "{s} {s}", .{ path, why }, "run `os update` to resolve the config into a lock");
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
fn readFacts(files: compose.Files, a: Allocator, path: []const u8) Error!facts.Facts {
    const bytes = files.read(a, path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.FactsUnreadable,
    };
    return facts.parse(a, bytes);
}

/// facts from `path` if given, else observed from the machine under
/// `root`. observer problems go to `diags`.
/// `managed` names the files the config manages, which get hashed.
pub fn getFacts(files: compose.Files, io: std.Io, a: Allocator, path: ?[]const u8, root: []const u8, managed: []const []const u8, diags: *diag.List) Error!facts.Facts {
    if (path) |p| return readFacts(files, a, p);
    return observe.observe(a, io, .{ .root = root, .files = managed }, diags);
}

pub const Inputs = struct {
    config_path: []const u8,
    lock_path: ?[]const u8 = null,
    /// read facts from this file instead of observing the machine.
    facts_path: ?[]const u8 = null,
    /// the machine to observe when there's no facts file.
    root: []const u8 = "/",
};

pub const Result = struct {
    state: State,
    facts: facts.Facts,
    plan: planner.Plan,

    pub fn allocator(r: *Result) Allocator {
        return r.state.arena.allocator();
    }

    pub fn deinit(r: *Result) void {
        r.state.deinit();
    }
};

/// builds the plan, or returns null with the reasons in `diags`.
pub fn buildPlan(gpa: Allocator, io: std.Io, files: compose.Files, in: Inputs, diags: *diag.List) Error!?Result {
    var state = try load(gpa, files, in.config_path, in.lock_path, diags) orelse return null;
    errdefer state.deinit();
    const a = state.arena.allocator();
    const f = try getFacts(files, io, a, in.facts_path, in.root, try planner.filePaths(a, state.config()), diags);
    if (diags.items.items.len > 0) {
        state.deinit();
        return null;
    }
    const p = try planner.plan(a, state.config(), &state.lock, &f, diags) orelse {
        state.deinit();
        return null;
    };
    return .{ .state = state, .facts = f, .plan = p };
}
