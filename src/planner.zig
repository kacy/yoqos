//! the planner: `plan(config, lock, facts)` returns every change needed to
//! make the machine match its config. it's a pure function. it does no io
//! and reads no clock, so the same three inputs always give a byte-identical
//! plan.
//!
//! packages work like this: the config names what's wanted (directly, or
//! through services and hardware), the lock says which version of each
//! wanted package and its dependencies to use, and everything installed
//! that the lock doesn't need gets removed.

const std = @import("std");
const config = @import("config.zig");
const lock = @import("lock.zig");
const facts = @import("facts.zig");
const catalog = @import("catalog.zig");
const diag = @import("diag.zig");
const output = @import("output.zig");
const lists = @import("lists.zig");
const Allocator = std.mem.Allocator;

pub const schema = "yoq.plan/1";

pub const Op = enum { add, change, remove };

pub const Kind = enum {
    /// a package the config asks for.
    package,
    /// a package pulled in by another one.
    dependency,
    /// flipping pacman's install reason between explicit and dependency.
    reason,
    /// a `[system]` value.
    setting,
    /// a systemd unit being enabled or disabled.
    unit,
    /// a user being created or changed. `from` and `to` say how.
    user,
    /// a file os writes whole: its content, its mode, or both.
    file,
};

pub const Change = struct {
    op: Op,
    kind: Kind,
    subject: []const u8,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    /// the config key that asked for this, when it isn't the `packages` list.
    cause: ?[]const u8 = null,
    /// why this change needs a reboot, if it does.
    reboot: ?[]const u8 = null,
};

pub const Plan = struct {
    changes: []const Change,

    pub fn count(p: *const Plan, op: Op) usize {
        var n: usize = 0;
        for (p.changes) |c| n += @intFromBool(c.op == op);
        return n;
    }

    pub fn empty(p: *const Plan) bool {
        return p.changes.len == 0;
    }

    /// the distinct reasons a reboot is needed, in the order they appear.
    pub fn rebootReasons(p: *const Plan, a: Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        outer: for (p.changes) |c| {
            const r = c.reboot orelse continue;
            for (out.items) |seen| {
                if (std.mem.eql(u8, seen, r)) continue :outer;
            }
            try out.append(a, r);
        }
        return out.items;
    }

    /// sha-256 of the changes as compact json. approving a plan means
    /// approving this hash.
    pub fn hash(p: *const Plan) ![64]u8 {
        var buf: [256]u8 = undefined;
        var hw: std.Io.Writer.Hashing(std.crypto.hash.sha2.Sha256) = .init(&buf);
        try std.json.Stringify.value(p.changes, .{}, &hw.writer);
        try hw.writer.flush();
        return std.fmt.bytesToHex(hw.hasher.finalResult(), .lower);
    }
};

/// a package the config asks for. `cause` is the key that implies it, or
/// null for the `packages` list itself.
pub const Want = struct {
    name: []const u8,
    cause: ?[]const u8,
    src: ?config.Src,
};

/// every package the config asks for, directly or through services,
/// hardware, desktop, and boot choices, in that order.
pub fn wants(a: Allocator, c: *const config.Config) ![]const Want {
    var out: std.ArrayList(Want) = .empty;
    for (c.packages.items.items) |it| try addWant(a, &out, it.name, null, it.src);
    const kernel = if (c.boot.kernel) |k| k.v else catalog.default_kernel;
    if (!std.mem.eql(u8, kernel, catalog.no_kernel)) try addWant(a, &out, kernel, "boot.kernel", if (c.boot.kernel) |k| k.src else null);
    if (c.hardware.cpu) |v| for (catalog.cpuPackages(v.v)) |n| try addWant(a, &out, n, "hardware.cpu", v.src);
    if (c.hardware.gpu) |v| for (catalog.gpuPackages(v.v)) |n| try addWant(a, &out, n, "hardware.gpu", v.src);
    if (c.desktop.session) |v| for (catalog.sessionPackages(v.v)) |n| try addWant(a, &out, n, "desktop.session", v.src);
    if (c.desktop.audio) |v| for (catalog.audioPackages(v.v)) |n| try addWant(a, &out, n, "desktop.audio", v.src);
    for (c.services.entries.items) |e| {
        if (!e.value.isEnabled()) continue;
        try addWant(a, &out, e.value.packageFor(e.name), try std.fmt.allocPrint(a, "services.{s}", .{e.name}), e.value.src);
    }
    return out.items;
}

