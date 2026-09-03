//! Per-update proxy discovery and download routing. Nothing here changes the
//! parent environment, desktop settings, or downloader configuration files.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const DownloadTool = struct {
    kind: enum { curl, wget },
    path: []const u8,
};

pub const Scheme = enum { http, https, socks4, socks4a, socks5, socks5h };
pub const Proxy = struct { url: []const u8, scheme: Scheme };
pub const Mode = union(enum) { auto, direct, forced: Proxy };
pub const Route = struct {
    proxy: ?Proxy = null,
    source: enum { direct, environment, gnome, libproxy, explicit } = .direct,
};

pub const Session = struct {
    allocator: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    mode: Mode,
    no_proxy: []const u8,
    desktop_routes: std.ArrayList(Route) = .empty,
    desktop_bypass: []const u8 = "",
    resolver_path: ?[]const u8 = null,
    preferred: ?Route = null,
    preferred_plan: ?[32]u8 = null,
    current_plan: [32]u8 = undefined,

    /// The caller normally supplies its update-lifetime arena allocator.
    pub fn init(allocator: Allocator, io: Io, environ: *const std.process.Environ.Map) !Session {
        var session: Session = .{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .mode = try parseMode(allocator, environ.get("ZIGUP_PROXY")),
            .no_proxy = firstNonEmpty(environ, &.{ "no_proxy", "NO_PROXY" }) orelse "",
        };
        if (session.mode == .auto and builtin.os.tag == .linux) {
            session.resolver_path = try session.findExecutable("proxy");
            try session.readGnome();
        }
        return session;
    }

    /// Routes are recomputed for each URL (PAC and bypass rules can vary by
    /// URL), but the last successful route is preferred if still applicable.
    pub fn routesFor(self: *Session, allocator: Allocator, url: []const u8) ![]Route {
        const uri = std.Uri.parse(url) catch return error.InvalidDownloadUrl;
        if ((!std.ascii.eqlIgnoreCase(uri.scheme, "https") and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) or
            uri.host == null or componentBytes(uri.host.?).len == 0 or uri.port == 0 or
            uri.user != null or uri.password != null) return error.InvalidDownloadUrl;
        for (url) |byte| if (byte <= 0x20 or byte == 0x7f) return error.InvalidDownloadUrl;
        var routes: std.ArrayList(Route) = .empty;
        errdefer routes.deinit(allocator);
        switch (self.mode) {
            .direct => try routes.append(allocator, .{}),
            .forced => |proxy| try routes.append(allocator, .{ .proxy = proxy, .source = .explicit }),
            .auto => {
                if (shouldBypass(url, self.no_proxy)) {
                    try routes.append(allocator, .{});
                    self.current_plan = planFingerprint(routes.items);
                    return routes.toOwnedSlice(allocator);
                }
                const keys: []const []const u8 = if (std.ascii.eqlIgnoreCase(uri.scheme, "https"))
                    &.{ "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" }
                else
                    // Uppercase HTTP_PROXY is deliberately excluded because of
                    // its CGI request-header collision (curl follows this rule).
                    &.{ "http_proxy", "all_proxy", "ALL_PROXY" };
                for (keys) |key| {
                    const value = self.environ.get(key) orelse continue;
                    if (std.mem.trim(u8, value, " \t").len == 0) continue;
                    const proxy = parseProxy(allocator, value, true) catch {
                        try status(self.io, "ignoring invalid environment proxy setting", .{});
                        continue;
                    };
                    try appendUnique(&routes, allocator, .{ .proxy = proxy, .source = .environment });
                    // Lowercase wins over uppercase for one variable family;
                    // ALL_PROXY remains a lower-priority alternate route.
                    if (std.mem.eql(u8, key, "https_proxy")) {
                        if (firstNonEmpty(self.environ, &.{ "all_proxy", "ALL_PROXY" })) |all| {
                            if (parseProxy(allocator, all, true)) |fallback| {
                                try appendUnique(&routes, allocator, .{ .proxy = fallback, .source = .environment });
                            } else |_| {}
                        }
                        break;
                    }
                    if (std.mem.eql(u8, key, "all_proxy")) break;
                }
                // gsettings still works over SSH when libproxy cannot identify
                // the desktop and returns direct://. Keep configured manual
                // proxies ahead of that generic direct result.
                if (!shouldBypass(url, self.desktop_bypass)) {
                    for (self.desktop_routes.items) |route| try appendUnique(&routes, allocator, route);
                }
                if (if (shouldBypass(url, self.desktop_bypass)) null else self.resolver_path) |resolver| {
                    // Remove environment proxy settings only in this child,
                    // allowing libproxy to discover desktop/PAC alternatives.
                    var child_env = try cleanEnvironment(allocator, self.environ);
                    defer child_env.deinit();
                    const result = std.process.run(allocator, self.io, .{
                        .argv = &.{ resolver, url },
                        .environ_map = &child_env,
                        .stdout_limit = .limited(32768),
                        .stderr_limit = .limited(8192),
                        .timeout = deadline(self.io, 8),
                    }) catch |err| switch (err) {
                        error.Canceled, error.OutOfMemory => return err,
                        else => null,
                    };
                    if (result) |resolved| {
                        if (resolved.term.success()) {
                            try appendResolverOutput(&routes, allocator, resolved.stdout);
                        } else {
                            try status(self.io, "system proxy resolver failed; trying remaining routes", .{});
                        }
                    } else {
                        try status(self.io, "system proxy resolver unavailable or timed out; trying remaining routes", .{});
                    }
                }
                try appendUnique(&routes, allocator, .{});
            },
        }
        self.current_plan = planFingerprint(routes.items);
        // PAC can change both candidates and their order for a new URL.
        // A cached direct fallback must never override a new PAC proxy merely
        // because direct is still one of the available routes.
        if (self.preferred_plan) |previous| {
            if (std.mem.eql(u8, &previous, &self.current_plan)) preferRoute(routes.items, self.preferred);
        }
        return routes.toOwnedSlice(allocator);
    }

    pub fn download(self: *Session, tool: DownloadTool, url: []const u8, output_path: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const routes = try self.routesFor(allocator, url);
        // Attempts write to a private same-directory temporary, protecting
        // existing destinations even when all network routes fail.
        var random: [16]u8 = undefined;
        try self.io.randomSecure(&random);
        const suffix = std.fmt.bytesToHex(random, .lower);
        const temporary = try std.fmt.allocPrint(allocator, "{s}.zigup-proxy-{s}", .{ output_path, suffix[0..] });
        var probe = try Io.Dir.cwd().createFile(self.io, temporary, .{ .exclusive = true });
        probe.close(self.io);
        defer Io.Dir.cwd().deleteFile(self.io, temporary) catch {};
        for (routes) |route| {
            if (tool.kind == .wget and route.proxy != null and !wgetSupports(route.proxy.?.scheme)) {
                try status(self.io, "wget cannot use this proxy protocol; curl is required", .{});
                if (self.mode == .forced) return error.ProxyUnsupportedByDownloadTool;
                continue;
            }
            // Some downloaders do not open their output for an empty body.
            // Remove a prior route's partial bytes before every new attempt.
            var attempt_file = try Io.Dir.cwd().createFile(self.io, temporary, .{ .truncate = true });
            attempt_file.close(self.io);
            try status(self.io, "download route: {s}", .{routeLabel(route)});
            self.tryDownload(allocator, tool, route, url, temporary) catch |err| {
                if (err != error.DownloadFailed) return err;
                // Downloader error output can include proxy authentication.
                // Report only the route type; never echo the raw proxy URL.
                try status(self.io, "{s} download failed; trying next available route", .{routeLabel(route)});
                continue;
            };
            try Io.Dir.cwd().rename(temporary, Io.Dir.cwd(), output_path, self.io);
            var preferred = route;
            if (route.proxy) |proxy| {
                preferred.proxy.?.url = try self.allocator.dupe(u8, proxy.url);
            }
            self.preferred = preferred;
            self.preferred_plan = self.current_plan;
            return;
        }
        return error.DownloadFailed;
    }

    fn tryDownload(self: *Session, allocator: Allocator, tool: DownloadTool, route: Route, url: []const u8, output: []const u8) !void {
        var child_env = try cleanEnvironment(allocator, self.environ);
        defer child_env.deinit();
        if (route.proxy) |proxy| {
            // Use child-only environment values so credentials are not present
            // in process argument lists. Explicit empty no_proxy prevents a
            // downloader from silently bypassing a forced proxy.
            try child_env.put("https_proxy", proxy.url);
            try child_env.put("http_proxy", proxy.url);
            try child_env.put("all_proxy", proxy.url);
        }
        const argv: []const []const u8 = switch (tool.kind) {
            .curl => &.{
                tool.path,           "--disable",   "--fail",        "--location", "--silent",
                "--retry",           "1",           "--retry-delay", "1",          "--retry-connrefused",
                "--connect-timeout", "8",           "--speed-time",  "15",         "--speed-limit",
                "1024",              "--max-time",  "600",           "--noproxy",  if (route.proxy == null) "*" else "",
                "--proto",           "=http,https", "--proto-redir", "=https",     "--output",
                output,              "--url",       url,
            },
            .wget => &.{
                tool.path,                                                           "--no-config",         "--tries=2",         "--timeout=15",
                "--dns-timeout=8",                                                   "--connect-timeout=8", "--read-timeout=15", "--quiet",
                if (route.proxy == null) "--no-proxy" else "--execute=use_proxy=on", "--output-document",   output,              "--",
                url,
            },
        };
        const result = std.process.run(allocator, self.io, .{
            .argv = argv,
            .environ_map = &child_env,
            .stdout_limit = .limited(32768),
            .stderr_limit = .limited(32768),
            .timeout = deadline(self.io, 620),
        }) catch |err| switch (err) {
            error.Timeout => return error.DownloadFailed,
            else => return err,
        };
        switch (result.term) {
            .exited => |code| {
                if (code == 0) return;
                // Disk-write and invocation errors are not a proxy outage.
                if ((tool.kind == .curl and (code == 2 or code == 23 or code == 26 or code == 27)) or
                    (tool.kind == .wget and (code == 2 or code == 3))) return error.DownloadLocalFailure;
                return error.DownloadFailed;
            },
            else => return error.DownloadInterrupted,
        }
    }

    fn findExecutable(self: *Session, name: []const u8) !?[]const u8 {
        const result = std.process.run(self.allocator, self.io, .{
            .argv = &.{ "sh", "-c", "command -v \"$1\"", "sh", name },
            .environ_map = self.environ,
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
            .timeout = deadline(self.io, 3),
        }) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => return null,
        };
        if (!result.term.success()) return null;
        const path = std.mem.trim(u8, result.stdout, " \t\r\n");
        return if (path.len == 0) null else path;
    }

    fn gsetting(self: *Session, tool: []const u8, schema: []const u8, key: []const u8) !?[]const u8 {
        const result = std.process.run(self.allocator, self.io, .{
            .argv = &.{ tool, "get", schema, key },
            .environ_map = self.environ,
            .stdout_limit = .limited(8192),
            .stderr_limit = .limited(4096),
            .timeout = deadline(self.io, 3),
        }) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => return null,
        };
        if (!result.term.success()) return null;
        return std.mem.trim(u8, result.stdout, " \t\r\n");
    }

    fn readGnome(self: *Session) !void {
        const tool = (try self.findExecutable("gsettings")) orelse return;
        const mode = (try self.gsetting(tool, "org.gnome.system.proxy", "mode")) orelse return;
        const decoded = decodeGvariantString(self.allocator, mode) catch return;
        if (std.mem.eql(u8, decoded, "auto")) {
            if (self.resolver_path == null) {
                try status(self.io, "GNOME PAC/WPAD requires the optional libproxy 'proxy' command; trying environment/direct routes", .{});
            }
            return;
        }
        if (!std.mem.eql(u8, decoded, "manual")) return;
        if (try self.gsetting(tool, "org.gnome.system.proxy", "ignore-hosts")) |value| {
            self.desktop_bypass = decodeGvariantList(self.allocator, value) catch "";
        }
        const same = (try self.gsetting(tool, "org.gnome.system.proxy", "use-same-proxy")) orelse "false";
        const primary = if (std.mem.eql(u8, same, "true")) "org.gnome.system.proxy.http" else "org.gnome.system.proxy.https";
        try self.addGnomeProxy(tool, primary, false);
        if (self.desktop_routes.items.len == 0 and !std.mem.eql(u8, same, "true")) {
            try self.addGnomeProxy(tool, "org.gnome.system.proxy.http", false);
        }
        try self.addGnomeProxy(tool, "org.gnome.system.proxy.socks", true);
    }

    fn addGnomeProxy(self: *Session, tool: []const u8, schema: []const u8, socks: bool) !void {
        const raw_host = (try self.gsetting(tool, schema, "host")) orelse return;
        const host = decodeGvariantString(self.allocator, raw_host) catch return;
        if (host.len == 0) return;
        const raw_port = (try self.gsetting(tool, schema, "port")) orelse return;
        const port = std.fmt.parseInt(u16, raw_port, 10) catch return;
        if (port == 0) return;
        const host_literal = if (std.mem.indexOfScalar(u8, host, ':') != null and host[0] != '[')
            try std.fmt.allocPrint(self.allocator, "[{s}]", .{host})
        else
            host;
        var auth: []const u8 = "";
        if (std.mem.eql(u8, schema, "org.gnome.system.proxy.http")) {
            const enabled = (try self.gsetting(tool, schema, "use-authentication")) orelse "false";
            if (std.mem.eql(u8, enabled, "true")) {
                const raw_user = (try self.gsetting(tool, schema, "authentication-user")) orelse return;
                const raw_pass = (try self.gsetting(tool, schema, "authentication-password")) orelse return;
                const user = decodeGvariantString(self.allocator, raw_user) catch return;
                const pass = decodeGvariantString(self.allocator, raw_pass) catch return;
                auth = try std.fmt.allocPrint(self.allocator, "{s}:{s}@", .{
                    try encodeUserInfo(self.allocator, user), try encodeUserInfo(self.allocator, pass),
                });
            }
        }
        // GNOME's https key describes the destination protocol, not TLS
        // transport to the proxy. These are ordinary HTTP CONNECT proxies.
        const url = try std.fmt.allocPrint(self.allocator, "{s}://{s}{s}:{d}", .{
            if (socks) "socks5h" else "http", auth, host_literal, port,
        });
        const proxy = parseProxy(self.allocator, url, false) catch return;
        try appendUnique(&self.desktop_routes, self.allocator, .{ .proxy = proxy, .source = .gnome });
    }
};

