//! secure boot with sbctl's keys: os signs the unified kernel images it
//! puts on the esp, and the loader files it installs there, with
//! `sbctl sign`. the keys are sbctl's own, in /var/lib/sbctl, which no
//! generation holds, so they outlast every rollback. os never makes or
//! enrolls keys. this part is pure; images.zig signs.

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

/// the firmware's db: the certificates it starts images signed with.
pub const db_var = "sys/firmware/efi/efivars/db-d719b2cb-3d3a-4596-a3bc-dad00e67656f";

/// EFI_CERT_X509_GUID as it's stored: a signature list of certificates.
const x509_guid = [16]u8{ 0xa1, 0x59, 0xc0, 0xa5, 0xe4, 0x94, 0xa7, 0x4a, 0x87, 0xb5, 0xab, 0x15, 0x5c, 0x2b, 0xf0, 0x72 };

/// whether the certificate in `pem`, like sbctl's db.pem, is in `db`, the
/// firmware's db variable as efivarfs shows it: four bytes of attributes,
/// then signature lists, each a type, its sizes, and entries of an owner
/// and the certificate. null if either can't be read.
pub fn inDb(a: Allocator, db: []const u8, pem: []const u8) !?bool {
    const der = try pemDer(a, pem) orelse return null;
    if (db.len < 4) return null;
    var rest = db[4..];
    while (rest.len > 0) {
        if (rest.len < 28) return null;
        const list_size = std.mem.readInt(u32, rest[16..20], .little);
        const header_size = std.mem.readInt(u32, rest[20..24], .little);
        const entry_size = std.mem.readInt(u32, rest[24..28], .little);
        if (list_size < 28 or list_size > rest.len or header_size > list_size - 28) return null;
        const list = rest[0..list_size];
        rest = rest[list_size..];
        if (!std.mem.eql(u8, list[0..16], &x509_guid) or entry_size <= 16) continue;
        var entries = list[28 + header_size ..];
        while (entries.len >= entry_size) : (entries = entries[entry_size..]) {
            if (std.mem.eql(u8, entries[16..entry_size], der)) return true;
        }
    }
    return false;
}

/// whether images get signed whatever the config says: the firmware
/// enforces secure boot, and sbctl has keys to sign with. a generation
/// without `[boot] secure_boot`, like one rolled back to, or a config
/// that turned it off before the firmware did, still starts then.
pub fn enforcedWithKeys(enforced: ?bool, keys: bool) bool {
    return keys and (enforced orelse false);
}

/// what a menu write does with a file it can't sign: stop, or, on a way
/// back, like a rollback, a fallback, or gc, go on without the signature.
/// a way back must never be blocked by signing; apply and update stop
/// with E0134 before they get there when sbctl has no keys.
pub fn goesOnUnsigned(way_back: bool) bool {
    return way_back;
}

/// the warning for files a way back left without a signature.
pub fn unsignedWarning(a: Allocator, files: []const []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "couldn't sign {s} for secure boot, so the boot menu uses them unsigned, and firmware that enforces secure boot won't start them. put sbctl's keys back in /var/lib/sbctl, or make new ones with `sbctl create-keys` and enroll them, then run `os gc`, which signs them.", .{try std.mem.join(a, ", ", files)});
}

/// the command that signs `file` in place with sbctl's db key. `signer`
/// is sbctl, or a stand-in in tests.
pub fn signArgv(a: Allocator, signer: []const []const u8, file: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, signer);
    try argv.appendSlice(a, &.{ "sign", file });
    return argv.items;
}

/// a one-byte efi variable's value, as efivarfs shows it: four bytes of
/// attributes, then the value. null if it isn't one.
pub fn efiFlag(bytes: []const u8) ?bool {
    if (bytes.len != 5) return null;
    return bytes[4] != 0;
}

/// how much of an efi binary `certTable` needs: its headers.
pub const header_bytes = 4096;

