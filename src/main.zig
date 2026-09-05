const std = @import("std");
const Io = std.Io;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const updater = @import("updater.zig");

const app_version = "0.2.2";

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    defer stderr.flush() catch {};

    if (args.len == 1) {
        try printUsage(stdout);
        return;
    }
    if (isHelp(args[1])) {
        requireArity(args, 2) catch return fail(stdout, stderr, error.InvalidArguments);
        try printUsage(stdout);
        return;
    }
    if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "version")) {
        requireArity(args, 2) catch return fail(stdout, stderr, error.InvalidArguments);
        try stdout.print("zigup {s}\n", .{app_version});
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "remove")) {
        _ = parseRemoveArgs(args) catch return fail(stdout, stderr, error.InvalidArguments);
    } else if (commandArity(command)) |expected| {
        requireArity(args, expected) catch return fail(stdout, stderr, error.InvalidArguments);
    } else {
        try stderr.print("unknown command: {s}\n\n", .{command});
        try printUsage(stderr);
        try stderr.flush();
        std.process.exit(2);
    }

    const store = Store.init(allocator, init.io, init.environ_map) catch |err| {
        return fail(stdout, stderr, err);
    };

    if (std.mem.eql(u8, command, "home")) {
        requireArity(args, 2) catch return fail(stdout, stderr, error.InvalidArguments);
        try stdout.print("{s}\n", .{store.root});
    } else if (std.mem.eql(u8, command, "env")) {
        requireArity(args, 2) catch return fail(stdout, stderr, error.InvalidArguments);
        try stdout.print("{s}\n", .{store.bin_dir});
    } else if (std.mem.eql(u8, command, "add")) {
        requireArity(args, 4) catch return fail(stdout, stderr, error.InvalidArguments);
        const executable = store.add(args[2], args[3]) catch |err| return fail(stdout, stderr, err);
        try stdout.print("registered {s} -> {s}\n", .{ args[2], executable });
    } else if (std.mem.eql(u8, command, "use")) {
        requireArity(args, 3) catch return fail(stdout, stderr, error.InvalidArguments);
        const executable = store.use(args[2]) catch |err| return fail(stdout, stderr, err);
        try stdout.print("using {s} -> {s}\n", .{ args[2], executable });
        try stdout.print("shim: {s}\n", .{store.bin_dir});
    } else if (std.mem.eql(u8, command, "update")) {
        requireArity(args, 2) catch return fail(stdout, stderr, error.InvalidArguments);
        try stdout.writeAll("zigup: updating stable and development Zig toolchains from ziglang.org\n");
        try stdout.flush();
        try stderr.flush();
        updater.run(allocator, init.io, store, init.environ_map) catch |err| return fail(stdout, stderr, err);
    } else if (std.mem.eql(u8, command, "current")) {
        requireArity(args, 2) catch return fail(stdout, stderr, error.InvalidArguments);
        if (store.current() catch |err| return fail(stdout, stderr, err)) |version| {
            const executable = store.resolve(version) catch |err| return fail(stdout, stderr, err);
            try stdout.print("stable {s} -> {s}\n", .{ version, executable });
        } else {
            try stdout.writeAll("stable not selected\n");
        }
        if (store.currentDev() catch |err| return fail(stdout, stderr, err)) |version| {
            const executable = store.resolve(version) catch |err| return fail(stdout, stderr, err);
            try stdout.print("dev    {s} -> {s}\n", .{ version, executable });
        } else {
            try stdout.writeAll("dev    not selected\n");
        }
    } else if (std.mem.eql(u8, command, "where")) {
        requireArity(args, 3) catch return fail(stdout, stderr, error.InvalidArguments);
        const executable = store.resolve(args[2]) catch |err| return fail(stdout, stderr, err);
        try stdout.print("{s}\n", .{executable});
    } else if (std.mem.eql(u8, command, "list")) {
        requireArity(args, 2) catch return fail(stdout, stderr, error.InvalidArguments);
        listVersions(store, stdout) catch |err| return fail(stdout, stderr, err);
    } else if (std.mem.eql(u8, command, "remove")) {
        const remove_args = parseRemoveArgs(args) catch return fail(stdout, stderr, error.InvalidArguments);
        const result = store.remove(remove_args.version, .{ .force = remove_args.force }) catch |err| {
            switch (err) {
                error.InvalidVersion, error.VersionNotFound, error.RemovalAlreadyRunning => return fail(stdout, stderr, err),
                else => return failRemoval(stdout, stderr, err),
            }
        };
        try stdout.print("removed registration for {s}\n", .{remove_args.version});
        if (result.terminated_processes != 0) {
            try stdout.print("force-stopped {d} toolchain process(es)\n", .{result.terminated_processes});
        }
        if (result.deleted_managed_toolchain) try stdout.writeAll("deleted managed toolchain files\n");
        if (result.cleared_stable) try stdout.writeAll("cleared stable selection and shim\n");
        if (result.cleared_dev) try stdout.writeAll("cleared dev selection and shim\n");
    } else unreachable;
}

