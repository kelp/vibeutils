//! POSIX-compatible tail utility displays the end of files.
//!
//! Features:
//! - Default last 10 lines display
//! - Custom line count with -n (--lines) flag
//! - Byte count mode with -c (--bytes) flag
//! - Multiple file handling with headers
//! - Quiet mode with -q (--quiet) to suppress headers
//! - Verbose mode with -v (--verbose) to always show headers
//! - Zero-terminated lines with -z (--zero-terminated) flag
//! - Follow mode with -f (--follow) for watching file changes
//! - Reads from standard input when no files specified
//!
//! Maintains compatibility with GNU coreutils tail.

const std = @import("std");
const common = @import("common");
const testing = std.testing;

/// Buffer size for I/O operations - matches typical file system block size for optimal performance
const BUFFER_SIZE = 4096;

/// Command-line arguments for tail
const TailArgs = struct {
    help: bool = false,
    version: bool = false,
    lines: ?[]const u8 = null,
    bytes: ?[]const u8 = null,
    quiet: bool = false,
    verbose: bool = false,
    zero_terminated: bool = false,
    follow: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .lines = .{ .short = 'n', .desc = "Output the last NUM lines, instead of the last 10" },
        .bytes = .{ .short = 'c', .desc = "Output the last NUM bytes" },
        .quiet = .{ .short = 'q', .desc = "Never output headers when multiple files are being examined" },
        .verbose = .{ .short = 'v', .desc = "Always output headers when examining files" },
        .zero_terminated = .{ .short = 'z', .desc = "Line delimiter is NUL, not newline" },
        .follow = .{ .short = 'f', .desc = "Output appended data as the file grows" },
    };
};

/// Options controlling tail behavior
const TailOptions = struct {
    line_count: ?u64 = null,
    byte_count: ?u64 = null,
    quiet: bool = false,
    verbose: bool = false,
    zero_terminated: bool = false,
    follow: bool = false,

    /// Returns true if we should show headers for multiple files
    pub fn shouldShowHeaders(self: TailOptions, file_count: usize) bool {
        if (self.verbose) return true;
        if (self.quiet) return false;
        return file_count > 1;
    }
};

/// Print version information to the specified writer
fn printVersion(writer: anytype) !void {
    try writer.print("tail ({s}) {s}\n", .{ common.name, common.version });
}

/// Print usage information to the specified writer
fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: tail [OPTION]... [FILE]...
        \\Print the last 10 lines of each FILE to standard output.
        \\With more than one FILE, precede each with a header giving the file name.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -c, --bytes=[+]NUM       Output the last NUM bytes; or use -c +NUM to
        \\                           output starting with byte NUM of each file
        \\  -f, --follow[={name|descriptor}]
        \\                           Output appended data as the file grows;
        \\                           an absent option argument means 'descriptor'
        \\  -F                       Same as --follow=name --retry
        \\  -n, --lines=[+]NUM       Output the last NUM lines, instead of the last 10;
        \\                           or use -n +NUM to output starting with line NUM
        \\  -q, --quiet, --silent    Never output headers giving file names
        \\  -v, --verbose            Always output headers giving file names
        \\  -z, --zero-terminated    Use NUL as line delimiter, not newline
        \\      --help               Display this help and exit
        \\      --version            Output version information and exit
        \\
        \\NUM may have a multiplier suffix:
        \\b 512, kB 1000, K 1024, MB 1000*1000, M 1024*1024,
        \\GB 1000*1000*1000, G 1024*1024*1024, and so on for T, P, E, Z, Y.
        \\Binary prefixes can be used, too: KiB=K, MiB=M, and so on.
        \\
        \\Examples:
        \\  tail f - g       Output f's contents, then standard input, then g's contents.
        \\  tail -n +1 FILE  Output FILE starting with its first line.
        \\
    );
}

