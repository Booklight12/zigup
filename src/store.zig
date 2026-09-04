const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Store = struct {
    allocator: Allocator,
    io: Io,
    root: []const u8,
    versions_dir: []const u8,
    bin_dir: []const u8,

    pub fn init(
        allocator: Allocator,
        io: Io,
        environ_map: *const std.process.Environ.Map,
    ) !Store {
        const root = try resolveRoot(allocator, io, environ_map);
        return .{
            .allocator = allocator,
            .io = io,
            .root = root,
            .versions_dir = try std.fs.path.join(allocator, &.{ root, "versions" }),
            .bin_dir = try std.fs.path.join(allocator, &.{ root, "bin" }),
        };
    }

    pub fn ensure(self: Store) !void {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(self.io, self.versions_dir);
        try cwd.createDirPath(self.io, self.bin_dir);
    }

    pub fn add(self: Store, version: []const u8, zig_executable: []const u8) ![]const u8 {
        if (!isValidVersion(version)) return error.InvalidVersion;
        try self.ensure();

        const absolute = try std.fs.path.resolve(self.allocator, &.{zig_executable});
        const stat = try Io.Dir.cwd().statFile(self.io, absolute, .{});
        try validateExecutable(stat);

        var mutation_lock = try self.acquireMutationLock();
        defer mutation_lock.close(self.io);
        const registration = try self.registrationPath(version);
        try self.replaceFile(registration, absolute, .default_file);
        try self.clearIncomplete(version);
        return absolute;
    }

    pub fn resolve(self: Store, version: []const u8) ![]const u8 {
        const executable = try self.readRegistration(version);
        const stat = try Io.Dir.cwd().statFile(self.io, executable, .{});
        try validateExecutable(stat);
        return executable;
    }

    fn readRegistration(self: Store, version: []const u8) ![]const u8 {
        if (!isValidVersion(version)) return error.InvalidVersion;
        const registration = try self.registrationPath(version);
        const bytes = Io.Dir.cwd().readFileAlloc(
            self.io,
            registration,
            self.allocator,
            .limited(64 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => return error.VersionNotFound,
            else => return err,
        };
        const executable = std.mem.trim(u8, bytes, "\r\n");
        if (executable.len == 0 or !std.fs.path.isAbsolute(executable)) {
            return error.InvalidRegistration;
        }
        return executable;
    }

    pub fn use(self: Store, version: []const u8) ![]const u8 {
        try self.ensure();
        var mutation_lock = try self.acquireMutationLock();
        defer mutation_lock.close(self.io);
        const executable = try self.resolve(version);
        try self.writeShim("zig", executable);
        try self.writeCurrentFile("current", version);
        return executable;
    }

    pub fn useDev(self: Store, version: []const u8) ![]const u8 {
        try self.ensure();
        var mutation_lock = try self.acquireMutationLock();
        defer mutation_lock.close(self.io);
        const executable = try self.resolve(version);
        try self.writeShim("zig-dev", executable);
        try self.writeCurrentFile("current-dev", version);
        return executable;
    }

    fn writeCurrentFile(self: Store, file_name: []const u8, version: []const u8) !void {
        const current_path = try std.fs.path.join(self.allocator, &.{ self.root, file_name });
        try self.replaceFile(current_path, version, .default_file);
    }

    pub fn current(self: Store) !?[]const u8 {
        return self.readCurrentFile("current");
    }

    pub fn currentDev(self: Store) !?[]const u8 {
        return self.readCurrentFile("current-dev");
    }

    fn readCurrentFile(self: Store, file_name: []const u8) !?[]const u8 {
        const current_path = try std.fs.path.join(self.allocator, &.{ self.root, file_name });
        const bytes = Io.Dir.cwd().readFileAlloc(
            self.io,
            current_path,
            self.allocator,
            .limited(4096),
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        const version = std.mem.trim(u8, bytes, " \r\n\t");
        if (version.len == 0) return null;
        if (!isValidVersion(version)) return error.InvalidRegistration;
        return version;
    }

    pub const RemoveResult = struct {
        cleared_stable: bool,
        cleared_dev: bool,
        deleted_managed_toolchain: bool,
        terminated_processes: usize,
    };

    pub const RemoveOptions = struct {
        force: bool = false,
    };

    pub fn remove(self: Store, version: []const u8, options: RemoveOptions) !RemoveResult {
        if (!isValidVersion(version)) return error.InvalidVersion;
        try self.ensure();
        var mutation_lock = try self.acquireMutationLock();
        defer mutation_lock.close(self.io);

        const executable = try self.readRegistration(version);
        const registration = try self.registrationPath(version);
        try self.markIncomplete(version);

        return self.removeMarked(version, executable, registration, options) catch |err| {
            // The marker is created before any destructive action. Recreate it
            // if a later cleanup step removed it before another step failed.
            self.markIncomplete(version) catch {};
            return err;
        };
    }

    fn removeMarked(
        self: Store,
        version: []const u8,
        executable: []const u8,
        registration: []const u8,
        options: RemoveOptions,
    ) !RemoveResult {
        var result: RemoveResult = .{
            .cleared_stable = false,
            .cleared_dev = false,
            .deleted_managed_toolchain = false,
            .terminated_processes = 0,
        };
        const clear_stable = if (try self.current()) |active| versionEqual(active, version) else false;
        const clear_dev = if (try self.currentDev()) |active| versionEqual(active, version) else false;

        if (try self.managedToolchainPath(version, executable)) |toolchain_path| {
            try self.removeManagedToolchain(toolchain_path, executable, options, &result);
            result.deleted_managed_toolchain = true;
        }

        if (clear_stable) {
            try self.clearSelection("current", "zig");
            result.cleared_stable = true;
        }
        if (clear_dev) {
            try self.clearSelection("current-dev", "zig-dev");
            result.cleared_dev = true;
        }
        try self.clearIncomplete(version);
        Io.Dir.cwd().deleteFile(self.io, registration) catch |err| switch (err) {
            error.FileNotFound => return error.VersionNotFound,
            else => return err,
        };
        return result;
    }

    pub fn isIncomplete(self: Store, version: []const u8) !bool {
        if (!isValidVersion(version)) return error.InvalidVersion;
        const path = try self.incompletePath(version);
        _ = Io.Dir.cwd().statFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    fn markIncomplete(self: Store, version: []const u8) !void {
        const path = try self.incompletePath(version);
        try self.replaceFile(path, "remove incomplete\n", .default_file);
    }

    fn clearIncomplete(self: Store, version: []const u8) !void {
        try deleteFileIfExists(self.io, try self.incompletePath(version));
    }

    fn incompletePath(self: Store, version: []const u8) ![]const u8 {
        const file_name = try std.fmt.allocPrint(self.allocator, "{s}.incomplete", .{version});
        return std.fs.path.join(self.allocator, &.{ self.versions_dir, file_name });
    }

    fn managedToolchainPath(self: Store, version: []const u8, executable: []const u8) !?[]const u8 {
        const toolchain_path = try std.fs.path.join(self.allocator, &.{ self.root, "toolchains", version });
        const executable_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";
        const expected_executable = try std.fs.path.join(self.allocator, &.{ toolchain_path, executable_name });
        if (!pathEqual(executable, expected_executable)) return null;
        return toolchain_path;
    }

    fn removeManagedToolchain(
        self: Store,
        toolchain_path: []const u8,
        executable: []const u8,
        options: RemoveOptions,
        result: *RemoveResult,
    ) !void {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            if (builtin.os.tag == .windows) {
                const process_result = try @import("process_windows.zig").ensureIdle(
                    self.allocator,
                    executable,
                    options.force,
                );
                result.terminated_processes += process_result.terminated;
            }
            self.deleteManagedToolchain(toolchain_path, executable) catch |err| switch (err) {
                // A new process can start between inspection and unlink. Force
                // mode gets bounded retries so it can stop that race winner.
                error.ToolchainInUse => if (options.force and attempt < 3) continue else return err,
                else => return err,
            };
            return;
        }
    }

    fn deleteManagedToolchain(self: Store, toolchain_path: []const u8, executable: []const u8) !void {
        const cwd = Io.Dir.cwd();
        const toolchain_stat = cwd.statFile(self.io, toolchain_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };

        // On Windows a running executable cannot be unlinked. Try it before
        // walking the directory so an in-use toolchain is left intact rather
        // than being partially deleted before deleteTree reaches zig.exe.
        if (toolchain_stat.kind == .directory) {
            cwd.deleteFile(self.io, executable) catch |err| switch (err) {
                error.FileNotFound => {},
                error.AccessDenied, error.PermissionDenied, error.FileBusy => return error.ToolchainInUse,
                else => return err,
            };
        }
        try cwd.deleteTree(self.io, toolchain_path);
    }

    fn clearSelection(self: Store, current_file_name: []const u8, shim_name: []const u8) !void {
        const shim_file_name = switch (builtin.os.tag) {
            .windows => try std.fmt.allocPrint(self.allocator, "{s}.cmd", .{shim_name}),
            else => shim_name,
        };
        const shim_path = try std.fs.path.join(self.allocator, &.{ self.bin_dir, shim_file_name });
        const current_path = try std.fs.path.join(self.allocator, &.{ self.root, current_file_name });

        try deleteFileIfExists(self.io, shim_path);
        try deleteFileIfExists(self.io, current_path);
    }

    fn acquireMutationLock(self: Store) !Io.File {
        const lock_path = try std.fs.path.join(self.allocator, &.{ self.root, "store.lock" });
        return Io.Dir.cwd().createFile(self.io, lock_path, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
        });
    }

    pub fn registrationPath(self: Store, version: []const u8) ![]const u8 {
        const file_name = try std.fmt.allocPrint(self.allocator, "{s}.path", .{version});
        return std.fs.path.join(self.allocator, &.{ self.versions_dir, file_name });
    }

    fn writeShim(self: Store, name: []const u8, executable: []const u8) !void {
        const shim: struct {
            file_name: []const u8,
            contents: []const u8,
            permissions: Io.File.Permissions,
        } = switch (builtin.os.tag) {
            .windows => .{
                .file_name = try std.fmt.allocPrint(self.allocator, "{s}.cmd", .{name}),
                .contents = try std.fmt.allocPrint(
                    self.allocator,
                    "@echo off\r\nsetlocal DisableDelayedExpansion\r\n\"{s}\" %*\r\n",
                    .{try escapeCmdPercent(self.allocator, executable)},
                ),
                .permissions = .default_file,
            },
            else => .{
                .file_name = name,
                .contents = try std.fmt.allocPrint(
                    self.allocator,
                    "#!/bin/sh\nexec {s} \"$@\"\n",
                    .{try quotePosixShell(self.allocator, executable)},
                ),
                // On POSIX the shim must carry the executable bit to run; on
                // Windows this permission is a harmless no-op.
                .permissions = .executable_file,
            },
        };
        const shim_path = try std.fs.path.join(self.allocator, &.{ self.bin_dir, shim.file_name });
        try self.replaceFile(shim_path, shim.contents, shim.permissions);
    }

    fn replaceFile(
        self: Store,
        destination: []const u8,
        contents: []const u8,
        permissions: Io.File.Permissions,
    ) !void {
        var random_bytes: [16]u8 = undefined;
        try self.io.randomSecure(&random_bytes);
        const suffix = std.fmt.bytesToHex(random_bytes, .lower);
        const temporary = try std.fmt.allocPrint(
            self.allocator,
            "{s}.zigup-tmp-{s}",
            .{ destination, suffix[0..] },
        );
        errdefer Io.Dir.cwd().deleteFile(self.io, temporary) catch {};
        try Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = temporary,
            .data = contents,
            .flags = .{ .exclusive = true, .permissions = permissions },
        });
        try Io.Dir.cwd().rename(temporary, Io.Dir.cwd(), destination, self.io);
    }
};

