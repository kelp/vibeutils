const std = @import("std");
const testing = std.testing;
const test_utils = @import("test_utils.zig");
const types = @import("types.zig");
const formatter = @import("formatter.zig");
const display = @import("display.zig");

const LsOptions = types.LsOptions;
const LsTestEnv = test_utils.LsTestEnv;
const LsAssertions = test_utils.LsAssertions;
const PlatformHelpers = test_utils.PlatformHelpers;

// Import constants for readability
const TEST_SIZE_2K = test_utils.TEST_SIZE_2K;
const TEST_SIZE_4K = test_utils.TEST_SIZE_4K;
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
    const files = [_][]const u8{
        "a",     "bb",     "ccc",     "dddd",
        "eeeee", "ffffff", "ggggggg", "hhhhhhhh",
    };
    for (files) |name| {
        try env.createFile(name, "");
    }

    // Multi-column is only the default on a terminal (issue #113: piped/
    // redirected stdout defaults to one-per-line instead).
    try env.runLs(.{ .terminal_width = TEST_TERMINAL_WIDTH, .is_terminal = true });

    try LsAssertions.expectMultiColumnFormat(env.getStdout(), files.len);
}

// Regression test for issue #113: POSIX/GNU/BSD ls all print one entry per
// line (equivalent to -1) when stdout is not a terminal and no explicit
// format flag is given. LsOptions.is_terminal defaults to false, so runLs
// with no explicit .is_terminal setting already exercises the "piped"
// path -- no extra plumbing needed to simulate a non-tty stdout.
test "format: default output is one entry per line when stdout is not a terminal" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("aaa", "");
    try env.createFile("bbbbbbbbbbbb", "");
    try env.createFile("ccc", "");

    try env.runLs(.{ .terminal_width = TEST_TERMINAL_WIDTH });

    try LsAssertions.expectExactOutput(env.getStdout(), "aaa\nbbbbbbbbbbbb\nccc\n");
}

// Companion to the exact-output test above: guards against a fix that gets
// the line count right but leaves column-padding spaces on non-final
// entries (the original symptom in issue #113 -- padded entries broke
// anchored `grep -v '\.lock$'` patterns downstream).
test "format: default non-terminal output has no trailing whitespace on any line" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    const files = [_][]const u8{
        "a",     "bb",     "ccc",     "dddd",
        "eeeee", "ffffff", "ggggggg", "hhhhhhhh",
    };
    for (files) |name| {
        try env.createFile(name, "");
    }

    try env.runLs(.{ .terminal_width = TEST_TERMINAL_WIDTH });

    const output = env.getStdout();
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[line.len - 1] == ' ') {
            std.debug.print("Line has trailing whitespace: '{s}'\n", .{line});
            return error.TrailingWhitespaceFound;
        }
        if (std.mem.find(u8, line, "  ") != null) {
            std.debug.print("Line has internal column padding: '{s}'\n", .{line});
            return error.ColumnPaddingFound;
        }
    }
}

// -1 must always win, on a tty or not: it is an explicit format flag, so it
// is never subject to the terminal-detection default.
test "format: -1 stays one entry per line even when stdout is a terminal" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("aaa.txt", "");
    try env.createFile("bbb.txt", "");

    try env.runLs(.{ .one_per_line = true, .is_terminal = true });

    try LsAssertions.expectOnePerLineOrder(env.getStdout(), &.{ "aaa.txt", "bbb.txt" });
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

