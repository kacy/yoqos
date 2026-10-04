//! the planner: `plan(config, lock, facts)` returns every change needed to
//! make the machine match its config. it's a pure function. it does no io
//! and reads no clock, so the same three inputs always give a byte-identical
//! plan.
//!
//! packages work like this: the config names what's wanted (directly, or
//! through services and hardware), the lock says which version of each
//! wanted package and its dependencies to use, and everything installed
//! that the lock doesn't need gets removed.
//!
//! desired.zig works out the files yos writes, checks.zig checks a plan
//! against the machine before anything is built, and planview.zig shows
//! it. all three are pure too.

const std = @import("std");
const config = @import("config.zig");
const lock = @import("lock.zig");
const facts = @import("facts.zig");
const catalog = @import("catalog.zig");
const diag = @import("diag.zig");
const lists = @import("lists.zig");
const uki = @import("uki.zig");
const secureboot = @import("secureboot.zig");
const desired = @import("desired.zig");
const Allocator = std.mem.Allocator;

pub const schema = "yos.plan/1";

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
    /// a repository's signing key, imported into pacman's keyring and
    /// trusted. the subject is its fingerprint.
    key,
    /// pacman.conf, reading the file yos writes the repositories to.
    pacman_conf,
    /// a file yos writes whole: its content, its mode, or both.
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

pub const Summary = struct {
    add: usize,
    change: usize,
    remove: usize,

    pub fn total(n: Summary) usize {
        return n.add + n.change + n.remove;
    }

    pub fn of(n: Summary, op: Op) usize {
        return switch (op) {
            .add => n.add,
            .change => n.change,
            .remove => n.remove,
        };
    }
};

