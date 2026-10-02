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
const aur = @import("aur.zig");
const diag = @import("diag.zig");
const output = @import("output.zig");
const lists = @import("lists.zig");
const generation = @import("generation.zig");
const menu = @import("menu.zig");
const uki = @import("uki.zig");
const secureboot = @import("secureboot.zig");
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
    /// a repository's signing key, imported into pacman's keyring and
    /// trusted. the subject is its fingerprint.
    key,
    /// pacman.conf, reading the file os writes the repositories to.
    pacman_conf,
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
    fn tally(p: *const Plan, kinds: []const Kind) Summary {
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
        try diags.add(.lock_stale, w.src, "{s} isn't in machine.lock yet", .{w.name}, "run `os update` to resolve it into the lock");
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
    const want = try desiredFiles(a, c, f);
    var files: std.ArrayList(Change) = .empty;
    for (want) |d| {
        const mode = try normalMode(a, d.mode);
        const exposed = exposure(d, mode);
        var ch: Change = .{
            .op = .change,
            .kind = .file,
            .subject = d.path,
            .cause = d.cause orelse try std.fmt.allocPrint(a, "files.\"{s}\"", .{d.path}),
            .reboot = d.reboot orelse fileReboot(d.path),
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
    for (generated_paths) |p| {
        if (lists.indexOf(want, "path", p) != null) continue;
        const have = f.file(p) orelse continue;
        if (!have.ours) continue;
        try files.append(a, .{
            .op = .remove,
            .kind = .file,
            .subject = p,
            .to = "remove: os wrote it, and nothing asks for it now",
            .reboot = fileReboot(p),
        });
    }
    lists.sortByField(Change, "subject", files.items);
    try changes.appendSlice(a, files.items);
}

/// a secret others can read is allowed, but the plan says so after its
/// mode.
fn exposure(d: DesiredFile, mode: []const u8) []const u8 {
    if (d.secret == null) return "";
    const bits = std.fmt.parseInt(u32, mode, 8) catch 0;
    return if (bits & 0o044 != 0) ", which lets others read the secret" else "";
}

/// what a plan's `content` says for a file whose hash couldn't be taken.
const unknown_hash = "unknown";

/// the hash a file os writes should have: the sha-256 of its content, or
/// for a secret, the keyed hash of its value the facts carry, which is
/// null when the observer couldn't read it. the planner never sees a
/// secret's value.
fn contentHash(a: Allocator, d: DesiredFile, f: *const facts.Facts) !?[]const u8 {
    const name = d.secret orelse return try a.dupe(u8, &facts.sha256Hex(d.content));
    const s = f.secret(name) orelse return null;
    return s.keyed;
}

/// refuses, with a diagnostic, a plan for a config whose secrets this
/// machine doesn't have. secrets the observer couldn't look at pass: apply
/// runs as root and looks again.
pub fn checkSecrets(c: *const config.Config, f: *const facts.Facts, diags: *diag.List) !bool {
    var ok = true;
    for (c.files.entries.items) |e| {
        const ref = e.value.secret orelse continue;
        const s = f.secret(ref.v) orelse continue;
        switch (s.state) {
            .set, .unknown => continue,
            .missing => try diags.addHint(.secret_missing, ref.src, "files.\"{s}\" needs the secret \"{s}\", and this machine doesn't have it", .{ e.name, ref.v }, "set it with `os secret set {s}`", .{ref.v}),
            .unreadable => try diags.addHint(.secret_missing, ref.src, "the secret \"{s}\" for files.\"{s}\" can't be decrypted on this machine", .{ ref.v, e.name }, "values don't move between machines; set it again here with `os secret set {s}`", .{ref.v}),
        }
        ok = false;
    }
    return ok;
}

/// "644" and "0644" are the same mode; facts write four digits.
fn normalMode(a: Allocator, mode: []const u8) ![]const u8 {
    return if (mode.len == 3) std.fmt.allocPrint(a, "0{s}", .{mode}) else mode;
}

/// whether the config has repositories of its own for pacman: declared
/// ones, or the local one aur packages are built into.
pub fn ownRepos(c: *const config.Config) bool {
    return c.repos.entries.items.len > 0 or c.aur.items.items.len > 0;
}

/// pacman reads the config's repositories through one include line, and
/// trusts each one's key. a repository pacman.conf declares too would be
/// there twice, which pacman refuses, so each is reported and the result
/// is false.
fn planRepos(a: Allocator, c: *const config.Config, f: *const facts.Facts, changes: *std.ArrayList(Change), diags: *diag.List) !bool {
    if (!ownRepos(c)) return true;
    var twice = false;
    for (c.repos.entries.items) |e| {
        if (!lists.contains(f.pacman.repos, e.name)) continue;
        twice = true;
        try diags.add(.bad_value, e.value.src, "repos.{s} is in /etc/pacman.conf too", .{e.name}, "take it out of pacman.conf; os writes it to /etc/pacman.d/yoq-repos.conf");
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

/// a file os writes, from `[files]` or made from another key.
pub const DesiredFile = struct {
    path: []const u8,
    content: []const u8,
    /// for a file that holds a secret: its name, and `content` is empty.
    /// apply reads the value only as it writes the file.
    secret: ?[]const u8 = null,
    mode: []const u8 = config.File.default_mode,
    /// the key that makes the file, for ones `[files]` doesn't name.
    cause: ?[]const u8 = null,
    /// where that key is set, when the config sets it.
    src: ?config.Src = null,
    /// why a change to it needs a reboot, if one does.
    reboot: ?[]const u8 = null,
};

/// where `[sysctl]` goes.
pub const sysctl_path = "/etc/sysctl.d/99-yoq.conf";

/// where `[boot] modules` goes.
pub const modules_path = "/etc/modules-load.d/99-yoq.conf";

const greetd_config_path = "/etc/greetd/config.toml";
const tty_session_path = "/etc/profile.d/yoq-session.sh";

/// mkinitcpio's drop-in that loads nvidia's modules early.
const nvidia_initramfs_path = "/etc/mkinitcpio.conf.d/10-yoq-nvidia.conf";

/// mkinitcpio's drop-in that unlocks a luks root.
pub const encrypt_initramfs_path = facts.initramfs_dropins ++ "/" ++ facts.encrypt_dropin;

/// whether a file os writes is a mkinitcpio drop-in. changing one changes
/// the initramfs, so it waits for a reboot like a kernel does, and apply
/// rebuilds the initramfs in the root it builds.
pub fn isInitramfsDropIn(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/etc/mkinitcpio.conf.d/");
}

/// why a change to a file os writes needs a reboot: a drop-in changes the
/// initramfs, the ukify config changes what the menu boots, and the
/// secure boot file whether its images are signed.
fn fileReboot(path: []const u8) ?[]const u8 {
    if (isInitramfsDropIn(path)) return "initramfs";
    if (std.mem.eql(u8, path, secureboot.config_path)) return secure_boot_reboot;
    return if (std.mem.eql(u8, path, uki.config_path)) uki_reboot else null;
}

/// the reboot reason for turning `[boot] uki` on or off.
pub const uki_reboot = "uki";

/// the reboot reason for turning `[boot] secure_boot` on or off.
pub const secure_boot_reboot = "secure boot";

/// files os writes from other keys, each starting with a "written by os"
/// line. one still there that nothing asks for any more is removed. the
/// session's own config isn't here: it's the user's file.
const generated_paths = [_][]const u8{ sysctl_path, modules_path, greetd_config_path, tty_session_path, nvidia_initramfs_path, encrypt_initramfs_path, uki.config_path, secureboot.config_path };

/// the first line of a file os makes from `key`.
fn header(comptime key: []const u8) []const u8 {
    return "# written by os from " ++ key ++ " in the config. edits here are overwritten.\n";
}

/// tuigreet on tty1, offering every installed wayland session.
const greetd_config =
    \\# written by os for [desktop] login = "greetd". edits here are overwritten.
    \\[terminal]
    \\vt = 1
    \\
    \\[default_session]
    \\command = "tuigreet --time --remember --remember-session --sessions /usr/share/wayland-sessions"
    \\user = "greeter"
    \\
;

/// logging in on tty1 starts the session through uwsm.
const tty_session =
    \\# written by os for [desktop] login = "tty". edits here are overwritten.
    \\if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = /dev/tty1 ] && uwsm check may-start; then
    \\    exec uwsm start {s}
    \\fi
    \\
;

/// the modules nvidia's driver wants early.
const nvidia_modules = [_][]const u8{ "nvidia", "nvidia_modeset", "nvidia_uvm", "nvidia_drm" };

const nvidia_initramfs_content = blk: {
    var s: []const u8 = "# written by os for [hardware] gpu = \"nvidia\".\nMODULES+=(" ++ nvidia_modules[0];
    for (nvidia_modules[1..]) |m| s = s ++ " " ++ m;
    break :blk s ++ ")\n";
};

/// sd-encrypt unlocks the root with what the kernel's command line names,
/// and it needs systemd in the initramfs: busybox's hooks (udev, keymap,
/// consolefont, and resume and usr, which systemd does itself) become
/// systemd's, sd-encrypt goes before filesystems, and keyboard before
/// that, to type the passphrase with. mkinitcpio sources drop-ins as
/// bash, after its own config, so this works on whatever hooks are set.
pub const encrypt_initramfs_content =
    \\# written by os from [boot] encrypt in the config. edits here are overwritten.
    \\_yoq_hooks=()
    \\for _yoq_hook in "${HOOKS[@]}"; do
    \\    case $_yoq_hook in
    \\    udev) _yoq_hook=systemd ;;
    \\    keymap | consolefont) _yoq_hook=sd-vconsole ;;
    \\    encrypt | sd-encrypt | resume | usr) continue ;;
    \\    filesystems)
    \\        [[ " ${_yoq_hooks[*]} " == *" keyboard "* ]] || _yoq_hooks+=(keyboard)
    \\        _yoq_hooks+=(sd-encrypt)
    \\        ;;
    \\    esac
    \\    [[ " ${_yoq_hooks[*]} " == *" $_yoq_hook "* ]] || _yoq_hooks+=("$_yoq_hook")
    \\done
    \\HOOKS=("${_yoq_hooks[@]}")
    \\unset _yoq_hooks _yoq_hook
    \\# with autodetect, add_checked_modules keeps only the modules this machine
    \\# uses, and mkinitcpio counts finding none as a failed build, without
    \\# saying why. that's what it finds when the driver is built into the
    \\# kernel, as arch's tpm and btrfs drivers are, and sd-encrypt asks for
    \\# the tpm's on every build. finding none isn't a failure here; a module
    \\# it finds and can't add still is.
    \\if declare -F add_checked_modules >/dev/null && ! declare -F _yoq_add_checked_modules >/dev/null; then
    \\    eval "_yoq_$(declare -f add_checked_modules)"
    \\    add_checked_modules() {
    \\        _yoq_add_checked_modules "$@" || true
    \\    }
    \\fi
    \\
