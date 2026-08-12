const std = @import("std");
const testing = std.testing;

/// Simple and efficient command-line argument parser for Zig.
///
/// Features:
/// - Type-safe argument parsing with compile-time validation
/// - Support for boolean flags, strings, integers, and enums
/// - Custom short flag mappings via struct metadata
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
/// const args = try ArgParser.parse(
///     Args,
///     allocator,
///     &[_][]const u8{ "--count=5", "-m", "fast", "file.txt" },
/// );
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
    pub fn parse(
        comptime T: type,
        allocator: std.mem.Allocator,
        args: []const []const u8,
    ) ParseError!T {
        var result: T = .{};
        var positionals = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        defer positionals.deinit(allocator);

        const type_info = @typeInfo(T);
        if (type_info != .@"struct") {
            @compileError("ArgParser.parse expects a struct type");
        }

        var i: usize = 0; // tiger:allow:usize-arch slice index into args
        while (i < args.len) : (i += 1) {
            const arg = args[i];

            // Handle -- separator
            if (std.mem.eql(u8, arg, "--")) {
                // Everything after -- is positional
                i += 1;
                std.debug.assert(i <= args.len);
                try parse_drainPositionals(allocator, &positionals, args, i);
                break;
            }

            // Performance optimization: early character check
            if (arg.len > 1 and arg[0] == '-') {
                if (arg.len > 2 and arg[1] == '-') {
                    // Long flag: --flag or --flag=value
                    const used = try parse_handleLongFlag(T, &result, arg, args, i);
                    switch (used) {
                        .Unknown => {
                            return ParseError.UnknownFlag;
                        },
                        .ValueUsed => i += 1, // Skip next arg as it was used as value
                        .NoValue => {}, // Boolean flag, no value consumed
                    }
                } else {
                    // Short flag(s): -f or -abc or -o value or -o=value
                    const used = try parse_handleShortCluster(T, &result, arg, args, i);
                    switch (used) {
                        .Unknown => {
                            return ParseError.UnknownFlag;
                        },
                        .ValueUsed => i += 1, // Skip next arg as it was used as value
                        .NoValue => {}, // Boolean flag, no value consumed
                    }
                }
            } else {
                // Positional argument
                try positionals.append(allocator, arg);
            }
        }

        try parse_assignPositionalsField(T, &result, &positionals, allocator);

        return result;
    }

    /// Drain every remaining arg (from `start`) into `positionals`. The caller
    /// owns the `--` detection and the loop `break`; this helper holds only the
    /// straight-line drain loop ("push fors down").
    fn parse_drainPositionals(
        allocator: std.mem.Allocator,
        positionals: *std.ArrayList([]const u8),
        args: []const []const u8,
        start: usize, // tiger:allow:usize-arch slice index into args
    ) ParseError!void {
        std.debug.assert(start <= args.len);

        var k: usize = start; // tiger:allow:usize-arch slice index into args
        while (k < args.len) : (k += 1) {
            try positionals.append(allocator, args[k]);
        }
    }

    /// Resolve a long flag (`--flag` or `--flag=value`) into a ValueUsage. Does
    /// NOT mutate `i`; the caller's switch advances the index. The `=value` form
    /// maps its UnknownFlag to `.Unknown` so the caller's single switch handles
    /// both forms uniformly.
    fn parse_handleLongFlag(
        comptime T: type,
        result: *T,
        arg: []const u8,
        args: []const []const u8,
        i: usize, // tiger:allow:usize-arch slice index into args
    ) ParseError!ValueUsage {
        std.debug.assert(arg.len > 2);
        std.debug.assert(arg[0] == '-');
        std.debug.assert(arg[1] == '-');

        // Long flag: --flag or --flag=value
        const flag_content = arg[2..];

        // Check for = separator
        if (std.mem.findScalar(u8, flag_content, '=')) |eq_pos| {
            std.debug.assert(eq_pos < flag_content.len);
            std.debug.assert(eq_pos + 1 <= flag_content.len);
            const flag_name = flag_content[0..eq_pos];
            const flag_value = flag_content[eq_pos + 1 ..];
            const next_arg: ?[]const u8 = null;
            const used = try parseLongFlagWithValue(T, result, flag_name, flag_value, next_arg, i);
            if (used == .Unknown) {
                return .Unknown;
            }
            return .NoValue;
        } else {
            // Check if next arg is the value
            const next_arg = if (i + 1 < args.len) args[i + 1] else null;
            return try parseLongFlagWithValue(T, result, flag_content, null, next_arg, i);
        }
    }

    /// Resolve a short-flag cluster (`-f`, `-abc`, `-o value`, `-o=value`) into a
    /// single ValueUsage describing whether the NEXT arg was consumed. The inner
    /// combined-flags loop lives here ("push fors down"); the caller keeps the
    /// outer switch that advances `i` or reports UnknownFlag.
    fn parse_handleShortCluster(
        comptime T: type,
        result: *T,
        arg: []const u8,
        args: []const []const u8,
        i: usize, // tiger:allow:usize-arch slice index into args
    ) ParseError!ValueUsage {
        std.debug.assert(arg.len > 1);
        std.debug.assert(arg[0] == '-');

        // Check for equals sign for short options too
        if (std.mem.findScalar(u8, arg[1..], '=')) |eq_pos| {
            std.debug.assert(eq_pos < arg.len - 1);
            std.debug.assert(2 + eq_pos <= arg.len);
            // Short flag with = syntax: -o=value
            const flag_char = arg[1];
            const flag_value = arg[2 + eq_pos ..];
            const next_arg: ?[]const u8 = null;

            const used = try parseShortFlagWithValue(T, result, flag_char, flag_value, next_arg, i);
            if (used == .Unknown) {
                return .Unknown;
            }
            return .NoValue;
        } else {
            // Combined flags or single flag with optional value
            return try parse_handleShortCluster_combined(T, result, arg, args, i);
        }
    }

    /// Walk a combined short-flag cluster (`-abc`, `-dVALUE`) one char at a time,
    /// returning a single ValueUsage for the whole cluster. Middle chars must be
    /// boolean flags (or value-taking flags that swallow the remainder); only the
    /// last char may consume the next arg. Split out of parse_handleShortCluster
    /// to keep that function under the 70-line limit ("push fors down").
    fn parse_handleShortCluster_combined(
        comptime T: type,
        result: *T,
        arg: []const u8,
        args: []const []const u8,
        i: usize, // tiger:allow:usize-arch slice index into args
    ) ParseError!ValueUsage {
        std.debug.assert(arg.len > 1);
        std.debug.assert(arg[0] == '-');

        var j: usize = 1; // tiger:allow:usize-arch slice index into arg
        while (j < arg.len) : (j += 1) {
            std.debug.assert(j >= 1);
            std.debug.assert(j < arg.len);
            const flag_char = arg[j];

            // Check if this is the last char and might have a value
            if (j == arg.len - 1) {
                // Check if remaining chars could be a value
                const remaining = if (j + 1 < arg.len) arg[j + 1 ..] else null;
                const next_arg = if (i + 1 < args.len) args[i + 1] else null;

                const used = try parseShortFlagWithValue(
                    T,
                    result,
                    flag_char,
                    remaining,
                    next_arg,
                    i,
                );
                switch (used) {
                    .Unknown => {
                        return .Unknown;
                    },
                    .ValueUsed => {
                        return .ValueUsed; // Skip next arg as it was used as value
                    },
                    .NoValue => {}, // Boolean flag
                }
            } else {
                // Middle of combined flags - try boolean first
                if (!try parseShortFlag(T, result, flag_char)) {
                    // Not a boolean flag; try as a value-taking flag
                    // with remaining chars as the value (POSIX: -dVALUE)
                    const remaining = arg[j + 1 ..];
                    const used = try parseShortFlagWithValue(
                        T,
                        result,
                        flag_char,
                        remaining,
                        null,
                        i,
                    );
                    switch (used) {
                        .Unknown => {
                            return .Unknown;
                        },
                        .NoValue, .ValueUsed => {
                            return .NoValue; // consumed rest of arg
                        },
                    }
                }
            }
        }
        return .NoValue;
    }

    /// Assign collected positionals to a `positionals: []const []const u8` field
    /// when `T` declares one, transferring ownership via `toOwnedSlice`.
    fn parse_assignPositionalsField(
        comptime T: type,
        result: *T,
        positionals: *std.ArrayList([]const u8),
        allocator: std.mem.Allocator,
    ) ParseError!void {
        const type_info = @typeInfo(T);

        // Handle special field types
        inline for (type_info.@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "positionals")) {
                if (field.type == []const []const u8) {
                    const positionals_slice = try positionals.toOwnedSlice(allocator);
                    @field(result, "positionals") = positionals_slice;
                }
            }
        }
    }

    /// Parse arguments from process args.
    /// Deprecated: pass args explicitly via parse() instead.
    pub fn parseProcess(comptime T: type, allocator: std.mem.Allocator) !T {
        _ = allocator;
        @compileError("parseProcess is removed in 0.16; " ++
            "pass args slice explicitly via ArgParser.parse()");
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

    fn parseLongFlagWithValue(
        comptime T: type,
        obj: *T,
        flag_name: []const u8,
        provided_value: ?[]const u8,
        next_arg: ?[]const u8,
        position: usize, // tiger:allow:usize-arch positional argument index
    ) !ValueUsage {
        const type_info = @typeInfo(T);
        inline for (type_info.@"struct".fields) |field| {
            // Check if field name or converted name matches
            const long_flag = comptime getLongFlag(field.name);
            const matches = std.mem.eql(u8, field.name, flag_name) or
                std.mem.eql(u8, long_flag, flag_name);

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

                    try parseValue(
                        field_type_info.optional.child,
                        &@field(obj, field.name),
                        value_str,
                        flag_name,
                        position,
                    );
                    return if (provided_value != null) .NoValue else .ValueUsed;
                }
            }
        }
        return .Unknown;
    }

    fn parseShortFlagWithValue(
        comptime T: type,
        obj: *T,
        flag_char: u8,
        provided_value: ?[]const u8,
        next_arg: ?[]const u8,
        position: usize, // tiger:allow:usize-arch positional argument index
    ) !ValueUsage {
        const type_info = @typeInfo(T);
        inline for (type_info.@"struct".fields) |field| {
            // Check metadata first, then default
            const short_flag = if (@hasDecl(T, "meta") and
                @hasField(@TypeOf(T.meta), field.name) and
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

                    try parseValue(
                        field_type_info.optional.child,
                        &@field(obj, field.name),
                        value_str,
                        field.name,
                        position,
                    );
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
                const short_flag = if (@hasDecl(T, "meta") and
                    @hasField(@TypeOf(T.meta), field.name) and
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
        if (comptime std.mem.findScalar(u8, name, '_') == null and name.len > 0) {
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

    /// Parse a value string into the appropriate type
    fn parseValue(
        comptime T: type,
        dest: *?T,
        value_str: []const u8,
        flag_name: []const u8,
        position: usize, // tiger:allow:usize-arch positional argument index
    ) !void {
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

    /// Parse arguments, printing a user-facing error to `stderr_writer` on failure.
    ///
    /// On success, returns the parsed `T`.
    /// On `UnknownFlag`, `MissingValue`, `InvalidValue`, or `TooManyValues`,
    /// prints `"{prog_name}: <message>\n"` and returns `error.ParseFailed`.
    /// `OutOfMemory` propagates unwrapped.
    ///
    /// Typical usage inside a `runX` function:
    /// ```zig
    /// const parsed = ArgParser.parseOrExit(Args, allocator, argv, "cat", stderr)
    ///     catch return @intFromEnum(common.ExitCode.general_error);
    /// ```
    ///
    /// `general_error` is right for nearly every utility. The exceptions are
    /// documented on `common.ExitCode`: `grep`, `ls`, `sort`, and `test` use
    /// `serious_error`, and `env` and `timeout` use `internal_error`.
    pub fn parseOrExit(
        comptime T: type,
        allocator: std.mem.Allocator,
        args: []const []const u8,
        prog_name: []const u8,
        stderr_writer: anytype,
    ) error{ ParseFailed, OutOfMemory }!T {
        return ArgParser.parse(T, allocator, args) catch |err| {
            const msg: []const u8 = switch (err) {
                error.UnknownFlag => "unrecognized option",
                error.MissingValue => "option requires an argument",
                error.InvalidValue => "invalid option value",
                error.TooManyValues => "option does not take an argument",
                error.OutOfMemory => return error.OutOfMemory,
            };
            stderr_writer.print("{s}: {s}\n", .{ prog_name, msg }) catch {};
            return error.ParseFailed;
        };
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
        try testing.expectApproxEqAbs(
            @as(f64, 2.71828182845904523536),
            result.precision.?,
            0.0000000000001,
        );
    }

    // Test scientific notation
    {
        const args = [_][]const u8{"--rate=1.23e-4"};
        const result = try ArgParser.parse(TestArgs, testing.allocator, &args);
        try testing.expect(result.rate != null);
        try testing.expectApproxEqAbs(@as(f32, 0.000123), result.rate.?, 0.000001);
    }
}

// ============================================================================
// parseOrExit tests — verify error messages and error kinds
// ============================================================================

const BasicArgs = struct {
    help: bool = false,
    output: ?[]const u8 = null,
    count: ?u32 = null,
    mode: ?enum { fast, slow } = null,
    positionals: []const []const u8 = &.{},
};

test "parseOrExit: success returns parsed struct" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const args = [_][]const u8{ "--help", "file.txt" };
    const result = try ArgParser.parseOrExit(BasicArgs, testing.allocator, &args, "prog", &w);
    defer testing.allocator.free(result.positionals);
    try testing.expect(result.help);
    try testing.expectEqual(@as(usize, 1), result.positionals.len);
    try testing.expectEqualStrings("file.txt", result.positionals[0]);
    // No error output
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "parseOrExit: UnknownFlag prints prog-name and message" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const args = [_][]const u8{"--bogus"};
    const result = ArgParser.parseOrExit(BasicArgs, testing.allocator, &args, "myutil", &w);
    try testing.expectError(error.ParseFailed, result);
    const output = w.buffered();
    try testing.expect(std.mem.find(u8, output, "myutil") != null);
    try testing.expect(std.mem.find(u8, output, "unrecognized option") != null);
    // Must end with newline
    try testing.expect(output[output.len - 1] == '\n');
}

test "parseOrExit: MissingValue prints prog-name and message" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // --output with no value
    const args = [_][]const u8{"--output"};
    const result = ArgParser.parseOrExit(BasicArgs, testing.allocator, &args, "myutil", &w);
    try testing.expectError(error.ParseFailed, result);
    const output = w.buffered();
    try testing.expect(std.mem.find(u8, output, "myutil") != null);
    // Narrowed needle: the pinned GNU long-form message interposes the
    // quoted flag name between "option" and "requires an argument"
    // ("option '--output' requires an argument"), so the longer
    // contiguous substring "option requires an argument" no longer
    // matches. The exact format is pinned separately at the test below,
    // "missing value on a long flag names it without '=value', with hint".
    try testing.expect(std.mem.find(u8, output, "requires an argument") != null);
    try testing.expect(output[output.len - 1] == '\n');
}

test "parseOrExit: InvalidValue prints prog-name, 'invalid', and the quoted flag name" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // --count with non-integer value
    const args = [_][]const u8{"--count=notanumber"};
    const result = ArgParser.parseOrExit(BasicArgs, testing.allocator, &args, "myutil", &w);
    try testing.expectError(error.ParseFailed, result);
    const output = w.buffered();
    try testing.expect(std.mem.find(u8, output, "myutil") != null);
    try testing.expect(std.mem.find(u8, output, "invalid") != null);
    // The offending flag name must be named and quoted, per the issue.
    try testing.expect(std.mem.find(u8, output, "'--count'") != null);
    try testing.expect(output[output.len - 1] == '\n');
}

test "parseOrExit: invalid enum value also names and quotes the flag" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const args = [_][]const u8{"--mode=turbo"};
    const result = ArgParser.parseOrExit(BasicArgs, testing.allocator, &args, "myutil", &w);
    try testing.expectError(error.ParseFailed, result);
    const output = w.buffered();
    try testing.expect(std.mem.find(u8, output, "invalid") != null);
    try testing.expect(std.mem.find(u8, output, "'--mode'") != null);
    try testing.expect(output[output.len - 1] == '\n');
}

test "parseOrExit: unknown long flag quotes the flag and adds the GNU hint line" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const args = [_][]const u8{"--zzz"};
    const result = ArgParser.parseOrExit(BasicArgs, testing.allocator, &args, "testprog", &w);
    try testing.expectError(error.ParseFailed, result);
    const output = w.buffered();
    // Exact format check, pinned from GNU coreutils 9.4 (LC_ALL=C):
    //   testprog: unrecognized option '--zzz'
    //   Try 'testprog --help' for more information.
    try testing.expectEqualStrings(
        "testprog: unrecognized option '--zzz'\n" ++
            "Try 'testprog --help' for more information.\n",
        output,
    );
}

