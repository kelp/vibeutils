//! opaquely - the scannable counterpart: the same utility with an options
//! struct and an `opts` receiver, so the field table can be built.
//!
//! The one-added-line discipline used by the other fixture pairs is not
//! achievable here: the defect is the absence of a multi-line declaration,
//! so the pair differs by the whole struct plus its receiver. The suite
//! asserts instead that nothing outside src/opaquely.zig differs.

const std = @import("std");

const OpaquelyArgs = struct {
    help: bool = false,
    verbose: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "display this help and exit" },
        .verbose = .{ .short = 'v', .desc = "explain what is being done" },
    };
};

pub fn runOpaquely(args: []const []const u8, writer: *std.Io.Writer) !u8 {
    var opts = OpaquelyArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h")) opts.help = true;
        if (std.mem.eql(u8, arg, "-v")) opts.verbose = true;
    }
    if (opts.help) {
        try writer.writeAll("usage: opaquely [-v]\n");
        return 0;
    }
    if (opts.verbose) {
        try writer.writeAll("opaquely (verbose)\n");
        return 0;
    }
    try writer.writeAll("opaquely\n");
    return 0;
}
