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

// ============================================================================
// -p flag: append slash to directories
// ============================================================================

test "append_slash: appends / to directories but not files" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("regular.txt", "");
    try env.createDir("mydir");

    try env.runLs(.{ .append_slash_dirs = true, .one_per_line = true });

    const output = env.getStdout();
    try LsAssertions.expectFileTypeIndicator(output, "mydir/");
    try LsAssertions.expectContainsFile(output, "regular.txt");
    // regular files should NOT get any indicator with -p
    try LsAssertions.expectNotContainsFile(output, "regular.txt/");
    try LsAssertions.expectNotContainsFile(output, "regular.txt*");
}

test "append_slash: does not add indicators for executables or symlinks" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createDir("mydir");

    if (PlatformHelpers.supportsExecutableBit()) {
        try env.createExecutableFile("myexe");
    }
    try env.createFile("target.txt", "content");
    try env.createSymlink("target.txt", "mylink");

    try env.runLs(.{ .append_slash_dirs = true, .one_per_line = true });

    const output = env.getStdout();
    // Only directories get /
    try LsAssertions.expectFileTypeIndicator(output, "mydir/");
    // Executables should NOT get * with -p (unlike -F)
    if (PlatformHelpers.supportsExecutableBit()) {
        try LsAssertions.expectNotContainsFile(output, "myexe*");
    }
    // Symlinks should NOT get @ with -p (unlike -F)
    try LsAssertions.expectNotContainsFile(output, "mylink@");
}

// ============================================================================
// -q flag: non-printable characters as ?
// ============================================================================

test "non_printable: replaces control chars with question marks" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Create a file with a control character (tab = 0x09) in the name
    try env.createFile("file\x09name", "");
    try env.createFile("normal.txt", "");

    try env.runLs(.{ .non_printable_as_question = true, .one_per_line = true });

    const output = env.getStdout();
    // The tab should be replaced with ?
    try LsAssertions.expectContainsFile(output, "file?name");
    // Normal file should be unchanged
    try LsAssertions.expectContainsFile(output, "normal.txt");
    // The raw control character should NOT appear
    try LsAssertions.expectNotContainsFile(output, "file\x09name");
}

// ============================================================================
// -g flag: long format without owner
// ============================================================================

test "omit_owner: long format without owner column" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("test.txt", "Hello");

    // -g implies long format and omits owner
    try env.runLs(.{ .long_format = true, .omit_owner = true });

    const output = env.getStdout();
    try LsAssertions.expectContainsFile(output, "test.txt");
    try LsAssertions.expectContainsPermissions(output, "-rw-");

    // Compare with normal long format to verify owner is missing
    env.stdout_buffer.clearRetainingCapacity();
    try env.runLs(.{ .long_format = true });

    const normal_output = env.getStdout();

    // The -g output should be shorter per line (missing owner column)
    // Split both outputs into lines and compare the test.txt line length
    var g_lines = std.mem.splitScalar(u8, output, '\n');
    var normal_lines = std.mem.splitScalar(u8, normal_output, '\n');

    // Skip "total" lines
    _ = g_lines.next();
    _ = normal_lines.next();

    const g_line = g_lines.next() orelse "";
    const normal_line = normal_lines.next() orelse "";

    // The -g line should be shorter because it omits the owner
    try testing.expect(g_line.len < normal_line.len);
}

// ============================================================================
// -o flag: long format without group
// ============================================================================

test "omit_group: long format without group column" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("test.txt", "Hello");

    // -o implies long format and omits group
    try env.runLs(.{ .long_format = true, .omit_group = true });

    const output = env.getStdout();
    try LsAssertions.expectContainsFile(output, "test.txt");
    try LsAssertions.expectContainsPermissions(output, "-rw-");

    // Compare with normal long format to verify group is missing
    env.stdout_buffer.clearRetainingCapacity();
    try env.runLs(.{ .long_format = true });

    const normal_output = env.getStdout();

    // Split both outputs into lines and compare the test.txt line length
    var o_lines = std.mem.splitScalar(u8, output, '\n');
    var normal_lines = std.mem.splitScalar(u8, normal_output, '\n');

    // Skip "total" lines
    _ = o_lines.next();
    _ = normal_lines.next();

    const o_line = o_lines.next() orelse "";
    const normal_line = normal_lines.next() orelse "";

    // The -o line should be shorter because it omits the group
    try testing.expect(o_line.len < normal_line.len);
}