/// where a pe file's signatures are: its certificate table, the fifth
/// data directory, whose address is an offset in the file.
pub const Table = struct { offset: u32, size: u32 };

/// whether the pe file that starts with `head` has an authenticode
/// signature: its certificate table isn't empty. null when `head` isn't
/// a pe file's headers. it says nothing about whose key signed it;
/// `signedBy` does.
pub fn signed(head: []const u8) ?bool {
    const t = certTable(head) orelse return null;
    return t.size > 0;
}

/// the certificate table of the pe file that starts with `head`, empty
/// when it has none. null when `head` isn't a pe file's headers.
pub fn certTable(head: []const u8) ?Table {
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
    if (std.mem.readInt(u32, head[count_at..][0..4], .little) < 5) return .{ .offset = 0, .size = 0 };
    return .{
        .offset = std.mem.readInt(u32, head[dirs + 4 * 8 ..][0..4], .little),
        .size = std.mem.readInt(u32, head[dirs + 4 * 8 + 4 ..][0..4], .little),
    };
}

/// whether `table`, a pe file's certificate table, has a signature from
/// the certificate `key` names, as `signerKey` makes it. an authenticode
/// signature names its signer by the certificate's issuer and serial
/// number, together in that order, so finding them is enough; it doesn't
/// check the signature itself, which the firmware does.
pub fn signedBy(table: []const u8, key: []const u8) bool {
    return key.len > 0 and std.mem.indexOf(u8, table, key) != null;
}

/// what names the certificate in `pem`, like sbctl's db.pem, as a signer:
/// its issuer and serial number, in der, as a signature's signer info has
/// them. null if it isn't a certificate.
pub fn signerKey(a: Allocator, pem: []const u8) !?[]const u8 {
    const der = try pemDer(a, pem) orelse return null;
    // Certificate ::= SEQUENCE { tbsCertificate, ... }, and tbsCertificate
    // ::= SEQUENCE { [0] version OPTIONAL, serialNumber, signature, issuer, ... }
    const cert = (der_parse.next(der) orelse return null).tlv;
    if (cert.tag != 0x30) return null;
    const tbs = (der_parse.next(cert.content) orelse return null).tlv;
    if (tbs.tag != 0x30) return null;
    var item = der_parse.next(tbs.content) orelse return null;
    if (item.tlv.tag == 0xa0) item = der_parse.next(item.rest) orelse return null;
    const serial = item.tlv;
    item = der_parse.next(item.rest) orelse return null;
    item = der_parse.next(item.rest) orelse return null;
    const issuer = item.tlv;
    if (serial.tag != 0x02 or issuer.tag != 0x30) return null;
    return try std.mem.concat(a, u8, &.{ issuer.all, serial.all });
}

/// the der in a pem certificate. null if there's none.
fn pemDer(a: Allocator, pem: []const u8) !?[]const u8 {
    const begin = "-----BEGIN CERTIFICATE-----";
    const start = (std.mem.indexOf(u8, pem, begin) orelse return null) + begin.len;
    const end = std.mem.indexOfPos(u8, pem, start, "-----END CERTIFICATE-----") orelse return null;
    var text: std.ArrayList(u8) = .empty;
    for (pem[start..end]) |ch| {
        if (!std.ascii.isWhitespace(ch)) try text.append(a, ch);
    }
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(text.items) catch return null;
    const out = try a.alloc(u8, size);
    decoder.decode(out, text.items) catch return null;
    return out;
}

