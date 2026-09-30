//! `os why <package>`: which line of the config makes a package part of the
//! machine. a package is either asked for (in `packages`, or implied by a
//! service or hardware choice) or pulled in by one that is, and then the
//! answer is the shortest dependency chain back to something asked for.
//! files and units get the key that makes os write or enable them.

const std = @import("std");
const config = @import("config.zig");
const lock = @import("lock.zig");
const planner = @import("planner.zig");
const output = @import("output.zig");
const lists = @import("lists.zig");
const catalog = @import("catalog.zig");
const Allocator = std.mem.Allocator;

pub const schema = "yoq.why/1";

pub const Answer = struct {
    package: []const u8,
    /// the package the config asks for that brings this one in. it's this
    /// package itself when the config asks for it directly.
    root: ?planner.Want,
    /// from `root` down to `package`. just the package when asked for directly.
    chain: []const []const u8,
    /// needed packages that depend on this one directly.
    needed_by: []const []const u8,
};

pub fn explain(a: Allocator, c: *const config.Config, l: *const lock.Lock, name: []const u8) !Answer {
    const ws = try planner.wants(a, c);
    var answer: Answer = .{ .package = name, .root = null, .chain = &.{}, .needed_by = &.{} };
    if (planner.findWant(ws, name)) |w| {
        answer.root = w.*;
        answer.chain = try a.dupe([]const u8, &.{name});
    }
    const needed = try planner.closure(a, l, ws);
    if (!needed.contains(name)) return answer;

    var parents: std.ArrayList([]const u8) = .empty;
    for (needed.keys()) |n| {
        for (l.package(n).?.depends) |d| {
            if (std.mem.eql(u8, d, name)) try parents.append(a, n);
        }
    }
    lists.sortStrings(parents.items);
    answer.needed_by = parents.items;
    if (answer.root != null) return answer;

    // breadth-first from the wanted packages finds the shortest chain.
    var came_from: std.StringHashMapUnmanaged([]const u8) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;
    for (ws) |w| {
        if (l.package(w.name) == null) continue;
        try came_from.put(a, w.name, "");
        try queue.append(a, w.name);
    }
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        if (std.mem.eql(u8, cur, name)) break;
        for (l.package(cur).?.depends) |d| {
            if (came_from.contains(d)) continue;
            try came_from.put(a, d, cur);
            try queue.append(a, d);
        }
    }
    var chain: std.ArrayList([]const u8) = .empty;
    var at = name;
    while (at.len > 0) : (at = came_from.get(at).?) try chain.append(a, at);
    std.mem.reverse([]const u8, chain.items);
    answer.chain = chain.items;
    answer.root = planner.findWant(ws, chain.items[0]).?.*;
    return answer;
}

pub fn writeText(w: *std.Io.Writer, ans: *const Answer) !void {
    const root = ans.root orelse {
        try w.print("{s}: nothing in the config needs it\n", .{ans.package});
        return;
    };
    if (ans.chain.len > 1) {
        try w.print("{s}: needed by ", .{ans.package});
        for (ans.chain, 0..) |n, i| {
            if (i > 0) try w.writeAll(" -> ");
            try w.writeAll(n);
        }
        try w.writeByte('\n');
    }
    try w.print("{s}: ", .{root.name});
    if (root.cause) |cause| try w.print("from {s}", .{cause}) else try w.writeAll("in packages");
    if (root.src) |s| {
        try w.print("  ({s}:{d})\n", .{ s.file, s.line });
    } else {
        try w.writeAll("  (the default)\n");
    }
    // the chain already names the package's parent, so list the others.
    // package names are never empty, so "" matches none.
    const parent = if (ans.chain.len > 1) ans.chain[ans.chain.len - 2] else "";
    var others: usize = 0;
    for (ans.needed_by) |n| others += @intFromBool(!std.mem.eql(u8, n, parent));
    if (others == 0) return;
    try w.print("also needed by {d} more: ", .{others});
    var first = true;
    for (ans.needed_by) |n| {
        if (std.mem.eql(u8, n, parent)) continue;
        if (!first) try w.writeAll(", ");
        first = false;
        try w.writeAll(n);
    }
    try w.writeByte('\n');
}

pub fn writeJson(w: *std.Io.Writer, ans: *const Answer) !void {
    const Root = struct { name: []const u8, cause: ?[]const u8, file: ?[]const u8, line: ?u32 };
    const root: ?Root = if (ans.root) |r| .{
        .name = r.name,
        .cause = r.cause,
        .file = if (r.src) |s| s.file else null,
        .line = if (r.src) |s| s.line else null,
    } else null;
    try output.writeDoc(w, schema, .{
        .package = ans.package,
        .needed = ans.root != null,
        .root = root,
        .chain = ans.chain,
        .needed_by = ans.needed_by,
    });
}

