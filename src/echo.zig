//! echo - display a line of text
//!
//! The echo utility writes its arguments to standard output, followed by a newline.
//! If the -n option is present, the trailing newline is omitted.
//!
//! This implementation is compatible with GNU echo and supports backslash escape
//! sequences when the -e option is specified.
const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const testing = std.testing;

/// Main entry point for the echo utility.
///
/// GNU echo treats unknown flags as positional arguments. Only -n, -e, -E
/// (and combinations like -neE) are recognized as flags. Everything else,
/// including -z, -foo, --unknown, is printed as a positional argument.
/// Once a non-flag argument is encountered, all remaining arguments
/// (including ones that look like flags) are treated as positional.
pub fn runEcho(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    _ = stderr_writer;
    var suppress_newline = false;
    var interpret_escapes = false;
    var positional_start: usize = 0;

    // Scan args for flags. Stop at the first non-flag argument.
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--help")) {
            try printHelp(allocator, stdout_writer);
            return @intFromEnum(common.ExitCode.success);
        }
        if (std.mem.eql(u8, arg, "--version")) {
            try printVersion(stdout_writer);
            return @intFromEnum(common.ExitCode.success);
        }

        // Must start with '-' and have at least one character after it
        if (arg.len < 2 or arg[0] != '-') {
            break;
        }

        // Check that every character after '-' is one of n, e, E
        const flag_chars = arg[1..];
        var valid_flag = true;
        for (flag_chars) |c| {
            if (c != 'n' and c != 'e' and c != 'E') {
                valid_flag = false;
                break;
            }
        }

        if (!valid_flag) {
            // Not a recognized flag combination -- treat as positional
            break;
        }

        // Apply flags left-to-right; last-wins for -e/-E
        for (flag_chars) |c| {
            switch (c) {
                'n' => suppress_newline = true,
                'e' => interpret_escapes = true,
                'E' => interpret_escapes = false,
                else => unreachable,
            }
        }

        positional_start = i + 1;
    }

    const positionals = args[positional_start..];

    const options = EchoOptions{
        .suppress_newline = suppress_newline,
        .interpret_escapes = interpret_escapes,
    };

    try echoStrings(positionals, stdout_writer, options);
    return @intFromEnum(common.ExitCode.success);
}

/// CLI entry point — parses process arguments and sets up I/O buffers.
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Parse process arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Set up buffered writers for stdout and stderr
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runEcho(allocator, args[1..], stdout, stderr);

    // Flush buffers before exit
    stdout.flush() catch {};
    stderr.flush() catch {};
    std.process.exit(exit_code);
}

/// Print help message to the specified writer
fn printHelp(allocator: std.mem.Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: echo [OPTION]... [STRING]...
        \\Echo the STRING(s) to standard output.
        \\
        \\  -n         suppress the trailing newline
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
            const terminated = try writeWithEscapes(str, writer);
            // If \c was encountered, stop processing remaining arguments
            if (terminated) return;
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
/// Returns true if \c was encountered (indicating termination), false otherwise
///
/// Edge cases handled:
/// - Incomplete escape sequences at end of string (e.g., "\") are output as literal backslash
/// - Octal sequences overflow wraps around (values > 255 wrap to low 8 bits)
/// - Hex sequences without valid digits after \x are output literally
/// - Single backslash at end of string outputs the backslash character
fn writeWithEscapes(s: []const u8, writer: anytype) !bool {
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
                    return true;
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
                    // Octal sequence: \0NNN or \NNN (up to 3 octal digits)
                    var octal_value: u8 = 0;
                    var j: usize = 1;
                    while (j <= 3 and i + j < s.len and s[i + j] >= '0' and s[i + j] <= '7') : (j += 1) {
                        // Convert octal digit to value and accumulate
                        // Use wrapping arithmetic to match GNU behavior for overflow
                        octal_value = octal_value *% 8 +% (s[i + j] - '0');
                    }
                    try writer.writeByte(octal_value);
                    i += j;
                },
                'x' => {
                    // Hex sequence: \xH or \xHH (1-2 hex digits, GNU compatible)
                    var hex_value: u8 = 0;
                    var j: usize = 2; // skip \x
                    var hex_digits: usize = 0;
                    while (hex_digits < 2 and i + j < s.len) : ({
                        j += 1;
                        hex_digits += 1;
                    }) {
                        const c = s[i + j];
                        const digit = switch (c) {
                            '0'...'9' => c - '0',
                            'a'...'f' => c - 'a' + 10,
                            'A'...'F' => c - 'A' + 10,
                            else => break,
                        };
                        hex_value = hex_value * 16 + digit;
                    }
                    if (hex_digits > 0) {
                        try writer.writeByte(hex_value);
                        i += j;
                    } else {
                        // No hex digits, output literally
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
    return false;
}

test "echo outputs single argument" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"hello"};
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\n", buffer.items);
}

