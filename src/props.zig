//! property tests over generated inputs, from a fixed seed so a failure
//! comes back the same way every run:
//!
//! - the planner gives byte-identical plans for the same inputs.
//! - applying a plan to the facts it was made from leaves nothing to plan.
//! - a lock written, read, and written again is the same bytes.
//! - adding a package and removing it again gives the file back as it was.

const std = @import("std");
const compose = @import("compose.zig");
const config = @import("config.zig");
const diag = @import("diag.zig");
const lock = @import("lock.zig");
const facts = @import("facts.zig");
const planner = @import("planner.zig");
const planview = @import("planview.zig");
const desired = @import("desired.zig");
const catalog = @import("catalog.zig");
const edit = @import("edit.zig");
const lists = @import("lists.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Random = std.Random;

const cases = 100;

fn pick(r: Random, comptime T: type, items: []const T) T {
    return items[r.uintLessThan(usize, items.len)];
}

fn chance(r: Random, percent: u8) bool {
    return r.uintLessThan(u8, 100) < percent;
}

/// each item of `items`, kept with the given chance, in order.
fn subset(a: Allocator, r: Random, items: []const []const u8, percent: u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |it| {
        if (chance(r, percent)) try out.append(a, it);
    }
    return out.items;
}

fn writeList(w: *std.Io.Writer, items: []const []const u8) !void {
    try w.writeByte('[');
    for (items, 0..) |it, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("\"{s}\"", .{it});
    }
    try w.writeByte(']');
}

// -- machines --

const package_pool = [_][]const u8{ "git", "vim", "ripgrep", "neovim", "htop", "base", "glibc", "curl" };
const extra_pool = [_][]const u8{ "nano", "perl", "openssl", "zlib", "old-thing", "filesystem", "pacman" };
const user_pool = [_][]const u8{ "kacy", "sam" };
const group_pool = [_][]const u8{ "wheel", "video", "audio" };
const version_pool = [_][]const u8{ "1", "2", "1.0-1", "2:3.1-2" };

/// a valid machine.toml using most of what the config can say.
fn genConfig(a: Allocator, r: Random) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll("version = 1\npackages = ");
    try writeList(w, try subset(a, r, &package_pool, 30));
    try w.writeByte('\n');
    if (chance(r, 15)) try w.writeAll("aur = [\"yay\"]\n");

    if (chance(r, 50)) {
        try w.writeAll("[boot]\n");
        if (chance(r, 60)) try w.print("kernel = \"{s}\"\n", .{pick(r, []const u8, &.{ "linux", "linux-lts", "none" })});
        if (chance(r, 40)) try w.writeAll("modules = [\"i2c-dev\"]\n");
    }
    if (chance(r, 60)) {
        try w.writeAll("[system]\n");
        if (chance(r, 60)) try w.print("hostname = \"{s}\"\n", .{pick(r, []const u8, &.{ "atlas", "box.lan" })});
        if (chance(r, 50)) try w.print("timezone = \"{s}\"\n", .{pick(r, []const u8, &.{ "UTC", "America/New_York" })});
        if (chance(r, 40)) try w.writeAll("locale = \"en_US.UTF-8\"\n");
        if (chance(r, 30)) try w.writeAll("keymap = \"us\"\n");
    }
    if (chance(r, 40)) {
        try w.writeAll("[hardware]\n");
        if (chance(r, 60)) try w.print("cpu = \"{s}\"\n", .{pick(r, []const u8, &.{ "amd", "intel" })});
        if (chance(r, 60)) try w.print("gpu = \"{s}\"\n", .{pick(r, []const u8, &.{ "amd", "intel", "nvidia", "none" })});
    }
    if (chance(r, 40)) {
        try w.writeAll("[desktop]\n");
        if (chance(r, 60)) try w.writeAll("session = \"hyprland\"\n");
        if (chance(r, 50)) try w.writeAll("audio = \"pipewire\"\n");
        if (chance(r, 60)) try w.print("login = \"{s}\"\n", .{pick(r, []const u8, &.{ "greetd", "sddm", "tty" })});
    }
    if (chance(r, 70)) {
        try w.writeAll("[services]\n");
        for (catalog.services) |s| {
            if (chance(r, 20)) try w.print("{s} = {s}\n", .{ s.name, if (chance(r, 75)) "true" else "false" });
        }
    }
    if (chance(r, 20)) try w.writeAll("[services.custom]\nunit = \"custom.service\"\npackage = \"custom-pkg\"\n");
    for (user_pool) |u| {
        if (!chance(r, 30)) continue;
        try w.print("[users.{s}]\n", .{u});
        if (chance(r, 60)) try w.print("shell = \"{s}\"\n", .{pick(r, []const u8, &.{ "zsh", "bash", "/usr/bin/fish" })});
        if (chance(r, 60)) {
            try w.writeAll("groups = ");
            try writeList(w, try subset(a, r, &group_pool, 50));
            try w.writeByte('\n');
        }
    }
    if (chance(r, 30)) try w.print("[sysctl]\n\"vm.swappiness\" = {d}\n", .{r.uintLessThan(u8, 100)});
    if (chance(r, 30)) try w.print("[files.\"/etc/motd\"]\ntext = \"hello {d}\\n\"\n{s}", .{ r.uintLessThan(u8, 5), if (chance(r, 50)) "mode = \"600\"\n" else "" });
    if (chance(r, 20)) try w.print("[repos.mine]\nserver = \"https://example.org/$repo/$arch\"\n{s}", .{if (chance(r, 60)) "key = \"0123456789ABCDEF0123456789ABCDEF01234567\"\n" else ""});
    return out.written();
}

