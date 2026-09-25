//! the libalpm side of alpm.zig. only compiled when libalpm is linked
//! (`-Dalpm`).

const std = @import("std");
const facts = @import("facts.zig");
const lock = @import("lock.zig");
const diag = @import("diag.zig");
const api = @import("alpm.zig");
const Allocator = std.mem.Allocator;
const c = @cImport(@cInclude("alpm.h"));
const Error = api.Error;
const ResolveInput = api.ResolveInput;

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
    open: std.ArrayList(Open) = .empty,
    failed: bool = false,

    const Open = struct {
        name: []const u8,
        options: []const []const u8,
    };

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

    /// reports every provider question the config didn't answer. returns
    /// true if there were any.
    fn reportOpen(self: *const Questions, diags: *diag.List) !bool {
        for (self.open.items) |o| {
            const options = try std.mem.join(self.a, ", ", o.options);
            try diags.addHint(.provider_choice, null, "{s} has more than one provider: {s}", .{ o.name, options }, "pick one in [providers], like {s} = \"{s}\"", .{ o.name, o.options[0] });
        }
        return self.open.items.len > 0;
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

pub fn resolve(a: Allocator, io: std.Io, in: ResolveInput, diags: *diag.List) Error!?lock.Lock {
    const scratch = try Scratch.make(a, io, in, diags) orelse return null;
    const h = try Handle.open(a, scratch.root, scratch.dbpath, diags) orelse return null;
    defer h.close();
    var questions: Questions = .{ .a = a, .providers = in.providers };
    _ = c.alpm_option_set_questioncb(h.h, Questions.answer, &questions);
    for (in.dbs) |db| {
        if (c.alpm_register_syncdb(h.h, (try a.dupeZ(u8, db.name)).ptr, 0) == null) {
            try diags.add(.alpm_failed, null, "can't load the {s} database: {s}", .{ db.name, h.lastError() }, null);
            return null;
        }
    }

    if (c.alpm_trans_init(h.h, 0) != 0) {
        try diags.add(.alpm_failed, null, "can't start resolving: {s}", .{h.lastError()}, null);
        return null;
    }
    defer _ = c.alpm_trans_release(h.h);
    if (!try addWants(a, h, in.wants, &questions, diags)) return null;

    var data: ?*c.alpm_list_t = null;
    if (c.alpm_trans_prepare(h.h, &data) != 0) {
        try reportPrepare(h, data, diags);
        return null;
    }
    if (try questions.reportOpen(diags)) return null;

    var l: lock.Lock = .{
        .sync_date = in.sync_date,
        .keyring = if (in.keyring.len > 0) in.keyring else try keyringVersion(a, h),
        .providers = questions.chosen.items,
        .packages = try lockPackages(a, c.alpm_trans_get_add(h.h)),
    };
    try lock.normalize(a, &l);
    return l;
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
        for ([_][]const u8{ s.root, sync_dir, local_dir }) |d| cwd.createDirPath(io, d) catch return error.AlpmFailed;
        cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ local_dir, "ALPM_DB_VERSION" }), .data = "9\n" }) catch return error.AlpmFailed;
        for (in.dbs) |db| {
            const bytes = cwd.readFileAlloc(io, db.path, a, .limited(256 << 20)) catch {
                try diags.add(.alpm_failed, null, "can't read the {s} database at {s}", .{ db.name, db.path }, null);
                return null;
            };
            const dest = try std.fmt.allocPrint(a, "{s}/{s}.db", .{ sync_dir, db.name });
            cwd.writeFile(io, .{ .sub_path = dest, .data = bytes }) catch return error.AlpmFailed;
        }
        return s;
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
            const sat = c.alpm_find_satisfier(adds, s) orelse continue;
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