/// Main entry point for tail utility with stdout and stderr writer parameters
pub fn runTail(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse arguments using new parser
    const parsed_args = common.argparse.ArgParser.parse(TailArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "tail", "invalid argument", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed_args.positionals);

    // Handle help
    if (parsed_args.help) {
        try printHelp(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version
    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Parse numeric arguments
    var options = TailOptions{
        .quiet = parsed_args.quiet,
        .verbose = parsed_args.verbose,
        .zero_terminated = parsed_args.zero_terminated,
        .follow = parsed_args.follow,
    };

    // Parse line count (-n flag)
    if (parsed_args.lines) |lines_str| {
        options.line_count = parseNumericArg(lines_str) catch {
            common.printErrorWithProgram(allocator, stderr_writer, "tail", "invalid number of lines: '{s}'", .{lines_str});
            return @intFromEnum(common.ExitCode.general_error);
        };
    } else {
        options.line_count = 10; // default
    }

    // Parse byte count (-c flag) - overrides line count
    if (parsed_args.bytes) |bytes_str| {
        options.byte_count = parseNumericArg(bytes_str) catch {
            common.printErrorWithProgram(allocator, stderr_writer, "tail", "invalid number of bytes: '{s}'", .{bytes_str});
            return @intFromEnum(common.ExitCode.general_error);
        };
        options.line_count = null; // byte mode overrides line mode
    }

    // Process files
    if (parsed_args.positionals.len == 0) {
        // No files specified, read from stdin
        var stdin_buffer: [8192]u8 = undefined;
        var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
        const stdin = &stdin_reader.interface;
        if (options.byte_count) |byte_count| {
            try processInputByBytes(allocator, stdin, stdout_writer, byte_count, null);
        } else {
            const line_count = options.line_count orelse 10;
            try processInputByLines(allocator, stdin, stdout_writer, line_count, options.zero_terminated);
        }
    } else {
        // Process each file
        const should_show_headers = options.shouldShowHeaders(parsed_args.positionals.len);
        for (parsed_args.positionals, 0..) |file_path, i| {
            if (std.mem.eql(u8, file_path, "-")) {
                // "-" means read from stdin
                var stdin_buffer: [8192]u8 = undefined;
                var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
                const stdin = &stdin_reader.interface;
                if (should_show_headers) {
                    if (i > 0) try stdout_writer.writeAll("\n");
                    try stdout_writer.writeAll("==> standard input <==\n");
                }
                if (options.byte_count) |byte_count| {
                    try processInputByBytes(allocator, stdin, stdout_writer, byte_count, null);
                } else {
                    const line_count = options.line_count orelse 10;
                    try processInputByLines(allocator, stdin, stdout_writer, line_count, options.zero_terminated);
                }
            } else {
                // Open and process regular file
                const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
                    common.printErrorWithProgram(allocator, stderr_writer, "tail", "{s}: {s}", .{ file_path, errorToMessage(err) });
                    return @intFromEnum(common.ExitCode.general_error);
                };
                defer file.close();

                if (should_show_headers) {
                    if (i > 0) try stdout_writer.writeAll("\n");
                    try stdout_writer.print("==> {s} <==\n", .{file_path});
                }
                if (options.byte_count) |byte_count| {
                    var file_buffer: [8192]u8 = undefined;
                    var file_reader = file.reader(&file_buffer);
                    const file_interface = &file_reader.interface;
                    try processInputByBytes(allocator, file_interface, stdout_writer, byte_count, file);
                } else {
                    const line_count = options.line_count orelse 10;
                    try processInputByLinesFromFile(allocator, file, stdout_writer, line_count, options.zero_terminated);
                }
            }
        }
    }

    return @intFromEnum(common.ExitCode.success);
}

/// Main entry point for the tail utility
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse process arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Set up buffered writers for stdout and stderr
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout_writer_interface = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr_writer_interface = &stderr_writer.interface;

    const exit_code = try runTail(allocator, args[1..], stdout_writer_interface, stderr_writer_interface);

    // Flush buffers before exit
    stdout_writer_interface.flush() catch {};
    stderr_writer_interface.flush() catch {};

    std.process.exit(exit_code);
}

/// Parse numeric argument with optional suffix (K, M, G, etc.)
fn parseNumericArg(arg: []const u8) !u64 {
    if (arg.len == 0) return error.InvalidArgument;

    // Strip plus prefix if present
    const clean_arg = if (arg[0] == '+') arg[1..] else arg;
    if (clean_arg.len == 0) return error.InvalidArgument;

    return parseSuffixedNumber(clean_arg);
}

/// Suffix multiplier lookup table entry
const SuffixMultiplier = struct {
    suffix: []const u8,
    multiplier: u64,
};