pub const Plan = struct {
    changes: []const Change,
    /// each file the plan writes, by path and the sha-256 of its content,
    /// or a secret's keyed hash. changes don't show content, so this goes
    /// into the hash instead: a saved plan can't write something other
    /// than what was reviewed.
    content: []const u8 = "",

    /// how many changes of each op the whole plan has.
    pub fn summary(p: *const Plan) Summary {
        return p.tally(std.enums.values(Kind));
    }

    /// like `summary`, counting only changes of `kinds`.
    pub fn tally(p: *const Plan, kinds: []const Kind) Summary {
        var n: Summary = .{ .add = 0, .change = 0, .remove = 0 };
        for (p.changes) |c| {
            if (std.mem.indexOfScalar(Kind, kinds, c.kind) == null) continue;
            switch (c.op) {
                .add => n.add += 1,
                .change => n.change += 1,
                .remove => n.remove += 1,
            }
        }
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

    /// the hash `content` gives the file at `path`, or null when the plan
    /// doesn't write it or couldn't take one.
    pub fn plannedHash(p: *const Plan, path: []const u8) ?[]const u8 {
        var rows = std.mem.splitScalar(u8, p.content, '\n');
        while (rows.next()) |row| {
            const space = std.mem.lastIndexOfScalar(u8, row, ' ') orelse continue;
            if (!std.mem.eql(u8, row[0..space], path)) continue;
            const got = row[space + 1 ..];
            return if (std.mem.eql(u8, got, unknown_hash)) null else got;
        }
        return null;
    }

    /// sha-256 of the changes as compact json. approving a plan means
    /// approving this hash.
    pub fn hash(p: *const Plan) ![64]u8 {
        var buf: [256]u8 = undefined;
        var hw: std.Io.Writer.Hashing(std.crypto.hash.sha2.Sha256) = .init(&buf);
        try std.json.Stringify.value(p.changes, .{}, &hw.writer);
        try hw.writer.writeAll(p.content);
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
    for (c.aur.items.items) |it| try addWant(a, &out, it.name, "aur", it.src);
    // building aur packages needs devtools' makechrootpkg.
    if (c.aur.items.items.len > 0) try addWant(a, &out, "devtools", "aur", c.aur.items.items[0].src);
    if (c.boot.kernel) |k| {
        if (!std.mem.eql(u8, k.v, catalog.no_kernel)) try addWant(a, &out, k.v, "boot.kernel", k.src);
    } else try addWant(a, &out, catalog.default_kernel, "boot.kernel", null);
    if (c.boot.uki) |v| {
        if (v.v) try addWant(a, &out, uki.package, "boot.uki", v.src);
    }
    if (c.boot.secure_boot) |v| {
        if (v.v) try addWant(a, &out, secureboot.package, "boot.secure_boot", v.src);
    }
    if (c.hardware.cpu) |v| try addWants(a, &out, catalog.cpuPackages(v.v), "hardware.cpu", v.src);
    if (c.hardware.gpu) |v| try addWants(a, &out, catalog.gpuPackages(v.v), "hardware.gpu", v.src);
    if (c.desktop.session) |v| try addWants(a, &out, catalog.sessionPackages(v.v), "desktop.session", v.src);
    if (c.desktop.audio) |v| try addWants(a, &out, catalog.audioPackages(v.v), "desktop.audio", v.src);
    if (c.desktop.login) |v| {
        // a tty login without a session is a plain console: nothing to start.
        if (v.v != .tty or c.desktop.session != null) try addWants(a, &out, catalog.loginPackages(v.v), "desktop.login", v.src);
    }
    for (c.services.entries.items) |e| {
        if (!e.value.isEnabled()) continue;
        try addWant(a, &out, e.value.packageFor(e.name), try std.fmt.allocPrint(a, "services.{s}", .{e.name}), e.value.src);
    }
    return out.items;
}

/// adds a want unless one by that name is there already, which keeps the
/// first cause.
fn addWant(a: Allocator, list: *std.ArrayList(Want), name: []const u8, cause: ?[]const u8, src: ?config.Src) !void {
    if (findWant(list.items, name) != null) return;
    try list.append(a, .{ .name = name, .cause = cause, .src = src });
}

fn addWants(a: Allocator, list: *std.ArrayList(Want), names: []const []const u8, cause: []const u8, src: config.Src) !void {
    for (names) |n| try addWant(a, list, n, cause, src);
}

pub fn findWant(list: []const Want, name: []const u8) ?*const Want {
    return lists.find(list, "name", name);
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

/// builds the plan. returns null, with diagnostics, if the lock doesn't
/// cover what the config asks for. everything is allocated in `a`, which
/// should be an arena.
pub fn plan(a: Allocator, c: *const config.Config, l: *const lock.Lock, f: *const facts.Facts, diags: *diag.List) !?Plan {
    var changes: std.ArrayList(Change) = .empty;
    if (!try planPackages(a, c, l, f, &changes, diags)) return null;
    try planSettings(a, c, f, &changes);
    try planUnits(a, c, f, &changes);
    try planUsers(a, c, f, &changes);
    var content: std.ArrayList(u8) = .empty;
    try planFiles(a, c, f, &changes, &content);
    if (!try planRepos(a, c, f, &changes, diags)) return null;
    return .{ .changes = changes.items, .content = content.items };
}

/// packages: the lock's closure of the wanted packages is what should be
/// installed, and everything else goes. returns false, with diagnostics,
/// if the lock is missing a wanted package or applying would remove a
/// core one.
fn planPackages(a: Allocator, c: *const config.Config, l: *const lock.Lock, f: *const facts.Facts, changes: *std.ArrayList(Change), diags: *diag.List) !bool {
    const ws = try wants(a, c);
    var stale = false;
    for (ws) |w| {
        if (l.package(w.name) != null) continue;
        stale = true;
        try diags.add(.lock_stale, w.src, "{s} isn't in machine.lock yet", .{w.name}, "run `yos update` to resolve it into the lock");
    }
    if (stale) return false;

    const needed = try closure(a, l, ws);
    try planInstalls(a, l, f, ws, needed.keys(), changes);
    return planRemovals(a, c, f, needed, changes, diags);
}

/// installs, upgrades, or re-marks each needed package, by name.
fn planInstalls(a: Allocator, l: *const lock.Lock, f: *const facts.Facts, ws: []const Want, needed: []const []const u8, changes: *std.ArrayList(Change)) !void {
    const names = try a.dupe([]const u8, needed);
    lists.sortStrings(names);
    for (names) |name| {
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
        if (cause != null) continue;
        const want_reason: facts.Package.Reason = if (want != null) .explicit else .dependency;
        if (have.reason != want_reason) {
            try changes.append(a, .{ .op = .change, .kind = .reason, .subject = name, .from = @tagName(have.reason), .to = @tagName(want_reason) });
        }
    }
}

/// removes what nothing needs, in facts order (by name), except core
/// packages the config doesn't remove on purpose. returns false, with a
/// diagnostic, if it would remove one of those.
fn planRemovals(a: Allocator, c: *const config.Config, f: *const facts.Facts, needed: std.StringArrayHashMapUnmanaged(void), changes: *std.ArrayList(Change), diags: *diag.List) !bool {
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
    if (blocked.items.len == 0) return true;
    const names = try std.mem.join(a, ", ", blocked.items);
    try diags.add(.protected_package, null, "applying would remove {s}, which the machine needs", .{names}, "add them to packages, or name them in [remove] to remove them anyway");
    return false;
}

/// `[system]` values. facts carry a field for every one of them.
fn planSettings(a: Allocator, c: *const config.Config, f: *const facts.Facts, changes: *std.ArrayList(Change)) !void {
    inline for (comptime config.keysOf(config.System)) |field| {
        if (@field(c.system, field)) |want| {
            const have = @field(f, field);
            if (have == null or !std.mem.eql(u8, have.?, want.v)) {
                try changes.append(a, .{ .op = .change, .kind = .setting, .subject = "system." ++ field, .from = have, .to = want.v });
            }
        }
    }
}

/// services: enabled ones get their unit enabled and started, disabled
/// ones stopped. services the config doesn't mention are left alone.
fn planUnits(a: Allocator, c: *const config.Config, f: *const facts.Facts, changes: *std.ArrayList(Change)) !void {
    var units: std.ArrayList(Change) = .empty;
    for (c.services.entries.items) |e| {
        const unit = e.value.unitFor(e.name);
        const step = unitStep(e.value.isEnabled(), f.unit(unit)) orelse continue;
        try units.append(a, .{ .op = step.op, .kind = .unit, .subject = unit, .to = step.to, .cause = try std.fmt.allocPrint(a, "services.{s}", .{e.name}) });
    }
    // a login choice owns the display manager: its own is enabled, the
    // others disabled. neither starts nor stops now, since that would end
    // the session applying it; the next boot does.
    if (c.desktop.login) |login| {
        const own = catalog.loginUnit(login.v);
        for (catalog.display_managers) |dm| {
            const want = own != null and std.mem.eql(u8, own.?, dm);
            const on = if (f.unit(dm)) |u| u.enabled else false;
            if (want == on) continue;
            try units.append(a, .{ .op = if (want) .add else .remove, .kind = .unit, .subject = dm, .to = if (want) "enable" else "disable", .cause = "desktop.login", .reboot = "display manager" });
        }
    }
    lists.sortByField(Change, "subject", units.items);
    try changes.appendSlice(a, units.items);
}

const UnitStep = struct { op: Op, to: []const u8 };

/// what it takes to get a unit enabled and running (`on`) or off, or
/// null if it's there already.
fn unitStep(on: bool, have: ?*const facts.Unit) ?UnitStep {
    const u = have orelse return if (on) .{ .op = .add, .to = "enable, start" } else null;
    if (on) {
        // a oneshot that ran and finished well counts as running.
        const running = u.active or u.ran;
        if (!u.enabled and !u.fixed) return .{ .op = .add, .to = if (running) "enable" else "enable, start" };
        if (!running) return .{ .op = .change, .to = "start" };
        return null;
    }
    // a unit that can't be enabled only stops.
    if (u.fixed) return if (u.active) .{ .op = .remove, .to = "stop" } else null;
    if (u.enabled or u.active) return .{ .op = .remove, .to = if (u.active) "disable, stop" else "disable" };
    return null;
}

/// users the config declares get created, or brought to its shell and
/// groups. the groups listed are all of them: others are left. users the
/// config doesn't mention are left alone, since removing an account by
/// accident costs too much.
fn planUsers(a: Allocator, c: *const config.Config, f: *const facts.Facts, changes: *std.ArrayList(Change)) !void {
    for (c.users.entries.items) |e| {
        const name = e.name;
        const want_groups = e.value.groups.items.items;
        const cause = try std.fmt.allocPrint(a, "users.{s}", .{name});
        // each change is one step `apply` can take: a new user is created,
        // then gets its shell and groups like any other.
        const found = lists.find(f.users, "name", name);
        if (found == null) try changes.append(a, .{ .op = .add, .kind = .user, .subject = name, .to = "new user", .cause = cause });
        if (e.value.shell) |sh| {
            const current = if (found) |u| u.shell orelse "" else "";
            if (!sameShell(current, sh.v)) try changes.append(a, .{
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
        if (want_groups.len == 0) continue;
        for (have_groups) |g| {
            if (!e.value.groups.contains(g)) try changes.append(a, .{ .op = .remove, .kind = .user, .subject = name, .from = try std.fmt.allocPrint(a, "leave {s}", .{g}), .cause = cause });
        }
    }
}

/// a shell given by name, like "zsh", matches any path ending in it.
fn sameShell(current: []const u8, want: []const u8) bool {
    if (std.mem.eql(u8, current, want)) return true;
    return std.mem.indexOfScalar(u8, want, '/') == null and std.mem.eql(u8, std.fs.path.basename(current), want);
}

/// files: written when missing or when their content differs, and their
/// mode set when only that differs. generated files nothing asks for any
/// more are removed; other files the config doesn't name are left alone.
fn planFiles(a: Allocator, c: *const config.Config, f: *const facts.Facts, changes: *std.ArrayList(Change), content: *std.ArrayList(u8)) !void {
    const want = try desired.files(a, c, f);
    var files: std.ArrayList(Change) = .empty;
    for (want) |d| {
        const mode = try normalMode(a, d.mode);
        const exposed = exposure(d, mode);
        var ch: Change = .{
            .op = .change,
            .kind = .file,
            .subject = d.path,
            .cause = d.cause orelse try std.fmt.allocPrint(a, "files.\"{s}\"", .{d.path}),
            .reboot = d.reboot orelse desired.fileReboot(d.path),
        };
        const hash = try contentHash(a, d, f);
        if (f.file(d.path)) |have| {
            // a hash that couldn't be taken, like a secret's without root,
            // isn't a difference.
            if (hash != null and have.sha256.len > 0 and !std.mem.eql(u8, have.sha256, hash.?)) {
                ch.to = try std.fmt.allocPrint(a, "rewrite, mode {s}{s}", .{ mode, exposed });
            } else if (!std.mem.eql(u8, have.mode, mode)) {
                // only the mode: nothing the reboot was for changes.
                ch.from = have.mode;
                ch.to = try std.fmt.allocPrint(a, "mode {s}{s}", .{ mode, exposed });
                ch.reboot = null;
            } else continue;
        } else {
            ch.op = .add;
            ch.to = try std.fmt.allocPrint(a, "write, mode {s}{s}", .{ mode, exposed });
        }
        try files.append(a, ch);
    }
    for (files.items) |ch| {
        const d = lists.find(want, "path", ch.subject).?;
        try content.print(a, "{s} {s}\n", .{ d.path, try contentHash(a, d.*, f) orelse unknown_hash });
    }
    for (desired.generated_paths ++ desired.legacy_paths) |p| {
        if (lists.indexOf(want, "path", p) != null) continue;
        const have = f.file(p) orelse continue;
        if (!have.ours) continue;
        try files.append(a, .{
            .op = .remove,
            .kind = .file,
            .subject = p,
            .to = "remove: yos wrote it, and nothing asks for it now",
            .reboot = desired.fileReboot(p),
        });
    }
    lists.sortByField(Change, "subject", files.items);
    try changes.appendSlice(a, files.items);
}

/// a secret others can read is allowed, but the plan says so after its
/// mode.
fn exposure(d: desired.File, mode: []const u8) []const u8 {
    if (d.secret == null) return "";
    const bits = std.fmt.parseInt(u32, mode, 8) catch 0;
    return if (bits & 0o044 != 0) ", which lets others read the secret" else "";
}

/// what a plan's `content` says for a file whose hash couldn't be taken.
const unknown_hash = "unknown";

/// the hash a file yos writes should have: the sha-256 of its content, or
/// for a secret, the keyed hash of its value the facts carry, which is
/// null when the observer couldn't read it. the planner never sees a
/// secret's value.
fn contentHash(a: Allocator, d: desired.File, f: *const facts.Facts) !?[]const u8 {
    const name = d.secret orelse return try a.dupe(u8, &facts.sha256Hex(d.content));
    const s = f.secret(name) orelse return null;
    return s.keyed;
}

/// "644" and "0644" are the same mode; facts write four digits.
fn normalMode(a: Allocator, mode: []const u8) ![]const u8 {
    return if (mode.len == 3) std.fmt.allocPrint(a, "0{s}", .{mode}) else mode;
}

/// pacman reads the config's repositories through one include line, and
/// trusts each one's key. a repository pacman.conf declares too would be
/// there twice, which pacman refuses, so each is reported and the result
/// is false.
fn planRepos(a: Allocator, c: *const config.Config, f: *const facts.Facts, changes: *std.ArrayList(Change), diags: *diag.List) !bool {
    if (!desired.ownRepos(c)) return true;
    var twice = false;
    for (c.repos.entries.items) |e| {
        if (!lists.contains(f.pacman.repos, e.name)) continue;
        twice = true;
        try diags.add(.bad_value, e.value.src, "repos.{s} is in /etc/pacman.conf too", .{e.name}, "take it out of pacman.conf; yos writes it to /etc/pacman.d/yos-repos.conf");
    }
    if (twice) return false;
    if (!f.pacman.includes_repos) try changes.append(a, .{ .op = .change, .kind = .pacman_conf, .subject = "/etc/pacman.conf", .to = "add " ++ facts.repos_include, .cause = "repos" });
    for (c.repos.entries.items) |e| {
        const k = e.value.key orelse continue;
        if (lists.contains(f.pacman.keys, k.v)) continue;
        try changes.append(a, .{ .op = .add, .kind = .key, .subject = k.v, .to = "import and trust", .cause = try std.fmt.allocPrint(a, "repos.{s}", .{e.name}) });
    }
    return true;
}

/// what the observer should look at for this config: every file it might
/// want or yos may have generated, and the repositories' signing keys.
pub fn wanted(a: Allocator, c: *const config.Config) !facts.Wanted {
    var keys: std.ArrayList([]const u8) = .empty;
    for (c.repos.entries.items) |e| {
        if (e.value.key) |k| try keys.append(a, k.v);
    }
    var names: std.ArrayList([]const u8) = .empty;
    var secret_files: std.ArrayList([]const u8) = .empty;
    for (c.files.entries.items) |e| {
        const s = e.value.secret orelse continue;
        try secret_files.append(a, e.name);
        if (!lists.contains(names.items, s.v)) try names.append(a, s.v);
    }
    return .{ .files = try desired.paths(a, c), .keys = keys.items, .secrets = names.items, .secret_files = secret_files.items };
}

// -- tests --

const testing = std.testing;

const helpers = @import("test_helpers.zig");
const T = helpers.Scratch;
const checks = @import("checks.zig");
const planview = @import("planview.zig");
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
    try planview.writeText(&out.writer, t.a(), &p, .{});
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
    try planview.writeText(&out.writer, t.a(), &p, .{});
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
    try planview.writeText(&verbose.writer, t.a(), &p, .{ .verbose = true });
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

test "a file's content is part of the plan's hash" {
    var t: T = .{};
    defer t.deinit();
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{lockPkg("linux", "1", &.{})} };
    var f: facts.Facts = .{};
    f.normalize();
    var hashes: [2][64]u8 = undefined;
    for ([_][]const u8{ "10", "60" }, &hashes) |v, *h| {
        const c = try t.cfg(try std.fmt.allocPrint(t.a(), "[sysctl]\n\"vm.swappiness\" = {s}\n", .{v}));
        const p = (try plan(t.a(), &c, &l, &f, &t.diags)).?;
        h.* = try p.hash();
    }
    try testing.expect(!std.mem.eql(u8, &hashes[0], &hashes[1]));
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
    try planview.writeJson(&out.writer, t.a(), &p);
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
        .{ .path = "/etc/issue", .sha256 = &facts.sha256Hex("old\n"), .mode = "0600" },
        .{ .path = "/etc/hosts.allow", .sha256 = &facts.sha256Hex("same\n"), .mode = "0644" },
    };
    const f: facts.Facts = .{ .files = &have };
    const p = (try plan(t.a(), &c, &l, &f, &t.diags)).?;
    try testing.expectEqual(4, p.changes.len);
    try testing.expectEqualStrings("/etc/hosts.allow", p.changes[0].subject);
    try testing.expectEqualStrings("mode 0600", p.changes[0].to.?);
    try testing.expectEqualStrings("/etc/issue", p.changes[1].subject);
    try testing.expectEqualStrings("rewrite, mode 0600", p.changes[1].to.?);
    try testing.expectEqual(Op.add, p.changes[2].op);
    try testing.expectEqualStrings(desired.sysctl_path, p.changes[3].subject);
    try testing.expectEqualStrings("sysctl", p.changes[3].cause.?);

    const sysctl = (try desired.files(t.a(), &c, &f))[3];
    try testing.expectEqualStrings(
        \\# written by yos from [sysctl] in the config. edits here are overwritten.
        \\kernel.printk = 3 3 3 3
        \\vm.swappiness = 10
        \\
    , sysctl.content);
}

test "nvidia's initramfs drop-in, unless the machine loads the modules already" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("[boot]\nkernel = \"none\"\n[hardware]\ngpu = \"nvidia\"\n");
    const without: facts.Facts = .{};
    const want = try desired.files(t.a(), &c, &without);
    try testing.expectEqual(1, want.len);
    try testing.expectEqualStrings(desired.nvidia_initramfs_path, want[0].path);
    try testing.expectEqualStrings("initramfs", want[0].reboot.?);

    const with: facts.Facts = .{ .initramfs_modules = &.{ "nvidia", "nvidia_modeset", "nvidia_uvm", "nvidia_drm" } };
    try testing.expectEqual(0, (try desired.files(t.a(), &c, &with)).len);

    const booster = try t.cfg("[boot]\nkernel = \"none\"\n[hardware]\ngpu = \"nvidia\"\n[providers]\ninitramfs = \"booster\"\n");
    try testing.expectEqual(0, (try desired.files(t.a(), &booster, &without)).len);
}

test "the drop-in that unlocks a luks root, unless the hooks do already" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("[boot]\nkernel = \"none\"\nencrypt = true\n");
    // mkinitcpio's own hooks, as a clean build starts with.
    const plain: facts.Facts = .{ .boot = .{ .initramfs_hooks = &.{ "base", "systemd", "autodetect", "microcode", "modconf", "kms", "keyboard", "sd-vconsole", "block", "filesystems", "fsck" } } };
    const want = try desired.files(t.a(), &c, &plain);
    try testing.expectEqual(1, want.len);
    try testing.expectEqualStrings("/etc/mkinitcpio.conf.d/90-yos-encrypt.conf", want[0].path);
    try testing.expectEqualStrings("initramfs", want[0].reboot.?);
    try testing.expectEqualStrings("boot.encrypt", want[0].cause.?);
    try testing.expect(std.mem.startsWith(u8, want[0].content, "# written by yos from [boot] encrypt in the config."));
    try testing.expect(std.mem.indexOf(u8, want[0].content, "    filesystems)\n") != null);
    try testing.expect(std.mem.indexOf(u8, want[0].content, "_yos_hooks+=(sd-encrypt)\n") != null);
    // autodetect finding no modules for a driver built into the kernel
    // isn't a failed build.
    try testing.expect(std.mem.indexOf(u8, want[0].content, "_yos_add_checked_modules \"$@\" || true\n") != null);

    // busybox's encrypt, as an older archinstall sets up, or sd-encrypt.
    const unlocking = [_][]const []const u8{ &.{ "base", "udev", "encrypt", "filesystems" }, &.{ "base", "systemd", "sd-encrypt", "filesystems" } };
    for (unlocking) |hooks| {
        const ready: facts.Facts = .{ .boot = .{ .initramfs_hooks = hooks } };
        try testing.expectEqual(0, (try desired.files(t.a(), &c, &ready)).len);
    }
    const off = try t.cfg("[boot]\nkernel = \"none\"\nencrypt = false\n");
    try testing.expectEqual(0, (try desired.files(t.a(), &off, &plain)).len);
    const booster = try t.cfg("[boot]\nkernel = \"none\"\nencrypt = true\n[providers]\ninitramfs = \"booster\"\n");
    try testing.expectEqual(0, (try desired.files(t.a(), &booster, &plain)).len);
}

test "[boot] uki brings ukify, and its config where yos writes the menu" {
    var t: T = .{};
    defer t.deinit();
    const a = t.a();
    const c = try t.cfg("[boot]\nkernel = \"none\"\nuki = true\n");
    const w = findWant(try wants(a, &c), "systemd-ukify").?;
    try testing.expectEqualStrings("boot.uki", w.cause.?);

    const on_gens: facts.Facts = .{ .boot = .{ .root_fs = "btrfs", .root_subvol = "/@roots/3" } };
    const want = try desired.files(a, &c, &on_gens);
    try testing.expectEqual(1, want.len);
    try testing.expectEqualStrings("/etc/kernel/yos-uki.conf", want[0].path);
    try testing.expectEqualStrings("uki", want[0].reboot.?);
    try testing.expect(std.mem.startsWith(u8, want[0].content, "# written by yos from [boot] uki in the config."));
    // a root being built, where mounts say nothing, gets it too.
    try testing.expectEqual(1, (try desired.files(a, &c, &.{})).len);
    // without generations, yos writes no menu.
    for ([_]facts.Boot{ .{ .root_fs = "ext4" }, .{ .root_fs = "btrfs", .root_subvol = "/@" } }) |b| {
        try testing.expectEqual(0, (try desired.files(a, &c, &.{ .boot = b })).len);
    }
    const off = try t.cfg("[boot]\nkernel = \"none\"\nuki = false\n");
    try testing.expectEqual(null, findWant(try wants(a, &off), "systemd-ukify"));
    try testing.expectEqual(0, (try desired.files(a, &off, &on_gens)).len);

    // turning it off takes yos's config out, which needs a reboot too.
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{} };
    var files = [_]facts.File{.{ .path = "/etc/kernel/yos-uki.conf", .sha256 = &facts.sha256Hex(uki.config_content), .mode = "0644", .ours = true }};
    const had: facts.Facts = .{ .files = &files, .boot = on_gens.boot };
    const p = (try plan(a, &off, &l, &had, &t.diags)).?;
    try testing.expectEqual(1, p.changes.len);
    try testing.expectEqual(Op.remove, p.changes[0].op);
    try testing.expectEqualStrings("uki", p.changes[0].reboot.?);
    try testing.expect(!checks.ukiAfter(&p, &had));
    try testing.expect(checks.ukiAfter(&.{ .changes = &.{} }, &had));
    // left on, the config there is the one it wants.
    const with: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{lockPkg("systemd-ukify", "258-1", &.{})} };
    for ((try plan(a, &c, &with, &had, &t.diags)).?.changes) |ch| try testing.expect(ch.kind != .file);
}

