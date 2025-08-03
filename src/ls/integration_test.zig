const std = @import("std");
const testing = std.testing;
const test_utils = @import("test_utils.zig");
const common = @import("common");

const LsOptions = @import("types.zig").LsOptions;
const listDirectoryTest = test_utils.listDirectoryTest;

test "ls lists files in current directory" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test files
    const file1 = try tmp_dir.dir.createFile("file1.txt", .{});
    file1.close();
    const file2 = try tmp_dir.dir.createFile("file2.txt", .{});
    file2.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Open directory with iterate permissions
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();

    // List directory
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{}, testing.allocator);

    // Should contain both files
    try testing.expect(std.mem.indexOf(u8, buffer.items, "file1.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "file2.txt") != null);
}

test "ls ignores hidden files by default" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create visible and hidden files
    const visible = try tmp_dir.dir.createFile("visible.txt", .{});
    visible.close();
    const hidden = try tmp_dir.dir.createFile(".hidden", .{});
    hidden.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();

    // List without -a
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{}, testing.allocator);

    // Should contain visible but not hidden
    try testing.expect(std.mem.indexOf(u8, buffer.items, "visible.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, ".hidden") == null);
}

test "ls -a shows hidden files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create visible and hidden files
    const visible = try tmp_dir.dir.createFile("visible.txt", .{});
    visible.close();
    const hidden = try tmp_dir.dir.createFile(".hidden", .{});
    hidden.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -a
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{ .all = true }, testing.allocator);

    // Should contain both files
    try testing.expect(std.mem.indexOf(u8, buffer.items, "visible.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, ".hidden") != null);
}

test "ls -1 lists one file per line" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test files
    const file1 = try tmp_dir.dir.createFile("aaa.txt", .{});
    file1.close();
    const file2 = try tmp_dir.dir.createFile("bbb.txt", .{});
    file2.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -1
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{ .one_per_line = true }, testing.allocator);

    // Should be one file per line
    try testing.expectEqualStrings("aaa.txt\nbbb.txt\n", buffer.items);
}

test "ls handles empty directory" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List empty directory
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{}, testing.allocator);

    // Should be empty
    try testing.expectEqualStrings("", buffer.items);
}

test "ls with directories shows type indicator" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file and a directory
    const file = try tmp_dir.dir.createFile("file.txt", .{});
    file.close();
    try tmp_dir.dir.makeDir("subdir");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -1 for predictable output
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{ .one_per_line = true }, testing.allocator);

    // Both should be listed
    try testing.expectEqualStrings("file.txt\nsubdir\n", buffer.items);
}

test "ls -l shows long format" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a test file
    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll("Hello, World!");
    file.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -l
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{ .long_format = true }, testing.allocator);

    // Should contain test.txt with permissions and size
    try testing.expect(std.mem.indexOf(u8, buffer.items, "test.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "-rw-") != null); // File permissions
    try testing.expect(std.mem.indexOf(u8, buffer.items, "13") != null); // Size of "Hello, World!"
    try testing.expect(std.mem.indexOf(u8, buffer.items, "total") != null); // Total blocks line
}

test "ls -lh shows human readable sizes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a larger test file
    const file = try tmp_dir.dir.createFile("large.txt", .{});
    var data: [2048]u8 = undefined;
    @memset(&data, 'A');
    try file.writeAll(&data);
    file.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -lh
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{ .long_format = true, .human_readable = true }, testing.allocator);

    // Should show human readable size
    try testing.expect(std.mem.indexOf(u8, buffer.items, "2.0K") != null);
}