pub fn parseMode(allocator: Allocator, input: ?[]const u8) !Mode {
    const value = std.mem.trim(u8, input orelse "auto", " \t");
    if (std.ascii.eqlIgnoreCase(value, "auto") or value.len == 0) return .auto;
    if (std.ascii.eqlIgnoreCase(value, "direct")) return .direct;
    return .{ .forced = try parseProxy(allocator, value, false) };
}

pub fn parseProxy(allocator: Allocator, input: []const u8, allow_missing_scheme: bool) !Proxy {
    const value = std.mem.trim(u8, input, " \t");
    if (value.len == 0) return error.InvalidProxy;
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f or byte == '\\') return error.InvalidProxy;
    const url = if (std.mem.indexOf(u8, value, "://") == null)
        if (allow_missing_scheme) try std.fmt.allocPrint(allocator, "http://{s}", .{value}) else return error.InvalidProxy
    else
        try allocator.dupe(u8, value);
    errdefer allocator.free(url);
    const uri = std.Uri.parse(url) catch return error.InvalidProxy;
    const scheme: Scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "socks")) .socks5h else blk: {
        inline for (.{ Scheme.http, Scheme.https, Scheme.socks4, Scheme.socks4a, Scheme.socks5, Scheme.socks5h }) |candidate| {
            if (std.ascii.eqlIgnoreCase(uri.scheme, @tagName(candidate))) break :blk candidate;
        }
        return error.InvalidProxy;
    };
    const host = componentBytes(uri.host orelse return error.InvalidProxy);
    if (host.len == 0 or uri.port == 0 or uri.query != null or uri.fragment != null) return error.InvalidProxy;
    const path = componentBytes(uri.path);
    if (path.len > 0 and !std.mem.eql(u8, path, "/")) return error.InvalidProxy;
    if (std.mem.indexOfAny(u8, host, "%@?#") != null) return error.InvalidProxy;
    if (host[0] == '[') {
        if (host[host.len - 1] != ']') return error.InvalidProxy;
        _ = Io.net.IpAddress.parse(host[1 .. host.len - 1], 0) catch return error.InvalidProxy;
    } else if (std.mem.indexOfScalar(u8, host, ':') != null) return error.InvalidProxy;
    if (uri.user) |user| if (!validPercentEncoding(componentBytes(user))) return error.InvalidProxy;
    if (uri.password) |pass| if (!validPercentEncoding(componentBytes(pass))) return error.InvalidProxy;
    // Canonical scheme/port ensures curl and wget agree on omitted ports.
    const authority_start = (std.mem.indexOf(u8, url, "://") orelse return error.InvalidProxy) + 3;
    const authority_end = authority_start + (std.mem.indexOfScalar(u8, url[authority_start..], '/') orelse (url.len - authority_start));
    const canonical = if (uri.port == null)
        try std.fmt.allocPrint(allocator, "{s}://{s}:{d}", .{ @tagName(scheme), url[authority_start..authority_end], defaultPort(scheme) })
    else
        try std.fmt.allocPrint(allocator, "{s}://{s}", .{ @tagName(scheme), url[authority_start..authority_end] });
    allocator.free(url);
    return .{ .url = canonical, .scheme = scheme };
}