fn listVersions(store: Store, writer: *Io.Writer) !void {
    try store.ensure();
    var dir = try Io.Dir.cwd().openDir(store.io, store.versions_dir, .{ .iterate = true });
    defer dir.close(store.io);

    const active = try store.current();
    const active_dev = try store.currentDev();
    var versions: std.ArrayList([]const u8) = .empty;
    defer {
        for (versions.items) |version| store.allocator.free(version);
        versions.deinit(store.allocator);
    }
    var iterator = dir.iterate();
    while (try iterator.next(store.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".path")) continue;
        const version = entry.name[0 .. entry.name.len - ".path".len];
        if (!store_mod.isValidVersion(version)) continue;
        try versions.append(store.allocator, try store.allocator.dupe(u8, version));
    }
    std.sort.heap([]const u8, versions.items, {}, versionLessThan);
    for (versions.items) |version| {
        const is_active = (active != null and store_mod.versionEqual(active.?, version)) or
            (active_dev != null and store_mod.versionEqual(active_dev.?, version));
        const marker = if (is_active) "*" else " ";
        const incomplete = if (try store.isIncomplete(version)) " [Incomplete]" else "";
        try writer.print("{s} {s}{s}\n", .{ marker, version, incomplete });
    }
    if (versions.items.len == 0) try writer.writeAll("no registered Zig versions\n");
}

fn versionLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "help") or
        std.mem.eql(u8, arg, "--help") or
        std.mem.eql(u8, arg, "-h");
}

fn requireArity(args: []const []const u8, expected: usize) !void {
    if (args.len != expected) return error.InvalidArguments;
}

fn commandArity(command: []const u8) ?usize {
    if (std.mem.eql(u8, command, "home") or
        std.mem.eql(u8, command, "env") or
        std.mem.eql(u8, command, "update") or
        std.mem.eql(u8, command, "current") or
        std.mem.eql(u8, command, "list")) return 2;
    if (std.mem.eql(u8, command, "use") or
        std.mem.eql(u8, command, "where")) return 3;
    if (std.mem.eql(u8, command, "add")) return 4;
    return null;
}

const RemoveArgs = struct {
    version: []const u8,
    force: bool,
};

fn parseRemoveArgs(args: []const []const u8) !RemoveArgs {
    if (args.len == 3) return .{ .version = args[2], .force = false };
    if (args.len == 4 and
        (std.mem.eql(u8, args[2], "-force") or
            std.mem.eql(u8, args[2], "--force") or
            std.mem.eql(u8, args[2], "-f")))
    {
        return .{ .version = args[3], .force = true };
    }
    return error.InvalidArguments;
}

fn fail(stdout: *Io.Writer, stderr: *Io.Writer, err: anyerror) noreturn {
    stdout.flush() catch {};
    stderr.print("zigup: {s}\n", .{describeError(err)}) catch {};
    stderr.print("details: {s}\n", .{@errorName(err)}) catch {};
    stderr.flush() catch {};
    std.process.exit(1);
}

fn failRemoval(stdout: *Io.Writer, stderr: *Io.Writer, err: anyerror) noreturn {
    stdout.flush() catch {};
    stderr.writeAll("zigup: removal did not complete [Incomplete]; files may be partially removed\n") catch {};
    stderr.print("reason: {s}\n", .{describeError(err)}) catch {};
    stderr.print("details: {s}\n", .{@errorName(err)}) catch {};
    stderr.flush() catch {};
    std.process.exit(1);
}

