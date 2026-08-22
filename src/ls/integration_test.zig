const std = @import("std");
const testing = std.testing;
const common = @import("common");
const TestDir = common.test_dir.TestDir;
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

fn parseLongFormatTotal(output: []const u8) !u64 {
    const prefix = "total ";
    const newline = std.mem.findScalar(u8, output, '\n') orelse return error.MissingTotalLine;
    if (!std.mem.startsWith(u8, output[0..newline], prefix)) return error.MissingTotalLine;
    return std.fmt.parseInt(u64, output[prefix.len..newline], 10);
}

// Empty test so the helpers below sit after the file's first test block.
// audit-check treats private fns declared there as test-section code.
test {}

/// The `-C`/`-x` `-s` tests exist to prove the prefix enters colwidth before
/// tab-stop rounding. A filesystem that keeps every count one digit still
/// hits the 8-vs-16 split for 6-char names; two-digit counts are recomputed
/// honestly rather than hard-coded.
fn expectPrefixChangesColWidth(name_len: usize, counts: []const u64) !void {
    std.debug.assert(name_len > 0);
    std.debug.assert(counts.len > 0);
    var widest: u64 = 0;
    for (counts) |count| widest = @max(widest, count);
    const prefix_w = common.test_dir.decimalDigitWidth(widest) + 1;
    const with_prefix = (prefix_w + name_len + 8) & ~@as(usize, 7);
    const without_prefix = (name_len + 8) & ~@as(usize, 7);
    try testing.expect(with_prefix != without_prefix);
    try testing.expect(prefix_w >= 2);
}

fn growUntilWiderBlocks(
    env: *LsTestEnv,
    small_name: []const u8,
    large_name: []const u8,
    start_size: usize,
) !struct { small: u64, large: u64 } {
    std.debug.assert(small_name.len > 0);
    std.debug.assert(large_name.len > 0);
    var size = start_size;
    var small_blocks = try env.tmp_dir.fileBlocks512(small_name);
    var large_blocks: u64 = 0;
    while (size <= 1 << 20) : (size *= 2) {
        try env.createFileWithSize(large_name, size, 'z');
        small_blocks = try env.tmp_dir.fileBlocks512(small_name);
        large_blocks = try env.tmp_dir.fileBlocks512(large_name);
        if (common.test_dir.decimalDigitWidth(large_blocks) >
            common.test_dir.decimalDigitWidth(small_blocks))
        {
            break;
        }
    }
    try common.test_dir.skipUnlessWiderBlockField(small_blocks, large_blocks);
    return .{ .small = small_blocks, .large = large_blocks };
}

fn growUntilBlockDigits(
    env: *LsTestEnv,
    name: []const u8,
    start_size: usize,
    min_digits: usize,
) !u64 {
    std.debug.assert(name.len > 0);
    std.debug.assert(min_digits >= 1);
    var size = start_size;
    var blocks: u64 = 0;
    while (size <= 8 << 20) : (size *= 2) {
        try env.createFileWithSize(name, size, 'z');
        blocks = try env.tmp_dir.fileBlocks512(name);
        if (common.test_dir.decimalDigitWidth(blocks) >= min_digits) break;
    }
    try common.test_dir.skipUnlessWidestHasDigits(blocks, min_digits);
    return blocks;
}

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

test "long_format: total uses 1024-byte blocks like GNU" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFileWithSize("first.bin", TEST_SIZE_4K, 'A');
    try env.createFileWithSize("second.bin", TEST_SIZE_2K, 'B');

    const first = try common.file.FileInfo.statDir(testing.allocator, env.test_dir, "first.bin");
    const second = try common.file.FileInfo.statDir(testing.allocator, env.test_dir, "second.bin");
    const total_blocks_512 = first.blocks + second.blocks;
    const expected_total = @divFloor(total_blocks_512 + 1, 2);

    try env.runLs(.{ .long_format = true });

    try testing.expect(total_blocks_512 > 0);
    try testing.expect(expected_total < total_blocks_512);
    try testing.expectEqual(expected_total, try parseLongFormatTotal(env.getStdout()));
}

test "long_format: empty directory prints total 0" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.runLs(.{ .long_format = true });

    try testing.expectEqualStrings("total 0\n", env.getStdout());
    try testing.expectEqualStrings("", env.getStderr());
}

test "long_format: -k total matches the 1024-byte default" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFileWithSize("payload.bin", TEST_SIZE_4K, 'K');
    const stat = try common.file.FileInfo.statDir(testing.allocator, env.test_dir, "payload.bin");
    const expected_total = @divFloor(stat.blocks + 1, 2);

    try env.runLs(.{ .long_format = true });
    const default_total = try parseLongFormatTotal(env.getStdout());

    try env.runLs(.{ .long_format = true, .kilobytes = true });
    const kilobyte_total = try parseLongFormatTotal(env.getStdout());

    try testing.expectEqual(expected_total, kilobyte_total);
    try testing.expectEqual(kilobyte_total, default_total);
}

test "long_format: -h humanizes the total line" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    try env.createFileWithSize("payload.bin", TEST_SIZE_4K, 'H');
    const stat = try common.file.FileInfo.statDir(testing.allocator, env.test_dir, "payload.bin");
    const total_bytes = stat.blocks * 512;

    var human_buf: [32]u8 = undefined;
    const expected_human = try common.file.formatSizeHuman(total_bytes, &human_buf);
    const expected_line = try std.fmt.allocPrint(
        testing.allocator,
        "total {s}\n",
        .{expected_human},
    );
    defer testing.allocator.free(expected_line);

    try env.runLs(.{ .long_format = true, .human_readable = true });
    const output = env.getStdout();
    const newline = std.mem.findScalar(u8, output, '\n') orelse return error.MissingTotalLine;

    try testing.expect(total_bytes > 0);
    try testing.expectEqualStrings(expected_line, output[0 .. newline + 1]);
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
    // 6 chars; a one-digit count makes prefix 2 and colwidth 16, while
    // omitting the prefix yields colwidth 8. Allocation is filesystem-
    // specific, so the grid is rebuilt from each file's `st_blocks`.
    const names = [_][]const u8{ "aa0001", "aa0002", "aa0003", "aa0004", "aa0005", "aa0006" };
    for (names[0..5]) |name| {
        try env.createFile(name, "");
    }
    try env.createFileWithSize("aa0006", TEST_SIZE_4K, 'z');

    var raw: [6]u64 = undefined;
    var counts: [6]u64 = undefined;
    for (names, &raw) |name, *slot| {
        slot.* = try env.tmp_dir.fileBlocks512(name);
    }
    test_utils.displayBlocks(&raw, false, &counts);
    try expectPrefixChangesColWidth(names[0].len, &counts);

    try env.runLs(.{
        .multi_column = true,
        .show_blocks = true,
        .terminal_width = 80,
    });

    var expected_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer expected_aw.deinit();
    try test_utils.writeColumnarBlocks(
        &expected_aw.writer,
        &names,
        &counts,
        true,
        80,
    );
    try std.testing.expectEqualStrings(expected_aw.writer.buffered(), env.getStdout());
}

test "columnar: -C -F widens the column even when the widest name has no indicator" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Issue #121. Two 7-char regular files and a 4-char directory, so the
    // WIDEST entry ("bbbbbbb") carries no -F indicator and the only entry
    // that does ("dir1/") is short. BSD ls sizes the column from the raw
    // maximum NAME length plus a flat +1 whenever -F is active:
    //   colwidth = (7 + 1 + 8) & ~7 = 16
    // so each gap needs two tabs (7 -> 8 -> 16, then 23 -> 24 -> 32).
    // Folding the indicator into each entry's own display width instead
    // yields max_width = 7, colwidth = (7 + 8) & ~7 = 8 and a single tab
    // per gap. Pinned byte-for-byte against macOS /bin/ls -C -F.
    try env.createFile("aaaaaaa", "");
    try env.createFile("bbbbbbb", "");
    try env.createDir("dir1");

    try env.runLs(.{
        .multi_column = true,
        .file_type_indicators = true,
        .terminal_width = 80,
    });

    try std.testing.expectEqualStrings(
        "aaaaaaa\t\tbbbbbbb\t\tdir1/\n",
        env.getStdout(),
    );
}

test "columnar: -C -p widens the column even when the widest name has no slash" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Same fixture and same arithmetic as the -F case above. BSD folds -p
    // (`f_typedir`) into the identical `colwidth += 1` term, so -p alone
    // must widen the column the same way. Pinned against macOS
    // /bin/ls -C -p.
    try env.createFile("aaaaaaa", "");
    try env.createFile("bbbbbbb", "");
    try env.createDir("dir1");

    try env.runLs(.{
        .multi_column = true,
        .append_slash_dirs = true,
        .terminal_width = 80,
    });

    try std.testing.expectEqualStrings(
        "aaaaaaa\t\tbbbbbbb\t\tdir1/\n",
        env.getStdout(),
    );
}

test "columnar: -C without an indicator flag keeps the plain maxlen column width" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Negative space for the two tests above: the flat +1 is owed to -F/-p
    // and nothing else. On the same fixture without either flag BSD
    // computes colwidth = (7 + 8) & ~7 = 8, one tab per gap. A fix that
    // adds the term unconditionally passes both tests above and fails
    // this one. Pinned against macOS /bin/ls -C.
    try env.createFile("aaaaaaa", "");
    try env.createFile("bbbbbbb", "");
    try env.createDir("dir1");

    try env.runLs(.{
        .multi_column = true,
        .terminal_width = 80,
    });

    try std.testing.expectEqualStrings(
        "aaaaaaa\tbbbbbbb\tdir1\n",
        env.getStdout(),
    );
}

// Regression tests for -x column geometry. BSD lays -x out on exactly the
// same grid as -C -- the widest name with the -F/-p indicator excluded, plus
// a flat +1 when either flag is active, plus any -s prefix, all rounded UP
// to the next 8-column tab stop, with the gap filled by literal tabs -- and
// differs from -C only in traversal order (-x fills across rows, -C down
// columns). printColumnarAcross instead used a flat two-space pad at
// max_width + 2, which both mis-sizes the column and emits the wrong
// separator byte. Every expectation below was pinned against macOS /bin/ls
// -x; the fixtures mirror the -C tests above so the two paths are held to
// one rule.

test "columnar: -x pads with tabs to the BSD tab-stop column width" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Nine names of increasing width (max 9: "iiiiiiiii"), so colwidth =
    // (9+8)&~7 = 16 and num_cols = 40/16 = 2. Row-major fill puts a and bb
    // on the first row, and every gap here needs two tab hops to reach
    // column 16 (1 -> 8 -> 16 for "a", 3 -> 8 -> 16 for "ccc", and so on).
    // The two-space pad produced three columns instead of two, so this
    // fixture pins the column COUNT as well as the separator.
    const files = [_][]const u8{
        "a",      "bb",      "ccc",      "dddd",      "eeeee",
        "ffffff", "ggggggg", "hhhhhhhh", "iiiiiiiii",
    };
    for (files) |name| {
        try env.createFile(name, "");
    }

    try env.runLs(.{ .columns_across = true, .terminal_width = 40 });

    try std.testing.expectEqualStrings(
        "a\t\tbb\n" ++
            "ccc\t\tdddd\n" ++
            "eeeee\t\tffffff\n" ++
            "ggggggg\t\thhhhhhhh\n" ++
            "iiiiiiiii\n",
        env.getStdout(),
    );
}

test "columnar: -x pads across intervening tab stops, not a single tab" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // The same nine names at 80 columns: colwidth is still 16 but num_cols
    // is 80/16 = 5, so the second row exposes the one gap where a single
    // tab is the right answer. After "hhhhhhhh" the cursor sits at absolute
    // column 40, and one hop reaches the 48 boundary; every other gap on
    // both rows needs two hops. An implementation that always emits exactly
    // one tab per gap passes the 40-column fixture above and fails here,
    // and one that always emits two fails only on this row's last gap.
    const files = [_][]const u8{
        "a",      "bb",      "ccc",      "dddd",      "eeeee",
        "ffffff", "ggggggg", "hhhhhhhh", "iiiiiiiii",
    };
    for (files) |name| {
        try env.createFile(name, "");
    }

    try env.runLs(.{ .columns_across = true, .terminal_width = 80 });

    try std.testing.expectEqualStrings(
        "a\t\tbb\t\tccc\t\tdddd\t\teeeee\n" ++
            "ffffff\t\tggggggg\t\thhhhhhhh\tiiiiiiiii\n",
        env.getStdout(),
    );
}

