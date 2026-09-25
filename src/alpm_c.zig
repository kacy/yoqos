//! the libalpm side of alpm.zig. only compiled when libalpm is linked
//! (`-Dalpm`).

const std = @import("std");
const facts = @import("facts.zig");
const lock = @import("lock.zig");
const diag = @import("diag.zig");
const api = @import("alpm.zig");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("alpm.h");
    @cInclude("stdio.h");
});
const Error = api.Error;
const ResolveInput = api.ResolveInput;
const Resolved = api.Resolved;

/// a libalpm handle on one root and database directory.
const Handle = struct {
    h: *c.alpm_handle_t,

    fn open(a: Allocator, root: []const u8, dbpath: []const u8, diags: *diag.List) Error!?Handle {
        var err: c.alpm_errno_t = 0;
        const h = c.alpm_initialize((try a.dupeZ(u8, root)).ptr, (try a.dupeZ(u8, dbpath)).ptr, &err) orelse {
            try diags.add(.alpm_failed, null, "can't open the package database at {s}: {s}", .{ dbpath, std.mem.span(c.alpm_strerror(err)) }, null);
            return null;
        };
        return .{ .h = h };
    }

    fn close(h: Handle) void {
        _ = c.alpm_release(h.h);
    }

    fn lastError(h: Handle) []const u8 {
        return std.mem.span(c.alpm_strerror(c.alpm_errno(h.h)));
    }

    const configure = configureImpl;
    const run = runImpl;
};

fn listItems(comptime T: type, list: ?*c.alpm_list_t) ListIter(T) {
    return .{ .node = list };
}

fn ListIter(comptime T: type) type {
    return struct {
        node: ?*c.alpm_list_t,

        fn next(it: *@This()) ?*T {
            const n = it.node orelse return null;
            it.node = n.next;
            return @ptrCast(@alignCast(n.data));
        }
    };
}

fn str(p: [*c]const u8) []const u8 {
    return if (p == null) "" else std.mem.span(p);
}

pub fn localPackages(a: Allocator, root: []const u8, dbpath: []const u8, diags: *diag.List) Error!?[]facts.Package {
    const h = try Handle.open(a, root, dbpath, diags) orelse return null;
    defer h.close();
    var out: std.ArrayList(facts.Package) = .empty;
    var it = listItems(c.alpm_pkg_t, c.alpm_db_get_pkgcache(c.alpm_get_localdb(h.h)));
    while (it.next()) |p| {
        try out.append(a, .{
            .name = try a.dupe(u8, str(c.alpm_pkg_get_name(p))),
            .version = try a.dupe(u8, str(c.alpm_pkg_get_version(p))),
            .reason = if (c.alpm_pkg_get_reason(p) == c.ALPM_PKG_REASON_DEPEND) .dependency else .explicit,
        });
    }
    return out.items;
}

/// what libalpm asked while resolving, and how it was answered.
const Questions = struct {
    a: Allocator,
    providers: []const lock.Provider,
    chosen: std.ArrayList(lock.Provider) = .empty,
    /// virtual packages with several providers and no choice in the config.
    open: std.ArrayList(api.Choice) = .empty,
    failed: bool = false,

    fn answer(ctx: ?*anyopaque, q_ptr: [*c]c.alpm_question_t) callconv(.c) void {
        const self: *Questions = @ptrCast(@alignCast(ctx));
        const q: *c.alpm_question_t = q_ptr;
        if (q.type != c.ALPM_QUESTION_SELECT_PROVIDER) {
            // conflicts, replacements, and the like: the answer is always no.
            q.any.answer = 0;
            return;
        }
        const sp: *c.alpm_question_select_provider_t = &q.select_provider;
        const depend: *c.alpm_depend_t = sp.depend;
        const dep = str(depend.name);
        self.selectProvider(sp, dep) catch {
            self.failed = true;
        };
    }

    fn isOpen(self: *const Questions, name: []const u8) bool {
        for (self.open.items) |o| {
            if (std.mem.eql(u8, o.name, name)) return true;
        }
        return false;
    }

    fn selectProvider(self: *Questions, sp: *c.alpm_question_select_provider_t, dep: []const u8) !void {
        var names: std.ArrayList([]const u8) = .empty;
        var it = listItems(c.alpm_pkg_t, sp.providers);
        while (it.next()) |p| try names.append(self.a, try self.a.dupe(u8, str(c.alpm_pkg_get_name(p))));
        sp.use_index = 0;
        for (self.providers) |choice| {
            if (!std.mem.eql(u8, choice.name, dep)) continue;
            for (names.items, 0..) |n, i| {
                if (!std.mem.eql(u8, n, choice.chosen)) continue;
                sp.use_index = @intCast(i);
                try self.chosen.append(self.a, choice);
                return;
            }
        }
        try self.open.append(self.a, .{ .name = try self.a.dupe(u8, dep), .options = names.items });
    }
};

