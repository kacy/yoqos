//! diagnostics. every error a user can hit has a stable code, a message,
//! where it happened, and usually a hint. `os explain <code>` prints the long
//! form from `table`.
//!
//! codes are grouped by area: E000x toml, E010x-E011x config and includes,
//! E012x the lock and the package and service backends, E02xx services.
//! once a code ships it keeps its number and meaning.

const std = @import("std");
const output = @import("output.zig");

pub const Code = enum {
    toml_syntax,
    toml_unsupported,
    toml_duplicate_key,
    config_missing,
    unknown_key,
    wrong_type,
    bad_value,
    include_missing,
    include_cycle,
    source_missing,
    lock_invalid,
    lock_stale,
    unresolvable,
    provider_choice,
    alpm_failed,
    systemd_failed,
    protected_package,
    apply_failed,
    plan_changed,
    unknown_service,
    plan_moved,
    aur_missing,
    esp_full,
    secret_missing,
    secure_boot_keys,
    secure_boot_tpm,
    secure_boot_enrolled,
    luks_locked,
};

pub const Entry = struct {
    code: Code,
    id: []const u8,
    title: []const u8,
    explanation: []const u8,
};

/// one entry per `Code`, in the same order.
pub const table = [_]Entry{
    .{
        .code = .toml_syntax,
        .id = "E0001",
        .title = "toml syntax error",
        .explanation = "the file isn't valid toml. the message says what the parser expected and where. " ++
            "a common cause is a missing quote around a string value, like `hostname = atlas` instead of " ++
            "`hostname = \"atlas\"`.",
    },
    .{
        .code = .toml_unsupported,
        .id = "E0002",
        .title = "unsupported toml feature",
        .explanation = "the file uses a toml feature os doesn't read yet, such as a date or time value. " ++
            "write the value as a string instead.",
    },
    .{
        .code = .toml_duplicate_key,
        .id = "E0003",
        .title = "key defined twice",
        .explanation = "toml doesn't allow setting the same key or table twice in one file. remove one of " ++
            "the two definitions. to change a value that an include sets, set it in the including file; " ++
            "the including file always wins.",
    },
    .{
        .code = .config_missing,
        .id = "E0100",
        .title = "no config file",
        .explanation = "os couldn't read the config file. by default it's /etc/yoq/machine.toml, and " ++
            "`--config <path>` points somewhere else. `os init` writes one that describes this machine.",
    },
    .{
        .code = .unknown_key,
        .id = "E0101",
        .title = "unknown key",
        .explanation = "the config has a key os doesn't know. it's usually a typo, and the hint names the " ++
            "closest known key.",
    },
    .{
        .code = .wrong_type,
        .id = "E0102",
        .title = "wrong type",
        .explanation = "the key exists, but its value has the wrong type, for example a string where a list " ++
            "is expected: `packages = \"git\"` instead of `packages = [\"git\"]`.",
    },
    .{
        .code = .bad_value,
        .id = "E0103",
        .title = "invalid value",
        .explanation = "the value has the right type but isn't allowed, for example an empty hostname or an " ++
            "unknown cpu vendor. the message lists what's accepted.",
    },
    .{
        .code = .include_missing,
        .id = "E0110",
        .title = "include not found",
        .explanation = "a file named in `include` doesn't exist. include paths are relative to the file that " ++
            "includes them.",
    },
    .{
        .code = .include_cycle,
        .id = "E0111",
        .title = "include cycle",
        .explanation = "two or more files include each other, directly or through other files. the message " ++
            "shows the chain. break it by moving the shared settings into a file that neither includes.",
    },
    .{
        .code = .source_missing,
        .id = "E0112",
        .title = "file source missing",
        .explanation = "a `[files]` entry's `source` names a file that doesn't exist or can't be read. the path " ++
            "is relative to the config file that names it, so `source = \"files/motd\"` in /etc/yoq/machine.toml " ++
            "is /etc/yoq/files/motd.",
    },
    .{
        .code = .lock_invalid,
        .id = "E0120",
        .title = "damaged lock file",
        .explanation = "machine.lock is written by os and read back exactly. this one doesn't match the " ++
            "format, usually because it was edited by hand or a merge left conflict markers in it. restore " ++
            "it from git (`git -C /etc/yoq checkout machine.lock`) or write a fresh one with `os update`.",
    },
    .{
        .code = .lock_stale,
        .id = "E0121",
        .title = "lock doesn't cover the config",
        .explanation = "the config asks for a package that machine.lock doesn't have, so os doesn't know which " ++
            "version to install. `os add <package>` resolves one package against the lock's current package " ++
            "date; `os update` resolves everything against today's.",
    },
    .{
        .code = .unresolvable,
        .id = "E0122",
        .title = "can't resolve packages",
        .explanation = "resolving the config against the arch package databases failed: a package doesn't " ++
            "exist, needs something no repository has, or conflicts with another package the config asks " ++
            "for. the message names the packages involved.",
    },
    .{
        .code = .provider_choice,
        .id = "E0123",
        .title = "choose a provider",
        .explanation = "a package depends on something several packages provide, like java-runtime, and os " ++
            "won't pick one for you. add the choice to the config under [providers], for example " ++
            "`java-runtime = \"jre-openjdk\"`. a name with a dot in it goes in quotes, like " ++
            "`\"libxtables.so\" = \"iptables\"`, or toml reads it as a table.",
    },
    .{
        .code = .alpm_failed,
        .id = "E0124",
        .title = "package database error",
        .explanation = "libalpm couldn't open or read a package database. the message has libalpm's own " ++
            "reason. a stale lock file (db.lck) left by a crashed pacman is a common cause.",
    },
    .{
        .code = .systemd_failed,
        .id = "E0125",
        .title = "can't read systemd",
        .explanation = "os asks systemd over the system bus which units are enabled and running. that " ++
            "failed, usually because systemd isn't running, as in a container or chroot.",
    },
    .{
        .code = .protected_package,
        .id = "E0126",
        .title = "won't remove a core package",
        .explanation = "the config leaves out a package the machine needs to boot or to manage packages, like " ++
            "base or pacman, so applying it would remove that package. usually the package was left out by " ++
            "mistake: add it to `packages`. to remove it anyway, say so with `[remove] packages = [\"base\"]`.",
    },
    .{
        .code = .apply_failed,
        .id = "E0127",
        .title = "a change didn't apply",
        .explanation = "os changed a file or ran a tool for a step of the plan, like useradd, sysctl, or " ++
            "mkinitcpio, and that failed. the message has the file or the tool's own words. the steps before " ++
            "it are done; fix the cause and run `os apply` again to finish.",
    },
    .{
        .code = .plan_changed,
        .id = "E0128",
        .title = "the saved plan is out of date",
        .explanation = "`os apply <file>` applies a plan `os plan -o <file>` saved, and only that plan. the " ++
            "config, the lock, or the machine changed since it was saved, so os would now do something else. " ++
            "run `os plan -o <file>` again, look it over, and apply the new one.",
    },
    .{
        .code = .unknown_service,
        .id = "E0213",
        .title = "unknown service",
        .explanation = "`[services]` names a service os doesn't know how to set up. names are short and " ++
            "stable, like `ssh` rather than `sshd` or `openssh`. for a unit os doesn't know, declare it with " ++
            "`[services.<name>] unit = \"<unit>.service\"` and `package = \"<package>\"`.",
    },
    .{
        .code = .plan_moved,
        .id = "E0129",
        .title = "the plan changed before it was applied",
        .explanation = "`os apply` plans again after you say yes, and applies only the plan it showed you. " ++
            "the config, the lock, or the machine changed in between, like a pacman run in another terminal, " ++
            "so os would now do something else and changed nothing. run the command again and look over the new plan.",
    },
    .{
        .code = .aur_missing,
        .id = "E0130",
        .title = "an aur package needs one the config doesn't list",
        .explanation = "an aur recipe's .SRCINFO depends on a package that isn't in the arch repositories " ++
            "and isn't in `aur`. that's usually another aur package, and os builds only the aur packages the " ++
            "config names, so add it: `os add --aur <package>`, then `os update` again. os builds them in " ++
            "order. when the missing name is a package a recipe splits off, os can't build it yet: from a " ++
            "split recipe it installs only the package named after the recipe.",
    },
    .{
        .code = .esp_full,
        .id = "E0131",
        .title = "the new boot files won't fit on the esp",
        .explanation = "the plan changes a kernel, its initramfs, or microcode, so the next generation " ++
            "puts new boot files on the esp: limine and systemd-boot boot copies of every generation's " ++
            "files from there, and with the esp at /boot the running kernel lives there too. the esp " ++
            "hasn't the room, so os stops before it builds anything. the size is an estimate from the " ++
            "boot files the running system has now. with limine or systemd-boot, `os gc --keep <n>` " ++
            "removes older generations and the copies only they use; the message names the ones " ++
            "`os gc --keep 1` would remove. with grub or refind, the esp holds only the running " ++
            "system's files, so make room by hand, for example by removing the fallback initramfs " ++
            "images, which os's menu doesn't boot. then plan again.",
    },
    .{
        .code = .secret_missing,
        .id = "E0133",
        .title = "a secret isn't set on this machine",
        .explanation = "a `[files]` entry says `secret = \"<name>\"`, and this machine has no value for that " ++
            "name, or has one it can't decrypt. values never go into the config or the lock: each machine " ++
            "keeps its own, encrypted with systemd-creds under /var/lib/yoq/secrets, so a config copied to " ++
            "a new machine needs its secrets set again there. `os secret set <name>` asks for the value, or " ++
            "reads it from stdin, as in `printf '%s' \"$value\" | sudo os secret set <name>`. then plan again.",
    },
    .{
        .code = .secure_boot_keys,
        .id = "E0134",
        .title = "secure boot is on, but there are no keys to sign with",
        .explanation = "with `[boot] secure_boot = true`, os signs every unified kernel image it puts on the " ++
            "esp with sbctl's db key, in /var/lib/sbctl, and that key isn't there. os never makes or enrolls " ++
            "keys itself. in this order: install sbctl and run `sbctl create-keys`; run `os apply`, which " ++
            "signs the next generation's images; reboot into the firmware's setup and put secure boot in setup " ++
            "mode (clearing its keys), then boot and run `sbctl enroll-keys -m`, which keeps microsoft's keys " ++
            "next to yours, for firmware drivers signed with them; sign the bootloader with `sbctl sign -s " ++
            "<file>` (`os doctor` lists what's unsigned); then turn secure boot on and reboot.",
    },
    .{
        .code = .secure_boot_tpm,
        .id = "E0136",
        .title = "grub can't start under secure boot here",
        .explanation = "os starts grub under secure boot without shim. grub then locks itself down and " ++
            "loads nothing, not even its own modules, unless something checks it first, and the thing that " ++
            "does is grub's tpm module, which measures each file into the tpm. on a machine without a tpm " ++
            "2.0 that module does nothing, so grub stops at its rescue prompt. turn the tpm on in the " ++
            "firmware setup (it may be called ptt, fttpm, or security device), or leave `secure_boot` off " ++
            "with grub.",
    },
    .{
        .code = .secure_boot_enrolled,
        .id = "E0137",
        .title = "the firmware doesn't have sbctl's keys",
        .explanation = "the firmware enforces secure boot, and the certificate os would sign images with, " ++
            "sbctl's db.pem in /var/lib/sbctl/keys/db, isn't in the firmware's db. images signed with it " ++
            "wouldn't start: grub falls back to the generation before, but limine halts and refind waits " ++
            "for a key, for good. it happens after `sbctl create-keys` makes new keys, or on a machine that " ++
            "boots through shim. enroll the keys: in the firmware's setup, clear the secure boot keys (setup " ++
            "mode), boot, and run `sbctl enroll-keys -m`. or turn secure boot off in the firmware until then.",
    },
    .{
        .code = .luks_locked,
        .id = "E0135",
        .title = "the initramfs wouldn't unlock the root",
        .explanation = "the root is on luks, and the only thing that unlocks it at boot is os's mkinitcpio " ++
            "drop-in from `[boot] encrypt = true`. the config doesn't ask for it any more, so applying would " ++
            "remove it and build an initramfs that can't open the root, and the machine wouldn't boot. keep " ++
            "`encrypt = true` under [boot], or first add sd-encrypt (or encrypt, for busybox's hooks) to HOOKS " ++
            "in /etc/mkinitcpio.conf, then plan again.",
    },
};