test "columnar: -x falls back to one entry per line when a single column fits" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Negative space for the two tests above: widening the column to the
    // next tab stop must not manufacture columns that do not fit. The same
    // nine names at 20 columns give colwidth 16 and num_cols = 20/16 = 1,
    // so BSD prints one name per line with no separator at all. Verified
    // against macOS /bin/ls -x at COLUMNS=20.
    const files = [_][]const u8{
        "a",      "bb",      "ccc",      "dddd",      "eeeee",
        "ffffff", "ggggggg", "hhhhhhhh", "iiiiiiiii",
    };
    for (files) |name| {
        try env.createFile(name, "");
    }

    try env.runLs(.{ .columns_across = true, .terminal_width = 20 });

    try std.testing.expectEqualStrings(
        "a\nbb\nccc\ndddd\neeeee\nffffff\nggggggg\nhhhhhhhh\niiiiiiiii\n",
        env.getStdout(),
    );
}

test "columnar: -x -F widens the column even when the widest name has no indicator" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // The -x mirror of the -C -F test above, on the identical fixture: the
    // widest entry ("bbbbbbb") carries no indicator and the only one that
    // does ("dir1/") is short, so the flat +1 has to come from the flag
    // rather than from any entry's own width. colwidth = (7+1+8)&~7 = 16
    // and each gap needs two tabs. Pinned against macOS /bin/ls -x -F.
    try env.createFile("aaaaaaa", "");
    try env.createFile("bbbbbbb", "");
    try env.createDir("dir1");

    try env.runLs(.{
        .columns_across = true,
        .file_type_indicators = true,
        .terminal_width = 80,
    });

    try std.testing.expectEqualStrings(
        "aaaaaaa\t\tbbbbbbb\t\tdir1/\n",
        env.getStdout(),
    );
}

test "columnar: -x -p widens the column even when the widest name has no slash" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // BSD folds -p into the same `colwidth += 1` term as -F, so -p alone
    // must widen the -x column identically. Pinned against macOS
    // /bin/ls -x -p on the same fixture.
    try env.createFile("aaaaaaa", "");
    try env.createFile("bbbbbbb", "");
    try env.createDir("dir1");

    try env.runLs(.{
        .columns_across = true,
        .append_slash_dirs = true,
        .terminal_width = 80,
    });

    try std.testing.expectEqualStrings(
        "aaaaaaa\t\tbbbbbbb\t\tdir1/\n",
        env.getStdout(),
    );
}

test "columnar: -x without an indicator flag keeps the plain maxlen column width" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Negative space for the -F and -p tests above: the flat +1 is owed to
    // those flags and nothing else. Without either, colwidth = (7+8)&~7 = 8
    // and one tab closes each gap. A fix that adds the term unconditionally
    // passes both tests above and fails this one. Pinned against macOS
    // /bin/ls -x.
    try env.createFile("aaaaaaa", "");
    try env.createFile("bbbbbbb", "");
    try env.createDir("dir1");

    try env.runLs(.{
        .columns_across = true,
        .terminal_width = 80,
    });

    try std.testing.expectEqualStrings(
        "aaaaaaa\tbbbbbbb\tdir1\n",
        env.getStdout(),
    );
}

test "columnar: -x folds the -s block prefix into the column width" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // The -x mirror of the -C block-prefix test, on the identical fixture,
    // so the -s prefix has to enter the column width BEFORE the tab-stop
    // rounding rather than after. Allocation is filesystem-specific; the
    // expected row-major grid is rebuilt from each file's `st_blocks`.
    const names = [_][]const u8{ "aa0001", "aa0002", "aa0003", "aa0004", "aa0005", "aa0006" };
    for (names[0..5]) |name| {
        try env.createFile(name, "");
    }
    try env.createFileWithSize("aa0006", TEST_SIZE_4K, 'z');

    var raw: [6]u64 = undefined;
    var counts: [6]u64 = undefined;
    for (names, &raw) |name, *slot| {
        slot.* = try env.tmp_dir.fileBlocks512(name);
    }
    test_utils.displayBlocks(&raw, false, &counts);
    try expectPrefixChangesColWidth(names[0].len, &counts);

    try env.runLs(.{
        .columns_across = true,
        .show_blocks = true,
        .terminal_width = 80,
    });

    var expected_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer expected_aw.deinit();
    try test_utils.writeColumnarBlocks(
        &expected_aw.writer,
        &names,
        &counts,
        false,
        80,
    );
    try std.testing.expectEqualStrings(expected_aw.writer.buffered(), env.getStdout());
}

test "blocks: -s reports st_blocks, not a size-derived count" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Issue #117. A size-derived count is ceil(size/512). A sparse 1 MiB
    // hole and a 1-byte file disagree with that on APFS, ext4, and FFS;
    // some guests report a size-derived count for both, and that fixture
    // is inapplicable rather than a production bug.
    const sparse_size: u64 = 1 << 20;
    const tiny_content = "x";
    {
        const file = try env.tmp_dir.dir().createFile(std.testing.io, "sparse", .{});
        defer file.close(std.testing.io);
        try file.setLength(std.testing.io, sparse_size);
    }
    try env.createFile("tiny", tiny_content);

    const sparse_blocks = try env.tmp_dir.fileBlocks512("sparse");
    const tiny_blocks = try env.tmp_dir.fileBlocks512("tiny");
    try common.test_dir.skipUnlessBlocksDifferFromSizeDerived(
        sparse_blocks,
        sparse_size,
        tiny_blocks,
        tiny_content.len,
    );

    try env.runLs(.{ .show_blocks = true, .one_per_line = true });

    var expected_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer expected_aw.deinit();
    try test_utils.writeOnePerLineBlocks(
        &expected_aw.writer,
        &.{ "sparse", "tiny" },
        &.{ sparse_blocks, tiny_blocks },
        true,
    );
    try std.testing.expectEqualStrings(expected_aw.writer.buffered(), env.getStdout());
}

test "blocks: -s -k converts st_blocks to 1 KiB units" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Same fixture as the test above, in the -k unit. Display counts are
    // `howmany(st_blocks, 2)`, not a size-derived kilobyte count.
    {
        const file = try env.tmp_dir.dir().createFile(std.testing.io, "sparse", .{});
        defer file.close(std.testing.io);
        try file.setLength(std.testing.io, 1 << 20);
    }
    try env.createFile("tiny", "x");

    const sparse_k = common.test_dir.howmany512To1k(try env.tmp_dir.fileBlocks512("sparse"));
    const tiny_k = common.test_dir.howmany512To1k(try env.tmp_dir.fileBlocks512("tiny"));

    try env.runLs(.{ .show_blocks = true, .kilobytes = true, .one_per_line = true });

    var expected_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer expected_aw.deinit();
    try test_utils.writeOnePerLineBlocks(
        &expected_aw.writer,
        &.{ "sparse", "tiny" },
        &.{ sparse_k, tiny_k },
        true,
    );
    try std.testing.expectEqualStrings(expected_aw.writer.buffered(), env.getStdout());
}

// Regression tests for the -s block-count FIELD WIDTH. BSD ls sizes that
// field to the widest block count in the section and right-aligns every
// count inside it, then writes one trailing space -- it does not reserve a
// fixed number of columns. The columnar (-C) path already does this via
// printColumnar_blockPrefixWidth; the one-per-line and long-format paths
// hardcoded four columns ("{d: >4} "), which pads every narrow listing with
// three phantom spaces. GNU `gls -1s` agrees with BSD here, so both
// references point the same way. Each expectation below was pinned against
// macOS /bin/ls. The unpadded "total N" line is correct already and must
// stay unpadded.

test "blocks: -s uses a one-column field when every count is a single digit" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Empty files are the narrowest allocation this filesystem will report.
    // The field is sized to the widest actual count, not a hardcoded four.
    try env.createFile("a", "");
    try env.createFile("b", "");
    const a_blocks = try env.tmp_dir.fileBlocks512("a");
    const b_blocks = try env.tmp_dir.fileBlocks512("b");
    try common.test_dir.skipUnlessWidestHasDigits(@max(a_blocks, b_blocks), 1);
    try testing.expect(common.test_dir.decimalDigitWidth(@max(a_blocks, b_blocks)) == 1);

    try env.runLs(.{ .show_blocks = true, .one_per_line = true });

    var expected_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer expected_aw.deinit();
    try test_utils.writeOnePerLineBlocks(
        &expected_aw.writer,
        &.{ "a", "b" },
        &.{ a_blocks, b_blocks },
        true,
    );
    try std.testing.expectEqualStrings(expected_aw.writer.buffered(), env.getStdout());
}

test "blocks: -s right-aligns counts in a field sized to the widest count" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // The width-1 fixture above cannot tell "size the field to the widest
    // count" apart from "never pad at all". The large file is grown until
    // this filesystem reports a wider `st_blocks` than the empty file.
    try env.createFile("a", "");
    const grown = try growUntilWiderBlocks(&env, "a", "b", TEST_SIZE_4K * 2);

    try env.runLs(.{ .show_blocks = true, .one_per_line = true });

    var expected_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer expected_aw.deinit();
    try test_utils.writeOnePerLineBlocks(
        &expected_aw.writer,
        &.{ "a", "b" },
        &.{ grown.small, grown.large },
        true,
    );
    try std.testing.expectEqualStrings(expected_aw.writer.buffered(), env.getStdout());
}

test "blocks: -s keeps a four-column field when the widest count has four digits" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Negative space for the two tests above: sizing the field to the data
    // must not shrink a listing that genuinely needs four columns. A dense
    // 1 MiB write is four digits on APFS, ext4, and FFS; if this filesystem
    // still reports fewer, the file is grown or the fixture is skipped.
    const huge_blocks = try growUntilBlockDigits(&env, "huge", 1 << 20, 4);
    try env.createFile("tiny", "xy");
    const tiny_blocks = try env.tmp_dir.fileBlocks512("tiny");
    try common.test_dir.skipUnlessWidestHasDigits(@max(huge_blocks, tiny_blocks), 4);

    try env.runLs(.{ .show_blocks = true, .one_per_line = true });

    var expected_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer expected_aw.deinit();
    try test_utils.writeOnePerLineBlocks(
        &expected_aw.writer,
        &.{ "huge", "tiny" },
        &.{ huge_blocks, tiny_blocks },
        true,
    );
    try std.testing.expectEqualStrings(expected_aw.writer.buffered(), env.getStdout());
}

test "blocks: -l -s uses a one-column field when every count is a single digit" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // Long format prints the -s prefix from printLongFormatEntryAligned, a
    // call site separate from the one-per-line and columnar paths, and it
    // carried its own copy of the hardcoded four-column format. Synthetic
    // entries with no stat report 0 blocks, which keeps the rest of the line
    // on the "?" fallbacks and lets this pin the whole line byte for byte
    // instead of only the prefix. Verified against macOS /bin/ls -ls on two
    // empty files, whose lines begin "0 -rw-r--r--" and not "   0 -rw-...".
    var entries = [_]types.Entry{
        .{ .name = "a.txt", .kind = .file },
        .{ .name = "b.txt", .kind = .file },
    };

    const options = types.LsOptions{ .long_format = true, .show_blocks = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);

    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    const expected = "total 0\n" ++
        "0 " ++ long_format_null_stat_prefix ++ "a.txt\n" ++
        "0 " ++ long_format_null_stat_prefix ++ "b.txt\n";
    try std.testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "blocks: -l -s right-aligns counts in a field sized to the widest count" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    // Same mixed-width fixture as the one-per-line alignment test, through
    // the long-format path. Only the -s prefix is asserted: our long format
    // pads the nlink, owner, group and size columns differently from BSD,
    // which is a pre-existing divergence and out of scope here.
    try env.createFile("a", "");
    const grown = try growUntilWiderBlocks(&env, "a", "b", TEST_SIZE_4K * 2);
    const field = common.test_dir.decimalDigitWidth(@max(grown.small, grown.large));

    try env.runLs(.{ .show_blocks = true, .long_format = true });

    // Line 0 is the "total" header, so the two entry lines are 1 and 2.
    var lines = std.mem.splitScalar(u8, env.getStdout(), '\n');
    _ = lines.next() orelse return error.MissingTotalLine;
    const line_a = lines.next() orelse return error.MissingEntryLine;
    const line_b = lines.next() orelse return error.MissingEntryLine;

    var prefix_a: std.Io.Writer.Allocating = .init(testing.allocator);
    defer prefix_a.deinit();
    var prefix_b: std.Io.Writer.Allocating = .init(testing.allocator);
    defer prefix_b.deinit();
    try test_utils.writeBlockPrefix(&prefix_a.writer, grown.small, field);
    try test_utils.writeBlockPrefix(&prefix_b.writer, grown.large, field);
    try prefix_a.writer.writeByte('-');
    try prefix_b.writer.writeByte('-');

    const want_a = prefix_a.writer.buffered();
    const want_b = prefix_b.writer.buffered();
    try std.testing.expect(line_a.len >= want_a.len);
    try std.testing.expect(line_b.len >= want_b.len);
    try std.testing.expectEqualStrings(want_a, line_a[0..want_a.len]);
    try std.testing.expectEqualStrings(want_b, line_b[0..want_b.len]);
}