fn deleteFileIfExists(io: Io, path: []const u8) !void {
    Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn pathEqual(lhs: []const u8, rhs: []const u8) bool {
    if (builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(lhs, rhs);
    return std.mem.eql(u8, lhs, rhs);
}

fn validateExecutable(stat: Io.File.Stat) !void {
    if (stat.kind != .file) return error.NotAFile;
    if (comptime Io.File.Permissions.has_executable_bit) {
        if (stat.permissions.toMode() & 0o111 == 0) return error.NotExecutable;
    }
}

fn escapeCmdPercent(allocator: Allocator, value: []const u8) ![]u8 {
    var percent_count: usize = 0;
    for (value) |char| {
        if (char == '%') percent_count += 1;
    }
    const escaped = try allocator.alloc(u8, value.len + percent_count);
    var index: usize = 0;
    for (value) |char| {
        escaped[index] = char;
        index += 1;
        if (char == '%') {
            escaped[index] = '%';
            index += 1;
        }
    }
    return escaped;
}

fn quotePosixShell(allocator: Allocator, value: []const u8) ![]u8 {
    var quote_count: usize = 0;
    for (value) |char| {
        if (char == '\'') quote_count += 1;
    }
    const quoted = try allocator.alloc(u8, value.len + 2 + quote_count * 3);
    var index: usize = 0;
    quoted[index] = '\'';
    index += 1;
    for (value) |char| {
        if (char == '\'') {
            for ([_]u8{ '\'', '\\', '\'', '\'' }) |escaped| {
                quoted[index] = escaped;
                index += 1;
            }
        } else {
            quoted[index] = char;
            index += 1;
        }
    }
    quoted[index] = '\'';
    return quoted;
}

pub fn isValidVersion(version: []const u8) bool {
    if (version.len == 0 or version.len > 128) return false;
    if (!std.ascii.isAlphanumeric(version[0]) or
        !std.ascii.isAlphanumeric(version[version.len - 1])) return false;
    for (version) |char| {
        if (!(std.ascii.isAlphanumeric(char) or char == '.' or char == '-' or char == '_' or char == '+')) {
            return false;
        }
    }
    const first_dot = std.mem.indexOfScalar(u8, version, '.') orelse version.len;
    if (isWindowsDeviceName(version[0..first_dot])) return false;
    return true;
}

pub fn versionEqual(lhs: []const u8, rhs: []const u8) bool {
    if (builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(lhs, rhs);
    return std.mem.eql(u8, lhs, rhs);
}

fn isWindowsDeviceName(name: []const u8) bool {
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(name, reserved)) return true;
    }
    if (name.len == 4 and name[3] >= '1' and name[3] <= '9') {
        return std.ascii.eqlIgnoreCase(name[0..3], "COM") or
            std.ascii.eqlIgnoreCase(name[0..3], "LPT");
    }
    return false;
}

fn resolveRoot(
    allocator: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
) ![]const u8 {
    if (environ_map.get("ZIGUP_HOME")) |root| {
        if (root.len == 0) return error.InvalidHome;
        return resolveAbsolutePath(allocator, io, &.{root});
    }

    if (builtin.os.tag == .windows) {
        const local_app_data = environ_map.get("LOCALAPPDATA") orelse return error.HomeNotFound;
        if (local_app_data.len == 0) return error.HomeNotFound;
        return resolveAbsolutePath(allocator, io, &.{ local_app_data, "zigup" });
    }

    if (environ_map.get("XDG_DATA_HOME")) |data_home| {
        if (data_home.len != 0 and std.fs.path.isAbsolute(data_home)) {
            return resolveAbsolutePath(allocator, io, &.{ data_home, "zigup" });
        }
    }
    const home = environ_map.get("HOME") orelse return error.HomeNotFound;
    if (home.len == 0) return error.HomeNotFound;
    return resolveAbsolutePath(allocator, io, &.{ home, ".local", "share", "zigup" });
}

fn resolveAbsolutePath(allocator: Allocator, io: Io, parts: []const []const u8) ![]const u8 {
    const joined = try std.fs.path.join(allocator, parts);
    defer allocator.free(joined);
    if (std.fs.path.isAbsolute(joined)) return std.fs.path.resolve(allocator, &.{joined});

    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buffer);
    return std.fs.path.resolve(allocator, &.{ cwd_buffer[0..cwd_len], joined });
}