pub fn resolve(a: Allocator, io: std.Io, in: ResolveInput, diags: *diag.List) Error!Resolved {
    const scratch = try Scratch.make(a, io, in, diags) orelse return .failed;
    const h = try Handle.open(a, scratch.root, scratch.dbpath, diags) orelse return .failed;
    defer h.close();
    var questions: Questions = .{ .a = a, .providers = in.providers };
    _ = c.alpm_option_set_questioncb(h.h, Questions.answer, &questions);
    for (in.dbs) |db| {
        if (c.alpm_register_syncdb(h.h, (try a.dupeZ(u8, db.name)).ptr, 0) == null) {
            try diags.add(.alpm_failed, null, "can't load the {s} database: {s}", .{ db.name, h.lastError() }, null);
            return .failed;
        }
    }

    // a dependency that names a real package gets that package, even when
    // something already in the set provides the name: curl needs
    // ca-certificates, which ca-certificates-utils also provides. that's
    // what an installed arch has, and it doesn't hang on the order
    // libalpm adds things. resolve again until nothing's missing.
    var targets: std.ArrayList([]const u8) = .empty;
    try targets.appendSlice(a, in.wants);
    while (true) {
        questions = .{ .a = a, .providers = in.providers };
        if (!try prepare(a, h, targets.items, &questions, diags)) return .failed;
        const before = targets.items.len;
        try namedDepends(a, h, &targets);
        if (targets.items.len == before) break;
        _ = c.alpm_trans_release(h.h);
    }
    defer _ = c.alpm_trans_release(h.h);
    if (questions.open.items.len > 0) return .{ .choose = questions.open.items };

    var l: lock.Lock = .{
        .sync_date = in.sync_date,
        .keyring = try keyringVersion(a, h),
        .providers = questions.chosen.items,
        .packages = try lockPackages(a, c.alpm_trans_get_add(h.h)),
    };
    try lock.normalize(a, &l);
    return .{ .lock = l };
}

/// starts a transaction for `targets` and resolves it. on success the
/// transaction stays open for the caller to release.
fn prepare(a: Allocator, h: Handle, targets: []const []const u8, questions: *Questions, diags: *diag.List) Error!bool {
    if (c.alpm_trans_init(h.h, 0) != 0) {
        try diags.add(.alpm_failed, null, "can't start resolving: {s}", .{h.lastError()}, null);
        return false;
    }
    var ok = false;
    defer if (!ok) {
        _ = c.alpm_trans_release(h.h);
    };
    if (!try addWants(a, h, targets, questions, diags)) return false;
    var data: ?*c.alpm_list_t = null;
    if (c.alpm_trans_prepare(h.h, &data) != 0) {
        try reportPrepare(h, data, diags);
        return false;
    }
    ok = true;
    return true;
}

