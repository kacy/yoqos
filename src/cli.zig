//! command dispatch. `run` takes its writers and args from the caller so
//! tests can drive it without a terminal.

const std = @import("std");
const build_options = @import("build_options");

pub const Context = struct {
    out: *std.Io.Writer,
    err: *std.Io.Writer,
};

const Handler = *const fn (ctx: *Context, args: []const [:0]const u8) anyerror!u8;

const Command = struct {
    name: []const u8,
    summary: []const u8,
    handler: Handler,
};

const commands = [_]Command{
    .{ .name = "help", .summary = "show this help", .handler = help },
    .{ .name = "version", .summary = "print the version", .handler = version },
};

/// runs one command line (without the program name) and returns the exit
/// code: 0 ok, 1 failed, 2 bad usage.
pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (args.len == 0) return help(ctx, args);

    const name = args[0];
    if (std.mem.eql(u8, name, "-h") or std.mem.eql(u8, name, "--help")) return help(ctx, args[1..]);
    if (std.mem.eql(u8, name, "--version")) return version(ctx, args[1..]);

    for (commands) |c| {
        if (std.mem.eql(u8, c.name, name)) return c.handler(ctx, args[1..]);
    }

    try ctx.err.print("os: unknown command '{s}'\n\n", .{name});
    try usage(ctx.err);
    return 2;
}

fn usage(w: *std.Io.Writer) !void {
    try w.writeAll("usage: os <command> [args]\n\ncommands:\n");
    for (commands) |c| try w.print("  {s:<10}{s}\n", .{ c.name, c.summary });
}

fn help(ctx: *Context, _: []const [:0]const u8) !u8 {
    try usage(ctx.out);
    return 0;
}

fn version(ctx: *Context, _: []const [:0]const u8) !u8 {
    try ctx.out.print("os {s}\n", .{build_options.version});
    return 0;
}

const TestRun = struct {
    out_buf: [1024]u8 = undefined,
    err_buf: [1024]u8 = undefined,
    out: std.Io.Writer = undefined,
    err: std.Io.Writer = undefined,
    code: u8 = 0,

    fn exec(t: *TestRun, args: []const [:0]const u8) !void {
        t.out = .fixed(&t.out_buf);
        t.err = .fixed(&t.err_buf);
        var ctx: Context = .{ .out = &t.out, .err = &t.err };
        t.code = try run(&ctx, args);
    }
};

test "no args prints usage" {
    var t: TestRun = .{};
    try t.exec(&.{});
    try std.testing.expectEqual(0, t.code);
    try std.testing.expect(std.mem.startsWith(u8, t.out.buffered(), "usage: os"));
}

test "version prints the build version" {
    var t: TestRun = .{};
    try t.exec(&.{"version"});
    try std.testing.expectEqualStrings("os " ++ build_options.version ++ "\n", t.out.buffered());

    try t.exec(&.{"--version"});
    try std.testing.expectEqualStrings("os " ++ build_options.version ++ "\n", t.out.buffered());
}

test "unknown command is a usage error" {
    var t: TestRun = .{};
    try t.exec(&.{"frobnicate"});
    try std.testing.expectEqual(2, t.code);
    try std.testing.expect(std.mem.startsWith(u8, t.err.buffered(), "os: unknown command 'frobnicate'"));
    try std.testing.expectEqual(0, t.out.buffered().len);
}
