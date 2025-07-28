const std = @import("std");
const testing = std.testing;

/// Error types for argument parsing
pub const ParseError = error{
    /// Unknown flag or option
    UnknownFlag,
    /// Option requires a value but none provided
    MissingValue,
    /// Invalid value for option
    InvalidValue,
    /// Too many values for boolean flag
    TooManyValues,
    /// Out of memory
    OutOfMemory,
};

/// Result of parsing arguments
pub fn ParseResult(comptime T: type) type {
    return struct {
        /// Parsed arguments struct
        args: T,
        /// Allocator used for positionals
        allocator: std.mem.Allocator,

        const Self = @This();

        /// Clean up allocated memory
        pub fn deinit(self: *Self) void {
            // Only positionals are allocated
            if (@hasField(T, "positionals")) {
                self.allocator.free(self.args.positionals);
            }
        }
    };
}

/// Common argument parsing library
pub const Args = struct {
    /// Parse command-line arguments into a struct
    /// Zero allocations for flag/option parsing - only allocates for positionals array
    pub fn parse(comptime T: type, allocator: std.mem.Allocator) ParseError!ParseResult(T) {
        const type_info = @typeInfo(T);
        if (type_info != .@"struct") {
            @compileError("Args.parse expects a struct type");
        }

        // Initialize result with defaults
        var result: T = undefined;
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (field.default_value) |default_ptr| {
                const default = @as(*const field.type, @ptrCast(@alignCast(default_ptr))).*;
                @field(result, field.name) = default;
            } else if (field.type == []const []const u8) {
                // Special handling for positionals - will be set later
                @field(result, field.name) = &[_][]const u8{};
            } else {
                @compileError("Field '" ++ field.name ++ "' must have a default value");
            }
        }
        var positionals = std.ArrayList([]const u8).init(allocator);
        defer positionals.deinit();

        // Get raw argv from the process
        const argv = std.os.argv;
        var i: usize = 1; // Skip program name

        // Parse arguments
        while (i < argv.len) {
            const arg = std.mem.span(argv[i]);

            // Check for -- separator
            if (std.mem.eql(u8, arg, "--")) {
                i += 1;
                // Everything after -- is a positional
                while (i < argv.len) {
                    try positionals.append(std.mem.span(argv[i]));
                    i += 1;
                }
                break;
            }

            // Check if it's a flag/option
            if (arg.len > 0 and arg[0] == '-') {
                if (arg.len > 1 and arg[1] == '-') {
                    // Long option: --foo or --foo=bar
                    const option_part = arg[2..];
                    if (std.mem.indexOf(u8, option_part, "=")) |eq_pos| {
                        // --option=value syntax
                        const name = option_part[0..eq_pos];
                        const value = option_part[eq_pos + 1 ..];
                        try parseOption(T, &result, name, value);
                    } else {
                        // Check if this option needs a value
                        if (try optionNeedsValue(T, option_part)) {
                            // --option value syntax
                            i += 1;
                            if (i >= argv.len) {
                                return error.MissingValue;
                            }
                            const value = std.mem.span(argv[i]);
                            try parseOption(T, &result, option_part, value);
                        } else {
                            // Boolean flag
                            try parseFlag(T, &result, option_part);
                        }
                    }
                } else {
                    // Short option(s): -a or -abc or -o value
                    var j: usize = 1;
                    while (j < arg.len) {
                        const short_name = arg[j .. j + 1];

                        // Check if this short option needs a value
                        if (try optionNeedsValue(T, short_name)) {
                            var value: []const u8 = undefined;
                            if (j + 1 < arg.len) {
                                // -ovalue syntax
                                value = arg[j + 1 ..];
                            } else {
                                // -o value syntax
                                i += 1;
                                if (i >= argv.len) {
                                    return error.MissingValue;
                                }
                                value = std.mem.span(argv[i]);
                            }
                            try parseOption(T, &result, short_name, value);
                            break; // Consumed the rest of the arg
                        } else {
                            // Boolean flag
                            try parseFlag(T, &result, short_name);
                        }
                        j += 1;
                    }
                }
            } else {
                // Positional argument
                try positionals.append(arg);
            }

            i += 1;
        }

        // Set positionals if the struct has that field
        if (@hasField(T, "positionals")) {
            result.positionals = try positionals.toOwnedSlice();
        }

        return ParseResult(T){
            .args = result,
            .allocator = allocator,
        };
    }

    /// Parse a boolean flag
    fn parseFlag(comptime T: type, result: *T, name: []const u8) ParseError!void {
        const fields = @typeInfo(T).@"struct".fields;

        // Try to find matching field
        inline for (fields) |field| {
            if (field.type == bool) {
                // Check if field name matches
                if (std.mem.eql(u8, field.name, name)) {
                    @field(result, field.name) = true;
                    return;
                }

                // Check if field has a short name alias
                // TODO: Add support for short name mapping
            }
        }

        return error.UnknownFlag;
    }

    /// Parse an option with a value
    fn parseOption(comptime T: type, result: *T, name: []const u8, value: []const u8) ParseError!void {
        const fields = @typeInfo(T).@"struct".fields;

        inline for (fields) |field| {
            if (field.type == ?[]const u8) {
                // Optional string field
                if (std.mem.eql(u8, field.name, name)) {
                    @field(result, field.name) = value;
                    return;
                }
            }
        }

        return error.UnknownFlag;
    }

    /// Check if an option requires a value
    fn optionNeedsValue(comptime T: type, name: []const u8) ParseError!bool {
        const fields = @typeInfo(T).@"struct".fields;

        inline for (fields) |field| {
            if (std.mem.eql(u8, field.name, name)) {
                return field.type == ?[]const u8;
            }
        }

        return false; // Unknown options are assumed to be boolean flags
    }
};