test "parseOrExit: no output on success" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const args = [_][]const u8{};
    _ = try ArgParser.parseOrExit(BasicArgs, testing.allocator, &args, "prog", &w);
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}

// ============================================================================
// GNU-parity diagnostic tests (issue #130) — pinned from GNU coreutils 9.4,
// LC_ALL=C, on this host: `whoami --invalid-flag`, `whoami -Z`, `head --lines`,
// `head -n`, `uniq --count=3`. Five distinct GNU formats; not every error gets
// the "Try '<prog> --help>' for more information." hint (bad values don't).
// These assert exact pinned output and must FAIL on the current
// bare-error-set implementation (single generic line, no flag text, no
// hint), then pass once parseOrExit threads a Diagnostic through parse().
// ============================================================================

test "parseOrExit: unknown long flag quotes the FULL typed token including '=value'" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const args = [_][]const u8{"--zzz=1"};
    const result = ArgParser.parseOrExit(BasicArgs, testing.allocator, &args, "testprog", &w);
    try testing.expectError(error.ParseFailed, result);
    try testing.expectEqualStrings(
        "testprog: unrecognized option '--zzz=1'\n" ++
            "Try 'testprog --help' for more information.\n",
        w.buffered(),
    );
}

test "parseOrExit: unknown short flag uses bare-char 'invalid option --' wording" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const args = [_][]const u8{"-Z"};
    const result = ArgParser.parseOrExit(BasicArgs, testing.allocator, &args, "testprog", &w);
    try testing.expectError(error.ParseFailed, result);
    try testing.expectEqualStrings(
        "testprog: invalid option -- 'Z'\n" ++
            "Try 'testprog --help' for more information.\n",
        w.buffered(),
    );
}