test "[boot] secure_boot brings sbctl, and its file where yos writes the menu" {
    var t: T = .{};
    defer t.deinit();
    const a = t.a();
    const c = try t.cfg("[boot]\nkernel = \"none\"\nuki = true\nsecure_boot = true\n");
    try testing.expectEqualStrings("boot.secure_boot", findWant(try wants(a, &c), "sbctl").?.cause.?);
    const on_gens: facts.Facts = .{ .boot = .{ .root_fs = "btrfs", .root_subvol = "/@roots/3", .sbctl_keys = true } };
    const want = try desired.files(a, &c, &on_gens);
    try testing.expectEqual(2, want.len);
    try testing.expectEqualStrings("/etc/kernel/yos-secure-boot.conf", want[1].path);
    try testing.expectEqualStrings("secure boot", want[1].reboot.?);
    try testing.expect(std.mem.startsWith(u8, want[1].content, "# written by yos from [boot] secure_boot in the config."));
    try testing.expectEqual(0, (try desired.files(a, &c, &.{ .boot = .{ .root_fs = "ext4" } })).len);

    // turning it off takes the file out, which needs a reboot too.
    const off = try t.cfg("[boot]\nkernel = \"none\"\nuki = true\n");
    try testing.expectEqual(null, findWant(try wants(a, &off), "sbctl"));
    var files = [_]facts.File{
        .{ .path = uki.config_path, .sha256 = &facts.sha256Hex(uki.config_content), .mode = "0644", .ours = true },
        .{ .path = secureboot.config_path, .sha256 = &facts.sha256Hex(secureboot.config_content), .mode = "0644", .ours = true },
    };
    const had: facts.Facts = .{ .files = &files, .boot = on_gens.boot };
    const with: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{ lockPkg("sbctl", "0.17-1", &.{}), lockPkg("systemd-ukify", "258-1", &.{}) } };
    const p = (try plan(a, &off, &with, &had, &t.diags)).?;
    var removed = false;
    for (p.changes) |ch| {
        if (ch.kind != .file) continue;
        try testing.expectEqual(Op.remove, ch.op);
        try testing.expectEqualStrings(secureboot.config_path, ch.subject);
        try testing.expectEqualStrings("secure boot", ch.reboot.?);
        removed = true;
    }
    try testing.expect(removed);
    // left on, the file there is the one it wants.
    for ((try plan(a, &c, &with, &had, &t.diags)).?.changes) |ch| try testing.expect(ch.kind != .file);
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

