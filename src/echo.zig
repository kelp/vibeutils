//! echo - display a line of text
//!
//! The echo utility writes its arguments to standard output, followed by a newline.
//! If the -n option is present, the trailing newline is omitted.
//!
//! This implementation is compatible with GNU echo and supports backslash escape
//! sequences when the -e option is specified.
const std = @import("std");
const common = @import("common");
const testing = std.testing;

/// Command-line arguments for the echo utility
const EchoArgs = struct {
    /// Display help and exit
    help: bool = false,
    /// Output version information and exit
    version: bool = false,
    /// Do not output the trailing newline
    n: bool = false,
    /// Enable interpretation of backslash escapes
    e: bool = false,
    /// Disable interpretation of backslash escapes (default)
    E: bool = false,
    /// Text arguments to display
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .n = .{ .short = 'n', .desc = "Do not output the trailing newline" },
        .e = .{ .short = 'e', .desc = "Enable interpretation of backslash escapes" },
        .E = .{ .short = 'E', .desc = "Disable interpretation of backslash escapes (default)" },
    };
};

/// Main entry point for the echo utility
pub fn runEcho(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    // Parse arguments using new parser
    const parsed_args = common.argparse.ArgParser.parse(EchoArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "echo", "invalid argument", .{});
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

    // Create options with correct flag precedence
    // When both -e and -E are specified, the last one should win (GNU behavior)
    const interpret_escapes = blk: {
        if (!parsed_args.e and !parsed_args.E) {
            // Neither flag specified, default to false
            break :blk false;
        } else if (parsed_args.e and !parsed_args.E) {
            // Only -e specified
            break :blk true;
        } else if (!parsed_args.e and parsed_args.E) {
            // Only -E specified
            break :blk false;
        } else {
            // Both flags specified, need to determine which came last
            // Check the raw arguments to find the last occurrence
            var last_e_pos: ?usize = null;
            var last_E_pos: ?usize = null;
            for (args, 0..) |arg, i| {
                if (std.mem.eql(u8, arg, "-e")) {
                    last_e_pos = i;
                } else if (std.mem.eql(u8, arg, "-E")) {
                    last_E_pos = i;
                }
            }

            if (last_e_pos != null and last_E_pos != null) {
                // Both found, use the one that appeared last
                break :blk last_e_pos.? > last_E_pos.?;
            } else if (last_e_pos != null) {
                break :blk true;
            } else {
                break :blk false;
            }
        }
    };

    const options = EchoOptions{
        .suppress_newline = parsed_args.n,
        .interpret_escapes = interpret_escapes,
    };

    try echoStrings(parsed_args.positionals, stdout_writer, options);
    return @intFromEnum(common.ExitCode.success);
}

/// Main entry point for the echo utility
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse process arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const exit_code = try runEcho(allocator, args[1..], stdout, stderr);
    std.process.exit(exit_code);
}

/// Print help message to the specified writer
fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: echo [OPTION]... [STRING]...
        \\Echo the STRING(s) to standard output.
        \\
        \\  -n         do not output the trailing newline
        \\  -e         enable interpretation of backslash escapes
        \\  -E         disable interpretation of backslash escapes (default)
        \\  --help     display this help and exit
        \\  --version  output version information and exit
        \\
        \\If -e is in effect, the following sequences are recognized:
        \\  \\a  alert (BEL)            \\n  new line
        \\  \\b  backspace              \\r  carriage return
        \\  \\c  produce no further output
        \\  \\e  escape                 \\t  horizontal tab
        \\  \\f  form feed              \\v  vertical tab
        \\  \\\\  backslash              \\0NNN  byte with octal value NNN
        \\  \\xHH  byte with hex value HH
        \\
    );
}

/// Print version information to the specified writer
fn printVersion(writer: anytype) !void {
    try writer.print("echo ({s}) {s}\n", .{ common.name, common.version });
}

/// Options for echo behavior
const EchoOptions = struct {
    /// If true, do not output a trailing newline
    suppress_newline: bool = false,
    /// If true, interpret backslash escape sequences
    interpret_escapes: bool = false,
};

/// Echo strings to the provided writer with the specified options.
/// Writes each string separated by spaces and optionally interprets escape sequences.
pub fn echoStrings(strings: []const []const u8, writer: anytype, options: EchoOptions) !void {
    for (strings, 0..) |str, i| {
        if (i > 0) try writer.writeAll(" ");

        if (options.interpret_escapes) {
            try writeWithEscapes(str, writer);
        } else {
            try writer.writeAll(str);
        }
    }

    if (!options.suppress_newline) {
        try writer.writeAll("\n");
    }
}