test "version names accept Zig release and development identifiers" {
    try std.testing.expect(isValidVersion("0.14.1"));
    try std.testing.expect(isValidVersion("0.17.0-dev.1902+896bd9e15"));
    try std.testing.expect(isValidVersion("master_windows-x86_64"));
}

test "version names reject path traversal and empty input" {
    try std.testing.expect(!isValidVersion(""));
    try std.testing.expect(!isValidVersion("../0.14.1"));
    try std.testing.expect(!isValidVersion("0.14/zig"));
    try std.testing.expect(!isValidVersion("0.14 zig"));
    try std.testing.expect(!isValidVersion(".hidden"));
    try std.testing.expect(!isValidVersion("trailing."));
    try std.testing.expect(!isValidVersion("CON"));
    try std.testing.expect(!isValidVersion("com1.release"));
}

test "version identity follows host filesystem case semantics" {
    try std.testing.expect(versionEqual("0.16.0", "0.16.0"));
    if (builtin.os.tag == .windows) {
        try std.testing.expect(versionEqual("1.0.0-RC1", "1.0.0-rc1"));
    } else {
        try std.testing.expect(!versionEqual("1.0.0-RC1", "1.0.0-rc1"));
    }
}

test "POSIX shell quoting preserves metacharacters and apostrophes" {
    const allocator = std.testing.allocator;
    const quoted = try quotePosixShell(allocator, "/tmp/$odd/it's zig");
    defer allocator.free(quoted);
    try std.testing.expectEqualStrings("'/tmp/$odd/it'\\''s zig'", quoted);
}

