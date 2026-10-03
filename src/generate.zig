//! writes a config that describes a machine as it is: the start of
//! `yos init`. the machine's own settings go into machine.toml; packages it
//! has installed on purpose go into imported.toml, which machine.toml
//! includes, so the main file stays short.

const std = @import("std");
const config = @import("config.zig");
const facts = @import("facts.zig");
const catalog = @import("catalog.zig");
const lists = @import("lists.zig");
const planner = @import("planner.zig");
const desired = @import("desired.zig");
const show = @import("show.zig");
const toml = @import("toml.zig");
const lock = @import("lock.zig");
const sync = @import("sync.zig");
const uki = @import("uki.zig");
const Allocator = std.mem.Allocator;

/// the config for what `f` describes, without its packages. values the
/// config couldn't hold, like a user name shadow allows but yos doesn't,
/// are left out.
pub fn fromFacts(a: Allocator, f: *const facts.Facts) !config.Config {
    const at: config.Src = .{ .file = "machine.toml", .line = 0, .column = 0 };
    var c: config.Config = .{ .version = .{ .v = config.supported_version, .src = at } };
    inline for (comptime config.keysOf(config.System)) |field| {
        if (@field(f, field)) |v| {
            if (config.systemProblem(field, v) == null) @field(c.system, field) = .{ .v = v, .src = at };
        }
    }
    // no kernel installed at all, as in a container, is worth saying.
    c.boot.kernel = .{ .v = catalog.no_kernel, .src = at };
    for (catalog.kernels) |k| {
        if (f.package(k) == null) continue;
        c.boot.kernel = if (std.mem.eql(u8, k, catalog.default_kernel)) null else .{ .v = k, .src = at };
        break;
    }
    // here mkinitcpio's hooks unlock the root already, so the key adds no
    // drop-in. it keeps one in a clean build, which starts from
    // mkinitcpio's own hooks.
    if (f.boot.luks_uuid != null) c.boot.encrypt = .{ .v = true, .src = at };
    // only with ukify there to build yos's own: the key would plan its
    // install otherwise, and init mustn't plan anything.
    if (f.boot.uki and f.package(uki.package) != null) c.boot.uki = .{ .v = true, .src = at };
    // hardware is written only when its packages are already installed:
    // init describes the machine, and mustn't plan a driver install.
    if (f.cpu) |cpu| {
        if (std.meta.stringToEnum(config.Cpu, cpu)) |v| {
            if (installed(f, catalog.cpuPackages(v))) c.hardware.cpu = .{ .v = v, .src = at };
        }
    }
    // with a discrete gpu next to an integrated one, the discrete one needs
    // the driver.
    for ([_]config.Gpu{ .nvidia, .amd, .intel }) |vendor| {
        if (!lists.contains(f.gpus, @tagName(vendor)) or !installed(f, catalog.gpuPackages(vendor))) continue;
        c.hardware.gpu = .{ .v = vendor, .src = at };
        break;
    }
    for (f.users) |u| {
        if (!u.person() or !config.validUserName(u.name) or config.systemUser(u.name)) continue;
        var user: config.User = .{ .src = at };
        if (u.shell) |sh| user.shell = .{ .v = std.fs.path.basename(sh), .src = at };
        for (u.groups) |g| {
            if (config.validUserName(g)) try user.groups.add(a, .{ .name = g, .src = at });
        }
        try c.users.entries.append(a, .{ .name = u.name, .value = user });
    }
    for (catalog.services) |s| {
        const unit = f.unit(s.unit) orelse continue;
        if (!unit.enabled) continue;
        try c.services.entries.append(a, .{ .name = s.name, .value = .{ .src = at, .enabled = .{ .v = true, .src = at } } });
    }
    return c;
}

fn installed(f: *const facts.Facts, names: []const []const u8) bool {
    for (names) |n| {
        if (f.package(n) == null) return false;
    }
    return true;
}

/// explicitly installed packages the config doesn't already imply, in
/// name order.
pub fn importedPackages(a: Allocator, c: *const config.Config, f: *const facts.Facts) ![]const []const u8 {
    const ws = try planner.wants(a, c);
    var out: std.ArrayList([]const u8) = .empty;
    for (f.packages) |p| {
        if (p.reason == .explicit and planner.findWant(ws, p.name) == null) try out.append(a, p.name);
    }
    return out.items;
}

pub fn machineToml(a: Allocator, c: *const config.Config, date: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print(
        \\# this machine, as `yos init` found it on {s}. packages installed on
        \\# purpose are in imported.toml: move the ones you care about into
        \\# `packages` here, and drop the rest from there.
        \\include = ["imported.toml"]
        \\
    , .{date});
    try show.writeToml(w, c, false);
    return out.written();
}

