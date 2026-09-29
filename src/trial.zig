//! a generation on trial: the next boot tries it once, the default stays
//! on the generation before, and `os health` ends the trial one way or the
//! other. grub reads these choices from an env file on the esp, since it
//! can write fat but not btrfs. limine reads them from efi variables,
//! which bootctl sets, and os keeps the trial itself in /var. refind has
//! no one-shot boot, so a generation that won't start is picked from its
//! menu by hand.

const std = @import("std");
const exec = @import("exec.zig");
const rootfs = @import("rootfs.zig");
const generation = @import("generation.zig");
const facts = @import("facts.zig");
const menu = @import("menu.zig");
const Allocator = std.mem.Allocator;

pub const Trial = struct {
    /// the generation on trial.
    n: u32,
    /// the generation a failed trial falls back to, or 0.
    fallback: u32,
    /// the boot that tries it has started.
    tried: bool,
};

/// where a machine keeps its trial.
pub const Store = struct {
    a: Allocator,
    io: std.Io,
    loader: menu.Loader,
    esp: []const u8,

    /// null for a machine without an esp or a bootloader os knows.
    pub fn of(a: Allocator, io: std.Io, boot: facts.Boot) ?Store {
        return .{ .a = a, .io = io, .loader = menu.Loader.of(boot) orelse return null, .esp = boot.esp orelse return null };
    }

    /// whether a generation that doesn't come up falls back on its own.
    pub fn automatic(s: Store) bool {
        return s.loader != .refind;
    }

    /// the trial waiting for its boot, or running, if there is one.
    pub fn current(s: Store) !?Trial {
        switch (s.loader) {
            .grub => {},
            .limine, .@"systemd-boot" => {
                const text = std.Io.Dir.cwd().readFileAlloc(s.io, state_path, s.a, .limited(64)) catch return null;
                var words = std.mem.tokenizeAny(u8, text, " \n");
                return .{
                    .n = std.fmt.parseInt(u32, words.next() orelse return null, 10) catch return null,
                    .fallback = std.fmt.parseInt(u32, words.next() orelse "0", 10) catch 0,
                    // the bootloader clears the one-shot variable when it
                    // reads it.
                    .tried = !rootfs.pathExists(s.io, oneshot_var),
                };
            },
            .refind => return null,
        }
        const n = try s.number("yoq_trial") orelse return null;
        return .{
            .n = n,
            .fallback = try s.number("yoq_default") orelse 0,
            .tried = try s.value("yoq_tried") != null,
        };
    }

    /// makes the next boot try the newest generation, `n`, once, and
    /// fall back to `fallback` if it doesn't come up.
    pub fn arm(s: Store, n: u32, fallback: generation.Record) !?[]const u8 {
        switch (s.loader) {
            .grub => {
                _ = try s.edit("unset", &.{"yoq_tried"});
                return s.edit("set", &.{
                    "yoq_next=head",
                    try std.fmt.allocPrint(s.a, "yoq_default=gen-{d}", .{fallback.n}),
                    try std.fmt.allocPrint(s.a, "yoq_trial={d}", .{n}),
                });
            },
            .limine, .@"systemd-boot" => {
                // the one-shot first, and the note of the trial last: a
                // fallback default or a note without a one-shot would make
                // the next boot look like a failed trial.
                const id = if (s.loader == .limine)
                    try menu.limineId(s.a, try generation.title(s.a, fallback))
                else
                    try menu.sdbootName(s.a, try std.fmt.allocPrint(s.a, "gen-{d}", .{fallback.n}));
                const why = try s.retry() orelse
                    try s.bootctl("set-default", id) orelse
                    blk: {
                        const state = try std.fmt.allocPrint(s.a, "{d} {d}\n", .{ n, fallback.n });
                        rootfs.writeAtomic(s.io, state_path, state, null) catch break :blk try std.fmt.allocPrint(s.a, "can't write {s}", .{state_path});
                        break :blk null;
                    } orelse return null;
                _ = try s.end();
                return why;
            },
            .refind => return null,
        }
    }

    /// the trial hasn't booted yet: the next boot tries it again.
    pub fn retry(s: Store) !?[]const u8 {
        return switch (s.loader) {
            .grub => s.edit("set", &.{"yoq_next=head"}),
            .limine => s.bootctl("set-oneshot", try menu.limineId(s.a, menu.limine_trial)),
            .@"systemd-boot" => s.bootctl("set-oneshot", menu.sdboot_trial),
            .refind => null,
        };
    }

    /// ends a trial, however it went: the newest generation is the
    /// default again.
    pub fn end(s: Store) !?[]const u8 {
        switch (s.loader) {
            .grub => return s.edit("unset", &.{ "yoq_default", "yoq_trial", "yoq_tried" }),
            .limine, .@"systemd-boot" => {
                // empty removes the one-shot. limine's first entry is the
                // newest generation, so it needs no default; systemd-boot
                // is pointed at it, past loader.conf's own.
                if (try s.bootctl("set-oneshot", "")) |w| return w;
                if (try s.bootctl("set-default", if (s.loader == .limine) "" else try menu.sdbootName(s.a, "head"))) |w| return w;
                std.Io.Dir.cwd().deleteFile(s.io, state_path) catch {};
                return null;
            },
            .refind => return null,
        }
    }

    fn bootctl(s: Store, verb: []const u8, id: []const u8) !?[]const u8 {
        return exec.run(s.a, s.io, &.{ "bootctl", verb, id });
    }

    /// where os keeps a trial on limine and systemd-boot: its generation,
    /// and the one before it.
    const state_path = "/var/lib/yoq/trial";
    /// the variable limine boots once from, under the boot loader
    /// interface's vendor guid.
    const oneshot_var = "/sys/firmware/efi/efivars/LoaderEntryOneShot-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f";

    /// the env file on the esp that grub reads the menu's choices from.
    fn envPath(s: Store) ![]const u8 {
        return std.fs.path.join(s.a, &.{ s.esp, generation.grubenv });
    }

    /// a generation number from the env file: "12", or "gen-12".
    fn number(s: Store, name: []const u8) !?u32 {
        const v = try s.value(name) orelse return null;
        const digits = if (std.mem.startsWith(u8, v, "gen-")) v["gen-".len..] else v;
        return std.fmt.parseInt(u32, digits, 10) catch null;
    }

    fn value(s: Store, name: []const u8) !?[]const u8 {
        const text = switch (try exec.output(s.a, s.io, &.{ "grub-editenv", try s.envPath(), "list" })) {
            .ok => |t| t,
            .failed => return null,
        };
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            if (std.mem.eql(u8, line[0..eq], name) and eq + 1 < line.len) return line[eq + 1 ..];
        }
        return null;
    }

    /// sets `name=value` pairs, or with "unset", removes names.
    fn edit(s: Store, verb: []const u8, args: []const []const u8) !?[]const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(s.a, &.{ "grub-editenv", try s.envPath(), verb });
        try argv.appendSlice(s.a, args);
        return exec.run(s.a, s.io, argv.items);
    }
};