// -- files and units --

pub const file_schema = "yoq.why-file/1";
pub const unit_schema = "yoq.why-unit/1";

/// what an argument to `os why` names, by its shape.
pub const Kind = enum { file, unit, package };

pub fn kindOf(arg: []const u8) Kind {
    if (arg[0] == '/') return .file;
    for (unit_suffixes) |s| {
        if (std.mem.endsWith(u8, arg, s)) return .unit;
    }
    return .package;
}

const unit_suffixes = [_][]const u8{ ".service", ".socket", ".timer" };

/// the key a file or unit comes from, and where the config sets it.
pub const Cause = struct {
    key: []const u8,
    src: ?config.Src,
};

pub const FileAnswer = struct {
    path: []const u8,
    /// the key that makes os write the file, or add to it.
    cause: ?Cause,
    /// os adds a line to the file instead of writing all of it.
    partial: bool = false,
    /// the package that ships the file, when os doesn't manage it. the
    /// caller fills this in: it takes reading the machine.
    package: ?[]const u8 = null,
};

pub fn explainFile(a: Allocator, c: *const config.Config, path: []const u8) !FileAnswer {
    var ans: FileAnswer = .{ .path = path, .cause = null };
    // `[files]` entries are checked by name: one whose source can't be
    // read is still os's.
    if (c.files.get(path)) |f| {
        ans.cause = .{ .key = try std.fmt.allocPrint(a, "files.\"{s}\"", .{path}), .src = f.src };
    } else if (lists.find(try planner.desiredFiles(a, c, &.{}), "path", path)) |d| {
        ans.cause = .{ .key = d.cause.?, .src = d.src };
    } else if (std.mem.eql(u8, path, "/etc/pacman.conf") and planner.ownRepos(c)) {
        ans.cause = .{ .key = "repos", .src = planner.reposSrc(c) };
        ans.partial = true;
    }
    return ans;
}

pub const UnitAnswer = struct {
    unit: []const u8,
    cause: ?Cause,
    /// what the config wants the unit to be, when it says.
    enabled: ?bool = null,
    /// the catalog's service for the unit, which `os enable` would turn on.
    service: ?[]const u8 = null,
};

pub fn explainUnit(a: Allocator, c: *const config.Config, unit: []const u8) !UnitAnswer {
    var ans: UnitAnswer = .{ .unit = unit, .cause = null };
    for (c.services.entries.items) |e| {
        if (!config.knownService(c, e.name) or !std.mem.eql(u8, e.value.unitFor(e.name), unit)) continue;
        ans.cause = .{ .key = try std.fmt.allocPrint(a, "services.{s}", .{e.name}), .src = e.value.src };
        ans.enabled = e.value.isEnabled();
        ans.service = e.name;
        return ans;
    }
    // a login choice enables its display manager and disables the others.
    if (c.desktop.login) |login| {
        for (catalog.display_managers) |dm| {
            if (!std.mem.eql(u8, dm, unit)) continue;
            const own = catalog.loginUnit(login.v);
            ans.cause = .{ .key = "desktop.login", .src = login.src };
            ans.enabled = own != null and std.mem.eql(u8, own.?, dm);
            return ans;
        }
    }
    for (catalog.services) |s| {
        if (std.mem.eql(u8, s.unit, unit)) ans.service = s.name;
    }
    return ans;
}

/// the unit a service name stands for, when `name` is a service the
/// config or the catalog knows.
pub fn serviceUnit(c: *const config.Config, name: []const u8) ?[]const u8 {
    if (!config.knownService(c, name)) return null;
    if (c.services.get(name)) |s| return s.unitFor(name);
    return catalog.service(name).?.unit;
}

fn srcOf(cause: ?Cause) ?config.Src {
    return if (cause) |c| c.src else null;
}

fn writeCause(w: *std.Io.Writer, cause: Cause) !void {
    try w.writeAll(cause.key);
    if (cause.src) |s| try w.print("  ({s}:{d})", .{ s.file, s.line });
    try w.writeByte('\n');
}

pub fn writeFileText(w: *std.Io.Writer, ans: *const FileAnswer) !void {
    if (ans.cause) |cause| {
        try w.print("{s}: os {s} it for ", .{ ans.path, if (ans.partial) "adds a line to" else "writes" });
        return writeCause(w, cause);
    }
    try w.print("{s}: not managed by os", .{ans.path});
    if (ans.package) |p| try w.print("; it comes with {s}", .{p});
    try w.writeByte('\n');
    if (std.mem.startsWith(u8, ans.path, "/etc/")) try w.print("`os adopt {s}` takes it into the config\n", .{ans.path});
}