/// with a lock, the packages are grouped under a comment naming their
/// repository, in pacman's order, so a long list is easier to trim.
pub fn importedToml(a: Allocator, packages: []const []const u8, date: []const u8, l: ?*const lock.Lock) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print(
        \\# packages that were installed on purpose when `yos init` ran on {s}.
        \\# their dependencies aren't listed; the lock records those. anything
        \\# deleted from here gets removed by the next apply.
        \\
    , .{date});
    const grouped = l != null;
    if (packages.len == 0 and !grouped) return out.written();

    const Entry = struct { repo: []const u8, name: []const u8 };
    const entries = try a.alloc(Entry, packages.len);
    for (packages, entries) |p, *e| {
        const lp = if (l) |locked| locked.package(p) else null;
        e.* = .{ .repo = if (lp) |x| x.repo else "not in the lock", .name = p };
    }
    if (grouped) std.mem.sort(Entry, entries, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            const rx = sync.repoRank(x.repo);
            const ry = sync.repoRank(y.repo);
            if (rx != ry) return rx < ry;
            const by_repo = std.mem.order(u8, x.repo, y.repo);
            return if (by_repo != .eq) by_repo == .lt else std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    try w.writeAll("packages = [\n");
    for (entries, 0..) |e, i| {
        if (grouped and (i == 0 or !std.mem.eql(u8, entries[i - 1].repo, e.repo))) try w.print("  # {s}\n", .{e.repo});
        try w.writeAll("  ");
        try toml.writeString(w, e.name);
        try w.writeAll(",\n");
    }
    try w.writeAll("]\n");
    return out.written();
}

// -- tests --

const testing = std.testing;

test "a config from facts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pkgs = [_]facts.Package{
        .{ .name = "amd-ucode", .version = "1" },
        .{ .name = "base", .version = "3-2" },
        .{ .name = "glibc", .version = "2.42-1", .reason = .dependency },
        .{ .name = "linux-zen", .version = "6.16.8-1" },
        .{ .name = "neovim", .version = "0.11.4-1" },
        .{ .name = "nvidia-open", .version = "580.82.09-1" },
        .{ .name = "nvidia-utils", .version = "580.82.09-1" },
        .{ .name = "openssh", .version = "10.0p1-4" },
    };
    var units = [_]facts.Unit{
        .{ .name = "sshd.service", .enabled = true, .active = true },
        .{ .name = "bluetooth.service", .enabled = false },
    };
    var users = [_]facts.User{.{ .name = "kacy", .uid = 1000, .shell = "/usr/bin/zsh", .primary_group = "kacy", .groups = &.{ "video", "wheel" } }};
    const f: facts.Facts = .{
        .hostname = "atlas",
        .timezone = "America/New_York",
        .locale = "en_US.UTF-8",
        .cpu = "amd",
        .gpus = &.{ "intel", "nvidia" },
        .packages = &pkgs,
        .units = &units,
        .users = &users,
    };
    const c = try fromFacts(a, &f);
    try testing.expectEqualStrings(
        \\# this machine, as `yos init` found it on 2026-09-25. packages installed on
        \\# purpose are in imported.toml: move the ones you care about into
        \\# `packages` here, and drop the rest from there.
        \\include = ["imported.toml"]
        \\version = 1
        \\
        \\[system]
        \\hostname = "atlas"
        \\timezone = "America/New_York"
        \\locale = "en_US.UTF-8"
        \\
        \\[boot]
        \\kernel = "linux-zen"
        \\
        \\[hardware]
        \\cpu = "amd"
        \\gpu = "nvidia"
        \\
        \\[users.kacy]
        \\shell = "zsh"
        \\groups = [
        \\  "video",
        \\  "wheel",
        \\]
        \\
        \\[services.ssh]
        \\enabled = true
        \\
    , try machineToml(a, &c, "2026-09-25"));

    // the kernel, microcode, and ssh come from the config, and glibc is a
    // dependency, so only base and neovim are imported.
    const imported = try importedPackages(a, &c, &f);
    try testing.expectEqual(2, imported.len);
    try testing.expectEqualStrings("base", imported[0]);
    try testing.expectEqualStrings("neovim", imported[1]);
    try testing.expectEqualStrings(
        \\# packages that were installed on purpose when `yos init` ran on 2026-09-25.
        \\# their dependencies aren't listed; the lock records those. anything
        \\# deleted from here gets removed by the next apply.
        \\packages = [
        \\  "base",
        \\  "neovim",
        \\]
        \\
    , try importedToml(a, imported, "2026-09-25", null));
}

