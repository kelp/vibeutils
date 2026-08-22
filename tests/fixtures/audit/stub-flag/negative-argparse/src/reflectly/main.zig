//! reflectly - argparse-shaped fixture: flags are filled reflectively.
//!
//! There is no `opts.unused_flag =` write anywhere in production. The field
//! is declared on the Args struct and in `meta`, which is how argparse
//! populates it. Nothing reads it, so it is a stub-flag. A scanner that
//! requires W[f] > 0 never sees it.

const std = @import("std");
const helper = @import("helper.zig");

pub const ReflectlyArgs = struct {
    help: bool = false,
    unused_flag: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "display this help and exit" },
        .unused_flag = .{ .long = "unused-flag", .desc = "planted argparse stub flag" },
    };
};

pub fn runReflectly(args: []const []const u8, writer: *std.Io.Writer) !u8 {
    _ = args;
    // Argparse would fill this struct reflectively. There is no parse-site
    // write of unused_flag, which is the shape the stub-flag check misses.
    const opts = ReflectlyArgs{};
    if (opts.help) {
        try writer.writeAll("usage: reflectly [--unused-flag]\n");
        return 0;
    }
    try helper.emitName(opts, writer);
    return 0;
}
