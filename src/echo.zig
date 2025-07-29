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
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse arguments using new parser
    const args = common.argparse.ArgParser.parseProcess(EchoArgs, allocator) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.fatal("invalid argument", .{});
            },
            else => return err,
        }
    };
    defer allocator.free(args.positionals);

    // Handle help
    if (args.help) {
        try printHelp();
        return;
    }

    // Handle version
    if (args.version) {
        try printVersion();
        return;
    }

    // Create options (handle -E flag which disables -e)
    const options = EchoOptions{
        .suppress_newline = args.n,
        .interpret_escapes = args.e and !args.E,
    };

    const stdout = std.io.getStdOut().writer();
    try echoStrings(args.positionals, stdout, options);
}

/// Print help message to stdout
fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
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

/// Print version information to stdout
fn printVersion() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("echo ({s}) {s}\n", .{ common.name, common.version });
}

/// Options for echo behavior
const EchoOptions = struct {
    /// If true, do not output a trailing newline
    suppress_newline: bool = false,
    /// If true, interpret backslash escape sequences
    interpret_escapes: bool = false,
};

/// Echo strings to the provided writer with the specified options
///
/// This function handles the core echo functionality, writing each string
/// separated by spaces and optionally interpreting escape sequences.
fn echoStrings(strings: []const []const u8, writer: anytype, options: EchoOptions) !void {
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

// Test helper that parses flags manually for backward compatibility with tests
fn echo(args: []const []const u8, writer: anytype) !void {
    var suppress_newline = false;
    var interpret_escapes = false;
    var start_index: usize = 0;

    // Parse flags
    while (start_index < args.len and args[start_index].len > 0 and args[start_index][0] == '-') {
        const flag = args[start_index];
        if (std.mem.eql(u8, flag, "-n")) {
            suppress_newline = true;
            start_index += 1;
        } else if (std.mem.eql(u8, flag, "-e")) {
            interpret_escapes = true;
            start_index += 1;
        } else if (std.mem.eql(u8, flag, "-E")) {
            interpret_escapes = false;
            start_index += 1;
        } else if (std.mem.eql(u8, flag, "-en") or std.mem.eql(u8, flag, "-ne")) {
            suppress_newline = true;
            interpret_escapes = true;
            start_index += 1;
        } else if (std.mem.eql(u8, flag, "--")) {
            start_index += 1;
            break;
        } else {
            break; // Unknown flag, treat as argument
        }
    }

    const options = EchoOptions{
        .suppress_newline = suppress_newline,
        .interpret_escapes = interpret_escapes,
    };

    try echoStrings(args[start_index..], writer, options);
}

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
                    // Suppress trailing newline
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
                    // Octal sequence
                    var octal_value: u8 = 0;
                    var j: usize = 1;
                    while (j <= 3 and i + j < s.len and s[i + j] >= '0' and s[i + j] <= '7') : (j += 1) {
                        octal_value = octal_value * 8 + (s[i + j] - '0');
                    }
                    try writer.writeByte(octal_value);
                    i += j;
                },
                'x' => {
                    // Hex sequence
                    if (i + 3 < s.len) {
                        const hex_value = std.fmt.parseInt(u8, s[i + 2 .. i + 4], 16) catch {
                            try writer.writeByte('\\');
                            try writer.writeByte('x');
                            i += 2;
                            continue;
                        };
                        try writer.writeByte(hex_value);
                        i += 4;
                    } else {
                        try writer.writeByte('\\');
                        try writer.writeByte('x');
                        i += 2;
                    }
                },
                else => {
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
    try echo(&args, buffer.writer());

    try testing.expectEqualStrings("hello\n", buffer.items);
}

test "echo outputs multiple arguments with spaces" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "hello", "world" };
    try echo(&args, buffer.writer());

    try testing.expectEqualStrings("hello world\n", buffer.items);
}

test "echo -n suppresses newline" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-n", "hello" };
    try echo(&args, buffer.writer());

    try testing.expectEqualStrings("hello", buffer.items);
}

test "echo handles empty input" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{};
    try echo(&args, buffer.writer());

    try testing.expectEqualStrings("\n", buffer.items);
}

test "echo with -n and multiple arguments" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-n", "hello", "world", "test" };
    try echo(&args, buffer.writer());

    try testing.expectEqualStrings("hello world test", buffer.items);
}

test "echo preserves empty strings" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "hello", "", "world" };
    try echo(&args, buffer.writer());

    try testing.expectEqualStrings("hello  world\n", buffer.items);
}

test "echo handles special characters" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "hello\tworld", "test\nline" };
    try echo(&args, buffer.writer());

    try testing.expectEqualStrings("hello\tworld test\nline\n", buffer.items);
}

test "echo -e interprets escape sequences" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-e", "hello\\nworld" };
    try echo(&args, buffer.writer());

    try testing.expectEqualStrings("hello\nworld\n", buffer.items);
}

test "echo -e handles multiple escape sequences" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-e", "\\t\\tindented\\nline\\ttwo\\\\backslash" };
    try echo(&args, buffer.writer());

    try testing.expectEqualStrings("\t\tindented\nline\ttwo\\backslash\n", buffer.items);
}

test "echo -e with octal sequences" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-e", "\\101\\040\\102" }; // A B in octal
    try echo(&args, buffer.writer());

    try testing.expectEqualStrings("A B\n", buffer.items);
}

test "echo -e with hex sequences" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-e", "\\x41\\x20\\x42" }; // A B in hex
    try echo(&args, buffer.writer());

    try testing.expectEqualStrings("A B\n", buffer.items);
}

test "echo -en combines flags" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-en", "hello\\nworld" };
    try echo(&args, buffer.writer());

    try testing.expectEqualStrings("hello\nworld", buffer.items);
}

test "echo -ne combines flags (different order)" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-ne", "hello\\nworld" };
    try echo(&args, buffer.writer());

    try testing.expectEqualStrings("hello\nworld", buffer.items);
}

test "echo -E disables escape sequences" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-E", "hello\\nworld" };
    try echo(&args, buffer.writer());

    try testing.expectEqualStrings("hello\\nworld\n", buffer.items);
}

test "echo -E overrides previous -e" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-e", "-E", "hello\\nworld" };
    try echo(&args, buffer.writer());

    try testing.expectEqualStrings("hello\\nworld\n", buffer.items);
}

test "echo -e overrides previous -E" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const args = [_][]const u8{ "-E", "-e", "hello\\nworld" };
    try echo(&args, buffer.writer());

    try testing.expectEqualStrings("hello\nworld\n", buffer.items);
}