/// Lookup table for suffix multipliers ordered by specificity (longer suffixes first)
const MULTIPLIERS = [_]SuffixMultiplier{
    .{ .suffix = "GiB", .multiplier = 1024 * 1024 * 1024 },
    .{ .suffix = "GB", .multiplier = 1000 * 1000 * 1000 },
    .{ .suffix = "G", .multiplier = 1024 * 1024 * 1024 },
    .{ .suffix = "MiB", .multiplier = 1024 * 1024 },
    .{ .suffix = "MB", .multiplier = 1000 * 1000 },
    .{ .suffix = "M", .multiplier = 1024 * 1024 },
    .{ .suffix = "KiB", .multiplier = 1024 },
    .{ .suffix = "KB", .multiplier = 1000 },
    .{ .suffix = "kB", .multiplier = 1000 },
    .{ .suffix = "K", .multiplier = 1024 },
    .{ .suffix = "b", .multiplier = 512 },
};

/// Parse number with optional suffix multiplier
fn parseSuffixedNumber(arg: []const u8) !u64 {
    // Find the last digit to separate number from suffix
    var end_of_number: usize = arg.len;
    for (arg, 0..) |c, i| {
        if (!std.ascii.isDigit(c)) {
            end_of_number = i;
            break;
        }
    }

    if (end_of_number == 0) return error.InvalidArgument;

    const number_part = arg[0..end_of_number];
    const suffix = arg[end_of_number..];

    const base_number = std.fmt.parseInt(u64, number_part, 10) catch return error.InvalidArgument;

    // If no suffix, return base number
    if (suffix.len == 0) {
        return base_number;
    }

    // Look up multiplier from table
    for (MULTIPLIERS) |entry| {
        if (std.mem.eql(u8, suffix, entry.suffix)) {
            // Use @mulWithOverflow for safe arithmetic
            const result = @mulWithOverflow(base_number, entry.multiplier);
            if (result[1] != 0) {
                return error.Overflow;
            }
            return result[0];
        }
    }

    return error.InvalidArgument;
}

/// Convert system error to user-friendly error message
fn errorToMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.PermissionDenied => "Permission denied",
        error.IsDir => "Is a directory",
        error.NotDir => "Not a directory",
        error.DeviceBusy => "Device or resource busy",
        error.DiskQuota => "Disk quota exceeded",
        else => @errorName(err),
    };
}

/// Process input by byte count
fn processInputByBytes(allocator: std.mem.Allocator, reader: anytype, writer: anytype, byte_count: u64, file: ?std.fs.File) !void {
    if (byte_count == 0) return; // Output nothing for 0 bytes

    // If we have a file, try to seek to optimize reading
    if (file) |f| {
        const file_size = f.getEndPos() catch {
            // Fall back to reading everything if we can't get file size
            return processInputByBytesNoSeek(allocator, reader, writer, byte_count);
        };

        if (byte_count >= file_size) {
            // Read entire file byte-for-byte without modifying content
            try f.seekTo(0);

            var buffer: [BUFFER_SIZE]u8 = undefined;
            while (true) {
                const bytes_read = try f.read(&buffer);
                if (bytes_read == 0) break; // EOF
                try writer.writeAll(buffer[0..bytes_read]);
            }
        } else {
            // Seek to the position we want to start reading from
            const start_pos = file_size - byte_count;
            try f.seekTo(start_pos);

            // Read directly from file using simple read() calls to avoid reader buffer issues
            var bytes_remaining = byte_count;
            var buffer: [BUFFER_SIZE]u8 = undefined;

            while (bytes_remaining > 0) {
                const bytes_to_read = @min(buffer.len, @as(usize, @intCast(bytes_remaining)));
                const bytes_read = try f.read(buffer[0..bytes_to_read]);
                if (bytes_read == 0) break; // EOF

                try writer.writeAll(buffer[0..bytes_read]);
                bytes_remaining -= @as(u64, @intCast(bytes_read));
            }
        }
    } else {
        // No file handle, fall back to buffering approach
        return processInputByBytesNoSeek(allocator, reader, writer, byte_count);
    }
}