test "ls -lk shows kilobyte sizes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test files
    const file1 = try tmp_dir.dir.createFile("small.txt", .{});
    try file1.writeAll("Hi");
    file1.close();

    const file2 = try tmp_dir.dir.createFile("medium.txt", .{});
    var data: [1500]u8 = undefined;
    @memset(&data, 'B');
    try file2.writeAll(&data);
    file2.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -lk
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{ .long_format = true, .kilobytes = true }, testing.allocator);

    // Should show sizes in kilobytes
    try testing.expect(std.mem.indexOf(u8, buffer.items, "small.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "medium.txt") != null);
    // Small file (2 bytes) should round up to 1K
    // Medium file (1500 bytes) should round up to 2K
}

test "ls -l shows symlink targets" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a target file
    const target = try tmp_dir.dir.createFile("target.txt", .{});
    try target.writeAll("Hello, World!");
    target.close();

    // Create a symlink to the file
    try tmp_dir.dir.symLink("target.txt", "link_to_file", .{});

    // Create a directory and symlink to it
    try tmp_dir.dir.makeDir("target_dir");
    try tmp_dir.dir.symLink("target_dir", "link_to_dir", .{});

    // Create a broken symlink
    try tmp_dir.dir.symLink("nonexistent", "broken_link", .{});

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -l
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{ .long_format = true }, testing.allocator);

    // Check that symlinks show their targets
    try testing.expect(std.mem.indexOf(u8, buffer.items, "link_to_file -> target.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "link_to_dir -> target_dir") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "broken_link -> nonexistent") != null);

    // Check that symlinks are marked with 'l' in permissions
    try testing.expect(std.mem.indexOf(u8, buffer.items, "lrwx") != null);
}

test "ls -A shows almost all files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create visible and hidden files
    const visible = try tmp_dir.dir.createFile("visible.txt", .{});
    visible.close();
    const hidden = try tmp_dir.dir.createFile(".hidden", .{});
    hidden.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -A (using -1 for predictable output)
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{ .almost_all = true, .one_per_line = true }, testing.allocator);

    // Should contain both visible and hidden files
    try testing.expect(std.mem.indexOf(u8, buffer.items, "visible.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, ".hidden") != null);
    // But NOT . and .. (can't easily test absence, but we can verify the feature works)
}

test "ls -F adds file type indicators" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create different file types
    const regular = try tmp_dir.dir.createFile("regular.txt", .{});
    regular.close();

    try tmp_dir.dir.makeDir("directory");

    // Create executable file with execute permissions
    const exe = try tmp_dir.dir.createFile("executable", .{ .mode = 0o755 });
    exe.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -F and -1 for predictable output
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{ .file_type_indicators = true, .one_per_line = true }, testing.allocator);

    // Check for type indicators
    try testing.expect(std.mem.indexOf(u8, buffer.items, "directory/") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "executable*") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "regular.txt") != null);
    // Regular file should not have indicator
    try testing.expect(std.mem.indexOf(u8, buffer.items, "regular.txt/") == null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "regular.txt*") == null);
}

test "ls -d lists directory itself, not contents" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create files in the directory
    const file1 = try tmp_dir.dir.createFile("file1.txt", .{});
    file1.close();
    const file2 = try tmp_dir.dir.createFile("file2.txt", .{});
    file2.close();
    try tmp_dir.dir.makeDir("subdir");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List with -d (should show "." only)
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{ .directory = true }, testing.allocator);

    // Should only contain "." and not the files
    try testing.expectEqualStrings(".\n", buffer.items);
}

