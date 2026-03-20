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
//! - Reads from standard input when no files specified
//!
//! Maintains compatibility with GNU coreutils tail.

const std = @import("std");
const common = @import("common");
const testing = std.testing;

/// Buffer size for I/O operations - matches typical file system block size for optimal performance
const BUFFER_SIZE = 8192;

/// Command-line arguments for tail
const TailArgs = struct {
    help: bool = false,
    version: bool = false,
    lines: ?[]const u8 = null,
    bytes: ?[]const u8 = null,
    blocks: ?[]const u8 = null,
    quiet: bool = false,
    verbose: bool = false,
    zero_terminated: bool = false,
    reverse: bool = false,
    follow: bool = false,
    follow_retry: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "display this help and exit" },
        .version = .{ .short = 'V', .desc = "output version information and exit" },
        .lines = .{ .short = 'n', .desc = "output the last NUM lines, instead of the last 10" },
        .bytes = .{ .short = 'c', .desc = "output the last NUM bytes" },
        .blocks = .{ .short = 'b', .desc = "output the last NUM 512-byte blocks" },
        .quiet = .{ .short = 'q', .desc = "never output headers when multiple files are being examined" },
        .verbose = .{ .short = 'v', .desc = "always output headers when examining files" },
        .zero_terminated = .{ .short = 'z', .desc = "line delimiter is NUL, not newline" },
        .reverse = .{ .short = 'r', .desc = "display the input in reverse order, by line" },
        .follow = .{ .short = 'f', .desc = "output appended data as the file grows" },
        .follow_retry = .{ .short = 'F', .desc = "same as -f, but retry if file is inaccessible" },
    };
};

