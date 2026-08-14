//! shadowly - fixture utility with a clean parser.
//!
//! Any finding over this tree comes from the shell test file.

const std = @import("std");

const ShadowlyArgs = struct {
    help: bool = false,
    verbose: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "display this help and exit" },
        .verbose = .{ .short = 'v', .desc = "explain what is being done" },
    };
};

pub fn runShadowly(args: []const []const u8, writer: *std.Io.Writer) !u8 {
    var opts = ShadowlyArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h")) opts.help = true;
        if (std.mem.eql(u8, arg, "-v")) opts.verbose = true;
    }
    if (opts.help) {
        try writer.writeAll("usage: shadowly [-v]\n");
        return 0;
    }
    if (opts.verbose) {
        try writer.writeAll("shadowly (verbose)\n");
        return 0;
    }
    try writer.writeAll("shadowly\n");
    return 0;
}
