const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const executable = b.addExecutable(.{
        .name = "zigup",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(executable);

    const run_command = b.addRunArtifact(executable);
    run_command.step.dependOn(b.getInstallStep());
    run_command.addPassthruArgs();
    b.step("run", "Run zigup").dependOn(&run_command.step);

    const store_tests = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/store.zig"),
            .target = target,
            .optimize = optimize,
        }),
    }));
    const main_tests = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    }));
    const updater_tests = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/updater.zig"),
            .target = target,
            .optimize = optimize,
        }),
    }));
    const posix_updater_tests = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/updater_posix.zig"),
            .target = target,
            .optimize = optimize,
        }),
    }));
    const test_step = b.step("test", "Run zigup tests");
    test_step.dependOn(&main_tests.step);
    test_step.dependOn(&store_tests.step);
    test_step.dependOn(&updater_tests.step);
    test_step.dependOn(&posix_updater_tests.step);
}
