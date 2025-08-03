const std = @import("std");
const testing = std.testing;

/// Simple and efficient command-line argument parser for Zig.
///
/// Features:
/// - Type-safe argument parsing with compile-time validation
/// - Support for boolean flags, strings, integers, and enums
/// - Custom short flag mappings via struct metadata
/// - Automatic help text generation
/// - POSIX-style argument handling (short/long flags, combined flags, --)
///
/// Example:
/// ```zig
/// const Args = struct {
///     help: bool = false,
///     count: ?u32 = null,
///     output: ?[]const u8 = null,
///     mode: ?enum { fast, slow, auto } = null,
///     positionals: []const []const u8 = &.{},
///
///     pub const meta = .{
///         .help = .{ .short = 'h', .desc = "Show this help message" },
///         .count = .{ .short = 'c', .desc = "Number of iterations", .value_name = "N" },
///         .output = .{ .short = 'o', .desc = "Output file", .value_name = "FILE" },
///         .mode = .{ .short = 'm', .desc = "Processing mode" },
///     };
/// };
///
/// const args = try ArgParser.parse(Args, allocator, &[_][]const u8{"--count=5", "-m", "fast", "file.txt"});
/// defer allocator.free(args.positionals);
/// ```
pub const ArgParser = struct {
    pub const ParseError = error{
        UnknownFlag,
        MissingValue,
        InvalidValue,
        TooManyValues,
        OutOfMemory,
    };

    const ValueUsage = enum {
        Unknown,
        NoValue,
        ValueUsed,
    };

    /// Parse arguments from a slice of strings
    /// Returns a parsed struct with all fields populated according to the command-line arguments
    pub fn parse(comptime T: type, allocator: std.mem.Allocator, args: []const []const u8) ParseError!T {
        var result: T = .{};
        var positionals = std.ArrayList([]const u8).init(allocator);
        defer positionals.deinit();

        const type_info = @typeInfo(T);
        if (type_info != .@"struct") {
            @compileError("ArgParser.parse expects a struct type");
        }

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];

            // Handle -- separator
            if (std.mem.eql(u8, arg, "--")) {
                // Everything after -- is positional
                i += 1;
                while (i < args.len) : (i += 1) {
                    try positionals.append(args[i]);
                }
                break;
            }

            // Performance optimization: early character check
            if (arg.len > 1 and arg[0] == '-') {
                if (arg.len > 2 and arg[1] == '-') {
                    // Long flag: --flag or --flag=value
                    const flag_content = arg[2..];

                    // Check for = separator
                    if (std.mem.indexOfScalar(u8, flag_content, '=')) |eq_pos| {
                        const flag_name = flag_content[0..eq_pos];
                        const flag_value = flag_content[eq_pos + 1 ..];
                        const next_arg: ?[]const u8 = null;
                        const used = try parseLongFlagWithValue(T, &result, flag_name, flag_value, next_arg, i);
                        if (used == .Unknown) {
                            return ParseError.UnknownFlag;
                        }
                    } else {
                        // Check if next arg is the value
                        const next_arg = if (i + 1 < args.len) args[i + 1] else null;
                        const used = try parseLongFlagWithValue(T, &result, flag_content, null, next_arg, i);
                        switch (used) {
                            .Unknown => {
                                return ParseError.UnknownFlag;
                            },
                            .ValueUsed => i += 1, // Skip next arg as it was used as value
                            .NoValue => {}, // Boolean flag, no value consumed
                        }
                    }
                } else {
                    // Short flag(s): -f or -abc or -o value or -o=value
                    // Check for equals sign for short options too
                    if (std.mem.indexOfScalar(u8, arg[1..], '=')) |eq_pos| {
                        // Short flag with = syntax: -o=value
                        const flag_char = arg[1];
                        const flag_value = arg[2 + eq_pos ..];
                        const next_arg: ?[]const u8 = null;

                        const used = try parseShortFlagWithValue(T, &result, flag_char, flag_value, next_arg, i);
                        if (used == .Unknown) {
                            return ParseError.UnknownFlag;
                        }
                    } else {
                        // Combined flags or single flag with optional value
                        var j: usize = 1;
                        while (j < arg.len) : (j += 1) {
                            const flag_char = arg[j];

                            // Check if this is the last char and might have a value
                            if (j == arg.len - 1) {
                                // Check if remaining chars could be a value
                                const remaining = if (j + 1 < arg.len) arg[j + 1 ..] else null;
                                const next_arg = if (i + 1 < args.len) args[i + 1] else null;

                                const used = try parseShortFlagWithValue(T, &result, flag_char, remaining, next_arg, i);
                                switch (used) {
                                    .Unknown => {
                                        return ParseError.UnknownFlag;
                                    },
                                    .ValueUsed => {
                                        i += 1; // Skip next arg as it was used as value
                                        break;
                                    },
                                    .NoValue => {}, // Boolean flag
                                }
                            } else {
                                // Middle of combined flags, must be boolean
                                if (!try parseShortFlag(T, &result, flag_char)) {
                                    return ParseError.UnknownFlag;
                                }
                            }
                        }
                    }
                }
            } else {
                // Positional argument
                try positionals.append(arg);
            }
        }

        // Handle special field types
        inline for (type_info.@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "positionals")) {
                if (field.type == []const []const u8) {
                    const positionals_slice = try positionals.toOwnedSlice();
                    @field(result, "positionals") = positionals_slice;
                }
            }
        }

        return result;
    }

    /// Parse arguments from process.args() iterator
    pub fn parseProcess(comptime T: type, allocator: std.mem.Allocator) !T {
        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();

        var iter = try std.process.argsWithAllocator(allocator);
        defer iter.deinit();

        // Skip program name
        _ = iter.next();

        while (iter.next()) |arg| {
            try args.append(arg);
        }

        return parse(T, allocator, args.items);
    }

    /// Generate help text for the argument parser
    /// Supports custom metadata for field descriptions and short flags
    pub fn printHelp(comptime T: type, prog_name: []const u8, writer: anytype) !void {
        try writer.print("Usage: {s} [OPTIONS]", .{prog_name});

        // Check if type has positionals field
        const type_info = @typeInfo(T);
        inline for (type_info.@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "positionals")) {
                try writer.print(" [ARGS]...", .{});
            }
        }
        try writer.print("\n\n", .{});

        // Print help text if available
        if (@hasDecl(T, "help_text")) {
            try writer.print("{s}\n", .{T.help_text});
        } else {
            // Auto-generate help text from struct fields
            try writer.print("Options:\n", .{});
            inline for (type_info.@"struct".fields) |field| {
                if (comptime std.mem.eql(u8, field.name, "positionals")) continue;

                const field_type_info = @typeInfo(field.type);
                const is_supported = isSupportedFieldType(field.type);

                if (is_supported) {
                    // Get short flag from metadata or default
                    const short_flag = if (@hasDecl(T, "meta") and @hasField(@TypeOf(T.meta), field.name))
                        if (@hasField(@TypeOf(@field(T.meta, field.name)), "short"))
                            @field(T.meta, field.name).short
                        else
                            comptime getShortFlag(field.name)
                    else
                        comptime getShortFlag(field.name);

                    const long_flag = comptime getLongFlag(field.name);

                    if (short_flag != 0) {
                        try writer.print("  -{c}, --{s}", .{ short_flag, long_flag });
                    } else {
                        try writer.print("      --{s}", .{long_flag});
                    }

                    // Add value indicator based on type
                    if (field_type_info == .optional) {
                        const value_name = if (@hasDecl(T, "meta") and @hasField(@TypeOf(T.meta), field.name) and
                            @hasField(@TypeOf(@field(T.meta, field.name)), "value_name"))
                            @field(T.meta, field.name).value_name
                        else
                            getValueName(field_type_info.optional.child);
                        try writer.print("={s}", .{value_name});
                    }

                    // Add spacing for alignment
                    const current_len = if (short_flag != 0) 6 + long_flag.len else 4 + long_flag.len;
                    const value_len = if (field_type_info == .optional)
                        1 + getValueName(field_type_info.optional.child).len
                    else
                        0;
                    const padding_needed = if (current_len + value_len < 25)
                        25 - current_len - value_len
                    else
                        2;

                    var j: usize = 0;
                    while (j < padding_needed) : (j += 1) {
                        try writer.print(" ", .{});
                    }

                    // Get description from metadata or default
                    const desc = if (@hasDecl(T, "meta") and @hasField(@TypeOf(T.meta), field.name) and
                        @hasField(@TypeOf(@field(T.meta, field.name)), "desc"))
                        @field(T.meta, field.name).desc
                    else
                        comptime getDescription(field.name);
                    try writer.print("{s}\n", .{desc});
                }
            }
        }
    }

    fn parseLongFlag(comptime T: type, obj: *T, flag_name: []const u8) !bool {
        const type_info = @typeInfo(T);
        inline for (type_info.@"struct".fields) |field| {
            if (field.type == bool) {
                // Check if flag matches field name
                if (std.mem.eql(u8, field.name, flag_name)) {
                    @field(obj, field.name) = true;
                    return true;
                }

                // Check if flag matches long flag format
                const long_flag = comptime getLongFlag(field.name);
                if (std.mem.eql(u8, long_flag, flag_name)) {
                    @field(obj, field.name) = true;
                    return true;
                }
            }
        }
        return false;
    }

    fn parseLongFlagWithValue(comptime T: type, obj: *T, flag_name: []const u8, provided_value: ?[]const u8, next_arg: ?[]const u8, position: usize) !ValueUsage {
        const type_info = @typeInfo(T);
        inline for (type_info.@"struct".fields) |field| {
            // Check if field name or converted name matches
            const long_flag = comptime getLongFlag(field.name);
            const matches = std.mem.eql(u8, field.name, flag_name) or std.mem.eql(u8, long_flag, flag_name);

            if (matches) {
                // Check field type
                const field_type_info = @typeInfo(field.type);
                if (field.type == bool) {
                    // Boolean flag
                    if (provided_value != null) {
                        return ParseError.TooManyValues;
                    }
                    @field(obj, field.name) = true;
                    return .NoValue;
                } else if (field_type_info == .optional) {
                    // Optional field - parse based on child type
                    const value_str = provided_value orelse next_arg orelse {
                        return ParseError.MissingValue;
                    };

                    try parseValue(field_type_info.optional.child, &@field(obj, field.name), value_str, flag_name, position);
                    return if (provided_value != null) .NoValue else .ValueUsed;
                }
            }
        }
        return .Unknown;
    }

    fn parseShortFlagWithValue(comptime T: type, obj: *T, flag_char: u8, provided_value: ?[]const u8, next_arg: ?[]const u8, position: usize) !ValueUsage {
        const type_info = @typeInfo(T);
        inline for (type_info.@"struct".fields) |field| {
            // Check metadata first, then default
            const short_flag = if (@hasDecl(T, "meta") and @hasField(@TypeOf(T.meta), field.name) and
                @hasField(@TypeOf(@field(T.meta, field.name)), "short"))
                @field(T.meta, field.name).short
            else
                comptime getShortFlag(field.name);

            if (short_flag == flag_char) {
                // Check field type
                const field_type_info = @typeInfo(field.type);
                if (field.type == bool) {
                    // Boolean flag
                    if (provided_value != null) {
                        return ParseError.TooManyValues;
                    }
                    @field(obj, field.name) = true;
                    return .NoValue;
                } else if (field_type_info == .optional) {
                    // Optional field - parse based on child type
                    const value_str = provided_value orelse next_arg orelse {
                        return ParseError.MissingValue;
                    };

                    try parseValue(field_type_info.optional.child, &@field(obj, field.name), value_str, field.name, position);
                    return if (provided_value != null) .NoValue else .ValueUsed;
                }
            }
        }
        return .Unknown;
    }

    fn parseShortFlag(comptime T: type, obj: *T, flag: u8) !bool {
        const type_info = @typeInfo(T);
        inline for (type_info.@"struct".fields) |field| {
            if (field.type == bool) {
                const short_flag = if (@hasDecl(T, "meta") and @hasField(@TypeOf(T.meta), field.name) and
                    @hasField(@TypeOf(@field(T.meta, field.name)), "short"))
                    @field(T.meta, field.name).short
                else
                    comptime getShortFlag(field.name);

                if (short_flag == flag) {
                    @field(obj, field.name) = true;
                    return true;
                }
            }
        }
        return false;
    }

    fn getShortFlag(comptime name: []const u8) u8 {
        // Common mappings
        if (comptime std.mem.eql(u8, name, "help")) return 'h';
        if (comptime std.mem.eql(u8, name, "version")) return 'V';
        if (comptime std.mem.eql(u8, name, "verbose")) return 'v';
        if (comptime std.mem.eql(u8, name, "suppress_newline")) return 'n';
        if (comptime std.mem.eql(u8, name, "number")) return 'n';
        if (comptime std.mem.eql(u8, name, "all")) return 'a';
        if (comptime std.mem.eql(u8, name, "long")) return 'l';
        if (comptime std.mem.eql(u8, name, "recursive")) return 'r';
        if (comptime std.mem.eql(u8, name, "force")) return 'f';
        if (comptime std.mem.eql(u8, name, "quiet")) return 'q';
        if (comptime std.mem.eql(u8, name, "output")) return 'o';
        if (comptime std.mem.eql(u8, name, "input")) return 'i';
        if (comptime std.mem.eql(u8, name, "color")) return 'c';

        // Default: use first character if single word
        if (comptime std.mem.indexOfScalar(u8, name, '_') == null and name.len > 0) {
            return name[0];
        }

        return 0; // No short flag
    }

    fn getLongFlag(comptime name: []const u8) []const u8 {
        // Convert underscores to hyphens at compile time
        comptime {
            var has_underscore = false;
            for (name) |c| {
                if (c == '_') {
                    has_underscore = true;
                    break;
                }
            }

            if (!has_underscore) {
                return name;
            }

            // Create compile-time string with underscores replaced by hyphens
            var result: [name.len]u8 = undefined;
            for (name, 0..) |c, i| {
                result[i] = if (c == '_') '-' else c;
            }
            const final = result;
            return &final;
        }
    }

    fn getDescription(comptime name: []const u8) []const u8 {
        // Common descriptions
        if (comptime std.mem.eql(u8, name, "help")) return "Display this help and exit";
        if (comptime std.mem.eql(u8, name, "version")) return "Output version information and exit";
        if (comptime std.mem.eql(u8, name, "verbose")) return "Enable verbose output";
        if (comptime std.mem.eql(u8, name, "suppress_newline")) return "Do not output the trailing newline";
        if (comptime std.mem.eql(u8, name, "number")) return "Number all output lines";
        if (comptime std.mem.eql(u8, name, "all")) return "Show all entries";
        if (comptime std.mem.eql(u8, name, "long")) return "Use long listing format";
        if (comptime std.mem.eql(u8, name, "recursive")) return "Process directories recursively";
        if (comptime std.mem.eql(u8, name, "force")) return "Force operation without prompting";
        if (comptime std.mem.eql(u8, name, "quiet")) return "Suppress normal output";

        // Default: convert field_name to "Enable field name"
        return "Enable " ++ name;
    }

    /// Parse a value string into the appropriate type
    fn parseValue(comptime T: type, dest: *?T, value_str: []const u8, flag_name: []const u8, position: usize) !void {
        _ = flag_name;
        _ = position;
        const type_info = @typeInfo(T);

        if (type_info == .pointer and type_info.pointer.child == u8) {
            // String type
            dest.* = value_str;
        } else if (type_info == .int) {
            // Integer types
            dest.* = std.fmt.parseInt(T, value_str, 10) catch {
                return ParseError.InvalidValue;
            };
        } else if (type_info == .float) {
            // Float types
            dest.* = std.fmt.parseFloat(T, value_str) catch {
                return ParseError.InvalidValue;
            };
        } else if (type_info == .@"enum") {
            // Enum types
            dest.* = std.meta.stringToEnum(T, value_str) orelse {
                return ParseError.InvalidValue;
            };
        } else {
            @compileError("Unsupported field type: " ++ @typeName(T));
        }
    }

    /// Check if a type is supported for argument parsing
    fn isSupportedFieldType(comptime T: type) bool {
        const type_info = @typeInfo(T);

        if (T == bool) return true;

        if (type_info == .optional) {
            const child_type = type_info.optional.child;
            const child_info = @typeInfo(child_type);

            // String
            if (child_info == .pointer and child_info.pointer.child == u8) return true;
            // Integer
            if (child_info == .int) return true;
            // Float
            if (child_info == .float) return true;
            // Enum
            if (child_info == .@"enum") return true;
        }

        return false;
    }

    /// Get a display name for value placeholders in help text
    fn getValueName(comptime T: type) []const u8 {
        const type_info = @typeInfo(T);

        if (type_info == .pointer and type_info.pointer.child == u8) {
            return "VALUE";
        } else if (type_info == .int) {
            if (type_info.int.signedness == .unsigned) {
                return "N";
            } else {
                return "NUM";
            }
        } else if (type_info == .float) {
            return "FLOAT";
        } else if (type_info == .@"enum") {
            // For enums, just return a generic placeholder
            // The actual enum values will be shown in the description
            return "CHOICE";
        }

        return "VALUE";
    }
};

