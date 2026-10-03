//! whether a boot file looks like something a bootloader can load. limine
//! stops at an error screen until someone presses a key when an entry's
//! file is missing or broken, so yos looks at a trial's files before the
//! reboot that tries them, and doesn't try them if they're broken.

const std = @import("std");

/// how many bytes of a file `problem` needs: enough for a pe file's
/// headers and its section table.
pub const head_bytes = 4096;

/// what's wrong with a boot file of `size` bytes that starts with `head`
/// and is called `name`, or null if it looks loadable. a `kernel`, what
/// an entry starts, a kernel or an image, is a pe file (arch's kernels
/// are, with their efi stub), and has to hold every section its headers
/// name, so a cut-off copy fails. any other file, like an initramfs,
/// can't be empty, and a copy yos named "<hash>-<name>" has to still have
/// that hash, `sum`'s first 16 hex digits, which the caller works out
/// only when `hashedName` says so.
pub fn problem(kernel: bool, name: []const u8, head: []const u8, size: u64, sum: ?[]const u8) ?[]const u8 {
    if (size == 0) return "it's empty";
    if (kernel) {
        if (!peWhole(head, size)) return "it isn't a whole efi binary";
        return null;
    }
    const want = hashedName(name) orelse return null;
    const got = sum orelse return null;
    if (got.len < 16 or !std.ascii.eqlIgnoreCase(got[0..16], want)) return "its content doesn't match the hash in its name";
    return null;
}

/// the hash in the name of a copy yos put on the esp, "<16 hex>-<name>",
/// or null for a name without one.
pub fn hashedName(name: []const u8) ?[]const u8 {
    const base = std.fs.path.basenamePosix(name);
    if (base.len < 18 or base[16] != '-') return null;
    for (base[0..16]) |ch| {
        if (!std.ascii.isHex(ch)) return null;
    }
    return base[0..16];
}

/// whether the pe file that starts with `head` has all of its sections
/// within its `size` bytes.
pub fn peWhole(head: []const u8, size: u64) bool {
    if (head.len < 0x40 or !std.mem.eql(u8, head[0..2], "MZ")) return false;
    const pe = std.mem.readInt(u32, head[0x3c..0x40], .little);
    if (pe > head.len -| 24 or !std.mem.eql(u8, head[pe..][0..4], "PE\x00\x00")) return false;
    const sections = std.mem.readInt(u16, head[pe + 6 ..][0..2], .little);
    const optional = std.mem.readInt(u16, head[pe + 20 ..][0..2], .little);
    const table = @as(usize, pe) + 24 + optional;
    if (sections == 0 or table + @as(usize, sections) * 40 > head.len) return false;
    for (0..sections) |i| {
        const s = head[table + i * 40 ..][0..40];
        const raw_size = std.mem.readInt(u32, s[16..20], .little);
        const raw_at = std.mem.readInt(u32, s[20..24], .little);
        if (@as(u64, raw_at) + raw_size > size) return false;
    }
    return true;
}

/// a pe file's headers with one section of `raw_size` bytes at
/// `raw_at`, for tests.
pub fn testPe(raw_at: u32, raw_size: u32) [512]u8 {
    var b = std.mem.zeroes([512]u8);
    b[0] = 'M';
    b[1] = 'Z';
    std.mem.writeInt(u32, b[0x3c..0x40], 0x80, .little);
    @memcpy(b[0x80..0x84], "PE\x00\x00");
    std.mem.writeInt(u16, b[0x80 + 6 ..][0..2], 1, .little);
    std.mem.writeInt(u16, b[0x80 + 20 ..][0..2], 240, .little);
    const s = 0x80 + 24 + 240;
    std.mem.writeInt(u32, b[s + 16 ..][0..4], raw_size, .little);
    std.mem.writeInt(u32, b[s + 20 ..][0..4], raw_at, .little);
    return b;
}

test "a kernel or image is whole, or it isn't" {
    const pe = testPe(0x400, 0x1000);
    try std.testing.expectEqual(null, problem(true, "vmlinuz-linux", &pe, 0x1400, null));
    // cut off before its last section ends.
    try std.testing.expectEqualStrings("it isn't a whole efi binary", problem(true, "0123456789abcdef-vmlinuz-linux", &pe, 0x1000, null).?);
    try std.testing.expectEqualStrings("it isn't a whole efi binary", problem(true, "garbage", "not a kernel\n", 13, null).?);
    try std.testing.expectEqualStrings("it's empty", problem(true, "vmlinuz-linux", "", 0, null).?);
}

test "a copy yos named by its hash still has that hash" {
    const name = "0123456789abcdef-initramfs-linux.img";
    try std.testing.expectEqualStrings("0123456789abcdef", hashedName(name).?);
    try std.testing.expectEqual(null, problem(false, name, "x", 1, "0123456789ABCDEF00"));
    try std.testing.expectEqualStrings("its content doesn't match the hash in its name", problem(false, name, "x", 1, "ffff456789abcdef00").?);
    // without a hash in its name, only an empty file is a problem.
    try std.testing.expectEqual(null, hashedName("initramfs-linux.img"));
    try std.testing.expectEqual(null, problem(false, "initramfs-linux.img", "x", 1, null));
    try std.testing.expectEqual(null, hashedName("0123456789abcdeg-x"));
}