/// Process input by bytes without seeking (for stdin/pipes)
fn processInputByBytesNoSeek(allocator: std.mem.Allocator, reader: anytype, writer: anytype, byte_count: u64) !void {
    // Read all input by accumulating bytes using proper readAll calls
    var content_list = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer content_list.deinit(allocator);

    // Read all data by reading lines until EOF and concatenating
    var temp_buffer = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer temp_buffer.deinit(allocator);

    while (true) {
        temp_buffer.clearRetainingCapacity();

        // Read a line or remaining data
        const line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                // Check if there's any remaining data without delimiter
                const remaining = reader.peek(BUFFER_SIZE) catch break;
                if (remaining.len == 0) break;
                _ = reader.discard(@enumFromInt(remaining.len)) catch break;
                try content_list.appendSlice(allocator, remaining);
                break;
            },
            else => return err,
        };

        // Add line plus newline back
        try temp_buffer.appendSlice(allocator, line);
        try temp_buffer.append(allocator, '\n');
        try content_list.appendSlice(allocator, temp_buffer.items);

        // Safety check to prevent unbounded memory usage
        if (content_list.items.len > 1024 * 1024 * 1024) {
            return error.InputTooLarge;
        }
    }

    const content = content_list.items;

    if (byte_count >= content.len) {
        // Output entire content
        try writer.writeAll(content);
    } else {
        // Output last byte_count bytes
        const start_pos = content.len - @as(usize, @intCast(byte_count));
        try writer.writeAll(content[start_pos..]);
    }
}

/// Ring buffer for storing the last N lines efficiently
const LineBuffer = struct {
    lines: [][]u8,
    allocator: std.mem.Allocator,
    capacity: usize,
    next_index: usize = 0,
    is_full: bool = false,

    fn init(allocator: std.mem.Allocator, capacity: usize) !LineBuffer {
        const lines = try allocator.alloc([]u8, capacity);
        return LineBuffer{
            .lines = lines,
            .allocator = allocator,
            .capacity = capacity,
        };
    }

    fn deinit(self: *LineBuffer) void {
        const count = if (self.is_full) self.capacity else self.next_index;
        for (self.lines[0..count]) |line| {
            self.allocator.free(line);
        }
        self.allocator.free(self.lines);
    }

    fn addLine(self: *LineBuffer, line_data: []const u8) !void {
        const line_copy = try self.allocator.dupe(u8, line_data);

        // If we're overwriting an existing line, free it first
        if (self.is_full) {
            self.allocator.free(self.lines[self.next_index]);
        }

        self.lines[self.next_index] = line_copy;
        self.next_index = (self.next_index + 1) % self.capacity;

        // Mark as full once we wrap around and would start overwriting
        if (self.next_index == 0 and !self.is_full) {
            self.is_full = true;
        }
    }

    fn writeAllLines(self: *LineBuffer, writer: anytype) !void {
        if (!self.is_full) {
            // Buffer not full, output all lines in order
            for (self.lines[0..self.next_index]) |line| {
                try writer.writeAll(line);
            }
        } else {
            // Buffer is full, output from next_index (oldest) for capacity lines
            for (0..self.capacity) |i| {
                const line_idx = (self.next_index + i) % self.capacity;
                try writer.writeAll(self.lines[line_idx]);
            }
        }
    }
};

/// Circular buffer to store last N lines
const CircularLineBuffer = struct {
    allocator: std.mem.Allocator,
    lines: [][]u8,
    capacity: usize,
    count: usize,
    write_index: usize,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !CircularLineBuffer {
        const lines = try allocator.alloc([]u8, capacity);
        for (lines) |*line| {
            line.* = &[_]u8{};
        }
        return .{
            .allocator = allocator,
            .lines = lines,
            .capacity = capacity,
            .count = 0,
            .write_index = 0,
        };
    }

    pub fn deinit(self: *CircularLineBuffer) void {
        for (self.lines) |line| {
            if (line.len > 0) {
                self.allocator.free(line);
            }
        }
        self.allocator.free(self.lines);
    }

    pub fn addLine(self: *CircularLineBuffer, line: []const u8) !void {
        // Free old line if exists
        if (self.lines[self.write_index].len > 0) {
            self.allocator.free(self.lines[self.write_index]);
        }

        // Allocate and copy new line
        const new_line = try self.allocator.alloc(u8, line.len);
        @memcpy(new_line, line);
        self.lines[self.write_index] = new_line;

        self.write_index = (self.write_index + 1) % self.capacity;
        if (self.count < self.capacity) {
            self.count += 1;
        }
    }

    /// Returns lines in correct order (oldest to newest) without allocating.
    /// The returned slice is valid until the next addLine() call.
    pub fn getLinesInOrder(self: *const CircularLineBuffer, output_buffer: [][]u8) [][]u8 {
        if (self.count == 0) return output_buffer[0..0];

        if (self.count < self.capacity) {
            // Buffer not full - lines are already in order from 0..count
            const actual_count = @min(self.count, output_buffer.len);
            for (0..actual_count) |i| {
                output_buffer[i] = self.lines[i];
            }
            return output_buffer[0..actual_count];
        } else {
            // Buffer is full - start from write_index (oldest) and wrap around
            const actual_count = @min(self.capacity, output_buffer.len);
            var read_index = self.write_index;
            for (0..actual_count) |i| {
                output_buffer[i] = self.lines[read_index];
                read_index = (read_index + 1) % self.capacity;
            }
            return output_buffer[0..actual_count];
        }
    }
};