// Tests
test "parse boolean flags" {
    const TestArgs = struct {
        help: bool = false,
        version: bool = false,
        verbose: bool = false,
    };

    // Test short flags
    {
        const args = [_][]const u8{ "-h", "-v" };
        const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
        try testing.expect(result.help == true);
        try testing.expect(result.verbose == true);
        try testing.expect(result.version == false);
    }

    // Test long flags
    {
        const args = [_][]const u8{ "--help", "--version" };
        const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
        try testing.expect(result.help == true);
        try testing.expect(result.version == true);
        try testing.expect(result.verbose == false);
    }

    // Test combined short flags
    {
        const args = [_][]const u8{"-hVv"};
        const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
        try testing.expect(result.help == true);
        try testing.expect(result.version == true);
        try testing.expect(result.verbose == true);
    }
}

test "parse with positionals" {
    const TestArgs = struct {
        help: bool = false,
        positionals: []const []const u8 = &.{},
    };

    const args = [_][]const u8{ "-h", "file1", "file2" };
    const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
    defer testing.allocator.free(result.positionals);

    try testing.expect(result.help == true);
    try testing.expectEqual(@as(usize, 2), result.positionals.len);
    try testing.expectEqualStrings("file1", result.positionals[0]);
    try testing.expectEqualStrings("file2", result.positionals[1]);
}