test "echo outputs multiple arguments with spaces" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "hello", "world" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello world\n", buffer.items);
}

test "echo -n suppresses newline" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-n", "hello" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello", buffer.items);
}

test "echo handles empty input" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{};
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\n", buffer.items);
}

test "echo with -n and multiple arguments" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-n", "hello", "world", "test" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello world test", buffer.items);
}

test "echo preserves empty strings" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "hello", "", "world" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello  world\n", buffer.items);
}

test "echo handles special characters" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "hello\tworld", "test\nline" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\tworld test\nline\n", buffer.items);
}

test "echo -e interprets escape sequences" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-e", "hello\\nworld" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\nworld\n", buffer.items);
}

test "echo -e handles multiple escape sequences" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-e", "\\t\\tindented\\nline\\ttwo\\\\backslash" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\t\tindented\nline\ttwo\\backslash\n", buffer.items);
}

test "echo -e with octal sequences" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-e", "\\101\\040\\102" }; // A B in octal
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("A B\n", buffer.items);
}

test "echo -e with hex sequences" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-e", "\\x41\\x20\\x42" }; // A B in hex
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("A B\n", buffer.items);
}

test "echo -e with incomplete hex sequences" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    // \x4 = 0x04 (1 hex digit), \x = literal, \xZ = literal
    const args = [_][]const u8{ "-e", "\\x4\\x\\xZ" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\x04\\x\\xZ\n", buffer.items);
}

test "echo -e with valid hex at end of string" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    // Test valid hex sequence at the end of string (boundary condition)
    const args = [_][]const u8{ "-e", "test\\x41" }; // should produce "testA"
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("testA\n", buffer.items);
}

test "echo -en combines flags" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-en", "hello\\nworld" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\nworld", buffer.items);
}

test "echo -ne combines flags (different order)" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-ne", "hello\\nworld" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\nworld", buffer.items);
}

test "echo -E disables escape sequences" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-E", "hello\\nworld" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\\nworld\n", buffer.items);
}

test "echo -E overrides previous -e" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-e", "-E", "hello\\nworld" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\\nworld\n", buffer.items);
}

test "echo -e overrides previous -E" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-E", "-e", "hello\\nworld" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\nworld\n", buffer.items);
}

test "echo -e with \\c stops all remaining arguments" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    // Test that \c stops processing ALL remaining arguments, not just current one
    const args = [_][]const u8{ "-e", "start", "middle\\c", "should", "not", "appear" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("start middle", buffer.items);
}

test "echo -e with \\c at start of argument stops all" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    // Test that \c at start of argument stops everything
    const args = [_][]const u8{ "-e", "start", "\\cfollowed", "by", "more" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("start ", buffer.items);
}

test "echo treats lone dash as positional argument" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-"};
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("-\n", buffer.items);
}

test "echo -n with lone dash and text" {
    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-n", "-", "hello" };
    const result = try runEcho(testing.allocator, &args, buffer.writer(testing.allocator), common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("- hello", buffer.items);
}