test "Windows command shim escaping doubles environment expansion markers" {
    const allocator = std.testing.allocator;
    const escaped = try escapeCmdPercent(allocator, "C:\\odd%PATH%\\zig.exe");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("C:\\odd%%PATH%%\\zig.exe", escaped);
}

test "remove deletes historical registrations and safely clears active channels" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = try allocator.dupe(u8, root_buffer[0..root_len]);
    const versions_dir = try std.fs.path.join(allocator, &.{ root, "versions" });
    const bin_dir = try std.fs.path.join(allocator, &.{ root, "bin" });
    const store: Store = .{
        .allocator = allocator,
        .io = std.testing.io,
        .root = root,
        .versions_dir = versions_dir,
        .bin_dir = bin_dir,
    };

    const executable_name = if (builtin.os.tag == .windows) "test-zig.exe" else "test-zig";
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = executable_name,
        .data = "test executable",
        .flags = .{ .permissions = .executable_file },
    });
    const executable = try std.fs.path.join(allocator, &.{ root, executable_name });

    const historical = "0.14.1";
    const active = "0.17.0-dev.1978+c961124d9";
    const managed_executable_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";
    const managed_dir_relative = try std.fs.path.join(allocator, &.{ "toolchains", historical });
    const managed_executable_relative = try std.fs.path.join(allocator, &.{ managed_dir_relative, managed_executable_name });
    try tmp.dir.createDirPath(std.testing.io, managed_dir_relative);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = managed_executable_relative,
        .data = "managed test executable",
        .flags = .{ .permissions = .executable_file },
    });
    const managed_dir = try std.fs.path.join(allocator, &.{ root, managed_dir_relative });
    const managed_executable = try std.fs.path.join(allocator, &.{ root, managed_executable_relative });

    _ = try store.add(historical, managed_executable);
    _ = try store.add(active, executable);
    _ = try store.use(active);
    _ = try store.useDev(active);

    const historical_result = try store.remove(historical, .{});
    try std.testing.expect(!historical_result.cleared_stable);
    try std.testing.expect(!historical_result.cleared_dev);
    try std.testing.expect(historical_result.deleted_managed_toolchain);
    try std.testing.expectEqual(@as(usize, 0), historical_result.terminated_processes);
    try std.testing.expect(!try store.isIncomplete(historical));
    try std.testing.expectError(error.VersionNotFound, store.resolve(historical));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(std.testing.io, managed_dir, .{}));
    try std.testing.expectEqualStrings(active, (try store.current()).?);
    try std.testing.expectEqualStrings(active, (try store.currentDev()).?);

    const active_result = try store.remove(active, .{});
    try std.testing.expect(active_result.cleared_stable);
    try std.testing.expect(active_result.cleared_dev);
    try std.testing.expect(!active_result.deleted_managed_toolchain);
    try std.testing.expectEqual(@as(usize, 0), active_result.terminated_processes);
    try std.testing.expect(!try store.isIncomplete(active));
    try std.testing.expect((try store.current()) == null);
    try std.testing.expect((try store.currentDev()) == null);
    try std.testing.expectError(error.VersionNotFound, store.resolve(active));

    const stable_shim_name = if (builtin.os.tag == .windows) "zig.cmd" else "zig";
    const dev_shim_name = if (builtin.os.tag == .windows) "zig-dev.cmd" else "zig-dev";
    const stable_shim = try std.fs.path.join(allocator, &.{ bin_dir, stable_shim_name });
    const dev_shim = try std.fs.path.join(allocator, &.{ bin_dir, dev_shim_name });
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(std.testing.io, stable_shim, .{}));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(std.testing.io, dev_shim, .{}));

    // Removing a registration never deletes the externally owned toolchain.
    _ = try Io.Dir.cwd().statFile(std.testing.io, executable, .{});
}