test "unknown flag error" {
    const TestArgs = struct {
        help: bool = false,
    };

    const args = [_][]const u8{"--unknown"};
    const result = ArgParser.parse(TestArgs, testing.allocator, &args);
    try testing.expectError(ArgParser.ParseError.UnknownFlag, result);
}

test "underscore to hyphen conversion" {
    const TestArgs = struct {
        suppress_newline: bool = false,
        show_all: bool = false,
    };

    // Test that underscores in field names are converted to hyphens
    const args = [_][]const u8{ "--suppress-newline", "--show-all" };
    const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
    try testing.expect(result.suppress_newline == true);
    try testing.expect(result.show_all == true);
}

test "print help" {
    const TestArgs = struct {
        help: bool = false,
        version: bool = false,
        suppress_newline: bool = false,
        positionals: []const []const u8 = &.{},

        pub const help_text =
            \\-h, --help     Display this help and exit.
            \\-V, --version  Output version information and exit.
            \\-n             Do not output the trailing newline.
            \\<str>...       Text to echo.
        ;
    };

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try ArgParser.printHelp(TestArgs, "echo", buffer.writer());
    const output = buffer.items;

    // Check for expected content
    try testing.expect(std.mem.indexOf(u8, output, "Usage: echo") != null);
    try testing.expect(std.mem.indexOf(u8, output, "[OPTIONS]") != null);
    try testing.expect(std.mem.indexOf(u8, output, "[ARGS]...") != null);
    try testing.expect(std.mem.indexOf(u8, output, "-h, --help") != null);
}