// ============================================================================
// Issue #124: -l nlink/owner/group/size column widths
//
// writeNlinkColored/writeOwnerColored/writeGroupColored/writeSizeColored
// currently hardcode their field widths (3/8/8/5-or-8) instead of sizing
// each column to the widest value actually present in the section, the way
// max_time_width and block_prefix_width already do a few lines above in
// printEntries_longFormat. Every test below asserts the pinned GNU
// coreutils 9.4 behavior (LC_ALL=C TZ=UTC, verified on this host) and is
// expected to fail against the current hardcoded-width code.
//
// uid 0 resolves to "root" via a real getpwuid lookup on every platform
// vibeutils targets (POSIX guarantees uid 0 is root), so it is used
// wherever a stable, portable owner *name* is needed. gid 0 is NOT
// portable the same way: getgrgid(0) resolves to "root" on Linux but to
// "wheel" on macOS -- this repo's CI runs `zig build test` on macos-26,
// and this is exactly the macOS failure class CLAUDE.md calls out. Tests
// below that use `.gid = 0` as a group-column filler therefore resolve
// the real name via `groupName` at test time and build their expected
// field with `padField`, rather than hardcoding the Linux-only literal
// "root" -- so the WIDTH/alignment arithmetic each test actually pins is
// unaffected while the rendered TEXT adapts to whatever the host's gid 0
// really resolves to. Tests that need two genuinely different-width
// values (to prove dynamic sizing, not just correct rendering of a single
// width) use -n numeric ids instead, since arbitrary uid/gid numbers are
// fully controllable without depending on real system accounts. The one
// scenario that specifically needs a real long *name* (not a number) --
// two names of different lengths in one section -- is covered separately
// in ls_test.sh against the real "systemd-network" (15 chars) account
// pinned in the issue.
// ============================================================================

/// Issue #124 test helper: the owner name uid `uid` really renders as on
/// this host -- a resolved account name, or uid's own decimal string when
/// the lookup fails. This is the same lookup (and the same numeric
/// fallback) the formatter measures its column width with, so deriving an
/// expectation from it is correct on any host by construction rather than
/// correct on Linux by luck. Cannot fail: getUserName's only error comes
/// from bufPrint, and 16 bytes hold every u32 (10 digits).
fn userName(uid: u32, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= 16);
    const name = common.file.getUserName(uid, buf) catch unreachable;
    std.debug.assert(name.len > 0);
    return name;
}

/// Issue #124 test helper: the group name gid `gid` really renders as on
/// this host -- gid 0 is "root" on Linux but "wheel" on macOS, and an
/// unmapped gid renders as its own digits (see the block comment above).
/// Resolving it at test time keeps every test below correct on both
/// platforms instead of hardcoding the Linux-only literal. Cannot fail for
/// the same reason userName cannot.
fn groupName(gid: u32, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= 16);
    const name = common.file.getGroupName(gid, buf) catch unreachable;
    std.debug.assert(name.len > 0);
    return name;
}

/// Issue #124 test helper: builds a field exactly the way the real
/// write-helpers do -- `name` padded to `width` on the correct side (left
/// for name mode, right for `-n` numeric mode), plus exactly one trailing
/// separator space -- so tests can assert against a runtime-resolved name
/// (e.g. `groupName`) instead of only a comptime string literal.
fn padField(buf: []u8, name: []const u8, width: usize, right_align: bool) []const u8 {
    std.debug.assert(width >= name.len);
    std.debug.assert(buf.len > width);
    if (right_align) {
        const pad = width - name.len;
        @memset(buf[0..pad], ' ');
        @memcpy(buf[pad .. pad + name.len], name);
    } else {
        @memcpy(buf[0..name.len], name);
        @memset(buf[name.len..width], ' ');
    }
    buf[width] = ' ';
    return buf[0 .. width + 1];
}

test "printEntries: fixture uids 424242 and 123456789 do not resolve to real accounts" {
    // Several tests below use these two uids/gids specifically because they
    // are expected to be unresolvable via getpwuid/getgrgid, so
    // common.file.getUserName/getGroupName fall back to rendering the
    // uid/gid as a decimal string -- giving controllable, genuinely
    // different-width NAME-mode values without depending on any real
    // /etc/passwd or /etc/group entry. If a host's NSS configuration (e.g.
    // a very full nss-systemd dynamic range, or a real local account/group
    // at one of these ids) resolved either id to an actual name, every test
    // depending on this fallback would fail with a confusing width mismatch
    // instead of a clear cause. This guard fails fast with that explicit
    // cause instead. Both getUserName and getGroupName are checked because
    // tests below use these values as both uid (owner) and gid (group).
    var buf: [32]u8 = undefined;
    const name_424242 = try common.file.getUserName(424242, &buf);
    try testing.expectEqualStrings("424242", name_424242);

    var buf2: [32]u8 = undefined;
    const name_123456789 = try common.file.getUserName(123456789, &buf2);
    try testing.expectEqualStrings("123456789", name_123456789);

    var buf3: [32]u8 = undefined;
    const group_424242 = try common.file.getGroupName(424242, &buf3);
    try testing.expectEqualStrings("424242", group_424242);

    var buf4: [32]u8 = undefined;
    const group_123456789 = try common.file.getGroupName(123456789, &buf4);
    try testing.expectEqualStrings("123456789", group_123456789);

    // uid 500 is used below (alongside uid 0 == "root") specifically
    // *because* its unresolved fallback name ("500", 3 chars) has fewer
    // digits than "root" has letters (4) -- the one combination that can
    // distinguish "column width measured from the rendered name" from a
    // buggy "column width measured from the uid's decimal digit count"
    // (which would coincide with the name width for every OTHER fixture
    // uid in this file, since an unresolved name always equals its own
    // digit string). Guarded the same way as 424242/123456789 above.
    var buf5: [32]u8 = undefined;
    const name_500 = try common.file.getUserName(500, &buf5);
    try testing.expectEqualStrings("500", name_500);
}

test "printEntries: fixture uid 0 resolves to root; fixture gid 0 does not assume a name" {
    // uid 0 is used everywhere below as a stable, portable owner name; this
    // guards that POSIX assumption explicitly instead of letting a
    // violation surface as a confusing width mismatch. Unlike the guard
    // above, gid 0 is NOT asserted to be any particular string -- that is
    // exactly the assumption that is false on macOS (gid 0 is "wheel", not
    // "root") and would also break in a minimal container with no
    // /etc/group. Every test below resolves gid 0's name via
    // `groupName` at test time instead of assuming it; this guard only
    // confirms the lookup succeeds and returns *something* non-empty, not
    // a specific string, and confirms uid 0's name specifically is "root"
    // since every test's OWNER field literal depends on that being true.
    var uid_buf: [32]u8 = undefined;
    const uid0_name = try common.file.getUserName(0, &uid_buf);
    try testing.expectEqualStrings("root", uid0_name);

    var gid_buf: [32]u8 = undefined;
    const gid0_name = groupName(0, &gid_buf);
    try testing.expect(gid0_name.len > 0);
}