/// an empty root with an empty local database and copies of the sync ones,
/// so resolving sees everything as not installed.
const Scratch = struct {
    root: []const u8,
    dbpath: []const u8,

    fn make(a: Allocator, io: std.Io, in: ResolveInput, diags: *diag.List) Error!?Scratch {
        const cwd = std.Io.Dir.cwd();
        const s: Scratch = .{
            .root = try std.fs.path.join(a, &.{ in.scratch, "root" }),
            .dbpath = try std.fs.path.join(a, &.{ in.scratch, "db" }),
        };
        const sync_dir = try std.fs.path.join(a, &.{ s.dbpath, "sync" });
        const local_dir = try std.fs.path.join(a, &.{ s.dbpath, "local" });
        for ([_][]const u8{ s.root, sync_dir, local_dir }) |d| cwd.createDirPath(io, d) catch return scratchFailed(diags, d);
        const version = try std.fs.path.join(a, &.{ local_dir, "ALPM_DB_VERSION" });
        cwd.writeFile(io, .{ .sub_path = version, .data = "9\n" }) catch return scratchFailed(diags, version);
        for (in.dbs) |db| {
            const bytes = cwd.readFileAlloc(io, db.path, a, .limited(256 << 20)) catch {
                try diags.add(.alpm_failed, null, "can't read the {s} database at {s}", .{ db.name, db.path }, null);
                return null;
            };
            const dest = try std.fmt.allocPrint(a, "{s}/{s}.db", .{ sync_dir, db.name });
            cwd.writeFile(io, .{ .sub_path = dest, .data = bytes }) catch return scratchFailed(diags, dest);
        }
        return s;
    }

    fn scratchFailed(diags: *diag.List, path: []const u8) Error!?Scratch {
        try diags.add(.alpm_failed, null, "can't set up a scratch root for resolving at {s}", .{path}, null);
        return null;
    }
};

/// adds each wanted package to the transaction. returns false if one isn't
/// in any sync database.
fn addWants(a: Allocator, h: Handle, wants: []const []const u8, questions: *const Questions, diags: *diag.List) Error!bool {
    const syncdbs = c.alpm_get_syncdbs(h.h);
    var ok = true;
    for (wants) |w| {
        const p = c.alpm_find_dbs_satisfier(h.h, syncdbs, (try a.dupeZ(u8, w)).ptr) orelse {
            // a virtual package with an open provider question is reported
            // with the other questions, not as missing.
            if (questions.isOpen(w)) continue;
            try diags.add(.unresolvable, null, "no package called {s} in the sync databases", .{w}, null);
            ok = false;
            continue;
        };
        _ = c.alpm_add_pkg(h.h, p);
    }
    return ok and !questions.failed;
}

/// adds to `targets` each package a dependency names that the transaction
/// leaves out.
fn namedDepends(a: Allocator, h: Handle, targets: *std.ArrayList([]const u8)) Error!void {
    const adds = c.alpm_trans_get_add(h.h);
    var it = listItems(c.alpm_pkg_t, adds);
    while (it.next()) |p| {
        var di = listItems(c.alpm_depend_t, c.alpm_pkg_get_depends(p));
        while (di.next()) |d| {
            if (d.mod != c.ALPM_DEP_MOD_ANY or c.alpm_pkg_find(adds, d.name) != null) continue;
            var dbs = listItems(c.alpm_db_t, c.alpm_get_syncdbs(h.h));
            while (dbs.next()) |db| {
                if (c.alpm_db_get_pkg(db, d.name) == null) continue;
                try targets.append(a, try a.dupe(u8, str(d.name)));
                break;
            }
        }
    }
}