test "auto-generated help" {
    const TestArgs = struct {
        help: bool = false,
        verbose: bool = false,
        all: bool = false,
    };

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try ArgParser.printHelp(TestArgs, "test", buffer.writer());
    const output = buffer.items;

    // Check auto-generated content
    try testing.expect(std.mem.indexOf(u8, output, "-h, --help") != null);
    try testing.expect(std.mem.indexOf(u8, output, "-v, --verbose") != null);
    try testing.expect(std.mem.indexOf(u8, output, "-a, --all") != null);
}

test "mixed flags and positionals" {
    const TestArgs = struct {
        verbose: bool = false,
        force: bool = false,
        positionals: []const []const u8 = &.{},
    };

    const args = [_][]const u8{ "-v", "file1", "--force", "file2", "-v" };
    const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
    defer testing.allocator.free(result.positionals);

    try testing.expect(result.verbose == true);
    try testing.expect(result.force == true);
    try testing.expectEqual(@as(usize, 2), result.positionals.len);
    try testing.expectEqualStrings("file1", result.positionals[0]);
    try testing.expectEqualStrings("file2", result.positionals[1]);
}

test "empty arguments" {
    const TestArgs = struct {
        help: bool = false,
    };

    const args = [_][]const u8{};
    const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
    try testing.expect(result.help == false);
}

