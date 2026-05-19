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
pub fn runYes(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    _ = io;
    // Parse arguments using common argparse
    const parsed_args = common.argparse.ArgParser.parse(YesArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                // GNU yes exits 1 for unrecognized options and includes the flag name
                const bad_flag = findUnknownFlag(args);
                if (bad_flag) |flag| {
                    common.printErrorWithProgram(allocator, stderr_writer, "yes", "unrecognized option '{s}'", .{flag});
                } else {
                    common.printErrorWithProgram(allocator, stderr_writer, "yes", "unrecognized option", .{});
                }
                return @intFromEnum(common.ExitCode.general_error);
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

/// Find the first unrecognized flag in args for error reporting.
/// Returns the full flag string (e.g., "--bad-flag") or null.
fn findUnknownFlag(args: []const []const u8) ?[]const u8 {
    for (args) |arg| {
        if (arg.len > 1 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--")) break;
            // Check if it's a known flag
            if (arg.len > 2 and arg[1] == '-') {
                // Long flag
                const flag_content = arg[2..];
                const flag_name = if (std.mem.findScalar(u8, flag_content, '=')) |eq_pos|
                    flag_content[0..eq_pos]
                else
                    flag_content;
                if (std.mem.eql(u8, flag_name, "help") or
                    std.mem.eql(u8, flag_name, "version"))
                {
                    continue;
                }
                return arg;
            } else {
                // Short flag - check each character
                for (arg[1..]) |c| {
                    if (c != 'h' and c != 'V') {
                        return arg;
                    }
                }
            }
        }
    }
    return null;
}

/// Prints help text for the yes utility.
fn printHelp(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
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
fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("yes ({s}) {s}\n", .{ common.name, common.version });
}

pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runYes);
}

// Tests

test "yes handles --help flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runYes(testing.allocator, io, &.{"--help"}, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage:") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "yes") != null);
}

test "yes handles --version flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runYes(testing.allocator, io, &.{"--version"}, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "yes") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "vibeutils") != null);
}

/// A Writer that captures output up to a byte limit, then returns BrokenPipe.
/// Implements the std.Io.Writer vtable.
const LimitedWriter = struct {
    captured: []u8,
    pos: usize,
    limit: usize,
    allocator: std.mem.Allocator,
    writer: std.Io.Writer,

    pub fn init(allocator: std.mem.Allocator, limit: usize) !LimitedWriter {
        var self = LimitedWriter{
            .captured = try allocator.alloc(u8, limit),
            .pos = 0,
            .limit = limit,
            .allocator = allocator,
            .writer = undefined,
        };
        self.writer = .{
            .vtable = &.{ .drain = LimitedWriter.drain },
            .buffer = &.{},
        };
        return self;
    }

    pub fn deinit(self: *LimitedWriter) void {
        self.allocator.free(self.captured);
    }

    pub fn items(self: *const LimitedWriter) []const u8 {
        return self.captured[0..self.pos];
    }

    pub fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *LimitedWriter = @alignCast(@fieldParentPtr("writer", w));
        if (self.pos >= self.limit) return error.WriteFailed;
        const last = data[data.len - 1];
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            const avail = self.limit - self.pos;
            const to_copy = @min(slice.len, avail);
            @memcpy(self.captured[self.pos..][0..to_copy], slice[0..to_copy]);
            self.pos += to_copy;
            total += slice.len;
        }
        // last element written `splat` times
        var splat_remaining = splat;
        while (splat_remaining > 0) : (splat_remaining -= 1) {
            const avail = self.limit - self.pos;
            const to_copy = @min(last.len, avail);
            @memcpy(self.captured[self.pos..][0..to_copy], last[0..to_copy]);
            self.pos += to_copy;
            total += last.len;
        }
        if (self.pos >= self.limit) return error.WriteFailed;
        return total;
    }
};

/// A Writer that counts calls and bytes, triggering BrokenPipe after max_calls.
const CallBoundedWriter = struct {
    bytes_written: usize,
    calls: usize,
    max_calls: usize,
    captured: []u8,
    captured_len: usize,
    allocator: std.mem.Allocator,
    writer: std.Io.Writer,

    pub fn init(allocator: std.mem.Allocator, capture_size: usize, max_calls: usize) !CallBoundedWriter {
        var self = CallBoundedWriter{
            .bytes_written = 0,
            .calls = 0,
            .max_calls = max_calls,
            .captured = try allocator.alloc(u8, capture_size),
            .captured_len = 0,
            .allocator = allocator,
            .writer = undefined,
        };
        self.writer = .{
            .vtable = &.{ .drain = CallBoundedWriter.drain },
            .buffer = &.{},
        };
        return self;
    }

    pub fn deinit(self: *CallBoundedWriter) void {
        self.allocator.free(self.captured);
    }

    pub fn items(self: *const CallBoundedWriter) []const u8 {
        return self.captured[0..self.captured_len];
    }

    pub fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *CallBoundedWriter = @alignCast(@fieldParentPtr("writer", w));
        self.calls += 1;
        if (self.calls > self.max_calls) return error.WriteFailed;
        const last = data[data.len - 1];
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            const remaining = self.captured.len - self.captured_len;
            const to_copy = @min(slice.len, remaining);
            if (to_copy > 0) {
                @memcpy(self.captured[self.captured_len..][0..to_copy], slice[0..to_copy]);
                self.captured_len += to_copy;
            }
            total += slice.len;
        }
        var splat_remaining = splat;
        while (splat_remaining > 0) : (splat_remaining -= 1) {
            const remaining = self.captured.len - self.captured_len;
            const to_copy = @min(last.len, remaining);
            if (to_copy > 0) {
                @memcpy(self.captured[self.captured_len..][0..to_copy], last[0..to_copy]);
                self.captured_len += to_copy;
            }
            total += last.len;
        }
        self.bytes_written += total;
        return total;
    }
};

