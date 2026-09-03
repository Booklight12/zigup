//! Test-only entry point for exercising the actual Linux download layer.
const std = @import("std");
const proxy = @import("proxy");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 5 or (args.len - 3) % 2 != 0) return error.InvalidArguments;
    const tool: proxy.DownloadTool = .{
        .kind = if (std.mem.eql(u8, args[1], "curl")) .curl else if (std.mem.eql(u8, args[1], "wget")) .wget else return error.InvalidArguments,
        .path = args[2],
    };
    var session = try proxy.Session.init(allocator, init.io, init.environ_map);
    var index: usize = 3;
    while (index < args.len) : (index += 2) {
        session.download(tool, args[index], args[index + 1]) catch |err| {
            var buffer: [512]u8 = undefined;
            var writer: std.Io.File.Writer = .init(.stderr(), init.io, &buffer);
            try writer.interface.print("proxy-test: {s}\n", .{@errorName(err)});
            try writer.interface.flush();
            std.process.exit(1);
        };
    }
}
