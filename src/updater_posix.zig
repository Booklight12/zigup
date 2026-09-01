//! Native Linux updater for zigup.
//!
//! Mirrors the Windows PowerShell updater: it reads the official ziglang.org
//! release index, installs the latest stable release and the `master`
//! development release side by side, verifies every archive against the
//! SHA-256 digest published in the index, registers both versions, selects
//! them with the `zig` and `zig-dev` shims, self-installs the zigup binary
//! and hooks the shim directory into the user `PATH` via `~/.profile`.
//!
//! Downloads use curl when available and fall back to wget; extraction uses
//! the system tar, matching the external-tool approach of the Windows updater.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const store_mod = @import("store.zig");
const Store = store_mod.Store;

const index_url = "https://ziglang.org/download/index.json";
const official_url_prefix = "https://ziglang.org/";
const profile_marker = "# >>> zigup managed PATH >>>";
const legacy_profile_marker = "# Added by zigup so the managed zig/zig-dev shims are available.";

const DownloadTool = struct {
    kind: enum { curl, wget },
    path: []const u8,
};

const Context = struct {
    allocator: Allocator,
    io: Io,
    store: Store,
    environ_map: *const std.process.Environ.Map,
    downloads_dir: []const u8,
    toolchains_dir: []const u8,
    platform_key: []const u8,
    download_tool: DownloadTool,
};

const Installed = struct {
    version: []const u8,
    executable: []const u8,
};

pub fn run(
    allocator: Allocator,
    io: Io,
    store: Store,
    environ_map: *const std.process.Environ.Map,
) !void {
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

    try store.ensure();
    const lock_path = try std.fs.path.join(allocator, &.{ store.root, "update.lock" });
    var lock_file = Io.Dir.cwd().createFile(io, lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.UpdateAlreadyRunning,
        else => return err,
    };
    defer lock_file.close(io);

    const downloads_dir = try std.fs.path.join(allocator, &.{ store.root, "downloads" });
    const toolchains_dir = try std.fs.path.join(allocator, &.{ store.root, "toolchains" });
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, downloads_dir);
    try cwd.createDirPath(io, toolchains_dir);

    var ctx: Context = .{
        .allocator = allocator,
        .io = io,
        .store = store,
        .environ_map = environ_map,
        .downloads_dir = downloads_dir,
        .toolchains_dir = toolchains_dir,
        .platform_key = try platformKey(allocator, builtin.cpu.arch, builtin.os.tag),
        .download_tool = undefined,
    };
    ctx.download_tool = (try findDownloadTool(&ctx)) orelse return error.DownloadToolMissing;

    const index = try fetchIndex(&ctx);
    const stable_release = try selectStable(index.value);
    const dev_release = switch (index.value) {
        .object => |obj| obj.get("master") orelse return error.NoMasterRelease,
        else => return error.InvalidIndex,
    };

    try status(io, "latest stable: {s}", .{try releaseVersion(stable_release)});
    try status(io, "latest dev:    {s}", .{try releaseVersion(dev_release)});

    const stable = try installRelease(&ctx, "stable", stable_release);
    const dev = try installRelease(&ctx, "dev", dev_release);

    _ = try store.add(stable.version, stable.executable);
    _ = try store.add(dev.version, dev.executable);
    _ = try store.use(stable.version);
    _ = try store.useDev(dev.version);

    try selfInstall(&ctx);
    const path_modified = try ensureUserPath(&ctx);

    try status(io, "update complete", .{});
    try status(io, "zig={s}", .{stable.version});
    try status(io, "zig-dev={s}", .{dev.version});
    if (path_modified) {
        try status(io, "open a new terminal to pick up PATH changes", .{});
    }
}

fn fetchIndex(ctx: *Context) !std.json.Parsed(std.json.Value) {
    try status(ctx.io, "reading official release index {s}", .{index_url});
    const final_path = try std.fs.path.join(ctx.allocator, &.{ ctx.downloads_dir, "index.json" });
    const partial_path = try uniqueTemporaryPath(ctx, final_path);
    defer Io.Dir.cwd().deleteFile(ctx.io, partial_path) catch {};
    try download(ctx, index_url, partial_path);
    try Io.Dir.cwd().rename(partial_path, Io.Dir.cwd(), final_path, ctx.io);
    const bytes = try Io.Dir.cwd().readFileAlloc(
        ctx.io,
        final_path,
        ctx.allocator,
        .limited(16 * 1024 * 1024),
    );
    return std.json.parseFromSlice(std.json.Value, ctx.allocator, bytes, .{});
}

