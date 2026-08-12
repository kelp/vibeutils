//! deadly - fixture utility whose helper is reachable only from a test.
//!
//! `doubleWidth` is private and every call site is inside a test block, which
//! is the test-only-code defect class.

const std = @import("std");
const testing = std.testing;

const DeadlyArgs = struct {
    help: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "display this help and exit" },
    };
};

fn doubleWidth(n: u32) u32 {
    return n * 2;
}

pub fn runDeadly(args: []const []const u8, writer: *std.Io.Writer) !u8 {
    var opts = DeadlyArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h")) opts.help = true;
    }
    if (opts.help) {
        try writer.writeAll("usage: deadly\n");
        return 0;
    }
    try writer.writeAll("deadly\n");
    if (doubleWidth(1) == 2) try writer.writeAll("live\n");
    return 0;
}

test "doubleWidth doubles its argument" {
    try testing.expectEqual(@as(u32, 4), doubleWidth(2));
}
