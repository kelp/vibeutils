const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const common = @import("common");

/// Exit codes for test utility
const ExitCode = enum(u8) {
    true = 0, // Expression is true
    false = 1, // Expression is false
    @"error" = 2, // Error occurred
};

/// Explicit error set for test expression parsing
const ParseError = error{
    /// Expression contains invalid syntax or structure
    InvalidExpression,
    /// Operator is not recognized or supported
    UnknownOperator,
    /// Numeric parsing failed for comparison operations
    InvalidNumber,
} || Allocator.Error;

/// Handles numeric comparisons with consolidated parsing logic
const NumericComparison = struct {
    /// Parse two strings as integers and compare them using the given operation
    fn compare(left: []const u8, right: []const u8, comptime op: ComparisonOp) ParseError!bool {
        const l = std.fmt.parseInt(i64, left, 10) catch return error.InvalidNumber;
        const r = std.fmt.parseInt(i64, right, 10) catch return error.InvalidNumber;

        return switch (op) {
            .eq => l == r,
            .ne => l != r,
            .lt => l < r,
            .le => l <= r,
            .gt => l > r,
            .ge => l >= r,
        };
    }

    const ComparisonOp = enum { eq, ne, lt, le, gt, ge };
};

/// Generic file access checker that eliminates duplicate patterns
const FileAccess = struct {
    /// Check file access using specified mode, returning false on any error
    fn check(path: []const u8, mode: u32) bool {
        std.posix.access(path, mode) catch return false;
        return true;
    }

    /// Get file status, returning null on any error
    fn getStat(path: []const u8) ?std.fs.File.Stat {
        return std.fs.cwd().statFile(path) catch null;
    }

    /// Check if path exists
    fn exists(path: []const u8) bool {
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }
};

/// Expression parser with focused methods for different expression types
const ExpressionParser = struct {
    allocator: Allocator,

    /// Create new expression parser
    fn init(allocator: Allocator) ExpressionParser {
        return .{ .allocator = allocator };
    }

    /// Parse and evaluate complete expression
    fn parseAndEvaluate(self: *ExpressionParser, args: []const []const u8) ParseError!bool {
        if (args.len == 0) return false;
        if (args.len == 1) return self.evaluateSingle(args[0]);
        if (args.len == 2) {
            // Check if it's a unary expression first
            if (isUnaryOperator(args[0])) {
                return evaluateUnary(args[0], args[1]);
            }
            // Otherwise it might be negation or other complex expression
            return self.evaluateComplexExpression(args);
        }
        if (args.len == 3) {
            // Check if it's a binary expression first
            if (isBinaryOperator(args[1])) {
                return evaluateBinary(args[0], args[1], args[2]);
            }
            // Otherwise it might be complex (parentheses, negation, etc.)
            return self.evaluateComplexExpression(args);
        }

        return self.evaluateComplexExpression(args);
    }

    /// Evaluate single argument (non-empty string test)
    fn evaluateSingle(self: *ExpressionParser, arg: []const u8) ParseError!bool {
        _ = self;
        if (isUnaryOperator(arg)) return error.InvalidExpression;
        return arg.len > 0;
    }

    /// Evaluate complex expressions with logical operators and grouping
    fn evaluateComplexExpression(self: *ExpressionParser, args: []const []const u8) ParseError!bool {
        // Handle negation first
        if (std.mem.eql(u8, args[0], "!")) {
            return self.evaluateNegation(args[1..]);
        }

        // Handle parentheses grouping
        if (args.len >= 3 and std.mem.eql(u8, args[0], "(") and std.mem.eql(u8, args[args.len - 1], ")")) {
            return self.parseAndEvaluate(args[1 .. args.len - 1]);
        }

        // Handle logical operators with proper precedence (-o has lower precedence than -a)
        return self.evaluateLogicalExpression(args);
    }

    /// Evaluate negation expressions
    fn evaluateNegation(self: *ExpressionParser, args: []const []const u8) ParseError!bool {
        if (args.len == 0) return error.InvalidExpression;

        // Special case: ! left op right becomes !(left op right)
        if (args.len == 3 and isBinaryOperator(args[1])) {
            const result = try evaluateBinary(args[0], args[1], args[2]);
            return !result;
        }

        // Special case: ! ( expr )
        if (args.len >= 3 and std.mem.eql(u8, args[0], "(") and std.mem.eql(u8, args[args.len - 1], ")")) {
            const result = try self.parseAndEvaluate(args[1 .. args.len - 1]);
            return !result;
        }

        // General negation
        const result = try self.parseAndEvaluate(args);
        return !result;
    }

    /// Evaluate logical expressions with proper operator precedence
    fn evaluateLogicalExpression(self: *ExpressionParser, args: []const []const u8) ParseError!bool {
        // Find -o operators first (lowest precedence)
        for (args, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, "-o")) {
                if (i == 0 or i == args.len - 1) return error.InvalidExpression;
                const left = try self.parseAndEvaluate(args[0..i]);
                const right = try self.parseAndEvaluate(args[i + 1 ..]);
                return left or right;
            }
        }

        // Find -a operators next (higher precedence)
        for (args, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, "-a")) {
                if (i == 0 or i == args.len - 1) return error.InvalidExpression;
                const left = try self.parseAndEvaluate(args[0..i]);
                const right = try self.parseAndEvaluate(args[i + 1 ..]);
                return left and right;
            }
        }

        return error.InvalidExpression;
    }
};

