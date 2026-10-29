const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Single source of truth for the version: build.zig.zon.
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const exe = b.addExecutable(.{
        .name = "zog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);

    b.installArtifact(exe);

    const test_step = b.step("test", "Run unit tests");

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("build_options", options);

    const run_tests = b.addRunArtifact(tests);

    test_step.dependOn(&run_tests.step);
}
