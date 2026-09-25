//! `add`, `remove`, `enable`, and `disable`: change the config file for
//! the user. change.zig works out and checks the edit; this prints it.

const std = @import("std");
const cli = @import("../cli.zig");
const change = @import("../change.zig");
const output = @import("../output.zig");
const Context = cli.Context;

pub fn addCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    return run(ctx, args, .add);
}

pub fn removeCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    return run(ctx, args, .remove);
}

pub fn enableCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    return run(ctx, args, .enable);
}

pub fn disableCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    return run(ctx, args, .disable);
}

fn run(ctx: *Context, args: []const [:0]const u8, op: change.Op) !u8 {
    if (args.len == 0) {
        try ctx.err.print("usage: os {s} <{s}>...\n", .{ @tagName(op), if (op == .add or op == .remove) "package" else "service" });
        return 2;
    }
    for (args) |a| {
        if (a[0] == '-') {
            try ctx.err.print("os: unknown flag '{s}'\n", .{a});
            return 2;
        }
    }

    var w: cli.Work = .init(ctx);
    defer w.deinit();
    const a = w.allocator();
    const loaded = try w.config() orelse return w.report();
    const top = loaded.files.items[0];
    const text = ctx.files.read(a, top) catch {
        try ctx.err.print("os: can't read {s}\n", .{top});
        return 1;
    };

    const names = try a.alloc([]const u8, args.len);
    for (args, names) |arg, *n| n.* = arg;
    const outcome = try change.plan(a, &loaded.config, top, text, op, names, &w.diags);
    if (w.failed()) return w.report();
    if (outcome.changed()) {
        if (!try change.check(ctx.gpa, ctx.files, top, outcome.text, op, outcome.notes, &w.diags)) return w.report();
        ctx.files.write(top, outcome.text) catch {
            try ctx.err.print("os: can't write {s}\n", .{top});
            return 1;
        };
    }

    if (ctx.json) {
        try output.writeDoc(ctx.out, "yoq.change/1", .{ .file = top, .changed = outcome.changed(), .notes = outcome.notes });
        return 0;
    }
    for (outcome.notes) |n| {
        switch (n.what) {
            .added => try ctx.out.print("+ packages \"{s}\"\n", .{n.name}),
            .removed => try ctx.out.print("- packages \"{s}\"\n", .{n.name}),
            .excluded => try ctx.out.print("+ remove.packages \"{s}\"  (set in {s})\n", .{ n.name, n.detail.? }),
            .enabled, .disabled => try ctx.out.print("~ services.{s} = {}\n", .{ n.name, n.what == .enabled }),
            .unchanged => try ctx.out.print("  {s} is already set that way  ({s})\n", .{ n.name, n.detail.? }),
        }
    }
    if (outcome.changed()) {
        try ctx.out.print("\nsaved {s}. applying isn't built yet; `os plan` shows what would change.\n", .{top});
    }
    return 0;
}

// -- tests --

const TestRun = cli.TestRun;

test "add, remove, enable, and disable edit the config file" {
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/base.toml", "packages = [\"nano\", \"git\"]\n");
    try t.fs.put("/etc/yoq/machine.toml",
        \\# my laptop
        \\include = ["base.toml"]
        \\packages = ["git", "neovim"]  # editors
        \\
        \\[services]
        \\ssh = true
        \\
    );
    try t.exec(&.{ "add", "ripgrep", "neovim" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expect(std.mem.startsWith(u8, t.out.buffered(), "+ packages \"ripgrep\"\n  neovim is already set that way  (/etc/yoq/machine.toml:3)\n"));

    try t.exec(&.{ "remove", "nano", "git" });
    try std.testing.expectEqual(0, t.code);
    try t.exec(&.{ "enable", "tailscale" });
    try t.exec(&.{ "disable", "ssh" });
    try std.testing.expectEqual(0, t.code);
    try std.testing.expectEqualStrings(
        \\# my laptop
        \\include = ["base.toml"]
        \\packages = ["neovim", "ripgrep"]  # editors
        \\
        \\[services]
        \\ssh = false
        \\tailscale = true
        \\
        \\[remove]
        \\packages = ["nano", "git"]
        \\
    , t.fs.get("/etc/yoq/machine.toml").?);
}

test "change refuses what it can't do" {
    var t: TestRun = .{};
    defer t.deinit();
    try t.fs.put("/etc/yoq/machine.toml", "packages = [\"git\"]\n[services]\nssh = true\n");
    try t.exec(&.{ "remove", "openssh" });
    try std.testing.expectEqual(1, t.code);
    try std.testing.expect(std.mem.indexOf(u8, t.err.buffered(), "openssh comes from services.ssh") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.err.buffered(), "run `os disable ssh`") != null);

    try t.exec(&.{ "remove", "vim" });
    try std.testing.expectEqual(1, t.code);
    try t.exec(&.{ "enable", "sshd" });
    try std.testing.expectEqual(1, t.code);
    try std.testing.expect(std.mem.indexOf(u8, t.err.buffered(), "did you mean \"ssh\"?") != null);
    try t.exec(&.{"add"});
    try std.testing.expectEqual(2, t.code);
    try std.testing.expectEqualStrings("packages = [\"git\"]\n[services]\nssh = true\n", t.fs.get("/etc/yoq/machine.toml").?);
}