;

/// every file the config wants: `[files]`, then the ones other keys make.
/// nvidia's initramfs drop-in is left out when the machine loads those
/// modules already, as `f` shows.
pub fn desiredFiles(a: Allocator, c: *const config.Config, f: *const facts.Facts) ![]const DesiredFile {
    var out: std.ArrayList(DesiredFile) = .empty;
    for (c.files.entries.items) |e| {
        if (e.value.secret) |s| {
            try out.append(a, .{ .path = e.name, .content = "", .secret = s.v, .mode = e.value.modeOf() });
            continue;
        }
        // a source that couldn't be read was reported when loading.
        const content = e.value.content orelse continue;
        try out.append(a, .{ .path = e.name, .content = content, .mode = e.value.modeOf() });
    }
    const made = [_]?DesiredFile{
        try sysctlFile(a, c),
        try loginFile(a, c),
        try reposFile(a, c, f),
        try sessionFile(a, c),
        try modulesFile(a, c),
        nvidiaFile(c, f),
        encryptFile(c, f),
        ukiFile(c, f),
        secureBootFile(c, f),
    };
    for (made) |m| {
        if (m) |d| try out.append(a, d);
    }
    return out.items;
}

fn sysctlFile(a: Allocator, c: *const config.Config) !?DesiredFile {
    if (c.sysctl.entries.items.len == 0) return null;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, header("[sysctl]"));
    for (try sortedNames(a, c.sysctl.entries.items)) |k| try text.print(a, "{s} = {s}\n", .{ k, c.sysctl.get(k).?.v.text });
    return .{ .path = sysctl_path, .content = text.items, .cause = "sysctl", .src = c.sysctl.entries.items[0].value.src };
}

fn modulesFile(a: Allocator, c: *const config.Config) !?DesiredFile {
    if (c.boot.modules.items.items.len == 0) return null;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, header("[boot] modules"));
    for (try sortedNames(a, c.boot.modules.items.items)) |n| try text.print(a, "{s}\n", .{n});
    return .{ .path = modules_path, .content = text.items, .cause = "boot.modules", .src = c.boot.modules.items.items[0].src };
}

/// the `name` of each item, sorted, so a file doesn't depend on the
/// config's order.
fn sortedNames(a: Allocator, items: anytype) ![]const []const u8 {
    const names = try a.alloc([]const u8, items.len);
    for (items, names) |it, *n| n.* = it.name;
    lists.sortStrings(names);
    return names;
}

fn loginFile(a: Allocator, c: *const config.Config) !?DesiredFile {
    const login = c.desktop.login orelse return null;
    return switch (login.v) {
        .greetd => .{ .path = greetd_config_path, .content = greetd_config, .cause = "desktop.login", .src = login.src },
        .tty => .{
            .path = tty_session_path,
            .content = try std.fmt.allocPrint(a, tty_session, .{catalog.sessionDesktop((c.desktop.session orelse return null).v)}),
            .cause = "desktop.login",
            .src = login.src,
        },
        .sddm => null,
    };
}

/// the file pacman.conf includes for the config's repositories. once
/// pacman.conf reads it, it stays, empty if need be: pacman fails on an
/// include that's gone.
fn reposFile(a: Allocator, c: *const config.Config, f: *const facts.Facts) !?DesiredFile {
    if (!ownRepos(c) and !f.pacman.includes_repos) return null;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, header("[repos]"));
    for (c.repos.entries.items) |e| {
        // one without a server was reported when the config loaded.
        const server = e.value.server orelse continue;
        // with a key, packages must be signed by it; without one, they
        // aren't checked.
        const siglevel = if (e.value.key != null) "Required DatabaseOptional" else "Optional TrustAll";
        try text.print(a, "\n[{s}]\nSigLevel = {s}\nServer = {s}\n", .{ e.name, siglevel, server.v });
    }
    // the aur packages os builds, unsigned, in a local repository.
    if (c.aur.items.items.len > 0) try text.print(a, "\n[{s}]\nSigLevel = Optional TrustAll\nServer = file://{s}\n", .{ aur.repo_name, aur.repo_dir });
    return .{ .path = facts.repos_conf, .content = text.items, .cause = "repos", .src = reposSrc(c) };
}

/// where the config first asks for a repository of its own, if it does.
pub fn reposSrc(c: *const config.Config) ?config.Src {
    if (c.repos.entries.items.len > 0) return c.repos.entries.items[0].value.src;
    if (c.aur.items.items.len > 0) return c.aur.items.items[0].src;
    return null;
}

/// hyprland reads /etc/xdg/hypr when a user has no config of their own.
/// the file keeps its extension: .conf, or .lua for newer ones.
fn sessionFile(a: Allocator, c: *const config.Config) !?DesiredFile {
    const content = c.desktop.session_content orelse return null;
    const ext = std.fs.path.extension(c.desktop.session_config.?.v);
    return .{
        .path = try std.fmt.allocPrint(a, "/etc/xdg/hypr/hyprland{s}", .{if (ext.len > 0) ext else ".conf"}),
        .content = content,
        .cause = "desktop.session_config",
        .src = c.desktop.session_config.?.src,
    };
}

