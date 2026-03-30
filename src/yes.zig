//! yes - repeatedly output a line with all specified strings, or 'y'.

const std = @import("std");
const common = @import("common");
const testing = std.testing;

/// Arguments structure for the yes utility.
const YesArgs = struct {
    help: bool = false,
    version: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "display this help and exit" },
        .version = .{ .short = 'V', .desc = "output version information and exit" },
    };
};

/// Main function for the yes utility.
/// Repeatedly outputs a line with all specified strings, or 'y' if no arguments provided.
/// Uses arena allocator for memory management as per CLI tool best practices.
pub fn runYes(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !u8 {
    // Parse arguments using common argparse
    const parsed_args = common.argparse.ArgParser.parse(YesArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, "yes", "unrecognized option", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "yes", "option requires an argument", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "yes", "invalid option value", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed_args.positionals);

    // Handle help flag
    if (parsed_args.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version flag
    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Build output string using std.mem.join for simplicity
    const output_str = blk: {
        if (parsed_args.positionals.len == 0) {
            break :blk "y\n";
        } else {
            // Join all arguments with space and add newline
            const joined = try std.mem.join(allocator, " ", parsed_args.positionals);
            defer allocator.free(joined);
            const with_newline = try std.fmt.allocPrint(allocator, "{s}\n", .{joined});
            break :blk with_newline;
        }
    };
    defer if (parsed_args.positionals.len > 0) allocator.free(output_str);

    // Create a larger buffer for efficient output
    const buffer_size = 8192;

    if (output_str.len > buffer_size) {
        // Large string: write directly each iteration (output_str already has trailing newline)
        while (true) {
            stdout_writer.writeAll(output_str) catch {
                return @intFromEnum(common.ExitCode.success);
            };
        }
    }

    var buffer: [buffer_size]u8 = undefined;

    // Fill buffer with repeated string
    var pos: usize = 0;
    while (pos + output_str.len <= buffer.len) {
        @memcpy(buffer[pos..][0..output_str.len], output_str);
        pos += output_str.len;
    }

    // Output forever
    while (true) {
        stdout_writer.writeAll(buffer[0..pos]) catch {
            // Any write error (including BrokenPipe) is expected when piping to head, etc.
            // yes traditionally exits silently on write errors
            return @intFromEnum(common.ExitCode.success);
        };
    }
}

/// Prints help text for the yes utility.
fn printHelp(allocator: std.mem.Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: yes [STRING]...
        \\   or: yes [OPTION]
        \\
        \\Repeatedly output a line with all specified STRING(s), or 'y'.
        \\
        \\  -h, --help     display this help and exit
        \\  -V, --version  output version information and exit
        \\
        \\Examples:
        \\  yes              # Output 'y' repeatedly
        \\  yes hello        # Output 'hello' repeatedly
        \\  yes hello world  # Output 'hello world' repeatedly
        \\
    );
}

/// Prints version information for the yes utility.
fn printVersion(writer: anytype) !void {
    try writer.print("yes ({s}) {s}\n", .{ common.name, common.version });
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Set up buffered writers for stdout and stderr
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runYes(allocator, args[1..], stdout, stderr);

    // Flush buffers before exit
    stdout.flush() catch {};
    stderr.flush() catch {};

    std.process.exit(exit_code);
}

// Tests

test "yes handles --help flag" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const result = try runYes(testing.allocator, &.{"--help"}, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage:") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "yes") != null);
}

test "yes handles --version flag" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const result = try runYes(testing.allocator, &.{"--version"}, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "yes") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "vibeutils") != null);
}

