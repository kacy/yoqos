//! secrets: values a managed file holds that stay out of the config and
//! the lock, like a wifi password. `[files."<path>"] secret = "<name>"`
//! names one, and `os secret set <name>` keeps its value here.
//!
//! values are encrypted with systemd-creds under /var/lib/yoq/secrets.
//! /var never rolls back, so they outlive every generation, and they're
//! this machine's: another machine can't decrypt them, so a new one needs
//! them set again.
//!
//! plans never hold a value. they compare a keyed hash, hmac-sha256 under
//! a key that stays in that directory, so a plan or facts document can be
//! published without anyone checking guesses against a short value.

const std = @import("std");
const exec = @import("exec.zig");
const rootfs = @import("rootfs.zig");
const lists = @import("lists.zig");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

pub const default_dir = "/var/lib/yoq/secrets";
/// the key keyed hashes are made with, beside the values. no secret's
/// name can start with a dot, so none can be called that.
const key_file = ".key";
const ext = ".cred";
/// the largest value os keeps.
pub const max_len = 64 << 10;

pub const Key = [32]u8;

/// why `n` can't name a secret, or null if it can: letters, digits, and
/// -_. in parts split by /, none of them empty or starting with a dot.
/// names become paths under the secrets directory, so this keeps them
/// inside it, and away from the machine key.
pub fn nameProblem(n: []const u8) ?[]const u8 {
    const rule = "secret names are letters, digits, -, _, and ., with / to group them, like wifi/home";
    if (n.len == 0 or n.len > 128) return rule;
    var parts = std.mem.splitScalar(u8, n, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or part[0] == '.') return "each part of the name, between the slashes, needs a first character that isn't a dot";
        for (part) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "-_.", ch) == null) return rule;
        }
    }
    return null;
}

/// hmac-sha256 of `bytes` under the machine's key, in hex.
pub fn keyedHex(key: *const Key, bytes: []const u8) [64]u8 {
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, bytes, key);
    return std.fmt.bytesToHex(mac, .lower);
}

/// zeroes a value once it's been used, in a way the compiler keeps.
pub fn wipe(value: []u8) void {
    std.crypto.secureZero(u8, value);
}

/// a secret as `os secret` reports it, never with its value. `os secret
/// set` and `rm` print one with --json, and `os secret list` a list.
pub const Entry = struct {
    name: []const u8,
    /// this machine keeps a value for it.
    set: bool,
    /// the files the config writes it to.
    files: []const []const u8 = &.{},
};

pub const entry_schema = "yoq.secret/1";
pub const list_schema = "yoq.secrets/1";
pub const List = struct { secrets: []const Entry };

/// what looking a secret up found.
pub const Lookup = union(enum) {
    /// the value, in a buffer the caller wipes when it's done.
    value: []u8,
    /// `os secret set` hasn't kept one by that name.
    missing,
    /// it's there, but can't be decrypted here: systemd-creds' reason.
    unreadable: []const u8,
    /// this process can't look, not being root.
    unknown,
};

/// where secrets are kept. the real one runs systemd-creds; tests use
/// `Memory`.
pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        problem: *const fn (ptr: *anyopaque) ?[]const u8,
        get: *const fn (ptr: *anyopaque, a: Allocator, name: []const u8) error{OutOfMemory}!Lookup,
        set: *const fn (ptr: *anyopaque, a: Allocator, name: []const u8, value: []const u8) error{OutOfMemory}!?[]const u8,
        remove: *const fn (ptr: *anyopaque, a: Allocator, name: []const u8) error{OutOfMemory}!?[]const u8,
        names: *const fn (ptr: *anyopaque, a: Allocator) error{OutOfMemory}![]const []const u8,
        key: *const fn (ptr: *anyopaque, a: Allocator) error{OutOfMemory}!?Key,
        /// makes a new key, over any there is. false when it can't.
        make_key: *const fn (ptr: *anyopaque, a: Allocator) error{OutOfMemory}!bool,
    };

    /// why this process can't read or change secrets, or null if it can.
    pub fn problem(s: Store) ?[]const u8 {
        return s.vtable.problem(s.ptr);
    }

    pub fn get(s: Store, a: Allocator, name: []const u8) !Lookup {
        return s.vtable.get(s.ptr, a, name);
    }

    /// keeps `value` for `name`, making the machine key first if there's
    /// none yet. null when it worked, or why it didn't.
    pub fn set(s: Store, a: Allocator, name: []const u8, value: []const u8) !?[]const u8 {
        return s.vtable.set(s.ptr, a, name, value);
    }

    /// forgets `name`. null when it worked, or why it didn't, like there
    /// being no such secret.
    pub fn remove(s: Store, a: Allocator, name: []const u8) !?[]const u8 {
        return s.vtable.remove(s.ptr, a, name);
    }

    /// every secret kept, sorted.
    pub fn names(s: Store, a: Allocator) ![]const []const u8 {
        return s.vtable.names(s.ptr, a);
    }

    /// the machine's key, or null when there's none yet or it can't be
    /// read. values kept without one, like a directory restored without
    /// its dotfiles, get a new one: with no key, a file that doesn't hold
    /// its value would look like it does.
    pub fn key(s: Store, a: Allocator) !?Key {
        if (try s.vtable.key(s.ptr, a)) |k| return k;
        if (s.problem() != null or (try s.names(a)).len == 0) return null;
        if (!try s.vtable.make_key(s.ptr, a)) return null;
        return s.vtable.key(s.ptr, a);
    }
};

