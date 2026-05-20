//! POSIX test utility for evaluating conditional expressions
//! Implements test(1) and [(1) commands with support for file tests,
//! string comparisons, numeric comparisons, and logical operators.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const common = @import("common");

const c = std.c;
const linux = std.os.linux;

extern "c" fn geteuid() std.c.uid_t;
extern "c" fn getegid() std.c.gid_t;

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

/// Raw stat result for ownership/mode checks
const RawStat = struct {
    uid: u32,
    gid: u32,
    mode: u32,
};

/// Get raw C stat for a path (follows symlinks)
fn getRawStat(path: []const u8) ?RawStat {
    var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    if (path.len > std.Io.Dir.max_path_bytes) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const c_path = buf[0..path.len :0];

    if (comptime builtin.os.tag == .linux) {
        var sx: linux.Statx = undefined;
        const rc = linux.statx(c.AT.FDCWD, c_path, 0, linux.STATX.BASIC_STATS, &sx);
        if (linux.errno(rc) != .SUCCESS) return null;
        return .{
            .uid = @intCast(sx.uid),
            .gid = @intCast(sx.gid),
            .mode = @intCast(sx.mode),
        };
    } else {
        var stat_buf: c.Stat = undefined;
        const result = c.fstatat(c.AT.FDCWD, c_path, &stat_buf, 0);
        if (result != 0) return null;
        return .{
            .uid = @intCast(stat_buf.uid),
            .gid = @intCast(stat_buf.gid),
            .mode = @intCast(stat_buf.mode),
        };
    }
}

/// Check if path is a symbolic link using lstat (does not follow symlinks)
fn isSymlink(path: []const u8) bool {
    var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    if (path.len > std.Io.Dir.max_path_bytes) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const c_path = buf[0..path.len :0];

    if (comptime builtin.os.tag == .linux) {
        var sx: linux.Statx = undefined;
        const rc = linux.statx(
            c.AT.FDCWD,
            c_path,
            linux.AT.SYMLINK_NOFOLLOW,
            linux.STATX.BASIC_STATS,
            &sx,
        );
        if (linux.errno(rc) != .SUCCESS) return false;
        return (@as(u32, @intCast(sx.mode)) & c.S.IFMT) == c.S.IFLNK;
    } else {
        var stat_buf: c.Stat = undefined;
        const result = c.fstatat(c.AT.FDCWD, c_path, &stat_buf, c.AT.SYMLINK_NOFOLLOW);
        if (result != 0) return false;
        return (stat_buf.mode & c.S.IFMT) == c.S.IFLNK;
    }
}

/// Generic file access checker that eliminates duplicate patterns
const FileAccess = struct {
    /// Check file access using specified mode, returning false on any error
    fn check(path: []const u8, mode: u32) bool {
        var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
        if (path.len > std.Io.Dir.max_path_bytes) return false;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        return c.access(buf[0..path.len :0].ptr, @intCast(mode)) == 0;
    }

    /// Get file status following symlinks, returning null on any error
    fn getStat(io: std.Io, path: []const u8) ?std.Io.File.Stat {
        return std.Io.Dir.cwd().statFile(io, path, .{}) catch null;
    }

    /// Check if path exists
    fn exists(io: std.Io, path: []const u8) bool {
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
        return true;
    }
};

/// Check if string is an unary operator (alphabetized)
fn isUnknownOperatorLike(str: []const u8) bool {
    if (str.len > 1 and str[0] == '-' and std.ascii.isAlphabetic(str[1])) {
        if (!isBinaryOperator(str) and !isUnaryOperator(str) and !std.mem.eql(u8, str, "-a") and !std.mem.eql(u8, str, "-o")) {
            return true;
        }
    }
    return false;
}