/// nvidia's driver wants its modules in the initramfs. amd and intel come
/// with mkinitcpio's kms hook already.
fn nvidiaFile(c: *const config.Config, f: *const facts.Facts) ?DesiredFile {
    const gpu = c.hardware.gpu orelse return null;
    if (gpu.v != .nvidia) return null;
    if (c.providers.get("initramfs")) |p| {
        if (!std.mem.eql(u8, p.v, "mkinitcpio")) return null;
    }
    for (nvidia_modules) |m| {
        if (!lists.contains(f.initramfs_modules, m)) break;
    } else return null;
    return .{ .path = nvidia_initramfs_path, .content = nvidia_initramfs_content, .cause = "hardware.gpu", .src = gpu.src, .reboot = "initramfs" };
}

/// the drop-in for `[boot] encrypt`, unless mkinitcpio's hooks unlock
/// luks already, as an encrypted archinstall's do, or another initramfs
/// generator builds it.
fn encryptFile(c: *const config.Config, f: *const facts.Facts) ?DesiredFile {
    const encrypt = c.boot.encrypt orelse return null;
    if (!encrypt.v) return null;
    if (c.providers.get("initramfs")) |p| {
        if (!std.mem.eql(u8, p.v, "mkinitcpio")) return null;
    }
    if (facts.hasEncryptHook(f.boot.initramfs_hooks)) return null;
    return .{ .path = encrypt_initramfs_path, .content = encrypt_initramfs_content, .cause = "boot.encrypt", .src = encrypt.src, .reboot = "initramfs" };
}

/// the ukify config for `[boot] uki`, which has the menu boot an image.
fn ukiFile(c: *const config.Config, f: *const facts.Facts) ?DesiredFile {
    return menuFile(c.boot.uki, f, .{ .path = uki.config_path, .content = uki.config_content, .cause = "boot.uki", .reboot = uki_reboot });
}

/// the file that has a root's images signed for `[boot] secure_boot`.
fn secureBootFile(c: *const config.Config, f: *const facts.Facts) ?DesiredFile {
    return menuFile(c.boot.secure_boot, f, .{ .path = secureboot.config_path, .content = secureboot.config_content, .cause = "boot.secure_boot", .reboot = secure_boot_reboot });
}

/// `file`, which tells os's boot menu how to boot a root, when `key` is
/// on and os writes the menu: in a root running a generation, or one
/// being built, where mounts say nothing (no root filesystem in facts).
/// a machine without generations boots the way it always has, so there
/// the key only brings its package. the next menu reads it, so a change
/// waits for a reboot.
fn menuFile(key: ?config.Val(bool), f: *const facts.Facts, file: DesiredFile) ?DesiredFile {
    const v = key orelse return null;
    if (!v.v) return null;
    if (f.boot.root_fs != null and !generation.running(f.boot.root_subvol)) return null;
    var out = file;
    out.src = v.src;
    return out;
}

/// what the observer should look at for this config: every file it might
/// want or os may have generated, and the repositories' signing keys.
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
    return .{ .files = try filePaths(a, c), .keys = keys.items, .secrets = names.items, .secret_files = secret_files.items };
}

fn filePaths(a: Allocator, c: *const config.Config) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try desiredFiles(a, c, &.{})) |d| try out.append(a, d.path);
    for (generated_paths) |p| {
        if (!lists.contains(out.items, p)) try out.append(a, p);
    }
    return out.items;
}

// -- output --

/// the room on the esp a plan's new boot files take.
pub const EspNeed = struct {
    /// bytes, estimated.
    need: u64,
    /// older generations keep copies of their boot files there, which
    /// `os gc` frees.
    collectable: bool,
};

/// an estimate of the room on the esp the next generation's new boot
/// files take, or null if the plan puts none there or there's nothing to
/// go by. installed file sizes aren't in the lock, so it goes by the boot
/// files the running root has now, a sixteenth bigger: a kernel the plan
/// changes gets a new kernel and initramfs, one it adds gets a pair like
/// the largest there, an initramfs change gets every initramfs new, and a
/// microcode change the microcode images too. limine and systemd-boot, and
/// any bootloader on a luks root, keep every generation's copies side by
/// side, so those add up. with the esp
/// at /boot, the first good boot also puts them over the running ones
/// there, one at a time.
///
/// with `uki_on`, the next generation boots unified kernel images, which
/// are on the esp for every bootloader: each kernel the plan touches gets
/// an image as big as its kernel, initramfs, and microcode together, plus
/// the stub. turning `[boot] uki` on or off makes every kernel's boot
/// files new.
pub fn espNeed(p: *const Plan, b: *const facts.Boot, uki_on: bool) ?EspNeed {
    if (!generation.running(b.root_subvol)) return null;
    const esp = b.esp orelse return null;
    if (menu.Loader.of(b.*) == null) return null;
    const hashed = menu.copiesOnEsp(b.*) or uki_on;
    const in_place = std.mem.eql(u8, esp, "/boot");
    if (!hashed and !in_place) return null;

    var initramfs = false;
    var microcode = false;
    var every = false;
    // systemd brings the stub, which every image starts with.
    var stub = false;
    for (p.changes) |c| {
        const r = c.reboot orelse continue;
        if (std.mem.eql(u8, r, "initramfs") or std.mem.eql(u8, r, "microcode")) initramfs = true;
        if (std.mem.eql(u8, r, "microcode")) microcode = true;
        if (std.mem.eql(u8, r, uki_reboot)) every = true;
        if (std.mem.eql(u8, r, "systemd")) stub = true;
    }
    // the files the plan changes, and every file, for a menu that stops
    // booting images and needs copies of them all again.
    var est: Estimate = .{};
    var all: Estimate = .{};
    var images: Estimate = .{};
    var largest: [2]u64 = .{ 0, 0 };
    var ucode: u64 = 0;
    for (b.boot_files) |f| {
        all.add(f.size, f.size);
        if (kernelOf(f.name)) |k| {
            const i: usize = if (std.mem.startsWith(u8, f.name, "vmlinuz-")) 0 else 1;
            largest[i] = @max(largest[i], f.size);
            if ((i == 1 and initramfs) or kernelChanges(p, k)) est.add(f.size, f.size);
        } else {
            ucode += f.size;
            if (microcode) est.add(f.size, f.size);
        }
    }
    if (uki_on) {
        for (b.boot_files) |f| {
            if (!std.mem.startsWith(u8, f.name, "vmlinuz-")) continue;
            const k = f.name["vmlinuz-".len..];
            if (every or stub or initramfs or kernelChanges(p, k)) images.add(f.size + initramfsSize(b, k) + ucode + uki.stub_size, 0);
        }
    }
    for (p.changes) |c| {
        if (c.op != .add or !std.mem.eql(u8, c.reboot orelse "", "kernel")) continue;
        if (hasKernel(b, c.subject)) continue;
        for ([_]*Estimate{ &est, &all }) |e| {
            e.add(largest[0], 0);
            e.add(largest[1], 0);
        }
        if (uki_on) images.add(largest[0] + largest[1] + ucode + uki.stub_size, 0);
    }
    const copies = if (uki_on) images.total else if (every) all.total else est.total;
    const need = (if (hashed) copies else 0) + (if (in_place) est.growth + est.lead else 0);
    if (need == 0) return null;
    return .{ .need = need, .collectable = hashed };
}

/// the size of kernel `kernel`'s initramfs among the boot files, 0 if it
/// has none.
fn initramfsSize(b: *const facts.Boot, kernel: []const u8) u64 {
    for (b.boot_files) |f| {
        if (!std.mem.startsWith(u8, f.name, "initramfs-")) continue;
        if (std.mem.eql(u8, kernelOf(f.name) orelse continue, kernel)) return f.size;
    }
    return 0;
}