/// the wanted packages plus everything they depend on in the lock. wanted
/// packages the lock doesn't have yet are left out.
pub fn closure(a: Allocator, l: *const lock.Lock, ws: []const Want) !std.StringArrayHashMapUnmanaged(void) {
    var needed: std.StringArrayHashMapUnmanaged(void) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;
    for (ws) |w| {
        if (l.package(w.name) != null) try queue.append(a, w.name);
    }
    while (queue.pop()) |name| {
        if ((try needed.getOrPut(a, name)).found_existing) continue;
        for (l.package(name).?.depends) |d| try queue.append(a, d);
    }
    return needed;
}

/// builds the plan. returns null, with diagnostics, if the lock doesn't
/// cover what the config asks for. everything is allocated in `a`, which
/// should be an arena.
pub fn plan(a: Allocator, c: *const config.Config, l: *const lock.Lock, f: *const facts.Facts, diags: *diag.List) !?Plan {
    var changes: std.ArrayList(Change) = .empty;

    const ws = try wants(a, c);

    // every wanted package has to be in the lock.
    var stale = false;
    for (ws) |w| {
        if (l.package(w.name) != null) continue;
        stale = true;
        const at: ?diag.Span = w.src;
        try diags.add(.lock_stale, at, "{s} isn't in machine.lock yet", .{w.name}, "run `os update` to resolve it into the lock");
    }
    if (stale) return null;

    // the lock's closure of the wanted packages is what should be installed.
    const needed = try closure(a, l, ws);

    // packages: install, upgrade, or re-mark what's needed.
    const need_names = try a.dupe([]const u8, needed.keys());
    lists.sortStrings(need_names);
    for (need_names) |name| {
        const lp = l.package(name).?;
        const want = findWant(ws, name);
        const kind: Kind = if (want != null) .package else .dependency;
        const cause = if (want) |w| w.cause else null;
        const reboot = catalog.rebootReason(name);
        const have = f.package(name) orelse {
            try changes.append(a, .{ .op = .add, .kind = kind, .subject = name, .to = lp.version, .cause = cause, .reboot = reboot });
            continue;
        };
        if (!std.mem.eql(u8, have.version, lp.version)) {
            try changes.append(a, .{ .op = .change, .kind = kind, .subject = name, .from = have.version, .to = lp.version, .cause = cause, .reboot = reboot });
        }
        // packages that come from another key, like a service's, keep the
        // reason they were installed with.
        if (want != null and want.?.cause != null) continue;
        const want_reason: facts.Package.Reason = if (want != null) .explicit else .dependency;
        if (have.reason != want_reason) {
            try changes.append(a, .{ .op = .change, .kind = .reason, .subject = name, .from = @tagName(have.reason), .to = @tagName(want_reason) });
        }
    }

    // packages: remove what nothing needs, except core packages the config
    // doesn't remove on purpose. facts are sorted by name.
    var blocked: std.ArrayList([]const u8) = .empty;
    for (f.packages) |have| {
        if (needed.contains(have.name)) continue;
        if (lists.contains(&catalog.protected, have.name) and !c.removed.contains(have.name)) {
            try blocked.append(a, have.name);
            continue;
        }
        try changes.append(a, .{
            .op = .remove,
            .kind = if (have.reason == .explicit) .package else .dependency,
            .subject = have.name,
            .from = have.version,
            .reboot = catalog.rebootReason(have.name),
        });
    }
    if (blocked.items.len > 0) {
        const names = try std.mem.join(a, ", ", blocked.items);
        try diags.add(.protected_package, null, "applying would remove {s}, which the machine needs", .{names}, "add them to packages, or name them in [remove] to remove them anyway");
        return null;
    }

    // system settings. facts carry a field for every one of them.
    inline for (comptime config.keysOf(config.System)) |field| {
        if (@field(c.system, field)) |want| {
            const have = @field(f, field);
            if (have == null or !std.mem.eql(u8, have.?, want.v)) {
                try changes.append(a, .{
                    .op = .change,
                    .kind = .setting,
                    .subject = "system." ++ field,
                    .from = have,
                    .to = want.v,
                });
            }
        }
    }

    // services: enabled ones get their unit enabled and started. services
    // the config doesn't mention are left alone.
    var units: std.ArrayList(Change) = .empty;
    for (c.services.entries.items) |e| {
        const enabled = e.value.isEnabled();
        const unit = e.value.unitFor(e.name);
        const cause = try std.fmt.allocPrint(a, "services.{s}", .{e.name});
        const have = f.unit(unit);
        if (enabled) {
            const is_enabled = if (have) |u| u.enabled else false;
            const is_active = if (have) |u| u.active else false;
            if (!is_enabled) {
                try units.append(a, .{ .op = .add, .kind = .unit, .subject = unit, .to = if (is_active) "enable" else "enable, start", .cause = cause });
            } else if (!is_active) {
                try units.append(a, .{ .op = .change, .kind = .unit, .subject = unit, .to = "start", .cause = cause });
            }
        } else if (have) |u| {
            if (u.enabled or u.active) {
                try units.append(a, .{ .op = .remove, .kind = .unit, .subject = unit, .to = if (u.active) "disable, stop" else "disable", .cause = cause });
            }
        }
    }
    lists.sortByField(Change, "subject", units.items);
    try changes.appendSlice(a, units.items);
    try planUsers(a, c, f, &changes);
    try planFiles(a, c, f, &changes);

    return .{ .changes = changes.items };
}