test "printEntries: -l nlink and size columns widen to the widest value in a section" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // Mirrors GNU coreutils 9.4 `ls -ld /run/systemd/netif /etc/hostname
    // /usr` (LC_ALL=C TZ=UTC): nlink 1/5/12 widens to a right-aligned
    // two-column field, and size 3/4096/4096 widens to a right-aligned
    // four-column field. Owner and group are pinned to uid/gid 0 ("root")
    // on every entry so this test isolates nlink/size sizing; this is also
    // the REGRESSION GUARD case for the "total N" header and the 10-char
    // permission string, both of which must stay byte-identical to today.
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "a", .kind = .file, .stat = common.file.FileInfo{
            .size = 3,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
            .blocks = 8,
        } },
        .{ .name = "b", .kind = .directory, .stat = common.file.FileInfo{
            .size = 4096,
            .mode = 0o755,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .directory,
            .inode = 2,
            .uid = 0,
            .gid = 0,
            .nlink = 5,
            .blocks = 8,
        } },
        .{ .name = "c", .kind = .directory, .stat = common.file.FileInfo{
            .size = 4096,
            .mode = 0o755,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .directory,
            .inode = 3,
            .uid = 0,
            .gid = 0,
            .nlink = 12,
            .blocks = 8,
        } },
    };

    const options = types.LsOptions{ .long_format = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const PERM_DIR = "drwxr-xr-x";
    const NLINK_1 = "  1 "; // right-aligned to width 2 ("12" is the widest)
    const NLINK_5 = "  5 ";
    const NLINK_12 = " 12 ";
    // left-aligned to width 4 (only value); uid 0 is portably "root".
    const OWNER_ROOT = "root ";
    const SIZE_3 = "   3 "; // right-aligned to width 4 ("4096" is widest)
    const SIZE_4096 = "4096 ";

    // gid 0's name is "root" on Linux but "wheel" on macOS; resolved at
    // test time (see groupName's comment above) so this test's real
    // point -- nlink/size widening -- holds on both platforms.
    var group_name_buf: [32]u8 = undefined;
    const group0 = groupName(0, &group_name_buf);
    var group_field_buf: [32]u8 = undefined;
    const GROUP_ROOT = padField(&group_field_buf, group0, group0.len, false);

    const fmt = "total 12\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_ROOT ++ "{s}" ++ SIZE_3 ++ "{s} a\n" ++
        PERM_DIR ++ NLINK_5 ++ OWNER_ROOT ++ "{s}" ++ SIZE_4096 ++ "{s} b\n" ++
        PERM_DIR ++ NLINK_12 ++ OWNER_ROOT ++ "{s}" ++ SIZE_4096 ++ "{s} c\n";
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        fmt,
        .{ GROUP_ROOT, time_str, GROUP_ROOT, time_str, GROUP_ROOT, time_str },
    );
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -lh size field widens to the widest rendered string, not a hardcoded width" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // Mirrors GNU `ls -ldh /run/systemd/netif /etc/hostname`: human-readable
    // renders "3" and "4.0K", the widest of which is 4 columns -- not the
    // hardcoded 5 that writeSizeColored's human_readable branch uses today.
    // Both entries share nlink 1 (width 1) and uid/gid 0 ("root", width 4)
    // so only the size column's width is under test here.
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "a", .kind = .file, .stat = common.file.FileInfo{
            .size = 3,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
        } },
        .{ .name = "b", .kind = .file, .stat = common.file.FileInfo{
            .size = 4096,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 2,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
        } },
    };

    const options = types.LsOptions{ .long_format = true, .human_readable = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const NLINK_1 = " 1 "; // width 1: both entries have nlink 1
    const OWNER_ROOT = "root ";
    const SIZE_3H = "   3 "; // right-aligned to width 4 ("4.0K" is widest)
    const SIZE_4096H = "4.0K ";

    var group_name_buf: [32]u8 = undefined;
    const group0 = groupName(0, &group_name_buf);
    var group_field_buf: [32]u8 = undefined;
    const GROUP_ROOT = padField(&group_field_buf, group0, group0.len, false);

    const fmt = "total 0\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_ROOT ++ "{s}" ++ SIZE_3H ++ "{s} a\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_ROOT ++ "{s}" ++ SIZE_4096H ++ "{s} b\n";
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        fmt,
        .{ GROUP_ROOT, time_str, GROUP_ROOT, time_str },
    );
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -ln right-aligns numeric ids to the widest value (flips vs name alignment)" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // Mirrors GNU `ls -ldn /run/systemd/netif /etc/hostname`: uid/gid 0 and
    // 998 widen to a RIGHT-aligned three-column field under -n, the
    // opposite alignment from the name case above. writeOwnerColored and
    // writeGroupColored today always left-align regardless of -n.
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "x", .kind = .file, .stat = common.file.FileInfo{
            .size = 3,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
        } },
        .{ .name = "y", .kind = .directory, .stat = common.file.FileInfo{
            .size = 4096,
            .mode = 0o755,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .directory,
            .inode = 2,
            .uid = 998,
            .gid = 998,
            .nlink = 5,
        } },
    };

    const options = types.LsOptions{ .long_format = true, .numeric_ids = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const PERM_DIR = "drwxr-xr-x";
    const NLINK_1 = " 1 "; // width 1: nlinks are 1 and 5
    const NLINK_5 = " 5 ";
    const ID_0 = "  0 "; // right-aligned to width 3 ("998" is widest)
    const ID_998 = "998 ";
    const SIZE_3 = "   3 ";
    const SIZE_4096 = "4096 ";

    const fmt = "total 0\n" ++
        PERM_FILE ++ NLINK_1 ++ ID_0 ++ ID_0 ++ SIZE_3 ++ "{s} x\n" ++
        PERM_DIR ++ NLINK_5 ++ ID_998 ++ ID_998 ++ SIZE_4096 ++ "{s} y\n";
    const expected = try std.fmt.allocPrint(testing.allocator, fmt, .{ time_str, time_str });
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -lo (omit_group) keeps the owner column at the full section width" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // -o (omit_group, matching GNU's -o) drops the group field entirely,
    // but the owner field must still be sized to the widest owner value in
    // the section, not shrink to fit each entry's own value. Numeric ids
    // (uid 7 and 12345) give two fully controllable, genuinely
    // different-width values without depending on real system accounts.
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "p", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 7,
            .gid = 1,
            .nlink = 1,
        } },
        .{ .name = "q", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 2,
            .uid = 12345,
            .gid = 1,
            .nlink = 1,
        } },
    };

    const options = types.LsOptions{ .long_format = true, .numeric_ids = true, .omit_group = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const NLINK_1 = " 1 "; // width 1
    const OWNER_7 = "    7 "; // right-aligned to width 5 ("12345" is widest)
    const OWNER_12345 = "12345 ";
    const SIZE_0 = "0 "; // width 1; no group column follows

    const fmt = "total 0\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_7 ++ SIZE_0 ++ "{s} p\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_12345 ++ SIZE_0 ++ "{s} q\n";
    const expected = try std.fmt.allocPrint(testing.allocator, fmt, .{ time_str, time_str });
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -lo (omit_group) keeps owner column at section width in name mode" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // Both -lo tests above only proved "omit + keep full width" under -n
    // (right-aligned), the pinned GNU -ldo reference is NAME mode
    // (left-aligned, no -n). This closes that gap: an implementation that
    // widens the surviving numeric column correctly but takes the
    // omitted column's width by mistake in name mode would still pass
    // the -n variant while failing here. uid 0 ("root", 4 chars) and an
    // unresolvable uid ("424242", 6 chars, via getUserName's decimal
    // fallback) give two genuinely different name-mode widths.
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "p", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 0,
            .gid = 1,
            .nlink = 1,
        } },
        .{ .name = "q", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 2,
            .uid = 424242,
            .gid = 1,
            .nlink = 1,
        } },
    };

    const options = types.LsOptions{ .long_format = true, .omit_group = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const NLINK_1 = " 1 "; // width 1
    // Left-aligned to width 6 ("424242" is widest): "root" pads with 2
    // trailing spaces, "424242" needs none.
    const OWNER_ROOT = "root   ";
    const OWNER_424242 = "424242 ";
    const SIZE_0 = "0 "; // width 1; no group column follows

    const fmt = "total 0\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_ROOT ++ SIZE_0 ++ "{s} p\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_424242 ++ SIZE_0 ++ "{s} q\n";
    const expected = try std.fmt.allocPrint(testing.allocator, fmt, .{ time_str, time_str });
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -lg (omit_owner) keeps the group column at the full section width" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // Symmetric to the -o test above: -g (omit_owner, matching GNU's -g)
    // drops the owner field, and the surviving group field must still be
    // sized to the widest group value in the section.
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "p", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 1,
            .gid = 7,
            .nlink = 1,
        } },
        .{ .name = "q", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 2,
            .uid = 1,
            .gid = 12345,
            .nlink = 1,
        } },
    };

    const options = types.LsOptions{ .long_format = true, .numeric_ids = true, .omit_owner = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const NLINK_1 = " 1 "; // width 1
    const GROUP_7 = "    7 "; // right-aligned to width 5 ("12345" is widest)
    const GROUP_12345 = "12345 ";
    const SIZE_0 = "0 "; // width 1; no owner column precedes it

    const fmt = "total 0\n" ++
        PERM_FILE ++ NLINK_1 ++ GROUP_7 ++ SIZE_0 ++ "{s} p\n" ++
        PERM_FILE ++ NLINK_1 ++ GROUP_12345 ++ SIZE_0 ++ "{s} q\n";
    const expected = try std.fmt.allocPrint(testing.allocator, fmt, .{ time_str, time_str });
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -lg (omit_owner) keeps group column at section width in name mode" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // Symmetric to the -lo name-mode test above: the pinned GNU -ldg
    // reference is also NAME mode (left-aligned, no -n), and the two -lg
    // tests so far only proved "omit + keep full width" under -n
    // (right-aligned). The issue explicitly notes -o and -g looked
    // byte-identical in the pinned GNU output purely by fixture
    // coincidence (owner name == group name on both files), so the two
    // flags deserve symmetric coverage; an implementation that takes the
    // omitted column's width by mistake specifically on the GROUP side in
    // name mode would still pass every other test while failing here.
    // gid 0 ("root" on Linux, "wheel" on macOS) and an unresolvable gid
    // ("424242", 6 chars) give two genuinely different name-mode widths.
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "p", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 1,
            .gid = 0,
            .nlink = 1,
        } },
        .{ .name = "q", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 2,
            .uid = 1,
            .gid = 424242,
            .nlink = 1,
        } },
    };

    const options = types.LsOptions{ .long_format = true, .omit_owner = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const NLINK_1 = " 1 "; // width 1
    const SIZE_0 = "0 "; // width 1; no owner column precedes it
    // Left-aligned to width 6 ("424242" is widest) on every platform: gid
    // 0's name is "root" (Linux) or "wheel" (macOS), both shorter than 6;
    // resolved at test time (see groupName's comment above).
    var group_name_buf: [32]u8 = undefined;
    const group0 = groupName(0, &group_name_buf);
    var group_field_buf: [32]u8 = undefined;
    const GROUP_ROOT = padField(&group_field_buf, group0, 6, false);
    const GROUP_424242 = "424242 ";

    const fmt = "total 0\n" ++
        PERM_FILE ++ NLINK_1 ++ "{s}" ++ SIZE_0 ++ "{s} p\n" ++
        PERM_FILE ++ NLINK_1 ++ GROUP_424242 ++ SIZE_0 ++ "{s} q\n";
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        fmt,
        .{ GROUP_ROOT, time_str, time_str },
    );
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -l all-minimal section has no filler whitespace anywhere" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // A single entry with nlink 1, owner/group "root" and size 0: every
    // field is already exactly its own section-wide width, so the correct
    // output has exactly one separating space between fields and none of
    // today's hardcoded filler. This is the literal example from issue
    // #124: "-rw-r--r-- 1 root root 0 <date> a".
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "a", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
        } },
    };

    const options = types.LsOptions{ .long_format = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    // gid 0's name is "root" on Linux but "wheel" on macOS; resolved at
    // test time (see groupName's comment above) instead of hardcoding
    // the issue's Linux-only literal, so this test's real point -- no
    // filler whitespace anywhere -- holds on both platforms.
    var group_name_buf: [32]u8 = undefined;
    const group0 = groupName(0, &group_name_buf);

    const fmt = "total 0\n" ++ "-rw-r--r-- 1 root {s} 0 {s} a\n";
    const expected = try std.fmt.allocPrint(testing.allocator, fmt, .{ group0, time_str });
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -ls block-size prefix width is independent of nlink/owner/group/size widths" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // Mirrors GNU `ls -lds /run/systemd/netif /etc/hostname`: the -s block
    // prefix is sized to the widest block count in the section (its own,
    // pre-existing computation via blockPrefixWidth) while nlink/owner/
    // group/size size to their own widest values independently. A fix that
    // accidentally couples the two would misalign one or the other here.
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "m", .kind = .file, .stat = common.file.FileInfo{
            .size = 3,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
            .blocks = 1,
        } },
        .{ .name = "n", .kind = .directory, .stat = common.file.FileInfo{
            .size = 4096,
            .mode = 0o755,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .directory,
            .inode = 2,
            .uid = 0,
            .gid = 0,
            .nlink = 12,
            .blocks = 20,
        } },
    };

    const options = types.LsOptions{ .long_format = true, .show_blocks = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const BLOCK_1 = " 1 "; // right-aligned to width 2 ("20" is widest)
    const BLOCK_20 = "20 ";
    const PERM_FILE = "-rw-r--r--";
    const PERM_DIR = "drwxr-xr-x";
    const NLINK_1 = "  1 "; // width 2 ("12" is widest)
    const NLINK_12 = " 12 ";
    const OWNER_ROOT = "root ";
    const SIZE_3 = "   3 "; // width 4 ("4096" is widest)
    const SIZE_4096 = "4096 ";

    var group_name_buf: [32]u8 = undefined;
    const group0 = groupName(0, &group_name_buf);
    var group_field_buf: [32]u8 = undefined;
    const GROUP_ROOT = padField(&group_field_buf, group0, group0.len, false);

    const fmt = "total 11\n" ++
        BLOCK_1 ++ PERM_FILE ++ NLINK_1 ++ OWNER_ROOT ++ "{s}" ++
        SIZE_3 ++ "{s} m\n" ++
        BLOCK_20 ++ PERM_DIR ++ NLINK_12 ++ OWNER_ROOT ++ "{s}" ++
        SIZE_4096 ++ "{s} n\n";
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        fmt,
        .{ GROUP_ROOT, time_str, GROUP_ROOT, time_str },
    );
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -l all-null-stat section collapses every fallback column to width one" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // Direct, single-entry version of the constant `long_format_null_stat_prefix`
    // used above -- a fresh assertion of the exact literal quoted in issue
    // #124 ("---------- ? ? ? ? ??? ?? ??:?? name"), independent of the
    // shared multi-entry fixture those tests use.
    var entries = [_]types.Entry{
        .{ .name = "z", .kind = .file },
    };

    const options = types.LsOptions{ .long_format = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    try testing.expectEqualStrings(
        "total 0\n" ++ "---------- ? ? ? ? ??? ?? ??:?? z\n",
        buf.writer.buffered(),
    );
}

// ----------------------------------------------------------------------
// Issue #124 follow-up (2nd review round): every "?" fallback test above
// only ever exercises an ALL-null-stat section, where the correct column
// width happens to be 1 for every field. That degenerate case cannot
// distinguish a real fix from an implementation that just hardcodes the
// fallback writes to width 1 (e.g. `writeAll(" ? ")` at formatter.zig's
// null-stat branches) -- such a stub would pass every test above while
// still misaligning the real-world case the fallbacks exist for: one
// entry whose lstat failed sitting next to siblings that stat'd fine
// (entry_collector leaves `.stat = null` only for the failed entry). These
// two tests mix a real-stat entry with a null-stat entry in the same
// section so the fallbacks must pad out to the *stat-derived* section
// width, not their own degenerate width of 1.
// ----------------------------------------------------------------------