/// whether the generation a plan makes boots unified kernel images: the
/// plan writes the ukify config, or keeps the one there.
pub fn ukiAfter(p: *const Plan, f: *const facts.Facts) bool {
    for (p.changes) |c| {
        if (c.kind == .file and std.mem.eql(u8, c.subject, uki.config_path)) return c.op != .remove;
    }
    return f.file(uki.config_path) != null;
}

/// new boot files, as `espNeed` adds them up.
const Estimate = struct {
    /// all of them.
    total: u64 = 0,
    /// what each adds over the file it replaces.
    growth: u64 = 0,
    /// the most any one takes beyond that while it's copied in beside
    /// the file it replaces.
    lead: u64 = 0,

    fn add(e: *Estimate, now: u64, replaces: u64) void {
        const size = now +| now / 16;
        const grows = size -| replaces;
        e.total +|= size;
        e.growth +|= grows;
        e.lead = @max(e.lead, size - grows);
    }
};

/// the kernel a boot file belongs to: "linux" for vmlinuz-linux and
/// initramfs-linux.img. null for microcode.
fn kernelOf(name: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, name, "vmlinuz-")) return name["vmlinuz-".len..];
    if (std.mem.startsWith(u8, name, "initramfs-") and std.mem.endsWith(u8, name, ".img")) return name["initramfs-".len .. name.len - ".img".len];
    return null;
}

fn hasKernel(b: *const facts.Boot, kernel: []const u8) bool {
    for (b.boot_files) |f| {
        if (std.mem.startsWith(u8, f.name, "vmlinuz-") and std.mem.eql(u8, f.name["vmlinuz-".len..], kernel)) return true;
    }
    return false;
}

/// whether the plan installs or upgrades the kernel package `kernel`.
fn kernelChanges(p: *const Plan, kernel: []const u8) bool {
    for (p.changes) |c| {
        if (c.op != .remove and std.mem.eql(u8, c.reboot orelse "", "kernel") and std.mem.eql(u8, c.subject, kernel)) return true;
    }
    return false;
}

/// refuses, with a diagnostic, a plan whose new boot files won't fit on
/// the esp, so nothing gets built only to be thrown away. returns whether
/// the plan can go ahead. the record step checks again with the real
/// files.
pub fn checkEsp(a: Allocator, p: *const Plan, f: *const facts.Facts, diags: *diag.List) !bool {
    const b = &f.boot;
    const uki_on = ukiAfter(p, f);
    var e = espNeed(p, b, uki_on) orelse EspNeed{ .need = 0, .collectable = true };
    e.need +|= try resignRoom(a, p, f, uki_on);
    e.need +|= embeddedRoom(p, f, uki_on);
    if (e.need == 0) return true;
    const free = b.esp_free orelse return true;
    if (generation.fits(e.need, free)) return true;
    const mib = 1 << 20;
    const of = if (b.esp_size) |s| try std.fmt.allocPrint(a, " of {d} MiB", .{s / mib}) else "";
    const hint = if (e.collectable) try generation.gcHint(a, b.generations, b.root_subvol orelse "") else generation.manual_hint;
    try diags.add(.esp_full, null, "the esp at {s} has {d} MiB free{s}, and this plan's new boot files need about {d} MiB", .{ b.esp.?, free / mib, of, (e.need + mib - 1) / mib }, hint);
    return false;
}

/// the room the menu written after a plan takes to sign an image on the
/// esp that has no signature from sbctl's db key yet: a signed copy goes
/// in beside it, one at a time, so it's the largest image, sized like a
/// new one. 0 when the menu won't sign, boots no images, or none on the
/// esp lack a signature.
fn resignRoom(a: Allocator, p: *const Plan, f: *const facts.Facts, uki_on: bool) !u64 {
    const b = &f.boot;
    if (p.changes.len == 0 or !uki_on or !generation.running(b.root_subvol)) return 0;
    const esp = b.esp orelse return 0;
    if (!signsAfter(p, f) or (try secureboot.ours(a, b.unsigned, esp)).len == 0) return 0;
    return largestImage(b);
}

/// the room the largest signed image takes, from the running root's boot
/// files, a sixteenth bigger, like a new one. os builds its initramfs, so
/// that counts with a little to spare (see uki.signedInitramfs).
fn largestImage(b: *const facts.Boot) u64 {
    var kernel: u64 = 0;
    var initramfs: u64 = 0;
    var ucode: u64 = 0;
    for (b.boot_files) |file| {
        if (std.mem.startsWith(u8, file.name, "vmlinuz-")) {
            kernel = @max(kernel, file.size);
        } else if (kernelOf(file.name) != null) {
            initramfs = @max(initramfs, file.size);
        } else ucode +|= file.size;
    }
    var e: Estimate = .{};
    e.add(kernel +| uki.signedInitramfs(initramfs) +| ucode +| uki.stub_size, 0);
    return e.total;
}

/// the room images with their command lines in them take, beyond what
/// `espNeed` counts, when the menu written after a plan signs (see
/// gens.Machine.ukiName): each entry has its own image then. the
/// generation before the new one moves to an entry with a command line of
/// its own, so it gets a new image. a plan that changes the boot files
/// gives the trial its twin of the new one, and counts the new one again
/// at its signed size, which espNeed doesn't. one that starts signing
/// gives every generation's entry, and the trial's, a new image.
fn embeddedRoom(p: *const Plan, f: *const facts.Facts, uki_on: bool) u64 {
    const b = &f.boot;
    if (p.changes.len == 0 or !uki_on or !generation.running(b.root_subvol) or b.esp == null) return 0;
    if (!signsAfter(p, f)) return 0;
    const signs_now = secureboot.enforcedWithKeys(b.secure_boot, b.sbctl_keys) or f.file(secureboot.config_path) != null;
    // the new generation's, the ones already there, and the trial's.
    if (!signs_now) return largestImage(b) *| (b.generations.len + 2);
    var images: u64 = 1;
    for (p.changes) |c| {
        if (c.reboot != null and bootFilesChange(c.reboot.?)) {
            images += 2;
            break;
        }
    }
    return largestImage(b) *| images;
}

/// whether a change for this reboot reason makes new boot files, and so
/// new images.
fn bootFilesChange(reason: []const u8) bool {
    for ([_][]const u8{ "kernel", "initramfs", "microcode", "systemd", uki_reboot }) |r| {
        if (std.mem.eql(u8, reason, r)) return true;
    }
    return false;
}

/// whether the menu written after a plan signs what it boots: the
/// generation it makes or the running one has the secure boot file, or
/// the firmware enforces secure boot and sbctl has keys (see
/// gens.Machine.signs). a plan that removes the file still signs once,
/// since the running root has it.
fn signsAfter(p: *const Plan, f: *const facts.Facts) bool {
    if (secureboot.enforcedWithKeys(f.boot.secure_boot, f.boot.sbctl_keys)) return true;
    for (p.changes) |c| {
        if (c.kind == .file and std.mem.eql(u8, c.subject, secureboot.config_path)) return true;
    }
    return f.file(secureboot.config_path) != null;
}

/// refuses, with a diagnostic, a plan for a machine with generations
/// whose config signs images for secure boot, when sbctl has no keys to
/// sign them with. os never makes or enrolls keys itself. returns whether
/// the plan can go ahead.
pub fn checkSecureBoot(c: *const config.Config, f: *const facts.Facts, diags: *diag.List) !bool {
    const v = c.boot.secure_boot orelse return true;
    if (!v.v or f.boot.sbctl_keys or !generation.running(f.boot.root_subvol)) return true;
    try diags.add(.secure_boot_keys, v.src, "secure_boot is on, but sbctl has no keys in {s} to sign with", .{secureboot.keys_dir}, "run `sbctl create-keys`, then plan again. enroll the keys only once a generation with signed images is ready");
    return false;
}

