//! what short names in the config turn into on an arch system. the planner
//! derives packages and units from these, so the config can say `ssh = true`
//! instead of naming `openssh` and `sshd.service`.

const std = @import("std");

pub const Service = struct {
    name: []const u8,
    package: []const u8,
    unit: []const u8,
};

/// sorted by name.
pub const services = [_]Service{
    .{ .name = "avahi", .package = "avahi", .unit = "avahi-daemon.service" },
    .{ .name = "bluetooth", .package = "bluez", .unit = "bluetooth.service" },
    .{ .name = "cups", .package = "cups", .unit = "cups.service" },
    .{ .name = "docker", .package = "docker", .unit = "docker.service" },
    .{ .name = "firewalld", .package = "firewalld", .unit = "firewalld.service" },
    .{ .name = "fstrim", .package = "util-linux", .unit = "fstrim.timer" },
    .{ .name = "fwupd", .package = "fwupd", .unit = "fwupd-refresh.timer" },
    .{ .name = "iwd", .package = "iwd", .unit = "iwd.service" },
    .{ .name = "libvirt", .package = "libvirt", .unit = "libvirtd.service" },
    .{ .name = "networkmanager", .package = "networkmanager", .unit = "NetworkManager.service" },
    .{ .name = "power-profiles", .package = "power-profiles-daemon", .unit = "power-profiles-daemon.service" },
    .{ .name = "reflector", .package = "reflector", .unit = "reflector.timer" },
    .{ .name = "resolved", .package = "systemd", .unit = "systemd-resolved.service" },
    .{ .name = "ssh", .package = "openssh", .unit = "sshd.service" },
    .{ .name = "tailscale", .package = "tailscale", .unit = "tailscaled.service" },
    .{ .name = "timesyncd", .package = "systemd", .unit = "systemd-timesyncd.service" },
    .{ .name = "tlp", .package = "tlp", .unit = "tlp.service" },
};

comptime {
    for (services[1..], 1..) |s, i| {
        if (!std.mem.lessThan(u8, services[i - 1].name, s.name)) @compileError("catalog.services isn't sorted at " ++ s.name);
    }
}

pub fn service(name: []const u8) ?Service {
    for (services) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

pub fn serviceNames() [services.len][]const u8 {
    var names: [services.len][]const u8 = undefined;
    for (services, &names) |s, *n| n.* = s.name;
    return names;
}

test "lookup" {
    try std.testing.expectEqualStrings("sshd.service", service("ssh").?.unit);
    try std.testing.expectEqual(null, service("sshd"));
}