pub fn writeFileJson(w: *std.Io.Writer, ans: *const FileAnswer) !void {
    try output.writeDoc(w, file_schema, .{
        .path = ans.path,
        .managed = ans.cause != null,
        .how = if (ans.cause == null) null else if (ans.partial) "adds a line" else "writes",
        .cause = if (ans.cause) |c| c.key else null,
        .file = if (srcOf(ans.cause)) |s| s.file else null,
        .line = if (srcOf(ans.cause)) |s| s.line else null,
        .package = ans.package,
    });
}

pub fn writeUnitText(w: *std.Io.Writer, ans: *const UnitAnswer) !void {
    if (ans.cause) |cause| {
        try w.print("{s}: {s} by ", .{ ans.unit, if (ans.enabled.?) "enabled" else "disabled" });
        return writeCause(w, cause);
    }
    try w.print("{s}: the config leaves it alone\n", .{ans.unit});
    if (ans.service) |s| try w.print("`os enable {s}` manages it\n", .{s});
}

pub fn writeUnitJson(w: *std.Io.Writer, ans: *const UnitAnswer) !void {
    try output.writeDoc(w, unit_schema, .{
        .unit = ans.unit,
        .managed = ans.cause != null,
        .enabled = ans.enabled,
        .cause = if (ans.cause) |c| c.key else null,
        .file = if (srcOf(ans.cause)) |s| s.file else null,
        .line = if (srcOf(ans.cause)) |s| s.line else null,
        .service = ans.service,
    });
}

// -- tests --

const testing = std.testing;

const helpers = @import("test_helpers.zig");

fn lockPkg(name: []const u8, depends: []const []const u8) lock.Package {
    return helpers.lockPackage(name, "1", depends);
}

const test_lock: lock.Lock = .{ .sync_date = "2026-09-25", .keyring = "1", .packages = &.{
    lockPkg("curl", &.{ "glibc", "openssl" }),
    lockPkg("git", &.{ "curl", "glibc", "perl-error" }),
    lockPkg("glibc", &.{}),
    lockPkg("linux", &.{}),
    lockPkg("openssh", &.{ "glibc", "openssl" }),
    lockPkg("openssl", &.{"glibc"}),
    lockPkg("perl", &.{"glibc"}),
    lockPkg("perl-error", &.{"perl"}),
} };

fn run(src: []const u8, name: []const u8) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try helpers.configFrom(a, src);
    const ans = try explain(a, &c, &test_lock, name);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    try writeText(&out.writer, &ans);
    return out.toOwnedSlice();
}

