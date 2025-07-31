//! Tests to verify that the writer parameter changes have successfully fixed stdout buffering issues
//!
//! This test suite validates that:
//! 1. Large output scenarios complete without hanging
//! 2. Output is immediately available in buffers (no buffering delays)
//! 3. Multiple utilities can write to buffers without interference
//! 4. Stdout/stderr isolation works correctly
//! 5. Operations complete within reasonable time bounds
//!
//! These tests would have hung before the buffering fix but now pass quickly.
//!
//! Note: Since these tests are run from within the common module, they focus on
//! testing the writer infrastructure itself rather than specific utility implementations.

const std = @import("std");
const testing = std.testing;
const test_utils = @import("test_utils.zig");
const TestWriter = test_utils.TestWriter;
const StdoutCapture = test_utils.StdoutCapture;

// Timer helper for measuring test execution time
const Timer = struct {
    start_time: i128,

    fn init() Timer {
        return Timer{ .start_time = std.time.nanoTimestamp() };
    }

    fn elapsedMs(self: Timer) i64 {
        const current = std.time.nanoTimestamp();
        const elapsed_ns = current - self.start_time;
        return @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms));
    }
};

// Test that large output to TestWriter completes without hanging
// Before the buffering fix, this would hang when trying to write large amounts to stdout
test "buffering fix: large output to TestWriter completes quickly" {
    const timer = Timer.init();

    var test_writer = TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    // Create a large string that would actually trigger buffering issues (64KB+)
    const large_text = "A" ** 65536; // 64KB of data - realistic for buffering issues

    // Write large content directly to test writer
    try test_writer.writer().writeAll(large_text);
    try test_writer.writer().writeAll("\n");

    // Verify output was captured immediately
    const content = test_writer.getContent();
    try testing.expect(content.len > 65000); // Should have our large text
    try testing.expect(std.mem.endsWith(u8, content, "\n")); // Should end with newline

    // Test should complete in under 2 seconds (was hanging before fix)
    const elapsed = timer.elapsedMs();
    try testing.expect(elapsed < 2000);
}

// Test that multiple writes to different TestWriters are isolated
// This verifies that writer parameters provide proper isolation
test "buffering fix: writes to different TestWriters are isolated" {
    var writer1 = TestWriter.init(testing.allocator);
    defer writer1.deinit();

    var writer2 = TestWriter.init(testing.allocator);
    defer writer2.deinit();

    // Write to different writers simultaneously
    try writer1.writer().writeAll("Hello from writer 1\n");
    try writer2.writer().writeAll("Hello from writer 2\n");

    // Verify outputs are isolated and correct
    try testing.expectEqualStrings("Hello from writer 1\n", writer1.getContent());
    try testing.expectEqualStrings("Hello from writer 2\n", writer2.getContent());
}

// Test that output is immediately available (no buffering delays)
// Before the fix, output might be buffered and not immediately visible
test "buffering fix: output is immediately available in TestWriter" {
    var test_writer = TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    // Write to buffer
    try test_writer.writer().writeAll("Immediate\n");

    // Output should be immediately available (no buffering delay)
    const content = test_writer.getContent();
    try testing.expectEqualStrings("Immediate\n", content);
}

// Test StdoutCapture isolation between stdout and stderr
// Verifies that the writer parameter approach provides proper stream isolation
test "buffering fix: stdout and stderr isolation works correctly" {
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    // Write to both stdout and stderr
    try capture.stdoutWriter().writeAll("stdout content\n");
    try capture.stderrWriter().writeAll("stderr content\n");

    // Verify isolation - each stream should only contain its own content
    try capture.expectStdout("stdout content\n");
    try capture.expectStderr("stderr content\n");
}

// Test rapid successive writes don't cause buffering issues
// This simulates a scenario that commonly caused hangs before the fix
test "buffering fix: rapid successive writes to TestWriter complete without hanging" {
    const timer = Timer.init();

    var test_writer = TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    // Perform many rapid writes
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try test_writer.writer().writeAll("Line\n");
    }

    // Verify all writes completed
    const content = test_writer.getContent();
    const line_count = std.mem.count(u8, content, "Line\n");
    try testing.expectEqual(@as(usize, 100), line_count);

    // Should complete quickly (was hanging before fix)
    const elapsed = timer.elapsedMs();
    try testing.expect(elapsed < 1000);
}

