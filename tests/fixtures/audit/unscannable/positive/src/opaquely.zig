//! opaquely - fixture utility that parses argv without an options struct.
//!
//! There is no `const <Name>Args = struct` to brace-match, so no field table
//! can be built. The unit must be reported unscannable rather than silently
//! counted as clean -- it takes flags, so "no findings" would be a lie.

const std = @import("std");

pub fn runOpaquely(args: []const []const u8, writer: *std.Io.Writer) !u8 {
    var verbose = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h")) {
            try writer.writeAll("usage: opaquely [-v]\n");
            return 0;
        }
        if (std.mem.eql(u8, arg, "-v")) verbose = true;
    }
    if (verbose) {
        try writer.writeAll("opaquely (verbose)\n");
        return 0;
    }
    try writer.writeAll("opaquely\n");
    return 0;
}
