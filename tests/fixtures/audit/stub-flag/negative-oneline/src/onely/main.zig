//! onely - argparse-shaped fixture whose stub sits after a one-line method.
//!
//! `unread_flag` is declared AFTER `pub fn ping() void {}` in the same
//! Args struct. classify() currently sets in_sfn on that method and never
//! clears it, because the braces net to zero so sfn_entered stays unset.
//! The planted stub is then invisible: it is not harvested into FIELD[]
//! and later declaration spans stop being STRUCT_SKIP'd.

const std = @import("std");
const helper = @import("helper.zig");

pub const OnelyArgs = struct {
    help: bool = false,
    pub fn ping() void {}
    unread_flag: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "display this help and exit" },
        .unread_flag = .{ .long = "unread-flag", .desc = "planted stub after a one-line method" },
    };
};

pub fn runOnely(args: []const []const u8, writer: *std.Io.Writer) !u8 {
    _ = args;
    // Argparse would fill this struct reflectively. There is no parse-site
    // write of unread_flag. A scanner that never harvests fields after a
    // one-line method never sees the planted stub.
    const opts = OnelyArgs{};
    if (opts.help) {
        try writer.writeAll("usage: onely [--unread-flag]\n");
        return 0;
    }
    try helper.emitName(opts, writer);
    return 0;
}