/// users the config declares get created, or brought to its shell and
/// groups. the groups listed are all of them: others are left. users the
/// config doesn't mention are left alone, since removing an account by
/// accident costs too much.
/// a file os writes, from `[files]` or made from another key.
pub const DesiredFile = struct {
    path: []const u8,
    content: []const u8,
    mode: []const u8,
    /// the key that makes the file, for ones `[files]` doesn't name.
    cause: ?[]const u8 = null,
};

/// where `[sysctl]` goes.
pub const sysctl_path = "/etc/sysctl.d/99-yoq.conf";

/// every file the config wants: `[files]`, then the one `[sysctl]` makes.
pub fn desiredFiles(a: Allocator, c: *const config.Config) ![]const DesiredFile {
    var out: std.ArrayList(DesiredFile) = .empty;
    for (c.files.entries.items) |e| {
        // a source that couldn't be read was reported when loading.
        const content = e.value.content orelse continue;
        try out.append(a, .{ .path = e.name, .content = content, .mode = e.value.modeOf() });
    }
    if (c.sysctl.entries.items.len > 0) {
        const keys = try a.alloc([]const u8, c.sysctl.entries.items.len);
        for (c.sysctl.entries.items, keys) |e, *k| k.* = e.name;
        lists.sortStrings(keys);
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(a, "# written by os from [sysctl] in the config. edits here are overwritten.\n");
        for (keys) |k| try text.print(a, "{s} = {s}\n", .{ k, c.sysctl.get(k).?.v.text });
        try out.append(a, .{ .path = sysctl_path, .content = text.items, .mode = config.File.default_mode, .cause = "sysctl" });
    }
    return out.items;
}

/// the paths of every file the config wants, for the observer to hash.
pub fn filePaths(a: Allocator, c: *const config.Config) ![]const []const u8 {
    const want = try desiredFiles(a, c);
    const out = try a.alloc([]const u8, want.len);
    for (want, out) |d, *p| p.* = d.path;
    return out;
}