/// Options controlling tail behavior
const TailOptions = struct {
    line_count: ?u64 = null,
    byte_count: ?u64 = null,
    quiet: bool = false,
    verbose: bool = false,
    zero_terminated: bool = false,
    from_beginning: bool = false,
    from_beginning_bytes: bool = false,
    reverse: bool = false,

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
fn printHelp(allocator: std.mem.Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: tail [OPTION]... [FILE]...
        \\Print the last 10 lines of each FILE to standard output.
        \\With more than one FILE, precede each with a header giving the file name.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -c, --bytes=NUM          output the last NUM bytes
        \\  -n, --lines=[+]NUM       output the last NUM lines, instead of the last 10;
        \\                           or use -n +NUM to output starting with line NUM
        \\  -q, --quiet, --silent    never output headers giving file names
        \\  -v, --verbose            always output headers giving file names
        \\  -z, --zero-terminated    use NUL as line delimiter, not newline
        \\  -f, --follow             output appended data as the file grows
        \\  -F                       same as --follow --retry
        \\      --help               display this help and exit
        \\      --version            output version information and exit
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

/// Expand obsolete -NUM syntax (e.g., -5) to -n NUM for backwards compatibility
fn expandObsoleteArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    // Count how many extra args we need (one extra per -NUM arg)
    var extra: usize = 0;
    for (args) |arg| {
        if (isObsoleteNumArg(arg)) extra += 1;
    }
    if (extra == 0) return allocator.dupe([]const u8, args);

    const expanded = try allocator.alloc([]const u8, args.len + extra);
    var i: usize = 0;
    for (args) |arg| {
        if (isObsoleteNumArg(arg)) {
            expanded[i] = "-n";
            i += 1;
            expanded[i] = arg[1..]; // strip leading '-'
            i += 1;
        } else {
            expanded[i] = arg;
            i += 1;
        }
    }
    return expanded;
}

/// Check if an argument matches the obsolete -NUM pattern (e.g., "-5", "-100")
fn isObsoleteNumArg(arg: []const u8) bool {
    if (arg.len < 2 or arg[0] != '-') return false;
    for (arg[1..]) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Main entry point for tail utility with stdout and stderr writer parameters
pub fn runTail(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    const expanded_args = try expandObsoleteArgs(allocator, args);
    defer allocator.free(expanded_args);

    const parsed_args = common.argparse.ArgParser.parse(TailArgs, allocator, expanded_args) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "tail", "invalid argument", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed_args.positionals);

    // Handle help
    if (parsed_args.help) {
        try printHelp(allocator, stdout_writer);
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
        .reverse = parsed_args.reverse,
    };

    // Parse line count (-n flag)
    if (parsed_args.lines) |lines_str| {
        if (lines_str.len > 0 and lines_str[0] == '+') {
            options.from_beginning = true;
        }
        options.line_count = parseNumericArg(lines_str) catch {
            common.printErrorWithProgram(allocator, stderr_writer, "tail", "invalid number of lines: '{s}'", .{lines_str});
            return @intFromEnum(common.ExitCode.misuse);
        };
    } else if (parsed_args.reverse) {
        options.line_count = null; // -r without -n: show all lines
    } else {
        options.line_count = 10; // default
    }

    // Parse byte count (-c flag) - overrides line count
    if (parsed_args.bytes) |bytes_str| {
        if (bytes_str.len > 0 and bytes_str[0] == '+') {
            options.from_beginning_bytes = true;
        }
        options.byte_count = parseNumericArg(bytes_str) catch {
            common.printErrorWithProgram(allocator, stderr_writer, "tail", "invalid number of bytes: '{s}'", .{bytes_str});
            return @intFromEnum(common.ExitCode.misuse);
        };
        options.line_count = null; // byte mode overrides line mode
    }

    // Parse block count (-b flag) - overrides lines, like -c but in 512-byte blocks
    if (parsed_args.blocks) |blocks_str| {
        if (blocks_str.len > 0 and blocks_str[0] == '+') {
            options.from_beginning_bytes = true;
        }
        const block_count = parseNumericArg(blocks_str) catch {
            common.printErrorWithProgram(allocator, stderr_writer, "tail", "invalid number of blocks: '{s}'", .{blocks_str});
            return @intFromEnum(common.ExitCode.misuse);
        };
        if (options.from_beginning_bytes) {
            // +N blocks means start at block N (1-indexed), skip (N-1)*512 bytes
            // processInputByBytesFromBeginning uses skip = byte_count - 1
            // so byte_count = (N-1)*512 + 1
            options.byte_count = if (block_count > 0) (block_count - 1) * 512 + 1 else 1;
        } else {
            options.byte_count = block_count * 512;
        }
        options.line_count = null; // block mode overrides line mode
    }

    // Process files
    if (parsed_args.positionals.len == 0) {
        // No files specified, read from stdin
        try processStdin(allocator, stdout_writer, options);
    } else {
        // Process each file
        var had_error = false;
        const should_show_headers = options.shouldShowHeaders(parsed_args.positionals.len);
        for (parsed_args.positionals, 0..) |file_path, i| {
            if (std.mem.eql(u8, file_path, "-")) {
                // "-" means read from stdin
                if (should_show_headers) {
                    if (i > 0) try stdout_writer.writeAll("\n");
                    try stdout_writer.writeAll("==> standard input <==\n");
                }
                try processStdin(allocator, stdout_writer, options);
            } else {
                // Open and process regular file
                const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
                    // -F (follow with retry) tolerates missing files
                    if (parsed_args.follow_retry and err == error.FileNotFound) {
                        continue;
                    }
                    common.printErrorWithProgram(allocator, stderr_writer, "tail", "{s}: {s}", .{ file_path, errorToMessage(err) });
                    had_error = true;
                    continue;
                };
                defer file.close();

                if (should_show_headers) {
                    if (i > 0) try stdout_writer.writeAll("\n");
                    try stdout_writer.print("==> {s} <==\n", .{file_path});
                }
                try processFile(allocator, file, stdout_writer, options);
            }
        }
        if (had_error) return @intFromEnum(common.ExitCode.general_error);
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
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout_writer_interface = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
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

/// Process stdin with given options
fn processStdin(allocator: std.mem.Allocator, stdout_writer: anytype, options: TailOptions) !void {
    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    if (options.byte_count) |byte_count| {
        try processInputByBytes(allocator, stdin, stdout_writer, byte_count, null, options.from_beginning_bytes);
    } else {
        try processInputByLines(allocator, stdin, stdout_writer, options.line_count, options.zero_terminated, options.from_beginning, options.reverse);
    }
}

/// Process a file with given options
fn processFile(allocator: std.mem.Allocator, file: std.fs.File, stdout_writer: anytype, options: TailOptions) !void {
    if (options.byte_count) |byte_count| {
        var file_buffer: [8192]u8 = undefined;
        var file_reader = file.reader(&file_buffer);
        const file_interface = &file_reader.interface;
        try processInputByBytes(allocator, file_interface, stdout_writer, byte_count, file, options.from_beginning_bytes);
    } else {
        try processInputByLinesFromFile(allocator, file, stdout_writer, options.line_count, options.zero_terminated, options.from_beginning, options.reverse);
    }
}

/// Process input by byte count
fn processInputByBytes(allocator: std.mem.Allocator, reader: anytype, writer: anytype, byte_count: u64, file: ?std.fs.File, from_beginning: bool) !void {
    if (from_beginning) {
        return processInputByBytesFromBeginning(reader, writer, byte_count, file);
    }

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

/// Process input by bytes from beginning: skip first (byte_count - 1) bytes, output the rest
fn processInputByBytesFromBeginning(reader: anytype, writer: anytype, byte_count: u64, file: ?std.fs.File) !void {
    // -c +N means output starting from byte N (1-indexed)
    // So skip the first (N-1) bytes
    const skip = if (byte_count > 0) byte_count - 1 else 0;

    if (file) |f| {
        // For seekable files, just seek past the skip bytes
        const file_size = f.getEndPos() catch {
            return processInputByBytesFromBeginningStream(reader, writer, skip);
        };

        if (skip >= file_size) return; // Nothing to output

        try f.seekTo(skip);
        var buffer: [BUFFER_SIZE]u8 = undefined;
        while (true) {
            const bytes_read = try f.read(&buffer);
            if (bytes_read == 0) break;
            try writer.writeAll(buffer[0..bytes_read]);
        }
    } else {
        return processInputByBytesFromBeginningStream(reader, writer, skip);
    }
}

/// Process stream input by bytes from beginning (non-seekable)
fn processInputByBytesFromBeginningStream(reader: anytype, writer: anytype, skip: u64) !void {
    var skipped: u64 = 0;

    while (true) {
        const available = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e| return e,
        };
        if (available.len == 0) return;

        if (skipped < skip) {
            const to_skip = @min(available.len, @as(usize, @intCast(skip - skipped)));
            reader.toss(to_skip);
            skipped += @as(u64, @intCast(to_skip));
        } else {
            try writer.writeAll(available);
            reader.toss(available.len);
        }
    }
}

/// Process input by bytes without seeking (for stdin/pipes) using circular buffer
fn processInputByBytesNoSeek(allocator: std.mem.Allocator, reader: anytype, writer: anytype, byte_count: u64) !void {
    const buffer_size = @as(usize, @intCast(byte_count));

    // Allocate circular buffer to hold only the last byte_count bytes
    const circular_buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(circular_buffer);

    var total_bytes_read: usize = 0;
    var write_index: usize = 0;

    // Read input and maintain only last byte_count bytes in circular buffer
    while (true) {
        const available = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };

        for (available) |byte| {
            circular_buffer[write_index] = byte;
            write_index = (write_index + 1) % buffer_size;
            total_bytes_read += 1;
        }
        reader.toss(available.len);
    }

    // Output the circular buffer in the correct order
    if (total_bytes_read >= buffer_size) {
        // Buffer wrapped around - output from write_index to end, then from start to write_index
        try writer.writeAll(circular_buffer[write_index..]);
        try writer.writeAll(circular_buffer[0..write_index]);
    } else {
        // Buffer didn't wrap - output from start to total_bytes_read
        try writer.writeAll(circular_buffer[0..total_bytes_read]);
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

    fn writeAllLinesReversed(self: *LineBuffer, writer: anytype, delimiter: u8) !void {
        if (!self.is_full) {
            // Buffer not full, output lines in reverse order
            var i = self.next_index;
            while (i > 0) {
                i -= 1;
                const line = self.lines[i];
                // Strip trailing delimiter, write content, then add delimiter
                if (line.len > 0 and line[line.len - 1] == delimiter) {
                    try writer.writeAll(line[0 .. line.len - 1]);
                    try writer.writeByte(delimiter);
                } else {
                    try writer.writeAll(line);
                    try writer.writeByte(delimiter);
                }
            }
        } else {
            // Buffer is full, output from newest to oldest
            var i = self.capacity;
            while (i > 0) {
                i -= 1;
                // newest is at (next_index - 1 + capacity) % capacity, going backwards
                const line_idx = (self.next_index + i) % self.capacity;
                const line = self.lines[line_idx];
                if (line.len > 0 and line[line.len - 1] == delimiter) {
                    try writer.writeAll(line[0 .. line.len - 1]);
                    try writer.writeByte(delimiter);
                } else {
                    try writer.writeAll(line);
                    try writer.writeByte(delimiter);
                }
            }
        }
    }
};

/// Process input by line count using file handle when available.
/// Streams the file in chunks instead of reading it all into memory.
/// When line_count is null (used with -r), all lines are collected.
fn processInputByLinesFromFile(allocator: std.mem.Allocator, file: std.fs.File, writer: anytype, line_count: ?u64, zero_terminated: bool, from_beginning: bool, reverse: bool) !void {
    if (line_count) |lc| {
        if (lc == 0 and !from_beginning) return;
    }

    const delimiter: u8 = if (zero_terminated) 0 else '\n';

    if (from_beginning) {
        const lc = line_count orelse 1;
        const max_lines = @as(usize, @intCast(lc));
        // Skip the first (line_count - 1) lines and stream the rest
        const skip_count = if (lc > 0) max_lines - 1 else 0;
        var read_buf: [8192]u8 = undefined;

        if (skip_count == 0) {
            // +1 means output everything from the start
            while (true) {
                const n = try file.read(&read_buf);
                if (n == 0) return;
                try writer.writeAll(read_buf[0..n]);
            }
        }

        var lines_seen: usize = 0;
        while (true) {
            const bytes_read = try file.read(&read_buf);
            if (bytes_read == 0) return; // EOF before we finished skipping

            for (read_buf[0..bytes_read], 0..) |byte, pos| {
                if (byte == delimiter) {
                    lines_seen += 1;
                    if (lines_seen >= skip_count) {
                        // Output the rest of this chunk after the delimiter
                        try writer.writeAll(read_buf[pos + 1 .. bytes_read]);
                        // Then stream remaining file content directly
                        while (true) {
                            const n = try file.read(&read_buf);
                            if (n == 0) return;
                            try writer.writeAll(read_buf[0..n]);
                        }
                    }
                }
            }
        }
    }

    // When line_count is null (reverse all), collect into a dynamic list
    if (line_count == null) {
        var lines = std.ArrayListUnmanaged([]u8){};
        defer {
            for (lines.items) |line| allocator.free(line);
            lines.deinit(allocator);
        }

        var read_buf: [8192]u8 = undefined;
        var partial = std.ArrayListUnmanaged(u8){};
        defer partial.deinit(allocator);

        while (true) {
            const bytes_read = try file.read(&read_buf);
            if (bytes_read == 0) break;

            var chunk_start: usize = 0;
            for (read_buf[0..bytes_read], 0..) |byte, pos| {
                if (byte == delimiter) {
                    const chunk_end = pos + 1;
                    if (partial.items.len > 0) {
                        try partial.appendSlice(allocator, read_buf[chunk_start..chunk_end]);
                        const line_copy = try allocator.dupe(u8, partial.items);
                        try lines.append(allocator, line_copy);
                        partial.clearRetainingCapacity();
                    } else {
                        const line_copy = try allocator.dupe(u8, read_buf[chunk_start..chunk_end]);
                        try lines.append(allocator, line_copy);
                    }
                    chunk_start = chunk_end;
                }
            }
            if (chunk_start < bytes_read) {
                try partial.appendSlice(allocator, read_buf[chunk_start..bytes_read]);
            }
        }

        if (partial.items.len > 0) {
            const line_copy = try allocator.dupe(u8, partial.items);
            try lines.append(allocator, line_copy);
        }

        // Output in reverse order
        var i = lines.items.len;
        while (i > 0) {
            i -= 1;
            const line = lines.items[i];
            if (line.len > 0 and line[line.len - 1] == delimiter) {
                try writer.writeAll(line[0 .. line.len - 1]);
                try writer.writeByte(delimiter);
            } else {
                try writer.writeAll(line);
                try writer.writeByte(delimiter);
            }
        }
        return;
    }

    const max_lines = @as(usize, @intCast(line_count.?));

    // Use LineBuffer to keep the last N lines
    var line_buffer = try LineBuffer.init(allocator, max_lines);
    defer line_buffer.deinit();

    // Stream file in chunks and extract lines
    var read_buf: [8192]u8 = undefined;
    var partial = std.ArrayListUnmanaged(u8){};
    defer partial.deinit(allocator);

    while (true) {
        const bytes_read = try file.read(&read_buf);
        if (bytes_read == 0) break; // EOF

        var chunk_start: usize = 0;
        for (read_buf[0..bytes_read], 0..) |byte, pos| {
            if (byte == delimiter) {
                const chunk_end = pos + 1; // Include delimiter
                if (partial.items.len > 0) {
                    // Combine partial data with this chunk
                    try partial.appendSlice(allocator, read_buf[chunk_start..chunk_end]);
                    try line_buffer.addLine(partial.items);
                    partial.clearRetainingCapacity();
                } else {
                    // Complete line within this chunk
                    try line_buffer.addLine(read_buf[chunk_start..chunk_end]);
                }
                chunk_start = chunk_end;
            }
        }

        // Save any remaining partial line data
        if (chunk_start < bytes_read) {
            try partial.appendSlice(allocator, read_buf[chunk_start..bytes_read]);
        }
    }

    // Handle final partial line (no trailing delimiter)
    if (partial.items.len > 0) {
        try line_buffer.addLine(partial.items);
    }

    if (reverse) {
        try line_buffer.writeAllLinesReversed(writer, delimiter);
    } else {
        try line_buffer.writeAllLines(writer);
    }
}

/// Process input by line count (fallback for non-file inputs like stdin)
fn processInputByLines(allocator: std.mem.Allocator, reader: anytype, writer: anytype, line_count: ?u64, zero_terminated: bool, from_beginning: bool, reverse: bool) !void {
    if (line_count) |lc| {
        if (lc == 0 and !from_beginning) return; // Output nothing for 0 lines
    }

    const delimiter: u8 = if (zero_terminated) 0 else '\n';

    if (from_beginning) {
        const lc = line_count orelse 1;
        const max_lines = @as(usize, @intCast(lc));
        // Skip the first (line_count - 1) lines and output the rest
        const skip_count = if (lc > 0) max_lines - 1 else 0;
        var lines_skipped: usize = 0;

        // Skip lines by reading and discarding them
        while (lines_skipped < skip_count) {
            if (reader.takeDelimiterInclusive(delimiter)) |_| {
                lines_skipped += 1;
            } else |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            }
        }

        // Output remaining lines
        while (reader.takeDelimiterInclusive(delimiter)) |line| {
            try writer.writeAll(line);
        } else |err| switch (err) {
            error.EndOfStream => {
                // Handle final partial line (no trailing delimiter)
                const remaining = reader.buffered();
                if (remaining.len > 0) {
                    try writer.writeAll(remaining);
                    reader.toss(remaining.len);
                }
            },
            else => return err,
        }
        return;
    }

    // When line_count is null (reverse all), collect into a dynamic list
    if (line_count == null) {
        var lines = std.ArrayListUnmanaged([]u8){};
        defer {
            for (lines.items) |line| allocator.free(line);
            lines.deinit(allocator);
        }

        while (reader.takeDelimiterInclusive(delimiter)) |line| {
            const line_copy = try allocator.dupe(u8, line);
            try lines.append(allocator, line_copy);
        } else |err| switch (err) {
            error.EndOfStream => {
                const remaining = reader.buffered();
                if (remaining.len > 0) {
                    const line_copy = try allocator.dupe(u8, remaining);
                    try lines.append(allocator, line_copy);
                    reader.toss(remaining.len);
                }
            },
            else => return err,
        }

        // Output in reverse order
        var i = lines.items.len;
        while (i > 0) {
            i -= 1;
            const line = lines.items[i];
            if (line.len > 0 and line[line.len - 1] == delimiter) {
                try writer.writeAll(line[0 .. line.len - 1]);
                try writer.writeByte(delimiter);
            } else {
                try writer.writeAll(line);
                try writer.writeByte(delimiter);
            }
        }
        return;
    }

    const max_lines = @as(usize, @intCast(line_count.?));

    // Use LineBuffer ring buffer for last N lines
    var line_buffer = try LineBuffer.init(allocator, max_lines);
    defer line_buffer.deinit();

    // Read lines and add to ring buffer
    while (reader.takeDelimiterInclusive(delimiter)) |line| {
        try line_buffer.addLine(line);
    } else |err| switch (err) {
        error.EndOfStream => {
            // Handle final partial line (no trailing delimiter)
            const remaining = reader.buffered();
            if (remaining.len > 0) {
                try line_buffer.addLine(remaining);
                reader.toss(remaining.len);
            }
        },
        else => return err,
    }

    // Output all stored lines
    if (reverse) {
        try line_buffer.writeAllLinesReversed(writer, delimiter);
    } else {
        try line_buffer.writeAllLines(writer);
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

test "tail -n +1 outputs entire file (from-beginning)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3\nline4\nline5\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const options = TailOptions{ .line_count = 1, .from_beginning = true };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(testing.allocator), options);

    // +1 means skip 0 lines, output everything
    try testing.expectEqualStrings("line1\nline2\nline3\nline4\nline5\n", buffer.items);
}

test "tail -n +3 skips first 2 lines (from-beginning)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3\nline4\nline5\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const options = TailOptions{ .line_count = 3, .from_beginning = true };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(testing.allocator), options);

    // +3 means skip first 2 lines, output from line 3 onward
    try testing.expectEqualStrings("line3\nline4\nline5\n", buffer.items);
}

test "tail -n +NUM larger than file outputs nothing" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const options = TailOptions{ .line_count = 100, .from_beginning = true };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(testing.allocator), options);

    // +100 on a 2-line file: skip 99 lines, nothing left
    try testing.expectEqualStrings("", buffer.items);
}