test "a login choice owns the display manager, and changes it at the next boot" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("[desktop]\nsession = \"hyprland\"\nlogin = \"greetd\"\n");
    const names = [_][]const u8{ "greetd", "greetd-tuigreet", "hyprland", "linux", "xdg-desktop-portal-hyprland" };
    var locked: [names.len]lock.Package = undefined;
    var have: [names.len]facts.Package = undefined;
    for (names, &locked, &have) |n, *l, *h| {
        l.* = lockPkg(n, "1", &.{});
        h.* = .{ .name = n, .version = "1" };
    }
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &locked };
    var units = [_]facts.Unit{
        .{ .name = "greetd.service", .enabled = false, .active = false },
        .{ .name = "sddm.service", .enabled = true, .active = true },
    };
    const f: facts.Facts = .{ .packages = &have, .units = &units };
    const p = (try plan(t.a(), &c, &l, &f, &t.diags)).?;
    var out: std.Io.Writer.Allocating = .init(t.a());
    try planview.writeText(&out.writer, t.a(), &p, .{});
    try testing.expectEqualStrings(
        \\services
        \\  + greetd.service: enable  (desktop.login)
        \\  - sddm.service: disable  (desktop.login)
        \\files
        \\  + /etc/greetd/config.toml: write, mode 0644  (desktop.login)
        \\
        \\plan: 2 to add, 0 to change, 1 to remove · reboot needed: display manager
        \\
    , out.written());
}