/// a lock holding everything the config wants and some more, each with
/// random dependencies inside the lock.
fn genLock(a: Allocator, r: Random, c: *const config.Config) !lock.Lock {
    var names: std.ArrayList([]const u8) = .empty;
    for (try planner.wants(a, c)) |w| try names.append(a, w.name);
    for (package_pool ++ extra_pool) |n| {
        if (!lists.contains(names.items, n) and chance(r, 40)) try names.append(a, n);
    }
    const pkgs = try a.alloc(lock.Package, names.items.len);
    for (names.items, pkgs) |n, *p| {
        p.* = .{ .name = n, .version = pick(r, []const u8, &version_pool), .repo = "core", .sha256 = "a" ** 64 };
        p.depends = try subset(a, r, names.items, 10);
    }
    var l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = pkgs };
    try lock.normalize(a, &l);
    return l;
}

/// a machine in some random state near what the config describes.
fn genFacts(a: Allocator, r: Random, c: *const config.Config, l: *const lock.Lock) !facts.Facts {
    const needed = try planner.closure(a, l, try planner.wants(a, c));
    var pkgs: std.ArrayList(facts.Package) = .empty;
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (l.packages) |p| try seen.put(a, p.name, {});
    for (extra_pool) |n| try seen.put(a, n, {});
    for (seen.keys()) |n| {
        if (!chance(r, 50)) continue;
        // a core package nothing needs would stop the plan.
        if (lists.contains(&catalog.protected, n) and !needed.contains(n)) continue;
        try pkgs.append(a, .{
            .name = n,
            .version = pick(r, []const u8, &version_pool),
            .reason = if (chance(r, 50)) .explicit else .dependency,
        });
    }

    var units: std.ArrayList(facts.Unit) = .empty;
    var unit_names: std.ArrayList([]const u8) = .empty;
    for (catalog.services) |s| try unit_names.append(a, s.unit);
    try unit_names.appendSlice(a, &catalog.display_managers);
    try unit_names.append(a, "custom.service");
    for (unit_names.items) |n| {
        if (!chance(r, 30) or lists.find(units.items, "name", n) != null) continue;
        try units.append(a, .{ .name = n, .enabled = r.boolean(), .fixed = chance(r, 10), .active = r.boolean(), .ran = chance(r, 10) });
    }

    var users: std.ArrayList(facts.User) = .empty;
    for (user_pool, 0..) |n, i| {
        if (!chance(r, 50)) continue;
        try users.append(a, .{
            .name = n,
            .uid = @intCast(1000 + i),
            .shell = if (chance(r, 70)) pick(r, []const u8, &.{ "/bin/bash", "/usr/bin/zsh", "/usr/bin/fish" }) else null,
            .groups = try subset(a, r, &group_pool, 50),
        });
    }

    var f: facts.Facts = .{
        .hostname = if (chance(r, 60)) pick(r, []const u8, &.{ "archlinux", "atlas" }) else null,
        .timezone = if (chance(r, 50)) "UTC" else null,
        .packages = pkgs.items,
        .units = units.items,
        .users = users.items,
        .initramfs_modules = if (chance(r, 30)) &.{ "nvidia", "nvidia_modeset", "nvidia_uvm", "nvidia_drm" } else &.{},
        .pacman = .{ .includes_repos = chance(r, 30), .keys = if (chance(r, 30)) &.{"0123456789ABCDEF0123456789ABCDEF01234567"} else &.{} },
    };

    var files: std.ArrayList(facts.File) = .empty;
    for ((try planner.wanted(a, c)).files) |p| {
        if (!chance(r, 40)) continue;
        const want = lists.find(try desired.files(a, c, &f), "path", p);
        const right = want != null and chance(r, 50);
        try files.append(a, .{
            .path = p,
            .sha256 = if (right) try a.dupe(u8, &facts.sha256Hex(want.?.content)) else "00",
            .mode = pick(r, []const u8, &.{ "0644", "0600" }),
            .ours = r.boolean(),
        });
    }
    f.files = files.items;
    f.normalize();
    return f;
}