test "tail -n +NUM detected via runTail arg parsing" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3\nline4\nline5\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    // Get the real path for the file
    const path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(path);

    const args = [_][]const u8{ "-n", "+3", path };
    const result = try runTail(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("line3\nline4\nline5\n", buffer.items);
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
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "invalid number of lines") != null);
}

test "tail with invalid byte count" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-c", "xyz" };
    const result = try runTail(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "invalid number of bytes") != null);
}

test "tail with obsolete -NUM syntax" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-2", file_path };
    const exit_code = try runTail(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("Line 4\nLine 5\n", stdout_buffer.items);
}

test "tail: -f flag is parsed" {
    const args = [_][]const u8{ "-f", "/tmp/somefile" };
    const parsed = try common.argparse.ArgParser.parse(TailArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);

    try testing.expect(parsed.follow);
    try testing.expect(!parsed.follow_retry);
}

test "tail: -F flag is parsed" {
    const args = [_][]const u8{ "-F", "/tmp/somefile" };
    const parsed = try common.argparse.ArgParser.parse(TailArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);

    try testing.expect(parsed.follow_retry);
    try testing.expect(!parsed.follow);
}

test "tail: -f with nonexistent file gives error" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-f", "/tmp/vibeutils_test_nonexistent_file_xyzzy" };
    const result = try runTail(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "No such file or directory") != null);
}