/// every package the transaction would install, with each dependency
/// resolved to the package that satisfies it.
fn lockPackages(a: Allocator, adds: ?*c.alpm_list_t) Error![]const lock.Package {
    var packages: std.ArrayList(lock.Package) = .empty;
    var it = listItems(c.alpm_pkg_t, adds);
    while (it.next()) |p| {
        var deps: std.ArrayList([]const u8) = .empty;
        var di = listItems(c.alpm_depend_t, c.alpm_pkg_get_depends(p));
        while (di.next()) |d| {
            const s = c.alpm_dep_compute_string(d);
            defer std.c.free(s);
            const named = if (d.mod == c.ALPM_DEP_MOD_ANY) c.alpm_pkg_find(adds, d.name) else null;
            const sat = named orelse c.alpm_find_satisfier(adds, s) orelse continue;
            // `bash` and `sh` can both resolve to bash; list it once.
            const name = str(c.alpm_pkg_get_name(sat));
            for (deps.items) |seen| {
                if (std.mem.eql(u8, seen, name)) break;
            } else try deps.append(a, try a.dupe(u8, name));
        }
        try packages.append(a, .{
            .name = try a.dupe(u8, str(c.alpm_pkg_get_name(p))),
            .version = try a.dupe(u8, str(c.alpm_pkg_get_version(p))),
            .repo = try a.dupe(u8, str(c.alpm_db_get_name(c.alpm_pkg_get_db(p)))),
            .sha256 = try a.dupe(u8, str(c.alpm_pkg_get_sha256sum(p))),
            .depends = deps.items,
        });
    }
    return packages.items;
}

/// the archlinux-keyring version in the sync databases, or "none".
fn keyringVersion(a: Allocator, h: Handle) Error![]const u8 {
    var dbs = listItems(c.alpm_db_t, c.alpm_get_syncdbs(h.h));
    while (dbs.next()) |db| {
        const p = c.alpm_db_get_pkg(db, "archlinux-keyring") orelse continue;
        return a.dupe(u8, str(c.alpm_pkg_get_version(p)));
    }
    return "none";
}

fn reportPrepare(h: Handle, data: ?*c.alpm_list_t, diags: *diag.List) !void {
    switch (c.alpm_errno(h.h)) {
        c.ALPM_ERR_UNSATISFIED_DEPS => {
            var it = listItems(c.alpm_depmissing_t, data);
            while (it.next()) |m| {
                const s = c.alpm_dep_compute_string(m.depend);
                defer std.c.free(s);
                try diags.add(.unresolvable, null, "{s} needs {s}, which no sync database provides", .{ str(m.target), str(s) }, null);
            }
        },
        c.ALPM_ERR_CONFLICTING_DEPS => {
            var it = listItems(c.alpm_conflict_t, data);
            while (it.next()) |conf| {
                try diags.add(.unresolvable, null, "{s} and {s} conflict", .{ str(c.alpm_pkg_get_name(conf.package1)), str(c.alpm_pkg_get_name(conf.package2)) }, "remove one of them from the config");
            }
        },
        else => try diags.add(.alpm_failed, null, "resolving failed: {s}", .{h.lastError()}, null),
    }
}

pub fn transact(a: Allocator, io: std.Io, t: api.Transaction, diags: *diag.List) Error!bool {
    const cwd = std.Io.Dir.cwd();
    // the lock's databases, where libalpm will look for sync databases.
    const sync_dir = try std.fs.path.join(a, &.{ t.target.dbpath, "sync" });
    cwd.createDirPath(io, sync_dir) catch return fail(diags, "can't create {s}", .{sync_dir});
    for (t.target.dbs) |db| {
        const bytes = cwd.readFileAlloc(io, db.path, a, .limited(256 << 20)) catch return fail(diags, "can't read {s}", .{db.path});
        const dest = try std.fmt.allocPrint(a, "{s}/{s}.db", .{ sync_dir, db.name });
        cwd.writeFile(io, .{ .sub_path = dest, .data = bytes }) catch return fail(diags, "can't write {s}", .{dest});
    }
    cwd.createDirPath(io, t.target.cachedir) catch return fail(diags, "can't create {s}", .{t.target.cachedir});

    const h = try Handle.open(a, t.target.root, t.target.dbpath, diags) orelse return false;
    defer h.close();
    if (!try h.configure(a, t, diags)) return false;
    var questions: Questions = .{ .a = a, .providers = &.{} };
    _ = c.alpm_option_set_questioncb(h.h, Questions.answer, &questions);
    _ = c.alpm_option_set_logcb(h.h, logErrors, diags);

    // install first: removing can take away what downloading needs, like
    // the tls certificates.
    if (t.install.len > 0 and !try h.run(a, t, .install, diags)) return false;
    if (t.remove.len > 0 and !try h.run(a, t, .remove, diags)) return false;

    const local = c.alpm_get_localdb(h.h);
    for ([_]struct { []const []const u8, c.alpm_pkgreason_t }{
        .{ t.explicit, c.ALPM_PKG_REASON_EXPLICIT },
        .{ t.dependency, c.ALPM_PKG_REASON_DEPEND },
    }) |group| {
        for (group[0]) |name| {
            const p = c.alpm_db_get_pkg(local, (try a.dupeZ(u8, name)).ptr) orelse continue;
            if (c.alpm_pkg_set_reason(p, group[1]) != 0) return fail(diags, "can't mark {s}: {s}", .{ name, h.lastError() });
        }
    }
    return true;
}