/// Expression parser with focused methods for different expression types
const ExpressionParser = struct {
    allocator: Allocator,
    io: std.Io,

    /// Create new expression parser
    fn init(allocator: Allocator, io: std.Io) ExpressionParser {
        return .{ .allocator = allocator, .io = io };
    }

    /// Core dispatch logic shared by parseAndEvaluate and evaluateWithoutNegation
    fn dispatchExpression(self: *ExpressionParser, args: []const []const u8) ParseError!bool {
        if (args.len == 0) return false;
        if (args.len == 1) return self.evaluateSingle(args[0]);
        if (args.len == 2) {
            if (isUnaryOperator(args[0])) {
                return evaluateUnary(self.io, args[0], args[1]);
            }
            return self.evaluateWithParentheses(args);
        }
        if (args.len == 3) {
            if (isBinaryOperator(args[1])) {
                return evaluateBinary(self.io, args[0], args[1], args[2]);
            }
            if (isUnknownOperatorLike(args[1])) {
                return error.UnknownOperator;
            }
            return self.evaluateWithParentheses(args);
        }
        return self.evaluateWithParentheses(args);
    }

    /// Parse and evaluate complete expression
    fn parseAndEvaluate(self: *ExpressionParser, args: []const []const u8) ParseError!bool {
        return self.dispatchExpression(args);
    }

    /// Evaluate single argument (non-empty string test)
    fn evaluateSingle(self: *ExpressionParser, arg: []const u8) ParseError!bool {
        _ = self;
        // If it's a unary operator, it needs an argument, so this is an error
        if (isUnaryOperator(arg)) return error.InvalidExpression;
        // Check for invalid operators that look like operators but aren't recognized
        if (isUnknownOperatorLike(arg)) {
            return error.UnknownOperator;
        }
        // Handle sentinel values from parentheses evaluation (null-prefixed
        // to avoid colliding with actual command-line strings)
        if (std.mem.eql(u8, arg, "\x00true")) return true;
        if (std.mem.eql(u8, arg, "\x00false")) return false;
        return arg.len > 0;
    }

    /// Evaluate negation expressions - apply negation to the next logical unit only
    fn evaluateNegation(self: *ExpressionParser, args: []const []const u8) ParseError!bool {
        if (args.len == 0) return error.InvalidExpression;

        // For negation, we need to find what it applies to:
        // If it starts with parentheses, find the matching closing paren
        // Otherwise, it applies to the next single unit only

        if (std.mem.eql(u8, args[0], "(")) {
            // Find the matching closing parenthesis
            var depth: usize = 1;
            var i: usize = 1;

            while (i < args.len and depth > 0) {
                if (std.mem.eql(u8, args[i], "(")) {
                    depth += 1;
                } else if (std.mem.eql(u8, args[i], ")")) {
                    depth -= 1;
                }
                i += 1;
            }

            if (depth > 0) {
                return error.InvalidExpression; // Unmatched parentheses
            }

            // Evaluate the parenthesized expression
            const paren_expr = args[1 .. i - 1];
            const paren_result = try self.evaluateWithoutNegation(paren_expr);
            return !paren_result;
        } else {
            // Negation applies to just the first argument/expression
            if (args.len == 1) {
                const result = try self.evaluateSingle(args[0]);
                return !result;
            } else if (args.len == 2 and isUnaryOperator(args[0])) {
                const result = try evaluateUnary(self.io, args[0], args[1]);
                return !result;
            } else if (args.len == 3 and isBinaryOperator(args[1])) {
                const result = try evaluateBinary(self.io, args[0], args[1], args[2]);
                return !result;
            } else {
                // This case shouldn't happen with proper operator precedence
                const result = try self.evaluateWithoutNegation(args);
                return !result;
            }
        }
    }

    /// Evaluate expression without checking for negation (used by evaluateNegation)
    fn evaluateWithoutNegation(self: *ExpressionParser, args: []const []const u8) ParseError!bool {
        return self.dispatchExpression(args);
    }

    /// Evaluate expressions with parentheses handling
    fn evaluateWithParentheses(self: *ExpressionParser, args: []const []const u8) ParseError!bool {
        // If no parentheses, evaluate logical operators directly
        var has_parens = false;
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "(") or std.mem.eql(u8, arg, ")")) {
                has_parens = true;
                break;
            }
        }

        if (!has_parens) {
            return self.evaluateLogicalExpression(args);
        }

        // Process parentheses recursively
        var processed_args: ArrayList([]const u8) = .empty;
        defer processed_args.deinit(self.allocator);

        var i: usize = 0;
        while (i < args.len) {
            if (std.mem.eql(u8, args[i], "(")) {
                // Find matching closing parenthesis
                const open = i;
                var depth: usize = 1;
                i += 1;

                while (i < args.len and depth > 0) {
                    if (std.mem.eql(u8, args[i], "(")) {
                        depth += 1;
                    } else if (std.mem.eql(u8, args[i], ")")) {
                        depth -= 1;
                    }
                    i += 1;
                }

                if (depth > 0) {
                    return error.InvalidExpression; // Unmatched parentheses
                }

                // Recursively evaluate the sub-expression
                const sub_expr = args[open + 1 .. i - 1];
                const sub_result = try self.evaluateWithoutNegation(sub_expr);

                // Replace parenthesized expression with its boolean result
                const result_str = if (sub_result) "\x00true" else "\x00false";
                try processed_args.append(self.allocator, result_str);
            } else {
                try processed_args.append(self.allocator, args[i]);
                i += 1;
            }
        }

        return self.evaluateLogicalExpression(processed_args.items);
    }

    /// Evaluate logical expressions with POSIX operator precedence.
    /// -a binds tighter than -o; both evaluate left-to-right.
    fn evaluateLogicalExpression(self: *ExpressionParser, args: []const []const u8) ParseError!bool {
        // Scan left-to-right for -o (lowest precedence).
        // Splitting at the leftmost -o keeps the left operand
        // minimal and recurses into the right remainder, which
        // mirrors POSIX left-to-right evaluation order.
        {
            var i: usize = 0;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "-o")) {
                    if (i == 0 or i == args.len - 1) return error.InvalidExpression;
                    const left = try self.evaluateLogicalExpression(args[0..i]);
                    const right = try self.evaluateLogicalExpression(args[i + 1 ..]);
                    return left or right;
                }
            }
        }

        // Scan left-to-right for -a (higher precedence than -o).
        {
            var i: usize = 0;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "-a")) {
                    if (i == 0 or i == args.len - 1) return error.InvalidExpression;
                    const left = try self.evaluateLogicalExpression(args[0..i]);
                    const right = try self.evaluateLogicalExpression(args[i + 1 ..]);
                    return left and right;
                }
            }
        }

        // Handle negation (highest precedence)
        if (args.len > 0 and std.mem.eql(u8, args[0], "!")) {
            return self.evaluateNegation(args[1..]);
        }

        // No logical operators found, evaluate as basic expression without logical operators
        if (args.len == 0) return false;
        if (args.len == 1) return self.evaluateSingle(args[0]);
        if (args.len == 2) {
            // Check if it's a unary expression
            if (isUnaryOperator(args[0])) {
                return evaluateUnary(self.io, args[0], args[1]);
            }
            return error.InvalidExpression;
        }
        if (args.len == 3) {
            // Check if it's a binary expression
            if (isBinaryOperator(args[1])) {
                return evaluateBinary(self.io, args[0], args[1], args[2]);
            }
            return error.InvalidExpression;
        }

        return error.InvalidExpression;
    }
};