/// files: written when missing or when their content differs, and their
/// mode set when only that differs. files the config doesn't name are
/// left alone.
fn planFiles(a: Allocator, c: *const config.Config, f: *const facts.Facts, changes: *std.ArrayList(Change)) !void {
    const want = try desiredFiles(a, c);
    var files: std.ArrayList(Change) = .empty;
    for (want) |d| {
        const cause = d.cause orelse try std.fmt.allocPrint(a, "files.\"{s}\"", .{d.path});
        const have = f.file(d.path) orelse {
            try files.append(a, .{ .op = .add, .kind = .file, .subject = d.path, .to = try std.fmt.allocPrint(a, "write, mode {s}", .{d.mode}), .cause = cause });
            continue;
        };
        const hex = @import("observe.zig").sha256Hex(d.content);
        const mode = try normalMode(a, d.mode);
        if (!std.mem.eql(u8, have.sha256, &hex)) {
            try files.append(a, .{ .op = .change, .kind = .file, .subject = d.path, .to = try std.fmt.allocPrint(a, "rewrite, mode {s}", .{mode}), .cause = cause });
        } else if (!std.mem.eql(u8, have.mode, mode)) {
            try files.append(a, .{ .op = .change, .kind = .file, .subject = d.path, .from = have.mode, .to = try std.fmt.allocPrint(a, "mode {s}", .{mode}), .cause = cause });
        }
    }
    lists.sortByField(Change, "subject", files.items);
    try changes.appendSlice(a, files.items);
}

/// "644" and "0644" are the same mode; facts write four digits.
fn normalMode(a: Allocator, mode: []const u8) ![]const u8 {
    return if (mode.len == 3) std.fmt.allocPrint(a, "0{s}", .{mode}) else mode;
}

fn planUsers(a: Allocator, c: *const config.Config, f: *const facts.Facts, changes: *std.ArrayList(Change)) !void {
    for (c.users.entries.items) |e| {
        const name = e.name;
        const want_groups = e.value.groups.items.items;
        const cause = try std.fmt.allocPrint(a, "users.{s}", .{name});
        // each change is one step `apply` can take: a new user is created,
        // then gets its shell and groups like any other.
        const found = for (f.users) |*u| {
            if (std.mem.eql(u8, u.name, name)) break u;
        } else null;
        if (found == null) try changes.append(a, .{ .op = .add, .kind = .user, .subject = name, .to = "new user", .cause = cause });
        if (e.value.shell) |sh| {
            const current = if (found) |u| u.shell orelse "" else "";
            const same = std.mem.eql(u8, current, sh.v) or
                (std.mem.indexOfScalar(u8, sh.v, '/') == null and std.mem.eql(u8, std.fs.path.basename(current), sh.v));
            if (!same) try changes.append(a, .{
                .op = .change,
                .kind = .user,
                .subject = name,
                .from = if (found != null) try std.fmt.allocPrint(a, "shell {s}", .{std.fs.path.basename(current)}) else null,
                .to = try std.fmt.allocPrint(a, "shell {s}", .{sh.v}),
                .cause = cause,
            });
        }
        const have_groups: []const []const u8 = if (found) |u| u.groups else &.{};
        for (want_groups) |g| {
            if (!lists.contains(have_groups, g.name)) try changes.append(a, .{ .op = .add, .kind = .user, .subject = name, .to = try std.fmt.allocPrint(a, "join {s}", .{g.name}), .cause = cause });
        }
        if (e.value.groups.items.items.len == 0) continue;
        for (have_groups) |g| {
            if (!e.value.groups.contains(g)) try changes.append(a, .{ .op = .remove, .kind = .user, .subject = name, .from = try std.fmt.allocPrint(a, "leave {s}", .{g}), .cause = cause });
        }
    }
}

fn addWant(a: Allocator, list: *std.ArrayList(Want), name: []const u8, cause: ?[]const u8, src: ?config.Src) !void {
    if (findWant(list.items, name) != null) return;
    try list.append(a, .{ .name = name, .cause = cause, .src = src });
}

/// explicitly installed packages that nothing in the config asks for or
/// needs, in facts order.
pub fn extraPackages(a: Allocator, c: *const config.Config, l: *const lock.Lock, f: *const facts.Facts) ![]const []const u8 {
    const ws = try wants(a, c);
    const needed = try closure(a, l, ws);
    var out: std.ArrayList([]const u8) = .empty;
    for (f.packages) |p| {
        if (p.reason != .explicit or needed.contains(p.name) or findWant(ws, p.name) != null) continue;
        try out.append(a, p.name);
    }
    return out.items;
}