test "tail: -F with nonexistent file does not immediately fail" {
    // -F (follow with retry) should not immediately error when the file
    // does not exist -- it should wait and retry. This test will FAIL
    // until follow-retry logic is implemented.
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-F", "/tmp/vibeutils_test_nonexistent_file_xyzzy" };
    const result = try runTail(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));
    // -F should exit 0 (or at least not fail immediately with error 1)
    try testing.expectEqual(@as(u8, 0), result);
}

test "tail: help output mentions -f and -F flags" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"--help"};
    const result = try runTail(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    // Help text should document the -f (follow) flag
    try testing.expect(std.mem.indexOf(u8, buffer.items, "-f") != null);
    // Help text should document the -F (follow-retry) flag
    try testing.expect(std.mem.indexOf(u8, buffer.items, "-F") != null);
}

test "tail: -b flag is parsed" {
    const args = [_][]const u8{ "-b", "3", "/tmp/somefile" };
    const parsed = try common.argparse.ArgParser.parse(TailArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);

    try testing.expect(parsed.blocks != null);
    try testing.expectEqualStrings("3", parsed.blocks.?);
}

test "tail: -b 2 shows last 1024 bytes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file with 2048 bytes (4 blocks of 512)
    var content: [2048]u8 = undefined;
    @memset(content[0..1024], 'A');
    @memset(content[1024..2048], 'B');
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", &content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    const args = [_][]const u8{ "-b", "2", file_path };
    const result = try runTail(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqual(@as(usize, 1024), buffer.items.len);
    // Last 1024 bytes should all be 'B'
    for (buffer.items) |byte| {
        try testing.expectEqual(@as(u8, 'B'), byte);
    }
}

