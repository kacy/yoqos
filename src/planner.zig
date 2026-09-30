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
    for (c.aur.items.items) |it| try addWant(a, &out, it.name, "aur", it.src);
    // building aur packages needs devtools' makechrootpkg.
    if (c.aur.items.items.len > 0) try addWant(a, &out, "devtools", "aur", c.aur.items.items[0].src);
    if (c.boot.kernel) |k| {
        if (!std.mem.eql(u8, k.v, catalog.no_kernel)) try addWant(a, &out, k.v, "boot.kernel", k.src);
    } else try addWant(a, &out, catalog.default_kernel, "boot.kernel", null);
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
    try planFiles(a, c, f, &changes);
    if (!try planRepos(a, c, f, &changes, diags)) return null;
    return .{ .changes = changes.items };
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

/// whether the config has repositories of its own for pacman: declared
/// ones, or the local one aur packages are built into.
fn ownRepos(c: *const config.Config) bool {
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
    mode: []const u8 = config.File.default_mode,
    /// the key that makes the file, for ones `[files]` doesn't name.
    cause: ?[]const u8 = null,
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

/// files os writes from other keys, each starting with a "written by os"
/// line. one still there that nothing asks for any more is removed. the
/// session's own config isn't here: it's the user's file.
const generated_paths = [_][]const u8{ sysctl_path, modules_path, greetd_config_path, tty_session_path, nvidia_initramfs_path };

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

/// every file the config wants: `[files]`, then the ones other keys make.
/// nvidia's initramfs drop-in is left out when the machine loads those
/// modules already, as `f` shows.
pub fn desiredFiles(a: Allocator, c: *const config.Config, f: *const facts.Facts) ![]const DesiredFile {
    var out: std.ArrayList(DesiredFile) = .empty;
    for (c.files.entries.items) |e| {
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
    return .{ .path = sysctl_path, .content = text.items, .cause = "sysctl" };
}

fn modulesFile(a: Allocator, c: *const config.Config) !?DesiredFile {
    if (c.boot.modules.items.items.len == 0) return null;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, header("[boot] modules"));
    for (try sortedNames(a, c.boot.modules.items.items)) |n| try text.print(a, "{s}\n", .{n});
    return .{ .path = modules_path, .content = text.items, .cause = "boot.modules" };
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
        .greetd => .{ .path = greetd_config_path, .content = greetd_config, .cause = "desktop.login" },
        .tty => .{
            .path = tty_session_path,
            .content = try std.fmt.allocPrint(a, tty_session, .{catalog.sessionDesktop((c.desktop.session orelse return null).v)}),
            .cause = "desktop.login",
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
    return .{ .path = facts.repos_conf, .content = text.items, .cause = "repos" };
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
    return .{ .path = nvidia_initramfs_path, .content = nvidia_initramfs_content, .cause = "hardware.gpu", .reboot = "initramfs" };
}

/// what the observer should look at for this config: every file it might
/// want or os may have generated, and the repositories' signing keys.
pub fn wanted(a: Allocator, c: *const config.Config) !facts.Wanted {
    var keys: std.ArrayList([]const u8) = .empty;
    for (c.repos.entries.items) |e| {
        if (e.value.key) |k| try keys.append(a, k.v);
    }
    return .{ .files = try filePaths(a, c), .keys = keys.items };
}

fn filePaths(a: Allocator, c: *const config.Config) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try desiredFiles(a, c, &.{})) |d| try out.append(a, d.path);
    for (generated_paths) |p| {
        if (!lists.contains(out.items, p)) try out.append(a, p);
    }
    return out.items;
}

/// files: written when missing or when their content differs, and their
/// mode set when only that differs. files the config doesn't name are
/// left alone.
fn planFiles(a: Allocator, c: *const config.Config, f: *const facts.Facts, changes: *std.ArrayList(Change)) !void {
    const want = try desiredFiles(a, c, f);
    var files: std.ArrayList(Change) = .empty;
    for (want) |d| {
        const mode = try normalMode(a, d.mode);
        var ch: Change = .{
            .op = .change,
            .kind = .file,
            .subject = d.path,
            .cause = d.cause orelse try std.fmt.allocPrint(a, "files.\"{s}\"", .{d.path}),
            .reboot = d.reboot,
        };
        if (f.file(d.path)) |have| {
            if (!std.mem.eql(u8, have.sha256, &facts.sha256Hex(d.content))) {
                ch.to = try std.fmt.allocPrint(a, "rewrite, mode {s}", .{mode});
            } else if (!std.mem.eql(u8, have.mode, mode)) {
                // only the mode: nothing the reboot was for changes.
                ch.from = have.mode;
                ch.to = try std.fmt.allocPrint(a, "mode {s}", .{mode});
                ch.reboot = null;
            } else continue;
        } else {
            ch.op = .add;
            ch.to = try std.fmt.allocPrint(a, "write, mode {s}", .{mode});
        }
        try files.append(a, ch);
    }
    for (generated_paths) |p| {
        if (lists.find(want, "path", p) != null) continue;
        const have = f.file(p) orelse continue;
        if (!have.ours) continue;
        try files.append(a, .{
            .op = .remove,
            .kind = .file,
            .subject = p,
            .to = "remove: os wrote it, and nothing asks for it now",
            .reboot = if (std.mem.eql(u8, p, nvidia_initramfs_path)) "initramfs" else null,
        });
    }
    lists.sortByField(Change, "subject", files.items);
    try changes.appendSlice(a, files.items);
}

/// "644" and "0644" are the same mode; facts write four digits.
fn normalMode(a: Allocator, mode: []const u8) ![]const u8 {
    return if (mode.len == 3) std.fmt.allocPrint(a, "0{s}", .{mode}) else mode;
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

// -- output --

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
    inline for (.{ .{ "system", Kind.setting }, .{ "users", Kind.user }, .{ "services", Kind.unit }, .{ "files", Kind.file }, .{ "repositories", Kind.pacman_conf }, .{ "keys", Kind.key } }) |section| {
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
    var n = [_]usize{ 0, 0, 0 };
    for (p.changes) |c| {
        if (c.kind == .package or c.kind == .dependency) n[@intFromEnum(c.op)] += 1;
    }
    if (n[0] + n[1] + n[2] == 0) return;
    try w.print("packages\n  upgrades {d}    new {d}    removed {d}   (-v lists them)\n", .{ n[1], n[0], n[2] });
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

/// a plan as json: what `os plan --json` prints, and `os plan -o` saves.
pub const Doc = struct {
    hash: []const u8,
    summary: struct { add: usize, change: usize, remove: usize },
    reboot: struct { needed: bool, because: []const []const u8 },
    changes: []const Change,
};

pub fn writeJson(w: *std.Io.Writer, a: Allocator, p: *const Plan) !void {
    const h = try p.hash();
    const reasons = try p.rebootReasons(a);
    const doc: Doc = .{
        .hash = &h,
        .summary = .{ .add = p.count(.add), .change = p.count(.change), .remove = p.count(.remove) },
        .reboot = .{ .needed = reasons.len > 0, .because = reasons },
        .changes = p.changes,
    };
    try output.writeDoc(w, schema, doc);
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
