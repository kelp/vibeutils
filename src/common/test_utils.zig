//! Test utilities for capturing and asserting command output
//!
//! This module provides comprehensive testing infrastructure for stdout/stderr capture,
//! ANSI code stripping, and environment variable mocking for the vibeutils project.
//!
//! # Key Components
//!
//! ## TestWriter
//! Simple buffer-based writer for capturing output:
//! ```zig
//! var test_writer = try TestWriter.init(testing.allocator);
//! defer test_writer.deinit();
//! try some_function(test_writer.writer());
//! try testing.expectEqualStrings("expected output", test_writer.getContent());
//! ```
//!
//! ## StdoutCapture
//! Comprehensive stdout/stderr capture with assertion helpers:
//! ```zig
//! var capture = try StdoutCapture.init(testing.allocator);
//! defer capture.deinit();
//! try some_function(capture.stdoutWriter(), capture.stderrWriter());
//! try capture.expectStdout("expected stdout");
//! try capture.expectStdoutStripped("expected without ANSI codes");
//! ```
//!
//! ## ANSI Code Stripping
//! Utilities for testing colored output by stripping escape sequences:
//! ```zig
//! const colored = "\x1b[31mRed Text\x1b[0m";
//! const stripped = try stripAnsiCodes(allocator, colored);
//! defer allocator.free(stripped);
//! try testing.expectEqualStrings("Red Text", stripped);
//! ```
//!
//! ## Helper Functions
//! Convenient one-liner functions for common testing patterns:
//! ```zig
//! // Capture output from a function call
//! const output = try captureOutput(allocator, my_function, .{arg1, arg2});
//! defer allocator.free(output);
//! ```

const std = @import("std");
const testing = std.testing;

/// Null writer for tests - re-export from std.io for convenience
pub const null_writer = std.io.null_writer;

/// Generate a unique test file name based on test name, timestamp, and random number
pub fn uniqueTestName(allocator: std.mem.Allocator, base_name: []const u8) ![]u8 {
    // Use timestamp and random number for thread-safe uniqueness
    const timestamp = std.time.timestamp();
    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(@max(0, timestamp))));
    const random_num = prng.random().int(u32);
    return try std.fmt.allocPrint(allocator, "{s}_{d}_{d}", .{ base_name, timestamp, random_num });
}

/// Create a test file with content in a directory
pub fn createTestFile(dir: std.fs.Dir, name: []const u8, content: []const u8) !void {
    const file = try dir.createFile(name, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Create a uniquely named test file with content
pub fn createUniqueTestFile(dir: std.fs.Dir, allocator: std.mem.Allocator, base_name: []const u8, content: []const u8) ![]u8 {
    const unique_name = try uniqueTestName(allocator, base_name);
    try createTestFile(dir, unique_name, content);
    return unique_name;
}

/// A test writer that captures output to a buffer for testing
pub const TestWriter = struct {
    buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize with an allocator
    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .buffer = try std.ArrayList(u8).initCapacity(allocator, 0),
            .allocator = allocator,
        };
    }

    /// Deinitialize and free the buffer
    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
    }

    /// Get the writer interface
    pub fn writer(self: *Self) std.ArrayList(u8).Writer {
        return self.buffer.writer(self.allocator);
    }

    /// Get the captured content as a string
    pub fn getContent(self: *const Self) []const u8 {
        return self.buffer.items;
    }

    /// Clear the buffer content
    pub fn clear(self: *Self) void {
        self.buffer.clearRetainingCapacity();
    }

    /// Get content with ANSI escape codes stripped
    pub fn getContentStripped(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        return stripAnsiCodes(allocator, self.buffer.items);
    }
};

