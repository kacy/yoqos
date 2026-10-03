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
const desired = @import("desired.zig");
const checks = @import("checks.zig");
const settings = @import("settings.zig");
const systemd = @import("systemd.zig");
const users = @import("users.zig");
const rootfs = @import("rootfs.zig");
const exec = @import("exec.zig");
const lists = @import("lists.zig");
const secrets = @import("secrets.zig");
const modules = @import("modules.zig");
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

/// what `run` applies, and where.
pub const Job = struct {
    plan: *const planner.Plan,
    lock: *const lock.Lock,
    /// the files the plan was made from, with what each one holds.
    files: []const desired.File,
    /// where secrets' values come from, when os can read them.
    store: ?secrets.Store,
    target: Target,
    /// systemd runs the machine, so units change too, and files that
    /// load something load it right away.
    units: bool,
    /// the running kernel's release, when `target` is the machine it runs:
    /// its modules outlast an upgrade of its package (see modules.zig).
    running_kernel: ?[]const u8 = null,
};

/// applies `job.plan`, with units only when `job.units` says systemd runs
/// the machine. units going away stop before their packages are removed,
/// and new ones start after theirs are installed. returns null, with
/// reasons in `diags`, if a step failed; steps before it stay done.
pub fn run(a: Allocator, io: std.Io, job: Job, diags: *diag.List) !?Result {
    const p = job.plan;
    const t = job.target;
    const units = job.units;
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
    const tx = try transaction(a, p, job.lock, t);
    if (tx.install.len + tx.remove.len + tx.explicit.len + tx.dependency.len > 0) {
        const kept: ?modules.Kept = if (job.running_kernel) |r| try modules.keep(a, io, t.root, r, p.changes) else null;
        const ok = try alpm.transact(a, io, tx, diags);
        if (kept) |k| try modules.restore(a, io, t.root, k);
        if (!ok) return null;
    }
    for (p.changes) |c| {
        const ok = switch (c.kind) {
            .setting => try settings.apply(a, io, t.root, c.subject, c.to.?, diags),
            .user => try users.apply(a, io, t.root, c, diags),
            .file => if (c.op == .remove) try removeFile(a, io, t.root, c.subject, diags) else try writeFile(a, io, job, c.subject, diags),
            else => true,
        };
        if (!ok) return null;
    }
    if (rebuildsInitramfs(p.changes) and !try rebuildInitramfs(a, io, t.root, diags)) return null;
    if (units and !try changeUnits(a, p, false, diags)) return null;
    return .{ .skipped = skipped.items };
}

/// the full path skips wrappers earlier in PATH that ask questions, like
/// omarchy's.
const mkinitcpio = "/usr/bin/mkinitcpio";

/// whether `changes` write or remove a mkinitcpio drop-in. the kernel's
/// own hook ran in the package transaction, before the drop-ins, so the
/// initramfs is built again once they're all in place.
pub fn rebuildsInitramfs(changes: []const planner.Change) bool {
    for (changes) |c| {
        if (c.kind == .file and desired.isInitramfsDropIn(c.subject)) return true;
    }
    return false;
}

/// the command that rebuilds every initramfs in `root`. another root (a
/// staged one, a clean build, an install) builds inside a chroot, the way
/// pacman ran the kernel's hook there.
pub fn mkinitcpioArgv(a: Allocator, root: []const u8) ![]const []const u8 {
    if (std.mem.eql(u8, root, "/")) return a.dupe([]const u8, &.{ mkinitcpio, "-P" });
    return a.dupe([]const u8, &.{ "chroot", root, mkinitcpio, "-P" });
}

