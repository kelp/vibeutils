const std = @import("std");
const testing = std.testing;
const test_utils = @import("test_utils.zig");

const LsOptions = @import("types.zig").LsOptions;
const LsTestEnv = test_utils.LsTestEnv;
const LsAssertions = test_utils.LsAssertions;
const PlatformHelpers = test_utils.PlatformHelpers;

// Import constants for readability
const TEST_SIZE_2K = test_utils.TEST_SIZE_2K;
const TEST_SIZE_1_5K = test_utils.TEST_SIZE_1_5K;
const TEST_TERMINAL_WIDTH = test_utils.TEST_TERMINAL_WIDTH;

// ============================================================================
// Basic listing functionality
// ============================================================================

test "basic: lists files in current directory" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("file1.txt", "");
    try env.createFile("file2.txt", "");

    try env.runLs(.{});

    try LsAssertions.expectContainsFile(env.getStdout(), "file1.txt");
    try LsAssertions.expectContainsFile(env.getStdout(), "file2.txt");
}

test "basic: handles empty directory" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.runLs(.{});

    try LsAssertions.expectExactOutput(env.getStdout(), "");
}

test "basic: shows directories and files together" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("file.txt", "");
    try env.createDir("subdir");

    try env.runLs(.{ .one_per_line = true });

    try LsAssertions.expectOnePerLineOrder(env.getStdout(), &.{ "file.txt", "subdir" });
}

// ============================================================================
// Hidden file handling
// ============================================================================

test "hidden: ignores hidden files by default" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("visible.txt", "");
    try env.createFile(".hidden", "");

    try env.runLs(.{});

    try LsAssertions.expectContainsFile(env.getStdout(), "visible.txt");
    try LsAssertions.expectNotContainsFile(env.getStdout(), ".hidden");
}

test "hidden: shows hidden files with -a flag" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("visible.txt", "");
    try env.createFile(".hidden", "");

    try env.runLs(.{ .all = true });

    try LsAssertions.expectContainsFile(env.getStdout(), "visible.txt");
    try LsAssertions.expectContainsFile(env.getStdout(), ".hidden");
}

test "hidden: shows almost all files with -A flag" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("visible.txt", "");
    try env.createFile(".hidden", "");

    try env.runLs(.{ .almost_all = true, .one_per_line = true });

    try LsAssertions.expectContainsFile(env.getStdout(), "visible.txt");
    try LsAssertions.expectContainsFile(env.getStdout(), ".hidden");
}

// ============================================================================
// Format options
// ============================================================================

test "format: one file per line with -1 flag" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("aaa.txt", "");
    try env.createFile("bbb.txt", "");

    try env.runLs(.{ .one_per_line = true });

    try LsAssertions.expectOnePerLineOrder(env.getStdout(), &.{ "aaa.txt", "bbb.txt" });
}

test "format: comma-separated output with -m flag" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("aaa.txt", "");
    try env.createFile("bbb.txt", "");
    try env.createFile("ccc.txt", "");

    try env.runLs(.{ .comma_format = true });

    try LsAssertions.expectCommaFormat(env.getStdout(), "aaa.txt, bbb.txt, ccc.txt\n");
}

test "format: multi-column output by default" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Create several files with different name lengths
    const files = [_][]const u8{ "a", "bb", "ccc", "dddd", "eeeee", "ffffff", "ggggggg", "hhhhhhhh" };
    for (files) |name| {
        try env.createFile(name, "");
    }

    try env.runLs(.{ .terminal_width = TEST_TERMINAL_WIDTH });

    try LsAssertions.expectMultiColumnFormat(env.getStdout(), files.len);
}

// ============================================================================
// Long format options
// ============================================================================

test "long_format: shows detailed information with -l flag" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("test.txt", "Hello, World!");

    try env.runLs(.{ .long_format = true });

    const output = env.getStdout();
    try LsAssertions.expectContainsFile(output, "test.txt");
    try LsAssertions.expectContainsPermissions(output, "-rw-");
    try LsAssertions.expectContainsFile(output, "13"); // Size of "Hello, World!"
    try LsAssertions.expectContainsFile(output, "total"); // Total blocks line
}

test "long_format: shows human readable sizes with -lh flags" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFileWithSize("large.txt", TEST_SIZE_2K, 'A');

    try env.runLs(.{ .long_format = true, .human_readable = true });

    try LsAssertions.expectHumanReadableSize(env.getStdout(), "2.0K");
}

test "long_format: shows kilobyte sizes with -lk flags" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("small.txt", "Hi");
    try env.createFileWithSize("medium.txt", TEST_SIZE_1_5K, 'B');

    try env.runLs(.{ .long_format = true, .kilobytes = true });

    const output = env.getStdout();
    try LsAssertions.expectContainsFile(output, "small.txt");
    try LsAssertions.expectContainsFile(output, "medium.txt");
}

