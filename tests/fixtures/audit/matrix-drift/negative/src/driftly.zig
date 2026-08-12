//! driftly - fixture utility whose parser is clean.
//!
//! Every field is written and read, so any finding over this tree comes from
//! the flag matrix, not from the source.

const std = @import("std");

const DriftlyArgs = struct {
    help: bool = false,
    all: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "display this help and exit" },
        .all = .{ .short = 'a', .desc = "show all entries" },
    };
};

pub fn runDriftly(args: []const []const u8, writer: *std.Io.Writer) !u8 {
    var opts = DriftlyArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h")) opts.help = true;
        if (std.mem.eql(u8, arg, "-a")) opts.all = true;
    }
    if (opts.help) {
        try writer.writeAll("usage: driftly [-a]\n");
        return 0;
    }
    if (opts.all) {
        try writer.writeAll("all\n");
        return 0;
    }
    try writer.writeAll("driftly\n");
    return 0;
}