/// refuses, with a diagnostic, a plan that removes os's drop-in that
/// unlocks a luks root while mkinitcpio's own hooks don't: the initramfs
/// built after it couldn't open the root, and without generations
/// nothing would boot. returns whether the plan can go ahead.
pub fn checkLuks(c: *const config.Config, p: *const Plan, f: *const facts.Facts, diags: *diag.List) !bool {
    if (f.boot.luks_uuid == null or facts.hasEncryptHook(f.boot.initramfs_hooks)) return true;
    if (c.providers.get("initramfs")) |pr| {
        if (!std.mem.eql(u8, pr.v, "mkinitcpio")) return true;
    }
    for (p.changes) |ch| {
        if (ch.kind != .file or ch.op != .remove or !std.mem.eql(u8, ch.subject, encrypt_initramfs_path)) continue;
        const src = if (c.boot.encrypt) |e| e.src else null;
        try diags.add(.luks_locked, src, "the root is on luks, and without [boot] encrypt nothing in the initramfs would unlock it", .{}, "keep `encrypt = true` under [boot], or add sd-encrypt to HOOKS in /etc/mkinitcpio.conf first");
        return false;
    }
    return true;
}

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
    var shown: usize = 0;
    for (p.changes) |c| {
        if ((c.kind != .package and c.kind != .dependency) or c.op != .change or !notable(c)) continue;
        if (shown < max_notable) {
            try w.print("  {s:<9}{s} {s} -> {s}\n", .{ if (shown == 0) "notable" else "", c.subject, c.from.?, c.to.? });
        }
        shown += 1;
    }
    if (shown > max_notable) try w.print("           and {d} more\n", .{shown - max_notable});
}

/// enough to see what matters and still fit the screen with the news and
/// the prompt.
const max_notable = 8;

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
    try output.writeDoc(w, schema, doc);
}

// -- tests --

test "a mkinitcpio drop-in waits for a reboot, written or removed" {
    try testing.expectEqualStrings("initramfs", fileReboot("/etc/mkinitcpio.conf.d/50-local.conf").?);
    try testing.expectEqual(null, fileReboot("/etc/mkinitcpio.conf.dx/a.conf"));
    try testing.expectEqual(null, fileReboot("/etc/motd"));
}

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
    try testing.expectEqualStrings(sysctl_path, p.changes[3].subject);
    try testing.expectEqualStrings("sysctl", p.changes[3].cause.?);

    const sysctl = (try desiredFiles(t.a(), &c, &f))[3];
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

test "nvidia's initramfs drop-in, unless the machine loads the modules already" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("[boot]\nkernel = \"none\"\n[hardware]\ngpu = \"nvidia\"\n");
    const without: facts.Facts = .{};
    const want = try desiredFiles(t.a(), &c, &without);
    try testing.expectEqual(1, want.len);
    try testing.expectEqualStrings(nvidia_initramfs_path, want[0].path);
    try testing.expectEqualStrings("initramfs", want[0].reboot.?);

    const with: facts.Facts = .{ .initramfs_modules = &.{ "nvidia", "nvidia_modeset", "nvidia_uvm", "nvidia_drm" } };
    try testing.expectEqual(0, (try desiredFiles(t.a(), &c, &with)).len);

    const booster = try t.cfg("[boot]\nkernel = \"none\"\n[hardware]\ngpu = \"nvidia\"\n[providers]\ninitramfs = \"booster\"\n");
    try testing.expectEqual(0, (try desiredFiles(t.a(), &booster, &without)).len);
}

test "the drop-in that unlocks a luks root, unless the hooks do already" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("[boot]\nkernel = \"none\"\nencrypt = true\n");
    // mkinitcpio's own hooks, as a clean build starts with.
    const plain: facts.Facts = .{ .boot = .{ .initramfs_hooks = &.{ "base", "systemd", "autodetect", "microcode", "modconf", "kms", "keyboard", "sd-vconsole", "block", "filesystems", "fsck" } } };
    const want = try desiredFiles(t.a(), &c, &plain);
    try testing.expectEqual(1, want.len);
    try testing.expectEqualStrings("/etc/mkinitcpio.conf.d/90-yoq-encrypt.conf", want[0].path);
    try testing.expectEqualStrings("initramfs", want[0].reboot.?);
    try testing.expectEqualStrings("boot.encrypt", want[0].cause.?);
    try testing.expect(std.mem.startsWith(u8, want[0].content, "# written by os from [boot] encrypt in the config."));
    try testing.expect(std.mem.indexOf(u8, want[0].content, "    filesystems)\n") != null);
    try testing.expect(std.mem.indexOf(u8, want[0].content, "_yoq_hooks+=(sd-encrypt)\n") != null);
    // autodetect finding no modules for a driver built into the kernel
    // isn't a failed build.
    try testing.expect(std.mem.indexOf(u8, want[0].content, "_yoq_add_checked_modules \"$@\" || true\n") != null);

    // busybox's encrypt, as an older archinstall sets up, or sd-encrypt.
    const unlocking = [_][]const []const u8{ &.{ "base", "udev", "encrypt", "filesystems" }, &.{ "base", "systemd", "sd-encrypt", "filesystems" } };
    for (unlocking) |hooks| {
        const ready: facts.Facts = .{ .boot = .{ .initramfs_hooks = hooks } };
        try testing.expectEqual(0, (try desiredFiles(t.a(), &c, &ready)).len);
    }
    const off = try t.cfg("[boot]\nkernel = \"none\"\nencrypt = false\n");
    try testing.expectEqual(0, (try desiredFiles(t.a(), &off, &plain)).len);
    const booster = try t.cfg("[boot]\nkernel = \"none\"\nencrypt = true\n[providers]\ninitramfs = \"booster\"\n");
    try testing.expectEqual(0, (try desiredFiles(t.a(), &booster, &plain)).len);
}

test "[boot] uki brings ukify, and its config where os writes the menu" {
    var t: T = .{};
    defer t.deinit();
    const a = t.a();
    const c = try t.cfg("[boot]\nkernel = \"none\"\nuki = true\n");
    const w = findWant(try wants(a, &c), "systemd-ukify").?;
    try testing.expectEqualStrings("boot.uki", w.cause.?);

    const on_gens: facts.Facts = .{ .boot = .{ .root_fs = "btrfs", .root_subvol = "/@roots/3" } };
    const want = try desiredFiles(a, &c, &on_gens);
    try testing.expectEqual(1, want.len);
    try testing.expectEqualStrings("/etc/kernel/yoq-uki.conf", want[0].path);
    try testing.expectEqualStrings("uki", want[0].reboot.?);
    try testing.expect(std.mem.startsWith(u8, want[0].content, "# written by os from [boot] uki in the config."));
    // a root being built, where mounts say nothing, gets it too.
    try testing.expectEqual(1, (try desiredFiles(a, &c, &.{})).len);
    // without generations, os writes no menu.
    for ([_]facts.Boot{ .{ .root_fs = "ext4" }, .{ .root_fs = "btrfs", .root_subvol = "/@" } }) |b| {
        try testing.expectEqual(0, (try desiredFiles(a, &c, &.{ .boot = b })).len);
    }
    const off = try t.cfg("[boot]\nkernel = \"none\"\nuki = false\n");
    try testing.expectEqual(null, findWant(try wants(a, &off), "systemd-ukify"));
    try testing.expectEqual(0, (try desiredFiles(a, &off, &on_gens)).len);

    // turning it off takes os's config out, which needs a reboot too.
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{} };
    var files = [_]facts.File{.{ .path = "/etc/kernel/yoq-uki.conf", .sha256 = &facts.sha256Hex(uki.config_content), .mode = "0644", .ours = true }};
    const had: facts.Facts = .{ .files = &files, .boot = on_gens.boot };
    const p = (try plan(a, &off, &l, &had, &t.diags)).?;
    try testing.expectEqual(1, p.changes.len);
    try testing.expectEqual(Op.remove, p.changes[0].op);
    try testing.expectEqualStrings("uki", p.changes[0].reboot.?);
    try testing.expect(!ukiAfter(&p, &had));
    try testing.expect(ukiAfter(&.{ .changes = &.{} }, &had));
    // left on, the config there is the one it wants.
    const with: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{lockPkg("systemd-ukify", "258-1", &.{})} };
    for ((try plan(a, &c, &with, &had, &t.diags)).?.changes) |ch| try testing.expect(ch.kind != .file);
}

