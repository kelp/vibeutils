//! longly - argparse-shaped fixture whose stub uses the house long-only meta.
//!
//! `unread_flag` is declared with `.short = 0` and no `.long`. That is how
//! this repo spells a long-only flag (chmod's `.no_preserve_root`, ls
//! `--help`). Nothing writes `opts.unread_flag =` and nothing reads it.
//! A scanner that only treats `.short = 'x'` or `.long = "..."` as
//! argparse writes never sees it.

const std = @import("std");
const helper = @import("helper.zig");

pub const LonglyArgs = struct {
    help: bool = false,
    unread_flag: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "display this help and exit" },
        .unread_flag = .{ .short = 0, .desc = "planted long-only stub" },
    };
};

pub fn runLongly(args: []const []const u8, writer: *std.Io.Writer) !u8 {
    _ = args;
    // Argparse would fill this struct reflectively. There is no parse-site
    // write of unread_flag, which is the shape the stub-flag check misses
    // when it requires a character `.short` or an explicit `.long`.
    const opts = LonglyArgs{};
    if (opts.help) {
        try writer.writeAll("usage: longly [--unread-flag]\n");
        return 0;
    }
    try helper.emitName(opts, writer);
    return 0;
}