test "printEntries: mixed section pads null-stat fallbacks to the stat-derived widths (names)" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // Entry "a" has a real stat (nlink 12, uid/gid 0 -> "root", size 4096);
    // entry "b" has `.stat = null`. The section's nlink/owner/group/size
    // widths are driven entirely by "a" (2/4/4/4), so "b"'s "?" fallbacks
    // must pad to those widths, not collapse to width 1 the way an
    // all-null section's fallbacks correctly do.
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "a", .kind = .file, .stat = common.file.FileInfo{
            .size = 4096,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 0,
            .gid = 0,
            .nlink = 12,
            .blocks = 8,
        } },
        .{ .name = "b", .kind = .file },
    };

    const options = types.LsOptions{ .long_format = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const PERM_NULL = "----------";
    const NLINK_A = " 12 "; // right-aligned to width 2 (only "a" has a real nlink)
    const NLINK_NULL = "  ? "; // "?" right-aligned to the same width-2 column
    const OWNER_A = "root "; // left-aligned to width 4 ("root" is widest)
    const OWNER_NULL = "?    "; // "?" left-aligned to the same width-4 column
    const SIZE_A = "4096 "; // right-aligned to width 4 (only "a" has a real size)
    const SIZE_NULL = "   ? "; // "?" right-aligned to the same width-4 column
    const DATE_NULL = "??? ?? ??:?? "; // unaffected by this bug, its own fallback

    // "a"'s group is gid 0, whose name is "root" on Linux but "wheel" on
    // macOS; resolved at test time (see groupName's comment above) so
    // the width this test pins holds on both platforms. The null-stat "?"
    // fallback pads to that same resolved width.
    var group_name_buf: [32]u8 = undefined;
    const group0 = groupName(0, &group_name_buf);
    var group_field_buf: [32]u8 = undefined;
    const GROUP_A = padField(&group_field_buf, group0, group0.len, false);
    var group_null_field_buf: [32]u8 = undefined;
    const GROUP_NULL = padField(&group_null_field_buf, "?", group0.len, false);

    const fmt = "total 4\n" ++
        PERM_FILE ++ NLINK_A ++ OWNER_A ++ "{s}" ++ SIZE_A ++ "{s} a\n" ++
        PERM_NULL ++ NLINK_NULL ++ OWNER_NULL ++ "{s}" ++ SIZE_NULL ++
        DATE_NULL ++ "b\n";
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        fmt,
        .{ GROUP_A, time_str, GROUP_NULL },
    );
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -ln mixed section right-aligns null-stat id/size fallbacks (flips vs names)" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // Same shape as the name-mode mixed-section test above, but under -n:
    // uid/gid 998 (3 digits) is the widest owner/group value in the
    // section, so both the real "998" and the null-stat "?" fallback must
    // be RIGHT-aligned to width 3 -- proving the alignment flip applies to
    // the fallback too, not just to real numeric ids.
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "a", .kind = .file, .stat = common.file.FileInfo{
            .size = 4096,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 998,
            .gid = 998,
            .nlink = 5,
            .blocks = 8,
        } },
        .{ .name = "b", .kind = .file },
    };

    const options = types.LsOptions{ .long_format = true, .numeric_ids = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const PERM_NULL = "----------";
    const NLINK_A = " 5 "; // right-aligned to width 1 (only "a" has a real nlink)
    const NLINK_NULL = " ? "; // "?" right-aligned to the same width-1 column
    const OWNER_GROUP_A = "998 "; // right-aligned to width 3 ("998" is widest, under -n)
    const OWNER_GROUP_NULL = "  ? "; // "?" right-aligned to the same width-3 column
    const SIZE_A = "4096 "; // right-aligned to width 4 (only "a" has a real size)
    const SIZE_NULL = "   ? "; // "?" right-aligned to the same width-4 column
    const DATE_NULL = "??? ?? ??:?? "; // unaffected by this bug, its own fallback

    const fmt = "total 4\n" ++
        PERM_FILE ++ NLINK_A ++ OWNER_GROUP_A ++ OWNER_GROUP_A ++ SIZE_A ++ "{s} a\n" ++
        PERM_NULL ++ NLINK_NULL ++ OWNER_GROUP_NULL ++ OWNER_GROUP_NULL ++ SIZE_NULL ++
        DATE_NULL ++ "b\n";
    const expected = try std.fmt.allocPrint(testing.allocator, fmt, .{time_str});
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

// ----------------------------------------------------------------------
// Issue #124 follow-up (review round): every test above only ever SHRINKS
// a column relative to the old hardcoded width (3/8/8/5-or-8), so an
// implementation that caps rather than maximizes (e.g. @min(8, widest))
// would pass all of them while leaving the reported defect -- a value
// wider than the old hardcode -- unfixed. These tests use values that
// exceed each old hardcode, and separately isolate name (left-align) from
// numeric (right-align) owner/group rendering, which the tests above never
// did (every non-numeric case used uid 0 on every entry).
// ----------------------------------------------------------------------

test "printEntries: -l nlink column widens past the old hardcoded 3-column width" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // nlink 1234 (4 digits) exceeds the old hardcoded width-3 format spec;
    // owner/group (uid/gid 0 on every entry) and size (0 on every entry)
    // are held fixed so only nlink sizing is under test.
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "a", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
        } },
        .{ .name = "b", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 2,
            .uid = 0,
            .gid = 0,
            .nlink = 1234,
        } },
    };

    const options = types.LsOptions{ .long_format = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const NLINK_1 = "    1 "; // right-aligned to width 4 ("1234" is widest)
    const NLINK_1234 = " 1234 ";
    const OWNER_ROOT = "root ";
    const SIZE_0 = "0 ";

    var group_name_buf: [32]u8 = undefined;
    const group0 = groupName(0, &group_name_buf);
    var group_field_buf: [32]u8 = undefined;
    const GROUP_ROOT = padField(&group_field_buf, group0, group0.len, false);

    const fmt = "total 0\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_ROOT ++ "{s}" ++ SIZE_0 ++ "{s} a\n" ++
        PERM_FILE ++ NLINK_1234 ++ OWNER_ROOT ++ "{s}" ++ SIZE_0 ++ "{s} b\n";
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        fmt,
        .{ GROUP_ROOT, time_str, GROUP_ROOT, time_str },
    );
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -l plain size column widens past the old hardcoded 8-column width" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // A 9-digit size (123456789) exceeds the old hardcoded width-8 format
    // spec used by writeSizeColored's non-human-readable branch.
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "a", .kind = .file, .stat = common.file.FileInfo{
            .size = 3,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
        } },
        .{ .name = "b", .kind = .file, .stat = common.file.FileInfo{
            .size = 123456789,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 2,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
        } },
    };

    const options = types.LsOptions{ .long_format = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const NLINK_1 = " 1 ";
    const OWNER_ROOT = "root ";
    const SIZE_3 = "        3 "; // right-aligned to width 9 ("123456789" is widest)
    const SIZE_BIG = "123456789 ";

    var group_name_buf: [32]u8 = undefined;
    const group0 = groupName(0, &group_name_buf);
    var group_field_buf: [32]u8 = undefined;
    const GROUP_ROOT = padField(&group_field_buf, group0, group0.len, false);

    const fmt = "total 0\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_ROOT ++ "{s}" ++ SIZE_3 ++ "{s} a\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_ROOT ++ "{s}" ++ SIZE_BIG ++ "{s} b\n";
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        fmt,
        .{ GROUP_ROOT, time_str, GROUP_ROOT, time_str },
    );
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -l owner/group names left-align, proven with two different-width real values" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // Every non-numeric-mode test above pins uid/gid 0 on EVERY entry, so
    // "root" is simultaneously the only value and the widest -- padding
    // direction is unobservable. Here uid 0 ("root", 4 chars) sits next to
    // an unresolvable uid, which common.file.getUserName/getGroupName fall
    // back to rendering as its decimal string ("424242", 6 chars) rather
    // than failing -- giving two genuinely different-width NAME-mode
    // values without depending on any real /etc/passwd entry or on -n.
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "a", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
        } },
        .{ .name = "b", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 2,
            .uid = 424242,
            .gid = 424242,
            .nlink = 1,
        } },
    };

    const options = types.LsOptions{ .long_format = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const NLINK_1 = " 1 ";
    const SIZE_0 = "0 ";
    // Left-aligned to width 6 ("424242" is widest): "root" pads with 2
    // trailing spaces, "424242" needs none. Right-alignment would instead
    // pad on the LEFT of "root" -- that's the direction this test pins.
    // "root" is uid 0's owner name, portably stable on every platform.
    const OWNER_ROOT = "root   ";
    const OWNER_424242 = "424242 ";

    // gid 0's group name is "root" on Linux but "wheel" on macOS; either
    // way its length (4 or 5) is still shorter than "424242" (6), so the
    // column's width stays 6 regardless of platform -- resolved at test
    // time (see groupName's comment above) so only the padding amount
    // for the group-0 entry, not the width itself, varies by platform.
    var group_name_buf: [32]u8 = undefined;
    const group0 = groupName(0, &group_name_buf);
    var group_field_buf: [32]u8 = undefined;
    const GROUP_ROOT = padField(&group_field_buf, group0, 6, false);
    const GROUP_424242 = "424242 ";

    const fmt = "total 0\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_ROOT ++ "{s}" ++ SIZE_0 ++ "{s} a\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_424242 ++ GROUP_424242 ++ SIZE_0 ++ "{s} b\n";
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        fmt,
        .{ GROUP_ROOT, time_str, time_str },
    );
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -l owner/group names (no -n) widen past the old hardcoded 8 columns" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // Combines the previous two tests: NAME-mode (left-aligned, no -n) with
    // a rendered width (9, via the unresolvable-uid decimal fallback) wider
    // than the old hardcoded 8. An implementation that only widens the
    // NUMERIC (-n) path, or that caps name width at 8, fails this.
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "a", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
        } },
        .{ .name = "b", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 2,
            .uid = 123456789,
            .gid = 123456789,
            .nlink = 1,
        } },
    };

    const options = types.LsOptions{ .long_format = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const NLINK_1 = " 1 ";
    const SIZE_0 = "0 ";
    // Left-aligned to width 9 ("123456789" is widest, > the old hardcoded
    // 8) regardless of whether uid/gid 0's names are "root"/"root" (Linux)
    // or "root"/"wheel" (macOS) -- both are shorter than 9.
    const OWNER_ROOT = "root      ";
    const OWNER_BIG = "123456789 ";

    var group_name_buf: [32]u8 = undefined;
    const group0 = groupName(0, &group_name_buf);
    var group_field_buf: [32]u8 = undefined;
    const GROUP_ROOT = padField(&group_field_buf, group0, 9, false);
    const GROUP_BIG = "123456789 ";

    const fmt = "total 0\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_ROOT ++ "{s}" ++ SIZE_0 ++ "{s} a\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_BIG ++ GROUP_BIG ++ SIZE_0 ++ "{s} b\n";
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        fmt,
        .{ GROUP_ROOT, time_str, time_str },
    );
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -l owner/group name-mode widens to a genuinely long rendered name" {
    // The pinned GNU scenario in issue #124 needs a real 15-char account
    // name ("systemd-network") in the same section as "root"; that
    // specific pairing is only reproducible against a real filesystem and
    // is covered in ls_test.sh (gated on that account existing). uid/gid
    // are u32 (see common.file.FileInfo), so the unresolved-id decimal
    // fallback this file uses everywhere else for a controllable
    // different-width name can reach at most 10 digits
    // ("4294967295" == u32 max) -- short of 15, but still a genuinely
    // long rendered name, wider than any width this test file has
    // exercised elsewhere, and it runs deterministically on every host
    // (Linux or macOS, with or without a systemd-network account), unlike
    // the shell-level fixture.
    //
    // Which of those two ids actually resolves is NOT portable, so no
    // width is hardcoded here: both columns are sized from the names
    // userName/groupName really return on this host. Linux resolves
    // neither maxInt(u32) id and renders "4294967295" in both columns;
    // macOS resolves gid -1 to the real group "nogroup" (7 chars) while
    // leaving the uid unresolved, which is exactly what made a hardcoded
    // width-10 group column fail there.
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "a", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
        } },
        .{ .name = "b", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 2,
            .uid = std.math.maxInt(u32),
            .gid = std.math.maxInt(u32),
            .nlink = 1,
        } },
    };

    const options = types.LsOptions{ .long_format = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const NLINK_1 = " 1 ";
    const SIZE_0 = "0 ";

    const big_id = std.math.maxInt(u32);
    var owner0_buf: [32]u8 = undefined;
    var owner_big_buf: [32]u8 = undefined;
    const owner0 = userName(0, &owner0_buf);
    const owner_big = userName(big_id, &owner_big_buf);
    var group0_buf: [32]u8 = undefined;
    var group_big_buf: [32]u8 = undefined;
    const group0 = groupName(0, &group0_buf);
    const group_big = groupName(big_id, &group_big_buf);

    // Each column is exactly as wide as the widest name it must hold. Both
    // long names are genuinely longer than the short ones -- that widening
    // is the entire point of this test, and a fixture that failed to
    // produce it would silently assert nothing -- so it is asserted rather
    // than assumed. It holds on every host: uid 0 and gid 0 are the
    // shortest ids there are ("root" 4, "wheel" 5), while maxInt(u32)
    // renders either its own 10 digits or a real long-tail account name
    // ("nogroup", 7, on macOS).
    try testing.expect(owner_big.len > owner0.len);
    try testing.expect(group_big.len > group0.len);
    const owner_width = @max(owner0.len, owner_big.len);
    const group_width = @max(group0.len, group_big.len);

    // Neither width may coincide with the 8 columns the pre-#124 code
    // hardcoded, or this test could pass against that very regression.
    // Linux gives 10 and 10, macOS 10 and 7.
    try testing.expect(owner_width != 8);
    try testing.expect(group_width != 8);

    var owner0_field_buf: [32]u8 = undefined;
    var owner_big_field_buf: [32]u8 = undefined;
    var group0_field_buf: [32]u8 = undefined;
    var group_big_field_buf: [32]u8 = undefined;
    const OWNER_ROOT = padField(&owner0_field_buf, owner0, owner_width, false);
    const OWNER_BIG = padField(&owner_big_field_buf, owner_big, owner_width, false);
    const GROUP_ROOT = padField(&group0_field_buf, group0, group_width, false);
    const GROUP_BIG = padField(&group_big_field_buf, group_big, group_width, false);

    const fmt = "total 0\n" ++
        PERM_FILE ++ NLINK_1 ++ "{s}{s}" ++ SIZE_0 ++ "{s} a\n" ++
        PERM_FILE ++ NLINK_1 ++ "{s}{s}" ++ SIZE_0 ++ "{s} b\n";
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        fmt,
        .{ OWNER_ROOT, GROUP_ROOT, time_str, OWNER_BIG, GROUP_BIG, time_str },
    );
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -l owner/group name-mode width comes from the rendered name, not the uid" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // Every other name-mode width test above pairs uid 0 ("root", 4 chars)
    // with an UNRESOLVED uid, whose fallback name is always its own decimal
    // digit string -- so "widest rendered name" and "widest uid digit
    // count" always happen to agree there (the bigger number's digit
    // string is also the longer name). That leaves a real gap: an
    // implementation that measures column width off stat.uid's decimal
    // length instead of the actually-printed name would still pass every
    // one of those tests.
    //
    // This test breaks that coincidence deliberately: uid 500 renders as
    // "500" (name width 3, digit width 3 -- ordinary), but uid 0 renders
    // as "root" (name width 4, digit width only 1). So:
    //   - correct (name-width) hypothesis: max(len("500"), len("root")) = 4
    //   - buggy (digit-width) hypothesis:   max(len("500"), len("0"))    = 3
    // A digit-width implementation would render "500" fully packed at
    // width 3, one column narrower than the correct width-4 field. Group
    // is pinned to gid 0 ("root") on both entries so only the owner column
    // is under test.
    //
    // uid 500 does not resolve, so it prints as a BARE NUMBER, and GNU's
    // format_user_or_group right-aligns those -- it keys the alignment on
    // what it printed, not on -n. Verified against GNU coreutils on this
    // host with a fixture chowned to the unmapped uid 500 (LC_ALL=C):
    //   -rw-r--r-- 1 root root 0 ... a
    //   -rw-r--r-- 1  500  500 0 ... b
    // So the expected owner field for uid 500 is " 500", right-aligned in
    // the name-derived width-4 column, next to the LEFT-aligned "root" in
    // that same column.
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "a", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 500,
            .gid = 0,
            .nlink = 1,
        } },
        .{ .name = "b", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 2,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
        } },
    };

    const options = types.LsOptions{ .long_format = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const NLINK_1 = " 1 ";
    const SIZE_0 = "0 ";
    // Width 4 comes from "root" (rendered length), NOT from "500" by digit
    // count. "root" is a resolved name and left-aligns; "500" is a bare
    // number and right-aligns, so its one pad column lands in FRONT.
    const OWNER_500 = " 500 ";
    const OWNER_ROOT = "root ";
    // Group is gid 0 on both entries, so its own width is just its own
    // resolved length regardless; this isolates the owner column as the
    // only variable under test. Resolved at test time (see
    // groupName's comment above) since gid 0's name is "root" on
    // Linux but "wheel" on macOS.
    var group_name_buf: [32]u8 = undefined;
    const group0 = groupName(0, &group_name_buf);
    var group_field_buf: [32]u8 = undefined;
    const GROUP_ROOT = padField(&group_field_buf, group0, group0.len, false);

    const fmt = "total 0\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_500 ++ "{s}" ++ SIZE_0 ++ "{s} a\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_ROOT ++ "{s}" ++ SIZE_0 ++ "{s} b\n";
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        fmt,
        .{ GROUP_ROOT, time_str, GROUP_ROOT, time_str },
    );
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -l right-aligns a bare numeric id beside a left-aligned name in one column" {
    // GNU's format_user_or_group picks the alignment from WHAT IT PRINTED,
    // not from -n: a resolved name left-aligns, a bare numeric id
    // right-aligns, and both happen inside the same section column. The
    // -n tests elsewhere in this file cannot see the difference, because
    // -n makes every value numeric; the name-mode tests cannot either,
    // because their unresolved ids happen to be the widest value and so
    // fill the column exactly, leaving no pad to place on either side.
    //
    // Here three entries make the pad visible on both rules at once. In
    // the owner column: "root" (resolved, 4) left-aligned, "123456789"
    // (unresolved, 9, the width) exact, and "500" (unresolved, 3)
    // right-aligned with six leading spaces. The group column repeats it
    // with gid 424242 so both columns are pinned independently. Verified
    // against GNU coreutils on this host with fixtures chowned to the
    // unmapped ids (LC_ALL=C), which prints e.g.
    //   -rw-r--r-- 1 root            root            0 ... a
    //   -rw-r--r-- 1             500             500 0 ... b
    // A regression that keys alignment on options.numeric_ids alone
    // renders "500      " and "424242   " instead.
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "a", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
        } },
        .{ .name = "b", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 2,
            .uid = 500,
            .gid = 424242,
            .nlink = 1,
        } },
        .{ .name = "c", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 3,
            .uid = 123456789,
            .gid = 123456789,
            .nlink = 1,
        } },
    };

    const options = types.LsOptions{ .long_format = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const NLINK_1 = " 1 ";
    const SIZE_0 = "0 ";
    // Both columns are 9 wide ("123456789"). gid 0's name is "root" on
    // Linux and "wheel" on macOS, so the group field for entry "a" is
    // built from the resolved name; either way it is shorter than 9 and
    // left-aligned, while every numeric field right-aligns.
    const OWNER_ROOT = "root      ";
    const OWNER_500 = "      500 ";
    const OWNER_BIG = "123456789 ";
    const GROUP_424242 = "   424242 ";
    const GROUP_BIG = "123456789 ";

    var group_name_buf: [32]u8 = undefined;
    const group0 = groupName(0, &group_name_buf);
    var group_field_buf: [32]u8 = undefined;
    const GROUP_ROOT = padField(&group_field_buf, group0, 9, false);

    const fmt = "total 0\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_ROOT ++ "{s}" ++ SIZE_0 ++ "{s} a\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_500 ++ GROUP_424242 ++ SIZE_0 ++ "{s} b\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_BIG ++ GROUP_BIG ++ SIZE_0 ++ "{s} c\n";
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        fmt,
        .{ GROUP_ROOT, time_str, time_str, time_str },
    );
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -l owner and group columns size independently, not to a shared max" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // Every other test in this block sets uid == gid on every entry (or
    // omits one column entirely), so an implementation that computes ONE
    // shared width = @max(widest owner, widest group) and reuses it for
    // BOTH columns passes every one of them while still diverging from
    // GNU. Verified against real GNU ls on this host: `ls -ld
    // /var/log/journal /etc/hostname` gives owner column 4 wide ("root")
    // and group column 15 wide ("systemd-journal"), sized independently.
    //
    // Here owner is uid 0 ("root", 4 chars) on BOTH entries -- so the
    // owner column's correct width is 4 regardless of what the group
    // column does -- while group is gid 0 ("root", 4 chars) on one entry
    // and gid 424242 ("424242", 6 chars, via the unresolved-id fallback)
    // on the other, so the group column's correct width is 6. A
    // shared-width implementation would widen the owner column to 6 as
    // well ("root  " instead of "root "), which this test catches.
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "a", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
        } },
        .{ .name = "b", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 2,
            .uid = 0,
            .gid = 424242,
            .nlink = 1,
        } },
    };

    const options = types.LsOptions{ .long_format = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const NLINK_1 = " 1 ";
    const SIZE_0 = "0 ";
    // Owner is "root" on every entry: correct width is 4 regardless of
    // the group column's width, so it never grows a trailing pad byte.
    const OWNER_ROOT = "root ";
    // Group left-aligns to width 6 ("424242" is widest in the group
    // column specifically) on every platform: gid 0's name is "root"
    // (Linux) or "wheel" (macOS), both shorter than 6, resolved at test
    // time (see groupName's comment above) since only the padding
    // amount for the group-0 entry -- not the width itself -- varies.
    var group_name_buf: [32]u8 = undefined;
    const group0 = groupName(0, &group_name_buf);
    var group_field_buf: [32]u8 = undefined;
    const GROUP_ROOT = padField(&group_field_buf, group0, 6, false);
    const GROUP_424242 = "424242 ";

    const fmt = "total 0\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_ROOT ++ "{s}" ++ SIZE_0 ++ "{s} a\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_ROOT ++ GROUP_424242 ++ SIZE_0 ++ "{s} b\n";
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        fmt,
        .{ GROUP_ROOT, time_str, time_str },
    );
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -ln numeric owner/group ids widen past the old hardcoded 8 columns" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // -n right-aligns; 4000000000 (10 digits, the largest value that fits
    // in the u32 uid/gid field) exceeds the old hardcoded 8. Pairs with a
    // single-digit uid/gid to prove right-alignment, not just width.
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "a", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 5,
            .gid = 5,
            .nlink = 1,
        } },
        .{ .name = "b", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 2,
            .uid = 4_000_000_000,
            .gid = 4_000_000_000,
            .nlink = 1,
        } },
    };

    const options = types.LsOptions{ .long_format = true, .numeric_ids = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const NLINK_1 = " 1 ";
    const SIZE_0 = "0 ";
    // Right-aligned to width 10 ("4000000000" is widest, > the old hardcoded 8).
    const ID_5 = "         5 ";
    const ID_BIG = "4000000000 ";

    const fmt = "total 0\n" ++
        PERM_FILE ++ NLINK_1 ++ ID_5 ++ ID_5 ++ SIZE_0 ++ "{s} a\n" ++
        PERM_FILE ++ NLINK_1 ++ ID_BIG ++ ID_BIG ++ SIZE_0 ++ "{s} b\n";
    const expected = try std.fmt.allocPrint(testing.allocator, fmt, .{ time_str, time_str });
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: --thousands size column widens to the widest grouped rendered string" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // The vibeutils-only --thousands extension renders sizes with comma
    // grouping ("1,234,567" instead of "1234567"); the section width must
    // come from that RENDERED string, not the raw byte count, or a fix
    // that widens off stat.size instead of the display string misaligns
    // this column while passing the plain/-h branches.
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "a", .kind = .file, .stat = common.file.FileInfo{
            .size = 3,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
        } },
        .{ .name = "b", .kind = .file, .stat = common.file.FileInfo{
            .size = 1234567,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 2,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
        } },
    };

    const options = types.LsOptions{ .long_format = true, .thousands_grouping = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const NLINK_1 = " 1 ";
    const OWNER_ROOT = "root ";
    // Right-aligned to width 9 ("1,234,567" is widest).
    const SIZE_3 = "        3 ";
    const SIZE_GROUPED = "1,234,567 ";

    var group_name_buf: [32]u8 = undefined;
    const group0 = groupName(0, &group_name_buf);
    var group_field_buf: [32]u8 = undefined;
    const GROUP_ROOT = padField(&group_field_buf, group0, group0.len, false);

    const fmt = "total 0\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_ROOT ++ "{s}" ++ SIZE_3 ++ "{s} a\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_ROOT ++ "{s}" ++ SIZE_GROUPED ++ "{s} b\n";
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        fmt,
        .{ GROUP_ROOT, time_str, GROUP_ROOT, time_str },
    );
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -k size column widens to the widest rendered kilobyte string" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // The -k (kilobytes) branch renders a different string than plain or
    // -h ("2" for a 1025-byte file, rounded up) -- the section width must
    // come from that rendered string too.
    //
    // NOTE: in GNU ls, -k affects only -s and the summary total, not the
    // -l size column itself (vibeutils applies it to the size column too,
    // a pre-existing divergence from GNU predating issue #124). This test
    // characterizes width behavior under vibeutils' existing -k semantics;
    // it is not a GNU-parity assertion, and a later GNU-parity fix to -k's
    // scope should not be read as regressing this issue-#124 test.
    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries = [_]types.Entry{
        .{ .name = "a", .kind = .file, .stat = common.file.FileInfo{
            .size = 1,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
        } },
        .{ .name = "b", .kind = .file, .stat = common.file.FileInfo{
            .size = 1025,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 2,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
        } },
    };

    const options = types.LsOptions{ .long_format = true, .kilobytes = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    const NLINK_1 = " 1 ";
    const OWNER_ROOT = "root ";
    // Right-aligned to width 1: "1" byte and "1025" bytes round up to the
    // 1K blocks "1" and "2" respectively -- both single digits, so this is
    // the negative-space companion to the growth tests above (a section
    // whose rendered strings stay narrow must NOT reserve the old
    // hardcoded 8 columns).
    const KB_1 = "1 ";
    const KB_2 = "2 ";

    var group_name_buf: [32]u8 = undefined;
    const group0 = groupName(0, &group_name_buf);
    var group_field_buf: [32]u8 = undefined;
    const GROUP_ROOT = padField(&group_field_buf, group0, group0.len, false);

    const fmt = "total 0\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_ROOT ++ "{s}" ++ KB_1 ++ "{s} a\n" ++
        PERM_FILE ++ NLINK_1 ++ OWNER_ROOT ++ "{s}" ++ KB_2 ++ "{s} b\n";
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        fmt,
        .{ GROUP_ROOT, time_str, GROUP_ROOT, time_str },
    );
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: successive sections each recompute their own column widths independently" {
    // Every test above uses a single printEntries call, i.e. a single
    // section, so none of them prove the widths are SECTION-scoped rather
    // than global/carried across calls. A section boundary is one
    // printEntries_longFormat invocation (one directory's contents, or the
    // grouped list of non-directory operands); ls's real multi-directory
    // output is exactly a sequence of such calls into the same stream, one
    // per directory argument. Calling printEntries twice into the same
    // buffer here mirrors that: section A (nlink 1, size 0) must stay
    // width 1 and must NOT widen just because section B (nlink 100, size
    // 123456), printed right after it into the same writer, needs more
    // columns.
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    const mtime_ns: i128 = 1_700_000_000 * std.time.ns_per_s;
    var entries_a = [_]types.Entry{
        .{ .name = "a", .kind = .file, .stat = common.file.FileInfo{
            .size = 0,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 1,
            .uid = 0,
            .gid = 0,
            .nlink = 1,
        } },
    };
    var entries_b = [_]types.Entry{
        .{ .name = "b", .kind = .file, .stat = common.file.FileInfo{
            .size = 123456,
            .mode = 0o644,
            .atime = mtime_ns,
            .mtime = mtime_ns,
            .kind = .file,
            .inode = 2,
            .uid = 0,
            .gid = 0,
            .nlink = 100,
        } },
    };

    const options = types.LsOptions{ .long_format = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(testing.allocator, &entries_a, &buf.writer, options, style);
    _ = try formatter.printEntries(testing.allocator, &entries_b, &buf.writer, options, style);

    var time_buf: [128]u8 = undefined;
    const time_str = try formatter.formatTimeWithStyle(
        mtime_ns,
        .default,
        testing.allocator,
        &time_buf,
    );

    const PERM_FILE = "-rw-r--r--";
    // Section A: the only entry has nlink 1 and size 0, so both fields
    // must stay width 1 -- NOT width 3 (nlink) or width 6 (size) to
    // accommodate section B's values, which have not been seen yet.
    const NLINK_A = " 1 ";
    const SIZE_A = "0 ";
    // Section B: its own single entry sets its own width (3 for nlink
    // "100", 6 for size "123456") -- NOT widened further by section A.
    const NLINK_B = " 100 ";
    const SIZE_B = "123456 ";
    const OWNER_ROOT = "root ";

    // Both sections' single entry has gid 0, whose name is "root" on
    // Linux but "wheel" on macOS; resolved at test time (see
    // groupName's comment above) so the widths this test pins hold on
    // both platforms. Each section recomputes independently, but since
    // both sections' only value is the same gid 0, the resolved field is
    // identical in both.
    var group_name_buf: [32]u8 = undefined;
    const group0 = groupName(0, &group_name_buf);
    var group_field_buf: [32]u8 = undefined;
    const GROUP_ROOT = padField(&group_field_buf, group0, group0.len, false);

    // Neither entry sets `.blocks` (defaults to 0), so both sections'
    // "total" lines are 0 regardless of `.size` -- unrelated to what this
    // test is checking, just keeping it consistent with the other tests'
    // "total 0\n" convention above.
    const fmt = "total 0\n" ++
        PERM_FILE ++ NLINK_A ++ OWNER_ROOT ++ "{s}" ++ SIZE_A ++ "{s} a\n" ++
        "total 0\n" ++
        PERM_FILE ++ NLINK_B ++ OWNER_ROOT ++ "{s}" ++ SIZE_B ++ "{s} b\n";
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        fmt,
        .{ GROUP_ROOT, time_str, GROUP_ROOT, time_str },
    );
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, buf.writer.buffered());
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
// Issue #ls-git-column: the 3-column git-status prefix must be reserved per
// DIRECTORY SECTION (i.e. per call to printEntries, which is invoked once
// per directory including once per -R subdirectory), not per entry. A
// section where every entry is .clean (or .not_in_repo) must render with no
// reserved column at all, matching --git=never byte for byte; a section
// with at least one real status keeps the column for every entry in that
// section, including the clean ones, so the alignment holds.
// ============================================================================