fn expectWhy(src: []const u8, name: []const u8, want: []const u8) !void {
    const got = try run(src, name);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

const cfg = "packages = [\"git\"]\n[services]\nssh = true\n";

test "asked for directly" {
    try expectWhy(cfg, "git", "git: in packages  (machine.toml:1)\n");
}

test "implied by a service or the default kernel" {
    try expectWhy(cfg, "openssh", "openssh: from services.ssh  (machine.toml:3)\n");
    try expectWhy(cfg, "linux", "linux: from boot.kernel  (the default)\n");
}

test "a dependency takes the shortest chain" {
    try expectWhy(cfg, "perl",
        \\perl: needed by git -> perl-error -> perl
        \\git: in packages  (machine.toml:1)
        \\
    );
}

test "shared dependencies list their other dependents" {
    try expectWhy(cfg, "openssl",
        \\openssl: needed by openssh -> openssl
        \\openssh: from services.ssh  (machine.toml:3)
        \\also needed by 1 more: curl
        \\
    );
}

test "nothing needs it" {
    try expectWhy(cfg, "nano", "nano: nothing in the config needs it\n");
    try expectWhy("packages = [\"git\"]\n", "openssh", "openssh: nothing in the config needs it\n");
}

test "a directly wanted package lists every dependent" {
    try expectWhy("packages = [\"openssl\", \"curl\"]\n", "openssl",
        \\openssl: in packages  (machine.toml:1)
        \\also needed by 1 more: curl
        \\
    );
}

test "an argument's shape says what it names" {
    try testing.expectEqual(Kind.file, kindOf("/etc/motd"));
    try testing.expectEqual(Kind.unit, kindOf("sshd.service"));
    try testing.expectEqual(Kind.unit, kindOf("fstrim.timer"));
    try testing.expectEqual(Kind.unit, kindOf("docker.socket"));
    try testing.expectEqual(Kind.package, kindOf("git"));
}

fn expectFile(src: []const u8, path: []const u8, package: ?[]const u8, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try helpers.configFrom(a, src);
    var ans = try explainFile(a, &c, path);
    ans.package = package;
    var out: std.Io.Writer.Allocating = .init(a);
    try writeFileText(&out.writer, &ans);
    try testing.expectEqualStrings(want, out.written());
}

const files_cfg =
    \\packages = ["git"]
    \\[files."/etc/motd"]
    \\text = "hi\n"
    \\[sysctl]
    \\"vm.swappiness" = 10
    \\[boot]
    \\modules = ["i2c-dev"]
    \\[hardware]
    \\gpu = "nvidia"
    \\[repos.chaotic]
    \\server = "https://example.org/$repo/$arch"
    \\
;

test "files os writes name the key behind them" {
    try expectFile(files_cfg, "/etc/motd", null, "/etc/motd: os writes it for files.\"/etc/motd\"  (machine.toml:2)\n");
    try expectFile(files_cfg, "/etc/sysctl.d/99-yoq.conf", null, "/etc/sysctl.d/99-yoq.conf: os writes it for sysctl  (machine.toml:5)\n");
    try expectFile(files_cfg, "/etc/modules-load.d/99-yoq.conf", null, "/etc/modules-load.d/99-yoq.conf: os writes it for boot.modules  (machine.toml:7)\n");
    try expectFile(files_cfg, "/etc/mkinitcpio.conf.d/10-yoq-nvidia.conf", null, "/etc/mkinitcpio.conf.d/10-yoq-nvidia.conf: os writes it for hardware.gpu  (machine.toml:9)\n");
    try expectFile(files_cfg, "/etc/pacman.d/yoq-repos.conf", null, "/etc/pacman.d/yoq-repos.conf: os writes it for repos  (machine.toml:10)\n");
    try expectFile(files_cfg, "/etc/pacman.conf", null, "/etc/pacman.conf: os adds a line to it for repos  (machine.toml:10)\n");
    try expectFile("[desktop]\nsession = \"hyprland\"\nlogin = \"greetd\"\n", "/etc/greetd/config.toml", null, "/etc/greetd/config.toml: os writes it for desktop.login  (machine.toml:3)\n");
}

test "files os leaves alone say where they come from" {
    try expectFile(files_cfg, "/etc/ssh/sshd_config", "openssh",
        \\/etc/ssh/sshd_config: not managed by os; it comes with openssh
        \\`os adopt /etc/ssh/sshd_config` takes it into the config
        \\
    );
    try expectFile("", "/etc/pacman.conf", "pacman",
        \\/etc/pacman.conf: not managed by os; it comes with pacman
        \\`os adopt /etc/pacman.conf` takes it into the config
        \\
    );
    try expectFile("", "/usr/bin/ssh", null, "/usr/bin/ssh: not managed by os\n");
}

fn expectUnit(src: []const u8, unit: []const u8, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try helpers.configFrom(a, src);
    const ans = try explainUnit(a, &c, unit);
    var out: std.Io.Writer.Allocating = .init(a);
    try writeUnitText(&out.writer, &ans);
    try testing.expectEqualStrings(want, out.written());
}

const units_cfg =
    \\[desktop]
    \\session = "hyprland"
    \\login = "sddm"
    \\[services]
    \\ssh = true
    \\bluetooth = false
    \\[services.web]
    \\unit = "caddy.service"
    \\package = "caddy"
    \\
;

test "units name the key that enables or disables them" {
    try expectUnit(units_cfg, "sshd.service", "sshd.service: enabled by services.ssh  (machine.toml:5)\n");
    try expectUnit(units_cfg, "bluetooth.service", "bluetooth.service: disabled by services.bluetooth  (machine.toml:6)\n");
    try expectUnit(units_cfg, "caddy.service", "caddy.service: enabled by services.web  (machine.toml:7)\n");
    try expectUnit(units_cfg, "sddm.service", "sddm.service: enabled by desktop.login  (machine.toml:3)\n");
    try expectUnit(units_cfg, "gdm.service", "gdm.service: disabled by desktop.login  (machine.toml:3)\n");
}

test "units the config leaves alone" {
    try expectUnit(units_cfg, "cups.service", "cups.service: the config leaves it alone\n`os enable cups` manages it\n");
    try expectUnit("", "gdm.service", "gdm.service: the config leaves it alone\n");
    try expectUnit("", "foo.timer", "foo.timer: the config leaves it alone\n");
}

test "a service name stands for its unit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try helpers.configFrom(arena.allocator(), units_cfg);
    try testing.expectEqualStrings("sshd.service", serviceUnit(&c, "ssh").?);
    try testing.expectEqualStrings("tailscaled.service", serviceUnit(&c, "tailscale").?);
    try testing.expectEqualStrings("caddy.service", serviceUnit(&c, "web").?);
    try testing.expectEqual(null, serviceUnit(&c, "git"));
}
