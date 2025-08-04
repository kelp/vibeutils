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

/// Copy engine for cp and mv utilities
pub const copy_engine = @import("copy_engine.zig");

/// Copy options and types for file copying operations
pub const copy_options = @import("copy_options.zig");

/// Unicode display width calculation for terminal output
pub const unicode = @import("unicode.zig");

/// Fuzzing utilities and helpers for property-based testing
pub const fuzz = @import("fuzz.zig");

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

/// DEPRECATED: Use printWarningWithWriter() instead
/// This function will be removed in a future version
pub fn printWarning(comptime fmt: []const u8, fmt_args: anytype) void {
    _ = fmt;
    _ = fmt_args;
    @compileError("printWarning() is deprecated - use printWarningWithWriter() with explicit stderr writer instead");
}

/// Print error message with custom program name to a specific writer
///
/// This version allows utilities to specify their program name explicitly,
/// which is useful for consistent error messages across different contexts.
pub fn printErrorWithProgram(allocator: std.mem.Allocator, writer: anytype, prog_name: []const u8, comptime fmt: []const u8, fmt_args: anytype) void {
    // Try to use color for errors
    const StyleType = style.Style(@TypeOf(writer));
    var s = StyleType.init(allocator, writer) catch {
        // Fallback to no color if style init fails
        writer.print("{s}: ", .{prog_name}) catch return;
        writer.print(fmt ++ "\n", fmt_args) catch return;
        return;
    };
    s.setColor(.bright_red) catch {};
    writer.print("{s}: ", .{prog_name}) catch return;
    s.reset() catch {};
    writer.print(fmt ++ "\n", fmt_args) catch return;
}

/// Print warning message with custom program name to a specific writer
///
/// This version allows utilities to specify their program name explicitly,
/// which is useful for consistent warning messages across different contexts.
pub fn printWarningWithProgram(allocator: std.mem.Allocator, writer: anytype, prog_name: []const u8, comptime fmt: []const u8, fmt_args: anytype) void {
    // Try to use color for warnings
    const StyleType = style.Style(@TypeOf(writer));
    var s = StyleType.init(allocator, writer) catch {
        // Fallback to no color if style init fails
        writer.print("{s}: warning: ", .{prog_name}) catch return;
        writer.print(fmt ++ "\n", fmt_args) catch return;
        return;
    };
    s.setColor(.bright_yellow) catch {};
    writer.print("{s}: warning: ", .{prog_name}) catch return;
    s.reset() catch {};
    writer.print(fmt ++ "\n", fmt_args) catch return;
}

test "common library basics" {
    // Test that we can import and use basic functionality
    const ec = ExitCode.success;
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(ec));
}

// Import tests to ensure they are run as part of the test suite
test {
    // All common module tests are included via individual test blocks
}
