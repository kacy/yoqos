//! `os docs`: the whole reference as one markdown document, the one that
//! came with this os, so it matches what's installed.

const cli = @import("../cli.zig");
const Context = cli.Context;

const parts = [_][]const u8{
    @embedFile("README.md"),
    @embedFile("docs/usage.md"),
    @embedFile("docs/generations.md"),
};

pub fn docsCmd(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (try cli.noArgs(ctx, args, "os docs")) |code| return code;
    for (parts, 0..) |p, i| {
        if (i > 0) try ctx.out.writeAll("\n");
        try ctx.out.writeAll(p);
    }
    return 0;
}
