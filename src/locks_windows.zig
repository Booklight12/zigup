//! Non-destructive delete-access probes; Restart Manager identifies file owners.
const std = @import("std");
const w = std.os.windows;
const Time = extern struct { low: u32, high: u32 };
const Identity = extern struct { pid: u32, started: Time };
const Owner = extern struct {
    process: Identity,
    name: [256]u16,
    service: [64]u16,
    kind: i32,
    status: u32,
    session: u32,
    restartable: i32,
};

pub fn ensureUnlocked(allocator: std.mem.Allocator, io: std.Io, root: []const u8, force: bool) !usize {
    const stat = std.Io.Dir.cwd().statFile(io, root, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    if (stat.kind != .directory) return error.UnsafeToolchainPath;
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    var terminated: usize = 0;
    for (0..4) |_| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var locked: std.ArrayList([*:0]const u16) = .empty;
        const root_w = try std.unicode.wtf8ToWtf16LeAllocZ(a, root);
        if (!try probe(root_w)) return error.ToolchainInUse;
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            const path = try std.fs.path.join(a, &.{ root, entry.path });
            const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(a, path);
            if (!try probe(path_w)) {
                if (!force) return error.ToolchainInUse;
                if (entry.kind == .directory or entry.kind == .sym_link) return error.ToolchainInUse;
                try locked.append(a, path_w.ptr);
            }
        }
        if (locked.items.len == 0) return terminated;
        terminated += try releaseOwners(a, locked.items);
    }
    return error.ToolchainForceStopFailed;
}

fn probe(path: [:0]const u16) !bool {
    // Request DELETE without changing anything. OPEN_REPARSE_POINT prevents
    // inspection from following links outside the managed tree.
    const handle = CreateFileW(path.ptr, 0x10000, 7, null, 3, 0x02200000, null);
    if (handle == w.INVALID_HANDLE_VALUE) {
        return switch (@backingInt(w.GetLastError())) {
            2, 3 => true,
            32, 33 => false,
            5 => error.AccessDenied,
            else => error.ToolchainLockInspectionFailed,
        };
    }
    w.CloseHandle(handle);
    return true;
}

fn releaseOwners(a: std.mem.Allocator, paths: []const [*:0]const u16) !usize {
    var session: u32 = 0;
    var key: [33]u16 = undefined;
    if (RmStartSession(&session, 0, &key) != 0) return error.ToolchainLockInspectionFailed;
    defer _ = RmEndSession(session);
    if (RmRegisterResources(session, @intCast(paths.len), paths.ptr, 0, null, 0, null) != 0)
        return error.ToolchainLockInspectionFailed;
    var needed: u32 = 0;
    var count: u32 = 0;
    var reasons: u32 = 0;
    var code = RmGetList(session, &needed, &count, null, &reasons);
    for (0..8) |_| {
        if (code == 0 and needed == 0) return error.ToolchainForceStopFailed;
        if (code != 234) return error.ToolchainLockInspectionFailed;
        const owners = try a.alloc(Owner, needed);
        count = needed;
        code = RmGetList(session, &needed, &count, owners.ptr, &reasons);
        if (code == 234) continue;
        if (code != 0) return error.ToolchainLockInspectionFailed;
        var stopped: usize = 0;
        for (owners[0..count]) |owner| {
            // Critical processes and the remover itself cannot be force stopped.
            if (owner.kind == 1000 or owner.process.pid == w.GetCurrentProcessId()) return error.ToolchainForceStopFailed;
            const h = OpenProcess(0x1000 | 0x1 | 0x100000, 0, owner.process.pid) orelse {
                if (@backingInt(w.GetLastError()) == 87) continue;
                return error.ToolchainForceStopFailed;
            };
            defer w.CloseHandle(h);
            var started: Time = undefined;
            var exited: Time = undefined;
            var kernel: Time = undefined;
            var user: Time = undefined;
            if (GetProcessTimes(h, &started, &exited, &kernel, &user) == 0) return error.ToolchainForceStopFailed;
            // A PID may have been recycled between discovery and opening.
            if (!std.meta.eql(started, owner.process.started)) continue;
            if (WaitForSingleObject(h, 0) == 0) continue;
            if (TerminateProcess(h, 1) == 0 or WaitForSingleObject(h, 5000) != 0) return error.ToolchainForceStopFailed;
            stopped += 1;
        }
        return stopped;
    }
    return error.ToolchainLockInspectionFailed;
}

extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?w.HANDLE) callconv(.winapi) w.HANDLE;
extern "kernel32" fn OpenProcess(u32, i32, u32) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn GetProcessTimes(w.HANDLE, *Time, *Time, *Time, *Time) callconv(.winapi) i32;
extern "kernel32" fn TerminateProcess(w.HANDLE, u32) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(w.HANDLE, u32) callconv(.winapi) u32;
extern "rstrtmgr" fn RmStartSession(*u32, u32, *[33]u16) callconv(.winapi) u32;
extern "rstrtmgr" fn RmEndSession(u32) callconv(.winapi) u32;
extern "rstrtmgr" fn RmRegisterResources(u32, u32, [*]const [*:0]const u16, u32, ?*anyopaque, u32, ?*anyopaque) callconv(.winapi) u32;
extern "rstrtmgr" fn RmGetList(u32, *u32, *u32, ?[*]Owner, *u32) callconv(.winapi) u32;