comptime {
    for (table, 0..) |e, i| {
        if (@intFromEnum(e.code) != i) @compileError("diag.table is out of order at " ++ e.id);
    }
    if (table.len != @typeInfo(Code).@"enum".fields.len) @compileError("diag.table is missing a code");
}

/// the json shape of an entry: `code` is the stable id, like in error
/// documents, and `name` is the short name.
pub const EntryJson = struct {
    code: []const u8,
    name: []const u8,
    title: []const u8,
    explanation: []const u8,
};

pub fn entryJson(e: Entry) EntryJson {
    return .{ .code = e.id, .name = @tagName(e.code), .title = e.title, .explanation = e.explanation };
}

pub fn entry(code: Code) Entry {
    return table[@intFromEnum(code)];
}

pub fn byId(id: []const u8) ?Entry {
    for (table) |e| {
        if (std.ascii.eqlIgnoreCase(e.id, id)) return e;
    }
    return null;
}

pub const Span = struct {
    file: []const u8,
    line: u32,
    column: u32,
};

pub const Diagnostic = struct {
    code: Code,
    message: []const u8,
    span: ?Span = null,
    hint: ?[]const u8 = null,

    pub fn render(d: Diagnostic, w: *std.Io.Writer) !void {
        const id = entry(d.code).id;
        try w.print("error[{s}]: {s}\n", .{ id, d.message });
        if (d.span) |s| try w.print("  --> {s}:{d}:{d}\n", .{ s.file, s.line, s.column });
        if (d.hint) |h| {
            try w.print("   | {s}  (os explain {s})\n", .{ h, id });
        } else {
            try w.print("   | os explain {s}\n", .{id});
        }
    }

    pub const Json = struct {
        code: []const u8,
        title: []const u8,
        message: []const u8,
        file: ?[]const u8,
        line: ?u32,
        column: ?u32,
        hint: ?[]const u8,
    };

    pub fn toJson(d: Diagnostic) Json {
        const e = entry(d.code);
        return .{
            .code = e.id,
            .title = e.title,
            .message = d.message,
            .file = if (d.span) |s| s.file else null,
            .line = if (d.span) |s| s.line else null,
            .column = if (d.span) |s| s.column else null,
            .hint = d.hint,
        };
    }
};