test "logging in on tty1 starts the session through uwsm" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("[desktop]\nsession = \"hyprland\"\nlogin = \"tty\"\n");
    const want = try desired.files(t.a(), &c, &.{});
    try testing.expectEqual(1, want.len);
    try testing.expectEqualStrings("/etc/profile.d/yos-session.sh", want[0].path);
    try testing.expect(std.mem.indexOf(u8, want[0].content, "exec uwsm start hyprland.desktop\n") != null);
}

test "the session's own config lands where hyprland looks without a user one" {
    var t: T = .{};
    defer t.deinit();
    var c = try t.cfg("[desktop]\nsession = \"hyprland\"\nsession_config = \"files/hyprland.lua\"\n");
    c.desktop.session_content = "-- mine\n";
    const want = try desired.files(t.a(), &c, &.{});
    try testing.expectEqual(1, want.len);
    try testing.expectEqualStrings("/etc/xdg/hypr/hyprland.lua", want[0].path);
    try testing.expectEqualStrings("-- mine\n", want[0].content);
}

test "kernel modules to load at boot" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("[boot]\nmodules = [\"nct6775\", \"i2c-dev\"]\n");
    const want = try desired.files(t.a(), &c, &.{});
    try testing.expectEqual(1, want.len);
    try testing.expectEqualStrings(desired.modules_path, want[0].path);
    try testing.expectEqualStrings("# written by yos from [boot] modules in the config. edits here are overwritten.\ni2c-dev\nnct6775\n", want[0].content);
}