pub fn findWant(list: []const Want, name: []const u8) ?*const Want {
    for (list) |*w| {
        if (std.mem.eql(u8, w.name, name)) return w;
    }
    return null;
}

// -- output --

pub const RenderOptions = struct {
    /// list each dependency instead of counting them.
    verbose: bool = false,
    /// packages as counts and the notable few, for big updates.
    summary: bool = false,
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
        for (p.changes) |c| {
            if (c.kind == .package) try line(w, c);
        }
        if (opts.verbose) {
            for (p.changes) |c| {
                if (c.kind == .dependency or c.kind == .reason) try line(w, c);
            }
        } else {
            try depSummary(w, p);
        }
    }
    inline for (.{ .{ "system", Kind.setting }, .{ "users", Kind.user }, .{ "services", Kind.unit }, .{ "files", Kind.file } }) |section| {
        if (has(p, section[1])) {
            try w.writeAll(section[0] ++ "\n");
            for (p.changes) |c| {
                if (c.kind == section[1]) try line(w, c);
            }
        }
    }

    try w.print("\nplan: {d} to add, {d} to change, {d} to remove", .{ p.count(.add), p.count(.change), p.count(.remove) });
    const reasons = try p.rebootReasons(a);
    if (reasons.len == 0) {
        try w.writeAll(" · no reboot\n");
    } else {
        try w.writeAll(" · reboot needed: ");
        for (reasons, 0..) |r, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(r);
        }
        try w.writeByte('\n');
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
        .unit, .file => try w.print("{s}: {s}", .{ c.subject, c.to.? }),
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
    var n = [_]usize{ 0, 0, 0 };
    for (p.changes) |c| {
        if (c.kind == .package or c.kind == .dependency) n[@intFromEnum(c.op)] += 1;
    }
    if (n[0] + n[1] + n[2] == 0) return;
    try w.print("packages\n  upgrades {d}    new {d}    removed {d}   (-v lists them)\n", .{ n[1], n[0], n[2] });
    var first = true;
    for (p.changes) |c| {
        if ((c.kind != .package and c.kind != .dependency) or c.op != .change or !notable(c)) continue;
        try w.print("  {s:<9}{s} {s} -> {s}\n", .{ if (first) "notable" else "", c.subject, c.from.?, c.to.? });
        first = false;
    }
}

/// an upgrade worth a look: one that needs a reboot, one the catalog
/// flags, like graphics and boot, or a new major version.
fn notable(c: Change) bool {
    if (catalog.rebootReason(c.subject) != null or catalog.notable(c.subject)) return true;
    return !std.mem.eql(u8, majorOf(c.from.?), majorOf(c.to.?));
}

/// "1:2.3.4-1" and "2.3.4-1" are both major version "2".
fn majorOf(version: []const u8) []const u8 {
    const v = if (std.mem.indexOfScalar(u8, version, ':')) |i| version[i + 1 ..] else version;
    return v[0 .. std.mem.indexOfAny(u8, v, ".-+_") orelse v.len];
}

fn depSummary(w: *std.Io.Writer, p: *const Plan) !void {
    var n = [_]usize{ 0, 0, 0 };
    for (p.changes) |c| {
        if (c.kind == .dependency or c.kind == .reason) n[@intFromEnum(c.op)] += 1;
    }
    if (n[0] + n[1] + n[2] == 0) return;
    try w.writeAll("  ");
    var first = true;
    for (n, 0..) |count, i| {
        if (count == 0) continue;
        if (!first) try w.writeAll(", ");
        first = false;
        try w.print("{c}{d}", .{ mark(@enumFromInt(i)), count });
    }
    try w.writeAll(" dependencies (-v to list)\n");
}

