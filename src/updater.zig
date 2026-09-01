const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Store = @import("store.zig").Store;
const posix_updater = @import("updater_posix.zig");

const windows_update_script = @embedFile("windows_update.ps1");

/// Updates both toolchain channels using the implementation specialized for
/// the host operating system.
pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    store: Store,
    environ_map: *const std.process.Environ.Map,
) !void {
    switch (builtin.os.tag) {
        .windows => return runWindows(allocator, io, store, environ_map),
        .linux => return posix_updater.run(allocator, io, store, environ_map),
        else => return error.UnsupportedPlatform,
    }
}

fn runWindows(
    allocator: std.mem.Allocator,
    io: Io,
    store: Store,
    environ_map: *const std.process.Environ.Map,
) !void {
    _ = environ_map;
    try store.ensure();
    var random_bytes: [16]u8 = undefined;
    try io.randomSecure(&random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);
    const script_name = try std.fmt.allocPrint(allocator, "windows-update-{s}.ps1", .{suffix[0..]});
    const script_path = try std.fs.path.join(allocator, &.{ store.root, script_name });
    defer Io.Dir.cwd().deleteFile(io, script_path) catch {};
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = script_path,
        .data = windows_update_script,
        .flags = .{ .exclusive = true },
    });

    const executable_path = try std.process.executablePathAlloc(io, allocator);
    const argv = [_][]const u8{
        "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        script_path,
        "-ZigupHome",
        store.root,
        "-ZigupExe",
        executable_path,
    };

    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    if (!term.success()) return error.UpdateFailed;
}

test "embedded Windows updater uses the official release index" {
    try std.testing.expect(std.mem.indexOf(
        u8,
        windows_update_script,
        "https://ziglang.org/download/index.json",
    ) != null);
}

test "embedded Windows updater provisions stable and dev commands" {
    try std.testing.expect(std.mem.indexOf(u8, windows_update_script, "zig-dev.cmd") != null);
    try std.testing.expect(std.mem.indexOf(u8, windows_update_script, "current-dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, windows_update_script, "New-Item -ItemType Junction") != null);
    try std.testing.expect(std.mem.indexOf(u8, windows_update_script, "Test-DedicatedZigDirectory") != null);
    try std.testing.expect(std.mem.indexOf(u8, windows_update_script, "Test-PathContainsDirectory") != null);
    try std.testing.expect(std.mem.indexOf(u8, windows_update_script, "store.lock") != null);
}