/// Evaluate unary operator against single argument
fn evaluateUnary(io: std.Io, op: []const u8, arg: []const u8) ParseError!bool {
    if (std.mem.eql(u8, op, "-z")) return arg.len == 0;
    if (std.mem.eql(u8, op, "-n")) return arg.len > 0;
    if (std.mem.eql(u8, op, "-e")) return FileAccess.exists(io, arg);
    if (std.mem.eql(u8, op, "-f")) return isRegularFile(io, arg);
    if (std.mem.eql(u8, op, "-d")) return isDirectory(io, arg);
    if (std.mem.eql(u8, op, "-r")) return FileAccess.check(arg, c.R_OK);
    if (std.mem.eql(u8, op, "-w")) return FileAccess.check(arg, c.W_OK);
    if (std.mem.eql(u8, op, "-x")) return FileAccess.check(arg, c.X_OK);
    if (std.mem.eql(u8, op, "-s")) return isNonEmpty(io, arg);
    if (std.mem.eql(u8, op, "-L") or std.mem.eql(u8, op, "-h")) return isSymlink(arg);
    if (std.mem.eql(u8, op, "-p")) return isPipe(io, arg);
    if (std.mem.eql(u8, op, "-S")) return isSocket(io, arg);
    if (std.mem.eql(u8, op, "-b")) return isBlockDevice(io, arg);
    if (std.mem.eql(u8, op, "-c")) return isCharDevice(io, arg);
    if (std.mem.eql(u8, op, "-g")) return hasSetgid(arg);
    if (std.mem.eql(u8, op, "-u")) return hasSetuid(arg);
    if (std.mem.eql(u8, op, "-k")) return hasSticky(arg);
    if (std.mem.eql(u8, op, "-G")) return isGroupOwned(arg);
    if (std.mem.eql(u8, op, "-O")) return isUserOwned(arg);
    if (std.mem.eql(u8, op, "-t")) {
        const fd = std.fmt.parseInt(i32, arg, 10) catch return error.InvalidNumber;
        if (fd < 0) return error.InvalidNumber;
        return c.isatty(fd) != 0;
    }

    return error.UnknownOperator;
}

/// Evaluate binary operator between two operands
fn evaluateBinary(io: std.Io, left: []const u8, op: []const u8, right: []const u8) ParseError!bool {
    if (std.mem.eql(u8, op, "=")) return std.mem.eql(u8, left, right);
    if (std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, left, right);
    if (std.mem.eql(u8, op, "-eq")) return NumericComparison.compare(left, right, .eq);
    if (std.mem.eql(u8, op, "-ne")) return NumericComparison.compare(left, right, .ne);
    if (std.mem.eql(u8, op, "-lt")) return NumericComparison.compare(left, right, .lt);
    if (std.mem.eql(u8, op, "-le")) return NumericComparison.compare(left, right, .le);
    if (std.mem.eql(u8, op, "-gt")) return NumericComparison.compare(left, right, .gt);
    if (std.mem.eql(u8, op, "-ge")) return NumericComparison.compare(left, right, .ge);
    if (std.mem.eql(u8, op, "<")) return std.mem.order(u8, left, right) == .lt;
    if (std.mem.eql(u8, op, ">")) return std.mem.order(u8, left, right) == .gt;
    if (std.mem.eql(u8, op, "-nt")) return isNewerThan(io, left, right);
    if (std.mem.eql(u8, op, "-ot")) return isOlderThan(io, left, right);
    if (std.mem.eql(u8, op, "-ef")) return common.file_ops.isSameFile(io, left, right);

    return error.UnknownOperator;
}

/// Check if path is a regular file
fn isRegularFile(io: std.Io, path: []const u8) bool {
    const stat = FileAccess.getStat(io, path) orelse return false;
    return stat.kind == .file;
}

/// Check if path is a directory
fn isDirectory(io: std.Io, path: []const u8) bool {
    const stat = FileAccess.getStat(io, path) orelse return false;
    return stat.kind == .directory;
}

/// Check if file has non-zero size
fn isNonEmpty(io: std.Io, path: []const u8) bool {
    const stat = FileAccess.getStat(io, path) orelse return false;
    return stat.size > 0;
}

/// Check if path is a named pipe (FIFO)
fn isPipe(io: std.Io, path: []const u8) bool {
    const stat = FileAccess.getStat(io, path) orelse return false;
    return stat.kind == .named_pipe;
}