test "dash by itself is positional" {
    const TestArgs = struct {
        positionals: []const []const u8 = &.{},
    };

    const args = [_][]const u8{"-"};
    const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
    defer testing.allocator.free(result.positionals);

    try testing.expectEqual(@as(usize, 1), result.positionals.len);
    try testing.expectEqualStrings("-", result.positionals[0]);
}

// Phase 2 tests: String option parsing
test "string option with equals syntax" {
    const TestArgs = struct {
        output: ?[]const u8 = null,
        color: ?[]const u8 = null,
        verbose: bool = false,
    };

    const args = [_][]const u8{ "--output=file.txt", "--color=auto", "-v" };
    const result = try ArgParser.parse(TestArgs, testing.allocator, &args);

    try testing.expect(result.verbose == true);
    try testing.expect(result.output != null);
    try testing.expectEqualStrings("file.txt", result.output.?);
    try testing.expect(result.color != null);
    try testing.expectEqualStrings("auto", result.color.?);
}

test "string option with separate value" {
    const TestArgs = struct {
        output: ?[]const u8 = null,
        input: ?[]const u8 = null,
    };

    const args = [_][]const u8{ "--output", "out.txt", "--input", "in.txt" };
    const result = try ArgParser.parse(TestArgs, testing.allocator, &args);

    try testing.expect(result.output != null);
    try testing.expectEqualStrings("out.txt", result.output.?);
    try testing.expect(result.input != null);
    try testing.expectEqualStrings("in.txt", result.input.?);
}