test "[boot] secure_boot brings sbctl, and its file where os writes the menu" {
    var t: T = .{};
    defer t.deinit();
    const a = t.a();
    const c = try t.cfg("[boot]\nkernel = \"none\"\nuki = true\nsecure_boot = true\n");
    try testing.expectEqualStrings("boot.secure_boot", findWant(try wants(a, &c), "sbctl").?.cause.?);
    const on_gens: facts.Facts = .{ .boot = .{ .root_fs = "btrfs", .root_subvol = "/@roots/3", .sbctl_keys = true } };
    const want = try desiredFiles(a, &c, &on_gens);
    try testing.expectEqual(2, want.len);
    try testing.expectEqualStrings("/etc/kernel/yoq-secure-boot.conf", want[1].path);
    try testing.expectEqualStrings("secure boot", want[1].reboot.?);
    try testing.expect(std.mem.startsWith(u8, want[1].content, "# written by os from [boot] secure_boot in the config."));
    try testing.expectEqual(0, (try desiredFiles(a, &c, &.{ .boot = .{ .root_fs = "ext4" } })).len);

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

test "turning encrypt off stops the plan when nothing else would unlock a luks root" {
    var t: T = .{};
    defer t.deinit();
    const a = t.a();
    var files = [_]facts.File{.{ .path = encrypt_initramfs_path, .sha256 = &facts.sha256Hex(encrypt_initramfs_content), .mode = "0644", .ours = true }};
    const hooks = [_][]const u8{ "base", "systemd", "autodetect", "block", "filesystems" };
    const luks: facts.Facts = .{ .files = &files, .boot = .{ .luks_uuid = "0f7a1c2e", .encrypt_dropin = true, .initramfs_hooks = &hooks } };
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{} };
    for ([_][]const u8{ "[boot]\nkernel = \"none\"\n", "[boot]\nkernel = \"none\"\nencrypt = false\n" }) |text| {
        const off = try t.cfg(text);
        const p = (try plan(a, &off, &l, &luks, &t.diags)).?;
        try testing.expect(!try checkLuks(&off, &p, &luks, &t.diags));
        try testing.expectEqual(diag.Code.luks_locked, t.diags.items.items[t.diags.items.items.len - 1].code);
        // a root that isn't on luks, hooks that unlock it themselves, or
        // another initramfs generator: the drop-in can go.
        var plain = luks;
        plain.boot.luks_uuid = null;
        try testing.expect(try checkLuks(&off, &p, &plain, &t.diags));
        var hooked = luks;
        hooked.boot.initramfs_hooks = &.{ "base", "systemd", "sd-encrypt", "filesystems" };
        try testing.expect(try checkLuks(&off, &p, &hooked, &t.diags));
    }
    const booster = try t.cfg("[boot]\nkernel = \"none\"\n[providers]\ninitramfs = \"booster\"\n");
    try testing.expect(try checkLuks(&booster, &(try plan(a, &booster, &l, &luks, &t.diags)).?, &luks, &t.diags));
    // left on, nothing is removed.
    const on = try t.cfg("[boot]\nkernel = \"none\"\nencrypt = true\n");
    try testing.expect(try checkLuks(&on, &(try plan(a, &on, &l, &luks, &t.diags)).?, &luks, &t.diags));
}

test "secure boot without sbctl's keys stops the plan" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("[boot]\nkernel = \"none\"\nuki = true\nsecure_boot = true\n");
    try testing.expect(try checkSecureBoot(&c, &.{ .boot = .{ .root_fs = "btrfs", .root_subvol = "/@roots/3", .sbctl_keys = true } }, &t.diags));
    // without generations, nothing is signed, so nothing needs keys.
    try testing.expect(try checkSecureBoot(&c, &.{ .boot = .{ .root_fs = "ext4" } }, &t.diags));
    try testing.expectEqual(0, t.diags.items.items.len);
    try testing.expect(!try checkSecureBoot(&c, &.{ .boot = .{ .root_fs = "btrfs", .root_subvol = "/@roots/3" } }, &t.diags));
    try testing.expectEqual(1, t.diags.items.items.len);
    const d = t.diags.items.items[0];
    try testing.expectEqual(diag.Code.secure_boot_keys, d.code);
    try testing.expectEqualStrings("secure_boot is on, but sbctl has no keys in /var/lib/sbctl/keys to sign with", d.message);
    try testing.expect(std.mem.startsWith(u8, d.hint.?, "run `sbctl create-keys`"));
    const off = try t.cfg("[boot]\nkernel = \"none\"\nuki = true\nsecure_boot = false\n");
    try testing.expect(try checkSecureBoot(&off, &.{ .boot = .{ .root_fs = "btrfs", .root_subvol = "/@roots/3" } }, &t.diags));
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
    try writeText(&out.writer, t.a(), &p, .{});
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
    const want = try desiredFiles(t.a(), &c, &.{});
    try testing.expectEqual(1, want.len);
    try testing.expectEqualStrings("/etc/profile.d/yoq-session.sh", want[0].path);
    try testing.expect(std.mem.indexOf(u8, want[0].content, "exec uwsm start hyprland.desktop\n") != null);
}

test "the session's own config lands where hyprland looks without a user one" {
    var t: T = .{};
    defer t.deinit();
    var c = try t.cfg("[desktop]\nsession = \"hyprland\"\nsession_config = \"files/hyprland.lua\"\n");
    c.desktop.session_content = "-- mine\n";
    const want = try desiredFiles(t.a(), &c, &.{});
    try testing.expectEqual(1, want.len);
    try testing.expectEqualStrings("/etc/xdg/hypr/hyprland.lua", want[0].path);
    try testing.expectEqualStrings("-- mine\n", want[0].content);
}

test "kernel modules to load at boot" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("[boot]\nmodules = [\"nct6775\", \"i2c-dev\"]\n");
    const want = try desiredFiles(t.a(), &c, &.{});
    try testing.expectEqual(1, want.len);
    try testing.expectEqualStrings(modules_path, want[0].path);
    try testing.expectEqualStrings("# written by os from [boot] modules in the config. edits here are overwritten.\ni2c-dev\nnct6775\n", want[0].content);
}

test "a file os generated goes when nothing asks for it, but one it didn't write stays" {
    var t: T = .{};
    defer t.deinit();
    const c = try t.cfg("[boot]\nkernel = \"none\"\n");
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{} };
    var files = [_]facts.File{
        .{ .path = sysctl_path, .sha256 = "x", .mode = "0644", .ours = true },
        .{ .path = greetd_config_path, .sha256 = "y", .mode = "0644", .ours = false },
    };
    const f: facts.Facts = .{ .files = &files };
    const p = (try plan(t.a(), &c, &l, &f, &t.diags)).?;
    try testing.expectEqual(1, p.changes.len);
    try testing.expectEqual(Op.remove, p.changes[0].op);
    try testing.expectEqualStrings(sysctl_path, p.changes[0].subject);
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
    try writeText(&out.writer, t.a(), &p, .{});
    try testing.expectEqualStrings(
        \\files
        \\  + /etc/pacman.d/yoq-repos.conf: write, mode 0644  (repos)
        \\repositories
        \\  ~ /etc/pacman.conf: add Include = /etc/pacman.d/yoq-repos.conf  (repos)
        \\keys
        \\  + EF925EA60F33D0CB85C44AD13056513887B78AEB: import and trust  (repos.chaotic-aur)
        \\
        \\plan: 2 to add, 1 to change, 0 to remove · no reboot
        \\
    , out.written());
    const want = try desiredFiles(t.a(), &c, &.{});
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

