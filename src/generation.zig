//! generations on the rollback rung: where they live on btrfs, and the
//! boot menu that lists them. this part is pure; cmd/enable_rollback.zig
//! and apply do the work.
//!
//! the layout, under the btrfs top level:
//!   @roots/<n>       writable roots: the one running, and the one before it
//!   @roots/boot-<n>  a fresh writable copy of generation n, for its menu
//!                    entry, remade whenever the menu is written
//!   @gens/<n>        a read-only record of every generation
//!   @var             /var, which never rolls back

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const roots_dir = "@roots";
pub const gens_dir = "@gens";
pub const var_subvol = "@var";

/// where the btrfs top level is mounted while os works on it.
pub const top_mount = "/run/yoq/top";

/// generation records, one json file each, in /var so they outlive
/// every rollback.
pub const records_dir = "var/lib/yoq/generations";

/// whether a machine runs a generation: its root is one of @roots.
pub fn running(root_subvol: ?[]const u8) bool {
    const sv = root_subvol orelse return false;
    return std.mem.startsWith(u8, sv, "/" ++ roots_dir ++ "/");
}

/// what os keeps about a generation.
pub const Record = struct {
    n: u32,
    /// unix seconds.
    time: i64,
    /// its writable root, under the top level.
    root: []const u8,
    /// what made it, like "enable-rollback" or "add fd".
    reason: []const u8,
    /// for the first generation: the root the machine ran before, still
    /// bootable from the menu.
    from: ?[]const u8 = null,
    /// the config directory and its commit when the generation was made,
    /// so a rollback can put that config back.
    config_dir: ?[]const u8 = null,
    config_rev: ?[]const u8 = null,
    /// kept by garbage collection however old it gets.
    pinned: bool = false,
};

/// how many generations garbage collection keeps, besides pinned ones and
/// the first.
pub const default_keep = 5;

/// the generations to keep of `records`, sorted by number: the newest
/// `keep`, the first, and every pinned one.
pub fn keeps(r: Record, records: []const Record, keep: usize) bool {
    if (r.n == 1 or r.pinned) return true;
    var newer: usize = 0;
    for (records) |o| newer += @intFromBool(o.n > r.n);
    return newer < keep;
}

/// a config directory at one commit.
pub const Config = struct { dir: []const u8, rev: []const u8 };

/// one boot menu entry: a kernel and its initrds, from a root subvolume.
pub const Entry = struct {
    id: []const u8,
    title: []const u8,
    /// the root subvolume, like "/@roots/1", or "/" for the top level.
    subvol: []const u8,
    kernel: []const u8,
    initrds: []const []const u8,
    args: []const u8,
};

/// the writable copy the menu boots for an older generation.
pub fn bootCopy(a: Allocator, n: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "/{s}/boot-{d}", .{ roots_dir, n });
}

/// a generation's kernel command line, from the running one: the root is
/// the btrfs filesystem by uuid, mounted from `subvol`; other rootflags
/// and arguments stay as they are.
pub fn kernelArgs(a: Allocator, cmdline: []const u8, root_uuid: []const u8, subvol: []const u8) ![]const u8 {
    var flags: std.ArrayList(u8) = .empty;
    try flags.print(a, "subvol={s}", .{subvol});
    var rest: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeAny(u8, cmdline, " \t\n");
    while (words.next()) |w| {
        if (std.mem.startsWith(u8, w, "BOOT_IMAGE=") or std.mem.startsWith(u8, w, "initrd=") or std.mem.startsWith(u8, w, "root=")) continue;
        if (std.mem.startsWith(u8, w, "rootflags=")) {
            var opts = std.mem.tokenizeScalar(u8, w["rootflags=".len..], ',');
            while (opts.next()) |o| {
                if (std.mem.startsWith(u8, o, "subvol=") or std.mem.startsWith(u8, o, "subvolid=")) continue;
                try flags.print(a, ",{s}", .{o});
            }
            continue;
        }
        try rest.print(a, " {s}", .{w});
    }
    // a kernel that panics reboots, so a generation on trial falls back.
    const panic = if (std.mem.indexOf(u8, rest.items, " panic=") == null) " panic=10" else "";
    return std.fmt.allocPrint(a, "root=UUID={s} rootflags={s}{s}{s}", .{ root_uuid, flags.items, rest.items, panic });
}

pub const GrubConfig = struct {
    esp_uuid: []const u8,
    root_uuid: []const u8,
    default: []const u8,
    timeout: u32 = 3,
    entries: []const Entry,
};