/// Evaluate unary operator against single argument
fn evaluateUnary(op: []const u8, arg: []const u8) ParseError!bool {
    if (std.mem.eql(u8, op, "-z")) return arg.len == 0;
    if (std.mem.eql(u8, op, "-n")) return arg.len > 0;
    if (std.mem.eql(u8, op, "-e")) return FileAccess.exists(arg);
    if (std.mem.eql(u8, op, "-f")) return isRegularFile(arg);
    if (std.mem.eql(u8, op, "-d")) return isDirectory(arg);
    if (std.mem.eql(u8, op, "-r")) return FileAccess.check(arg, std.posix.R_OK);
    if (std.mem.eql(u8, op, "-w")) return FileAccess.check(arg, std.posix.W_OK);
    if (std.mem.eql(u8, op, "-x")) return FileAccess.check(arg, std.posix.X_OK);
    if (std.mem.eql(u8, op, "-s")) return isNonEmpty(arg);
    if (std.mem.eql(u8, op, "-L") or std.mem.eql(u8, op, "-h")) return isSymlink(arg);
    if (std.mem.eql(u8, op, "-p")) return isPipe(arg);
    if (std.mem.eql(u8, op, "-S")) return isSocket(arg);
    if (std.mem.eql(u8, op, "-b")) return isBlockDevice(arg);
    if (std.mem.eql(u8, op, "-c")) return isCharDevice(arg);
    if (std.mem.eql(u8, op, "-g")) return hasSetgid(arg);
    if (std.mem.eql(u8, op, "-t")) {
        const fd = std.fmt.parseInt(i32, arg, 10) catch return error.InvalidNumber;
        return std.posix.isatty(fd);
    }

    return error.UnknownOperator;
}

/// Evaluate binary operator between two operands
fn evaluateBinary(left: []const u8, op: []const u8, right: []const u8) ParseError!bool {
    if (std.mem.eql(u8, op, "=")) return std.mem.eql(u8, left, right);
    if (std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, left, right);
    if (std.mem.eql(u8, op, "-eq")) return NumericComparison.compare(left, right, .eq);
    if (std.mem.eql(u8, op, "-ne")) return NumericComparison.compare(left, right, .ne);
    if (std.mem.eql(u8, op, "-lt")) return NumericComparison.compare(left, right, .lt);
    if (std.mem.eql(u8, op, "-le")) return NumericComparison.compare(left, right, .le);
    if (std.mem.eql(u8, op, "-gt")) return NumericComparison.compare(left, right, .gt);
    if (std.mem.eql(u8, op, "-ge")) return NumericComparison.compare(left, right, .ge);

    return error.UnknownOperator;
}

