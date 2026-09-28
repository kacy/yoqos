//! carries out a plan on a machine: packages through a libalpm
//! transaction, `[system]` settings through their files, users through
//! shadow's tools, and units through systemd when it runs the machine.
//! without systemd, `run` hands the units back as skipped.

const std = @import("std");
const facts = @import("facts.zig");
const alpm = @import("alpm.zig");
const diag = @import("diag.zig");
const lock = @import("lock.zig");
const planner = @import("planner.zig");
const settings = @import("settings.zig");
const systemd = @import("systemd.zig");
const users = @import("users.zig");
const rootfs = @import("rootfs.zig");
const exec = @import("exec.zig");
const Allocator = std.mem.Allocator;

pub const Target = alpm.Target;

/// whether `run` changes this kind of thing. units need systemd running
/// the machine.
pub fn applies(k: planner.Kind, units: bool) bool {
    return k != .unit or units;
}

pub const Result = struct {
    /// changes that weren't applied: units without systemd.
    skipped: []const planner.Change,
};

/// the package side of a plan, as one transaction's worth of lists.
fn transaction(a: Allocator, p: *const planner.Plan, l: *const lock.Lock, t: Target) !alpm.Transaction {
    var install: std.ArrayList(lock.Package) = .empty;
    var remove: std.ArrayList([]const u8) = .empty;
    var explicit: std.ArrayList([]const u8) = .empty;
    var dependency: std.ArrayList([]const u8) = .empty;
    for (p.changes) |c| switch (c.kind) {
        .package, .dependency => switch (c.op) {
            .add, .change => {
                try install.append(a, l.package(c.subject).?.*);
                // libalpm installs every target as explicit; set it right.
                try (if (c.kind == .package) &explicit else &dependency).append(a, c.subject);
            },
            .remove => try remove.append(a, c.subject),
        },
        .reason => try (if (std.mem.eql(u8, c.to.?, "explicit")) &explicit else &dependency).append(a, c.subject),
        .setting, .unit, .user, .file, .key, .pacman_conf => {},
    };
    return .{
        .target = t,
        .install = install.items,
        .remove = remove.items,
        .explicit = explicit.items,
        .dependency = dependency.items,
    };
}

/// applies `p`, with units only when `units` says systemd runs the
/// machine. units going away stop before their packages are removed, and
/// new ones start after theirs are installed. returns null, with reasons
/// in `diags`, if a step failed; steps before it stay done.
pub fn run(a: Allocator, io: std.Io, p: *const planner.Plan, l: *const lock.Lock, files: []const planner.DesiredFile, t: Target, units: bool, diags: *diag.List) !?Result {
    var skipped: std.ArrayList(planner.Change) = .empty;
    for (p.changes) |c| {
        if (!applies(c.kind, units)) try skipped.append(a, c);
    }
    if (units and !try changeUnits(a, p, true, diags)) return null;
    // repositories' keys and pacman.conf come first: packages from those
    // repositories are checked against the keys.
    for (p.changes) |c| {
        const ok = switch (c.kind) {
            .key => try importKey(a, io, t.root, c.subject, diags),
            .pacman_conf => try includeRepos(a, io, t.root, diags),
            else => true,
        };
        if (!ok) return null;
    }
    const tx = try transaction(a, p, l, t);
    if (tx.install.len + tx.remove.len + tx.explicit.len + tx.dependency.len > 0) {
        if (!try alpm.transact(a, io, tx, diags)) return null;
    }
    for (p.changes) |c| {
        const ok = switch (c.kind) {
            .setting => try settings.apply(a, io, t.root, c.subject, c.to.?, diags),
            .user => try users.apply(a, io, t.root, c, diags),
            .file => if (c.op == .remove) try removeFile(a, io, t.root, c.subject, units, diags) else try writeFile(a, io, t.root, files, c.subject, units, diags),
            else => true,
        };
        if (!ok) return null;
    }
    if (units and !try changeUnits(a, p, false, diags)) return null;
    return .{ .skipped = skipped.items };
}

