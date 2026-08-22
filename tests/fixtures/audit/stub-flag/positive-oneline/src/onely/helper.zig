//! Non-entry-point sibling of src/onely/main.zig.
//!
//! Receives the argparse-populated options so a production read of
//! unread_flag can be planted here without adding an explicit write.

const std = @import("std");
const main = @import("main.zig");

pub fn emitName(opts: main.OnelyArgs, writer: *std.Io.Writer) !void {
    _ = opts;
    try writer.writeAll("onely\n");
}