pub fn shouldBypass(url: []const u8, rules: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    const raw_host = componentBytes(uri.host orelse return false);
    const host = stripHost(raw_host);
    const port = uri.port orelse if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) @as(u16, 443) else @as(u16, 80);
    var entries = std.mem.tokenizeAny(u8, rules, ",; \t\r\n");
    while (entries.next()) |entry| if (bypassEntry(host, port, entry)) return true;
    return false;
}

fn bypassEntry(host: []const u8, port: u16, input: []const u8) bool {
    if (std.mem.eql(u8, input, "*")) return true;
    if (std.ascii.eqlIgnoreCase(input, "<local>")) return std.mem.indexOfScalar(u8, host, '.') == null and std.mem.indexOfScalar(u8, host, ':') == null;
    if (std.mem.indexOfScalar(u8, input, '/')) |slash| {
        const network = Io.net.IpAddress.parse(stripHost(input[0..slash]), 0) catch return false;
        const address = Io.net.IpAddress.parse(host, 0) catch return false;
        const bits = std.fmt.parseInt(u8, input[slash + 1 ..], 10) catch return false;
        return switch (network) {
            .ip4 => |net| address == .ip4 and prefixMatches(&net.bytes, &address.ip4.bytes, bits),
            .ip6 => |net| address == .ip6 and prefixMatches(&net.bytes, &address.ip6.bytes, bits),
        };
    }
    var pattern = input;
    if (pattern.len > 0 and pattern[0] == '[') {
        const end = std.mem.indexOfScalar(u8, pattern, ']') orelse return false;
        if (end + 1 < pattern.len) {
            if (pattern[end + 1] != ':') return false;
            const expected = std.fmt.parseInt(u16, pattern[end + 2 ..], 10) catch return false;
            if (expected != port) return false;
        }
        pattern = pattern[1..end];
    } else if (std.mem.count(u8, pattern, ":") == 1) {
        const colon = std.mem.indexOfScalar(u8, pattern, ':').?;
        const expected = std.fmt.parseInt(u16, pattern[colon + 1 ..], 10) catch return false;
        if (expected != port) return false;
        pattern = pattern[0..colon];
    }
    if (Io.net.IpAddress.parse(host, 0)) |address| {
        const expected = Io.net.IpAddress.parse(pattern, 0) catch return false;
        return switch (address) {
            .ip4 => |ip| expected == .ip4 and std.mem.eql(u8, &ip.bytes, &expected.ip4.bytes),
            .ip6 => |ip| expected == .ip6 and std.mem.eql(u8, &ip.bytes, &expected.ip6.bytes),
        };
    } else |_| {}
    if (std.mem.startsWith(u8, pattern, "*.")) pattern = pattern[2..] else if (std.mem.startsWith(u8, pattern, ".")) pattern = pattern[1..];
    pattern = std.mem.trimEnd(u8, pattern, ".");
    if (pattern.len == 0 or host.len < pattern.len) return false;
    if (!std.ascii.eqlIgnoreCase(host[host.len - pattern.len ..], pattern)) return false;
    return host.len == pattern.len or host[host.len - pattern.len - 1] == '.';
}