test "a file yos generated goes when nothing asks for it, but one it didn't write stays" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("[boot]\nkernel = \"none\"\n");
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{} };
    var files = [_]facts.File{
        .{ .path = desired.sysctl_path, .sha256 = "x", .mode = "0644", .ours = true },
        .{ .path = desired.greetd_config_path, .sha256 = "y", .mode = "0644", .ours = false },
    };
    const f: facts.Facts = .{ .files = &files };
    const p = (try plan(t.a(), &c, &l, &f, &t.diags)).?;
    try testing.expectEqual(1, p.changes.len);
    try testing.expectEqual(Op.remove, p.changes[0].op);
    try testing.expectEqualStrings(desired.sysctl_path, p.changes[0].subject);
}

test "what yoq os wrote goes once the machine moved over, even when yos writes the same now" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("[boot]\nkernel = \"none\"\n[sysctl]\n\"vm.swappiness\" = 10\n");
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{} };
    var files = [_]facts.File{
        .{ .path = "/etc/sysctl.d/99-yoq.conf", .sha256 = "x", .mode = "0644", .ours = true },
        .{ .path = "/etc/modules-load.d/99-yoq.conf", .sha256 = "y", .mode = "0644", .ours = false },
    };
    const f: facts.Facts = .{ .files = &files };
    const p = (try plan(t.a(), &c, &l, &f, &t.diags)).?;
    try testing.expectEqual(2, p.changes.len);
    try testing.expectEqualStrings("/etc/sysctl.d/99-yoq.conf", p.changes[0].subject);
    try testing.expectEqual(Op.remove, p.changes[0].op);
    try testing.expectEqualStrings(desired.sysctl_path, p.changes[1].subject);
    try testing.expectEqual(Op.add, p.changes[1].op);
}