fn noSecret(a: Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "there's no secret called {s}. `os secret list` lists them", .{name});
}

/// the real store: one systemd-creds file per secret under `dir`, made
/// with systemd-creds' default keys (the host's credential key, and the
/// tpm2 too when the machine has one), but bound to no pcrs. its default,
/// pcr 7, is the secure boot state, and turning secure boot on would
/// leave every value unreadable.
pub const System = struct {
    io: std.Io,
    dir: []const u8 = default_dir,

    pub fn store(s: *System) Store {
        return .{ .ptr = s, .vtable = &.{ .problem = problem, .get = get, .set = set, .remove = remove, .names = names, .key = key, .make_key = makeKey } };
    }

    fn of(ptr: *anyopaque) *System {
        return @ptrCast(@alignCast(ptr));
    }

    fn credPath(s: *const System, a: Allocator, name: []const u8) ![:0]const u8 {
        return std.fmt.allocPrintSentinel(a, "{s}/{s}" ++ ext, .{ s.dir, name }, 0);
    }

    fn keyPath(s: *const System, a: Allocator) ![]const u8 {
        return std.fs.path.join(a, &.{ s.dir, key_file });
    }

    /// the name sealed into the credential, which decrypting checks, so a
    /// file renamed to another secret's name won't decrypt. systemd's
    /// names can't hold a /, and @ can't be in os's names.
    fn nameFlag(a: Allocator, name: []const u8) ![]const u8 {
        const flag = try std.fmt.allocPrint(a, "--name={s}", .{name});
        std.mem.replaceScalar(u8, flag, '/', '@');
        return flag;
    }

    /// encrypts stdin into `out`. the empty pcr list ties the credential
    /// to the machine's tpm2 and host key, not to what it booted.
    fn encryptArgv(a: Allocator, name: []const u8, out: []const u8) ![]const []const u8 {
        return a.dupe([]const u8, &.{ "systemd-creds", "encrypt", try nameFlag(a, name), "--tpm2-pcrs=", "-", out });
    }

    /// decrypts `path` to stdout. the credential carries its own policy,
    /// so this needs no key or pcr flags.
    fn decryptArgv(a: Allocator, name: []const u8, path: []const u8) ![]const []const u8 {
        return a.dupe([]const u8, &.{ "systemd-creds", "decrypt", "--newline=no", try nameFlag(a, name), path, "-" });
    }

    fn problem(_: *anyopaque) ?[]const u8 {
        return if (linux.geteuid() == 0) null else "secrets are root's, so this needs root";
    }

    fn get(ptr: *anyopaque, a: Allocator, name: []const u8) error{OutOfMemory}!Lookup {
        const s = of(ptr);
        if (problem(ptr) != null) return .unknown;
        const path = try s.credPath(a, name);
        if (!rootfs.pathExists(s.io, path)) return .missing;
        const buf = try a.alloc(u8, max_len + 1);
        switch (try exec.capture(a, s.io, try decryptArgv(a, name, path), buf)) {
            .ok => |v| return .{ .value = v },
            .failed => |why| {
                wipe(buf);
                return .{ .unreadable = why };
            },
        }
    }

    fn set(ptr: *anyopaque, a: Allocator, name: []const u8, value: []const u8) error{OutOfMemory}!?[]const u8 {
        const s = of(ptr);
        if (problem(ptr)) |why| return why;
        const path = try s.credPath(a, name);
        if (!try s.makeDirs(a, std.fs.path.dirnamePosix(path).?)) return try std.fmt.allocPrint(a, "can't make {s}", .{s.dir});
        if (try key(ptr, a) == null and !try makeKey(ptr, a)) return try std.fmt.allocPrint(a, "can't write {s}", .{try s.keyPath(a)});
        const tmp = try std.fmt.allocPrintSentinel(a, "{s}.os-tmp", .{path}, 0);
        // one left by a crash goes first, and one left by a failure here
        // goes after. once renamed, there's nothing left to remove.
        _ = linux.unlink(tmp);
        defer _ = linux.unlink(tmp);
        if (try exec.feed(a, s.io, try encryptArgv(a, name, tmp), value)) |why| return why;
        if (!commit(tmp, path)) return try std.fmt.allocPrint(a, "can't write {s}", .{path});
        return null;
    }

    /// puts the credential systemd-creds wrote at `tmp` in place at
    /// `path`, readable by root alone: synced first, renamed, and the
    /// directory synced, so a power cut leaves the old value or the new
    /// one, never an empty file under the secret's name.
    fn commit(tmp: [:0]const u8, path: [:0]const u8) bool {
        const opened = linux.open(tmp, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true }, 0);
        if (linux.errno(opened) != .SUCCESS) return false;
        const fd: linux.fd_t = @intCast(opened);
        const synced = linux.errno(linux.fchmod(fd, 0o600)) == .SUCCESS and linux.errno(linux.fsync(fd)) == .SUCCESS;
        _ = linux.close(fd);
        if (!synced or linux.errno(linux.rename(tmp, path)) != .SUCCESS) return false;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = std.fmt.bufPrintZ(&buf, "{s}", .{std.fs.path.dirnamePosix(path) orelse "."}) catch return true;
        const dfd = linux.open(dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
        if (linux.errno(dfd) != .SUCCESS) return true;
        defer _ = linux.close(@intCast(dfd));
        return linux.errno(linux.fsync(@intCast(dfd))) == .SUCCESS;
    }

    /// makes the secrets directory and the ones under it down to `to`,
    /// readable by root alone.
    fn makeDirs(s: *const System, a: Allocator, to: []const u8) !bool {
        if (std.fs.path.dirnamePosix(s.dir)) |parent| std.Io.Dir.cwd().createDirPath(s.io, parent) catch return false;
        var at: usize = s.dir.len;
        while (true) {
            const z = try a.dupeZ(u8, to[0..at]);
            switch (linux.errno(linux.mkdir(z, 0o700))) {
                .SUCCESS, .EXIST => {},
                else => return false,
            }
            if (at == s.dir.len and linux.errno(linux.chmod(z, 0o700)) != .SUCCESS) return false;
            if (at == to.len) return true;
            at = std.mem.indexOfScalarPos(u8, to, at + 1, '/') orelse to.len;
        }
    }

    fn makeKey(ptr: *anyopaque, a: Allocator) error{OutOfMemory}!bool {
        const s = of(ptr);
        var k: Key = undefined;
        defer wipe(&k);
        s.io.randomSecure(&k) catch return false;
        rootfs.writeAtomic(s.io, try s.keyPath(a), &k, 0o600) catch return false;
        return true;
    }

    fn key(ptr: *anyopaque, a: Allocator) error{OutOfMemory}!?Key {
        const s = of(ptr);
        var k: Key = undefined;
        const f = std.Io.Dir.cwd().openFile(s.io, try s.keyPath(a), .{}) catch return null;
        defer f.close(s.io);
        const n = f.readPositionalAll(s.io, &k, 0) catch return null;
        return if (n == k.len) k else null;
    }

    fn remove(ptr: *anyopaque, a: Allocator, name: []const u8) error{OutOfMemory}!?[]const u8 {
        const s = of(ptr);
        if (problem(ptr)) |why| return why;
        const path = try s.credPath(a, name);
        switch (linux.errno(linux.unlink(path))) {
            .SUCCESS => {},
            .NOENT => return try noSecret(a, name),
            else => return try std.fmt.allocPrint(a, "can't remove {s}", .{path}),
        }
        // the directories that grouped it, once they're empty.
        var dir = std.fs.path.dirnamePosix(path).?;
        while (dir.len > s.dir.len) : (dir = std.fs.path.dirnamePosix(dir).?) {
            if (linux.errno(linux.rmdir(try a.dupeZ(u8, dir))) != .SUCCESS) break;
        }
        return null;
    }

    fn names(ptr: *anyopaque, a: Allocator) error{OutOfMemory}![]const []const u8 {
        const s = of(ptr);
        var out: std.ArrayList([]const u8) = .empty;
        var d = std.Io.Dir.cwd().openDir(s.io, s.dir, .{ .iterate = true }) catch return out.items;
        defer d.close(s.io);
        var walker = try d.walk(a);
        defer walker.deinit();
        while (walker.next(s.io) catch null) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.path, ext)) continue;
            const name = e.path[0 .. e.path.len - ext.len];
            if (nameProblem(name) == null) try out.append(a, try a.dupe(u8, name));
        }
        lists.sortStrings(out.items);
        return out.items;
    }
};

