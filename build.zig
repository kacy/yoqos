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
    root.addOptions("build_options", options);

    const exe = b.addExecutable(.{ .name = "os", .root_module = root });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "run os").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = root });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));
    b.step("test", "run unit and golden tests").dependOn(&run_tests.step);

    const fmt = b.addFmt(.{ .paths = &.{ "build.zig", "build.zig.zon", "src" }, .check = true });
    b.step("fmt", "check formatting").dependOn(&fmt.step);
}