test "a unit that can't be enabled only starts and stops" {
    var t: T = .{};
    defer t.deinit();
    const on = try t.cfg("[boot]\nkernel = \"none\"\n[services.pinger]\nunit = \"pinger.service\"\npackage = \"iputils\"\n");
    const off = try t.cfg("[boot]\nkernel = \"none\"\n[services.pinger]\nenabled = false\nunit = \"pinger.service\"\npackage = \"iputils\"\n");
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{lockPkg("iputils", "1", &.{})} };
    var have = [_]facts.Package{.{ .name = "iputils", .version = "1" }};
    var units = [_]facts.Unit{.{ .name = "pinger.service", .fixed = true, .active = true }};
    const f: facts.Facts = .{ .packages = &have, .units = &units };
    try testing.expect((try plan(t.a(), &on, &l, &f, &t.diags)).?.empty());
    const p = (try plan(t.a(), &off, &l, &f, &t.diags)).?;
    var stops: usize = 0;
    for (p.changes) |ch| {
        if (ch.kind == .unit) {
            try testing.expectEqualStrings("stop", ch.to.?);
            stops += 1;
        }
    }
    try testing.expectEqual(1, stops);
}

test "a oneshot service that ran and finished is as it should be" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("[boot]\nkernel = \"none\"\n[services.setup]\nunit = \"setup.service\"\npackage = \"setup\"\n");
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{lockPkg("setup", "1", &.{})} };
    var have = [_]facts.Package{.{ .name = "setup", .version = "1" }};
    var units = [_]facts.Unit{.{ .name = "setup.service", .enabled = true, .ran = true }};
    const f: facts.Facts = .{ .packages = &have, .units = &units };
    try testing.expect((try plan(t.a(), &c, &l, &f, &t.diags)).?.empty());
}

test "a repository from the config: its file, pacman.conf's include, and its key" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg(
        \\[boot]
        \\kernel = "none"
        \\[repos.chaotic-aur]
        \\server = "https://cdn-mirror.chaotic.cx/$repo/$arch"
        \\key = "EF925EA60F33D0CB85C44AD13056513887B78AEB"
        \\
    );
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{} };
    const p = (try plan(t.a(), &c, &l, &.{}, &t.diags)).?;
    var out: std.Io.Writer.Allocating = .init(t.a());
    try planview.writeText(&out.writer, t.a(), &p, .{});
    try testing.expectEqualStrings(
        \\files
        \\  + /etc/pacman.d/yos-repos.conf: write, mode 0644  (repos)
        \\repositories
        \\  ~ /etc/pacman.conf: add Include = /etc/pacman.d/yos-repos.conf  (repos)
        \\keys
        \\  + EF925EA60F33D0CB85C44AD13056513887B78AEB: import and trust  (repos.chaotic-aur)
        \\
        \\plan: 2 to add, 1 to change, 0 to remove · no reboot
        \\
    , out.written());
    const want = try desired.files(t.a(), &c, &.{});
    try testing.expect(std.mem.indexOf(u8, want[0].content, "[chaotic-aur]\nSigLevel = Required DatabaseOptional\nServer = https://cdn-mirror.chaotic.cx/$repo/$arch\n") != null);

    // once pacman.conf has the include and the keyring the key, nothing's left
    // but the file.
    var files = [_]facts.File{.{ .path = facts.repos_conf, .sha256 = &facts.sha256Hex(want[0].content), .mode = "0644", .ours = true }};
    const f: facts.Facts = .{ .files = &files, .pacman = .{ .includes_repos = true, .keys = &.{"EF925EA60F33D0CB85C44AD13056513887B78AEB"} } };
    try testing.expect((try plan(t.a(), &c, &l, &f, &t.diags)).?.empty());
}

