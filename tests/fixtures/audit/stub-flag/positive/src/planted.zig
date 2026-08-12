//! planted - fixture utility carrying exactly one unread flag.
//!
//! `unused_flag` is written at the parse site and never read afterwards,
//! which is the stub-flag defect class. Everything else here is clean, so a
//! run over this tree must report exactly one finding.

const std = @import("std");

const PlantedArgs = struct {
    help: bool = false,
    unused_flag: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "display this help and exit" },
        .unused_flag = .{ .long = "unused-flag", .desc = "planted stub flag" },
    };
};

pub fn runPlanted(args: []const []const u8, writer: *std.Io.Writer) !u8 {
    var opts = PlantedArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h")) opts.help = true;
        if (std.mem.eql(u8, arg, "--unused-flag")) opts.unused_flag = true;
    }
    if (opts.help) {
        try writer.writeAll("usage: planted [--unused-flag]\n");
        return 0;
    }
    try writer.writeAll("planted\n");
    return 0;
}