/// Captures stdout for testing command-line utilities
pub const StdoutCapture = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8),
    error_output: std.ArrayList(u8),

    const Self = @This();

    /// Initialize stdout capture
    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .output = try std.ArrayList(u8).initCapacity(allocator, 0),
            .error_output = try std.ArrayList(u8).initCapacity(allocator, 0),
        };
    }

    /// Deinitialize and free buffers
    pub fn deinit(self: *Self) void {
        self.output.deinit(self.allocator);
        self.error_output.deinit(self.allocator);
    }

    /// Get stdout writer
    pub fn stdoutWriter(self: *Self) std.ArrayList(u8).Writer {
        return self.output.writer(self.allocator);
    }

    /// Get stderr writer
    pub fn stderrWriter(self: *Self) std.ArrayList(u8).Writer {
        return self.error_output.writer(self.allocator);
    }

    /// Get stdout content
    pub fn getStdout(self: *const Self) []const u8 {
        return self.output.items;
    }

    /// Get stderr content
    pub fn getStderr(self: *const Self) []const u8 {
        return self.error_output.items;
    }

    /// Get stdout with ANSI codes stripped
    pub fn getStdoutStripped(self: *const Self) ![]u8 {
        return stripAnsiCodes(self.allocator, self.output.items);
    }

    /// Get stderr with ANSI codes stripped
    pub fn getStderrStripped(self: *const Self) ![]u8 {
        return stripAnsiCodes(self.allocator, self.error_output.items);
    }

    /// Clear all captured output
    pub fn clear(self: *Self) void {
        self.output.clearRetainingCapacity();
        self.error_output.clearRetainingCapacity();
    }

    /// Assert stdout equals expected content
    pub fn expectStdout(self: *const Self, expected: []const u8) !void {
        try testing.expectEqualStrings(expected, self.output.items);
    }

    /// Assert stderr equals expected content
    pub fn expectStderr(self: *const Self, expected: []const u8) !void {
        try testing.expectEqualStrings(expected, self.error_output.items);
    }

    /// Assert stdout equals expected content (with ANSI codes stripped)
    pub fn expectStdoutStripped(self: *const Self, expected: []const u8) !void {
        const stripped = try self.getStdoutStripped();
        defer self.allocator.free(stripped);
        try testing.expectEqualStrings(expected, stripped);
    }

    /// Assert stderr equals expected content (with ANSI codes stripped)
    pub fn expectStderrStripped(self: *const Self, expected: []const u8) !void {
        const stripped = try self.getStderrStripped();
        defer self.allocator.free(stripped);
        try testing.expectEqualStrings(expected, stripped);
    }

    /// Assert stdout contains substring
    pub fn expectStdoutContains(self: *const Self, needle: []const u8) !void {
        if (std.mem.indexOf(u8, self.output.items, needle) == null) {
            try testing.expect(false); // Will fail with proper test context
        }
    }

    /// Assert stderr contains substring
    pub fn expectStderrContains(self: *const Self, needle: []const u8) !void {
        if (std.mem.indexOf(u8, self.error_output.items, needle) == null) {
            try testing.expect(false); // Will fail with proper test context
        }
    }

    /// Assert that stdout is empty
    pub fn expectStdoutEmpty(self: *const Self) !void {
        try testing.expectEqualStrings("", self.output.items);
    }

    /// Assert that stderr is empty
    pub fn expectStderrEmpty(self: *const Self) !void {
        try testing.expectEqualStrings("", self.error_output.items);
    }
};

/// Strip ANSI escape codes from text
/// Handles multiple escape sequence types: CSI, OSC, and other ANSI sequences
pub fn stripAnsiCodes(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\x1b' and i + 1 < input.len) {
            const next_char = input[i + 1];

            if (next_char == '[') {
                // CSI (Control Sequence Introducer) - ESC[
                i += 2; // Skip ESC[

                // Skip parameter bytes (0x30-0x3F) and intermediate bytes (0x20-0x2F)
                while (i < input.len) {
                    const c = input[i];
                    if ((c >= 0x30 and c <= 0x3F) or (c >= 0x20 and c <= 0x2F)) {
                        i += 1;
                    } else {
                        break;
                    }
                }

                // Skip final byte (0x40-0x7E)
                if (i < input.len and input[i] >= 0x40 and input[i] <= 0x7E) {
                    i += 1;
                }
            } else if (next_char == ']') {
                // OSC (Operating System Command) - ESC]
                i += 2; // Skip ESC]

                // OSC sequences end with BEL (\x07) or ST (ESC\)
                while (i < input.len) {
                    if (input[i] == '\x07') {
                        // BEL terminator
                        i += 1;
                        break;
                    } else if (input[i] == '\x1b' and i + 1 < input.len and input[i + 1] == '\\') {
                        // ST (String Terminator) - ESC\
                        i += 2;
                        break;
                    }
                    i += 1;
                }
            } else if (next_char >= 0x40 and next_char <= 0x5F) {
                // Fe sequences (ESC followed by 0x40-0x5F)
                i += 2;
            } else if (next_char >= 0x60 and next_char <= 0x7E) {
                // Fs sequences (ESC followed by 0x60-0x7E)
                i += 2;
            } else if (next_char >= 0x30 and next_char <= 0x3F) {
                // Fp sequences (ESC followed by 0x30-0x3F)
                i += 2;
            } else {
                // Unknown escape sequence, skip ESC and continue
                try result.append(allocator, input[i]);
                i += 1;
            }
        } else {
            // Regular character, add to result
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Helper function to run a command and capture its output
pub fn runCommand(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !struct { stdout: []u8, stderr: []u8, exit_code: u8 } {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);

    const result = try child.wait();
    const exit_code = switch (result) {
        .Exited => |code| code,
        .Signal => |signal| @as(u8, @intCast(signal + 128)),
        .Stopped => |signal| @as(u8, @intCast(signal + 128)),
        .Unknown => |code| @as(u8, @intCast(code)),
    };

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = exit_code,
    };
}