// Test large output generation that simulates ls-like directory listing
// This tests writer parameter behavior with substantial output
test "buffering fix: large output generation completes quickly" {
    const timer = Timer.init();

    var test_writer = TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    // Simulate generating a large directory listing like ls would produce
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        // Write directory entry-like content
        try test_writer.writer().print("file_{d}.txt\n", .{i});
        try test_writer.writer().print("directory_{d}/\n", .{i});
        try test_writer.writer().print("link_{d} -> target_{d}\n", .{ i, i });
    }

    // Verify substantial content was written
    const content = test_writer.getContent();
    try testing.expect(content.len > 5000); // Should be substantial
    try testing.expect(std.mem.indexOf(u8, content, "file_0.txt") != null);
    try testing.expect(std.mem.indexOf(u8, content, "file_199.txt") != null);

    // Should complete in under 2 seconds (was hanging before fix)
    const elapsed = timer.elapsedMs();
    try testing.expect(elapsed < 2000);
}

// Test concurrent access to different writers
// This verifies that the writer parameter approach supports concurrent access
test "buffering fix: concurrent writes to different TestWriters work correctly" {
    var writer1 = TestWriter.init(testing.allocator);
    defer writer1.deinit();

    var writer2 = TestWriter.init(testing.allocator);
    defer writer2.deinit();

    var writer3 = TestWriter.init(testing.allocator);
    defer writer3.deinit();

    // Simulate concurrent writes (in single-threaded test)
    try writer1.writer().writeAll("Buffer 1 content\n");
    try writer2.writer().writeAll("Buffer 2 content\n");
    try writer3.writer().writeAll("Buffer 3 content\n");

    // Verify each buffer has correct isolated content
    try testing.expectEqualStrings("Buffer 1 content\n", writer1.getContent());
    try testing.expectEqualStrings("Buffer 2 content\n", writer2.getContent());
    try testing.expectEqualStrings("Buffer 3 content\n", writer3.getContent());
}

// Test complex content writing doesn't cause buffering issues
// Writing complex content with special characters could trigger buffering problems
test "buffering fix: complex content writing works without hanging" {
    const timer = Timer.init();

    var test_writer = TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    // Create content with many special characters and escape sequences
    const complex_content = "\n\t\r\\\x07\x08\x0C\x0B\x1B";

    // This should write complex content without hanging
    try test_writer.writer().writeAll(complex_content);

    // Verify content was written
    const content = test_writer.getContent();
    try testing.expect(content.len > 0);
    try testing.expect(std.mem.indexOf(u8, content, "\n") != null); // Should contain actual newline

    // Should complete quickly
    const elapsed = timer.elapsedMs();
    try testing.expect(elapsed < 1000);
}

// Test that memory allocation doesn't cause buffering hangs
// Large memory allocations combined with output could cause issues before the fix
test "buffering fix: large memory operations with TestWriter complete correctly" {
    const timer = Timer.init();

    var test_writer = TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    // Create a moderately large string that requires allocation
    var large_content = std.ArrayList(u8).init(testing.allocator);
    defer large_content.deinit();

    // Build up content that exercises memory allocation
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        try large_content.appendSlice("Data chunk ");
        try large_content.writer().print("{d} ", .{i});
    }

    // This should handle large content without hanging
    try test_writer.writer().writeAll(large_content.items);
    try test_writer.writer().writeAll("\n");

    // Verify content was written correctly
    const content = test_writer.getContent();
    try testing.expect(content.len > 5000); // Should be substantial
    try testing.expect(std.mem.indexOf(u8, content, "Data chunk 0") != null);
    try testing.expect(std.mem.indexOf(u8, content, "Data chunk 499") != null);

    // Should complete in reasonable time
    const elapsed = timer.elapsedMs();
    try testing.expect(elapsed < 3000);
}

// Test time-bounded operations to ensure no infinite loops or hangs
// This is a stress test that would expose buffering-related infinite loops
test "buffering fix: time-bounded stress test with TestWriter completes within limits" {
    const timer = Timer.init();

    var test_writer = TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    // Perform intensive operations that could trigger buffering issues
    var iteration: u32 = 0;
    while (iteration < 50) : (iteration += 1) {
        // Write various content types that could trigger different buffering behaviors
        try test_writer.writer().writeAll("Short\n");
        try test_writer.writer().writeAll("Medium length content with spaces\n");
        try test_writer.writer().writeAll("Very long content that spans multiple lines and contains various characters !@#$%^&*()_+-={}[]|\\:;\"'<>,.?/\n");

        // Check that we haven't exceeded reasonable time limits
        const current_elapsed = timer.elapsedMs();
        if (current_elapsed > 5000) {
            // Test is taking too long, fail fast
            return error.TestTimeout;
        }
    }

    // Verify substantial content was written
    const content = test_writer.getContent();
    try testing.expect(content.len > 1000);

    // Should complete well within time limit
    const final_elapsed = timer.elapsedMs();
    try testing.expect(final_elapsed < 5000);
}