pub fn writeJson(w: *std.Io.Writer, a: Allocator, p: *const Plan) !void {
    const h = try p.hash();
    try output.writeDoc(w, schema, .{
        .hash = &h,
        .summary = .{ .add = p.count(.add), .change = p.count(.change), .remove = p.count(.remove) },
        .reboot = .{ .needed = (try p.rebootReasons(a)).len > 0, .because = try p.rebootReasons(a) },
        .changes = p.changes,
    });
}

// -- tests --

const testing = std.testing;

const T = struct {
    arena: std.heap.ArenaAllocator = .init(testing.allocator),
    diags: diag.List = .init(testing.allocator),

    fn deinit(t: *T) void {
        t.diags.deinit();
        t.arena.deinit();
    }

    fn a(t: *T) Allocator {
        return t.arena.allocator();
    }

    fn cfg(t: *T, src: []const u8) !config.Config {
        return helpers.configFrom(t.a(), src);
    }
};

const helpers = @import("test_helpers.zig");
const lockPkg = helpers.lockPackage;

test "converged machine gives an empty plan" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("packages = [\"git\"]\n[system]\nhostname = \"atlas\"\n");
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{
        lockPkg("git", "2.51.0-1", &.{"glibc"}),
        lockPkg("glibc", "2.42-1", &.{}),
        lockPkg("linux", "6.16.8-1", &.{}),
    } };
    var have = [_]facts.Package{
        .{ .name = "git", .version = "2.51.0-1" },
        .{ .name = "glibc", .version = "2.42-1", .reason = .dependency },
        .{ .name = "linux", .version = "6.16.8-1" },
    };
    const f: facts.Facts = .{ .hostname = "atlas", .packages = &have };
    const p = (try plan(t.a(), &c, &l, &f, &t.diags)).?;
    try testing.expect(p.empty());

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeText(&out.writer, t.a(), &p, .{});
    try testing.expectEqualStrings("nothing to do. this machine matches its config.\n", out.written());
}

test "installs, upgrades, removes, and orphaned dependencies" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("packages = [\"git\", \"neovim\"]\n[services]\nssh = true\n");
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{
        lockPkg("git", "2.51.0-1", &.{"glibc"}),
        lockPkg("glibc", "2.42-1", &.{}),
        lockPkg("linux", "6.16.8-1", &.{}),
        lockPkg("luajit", "2.1-1", &.{"glibc"}),
        lockPkg("neovim", "0.11.4-1", &.{"luajit"}),
        lockPkg("openssh", "10.0p1-1", &.{"glibc"}),
    } };
    var have = [_]facts.Package{
        .{ .name = "git", .version = "2.50.1-1" },
        .{ .name = "glibc", .version = "2.42-1", .reason = .dependency },
        .{ .name = "linux", .version = "6.16.7-1" },
        .{ .name = "nano", .version = "8.6-1" },
        .{ .name = "ncurses", .version = "6.5-4", .reason = .dependency },
    };
    const f: facts.Facts = .{ .packages = &have };
    const p = (try plan(t.a(), &c, &l, &f, &t.diags)).?;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeText(&out.writer, t.a(), &p, .{});
    try testing.expectEqualStrings(
        \\packages
        \\  ~ git 2.50.1-1 -> 2.51.0-1
        \\  ~ linux 6.16.7-1 -> 6.16.8-1  (boot.kernel)
        \\  + neovim 0.11.4-1
        \\  + openssh 10.0p1-1  (services.ssh)
        \\  - nano 8.6-1
        \\  +1, -1 dependencies (-v to list)
        \\services
        \\  + sshd.service: enable, start  (services.ssh)
        \\
        \\plan: 4 to add, 2 to change, 2 to remove · reboot needed: kernel
        \\
    , out.written());

    var verbose: std.Io.Writer.Allocating = .init(testing.allocator);
    defer verbose.deinit();
    try writeText(&verbose.writer, t.a(), &p, .{ .verbose = true });
    try testing.expect(std.mem.indexOf(u8, verbose.written(), "  + luajit 2.1-1 (dependency)\n") != null);
    try testing.expect(std.mem.indexOf(u8, verbose.written(), "  - ncurses 6.5-4 (dependency)\n") != null);
}

