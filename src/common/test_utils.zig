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
//! var test_writer = TestWriter.init(testing.allocator);
//! defer test_writer.deinit();
//! try some_function(test_writer.writer());
//! try testing.expectEqualStrings("expected output", test_writer.getContent());
//! ```
//!
//! ## StdoutCapture
//! Comprehensive stdout/stderr capture with assertion helpers:
//! ```zig
//! var capture = StdoutCapture.init(testing.allocator);
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
//!
//! // Capture and strip ANSI codes in one call
//! const clean_output = try captureOutputStripped(allocator, colored_function, .{args});
//! defer allocator.free(clean_output);
//! ```
//!
//! ## MockEnv
//! Environment variable mocking for testing environment-dependent code:
//! ```zig
//! var mock_env = MockEnv.init(testing.allocator);
//! defer mock_env.deinit();
//! try mock_env.setVar("NO_COLOR", "1");
//! // Test code that depends on NO_COLOR being set
//! ```

const std = @import("std");
const testing = std.testing;

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

/// Create an executable test file
pub fn createExecutableFile(dir: std.fs.Dir, name: []const u8, content: []const u8) !void {
    const file = try dir.createFile(name, .{ .mode = 0o755 });
    defer file.close();
    try file.writeAll(content);
}

/// A test writer that captures output to a buffer for testing
pub const TestWriter = struct {
    buffer: std.ArrayList(u8),

    const Self = @This();

    /// Initialize with an allocator
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    /// Deinitialize and free the buffer
    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }

    /// Get the writer interface
    pub fn writer(self: *Self) std.ArrayList(u8).Writer {
        return self.buffer.writer();
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
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .output = std.ArrayList(u8).init(allocator),
            .error_output = std.ArrayList(u8).init(allocator),
        };
    }

    /// Deinitialize and free buffers
    pub fn deinit(self: *Self) void {
        self.output.deinit();
        self.error_output.deinit();
    }

    /// Get stdout writer
    pub fn stdoutWriter(self: *Self) std.ArrayList(u8).Writer {
        return self.output.writer();
    }

    /// Get stderr writer
    pub fn stderrWriter(self: *Self) std.ArrayList(u8).Writer {
        return self.error_output.writer();
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
            std.debug.print("Expected stdout to contain: '{s}'\n", .{needle});
            std.debug.print("Actual stdout: '{s}'\n", .{self.output.items});
            return testing.expectEqual(true, false); // This will fail with a proper test failure message
        }
    }

    /// Assert stderr contains substring
    pub fn expectStderrContains(self: *const Self, needle: []const u8) !void {
        if (std.mem.indexOf(u8, self.error_output.items, needle) == null) {
            std.debug.print("Expected stderr to contain: '{s}'\n", .{needle});
            std.debug.print("Actual stderr: '{s}'\n", .{self.error_output.items});
            return testing.expectEqual(true, false); // This will fail with a proper test failure message
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
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

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
                try result.append(input[i]);
                i += 1;
            }
        } else {
            // Regular character, add to result
            try result.append(input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
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
    var test_writer = TestWriter.init(allocator);
    defer test_writer.deinit();

    try @call(.auto, func, .{test_writer.writer()} ++ args);

    return allocator.dupe(u8, test_writer.getContent());
}

/// Convenient function to create a TestWriter and run a function with it, stripping ANSI codes
pub fn captureOutputStripped(
    allocator: std.mem.Allocator,
    comptime func: anytype,
    args: anytype,
) ![]u8 {
    var test_writer = TestWriter.init(allocator);
    defer test_writer.deinit();

    try @call(.auto, func, .{test_writer.writer()} ++ args);

    return stripAnsiCodes(allocator, test_writer.getContent());
}

/// Test assertion helper for comparing output
pub fn expectOutput(expected: []const u8, actual: []const u8) !void {
    if (!std.mem.eql(u8, expected, actual)) {
        std.debug.print("Expected output:\n'{s}'\n", .{expected});
        std.debug.print("Actual output:\n'{s}'\n", .{actual});
        std.debug.print("Expected bytes: {any}\n", .{expected});
        std.debug.print("Actual bytes:   {any}\n", .{actual});
    }
    try testing.expectEqualStrings(expected, actual);
}

/// Test assertion helper for comparing output with ANSI stripping
pub fn expectOutputStripped(allocator: std.mem.Allocator, expected: []const u8, actual: []const u8) !void {
    const stripped = try stripAnsiCodes(allocator, actual);
    defer allocator.free(stripped);
    try expectOutput(expected, stripped);
}

/// Mock environment variable setter for testing
/// Note: This is a simplified mock that doesn't actually modify the process environment
/// It's mainly useful for testing environment-related logic in isolation
pub const MockEnv = struct {
    allocator: std.mem.Allocator,
    env_map: std.StringHashMap([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .env_map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Free all keys and values before deinit
        var iterator = self.env_map.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.env_map.deinit();
    }

    /// Set a mock environment variable
    pub fn setVar(self: *Self, key: []const u8, value: []const u8) !void {
        // Check if key already exists and free old values if it does
        if (self.env_map.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }

        const key_owned = try self.allocator.dupe(u8, key);
        const value_owned = try self.allocator.dupe(u8, value);
        try self.env_map.put(key_owned, value_owned);
    }

    /// Remove a mock environment variable
    pub fn unsetVar(self: *Self, key: []const u8) void {
        if (self.env_map.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    /// Get a mock environment variable value
    pub fn getVar(self: *const Self, key: []const u8) ?[]const u8 {
        return self.env_map.get(key);
    }

    /// Check if a mock environment variable exists
    pub fn hasVar(self: *const Self, key: []const u8) bool {
        return self.env_map.contains(key);
    }

    /// Clear all mock environment variables
    pub fn clear(self: *Self) void {
        // Free all current entries
        var iterator = self.env_map.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }

        // Clear the map
        self.env_map.clearAndFree();
    }
};

// ============================================================================
// Tests for the testing infrastructure
// ============================================================================

test "TestWriter basic functionality" {
    var test_writer = TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    try test_writer.writer().writeAll("Hello, ");
    try test_writer.writer().writeAll("World!");

    try testing.expectEqualStrings("Hello, World!", test_writer.getContent());
}

test "TestWriter clear functionality" {
    var test_writer = TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    try test_writer.writer().writeAll("Initial content");
    try testing.expectEqualStrings("Initial content", test_writer.getContent());

    test_writer.clear();
    try testing.expectEqualStrings("", test_writer.getContent());

    try test_writer.writer().writeAll("New content");
    try testing.expectEqualStrings("New content", test_writer.getContent());
}

test "StdoutCapture basic functionality" {
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    try capture.stdoutWriter().writeAll("stdout content");
    try capture.stderrWriter().writeAll("stderr content");

    try testing.expectEqualStrings("stdout content", capture.getStdout());
    try testing.expectEqualStrings("stderr content", capture.getStderr());
}

test "StdoutCapture assertion methods" {
    var capture = StdoutCapture.init(testing.allocator);
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
    var capture = StdoutCapture.init(testing.allocator);
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
    var test_writer = TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    try test_writer.writer().writeAll("Hello \x1b[31mRed\x1b[0m World");

    const stripped = try test_writer.getContentStripped(testing.allocator);
    defer testing.allocator.free(stripped);

    try testing.expectEqualStrings("Hello Red World", stripped);
}

test "StdoutCapture with ANSI stripping" {
    var capture = StdoutCapture.init(testing.allocator);
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

test "captureOutputStripped helper function" {
    // Function that writes ANSI codes
    const TestFunc = struct {
        fn writeColored(writer: anytype, text: []const u8) !void {
            try writer.print("\x1b[31m{s}\x1b[0m", .{text});
        }
    };

    const output = try captureOutputStripped(testing.allocator, TestFunc.writeColored, .{"Test"});
    defer testing.allocator.free(output);

    try testing.expectEqualStrings("Test", output);
}

test "expectOutput helper function success" {
    try expectOutput("expected", "expected");
}

test "expectOutputStripped helper function" {
    const output = "Hello \x1b[31mRed\x1b[0m World";
    try expectOutputStripped(testing.allocator, "Hello Red World", output);
}

test "MockEnv environment variable mocking" {
    var mock_env = MockEnv.init(testing.allocator);
    defer mock_env.deinit();

    // Set a test environment variable
    try mock_env.setVar("TEST_VAR", "test_value");

    // Verify it was set in the mock
    try testing.expect(mock_env.hasVar("TEST_VAR"));
    const value = mock_env.getVar("TEST_VAR").?;
    try testing.expectEqualStrings("test_value", value);

    // Verify non-existent variable
    try testing.expect(!mock_env.hasVar("NONEXISTENT"));
    try testing.expect(mock_env.getVar("NONEXISTENT") == null);
}

test "MockEnv unset functionality" {
    var mock_env = MockEnv.init(testing.allocator);
    defer mock_env.deinit();

    // First set a variable
    try mock_env.setVar("TEMP_TEST_VAR", "initial_value");
    try testing.expect(mock_env.hasVar("TEMP_TEST_VAR"));

    // Then unset it
    mock_env.unsetVar("TEMP_TEST_VAR");

    // Verify it's unset
    try testing.expect(!mock_env.hasVar("TEMP_TEST_VAR"));
    try testing.expect(mock_env.getVar("TEMP_TEST_VAR") == null);
}

test "MockEnv clear functionality" {
    var mock_env = MockEnv.init(testing.allocator);
    defer mock_env.deinit();

    // Set multiple variables
    try mock_env.setVar("VAR1", "value1");
    try mock_env.setVar("VAR2", "value2");
    try mock_env.setVar("VAR3", "value3");

    // Verify they exist
    try testing.expect(mock_env.hasVar("VAR1"));
    try testing.expect(mock_env.hasVar("VAR2"));
    try testing.expect(mock_env.hasVar("VAR3"));

    // Clear all
    mock_env.clear();

    // Verify they're all gone
    try testing.expect(!mock_env.hasVar("VAR1"));
    try testing.expect(!mock_env.hasVar("VAR2"));
    try testing.expect(!mock_env.hasVar("VAR3"));
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
    var test_writer = TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    const args = [_][]const u8{ "hello", "world" };
    try EchoFunc.echo(test_writer.writer(), &args, true);

    try testing.expectEqualStrings("hello world\n", test_writer.getContent());

    // Test with StdoutCapture
    var capture = StdoutCapture.init(testing.allocator);
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
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    try ColorFunc.coloredOutput(capture.stdoutWriter(), "red text");

    // Raw output includes ANSI codes
    try capture.expectStdoutContains("\x1b[31m");
    try capture.expectStdoutContains("red text");
    try capture.expectStdoutContains("\x1b[0m");

    // Stripped output has clean text
    try capture.expectStdoutStripped("red text\n");
}