test "short option with value" {
    const TestArgs = struct {
        output: ?[]const u8 = null,
        verbose: bool = false,
    };

    const args = [_][]const u8{ "-o", "file.txt", "-v" };
    const result = try ArgParser.parse(TestArgs, testing.allocator, &args);

    try testing.expect(result.output != null);
    try testing.expectEqualStrings("file.txt", result.output.?);
    try testing.expect(result.verbose == true);
}

test "missing value error" {
    const TestArgs = struct {
        output: ?[]const u8 = null,
    };

    const args = [_][]const u8{"--output"};
    const result = ArgParser.parse(TestArgs, testing.allocator, &args);
    try testing.expectError(ArgParser.ParseError.MissingValue, result);
}

test "double dash separator" {
    const TestArgs = struct {
        verbose: bool = false,
        positionals: []const []const u8 = &.{},
    };

    const args = [_][]const u8{ "-v", "--", "--not-a-flag", "-also-not" };
    const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
    defer testing.allocator.free(result.positionals);

    try testing.expect(result.verbose == true);
    try testing.expectEqual(@as(usize, 2), result.positionals.len);
    try testing.expectEqualStrings("--not-a-flag", result.positionals[0]);
    try testing.expectEqualStrings("-also-not", result.positionals[1]);
}

test "mixed string options and positionals" {
    const TestArgs = struct {
        output: ?[]const u8 = null,
        verbose: bool = false,
        positionals: []const []const u8 = &.{},
    };

    const args = [_][]const u8{ "-v", "file1", "--output=out.txt", "file2", "file3" };
    const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
    defer testing.allocator.free(result.positionals);

    try testing.expect(result.verbose == true);
    try testing.expect(result.output != null);
    try testing.expectEqualStrings("out.txt", result.output.?);
    try testing.expectEqual(@as(usize, 3), result.positionals.len);
    try testing.expectEqualStrings("file1", result.positionals[0]);
    try testing.expectEqualStrings("file2", result.positionals[1]);
    try testing.expectEqualStrings("file3", result.positionals[2]);
}

test "empty string value" {
    const TestArgs = struct {
        output: ?[]const u8 = null,
    };

    const args = [_][]const u8{"--output="};
    const result = try ArgParser.parse(TestArgs, testing.allocator, &args);

    // Empty string is a valid value
    try testing.expect(result.output != null);
    try testing.expectEqualStrings("", result.output.?);
}

test "string option help generation" {
    const TestArgs = struct {
        output: ?[]const u8 = null,
        color: ?[]const u8 = null,
        verbose: bool = false,
    };

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try ArgParser.printHelp(TestArgs, "test", buffer.writer());
    const output = buffer.items;

    // Check that string options show VALUE indicator
    try testing.expect(std.mem.indexOf(u8, output, "--output=VALUE") != null);
    try testing.expect(std.mem.indexOf(u8, output, "--color=VALUE") != null);
    try testing.expect(std.mem.indexOf(u8, output, "-v, --verbose") != null);
}

test "argv compatibility helpers" {
    const TestArgs = struct {
        help: bool = false,
        output: ?[]const u8 = null,
        positionals: []const []const u8 = &.{},
    };

    // Test with direct array (simulating parseArgv behavior)
    const args = [_][]const u8{ "--help", "--output=test.txt", "file1" };
    const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
    defer testing.allocator.free(result.positionals);

    try testing.expect(result.help == true);
    try testing.expect(result.output != null);
    try testing.expectEqualStrings("test.txt", result.output.?);
    try testing.expectEqual(@as(usize, 1), result.positionals.len);
    try testing.expectEqualStrings("file1", result.positionals[0]);
}

// Extended type support tests
test "integer parsing" {
    const TestArgs = struct {
        count: ?u32 = null,
        offset: ?i64 = null,
        verbose: bool = false,
    };

    // Test unsigned integer
    {
        const args = [_][]const u8{ "--count=42", "-v" };
        const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
        try testing.expect(result.count != null);
        try testing.expectEqual(@as(u32, 42), result.count.?);
        try testing.expect(result.verbose == true);
    }

    // Test signed integer with negative value
    {
        const args = [_][]const u8{"--offset=-100"};
        const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
        try testing.expect(result.offset != null);
        try testing.expectEqual(@as(i64, -100), result.offset.?);
    }

    // Test integer with separate value
    {
        const args = [_][]const u8{ "--count", "999" };
        const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
        try testing.expect(result.count != null);
        try testing.expectEqual(@as(u32, 999), result.count.?);
    }
}