/// just enough der to find a certificate's issuer and serial number.
const der_parse = struct {
    const Tlv = struct { tag: u8, all: []const u8, content: []const u8 };

    /// the first value in `bytes`, and what follows it. null if it's cut
    /// short or its length is past what os reads.
    fn next(bytes: []const u8) ?struct { tlv: Tlv, rest: []const u8 } {
        if (bytes.len < 2) return null;
        var len: usize = bytes[1];
        var head: usize = 2;
        if (len >= 0x80) {
            const n = len & 0x7f;
            if (n == 0 or n > 4 or bytes.len < 2 + n) return null;
            len = 0;
            for (bytes[2 .. 2 + n]) |b| len = len << 8 | b;
            head += n;
        }
        if (len > bytes.len - head) return null;
        const end = head + len;
        return .{ .tlv = .{ .tag = bytes[0], .all = bytes[0..end], .content = bytes[head..end] }, .rest = bytes[end..] };
    }
};

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
    const argv = try signArgv(arena.allocator(), &.{package}, "/run/yoq/private/top/@roots/4/tmp/yoq-uki/yoq.efi");
    try testing.expectEqual(3, argv.len);
    try testing.expectEqualStrings("sbctl", argv[0]);
    try testing.expectEqualStrings("sign", argv[1]);
    try testing.expectEqualStrings("/run/yoq/private/top/@roots/4/tmp/yoq-uki/yoq.efi", argv[2]);
}

/// a db variable with a list of hashes, then one list of `certs`, after
/// efivarfs's four bytes of attributes.
fn testDb(a: Allocator, certs: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, &.{ 0x27, 0, 0, 0 });
    try out.appendSlice(a, &([_]u8{0x26} ** 16));
    for ([_]u32{ 28 + 48, 0, 48 }) |n| try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, n)));
    try out.appendSlice(a, &([_]u8{0} ** 48));
    for (certs) |c| {
        try out.appendSlice(a, &x509_guid);
        for ([_]u32{ @intCast(28 + 16 + c.len), 0, @intCast(16 + c.len) }) |n| try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, n)));
        try out.appendSlice(a, &([_]u8{0x77} ** 16));
        try out.appendSlice(a, c);
    }
    return out.items;
}

test "sbctl's certificate in the firmware's db" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mine = try testCert(a, "sbctl db", &.{7});
    const theirs = try testCert(a, "microsoft", &.{9});
    const mine_der = (try pemDer(a, mine.pem)).?;
    const theirs_der = (try pemDer(a, theirs.pem)).?;
    try testing.expectEqual(true, try inDb(a, try testDb(a, &.{ theirs_der, mine_der }), mine.pem));
    try testing.expectEqual(false, try inDb(a, try testDb(a, &.{theirs_der}), mine.pem));
    try testing.expectEqual(false, try inDb(a, try testDb(a, &.{}), mine.pem));
    // cut short, or nothing to compare with.
    const db = try testDb(a, &.{mine_der});
    try testing.expectEqual(null, try inDb(a, db[0 .. db.len - 3], mine.pem));
    try testing.expectEqual(null, try inDb(a, "", mine.pem));
    try testing.expectEqual(null, try inDb(a, db, "not a certificate"));
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

test "signing while the firmware enforces secure boot" {
    try testing.expect(enforcedWithKeys(true, true));
    try testing.expect(!enforcedWithKeys(true, false));
    try testing.expect(!enforcedWithKeys(false, true));
    try testing.expect(!enforcedWithKeys(null, true));
}