test "printEntries: all-clean git section drops the reserved column (implicit one-per-line)" {
    var buf_always: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_always.deinit();
    var buf_never: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_never.deinit();

    var entries_always = [_]types.Entry{
        .{ .name = "clean1.txt", .kind = .file, .git_status = .clean },
        .{ .name = "clean2.txt", .kind = .file, .git_status = .clean },
    };
    var entries_never = [_]types.Entry{
        .{ .name = "clean1.txt", .kind = .file, .git_status = .clean },
        .{ .name = "clean2.txt", .kind = .file, .git_status = .clean },
    };

    const style_always = try display.initStyle(testing.allocator, &buf_always.writer, .never);
    const style_never = try display.initStyle(testing.allocator, &buf_never.writer, .never);

    // No explicit -1/-C/-x and is_terminal = false: the non-tty default
    // path (POSIX "same as -1"), exactly issue #113's implicit-pipe case.
    _ = try formatter.printEntries(
        testing.allocator,
        &entries_always,
        &buf_always.writer,
        .{ .show_git_status = true },
        style_always,
    );
    _ = try formatter.printEntries(
        testing.allocator,
        &entries_never,
        &buf_never.writer,
        .{ .show_git_status = false },
        style_never,
    );

    // A directory where every tracked file is clean must render exactly
    // like --git=never: no reserved column, names start at column 0.
    try std.testing.expectEqualStrings("clean1.txt\nclean2.txt\n", buf_never.writer.buffered());
    try std.testing.expectEqualStrings(buf_never.writer.buffered(), buf_always.writer.buffered());
}

