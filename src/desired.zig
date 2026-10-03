//! the files yos writes from the config: `[files]`, and the ones other
//! keys make, like the sysctl file, mkinitcpio drop-ins, and the configs
//! that tell the boot menu to build and sign images. pure, like the
//! planner, which compares them with what the machine has.

const std = @import("std");
const config = @import("config.zig");
const facts = @import("facts.zig");
const catalog = @import("catalog.zig");
const aur = @import("aur.zig");
const lists = @import("lists.zig");
const generation = @import("generation.zig");
const uki = @import("uki.zig");
const secureboot = @import("secureboot.zig");
const Allocator = std.mem.Allocator;

/// whether the config has repositories of its own for pacman: declared
/// ones, or the local one aur packages are built into.
pub fn ownRepos(c: *const config.Config) bool {
    return c.repos.entries.items.len > 0 or c.aur.items.items.len > 0;
}

/// a file yos writes, from `[files]` or made from another key.
pub const File = struct {
    path: []const u8,
    content: []const u8,
    /// for a file that holds a secret: its name, and `content` is empty.
    /// apply reads the value only as it writes the file.
    secret: ?[]const u8 = null,
    mode: []const u8 = config.File.default_mode,
    /// the key that makes the file, for ones `[files]` doesn't name.
    cause: ?[]const u8 = null,
    /// where that key is set, when the config sets it.
    src: ?config.Src = null,
    /// why a change to it needs a reboot, if one does.
    reboot: ?[]const u8 = null,
};

/// where `[sysctl]` goes.
pub const sysctl_path = "/etc/sysctl.d/99-yos.conf";

/// where `[boot] modules` goes.
pub const modules_path = "/etc/modules-load.d/99-yos.conf";

pub const greetd_config_path = "/etc/greetd/config.toml";
const tty_session_path = "/etc/profile.d/yos-session.sh";

/// mkinitcpio's drop-in that loads nvidia's modules early.
pub const nvidia_initramfs_path = "/etc/mkinitcpio.conf.d/10-yos-nvidia.conf";

/// mkinitcpio's drop-in that unlocks a luks root.
pub const encrypt_initramfs_path = facts.initramfs_dropins ++ "/" ++ facts.encrypt_dropin;

/// whether a file yos writes is a mkinitcpio drop-in. changing one changes
/// the initramfs, so it waits for a reboot like a kernel does, and apply
/// rebuilds the initramfs in the root it builds.
pub fn isInitramfsDropIn(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/etc/mkinitcpio.conf.d/");
}

/// why a change to a file yos writes needs a reboot: a drop-in changes the
/// initramfs, the ukify config changes what the menu boots, and the
/// secure boot file whether its images are signed.
pub fn fileReboot(path: []const u8) ?[]const u8 {
    if (isInitramfsDropIn(path)) return "initramfs";
    if (std.mem.eql(u8, path, secureboot.config_path)) return secure_boot_reboot;
    return if (std.mem.eql(u8, path, uki.config_path)) uki_reboot else null;
}

/// the reboot reason for turning `[boot] uki` on or off.
pub const uki_reboot = "uki";

/// the reboot reason for turning `[boot] secure_boot` on or off.
pub const secure_boot_reboot = "secure boot";

/// files yos writes from other keys, each starting with a "written by yos"
/// line. one still there that nothing asks for any more is removed. the
/// session's own config isn't here: it's the user's file.
pub const generated_paths = [_][]const u8{ sysctl_path, modules_path, greetd_config_path, tty_session_path, nvidia_initramfs_path, encrypt_initramfs_path, uki.config_path, secureboot.config_path };

/// the first line of a file yos makes from `key`.
fn header(comptime key: []const u8) []const u8 {
    return "# written by yos from " ++ key ++ " in the config. edits here are overwritten.\n";
}