// ===================== Tests =====================

test "parse boolean flags" {
    const TestArgs = struct {
        help: bool = false,
        verbose: bool = false,
        force: bool = false,
        positionals: []const []const u8,
    };

    // Simulate command line: program -h -v
    std.os.argv = @constCast(&[_][*:0]u8{
        @constCast(@ptrCast("test")),
        @constCast(@ptrCast("-h")),
        @constCast(@ptrCast("-v")),
    });

    var result = try Args.parse(TestArgs, testing.allocator);
    defer result.deinit();

    try testing.expect(result.args.help == true);
    try testing.expect(result.args.verbose == true);
    try testing.expect(result.args.force == false);
    try testing.expect(result.args.positionals.len == 0);
}

test "parse combined short flags" {
    const TestArgs = struct {
        a: bool = false,
        b: bool = false,
        c: bool = false,
        positionals: []const []const u8,
    };

    // Simulate: program -abc
    std.os.argv = @constCast(&[_][*:0]u8{
        @constCast(@ptrCast("test")),
        @constCast(@ptrCast("-abc")),
    });

    var result = try Args.parse(TestArgs, testing.allocator);
    defer result.deinit();

    try testing.expect(result.args.a == true);
    try testing.expect(result.args.b == true);
    try testing.expect(result.args.c == true);
}

test "parse string option with equals syntax" {
    const TestArgs = struct {
        output: ?[]const u8 = null,
        color: ?[]const u8 = null,
        positionals: []const []const u8,
    };

    // Simulate: program --output=file.txt --color=auto
    std.os.argv = @constCast(&[_][*:0]u8{
        @constCast(@ptrCast("test")),
        @constCast(@ptrCast("--output=file.txt")),
        @constCast(@ptrCast("--color=auto")),
    });

    var result = try Args.parse(TestArgs, testing.allocator);
    defer result.deinit();

    try testing.expect(result.args.output != null);
    try testing.expectEqualStrings("file.txt", result.args.output.?);
    try testing.expect(result.args.color != null);
    try testing.expectEqualStrings("auto", result.args.color.?);
}

test "parse string option with separate value" {
    const TestArgs = struct {
        output: ?[]const u8 = null,
        format: ?[]const u8 = null,
        positionals: []const []const u8,
    };

    // Simulate: program --output file.txt --format json
    std.os.argv = @constCast(&[_][*:0]u8{
        @constCast(@ptrCast("test")),
        @constCast(@ptrCast("--output")),
        @constCast(@ptrCast("file.txt")),
        @constCast(@ptrCast("--format")),
        @constCast(@ptrCast("json")),
    });

    var result = try Args.parse(TestArgs, testing.allocator);
    defer result.deinit();

    try testing.expectEqualStrings("file.txt", result.args.output.?);
    try testing.expectEqualStrings("json", result.args.format.?);
}

test "parse short option with value" {
    const TestArgs = struct {
        o: ?[]const u8 = null,
        f: ?[]const u8 = null,
        positionals: []const []const u8,
    };

    // Test -o value syntax
    std.os.argv = @constCast(&[_][*:0]u8{
        @constCast(@ptrCast("test")),
        @constCast(@ptrCast("-o")),
        @constCast(@ptrCast("output.txt")),
        @constCast(@ptrCast("-fformat.json")),
    });

    var result = try Args.parse(TestArgs, testing.allocator);
    defer result.deinit();

    try testing.expectEqualStrings("output.txt", result.args.o.?);
    try testing.expectEqualStrings("format.json", result.args.f.?);
}