/// Convenient function to create a TestWriter and run a function with it
pub fn captureOutput(
    allocator: std.mem.Allocator,
    comptime func: anytype,
    args: anytype,
) ![]u8 {
    var test_writer = try TestWriter.init(allocator);
    defer test_writer.deinit();

    try @call(.auto, func, .{test_writer.writer()} ++ args);

    return allocator.dupe(u8, test_writer.getContent());
}

// ============================================================================
// Tests for the testing infrastructure
// ============================================================================

test "TestWriter basic functionality" {
    var test_writer = try TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    try test_writer.writer().writeAll("Hello, ");
    try test_writer.writer().writeAll("World!");

    try testing.expectEqualStrings("Hello, World!", test_writer.getContent());
}

test "TestWriter clear functionality" {
    var test_writer = try TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    try test_writer.writer().writeAll("Initial content");
    try testing.expectEqualStrings("Initial content", test_writer.getContent());

    test_writer.clear();
    try testing.expectEqualStrings("", test_writer.getContent());

    try test_writer.writer().writeAll("New content");
    try testing.expectEqualStrings("New content", test_writer.getContent());
}

test "StdoutCapture basic functionality" {
    var capture = try StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    try capture.stdoutWriter().writeAll("stdout content");
    try capture.stderrWriter().writeAll("stderr content");

    try testing.expectEqualStrings("stdout content", capture.getStdout());
    try testing.expectEqualStrings("stderr content", capture.getStderr());
}

test "StdoutCapture assertion methods" {
    var capture = try StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    try capture.stdoutWriter().writeAll("test output");
    try capture.stderrWriter().writeAll("error output");

    // Test exact match assertions
    try capture.expectStdout("test output");
    try capture.expectStderr("error output");

    // Test contains assertions
    try capture.expectStdoutContains("test");
    try capture.expectStdoutContains("output");
    try capture.expectStderrContains("error");
    try capture.expectStderrContains("output");
}

test "StdoutCapture clear functionality" {
    var capture = try StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    try capture.stdoutWriter().writeAll("initial stdout");
    try capture.stderrWriter().writeAll("initial stderr");

    capture.clear();
    try capture.expectStdoutEmpty();
    try capture.expectStderrEmpty();

    try capture.stdoutWriter().writeAll("new stdout");
    try capture.expectStdout("new stdout");
}

