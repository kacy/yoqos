//! writes a config that describes a machine as it is: the start of
//! `os init`. the machine's own settings go into machine.toml; packages it
//! has installed on purpose go into imported.toml, which machine.toml
//! includes, so the main file stays short.

const std = @import("std");
const config = @import("config.zig");
const facts = @import("facts.zig");
const catalog = @import("catalog.zig");
const planner = @import("planner.zig");
const show = @import("show.zig");
const Allocator = std.mem.Allocator;

/// the config for what `f` describes, without its packages.
pub fn fromFacts(a: Allocator, f: *const facts.Facts) !config.Config {
    const at: config.Src = .{ .file = "machine.toml", .line = 0, .column = 0 };
    var c: config.Config = .{ .version = .{ .v = config.supported_version, .src = at } };
    inline for (comptime config.keysOf(config.System)) |field| {
        if (@field(f, field)) |v| @field(c.system, field) = .{ .v = v, .src = at };
    }
    for (catalog.kernels) |k| {
        const p = f.package(k) orelse continue;
        if (p.reason != .explicit) continue;
        if (!std.mem.eql(u8, k, catalog.default_kernel)) c.boot.kernel = .{ .v = k, .src = at };
        break;
    }
    if (f.cpu) |cpu| {
        if (std.meta.stringToEnum(config.Cpu, cpu)) |v| c.hardware.cpu = .{ .v = v, .src = at };
    }
    // with a discrete gpu next to an integrated one, the discrete one needs
    // the driver.
    for ([_][]const u8{ "nvidia", "amd", "intel" }) |vendor| {
        for (f.gpus) |g| {
            if (!std.mem.eql(u8, g, vendor)) continue;
            c.hardware.gpu = .{ .v = std.meta.stringToEnum(config.Gpu, vendor).?, .src = at };
            break;
        }
        if (c.hardware.gpu != null) break;
    }
    for (f.users) |u| {
        var user: config.User = .{ .src = at };
        if (u.shell) |sh| user.shell = .{ .v = std.fs.path.basename(sh), .src = at };
        for (u.groups) |g| try user.groups.add(a, .{ .name = g, .src = at });
        try c.users.entries.append(a, .{ .name = u.name, .value = user });
    }
    for (catalog.services) |s| {
        const unit = f.unit(s.unit) orelse continue;
        if (!unit.enabled) continue;
        try c.services.entries.append(a, .{ .name = s.name, .value = .{ .src = at, .enabled = .{ .v = true, .src = at } } });
    }
    return c;
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
    w.print(
        \\# this machine, as `os init` found it on {s}. packages installed on
        \\# purpose are in imported.toml: move the ones you care about into
        \\# `packages` here, and drop the rest from there.
        \\include = ["imported.toml"]
        \\
    , .{date}) catch return error.OutOfMemory;
    show.writeToml(w, c, false) catch return error.OutOfMemory;
    return out.written();
}

pub fn importedToml(a: Allocator, packages: []const []const u8, date: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    w.print(
        \\# packages that were installed on purpose when `os init` ran on {s}.
        \\# their dependencies aren't listed; the lock records those. anything
        \\# deleted from here gets removed by the next apply.
        \\
    , .{date}) catch return error.OutOfMemory;
    var c: config.Config = .{};
    for (packages) |p| try c.packages.add(a, .{ .name = p, .src = .{ .file = "imported.toml", .line = 0, .column = 0 } });
    show.writeToml(w, &c, false) catch return error.OutOfMemory;
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
        \\# this machine, as `os init` found it on 2026-09-25. packages installed on
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
        \\# packages that were installed on purpose when `os init` ran on 2026-09-25.
        \\# their dependencies aren't listed; the lock records those. anything
        \\# deleted from here gets removed by the next apply.
        \\packages = [
        \\  "base",
        \\  "neovim",
        \\]
        \\
    , try importedToml(a, imported, "2026-09-25"));
}
