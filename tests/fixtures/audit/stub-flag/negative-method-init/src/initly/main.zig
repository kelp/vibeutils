//! initly - live_flag is argparse-filled and read only inside a method
//! whose signature is split across lines, with `{` on a later line.
//!
//! classify() currently sets in_sfn on `fn init(` and clears it on the
//! same line when that line has no `{`, so the method body is STRUCT_SKIP'd
//! and the production read is invisible. That is a false stub-flag.

const std = @import("std");

const PlantedArgs = struct {
    help: bool = false,
    live_flag: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "display this help and exit" },
        .live_flag = .{ .long = "live-flag", .desc = "read only inside PlantedOptions.init" },
    };
};

const PlantedOptions = struct {
    pub fn init(
        opts: PlantedArgs,
        writer: *std.Io.Writer,
    ) !void {
        if (opts.live_flag) try writer.writeAll("live\n");
    }
};

pub fn runInitly(args: []const []const u8, writer: *std.Io.Writer) !u8 {
    _ = args;
    const opts = PlantedArgs{};
    if (opts.help) {
        try writer.writeAll("usage: initly [--live-flag]\n");
        return 0;
    }
    try PlantedOptions.init(opts, writer);
    try writer.writeAll("initly\n");
    return 0;
}