/// Check if path is a regular file
fn isRegularFile(path: []const u8) bool {
    const stat = FileAccess.getStat(path) orelse return false;
    return stat.kind == .file;
}

/// Check if path is a directory
fn isDirectory(path: []const u8) bool {
    const stat = FileAccess.getStat(path) orelse return false;
    return stat.kind == .directory;
}

/// Check if file has non-zero size
fn isNonEmpty(path: []const u8) bool {
    const stat = FileAccess.getStat(path) orelse return false;
    return stat.size > 0;
}

/// Check if path is a symbolic link
fn isSymlink(path: []const u8) bool {
    const stat = FileAccess.getStat(path) orelse return false;
    return stat.kind == .sym_link;
}

/// Check if path is a named pipe (FIFO)
fn isPipe(path: []const u8) bool {
    const stat = FileAccess.getStat(path) orelse return false;
    return stat.kind == .named_pipe;
}

/// Check if path is a socket
fn isSocket(path: []const u8) bool {
    const stat = FileAccess.getStat(path) orelse return false;
    return stat.kind == .unix_domain_socket;
}

/// Check if path is a block device
fn isBlockDevice(path: []const u8) bool {
    const stat = FileAccess.getStat(path) orelse return false;
    return stat.kind == .block_device;
}

/// Check if path is a character device
fn isCharDevice(path: []const u8) bool {
    const stat = FileAccess.getStat(path) orelse return false;
    return stat.kind == .character_device;
}

/// Check if file has setgid bit set
fn hasSetgid(path: []const u8) bool {
    const stat = FileAccess.getStat(path) orelse return false;
    return (stat.mode & std.posix.S.ISGID) != 0;
}

/// Check if string is a unary operator (alphabetized)
fn isUnaryOperator(str: []const u8) bool {
    const unary_ops = [_][]const u8{ "-b", "-c", "-d", "-e", "-f", "-g", "-h", "-L", "-n", "-p", "-r", "-s", "-S", "-t", "-w", "-x", "-z" };

    for (unary_ops) |op| {
        if (std.mem.eql(u8, str, op)) return true;
    }
    return false;
}

/// Check if string is a binary operator (alphabetized)
fn isBinaryOperator(str: []const u8) bool {
    const binary_ops = [_][]const u8{ "!=", "-eq", "-ge", "-gt", "-le", "-lt", "-ne", "=" };

    for (binary_ops) |op| {
        if (std.mem.eql(u8, str, op)) return true;
    }
    return false;
}

/// Run test command in bracket form (when invoked as '[')
pub fn runBracketTest(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    _ = stdout_writer; // Not used in test command

    // Bracket form requires closing ']'
    if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1], "]")) {
        common.printErrorWithProgram(allocator, stderr_writer, "[", "missing closing ']'", .{});
        return @intFromEnum(ExitCode.@"error");
    }

    // Remove closing ']' from arguments
    const test_args = args[0 .. args.len - 1];

    var parser = ExpressionParser.init(allocator);
    const result = parser.parseAndEvaluate(test_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            common.printErrorWithProgram(allocator, stderr_writer, "[", "invalid expression", .{});
            return @intFromEnum(ExitCode.@"error");
        },
    };

    return if (result) @intFromEnum(ExitCode.true) else @intFromEnum(ExitCode.false);
}