const VaList = @typeInfo(@typeInfo(@typeInfo(c.alpm_cb_log).optional.child).pointer.child).@"fn".params[3].type.?;

/// libalpm's error messages, like why a download failed, as diagnostics.
fn logErrors(ctx: ?*anyopaque, level: c.alpm_loglevel_t, fmt: [*c]const u8, args: VaList) callconv(.c) void {
    if (level != c.ALPM_LOG_ERROR) return;
    const diags: *diag.List = @ptrCast(@alignCast(ctx));
    var buf: [512]u8 = undefined;
    const n = c.vsnprintf(&buf, buf.len, fmt, args);
    if (n < 0) return;
    const msg = std.mem.trimEnd(u8, buf[0..@min(@as(usize, @intCast(n)), buf.len - 1)], "\n");
    diags.add(.alpm_failed, null, "{s}", .{msg}, null) catch {};
}

/// pacman 7.1 split the sandbox switch in two, and dropped the old one from
/// the library but not the header.
fn setSandbox(h: Handle, s: api.Sandbox) bool {
    if (@hasDecl(c, "alpm_option_set_disable_sandbox_filesystem")) {
        return c.alpm_option_set_disable_sandbox_filesystem(h.h, @intFromBool(s.no_filesystem)) == 0 and
            c.alpm_option_set_disable_sandbox_syscalls(h.h, @intFromBool(s.no_syscalls)) == 0;
    }
    return c.alpm_option_set_disable_sandbox(h.h, @intFromBool(s.no_filesystem or s.no_syscalls)) == 0;
}

fn fail(diags: *diag.List, comptime fmt: []const u8, args: anytype) Error!bool {
    try diags.add(.alpm_failed, null, fmt, args, null);
    return false;
}

/// a directory path with the trailing slash libalpm wants.
fn dirZ(a: Allocator, parts: []const []const u8) ![*:0]const u8 {
    const joined = try std.fs.path.join(a, parts);
    return (try std.fmt.allocPrintSentinel(a, "{s}/", .{joined}, 0)).ptr;
}

const Step = enum { remove, install };

fn configureImpl(h: Handle, a: Allocator, t: api.Transaction, diags: *diag.List) Error!bool {
    if (c.alpm_option_add_cachedir(h.h, try dirZ(a, &.{t.target.cachedir})) != 0 or
        c.alpm_option_add_hookdir(h.h, try dirZ(a, &.{ t.target.root, "usr/share/libalpm/hooks" })) != 0 or
        c.alpm_option_add_hookdir(h.h, try dirZ(a, &.{ t.target.root, "etc/pacman.d/hooks" })) != 0 or
        c.alpm_option_add_architecture(h.h, @import("sync.zig").arch) != 0 or
        c.alpm_option_set_logfile(h.h, (try a.dupeZ(u8, try std.fs.path.join(a, &.{ t.target.root, "var/log/pacman.log" }))).ptr) != 0)
    {
        return fail(diags, "can't set up libalpm: {s}", .{h.lastError()});
    }
    if (!setSandbox(h, t.target.sandbox)) return fail(diags, "can't turn off the download sandbox: {s}", .{h.lastError()});
    if (t.target.download_user) |user| {
        if (c.alpm_option_set_sandboxuser(h.h, (try a.dupeZ(u8, user)).ptr) != 0) return fail(diags, "can't download as {s}: {s}", .{ user, h.lastError() });
    }
    // arch's default: packages must be signed, databases may be.
    var level: c_int = 0;
    if (t.target.gpgdir) |g| {
        if (c.alpm_option_set_gpgdir(h.h, try dirZ(a, &.{g})) != 0) return fail(diags, "can't use the keyring at {s}: {s}", .{ g, h.lastError() });
        level = c.ALPM_SIG_PACKAGE | c.ALPM_SIG_DATABASE | c.ALPM_SIG_DATABASE_OPTIONAL;
    }
    for (t.target.dbs) |db| {
        const d = c.alpm_register_syncdb(h.h, (try a.dupeZ(u8, db.name)).ptr, level) orelse return fail(diags, "can't load the {s} database: {s}", .{ db.name, h.lastError() });
        for (db.servers) |server| {
            if (c.alpm_db_add_server(d, (try a.dupeZ(u8, server)).ptr) != 0) return fail(diags, "bad server {s}", .{server});
        }
    }
    return true;
}

