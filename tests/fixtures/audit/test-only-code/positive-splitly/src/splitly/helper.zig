//! Non-entry-point sibling of src/splitly/main.zig.
//!
//! `hiddenHelper` is private and every call site is inside a test block,
//! which is the test-only-code defect class — but this file is not the
//! manifest path, so a scanner that only opens main.zig never sees it.
//! `opts.live_flag` is read here; that is a real production use.

const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");

pub fn emitLive(opts: main.SplitlyArgs, writer: *std.Io.Writer) !void {
    if (opts.live_flag) try writer.writeAll("live\n");
}

fn hiddenHelper(n: u32) u32 {
    return n * 2;
}

test "hiddenHelper doubles its argument" {
    try testing.expectEqual(@as(u32, 4), hiddenHelper(2));
}