/// a store in memory, for tests.
pub const Memory = struct {
    arena: std.heap.ArenaAllocator,
    values: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    machine_key: ?Key = null,
    /// names kept that won't decrypt, as if copied from another machine.
    broken: []const []const u8 = &.{},
    /// what `problem` says, as for someone who isn't root.
    refuse: ?[]const u8 = null,

    pub fn init(gpa: Allocator) Memory {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(m: *Memory) void {
        m.arena.deinit();
    }

    pub fn store(m: *Memory) Store {
        return .{ .ptr = m, .vtable = &.{ .problem = problem, .get = get, .set = set, .remove = remove, .names = names, .key = key, .make_key = makeKey } };
    }

    fn of(ptr: *anyopaque) *Memory {
        return @ptrCast(@alignCast(ptr));
    }

    fn problem(ptr: *anyopaque) ?[]const u8 {
        return of(ptr).refuse;
    }

    fn get(ptr: *anyopaque, a: Allocator, name: []const u8) error{OutOfMemory}!Lookup {
        const m = of(ptr);
        if (m.refuse != null) return .unknown;
        if (lists.contains(m.broken, name)) return .{ .unreadable = "the credential can't be decrypted here" };
        return .{ .value = try a.dupe(u8, m.values.get(name) orelse return .missing) };
    }

    fn set(ptr: *anyopaque, _: Allocator, name: []const u8, value: []const u8) error{OutOfMemory}!?[]const u8 {
        const m = of(ptr);
        if (m.refuse) |why| return why;
        if (m.machine_key == null) m.machine_key = @splat(0x5a);
        const a = m.arena.allocator();
        try m.values.put(a, try a.dupe(u8, name), try a.dupe(u8, value));
        return null;
    }

    fn remove(ptr: *anyopaque, a: Allocator, name: []const u8) error{OutOfMemory}!?[]const u8 {
        const m = of(ptr);
        if (m.refuse) |why| return why;
        return if (m.values.orderedRemove(name)) null else try noSecret(a, name);
    }

    fn names(ptr: *anyopaque, a: Allocator) error{OutOfMemory}![]const []const u8 {
        const out = try a.dupe([]const u8, of(ptr).values.keys());
        lists.sortStrings(out);
        return out;
    }

    fn key(ptr: *anyopaque, _: Allocator) error{OutOfMemory}!?Key {
        return of(ptr).machine_key;
    }

    fn makeKey(ptr: *anyopaque, _: Allocator) error{OutOfMemory}!bool {
        of(ptr).machine_key = @splat(0xa5);
        return true;
    }
};

const testing = std.testing;

test "a new credential goes in place synced, readable by root alone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var a_buf: [256]u8 = undefined;
    var b_buf: [256]u8 = undefined;
    const from = try std.fmt.bufPrintZ(&a_buf, ".zig-cache/tmp/{s}/home.cred.os-tmp", .{tmp.sub_path});
    const to = try std.fmt.bufPrintZ(&b_buf, ".zig-cache/tmp/{s}/home.cred", .{tmp.sub_path});
    try tmp.dir.writeFile(io, .{ .sub_path = "home.cred.os-tmp", .data = "sealed" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home.cred", .data = "older" });
    try std.testing.expect(System.commit(from, to));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("sealed", try tmp.dir.readFile(io, "home.cred", &buf));
    try std.testing.expectEqual(0o600, @intFromEnum((try tmp.dir.statFile(io, "home.cred", .{})).permissions) & 0o777);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "home.cred.os-tmp", .{}));
    // nothing there to put in place leaves the old value.
    try std.testing.expect(!System.commit(from, to));
    try std.testing.expectEqualStrings("sealed", try tmp.dir.readFile(io, "home.cred", &buf));
}