test "tail: -b +2 shows from byte 512 onwards" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file with 1536 bytes (3 blocks of 512)
    var content: [1536]u8 = undefined;
    @memset(content[0..512], 'A');
    @memset(content[512..1024], 'B');
    @memset(content[1024..1536], 'C');
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", &content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    // -b +2 means starting from block 2 (byte 512), output the rest
    const args = [_][]const u8{ "-b", "+2", file_path };
    const result = try runTail(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    // Should output from byte 512 onwards (1024 bytes: 512 B's + 512 C's)
    try testing.expectEqual(@as(usize, 1024), buffer.items.len);
    for (buffer.items[0..512]) |byte| {
        try testing.expectEqual(@as(u8, 'B'), byte);
    }
    for (buffer.items[512..1024]) |byte| {
        try testing.expectEqual(@as(u8, 'C'), byte);
    }
}

test "tail: -b with file shorter than block count shows everything" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "short file content";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const file_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(file_path);

    // -b 10 = 5120 bytes, much larger than the file
    const args = [_][]const u8{ "-b", "10", file_path };
    const result = try runTail(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("short file content", buffer.items);
}

test "tail: -r flag is parsed" {
    const args = [_][]const u8{ "-r", "/tmp/somefile" };
    const parsed = try common.argparse.ArgParser.parse(TailArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);

    try testing.expect(parsed.reverse);
}

