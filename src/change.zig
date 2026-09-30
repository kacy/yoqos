//! `os add`, `os remove`, `os enable`, and `os disable` change the config
//! file for the user. each one edits the text of the top config file,
//! checks the result by loading the whole config with the new text, and
//! only then writes it.

const std = @import("std");
const lists = @import("lists.zig");
const compose = @import("compose.zig");
const config = @import("config.zig");
const planner = @import("planner.zig");
const diag = @import("diag.zig");
const edit = @import("edit.zig");
const Allocator = std.mem.Allocator;

pub const Op = enum { add, remove, enable, disable };

pub const Note = struct {
    name: []const u8,
    what: What,
    /// where the existing setting comes from, or what implies the package.
    detail: ?[]const u8 = null,
    /// the change is to the `aur` list, not `packages`.
    aur: bool = false,

    pub const What = enum {
        added,
        removed,
        /// set by an include, so it went into `[remove]` instead.
        excluded,
        enabled,
        disabled,
        /// a provider picked for a virtual package; `detail` is the pick.
        chosen,
        unchanged,
    };
};

pub const Outcome = struct {
    text: []const u8,
    notes: []const Note,

    pub fn changed(o: *const Outcome) bool {
        for (o.notes) |n| {
            if (n.what != .unchanged) return true;
        }
        return false;
    }
};

/// works out the new text for `op` on each name. problems, like removing a
/// package nothing asks for, go to `diags`.
/// with `aur`, add and remove edit the `aur` list instead of `packages`.
pub fn plan(a: Allocator, c: *const config.Config, top: []const u8, text: []const u8, op: Op, names: []const []const u8, aur: bool, diags: *diag.List) !Outcome {
    var out = text;
    var notes: std.ArrayList(Note) = .empty;
    for (names, 0..) |name, i| {
        // a name given twice is one change.
        if (lists.contains(names[0..i], name)) continue;
        if ((op == .add or op == .remove) and !config.validPackageName(name)) {
            try config.badPackageName(diags, name, null);
            continue;
        }
        const note: ?Note = switch (op) {
            .add => try add(a, c, &out, name, aur),
            .remove => try remove(a, c, top, &out, name, aur, diags),
            .enable, .disable => try service(a, c, &out, name, op == .enable, diags),
        };
        if (note) |n| try notes.append(a, n);
    }
    return .{ .text = out, .notes = notes.items };
}

fn at(a: Allocator, src: config.Src) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}:{d}", .{ src.file, src.line });
}

fn add(a: Allocator, c: *const config.Config, text: *[]const u8, name: []const u8, aur: bool) !Note {
    const set = listOf(c, aur);
    if (set.indexOf(name)) |i| return .{ .name = name, .what = .unchanged, .detail = try at(a, set.items.items[i].src), .aur = aur };
    text.* = (try edit.addToList(a, text.*, &.{}, listKey(aur), name)).?;
    return .{ .name = name, .what = .added, .aur = aur };
}

/// the list add and remove edit: `aur`, or `packages`.
fn listOf(c: *const config.Config, aur: bool) *const config.Set {
    return if (aur) &c.aur else &c.packages;
}

fn listKey(aur: bool) []const u8 {
    return if (aur) "aur" else "packages";
}

fn remove(a: Allocator, c: *const config.Config, top: []const u8, text: *[]const u8, name: []const u8, aur: bool, diags: *diag.List) !?Note {
    const set = listOf(c, aur);
    if (set.indexOf(name)) |i| {
        // a set keeps its first source, so an include shows up here even if
        // the top file lists the package too. take it out of both.
        const src = set.items.items[i].src;
        if (try edit.removeFromList(a, text.*, &.{}, listKey(aur), name)) |t| text.* = t;
        if (std.mem.eql(u8, src.file, top)) return .{ .name = name, .what = .removed, .aur = aur };
        text.* = (try edit.addToList(a, text.*, &.{"remove"}, listKey(aur), name)) orelse text.*;
        return .{ .name = name, .what = .excluded, .detail = try at(a, src), .aur = aur };
    }
    if (aur) {
        try diags.add(.bad_value, null, "nothing in the config asks for {s} from the aur", .{name}, null);
        return null;
    }
    const ws = try planner.wants(a, c);
    if (planner.findWant(ws, name)) |w| {
        const cause = w.cause.?;
        if (std.mem.startsWith(u8, cause, "services.")) {
            try diags.addHint(.bad_value, null, "{s} comes from {s}", .{ name, cause }, "run `os disable {s}`", .{cause["services.".len..]});
        } else {
            try diags.addHint(.bad_value, null, "{s} comes from {s}", .{ name, cause }, "change {s} in the config", .{cause});
        }
        return null;
    }
    try diags.add(.bad_value, null, "nothing in the config asks for {s}", .{name}, null);
    return null;
}

fn service(a: Allocator, c: *const config.Config, text: *[]const u8, name: []const u8, enabled: bool, diags: *diag.List) !?Note {
    if (!config.knownService(c, name)) {
        try config.unknownService(diags, name, null);
        return null;
    }
    const what: Note.What = if (enabled) .enabled else .disabled;
    if (c.services.get(name)) |s| {
        if (s.enabled) |en| {
            if (en.v == enabled) return .{ .name = name, .what = .unchanged, .detail = try at(a, en.src) };
        }
    }
    text.* = (try edit.setService(a, text.*, name, enabled)) orelse text.*;
    return .{ .name = name, .what = what };
}

/// loads the whole config as if `path` held `text`. returns false, with
/// the problems in `diags`, if the edit would leave the config broken or
/// didn't take effect.
pub fn check(gpa: Allocator, files: compose.Files, path: []const u8, text: []const u8, notes: []const Note, diags: *diag.List) !bool {
    var overlay: Overlay = .{ .base = files, .path = path, .text = text };
    var loaded = try compose.load(gpa, overlay.files(), path, diags);
    defer loaded.deinit();
    if (diags.items.items.len > 0) return false;
    const c = &loaded.config;
    for (notes) |n| {
        const ok = switch (n.what) {
            .added => listOf(c, n.aur).contains(n.name),
            .removed, .excluded => !listOf(c, n.aur).contains(n.name),
            .enabled, .disabled => if (c.services.get(n.name)) |s| s.enabled != null and s.enabled.?.v == (n.what == .enabled) else false,
            .chosen => if (c.providers.get(n.name)) |p| std.mem.eql(u8, p.v, n.detail.?) else false,
            .unchanged => true,
        };
        if (!ok) {
            try diags.add(.bad_value, null, "the edit to {s} didn't take effect for {s} ({s})", .{ path, n.name, @tagName(n.what) }, "this is a bug in os; the file was left alone");
            return false;
        }
    }
    return true;
}

/// reads `path` from `text`, and everything else from `base`.
const Overlay = struct {
    base: compose.Files,
    path: []const u8,
    text: []const u8,

    fn files(o: *Overlay) compose.Files {
        return .{ .ctx = o, .readFn = read, .writeFn = write };
    }

    fn read(ctx: *anyopaque, gpa: Allocator, path: []const u8) compose.Files.ReadError![]u8 {
        const o: *Overlay = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, path, o.path)) return gpa.dupe(u8, o.text);
        return o.base.read(gpa, path);
    }

    fn write(_: *anyopaque, _: []const u8, _: []const u8) compose.Files.WriteError!void {
        return error.WriteFailed;
    }
};