test "secret names" {
    for ([_][]const u8{ "wifi", "wifi/home", "a.b-c_d/e1", "x/y/z" }) |n| try testing.expectEqual(null, nameProblem(n));
    for ([_][]const u8{ "", "/wifi", "wifi/", "a//b", "../x", "a/../b", "a/./b", ".key", "a/.hidden", "has space", "a\nb", "a:b", "a@b", "a" ** 129 }) |n| {
        try testing.expect(nameProblem(n) != null);
    }
}

test "keyed hashes depend on the key" {
    const k1: Key = @splat(1);
    const k2: Key = @splat(2);
    try testing.expect(!std.mem.eql(u8, &keyedHex(&k1, "hunter2"), &keyedHex(&k2, "hunter2")));
    try testing.expectEqualStrings(&keyedHex(&k1, "hunter2"), &keyedHex(&k1, "hunter2"));
    var plain: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("hunter2", &plain, .{});
    try testing.expect(!std.mem.eql(u8, &keyedHex(&k1, "hunter2"), &std.fmt.bytesToHex(plain, .lower)));
}

test "the memory store" {
    var m: Memory = .init(testing.allocator);
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = m.store();
    try testing.expectEqual(null, try s.key(a));
    try testing.expectEqual(.missing, std.meta.activeTag(try s.get(a, "wifi/home")));
    try testing.expectEqual(null, try s.set(a, "wifi/home", "hunter2"));
    try testing.expect(try s.key(a) != null);
    try testing.expectEqualStrings("hunter2", (try s.get(a, "wifi/home")).value);
    try testing.expectEqualStrings("wifi/home", (try s.names(a))[0]);
    try testing.expectEqual(null, try s.remove(a, "wifi/home"));
    try testing.expect(try s.remove(a, "wifi/home") != null);
}