test "failed removal keeps registration and marks it incomplete" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = try allocator.dupe(u8, root_buffer[0..root_len]);
    const store: Store = .{
        .allocator = allocator,
        .io = std.testing.io,
        .root = root,
        .versions_dir = try std.fs.path.join(allocator, &.{ root, "versions" }),
        .bin_dir = try std.fs.path.join(allocator, &.{ root, "bin" }),
    };

    const executable_name = if (builtin.os.tag == .windows) "external-zig.exe" else "external-zig";
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = executable_name,
        .data = "external executable",
        .flags = .{ .permissions = .executable_file },
    });
    const executable = try std.fs.path.join(allocator, &.{ root, executable_name });
    const version = "2.0.0-test";
    _ = try store.add(version, executable);
    try store.writeCurrentFile("current", "invalid/version");

    try std.testing.expectError(error.InvalidRegistration, store.remove(version, .{}));
    try std.testing.expect(try store.isIncomplete(version));
    try std.testing.expectEqualStrings(executable, try store.resolve(version));
    _ = try Io.Dir.cwd().statFile(std.testing.io, try store.registrationPath(version), .{});
    _ = try Io.Dir.cwd().statFile(std.testing.io, executable, .{});
}

test "explicit ZIGUP_HOME must be non-empty and resolves absolutely" {
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();

    try environ.put("ZIGUP_HOME", "");
    try std.testing.expectError(error.InvalidHome, resolveRoot(allocator, std.testing.io, &environ));

    try environ.put("ZIGUP_HOME", "relative-zigup-home");
    const root = try resolveRoot(allocator, std.testing.io, &environ);
    defer allocator.free(root);
    try std.testing.expect(std.fs.path.isAbsolute(root));
}

test "empty or relative XDG_DATA_HOME falls back to HOME" {
    if (builtin.os.tag == .windows) return;

    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/tmp/zigup-test-user");

    try environ.put("XDG_DATA_HOME", "");
    const empty_root = try resolveRoot(allocator, std.testing.io, &environ);
    defer allocator.free(empty_root);
    try std.testing.expectEqualStrings("/tmp/zigup-test-user/.local/share/zigup", empty_root);

    try environ.put("XDG_DATA_HOME", "relative-data-home");
    const relative_root = try resolveRoot(allocator, std.testing.io, &environ);
    defer allocator.free(relative_root);
    try std.testing.expectEqualStrings("/tmp/zigup-test-user/.local/share/zigup", relative_root);
}