test "printEntries: all-clean git section matches --git=never column width arithmetic (-C)" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // Same 5-char-name fixture as the "-C width arithmetic ... (git
    // prefix)" test above, but every entry is clean instead of modified.
    var entries = [_]types.Entry{
        .{ .name = "bbbbb", .kind = .file, .git_status = .clean },
        .{ .name = "ccccc", .kind = .file, .git_status = .clean },
        .{ .name = "ddddd", .kind = .file, .git_status = .clean },
    };

    const options = types.LsOptions{
        .terminal_width = 40,
        .show_git_status = true,
        .multi_column = true,
    };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);

    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    // A wholly clean section must NOT reserve the 3-column git prefix, so
    // the width arithmetic collapses back to the --git=never shape:
    // colwidth = (5+8)&~7 = 8, num_cols = 40/8 = 5, all three names fit on
    // one row with a single tab between each (matching the un-prefixed
    // "bbbbb\tccccc\tddddd" shape the sibling icon/git-prefix tests use as
    // their baseline).
    try std.testing.expectEqualStrings("bbbbb\tccccc\tddddd\n", buf.writer.buffered());
}

test "printEntries: not_in_repo entries stay unaffected inside an all-clean section" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    var entries = [_]types.Entry{
        .{ .name = "clean.txt", .kind = .file, .git_status = .clean },
        .{ .name = "outside.txt", .kind = .file, .git_status = .not_in_repo },
    };

    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(
        testing.allocator,
        &entries,
        &buf.writer,
        .{ .show_git_status = true },
        style,
    );

    // Neither a clean tracked file nor a file outside the repo counts as
    // "dirty", so the section as a whole reserves no column and both names
    // start at column 0.
    try std.testing.expectEqualStrings("clean.txt\noutside.txt\n", buf.writer.buffered());
}

test "printEntries: not_in_repo entry prints no indicator inside a dirty section" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // Section is dirty overall (mmm is modified), so the column IS
    // reserved -- but the .not_in_repo entry must still print nothing of
    // its own (per-entry rule, unchanged from before this fix), distinct
    // from the .clean entry elsewhere which prints a blank "   " pad for
    // alignment. A fix that replaces the per-entry `!= .not_in_repo`
    // guards in types.zig/display.zig with the per-section flag alone
    // (instead of ANDing the two) would make "out" print a spurious
    // indicator or blank prefix; this test pins the difference.
    var entries = [_]types.Entry{
        .{ .name = "mmm", .kind = .file, .git_status = .modified },
        .{ .name = "out", .kind = .file, .git_status = .not_in_repo },
    };

    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(
        testing.allocator,
        &entries,
        &buf.writer,
        .{ .show_git_status = true },
        style,
    );

    // "mmm" gets its "M  " indicator; "out" gets nothing at all -- no
    // indicator and no blank pad, because it is outside the repo, not
    // merely clean.
    try std.testing.expectEqualStrings("M  mmm\nout\n", buf.writer.buffered());
}

test "printEntries: not_in_repo entry stays width-unaffected inside a dirty section (-C)" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // Mirrors the two one-per-line not_in_repo tests above, but drives the
    // multi-column width arithmetic -- the column-width reduction and the
    // tab padding, both gated on options.show_git_status -- instead of just
    // the print path (display.printEntryName). The two are
    // separate `!= .not_in_repo` guards that a half-fix could desynchronize:
    // this test fails if either one stops excluding "out" from the +3 width
    // contribution while the section is dirty.
    //
    // Widths: "m" (modified) = 3 (indicator) + 1 = 4. "cc" (clean, section
    // is dirty so the column stays reserved) = 3 + 2 = 5. "out"
    // (not_in_repo) = 0 + 3 = 3, unaffected by the section decision.
    // max_width = 5, so col_width = (5+8)&~7 = 8; at terminal_width = 40,
    // num_cols = 40/8 = 5 and all three entries fit on a single row.
    var entries = [_]types.Entry{
        .{ .name = "m", .kind = .file, .git_status = .modified },
        .{ .name = "cc", .kind = .file, .git_status = .clean },
        .{ .name = "out", .kind = .file, .git_status = .not_in_repo },
    };

    const options = types.LsOptions{
        .terminal_width = 40,
        .show_git_status = true,
        .multi_column = true,
    };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);

    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    // "M  m" (width 4) pads to the col-8 boundary with one tab; "   cc"
    // (blank 3-space pad plus name, width 5) also pads with one tab; "out"
    // is the last cell and gets neither an indicator nor trailing padding.
    try std.testing.expectEqualStrings("M  m\t   cc\tout\n", buf.writer.buffered());
}