/// one transaction: all the removals, or all the installs.
fn runImpl(h: Handle, a: Allocator, t: api.Transaction, step: Step, diags: *diag.List) Error!bool {
    if (c.alpm_trans_init(h.h, 0) != 0) return fail(diags, "can't start the transaction: {s}", .{h.lastError()});
    defer _ = c.alpm_trans_release(h.h);
    switch (step) {
        .remove => {
            const local = c.alpm_get_localdb(h.h);
            for (t.remove) |name| {
                const p = c.alpm_db_get_pkg(local, (try a.dupeZ(u8, name)).ptr) orelse continue;
                if (c.alpm_remove_pkg(h.h, p) != 0) return fail(diags, "can't remove {s}: {s}", .{ name, h.lastError() });
            }
        },
        .install => for (t.install) |want| {
            const p = try syncPackage(h, a, want, diags) orelse return false;
            if (c.alpm_add_pkg(h.h, p) != 0) return fail(diags, "can't add {s}: {s}", .{ want.name, h.lastError() });
        },
    }
    var data: ?*c.alpm_list_t = null;
    if (c.alpm_trans_prepare(h.h, &data) != 0) {
        try reportPrepare(h, data, diags);
        return false;
    }
    if (c.alpm_trans_commit(h.h, &data) != 0) {
        if (c.alpm_errno(h.h) == c.ALPM_ERR_FILE_CONFLICTS) {
            var it = listItems(c.alpm_fileconflict_t, data);
            while (it.next()) |fc| try diags.add(.alpm_failed, null, "{s} would overwrite {s}", .{ str(fc.target), str(fc.file) }, "a file there isn't owned by the package; move it away");
            return false;
        }
        return fail(diags, "the transaction failed: {s}", .{h.lastError()});
    }
    return true;
}

/// the sync package for a locked one, checked against the lock.
fn syncPackage(h: Handle, a: Allocator, want: lock.Package, diags: *diag.List) Error!?*c.alpm_pkg_t {
    var dbs = listItems(c.alpm_db_t, c.alpm_get_syncdbs(h.h));
    while (dbs.next()) |db| {
        if (!std.mem.eql(u8, str(c.alpm_db_get_name(db)), want.repo)) continue;
        const p = c.alpm_db_get_pkg(db, (try a.dupeZ(u8, want.name)).ptr) orelse break;
        const version = str(c.alpm_pkg_get_version(p));
        const sha = str(c.alpm_pkg_get_sha256sum(p));
        if (!std.mem.eql(u8, version, want.version) or !std.mem.eql(u8, sha, want.sha256)) {
            _ = try fail(diags, "the {s} database has {s} {s}, but the lock says {s}", .{ want.repo, want.name, version, want.version });
            return null;
        }
        return p;
    }
    _ = try fail(diags, "{s} isn't in the {s} database the lock came from", .{ want.name, want.repo });
    return null;
}