/// rebuilds the initramfs in `root`. a root without mkinitcpio has none
/// to rebuild, like a test's.
fn rebuildInitramfs(a: Allocator, io: std.Io, root: []const u8, diags: *diag.List) !bool {
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = root };
    if (!fs.exists(mkinitcpio[1..])) return true;
    if (try exec.run(a, io, try mkinitcpioArgv(a, root))) |why| {
        try diags.add(.apply_failed, null, "the mkinitcpio drop-ins changed, but {s} -P failed: {s}", .{ mkinitcpio, why }, null);
        return false;
    }
    return true;
}

/// writes a managed file whole, with its mode. on a running machine
/// (`job.units`) the sysctl file and the module list are loaded right
/// away. a secret's value is read from `job.store` just for the write,
/// and wiped after it.
fn writeFile(a: Allocator, io: std.Io, job: Job, path: []const u8, diags: *diag.List) !bool {
    const d = lists.find(job.files, "path", path).?; // the plan came from these files.
    const fs: rootfs.Root = .{ .a = a, .io = io, .dir = job.target.root };
    const mode = std.fmt.parseInt(u32, d.mode, 8) catch unreachable; // validated with the config.
    var value: ?[]u8 = null;
    defer if (value) |v| secrets.wipe(v);
    if (d.secret) |name| value = try secretValue(a, job.store, job.plan, path, name, diags) orelse return false;
    // the path is the config's, and a directory on the way may be a
    // user's, like a home: the write is checked all the way down.
    if (try rootfs.writeChecked(a, fs.dir, std.mem.trimStart(u8, path, "/"), value orelse d.content, mode)) |why| {
        try diags.add(.apply_failed, null, "{s}", .{why}, null);
        return false;
    }
    if (!job.units) return true;
    const then: []const []const u8 = if (std.mem.eql(u8, path, desired.sysctl_path))
        &.{ "sysctl", "-p", path }
    else if (std.mem.eql(u8, path, desired.modules_path))
        &.{ "systemctl", "restart", "systemd-modules-load.service" }
    else
        return true;
    if (try exec.run(a, io, then)) |why| {
        try diags.add(.apply_failed, null, "wrote {s}, but {s} failed: {s}", .{ path, then[0], why }, null);
        return false;
    }
    return true;
}

/// the value of the secret `name` for the file at `path`, as long as it's
/// the one `p` was made for: `os secret set` may have run since. null
/// after saying why not. the caller wipes it.
fn secretValue(a: Allocator, store: ?secrets.Store, p: *const planner.Plan, path: []const u8, name: []const u8, diags: *diag.List) !?[]u8 {
    const s = store orelse return secretUnread(diags, path, name, "secrets need root");
    const value = switch (try s.get(a, name)) {
        .value => |v| v,
        .missing => return secretUnread(diags, path, name, "this machine doesn't have it"),
        .unreadable => |why| return secretUnread(diags, path, name, why),
        .unknown => return secretUnread(diags, path, name, "secrets need root"),
    };
    const key = try s.key(a);
    const planned = p.plannedHash(path);
    if (key != null and planned != null and std.mem.eql(u8, planned.?, &secrets.keyedHex(&key.?, value))) return value;
    secrets.wipe(value);
    try diags.add(.plan_moved, null, "the secret \"{s}\" isn't the value the plan was made for, so {s} wasn't written", .{ name, path }, "run it again and look over the new plan");
    return null;
}