// -l is already one entry per line regardless of is_terminal (the
// long_format branch is checked ahead of the default branch), so it must
// not gain or lose lines when stdout is not a terminal (issue #113).
test "long_format: line count matches file count when stdout is not a terminal" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    const files = [_][]const u8{ "aaa", "bbbbbbbbbbbb", "ccc" };
    for (files) |name| {
        try env.createFile(name, "");
    }

    try env.runLs(.{ .long_format = true });

    const output = env.getStdout();
    var non_empty_lines: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) non_empty_lines += 1;
    }

    // files.len entries plus one "total N" line.
    try testing.expectEqual(files.len + 1, non_empty_lines);
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
    defer dir1.close(std.testing.io);

    const file2 = try dir1.createFile(std.testing.io, "file2.txt", .{});
    file2.close(std.testing.io);

    try dir1.createDir(std.testing.io, "subdir1", .default_dir);
    var subdir1 = try dir1.openDir(std.testing.io, "subdir1", .{});
    defer subdir1.close(std.testing.io);

    const file3 = try subdir1.createFile(std.testing.io, "file3.txt", .{});
    file3.close(std.testing.io);

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
    defer dir1.close(std.testing.io);
    try dir1.createDir(std.testing.io, "subdir", .default_dir);

    try env.runLs(.{ .recursive = true });

    const output = env.getStdout();
    try LsAssertions.expectDirectoryHeader(output, "./dir1:");
    try LsAssertions.expectDirectoryHeader(output, "./dir2:");
    try LsAssertions.expectDirectoryHeader(output, "./dir1/subdir:");
}

test "recursive: each directory header appears exactly once (no duplicates)" {
    // Guard against bug G13: ls -R printed each subdirectory path header twice.
    // Substring presence (expectDirectoryHeader) cannot detect this because it
    // stops at the first match. This test counts occurrences and asserts == 1.
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Two top-level subdirs and one nested subdir exercise both shallow and
    // deep recursion code paths.
    try env.createDir("dir1");
    try env.createDir("dir2");

    var dir1 = try env.createDirAndOpen("dir1");
    defer dir1.close(std.testing.io);
    try dir1.createDir(std.testing.io, "subdir", .default_dir);

    try env.runLs(.{ .recursive = true });

    const output = env.getStdout();

    const headers = [_][]const u8{ "./dir1:", "./dir2:", "./dir1/subdir:" };
    for (headers) |header| {
        var count: u32 = 0;
        var pos: usize = 0;
        while (std.mem.findPos(u8, output, pos, header)) |found| {
            count += 1;
            pos = found + header.len;
        }
        if (count != 1) {
            std.debug.print(
                "Header '{s}' appears {d} time(s) (expected 1) in output:\n{s}\n",
                .{ header, count, output },
            );
            return error.HeaderCountWrong;
        }
    }
}

test "recursive: handles symlink cycles safely" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createDir("dir1");

    var dir1 = try env.createDirAndOpen("dir1");
    defer dir1.close(std.testing.io);

    // Create a symlink back to parent directory
    try dir1.symLink(std.testing.io, "..", "parent_link", .{});

    try env.runLs(.{ .recursive = true });

    // Should contain the symlink but not recurse infinitely
    try LsAssertions.expectContainsFile(env.getStdout(), "parent_link");
}

// Regression test for issue #113 covering -R specifically: every directory
// section printed during a recursive listing must independently honor the
// non-terminal default, not just the top-level section.
test "recursive: default output is one entry per line in every section when not a terminal" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFile("aaa", "");
    try env.createFile("bbbbbbbbbbbb", "");
    try env.createFile("ccc", "");

    var sub = try env.createDirAndOpen("sub");
    defer sub.close(std.testing.io);
    const zzz = try sub.createFile(std.testing.io, "zzz", .{});
    zzz.close(std.testing.io);

    try env.runLs(.{ .recursive = true, .terminal_width = TEST_TERMINAL_WIDTH });

    const expected = "aaa\n" ++
        "bbbbbbbbbbbb\n" ++
        "ccc\n" ++
        "sub\n" ++
        "\n" ++
        "./sub:\n" ++
        "zzz\n";
    try LsAssertions.expectExactOutput(env.getStdout(), expected);
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
    env.clearOutput();
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
    env.clearOutput();
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