test "long_format: shows numeric user and group IDs with -n flag" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("test.txt", "test content");

    try env.runLs(.{ .long_format = true, .numeric_ids = true });

    const output = env.getStdout();
    try LsAssertions.expectContainsFile(output, "test.txt");
    try LsAssertions.expectContainsPermissions(output, "-rw-");
}

// ============================================================================
// Symlink handling
// ============================================================================

test "symlinks: shows symlink targets in long format" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("target.txt", "Hello, World!");
    try env.createDir("target_dir");
    try env.createSymlink("target.txt", "link_to_file");
    try env.createSymlink("target_dir", "link_to_dir");
    try env.createSymlink("nonexistent", "broken_link");

    try env.runLs(.{ .long_format = true });

    const output = env.getStdout();
    try LsAssertions.expectSymlinkTarget(output, "link_to_file", "target.txt");
    try LsAssertions.expectSymlinkTarget(output, "link_to_dir", "target_dir");
    try LsAssertions.expectSymlinkTarget(output, "broken_link", "nonexistent");
    try LsAssertions.expectContainsPermissions(output, "lrwx"); // Symlink permissions
}

// ============================================================================
// File type indicators
// ============================================================================

test "file_type: adds indicators with -F flag" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("regular.txt", "");
    try env.createDir("directory");

    if (PlatformHelpers.supportsExecutableBit()) {
        try env.createExecutableFile("executable");
    }

    try env.runLs(.{ .file_type_indicators = true, .one_per_line = true });

    const output = env.getStdout();
    try LsAssertions.expectFileTypeIndicator(output, "directory/");
    try LsAssertions.expectContainsFile(output, "regular.txt");
    try LsAssertions.expectNotContainsFile(output, "regular.txt/");
    try LsAssertions.expectNotContainsFile(output, "regular.txt*");

    if (PlatformHelpers.supportsExecutableBit()) {
        try LsAssertions.expectFileTypeIndicator(output, "executable*");
    }
}

// ============================================================================
// Directory listing options
// ============================================================================

test "directory: lists directory itself with -d flag" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("file1.txt", "");
    try env.createFile("file2.txt", "");
    try env.createDir("subdir");

    try env.runLs(.{ .directory = true });

    try LsAssertions.expectExactOutput(env.getStdout(), ".\n");
}

// ============================================================================
// Inode display
// ============================================================================

test "inodes: shows inode numbers with -i flag" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("test.txt", "");

    try env.runLs(.{ .show_inodes = true, .one_per_line = true });

    const output = env.getStdout();
    try LsAssertions.expectContainsFile(output, "test.txt");
    try LsAssertions.expectContainsNumeric(output, "inode numbers");
}

// ============================================================================
// Recursive listing
// ============================================================================

test "recursive: lists subdirectories with proper structure" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Create complex directory structure
    try env.createFile("file1.txt", "");
    try env.createDir("dir1");

    var dir1 = try env.createDirAndOpen("dir1");
    defer dir1.close();

    const file2 = try dir1.createFile("file2.txt", .{});
    file2.close();

    try dir1.makeDir("subdir1");
    var subdir1 = try dir1.openDir("subdir1", .{});
    defer subdir1.close();

    const file3 = try subdir1.createFile("file3.txt", .{});
    file3.close();

    try env.runLs(.{ .recursive = true, .one_per_line = true });

    const output = env.getStdout();
    try LsAssertions.expectContainsFile(output, "file1.txt");
    try LsAssertions.expectContainsFile(output, "dir1");
    try LsAssertions.expectContainsFile(output, "file2.txt");
    try LsAssertions.expectContainsFile(output, "file3.txt");
}

test "recursive: shows directory headers with proper formatting" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createDir("dir1");
    try env.createDir("dir2");

    var dir1 = try env.createDirAndOpen("dir1");
    defer dir1.close();
    try dir1.makeDir("subdir");

    try env.runLs(.{ .recursive = true });

    const output = env.getStdout();
    try LsAssertions.expectDirectoryHeader(output, "./dir1:");
    try LsAssertions.expectDirectoryHeader(output, "./dir2:");
    try LsAssertions.expectDirectoryHeader(output, "./dir1/subdir:");
}

test "recursive: handles symlink cycles safely" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createDir("dir1");

    var dir1 = try env.createDirAndOpen("dir1");
    defer dir1.close();

    // Create a symlink back to parent directory
    try dir1.symLink("..", "parent_link", .{});

    try env.runLs(.{ .recursive = true });

    // Should contain the symlink but not recurse infinitely
    try LsAssertions.expectContainsFile(env.getStdout(), "parent_link");
}