/// Writer that captures output up to a limit, then returns an error
/// to break the infinite loop in yes. Simulates a broken pipe.
const LimitedCapture = struct {
    allocator: std.mem.Allocator,
    captured: []u8,
    pos: usize,
    limit: usize,

    fn init(allocator: std.mem.Allocator, limit: usize) !LimitedCapture {
        return .{
            .allocator = allocator,
            .captured = try allocator.alloc(u8, limit),
            .pos = 0,
            .limit = limit,
        };
    }

    fn deinit(self: *LimitedCapture) void {
        self.allocator.free(self.captured);
    }

    fn items(self: *const LimitedCapture) []const u8 {
        return self.captured[0..self.pos];
    }

    pub fn writeByte(self: *LimitedCapture, byte: u8) error{BrokenPipe}!void {
        return self.writeAll(&.{byte});
    }

    pub fn writeAll(self: *LimitedCapture, data: []const u8) error{BrokenPipe}!void {
        if (self.pos >= self.limit) return error.BrokenPipe;
        const remaining = self.limit - self.pos;
        const to_write = @min(data.len, remaining);
        @memcpy(self.captured[self.pos..][0..to_write], data[0..to_write]);
        self.pos += to_write;
        if (self.pos >= self.limit) return error.BrokenPipe;
    }

    fn print(self: *LimitedCapture, comptime fmt: []const u8, args: anytype) error{BrokenPipe}!void {
        _ = fmt;
        _ = args;
        _ = self;
        return error.BrokenPipe;
    }

    fn flush(self: *LimitedCapture) error{BrokenPipe}!void {
        _ = self;
    }
};

test "yes outputs y by default" {
    var capture = try LimitedCapture.init(testing.allocator, 256);
    defer capture.deinit();

    const result = try runYes(testing.allocator, &.{}, &capture, common.null_writer);

    // yes exits successfully on write error (broken pipe)
    try testing.expectEqual(@as(u8, 0), result);

    // Output should be "y\n" repeated
    const output = capture.items();
    try testing.expect(output.len > 0);
    try testing.expect(std.mem.startsWith(u8, output, "y\n"));

    // Verify the pattern repeats
    var i: usize = 0;
    while (i + 2 <= output.len) : (i += 2) {
        try testing.expectEqualStrings("y\n", output[i..][0..2]);
    }
}

