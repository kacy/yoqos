//! the config `os init --new` writes for a machine that has nothing on it
//! yet, from a few answers and what the live system can see of the
//! hardware. it has what a new machine can't do without: a kernel, the
//! bootloader, firmware on real hardware, a network, and a user who can use
//! sudo. this part is pure; cmd/init.zig asks and writes.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Answers = struct {
    hostname: []const u8,
    user: []const u8,
    timezone: []const u8 = "UTC",
    /// "amd" or "intel", for its microcode.
    cpu: ?[]const u8 = null,
    /// "amd", "intel", or "nvidia", for its driver.
    gpu: ?[]const u8 = null,
    /// real hardware wants linux-firmware; a virtual machine doesn't.
    firmware: bool = true,
    ssh: bool = false,
};

pub fn machineToml(a: Allocator, x: Answers) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a,
        \\# written by os init --new: a small machine to start from. add to it;
        \\# `os docs` says everything a config can hold.
        \\version = 1
        \\packages = [
        \\  "base",
        \\  "linux",
        \\
    );
    if (x.firmware) try out.appendSlice(a, "  \"linux-firmware\",\n");
    try out.appendSlice(a,
        \\  "grub",
        \\  "efibootmgr",
        \\  "btrfs-progs",
        \\  "sudo",
        \\]
        \\
    );
    try out.print(a, "\n[system]\nhostname = \"{s}\"\ntimezone = \"{s}\"\n", .{ x.hostname, x.timezone });
    if (x.cpu != null or x.gpu != null) {
        try out.appendSlice(a, "\n[hardware]\n");
        if (x.cpu) |c| try out.print(a, "cpu = \"{s}\"\n", .{c});
        if (x.gpu) |g| try out.print(a, "gpu = \"{s}\"\n", .{g});
    }
    try out.print(a, "\n[users.{s}]\ngroups = [\"wheel\"]\n", .{x.user});
    try out.appendSlice(a, "\n[services]\nnetworkmanager = true\n");
    if (x.ssh) try out.appendSlice(a, "ssh = true\n");
    try out.appendSlice(a,
        \\
        \\# choices pacman would otherwise ask about, answered the usual way.
        \\[providers]
        \\initramfs = "mkinitcpio"
        \\"libxtables.so" = "iptables"
        \\
        \\# people in wheel can use sudo, with their own password.
        \\[files."/etc/sudoers.d/10-wheel"]
        \\text = "%wheel ALL=(ALL:ALL) ALL\n"
        \\mode = "0440"
        \\
    );
    return out.items;
}

/// the config's gpu value for what the machine has: nvidia if there's one,
/// since it needs its own driver, then amd, then intel.
pub fn gpuChoice(gpus: []const []const u8) ?[]const u8 {
    for ([_][]const u8{ "nvidia", "amd", "intel" }) |want| {
        for (gpus) |g| {
            if (std.mem.eql(u8, g, want)) return want;
        }
    }
    return null;
}

test "a new machine's config loads, with what a new machine needs" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try machineToml(a, .{ .hostname = "atlas", .user = "kacy", .timezone = "America/New_York", .cpu = "amd", .gpu = "nvidia", .ssh = true });
    const c = try @import("test_helpers.zig").configFrom(a, text);
    try std.testing.expect(c.packages.contains("linux-firmware"));
    try std.testing.expect(c.packages.contains("grub"));
    try std.testing.expectEqualStrings("atlas", c.system.hostname.?.v);
    try std.testing.expect(c.users.get("kacy").?.groups.contains("wheel"));
    const vm = try machineToml(a, .{ .hostname = "box", .user = "me", .firmware = false });
    try std.testing.expect(std.mem.indexOf(u8, vm, "linux-firmware") == null);
    try std.testing.expect(std.mem.indexOf(u8, vm, "[hardware]") == null);
    _ = try @import("test_helpers.zig").configFrom(a, vm);
    try std.testing.expectEqualStrings("nvidia", gpuChoice(&.{ "intel", "nvidia" }).?);
    try std.testing.expectEqual(null, gpuChoice(&.{"vmware"}));
}