/// tuigreet on tty1, offering every installed wayland session.
const greetd_config =
    \\# written by yos for [desktop] login = "greetd". edits here are overwritten.
    \\[terminal]
    \\vt = 1
    \\
    \\[default_session]
    \\command = "tuigreet --time --remember --remember-session --sessions /usr/share/wayland-sessions"
    \\user = "greeter"
    \\
;

/// logging in on tty1 starts the session through uwsm.
const tty_session =
    \\# written by yos for [desktop] login = "tty". edits here are overwritten.
    \\if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = /dev/tty1 ] && uwsm check may-start; then
    \\    exec uwsm start {s}
    \\fi
    \\
;

/// the modules nvidia's driver wants early.
const nvidia_modules = [_][]const u8{ "nvidia", "nvidia_modeset", "nvidia_uvm", "nvidia_drm" };

const nvidia_initramfs_content = blk: {
    var s: []const u8 = "# written by yos for [hardware] gpu = \"nvidia\".\nMODULES+=(" ++ nvidia_modules[0];
    for (nvidia_modules[1..]) |m| s = s ++ " " ++ m;
    break :blk s ++ ")\n";
};

/// sd-encrypt unlocks the root with what the kernel's command line names,
/// and it needs systemd in the initramfs: busybox's hooks (udev, keymap,
/// consolefont, and resume and usr, which systemd does itself) become
/// systemd's, sd-encrypt goes before filesystems, and keyboard before
/// that, to type the passphrase with. mkinitcpio sources drop-ins as
/// bash, after its own config, so this works on whatever hooks are set.
pub const encrypt_initramfs_content =
    \\# written by yos from [boot] encrypt in the config. edits here are overwritten.
    \\_yos_hooks=()
    \\for _yos_hook in "${HOOKS[@]}"; do
    \\    case $_yos_hook in
    \\    udev) _yos_hook=systemd ;;
    \\    keymap | consolefont) _yos_hook=sd-vconsole ;;
    \\    encrypt | sd-encrypt | resume | usr) continue ;;
    \\    filesystems)
    \\        [[ " ${_yos_hooks[*]} " == *" keyboard "* ]] || _yos_hooks+=(keyboard)
    \\        _yos_hooks+=(sd-encrypt)
    \\        ;;
    \\    esac
    \\    [[ " ${_yos_hooks[*]} " == *" $_yos_hook "* ]] || _yos_hooks+=("$_yos_hook")
    \\done
    \\HOOKS=("${_yos_hooks[@]}")
    \\unset _yos_hooks _yos_hook
    \\# with autodetect, add_checked_modules keeps only the modules this machine
    \\# uses, and mkinitcpio counts finding none as a failed build, without
    \\# saying why. that's what it finds when the driver is built into the
    \\# kernel, as arch's tpm and btrfs drivers are, and sd-encrypt asks for
    \\# the tpm's on every build. finding none isn't a failure here; a module
    \\# it finds and can't add still is.
    \\if declare -F add_checked_modules >/dev/null && ! declare -F _yos_add_checked_modules >/dev/null; then
    \\    eval "_yos_$(declare -f add_checked_modules)"
    \\    add_checked_modules() {
    \\        _yos_add_checked_modules "$@" || true
    \\    }
    \\fi
    \\
;

/// every file the config wants: `[files]`, then the ones other keys make.
/// nvidia's initramfs drop-in is left out when the machine loads those
/// modules already, as `f` shows.
pub fn files(a: Allocator, c: *const config.Config, f: *const facts.Facts) ![]const File {
    var out: std.ArrayList(File) = .empty;
    for (c.files.entries.items) |e| {
        if (e.value.secret) |s| {
            try out.append(a, .{ .path = e.name, .content = "", .secret = s.v, .mode = e.value.modeOf() });
            continue;
        }
        // a source that couldn't be read was reported when loading.
        const content = e.value.content orelse continue;
        try out.append(a, .{ .path = e.name, .content = content, .mode = e.value.modeOf() });
    }
    const made = [_]?File{
        try sysctlFile(a, c),
        try loginFile(a, c),
        try reposFile(a, c, f),
        try sessionFile(a, c),
        try modulesFile(a, c),
        nvidiaFile(c, f),
        encryptFile(c, f),
        ukiFile(c, f),
        secureBootFile(c, f),
    };
    for (made) |m| {
        if (m) |d| try out.append(a, d);
    }
    return out.items;
}