fn secretUnread(diags: *diag.List, path: []const u8, name: []const u8, why: []const u8) !?[]u8 {
    try diags.addHint(.apply_failed, null, "can't write {s}: can't read the secret \"{s}\": {s}", .{ path, name, why }, "`os secret set {s}` sets it", .{name});
    return null;
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

/// removes a file os generated that nothing asks for now.
fn removeFile(a: Allocator, io: std.Io, root: []const u8, path: []const u8, diags: *diag.List) !bool {
    _ = io;
    if (try rootfs.removeChecked(a, root, std.mem.trimStart(u8, path, "/"))) |why| {
        try diags.add(.apply_failed, null, "{s}", .{why}, null);
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
    const files = try desired.files(a, &c, &.{});
    const want = try planner.wanted(a, &c);
    const observe = @import("observe.zig");

    var f = try observe.observe(a, io, .{ .root = root, .packages = false, .units = false, .wanted = want }, &diags);
    const p = (try planner.plan(a, &c, &l, &f, &diags)).?;
    try testing.expectEqual(2, p.changes.len);
    const t: Target = .{ .root = root, .dbpath = "", .dbs = &.{}, .cachedir = "", .gpgdir = null };
    _ = (try run(a, io, .{ .plan = &p, .lock = &l, .files = files, .store = null, .target = t, .units = false }, &diags)).?;

    f = try observe.observe(a, io, .{ .root = root, .packages = false, .units = false, .wanted = want }, &diags);
    try testing.expect((try planner.plan(a, &c, &l, &f, &diags)).?.empty());
    try testing.expectEqualStrings("0600", f.file("/etc/ssh/sshd_config.d/10-local.conf").?.mode);
    try testing.expectEqualStrings("0644", f.file(desired.sysctl_path).?.mode);
}

test "a secret's file is written from the store, and the facts only hold its keyed hash" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var diags: diag.List = .init(testing.allocator);
    defer diags.deinit();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var mem: secrets.Memory = .init(testing.allocator);
    defer mem.deinit();
    const store = mem.store();
    const observe = @import("observe.zig");

    const c = try helpers.configFrom(a, "[boot]\nkernel = \"none\"\n[files.\"/etc/wifi.psk\"]\nsecret = \"wifi/home\"\n");
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{} };
    const files = try desired.files(a, &c, &.{});
    const want = try planner.wanted(a, &c);
    const opts: observe.Options = .{ .root = root, .packages = false, .units = false, .wanted = want, .secrets = store };
    const t: Target = .{ .root = root, .dbpath = "", .dbs = &.{}, .cachedir = "", .gpgdir = null };

    var f = try observe.observe(a, io, opts, &diags);
    try testing.expectEqual(.missing, f.secret("wifi/home").?.state);
    try testing.expect(!try checks.checkSecrets(&c, &f, &diags));
    // apply refuses too, should it get that far.
    var p = (try planner.plan(a, &c, &l, &f, &diags)).?;
    try testing.expectEqual(null, try run(a, io, .{ .plan = &p, .lock = &l, .files = files, .store = store, .target = t, .units = false }, &diags));

    _ = try store.set(a, "wifi/home", "hunter2");
    f = try observe.observe(a, io, opts, &diags);
    p = (try planner.plan(a, &c, &l, &f, &diags)).?;
    try testing.expectEqual(1, p.changes.len);
    _ = (try run(a, io, .{ .plan = &p, .lock = &l, .files = files, .store = store, .target = t, .units = false }, &diags)).?;
    try testing.expectEqualStrings("hunter2", try tmp.dir.readFileAlloc(io, "etc/wifi.psk", a, .limited(64)));

    f = try observe.observe(a, io, opts, &diags);
    try testing.expect((try planner.plan(a, &c, &l, &f, &diags)).?.empty());
    try testing.expectEqualStrings("0600", f.file("/etc/wifi.psk").?.mode);
    var out: std.Io.Writer.Allocating = .init(a);
    try facts.write(&out.writer, &f);
    try testing.expect(std.mem.indexOf(u8, out.written(), "hunter2") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), &facts.sha256Hex("hunter2")) == null);
    try testing.expect(f.file("/etc/wifi.psk").?.keyed);

    _ = try store.set(a, "wifi/home", "hunter3");
    f = try observe.observe(a, io, opts, &diags);
    p = (try planner.plan(a, &c, &l, &f, &diags)).?;
    try testing.expectEqualStrings("rewrite, mode 0600", p.changes[0].to.?);
    // a value set after the plan was made isn't the one it was made for.
    _ = try store.set(a, "wifi/home", "hunter4");
    try testing.expectEqual(null, try run(a, io, .{ .plan = &p, .lock = &l, .files = files, .store = store, .target = t, .units = false }, &diags));
    try testing.expectEqualStrings("hunter2", try tmp.dir.readFileAlloc(io, "etc/wifi.psk", a, .limited(64)));
    try testing.expectEqual(diag.Code.plan_moved, diags.items.items[diags.items.items.len - 1].code);
    _ = try store.set(a, "wifi/home", "hunter3");
    _ = (try run(a, io, .{ .plan = &p, .lock = &l, .files = files, .store = store, .target = t, .units = false }, &diags)).?;
    try testing.expectEqualStrings("hunter3", try tmp.dir.readFileAlloc(io, "etc/wifi.psk", a, .limited(64)));
    // the refusals earlier are the only problems, and they don't hold the
    // value.
    try testing.expectEqual(3, diags.items.items.len);
    for (diags.items.items) |d| try testing.expect(std.mem.indexOf(u8, d.message, "hunter") == null);
}