test "settings and units" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg(
        \\[system]
        \\hostname = "atlas"
        \\timezone = "UTC"
        \\[services]
        \\bluetooth = false
        \\ssh = true
        \\
    );
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{
        lockPkg("linux", "1", &.{}), lockPkg("openssh", "1", &.{}),
    } };
    var have = [_]facts.Package{ .{ .name = "linux", .version = "1" }, .{ .name = "openssh", .version = "1" } };
    var units = [_]facts.Unit{
        .{ .name = "bluetooth.service", .enabled = true, .active = true },
        .{ .name = "sshd.service", .enabled = true, .active = false },
    };
    const f: facts.Facts = .{ .hostname = "archlinux", .packages = &have, .units = &units };
    const p = (try plan(t.a(), &c, &l, &f, &t.diags)).?;
    try testing.expectEqual(4, p.changes.len);
    try testing.expectEqualStrings("system.hostname", p.changes[0].subject);
    try testing.expectEqualStrings("archlinux", p.changes[0].from.?);
    try testing.expectEqual(null, p.changes[1].from);
    try testing.expectEqual(Op.remove, p.changes[2].op);
    try testing.expectEqualStrings("disable, stop", p.changes[2].to.?);
    try testing.expectEqualStrings("start", p.changes[3].to.?);
}

test "a package missing from the lock stops the plan" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("packages = [\"git\", \"ripgrep\"]\n");
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{ lockPkg("git", "1", &.{}), lockPkg("linux", "1", &.{}) } };
    const f: facts.Facts = .{};
    try testing.expectEqual(null, try plan(t.a(), &c, &l, &f, &t.diags));
    try testing.expectEqual(1, t.diags.items.items.len);
    try testing.expectEqual(diag.Code.lock_stale, t.diags.items.items[0].code);
    try testing.expectEqualStrings("ripgrep isn't in machine.lock yet", t.diags.items.items[0].message);
    try testing.expectEqual(1, t.diags.items.items[0].span.?.line);
}

test "reason changes and explicit dependencies" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("packages = [\"glibc\"]\n");
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{ lockPkg("glibc", "1", &.{}), lockPkg("linux", "1", &.{"glibc"}) } };
    var have = [_]facts.Package{ .{ .name = "glibc", .version = "1", .reason = .dependency }, .{ .name = "linux", .version = "1" } };
    const f: facts.Facts = .{ .packages = &have };
    const p = (try plan(t.a(), &c, &l, &f, &t.diags)).?;
    try testing.expectEqual(1, p.changes.len);
    try testing.expectEqual(Kind.reason, p.changes[0].kind);
    try testing.expectEqualStrings("explicit", p.changes[0].to.?);
}

test "the same inputs give the same plan and hash" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("packages = [\"b\", \"a\"]\n[services]\ntailscale = true\nssh = true\n");
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{
        lockPkg("a", "1", &.{"c"}),    lockPkg("b", "1", &.{"c"}),      lockPkg("c", "1", &.{}), lockPkg("linux", "1", &.{}),
        lockPkg("openssh", "1", &.{}), lockPkg("tailscale", "1", &.{}),
    } };
    var have = [_]facts.Package{ .{ .name = "z", .version = "1" }, .{ .name = "y", .version = "1" } };
    var f: facts.Facts = .{ .packages = &have };
    f.normalize();

    var first: ?[64]u8 = null;
    for (0..5) |_| {
        const p = (try plan(t.a(), &c, &l, &f, &t.diags)).?;
        const hash = try p.hash();
        if (first) |x| try testing.expectEqualStrings(&x, &hash) else first = hash;
    }

    const p = (try plan(t.a(), &c, &l, &f, &t.diags)).?;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeJson(&out.writer, t.a(), &p);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(&first.?, parsed.value.object.get("hash").?.string);
    try testing.expectEqual(2, parsed.value.object.get("summary").?.object.get("remove").?.integer);
}

