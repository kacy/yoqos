const std = @import("std");
const cli = @import("cli.zig");
const disk = @import("disk.zig");
const sync = @import("sync.zig");
const history = @import("history.zig");

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    const stdout = std.Io.File.stdout();
    var out = stdout.writer(init.io, &out_buf);
    var err = std.Io.File.stderr().writer(init.io, &err_buf);
    var in_buf: [1024]u8 = undefined;
    const stdin = std.Io.File.stdin();
    var in = stdin.reader(init.io, &in_buf);
    const tty = (stdout.isTty(init.io) catch false) and (stdin.isTty(init.io) catch false);

    var disk_files: disk.Files = .{ .io = init.io };
    var git: history.Git = .{ .io = init.io };
    var http: sync.HttpFetcher = .init(init.gpa, init.io);
    defer http.deinit();
    var ctx: cli.Context = .{
        .io = init.io,
        .files = disk_files.files(),
        .fetcher = http.fetcher(),
        .history = git.history(),
        .in = &in.interface,
        .interactive = tty,
        .gpa = init.gpa,
        .out = &out.interface,
        .err = &err.interface,
    };
    const code = cli.run(&ctx, argv[1..]) catch |e| blk: {
        err.interface.print("os: {s}\n", .{@errorName(e)}) catch {};
        break :blk 1;
    };

    out.interface.flush() catch {};
    err.interface.flush() catch {};
    std.process.exit(code);
}

test {
    _ = cli;
    _ = @import("output.zig");
    _ = @import("diag.zig");
    _ = @import("toml.zig");
    _ = @import("catalog.zig");
    _ = @import("config.zig");
    _ = @import("compose.zig");
    _ = @import("show.zig");
    _ = @import("facts.zig");
    _ = @import("lock.zig");
    _ = @import("users.zig");
    _ = @import("rootfs.zig");
    _ = @import("exec.zig");
    _ = @import("news.zig");
    _ = @import("planner.zig");
    _ = @import("pipeline.zig");
    _ = @import("golden.zig");
    _ = @import("lists.zig");
    _ = @import("why.zig");
    _ = @import("edit.zig");
    _ = @import("change.zig");
    _ = @import("alpm.zig");
    _ = @import("observe.zig");
    _ = @import("sync.zig");
    _ = @import("systemd.zig");
    _ = @import("status.zig");
    _ = @import("history.zig");
    _ = @import("generate.zig");
    _ = @import("settings.zig");
    _ = @import("apply.zig");
    _ = disk;
}