test "values kept without a key get one, so a stale file still shows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var diags: diag.List = .init(testing.allocator);
    defer diags.deinit();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(io, "etc");
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/wifi.psk", .data = "old value" });
    var mem: secrets.Memory = .init(testing.allocator);
    defer mem.deinit();
    // a value with no key beside it.
    try mem.values.put(mem.arena.allocator(), "wifi/home", "hunter2");
    const observe = @import("observe.zig");

    const c = try helpers.configFrom(a, "[boot]\nkernel = \"none\"\n[files.\"/etc/wifi.psk\"]\nsecret = \"wifi/home\"\n");
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{} };
    const f = try observe.observe(a, io, .{ .root = root, .packages = false, .units = false, .wanted = try planner.wanted(a, &c), .secrets = mem.store() }, &diags);
    const p = (try planner.plan(a, &c, &l, &f, &diags)).?;
    try testing.expectEqual(1, p.changes.len);
    try testing.expectEqualStrings("rewrite, mode 0600", p.changes[0].to.?);
}

test "mkinitcpio drop-ins rebuild the initramfs once" {
    const drop: planner.Change = .{ .op = .add, .kind = .file, .subject = "/etc/mkinitcpio.conf.d/10-yoq-nvidia.conf" };
    const other: planner.Change = .{ .op = .add, .kind = .file, .subject = "/etc/sysctl.d/99-yoq.conf" };
    const sibling: planner.Change = .{ .op = .add, .kind = .file, .subject = "/etc/mkinitcpio.conf.dx/a.conf" };
    const gone: planner.Change = .{ .op = .remove, .kind = .file, .subject = "/etc/mkinitcpio.conf.d/50-local.conf" };
    const pkg: planner.Change = .{ .op = .add, .kind = .package, .subject = "/etc/mkinitcpio.conf.d/x", .to = "1" };
    try testing.expect(!rebuildsInitramfs(&.{}));
    try testing.expect(!rebuildsInitramfs(&.{ other, sibling, pkg }));
    try testing.expect(rebuildsInitramfs(&.{ other, drop }));
    try testing.expect(rebuildsInitramfs(&.{ drop, gone }));
    try testing.expect(rebuildsInitramfs(&.{gone}));
}

test "mkinitcpio runs in the root it builds for" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const live = try mkinitcpioArgv(a, "/");
    try testing.expectEqual(2, live.len);
    try testing.expectEqualStrings("/usr/bin/mkinitcpio", live[0]);
    try testing.expectEqualStrings("-P", live[1]);
    const staged = try mkinitcpioArgv(a, "/run/yoq/next");
    try testing.expectEqual(4, staged.len);
    try testing.expectEqualStrings("chroot", staged[0]);
    try testing.expectEqualStrings("/run/yoq/next", staged[1]);
    try testing.expectEqualStrings("/usr/bin/mkinitcpio", staged[2]);
}