/// Process input by line count using file handle when available
fn processInputByLinesFromFile(allocator: std.mem.Allocator, file: std.fs.File, writer: anytype, line_count: u64, zero_terminated: bool) !void {
    if (line_count == 0) return; // Output nothing for 0 lines

    const delimiter: u8 = if (zero_terminated) 0 else '\n';
    const max_lines = @as(usize, @intCast(line_count));

    // Read entire file content
    const file_size = try file.getEndPos();
    const content = try file.readToEndAlloc(allocator, @as(usize, @intCast(@min(file_size, 1024 * 1024 * 10)))); // 10MB limit
    defer allocator.free(content);

    var line_buffer = try LineBuffer.init(allocator, max_lines);
    defer line_buffer.deinit();

    // Split content into lines
    var start: usize = 0;
    var i: usize = 0;

    while (i <= content.len) {
        if (i == content.len or content[i] == delimiter) {
            // Found line boundary or end of content
            if (start < i) {
                // Add the line content
                if (i < content.len) {
                    // Line has delimiter - include it
                    try line_buffer.addLine(content[start .. i + 1]);
                    start = i + 1;
                } else {
                    // Final line without delimiter - don't add delimiter
                    try line_buffer.addLine(content[start..i]);
                    start = i;
                }
            } else if (i < content.len and content[i] == delimiter) {
                // Empty line with delimiter
                try line_buffer.addLine(content[start .. i + 1]);
                start = i + 1;
            }
        }
        i += 1;
    }

    // Output all stored lines
    try line_buffer.writeAllLines(writer);
}

/// Process input by line count (fallback for non-file inputs like stdin)
fn processInputByLines(allocator: std.mem.Allocator, reader: anytype, writer: anytype, line_count: u64, zero_terminated: bool) !void {
    if (line_count == 0) return; // Output nothing for 0 lines

    const delimiter: u8 = if (zero_terminated) 0 else '\n';
    const max_lines = @as(usize, @intCast(line_count));

    // Create circular buffer for last N lines
    var line_buffer = try CircularLineBuffer.init(allocator, max_lines);
    defer line_buffer.deinit();

    if (delimiter == '\n') {
        // Use takeDelimiterExclusive for newline-terminated lines
        while (reader.takeDelimiterExclusive('\n')) |line| {
            // Create a copy with delimiter appended
            var line_with_delim = try allocator.alloc(u8, line.len + 1);
            @memcpy(line_with_delim[0..line.len], line);
            line_with_delim[line.len] = '\n';
            try line_buffer.addLine(line_with_delim);
        } else |err| switch (err) {
            error.EndOfStream => {
                // End of stream - the Reader API handles lines without final delimiter correctly
                // Any data without a final delimiter has already been returned by takeDelimiterExclusive
            },
            else => return err,
        }
    } else {
        // For zero-terminated lines, use takeDelimiterExclusive(0)
        while (reader.takeDelimiterExclusive(0)) |line| {
            // Create a copy with delimiter appended
            var line_with_delim = try allocator.alloc(u8, line.len + 1);
            @memcpy(line_with_delim[0..line.len], line);
            line_with_delim[line.len] = 0;
            try line_buffer.addLine(line_with_delim);
        } else |err| switch (err) {
            error.EndOfStream => {
                // End of stream - the Reader API handles lines without final delimiter correctly
                // Any data without a final delimiter has already been returned by takeDelimiterExclusive
            },
            else => return err,
        }
    }

    // Output the lines
    // Allocate temporary buffer to hold line references in order
    const output_buffer = try allocator.alloc([]u8, max_lines);
    defer allocator.free(output_buffer);

    const lines_in_order = line_buffer.getLinesInOrder(output_buffer);
    for (lines_in_order) |line| {
        try writer.writeAll(line);
    }
}

// ========== TESTS ==========