fn installRelease(ctx: *Context, channel: []const u8, release: std.json.Value) !Installed {
    const version = try releaseVersion(release);
    if (!store_mod.isValidVersion(version)) return error.UnsafeVersionInIndex;

    const asset = switch (release) {
        .object => |obj| obj.get(ctx.platform_key) orelse return error.NoAssetForPlatform,
        else => return error.InvalidIndex,
    };
    const tarball_url = switch (asset) {
        .object => |obj| switch (obj.get("tarball") orelse return error.InvalidIndex) {
            .string => |s| s,
            else => return error.InvalidIndex,
        },
        else => return error.InvalidIndex,
    };
    const shasum = switch (asset) {
        .object => |obj| switch (obj.get("shasum") orelse return error.InvalidIndex) {
            .string => |s| s,
            else => return error.InvalidIndex,
        },
        else => return error.InvalidIndex,
    };

    if (!std.mem.startsWith(u8, tarball_url, official_url_prefix)) {
        return error.NonOfficialDownloadUrl;
    }
    if (!isHex64(shasum)) return error.InvalidSha256InIndex;

    const target_dir = try std.fs.path.join(ctx.allocator, &.{ ctx.toolchains_dir, version });
    const zig_exe = try std.fs.path.join(ctx.allocator, &.{ target_dir, "zig" });
    if (try probeZigVersion(ctx.allocator, ctx.io, zig_exe)) |actual| {
        if (std.mem.eql(u8, actual, version)) {
            try status(ctx.io, "{s} {s} is already installed", .{ channel, version });
            return .{ .version = version, .executable = zig_exe };
        }
    }

    const archive_path = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}/zig-{s}-{s}.tar.xz",
        .{ ctx.downloads_dir, channel, version },
    );
    if (!try archiveHashMatches(ctx, archive_path, shasum)) {
        const partial_path = try uniqueTemporaryPath(ctx, archive_path);
        defer Io.Dir.cwd().deleteFile(ctx.io, partial_path) catch {};
        try status(ctx.io, "downloading {s} {s}", .{ channel, version });
        try download(ctx, tarball_url, partial_path);
        try Io.Dir.cwd().rename(partial_path, Io.Dir.cwd(), archive_path, ctx.io);
    }

    try status(ctx.io, "verifying {s} {s} SHA-256", .{ channel, version });
    if (!try archiveHashMatches(ctx, archive_path, shasum)) return error.Sha256Mismatch;

    if (Io.Dir.cwd().statFile(ctx.io, target_dir, .{ .follow_symlinks = false })) |stat| {
        _ = stat;
        const backup_prefix = try std.fmt.allocPrint(ctx.allocator, "{s}.invalid", .{target_dir});
        const backup = try uniqueTemporaryPath(ctx, backup_prefix);
        try Io.Dir.cwd().rename(target_dir, Io.Dir.cwd(), backup, ctx.io);
        try status(ctx.io, "preserved invalid installation at {s}", .{backup});
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const extract_prefix = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}/.extract-{s}",
        .{ ctx.toolchains_dir, channel },
    );
    const extract_dir = try uniqueTemporaryPath(ctx, extract_prefix);
    try Io.Dir.cwd().createDir(ctx.io, extract_dir, .default_dir);
    {
        errdefer Io.Dir.cwd().deleteTree(ctx.io, extract_dir) catch {};
        try status(ctx.io, "extracting {s} {s}", .{ channel, version });
        try extractArchive(ctx.io, archive_path, extract_dir);
        const extracted_zig = try std.fs.path.join(ctx.allocator, &.{ extract_dir, "zig" });
        const actual = (try probeZigVersion(ctx.allocator, ctx.io, extracted_zig)) orelse
            return error.ExtractedVersionMismatch;
        if (!std.mem.eql(u8, actual, version)) return error.ExtractedVersionMismatch;
        try Io.Dir.cwd().rename(extract_dir, Io.Dir.cwd(), target_dir, ctx.io);
    }

    const installed = (try probeZigVersion(ctx.allocator, ctx.io, zig_exe)) orelse
        return error.InstalledVersionMismatch;
    if (!std.mem.eql(u8, installed, version)) return error.InstalledVersionMismatch;
    return .{ .version = version, .executable = zig_exe };
}