test "yes outputs y by default" {
    const io = testing.io;
    var capture = try LimitedWriter.init(testing.allocator, 256);
    defer capture.deinit();

    const result = try runYes(testing.allocator, io, &.{}, &capture.writer, common.null_writer);

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
    const io = testing.io;
    var capture = try LimitedWriter.init(testing.allocator, 256);
    defer capture.deinit();

    const result = try runYes(testing.allocator, io, &.{"hello"}, &capture.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    const output = capture.items();
    try testing.expect(output.len > 0);
    try testing.expect(std.mem.startsWith(u8, output, "hello\n"));
}

test "yes joins multiple arguments with spaces" {
    const io = testing.io;
    var capture = try LimitedWriter.init(testing.allocator, 256);
    defer capture.deinit();

    const args = [_][]const u8{ "hello", "world" };
    const result = try runYes(testing.allocator, io, &args, &capture.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    const output = capture.items();
    try testing.expect(output.len > 0);
    try testing.expect(std.mem.startsWith(u8, output, "hello world\n"));
}

test "yes with string longer than 8192 bytes produces output" {
    const io = testing.io;
    // Build a string longer than the 8192-byte internal buffer.
    const long_str = "A" ** 8193;

    var writer = try CallBoundedWriter.init(testing.allocator, 16384, 100);
    defer writer.deinit();

    const result = try runYes(testing.allocator, io, &.{long_str}, &writer.writer, common.null_writer);

    // yes exits 0 on write error (broken pipe)
    try testing.expectEqual(@as(u8, 0), result);

    // The critical assertion: meaningful bytes must have been written.
    try testing.expect(writer.bytes_written > 0);

    // Verify the output contains the long string followed by newline
    const output = writer.items();
    try testing.expect(output.len >= long_str.len + 1);
    try testing.expect(std.mem.startsWith(u8, output, long_str));
    try testing.expectEqual(@as(u8, '\n'), output[long_str.len]);
}

test "yes with string of exactly 8193 bytes works correctly" {
    const io = testing.io;
    const str_8193 = "B" ** 8193;

    var writer = try CallBoundedWriter.init(testing.allocator, 16384, 100);
    defer writer.deinit();

    const result = try runYes(testing.allocator, io, &.{str_8193}, &writer.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(writer.bytes_written > 0);

    const output = writer.items();
    try testing.expect(output.len >= str_8193.len + 1);
    try testing.expectEqualStrings(str_8193, output[0..str_8193.len]);
    try testing.expectEqual(@as(u8, '\n'), output[str_8193.len]);
}

// ============================================================================
// Audit finding tests (IMPORTANT) — wave 5
// ============================================================================

test "yes unknown flag exits 1 (GNU behavior), not 2" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runYes(testing.allocator, io, &.{"--unknown-flag"}, common.null_writer, &stderr_aw.writer);

    // GNU yes exits 1 for unrecognized options
    try testing.expectEqual(@as(u8, 1), result);
}

test "yes error message includes the unrecognized flag name" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    _ = try runYes(testing.allocator, io, &.{"--bad-flag"}, common.null_writer, &stderr_aw.writer);

    // The error message should include the flag name
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "--bad-flag") != null);
}

test "yes with string much larger than buffer produces output" {
    const io = testing.io;
    // String that is 3x the buffer size
    const huge_str = "C" ** (8192 * 3);

    var writer = try CallBoundedWriter.init(testing.allocator, 8192 * 4, 100);
    defer writer.deinit();

    const result = try runYes(testing.allocator, io, &.{huge_str}, &writer.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(writer.bytes_written > 0);

    // Verify output starts with the huge string + newline
    const output = writer.items();
    try testing.expect(output.len >= huge_str.len + 1);
    try testing.expect(std.mem.startsWith(u8, output, huge_str));
    try testing.expectEqual(@as(u8, '\n'), output[huge_str.len]);
}
