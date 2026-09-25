const std = @import("std");
const cli = @import("cli.zig");
const disk = @import("disk.zig");

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    const stdout = std.Io.File.stdout();
    var out = stdout.writer(init.io, &out_buf);
    var err = std.Io.File.stderr().writer(init.io, &err_buf);

    var disk_files: disk.Files = .{ .io = init.io };
    var ctx: cli.Context = .{
        .io = init.io,
        .files = disk_files.files(),
        .gpa = init.gpa,
        .out = &out.interface,
        .err = &err.interface,
        .color = (stdout.isTty(init.io) catch false) and init.environ_map.get("NO_COLOR") == null,
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
    _ = @import("planner.zig");
    _ = @import("pipeline.zig");
    _ = @import("golden.zig");
    _ = @import("sort.zig");
    _ = @import("why.zig");
    _ = @import("edit.zig");
    _ = @import("change.zig");
    _ = @import("alpm.zig");
    _ = @import("observe.zig");
    _ = disk;
}