/// Run main test command implementation
pub fn runTest(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    _ = stdout_writer; // Not used in test command

    var test_args = args;

    // Handle bracket form embedded in test command arguments
    if (args.len > 0 and std.mem.eql(u8, args[0], "[")) {
        if (args.len < 2 or !std.mem.eql(u8, args[args.len - 1], "]")) {
            common.printErrorWithProgram(allocator, stderr_writer, "test", "missing closing ']'", .{});
            return @intFromEnum(ExitCode.@"error");
        }
        // Remove '[' and ']' from arguments
        test_args = args[1 .. args.len - 1];
    }

    var parser = ExpressionParser.init(allocator);
    const result = parser.parseAndEvaluate(test_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            common.printErrorWithProgram(allocator, stderr_writer, "test", "invalid expression", .{});
            return @intFromEnum(ExitCode.@"error");
        },
    };

    return if (result) @intFromEnum(ExitCode.true) else @intFromEnum(ExitCode.false);
}

/// Comprehensive help text for test command
const help_text =
    \\Usage: test EXPRESSION
    \\   or: [ EXPRESSION ]
    \\
    \\Evaluate conditional expression.
    \\
    \\File tests:
    \\  -b FILE        FILE exists and is block special
    \\  -c FILE        FILE exists and is character special
    \\  -d FILE        FILE exists and is a directory
    \\  -e FILE        FILE exists
    \\  -f FILE        FILE exists and is a regular file
    \\  -g FILE        FILE exists and is set-group-ID
    \\  -h FILE        FILE exists and is a symbolic link (same as -L)
    \\  -L FILE        FILE exists and is a symbolic link (same as -h)
    \\  -p FILE        FILE exists and is a named pipe
    \\  -r FILE        FILE exists and is readable
    \\  -s FILE        FILE exists and has size greater than zero
    \\  -S FILE        FILE exists and is a socket
    \\  -t FD          file descriptor FD is opened on a terminal
    \\  -w FILE        FILE exists and is writable
    \\  -x FILE        FILE exists and is executable
    \\
    \\String tests:
    \\  -n STRING      length of STRING is non-zero
    \\  -z STRING      length of STRING is zero
    \\  STRING         equivalent to -n STRING
    \\  STRING1 = STRING2    strings are equal
    \\  STRING1 != STRING2   strings are not equal
    \\
    \\Numeric tests:
    \\  INTEGER1 -eq INTEGER2   INTEGER1 is equal to INTEGER2
    \\  INTEGER1 -ge INTEGER2   INTEGER1 is greater than or equal to INTEGER2
    \\  INTEGER1 -gt INTEGER2   INTEGER1 is greater than INTEGER2
    \\  INTEGER1 -le INTEGER2   INTEGER1 is less than or equal to INTEGER2
    \\  INTEGER1 -lt INTEGER2   INTEGER1 is less than INTEGER2
    \\  INTEGER1 -ne INTEGER2   INTEGER1 is not equal to INTEGER2
    \\
    \\Logical operators:
    \\  ! EXPRESSION         negates EXPRESSION
    \\  EXPRESSION1 -a EXPRESSION2   both EXPRESSION1 and EXPRESSION2 are true
    \\  EXPRESSION1 -o EXPRESSION2   either EXPRESSION1 or EXPRESSION2 is true
    \\  ( EXPRESSION )       force precedence
    \\
    \\Exit status:
    \\  0 if EXPRESSION is true
    \\  1 if EXPRESSION is false
    \\  2 if an error occurred
    \\
;

/// Entry point for command-line usage
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    // Detect if we're called as '[' by checking program name
    const program_name = args_iter.next() orelse return;
    const is_bracket_form = std.mem.endsWith(u8, program_name, "[");

    var args = ArrayList([]const u8).init(allocator);
    defer args.deinit();

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            try stdout.print("{s}", .{help_text});
            return;
        }
        try args.append(arg);
    }

    const exit_code = if (is_bracket_form)
        try runBracketTest(allocator, args.items, stdout, stderr)
    else
        try runTest(allocator, args.items, stdout, stderr);

    std.process.exit(exit_code);
}

// ========== TESTS ==========

