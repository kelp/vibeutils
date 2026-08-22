//! splitly - multi-file fixture whose entry point is src/splitly/main.zig.
//!
//! `live_flag` is written here and read in helper.zig. Unit-scope counting
//! must see that read; a per-file scan of this file alone reports a stub.
//! `hiddenHelper` lives in helper.zig and is not referenced from here.

const std = @import("std");
const helper = @import("helper.zig");

pub const SplitlyArgs = struct {
    help: bool = false,
    live_flag: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "display this help and exit" },
        .live_flag = .{ .long = "live-flag", .desc = "written here, read in helper.zig" },
    };
};

pub fn runSplitly(args: []const []const u8, writer: *std.Io.Writer) !u8 {
    var opts = SplitlyArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h")) opts.help = true;
        if (std.mem.eql(u8, arg, "--live-flag")) opts.live_flag = true;
    }
    if (opts.help) {
        try writer.writeAll("usage: splitly [--live-flag]\n");
        return 0;
    }
    try helper.emitLive(opts, writer);
    try writer.writeAll("splitly\n");
    return 0;
}