fn prefixMatches(network: []const u8, address: []const u8, bits: u8) bool {
    if (bits > network.len * 8) return false;
    const full = bits / 8;
    if (!std.mem.eql(u8, network[0..full], address[0..full])) return false;
    const remaining: u3 = @intCast(bits % 8);
    if (remaining == 0) return true;
    const mask: u8 = @as(u8, 0xff) << @as(u3, @intCast(8 - @as(u4, remaining)));
    return network[full] & mask == address[full] & mask;
}

pub fn appendResolverOutput(routes: *std.ArrayList(Route), allocator: Allocator, output: []const u8) !void {
    var tokens = std.mem.tokenizeAny(u8, output, " \t\r\n");
    var count: usize = 0;
    while (tokens.next()) |token| {
        count += 1;
        if (count > 16) break;
        if (std.mem.eql(u8, token, "direct://")) {
            try appendUnique(routes, allocator, .{});
        } else {
            const proxy = parseProxy(allocator, token, false) catch continue;
            try appendUnique(routes, allocator, .{ .proxy = proxy, .source = .libproxy });
        }
    }
}

fn appendUnique(routes: *std.ArrayList(Route), allocator: Allocator, route: Route) !void {
    for (routes.items) |existing| if (sameRoute(existing, route)) return;
    try routes.append(allocator, route);
}