fn sysctlFile(a: Allocator, c: *const config.Config) !?File {
    if (c.sysctl.entries.items.len == 0) return null;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, header("[sysctl]"));
    for (try sortedNames(a, c.sysctl.entries.items)) |k| try text.print(a, "{s} = {s}\n", .{ k, c.sysctl.get(k).?.v.text });
    return .{ .path = sysctl_path, .content = text.items, .cause = "sysctl", .src = c.sysctl.entries.items[0].value.src };
}

fn modulesFile(a: Allocator, c: *const config.Config) !?File {
    if (c.boot.modules.items.items.len == 0) return null;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, header("[boot] modules"));
    for (try sortedNames(a, c.boot.modules.items.items)) |n| try text.print(a, "{s}\n", .{n});
    return .{ .path = modules_path, .content = text.items, .cause = "boot.modules", .src = c.boot.modules.items.items[0].src };
}

/// the `name` of each item, sorted, so a file doesn't depend on the
/// config's order.
fn sortedNames(a: Allocator, items: anytype) ![]const []const u8 {
    const names = try a.alloc([]const u8, items.len);
    for (items, names) |it, *n| n.* = it.name;
    lists.sortStrings(names);
    return names;
}

fn loginFile(a: Allocator, c: *const config.Config) !?File {
    const login = c.desktop.login orelse return null;
    return switch (login.v) {
        .greetd => .{ .path = greetd_config_path, .content = greetd_config, .cause = "desktop.login", .src = login.src },
        .tty => .{
            .path = tty_session_path,
            .content = try std.fmt.allocPrint(a, tty_session, .{catalog.sessionDesktop((c.desktop.session orelse return null).v)}),
            .cause = "desktop.login",
            .src = login.src,
        },
        .sddm => null,
    };
}

/// the file pacman.conf includes for the config's repositories. once
/// pacman.conf reads it, it stays, empty if need be: pacman fails on an
/// include that's gone.
fn reposFile(a: Allocator, c: *const config.Config, f: *const facts.Facts) !?File {
    if (!ownRepos(c) and !f.pacman.includes_repos) return null;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, header("[repos]"));
    for (c.repos.entries.items) |e| {
        // one without a server was reported when the config loaded.
        const server = e.value.server orelse continue;
        // with a key, packages must be signed by it; without one, they
        // aren't checked.
        const siglevel = if (e.value.key != null) "Required DatabaseOptional" else "Optional TrustAll";
        try text.print(a, "\n[{s}]\nSigLevel = {s}\nServer = {s}\n", .{ e.name, siglevel, server.v });
    }
    // the aur packages yos builds, unsigned, in a local repository.
    if (c.aur.items.items.len > 0) try text.print(a, "\n[{s}]\nSigLevel = Optional TrustAll\nServer = file://{s}\n", .{ aur.repo_name, aur.repo_dir });
    return .{ .path = facts.repos_conf, .content = text.items, .cause = "repos", .src = reposSrc(c) };
}

/// where the config first asks for a repository of its own, if it does.
pub fn reposSrc(c: *const config.Config) ?config.Src {
    if (c.repos.entries.items.len > 0) return c.repos.entries.items[0].value.src;
    if (c.aur.items.items.len > 0) return c.aur.items.items[0].src;
    return null;
}