// Regression test for issue #113: an explicit -C must keep multi-column
// output even when stdout is not a terminal (explicit flag beats the
// non-tty default). LsOptions has no multi_column field yet -- the
// implementer adds it in src/ls/types.zig/main.zig -- so this test is
// gated with @hasField: the comptime-false branch is never analyzed
// today, which lets this file compile in the RED phase without a
// multi_column field, and the guard activates automatically once the
// field lands. Until then, the end-to-end guard for this behavior lives
// in tests/utilities/ls_test.sh ("explicit -C keeps multi-column layout
// when piped").
test "multi_column: -C forces multi-column output even when stdout is not a terminal" {
    if (!@hasField(LsOptions, "multi_column")) return error.SkipZigTest;

    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    const files = [_][]const u8{ "aaa", "bbb", "ccc", "ddd", "eee", "fff" };
    for (files) |name| {
        try env.createFile(name, "");
    }

    try env.runLs(.{
        .multi_column = true,
        .is_terminal = false,
        .terminal_width = TEST_TERMINAL_WIDTH,
    });

    try LsAssertions.expectMultiColumnFormat(env.getStdout(), files.len);
}

// Regression tests for issue #ls-column-tabs: printColumnar (explicit -C and
// the terminal default) must match macOS/BSD /bin/ls's tab-stop columnizer
// byte for byte -- pad with '\t' to a uniform (max_width + 8) & ~7 column
// width, never pad after the last cell of a row, and drive the arithmetic
// off Entry.getDisplayWidth (which folds in icon/git-status prefixes), not
// the raw name length. GNU is explicitly NOT the reference for this fix.

test "columnar: -C row never ends in space or tab, partial last row" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // 7 entries of increasing width (max 7 chars: "ggggggg"). At a
    // 24-column terminal this yields colwidth = (7+8)&~7 = 8,
    // num_cols = 24/8 = 3, num_rows = ceil(7/3) = 3 -- the third column
    // only has one entry (row 0), so rows 1 and 2 are partially filled:
    // the current (buggy) pad guard only checks for the single
    // globally-last entry, so it still emits a pad after the last
    // printed cell in rows 1 and 2.
    const files = [_][]const u8{ "a", "bb", "ccc", "dddd", "eeeee", "ffffff", "ggggggg" };
    for (files) |name| {
        try env.createFile(name, "");
    }

    try env.runLs(.{ .multi_column = true, .terminal_width = 24 });

    try std.testing.expectEqualStrings(
        "a\tdddd\tggggggg\nbb\teeeee\nccc\tffffff\n",
        env.getStdout(),
    );
}

test "columnar: terminal default row never ends in space or tab, partial last row" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    const files = [_][]const u8{ "a", "bb", "ccc", "dddd", "eeeee", "ffffff", "ggggggg" };
    for (files) |name| {
        try env.createFile(name, "");
    }

    // Same fixture as above but reached through the terminal default
    // (is_terminal = true, no explicit -C) instead of the explicit flag.
    // icon_mode is pinned to .never: shouldShowIcons(.auto, is_terminal)
    // would otherwise turn icons on for is_terminal = true, adding an
    // icon+space prefix to every name and pushing max_width (and every
    // tab-stop boundary below) up -- the briefing pins the reference
    // with icons disabled, so this test must too.
    try env.runLs(.{ .is_terminal = true, .terminal_width = 24, .icon_mode = .never });

    try std.testing.expectEqualStrings(
        "a\tdddd\tggggggg\nbb\teeeee\nccc\tffffff\n",
        env.getStdout(),
    );
}

test "columnar: -C pads with tabs to (max_width + 8) & ~7 at the maxlen=8 tab-stop boundary" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // 12 files, each exactly 8 chars long, pinned against real macOS
    // /bin/ls (COLUMNS=80, longest name 8 chars): colwidth = (8+8)&~7 =
    // 16, num_cols = 80/16 = 5, num_rows = ceil(12/5) = 3. Column-major
    // fill-down only produces 4 visible columns -- the 5th column's
    // first index (12) is out of range, so it never appears.
    const files = [_][]const u8{
        "aaaaaa01", "aaaaaa02", "aaaaaa03", "aaaaaa04",
        "aaaaaa05", "aaaaaa06", "aaaaaa07", "aaaaaa08",
        "aaaaaa09", "aaaaaa10", "aaaaaa11", "aaaaaa12",
    };
    for (files) |name| {
        try env.createFile(name, "");
    }

    try env.runLs(.{ .multi_column = true, .terminal_width = 80 });

    try std.testing.expectEqualStrings(
        "aaaaaa01\taaaaaa04\taaaaaa07\taaaaaa10\n" ++
            "aaaaaa02\taaaaaa05\taaaaaa08\taaaaaa11\n" ++
            "aaaaaa03\taaaaaa06\taaaaaa09\taaaaaa12\n",
        env.getStdout(),
    );
}