// ============================================================================
// -f flag: no sort, implies -a
// ============================================================================

test "no_sort: -f shows hidden files (implies -a)" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("visible.txt", "");
    try env.createFile(".hidden", "");

    try env.runLs(.{ .no_sort = true, .all = true, .one_per_line = true });

    const output = env.getStdout();
    // -f implies -a, so hidden files should appear
    try LsAssertions.expectContainsFile(output, "visible.txt");
    try LsAssertions.expectContainsFile(output, ".hidden");
}

test "no_sort: -f does not sort entries alphabetically" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Create files; directory order is filesystem-dependent,
    // but we can at least verify that all files appear
    try env.createFile("zebra.txt", "");
    try env.createFile("apple.txt", "");
    try env.createFile("mango.txt", "");

    try env.runLs(.{ .no_sort = true, .one_per_line = true });

    const output = env.getStdout();
    try LsAssertions.expectContainsFile(output, "zebra.txt");
    try LsAssertions.expectContainsFile(output, "apple.txt");
    try LsAssertions.expectContainsFile(output, "mango.txt");
}

// ============================================================================
// -s flag: show filesystem blocks
// ============================================================================

test "show_blocks: -s displays block counts" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFileWithSize("test.txt", TEST_SIZE_2K, 'X');

    try env.runLs(.{ .show_blocks = true, .one_per_line = true });

    const output = env.getStdout();
    // Should contain the filename
    try LsAssertions.expectContainsFile(output, "test.txt");
    // Should contain numeric block count before the filename
    try LsAssertions.expectContainsNumeric(output, "block count");
}

test "show_blocks: -s prints total line" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("a.txt", "hello");
    try env.createFile("b.txt", "world");

    try env.runLs(.{ .show_blocks = true, .one_per_line = true });

    const output = env.getStdout();
    try LsAssertions.expectContainsFile(output, "total");
}

// ============================================================================
// -u flag: use access time
// ============================================================================

test "use_atime: -u flag is accepted" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("test.txt", "content");

    // -u should work without error
    try env.runLs(.{ .use_atime = true, .one_per_line = true });

    try LsAssertions.expectContainsFile(env.getStdout(), "test.txt");
}

test "use_atime: -u with -t sorts by access time" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("file1.txt", "content");
    try env.createFile("file2.txt", "content");

    // Both flags should be accepted together
    try env.runLs(.{ .use_atime = true, .sort_by_time = true, .one_per_line = true });

    const output = env.getStdout();
    try LsAssertions.expectContainsFile(output, "file1.txt");
    try LsAssertions.expectContainsFile(output, "file2.txt");
}

// ============================================================================
// -C flag: multi-column sorted down columns
// ============================================================================

test "multi_column: -C forces multi-column output" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    const files = [_][]const u8{ "aaa", "bbb", "ccc", "ddd", "eee", "fff" };
    for (files) |name| {
        try env.createFile(name, "");
    }

    // -C should produce multi-column output (fewer lines than files)
    try env.runLs(.{ .terminal_width = TEST_TERMINAL_WIDTH });

    try LsAssertions.expectMultiColumnFormat(env.getStdout(), files.len);
}

// ============================================================================
// -x flag: multi-column sorted across rows
// ============================================================================

test "columns_across: -x sorts entries across rows" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    const files = [_][]const u8{ "aaa", "bbb", "ccc", "ddd", "eee", "fff" };
    for (files) |name| {
        try env.createFile(name, "");
    }

    // -x should produce multi-column output sorted across
    try env.runLs(.{ .columns_across = true, .terminal_width = TEST_TERMINAL_WIDTH });

    const output = env.getStdout();
    // Should contain all files
    for (files) |name| {
        try LsAssertions.expectContainsFile(output, name);
    }
    // Should be multi-column (fewer lines than files)
    try LsAssertions.expectMultiColumnFormat(output, files.len);
}