/// Check if path is a socket
fn isSocket(io: std.Io, path: []const u8) bool {
    const stat = FileAccess.getStat(io, path) orelse return false;
    return stat.kind == .unix_domain_socket;
}

/// Check if path is a block device
fn isBlockDevice(io: std.Io, path: []const u8) bool {
    const stat = FileAccess.getStat(io, path) orelse return false;
    return stat.kind == .block_device;
}

/// Check if path is a character device
fn isCharDevice(io: std.Io, path: []const u8) bool {
    const stat = FileAccess.getStat(io, path) orelse return false;
    return stat.kind == .character_device;
}

/// Check if file has setgid bit set
fn hasSetgid(path: []const u8) bool {
    const raw = getRawStat(path) orelse return false;
    return (raw.mode & c.S.ISGID) != 0;
}

/// Check if file has setuid bit set
fn hasSetuid(path: []const u8) bool {
    const raw = getRawStat(path) orelse return false;
    return (raw.mode & c.S.ISUID) != 0;
}

/// Check if file has sticky bit set
fn hasSticky(path: []const u8) bool {
    const raw = getRawStat(path) orelse return false;
    return (raw.mode & c.S.ISVTX) != 0;
}

/// Check if file exists and its group ID matches the effective group ID
fn isGroupOwned(path: []const u8) bool {
    const raw = getRawStat(path) orelse return false;
    return raw.gid == getegid();
}

/// Check if file exists and its user ID matches the effective user ID
fn isUserOwned(path: []const u8) bool {
    const raw = getRawStat(path) orelse return false;
    return raw.uid == geteuid();
}

/// Check if file1 is newer than file2 (compare mtime)
fn isNewerThan(io: std.Io, path1: []const u8, path2: []const u8) bool {
    const stat1 = FileAccess.getStat(io, path1) orelse return false;
    const stat2 = FileAccess.getStat(io, path2) orelse return false;
    return stat1.mtime.nanoseconds > stat2.mtime.nanoseconds;
}

/// Check if file1 is older than file2 (compare mtime)
fn isOlderThan(io: std.Io, path1: []const u8, path2: []const u8) bool {
    const stat1 = FileAccess.getStat(io, path1) orelse return false;
    const stat2 = FileAccess.getStat(io, path2) orelse return false;
    return stat1.mtime.nanoseconds < stat2.mtime.nanoseconds;
}

/// Check if string is a unary operator (alphabetized)
fn isUnaryOperator(str: []const u8) bool {
    const unary_ops = [_][]const u8{ "-b", "-c", "-d", "-e", "-f", "-g", "-G", "-h", "-k", "-L", "-n", "-O", "-p", "-r", "-s", "-S", "-t", "-u", "-w", "-x", "-z" };

    for (unary_ops) |op| {
        if (std.mem.eql(u8, str, op)) return true;
    }
    return false;
}

/// Check if string is a binary operator (alphabetized)
fn isBinaryOperator(str: []const u8) bool {
    const binary_ops = [_][]const u8{ "!=", "<", "=", ">", "-ef", "-eq", "-ge", "-gt", "-le", "-lt", "-ne", "-nt", "-ot" };

    for (binary_ops) |op| {
        if (std.mem.eql(u8, str, op)) return true;
    }
    return false;
}

/// Evaluate parsed test arguments and return exit code
fn evaluateTestArgs(allocator: Allocator, io: std.Io, test_args: []const []const u8, stderr_writer: *std.Io.Writer, prog_name: []const u8) !u8 {
    var parser = ExpressionParser.init(allocator, io);
    const result = parser.parseAndEvaluate(test_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid expression", .{});
            return @intFromEnum(ExitCode.@"error");
        },
    };
    return if (result) @intFromEnum(ExitCode.true) else @intFromEnum(ExitCode.false);
}

/// Run test command in bracket form (when invoked as '[')
pub fn runBracketTest(allocator: Allocator, io: std.Io, args: []const []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) !u8 {
    _ = stdout_writer; // Not used in test command

    // POSIX compliance: treat all arguments including --help and --version as expressions
    // This matches BSD/OpenBSD behavior (see docs/DESIGN_PHILOSOPHY.md)

    // Bracket form requires closing ']'
    if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1], "]")) {
        common.printErrorWithProgram(allocator, stderr_writer, "[", "missing closing ']'", .{});
        return @intFromEnum(ExitCode.@"error");
    }

    // Remove closing ']' from arguments
    const test_args = args[0 .. args.len - 1];

    return evaluateTestArgs(allocator, io, test_args, stderr_writer, "[");
}

/// Run main test command implementation
pub fn runTest(allocator: Allocator, io: std.Io, args: []const []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) !u8 {
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

    return evaluateTestArgs(allocator, io, test_args, stderr_writer, "test");
}

/// Run function for bracket form binary ('[').
fn runBracketCmd(allocator: Allocator, io: std.Io, args: []const []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) anyerror!u8 {
    return runBracketTest(allocator, io, args, stdout_writer, stderr_writer);
}

/// Run function for test binary.
fn runTestCmd(allocator: Allocator, io: std.Io, args: []const []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) anyerror!u8 {
    return runTest(allocator, io, args, stdout_writer, stderr_writer);
}

