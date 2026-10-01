//! secure boot with sbctl's keys: os signs the unified kernel images it
//! puts on the esp, and the loader files it installs there, with
//! `sbctl sign`. the keys are sbctl's own, in /var/lib/sbctl, which no
//! generation holds, so they outlast every rollback. os never makes or
//! enrolls keys. this part is pure; gens.zig signs.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// the package with sbctl in it.
pub const package = "sbctl";

/// the file os writes into a root for `[boot] secure_boot`, relative to
/// the root. a menu written for a root that has it, or from a running one
/// that has it, signs every image.
pub const config_rel = "etc/kernel/yoq-secure-boot.conf";
pub const config_path = "/" ++ config_rel;

pub const config_content =
    \\# written by os from [boot] secure_boot in the config. edits here are overwritten.
    \\# os signs this root's unified kernel images with sbctl's keys in
    \\# /var/lib/sbctl before they go on the esp.
    \\
;

/// sbctl's signing key and certificate. their being there is all os
/// checks; it never reads them.
pub const keys_dir = "/var/lib/sbctl/keys";
pub const db_key_rel = "var/lib/sbctl/keys/db/db.key";
pub const db_cert_rel = "var/lib/sbctl/keys/db/db.pem";

/// the efi variables that say whether the firmware enforces secure boot,
/// and whether it's in setup mode, taking new keys.
const global_guid = "8be4df61-93ca-11d2-aa0d-00e098032b8c";
pub const secure_boot_var = "sys/firmware/efi/efivars/SecureBoot-" ++ global_guid;
pub const setup_mode_var = "sys/firmware/efi/efivars/SetupMode-" ++ global_guid;

/// the command that signs `file` in place with sbctl's db key. `signer`
/// is sbctl, or a stand-in in tests.
pub fn signArgv(a: Allocator, signer: []const u8, file: []const u8) ![]const []const u8 {
    return a.dupe([]const u8, &.{ signer, "sign", file });
}

/// a one-byte efi variable's value, as efivarfs shows it: four bytes of
/// attributes, then the value. null if it isn't one.
pub fn efiFlag(bytes: []const u8) ?bool {
    if (bytes.len != 5) return null;
    return bytes[4] != 0;
}

/// how much of an efi binary `signed` needs: its headers.
pub const header_bytes = 4096;

/// whether the pe file that starts with `head` has an authenticode
/// signature: its certificate table, the fifth data directory, isn't
/// empty. null when `head` isn't a pe file's headers. it says nothing
/// about whose key signed it.
pub fn signed(head: []const u8) ?bool {
    if (head.len < 0x40 or !std.mem.eql(u8, head[0..2], "MZ")) return null;
    const pe = std.mem.readInt(u32, head[0x3c..0x40], .little);
    if (pe > head.len -| 24 or !std.mem.eql(u8, head[pe..][0..4], "PE\x00\x00")) return null;
    const opt = pe + 24;
    if (opt + 2 > head.len) return null;
    // the data directories start later in a 64-bit optional header.
    const dirs: usize = switch (std.mem.readInt(u16, head[opt..][0..2], .little)) {
        0x10b => opt + 96,
        0x20b => opt + 112,
        else => return null,
    };
    const count_at = dirs - 4;
    if (dirs + 5 * 8 > head.len) return null;
    if (std.mem.readInt(u32, head[count_at..][0..4], .little) < 5) return false;
    const size = std.mem.readInt(u32, head[dirs + 4 * 8 + 4 ..][0..4], .little);
    return size > 0;
}

/// the paths in `unsigned` that os put on the esp at `esp` itself: its
/// images, in yoq/boot.
pub fn ours(a: Allocator, unsigned: []const []const u8, esp: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const dir = try std.fmt.allocPrint(a, "{s}/yoq/", .{std.mem.trimEnd(u8, esp, "/")});
    for (unsigned) |p| {
        if (std.mem.startsWith(u8, p, dir)) try out.append(a, p);
    }
    return out.items;
}

/// the firmware's secure boot state in a few words, for `os doctor`.
pub fn describe(on: ?bool, setup: ?bool) []const u8 {
    const enforced = on orelse return "unknown: no efi variables for it";
    if (enforced) return "on";
    return if (setup orelse false) "off, in setup mode" else "off";
}

const testing = std.testing;

test "sbctl's arguments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const argv = try signArgv(arena.allocator(), "sbctl", "/run/yoq/top/@roots/4/tmp/yoq-uki/yoq.efi");
    try testing.expectEqual(3, argv.len);
    try testing.expectEqualStrings("sbctl", argv[0]);
    try testing.expectEqualStrings("sign", argv[1]);
    try testing.expectEqualStrings("/run/yoq/top/@roots/4/tmp/yoq-uki/yoq.efi", argv[2]);
}

test "secure boot and setup mode from efivarfs" {
    try testing.expectEqual(true, efiFlag(&.{ 6, 0, 0, 0, 1 }));
    try testing.expectEqual(false, efiFlag(&.{ 6, 0, 0, 0, 0 }));
    try testing.expectEqual(null, efiFlag(&.{ 6, 0, 0, 0 }));
    try testing.expectEqual(null, efiFlag(""));
    try testing.expectEqualStrings("on", describe(true, false));
    try testing.expectEqualStrings("off, in setup mode", describe(false, true));
    try testing.expectEqualStrings("off", describe(false, false));
    try testing.expectEqualStrings("off", describe(false, null));
    try testing.expectEqualStrings("unknown: no efi variables for it", describe(null, null));
}

test "os's own unsigned files" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try ours(arena.allocator(), &.{ "/boot/EFI/BOOT/BOOTX64.EFI", "/boot/yoq/boot/0123456789abcdef-yoq.efi", "/boot/yoqx/a.efi" }, "/boot");
    try testing.expectEqual(1, got.len);
    try testing.expectEqualStrings("/boot/yoq/boot/0123456789abcdef-yoq.efi", got[0]);
}

/// pe headers with a certificate table of `size` bytes, as a 64-bit
/// image (magic 0x20b) or a 32-bit one.
fn testPe(magic: u16, size: u32) [512]u8 {
    var b = std.mem.zeroes([512]u8);
    b[0] = 'M';
    b[1] = 'Z';
    std.mem.writeInt(u32, b[0x3c..0x40], 0x80, .little);
    @memcpy(b[0x80..0x84], "PE\x00\x00");
    const opt = 0x80 + 24;
    std.mem.writeInt(u16, b[opt..][0..2], magic, .little);
    const dirs: usize = if (magic == 0x20b) opt + 112 else opt + 96;
    std.mem.writeInt(u32, b[dirs - 4 ..][0..4], 16, .little);
    std.mem.writeInt(u32, b[dirs + 32 ..][0..4], 0x1000, .little);
    std.mem.writeInt(u32, b[dirs + 36 ..][0..4], size, .little);
    return b;
}

test "a pe file's signature" {
    try testing.expectEqual(true, signed(&testPe(0x20b, 2048)));
    try testing.expectEqual(false, signed(&testPe(0x20b, 0)));
    try testing.expectEqual(true, signed(&testPe(0x10b, 2048)));
    try testing.expectEqual(null, signed(&testPe(0x999, 2048)));
    try testing.expectEqual(null, signed("not an efi binary"));
    var short = testPe(0x20b, 2048);
    try testing.expectEqual(null, signed(short[0..200]));
    // a pe header said to be past the end.
    std.mem.writeInt(u32, short[0x3c..0x40], 0xffff_fff0, .little);
    try testing.expectEqual(null, signed(&short));
}