test "systemd-creds runs bound to no pcrs, with its default keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const enc = try System.encryptArgv(a, "wifi/home", "/s/wifi/home.cred.os-tmp");
    const want_enc = [_][]const u8{ "systemd-creds", "encrypt", "--name=wifi@home", "--tpm2-pcrs=", "-", "/s/wifi/home.cred.os-tmp" };
    try testing.expectEqual(want_enc.len, enc.len);
    for (want_enc, enc) |w, g| try testing.expectEqualStrings(w, g);
    for (enc) |arg| try testing.expect(!std.mem.startsWith(u8, arg, "--with-key"));
    const dec = try System.decryptArgv(a, "wifi/home", "/s/wifi/home.cred");
    const want_dec = [_][]const u8{ "systemd-creds", "decrypt", "--newline=no", "--name=wifi@home", "/s/wifi/home.cred", "-" };
    try testing.expectEqual(want_dec.len, dec.len);
    for (want_dec, dec) |w, g| try testing.expectEqualStrings(w, g);
}

test "the systemd-creds store, as root" {
    if (linux.geteuid() != 0) return error.SkipZigTest;
    // systemd-creds needs a running systemd: a container's root has none.
    std.Io.Dir.cwd().access(testing.io, "/run/systemd/system", .{}) catch return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sys: System = .{ .io = testing.io, .dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/secrets", .{tmp.sub_path}) };
    const s = sys.store();
    if (try s.set(a, "wifi/home", "hunter2")) |why| {
        if (std.mem.indexOf(u8, why, "systemd-creds") != null) return error.SkipZigTest;
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("hunter2", (try s.get(a, "wifi/home")).value);
    try testing.expect(try s.key(a) != null);
    try testing.expectEqualStrings("wifi/home", (try s.names(a))[0]);
    try testing.expectEqual(null, try s.remove(a, "wifi/home"));
    try testing.expectEqual(.missing, std.meta.activeTag(try s.get(a, "wifi/home")));
}