pub fn main(init: std.process.Init) noreturn {
    // Detect if we were invoked as '[' by checking argv[0]
    const is_bracket = if (init.minimal.args.vector.len > 0)
        std.mem.endsWith(u8, std.mem.span(init.minimal.args.vector[0]), "[")
    else
        false;

    if (is_bracket) {
        common.utilityMain(init, runBracketCmd);
    } else {
        common.utilityMain(init, runTestCmd);
    }
}

// ========== TESTS ==========

test "empty expression returns false" {
    const io = testing.io;
    const result = try runTest(testing.allocator, io, &[_][]const u8{}, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "single non-empty string returns true" {
    const io = testing.io;
    const result = try runTest(testing.allocator, io, &[_][]const u8{"hello"}, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);
}

test "single empty string returns false" {
    const io = testing.io;
    const result = try runTest(testing.allocator, io, &[_][]const u8{""}, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "string length tests -z and -n" {
    const io = testing.io;
    // -z (zero length)
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "-z", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, io, &[_][]const u8{ "-z", "hello" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // -n (non-zero length)
    result = try runTest(testing.allocator, io, &[_][]const u8{ "-n", "hello" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, io, &[_][]const u8{ "-n", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "string equality tests" {
    const io = testing.io;
    // String equality
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "hello", "=", "hello" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, io, &[_][]const u8{ "hello", "=", "world" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // String inequality
    result = try runTest(testing.allocator, io, &[_][]const u8{ "hello", "!=", "world" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, io, &[_][]const u8{ "hello", "!=", "hello" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "numeric comparison tests" {
    const io = testing.io;
    // Equal
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "5", "-eq", "5" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, io, &[_][]const u8{ "5", "-eq", "3" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Not equal
    result = try runTest(testing.allocator, io, &[_][]const u8{ "5", "-ne", "3" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, io, &[_][]const u8{ "5", "-ne", "5" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Less than
    result = try runTest(testing.allocator, io, &[_][]const u8{ "3", "-lt", "5" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, io, &[_][]const u8{ "5", "-lt", "3" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Less than or equal
    result = try runTest(testing.allocator, io, &[_][]const u8{ "3", "-le", "5" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, io, &[_][]const u8{ "5", "-le", "5" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, io, &[_][]const u8{ "5", "-le", "3" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Greater than
    result = try runTest(testing.allocator, io, &[_][]const u8{ "5", "-gt", "3" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, io, &[_][]const u8{ "3", "-gt", "5" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Greater than or equal
    result = try runTest(testing.allocator, io, &[_][]const u8{ "5", "-ge", "3" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, io, &[_][]const u8{ "5", "-ge", "5" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, io, &[_][]const u8{ "3", "-ge", "5" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "file existence tests" {
    const io = testing.io;
    // Create a temporary file for testing
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const test_file = try tmp.dir.createFile(io, "test_file", .{});
    test_file.close(io);

    // Get the full path to our temp file
    const temp_path = try tmp.dir.realPathFileAlloc(io, "test_file", testing.allocator);
    defer testing.allocator.free(temp_path);

    // Test file existence
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "-e", temp_path }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // Test regular file
    result = try runTest(testing.allocator, io, &[_][]const u8{ "-f", temp_path }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // Test non-existent file
    result = try runTest(testing.allocator, io, &[_][]const u8{ "-e", "/nonexistent/file" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "directory tests" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "test_dir", .default_dir);

    const temp_dir = try tmp.dir.realPathFileAlloc(io, "test_dir", testing.allocator);
    defer testing.allocator.free(temp_dir);

    // Test directory existence
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "-d", temp_dir }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // Test that file is not a directory
    const test_file = try tmp.dir.createFile(io, "test_file", .{});
    test_file.close(io);

    const temp_file = try tmp.dir.realPathFileAlloc(io, "test_file", testing.allocator);
    defer testing.allocator.free(temp_file);

    result = try runTest(testing.allocator, io, &[_][]const u8{ "-d", temp_file }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "file size tests" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create empty file
    const empty_file = try tmp.dir.createFile(io, "empty", .{});
    empty_file.close(io);

    const empty_path = try tmp.dir.realPathFileAlloc(io, "empty", testing.allocator);
    defer testing.allocator.free(empty_path);

    // Create non-empty file
    const non_empty = try tmp.dir.createFile(io, "nonempty", .{});
    try non_empty.writeStreamingAll(io, "content");
    non_empty.close(io);

    const nonempty_path = try tmp.dir.realPathFileAlloc(io, "nonempty", testing.allocator);
    defer testing.allocator.free(nonempty_path);

    // Test empty file
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "-s", empty_path }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Test non-empty file
    result = try runTest(testing.allocator, io, &[_][]const u8{ "-s", nonempty_path }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);
}

test "bracket form requires closing bracket" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const result = try runTest(testing.allocator, io, &[_][]const u8{ "[", "hello" }, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@intFromEnum(ExitCode.@"error"), result);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "missing closing ']'") != null);
}

test "bracket form works correctly" {
    const io = testing.io;
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "[", "hello", "]" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, io, &[_][]const u8{ "[", "", "]" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    result = try runTest(testing.allocator, io, &[_][]const u8{ "[", "5", "-eq", "5", "]" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);
}

test "terminal test with invalid fd" {
    const io = testing.io;
    // Test with invalid file descriptor
    const result = try runTest(testing.allocator, io, &[_][]const u8{ "-t", "999" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "terminal test with valid fd" {
    const io = testing.io;
    // Test with stdout (fd 1) - may or may not be a terminal depending on test environment
    // We just verify it doesn't crash
    const result = try runTest(testing.allocator, io, &[_][]const u8{ "-t", "1" }, common.null_writer, common.null_writer);
    // Result can be either true or false depending on environment, just check it's not error
    try testing.expect(result == @intFromEnum(ExitCode.true) or result == @intFromEnum(ExitCode.false));
}

test "numeric comparison with invalid numbers" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Invalid numbers should return error for numeric operations (not false)
    const result = try runTest(testing.allocator, io, &[_][]const u8{ "abc", "-eq", "5" }, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@intFromEnum(ExitCode.@"error"), result);
}

test "invalid expressions return error" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test with incomplete unary expression (missing argument)
    var result = try runTest(testing.allocator, io, &[_][]const u8{"-e"}, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@intFromEnum(ExitCode.@"error"), result);

    // Test with incomplete binary expression (missing second operand)
    stderr_aw.clearRetainingCapacity();
    result = try runTest(testing.allocator, io, &[_][]const u8{ "hello", "=" }, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@intFromEnum(ExitCode.@"error"), result);
}

test "negation operator" {
    const io = testing.io;
    // Simple negation
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "!", "hello" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    result = try runTest(testing.allocator, io, &[_][]const u8{ "!", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // Negation with file tests
    result = try runTest(testing.allocator, io, &[_][]const u8{ "!", "-e", "/nonexistent" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);
}

test "logical AND operator -a" {
    const io = testing.io;
    // Both true
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "hello", "-a", "world" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // First false
    result = try runTest(testing.allocator, io, &[_][]const u8{ "", "-a", "world" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Second false
    result = try runTest(testing.allocator, io, &[_][]const u8{ "hello", "-a", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Both false
    result = try runTest(testing.allocator, io, &[_][]const u8{ "", "-a", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "logical OR operator -o" {
    const io = testing.io;
    // Both true
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "hello", "-o", "world" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // First true, second false
    result = try runTest(testing.allocator, io, &[_][]const u8{ "hello", "-o", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // First false, second true
    result = try runTest(testing.allocator, io, &[_][]const u8{ "", "-o", "world" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // Both false
    result = try runTest(testing.allocator, io, &[_][]const u8{ "", "-o", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "parentheses grouping" {
    const io = testing.io;
    // Simple parentheses
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "(", "hello", ")" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    result = try runTest(testing.allocator, io, &[_][]const u8{ "(", "", ")" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Parentheses with operators
    result = try runTest(testing.allocator, io, &[_][]const u8{ "(", "5", "-eq", "5", ")" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);
}

test "operator precedence -o vs -a" {
    const io = testing.io;
    // Test that -a has higher precedence than -o
    // This should be: (false -a true) -o true = false -o true = true
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "", "-a", "hello", "-o", "world" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // This should be: true -o (false -a false) = true -o false = true
    result = try runTest(testing.allocator, io, &[_][]const u8{ "hello", "-o", "", "-a", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);
}

test "complex nested expressions" {
    const io = testing.io;
    // Test: ! ( "" -o "hello" ) should be false (because "" -o "hello" is true)
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "!", "(", "", "-o", "hello", ")" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Test simple negation of string inequality (should be false)
    result = try runTest(testing.allocator, io, &[_][]const u8{ "!", "hello", "!=", "world" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "error handling for malformed expressions" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test with mixed operators that don't make sense
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "-e", "-f", "hello" }, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@intFromEnum(ExitCode.@"error"), result);

    // Test with unbalanced parentheses
    stderr_aw.clearRetainingCapacity();
    result = try runTest(testing.allocator, io, &[_][]const u8{ "(", "hello" }, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@intFromEnum(ExitCode.@"error"), result);
}

// Test individual evaluation functions
test "evaluateUnary function" {
    const io = testing.io;
    try testing.expect(try evaluateUnary(io, "-z", ""));
    try testing.expect(!try evaluateUnary(io, "-z", "hello"));
    try testing.expect(try evaluateUnary(io, "-n", "hello"));
    try testing.expect(!try evaluateUnary(io, "-n", ""));
}

test "evaluateBinary function" {
    const io = testing.io;
    try testing.expect(try evaluateBinary(io, "hello", "=", "hello"));
    try testing.expect(!try evaluateBinary(io, "hello", "=", "world"));
    try testing.expect(try evaluateBinary(io, "hello", "!=", "world"));
    try testing.expect(!try evaluateBinary(io, "hello", "!=", "hello"));

    try testing.expect(try evaluateBinary(io, "5", "-eq", "5"));
    try testing.expect(!try evaluateBinary(io, "5", "-eq", "3"));
    try testing.expect(try evaluateBinary(io, "3", "-lt", "5"));
    try testing.expect(!try evaluateBinary(io, "5", "-lt", "3"));
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
    const io = testing.io;
    // Test with non-existent file
    try testing.expect(!FileAccess.exists(io, "/nonexistent/file"));
    try testing.expect(!FileAccess.check("/nonexistent/file", c.R_OK));
    try testing.expect(FileAccess.getStat(io, "/nonexistent/file") == null);
}

// ========== BUG FIX TESTS ==========
// Tests for specific bugs identified by architect agent

test "invalid operator should return exit code 2" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test with invalid unary operator - should return error exit code 2, not false (1)
    const result = try runTest(testing.allocator, io, &[_][]const u8{"-invalid"}, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@intFromEnum(ExitCode.@"error"), result);

    // Test with invalid binary operator - should return error exit code 2
    stderr_aw.clearRetainingCapacity();
    const result2 = try runTest(testing.allocator, io, &[_][]const u8{ "hello", "-badop", "world" }, common.null_writer, &stderr_aw.writer);
    try testing.expectEqual(@intFromEnum(ExitCode.@"error"), result2);

    // Debug: Test that valid operators still work
    const result3 = try runTest(testing.allocator, io, &[_][]const u8{ "-e", "/nonexistent" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result3);
}

test "parentheses expression with logical operators should return correct exit code" {
    const io = testing.io;
    // Test: test ( "" -o "hello" ) -a "" should return exit code 1 (false), not 2 (error)
    // This tests proper parsing of parentheses expressions with logical operators
    const result = try runTest(testing.allocator, io, &[_][]const u8{ "(", "", "-o", "hello", ")", "-a", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Test: test ( "hello" -a "world" ) -o "" should return exit code 0 (true)
    const result2 = try runTest(testing.allocator, io, &[_][]const u8{ "(", "hello", "-a", "world", ")", "-o", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result2);
}

test "complex nested expressions should parse correctly" {
    const io = testing.io;
    // Test: test ! ( ( "" ) ) -a "" should parse correctly and return false
    const result = try runTest(testing.allocator, io, &[_][]const u8{ "!", "(", "(", "", ")", ")", "-a", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Test: test ! ( "hello" -o "" ) -a "world" should parse correctly
    const result2 = try runTest(testing.allocator, io, &[_][]const u8{ "!", "(", "hello", "-o", "", ")", "-a", "world" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result2);
}

test "bracket form should handle errors identically to test command" {
    const io = testing.io;
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test invalid operator in bracket form - should return same error as test command
    const bracket_result = try runBracketTest(testing.allocator, io, &[_][]const u8{ "-invalid", "]" }, common.null_writer, &stderr_aw.writer);

    stderr_aw.clearRetainingCapacity();
    const test_result = try runTest(testing.allocator, io, &[_][]const u8{"-invalid"}, common.null_writer, &stderr_aw.writer);

    // Both should return error exit code 2
    try testing.expectEqual(@intFromEnum(ExitCode.@"error"), bracket_result);
    try testing.expectEqual(@intFromEnum(ExitCode.@"error"), test_result);
    try testing.expectEqual(bracket_result, test_result);
}

test "POSIX: string 'false' is non-empty, should be true" {
    const io = testing.io;
    // POSIX: test "false" should return true because "false" is a non-empty string
    const result = try runTest(testing.allocator, io, &[_][]const u8{"false"}, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);
}

test "POSIX: string 'true' is non-empty, should be true" {
    const io = testing.io;
    // POSIX: test "true" should return true because "true" is a non-empty string
    const result = try runTest(testing.allocator, io, &[_][]const u8{"true"}, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);
}

test "POSIX: -o is left-associative" {
    const io = testing.io;
    // "a" -o "b" -o "c" should not error (exercises the split logic)
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "a", "-o", "b", "-o", "c" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // "a" -a "b" -a "c" should be true (all non-empty)
    result = try runTest(testing.allocator, io, &[_][]const u8{ "a", "-a", "b", "-a", "c" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // "" -a "b" -a "c" should be false (left-assoc: ("" -a "b") -a "c" = false -a "c" = false)
    result = try runTest(testing.allocator, io, &[_][]const u8{ "", "-a", "b", "-a", "c" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "symlink detection with -L and -h operators" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a regular file
    const test_file = try tmp.dir.createFile(io, "target_file", .{});
    try test_file.writeStreamingAll(io, "test content");
    test_file.close(io);

    // Create a symlink to the file
    try tmp.dir.symLink(io, "target_file", "link_to_file", .{});

    // Get full paths
    const target_path = try tmp.dir.realPathFileAlloc(io, "target_file", testing.allocator);
    defer testing.allocator.free(target_path);

    // Get the absolute path of the symlink without resolving it
    const tmpdir_path = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmpdir_path);

    const link_path_abs = try std.fmt.allocPrint(testing.allocator, "{s}/link_to_file", .{tmpdir_path});
    defer testing.allocator.free(link_path_abs);

    // Test -L operator on symlink (should return true)
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "-L", link_path_abs }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // Test -h operator on symlink (should return true)
    result = try runTest(testing.allocator, io, &[_][]const u8{ "-h", link_path_abs }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // Test -L operator on regular file (should return false)
    result = try runTest(testing.allocator, io, &[_][]const u8{ "-L", target_path }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Test -h operator on regular file (should return false)
    result = try runTest(testing.allocator, io, &[_][]const u8{ "-h", target_path }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "setuid and sticky bit operators -u and -k" {
    const io = testing.io;
    // These operators require special file setup, so just test they don't crash
    // on non-existent files (should return false)
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "-u", "/nonexistent" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    result = try runTest(testing.allocator, io, &[_][]const u8{ "-k", "/nonexistent" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "file comparison operators -nt, -ot, -ef" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create two files with different timestamps
    const file1 = try tmp.dir.createFile(io, "older", .{});
    file1.close(io);

    // Small delay to ensure different mtime
    io.sleep(std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};

    const file2 = try tmp.dir.createFile(io, "newer", .{});
    file2.close(io);

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    const older_path = try std.fmt.allocPrint(testing.allocator, "{s}/older", .{dir_path});
    defer testing.allocator.free(older_path);
    const newer_path = try std.fmt.allocPrint(testing.allocator, "{s}/newer", .{dir_path});
    defer testing.allocator.free(newer_path);

    // -nt: newer file is newer than older file
    var result = try runTest(testing.allocator, io, &[_][]const u8{ newer_path, "-nt", older_path }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // -ot: older file is older than newer file
    result = try runTest(testing.allocator, io, &[_][]const u8{ older_path, "-ot", newer_path }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // -ef: same file should be equal to itself
    result = try runTest(testing.allocator, io, &[_][]const u8{ older_path, "-ef", older_path }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // -ef: different files should not be equal
    result = try runTest(testing.allocator, io, &[_][]const u8{ older_path, "-ef", newer_path }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Non-existent files should return false
    result = try runTest(testing.allocator, io, &[_][]const u8{ "/nonexistent1", "-nt", "/nonexistent2" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "string ordering operator < (less than)" {
    const io = testing.io;
    // "abc" < "def" should be true
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "abc", "<", "def" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // "def" < "abc" should be false
    result = try runTest(testing.allocator, io, &[_][]const u8{ "def", "<", "abc" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Same strings should be false
    result = try runTest(testing.allocator, io, &[_][]const u8{ "abc", "<", "abc" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Empty string sorts before non-empty
    result = try runTest(testing.allocator, io, &[_][]const u8{ "", "<", "abc" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);
}

test "string ordering operator > (greater than)" {
    const io = testing.io;
    // "def" > "abc" should be true
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "def", ">", "abc" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // "abc" > "def" should be false
    result = try runTest(testing.allocator, io, &[_][]const u8{ "abc", ">", "def" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Same strings should be false
    result = try runTest(testing.allocator, io, &[_][]const u8{ "abc", ">", "abc" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);

    // Non-empty string sorts after empty
    result = try runTest(testing.allocator, io, &[_][]const u8{ "abc", ">", "" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);
}

test "string ordering operators are recognized as binary operators" {
    try testing.expect(isBinaryOperator("<"));
    try testing.expect(isBinaryOperator(">"));
}

test "-G operator: file group matches effective group ID" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a file owned by current user/group
    const test_file = try tmp.dir.createFile(io, "test_file", .{});
    test_file.close(io);

    const temp_path = try tmp.dir.realPathFileAlloc(io, "test_file", testing.allocator);
    defer testing.allocator.free(temp_path);

    // File created by current process should match effective group ID
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "-G", temp_path }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // Non-existent file should return false
    result = try runTest(testing.allocator, io, &[_][]const u8{ "-G", "/nonexistent/file" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "-O operator: file user matches effective user ID" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a file owned by current user
    const test_file = try tmp.dir.createFile(io, "test_file", .{});
    test_file.close(io);

    const temp_path = try tmp.dir.realPathFileAlloc(io, "test_file", testing.allocator);
    defer testing.allocator.free(temp_path);

    // File created by current process should match effective user ID
    var result = try runTest(testing.allocator, io, &[_][]const u8{ "-O", temp_path }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.true), result);

    // Non-existent file should return false
    result = try runTest(testing.allocator, io, &[_][]const u8{ "-O", "/nonexistent/file" }, common.null_writer, common.null_writer);
    try testing.expectEqual(@intFromEnum(ExitCode.false), result);
}

test "-G and -O are recognized as unary operators" {
    try testing.expect(isUnaryOperator("-G"));
    try testing.expect(isUnaryOperator("-O"));
}

test "evaluateBinary with < and > operators" {
    const io = testing.io;
    try testing.expect(try evaluateBinary(io, "abc", "<", "def"));
    try testing.expect(!try evaluateBinary(io, "def", "<", "abc"));
    try testing.expect(!try evaluateBinary(io, "abc", "<", "abc"));
    try testing.expect(try evaluateBinary(io, "def", ">", "abc"));
    try testing.expect(!try evaluateBinary(io, "abc", ">", "def"));
    try testing.expect(!try evaluateBinary(io, "abc", ">", "abc"));
}

test "evaluateUnary with -G and -O operators" {
    const io = testing.io;
    // Non-existent file should return false for both
    try testing.expect(!try evaluateUnary(io, "-G", "/nonexistent"));
    try testing.expect(!try evaluateUnary(io, "-O", "/nonexistent"));
}
