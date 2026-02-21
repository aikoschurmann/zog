const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zog", 
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);


    const test_step = b.step("test", "Run unit tests");

    const scanner_tests = b.addTest(.{
        .root_source_file = b.path("src/Scanner.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_scanner_tests = b.addRunArtifact(scanner_tests);

    test_step.dependOn(&run_scanner_tests.step);
}