/// the whole grub.cfg os keeps on the esp. choices come from an env file
/// there, since grub can write fat but not btrfs: `yoq_next` boots an
/// entry once, and `yoq_default`, set while a generation is on trial, is
/// both the default and what grub falls back to if an entry won't boot.
pub fn grubConfig(a: Allocator, c: GrubConfig) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    w.print(
        \\# written by os: one entry per generation. edits here are overwritten.
        \\insmod part_gpt
        \\insmod fat
        \\insmod btrfs
        \\set timeout={d}
        \\set default="{s}"
        \\search --no-floppy --fs-uuid --set=yoq_esp {s}
        \\if [ -f (${{yoq_esp}})/yoq/grubenv ]; then
        \\  load_env -f (${{yoq_esp}})/yoq/grubenv yoq_next yoq_default
        \\  if [ "${{yoq_default}}" ]; then
        \\    set default="${{yoq_default}}"
        \\    set fallback="${{yoq_default}}"
        \\  fi
        \\  if [ "${{yoq_next}}" ]; then
        \\    set default="${{yoq_next}}"
        \\    set yoq_next=
        \\    save_env -f (${{yoq_esp}})/yoq/grubenv yoq_next
        \\  fi
        \\fi
        \\search --no-floppy --fs-uuid --set=root {s}
        \\
    , .{ c.timeout, c.default, c.esp_uuid, c.root_uuid }) catch return error.OutOfMemory;
    for (c.entries) |e| {
        const dir = if (std.mem.eql(u8, e.subvol, "/")) "" else e.subvol;
        w.print("\nmenuentry \"{s}\" --id {s} {{\n  linux {s}/boot/{s} {s}\n  initrd", .{ e.title, e.id, dir, e.kernel, e.args }) catch return error.OutOfMemory;
        for (e.initrds) |i| w.print(" {s}/boot/{s}", .{ dir, i }) catch return error.OutOfMemory;
        w.writeAll("\n}\n") catch return error.OutOfMemory;
    }
    return out.written();
}

// -- tests --

const testing = std.testing;

test "which generations collection keeps" {
    const recs = [_]Record{
        .{ .n = 1, .time = 0, .root = "@roots/1", .reason = "enable-rollback" },
        .{ .n = 2, .time = 0, .root = "@roots/1", .reason = "a" },
        .{ .n = 3, .time = 0, .root = "@roots/1", .reason = "b", .pinned = true },
        .{ .n = 4, .time = 0, .root = "@roots/1", .reason = "c" },
        .{ .n = 5, .time = 0, .root = "@roots/1", .reason = "d" },
        .{ .n = 6, .time = 0, .root = "@roots/1", .reason = "e" },
    };
    var kept: [6]bool = undefined;
    for (recs, &kept) |r, *k| k.* = keeps(r, &recs, 2);
    try testing.expectEqualSlices(bool, &.{ true, false, true, false, true, true }, &kept);
}

test "a generation's kernel command line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cmdline = "BOOT_IMAGE=/boot/vmlinuz-linux root=UUID=abc rw net.ifnames=0 rootflags=compress=zstd:1,subvol=/@ console=ttyS0,115200\n";
    try testing.expectEqualStrings("root=UUID=abc rootflags=subvol=/@roots/1,compress=zstd:1 rw net.ifnames=0 console=ttyS0,115200 panic=10", try kernelArgs(arena.allocator(), cmdline, "abc", "/@roots/1"));
    try testing.expectEqualStrings("root=UUID=abc rootflags=subvol=/ rw panic=30", try kernelArgs(arena.allocator(), "rw panic=30", "abc", "/"));
    try testing.expectEqualStrings("/@roots/boot-2", try bootCopy(arena.allocator(), 2));
}

test "grub's config on the esp" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = try grubConfig(arena.allocator(), .{
        .esp_uuid = "41B2-0FB5",
        .root_uuid = "1df77bf6",
        .default = "gen-1",
        .entries = &.{
            .{ .id = "gen-1", .title = "yoq 1 · 2026-09-26 · enable-rollback", .subvol = "/@roots/1", .kernel = "vmlinuz-linux", .initrds = &.{ "amd-ucode.img", "initramfs-linux.img" }, .args = "root=UUID=1df77bf6 rootflags=subvol=/@roots/1 rw" },
            .{ .id = "before", .title = "the system before generations", .subvol = "/", .kernel = "vmlinuz-linux", .initrds = &.{"initramfs-linux.img"}, .args = "root=UUID=1df77bf6 rootflags=subvol=/ rw" },
        },
    });
    try testing.expect(std.mem.indexOf(u8, text, "set default=\"gen-1\"\nsearch --no-floppy --fs-uuid --set=yoq_esp 41B2-0FB5\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "load_env -f (${yoq_esp})/yoq/grubenv yoq_next yoq_default\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "set fallback=\"${yoq_default}\"") != null);
    try testing.expect(std.mem.endsWith(u8, text,
        \\search --no-floppy --fs-uuid --set=root 1df77bf6
        \\
        \\menuentry "yoq 1 · 2026-09-26 · enable-rollback" --id gen-1 {
        \\  linux /@roots/1/boot/vmlinuz-linux root=UUID=1df77bf6 rootflags=subvol=/@roots/1 rw
        \\  initrd /@roots/1/boot/amd-ucode.img /@roots/1/boot/initramfs-linux.img
        \\}
        \\
        \\menuentry "the system before generations" --id before {
        \\  linux /boot/vmlinuz-linux root=UUID=1df77bf6 rootflags=subvol=/ rw
        \\  initrd /boot/initramfs-linux.img
        \\}
        \\
    ));
}