test "a repository pacman.conf declares too is reported, not written twice" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("[boot]\nkernel = \"none\"\n[repos.omarchy]\nserver = \"https://pkgs.omarchy.org/$arch\"\n");
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{} };
    const f: facts.Facts = .{ .pacman = .{ .repos = &.{ "core", "extra", "omarchy" } } };
    try testing.expectEqual(null, try plan(t.a(), &c, &l, &f, &t.diags));
    try testing.expectEqualStrings("repos.omarchy is in /etc/pacman.conf too", t.diags.items.items[0].message);
}

test "a secret's file is planned by its keyed hash, never its value" {
    var t: T = .{};
    defer t.deinit();
    const a = t.a();
    const secrets = @import("secrets.zig");
    const c = try t.cfg("[boot]\nkernel = \"none\"\n[files.\"/etc/wifi.psk\"]\nsecret = \"wifi/home\"\n");
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{} };
    const key: secrets.Key = @splat(7);
    const now = secrets.keyedHex(&key, "hunter2");
    var have = [_]facts.File{.{ .path = "/etc/wifi.psk", .sha256 = &now, .mode = "0600", .keyed = true }};
    var known = [_]facts.Secret{.{ .name = "wifi/home", .state = .set, .keyed = &now }};
    var f: facts.Facts = .{ .files = &have, .secrets = &known };

    const want = try wanted(a, &c);
    try testing.expectEqualStrings("wifi/home", want.secrets[0]);
    try testing.expectEqualStrings("/etc/wifi.psk", want.secret_files[0]);
    try testing.expect((try plan(a, &c, &l, &f, &t.diags)).?.empty());
    try testing.expect(try checks.checkSecrets(&c, &f, &t.diags));

    // a new value: the file is rewritten, and the hash follows the value.
    const next = secrets.keyedHex(&key, "hunter3");
    known[0].keyed = &next;
    const p = (try plan(a, &c, &l, &f, &t.diags)).?;
    try testing.expectEqual(1, p.changes.len);
    try testing.expectEqualStrings("rewrite, mode 0600", p.changes[0].to.?);
    const third = secrets.keyedHex(&key, "hunter4");
    known[0].keyed = &third;
    const p2 = (try plan(a, &c, &l, &f, &t.diags)).?;
    try testing.expect(!std.mem.eql(u8, &try p.hash(), &try p2.hash()));
    var out: std.Io.Writer.Allocating = .init(a);
    try planview.writeJson(&out.writer, a, &p);
    try planview.writeText(&out.writer, a, &p, .{ .verbose = true });
    for ([_][]const u8{ "hunter2", "hunter3", &facts.sha256Hex("hunter2"), &facts.sha256Hex("hunter3"), &next }) |leak| {
        try testing.expect(std.mem.indexOf(u8, out.written(), leak) == null);
    }

    // without root, nothing can be compared, so nothing differs.
    known[0] = .{ .name = "wifi/home" };
    have[0].sha256 = "";
    try testing.expect((try plan(a, &c, &l, &f, &t.diags)).?.empty());
    try testing.expect(try checks.checkSecrets(&c, &f, &t.diags));

    // not set here: a plan error that says how to set it.
    known[0].state = .missing;
    try testing.expect(!try checks.checkSecrets(&c, &f, &t.diags));
    const d = t.diags.items.items[0];
    try testing.expectEqual(diag.Code.secret_missing, d.code);
    try testing.expectEqualStrings("files.\"/etc/wifi.psk\" needs the secret \"wifi/home\", and this machine doesn't have it", d.message);
    try testing.expectEqualStrings("set it with `yos secret set wifi/home`", d.hint.?);
    try testing.expectEqualStrings("E0133", diag.entry(d.code).id);
}

test "a secret others can read is written, with a warning" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("[boot]\nkernel = \"none\"\n[files.\"/etc/shared\"]\nsecret = \"shared\"\nmode = \"0644\"\n");
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{} };
    var f: facts.Facts = .{};
    const p = (try plan(t.a(), &c, &l, &f, &t.diags)).?;
    try testing.expectEqualStrings("write, mode 0644, which lets others read the secret", p.changes[0].to.?);
    var have = [_]facts.File{.{ .path = "/etc/shared", .sha256 = "", .mode = "0600", .keyed = true }};
    f.files = &have;
    try testing.expectEqualStrings("mode 0644, which lets others read the secret", (try plan(t.a(), &c, &l, &f, &t.diags)).?.changes[0].to.?);
}