test "stripAnsiCodes basic functionality" {
    const input = "Hello \x1b[31mRed\x1b[0m World";
    const expected = "Hello Red World";

    const result = try stripAnsiCodes(testing.allocator, input);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

test "stripAnsiCodes multiple sequences" {
    const input = "\x1b[1m\x1b[31mBold Red\x1b[0m\x1b[32m Green\x1b[0m";
    const expected = "Bold Red Green";

    const result = try stripAnsiCodes(testing.allocator, input);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

test "stripAnsiCodes no escape sequences" {
    const input = "Plain text with no escape sequences";
    const expected = "Plain text with no escape sequences";

    const result = try stripAnsiCodes(testing.allocator, input);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

test "stripAnsiCodes complex sequences" {
    // Test various ANSI escape sequences
    const input = "\x1b[2J\x1b[H\x1b[31;1mRed Bold\x1b[0m\x1b[32mGreen\x1b[K";
    const expected = "Red BoldGreen";

    const result = try stripAnsiCodes(testing.allocator, input);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

test "stripAnsiCodes empty string" {
    const input = "";
    const expected = "";

    const result = try stripAnsiCodes(testing.allocator, input);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

test "stripAnsiCodes only escape sequences" {
    const input = "\x1b[31m\x1b[1m\x1b[0m";
    const expected = "";

    const result = try stripAnsiCodes(testing.allocator, input);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

test "stripAnsiCodes OSC sequences" {
    // Test OSC sequence with BEL terminator
    const input1 = "Text\x1b]0;Window Title\x07More text";
    const expected1 = "TextMore text";

    const result1 = try stripAnsiCodes(testing.allocator, input1);
    defer testing.allocator.free(result1);

    try testing.expectEqualStrings(expected1, result1);

    // Test OSC sequence with ST (ESC\) terminator
    const input2 = "Text\x1b]0;Window Title\x1b\\More text";
    const expected2 = "TextMore text";

    const result2 = try stripAnsiCodes(testing.allocator, input2);
    defer testing.allocator.free(result2);

    try testing.expectEqualStrings(expected2, result2);
}

test "stripAnsiCodes Fe and Fs sequences" {
    // Test Fe sequences (ESC D = Index, ESC M = Reverse Index)
    const input1 = "Line1\x1bDLine2\x1bMLine3";
    const expected1 = "Line1Line2Line3";

    const result1 = try stripAnsiCodes(testing.allocator, input1);
    defer testing.allocator.free(result1);

    try testing.expectEqualStrings(expected1, result1);

    // Test Fs sequences (ESC n = LS2, ESC o = LS3)
    const input2 = "Text\x1bnMore\x1boText";
    const expected2 = "TextMoreText";

    const result2 = try stripAnsiCodes(testing.allocator, input2);
    defer testing.allocator.free(result2);

    try testing.expectEqualStrings(expected2, result2);
}

test "stripAnsiCodes mixed sequence types" {
    // Test a mix of CSI, OSC, and other sequences
    const input = "\x1b[31mRed\x1b]0;Title\x07\x1b[0m\x1bDNormal\x1b[32mGreen\x1b]1;Icon\x1b\\\x1b[0m";
    const expected = "RedNormalGreen";

    const result = try stripAnsiCodes(testing.allocator, input);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

test "TestWriter with ANSI stripping" {
    var test_writer = try TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    try test_writer.writer().writeAll("Hello \x1b[31mRed\x1b[0m World");

    const stripped = try test_writer.getContentStripped(testing.allocator);
    defer testing.allocator.free(stripped);

    try testing.expectEqualStrings("Hello Red World", stripped);
}

test "StdoutCapture with ANSI stripping" {
    var capture = try StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    try capture.stdoutWriter().writeAll("Hello \x1b[31mRed\x1b[0m World");
    try capture.stderrWriter().writeAll("Error \x1b[1m\x1b[31mBold Red\x1b[0m Message");

    try capture.expectStdoutStripped("Hello Red World");
    try capture.expectStderrStripped("Error Bold Red Message");
}

test "captureOutput helper function" {
    // Simple function that writes to a writer
    const TestFunc = struct {
        fn writeHello(writer: anytype, name: []const u8) !void {
            try writer.print("Hello, {s}!", .{name});
        }
    };

    const output = try captureOutput(testing.allocator, TestFunc.writeHello, .{"Zig"});
    defer testing.allocator.free(output);

    try testing.expectEqualStrings("Hello, Zig!", output);
}

// Integration test demonstrating how to use the testing infrastructure
test "integration example: testing a simple echo function" {
    // Define a simple echo function for testing
    const EchoFunc = struct {
        fn echo(writer: anytype, args: []const []const u8, newline: bool) !void {
            for (args, 0..) |arg, i| {
                if (i > 0) try writer.writeAll(" ");
                try writer.writeAll(arg);
            }
            if (newline) try writer.writeAll("\n");
        }
    };

    // Test with TestWriter
    var test_writer = try TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    const args = [_][]const u8{ "hello", "world" };
    try EchoFunc.echo(test_writer.writer(), &args, true);

    try testing.expectEqualStrings("hello world\n", test_writer.getContent());

    // Test with StdoutCapture
    var capture = try StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    try EchoFunc.echo(capture.stdoutWriter(), &args, false);
    try capture.expectStdout("hello world");

    // Test with helper function
    const output = try captureOutput(testing.allocator, EchoFunc.echo, .{ &args, true });
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("hello world\n", output);
}

test "integration example: testing colored output" {
    // Function that outputs colored text
    const ColorFunc = struct {
        fn coloredOutput(writer: anytype, text: []const u8) !void {
            try writer.print("\x1b[31m{s}\x1b[0m\n", .{text});
        }
    };

    // Test with ANSI stripping
    var capture = try StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    try ColorFunc.coloredOutput(capture.stdoutWriter(), "red text");

    // Raw output includes ANSI codes
    try capture.expectStdoutContains("\x1b[31m");
    try capture.expectStdoutContains("red text");
    try capture.expectStdoutContains("\x1b[0m");

    // Stripped output has clean text
    try capture.expectStdoutStripped("red text\n");
}