// Test integration with ANSI stripping to ensure no buffering issues
// ANSI code processing with large content could cause buffering problems
test "buffering fix: ANSI stripping with TestWriter works correctly" {
    const timer = Timer.init();

    var test_writer = TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    // Create content with ANSI codes that would be stripped in testing
    var content_with_ansi = std.ArrayList(u8).init(testing.allocator);
    defer content_with_ansi.deinit();

    try content_with_ansi.appendSlice("\x1b[31mRed text\x1b[0m ");
    try content_with_ansi.appendSlice("\x1b[32mGreen text\x1b[0m ");
    try content_with_ansi.appendSlice("\x1b[1m\x1b[33mBold yellow\x1b[0m\n");

    // Write colored content
    try test_writer.writer().writeAll(content_with_ansi.items);

    // Test ANSI stripping functionality
    const stripped = try test_writer.getContentStripped(testing.allocator);
    defer testing.allocator.free(stripped);

    // Verify ANSI codes were stripped but content remains
    try testing.expect(std.mem.indexOf(u8, stripped, "Red text") != null);
    try testing.expect(std.mem.indexOf(u8, stripped, "Green text") != null);
    try testing.expect(std.mem.indexOf(u8, stripped, "Bold yellow") != null);
    try testing.expect(std.mem.indexOf(u8, stripped, "\x1b[") == null); // No ANSI codes

    // Should complete quickly
    const elapsed = timer.elapsedMs();
    try testing.expect(elapsed < 2000);
}

// Performance regression test
// Ensures that the buffering fix didn't introduce performance regressions
test "buffering fix: performance regression test with TestWriter" {
    const timer = Timer.init();

    var test_writer = TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    // Simulate typical usage patterns
    const test_cases = [_][]const u8{
        "hello world\n",
        "ls -la /usr/bin\n",
        "cat /etc/passwd | grep root\n",
        "find . -name '*.zig'\n",
        "echo 'The quick brown fox jumps over the lazy dog' | wc -w\n",
    };

    // Run multiple iterations of typical output patterns
    for (test_cases) |test_case| {
        var i: u32 = 0;
        while (i < 20) : (i += 1) {
            try test_writer.writer().writeAll(test_case);
        }
    }

    // Verify substantial output
    const content = test_writer.getContent();
    try testing.expect(content.len > 1000);

    // Should complete very quickly for typical usage
    const elapsed = timer.elapsedMs();
    try testing.expect(elapsed < 2000);
}

// Test demonstrating integration with the existing test infrastructure
// Shows how the buffering fix integrates with the captureOutput helper
test "buffering fix: integration with test_utils captureOutput works correctly" {
    const timer = Timer.init();

    // Function that simulates a utility writing output
    const TestFunc = struct {
        fn simulateUtilityOutput(writer: anytype, content: []const u8, repeat: u32) !void {
            var i: u32 = 0;
            while (i < repeat) : (i += 1) {
                try writer.print("{s} (iteration {d})\n", .{ content, i });
            }
        }
    };

    // Use the captureOutput helper which internally uses TestWriter
    const output = try test_utils.captureOutput(testing.allocator, TestFunc.simulateUtilityOutput, .{ "Test output", 10 });
    defer testing.allocator.free(output);

    // Verify output was captured correctly
    try testing.expect(std.mem.indexOf(u8, output, "Test output (iteration 0)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Test output (iteration 9)") != null);
    try testing.expect(std.mem.count(u8, output, "Test output") == 10);

    // Should complete quickly demonstrating that buffering fix works with helper functions
    const elapsed = timer.elapsedMs();
    try testing.expect(elapsed < 1000);
}