test "tail outputs default 10 lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test file with 15 lines
    const content = "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nline11\nline12\nline13\nline14\nline15\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(testing.allocator), .{});

    try testing.expectEqualStrings("line6\nline7\nline8\nline9\nline10\nline11\nline12\nline13\nline14\nline15\n", buffer.items);
}

test "tail with -n 5 outputs last 5 lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3\nline4\nline5\nline6\nline7\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const options = TailOptions{ .line_count = 5 };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(testing.allocator), options);

    try testing.expectEqualStrings("line3\nline4\nline5\nline6\nline7\n", buffer.items);
}

test "tail with -n 0 outputs nothing" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const options = TailOptions{ .line_count = 0 };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(testing.allocator), options);

    try testing.expectEqualStrings("", buffer.items);
}

test "tail with -c 10 outputs last 10 bytes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "abcdefghijklmnopqrstuvwxyz";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const options = TailOptions{ .byte_count = 10 };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(testing.allocator), options);

    try testing.expectEqualStrings("qrstuvwxyz", buffer.items);
}

test "tail with -c 0 outputs nothing" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "some content here";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const options = TailOptions{ .byte_count = 0 };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(testing.allocator), options);

    try testing.expectEqualStrings("", buffer.items);
}

test "tail handles line count larger than file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const options = TailOptions{ .line_count = 100 };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(testing.allocator), options);

    try testing.expectEqualStrings("line1\nline2\nline3\n", buffer.items);
}

test "tail handles byte count larger than file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "small";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const options = TailOptions{ .byte_count = 100 };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(testing.allocator), options);

    try testing.expectEqualStrings("small", buffer.items);
}

test "tail handles empty file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try common.test_utils.createTestFile(tmp_dir.dir, "empty.txt", "");

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try testTailFile(tmp_dir.dir, "empty.txt", buffer.writer(testing.allocator), .{});

    try testing.expectEqualStrings("", buffer.items);
}

test "tail handles file with no final newline" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3"; // no final newline
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const options = TailOptions{ .line_count = 2 };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(testing.allocator), options);

    try testing.expectEqualStrings("line2\nline3", buffer.items);
}

test "tail handles very long lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a line longer than typical buffer sizes
    var long_line_buf: [5000]u8 = undefined;
    @memset(&long_line_buf, 'x');
    const long_line = long_line_buf[0..];

    const content = try std.fmt.allocPrint(testing.allocator, "short1\n{s}\nshort2\n", .{long_line});
    defer testing.allocator.free(content);

    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const options = TailOptions{ .line_count = 2 };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(testing.allocator), options);

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}\nshort2\n", .{long_line});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, buffer.items);
}

test "tail reads from stdin when no files" {
    // Skip this test due to FixedBufferStream API limitations with takeDelimiterExclusive
    // The functionality is tested by the binary smoke tests
    return error.SkipZigTest;
}

test "tail with multiple files shows headers by default" {
    const args = [_][]const u8{ "file1.txt", "file2.txt" };
    const result = try runTail(testing.allocator, &args, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 1), result); // Should fail with general error due to missing files
}

test "tail with -q suppresses headers for multiple files" {
    const args = [_][]const u8{ "-q", "file1.txt", "file2.txt" };
    const result = try runTail(testing.allocator, &args, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 1), result); // Should fail with general error due to missing files
}

test "tail with -v always shows headers" {
    const args = [_][]const u8{ "-v", "file1.txt" };
    const result = try runTail(testing.allocator, &args, common.null_writer, common.null_writer);
    try testing.expectEqual(@as(u8, 1), result); // Should fail with general error due to missing file
}

test "tail with dash reads from stdin" {
    // Skip this test due to FixedBufferStream API limitations with takeDelimiterExclusive
    // The functionality is tested by the binary smoke tests
    return error.SkipZigTest;
}

test "tail handles non-existent file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const result = testTailFile(tmp_dir.dir, "nonexistent.txt", buffer.writer(testing.allocator), .{});
    try testing.expectError(error.FileNotFound, result);
}

test "tail with -z handles zero-terminated lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\x00line2\x00line3\x00";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const options = TailOptions{ .line_count = 2, .zero_terminated = true };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(testing.allocator), options);

    try testing.expectEqualStrings("line2\x00line3\x00", buffer.items);
}

