const std = @import("std");

const Allocator = std.mem.Allocator;
const windows = std.os.windows;

const process_query_limited_information: windows.DWORD = 0x1000;
const process_terminate: windows.DWORD = 0x0001;
const synchronize: windows.DWORD = 0x00100000;
const th32cs_snapprocess: windows.DWORD = 0x00000002;

const ProcessEntry = extern struct {
    size: windows.DWORD,
    usage: windows.DWORD,
    process_id: windows.DWORD,
    default_heap_id: usize,
    module_id: windows.DWORD,
    threads: windows.DWORD,
    parent_process_id: windows.DWORD,
    priority_class_base: i32,
    flags: windows.DWORD,
    executable_name: [260]u16,
};

const ProcessInfo = struct {
    process_id: windows.DWORD,
    parent_process_id: windows.DWORD,
    target: bool,
    started: u64,
    selected: bool = false,
};

pub const Result = struct {
    matched: usize = 0,
    terminated: usize = 0,
};

/// Checks whether the exact executable is running. In force mode, terminates
/// matching processes and their descendants, then verifies that no matching
/// process remains. It never targets a process based only on its image name.
pub fn ensureIdle(allocator: Allocator, executable: []const u8, force: bool) !Result {
    var result: Result = .{};
    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        var processes = try snapshot(allocator, executable);
        defer processes.deinit(allocator);

        var matched: usize = 0;
        for (processes.items) |process| {
            if (process.target) matched += 1;
        }
        if (matched == 0) return result;
        if (!force) return error.ToolchainInUse;
        if (pass == 0) result.matched = matched;

        selectDescendants(processes.items);
        result.terminated += try terminateSelected(processes.items);
    }
    return error.ToolchainForceStopFailed;
}

fn snapshot(allocator: Allocator, executable: []const u8) !std.ArrayList(ProcessInfo) {
    const handle = CreateToolhelp32Snapshot(th32cs_snapprocess, 0);
    if (handle == windows.INVALID_HANDLE_VALUE) return error.ToolchainProcessInspectionFailed;
    defer windows.CloseHandle(handle);

    var result: std.ArrayList(ProcessInfo) = .empty;
    errdefer result.deinit(allocator);
    var entry: ProcessEntry = std.mem.zeroes(ProcessEntry);
    entry.size = @sizeOf(ProcessEntry);
    var available = Process32FirstW(handle, &entry).toBool();
    if (!available) return error.ToolchainProcessInspectionFailed;

    while (available) {
        const identity = try processIdentity(allocator, entry.process_id, executable);
        try result.append(allocator, .{
            .process_id = entry.process_id,
            .parent_process_id = entry.parent_process_id,
            .target = identity.target,
            .started = identity.started,
        });
        entry.size = @sizeOf(ProcessEntry);
        available = Process32NextW(handle, &entry).toBool();
    }
    if (@backingInt(windows.GetLastError()) != 18) return error.ToolchainProcessInspectionFailed;
    return result;
}

const Identity = struct { target: bool = false, started: u64 = 0 };
const Time = extern struct { low: u32, high: u32 };

fn creationTime(handle: windows.HANDLE) !u64 {
    var start: Time = undefined;
    var end: Time = undefined;
    var kernel: Time = undefined;
    var user: Time = undefined;
    if (!GetProcessTimes(handle, &start, &end, &kernel, &user).toBool()) return error.ToolchainProcessInspectionFailed;
    return (@as(u64, start.high) << 32) | start.low;
}

fn processIdentity(allocator: Allocator, process_id: windows.DWORD, executable: []const u8) !Identity {
    if (process_id == windows.GetCurrentProcessId()) return .{};
    const handle = OpenProcess(process_query_limited_information, .FALSE, process_id) orelse return .{};
    defer windows.CloseHandle(handle);

    var path_w: [32768:0]u16 = undefined;
    var path_len: windows.DWORD = path_w.len;
    if (!QueryFullProcessImageNameW(handle, 0, &path_w, &path_len).toBool()) return .{};
    const path = try std.unicode.wtf16LeToWtf8Alloc(allocator, path_w[0..path_len]);
    defer allocator.free(path);
    return .{ .target = std.ascii.eqlIgnoreCase(path, executable), .started = try creationTime(handle) };
}

fn selectDescendants(processes: []ProcessInfo) void {
    for (processes) |*process| process.selected = process.target;
    var changed = true;
    while (changed) {
        changed = false;
        for (processes) |*candidate| {
            if (candidate.selected) continue;
            for (processes) |parent| {
                if (parent.selected and candidate.parent_process_id == parent.process_id and
                    candidate.started != 0 and candidate.started >= parent.started)
                {
                    candidate.selected = true;
                    changed = true;
                    break;
                }
            }
        }
    }
}

fn terminateSelected(processes: []const ProcessInfo) !usize {
    var terminated: usize = 0;
    // Stop roots first so persistent build/watch processes cannot spawn more
    // children while the rest of their process tree is being terminated.
    for (processes) |process| {
        if (!process.target) continue;
        if (try terminate(process)) terminated += 1;
    }
    for (processes) |process| {
        if (!process.selected or process.target) continue;
        if (try terminate(process)) terminated += 1;
    }
    return terminated;
}

fn terminate(process: ProcessInfo) !bool {
    const handle = OpenProcess(process_query_limited_information | process_terminate | synchronize, .FALSE, process.process_id) orelse {
        if (@backingInt(windows.GetLastError()) == 87) return false;
        return error.ToolchainForceStopFailed;
    };
    defer windows.CloseHandle(handle);
    if (try creationTime(handle) != process.started) return false;
    if (WaitForSingleObject(handle, 0) == 0) return false;
    if (!TerminateProcess(handle, 1).toBool() or WaitForSingleObject(handle, 5000) != 0) return error.ToolchainForceStopFailed;
    return true;
}

extern "kernel32" fn GetProcessTimes(windows.HANDLE, *Time, *Time, *Time, *Time) callconv(.winapi) windows.BOOL;

extern "kernel32" fn CreateToolhelp32Snapshot(
    flags: windows.DWORD,
    process_id: windows.DWORD,
) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn Process32FirstW(
    snapshot: windows.HANDLE,
    entry: *ProcessEntry,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn Process32NextW(
    snapshot: windows.HANDLE,
    entry: *ProcessEntry,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn OpenProcess(
    desired_access: windows.DWORD,
    inherit_handle: windows.BOOL,
    process_id: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn QueryFullProcessImageNameW(
    process: windows.HANDLE,
    flags: windows.DWORD,
    executable_name: windows.LPWSTR,
    size: *windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn TerminateProcess(
    process: windows.HANDLE,
    exit_code: windows.UINT,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitForSingleObject(
    handle: windows.HANDLE,
    milliseconds: windows.DWORD,
) callconv(.winapi) windows.DWORD;
