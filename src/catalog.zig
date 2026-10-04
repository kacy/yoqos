//! what short names in the config turn into on an arch system. the planner
//! derives packages and units from these, so the config can say `ssh = true`
//! instead of naming `openssh` and `sshd.service`.

const std = @import("std");
const lists = @import("lists.zig");

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
    return services[lists.indexOf(&services, "name", name) orelse return null];
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

/// packages a `[hardware]` or `[desktop]` choice implies.
pub fn cpuPackages(cpu: anytype) []const []const u8 {
    return switch (cpu) {
        .amd => &.{"amd-ucode"},
        .intel => &.{"intel-ucode"},
    };
}

/// a gpu's driver packages, for a machine booting `kernel`. nvidia's open
/// modules come built for arch's `linux` alone; another kernel has them
/// built by dkms, against its headers.
pub fn gpuPackages(a: std.mem.Allocator, gpu: anytype, kernel: []const u8) ![]const []const u8 {
    return switch (gpu) {
        .amd => &.{ "mesa", "vulkan-radeon" },
        .intel => &.{ "mesa", "vulkan-intel" },
        .nvidia => if (std.mem.eql(u8, kernel, default_kernel) or std.mem.eql(u8, kernel, no_kernel))
            &.{ "nvidia-open", "nvidia-utils" }
        else
            try a.dupe([]const u8, &.{ "nvidia-open-dkms", "nvidia-utils", try std.fmt.allocPrint(a, "{s}-headers", .{kernel}) }),
        .none => &.{},
    };
}

test "nvidia's modules for a kernel other than linux come from dkms" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Gpu = enum { amd, intel, nvidia, none };
    try std.testing.expectEqualStrings("nvidia-open", (try gpuPackages(a, Gpu.nvidia, "linux"))[0]);
    const zen = try gpuPackages(a, Gpu.nvidia, "linux-zen");
    try std.testing.expectEqualStrings("nvidia-open-dkms", zen[0]);
    try std.testing.expectEqualStrings("linux-zen-headers", zen[2]);
}

pub fn sessionPackages(session: anytype) []const []const u8 {
    return switch (session) {
        .hyprland => &.{ "hyprland", "xdg-desktop-portal-hyprland" },
    };
}

pub fn audioPackages(audio: anytype) []const []const u8 {
    return switch (audio) {
        .pipewire => &.{ "pipewire", "pipewire-pulse", "wireplumber" },
    };
}

pub fn loginPackages(login: anytype) []const []const u8 {
    return switch (login) {
        .greetd => &.{ "greetd", "greetd-tuigreet" },
        .sddm => &.{"sddm"},
        .tty => &.{"uwsm"},
    };
}

/// the display manager a login choice enables, if it uses one.
pub fn loginUnit(login: anytype) ?[]const u8 {
    return switch (login) {
        .greetd => "greetd.service",
        .sddm => "sddm.service",
        .tty => null,
    };
}

/// the display managers yos knows. a login choice turns off every one it
/// doesn't use, since only one can be the display manager.
pub const display_managers = [_][]const u8{ "gdm.service", "greetd.service", "lightdm.service", "ly.service", "sddm.service" };

/// the wayland session file a session installs, for starting it on a tty.
pub fn sessionDesktop(session: anytype) []const u8 {
    return switch (session) {
        .hyprland => "hyprland.desktop",
    };
}

pub const default_kernel = "linux";

/// `[boot] kernel = "none"`: a machine without its own kernel, like a
/// container.
pub const no_kernel = "none";

/// whether yos offers to restart a unit that runs replaced files. the
/// plumbing a session hangs on, like d-bus, logins, and display managers,
/// waits for a reboot instead.
pub fn restartable(unit: []const u8) bool {
    return !lists.startsWithAny(unit, &.{ "systemd-", "dbus", "user@", "getty@", "serial-getty@", "polkit", "gdm", "sddm", "lightdm", "greetd", "ly." });
}

/// arch's kernel packages.
pub const kernels = [_][]const u8{ "linux", "linux-lts", "linux-zen", "linux-hardened", "linux-rt", "linux-rt-lts" };

/// packages `yos` won't remove unless a `[remove]` names them: without
/// them the machine can't boot or can't manage packages.
pub const protected = [_][]const u8{ "base", "filesystem", "glibc", "pacman", "systemd" };

/// upgrades worth pointing out even without a reboot: graphics, boot, and
/// the package manager.
pub fn notable(pkg: []const u8) bool {
    return lists.startsWithAny(pkg, &.{ "mesa", "nvidia", "vulkan-", "grub", "limine", "refind", "pacman", "openssh" });
}

/// why changing this package needs a reboot, or null if it can apply live.
/// these are the packages the running system can't swap out safely.
pub fn rebootReason(pkg: []const u8) ?[]const u8 {
    if (lists.contains(&kernels, pkg)) return "kernel";
    const exact = [_]struct { []const u8, []const u8 }{
        .{ "amd-ucode", "microcode" },
        .{ "intel-ucode", "microcode" },
        .{ "linux-firmware", "firmware" },
        .{ "glibc", "glibc" },
        .{ "systemd", "systemd" },
        .{ "dbus", "d-bus" },
        .{ "dbus-broker", "d-bus" },
        .{ "mkinitcpio", "initramfs" },
    };
    for (exact) |e| {
        if (std.mem.eql(u8, e[0], pkg)) return e[1];
    }
    // the driver and its libraries, not the tools beside them, which
    // change nothing the running kernel or session holds.
    if (std.mem.startsWith(u8, pkg, "nvidia") and !lists.startsWithAny(pkg, &.{ "nvidia-settings", "nvidia-prime", "nvidia-container" })) return "gpu driver";
    return null;
}

test "reboot reasons" {
    try std.testing.expectEqualStrings("kernel", rebootReason("linux").?);
    try std.testing.expectEqualStrings("gpu driver", rebootReason("nvidia-utils").?);
    try std.testing.expectEqual(null, rebootReason("nvidia-settings"));
    try std.testing.expectEqual(null, rebootReason("neovim"));
}
