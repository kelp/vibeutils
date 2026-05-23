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
pub fn runEcho(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) !u8 {
    _ = io;
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
pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, runEcho);
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
        \\  \\xHH  byte with hex value (1 to 2 digits)
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
                '0' => {
                    // Octal with \0 prefix: \0NNN (up to 3 octal digits after the 0 introducer)
                    var octal_value: u8 = 0;
                    var j: usize = 2; // skip past \ and 0 introducer
                    var count: usize = 0;
                    while (count < 3 and i + j < s.len and s[i + j] >= '0' and s[i + j] <= '7') : ({
                        j += 1;
                        count += 1;
                    }) {
                        octal_value = octal_value *% 8 +% (s[i + j] - '0');
                    }
                    try writer.writeByte(octal_value);
                    i += j;
                },
                '1'...'7' => {
                    // Octal sequence: \NNN (up to 3 octal digits, first digit is part of value)
                    var octal_value: u8 = 0;
                    var j: usize = 1;
                    while (j <= 3 and i + j < s.len and s[i + j] >= '0' and s[i + j] <= '7') : (j += 1) {
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
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{"hello"};
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\n", buffer.writer.buffered());
}

test "echo outputs multiple arguments with spaces" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "hello", "world" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello world\n", buffer.writer.buffered());
}

test "echo -n suppresses newline" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-n", "hello" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello", buffer.writer.buffered());
}

test "echo handles empty input" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{};
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\n", buffer.writer.buffered());
}

test "echo with -n and multiple arguments" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-n", "hello", "world", "test" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello world test", buffer.writer.buffered());
}

test "echo preserves empty strings" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "hello", "", "world" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello  world\n", buffer.writer.buffered());
}

test "echo handles special characters" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "hello\tworld", "test\nline" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\tworld test\nline\n", buffer.writer.buffered());
}

test "echo -e interprets escape sequences" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-e", "hello\\nworld" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\nworld\n", buffer.writer.buffered());
}

test "echo -e handles multiple escape sequences" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-e", "\\t\\tindented\\nline\\ttwo\\\\backslash" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\t\tindented\nline\ttwo\\backslash\n", buffer.writer.buffered());
}

test "echo -e with octal sequences" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-e", "\\101\\040\\102" }; // A B in octal
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("A B\n", buffer.writer.buffered());
}

test "echo -e with hex sequences" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-e", "\\x41\\x20\\x42" }; // A B in hex
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("A B\n", buffer.writer.buffered());
}

test "echo -e with incomplete hex sequences" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    // \x4 = 0x04 (1 hex digit), \x = literal, \xZ = literal
    const args = [_][]const u8{ "-e", "\\x4\\x\\xZ" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\x04\\x\\xZ\n", buffer.writer.buffered());
}

test "echo -e with valid hex at end of string" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    // Test valid hex sequence at the end of string (boundary condition)
    const args = [_][]const u8{ "-e", "test\\x41" }; // should produce "testA"
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("testA\n", buffer.writer.buffered());
}

test "echo -en combines flags" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-en", "hello\\nworld" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\nworld", buffer.writer.buffered());
}

test "echo -ne combines flags (different order)" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-ne", "hello\\nworld" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\nworld", buffer.writer.buffered());
}

test "echo -E disables escape sequences" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-E", "hello\\nworld" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\\nworld\n", buffer.writer.buffered());
}

test "echo -E overrides previous -e" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-e", "-E", "hello\\nworld" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\\nworld\n", buffer.writer.buffered());
}

test "echo -e overrides previous -E" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-E", "-e", "hello\\nworld" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("hello\nworld\n", buffer.writer.buffered());
}

test "echo -e with \\c stops all remaining arguments" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    // Test that \c stops processing ALL remaining arguments, not just current one
    const args = [_][]const u8{ "-e", "start", "middle\\c", "should", "not", "appear" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("start middle", buffer.writer.buffered());
}

test "echo -e with \\c at start of argument stops all" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    // Test that \c at start of argument stops everything
    const args = [_][]const u8{ "-e", "start", "\\cfollowed", "by", "more" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("start ", buffer.writer.buffered());
}

test "echo treats lone dash as positional argument" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{"-"};
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("-\n", buffer.writer.buffered());
}

test "echo -n with lone dash and text" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-n", "-", "hello" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("- hello", buffer.writer.buffered());
}

// Tests for \0NNN octal introducer bug:
// GNU echo -e treats \0 as a prefix introducer followed by up to 3 octal digits,
// distinct from \NNN where the first digit is part of the value.

test "echo -e backslash-zero-NNN: \\0077 produces ? (octal 077 = 63)" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    // \0077: \0 is introducer, 077 is the value = 63 = '?'
    const args = [_][]const u8{ "-e", "\\0077" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("?\n", buffer.writer.buffered());
}

test "echo -e backslash-zero-NNN: \\0101 produces A (octal 101 = 65)" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    // \0101: \0 is introducer, 101 is the value = 65 = 'A'
    const args = [_][]const u8{ "-e", "\\0101" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("A\n", buffer.writer.buffered());
}

test "echo -e backslash-zero alone: \\0 produces NUL" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    // \0 alone = NUL byte
    const args = [_][]const u8{ "-e", "\\0" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\x00\n", buffer.writer.buffered());
}

test "echo -e backslash-zero-zero: \\00 produces NUL" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    // \00 = NUL byte (introducer \0, value 0)
    const args = [_][]const u8{ "-e", "\\00" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\x00\n", buffer.writer.buffered());
}

test "echo -e backslash-NNN without zero prefix: \\077 produces ?" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    // \077: no introducer, 077 is the value = 63 = '?'
    const args = [_][]const u8{ "-e", "\\077" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("?\n", buffer.writer.buffered());
}

test "echo help text documents \\x as accepting 1 or 2 hex digits" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{"--help"};
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    // The help text should indicate that \x accepts 1 or 2 hex digits,
    // not imply exactly 2 with "HH". Currently says "byte with hex value HH".
    try testing.expect(std.mem.find(u8, buffer.writer.buffered(), "1 to 2") != null);
}

test "echo -e hex escape with 2 digits: \\x41 produces A" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-e", "\\x41" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("A\n", buffer.writer.buffered());
}

test "echo -e hex escape with 1 digit: \\x9 produces byte 0x09" {
    const io = testing.io;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-e", "\\x9" };
    const result = try runEcho(testing.allocator, io, &args, &buffer.writer, common.null_writer);
    try testing.expectEqual(@as(u8, 0), result);
    try testing.expectEqualStrings("\x09\n", buffer.writer.buffered());
}
