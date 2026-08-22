//! Non-entry-point sibling of src/reflectly/main.zig.
//!
//! Receives the argparse-populated options so a production read of
//! unused_flag can be planted here without adding an explicit write.

const std = @import("std");
const main = @import("main.zig");

pub fn emitName(opts: main.ReflectlyArgs, writer: *std.Io.Writer) !void {
    _ = opts;
    try writer.writeAll("reflectly\n");
}