fn sameRoute(a: Route, b: Route) bool {
    if (a.proxy) |ap| return if (b.proxy) |bp| std.mem.eql(u8, ap.url, bp.url) else false;
    return b.proxy == null;
}

pub fn preferRoute(routes: []Route, preferred: ?Route) void {
    const desired = preferred orelse return;
    for (routes, 0..) |route, i| {
        if (!sameRoute(route, desired)) continue;
        std.mem.copyBackwards(Route, routes[1 .. i + 1], routes[0..i]);
        routes[0] = route;
        return;
    }
}

fn planFingerprint(routes: []const Route) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (routes) |route| {
        hash.update(@tagName(route.source));
        hash.update(&.{0});
        if (route.proxy) |proxy| hash.update(proxy.url);
        hash.update(&.{0});
    }
    var fingerprint: [32]u8 = undefined;
    hash.final(&fingerprint);
    return fingerprint;
}

pub fn cleanEnvironment(allocator: Allocator, original: *const std.process.Environ.Map) !std.process.Environ.Map {
    var result = std.process.Environ.Map.init(allocator);
    errdefer result.deinit();
    for (original.keys(), original.values()) |key, value| {
        if (std.ascii.eqlIgnoreCase(key, "http_proxy") or
            std.ascii.eqlIgnoreCase(key, "https_proxy") or
            std.ascii.eqlIgnoreCase(key, "all_proxy") or
            std.ascii.eqlIgnoreCase(key, "ftp_proxy") or
            std.ascii.eqlIgnoreCase(key, "no_proxy") or
            std.ascii.eqlIgnoreCase(key, "PX_DEBUG") or
            std.ascii.eqlIgnoreCase(key, "G_MESSAGES_DEBUG")) continue;
        try result.put(key, value);
    }
    return result;
}

