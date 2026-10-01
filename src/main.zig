const std = @import("std");
const cli = @import("cli.zig");
const alpm = @import("alpm.zig");
const aur = @import("aur.zig");
const disk = @import("disk.zig");
const sync = @import("sync.zig");
const history = @import("history.zig");
const secrets = @import("secrets.zig");

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
    const err_tty = std.Io.File.stderr().isTty(init.io) catch false;

    var disk_files: disk.Files = .{ .io = init.io };
    var git: history.Git = .{ .io = init.io };
    var http: sync.HttpFetcher = .init(init.gpa, init.io);
    var secret_store: secrets.System = .{ .io = init.io };
    defer http.deinit();
    const env = init.environ_map;
    var ctx: cli.Context = .{
        .gpa = init.gpa,
        .io = init.io,
        .out = &out.interface,
        .err = &err.interface,
        .config_path = try hostConfig(init.arena.allocator(), init.io),
        .fetcher = http.fetcher(),
        .history = git.history(),
        .files = disk_files.files(),
        .in = &in.interface,
        .interactive = tty,
        .in_own_transaction = env.get(alpm.own_env) != null,
        .aur_url = env.get("YOQ_AUR") orelse aur.default_url,
        .editor = env.get("VISUAL") orelse env.get("EDITOR") orelse "vi",
        .progress = if (err_tty) .terminal else .log,
        .secrets = secret_store.store(),
        .set_echo = setEcho,
    };
    const code = cli.run(&ctx, argv[1..]) catch |e| blk: {
        err.interface.print("os: {s}\n", .{@errorName(e)}) catch {};
        break :blk 1;
    };

    out.interface.flush() catch {};
    err.interface.flush() catch {};
    std.process.exit(code);
}

/// turns the terminal's echo on stdin off or on again.
fn setEcho(on: bool) void {
    const linux = std.os.linux;
    var t: linux.termios = undefined;
    if (linux.errno(linux.tcgetattr(0, &t)) != .SUCCESS) return;
    t.lflag.ECHO = on;
    _ = linux.tcsetattr(0, .NOW, &t);
}

/// the config this machine reads unless --config says otherwise:
/// /etc/yoq/machine.toml, or in a repository for several machines, the one
/// under hosts/ named for this machine's hostname.
fn hostConfig(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    if (cwd.access(io, cli.default_config, .{})) |_| return cli.default_config else |_| {}
    const name = cwd.readFileAlloc(io, "/etc/hostname", a, .limited(256)) catch return cli.default_config;
    const path = try cli.hostConfigPath(a, std.mem.trim(u8, name, " \n"));
    cwd.access(io, path, .{}) catch return cli.default_config;
    return path;
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
    _ = secrets;
    _ = aur;
    _ = @import("exec.zig");
    _ = @import("news.zig");
    _ = @import("journal.zig");
    _ = @import("drift.zig");
    _ = @import("events.zig");
    _ = @import("btrfs.zig");
    _ = @import("enable.zig");
    _ = @import("generation.zig");
    _ = @import("menu.zig");
    _ = @import("uki.zig");
    _ = @import("trial.zig");
    _ = @import("uninstall.zig");
    _ = @import("install.zig");
    _ = @import("accounts.zig");
    _ = @import("newconfig.zig");
    _ = @import("gens.zig");
    _ = @import("planner.zig");
    _ = @import("pipeline.zig");
    _ = @import("golden.zig");
    _ = @import("fuzz.zig");
    _ = @import("props.zig");
    _ = @import("lists.zig");
    _ = @import("progress.zig");
    _ = @import("why.zig");
    _ = @import("schema.zig");
    _ = @import("edit.zig");
    _ = @import("change.zig");
    _ = alpm;
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