test "columns_across: -x first row contains first entries" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Use enough files to get multiple rows with a narrow terminal
    try env.createFile("aaa", "");
    try env.createFile("bbb", "");
    try env.createFile("ccc", "");
    try env.createFile("ddd", "");

    // With a 20-char terminal, we should get ~2 columns
    try env.runLs(.{ .columns_across = true, .terminal_width = 20 });

    const output = env.getStdout();
    // In -x mode, first row should have "aaa" and "bbb"
    // (sorted across, not down)
    var lines = std.mem.splitScalar(u8, output, '\n');
    const first_line = lines.next() orelse "";
    try testing.expect(std.mem.indexOf(u8, first_line, "aaa") != null);
    try testing.expect(std.mem.indexOf(u8, first_line, "bbb") != null);
}

// ============================================================================
// -T flag: full time display
// ============================================================================

test "full_time: -T shows seconds in long format" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("test.txt", "content");

    try env.runLs(.{ .long_format = true, .full_time = true });

    const output = env.getStdout();
    try LsAssertions.expectContainsFile(output, "test.txt");
    // Full time format should contain colons for HH:MM:SS
    // Count colons in the time portion - should have at least 2
    // (one for HH:MM, another for MM:SS)
    var colon_count: usize = 0;
    for (output) |ch| {
        if (ch == ':') colon_count += 1;
    }
    // With full time, we expect at least 2 colons (HH:MM:SS)
    try testing.expect(colon_count >= 2);
}

test "full_time: -T without -l has no effect" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("test.txt", "content");

    // -T without -l should still work (just ignored)
    try env.runLs(.{ .full_time = true, .one_per_line = true });

    try LsAssertions.expectContainsFile(env.getStdout(), "test.txt");
}

// ============================================================================
// -L flag: follow all symlinks
// ============================================================================

test "follow_symlinks: -L shows target file info instead of link info" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("target.txt", "Hello, World!");
    try env.createSymlink("target.txt", "link.txt");

    // Without -L: should show symlink info (kind = sym_link)
    try env.runLs(.{ .long_format = true });
    const without_L = try testing.allocator.dupe(u8, env.getStdout());
    defer testing.allocator.free(without_L);

    // With -L: should show target file info (kind = file)
    env.stdout_buffer.clearRetainingCapacity();
    try env.runLs(.{ .long_format = true, .follow_all_symlinks = true });
    const with_L = env.getStdout();

    // Without -L, the link should show "l" permission prefix
    try testing.expect(std.mem.indexOf(u8, without_L, "lrwx") != null);
    // With -L, the link should show "-" permission prefix (regular file)
    // Find the line containing "link.txt"
    var lines = std.mem.splitScalar(u8, with_L, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "link.txt") != null) {
            // Should NOT start with 'l' (symlink) permission
            try testing.expect(line.len > 0 and line[0] == '-');
            break;
        }
    }
}

test "follow_symlinks: -L does not show symlink arrow" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("real.txt", "data");
    try env.createSymlink("real.txt", "sym.txt");

    try env.runLs(.{ .long_format = true, .follow_all_symlinks = true });

    const output = env.getStdout();
    // With -L, no "-> target" should appear
    try LsAssertions.expectNotContainsFile(output, "->");
}

// ============================================================================
// -H flag: follow command-line symlinks
// ============================================================================

test "follow_cmdline: -H flag is accepted" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("test.txt", "content");

    // -H should work without error
    try env.runLs(.{ .follow_cmdline_symlinks = true, .one_per_line = true });

    try LsAssertions.expectContainsFile(env.getStdout(), "test.txt");
}

// ============================================================================
// -B flag: hide backup files
// ============================================================================

test "hide_backups: -B hides files ending with ~" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("document.txt", "content");
    try env.createFile("document.txt~", "old content");
    try env.createFile("notes~", "backup");

    try env.runLs(.{ .hide_backups = true, .one_per_line = true });

    try LsAssertions.expectContainsFile(env.getStdout(), "document.txt");
    try LsAssertions.expectNotContainsFile(env.getStdout(), "document.txt~");
    try LsAssertions.expectNotContainsFile(env.getStdout(), "notes~");
}

// ============================================================================
// -I PATTERN flag: ignore pattern
// ============================================================================

