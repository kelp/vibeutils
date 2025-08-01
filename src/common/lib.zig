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

/// Null writer for suppressing output (commonly used in tests)
pub const null_writer = std.io.null_writer;

/// Get the standard error writer
pub fn getStderrWriter() @TypeOf(std.io.getStdErr().writer()) {
    return std.io.getStdErr().writer();
}

/// Get the standard output writer
pub fn getStdoutWriter() @TypeOf(std.io.getStdOut().writer()) {
    return std.io.getStdOut().writer();
}

/// Get a null writer that discards all output
pub fn getNullWriter() @TypeOf(std.io.null_writer) {
    return std.io.null_writer;
}

/// DEPRECATED: Use fatalWithWriter() instead
/// This function will be removed in a future version
pub fn fatal(comptime fmt: []const u8, fmt_args: anytype) noreturn {
    _ = fmt;
    _ = fmt_args;
    @compileError("fatal() is deprecated - use fatalWithWriter() with explicit stderr writer instead");
}

/// Print error message to stderr writer and exit with error code
///
/// This function formats an error message with the program name prefix,
/// prints it to the provided stderr writer, and exits with a general error code.
///
/// Example:
/// ```zig
/// const stderr = std.io.getStdErr().writer();
/// common.fatalWithWriter(stderr, "cannot open file: {s}", .{filename});
/// // Output: myprogram: cannot open file: test.txt
/// ```
pub fn fatalWithWriter(stderr_writer: anytype, comptime fmt: []const u8, fmt_args: anytype) noreturn {
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));
    stderr_writer.print("{s}: " ++ fmt ++ "\n", .{prog_name} ++ fmt_args) catch {};
    std.process.exit(@intFromEnum(ExitCode.general_error));
}

/// DEPRECATED: Use printErrorWithWriter() instead
/// This function will be removed in a future version
pub fn printError(comptime fmt: []const u8, fmt_args: anytype) void {
    _ = fmt;
    _ = fmt_args;
    @compileError("printError() is deprecated - use printErrorWithWriter() with explicit stderr writer instead");
}

/// Print error message to stderr writer without exiting
///
/// Similar to fatalWithWriter() but allows the program to continue execution.
/// Useful for non-fatal warnings or when handling multiple errors.
pub fn printErrorWithWriter(stderr_writer: anytype, comptime fmt: []const u8, fmt_args: anytype) void {
    printErrorTo(stderr_writer, fmt, fmt_args);
}

/// Print error message to a specific writer without exiting
///
/// Like printError() but allows specifying the writer to use.
/// Useful for testing or when redirecting error output.
pub fn printErrorTo(writer: anytype, comptime fmt: []const u8, fmt_args: anytype) void {
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

    // Try to use color for errors
    const StyleType = style.Style(@TypeOf(writer));
    var s = StyleType.init(writer);
    s.setColor(.bright_red) catch {};
    writer.print("{s}: ", .{prog_name}) catch return;
    s.reset() catch {};
    writer.print(fmt ++ "\n", fmt_args) catch return;
}

/// DEPRECATED: Use printWarningWithWriter() instead
/// This function will be removed in a future version
pub fn printWarning(comptime fmt: []const u8, fmt_args: anytype) void {
    _ = fmt;
    _ = fmt_args;
    @compileError("printWarning() is deprecated - use printWarningWithWriter() with explicit stderr writer instead");
}

/// Print warning message to stderr writer without exiting
///
/// Used for non-fatal issues that should be reported but don't stop execution.
/// Warnings are displayed in yellow to distinguish them from errors.
pub fn printWarningWithWriter(stderr_writer: anytype, comptime fmt: []const u8, fmt_args: anytype) void {
    printWarningTo(stderr_writer, fmt, fmt_args);
}

/// Print warning message to a specific writer
///
/// Used for non-fatal issues that should be reported but don't stop execution.
/// Warnings are displayed in yellow to distinguish them from errors.
pub fn printWarningTo(writer: anytype, comptime fmt: []const u8, fmt_args: anytype) void {
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));

    // Try to use color for warnings
    const StyleType = style.Style(@TypeOf(writer));
    var s = StyleType.init(writer);
    s.setColor(.bright_yellow) catch {};
    writer.print("{s}: warning: ", .{prog_name}) catch return;
    s.reset() catch {};
    writer.print(fmt ++ "\n", fmt_args) catch return;
}

/// Print error message with custom program name to a specific writer
///
/// This version allows utilities to specify their program name explicitly,
/// which is useful for consistent error messages across different contexts.
pub fn printErrorWithProgram(writer: anytype, prog_name: []const u8, comptime fmt: []const u8, fmt_args: anytype) void {
    // Try to use color for errors
    const StyleType = style.Style(@TypeOf(writer));
    var s = StyleType.init(writer);
    s.setColor(.bright_red) catch {};
    writer.print("{s}: ", .{prog_name}) catch return;
    s.reset() catch {};
    writer.print(fmt ++ "\n", fmt_args) catch return;
}

/// Print warning message with custom program name to a specific writer
///
/// This version allows utilities to specify their program name explicitly,
/// which is useful for consistent warning messages across different contexts.
pub fn printWarningWithProgram(writer: anytype, prog_name: []const u8, comptime fmt: []const u8, fmt_args: anytype) void {
    // Try to use color for warnings
    const StyleType = style.Style(@TypeOf(writer));
    var s = StyleType.init(writer);
    s.setColor(.bright_yellow) catch {};
    writer.print("{s}: warning: ", .{prog_name}) catch return;
    s.reset() catch {};
    writer.print(fmt ++ "\n", fmt_args) catch return;
}

/// Common command line options (DEPRECATED)
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

// Import tests to ensure they are run as part of the test suite
test {
    _ = @import("buffering_test.zig");
}