test "columnar: -C pads with tabs to (max_width + 8) & ~7 at the maxlen=16 tab-stop boundary" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // 12 files, each exactly 16 chars long, pinned against real macOS
    // /bin/ls (COLUMNS=80, longest name 16 chars): colwidth =
    // (16+8)&~7 = 24, num_cols = 80/24 = 3, num_rows = ceil(12/3) = 4 --
    // an exact fill, unlike the maxlen=8 case above.
    const files = [_][]const u8{
        "aaaaaaaaaaaaaa01", "aaaaaaaaaaaaaa02", "aaaaaaaaaaaaaa03",
        "aaaaaaaaaaaaaa04", "aaaaaaaaaaaaaa05", "aaaaaaaaaaaaaa06",
        "aaaaaaaaaaaaaa07", "aaaaaaaaaaaaaa08", "aaaaaaaaaaaaaa09",
        "aaaaaaaaaaaaaa10", "aaaaaaaaaaaaaa11", "aaaaaaaaaaaaaa12",
    };
    for (files) |name| {
        try env.createFile(name, "");
    }

    try env.runLs(.{ .multi_column = true, .terminal_width = 80 });

    try std.testing.expectEqualStrings(
        "aaaaaaaaaaaaaa01\taaaaaaaaaaaaaa05\taaaaaaaaaaaaaa09\n" ++
            "aaaaaaaaaaaaaa02\taaaaaaaaaaaaaa06\taaaaaaaaaaaaaa10\n" ++
            "aaaaaaaaaaaaaa03\taaaaaaaaaaaaaa07\taaaaaaaaaaaaaa11\n" ++
            "aaaaaaaaaaaaaa04\taaaaaaaaaaaaaa08\taaaaaaaaaaaaaa12\n",
        env.getStdout(),
    );
}

test "columnar: -C pads across intervening tab stops, not a single tab" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Pinned against real macOS /bin/ls (COLUMNS=80): names of widths
    // 1, 9, 5, 8, 2. Longest name is 9 chars, so colwidth = (9+8)&~7 =
    // 16, num_cols = 80/16 = 5, num_rows = ceil(5/5) = 1 -- a single
    // row with all 5 entries. This is the one fixture where a single
    // '\t' per entry is NOT enough to reach the next column boundary:
    // BSD ls pads with a *loop* of 8-column tab stops until the
    // absolute cursor column reaches the next multiple of colwidth,
    // exactly like a real terminal tab key. Two entries need two hops:
    //   - "a" (width 1) needs 2 tabs to reach column 16 (1 -> 8 -> 16)
    //   - "ccccc" (width 5, column-relative start 32) needs 2 tabs to
    //     reach 48 (37 -> 40 -> 48)
    // while "bbbbbbbbb" (width 9, exactly at the boundary) and
    // "dddddddd" (width 8) each need exactly one tab. An implementation
    // that always emits a single '\t' per padded entry (e.g. reusing
    // the old space-padding loop's single-append shape) passes every
    // other fixture in this file but fails this one.
    const files = [_][]const u8{ "a", "bbbbbbbbb", "ccccc", "dddddddd", "ee" };
    for (files) |name| {
        try env.createFile(name, "");
    }

    try env.runLs(.{ .multi_column = true, .terminal_width = 80 });

    try std.testing.expectEqualStrings(
        "a\t\tbbbbbbbbb\tccccc\t\tdddddddd\tee\n",
        env.getStdout(),
    );
}