/// a config loaded the way the cli loads it, which also fills in file
/// contents. fails the test if the text has problems.
fn load(a: Allocator, text: []const u8) !config.Config {
    var fs: compose.MemFiles = .{};
    defer fs.deinit();
    try fs.put("/etc/yoq/machine.toml", text);
    var diags: diag.List = .init(testing.allocator);
    defer diags.deinit();
    const loaded = try compose.load(a, fs.files(), "/etc/yoq/machine.toml", &diags);
    if (diags.items.items.len > 0) {
        try diags.render(std.debug.lockStderr(&.{}).terminal().writer);
        std.debug.print("\nin:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    }
    return loaded.config;
}

fn planJson(a: Allocator, c: *const config.Config, l: *const lock.Lock, f: *const facts.Facts) !?[]const u8 {
    var diags: diag.List = .init(testing.allocator);
    defer diags.deinit();
    const p = try planner.plan(a, c, l, f, &diags) orelse return null;
    var out: std.Io.Writer.Allocating = .init(a);
    try planview.writeJson(&out.writer, a, &p);
    return out.written();
}

test "property: the planner gives the same plan for the same inputs" {
    var prng: Random.DefaultPrng = .init(0x9a7e);
    const r = prng.random();
    for (0..cases) |_| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const c = try load(a, try genConfig(a, r));
        const l = try genLock(a, r, &c);
        const f = try genFacts(a, r, &c, &l);
        const first = try planJson(a, &c, &l, &f) orelse continue;

        // again, in a fresh arena, with the facts read back from json in
        // another order.
        var other: std.heap.ArenaAllocator = .init(testing.allocator);
        defer other.deinit();
        const b = other.allocator();
        var fj: std.Io.Writer.Allocating = .init(b);
        const shuffled = try b.dupe(facts.Package, f.packages);
        r.shuffle(facts.Package, shuffled);
        var f2 = f;
        f2.packages = shuffled;
        try facts.write(&fj.writer, &f2);
        const back = try facts.parse(b, fj.written());
        const second = (try planJson(b, &c, &l, &back)).?;
        try testing.expectEqualStrings(first, second);
    }
}

/// what the machine looks like once `p` is applied to `f`: the planner's
/// view of apply, without the machine.
fn applied(a: Allocator, c: *const config.Config, f: *const facts.Facts, p: *const planner.Plan) !facts.Facts {
    var pkgs: std.ArrayList(facts.Package) = .empty;
    try pkgs.appendSlice(a, f.packages);
    var units: std.ArrayList(facts.Unit) = .empty;
    try units.appendSlice(a, f.units);
    var users: std.ArrayList(facts.User) = .empty;
    try users.appendSlice(a, f.users);
    var files: std.ArrayList(facts.File) = .empty;
    try files.appendSlice(a, f.files);
    var keys: std.ArrayList([]const u8) = .empty;
    try keys.appendSlice(a, f.pacman.keys);
    var out = f.*;
    const wanted_files = try desired.files(a, c, f);

    for (p.changes) |ch| switch (ch.kind) {
        .package, .dependency => {
            const i = lists.indexOf(pkgs.items, "name", ch.subject);
            switch (ch.op) {
                .remove => _ = pkgs.orderedRemove(i.?),
                .change => pkgs.items[i.?].version = ch.to.?,
                .add => try pkgs.append(a, .{ .name = ch.subject, .version = ch.to.?, .reason = if (ch.kind == .package) .explicit else .dependency }),
            }
        },
        .reason => pkgs.items[lists.indexOf(pkgs.items, "name", ch.subject).?].reason = std.meta.stringToEnum(facts.Package.Reason, ch.to.?).?,
        .setting => inline for (comptime config.keysOf(config.System)) |k| {
            if (std.mem.eql(u8, ch.subject, "system." ++ k)) @field(out, k) = ch.to.?;
        },
        .unit => {
            const i = lists.indexOf(units.items, "name", ch.subject) orelse blk: {
                try units.append(a, .{ .name = ch.subject });
                break :blk units.items.len - 1;
            };
            const u = &units.items[i];
            const to = ch.to.?;
            if (std.mem.indexOf(u8, to, "disable") != null) {
                u.enabled = false;
            } else if (std.mem.indexOf(u8, to, "enable") != null) u.enabled = true;
            if (std.mem.indexOf(u8, to, "stop") != null) {
                u.active = false;
            } else if (std.mem.indexOf(u8, to, "start") != null) u.active = true;
        },
        .user => {
            const i = lists.indexOf(users.items, "name", ch.subject) orelse blk: {
                try users.append(a, .{ .name = ch.subject, .uid = @intCast(2000 + users.items.len) });
                break :blk users.items.len - 1;
            };
            const u = &users.items[i];
            if (ch.op == .remove) {
                const g = ch.from.?["leave ".len..];
                var kept: std.ArrayList([]const u8) = .empty;
                for (u.groups) |have| {
                    if (!std.mem.eql(u8, have, g)) try kept.append(a, have);
                }
                u.groups = kept.items;
            } else if (std.mem.startsWith(u8, ch.to.?, "shell ")) {
                u.shell = ch.to.?["shell ".len..];
            } else if (std.mem.startsWith(u8, ch.to.?, "join ")) {
                u.groups = try std.mem.concat(a, []const u8, &.{ u.groups, &.{ch.to.?["join ".len..]} });
            }
        },
        .file => {
            const i = lists.indexOf(files.items, "path", ch.subject);
            if (ch.op == .remove) {
                _ = files.orderedRemove(i.?);
                continue;
            }
            const d = lists.find(wanted_files, "path", ch.subject).?;
            const mode = if (d.mode.len == 3) try std.fmt.allocPrint(a, "0{s}", .{d.mode}) else d.mode;
            const file: facts.File = .{ .path = d.path, .sha256 = try a.dupe(u8, &facts.sha256Hex(d.content)), .mode = mode, .ours = d.cause != null };
            if (i) |n| files.items[n] = file else try files.append(a, file);
        },
        .pacman_conf => out.pacman.includes_repos = true,
        .key => try keys.append(a, ch.subject),
    };
    out.packages = pkgs.items;
    out.units = units.items;
    out.users = users.items;
    out.files = files.items;
    out.pacman.keys = keys.items;
    out.normalize();
    return out;
}

test "property: applying a plan leaves nothing to plan" {
    var prng: Random.DefaultPrng = .init(0xc0de);
    const r = prng.random();
    var planned: usize = 0;
    for (0..cases) |_| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const c = try load(a, try genConfig(a, r));
        const l = try genLock(a, r, &c);
        const f = try genFacts(a, r, &c, &l);
        var diags: diag.List = .init(testing.allocator);
        defer diags.deinit();
        const p = try planner.plan(a, &c, &l, &f, &diags) orelse continue;
        planned += 1;

        const after = try applied(a, &c, &f, &p);
        const again = (try planner.plan(a, &c, &l, &after, &diags)).?;
        if (!again.empty()) {
            var out: std.Io.Writer.Allocating = .init(a);
            try planview.writeText(&out.writer, a, &again, .{ .verbose = true });
            std.debug.print("still to do after applying:\n{s}\n", .{out.written()});
            return error.TestUnexpectedResult;
        }
    }
    // a plan that stops early checks nothing, so most should get through.
    try testing.expect(planned > cases / 2);
}