fn findDownloadTool(ctx: *Context) !?DownloadTool {
    for ([_]DownloadTool{
        .{ .kind = .curl, .path = "curl" },
        .{ .kind = .wget, .path = "wget" },
    }) |tool| {
        const result = std.process.run(ctx.allocator, ctx.io, .{
            .argv = &.{ "sh", "-c", "command -v \"$1\"", "sh", tool.path },
            .stdout_limit = .limited(4096),
        }) catch continue;
        if (!result.term.success()) continue;
        const path = std.mem.trim(u8, result.stdout, " \r\n\t");
        if (path.len == 0) continue;
        return .{ .kind = tool.kind, .path = path };
    }
    return null;
}

fn download(ctx: *Context, url: []const u8, output_path: []const u8) !void {
    const argv: []const []const u8 = switch (ctx.download_tool.kind) {
        .curl => &.{
            ctx.download_tool.path, "--fail",       "--location", "--retry",   "3",
            "--silent",             "--show-error", "--output",   output_path, url,
        },
        .wget => &.{
            ctx.download_tool.path, "--tries=3", "--timeout=30", "--no-verbose",
            "--output-document",    output_path, url,
        },
    };
    var child = std.process.spawn(ctx.io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return error.DownloadFailed;
    const term = child.wait(ctx.io) catch return error.DownloadFailed;
    if (!term.success()) return error.DownloadFailed;
}

fn extractArchive(io: Io, archive_path: []const u8, dest_dir: []const u8) !void {
    const argv = [_][]const u8{
        "tar", "-xf", archive_path, "-C", dest_dir, "--strip-components=1",
    };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .inherit,
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch return error.TarFailed;
    const term = child.wait(io) catch return error.TarFailed;
    if (!term.success()) return error.TarFailed;
}

fn probeZigVersion(allocator: Allocator, io: Io, executable: []const u8) !?[]const u8 {
    const stat = Io.Dir.cwd().statFile(io, executable, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.kind != .file) return null;
    const result = std.process.run(allocator, io, .{
        .argv = &.{ executable, "version" },
        .stdout_limit = .limited(4096),
    }) catch return null;
    if (!result.term.success()) return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \r\n\t");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn archiveHashMatches(ctx: *Context, archive_path: []const u8, expected_hex: []const u8) !bool {
    const stat = Io.Dir.cwd().statFile(ctx.io, archive_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind != .file) return false;

    var file = try Io.Dir.cwd().openFile(ctx.io, archive_path, .{});
    defer file.close(ctx.io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var hash_buffer: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(ctx.io, &read_buffer);
    var hashing = Io.Writer.Hashing(std.crypto.hash.sha2.Sha256).init(&hash_buffer);
    _ = try file_reader.interface.streamRemaining(&hashing.writer);
    try hashing.writer.flush();
    var digest: [32]u8 = undefined;
    hashing.hasher.final(&digest);
    return hex64MatchesDigest(expected_hex, digest);
}

fn selfInstall(ctx: *Context) !void {
    const executable_path = try std.process.executablePathAlloc(ctx.io, ctx.allocator);
    const bytes = try Io.Dir.cwd().readFileAlloc(
        ctx.io,
        executable_path,
        ctx.allocator,
        .limited(64 * 1024 * 1024),
    );
    const destination = try std.fs.path.join(ctx.allocator, &.{ ctx.store.bin_dir, "zigup" });
    const temporary = try uniqueTemporaryPath(ctx, destination);
    errdefer Io.Dir.cwd().deleteFile(ctx.io, temporary) catch {};
    try Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = temporary,
        .data = bytes,
        .flags = .{ .exclusive = true, .permissions = .executable_file },
    });
    try Io.Dir.cwd().rename(temporary, Io.Dir.cwd(), destination, ctx.io);
}

