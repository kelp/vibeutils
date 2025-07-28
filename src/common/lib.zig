const std = @import("std");
const build_options = @import("build_options");

/// Common functionality for all vibeutils
pub const style = @import("style.zig");
pub const args = @import("args.zig");
pub const file = @import("file.zig");
pub const terminal = @import("terminal.zig");
pub const test_utils = @import("test_utils.zig");
pub const constants = @import("constants.zig");
pub const directory = @import("directory.zig");
pub const icons = @import("icons.zig");
pub const relative_date = @import("relative_date.zig");
pub const git = @import("git.zig");
pub const user_group = @import("user_group.zig");
pub const privilege_test = @import("privilege_test.zig");

/// Version information from build options
pub const version = build_options.version;
pub const name = "vibeutils";

/// Common error types
pub const Error = error{
    ArgumentError,
    FileNotFound,
    PermissionDenied,
    InvalidInput,
    OutputError,
};

/// Standard exit codes
pub const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    misuse = 2,
};

/// Print error message to stderr and exit
pub fn fatal(comptime fmt: []const u8, fmt_args: anytype) noreturn {
    const stderr = std.io.getStdErr().writer();
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));
    stderr.print("{s}: " ++ fmt ++ "\n", .{prog_name} ++ fmt_args) catch {};
    std.process.exit(@intFromEnum(ExitCode.general_error));
}

/// Print error message to stderr
pub fn printError(comptime fmt: []const u8, fmt_args: anytype) void {
    const stderr = std.io.getStdErr().writer();
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

    // Try to use color for errors
    const StyleType = style.Style(@TypeOf(stderr));
    var s = StyleType.init(stderr);
    s.setColor(.bright_red) catch {};
    stderr.print("{s}: ", .{prog_name}) catch return;
    s.reset() catch {};
    stderr.print(fmt ++ "\n", fmt_args) catch return;
}

/// Common command line options
pub const CommonOpts = struct {
    help: bool = false,
    version: bool = false,

    /// Print help message
    pub fn printHelp(comptime usage: []const u8, comptime description: []const u8) void {
        const stdout = std.io.getStdOut().writer();
        const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

        stdout.print("Usage: {s} {s}\n\n", .{ prog_name, usage }) catch return;
        stdout.print("{s}\n", .{description}) catch return;
    }

    /// Print version
    pub fn printVersion() void {
        const stdout = std.io.getStdOut().writer();
        const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));
        stdout.print("{s} ({s}) {s}\n", .{ prog_name, name, version }) catch return;
    }
};

test "common library basics" {
    // Test that we can import and use basic functionality
    const ec = ExitCode.success;
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(ec));
}