// -- locks --

/// strings that make the writer quote and escape.
const odd_pool = [_][]const u8{ "plain", "a.b", "g++", "lib32-x", "has space", "quo\"te", "back\\slash", "tab\there", "line\nbreak", "\x01ctl", "del\x7f", "ünï", "", "=", "[x]", "#hash" };

fn genString(a: Allocator, r: Random) ![]const u8 {
    const x = pick(r, []const u8, &odd_pool);
    return if (chance(r, 30)) std.fmt.allocPrint(a, "{s}{d}", .{ x, r.int(u8) }) else x;
}

fn genHex(a: Allocator, r: Random, len: usize) ![]const u8 {
    const out = try a.alloc(u8, len);
    for (out) |*ch| ch.* = "0123456789abcdef"[r.uintLessThan(u8, 16)];
    return out;
}

test "property: a lock reads back as the same bytes" {
    var prng: Random.DefaultPrng = .init(0x10c4);
    const r = prng.random();
    for (0..cases) |_| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var names: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (0..r.uintLessThan(usize, 12)) |_| try names.put(a, try genString(a, r), {});
        const pkgs = try a.alloc(lock.Package, names.count());
        for (names.keys(), pkgs) |n, *p| p.* = .{
            .name = n,
            .version = try genString(a, r),
            .repo = try genString(a, r),
            .sha256 = try genHex(a, r, 64),
            .depends = try subset(a, r, names.keys(), 20),
            .recipe = if (chance(r, 20)) try genHex(a, r, 40) else null,
        };
        var provs: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        for (0..r.uintLessThan(usize, 4)) |_| try provs.put(a, try genString(a, r), try genString(a, r));
        const providers = try a.alloc(lock.Provider, provs.count());
        for (provs.keys(), provs.values(), providers) |k, v, *p| p.* = .{ .name = k, .chosen = v };

        var l: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = try genString(a, r), .packages = pkgs, .providers = providers };
        try lock.normalize(a, &l);
        var first: std.Io.Writer.Allocating = .init(a);
        try lock.write(&first.writer, &l);

        var diags: diag.List = .init(testing.allocator);
        defer diags.deinit();
        const back = try lock.parse(a, "machine.lock", first.written(), &diags) orelse {
            try diags.render(std.debug.lockStderr(&.{}).terminal().writer);
            std.debug.print("\nin:\n{s}\n", .{first.written()});
            return error.TestUnexpectedResult;
        };
        var second: std.Io.Writer.Allocating = .init(a);
        try lock.write(&second.writer, &back);
        try testing.expectEqualStrings(first.written(), second.written());
    }
}