fn ensureUserPath(ctx: *Context) !bool {
    const home = ctx.environ_map.get("HOME") orelse return error.HomeEnvMissing;
    if (home.len == 0) return error.HomeEnvMissing;
    var profile_path: []const u8 = try std.fs.path.join(ctx.allocator, &.{ home, ".profile" });
    if (Io.Dir.cwd().statFile(ctx.io, profile_path, .{ .follow_symlinks = false })) |stat| {
        switch (stat.kind) {
            .file => {},
            .sym_link => {
                profile_path = Io.Dir.cwd().realPathFileAlloc(
                    ctx.io,
                    profile_path,
                    ctx.allocator,
                ) catch return error.InvalidProfile;
                const target_stat = Io.Dir.cwd().statFile(ctx.io, profile_path, .{}) catch
                    return error.InvalidProfile;
                if (target_stat.kind != .file) return error.InvalidProfile;
            },
            else => return error.InvalidProfile,
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const existing = Io.Dir.cwd().readFileAlloc(
        ctx.io,
        profile_path,
        ctx.allocator,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    if (std.mem.indexOf(u8, existing, profile_marker) != null) return false;
    if (std.mem.indexOf(u8, existing, legacy_profile_marker) != null and
        std.mem.indexOf(u8, existing, ctx.store.bin_dir) != null)
    {
        return false;
    }

    const block = try profileBlock(ctx.allocator, ctx.store.bin_dir);
    const replacement = try std.mem.concat(ctx.allocator, u8, &.{ existing, block });
    const temporary = try uniqueTemporaryPath(ctx, profile_path);
    errdefer Io.Dir.cwd().deleteFile(ctx.io, temporary) catch {};

    var permissions: Io.File.Permissions = .default_file;
    if (Io.Dir.cwd().statFile(ctx.io, profile_path, .{})) |stat| {
        permissions = stat.permissions;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try Io.Dir.cwd().writeFile(ctx.io, .{
        .sub_path = temporary,
        .data = replacement,
        .flags = .{ .exclusive = true, .permissions = permissions },
    });
    try Io.Dir.cwd().rename(temporary, Io.Dir.cwd(), profile_path, ctx.io);
    try status(ctx.io, "added {s} to PATH via {s}", .{ ctx.store.bin_dir, profile_path });
    return true;
}

fn uniqueTemporaryPath(ctx: *Context, prefix: []const u8) ![]const u8 {
    var random_bytes: [16]u8 = undefined;
    try ctx.io.randomSecure(&random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);
    return std.fmt.allocPrint(ctx.allocator, "{s}.zigup-tmp-{s}", .{ prefix, suffix[0..] });
}

fn profileBlock(allocator: Allocator, bin_dir: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, bin_dir, ':') != null) return error.PathContainsSeparator;
    const quoted = try quotePosixShell(allocator, bin_dir);
    defer allocator.free(quoted);
    return std.fmt.allocPrint(
        allocator,
        "\n" ++ profile_marker ++ "\n" ++
            "case \":${{PATH-}}:\" in\n" ++
            "  *:{s}:*) ;;\n" ++
            "  *) PATH={s}${{PATH:+\":$PATH\"}}; export PATH ;;\n" ++
            "esac\n" ++
            "# <<< zigup managed PATH <<<\n",
        .{ quoted, quoted },
    );
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

fn releaseVersion(release: std.json.Value) ![]const u8 {
    return switch (release) {
        .object => |obj| switch (obj.get("version") orelse return error.InvalidIndex) {
            .string => |s| s,
            else => error.InvalidIndex,
        },
        else => error.InvalidIndex,
    };
}

fn selectStable(index: std.json.Value) !std.json.Value {
    const obj = switch (index) {
        .object => |obj| obj,
        else => return error.InvalidIndex,
    };
    var best_version: ?std.SemanticVersion = null;
    var best_name: ?[]const u8 = null;
    var best_value: std.json.Value = .null;
    var iterator = obj.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!isPlainStableVersion(name)) continue;
        const parsed = std.SemanticVersion.parse(name) catch continue;
        if (best_version == null or std.SemanticVersion.order(parsed, best_version.?) == .gt) {
            best_version = parsed;
            best_name = name;
            best_value = entry.value_ptr.*;
        }
    }
    if (best_version == null) return error.NoStableRelease;
    const value_version = try releaseVersion(best_value);
    if (!std.mem.eql(u8, best_name.?, value_version)) return error.InvalidIndex;
    return best_value;
}

fn platformKey(
    allocator: Allocator,
    arch: std.Target.Cpu.Arch,
    os: std.Target.Os.Tag,
) ![]const u8 {
    const arch_name = switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "x86",
        .riscv64 => "riscv64",
        else => return error.UnsupportedHostArch,
    };
    const os_name = switch (os) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => return error.UnsupportedHostOs,
    };
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ arch_name, os_name });
}