pub fn decodeGvariantString(allocator: Allocator, input: []const u8) ![]const u8 {
    if (input.len < 2 or (input[0] != '\'' and input[0] != '"') or input[input.len - 1] != input[0]) return error.InvalidProxy;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 1;
    while (i < input.len - 1) : (i += 1) {
        var byte = input[i];
        if (byte == '\\') {
            i += 1;
            if (i >= input.len - 1) return error.InvalidProxy;
            byte = switch (input[i]) {
                '\\', '\'', '"' => input[i],
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => return error.InvalidProxy,
            };
        } else if (byte == input[0]) return error.InvalidProxy;
        try out.append(allocator, byte);
    }
    return out.toOwnedSlice(allocator);
}

fn decodeGvariantList(allocator: Allocator, input: []const u8) ![]const u8 {
    if (std.mem.eql(u8, input, "@as []")) return "";
    if (input.len < 2 or input[0] != '[' or input[input.len - 1] != ']') return error.InvalidProxy;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var i: usize = 1;
    while (i < input.len - 1) {
        if (std.mem.indexOfScalar(u8, " ,\t", input[i]) != null) {
            i += 1;
            continue;
        }
        const quote = input[i];
        if (quote != '\'' and quote != '"') return error.InvalidProxy;
        const start = i;
        i += 1;
        while (i < input.len - 1 and input[i] != quote) : (i += 1) {
            if (input[i] == '\\') i += 1;
        }
        if (i >= input.len - 1) return error.InvalidProxy;
        const decoded = try decodeGvariantString(allocator, input[start .. i + 1]);
        defer allocator.free(decoded);
        if (result.items.len > 0) try result.append(allocator, ',');
        try result.appendSlice(allocator, decoded);
        i += 1;
    }
    return result.toOwnedSlice(allocator);
}

fn encodeUserInfo(allocator: Allocator, value: []const u8) ![]const u8 {
    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null) {
            try encoded.append(allocator, byte);
        } else {
            try encoded.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 15] });
        }
    }
    return encoded.toOwnedSlice(allocator);
}

fn validPercentEncoding(value: []const u8) bool {
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (value[i] != '%') continue;
        if (i + 2 >= value.len or !std.ascii.isHex(value[i + 1]) or !std.ascii.isHex(value[i + 2])) return false;
        const decoded = std.fmt.parseInt(u8, value[i + 1 .. i + 3], 16) catch return false;
        if (decoded < 0x20 or decoded == 0x7f) return false;
        i += 2;
    }
    return true;
}

fn componentBytes(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw, .percent_encoded => |value| value,
    };
}

fn firstNonEmpty(environ: *const std.process.Environ.Map, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        const value = environ.get(key) orelse continue;
        if (std.mem.trim(u8, value, " \t\r\n").len > 0) return value;
    }
    return null;
}
fn stripHost(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') return value[1 .. value.len - 1];
    return std.mem.trimEnd(u8, value, ".");
}
fn defaultPort(scheme: Scheme) u16 {
    return switch (scheme) {
        .http => 80,
        .https => 443,
        else => 1080,
    };
}
pub fn wgetSupports(scheme: Scheme) bool {
    return scheme == .http;
}
fn routeLabel(route: Route) []const u8 {
    return switch (route.source) {
        .direct => "direct",
        .environment => "environment proxy",
        .gnome => "GNOME system proxy",
        .libproxy => "system/PAC proxy",
        .explicit => "explicit proxy",
    };
}
fn deadline(io: Io, seconds: i64) Io.Timeout {
    return (Io.Timeout{ .duration = .{ .raw = .fromSeconds(seconds), .clock = .awake } }).toDeadline(io);
}
fn status(io: Io, comptime format: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    try writer.interface.print("zigup: " ++ format ++ "\n", args);
    try writer.interface.flush();
}

test "proxy modes and normalized schemes are validated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(try parseMode(a, null) == .auto);
    try std.testing.expect(try parseMode(a, "DIRECT") == .direct);
    try std.testing.expectEqualStrings("http://localhost:8080", (try parseProxy(a, "localhost:8080", true)).url);
    try std.testing.expectEqualStrings("http://localhost:80", (try parseProxy(a, "HTTP://localhost/", false)).url);
    try std.testing.expectEqualStrings("socks5h://[::1]:1080", (try parseProxy(a, "socks://[::1]", false)).url);
    try std.testing.expect(try parseMode(a, "http://user:p%40ss@proxy:80") == .forced);
    for ([_][]const u8{ "localhost:8080", "file:///x", "http://", "http://host:0", "http://host/pac.js", "http://host?a=b", "http://host/#a", "http://host\n", "http://u:p%0A@host", "http://::1:80", "http://u:p%zz@host" }) |bad| {
        try std.testing.expectError(error.InvalidProxy, parseProxy(a, bad, false));
    }
}