/// writes a managed file whole, with its mode. on a running machine
/// (`live`, as for units) the sysctl file and the module list are loaded
/// right away, and a mkinitcpio drop-in rebuilds the initramfs.
fn writeFile(a: Allocator, io: std.Io, root: []const u8, files: []const planner.DesiredFile, path: []const u8, live: bool, diags: *diag.List) !bool {
    const d = for (files) |d| {
        if (std.mem.eql(u8, d.path, path)) break d;
    } else unreachable; // the plan came from these files.
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    const mode = std.fmt.parseInt(u32, d.mode, 8) catch unreachable; // validated with the config.
    fs.writeMode(std.mem.trimStart(u8, path, "/"), d.content, mode) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.WriteFailed => {
            try diags.add(.apply_failed, null, "can't write {s}", .{try fs.path(path)}, null);
            return false;
        },
    };
    if (!live) return true;
    const then: []const []const u8 = if (std.mem.eql(u8, path, planner.sysctl_path))
        &.{ "sysctl", "-p", path }
    else if (std.mem.eql(u8, path, planner.modules_path))
        &.{ "systemctl", "restart", "systemd-modules-load.service" }
    else if (std.mem.startsWith(u8, path, "/etc/mkinitcpio.conf.d/"))
        &.{ "/usr/bin/mkinitcpio", "-P" }
    else
        return true;
    if (try exec.run(a, io, then)) |why| {
        try diags.add(.apply_failed, null, "wrote {s}, but {s} failed: {s}", .{ path, then[0], why }, null);
        return false;
    }
    return true;
}

/// fetches a signing key into pacman's keyring and signs it locally, the
/// way pacman-key's own instructions add a repository's key.
fn importKey(a: Allocator, io: std.Io, root: []const u8, fingerprint: []const u8, diags: *diag.List) !bool {
    const gpgdir = try std.fs.path.join(a, &.{ root, "etc/pacman.d/gnupg" });
    for ([_][]const u8{ "--recv-keys", "--lsign-key" }) |verb| {
        if (try exec.run(a, io, &.{ "pacman-key", "--gpgdir", gpgdir, verb, fingerprint })) |why| {
            try diags.add(.apply_failed, null, "can't add the key {s} to pacman's keyring: {s}", .{ fingerprint, why }, "check the fingerprint, and that the keyserver in /etc/pacman.d/gnupg/gpg.conf can be reached");
            return false;
        }
    }
    return true;
}

/// adds the line that reads the repositories' file to pacman.conf, at the
/// end, after arch's own repositories.
fn includeRepos(a: Allocator, io: std.Io, root: []const u8, diags: *diag.List) !bool {
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    const conf = try fs.read("etc/pacman.conf");
    const sep: []const u8 = if (conf.len > 0 and conf[conf.len - 1] != '\n') "\n" else "";
    const mode = try fs.mode("etc/pacman.conf") orelse 0o644;
    fs.writeMode("etc/pacman.conf", try std.mem.concat(a, u8, &.{ conf, sep, "\n# the repositories in os's config.\n", facts.repos_include, "\n" }), mode) catch {
        try diags.add(.apply_failed, null, "can't write {s}", .{try fs.path("etc/pacman.conf")}, null);
        return false;
    };
    return true;
}

/// removes a file os generated that nothing asks for now. a mkinitcpio
/// drop-in going rebuilds the initramfs on a running machine.
fn removeFile(a: Allocator, io: std.Io, root: []const u8, path: []const u8, live: bool, diags: *diag.List) !bool {
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    std.Io.Dir.cwd().deleteFile(io, try fs.path(std.mem.trimStart(u8, path, "/"))) catch |e| switch (e) {
        error.FileNotFound => {},
        else => {
            try diags.add(.apply_failed, null, "can't remove {s}", .{try fs.path(path)}, null);
            return false;
        },
    };
    if (!live or !std.mem.startsWith(u8, path, "/etc/mkinitcpio.conf.d/")) return true;
    if (try exec.run(a, io, &.{ "/usr/bin/mkinitcpio", "-P" })) |why| {
        try diags.add(.apply_failed, null, "removed {s}, but mkinitcpio failed: {s}", .{ path, why }, null);
        return false;
    }
    return true;
}

