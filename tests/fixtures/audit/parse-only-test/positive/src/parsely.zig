//! parsely - fixture utility whose only test asserts the parse result.
//!
//! `show_tabs` appears exactly twice: the parse-site write, and a test block
//! asserting `parsed.opts.show_tabs`. No behaviour is pinned, so the flag can
//! be a no-op forever. It is therefore also a stub-flag; the two checks
//! deliberately overlap on this fixture and the suite scopes with --check.

const std = @import("std");
const testing = std.testing;

const ParselyArgs = struct {
    help: bool = false,
    show_tabs: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "display this help and exit" },
        .show_tabs = .{ .short = 'T', .desc = "display TAB characters as ^I" },
    };
};

const Parsed = struct {
    opts: ParselyArgs,
};

fn parseArgs(args: []const []const u8) Parsed {
    var opts = ParselyArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h")) opts.help = true;
        if (std.mem.eql(u8, arg, "-T")) opts.show_tabs = true;
    }
    return .{ .opts = opts };
}

pub fn runParsely(args: []const []const u8, writer: *std.Io.Writer) !u8 {
    const opts = parseArgs(args).opts;
    if (opts.help) {
        try writer.writeAll("usage: parsely [-T]\n");
        return 0;
    }
    try writer.writeAll("parsely\n");
    return 0;
}

test "parseArgs sets show_tabs for -T" {
    const parsed = parseArgs(&.{"-T"});
    try testing.expect(parsed.opts.show_tabs);
}