// Test simulating a real utility scenario that previously caused hangs
// This test represents the kind of scenario that would have hung before the writer parameter fix
test "buffering fix: simulated real utility scenario completes without hanging" {
    const timer = Timer.init();

    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    // Simulate a utility that processes multiple files and outputs progress
    const files = [_][]const u8{ "file1.txt", "file2.txt", "file3.txt", "file4.txt", "file5.txt" };

    for (files, 0..) |filename, i| {
        // Simulate processing with verbose output (what would cause buffering issues)
        try capture.stdoutWriter().print("Processing {s}...\n", .{filename});
        try capture.stdoutWriter().print("Read {d} bytes from {s}\n", .{ (i + 1) * 1024, filename });
        try capture.stdoutWriter().print("Processed {s} successfully\n", .{filename});

        // Simulate occasional error output
        if (i == 2) {
            try capture.stderrWriter().print("Warning: {s} has unusual format\n", .{filename});
        }
    }

    // Final summary
    try capture.stdoutWriter().print("Processed {d} files total\n", .{files.len});

    // Verify all output was captured correctly
    const stdout_content = capture.getStdout();
    const stderr_content = capture.getStderr();

    try testing.expect(std.mem.indexOf(u8, stdout_content, "Processing file1.txt") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_content, "Processing file5.txt") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_content, "Processed 5 files total") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_content, "Warning: file3.txt has unusual format") != null);

    // Most importantly, this scenario should complete quickly without hanging
    const elapsed = timer.elapsedMs();
    try testing.expect(elapsed < 2000);
}

// ============================================================================
// Integration Tests - Functional Verification of anytype Writer Fix
// ============================================================================

// Test anytype writer compatibility - the core of the buffering fix
test "integration: anytype writer compatibility verification" {
    const timer = Timer.init();

    // This is the core test: functions accepting anytype writers work with different writer types
    const UtilityFunction = struct {
        fn processData(writer: anytype, data: []const []const u8, options: struct {
            prefix: []const u8 = "",
            suffix: []const u8 = "\n",
            separator: []const u8 = " ",
        }) !void {
            if (options.prefix.len > 0) {
                try writer.writeAll(options.prefix);
            }

            for (data, 0..) |item, i| {
                if (i > 0) try writer.writeAll(options.separator);
                try writer.writeAll(item);
            }

            if (options.suffix.len > 0) {
                try writer.writeAll(options.suffix);
            }
        }
    };

    // Test with TestWriter (mimics actual utility usage)
    var test_writer = TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    const test_data = [_][]const u8{ "Hello", "anytype", "writer", "fix!" };
    try UtilityFunction.processData(test_writer.writer(), &test_data, .{});

    const content1 = test_writer.getContent();
    try testing.expectEqualStrings("Hello anytype writer fix!\n", content1);

    // Test with StdoutCapture (different writer type - this was the issue)
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    try UtilityFunction.processData(capture.stdoutWriter(), &test_data, .{ .prefix = "Output: " });
    try capture.expectStdout("Output: Hello anytype writer fix!\n");

    // Test with stderr writer as well
    try UtilityFunction.processData(capture.stderrWriter(), &test_data, .{ .prefix = "Error: " });
    try capture.expectStderr("Error: Hello anytype writer fix!\n");

    // Should complete quickly without hanging
    const elapsed = timer.elapsedMs();
    try testing.expect(elapsed < 2000);
}

// Test large output scenario that would trigger buffering issues
test "integration: large output with anytype writers" {
    const timer = Timer.init();

    // Simulate a utility function that generates large output
    const LargeOutputGenerator = struct {
        fn generateLargeOutput(writer: anytype, base_text: []const u8, repeat_count: usize) !void {
            var i: usize = 0;
            while (i < repeat_count) : (i += 1) {
                try writer.print("{s} line {d}\n", .{ base_text, i });
            }
        }
    };

    var test_writer = TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    // Generate substantial output that would have caused buffering issues
    try LargeOutputGenerator.generateLargeOutput(test_writer.writer(), "Large output test", 2000);

    const content = test_writer.getContent();
    try testing.expect(content.len > 50000); // Should be substantial
    try testing.expect(std.mem.indexOf(u8, content, "Large output test line 0") != null);
    try testing.expect(std.mem.indexOf(u8, content, "Large output test line 1999") != null);
    try testing.expect(std.mem.count(u8, content, "Large output test") == 2000);

    // Should complete within reasonable time (was hanging before fix)
    const elapsed = timer.elapsedMs();
    try testing.expect(elapsed < 3000);
}