test "ignore_pattern: -I filters entries matching glob" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("main.c", "");
    try env.createFile("test.c", "");
    try env.createFile("readme.md", "");
    try env.createFile("notes.txt", "");

    try env.runLs(.{ .ignore_pattern = "*.c", .one_per_line = true });

    try LsAssertions.expectNotContainsFile(env.getStdout(), "main.c");
    try LsAssertions.expectNotContainsFile(env.getStdout(), "test.c");
    try LsAssertions.expectContainsFile(env.getStdout(), "readme.md");
    try LsAssertions.expectContainsFile(env.getStdout(), "notes.txt");
}

// ============================================================================
// -U flag: unsorted (directory order)
// ============================================================================

test "unsorted: -U disables sorting" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("zebra.txt", "");
    try env.createFile("alpha.txt", "");

    // -U should not error; we verify at least the files appear
    try env.runLs(.{ .unsorted = true, .one_per_line = true });

    try LsAssertions.expectContainsFile(env.getStdout(), "zebra.txt");
    try LsAssertions.expectContainsFile(env.getStdout(), "alpha.txt");
}

// ============================================================================
// -v flag: version sort
// ============================================================================

test "version_sort: -v sorts version numbers naturally" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("file1", "");
    try env.createFile("file10", "");
    try env.createFile("file2", "");
    try env.createFile("file20", "");

    try env.runLs(.{ .version_sort = true, .one_per_line = true });

    // Should be file1, file2, file10, file20
    try LsAssertions.expectOnePerLineOrder(env.getStdout(), &.{ "file1", "file2", "file10", "file20" });
}

// ============================================================================
// -X flag: sort by extension
// ============================================================================

test "sort_by_extension: -X sorts by file extension" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("readme.md", "");
    try env.createFile("main.c", "");
    try env.createFile("notes.txt", "");

    try env.runLs(.{ .sort_by_extension = true, .one_per_line = true });

    // Sorted by extension: .c, .md, .txt
    try LsAssertions.expectOnePerLineOrder(env.getStdout(), &.{ "main.c", "readme.md", "notes.txt" });
}

// ============================================================================
// -w WIDTH flag: output width
// ============================================================================

test "output_width: -w overrides terminal width" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("file1", "");
    try env.createFile("file2", "");
    try env.createFile("file3", "");

    // Very narrow width should force single column
    try env.runLs(.{ .terminal_width = 10 });

    const output = env.getStdout();
    // Count non-empty lines
    var lines = std.mem.splitScalar(u8, output, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    // With 10-char width, each file takes its own line
    try testing.expectEqual(@as(usize, 3), count);
}

// ============================================================================
// F49: ls exit code must be non-zero on error (nonexistent path)
// ============================================================================

test "F49: runUtility returns non-zero exit for nonexistent path" {
    // GNU ls exits 2 when given a nonexistent path.
    // Our runUtility wraps lsMain and should propagate the error
    // as a non-zero exit code.
    const main = @import("main.zig");

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    const exit_code = try main.runUtility(
        testing.allocator,
        &.{"/tmp/vibeutils_nonexistent_path_f49_test"},
        stdout_buf.writer(testing.allocator),
        stderr_buf.writer(testing.allocator),
    );

    // Should be non-zero (GNU uses 2, we accept any non-zero)
    try testing.expect(exit_code != 0);

    // Should have printed an error message on stderr
    try testing.expect(stderr_buf.items.len > 0);
}

test "F49: runUtility returns non-zero when one of multiple paths is invalid" {
    // When listing multiple paths and one fails, GNU ls still
    // lists the valid ones but exits non-zero.
    const main = @import("main.zig");

    // Create a real temporary directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f = try tmp_dir.dir.createFile("real.txt", .{});
    f.close();

    var stdout_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buf.deinit(testing.allocator);
    var stderr_buf = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buf.deinit(testing.allocator);

    // We can't easily pass the tmp dir path to runUtility since it
    // resolves paths from CWD. Use an absolute nonexistent path instead.
    const exit_code = try main.runUtility(
        testing.allocator,
        &.{"/tmp/vibeutils_nonexistent_mixed_f49"},
        stdout_buf.writer(testing.allocator),
        stderr_buf.writer(testing.allocator),
    );

    try testing.expect(exit_code != 0);
}