/// collects diagnostics so a command can report every problem at once. all
/// strings live in the list's arena.
pub const List = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Diagnostic) = .empty,

    pub fn init(gpa: std.mem.Allocator) List {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(l: *List) void {
        l.arena.deinit();
    }

    pub fn add(
        l: *List,
        code: Code,
        span: ?Span,
        comptime fmt: []const u8,
        args: anytype,
        hint: ?[]const u8,
    ) !void {
        const a = l.arena.allocator();
        try l.items.append(a, .{
            .code = code,
            .message = try std.fmt.allocPrint(a, fmt, args),
            .span = if (span) |s| .{ .file = try a.dupe(u8, s.file), .line = s.line, .column = s.column } else null,
            .hint = if (hint) |h| try a.dupe(u8, h) else null,
        });
    }

    /// like `add`, with a formatted hint.
    pub fn addHint(
        l: *List,
        code: Code,
        span: ?Span,
        comptime fmt: []const u8,
        args: anytype,
        comptime hint_fmt: []const u8,
        hint_args: anytype,
    ) !void {
        const hint = try std.fmt.allocPrint(l.arena.allocator(), hint_fmt, hint_args);
        try l.add(code, span, fmt, args, hint);
    }

    pub fn render(l: *const List, w: *std.Io.Writer) !void {
        for (l.items.items, 0..) |d, i| {
            if (i > 0) try w.writeByte('\n');
            try d.render(w);
        }
    }

    pub fn writeJson(l: *const List, w: *std.Io.Writer) !void {
        const a = l.arena.child_allocator;
        const errors = try a.alloc(Diagnostic.Json, l.items.items.len);
        defer a.free(errors);
        for (l.items.items, errors) |d, *j| j.* = d.toJson();
        try output.writeDoc(w, "yoq.errors/1", JsonDoc{ .errors = errors });
    }
};

