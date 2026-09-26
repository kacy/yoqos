//! generations on the rollback rung: where they live on btrfs, and the
//! boot menu that lists them. this part is pure; cmd/enable_rollback.zig
//! and apply do the work.
//!
//! the layout, under the btrfs top level:
//!   @roots/<n>  writable roots: the one running, and the one before it
//!   @gens/<n>   a read-only record of every generation
//!   @var        /var, which never rolls back

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

/// what os keeps about a generation.
pub const Record = struct {
    n: u32,
    /// unix seconds.
    time: i64,
    /// its writable root, under the top level.
    root: []const u8,
    /// what made it, like "enable-rollback" or "add fd".
    reason: []const u8,
};

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
    return std.fmt.allocPrint(a, "root=UUID={s} rootflags={s}{s}", .{ root_uuid, flags.items, rest.items });
}

pub const GrubConfig = struct {
    esp_uuid: []const u8,
    root_uuid: []const u8,
    default: []const u8,
    timeout: u32 = 3,
    entries: []const Entry,
};

/// the whole grub.cfg os keeps on the esp. a one-shot choice comes from
/// an env file there: grub can write fat, but not btrfs.
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
        \\  load_env -f (${{yoq_esp}})/yoq/grubenv yoq_next
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

test "a generation's kernel command line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try kernelArgs(arena.allocator(), "BOOT_IMAGE=/boot/vmlinuz-linux root=UUID=abc rw net.ifnames=0 rootflags=compress=zstd:1,subvol=/@ console=ttyS0,115200\n", "abc", "/@roots/1");
    try testing.expectEqualStrings("root=UUID=abc rootflags=subvol=/@roots/1,compress=zstd:1 rw net.ifnames=0 console=ttyS0,115200", got);
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
    try testing.expect(std.mem.indexOf(u8, text, "load_env -f (${yoq_esp})/yoq/grubenv yoq_next\n") != null);
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
