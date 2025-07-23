const std = @import("std");
const clap = @import("clap");

/// Common argument parsing helpers using zig-clap
pub const Args = struct {
    /// Parse arguments for utilities that follow GNU conventions
    pub fn parseGnu(
        comptime Id: type,
        comptime params: []const clap.Param(Id),
        allocator: std.mem.Allocator,
    ) !clap.Result(Id, clap.parsers.default) {
        // GNU utilities support -- to stop parsing flags
        var iter = try std.process.ArgIterator.initWithAllocator(allocator);
        defer iter.deinit();

        // Skip program name
        _ = iter.next();

        return clap.parse(Id, params, clap.parsers.default, .{
            .allocator = allocator,
            .diagnostic = null,
        }) catch |err| {
            // Handle common parsing errors
            switch (err) {
                error.InvalidArgument => {
                    std.debug.print("Invalid argument\n", .{});
                    std.process.exit(1);
                },
                else => return err,
            }
        };
    }

    /// Generate help text in GNU style
    pub fn help(
        comptime params: []const clap.Param(clap.Help),
        prog_name: []const u8,
        description: []const u8,
        writer: anytype,
    ) !void {
        try writer.print("Usage: {s} [OPTION]...\n", .{prog_name});
        try writer.print("{s}\n\n", .{description});
        try clap.help(writer, clap.Help, params, .{});
    }
};

/// Example of how to define parameters for a utility
pub const ExampleParams = [_]clap.Param(clap.Help){
    clap.parseParam("-h, --help     Display this help and exit") catch unreachable,
    clap.parseParam("-V, --version  Output version information and exit") catch unreachable,
    clap.parseParam("-n, --number <NUM>  An option parameter") catch unreachable,
};