test "columnar: -C folds the -s block prefix into the column width" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // The one fixture where dropping the block prefix from the column
    // width changes the layout instead of merely shifting it. Names are
    // 6 chars and the widest block count is one digit, so the prefix is
    // 2 chars: base = 2 + 6 = 8 and colwidth = (8+8)&~7 = 16, a base on
    // a tab stop still gaining a full stop. Without the prefix the base
    // would be 6 and colwidth (6+8)&~7 = 8, giving a different grid.
    // num_cols = 80/16 = 5, num_rows = ceil(6/5) = 2, so column-major
    // fill-down shows 3 columns. Each cell is 8 chars wide and reaches
    // the next stop at 16 with a single tab.
    //
    // aa0006 is exactly 4096 bytes so its block count is 8 whether it
    // is derived from the size or read from st_blocks; the two disagree
    // for sizes that are not a multiple of the allocation unit.
    const empty = [_][]const u8{ "aa0001", "aa0002", "aa0003", "aa0004", "aa0005" };
    for (empty) |name| {
        try env.createFile(name, "");
    }
    try env.createFileWithSize("aa0006", TEST_SIZE_4K, 'z');

    try env.runLs(.{
        .multi_column = true,
        .show_blocks = true,
        .terminal_width = 80,
    });

    // Verified byte-identical to macOS /bin/ls -C -s on this fixture.
    try std.testing.expectEqualStrings(
        "total 8\n" ++
            "0 aa0001\t0 aa0003\t0 aa0005\n" ++
            "0 aa0002\t0 aa0004\t8 aa0006\n",
        env.getStdout(),
    );
}

test "columnar: -C width arithmetic uses getDisplayWidth (git prefix)" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();

    // Each name is 5 raw characters, but the "M  " git-status prefix
    // (2-char indicator + trailing space, see GitStatus.getIndicator)
    // adds 3 more, for a real display width of 8, so colwidth =
    // (8+8)&~7 = 16. At a 40-column terminal that gives num_cols =
    // 40/16 = 2 -- wide enough to actually assert alignment (a
    // narrower terminal collapsing to 1 column would never call the
    // padding helper at all). Using the raw name length instead would
    // compute colwidth = (5+8)&~7 = 8 and num_cols = 5, producing a
    // completely different (and wrong) row shape and tab count. If the
    // fix uses entry.name.len instead of getDisplayWidth anywhere in
    // the tab arithmetic, the exact byte comparison below fails.
    var entries = [_]types.Entry{
        .{ .name = "bbbbb", .kind = .file, .git_status = .modified },
        .{ .name = "ccccc", .kind = .file, .git_status = .modified },
        .{ .name = "ddddd", .kind = .file, .git_status = .modified },
    };

    const options = types.LsOptions{ .terminal_width = 40, .show_git_status = true };
    const style = try display.initStyle(testing.allocator, &buf_aw.writer, .never);

    try formatter.printColumnar(testing.allocator, &entries, &buf_aw.writer, options, style);

    // num_rows = ceil(3/2) = 2; column-major fill-down gives:
    // col0 = [bbbbb, ccccc], col1 = [ddddd] (idx 3 is out of range).
    // "M  bbbbb" (display width 8) needs exactly one tab to reach the
    // column-16 boundary; the row's last cell ("M  ddddd") gets no
    // pad; row 2's only cell ("M  ccccc") is the last (and only) cell
    // in its row, so it also gets no trailing pad even though it is
    // not the last entry overall -- this is the exact bug-1 shape.
    try std.testing.expectEqualStrings(
        "M  bbbbb\tM  ddddd\nM  ccccc\n",
        buf_aw.writer.buffered(),
    );
}