/// the unit changes that turn units off, or the ones that turn them on.
fn changeUnits(a: Allocator, p: *const planner.Plan, off: bool, diags: *diag.List) !bool {
    for (p.changes) |c| {
        if (c.kind != .unit or (c.op == .remove) != off) continue;
        if (!try systemd.change(a, c.subject, try systemd.parseVerbs(a, c.to.?), diags)) return false;
    }
    return true;
}

// -- tests --

const testing = std.testing;
const helpers = @import("test_helpers.zig");

test "a plan becomes one transaction" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{
        helpers.lockPackage("git", "2", &.{"glibc"}),
        helpers.lockPackage("glibc", "2", &.{}),
        helpers.lockPackage("vim", "1", &.{}),
    } };
    const p: planner.Plan = .{ .changes = &.{
        .{ .op = .change, .kind = .package, .subject = "git", .from = "1", .to = "2" },
        .{ .op = .add, .kind = .dependency, .subject = "glibc", .to = "2" },
        .{ .op = .change, .kind = .reason, .subject = "vim", .from = "dependency", .to = "explicit" },
        .{ .op = .remove, .kind = .package, .subject = "nano", .from = "8" },
        .{ .op = .change, .kind = .setting, .subject = "system.hostname", .to = "atlas" },
        .{ .op = .add, .kind = .unit, .subject = "sshd.service", .to = "enable, start" },
    } };
    const tx = try transaction(a, &p, &l, .{ .root = "/", .dbpath = "/var/lib/pacman", .dbs = &.{}, .cachedir = "/c", .gpgdir = null });
    try testing.expectEqual(2, tx.install.len);
    try testing.expectEqualStrings("2", tx.install[0].version);
    try testing.expectEqualStrings("nano", tx.remove[0]);
    try testing.expectEqual(2, tx.explicit.len);
    try testing.expectEqualStrings("vim", tx.explicit[1]);
    try testing.expectEqualStrings("glibc", tx.dependency[0]);
}

test "files are written with their mode, and the plan comes back empty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var diags: diag.List = .init(testing.allocator);
    defer diags.deinit();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var c = try helpers.configFrom(a,
        \\[boot]
        \\kernel = "none"
        \\[files."/etc/ssh/sshd_config.d/10-local.conf"]
        \\text = "PasswordAuthentication no\n"
        \\mode = "0600"
        \\[sysctl]
        \\"vm.swappiness" = 10
        \\
    );
    for (c.files.entries.items) |*e| e.value.content = e.value.text.?.v;
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{} };
    const files = try planner.desiredFiles(a, &c, &.{});
    const want = try planner.wanted(a, &c);
    const observe = @import("observe.zig");

    var f = try observe.observe(a, io, .{ .root = root, .packages = false, .units = false, .wanted = want }, &diags);
    const p = (try planner.plan(a, &c, &l, &f, &diags)).?;
    try testing.expectEqual(2, p.changes.len);
    const t: Target = .{ .root = root, .dbpath = "", .dbs = &.{}, .cachedir = "", .gpgdir = null };
    _ = (try run(a, io, &p, &l, files, t, false, &diags)).?;

    f = try observe.observe(a, io, .{ .root = root, .packages = false, .units = false, .wanted = want }, &diags);
    try testing.expect((try planner.plan(a, &c, &l, &f, &diags)).?.empty());
    try testing.expectEqualStrings("0600", f.file("/etc/ssh/sshd_config.d/10-local.conf").?.mode);
    try testing.expectEqualStrings("0644", f.file(planner.sysctl_path).?.mode);
}