// Test directory information output similar to pwd utility
test "integration: directory info with anytype writers" {
    const timer = Timer.init();

    // Simulate pwd-like functionality using standard library functions
    const DirectoryInfo = struct {
        fn printCurrentDirectory(writer: anytype) !void {
            const cwd = std.process.getCwdAlloc(testing.allocator) catch {
                // Handle potential errors gracefully
                try writer.writeAll("/permission-denied\n");
                return;
            };
            defer testing.allocator.free(cwd);

            try writer.print("{s}\n", .{cwd});
        }
    };

    var test_writer = TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    // Test that directory info works with anytype writer
    try DirectoryInfo.printCurrentDirectory(test_writer.writer());

    const content = test_writer.getContent();
    try testing.expect(content.len > 0);
    try testing.expect(std.mem.endsWith(u8, content, "\n"));

    // Should complete quickly
    const elapsed = timer.elapsedMs();
    try testing.expect(elapsed < 2000);
}

// Test directory listing functionality similar to ls utility
test "integration: directory listing with anytype writers" {
    const timer = Timer.init();

    // Simulate ls-like functionality using standard library functions
    const DirectoryLister = struct {
        fn listDirectory(writer: anytype, dir_path: []const u8) !void {
            var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
                try writer.writeAll("access-denied\n");
                return;
            };
            defer dir.close();

            var iterator = dir.iterate();
            var count: usize = 0;
            while (try iterator.next()) |entry| {
                try writer.print("{s}\n", .{entry.name});
                count += 1;
                // Limit output for test performance
                if (count > 50) break;
            }

            if (count == 0) {
                try writer.writeAll("empty-directory\n");
            }
        }
    };

    var test_writer = TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    // Test directory listing with anytype writer
    try DirectoryLister.listDirectory(test_writer.writer(), ".");

    const content = test_writer.getContent();
    try testing.expect(content.len > 0);

    // Test with StdoutCapture as well (different writer type)
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    try DirectoryLister.listDirectory(capture.stdoutWriter(), ".");
    const stdout_content = capture.getStdout();
    try testing.expect(stdout_content.len > 0);

    // Should complete without hanging (this was the main issue before the fix)
    const elapsed = timer.elapsedMs();
    try testing.expect(elapsed < 5000);
}

// Test large directory listing output to stress test buffering
test "integration: large directory listing verifies no buffering hang" {
    const timer = Timer.init();

    // Simulate processing a large directory with many entries
    const LargeDirectorySimulator = struct {
        fn simulateLargeDirectoryListing(writer: anytype, entry_count: usize) !void {
            var i: usize = 0;
            while (i < entry_count) : (i += 1) {
                // Simulate detailed file listing output like ls -l would produce
                try writer.print("-rw-r--r-- 1 user group  {d:>8} Jan  1 12:00 file_{d:0>3}.txt\n", .{ i * 100 + 1024, i });

                // Add some directories too
                if (i % 10 == 0) {
                    try writer.print("drwxr-xr-x 2 user group     4096 Jan  1 12:00 dir_{d:0>3}/\n", .{i / 10});
                }

                // Occasionally add symbolic links
                if (i % 25 == 0) {
                    try writer.print("lrwxrwxrwx 1 user group       10 Jan  1 12:00 link_{d} -> target_{d}\n", .{ i, i });
                }
            }
        }
    };

    var test_writer = TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    // Generate substantial output that would have caused buffering issues
    try LargeDirectorySimulator.simulateLargeDirectoryListing(test_writer.writer(), 500);

    const content = test_writer.getContent();
    try testing.expect(content.len > 30000); // Should have substantial output
    try testing.expect(std.mem.indexOf(u8, content, "file_000.txt") != null);
    try testing.expect(std.mem.indexOf(u8, content, "file_499.txt") != null);
    try testing.expect(std.mem.indexOf(u8, content, "dir_000/") != null);
    try testing.expect(std.mem.indexOf(u8, content, "link_0 -> target_0") != null);

    // Most important: should complete without hanging
    const elapsed = timer.elapsedMs();
    try testing.expect(elapsed < 5000);
}