/// errors as json: what every command prints with --json when it fails.
pub const JsonDoc = struct { errors: []const Diagnostic.Json };

/// the candidate closest to `name` by edit distance, if it's close enough to
/// be a likely typo.
pub fn suggest(name: []const u8, candidates: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = std.math.maxInt(usize);
    for (candidates) |c| {
        const d = editDistance(name, c);
        if (d < best_dist) {
            best = c;
            best_dist = d;
        }
    }
    const limit = @max(1, @min(name.len, 12) / 3);
    return if (best_dist <= limit) best else null;
}

/// levenshtein distance, for short identifiers only.
fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 64 or b.len > 64) return std.math.maxInt(usize);
    var prev: [65]usize = undefined;
    var cur: [65]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const sub = prev[j] + @intFromBool(ca != cb);
            cur[j + 1] = @min(sub, prev[j + 1] + 1, cur[j] + 1);
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

test "codes are unique" {
    for (table, 0..) |a, i| {
        for (table[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.id, b.id));
    }
}

test "render with span and hint" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const d: Diagnostic = .{
        .code = .unknown_service,
        .message = "unknown service \"sshd\"",
        .span = .{ .file = "/etc/yoq/machine.toml", .line = 24, .column = 1 },
        .hint = "did you mean \"ssh\"?",
    };
    try d.render(&w);
    try std.testing.expectEqualStrings(
        \\error[E0213]: unknown service "sshd"
        \\  --> /etc/yoq/machine.toml:24:1
        \\   | did you mean "ssh"?  (os explain E0213)
        \\
    , w.buffered());
}