test "files: written when missing, rewritten when different, and the sysctl file" {
    var t: T = .{};
    defer t.deinit();
    var c = try t.cfg(
        \\[boot]
        \\kernel = "none"
        \\[files."/etc/motd"]
        \\text = "hi\n"
        \\[files."/etc/issue"]
        \\text = "atlas\n"
        \\mode = "0600"
        \\[files."/etc/hosts.allow"]
        \\text = "same\n"
        \\mode = "600"
        \\[sysctl]
        \\"vm.swappiness" = 10
        \\"kernel.printk" = "3 3 3 3"
        \\
    );
    // decoding alone doesn't fill in content; loading does.
    for (c.files.entries.items) |*e| e.value.content = e.value.text.?.v;
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{} };
    var have = [_]facts.File{
        .{ .path = "/etc/issue", .sha256 = &@import("observe.zig").sha256Hex("old\n"), .mode = "0600" },
        .{ .path = "/etc/hosts.allow", .sha256 = &@import("observe.zig").sha256Hex("same\n"), .mode = "0644" },
    };
    const f: facts.Facts = .{ .files = &have };
    const p = (try plan(t.a(), &c, &l, &f, &t.diags)).?;
    try testing.expectEqual(4, p.changes.len);
    try testing.expectEqualStrings("/etc/hosts.allow", p.changes[0].subject);
    try testing.expectEqualStrings("mode 0600", p.changes[0].to.?);
    try testing.expectEqualStrings("/etc/issue", p.changes[1].subject);
    try testing.expectEqualStrings("rewrite, mode 0600", p.changes[1].to.?);
    try testing.expectEqual(Op.add, p.changes[2].op);
    try testing.expectEqualStrings(sysctl_path, p.changes[3].subject);
    try testing.expectEqualStrings("sysctl", p.changes[3].cause.?);

    const sysctl = (try desiredFiles(t.a(), &c))[3];
    try testing.expectEqualStrings(
        \\# written by os from [sysctl] in the config. edits here are overwritten.
        \\kernel.printk = 3 3 3 3
        \\vm.swappiness = 10
        \\
    , sysctl.content);
}

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

test "a package from a service keeps its install reason" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("[boot]\nkernel = \"none\"\n[services]\nresolved = true\n");
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{
        lockPkg("systemd", "258-1", &.{}),
    } };
    var have = [_]facts.Package{.{ .name = "systemd", .version = "258-1", .reason = .dependency }};
    var units = [_]facts.Unit{.{ .name = "systemd-resolved.service", .enabled = true, .active = true }};
    const f: facts.Facts = .{ .packages = &have, .units = &units };
    try testing.expect((try plan(t.a(), &c, &l, &f, &t.diags)).?.empty());
}

test "core packages are removed only when [remove] names them" {
    var t: T = .{};
    defer t.deinit();
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{
        lockPkg("tree", "2.3.2-1", &.{}),
    } };
    var have = [_]facts.Package{
        .{ .name = "base", .version = "3-3" },
        .{ .name = "tree", .version = "2.3.2-1" },
    };
    const f: facts.Facts = .{ .packages = &have };

    const c = try t.cfg("packages = [\"tree\"]\n[boot]\nkernel = \"none\"\n");
    try testing.expectEqual(null, try plan(t.a(), &c, &l, &f, &t.diags));
    try testing.expectEqual(diag.Code.protected_package, t.diags.items.items[0].code);
    try testing.expectEqualStrings("applying would remove base, which the machine needs", t.diags.items.items[0].message);

    const ok = try t.cfg("packages = [\"tree\"]\n[boot]\nkernel = \"none\"\n[remove]\npackages = [\"base\"]\n");
    const p = (try plan(t.a(), &ok, &l, &f, &t.diags)).?;
    try testing.expectEqual(1, p.changes.len);
    try testing.expectEqualStrings("base", p.changes[0].subject);
}

test "a machine without a kernel" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("packages = [\"git\"]\n[boot]\nkernel = \"none\"\n");
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{lockPkg("git", "1", &.{})} };
    var have = [_]facts.Package{.{ .name = "git", .version = "1" }};
    const f: facts.Facts = .{ .packages = &have };
    try testing.expect((try plan(t.a(), &c, &l, &f, &t.diags)).?.empty());
}