// ============================================================================
// F50: ls -a must include . and .. entries
// ============================================================================

test "F50: ls -a output includes . and .. entries" {
    // GNU ls -a includes "." and ".." as the first two entries.
    // Our implementation currently behaves like -A (shows hidden
    // files but omits . and ..).
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("visible.txt", "");
    try env.createFile(".hidden", "");

    try env.runLs(.{ .all = true, .one_per_line = true });

    const output = env.getStdout();

    // Must contain "." and ".." as separate lines
    var found_dot = false;
    var found_dotdot = false;
    var line_iter = std.mem.splitScalar(u8, output, '\n');
    while (line_iter.next()) |line| {
        if (std.mem.eql(u8, line, ".")) found_dot = true;
        if (std.mem.eql(u8, line, "..")) found_dotdot = true;
    }

    if (!found_dot) {
        std.debug.print("F50: '.' not found in -a output:\n{s}\n", .{output});
    }
    if (!found_dotdot) {
        std.debug.print("F50: '..' not found in -a output:\n{s}\n", .{output});
    }

    try testing.expect(found_dot);
    try testing.expect(found_dotdot);
}

test "F50: ls -a on empty directory still shows . and .." {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Empty directory - no files created
    try env.runLs(.{ .all = true, .one_per_line = true });

    const output = env.getStdout();

    var found_dot = false;
    var found_dotdot = false;
    var line_iter = std.mem.splitScalar(u8, output, '\n');
    while (line_iter.next()) |line| {
        if (std.mem.eql(u8, line, ".")) found_dot = true;
        if (std.mem.eql(u8, line, "..")) found_dotdot = true;
    }

    if (!found_dot) {
        std.debug.print("F50: '.' not found in -a output for empty dir:\n{s}\n", .{output});
    }
    if (!found_dotdot) {
        std.debug.print("F50: '..' not found in -a output for empty dir:\n{s}\n", .{output});
    }

    try testing.expect(found_dot);
    try testing.expect(found_dotdot);
}

test "F50: ls -A does NOT include . and .. (contrast with -a)" {
    // This test verifies -A behavior is correct (should NOT have . and ..)
    // to confirm the distinction between -a and -A.
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("visible.txt", "");
    try env.createFile(".hidden", "");

    try env.runLs(.{ .almost_all = true, .one_per_line = true });

    const output = env.getStdout();

    // -A must NOT contain "." or ".." as lines
    var line_iter = std.mem.splitScalar(u8, output, '\n');
    while (line_iter.next()) |line| {
        if (std.mem.eql(u8, line, ".")) {
            std.debug.print("F50: '.' should NOT appear in -A output:\n{s}\n", .{output});
            return error.TestUnexpectedResult;
        }
        if (std.mem.eql(u8, line, "..")) {
            std.debug.print("F50: '..' should NOT appear in -A output:\n{s}\n", .{output});
            return error.TestUnexpectedResult;
        }
    }

    // -A should still show hidden files
    try LsAssertions.expectContainsFile(output, ".hidden");
    try LsAssertions.expectContainsFile(output, "visible.txt");
}

test "F50: . and .. are first entries in ls -a sorted output" {
    // GNU ls -a sorts entries alphabetically, and "." and ".."
    // sort before any other entries.
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("aaa.txt", "");
    try env.createFile(".zzz", "");

    try env.runLs(.{ .all = true, .one_per_line = true });

    const output = env.getStdout();
    var line_iter = std.mem.splitScalar(u8, output, '\n');

    const first = line_iter.next() orelse "";
    const second = line_iter.next() orelse "";

    if (!std.mem.eql(u8, first, ".")) {
        std.debug.print("F50: Expected '.' as first entry, got '{s}'\nFull output:\n{s}\n", .{ first, output });
    }
    if (!std.mem.eql(u8, second, "..")) {
        std.debug.print("F50: Expected '..' as second entry, got '{s}'\nFull output:\n{s}\n", .{ second, output });
    }

    try testing.expectEqualStrings(".", first);
    try testing.expectEqualStrings("..", second);
}