test "how much room a plan's new boot files take on the esp" {
    const mib = 1 << 20;
    const files = [_]facts.BootFile{
        .{ .name = "amd-ucode.img", .size = 4 * mib },
        .{ .name = "initramfs-linux.img", .size = 32 * mib },
        .{ .name = "vmlinuz-linux", .size = 16 * mib },
    };
    var b: facts.Boot = .{ .esp = "/efi", .loader = "systemd-boot", .root_subvol = "/@roots/3", .boot_files = &files };
    const upgrade: Plan = .{ .changes = &.{.{ .op = .change, .kind = .package, .subject = "linux", .from = "6.16.8", .to = "6.17.1", .reboot = "kernel" }} };
    // limine and systemd-boot keep the new pair beside the old one.
    try testing.expectEqual(EspNeed{ .need = 51 * mib, .collectable = true }, espNeed(&upgrade, &b, false).?);
    const lts: Plan = .{ .changes = &.{.{ .op = .add, .kind = .package, .subject = "linux-lts", .to = "6.12.48", .reboot = "kernel" }} };
    try testing.expectEqual(51 * mib, espNeed(&lts, &b, false).?.need);
    const ucode: Plan = .{ .changes = &.{.{ .op = .change, .kind = .package, .subject = "amd-ucode", .from = "1", .to = "2", .reboot = "microcode" }} };
    try testing.expectEqual(38 * mib + mib / 4, espNeed(&ucode, &b, false).?.need);
    const drop_in: Plan = .{ .changes = &.{.{ .op = .add, .kind = .file, .subject = "/etc/mkinitcpio.conf.d/10-yoq-nvidia.conf", .reboot = "initramfs" }} };
    try testing.expectEqual(34 * mib, espNeed(&drop_in, &b, false).?.need);
    // nothing new to boot, or a kernel that goes.
    const tool: Plan = .{ .changes = &.{.{ .op = .add, .kind = .package, .subject = "ripgrep", .to = "14" }} };
    try testing.expectEqual(null, espNeed(&tool, &b, false));
    const gone: Plan = .{ .changes = &.{.{ .op = .remove, .kind = .package, .subject = "linux", .from = "6.16.8", .reboot = "kernel" }} };
    try testing.expectEqual(null, espNeed(&gone, &b, false));

    // with the esp at /boot, a good boot also puts them over the running
    // ones, one at a time: the growth, and the largest while it's copied.
    b.esp = "/boot";
    try testing.expectEqual(EspNeed{ .need = (51 + 35) * mib, .collectable = true }, espNeed(&upgrade, &b, false).?);
    b.loader = "grub";
    try testing.expectEqual(EspNeed{ .need = 35 * mib, .collectable = false }, espNeed(&upgrade, &b, false).?);
    // grub and refind read each root's kernel over btrfs.
    b.esp = "/efi";
    try testing.expectEqual(null, espNeed(&upgrade, &b, false));
    b.loader = "refind";
    try testing.expectEqual(null, espNeed(&upgrade, &b, false));
    // unless the root is on luks: then they can't, and boot copies on the
    // esp like limine.
    b.luks_uuid = "0f7a1c2e-9b3d-4e5f-8a6b-7c8d9e0f1a2b";
    try testing.expectEqual(EspNeed{ .need = 51 * mib, .collectable = true }, espNeed(&upgrade, &b, false).?);
    // without generations, pacman changes the files in place, as always.
    b = .{ .esp = "/boot", .loader = "systemd-boot", .root_subvol = "/@", .boot_files = &files };
    try testing.expectEqual(null, espNeed(&upgrade, &b, false));
    // no boot files to go by.
    b = .{ .esp = "/efi", .loader = "limine", .root_subvol = "/@roots/3" };
    try testing.expectEqual(null, espNeed(&upgrade, &b, false));
}

test "unified kernel images on the esp take a kernel's files together" {
    const mib = 1 << 20;
    const k = 16 * mib - uki.stub_size;
    const files = [_]facts.BootFile{
        .{ .name = "amd-ucode.img", .size = 4 * mib },
        .{ .name = "initramfs-linux.img", .size = 28 * mib },
        .{ .name = "vmlinuz-linux", .size = k },
    };
    // 4 + 28 + 16 MiB with the stub, and a sixteenth: 51 MiB an image.
    var b: facts.Boot = .{ .esp = "/efi", .loader = "grub", .root_subvol = "/@roots/3", .boot_files = &files };
    const upgrade: Plan = .{ .changes = &.{.{ .op = .change, .kind = .package, .subject = "linux", .from = "6.16.8", .to = "6.17.1", .reboot = "kernel" }} };
    // grub reads the roots, but images are on the esp for every bootloader.
    try testing.expectEqual(null, espNeed(&upgrade, &b, false));
    try testing.expectEqual(EspNeed{ .need = 51 * mib, .collectable = true }, espNeed(&upgrade, &b, true).?);
    const drop_in: Plan = .{ .changes = &.{.{ .op = .add, .kind = .file, .subject = "/etc/mkinitcpio.conf.d/10-yoq-nvidia.conf", .reboot = "initramfs" }} };
    try testing.expectEqual(51 * mib, espNeed(&drop_in, &b, true).?.need);
    const lts: Plan = .{ .changes = &.{.{ .op = .add, .kind = .package, .subject = "linux-lts", .to = "6.12.48", .reboot = "kernel" }} };
    try testing.expectEqual(51 * mib, espNeed(&lts, &b, true).?.need);
    const tool: Plan = .{ .changes = &.{.{ .op = .add, .kind = .package, .subject = "ripgrep", .to = "14" }} };
    try testing.expectEqual(null, espNeed(&tool, &b, true));
    // a new systemd brings a new stub, and every image is new.
    const systemd: Plan = .{ .changes = &.{.{ .op = .change, .kind = .package, .subject = "systemd", .from = "258-1", .to = "258-2", .reboot = "systemd" }} };
    try testing.expectEqual(51 * mib, espNeed(&systemd, &b, true).?.need);
    try testing.expectEqual(null, espNeed(&systemd, &b, false));
    // turning them on makes every kernel's image.
    const on: Plan = .{ .changes = &.{.{ .op = .add, .kind = .file, .subject = uki.config_path, .reboot = uki_reboot }} };
    try testing.expectEqual(51 * mib, espNeed(&on, &b, true).?.need);
    // turning them off on systemd-boot needs copies of every file again.
    b.loader = "systemd-boot";
    const off: Plan = .{ .changes = &.{.{ .op = .remove, .kind = .file, .subject = uki.config_path, .reboot = uki_reboot }} };
    try testing.expectEqual(34 * mib + k + k / 16, espNeed(&off, &b, false).?.need);
    b.loader = "grub";
    try testing.expectEqual(null, espNeed(&off, &b, false));
    // with the esp at /boot, a good boot puts the files there as before.
    b.esp = "/boot";
    try testing.expectEqual(EspNeed{ .need = 51 * mib + 28 * mib + 28 * mib / 16 + k / 16, .collectable = true }, espNeed(&upgrade, &b, true).?);
}