test "yes outputs custom string" {
    var capture = try LimitedCapture.init(testing.allocator, 256);
    defer capture.deinit();

    const result = try runYes(testing.allocator, &.{"hello"}, &capture, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    const output = capture.items();
    try testing.expect(output.len > 0);
    try testing.expect(std.mem.startsWith(u8, output, "hello\n"));
}

test "yes joins multiple arguments with spaces" {
    var capture = try LimitedCapture.init(testing.allocator, 256);
    defer capture.deinit();

    const args = [_][]const u8{ "hello", "world" };
    const result = try runYes(testing.allocator, &args, &capture, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    const output = capture.items();
    try testing.expect(output.len > 0);
    try testing.expect(std.mem.startsWith(u8, output, "hello world\n"));
}

/// Writer that limits total writeAll calls to prevent infinite loops.
/// If too many calls occur without meaningful bytes written, returns
/// BrokenPipe. This detects the bug where yes writes zero-byte chunks
/// in an infinite loop when the string exceeds the buffer size.
const CallBoundedWriter = struct {
    bytes_written: usize,
    calls: usize,
    max_calls: usize,
    captured: []u8,
    captured_len: usize,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, capture_size: usize, max_calls: usize) !CallBoundedWriter {
        return .{
            .bytes_written = 0,
            .calls = 0,
            .max_calls = max_calls,
            .captured = try allocator.alloc(u8, capture_size),
            .captured_len = 0,
            .allocator = allocator,
        };
    }

    fn deinit(self: *CallBoundedWriter) void {
        self.allocator.free(self.captured);
    }

    pub fn writeByte(self: *CallBoundedWriter, byte: u8) error{BrokenPipe}!void {
        return self.writeAll(&.{byte});
    }

    pub fn writeAll(self: *CallBoundedWriter, data: []const u8) error{BrokenPipe}!void {
        self.calls += 1;
        if (self.calls > self.max_calls) return error.BrokenPipe;
        self.bytes_written += data.len;
        // Capture beginning of output for verification
        const remaining = self.captured.len - self.captured_len;
        const to_copy = @min(data.len, remaining);
        if (to_copy > 0) {
            @memcpy(self.captured[self.captured_len..][0..to_copy], data[0..to_copy]);
            self.captured_len += to_copy;
        }
    }

    fn print(self: *CallBoundedWriter, comptime fmt: []const u8, args: anytype) error{BrokenPipe}!void {
        _ = fmt;
        _ = args;
        _ = self;
        return error.BrokenPipe;
    }

    fn flush(self: *CallBoundedWriter) error{BrokenPipe}!void {
        _ = self;
    }

    fn items(self: *const CallBoundedWriter) []const u8 {
        return self.captured[0..self.captured_len];
    }
};

test "yes with string longer than 8192 bytes produces output" {
    // Build a string longer than the 8192-byte internal buffer.
    // The string itself is 8193 bytes (before newline), so with
    // newline it is 8194 bytes -- exceeding the buffer size.
    const long_str = "A" ** 8193;

    // Use CallBoundedWriter: if yes enters an infinite loop writing
    // zero bytes, it will hit the max_calls limit and error out.
    // With max_calls=100, a working implementation needs only 1-2
    // calls to write 8194+ bytes. The bug writes 0 bytes per call
    // and would exhaust 100 calls with 0 bytes_written.
    var writer = try CallBoundedWriter.init(testing.allocator, 16384, 100);
    defer writer.deinit();

    const result = try runYes(testing.allocator, &.{long_str}, &writer, common.null_writer);

    // yes exits 0 on write error (broken pipe)
    try testing.expectEqual(@as(u8, 0), result);

    // The critical assertion: meaningful bytes must have been written.
    // With the bug, bytes_written is 0 because every writeAll call
    // passes a zero-length slice.
    try testing.expect(writer.bytes_written > 0);

    // Verify the output contains the long string followed by newline
    const output = writer.items();
    try testing.expect(output.len >= long_str.len + 1);
    try testing.expect(std.mem.startsWith(u8, output, long_str));
    try testing.expectEqual(@as(u8, '\n'), output[long_str.len]);
}

test "yes with string of exactly 8193 bytes works correctly" {
    // Edge case: string is exactly 1 byte over the buffer size
    const str_8193 = "B" ** 8193;

    var writer = try CallBoundedWriter.init(testing.allocator, 16384, 100);
    defer writer.deinit();

    const result = try runYes(testing.allocator, &.{str_8193}, &writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(writer.bytes_written > 0);

    // Output must start with the full string + newline
    const output = writer.items();
    try testing.expect(output.len >= str_8193.len + 1);
    try testing.expectEqualStrings(str_8193, output[0..str_8193.len]);
    try testing.expectEqual(@as(u8, '\n'), output[str_8193.len]);
}

// ============================================================================
// Audit finding tests (IMPORTANT) — wave 5
// ============================================================================

test "yes unknown flag exits 1 (GNU behavior), not 2" {
    // GNU yes: unknown flags exit 1, not 2.
    // vibeutils currently exits 2 (misuse).
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const result = try runYes(testing.allocator, &.{"--unknown-flag"}, common.null_writer, stderr_buffer.writer(testing.allocator));

    // GNU yes exits 1 for unrecognized options
    try testing.expectEqual(@as(u8, 1), result);
}

test "yes error message includes the unrecognized flag name" {
    // GNU yes: "yes: unrecognized option '--unknown-flag'"
    // vibeutils currently says: "yes: unrecognized option" (no flag name).
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    _ = try runYes(testing.allocator, &.{"--bad-flag"}, common.null_writer, stderr_buffer.writer(testing.allocator));

    // The error message should include the flag name
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "--bad-flag") != null);
}

test "yes with string much larger than buffer produces output" {
    // String that is 3x the buffer size
    const huge_str = "C" ** (8192 * 3);

    var writer = try CallBoundedWriter.init(testing.allocator, 8192 * 4, 100);
    defer writer.deinit();

    const result = try runYes(testing.allocator, &.{huge_str}, &writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(writer.bytes_written > 0);

    // Verify output starts with the huge string + newline
    const output = writer.items();
    try testing.expect(output.len >= huge_str.len + 1);
    try testing.expect(std.mem.startsWith(u8, output, huge_str));
    try testing.expectEqual(@as(u8, '\n'), output[huge_str.len]);
}