test "printEntries: per-call git column decision does not depend on other calls" {
    var buf_clean: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_clean.deinit();
    var buf_dirty: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_dirty.deinit();

    // Section A: stands in for a clean -R subdirectory.
    var clean_entries = [_]types.Entry{
        .{ .name = "a.txt", .kind = .file, .git_status = .clean },
        .{ .name = "b.txt", .kind = .file, .git_status = .clean },
    };
    // Section B: stands in for a dirty -R parent directory. Same options
    // (show_git_status = true) as section A -- only the entries differ --
    // so any difference in output proves the decision is made per call
    // (per directory section), not once globally.
    var dirty_entries = [_]types.Entry{
        .{ .name = "m.txt", .kind = .file, .git_status = .modified },
        .{ .name = "c.txt", .kind = .file, .git_status = .clean },
    };

    const style_clean = try display.initStyle(testing.allocator, &buf_clean.writer, .never);
    const style_dirty = try display.initStyle(testing.allocator, &buf_dirty.writer, .never);

    _ = try formatter.printEntries(
        testing.allocator,
        &clean_entries,
        &buf_clean.writer,
        .{ .show_git_status = true },
        style_clean,
    );
    _ = try formatter.printEntries(
        testing.allocator,
        &dirty_entries,
        &buf_dirty.writer,
        .{ .show_git_status = true },
        style_dirty,
    );

    // Section A (all clean) drops the column entirely...
    try std.testing.expectEqualStrings("a.txt\nb.txt\n", buf_clean.writer.buffered());
    // ...while Section B (one dirty entry) keeps it for every entry,
    // including the clean one.
    try std.testing.expectEqualStrings("M  m.txt\n   c.txt\n", buf_dirty.writer.buffered());
}

test "printEntries: sequential calls into the same writer do not leak the reserve decision" {
    // Unlike the isolated-buffer test above, both calls write into the
    // SAME writer, one right after the other -- the shape of a real -R
    // run walking dirty-then-clean or clean-then-dirty subdirectories in
    // sequence. This is the only unit test that could catch a fix that
    // caches "reserve the column" in something wider than the current
    // call's own entries (e.g. a module-level or writer-scoped flag):
    // such a leak would make the second call's decision match the
    // first's instead of its own entries.
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);

    var dirty_first = [_]types.Entry{
        .{ .name = "d1.txt", .kind = .file, .git_status = .modified },
    };
    var clean_second = [_]types.Entry{
        .{ .name = "c1.txt", .kind = .file, .git_status = .clean },
    };

    _ = try formatter.printEntries(
        testing.allocator,
        &dirty_first,
        &buf.writer,
        .{ .show_git_status = true },
        style,
    );
    _ = try formatter.printEntries(
        testing.allocator,
        &clean_second,
        &buf.writer,
        .{ .show_git_status = true },
        style,
    );

    // The dirty call reserves its column ("M  d1.txt"); the clean call
    // that follows, in the same writer, must NOT inherit that reservation
    // -- it drops the column entirely ("c1.txt", no leading pad).
    try std.testing.expectEqualStrings("M  d1.txt\nc1.txt\n", buf.writer.buffered());
}

test "printEntries: dirty section keeps the reserved column for every entry (-C, mixed statuses)" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    var entries = [_]types.Entry{
        .{ .name = "bbbbb", .kind = .file, .git_status = .modified },
        .{ .name = "ccccc", .kind = .file, .git_status = .clean },
        .{ .name = "ddddd", .kind = .file, .git_status = .untracked },
    };

    const options = types.LsOptions{
        .terminal_width = 40,
        .show_git_status = true,
        .multi_column = true,
    };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);

    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    // One dirty entry (bbbbb) is enough to reserve the column for the
    // whole section: ccccc (clean) still gets the blank 3-space prefix for
    // alignment instead of losing it, and ddddd (untracked) keeps its own
    // indicator. This pins the "preserve" half of the fix -- the decision
    // must never drop the prefix per-entry inside a dirty section, only
    // per-section.
    try std.testing.expectEqualStrings("M  bbbbb\t?? ddddd\n   ccccc\n", buf.writer.buffered());
}

test "printEntries: --git=never suppresses the column even in a dirty section" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // A section with real, non-clean statuses -- the exact case where a
    // buggy fix might compute "section has status" and ASSIGN it straight
    // into show_git_status instead of ANDing it with the caller's own
    // --git=never request. If that slip happens this test catches it:
    // show_git_status = false must mean no column, full stop, regardless
    // of what the entries' statuses are.
    var entries = [_]types.Entry{
        .{ .name = "m.txt", .kind = .file, .git_status = .modified },
        .{ .name = "u.txt", .kind = .file, .git_status = .untracked },
    };

    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(
        testing.allocator,
        &entries,
        &buf.writer,
        .{ .show_git_status = false },
        style,
    );

    // --git=never must win outright: no indicator, no reserved column,
    // even though both entries have a real (non-clean) git status.
    try std.testing.expectEqualStrings("m.txt\nu.txt\n", buf.writer.buffered());
}

test "printEntries: an untracked-only section still reserves the git column" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    var entries = [_]types.Entry{
        .{ .name = "file1", .kind = .file, .git_status = .untracked },
        .{ .name = "file2", .kind = .file, .git_status = .untracked },
    };

    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(
        testing.allocator,
        &entries,
        &buf.writer,
        .{ .show_git_status = true },
        style,
    );

    // An untracked file is a real status (neither clean nor not_in_repo),
    // so even a section with no *modified* files still reserves the
    // column.
    try std.testing.expectEqualStrings("?? file1\n?? file2\n", buf.writer.buffered());
}

// Fixed-width placeholder columns that printLongFormatEntryAligned emits
// for an Entry with `.stat = null` (the default): permissions, link count,
// owner, group, size, and date all fall back to their "unknown" literals
// (formatter.zig:450, 458, 564, 565, 590, 485). Concatenating them gives a
// fully deterministic prefix that precedes the name column, independent of
// the host's real uid/gid/mtime -- letting these -l tests pin an exact byte
// string instead of only a length/substring comparison.
//
// Per issue #124, nlink/owner/group/size must size to the widest value
// actually present in the section rather than to a hardcoded width. In a
// section where every entry has `.stat = null`, "?" is the only value ever
// rendered in each of those four columns, so each collapses to width 1: a
// single "? " apiece for owner/group/size. nlink additionally keeps a
// leading separator space (" ? "), matching writeNlinkColored's own
// leading-space contract (see its unit test in formatter.zig) -- this is
// NOT the same mechanism as writeDateColored, which only pads a TRAILING
// space and never a leading one; nlink is simply the one field whose
// helper owns both sides of its own field. The date fallback is untouched
// by this bug and keeps its own width.
const long_format_null_stat_prefix =
    "----------" ++ // permissions fallback
    " ? " ++ // link-count fallback, width 1
    "? " ++ // owner fallback, width 1
    "? " ++ // group fallback, width 1
    "? " ++ // size fallback, width 1
    "??? ?? ??:?? "; // date fallback

test "printEntries: long format (-l) all-clean git section drops the reserved column" {
    var buf_always: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_always.deinit();
    var buf_never: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf_never.deinit();

    var entries_always = [_]types.Entry{
        .{ .name = "clean1.txt", .kind = .file, .git_status = .clean },
        .{ .name = "clean2.txt", .kind = .file, .git_status = .clean },
    };
    var entries_never = [_]types.Entry{
        .{ .name = "clean1.txt", .kind = .file, .git_status = .clean },
        .{ .name = "clean2.txt", .kind = .file, .git_status = .clean },
    };

    const style_always = try display.initStyle(testing.allocator, &buf_always.writer, .never);
    const style_never = try display.initStyle(testing.allocator, &buf_never.writer, .never);

    _ = try formatter.printEntries(
        testing.allocator,
        &entries_always,
        &buf_always.writer,
        .{ .long_format = true, .show_git_status = true },
        style_always,
    );
    _ = try formatter.printEntries(
        testing.allocator,
        &entries_never,
        &buf_never.writer,
        .{ .long_format = true, .show_git_status = false },
        style_never,
    );

    // -l dispatches to printEntries_longFormat -> printLongFormatEntryAligned
    // -> display.printEntryName, a call site separate from -C/-1. A fix
    // scoped only to the columnar/one-per-line branches of printEntries
    // would leave this path forwarding the raw (unfixed) options and still
    // reserving the column here even though every entry is clean.
    const expected = "total 0\n" ++
        long_format_null_stat_prefix ++ "clean1.txt\n" ++
        long_format_null_stat_prefix ++ "clean2.txt\n";
    try std.testing.expectEqualStrings(expected, buf_never.writer.buffered());
    try std.testing.expectEqualStrings(buf_never.writer.buffered(), buf_always.writer.buffered());
}

test "printEntries: long format (-l) dirty git section keeps the reserved column for every entry" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    var entries = [_]types.Entry{
        .{ .name = "d.txt", .kind = .file, .git_status = .modified },
        .{ .name = "c.txt", .kind = .file, .git_status = .clean },
    };

    const style = try display.initStyle(testing.allocator, &buf.writer, .never);
    _ = try formatter.printEntries(
        testing.allocator,
        &entries,
        &buf.writer,
        .{ .long_format = true, .show_git_status = true },
        style,
    );

    // A single dirty entry (d.txt) reserves the column for the whole
    // section, so c.txt -- genuinely clean -- still gets the blank 3-space
    // pad instead of losing it. This is the -l counterpart of the -C
    // "dirty section keeps the reserved column" test above, closing the
    // one dispatch branch of printEntries that test left uncovered.
    const expected = "total 0\n" ++
        long_format_null_stat_prefix ++ "M  d.txt\n" ++
        long_format_null_stat_prefix ++ "   c.txt\n";
    try std.testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "printEntries: -x (columns_across) all-clean git section drops the reserved column" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    // Same 5-char-name fixture as the "-C ... (git prefix)" tests, but
    // -x (columns_across) instead of -C: printColumnarAcross shares the
    // column-width and tab-padding machinery with -C, yet reaches it
    // through its own dispatch branch in printEntries -- one a -C-only fix
    // could leave forwarding the raw options.
    var entries = [_]types.Entry{
        .{ .name = "bbbbb", .kind = .file, .git_status = .clean },
        .{ .name = "ccccc", .kind = .file, .git_status = .clean },
        .{ .name = "ddddd", .kind = .file, .git_status = .clean },
    };

    const options = types.LsOptions{
        .terminal_width = 40,
        .show_git_status = true,
        .columns_across = true,
    };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);

    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    // With no reserved column: max_width = 5, colwidth = (5+8)&~7 = 8 and
    // num_cols = 40/8 = 5, so all three names fit on one row and each gap
    // is one tab hop (5 -> 8, then 13 -> 16). Reserving the git column
    // would push max_width to 8 and colwidth to 16, changing the tab count.
    try std.testing.expectEqualStrings("bbbbb\tccccc\tddddd\n", buf.writer.buffered());
}

test "printEntries: -m (comma_format) all-clean git section drops the reserved column" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    var entries = [_]types.Entry{
        .{ .name = "clean1.txt", .kind = .file, .git_status = .clean },
        .{ .name = "clean2.txt", .kind = .file, .git_status = .clean },
    };

    const options = types.LsOptions{ .show_git_status = true, .comma_format = true };
    const style = try display.initStyle(testing.allocator, &buf.writer, .never);

    _ = try formatter.printEntries(testing.allocator, &entries, &buf.writer, options, style);

    // -m (comma_format) calls display.printEntryName directly inside
    // printEntries itself (formatter.zig:989-995), the one dispatch branch
    // that never delegates to a printColumnar* or printEntries_* helper --
    // a fix that only touches the helpers it calls out to would leave this
    // inline branch on the raw options and still reserve the column here.
    try std.testing.expectEqualStrings("clean1.txt, clean2.txt\n", buf.writer.buffered());
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

// Regression pin for -x's column geometry on the smallest fixture that
// still has two rows. -x and -C share printColumnar_writeTabs and the
// tab-stop rounding; only the traversal order differs, so an edit to the
// shared machinery while working on -C must not change either one's bytes.
test "columns_across: -x pads with tabs at the tab-stop column width, not spaces" {
    var env = try LsTestEnv.init(testing.allocator);
    defer env.deinit();

    const files = [_][]const u8{ "aaa", "bbb", "ccc", "ddd" };
    for (files) |name| {
        try env.createFile(name, "");
    }

    // max_width = 3, colwidth = (3+8)&~7 = 8, num_cols = 20/8 = 2, so the
    // four entries fill two rows across and each gap is a single tab hop
    // from column 3 to column 8. Verified against macOS /bin/ls -x at
    // COLUMNS=20; the old two-space pad put all four on one row instead.
    try env.runLs(.{ .columns_across = true, .terminal_width = 20 });

    try std.testing.expectEqualStrings("aaa\tbbb\nccc\tddd\n", env.getStdout());
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
    var tmp_dir = TestDir.init(testing.allocator);
    defer tmp_dir.deinit();

    const f = try tmp_dir.dir().createFile(testing.io, "real.txt", .{});
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