test "a plan whose boot files don't fit on the esp stops before anything is built" {
    var t: T = .{};
    defer t.deinit();
    const a = t.a();
    const mib = 1 << 20;
    const files = [_]facts.BootFile{
        .{ .name = "initramfs-linux.img", .size = 32 * mib },
        .{ .name = "vmlinuz-linux", .size = 16 * mib },
    };
    const gens = [_]facts.Generation{
        .{ .n = 1, .root = "@roots/1" },
        .{ .n = 2, .root = "@roots/1" },
        .{ .n = 3, .root = "@roots/3" },
    };
    var f: facts.Facts = .{ .boot = .{ .esp = "/efi", .loader = "limine", .root_subvol = "/@roots/3", .esp_free = 40 * mib, .esp_size = 512 * mib, .boot_files = &files, .generations = &gens } };
    const upgrade: Plan = .{ .changes = &.{.{ .op = .change, .kind = .package, .subject = "linux", .from = "6.16.8", .to = "6.17.1", .reboot = "kernel" }} };
    try testing.expect(!try checkEsp(a, &upgrade, &f, &t.diags));
    const d = t.diags.items.items[0];
    try testing.expectEqual(diag.Code.esp_full, d.code);
    try testing.expectEqualStrings("the esp at /efi has 40 MiB free of 512 MiB, and this plan's new boot files need about 51 MiB", d.message);
    try testing.expectEqualStrings("`os gc --keep 1` removes generation 2, with the boot files only it uses", d.hint.?);

    // grub with the esp at /boot: removing generations frees nothing there.
    f.boot.esp = "/boot";
    f.boot.loader = "grub";
    f.boot.esp_free = 20 * mib;
    f.boot.esp_size = null;
    try testing.expect(!try checkEsp(a, &upgrade, &f, &t.diags));
    try testing.expectEqualStrings("the esp at /boot has 20 MiB free, and this plan's new boot files need about 35 MiB", t.diags.items.items[1].message);
    try testing.expectEqualStrings(generation.manual_hint, t.diags.items.items[1].hint.?);

    // room enough, with a mebibyte to spare; or no telling how much.
    f.boot.esp_free = 36 * mib;
    try testing.expect(try checkEsp(a, &upgrade, &f, &t.diags));
    f.boot.esp_free = null;
    try testing.expect(try checkEsp(a, &upgrade, &f, &t.diags));
    try testing.expectEqual(2, t.diags.items.items.len);
}

test "signing an image already on the esp needs room beside it" {
    var t: T = .{};
    defer t.deinit();
    const a = t.a();
    const mib = 1 << 20;
    const boot_files = [_]facts.BootFile{
        .{ .name = "initramfs-linux.img", .size = 32 * mib },
        .{ .name = "vmlinuz-linux", .size = 16 * mib },
    };
    var files = [_]facts.File{.{ .path = uki.config_path, .sha256 = &facts.sha256Hex(uki.config_content), .mode = "0644", .ours = true }};
    var f: facts.Facts = .{ .files = &files, .boot = .{
        .esp = "/efi",
        .loader = "grub",
        .root_subvol = "/@roots/3",
        .esp_free = 100 * mib,
        .boot_files = &boot_files,
        .secure_boot = true,
        .sbctl_keys = true,
        .unsigned = &.{"/efi/yoq/boot/0123456789abcdef-yoq.efi"},
    } };
    // a change that brings no new boot files; the menu after it still
    // signs the image, in a copy beside it, and the generation before
    // the new one gets an image with its own command line in it.
    const tool: Plan = .{ .changes = &.{.{ .op = .add, .kind = .package, .subject = "tree", .to = "2.2.1" }} };
    try testing.expect(!try checkEsp(a, &tool, &f, &t.diags));
    try testing.expectEqualStrings("the esp at /efi has 100 MiB free, and this plan's new boot files need about 112 MiB", t.diags.items.items[0].message);
    // with nothing unsigned, or nothing that signs, there's room.
    f.boot.unsigned = &.{"/efi/EFI/BOOT/BOOTX64.EFI"};
    try testing.expect(try checkEsp(a, &tool, &f, &t.diags));
    f.boot.unsigned = &.{"/efi/yoq/boot/0123456789abcdef-yoq.efi"};
    f.boot.secure_boot = false;
    try testing.expect(try checkEsp(a, &tool, &f, &t.diags));
    // the config's key signs too, and an empty plan writes no menu.
    files[0].path = secureboot.config_path;
    var both = [_]facts.File{ .{ .path = uki.config_path, .sha256 = "", .mode = "0644" }, files[0] };
    f.files = &both;
    try testing.expect(!try checkEsp(a, &tool, &f, &t.diags));
    try testing.expect(try checkEsp(a, &.{ .changes = &.{} }, &f, &t.diags));
}

test "with secure boot, each entry's image has its command line, and takes room" {
    const mib = 1 << 20;
    const boot_files = [_]facts.BootFile{
        .{ .name = "initramfs-linux.img", .size = 32 * mib },
        .{ .name = "vmlinuz-linux", .size = 16 * mib },
    };
    // os builds the initramfs for a signed image, with an eighth to spare.
    const now = 16 * mib + 36 * mib + uki.stub_size;
    const image = now + now / 16;
    var files = [_]facts.File{
        .{ .path = uki.config_path, .sha256 = "", .mode = "0644" },
        .{ .path = secureboot.config_path, .sha256 = "", .mode = "0644" },
    };
    const gens = [_]facts.Generation{ .{ .n = 1, .root = "@roots/1" }, .{ .n = 2, .root = "@roots/2" } };
    var f: facts.Facts = .{ .files = &files, .boot = .{ .esp = "/efi", .loader = "grub", .root_subvol = "/@roots/3", .boot_files = &boot_files, .generations = &gens } };
    const tool: Plan = .{ .changes = &.{.{ .op = .add, .kind = .package, .subject = "tree", .to = "2.2.1" }} };
    const upgrade: Plan = .{ .changes = &.{.{ .op = .change, .kind = .package, .subject = "linux", .from = "6.16.8", .to = "6.17.1", .reboot = "kernel" }} };
    // the generation before the new one moves to an entry of its own.
    try testing.expectEqual(image, embeddedRoom(&tool, &f, true));
    // new boot files give the trial a twin of the new image, and the new
    // one counts again at its signed size, besides what espNeed counts.
    try testing.expectEqual(3 * image, embeddedRoom(&upgrade, &f, true));
    // no images, an empty plan, or no signing: nothing.
    try testing.expectEqual(0, embeddedRoom(&tool, &f, false));
    try testing.expectEqual(0, embeddedRoom(&.{ .changes = &.{} }, &f, true));
    f.files = files[0..1];
    try testing.expectEqual(0, embeddedRoom(&tool, &f, true));
    // a plan that starts signing makes every entry's image new: the two
    // generations there, the new one, and the trial's.
    const on: Plan = .{ .changes = &.{.{ .op = .add, .kind = .file, .subject = secureboot.config_path, .reboot = secure_boot_reboot }} };
    try testing.expectEqual(4 * image, embeddedRoom(&on, &f, true));
    // firmware that enforces it, with keys, signs already.
    f.boot.secure_boot = true;
    f.boot.sbctl_keys = true;
    try testing.expectEqual(image, embeddedRoom(&on, &f, true));
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
    try testing.expect(try checkSecrets(&c, &f, &t.diags));

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
    try writeJson(&out.writer, a, &p);
    try writeText(&out.writer, a, &p, .{ .verbose = true });
    for ([_][]const u8{ "hunter2", "hunter3", &facts.sha256Hex("hunter2"), &facts.sha256Hex("hunter3"), &next }) |leak| {
        try testing.expect(std.mem.indexOf(u8, out.written(), leak) == null);
    }

    // without root, nothing can be compared, so nothing differs.
    known[0] = .{ .name = "wifi/home" };
    have[0].sha256 = "";
    try testing.expect((try plan(a, &c, &l, &f, &t.diags)).?.empty());
    try testing.expect(try checkSecrets(&c, &f, &t.diags));

    // not set here: a plan error that says how to set it.
    known[0].state = .missing;
    try testing.expect(!try checkSecrets(&c, &f, &t.diags));
    const d = t.diags.items.items[0];
    try testing.expectEqual(diag.Code.secret_missing, d.code);
    try testing.expectEqualStrings("files.\"/etc/wifi.psk\" needs the secret \"wifi/home\", and this machine doesn't have it", d.message);
    try testing.expectEqualStrings("set it with `os secret set wifi/home`", d.hint.?);
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