test "invalid integer parsing" {
    const TestArgs = struct {
        count: ?u32 = null,
    };

    // Test invalid integer
    {
        const args = [_][]const u8{"--count=abc"};
        const result = ArgParser.parse(TestArgs, testing.allocator, &args);
        try testing.expectError(ArgParser.ParseError.InvalidValue, result);
    }

    // Test overflow
    {
        const args = [_][]const u8{"--count=999999999999999999999"};
        const result = ArgParser.parse(TestArgs, testing.allocator, &args);
        try testing.expectError(ArgParser.ParseError.InvalidValue, result);
    }

    // Test negative for unsigned
    {
        const args = [_][]const u8{"--count=-5"};
        const result = ArgParser.parse(TestArgs, testing.allocator, &args);
        try testing.expectError(ArgParser.ParseError.InvalidValue, result);
    }
}

test "enum parsing" {
    const TestArgs = struct {
        mode: ?enum { fast, slow, auto } = null,
        color: ?enum { always, never, auto } = null,
    };

    // Test valid enum values
    {
        const args = [_][]const u8{ "--mode=fast", "--color=auto" };
        const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
        try testing.expect(result.mode != null);
        try testing.expectEqual(.fast, result.mode.?);
        try testing.expect(result.color != null);
        try testing.expectEqual(.auto, result.color.?);
    }

    // Test enum with separate value
    {
        const args = [_][]const u8{ "--mode", "slow" };
        const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
        try testing.expect(result.mode != null);
        try testing.expectEqual(.slow, result.mode.?);
    }
}

test "invalid enum parsing" {
    const TestArgs = struct {
        mode: ?enum { fast, slow, auto } = null,
    };

    const args = [_][]const u8{"--mode=invalid"};
    const result = ArgParser.parse(TestArgs, testing.allocator, &args);
    try testing.expectError(ArgParser.ParseError.InvalidValue, result);
}

test "custom metadata" {
    const TestArgs = struct {
        help: bool = false,
        count: ?u32 = null,
        output: ?[]const u8 = null,
        mode: ?enum { fast, slow } = null,

        pub const meta = .{
            .help = .{ .short = '?', .desc = "Show usage information" },
            .count = .{ .short = 'n', .desc = "Number of items", .value_name = "NUM" },
            .output = .{ .short = 'o', .desc = "Output file path", .value_name = "FILE" },
            .mode = .{ .short = 'm', .desc = "Processing mode" },
        };
    };

    // Test custom short flags
    {
        const args = [_][]const u8{ "-?", "-n", "10", "-o=out.txt", "-m", "fast" };
        const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
        try testing.expect(result.help == true);
        try testing.expect(result.count != null);
        try testing.expectEqual(@as(u32, 10), result.count.?);
        try testing.expect(result.output != null);
        try testing.expectEqualStrings("out.txt", result.output.?);
        try testing.expect(result.mode != null);
        try testing.expectEqual(.fast, result.mode.?);
    }

    // Test help generation with custom metadata
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try ArgParser.printHelp(TestArgs, "test", buffer.writer());
    const output = buffer.items;

    // Check custom descriptions
    try testing.expect(std.mem.indexOf(u8, output, "Show usage information") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Number of items") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Output file path") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Processing mode") != null);

    // Check custom short flags
    try testing.expect(std.mem.indexOf(u8, output, "-?, --help") != null);
    try testing.expect(std.mem.indexOf(u8, output, "-n, --count=NUM") != null);
    try testing.expect(std.mem.indexOf(u8, output, "-o, --output=FILE") != null);
    try testing.expect(std.mem.indexOf(u8, output, "-m, --mode=CHOICE") != null);
}

test "mixed types complex scenario" {
    const TestArgs = struct {
        verbose: bool = false,
        debug: bool = false,
        threads: ?u8 = null,
        timeout: ?f32 = null,
        mode: ?enum { sequential, parallel, auto } = null,
        output: ?[]const u8 = null,
        positionals: []const []const u8 = &.{},
    };

    const args = [_][]const u8{
        "-v",
        "--threads=4",
        "input1.txt",
        "--mode",
        "parallel",
        "--timeout=2.5",
        "--debug",
        "input2.txt",
        "--output=result.txt",
        "input3.txt",
    };

    const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
    defer testing.allocator.free(result.positionals);

    try testing.expect(result.verbose == true);
    try testing.expect(result.debug == true);
    try testing.expect(result.threads != null);
    try testing.expectEqual(@as(u8, 4), result.threads.?);
    try testing.expect(result.timeout != null);
    try testing.expectApproxEqAbs(@as(f32, 2.5), result.timeout.?, 0.001);
    try testing.expect(result.mode != null);
    try testing.expectEqual(.parallel, result.mode.?);
    try testing.expect(result.output != null);
    try testing.expectEqualStrings("result.txt", result.output.?);
    try testing.expectEqual(@as(usize, 3), result.positionals.len);
    try testing.expectEqualStrings("input1.txt", result.positionals[0]);
    try testing.expectEqualStrings("input2.txt", result.positionals[1]);
    try testing.expectEqualStrings("input3.txt", result.positionals[2]);
}

