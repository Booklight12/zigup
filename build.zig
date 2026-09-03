const std = @import("std");
const builtin = @import("builtin");

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
    const proxy_module = b.createModule(.{
        .root_source_file = b.path("src/proxy_posix.zig"),
        .target = target,
        .optimize = optimize,
    });
    const proxy_tests = b.addRunArtifact(b.addTest(.{ .root_module = proxy_module }));
    const test_step = b.step("test", "Run zigup tests");
    test_step.dependOn(&main_tests.step);
    test_step.dependOn(&store_tests.step);
    test_step.dependOn(&updater_tests.step);
    test_step.dependOn(&posix_updater_tests.step);
    test_step.dependOn(&proxy_tests.step);

    if (builtin.os.tag == .windows) {
        const windows_proxy_tests = b.addSystemCommand(&.{
            "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
        });
        windows_proxy_tests.addFileArg(b.path("tests/windows_proxy.Tests.ps1"));
        test_step.dependOn(&windows_proxy_tests.step);
    }

    // Optional test tooling is not part of the installed zigup distribution.
    const proxy_driver = b.addExecutable(.{
        .name = "zigup-proxy-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/proxy_download_driver.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "proxy", .module = proxy_module }},
        }),
    });
    const install_proxy_driver = b.addInstallArtifact(proxy_driver, .{});
    b.step("proxy-test-driver", "Build the Linux proxy integration-test driver").dependOn(&install_proxy_driver.step);

    const integration = b.addSystemCommand(if (builtin.os.tag == .windows) &.{ "py", "-3" } else &.{"python3"});
    integration.addFileArg(b.path("tests/proxy_integration.py"));
    if (builtin.os.tag == .windows) {
        integration.addArg("--windows");
    } else {
        integration.addArg("--driver");
        integration.addArtifactArg(proxy_driver);
    }
    b.step("test-proxy", "Run offline loopback proxy integration tests (requires Python 3)").dependOn(&integration.step);
}