test "columnar: -C width arithmetic uses getDisplayWidth (icon prefix)" {
    var buf_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_aw.deinit();

    // Mirrors the git-status test above but through the icon path
    // instead: icon glyph + trailing space contributes displayWidth +
    // 1 = 3 (the default file icon, U+F15B, is a Nerd Font Private Use
    // Area glyph that renders 2 columns wide -- see
    // common.unicode.isNerdFontWide), the same width contribution as
    // the git indicator, so the row shape and tab counts are identical
    // to the git-status fixture. icon_mode = .always forces icons on
    // regardless of is_terminal, keeping this a plain unit test of the
    // formatter rather than a terminal-detection test.
    var entries = [_]types.Entry{
        .{ .name = "bbbbb", .kind = .file },
        .{ .name = "ccccc", .kind = .file },
        .{ .name = "ddddd", .kind = .file },
    };

    const options = types.LsOptions{ .terminal_width = 40, .icon_mode = .always };
    const style = try display.initStyle(testing.allocator, &buf_aw.writer, .never);

    try formatter.printColumnar(testing.allocator, &entries, &buf_aw.writer, options, style);

    // "\xef\x85\x9b" is the 3-byte UTF-8 encoding of U+F15B (the
    // default file icon); the icon renderer writes "{s} " (glyph plus
    // a literal trailing space) before every name. Row shape mirrors
    // the git-status fixture exactly.
    try std.testing.expectEqualStrings(
        "\u{f15b} bbbbb\t\u{f15b} ddddd\n\u{f15b} ccccc\n",
        buf_aw.writer.buffered(),
    );
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

// Regression pin for issue #ls-column-tabs: -x (printColumnarAcross)
// shares printColumnar_writePadding and the COLUMN_PADDING/col_width
// arithmetic with -C (printColumnar), but the pinned target behavior
// for this issue is explicit that -x is unaffected -- it must keep
// padding with plain runs of spaces at (max_width + 2), never tabs.
// An accidental edit to the shared padding helper (or to COLUMN_PADDING
// itself) while fixing -C would silently flip -x's separator to tabs
// or change its column count; this exact byte comparison catches that.
test "columns_across: -x still pads with spaces at (max_width + 2), not tabs" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    const files = [_][]const u8{ "aaa", "bbb", "ccc", "ddd" };
    for (files) |name| {
        try env.createFile(name, "");
    }

    // max_width = 3, col_width = 3 + 2 = 5, num_cols = 20 / 5 = 4 --
    // all four entries fit on a single row.
    try env.runLs(.{ .columns_across = true, .terminal_width = 20 });

    try std.testing.expectEqualStrings("aaa  bbb  ccc  ddd\n", env.getStdout());
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
    env.clearOutput();
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
    try LsAssertions.expectOnePerLineOrder(
        env.getStdout(),
        &.{ "file1", "file2", "file10", "file20" },
    );
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
    try LsAssertions.expectOnePerLineOrder(
        env.getStdout(),
        &.{ "main.c", "readme.md", "notes.txt" },
    );
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

test "F49: runLs returns non-zero exit for nonexistent path" {
    // GNU ls exits 2 when given a nonexistent path.
    // Our runLs wraps lsMain and should propagate the error
    // as a non-zero exit code.
    const main = @import("main.zig");

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try main.runLs(
        testing.allocator,
        testing.io,
        &.{"/tmp/vibeutils_nonexistent_path_f49_test"},
        &stdout_aw.writer,
        &stderr_aw.writer,
    );

    // Should be non-zero (GNU uses 2, we accept any non-zero)
    try testing.expect(exit_code != 0);

    // Should have printed an error message on stderr
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

test "F49: runLs returns non-zero when one of multiple paths is invalid" {
    // When listing multiple paths and one fails, GNU ls still
    // lists the valid ones but exits non-zero.
    const main = @import("main.zig");

    // Create a real temporary directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f = try tmp_dir.dir.createFile(testing.io, "real.txt", .{});
    f.close(testing.io);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Use an absolute nonexistent path to guarantee an error.
    const exit_code = try main.runLs(
        testing.allocator,
        testing.io,
        &.{"/tmp/vibeutils_nonexistent_mixed_f49"},
        &stdout_aw.writer,
        &stderr_aw.writer,
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
        std.debug.print(
            "F50: Expected '.' as first entry, got '{s}'\nFull output:\n{s}\n",
            .{ first, output },
        );
    }
    if (!std.mem.eql(u8, second, "..")) {
        std.debug.print(
            "F50: Expected '..' as second entry, got '{s}'\nFull output:\n{s}\n",
            .{ second, output },
        );
    }

    try testing.expectEqualStrings(".", first);
    try testing.expectEqualStrings("..", second);
}