test "NO_PROXY handles domains boundaries ports local IPv4 and IPv6 CIDR" {
    const yes = [_][2][]const u8{
        .{ "https://ziglang.org/a", "ziglang.org" },       .{ "https://cdn.ziglang.org", ".ziglang.org" },
        .{ "https://ZIGLANG.ORG./", "*.ziglang.org:443" }, .{ "http://intranet", "<local>" },
        .{ "http://127.12.1.2", "127.0.0.0/8" },           .{ "https://[::1]/", "[::1]:443" },
        .{ "https://[2001:db8::12]/", "2001:db8::/32" },   .{ "http://anything", "*" },
    };
    for (yes) |pair| try std.testing.expect(shouldBypass(pair[0], pair[1]));
    const no = [_][2][]const u8{
        .{ "https://evilziglang.org", "ziglang.org" }, .{ "https://ziglang.org", "ziglang.org:80" },
        .{ "http://128.0.0.1", "127.0.0.0/8" },        .{ "http://127.0.0.1", "0.0.1" },
        .{ "https://[2001:db9::1]", "2001:db8::/32" }, .{ "http://local.example", "<local>" },
    };
    for (no) |pair| try std.testing.expect(!shouldBypass(pair[0], pair[1]));
}

test "GVariant manual settings parse without evaluating shell text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("it's a $proxy", try decodeGvariantString(a, "'it\\'s a $proxy'"));
    try std.testing.expectEqualStrings("localhost,127.0.0.0/8,::1", try decodeGvariantList(a, "['localhost', '127.0.0.0/8', '::1']"));
    try std.testing.expectEqualStrings("user%3Aa%40b%25", try encodeUserInfo(a, "user:a@b%"));
    try std.testing.expectError(error.InvalidProxy, decodeGvariantString(a, "'broken"));
}

test "resolver candidates are validated deduplicated and sticky routes remain applicable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var routes: std.ArrayList(Route) = .empty;
    try appendResolverOutput(&routes, a, "http://one:80 socks5://two:1080 direct:// http://one:80 file:///bad");
    try std.testing.expectEqual(@as(usize, 3), routes.items.len);
    preferRoute(routes.items, routes.items[1]);
    try std.testing.expectEqualStrings("socks5://two:1080", routes.items[0].proxy.?.url);
    const before = routes.items[0];
    preferRoute(routes.items, .{ .proxy = try parseProxy(a, "http://other:80", false) });
    try std.testing.expect(sameRoute(before, routes.items[0]));
    try std.testing.expect(wgetSupports(.http));
    try std.testing.expect(!wgetSupports(.https));
    try std.testing.expect(!wgetSupports(.socks5h));
}

test "child environment clearing cannot mutate parent proxy settings" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("https_proxy", "http://secret:pass@host:80");
    try env.put("NO_PROXY", "*");
    try env.put("PATH", "/usr/bin");
    var clean = try cleanEnvironment(std.testing.allocator, &env);
    defer clean.deinit();
    try std.testing.expect(clean.get("https_proxy") == null);
    try std.testing.expect(clean.get("NO_PROXY") == null);
    try std.testing.expectEqualStrings("/usr/bin", clean.get("PATH").?);
    try std.testing.expect(env.get("https_proxy") != null);
}

test "automatic routes respect environment priority bypass and direct fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("https_proxy", "http://primary:8080");
    try env.put("all_proxy", "socks5h://alternate:1080");
    var session: Session = .{ .allocator = a, .io = undefined, .environ = &env, .mode = .auto, .no_proxy = "" };
    const routes = try session.routesFor(a, "https://ziglang.org/download/index.json");
    try std.testing.expectEqual(@as(usize, 3), routes.len);
    try std.testing.expectEqualStrings("http://primary:8080", routes[0].proxy.?.url);
    try std.testing.expectEqualStrings("socks5h://alternate:1080", routes[1].proxy.?.url);
    try std.testing.expect(routes[2].proxy == null);
    session.no_proxy = "ziglang.org";
    const bypass = try session.routesFor(a, "https://ziglang.org/download/index.json");
    try std.testing.expectEqual(@as(usize, 1), bypass.len);
    try std.testing.expect(bypass[0].proxy == null);
}

