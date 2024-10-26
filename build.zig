const std = @import("std");
const Build = std.Build;
const Step = Build.Step;

const Options = struct {
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn build(b: *Build) void {
    const options: Options = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    };

    const asphyxiaz_module: *Build.Module = b.dependency("asphyxiaz", options).module("asphyxiaz");

    const activez_module: *Build.Module = b.addModule("activez", .{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "asphyxiaz", .module = asphyxiaz_module },
        },
        .target = options.target,
        .optimize = options.optimize,
    });

    // activez tests
    const activez_tests: *Step.Compile = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });

    const activez_tests_cmd: *Step.Run = b.addRunArtifact(activez_tests);

    const test_step: *Step = b.step("test", "Run unit tests");
    test_step.dependOn(&activez_tests_cmd.step);

    // cat example
    const cat: *Step.Compile = b.addExecutable(.{
        .name = "cat",
        .root_source_file = b.path("examples/001-cat.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });

    cat.root_module.addImport("activez", activez_module);
    cat.use_lld = false;

    b.installArtifact(cat);

    const cat_cmd: *Step.Run = b.addRunArtifact(cat);

    cat_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        cat_cmd.addArgs(args);
    }

    const cat_step = b.step("cat", "Run the cat example");
    cat_step.dependOn(&cat_cmd.step);

    // benchmark example
    const benchmark: *Step.Compile = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = b.path("examples/002-benchmark.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });

    benchmark.root_module.addImport("activez", activez_module);
    benchmark.use_lld = false;

    b.installArtifact(benchmark);

    const benchmark_cmd: *Step.Run = b.addRunArtifact(benchmark);

    benchmark_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        benchmark_cmd.addArgs(args);
    }

    const benchmark_step = b.step("benchmark", "Run the benchmark example");
    benchmark_step.dependOn(&benchmark_cmd.step);
}