test "parse positional arguments" {
    const TestArgs = struct {
        verbose: bool = false,
        positionals: []const []const u8,
    };

    // Simulate: program -v file1 file2 file3
    std.os.argv = @constCast(&[_][*:0]u8{
        @constCast(@ptrCast("test")),
        @constCast(@ptrCast("-v")),
        @constCast(@ptrCast("file1")),
        @constCast(@ptrCast("file2")),
        @constCast(@ptrCast("file3")),
    });

    var result = try Args.parse(TestArgs, testing.allocator);
    defer result.deinit();

    try testing.expect(result.args.verbose == true);
    try testing.expect(result.args.positionals.len == 3);
    try testing.expectEqualStrings("file1", result.args.positionals[0]);
    try testing.expectEqualStrings("file2", result.args.positionals[1]);
    try testing.expectEqualStrings("file3", result.args.positionals[2]);
}

test "parse with -- separator" {
    const TestArgs = struct {
        verbose: bool = false,
        positionals: []const []const u8,
    };

    // Simulate: program -v -- -file --with --dashes
    std.os.argv = @constCast(&[_][*:0]u8{
        @constCast(@ptrCast("test")),
        @constCast(@ptrCast("-v")),
        @constCast(@ptrCast("--")),
        @constCast(@ptrCast("-file")),
        @constCast(@ptrCast("--with")),
        @constCast(@ptrCast("--dashes")),
    });

    var result = try Args.parse(TestArgs, testing.allocator);
    defer result.deinit();

    try testing.expect(result.args.verbose == true);
    try testing.expect(result.args.positionals.len == 3);
    try testing.expectEqualStrings("-file", result.args.positionals[0]);
    try testing.expectEqualStrings("--with", result.args.positionals[1]);
    try testing.expectEqualStrings("--dashes", result.args.positionals[2]);
}

test "error on missing value for string option" {
    const TestArgs = struct {
        output: ?[]const u8 = null,
        positionals: []const []const u8,
    };

    // Simulate: program --output (missing value)
    std.os.argv = @constCast(&[_][*:0]u8{
        @constCast(@ptrCast("test")),
        @constCast(@ptrCast("--output")),
    });

    const result = Args.parse(TestArgs, testing.allocator);
    try testing.expectError(error.MissingValue, result);
}

test "error on unknown flag" {
    const TestArgs = struct {
        help: bool = false,
        positionals: []const []const u8,
    };

    // Simulate: program --unknown
    std.os.argv = @constCast(&[_][*:0]u8{
        @constCast(@ptrCast("test")),
        @constCast(@ptrCast("--unknown")),
    });

    const result = Args.parse(TestArgs, testing.allocator);
    try testing.expectError(error.UnknownFlag, result);
}

test "mixed string options and positionals" {
    const TestArgs = struct {
        verbose: bool = false,
        output: ?[]const u8 = null,
        format: ?[]const u8 = null,
        positionals: []const []const u8,
    };

    // Simulate: program -v --output=result.txt input1 --format json input2
    std.os.argv = @constCast(&[_][*:0]u8{
        @constCast(@ptrCast("test")),
        @constCast(@ptrCast("-v")),
        @constCast(@ptrCast("--output=result.txt")),
        @constCast(@ptrCast("input1")),
        @constCast(@ptrCast("--format")),
        @constCast(@ptrCast("json")),
        @constCast(@ptrCast("input2")),
    });

    var result = try Args.parse(TestArgs, testing.allocator);
    defer result.deinit();

    try testing.expect(result.args.verbose == true);
    try testing.expectEqualStrings("result.txt", result.args.output.?);
    try testing.expectEqualStrings("json", result.args.format.?);
    try testing.expect(result.args.positionals.len == 2);
    try testing.expectEqualStrings("input1", result.args.positionals[0]);
    try testing.expectEqualStrings("input2", result.args.positionals[1]);
}

test "empty option value with equals" {
    const TestArgs = struct {
        message: ?[]const u8 = null,
        positionals: []const []const u8,
    };

    // Simulate: program --message=
    std.os.argv = @constCast(&[_][*:0]u8{
        @constCast(@ptrCast("test")),
        @constCast(@ptrCast("--message=")),
    });

    var result = try Args.parse(TestArgs, testing.allocator);
    defer result.deinit();

    try testing.expect(result.args.message != null);
    try testing.expectEqualStrings("", result.args.message.?);
}

test "no positionals field" {
    const TestArgs = struct {
        verbose: bool = false,
        help: bool = false,
    };

    // Simulate: program -v file1 file2
    std.os.argv = @constCast(&[_][*:0]u8{
        @constCast(@ptrCast("test")),
        @constCast(@ptrCast("-v")),
        @constCast(@ptrCast("file1")),
        @constCast(@ptrCast("file2")),
    });

    var result = try Args.parse(TestArgs, testing.allocator);
    defer result.deinit();

    try testing.expect(result.args.verbose == true);
    // Positionals are silently ignored if field doesn't exist
}