fn isPlainStableVersion(name: []const u8) bool {
    var part_count: usize = 0;
    var iterator = std.mem.splitScalar(u8, name, '.');
    while (iterator.next()) |part| {
        part_count += 1;
        if (part_count > 3) return false;
        if (part.len == 0) return false;
        for (part) |char| {
            if (!std.ascii.isDigit(char)) return false;
        }
    }
    return part_count == 3;
}

fn isHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |char| {
        if (!std.ascii.isHex(char)) return false;
    }
    return true;
}

fn hex64MatchesDigest(expected_hex: []const u8, digest: [32]u8) bool {
    if (expected_hex.len != 64) return false;
    const hex_chars = "0123456789abcdef";
    var actual: [64]u8 = undefined;
    for (digest, 0..) |byte, i| {
        actual[i * 2] = hex_chars[byte >> 4];
        actual[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    for (expected_hex, actual) |expected, actual_char| {
        if (std.ascii.toLower(expected) != actual_char) return false;
    }
    return true;
}

fn status(io: Io, comptime format: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    try file_writer.interface.print("zigup: " ++ format ++ "\n", args);
    try file_writer.interface.flush();
}

test "platform key matches ziglang.org asset naming" {
    const allocator = std.testing.allocator;
    const linux_key = try platformKey(allocator, .x86_64, .linux);
    defer allocator.free(linux_key);
    try std.testing.expectEqualStrings("x86_64-linux", linux_key);
    const macos_key = try platformKey(allocator, .aarch64, .macos);
    defer allocator.free(macos_key);
    try std.testing.expectEqualStrings("aarch64-macos", macos_key);
    try std.testing.expectError(error.UnsupportedHostArch, platformKey(allocator, .wasm32, .linux));
}

test "stable selection picks the highest plain release" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"master": {"version": "0.17.0-dev.1"}, "0.16.0": {"version": "0.16.0"},
        \\ "0.15.2": {"version": "0.15.2"}, "0.16.0-rc.1": {"version": "0.16.0-rc.1"}}
    ,
        .{},
    );
    defer parsed.deinit();
    const stable = try selectStable(parsed.value);
    try std.testing.expectEqualStrings("0.16.0", try releaseVersion(stable));
}

test "stable selection fails when the index has no plain release" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"master": {"version": "0.17.0-dev.1"}, "0.16.0-rc.1": {"version": "0.16.0-rc.1"}}
    ,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectError(error.NoStableRelease, selectStable(parsed.value));
}

test "stable selection rejects a release whose key and version disagree" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"0.16.0": {"version": "0.15.2"}}
    ,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidIndex, selectStable(parsed.value));
}

test "plain stable version detection" {
    try std.testing.expect(isPlainStableVersion("0.16.0"));
    try std.testing.expect(isPlainStableVersion("1.2.3"));
    try std.testing.expect(!isPlainStableVersion("master"));
    try std.testing.expect(!isPlainStableVersion("0.16.0-rc.1"));
    try std.testing.expect(!isPlainStableVersion("0.17.0-dev.1902"));
    try std.testing.expect(!isPlainStableVersion(""));
    try std.testing.expect(!isPlainStableVersion("1.2"));
}

test "hex digest comparison is case-insensitive" {
    var digest: [32]u8 = undefined;
    @memset(&digest, 0xab);

    var expected: [64]u8 = undefined;
    for (&expected, 0..) |*char, i| {
        char.* = if (i % 2 == 0) 'a' else 'b';
    }
    try std.testing.expect(hex64MatchesDigest(&expected, digest));

    for (&expected, 0..) |*char, i| {
        char.* = if (i % 2 == 0) 'A' else 'B';
    }
    try std.testing.expect(hex64MatchesDigest(&expected, digest));

    expected[0] = 'c';
    try std.testing.expect(!hex64MatchesDigest(&expected, digest));
    try std.testing.expect(!hex64MatchesDigest(expected[0..63], digest));
}

test "profile block quotes shell metacharacters" {
    const allocator = std.testing.allocator;
    const block = try profileBlock(allocator, "/tmp/odd $dir/it's-bin");
    defer allocator.free(block);
    try std.testing.expect(std.mem.indexOf(u8, block, profile_marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "'/tmp/odd $dir/it'\\''s-bin'") != null);
    try std.testing.expectError(error.PathContainsSeparator, profileBlock(allocator, "/tmp/odd:dir/bin"));
}