test "parseOrExit: unknown short flag mid-cluster reports the OFFENDING char" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // 'h' is a valid boolean flag on BasicArgs (help); 'Z' is not. The
    // diagnostic must name 'Z', not 'h' (the cluster's first character),
    // proving it tracks the exact byte that failed.
    const args = [_][]const u8{"-hZ"};
    const result = ArgParser.parseOrExit(BasicArgs, testing.allocator, &args, "testprog", &w);
    try testing.expectError(error.ParseFailed, result);
    try testing.expectEqualStrings(
        "testprog: invalid option -- 'Z'\n" ++
            "Try 'testprog --help' for more information.\n",
        w.buffered(),
    );
}

test "parseOrExit: missing value on a long flag names it without '=value', with hint" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const args = [_][]const u8{"--output"};
    const result = ArgParser.parseOrExit(BasicArgs, testing.allocator, &args, "testprog", &w);
    try testing.expectError(error.ParseFailed, result);
    try testing.expectEqualStrings(
        "testprog: option '--output' requires an argument\n" ++
            "Try 'testprog --help' for more information.\n",
        w.buffered(),
    );
}

test "parseOrExit: missing value on a short flag uses 'requires an argument --' wording" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const args = [_][]const u8{"-o"};
    const result = ArgParser.parseOrExit(BasicArgs, testing.allocator, &args, "testprog", &w);
    try testing.expectError(error.ParseFailed, result);
    try testing.expectEqualStrings(
        "testprog: option requires an argument -- 'o'\n" ++
            "Try 'testprog --help' for more information.\n",
        w.buffered(),
    );
}