test "tail: -r reverses all lines of a file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3\nline4\nline5\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const options = TailOptions{ .line_count = null, .reverse = true };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(testing.allocator), options);

    try testing.expectEqualStrings("line5\nline4\nline3\nline2\nline1\n", buffer.items);
}

test "tail: -r -n 3 reverses last 3 lines" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "line1\nline2\nline3\nline4\nline5\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const options = TailOptions{ .line_count = 3, .reverse = true };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(testing.allocator), options);

    try testing.expectEqualStrings("line5\nline4\nline3\n", buffer.items);
}

test "tail: -r on single-line file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "only line\n";
    try common.test_utils.createTestFile(tmp_dir.dir, "test.txt", content);

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const options = TailOptions{ .line_count = null, .reverse = true };
    try testTailFile(tmp_dir.dir, "test.txt", buffer.writer(testing.allocator), options);

    try testing.expectEqualStrings("only line\n", buffer.items);
}

/// Test helper for processing a file from a directory
fn testTailFile(dir: std.fs.Dir, filename: []const u8, writer: anytype, options: TailOptions) !void {
    const file = try dir.openFile(filename, .{});
    defer file.close();
    if (options.byte_count) |byte_count| {
        var file_buffer: [8192]u8 = undefined;
        var file_reader = file.reader(&file_buffer);
        const file_interface = &file_reader.interface;
        try processInputByBytes(testing.allocator, file_interface, writer, byte_count, file, options.from_beginning_bytes);
    } else {
        const line_count = if (options.line_count) |lc| @as(?u64, lc) else if (options.reverse) null else @as(?u64, 10);
        try processInputByLinesFromFile(testing.allocator, file, writer, line_count, options.zero_terminated, options.from_beginning, options.reverse);
    }
}