test "a luks root sets [boot] encrypt" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pkgs = [_]facts.Package{.{ .name = "linux", .version = "6.16.8-1" }};
    const f: facts.Facts = .{
        .packages = &pkgs,
        .boot = .{ .luks_uuid = "0f7a1c2e-9b3d-4e5f-8a6b-7c8d9e0f1a2b", .luks_name = "root", .initramfs_hooks = &.{ "base", "udev", "keyboard", "encrypt", "filesystems" } },
    };
    const c = try fromFacts(a, &f);
    try testing.expect(c.boot.encrypt.?.v);
    try testing.expect(std.mem.endsWith(u8, try machineToml(a, &c, "2026-10-01"), "\n[boot]\nencrypt = true\n"));
    // the hooks unlock it already, so the plan stays empty.
    try testing.expectEqual(0, (try desired.files(a, &c, &f)).len);
    try testing.expectEqual(null, (try fromFacts(a, &.{ .packages = &pkgs })).boot.encrypt);
}

test "unified kernel images set [boot] uki, when ukify is there" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pkgs = [_]facts.Package{ .{ .name = "linux", .version = "6.16.8-1" }, .{ .name = "systemd-ukify", .version = "258-1" } };
    const f: facts.Facts = .{ .packages = &pkgs, .boot = .{ .uki = true } };
    const c = try fromFacts(a, &f);
    try testing.expect(c.boot.uki.?.v);
    try testing.expect(std.mem.endsWith(u8, try machineToml(a, &c, "2026-10-01"), "\n[boot]\nuki = true\n"));
    // without generations, yos makes no menu, so ukify is all the key wants.
    try testing.expectEqual(0, (try desired.files(a, &c, &.{ .packages = &pkgs, .boot = .{ .uki = true, .root_fs = "ext4" } })).len);
    // with no ukify to build them, the key would plan an install.
    try testing.expectEqual(null, (try fromFacts(a, &.{ .packages = pkgs[0..1], .boot = .{ .uki = true } })).boot.uki);
    try testing.expectEqual(null, (try fromFacts(a, &.{ .packages = &pkgs })).boot.uki);
}

test "hardware without its packages installed stays out of the config" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var pkgs = [_]facts.Package{.{ .name = "mesa", .version = "1", .reason = .dependency }};
    const f: facts.Facts = .{ .cpu = "amd", .gpus = &.{"nvidia"}, .packages = &pkgs };
    const c = try fromFacts(arena.allocator(), &f);
    try testing.expectEqual(null, c.hardware.cpu);
    try testing.expectEqual(null, c.hardware.gpu);
}

test "values the config can't hold are left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var users = [_]facts.User{
        .{ .name = "kacy", .uid = 1000, .primary_group = "kacy", .groups = &.{ "-r", "wheel" } },
        .{ .name = "Guest", .uid = 1001, .primary_group = "Guest" },
    };
    const f: facts.Facts = .{ .hostname = "atlas.lan", .locale = "C\nX=1", .users = &users };
    const c = try fromFacts(arena.allocator(), &f);
    try testing.expectEqualStrings("atlas.lan", c.system.hostname.?.v);
    try testing.expectEqual(null, c.system.locale);
    try testing.expectEqual(1, c.users.entries.items.len);
    try testing.expectEqual(1, c.users.get("kacy").?.groups.items.items.len);
    var diags: @import("diag.zig").List = .init(testing.allocator);
    defer diags.deinit();
    try config.validate(&c, &diags);
    try testing.expectEqual(0, diags.items.items.len);
}

test "imported packages grouped by repository" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const helpers = @import("test_helpers.zig");
    var git = helpers.lockPackage("git", "2", &.{});
    git.repo = "extra";
    var steam = helpers.lockPackage("steam", "1", &.{});
    steam.repo = "multilib";
    // the lock keeps packages sorted by name.
    const l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{ helpers.lockPackage("base", "3", &.{}), git, steam } };
    const text = try importedToml(arena.allocator(), &.{ "base", "git", "steam", "zz-local" }, "2026-09-25", &l);
    try testing.expect(std.mem.endsWith(u8, text,
        \\packages = [
        \\  # core
        \\  "base",
        \\  # extra
        \\  "git",
        \\  # multilib
        \\  "steam",
        \\  # not in the lock
        \\  "zz-local",
        \\]
        \\
    ));
}