// -- edits --

const list_pool = [_][]const u8{ "git", "vim", "base", "linux-firmware", "ripgrep" };
const new_pool = [_][]const u8{ "htop", "neovim", "with \"quote\"", "é", "a.b+c" };

/// a string list in one of the ways people write them, with its key.
fn genList(a: Allocator, r: Random, key: []const u8) ![]const u8 {
    const items = try subset(a, r, &list_pool, 50);
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("{s} = [", .{key});
    switch (r.uintLessThan(u8, 3)) {
        // one line
        0 => for (items, 0..) |it, i| {
            if (i > 0) try w.writeAll(if (chance(r, 50)) ", " else ",");
            try w.print("\"{s}\"", .{it});
        },
        // one per line, each with a comma, maybe a comment
        1 => {
            try w.writeByte('\n');
            for (items) |it| try w.print("    \"{s}\",{s}\n", .{ it, if (chance(r, 30)) "  # why" else "" });
        },
        // one per line, the last one on the closing bracket's line
        else => {
            if (items.len > 0) try w.writeByte('\n');
            for (items, 0..) |it, i| {
                if (i > 0) try w.writeAll(",\n");
                try w.print("  \"{s}\"", .{it});
            }
        },
    }
    try w.writeByte(']');
    if (chance(r, 30)) try w.writeAll("  # tools");
    try w.writeByte('\n');
    return out.written();
}

fn genEditable(a: Allocator, r: Random, path: []const []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    if (chance(r, 30)) try w.writeAll("# my machine\n");
    if (chance(r, 50)) try w.writeAll("version = 1\n");
    if (path.len == 0) {
        try w.writeAll(try genList(a, r, "packages"));
        if (chance(r, 30)) try w.writeAll("\n[remove]\npackages = [\"nano\"]\n");
    } else {
        if (chance(r, 50)) try w.writeAll("packages = [\"git\"]\n");
        try w.writeAll("\n[remove]\n");
        if (chance(r, 30)) try w.writeAll("aur = []\n");
        try w.writeAll(try genList(a, r, "packages"));
    }
    if (chance(r, 50)) try w.writeAll("\n[system]\nhostname = \"atlas\"\n");
    return out.written();
}

test "property: adding a package and removing it gives the file back" {
    var prng: Random.DefaultPrng = .init(0xed17);
    const r = prng.random();
    const paths = [_][]const []const u8{ &.{}, &.{"remove"} };
    for (0..cases) |_| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const path = pick(r, []const []const u8, &paths);
        const text = try genEditable(a, r, path);
        const name = pick(r, []const u8, &new_pool);
        const added = (try edit.addToList(a, text, path, "packages", name)).?;
        const back = (try edit.removeFromList(a, added, path, "packages", name)).?;
        if (!std.mem.eql(u8, text, back)) {
            std.debug.print("--- before\n{s}--- added\n{s}--- removed\n{s}", .{ text, added, back });
            return error.TestUnexpectedResult;
        }
    }
}