test "parseOrExit: bool flag given a value strips '=value' from the quoted flag name" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const args = [_][]const u8{"--help=1"};
    const result = ArgParser.parseOrExit(BasicArgs, testing.allocator, &args, "testprog", &w);
    try testing.expectError(error.ParseFailed, result);
    try testing.expectEqualStrings(
        "testprog: option '--help' doesn't allow an argument\n" ++
            "Try 'testprog --help' for more information.\n",
        w.buffered(),
    );
}

test "parseOrExit: prog_name is echoed exactly twice (error line and hint line)" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const distinctive_prog = "distinctiveprogname130";
    const args = [_][]const u8{"--zzz"};
    const result = ArgParser.parseOrExit(
        BasicArgs,
        testing.allocator,
        &args,
        distinctive_prog,
        &w,
    );
    try testing.expectError(error.ParseFailed, result);
    const output = w.buffered();

    var occurrences: u32 = 0;
    var search_start: usize = 0; // tiger:allow:usize-arch slice index into output
    while (std.mem.findPos(u8, output, search_start, distinctive_prog)) |pos| {
        std.debug.assert(pos >= search_start);
        occurrences += 1;
        search_start = pos + distinctive_prog.len;
        std.debug.assert(search_start <= output.len);
    }
    try testing.expectEqual(@as(u32, 2), occurrences);
}
