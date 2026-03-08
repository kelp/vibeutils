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

/// Unicode display width calculation for terminal output
pub const unicode = @import("unicode.zig");

/// Help text colorization for terminal output
pub const help = @import("help.zig");

/// Shared color functions for size-based coloring
pub const colors = @import("colors.zig");

/// Test directory utilities for managing temporary file systems in tests
pub const test_dir = @import("test_dir.zig");

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
pub fn fatalWithWriter(_: anytype, comptime fmt: []const u8, fmt_args: anytype) noreturn {
    // Write directly to stderr with a dedicated buffer to guarantee
    // output is flushed before exit. The passed writer may be buffered
    // with no way to flush through the interface pointer.
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    const stderr = &w.interface;
    const prog_name = std.fs.path.basename(std.mem.span(std.os.argv[0]));
    stderr.print("{s}: " ++ fmt ++ "\n", .{prog_name} ++ fmt_args) catch {};
    stderr.flush() catch {};
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

/// Print hint message with custom program name to a specific writer
///
/// Hints are informational suggestions for the user, displayed in cyan.
/// Use for one-time suggestions like "use -i for interactive prompts".
pub fn printHintWithProgram(allocator: std.mem.Allocator, writer: anytype, prog_name: []const u8, comptime fmt: []const u8, fmt_args: anytype) void {
    // Try to use color for hints
    const StyleType = style.Style(@TypeOf(writer));
    var s = StyleType.init(allocator, writer) catch {
        // Fallback to no color if style init fails
        writer.print("{s}: hint: ", .{prog_name}) catch return;
        writer.print(fmt ++ "\n", fmt_args) catch return;
        return;
    };
    s.setColor(.bright_cyan) catch {};
    writer.print("{s}: hint: ", .{prog_name}) catch return;
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

test "utilities must use writerStreaming not writer for stdout/stderr (issue #5)" {
    // Regression test for GitHub issue #5: File.writer() (positional mode)
    // uses pwritev at offset 0, ignoring O_APPEND on macOS. Utilities must
    // use writerStreaming() which calls writev and respects O_APPEND.
    //
    // This test scans utility source files to ensure none use the buggy
    // .stdout().writer( or .stderr().writer( pattern.
    const testing = std.testing;

    const src_dir = std.fs.cwd().openDir("src", .{ .iterate = true }) catch {
        // Skip if src/ not available (e.g. installed package)
        return;
    };

    var walker = try src_dir.walk(testing.allocator);
    defer walker.deinit();

    var violations: std.ArrayListUnmanaged(u8) = .empty;
    defer violations.deinit(testing.allocator);

    while (try walker.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        // Skip test/integration files
        if (std.mem.indexOf(u8, entry.path, "integration_tests") != null) continue;

        const content = src_dir.readFileAlloc(testing.allocator, entry.path, 1024 * 1024) catch continue;
        defer testing.allocator.free(content);

        // Search for buggy pattern: .stdout().writer( or .stderr().writer(
        // Correct pattern is: .stdout().writerStreaming( or .stderr().writerStreaming(
        const patterns = [_][]const u8{
            ".stdout().writer(",
            ".stderr().writer(",
        };
        for (patterns) |pattern| {
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, content, pos, pattern)) |idx| {
                // Check it's not writerStreaming (which contains ".writer(" as substring)
                // writerStreaming( would appear as .writerStreaming( so check preceding chars
                const before_writer = idx + std.mem.indexOf(u8, pattern, ".writer(").?;
                if (before_writer >= "Streaming".len) {
                    const prefix_start = before_writer - "Streaming".len;
                    if (std.mem.eql(u8, content[prefix_start..before_writer], "Streaming")) {
                        pos = idx + pattern.len;
                        continue;
                    }
                }
                try violations.appendSlice(testing.allocator, entry.path);
                try violations.appendSlice(testing.allocator, ": uses positional ");
                try violations.appendSlice(testing.allocator, pattern);
                try violations.append(testing.allocator, '\n');
                pos = idx + pattern.len;
            }
        }
    }

    if (violations.items.len > 0) {
        std.debug.print("\nIssue #5 violation - these files use .writer() instead of .writerStreaming():\n{s}\n", .{violations.items});
        return error.TestExpectedEqual;
    }
}

// Import tests to ensure they are run as part of the test suite
test {
    // All common module tests are included via individual test blocks
}