test "a way back goes on without signatures" {
    try testing.expect(goesOnUnsigned(true));
    try testing.expect(!goesOnUnsigned(false));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const w = try unsignedWarning(arena.allocator(), &.{ "/boot/yoq/boot/a-yoq.efi", "/boot/yoq/boot/b-yoq.efi" });
    try testing.expect(std.mem.startsWith(u8, w, "couldn't sign /boot/yoq/boot/a-yoq.efi, /boot/yoq/boot/b-yoq.efi for secure boot"));
    try testing.expect(std.mem.indexOf(u8, w, "`os gc`") != null);
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
pub fn testPe(magic: u16, size: u32) [512]u8 {
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

/// a der value with `tag` around `content`.
pub fn testDer(a: Allocator, tag: u8, content: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, tag);
    if (content.len < 0x80) {
        try out.append(a, @intCast(content.len));
    } else {
        try out.appendSlice(a, &.{ 0x82, @intCast(content.len >> 8), @intCast(content.len & 0xff) });
    }
    try out.appendSlice(a, content);
    return out.items;
}

/// a certificate issued by `cn`, with serial number `serial`, as pem, and
/// its issuer and serial number as a signature names them.
pub fn testCert(a: Allocator, cn: []const u8, serial: []const u8) !struct { pem: []const u8, key: []const u8 } {
    const oid_cn = try testDer(a, 0x06, &.{ 0x55, 0x04, 0x03 });
    const issuer = try testDer(a, 0x30, try testDer(a, 0x31, try testDer(a, 0x30, try std.mem.concat(a, u8, &.{ oid_cn, try testDer(a, 0x0c, cn) }))));
    const serial_der = try testDer(a, 0x02, serial);
    const alg = try testDer(a, 0x30, try testDer(a, 0x06, &.{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b }));
    // a long subject key, so lengths take more than a byte.
    const key_info = try testDer(a, 0x30, &([_]u8{0} ** 300));
    const tbs = try testDer(a, 0x30, try std.mem.concat(a, u8, &.{ try testDer(a, 0xa0, try testDer(a, 0x02, &.{2})), serial_der, alg, issuer, try testDer(a, 0x30, ""), issuer, key_info }));
    const cert = try testDer(a, 0x30, try std.mem.concat(a, u8, &.{ tbs, alg, try testDer(a, 0x03, &.{ 0, 1 }) }));
    const enc = std.base64.standard.Encoder;
    const b64 = try a.alloc(u8, enc.calcSize(cert.len));
    _ = enc.encode(b64, cert);
    var pem: std.ArrayList(u8) = .empty;
    try pem.appendSlice(a, "-----BEGIN CERTIFICATE-----\n");
    var i: usize = 0;
    while (i < b64.len) : (i += 64) try pem.print(a, "{s}\n", .{b64[i..@min(i + 64, b64.len)]});
    try pem.appendSlice(a, "-----END CERTIFICATE-----\n");
    return .{ .pem = pem.items, .key = try std.mem.concat(a, u8, &.{ issuer, serial_der }) };
}

test "a signature from sbctl's db key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try testCert(a, "yoq db", &.{ 0x01, 0x23, 0x45 });
    const key = (try signerKey(a, db.pem)).?;
    try testing.expectEqualSlices(u8, db.key, key);
    // a signer info names the issuer, then the serial number.
    const signer_info = try testDer(a, 0x30, try std.mem.concat(a, u8, &.{ try testDer(a, 0x02, &.{1}), try testDer(a, 0x30, key) }));
    const table = try std.mem.concat(a, u8, &.{ &.{ 0, 1, 0, 0, 0, 2, 2, 0 }, signer_info });
    try testing.expect(signedBy(table, key));
    // the same name with another serial number is another key, as after
    // `sbctl create-keys` again.
    const other = try testCert(a, "yoq db", &.{ 0x01, 0x23, 0x46 });
    try testing.expect(!signedBy(table, (try signerKey(a, other.pem)).?));
    try testing.expect(!signedBy(table, ""));
    try testing.expectEqual(null, try signerKey(a, "not a certificate"));
    try testing.expectEqual(null, try signerKey(a, "-----BEGIN CERTIFICATE-----\nMAA=\n-----END CERTIFICATE-----\n"));
    try testing.expectEqual(null, try signerKey(a, "-----BEGIN CERTIFICATE-----\n!!!!\n-----END CERTIFICATE-----\n"));
}

test "a pe file's signature" {
    try testing.expectEqual(true, signed(&testPe(0x20b, 2048)));
    try testing.expectEqual(Table{ .offset = 0x1000, .size = 2048 }, certTable(&testPe(0x20b, 2048)).?);
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