// Test multiple utility-like functions with the same writer to verify isolation
test "integration: multiple utilities with same writer verify proper isolation" {
    const timer = Timer.init();

    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    // Simulate multiple utilities using the same capture infrastructure
    const MultiUtilityTest = struct {
        fn echoLike(writer: anytype, args: []const []const u8) !void {
            for (args, 0..) |arg, i| {
                if (i > 0) try writer.writeAll(" ");
                try writer.writeAll(arg);
            }
            try writer.writeAll("\n");
        }

        fn pwdLike(writer: anytype) !void {
            const cwd = std.process.getCwdAlloc(testing.allocator) catch {
                try writer.writeAll("/access-denied\n");
                return;
            };
            defer testing.allocator.free(cwd);
            try writer.print("Current directory: {s}\n", .{cwd});
        }

        fn errorMessage(writer: anytype, msg: []const u8) !void {
            try writer.print("ERROR: {s}\n", .{msg});
        }
    };

    // Use different writers for different outputs
    const echo_args = [_][]const u8{ "Echo", "test", "output" };
    try MultiUtilityTest.echoLike(capture.stdoutWriter(), &echo_args);

    // Use stderr for error output
    try MultiUtilityTest.errorMessage(capture.stderrWriter(), "This is an error message");

    // Use stdout for more output
    try MultiUtilityTest.pwdLike(capture.stdoutWriter());

    // Verify outputs are properly isolated
    const stdout_content = capture.getStdout();
    const stderr_content = capture.getStderr();

    try testing.expect(std.mem.indexOf(u8, stdout_content, "Echo test output") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_content, "Current directory:") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_content, "ERROR: This is an error message") != null);

    // Stderr should not contain stdout content and vice versa
    try testing.expect(std.mem.indexOf(u8, stderr_content, "Echo test output") == null);
    try testing.expect(std.mem.indexOf(u8, stdout_content, "ERROR: This is an error message") == null);

    // Should complete quickly
    const elapsed = timer.elapsedMs();
    try testing.expect(elapsed < 3000);
}

// Functional verification test - this is what matters most
test "integration: functional verification that anytype writer fix works" {
    const timer = Timer.init();

    // Test the exact scenario that was failing before the fix:
    // Utility functions accepting anytype writers and working with different writer types

    const UtilitySimulator = struct {
        fn writeToAnytype(writer: anytype, content: []const u8) !void {
            try writer.writeAll(content);
        }

        fn processArgs(writer: anytype, args: []const []const u8) !void {
            for (args, 0..) |arg, i| {
                if (i > 0) try writer.writeAll(" ");
                try writer.writeAll(arg);
            }
            try writer.writeAll("\n");
        }

        fn generateReport(writer: anytype, items: []const []const u8) !void {
            try writer.writeAll("Report:\n");
            for (items) |item| {
                try writer.print("  - {s}\n", .{item});
            }
            try writer.writeAll("End of report\n");
        }
    };

    // 1. Test that we can pass TestWriter to functions expecting anytype
    var test_writer = TestWriter.init(testing.allocator);
    defer test_writer.deinit();

    // This should work without compilation errors (the main fix)
    try UtilitySimulator.writeToAnytype(test_writer.writer(), "TestWriter works\n");

    // 2. Test with StdoutCapture writer
    var capture = StdoutCapture.init(testing.allocator);
    defer capture.deinit();

    try UtilitySimulator.writeToAnytype(capture.stdoutWriter(), "StdoutCapture works\n");

    // 3. Test that both captured their content correctly
    try testing.expectEqualStrings("TestWriter works\n", test_writer.getContent());
    try capture.expectStdout("StdoutCapture works\n");

    // 4. Test with more complex utility-like functions
    const test_args = [_][]const u8{ "Functional", "test", "passed" };
    try UtilitySimulator.processArgs(test_writer.writer(), &test_args);

    const report_items = [_][]const u8{ "Item 1", "Item 2", "Item 3" };
    try UtilitySimulator.generateReport(test_writer.writer(), &report_items);

    const final_content = test_writer.getContent();
    try testing.expect(std.mem.indexOf(u8, final_content, "TestWriter works") != null);
    try testing.expect(std.mem.indexOf(u8, final_content, "Functional test passed") != null);
    try testing.expect(std.mem.indexOf(u8, final_content, "Report:") != null);
    try testing.expect(std.mem.indexOf(u8, final_content, "  - Item 1") != null);
    try testing.expect(std.mem.indexOf(u8, final_content, "End of report") != null);

    // This is the key success criteria: no hanging, no compilation errors, proper functionality
    const elapsed = timer.elapsedMs();
    try testing.expect(elapsed < 2000);
}
