const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    options.addOption(bool, "update_golden", b.option(bool, "update-golden", "rewrite golden test outputs") orelse false);
    const alpm = b.option(bool, "alpm", "link libalpm for reading and resolving arch packages") orelse false;
    options.addOption(bool, "alpm", alpm);
    const systemd = b.option(bool, "systemd", "link libsystemd for reading unit state") orelse false;
    options.addOption(bool, "systemd", systemd);
    root.addOptions("build_options", options);
    // `yos docs` prints these, as they were when this yos was built.
    for ([_][]const u8{ "README.md", "docs/usage.md", "docs/generations.md" }) |doc| {
        root.addAnonymousImport(doc, .{ .root_source_file = b.path(doc) });
    }
    if (alpm) {
        root.link_libc = true;
        root.linkSystemLibrary("alpm", .{ .use_pkg_config = .no });
    }
    if (systemd) {
        root.link_libc = true;
        // not through pkg-config: arch's systemd.pc is systemd's own,
        // with no library in it.
        root.linkSystemLibrary("systemd", .{ .use_pkg_config = .no });
    }

    const exe = b.addExecutable(.{ .name = "yos", .root_module = root });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "run yos").dependOn(&run.step);

    // `zig build test -Dfuzz --fuzz=<n> -Dtest-filter="fuzz toml"` runs one
    // fuzz test from src/fuzz.zig for n inputs; plain `--fuzz` runs until
    // stopped.
    const filters: []const []const u8 = if (b.option([]const u8, "test-filter", "only run tests whose name has this in it")) |f| &.{f} else &.{};
    const fuzz = b.option(bool, "fuzz", "build tests with a test runner that works under --fuzz") orelse false;
    const tests = b.addTest(.{
        .root_module = root,
        .filters = filters,
        .test_runner = if (fuzz) .{ .path = fuzzRunner(b), .mode = .server } else null,
        // coverage for the fuzzer comes from llvm.
        .use_llvm = if (fuzz) true else null,
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));
    b.step("test", "run unit and golden tests").dependOn(&run_tests.step);

    const fmt = b.addFmt(.{ .paths = &.{ "build.zig", "build.zig.zon", "src" }, .check = true });
    b.step("fmt", "check formatting").dependOn(&fmt.step);
}

/// zig 0.16.0's own test runner doesn't compile with -ffuzz: it hands an
/// error return trace to `writeStackTrace`. this is a copy with that call
/// fixed.
fn fuzzRunner(b: *std.Build) std.Build.LazyPath {
    const lib = b.graph.zig_lib_directory;
    const stock = lib.handle.readFileAlloc(b.graph.io, "compiler/test_runner.zig", b.allocator, .unlimited) catch |e|
        std.debug.panic("can't read zig's test runner: {t}", .{e});
    const fixed = std.mem.replaceOwned(u8, b.allocator, stock, "std.debug.writeStackTrace(trace,", "std.debug.writeErrorReturnTrace(trace,") catch @panic("OOM");
    return b.addWriteFiles().add("test_runner.zig", fixed);
}