test "list collects and renders json" {
    var l: List = .init(std.testing.allocator);
    defer l.deinit();
    try l.add(.wrong_type, .{ .file = "m.toml", .line = 2, .column = 12 }, "packages must be a list", .{}, null);
    try l.addHint(.unknown_key, null, "unknown key \"hostnme\"", .{}, "did you mean \"{s}\"?", .{"hostname"});

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try l.writeJson(&w);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    const errors = parsed.value.object.get("errors").?.array.items;
    try std.testing.expectEqual(2, errors.len);
    try std.testing.expectEqualStrings("E0102", errors[0].object.get("code").?.string);
    try std.testing.expectEqual(2, errors[0].object.get("line").?.integer);
    try std.testing.expectEqualStrings("did you mean \"hostname\"?", errors[1].object.get("hint").?.string);
    try std.testing.expect(errors[1].object.get("file").? == .null);
}

test "suggest finds likely typos only" {
    const keys: []const []const u8 = &.{ "hostname", "timezone", "locale" };
    try std.testing.expectEqualStrings("hostname", suggest("hostnme", keys).?);
    try std.testing.expectEqualStrings("timezone", suggest("timzone", keys).?);
    try std.testing.expectEqual(null, suggest("kernel", keys));
    try std.testing.expectEqualStrings("ssh", suggest("sshd", &.{ "ssh", "cups", "docker" }).?);
}

test "byId ignores case" {
    try std.testing.expectEqual(Code.unknown_service, byId("e0213").?.code);
    try std.testing.expectEqual(null, byId("E9999"));
}