/// hyprland reads /etc/xdg/hypr when a user has no config of their own.
/// the file keeps its extension: .conf, or .lua for newer ones.
fn sessionFile(a: Allocator, c: *const config.Config) !?File {
    const content = c.desktop.session_content orelse return null;
    const ext = std.fs.path.extension(c.desktop.session_config.?.v);
    return .{
        .path = try std.fmt.allocPrint(a, "/etc/xdg/hypr/hyprland{s}", .{if (ext.len > 0) ext else ".conf"}),
        .content = content,
        .cause = "desktop.session_config",
        .src = c.desktop.session_config.?.src,
    };
}

/// nvidia's driver wants its modules in the initramfs. amd and intel come
/// with mkinitcpio's kms hook already.
fn nvidiaFile(c: *const config.Config, f: *const facts.Facts) ?File {
    const gpu = c.hardware.gpu orelse return null;
    if (gpu.v != .nvidia) return null;
    if (c.providers.get("initramfs")) |p| {
        if (!std.mem.eql(u8, p.v, "mkinitcpio")) return null;
    }
    for (nvidia_modules) |m| {
        if (!lists.contains(f.initramfs_modules, m)) break;
    } else return null;
    return .{ .path = nvidia_initramfs_path, .content = nvidia_initramfs_content, .cause = "hardware.gpu", .src = gpu.src, .reboot = "initramfs" };
}

/// the drop-in for `[boot] encrypt`, unless mkinitcpio's hooks unlock
/// luks already, as an encrypted archinstall's do, or another initramfs
/// generator builds it.
fn encryptFile(c: *const config.Config, f: *const facts.Facts) ?File {
    const encrypt = c.boot.encrypt orelse return null;
    if (!encrypt.v) return null;
    if (c.providers.get("initramfs")) |p| {
        if (!std.mem.eql(u8, p.v, "mkinitcpio")) return null;
    }
    if (facts.hasEncryptHook(f.boot.initramfs_hooks)) return null;
    return .{ .path = encrypt_initramfs_path, .content = encrypt_initramfs_content, .cause = "boot.encrypt", .src = encrypt.src, .reboot = "initramfs" };
}

/// the ukify config for `[boot] uki`, which has the menu boot an image.
fn ukiFile(c: *const config.Config, f: *const facts.Facts) ?File {
    return menuFile(c.boot.uki, f, .{ .path = uki.config_path, .content = uki.config_content, .cause = "boot.uki", .reboot = uki_reboot });
}

/// the file that has a root's images signed for `[boot] secure_boot`.
fn secureBootFile(c: *const config.Config, f: *const facts.Facts) ?File {
    return menuFile(c.boot.secure_boot, f, .{ .path = secureboot.config_path, .content = secureboot.config_content, .cause = "boot.secure_boot", .reboot = secure_boot_reboot });
}

/// `file`, which tells yos's boot menu how to boot a root, when `key` is
/// on and yos writes the menu: in a root running a generation, or one
/// being built, where mounts say nothing (no root filesystem in facts).
/// a machine without generations boots the way it always has, so there
/// the key only brings its package. the next menu reads it, so a change
/// waits for a reboot.
fn menuFile(key: ?config.Val(bool), f: *const facts.Facts, file: File) ?File {
    const v = key orelse return null;
    if (!v.v) return null;
    if (f.boot.root_fs != null and !generation.on(f.boot)) return null;
    var out = file;
    out.src = v.src;
    return out;
}

pub fn paths(a: Allocator, c: *const config.Config) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try files(a, c, &.{})) |d| try out.append(a, d.path);
    for (generated_paths) |p| {
        if (!lists.contains(out.items, p)) try out.append(a, p);
    }
    return out.items;
}

test "a mkinitcpio drop-in waits for a reboot, written or removed" {
    try std.testing.expectEqualStrings("initramfs", fileReboot("/etc/mkinitcpio.conf.d/50-local.conf").?);
    try std.testing.expectEqual(null, fileReboot("/etc/mkinitcpio.conf.dx/a.conf"));
    try std.testing.expectEqual(null, fileReboot("/etc/motd"));
}