test "direct mode disables discovery and explicit proxy cannot be bypassed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("https_proxy", "http://environment:8080");
    var session: Session = .{ .allocator = a, .io = undefined, .environ = &env, .mode = .direct, .no_proxy = "*", .resolver_path = "/must/not/run" };
    const direct = try session.routesFor(a, "https://ziglang.org");
    try std.testing.expectEqual(@as(usize, 1), direct.len);
    try std.testing.expect(direct[0].proxy == null);
    session.mode = try parseMode(a, "http://explicit:8080");
    const forced = try session.routesFor(a, "https://ziglang.org");
    try std.testing.expectEqual(@as(usize, 1), forced.len);
    try std.testing.expectEqualStrings("http://explicit:8080", forced[0].proxy.?.url);
    try std.testing.expectError(error.InvalidDownloadUrl, session.routesFor(a, "file:///etc/passwd"));
    try std.testing.expectError(error.InvalidDownloadUrl, session.routesFor(a, "https://user:password@ziglang.org"));
}

test "manual desktop bypass does not override environment proxy and routes are sticky" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("https_proxy", "http://environment:8080");
    var session: Session = .{ .allocator = a, .io = undefined, .environ = &env, .mode = .auto, .no_proxy = "", .desktop_bypass = "ziglang.org" };
    const desktop: Route = .{ .proxy = try parseProxy(a, "http://desktop:8080", false), .source = .gnome };
    try session.desktop_routes.append(a, desktop);
    session.preferred = desktop;
    const bypass = try session.routesFor(a, "https://ziglang.org/a");
    try std.testing.expectEqual(@as(usize, 2), bypass.len);
    try std.testing.expectEqualStrings("http://environment:8080", bypass[0].proxy.?.url);
    const unpreferred = try session.routesFor(a, "https://other.example/a");
    session.preferred_plan = planFingerprint(unpreferred);
    const sticky = try session.routesFor(a, "https://other.example/a");
    try std.testing.expectEqualStrings("http://desktop:8080", sticky[0].proxy.?.url);
}

test "empty lowercase bypass uses uppercase and ordinary missing ports are explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Environment maps are case-insensitive on Windows; test the fallback
    // helper with distinct keys there, and actual environment keys on Linux.
    var env = std.process.Environ.Map.init(a);
    try env.put("first", " ");
    try env.put("second", "example.org");
    try std.testing.expectEqualStrings("example.org", firstNonEmpty(&env, &.{ "first", "second" }).?);
    try std.testing.expectEqualStrings("https://proxy:443", (try parseProxy(a, "https://proxy", false)).url);
    try std.testing.expectEqualStrings("socks5h://proxy:1080", (try parseProxy(a, "socks5h://proxy", false)).url);
}

test "Linux lowercase environment wins and empty lowercase falls back uppercase" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("https_proxy", "http://lowercase:80");
    try env.put("HTTPS_PROXY", "http://uppercase:80");
    try env.put("all_proxy", " ");
    try env.put("ALL_PROXY", "socks5h://fallback:1080");
    var session: Session = .{ .allocator = a, .io = undefined, .environ = &env, .mode = .auto, .no_proxy = "" };
    const first = try session.routesFor(a, "https://ziglang.org");
    try std.testing.expectEqual(@as(usize, 3), first.len);
    try std.testing.expectEqualStrings("http://lowercase:80", first[0].proxy.?.url);
    try std.testing.expectEqualStrings("socks5h://fallback:1080", first[1].proxy.?.url);
    try env.put("https_proxy", "");
    const fallback = try session.routesFor(a, "https://ziglang.org");
    try std.testing.expectEqualStrings("http://uppercase:80", fallback[0].proxy.?.url);
    try env.put("no_proxy", "");
    try env.put("NO_PROXY", "*");
    try std.testing.expectEqualStrings("*", firstNonEmpty(&env, &.{ "no_proxy", "NO_PROXY" }).?);
}

test "sticky direct is not promoted when PAC or system route plans change" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    var session: Session = .{ .allocator = a, .io = undefined, .environ = &env, .mode = .auto, .no_proxy = "" };
    const initial = try session.routesFor(a, "https://ziglang.org/index.json");
    session.preferred = initial[0];
    session.preferred_plan = session.current_plan;
    const added: Route = .{ .proxy = try parseProxy(a, "http://new-pac-proxy:80", false), .source = .libproxy };
    try session.desktop_routes.append(a, added);
    const changed = try session.routesFor(a, "https://ziglang.org/archive");
    try std.testing.expect(changed[0].proxy != null);
    session.preferred = changed[0];
    session.preferred_plan = session.current_plan;
    session.desktop_routes.clearRetainingCapacity();
    const direct = try session.routesFor(a, "https://ziglang.org/direct");
    try std.testing.expectEqual(@as(usize, 1), direct.len);
    try std.testing.expect(direct[0].proxy == null);
    var reordered = [_]Route{ added, .{} };
    const one = planFingerprint(&reordered);
    std.mem.swap(Route, &reordered[0], &reordered[1]);
    const two = planFingerprint(&reordered);
    try std.testing.expect(!std.mem.eql(u8, &one, &two));
}