fn describeError(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidArguments => "invalid command arguments; run `zigup help`",
        error.InvalidVersion => "invalid version name",
        error.VersionNotFound => "version is not registered",
        error.RemovalAlreadyRunning => "another update or store operation is running; nothing was deleted",
        error.ToolchainInUse => "toolchain is in use; stop running Zig processes and retry",
        error.ToolchainForceStopFailed => "could not stop every process using the toolchain",
        error.ToolchainProcessInspectionFailed => "could not inspect running processes for toolchain locks",
        error.ToolchainLockInspectionFailed => "could not inspect toolchain file locks; deletion aborted",
        error.UnsafeToolchainPath => "managed toolchain path contains a link or unexpected entry; deletion aborted",
        error.InvalidRegistration => "registration metadata is invalid",
        error.NotAFile => "the Zig executable path is not a file",
        error.NotExecutable => "the Zig executable path is not executable",
        error.FileNotFound => "file or directory not found",
        error.AccessDenied, error.PermissionDenied => "filesystem access denied",
        error.HomeNotFound => "cannot determine the data directory; set ZIGUP_HOME",
        error.InvalidHome => "ZIGUP_HOME cannot be empty",
        error.EntropyUnavailable => "cannot obtain secure randomness for a temporary file",
        error.UnsupportedPlatform => "automatic update currently supports Windows and Linux",
        error.UpdateFailed => "automatic update failed; see the updater output above",
        error.UpdateAlreadyRunning => "another zigup update is already running",
        error.InvalidIndex => "the Zig download index is malformed",
        error.NoStableRelease => "the Zig download index contains no stable release",
        error.NoMasterRelease => "the Zig download index contains no master development release",
        error.NoAssetForPlatform => "the Zig download index has no asset for this platform",
        error.NonOfficialDownloadUrl => "refusing a non-official Zig download URL",
        error.InvalidSha256InIndex => "invalid SHA-256 in the Zig download index",
        error.Sha256Mismatch => "SHA-256 mismatch for the downloaded archive",
        error.DownloadFailed => "download failed; check network connectivity",
        error.InvalidProxy => "invalid proxy configuration; set ZIGUP_PROXY to auto, direct, or a proxy URL",
        error.ProxyUnsupportedByDownloadTool => "this proxy protocol requires curl; wget supports HTTP proxies only",
        error.DownloadLocalFailure => "the downloader could not read or write a local file",
        error.DownloadInterrupted => "download interrupted",
        error.InvalidDownloadUrl => "invalid download URL",
        error.DownloadToolMissing => "neither curl nor wget is available for downloading",
        error.TarFailed => "extraction failed; ensure tar supports xz archives",
        error.ExtractedVersionMismatch => "the extracted archive does not contain the expected Zig version",
        error.InstalledVersionMismatch => "installed Zig failed version validation",
        error.UnsafeVersionInIndex => "unsafe version string in the Zig download index",
        error.HomeEnvMissing => "cannot determine the user home directory; set HOME",
        error.InvalidProfile => "the user .profile path is not a writable regular file",
        error.PathContainsSeparator => "the zigup bin directory contains ':' and cannot be added to PATH",
        error.UnsupportedHostArch => "this CPU architecture has no supported Zig updater target",
        error.UnsupportedHostOs => "this operating system has no supported Zig updater target",
        else => "operation failed",
    };
}

fn printUsage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\zigup - select between registered Zig toolchains
        \\
        \\Usage:
        \\  zigup add <version> <zig-executable>
        \\  zigup list
        \\  zigup use <version>
        \\  zigup update
        \\  zigup current
        \\  zigup where <version>
        \\  zigup remove [-force] <version>
        \\  zigup home
        \\  zigup env
        \\  zigup version
        \\
        \\`remove` checks for running toolchain processes before deletion. Failures
        \\are retained as [Incomplete]; `remove -force` stops those processes first.
        \\Managed toolchains are deleted; external installations are unregistered.
        \\Downloads automatically select environment/system proxies, then direct.
        \\ZIGUP_PROXY=direct disables proxies; ZIGUP_PROXY=<URL> forces one proxy.
        \\
    );
}

test "command arities reject unknown commands" {
    try std.testing.expectEqual(@as(?usize, 2), commandArity("list"));
    try std.testing.expectEqual(@as(?usize, 3), commandArity("use"));
    try std.testing.expectEqual(@as(?usize, 4), commandArity("add"));
    try std.testing.expectEqual(@as(?usize, null), commandArity("unknown"));
}

test "remove accepts explicit force spellings only before the version" {
    const plain = [_][]const u8{ "zigup", "remove", "1.2.3" };
    const force = [_][]const u8{ "zigup", "remove", "-force", "1.2.3" };
    const long_force = [_][]const u8{ "zigup", "remove", "--force", "1.2.3" };
    const short_force = [_][]const u8{ "zigup", "remove", "-f", "1.2.3" };
    const misplaced = [_][]const u8{ "zigup", "remove", "1.2.3", "-force" };
    const unknown = [_][]const u8{ "zigup", "remove", "-delete", "1.2.3" };

    try std.testing.expect(!(try parseRemoveArgs(&plain)).force);
    try std.testing.expect((try parseRemoveArgs(&force)).force);
    try std.testing.expect((try parseRemoveArgs(&long_force)).force);
    try std.testing.expect((try parseRemoveArgs(&short_force)).force);
    try std.testing.expectError(error.InvalidArguments, parseRemoveArgs(&misplaced));
    try std.testing.expectError(error.InvalidArguments, parseRemoveArgs(&unknown));
}

test "version labels sort deterministically" {
    var versions = [_][]const u8{ "master", "0.16.0", "0.17.0-dev.1" };
    std.sort.heap([]const u8, &versions, {}, versionLessThan);
    try std.testing.expectEqualStrings("0.16.0", versions[0]);
    try std.testing.expectEqualStrings("0.17.0-dev.1", versions[1]);
    try std.testing.expectEqualStrings("master", versions[2]);
}