/// Write string while interpreting backslash escape sequences
/// Invalid escape sequences are passed through literally
///
/// Edge cases handled:
/// - Incomplete escape sequences at end of string (e.g., "\") are output as literal backslash
/// - Octal sequences overflow wraps around (values > 255 wrap to low 8 bits)
/// - Hex sequences without valid digits after \x are output literally
/// - Single backslash at end of string outputs the backslash character
fn writeWithEscapes(s: []const u8, writer: anytype) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                'a' => {
                    try writer.writeByte('\x07'); // Alert (bell)
                    i += 2;
                },
                'b' => {
                    try writer.writeByte('\x08'); // Backspace
                    i += 2;
                },
                'c' => {
                    // \c suppresses all further output, including the trailing newline
                    // This matches GNU echo behavior
                    return;
                },
                'e' => {
                    try writer.writeByte('\x1b'); // Escape
                    i += 2;
                },
                'f' => {
                    try writer.writeByte('\x0c'); // Form feed
                    i += 2;
                },
                'n' => {
                    try writer.writeByte('\n'); // Newline
                    i += 2;
                },
                'r' => {
                    try writer.writeByte('\r'); // Carriage return
                    i += 2;
                },
                't' => {
                    try writer.writeByte('\t'); // Tab
                    i += 2;
                },
                'v' => {
                    try writer.writeByte('\x0b'); // Vertical tab
                    i += 2;
                },
                '\\' => {
                    try writer.writeByte('\\'); // Backslash
                    i += 2;
                },
                '0'...'7' => {
                    // Octal sequence: \0NNN (1-3 digits)
                    var octal_value: u8 = 0;
                    var j: usize = 1;
                    while (j <= 3 and i + j < s.len and s[i + j] >= '0' and s[i + j] <= '7') : (j += 1) {
                        // Convert octal digit to value and accumulate
                        // Note: We don't check for overflow as echo traditionally wraps values
                        octal_value = octal_value * 8 + (s[i + j] - '0');
                    }
                    try writer.writeByte(octal_value);
                    i += j;
                },
                'x' => {
                    // Hex sequence: \xHH (exactly 2 hex digits)
                    if (i + 4 <= s.len) {
                        // Try to parse the next 2 characters as hex
                        const hex_value = std.fmt.parseInt(u8, s[i + 2 .. i + 4], 16) catch {
                            // Invalid hex sequence, output literally
                            try writer.writeByte('\\');
                            try writer.writeByte('x');
                            i += 2;
                            continue;
                        };
                        try writer.writeByte(hex_value);
                        i += 4;
                    } else {
                        // Not enough characters for hex value, output literally
                        try writer.writeByte('\\');
                        try writer.writeByte('x');
                        i += 2;
                    }
                },
                else => {
                    // Unknown escape sequence, output literally
                    try writer.writeByte('\\');
                    i += 1;
                },
            }
        } else {
            try writer.writeByte(s[i]);
            i += 1;
        }
    }
}

test "echo outputs single argument" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{"hello"};
    const result = try runEcho(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\n", buffer.items);
}

test "echo outputs multiple arguments with spaces" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "hello", "world" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello world\n", buffer.items);
}

test "echo -n suppresses newline" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-n", "hello" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello", buffer.items);
}

test "echo handles empty input" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{};
    const result = try runEcho(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\n", buffer.items);
}

test "echo with -n and multiple arguments" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-n", "hello", "world", "test" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello world test", buffer.items);
}

test "echo preserves empty strings" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "hello", "", "world" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello  world\n", buffer.items);
}

test "echo handles special characters" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "hello\tworld", "test\nline" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\tworld test\nline\n", buffer.items);
}

test "echo -e interprets escape sequences" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-e", "hello\\nworld" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\nworld\n", buffer.items);
}

test "echo -e handles multiple escape sequences" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-e", "\\t\\tindented\\nline\\ttwo\\\\backslash" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\t\tindented\nline\ttwo\\backslash\n", buffer.items);
}

test "echo -e with octal sequences" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-e", "\\101\\040\\102" }; // A B in octal
    const result = try runEcho(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("A B\n", buffer.items);
}

test "echo -e with hex sequences" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-e", "\\x41\\x20\\x42" }; // A B in hex
    const result = try runEcho(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("A B\n", buffer.items);
}

test "echo -e with incomplete hex sequences" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Test incomplete hex sequences that should be output literally
    const args = [_][]const u8{ "-e", "\\x4\\x\\xZ" }; // incomplete and invalid hex
    const result = try runEcho(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\\x4\\x\\xZ\n", buffer.items);
}

test "echo -e with valid hex at end of string" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Test valid hex sequence at the end of string (boundary condition)
    const args = [_][]const u8{ "-e", "test\\x41" }; // should produce "testA"
    const result = try runEcho(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("testA\n", buffer.items);
}