test "empty expression returns false" {
    const result = try runTest(testing.allocator, &[_][]const u8{}, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "single non-empty string returns true" {
    const result = try runTest(testing.allocator, &[_][]const u8{"hello"}, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);
}

test "single empty string returns false" {
    const result = try runTest(testing.allocator, &[_][]const u8{""}, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "string length tests -z and -n" {
    // -z (zero length)
    var result = try runTest(testing.allocator, &[_][]const u8{ "-z", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, &[_][]const u8{ "-z", "hello" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // -n (non-zero length)
    result = try runTest(testing.allocator, &[_][]const u8{ "-n", "hello" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, &[_][]const u8{ "-n", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "string equality tests" {
    // String equality
    var result = try runTest(testing.allocator, &[_][]const u8{ "hello", "=", "hello" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, &[_][]const u8{ "hello", "=", "world" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // String inequality
    result = try runTest(testing.allocator, &[_][]const u8{ "hello", "!=", "world" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, &[_][]const u8{ "hello", "!=", "hello" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "numeric comparison tests" {
    // Equal
    var result = try runTest(testing.allocator, &[_][]const u8{ "5", "-eq", "5" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, &[_][]const u8{ "5", "-eq", "3" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Not equal
    result = try runTest(testing.allocator, &[_][]const u8{ "5", "-ne", "3" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, &[_][]const u8{ "5", "-ne", "5" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Less than
    result = try runTest(testing.allocator, &[_][]const u8{ "3", "-lt", "5" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, &[_][]const u8{ "5", "-lt", "3" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Less than or equal
    result = try runTest(testing.allocator, &[_][]const u8{ "3", "-le", "5" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, &[_][]const u8{ "5", "-le", "5" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, &[_][]const u8{ "5", "-le", "3" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Greater than
    result = try runTest(testing.allocator, &[_][]const u8{ "5", "-gt", "3" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, &[_][]const u8{ "3", "-gt", "5" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Greater than or equal
    result = try runTest(testing.allocator, &[_][]const u8{ "5", "-ge", "3" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, &[_][]const u8{ "5", "-ge", "5" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, &[_][]const u8{ "3", "-ge", "5" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "file existence tests" {
    // Create a temporary file for testing
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const test_file = try tmp.dir.createFile("test_file", .{});
    test_file.close();

    // Get the full path to our temp file
    const temp_path = try tmp.dir.realpathAlloc(testing.allocator, "test_file");
    defer testing.allocator.free(temp_path);

    // Test file existence
    var result = try runTest(testing.allocator, &[_][]const u8{ "-e", temp_path }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // Test regular file
    result = try runTest(testing.allocator, &[_][]const u8{ "-f", temp_path }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // Test non-existent file
    result = try runTest(testing.allocator, &[_][]const u8{ "-e", "/nonexistent/file" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "directory tests" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("test_dir");

    const temp_dir = try tmp.dir.realpathAlloc(testing.allocator, "test_dir");
    defer testing.allocator.free(temp_dir);

    // Test directory existence
    var result = try runTest(testing.allocator, &[_][]const u8{ "-d", temp_dir }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // Test that file is not a directory
    const test_file = try tmp.dir.createFile("test_file", .{});
    test_file.close();

    const temp_file = try tmp.dir.realpathAlloc(testing.allocator, "test_file");
    defer testing.allocator.free(temp_file);

    result = try runTest(testing.allocator, &[_][]const u8{ "-d", temp_file }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "file size tests" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create empty file
    const empty_file = try tmp.dir.createFile("empty", .{});
    empty_file.close();

    const empty_path = try tmp.dir.realpathAlloc(testing.allocator, "empty");
    defer testing.allocator.free(empty_path);

    // Create non-empty file
    const non_empty = try tmp.dir.createFile("nonempty", .{});
    try non_empty.writeAll("content");
    non_empty.close();

    const nonempty_path = try tmp.dir.realpathAlloc(testing.allocator, "nonempty");
    defer testing.allocator.free(nonempty_path);

    // Test empty file
    var result = try runTest(testing.allocator, &[_][]const u8{ "-s", empty_path }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Test non-empty file
    result = try runTest(testing.allocator, &[_][]const u8{ "-s", nonempty_path }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);
}

test "bracket form requires closing bracket" {
    var stderr_output = ArrayList(u8).init(testing.allocator);
    defer stderr_output.deinit();

    const result = try runTest(testing.allocator, &[_][]const u8{ "[", "hello" }, common.null_writer, stderr_output.writer());
    try testing.expectEqual(@intFromEnum(ExitCode.@"error"), result);
    try testing.expect(std.mem.indexOf(u8, stderr_output.items, "missing closing ']'") != null);
}

test "bracket form works correctly" {
    var result = try runTest(testing.allocator, &[_][]const u8{ "[", "hello", "]" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, &[_][]const u8{ "[", "", "]" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    result = try runTest(testing.allocator, &[_][]const u8{ "[", "5", "-eq", "5", "]" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);
}

test "terminal test with invalid fd" {
    // Test with invalid file descriptor
    const result = try runTest(testing.allocator, &[_][]const u8{ "-t", "999" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "terminal test with valid fd" {
    // Test with stdout (fd 1) - may or may not be a terminal depending on test environment
    // We just verify it doesn't crash
    const result = try runTest(testing.allocator, &[_][]const u8{ "-t", "1" }, common.null_writer, common.null_writer);
    // Result can be either true or false depending on environment, just check it's not error
    try testing.expect(result == @intFromEnum(ExitCode.true) or result == @intFromEnum(ExitCode.false));
}

test "numeric comparison with invalid numbers" {
    var stderr_output = ArrayList(u8).init(testing.allocator);
    defer stderr_output.deinit();

    // Invalid numbers should return error for numeric operations (not false)
    const result = try runTest(testing.allocator, &[_][]const u8{ "abc", "-eq", "5" }, common.null_writer, stderr_output.writer());
    try testing.expectEqual(@intFromEnum(ExitCode.@"error"), result);
}

test "invalid expressions return error" {
    var stderr_output = ArrayList(u8).init(testing.allocator);
    defer stderr_output.deinit();

    // Test with incomplete unary expression (missing argument)
    var result = try runTest(testing.allocator, &[_][]const u8{"-e"}, common.null_writer, stderr_output.writer());
    try testing.expectEqual(@intFromEnum(ExitCode.@"error"), result);

    // Test with incomplete binary expression (missing second operand)
    stderr_output.clearRetainingCapacity();
    result = try runTest(testing.allocator, &[_][]const u8{ "hello", "=" }, common.null_writer, stderr_output.writer());
    try testing.expectEqual(@intFromEnum(ExitCode.@"error"), result);
}

test "negation operator" {
    // Simple negation
    var result = try runTest(testing.allocator, &[_][]const u8{ "!", "hello" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    result = try runTest(testing.allocator, &[_][]const u8{ "!", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // Negation with file tests
    result = try runTest(testing.allocator, &[_][]const u8{ "!", "-e", "/nonexistent" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);
}

test "logical AND operator -a" {
    // Both true
    var result = try runTest(testing.allocator, &[_][]const u8{ "hello", "-a", "world" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // First false
    result = try runTest(testing.allocator, &[_][]const u8{ "", "-a", "world" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Second false
    result = try runTest(testing.allocator, &[_][]const u8{ "hello", "-a", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Both false
    result = try runTest(testing.allocator, &[_][]const u8{ "", "-a", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "logical OR operator -o" {
    // Both true
    var result = try runTest(testing.allocator, &[_][]const u8{ "hello", "-o", "world" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // First true, second false
    result = try runTest(testing.allocator, &[_][]const u8{ "hello", "-o", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // First false, second true
    result = try runTest(testing.allocator, &[_][]const u8{ "", "-o", "world" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // Both false
    result = try runTest(testing.allocator, &[_][]const u8{ "", "-o", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "parentheses grouping" {
    // Simple parentheses
    var result = try runTest(testing.allocator, &[_][]const u8{ "(", "hello", ")" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, &[_][]const u8{ "(", "", ")" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Parentheses with operators
    result = try runTest(testing.allocator, &[_][]const u8{ "(", "5", "-eq", "5", ")" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);
}

test "operator precedence -o vs -a" {
    // Test that -a has higher precedence than -o
    // This should be: (false -a true) -o true = false -o true = true
    var result = try runTest(testing.allocator, &[_][]const u8{ "", "-a", "hello", "-o", "world" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // This should be: true -o (false -a false) = true -o false = true
    result = try runTest(testing.allocator, &[_][]const u8{ "hello", "-o", "", "-a", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);
}

test "complex nested expressions" {
    // Test: ! ( "" -o "hello" ) should be false (because "" -o "hello" is true)
    var result = try runTest(testing.allocator, &[_][]const u8{ "!", "(", "", "-o", "hello", ")" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Test simple negation of string inequality (should be false)
    result = try runTest(testing.allocator, &[_][]const u8{ "!", "hello", "!=", "world" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "error handling for malformed expressions" {
    var stderr_output = ArrayList(u8).init(testing.allocator);
    defer stderr_output.deinit();

    // Test with mixed operators that don't make sense
    var result = try runTest(testing.allocator, &[_][]const u8{ "-e", "-f", "hello" }, common.null_writer, stderr_output.writer());
    try testing.expectEqual(@intFromEnum(ExitCode.@"error"), result);

    // Test with unbalanced parentheses
    stderr_output.clearRetainingCapacity();
    result = try runTest(testing.allocator, &[_][]const u8{ "(", "hello" }, common.null_writer, stderr_output.writer());
    try testing.expectEqual(@intFromEnum(ExitCode.@"error"), result);
}

// Test individual evaluation functions
test "evaluateUnary function" {
    try testing.expect(try evaluateUnary("-z", ""));
    try testing.expect(!try evaluateUnary("-z", "hello"));
    try testing.expect(try evaluateUnary("-n", "hello"));
    try testing.expect(!try evaluateUnary("-n", ""));
}

test "evaluateBinary function" {
    try testing.expect(try evaluateBinary("hello", "=", "hello"));
    try testing.expect(!try evaluateBinary("hello", "=", "world"));
    try testing.expect(try evaluateBinary("hello", "!=", "world"));
    try testing.expect(!try evaluateBinary("hello", "!=", "hello"));

    try testing.expect(try evaluateBinary("5", "-eq", "5"));
    try testing.expect(!try evaluateBinary("5", "-eq", "3"));
    try testing.expect(try evaluateBinary("3", "-lt", "5"));
    try testing.expect(!try evaluateBinary("5", "-lt", "3"));
}

// Test operator detection
test "operator detection" {
    try testing.expect(isUnaryOperator("-e"));
    try testing.expect(isUnaryOperator("-f"));
    try testing.expect(isUnaryOperator("-z"));
    try testing.expect(!isUnaryOperator("hello"));

    try testing.expect(isBinaryOperator("="));
    try testing.expect(isBinaryOperator("-eq"));
    try testing.expect(isBinaryOperator("-lt"));
    try testing.expect(!isBinaryOperator("-e"));
}

// Test NumericComparison module
test "NumericComparison module" {
    try testing.expect(try NumericComparison.compare("5", "5", .eq));
    try testing.expect(!try NumericComparison.compare("5", "3", .eq));
    try testing.expect(try NumericComparison.compare("3", "5", .lt));
    try testing.expect(!try NumericComparison.compare("5", "3", .lt));

    // Test error handling for invalid numbers
    try testing.expectError(error.InvalidNumber, NumericComparison.compare("abc", "5", .eq));
}

// Test FileAccess module
test "FileAccess module" {
    // Test with non-existent file
    try testing.expect(!FileAccess.exists("/nonexistent/file"));
    try testing.expect(!FileAccess.check("/nonexistent/file", std.posix.R_OK));
    try testing.expect(FileAccess.getStat("/nonexistent/file") == null);
}
