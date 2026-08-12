//! toothy - fixture utility with a clean parser.
//!
//! Any finding over this tree comes from the shell test file.

const std = @import("std");

const ToothyArgs = struct {
    help: bool = false,
    verbose: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "display this help and exit" },
        .verbose = .{ .short = 'v', .desc = "explain what is being done" },
    };
};

pub fn runToothy(args: []const []const u8, writer: *std.Io.Writer) !u8 {
    var opts = ToothyArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h")) opts.help = true;
        if (std.mem.eql(u8, arg, "-v")) opts.verbose = true;
    }
    if (opts.help) {
        try writer.writeAll("usage: toothy [-v]\n");
        return 0;
    }
    if (opts.verbose) {
        try writer.writeAll("toothy (verbose)\n");
        return 0;
    }
    try writer.writeAll("toothy\n");
    return 0;
}