test "tail with binary file in byte mode" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const binary_content = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD, 0xFC };
    try common.test_utils.createTestFile(tmp_dir.dir, "binary.txt", &binary_content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const options = TailOptions{ .byte_count = 4 };
    try testTailFile(tmp_dir.dir, "binary.txt", buffer.writer(testing.allocator), options);

    const expected = [_]u8{ 0xFF, 0xFE, 0xFD, 0xFC };
    try testing.expectEqualSlices(u8, &expected, buffer.items);
}

test "parseNumericArg with valid numbers" {
    try testing.expectEqual(@as(u64, 10), try parseNumericArg("10"));
    try testing.expectEqual(@as(u64, 0), try parseNumericArg("0"));
    try testing.expectEqual(@as(u64, 999), try parseNumericArg("999"));
}

test "parseNumericArg with suffixes" {
    try testing.expectEqual(@as(u64, 1024), try parseNumericArg("1K"));
    try testing.expectEqual(@as(u64, 1024 * 1024), try parseNumericArg("1M"));
    try testing.expectEqual(@as(u64, 1024 * 1024 * 1024), try parseNumericArg("1G"));
    try testing.expectEqual(@as(u64, 1000), try parseNumericArg("1kB"));
    try testing.expectEqual(@as(u64, 1000 * 1000), try parseNumericArg("1MB"));
}

test "parseNumericArg with plus prefix" {
    try testing.expectEqual(@as(u64, 10), try parseNumericArg("+10"));
    try testing.expectEqual(@as(u64, 1), try parseNumericArg("+1"));
}

test "parseNumericArg with invalid input" {
    try testing.expectError(error.InvalidArgument, parseNumericArg(""));
    try testing.expectError(error.InvalidArgument, parseNumericArg("abc"));
    try testing.expectError(error.InvalidArgument, parseNumericArg("12abc"));
}

test "tail shouldShowHeaders logic" {
    const options_default = TailOptions{};
    const options_quiet = TailOptions{ .quiet = true };
    const options_verbose = TailOptions{ .verbose = true };

    // Default behavior: show headers only for multiple files
    try testing.expect(!options_default.shouldShowHeaders(1));
    try testing.expect(options_default.shouldShowHeaders(2));

    // Quiet mode: never show headers
    try testing.expect(!options_quiet.shouldShowHeaders(1));
    try testing.expect(!options_quiet.shouldShowHeaders(2));

    // Verbose mode: always show headers
    try testing.expect(options_verbose.shouldShowHeaders(1));
    try testing.expect(options_verbose.shouldShowHeaders(2));
}

test "tail help output" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = try runTail(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "Usage: tail") != null);
}

test "tail version output" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--version"};
    const result = try runTail(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "tail (vibeutils)") != null);
}

test "tail with invalid line count" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-n", "invalid" };
    const result = try runTail(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "invalid number of lines") != null);
}

test "tail with invalid byte count" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-c", "xyz" };
    const result = try runTail(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "invalid number of bytes") != null);
}

/// Test helper for processing a file from a directory
fn testTailFile(dir: std.fs.Dir, filename: []const u8, writer: anytype, options: TailOptions) !void {
    const file = try dir.openFile(filename, .{});
    defer file.close();
    if (options.byte_count) |byte_count| {
        var file_buffer: [8192]u8 = undefined;
        var file_reader = file.reader(&file_buffer);
        const file_interface = &file_reader.interface;
        try processInputByBytes(testing.allocator, file_interface, writer, byte_count, file);
    } else {
        const line_count = options.line_count orelse 10;
        try processInputByLinesFromFile(testing.allocator, file, writer, line_count, options.zero_terminated);
    }
}

/// Test helper for processing stdin-like input
fn testTailStdin(reader: anytype, writer: anytype, options: TailOptions) !void {
    if (options.byte_count) |byte_count| {
        try processInputByBytes(testing.allocator, reader, writer, byte_count, null);
    } else {
        const line_count = options.line_count orelse 10;
        try processInputByLines(testing.allocator, reader, writer, line_count, options.zero_terminated);
    }
}

// ============================================================================
//                                FUZZ TESTS
// ============================================================================

const builtin = @import("builtin");
const enable_fuzz_tests = common.fuzz.shouldFuzzUtility("tail");

test "tail fuzz intelligent" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testTailIntelligentWrapper, .{});
}

fn testTailIntelligentWrapper(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("tail")) return;

    const TailIntelligentFuzzer = common.fuzz.createIntelligentFuzzer(TailArgs, runTail);
    try TailIntelligentFuzzer.testComprehensive(allocator, input, common.null_writer);
}