// Edge case tests
test "unicode in arguments" {
    const TestArgs = struct {
        message: ?[]const u8 = null,
        positionals: []const []const u8 = &.{},
    };

    const args = [_][]const u8{ "--message=Hello 世界! 🌍", "файл.txt", "文件.txt" };
    const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
    defer testing.allocator.free(result.positionals);

    try testing.expect(result.message != null);
    try testing.expectEqualStrings("Hello 世界! 🌍", result.message.?);
    try testing.expectEqual(@as(usize, 2), result.positionals.len);
    try testing.expectEqualStrings("файл.txt", result.positionals[0]);
    try testing.expectEqualStrings("文件.txt", result.positionals[1]);
}

test "very long argument strings" {
    const TestArgs = struct {
        path: ?[]const u8 = null,
    };

    const long_path = "a" ** 500; // 500 character path
    const args = [_][]const u8{"--path=" ++ long_path};
    const result = try ArgParser.parse(TestArgs, testing.allocator, &args);

    try testing.expect(result.path != null);
    try testing.expectEqual(@as(usize, 500), result.path.?.len);
    try testing.expectEqualStrings(long_path, result.path.?);
}

test "special characters in values" {
    const TestArgs = struct {
        regex: ?[]const u8 = null,
        separator: ?[]const u8 = null,
    };

    const args = [_][]const u8{ "--regex=^[a-z]+\\d*$", "--separator=|>&<" };
    const result = try ArgParser.parse(TestArgs, testing.allocator, &args);

    try testing.expect(result.regex != null);
    try testing.expectEqualStrings("^[a-z]+\\d*$", result.regex.?);
    try testing.expect(result.separator != null);
    try testing.expectEqualStrings("|>&<", result.separator.?);
}

test "invalid short flag in combined flags" {
    const TestArgs = struct {
        verbose: bool = false,
        debug: bool = false,
    };

    // 'x' is not a valid flag
    const args = [_][]const u8{"-vxd"};
    const result = ArgParser.parse(TestArgs, testing.allocator, &args);
    try testing.expectError(ArgParser.ParseError.UnknownFlag, result);
}

test "float parsing" {
    const TestArgs = struct {
        rate: ?f32 = null,
        precision: ?f64 = null,
    };

    // Test float values
    {
        const args = [_][]const u8{ "--rate=3.14159", "--precision=2.71828182845904523536" };
        const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
        try testing.expect(result.rate != null);
        try testing.expectApproxEqAbs(@as(f32, 3.14159), result.rate.?, 0.00001);
        try testing.expect(result.precision != null);
        try testing.expectApproxEqAbs(@as(f64, 2.71828182845904523536), result.precision.?, 0.0000000000001);
    }

    // Test scientific notation
    {
        const args = [_][]const u8{"--rate=1.23e-4"};
        const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
        try testing.expect(result.rate != null);
        try testing.expectApproxEqAbs(@as(f32, 0.000123), result.rate.?, 0.000001);
    }
}

test "help text for all types" {
    const TestArgs = struct {
        verbose: bool = false,
        count: ?u32 = null,
        rate: ?f32 = null,
        mode: ?enum { fast, slow, auto } = null,
        output: ?[]const u8 = null,

        pub const meta = .{
            .verbose = .{ .short = 'v', .desc = "Enable verbose output" },
            .count = .{ .short = 'c', .desc = "Number of iterations" },
            .rate = .{ .short = 'r', .desc = "Sample rate", .value_name = "HZ" },
            .mode = .{ .short = 'm', .desc = "Processing mode" },
            .output = .{ .short = 'o', .desc = "Output file" },
        };
    };

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try ArgParser.printHelp(TestArgs, "test", buffer.writer());
    const output = buffer.items;

    // Check all types are properly displayed
    try testing.expect(std.mem.indexOf(u8, output, "-v, --verbose") != null);
    try testing.expect(std.mem.indexOf(u8, output, "-c, --count=N") != null);
    try testing.expect(std.mem.indexOf(u8, output, "-r, --rate=HZ") != null);
    try testing.expect(std.mem.indexOf(u8, output, "-m, --mode=CHOICE") != null);
    try testing.expect(std.mem.indexOf(u8, output, "-o, --output=VALUE") != null);
}