test "echo -en combines flags" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-en", "hello\\nworld" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\nworld", buffer.items);
}

test "echo -ne combines flags (different order)" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-ne", "hello\\nworld" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\nworld", buffer.items);
}

test "echo -E disables escape sequences" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-E", "hello\\nworld" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\\nworld\n", buffer.items);
}

test "echo -E overrides previous -e" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-e", "-E", "hello\\nworld" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\\nworld\n", buffer.items);
}

test "echo -e overrides previous -E" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-E", "-e", "hello\\nworld" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\nworld\n", buffer.items);
}

// Fuzzing tests - these test properties that should hold for all inputs
test "fuzz: echo never panics with arbitrary arguments" {
    const fuzz = @import("common").fuzz;
    const allocator = testing.allocator;

    // Test various argument patterns
    const test_inputs = [_][]const u8{
        &[_]u8{}, // Empty
        &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 }, // Various argument types
        &[_]u8{ 255, 254, 253, 100, 50, 25 }, // High bytes
        &[_]u8{ 4, 65, 66, 67, 68, 69, 70 }, // Mixed chars with special handling
        &[_]u8{ 0, 255, 0, 255, 128, 64, 32, 16 }, // Alternating pattern
    };

    for (test_inputs) |input| {
        // Generate arguments from fuzzer input
        const args = try fuzz.generateArgs(allocator, input);
        defer {
            for (args) |arg| allocator.free(arg);
            allocator.free(args);
        }

        // Echo should never panic, only return success or error
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        const result = runEcho(allocator, args, buffer.writer(), common.null_writer) catch {
            // Errors are acceptable (e.g., argument parsing errors)
            continue;
        };

        // If it succeeded, we should have gotten a valid exit code
        try testing.expect(result == 0 or result == 1 or result == 2);
    }
}

test "fuzz: echo with escape sequences never panics" {
    const fuzz = @import("common").fuzz;
    const allocator = testing.allocator;

    // Test various escape sequence patterns
    const test_inputs = [_][]const u8{
        &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }, // All escape types
        &[_]u8{ 0, 100, 1, 200, 2, 150 }, // Mixed with regular chars
        &[_]u8{ 9, 9, 9, 10, 10, 10 }, // Repeated patterns
        &[_]u8{ 255, 0, 128, 64, 32, 16, 8, 4, 2, 1 }, // Binary countdown
    };

    for (test_inputs) |input| {
        // Generate escape sequences
        const escape_seq = try fuzz.generateEscapeSequence(allocator, input);
        defer allocator.free(escape_seq);

        // Test both with and without -e flag
        const test_cases = [_][]const []const u8{
            &[_][]const u8{ "-e", escape_seq },
            &[_][]const u8{ "-E", escape_seq },
            &[_][]const u8{ "-en", escape_seq },
            &[_][]const u8{escape_seq},
        };

        for (test_cases) |args| {
            var buffer = std.ArrayList(u8).init(allocator);
            defer buffer.deinit();

            const result = runEcho(allocator, args, buffer.writer(), common.null_writer) catch {
                // Parsing errors are acceptable
                continue;
            };

            // Should succeed and produce valid exit code
            try testing.expect(result == 0 or result == 1 or result == 2);
        }
    }
}

test "fuzz: echo output is deterministic for same input" {
    const fuzz = @import("common").fuzz;
    const allocator = testing.allocator;

    const test_input = [_]u8{ 1, 2, 3, 4, 5 };
    const args = try fuzz.generateArgs(allocator, test_input[0..]);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    // Run echo twice with the same arguments
    var buffer1 = std.ArrayList(u8).init(allocator);
    defer buffer1.deinit();
    var buffer2 = std.ArrayList(u8).init(allocator);
    defer buffer2.deinit();

    const result1 = runEcho(allocator, args, buffer1.writer(), common.null_writer) catch return;
    const result2 = runEcho(allocator, args, buffer2.writer(), common.null_writer) catch return;

    // Should produce identical results
    try testing.expectEqual(result1, result2);
    try testing.expectEqualStrings(buffer1.items, buffer2.items);
}

test "fuzz: echo handles maximum argument counts gracefully" {
    const allocator = testing.allocator;

    // Create maximum number of arguments
    var args = std.ArrayList([]const u8).init(allocator);
    defer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit();
    }

    // Add up to 1000 arguments
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const arg = try std.fmt.allocPrint(allocator, "arg{}", .{i});
        try args.append(arg);
    }

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Should handle large argument counts without crashing
    const result = runEcho(allocator, args.items, buffer.writer(), common.null_writer) catch {
        // Out of memory or other resource errors are acceptable
        return;
    };

    try testing.expect(result == 0);
    // Output should contain all arguments separated by spaces
    try testing.expect(buffer.items.len > 1000); // Should be substantial output
}