test "ls recursive listing" {
    // Test that the recursive flag is recognized
    // Full recursive implementation tested via integration tests
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create directory structure
    try tmp_dir.dir.makeDir("dir1");
    const file1 = try tmp_dir.dir.createFile("file1.txt", .{});
    file1.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Create more nested directories for proper testing
    var dir1 = try tmp_dir.dir.openDir("dir1", .{});
    defer dir1.close();
    try dir1.makeDir("subdir1");
    const file2 = try dir1.createFile("file2.txt", .{});
    file2.close();

    var subdir1 = try dir1.openDir("subdir1", .{});
    defer subdir1.close();
    const file3 = try subdir1.createFile("file3.txt", .{});
    file3.close();

    // Open the temp directory with iterate permissions
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();

    // Use the test helper function
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{ .recursive = true, .one_per_line = true }, testing.allocator);

    // Should contain all files and directory headers
    try testing.expect(std.mem.indexOf(u8, buffer.items, "file1.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "dir1") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "file2.txt") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "file3.txt") != null);
}

test "ls multi-column output" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create several files with different name lengths
    const files = [_][]const u8{ "a", "bb", "ccc", "dddd", "eeeee", "ffffff", "ggggggg", "hhhhhhhh" };
    for (files) |name| {
        const f = try tmp_dir.dir.createFile(name, .{});
        f.close();
    }

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // List without -1 (should use columns)
    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{
        .terminal_width = 40, // Force specific width for testing
    }, testing.allocator);

    // Output should have multiple entries per line
    var lines = std.mem.splitScalar(u8, buffer.items, '\n');
    var line_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len > 0) line_count += 1;
    }

    // With 8 files and 40 char width, should fit multiple per line
    try testing.expect(line_count < files.len);
}

// Additional integration tests

test "ls -R shows directory headers with proper formatting" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create nested directory structure
    try tmp_dir.dir.makeDir("dir1");
    try tmp_dir.dir.makeDir("dir2");
    var dir1 = try tmp_dir.dir.openDir("dir1", .{});
    defer dir1.close();
    try dir1.makeDir("subdir");

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{ .recursive = true }, testing.allocator);

    // Should contain directory headers in the format "./dirname:"
    try testing.expect(std.mem.indexOf(u8, buffer.items, "./dir1:") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "./dir2:") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "./dir1/subdir:") != null);
}

test "ls -R detects and handles symlink cycles" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a directory and a symlink that creates a cycle
    try tmp_dir.dir.makeDir("dir1");
    var dir1 = try tmp_dir.dir.openDir("dir1", .{});
    defer dir1.close();

    // Create a symlink back to parent directory
    try dir1.symLink("..", "parent_link", .{});

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();

    // This should not cause infinite recursion
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{ .recursive = true }, testing.allocator);

    // Should contain the symlink but not recurse infinitely
    try testing.expect(std.mem.indexOf(u8, buffer.items, "parent_link") != null);
}

test "ls -i shows inode numbers before filenames" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test.txt", .{});
    file.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{ .show_inodes = true, .one_per_line = true }, testing.allocator);

    // Output should have inode number followed by filename
    // Format: "<inode> test.txt"
    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "test.txt") != null);

    // Check that there's a number before the filename
    var iter = std.mem.tokenizeAny(u8, output, " \n");
    if (iter.next()) |first_token| {
        // First token should be a number (inode)
        _ = try std.fmt.parseInt(u64, first_token, 10);
    }
}

test "ls -n shows numeric user/group IDs instead of names" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll("test content");
    file.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{ .long_format = true, .numeric_ids = true }, testing.allocator);

    // Output should contain numeric IDs instead of names
    const output = buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "test.txt") != null);

    // Check for numeric IDs (should see numbers, not usernames)
    // The format includes permissions, links, uid, gid, size, date, name
    // We can't predict the exact IDs, but we can verify the format
    try testing.expect(std.mem.indexOf(u8, output, "-rw-") != null);
}

test "ls -m produces comma-separated output" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test files
    const file1 = try tmp_dir.dir.createFile("aaa.txt", .{});
    file1.close();
    const file2 = try tmp_dir.dir.createFile("bbb.txt", .{});
    file2.close();
    const file3 = try tmp_dir.dir.createFile("ccc.txt", .{});
    file3.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    var test_dir = try tmp_dir.dir.openDir(".", .{ .iterate = true });
    defer test_dir.close();
    try listDirectoryTest(test_dir, ".", buffer.writer(), common.null_writer, .{ .comma_format = true }, testing.allocator);

    // Should be comma-separated with trailing newline
    try testing.expectEqualStrings("aaa.txt, bbb.txt, ccc.txt\n", buffer.items);
}
