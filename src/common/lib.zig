//! Common library for vibeutils - Modern Zig implementation of GNU coreutils
//!
//! This module provides shared functionality used across all vibeutils utilities,
//! including terminal styling, argument parsing, file operations, and more.
//!
//! The library follows OpenBSD principles of correctness and simplicity while
//! adding modern UX enhancements like colors, icons, and progress indicators.

const std = @import("std");
const build_options = @import("build_options");

/// Terminal styling and color detection functionality
pub const style = @import("style.zig");

/// Command-line argument parsing utilities
pub const args = @import("args.zig");

/// File operation helpers with enhanced error handling
pub const file = @import("file.zig");

/// Terminal capability detection (color support, unicode, etc.)
pub const terminal = @import("terminal.zig");

/// Testing utilities for consistent test patterns
pub const test_utils = @import("test_utils.zig");

/// Common constants used across utilities
pub const constants = @import("constants.zig");

/// Directory traversal and listing utilities
pub const directory = @import("directory.zig");

/// File type icons for enhanced terminal output
pub const icons = @import("icons.zig");

/// Human-friendly relative date formatting
pub const relative_date = @import("relative_date.zig");

/// Git repository detection and status
pub const git = @import("git.zig");

/// User and group information utilities
pub const user_group = @import("user_group.zig");

/// Advanced argument parsing with GNU-style support
pub const argparse = @import("argparse.zig");

/// Privilege testing framework for operations requiring elevated permissions
pub const privilege_test = @import("privilege_test.zig");

/// Testing utilities specifically for privilege-related tests
pub const test_utils_privilege = @import("test_utils_privilege.zig");

/// File operation helpers with platform-specific workarounds
pub const file_ops = @import("file_ops.zig");

/// Version information from build configuration
pub const version = build_options.version;

/// Name of the utility suite
pub const name = "vibeutils";

/// Common error types used throughout vibeutils
pub const Error = error{
    /// Invalid command-line arguments were provided
    ArgumentError,
    /// Requested file could not be found
    FileNotFound,
    /// Operation requires permissions not available to the current user
    PermissionDenied,
    /// Input data is malformed or invalid
    InvalidInput,
    /// Error occurred while writing output
    OutputError,
};

/// Standard exit codes following POSIX conventions
pub const ExitCode = enum(u8) {
    /// Successful termination
    success = 0,
    /// General errors (catch-all for miscellaneous errors)
    general_error = 1,
    /// Misuse of shell builtins (missing arguments, etc.)
    misuse = 2,
};

/// Print error message to stderr and exit with error code
///
/// This function formats an error message with the program name prefix,
/// prints it to stderr, and exits with a general error code.
///
/// Example:
/// ```zig
/// common.fatal("cannot open file: {s}", .{filename});
/// // Output: myprogram: cannot open file: test.txt
/// ```
pub fn fatal(comptime fmt: []const u8, fmt_args: anytype) noreturn {
    const stderr = std.io.getStdErr().writer();
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));
    stderr.print("{s}: " ++ fmt ++ "\n", .{prog_name} ++ fmt_args) catch {};
    std.process.exit(@intFromEnum(ExitCode.general_error));
}

/// Print error message to stderr without exiting
///
/// Similar to fatal() but allows the program to continue execution.
/// Useful for non-fatal warnings or when handling multiple errors.
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

/// Print warning message to stderr without exiting
///
/// Used for non-fatal issues that should be reported but don't stop execution.
/// Warnings are displayed in yellow to distinguish them from errors.
pub fn printWarning(comptime fmt: []const u8, fmt_args: anytype) void {
    const stderr = std.io.getStdErr().writer();
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

    // Try to use color for warnings
    const StyleType = style.Style(@TypeOf(stderr));
    var s = StyleType.init(stderr);
    s.setColor(.bright_yellow) catch {};
    stderr.print("{s}: warning: ", .{prog_name}) catch return;
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
