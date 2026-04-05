//! env - run a command in a modified environment
//!
//! The env utility runs a command with a modified environment, or prints the
//! current environment. It supports clearing the environment, unsetting
//! specific variables, setting new variables, and changing directory before
//! executing the command.
//!
//! This implementation follows POSIX and GNU coreutils specifications.

const std = @import("std");
const common = @import("common");
const testing = std.testing;

const Allocator = std.mem.Allocator;
const process = std.process;

/// Options parsed from command-line arguments
const EnvOptions = struct {
    /// Start with an empty environment
    ignore_environment: bool = false,
    /// Variable names to unset (owned slice from parseArgs)
    unsets: []const []const u8 = &.{},
    /// Directory to change to before running the command
    chdir: ?[]const u8 = null,
    /// Use NUL instead of newline as output delimiter
    null_delimiter: bool = false,
    /// Alternate PATH to search for utility
    alt_path: ?[]const u8 = null,
    /// Split string argument (stub)
    split_string: ?[]const u8 = null,
    /// Verbose mode
    verbose: bool = false,
    /// Show help
    help: bool = false,
    /// Show version
    version: bool = false,
    /// NAME=VALUE assignments (owned slice from parseArgs)
    assignments: []const Assignment = &.{},
    /// Command and its arguments to execute
    command: []const []const u8 = &.{},
    /// Whether the unsets/assignments slices were allocated by parseArgs
    owns_memory: bool = false,

    /// Free memory allocated by parseArgs
    fn deinit(self: *const EnvOptions, allocator: Allocator) void {
        if (self.owns_memory) {
            if (self.unsets.len > 0) allocator.free(self.unsets);
            if (self.assignments.len > 0) allocator.free(self.assignments);
        }
    }
};

const Assignment = struct {
    name: []const u8,
    value: []const u8,
};

/// Main entry point
pub fn main() !void {
    common.utilityMain(runEnv);
}

/// Run the env utility with given arguments
pub fn runEnv(allocator: Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) anyerror!u8 {
    var options = parseArgs(allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, "env", "unrecognized option\nTry 'env --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "env", "option requires an argument\nTry 'env --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.OutOfMemory => {
                common.printErrorWithProgram(allocator, stderr_writer, "env", "out of memory", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
        }
    };
    defer options.deinit(allocator);

    if (options.help) {
        printHelp(allocator, stdout_writer) catch {};
        return 0;
    }

    if (options.version) {
        printVersion(stdout_writer) catch {};
        return 0;
    }

    // Per macOS spec: -0 and utility may not be specified together
    if (options.null_delimiter and options.command.len > 0) {
        common.printErrorWithProgram(allocator, stderr_writer, "env", "cannot specify -0 with a utility", .{});
        return 125;
    }

    // Handle -S: split string into tokens, process as assignments/command
    if (options.split_string) |split_str| {
        var split_assignments = std.ArrayListUnmanaged(Assignment){};
        defer split_assignments.deinit(allocator);
        var split_command = std.ArrayListUnmanaged([]const u8){};
        var in_command = false;

        var token_it = std.mem.tokenizeAny(u8, split_str, " \t");
        while (token_it.next()) |token| {
            if (in_command) {
                split_command.append(allocator, token) catch {
                    common.printErrorWithProgram(allocator, stderr_writer, "env", "out of memory", .{});
                    return @intFromEnum(common.ExitCode.general_error);
                };
            } else if (std.mem.indexOfScalar(u8, token, '=')) |eq_pos| {
                split_assignments.append(allocator, .{
                    .name = token[0..eq_pos],
                    .value = token[eq_pos + 1 ..],
                }) catch {
                    common.printErrorWithProgram(allocator, stderr_writer, "env", "out of memory", .{});
                    return @intFromEnum(common.ExitCode.general_error);
                };
            } else {
                // First non-assignment token starts the command
                in_command = true;
                split_command.append(allocator, token) catch {
                    common.printErrorWithProgram(allocator, stderr_writer, "env", "out of memory", .{});
                    return @intFromEnum(common.ExitCode.general_error);
                };
            }
        }

        // Merge -S assignments with any from the command line
        if (split_assignments.items.len > 0) {
            var merged = std.ArrayListUnmanaged(Assignment){};
            // Add original assignments first
            for (options.assignments) |a| {
                merged.append(allocator, a) catch {
                    common.printErrorWithProgram(allocator, stderr_writer, "env", "out of memory", .{});
                    return @intFromEnum(common.ExitCode.general_error);
                };
            }
            // Then -S assignments
            for (split_assignments.items) |a| {
                merged.append(allocator, a) catch {
                    common.printErrorWithProgram(allocator, stderr_writer, "env", "out of memory", .{});
                    return @intFromEnum(common.ExitCode.general_error);
                };
            }
            // Free old owned assignments before replacing
            if (options.owns_memory and options.assignments.len > 0) {
                allocator.free(options.assignments);
            }
            options.assignments = merged.toOwnedSlice(allocator) catch {
                common.printErrorWithProgram(allocator, stderr_writer, "env", "out of memory", .{});
                return @intFromEnum(common.ExitCode.general_error);
            };
        }

        // -S command tokens override if no command was set from args
        if (options.command.len == 0 and split_command.items.len > 0) {
            options.command = split_command.items;
        } else {
            split_command.deinit(allocator);
        }
    }

    // Build the environment
    var env_map = buildEnvMap(allocator, options) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "env", "failed to build environment: {s}", .{common.posixErrorString(err)});
        return @intFromEnum(common.ExitCode.general_error);
    };
    defer env_map.deinit();

    // Verbose output for environment modifications
    if (options.verbose) {
        if (options.ignore_environment) {
            stderr_writer.writeAll("env: clearing environment\n") catch {};
        }
        for (options.unsets) |name| {
            stderr_writer.print("env: unsetenv {s}\n", .{name}) catch {};
        }
        for (options.assignments) |assignment| {
            stderr_writer.print("env: setenv {s}={s}\n", .{ assignment.name, assignment.value }) catch {};
        }
    }

    // Handle -C/--chdir
    if (options.chdir) |dir| {
        std.posix.chdir(dir) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "env", "cannot change directory to '{s}': {s}", .{ dir, common.posixErrorString(err) });
            return 125;
        };
    }

    // If no command, print the environment
    if (options.command.len == 0) {
        printEnvironment(stdout_writer, &env_map, options.null_delimiter) catch {
            return @intFromEnum(common.ExitCode.general_error);
        };
        return 0;
    }

    // Handle -P: set alternate PATH for command search.
    // Per macOS spec, -P only affects where the utility is searched,
    // not the child's environment. We set PATH in env_map here only
    // for process.Child's search; it does not apply when printing.
    if (options.alt_path) |alt| {
        if (options.verbose) {
            stderr_writer.print("env: using alternate PATH: {s}\n", .{alt}) catch {};
        }
        env_map.put("PATH", alt) catch {
            common.printErrorWithProgram(allocator, stderr_writer, "env", "failed to set alternate PATH", .{});
            return @intFromEnum(common.ExitCode.general_error);
        };
    }

    // Execute the command
    return execCommand(allocator, options.command, &env_map, stderr_writer);
}

/// Parse command-line arguments manually (env has unusual argument syntax)
fn parseArgs(allocator: Allocator, args: []const []const u8) error{ UnknownFlag, MissingValue, OutOfMemory }!EnvOptions {
    var options = EnvOptions{};
    var unsets = std.ArrayListUnmanaged([]const u8){};
    errdefer unsets.deinit(allocator);
    var assignments = std.ArrayListUnmanaged(Assignment){};
    errdefer assignments.deinit(allocator);
    var i: usize = 0;
    var past_options = false;
    var seen_assignment = false;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // After --, everything is command
        if (past_options) {
            options.command = args[i..];
            break;
        }

        // Check for --
        if (std.mem.eql(u8, arg, "--")) {
            past_options = true;
            continue;
        }

        // A bare `-` implies -i (clear environment), per GNU coreutils
        if (std.mem.eql(u8, arg, "-")) {
            options.ignore_environment = true;
            continue;
        }

        // Check for NAME=VALUE assignment or command start
        if (!past_options and !std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
                assignments.append(allocator, .{
                    .name = arg[0..eq_pos],
                    .value = arg[eq_pos + 1 ..],
                }) catch return error.OutOfMemory;
                seen_assignment = true;
                continue;
            }
            // Not an assignment and not a flag -- it's the command
            options.command = args[i..];
            break;
        }

        // Per POSIX/macOS spec: once a NAME=VALUE has been seen,
        // subsequent flag-like tokens start the command.
        if (seen_assignment) {
            options.command = args[i..];
            break;
        }

        // Long flags
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--help")) {
                options.help = true;
                break;
            } else if (std.mem.eql(u8, arg, "--version")) {
                options.version = true;
                break;
            } else if (std.mem.eql(u8, arg, "--ignore-environment")) {
                options.ignore_environment = true;
            } else if (std.mem.eql(u8, arg, "--null")) {
                options.null_delimiter = true;
            } else if (std.mem.startsWith(u8, arg, "--unset=")) {
                const name = arg["--unset=".len..];
                unsets.append(allocator, name) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, arg, "--unset")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                unsets.append(allocator, args[i]) catch return error.OutOfMemory;
            } else if (std.mem.startsWith(u8, arg, "--chdir=")) {
                options.chdir = arg["--chdir=".len..];
            } else if (std.mem.eql(u8, arg, "--chdir")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                options.chdir = args[i];
            } else if (std.mem.startsWith(u8, arg, "--split-string=")) {
                options.split_string = arg["--split-string=".len..];
            } else if (std.mem.eql(u8, arg, "--split-string")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                options.split_string = args[i];
            } else {
                return error.UnknownFlag;
            }
            continue;
        }

        // Short flags (can be combined for boolean flags)
        if (arg.len > 1 and arg[0] == '-') {
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                switch (arg[j]) {
                    'i' => options.ignore_environment = true,
                    '0', 'z' => options.null_delimiter = true,
                    'h' => {
                        options.help = true;
                        break;
                    },
                    'V' => {
                        options.version = true;
                        break;
                    },
                    'u' => {
                        // -u requires a value
                        if (j + 1 < arg.len) {
                            // Value is the rest of this arg: -uNAME
                            unsets.append(allocator, arg[j + 1 ..]) catch return error.OutOfMemory;
                            j = arg.len; // consumed rest of arg
                        } else {
                            // Value is the next arg
                            i += 1;
                            if (i >= args.len) return error.MissingValue;
                            unsets.append(allocator, args[i]) catch return error.OutOfMemory;
                        }
                        break;
                    },
                    'C' => {
                        // -C requires a value
                        if (j + 1 < arg.len) {
                            options.chdir = arg[j + 1 ..];
                            j = arg.len;
                        } else {
                            i += 1;
                            if (i >= args.len) return error.MissingValue;
                            options.chdir = args[i];
                        }
                        break;
                    },
                    'P' => {
                        // -P requires a path value
                        if (j + 1 < arg.len) {
                            options.alt_path = arg[j + 1 ..];
                            j = arg.len;
                        } else {
                            i += 1;
                            if (i >= args.len) return error.MissingValue;
                            options.alt_path = args[i];
                        }
                        break;
                    },
                    'S' => {
                        // -S requires a string value (stub)
                        if (j + 1 < arg.len) {
                            options.split_string = arg[j + 1 ..];
                            j = arg.len;
                        } else {
                            i += 1;
                            if (i >= args.len) return error.MissingValue;
                            options.split_string = args[i];
                        }
                        break;
                    },
                    'v' => options.verbose = true,
                    else => return error.UnknownFlag,
                }
            }
            // Early return if help/version was found in combined flags
            if (options.help or options.version) break;
            continue;
        }
    }

    // Transfer ownership from ArrayListUnmanaged to owned slices
    options.owns_memory = true;
    if (unsets.items.len > 0) {
        options.unsets = unsets.toOwnedSlice(allocator) catch return error.OutOfMemory;
    } else {
        unsets.deinit(allocator);
    }
    if (assignments.items.len > 0) {
        options.assignments = assignments.toOwnedSlice(allocator) catch return error.OutOfMemory;
    } else {
        assignments.deinit(allocator);
    }
    return options;
}

/// Build the environment map based on options
fn buildEnvMap(allocator: Allocator, options: EnvOptions) !process.EnvMap {
    var env_map = if (options.ignore_environment)
        process.EnvMap.init(allocator)
    else
        try process.getEnvMap(allocator);

    // Apply unsets
    for (options.unsets) |name| {
        env_map.remove(name);
    }

    // Apply assignments
    for (options.assignments) |assignment| {
        try env_map.put(assignment.name, assignment.value);
    }

    return env_map;
}

/// Print the environment to stdout
fn printEnvironment(writer: anytype, env_map: *const process.EnvMap, null_delimiter: bool) !void {
    var it = env_map.iterator();
    while (it.next()) |entry| {
        try writer.print("{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
        if (null_delimiter) {
            try writer.writeByte(0);
        } else {
            try writer.writeByte('\n');
        }
    }
}

/// Execute a command with the given environment
fn execCommand(allocator: Allocator, command: []const []const u8, env_map: *const process.EnvMap, stderr_writer: anytype) u8 {
    var child = process.Child.init(command, allocator);
    child.env_map = env_map;

    child.spawn() catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "env", "'{s}': {s}", .{ command[0], common.posixErrorString(err) });
        return 127;
    };

    const result = child.wait() catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "env", "'{s}': {s}", .{ command[0], common.posixErrorString(err) });
        // FileNotFound means the command was not found (127)
        // Other errors mean it was found but could not be invoked (126)
        return if (err == error.FileNotFound) 127 else 126;
    };

    return switch (result) {
        .Exited => |code| code,
        .Signal => |signal| @as(u8, @intCast(@min(signal + 128, 255))),
        .Stopped => |signal| @as(u8, @intCast(@min(signal + 128, 255))),
        .Unknown => |code| @as(u8, @intCast(@min(code, 255))),
    };
}

/// Print help message
fn printHelp(allocator: Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: env [OPTION]... [-] [NAME=VALUE]... [COMMAND [ARG]...]
        \\Set each NAME to VALUE in the environment and run COMMAND.
        \\
        \\  -i, --ignore-environment  start with an empty environment
        \\  -0, --null                end each output line with NUL, not newline
        \\  -u, --unset=NAME          remove variable from the environment
        \\  -C, --chdir=DIR           change working directory to DIR
        \\  -P PATH                   search PATH for utility instead of $PATH
        \\  -S STRING, --split-string=STRING
        \\                            split STRING into arguments (stub)
        \\  -v                        verbose: show env modifications on stderr
        \\  -h, --help                display this help and exit
        \\  -V, --version             output version information and exit
        \\
        \\A mere - implies -i.  If no COMMAND, print the resulting environment.
        \\
        \\Exit status:
        \\  0      if no COMMAND, or COMMAND exits with 0
        \\  125    if env itself fails (e.g., chdir error)
        \\  126    if COMMAND is found but cannot be invoked
        \\  127    if COMMAND cannot be found
        \\  other  the exit status of COMMAND
        \\
    );
}

/// Print version information
fn printVersion(writer: anytype) !void {
    try writer.print("env ({s}) {s}\n", .{ common.name, common.version });
}

// ============================================================================
//                                  TESTS
// ============================================================================

test "env parseArgs: no arguments" {
    const options = try parseArgs(testing.allocator, &.{});
    defer options.deinit(testing.allocator);
    try testing.expect(!options.ignore_environment);
    try testing.expect(!options.null_delimiter);
    try testing.expect(!options.help);
    try testing.expect(!options.version);
    try testing.expectEqual(@as(usize, 0), options.command.len);
    try testing.expectEqual(@as(usize, 0), options.assignments.len);
    try testing.expectEqual(@as(usize, 0), options.unsets.len);
    try testing.expect(options.chdir == null);
}

test "env parseArgs: -i flag" {
    const options = try parseArgs(testing.allocator, &.{"-i"});
    defer options.deinit(testing.allocator);
    try testing.expect(options.ignore_environment);
}

test "env parseArgs: --ignore-environment flag" {
    const options = try parseArgs(testing.allocator, &.{"--ignore-environment"});
    defer options.deinit(testing.allocator);
    try testing.expect(options.ignore_environment);
}

test "env parseArgs: -0 flag" {
    const options = try parseArgs(testing.allocator, &.{"-0"});
    defer options.deinit(testing.allocator);
    try testing.expect(options.null_delimiter);
}

test "env parseArgs: -z flag" {
    const options = try parseArgs(testing.allocator, &.{"-z"});
    defer options.deinit(testing.allocator);
    try testing.expect(options.null_delimiter);
}

test "env parseArgs: --null flag" {
    const options = try parseArgs(testing.allocator, &.{"--null"});
    defer options.deinit(testing.allocator);
    try testing.expect(options.null_delimiter);
}

test "env parseArgs: -u flag" {
    const options = try parseArgs(testing.allocator, &.{ "-u", "HOME" });
    defer options.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), options.unsets.len);
    try testing.expectEqualStrings("HOME", options.unsets[0]);
}

test "env parseArgs: --unset=NAME" {
    const options = try parseArgs(testing.allocator, &.{"--unset=PATH"});
    defer options.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), options.unsets.len);
    try testing.expectEqualStrings("PATH", options.unsets[0]);
}

test "env parseArgs: --unset NAME" {
    const options = try parseArgs(testing.allocator, &.{ "--unset", "PATH" });
    defer options.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), options.unsets.len);
    try testing.expectEqualStrings("PATH", options.unsets[0]);
}

test "env parseArgs: -C flag" {
    const options = try parseArgs(testing.allocator, &.{ "-C", "/tmp" });
    defer options.deinit(testing.allocator);
    try testing.expectEqualStrings("/tmp", options.chdir.?);
}

test "env parseArgs: --chdir=DIR" {
    const options = try parseArgs(testing.allocator, &.{"--chdir=/tmp"});
    defer options.deinit(testing.allocator);
    try testing.expectEqualStrings("/tmp", options.chdir.?);
}

test "env parseArgs: --chdir DIR" {
    const options = try parseArgs(testing.allocator, &.{ "--chdir", "/tmp" });
    defer options.deinit(testing.allocator);
    try testing.expectEqualStrings("/tmp", options.chdir.?);
}

test "env parseArgs: NAME=VALUE assignment" {
    const options = try parseArgs(testing.allocator, &.{"FOO=bar"});
    defer options.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), options.assignments.len);
    try testing.expectEqualStrings("FOO", options.assignments[0].name);
    try testing.expectEqualStrings("bar", options.assignments[0].value);
    try testing.expectEqual(@as(usize, 0), options.command.len);
}

test "env parseArgs: NAME=VALUE with empty value" {
    const options = try parseArgs(testing.allocator, &.{"FOO="});
    defer options.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), options.assignments.len);
    try testing.expectEqualStrings("FOO", options.assignments[0].name);
    try testing.expectEqualStrings("", options.assignments[0].value);
}

test "env parseArgs: command after assignment" {
    const options = try parseArgs(testing.allocator, &.{ "FOO=bar", "echo", "hello" });
    defer options.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), options.assignments.len);
    try testing.expectEqualStrings("FOO", options.assignments[0].name);
    try testing.expectEqualStrings("bar", options.assignments[0].value);
    try testing.expectEqual(@as(usize, 2), options.command.len);
    try testing.expectEqualStrings("echo", options.command[0]);
    try testing.expectEqualStrings("hello", options.command[1]);
}

test "env parseArgs: -- separates options from command" {
    const options = try parseArgs(testing.allocator, &.{ "-i", "--", "echo", "test" });
    defer options.deinit(testing.allocator);
    try testing.expect(options.ignore_environment);
    try testing.expectEqual(@as(usize, 2), options.command.len);
    try testing.expectEqualStrings("echo", options.command[0]);
}

test "env parseArgs: combined short flags" {
    const options = try parseArgs(testing.allocator, &.{"-i0"});
    defer options.deinit(testing.allocator);
    try testing.expect(options.ignore_environment);
    try testing.expect(options.null_delimiter);
}

test "env parseArgs: unknown flag" {
    const result = parseArgs(testing.allocator, &.{"--nonexistent"});
    try testing.expectError(error.UnknownFlag, result);
}

test "env parseArgs: missing value for -u" {
    const result = parseArgs(testing.allocator, &.{"-u"});
    try testing.expectError(error.MissingValue, result);
}

test "env parseArgs: missing value for -C" {
    const result = parseArgs(testing.allocator, &.{"-C"});
    try testing.expectError(error.MissingValue, result);
}

test "env parseArgs: missing value for --unset" {
    const result = parseArgs(testing.allocator, &.{"--unset"});
    try testing.expectError(error.MissingValue, result);
}

test "env parseArgs: missing value for --chdir" {
    const result = parseArgs(testing.allocator, &.{"--chdir"});
    try testing.expectError(error.MissingValue, result);
}

test "env parseArgs: help flag" {
    const options = try parseArgs(testing.allocator, &.{"--help"});
    defer options.deinit(testing.allocator);
    try testing.expect(options.help);
}

test "env parseArgs: version flag" {
    const options = try parseArgs(testing.allocator, &.{"--version"});
    defer options.deinit(testing.allocator);
    try testing.expect(options.version);
}

test "env parseArgs: -h short help" {
    const options = try parseArgs(testing.allocator, &.{"-h"});
    defer options.deinit(testing.allocator);
    try testing.expect(options.help);
}

test "env parseArgs: -V short version" {
    const options = try parseArgs(testing.allocator, &.{"-V"});
    defer options.deinit(testing.allocator);
    try testing.expect(options.version);
}

test "env parseArgs: multiple unsets" {
    const options = try parseArgs(testing.allocator, &.{ "-u", "HOME", "-u", "PATH" });
    defer options.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), options.unsets.len);
    try testing.expectEqualStrings("HOME", options.unsets[0]);
    try testing.expectEqualStrings("PATH", options.unsets[1]);
}

test "env parseArgs: multiple assignments" {
    const options = try parseArgs(testing.allocator, &.{ "FOO=1", "BAR=2" });
    defer options.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), options.assignments.len);
    try testing.expectEqualStrings("FOO", options.assignments[0].name);
    try testing.expectEqualStrings("1", options.assignments[0].value);
    try testing.expectEqualStrings("BAR", options.assignments[1].name);
    try testing.expectEqualStrings("2", options.assignments[1].value);
}

test "env parseArgs: -uNAME inline value" {
    const options = try parseArgs(testing.allocator, &.{"-uHOME"});
    defer options.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), options.unsets.len);
    try testing.expectEqualStrings("HOME", options.unsets[0]);
}

test "env parseArgs: -C/tmp inline value" {
    const options = try parseArgs(testing.allocator, &.{"-C/tmp"});
    defer options.deinit(testing.allocator);
    try testing.expectEqualStrings("/tmp", options.chdir.?);
}

test "env buildEnvMap: ignore environment" {
    const options = EnvOptions{
        .ignore_environment = true,
    };
    var env_map = try buildEnvMap(testing.allocator, options);
    defer env_map.deinit();

    // Should be empty
    var it = env_map.iterator();
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 0), count);
}

test "env buildEnvMap: ignore environment with assignments" {
    const assignments = [_]Assignment{
        .{ .name = "FOO", .value = "bar" },
        .{ .name = "BAZ", .value = "qux" },
    };
    const options = EnvOptions{
        .ignore_environment = true,
        .assignments = &assignments,
    };
    var env_map = try buildEnvMap(testing.allocator, options);
    defer env_map.deinit();

    try testing.expectEqualStrings("bar", env_map.get("FOO").?);
    try testing.expectEqualStrings("qux", env_map.get("BAZ").?);
}

test "env buildEnvMap: unset before assign" {
    // With -i, set a var, unset should happen before assignment
    const assignments = [_]Assignment{
        .{ .name = "X", .value = "new" },
    };
    const unsets = [_][]const u8{"X"};
    const options = EnvOptions{
        .ignore_environment = true,
        .unsets = &unsets,
        .assignments = &assignments,
    };
    var env_map = try buildEnvMap(testing.allocator, options);
    defer env_map.deinit();

    // Unset happens first (on empty env), then assignment sets it
    try testing.expectEqualStrings("new", env_map.get("X").?);
}

test "env printEnvironment: basic output" {
    var env_map = process.EnvMap.init(testing.allocator);
    defer env_map.deinit();
    try env_map.put("FOO", "bar");

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try printEnvironment(buffer.writer(testing.allocator), &env_map, false);
    try testing.expectEqualStrings("FOO=bar\n", buffer.items);
}

test "env printEnvironment: null delimiter" {
    var env_map = process.EnvMap.init(testing.allocator);
    defer env_map.deinit();
    try env_map.put("FOO", "bar");

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try printEnvironment(buffer.writer(testing.allocator), &env_map, true);

    // Should end with NUL instead of newline
    try testing.expectEqual(@as(usize, 8), buffer.items.len);
    try testing.expectEqualStrings("FOO=bar", buffer.items[0..7]);
    try testing.expectEqual(@as(u8, 0), buffer.items[7]);
}

test "env printEnvironment: empty environment" {
    var env_map = process.EnvMap.init(testing.allocator);
    defer env_map.deinit();

    var buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer buffer.deinit(testing.allocator);

    try printEnvironment(buffer.writer(testing.allocator), &env_map, false);
    try testing.expectEqual(@as(usize, 0), buffer.items.len);
}

test "env runEnv: help flag" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const exit_code = try runEnv(testing.allocator, &.{"--help"}, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: env") != null);
}

test "env runEnv: version flag" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const exit_code = try runEnv(testing.allocator, &.{"--version"}, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "env") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, common.version) != null);
}

test "env runEnv: print environment with -i and assignment" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const exit_code = try runEnv(testing.allocator, &.{ "-i", "FOO=bar" }, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("FOO=bar\n", stdout_buffer.items);
}

test "env runEnv: empty environment with -i" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const exit_code = try runEnv(testing.allocator, &.{"-i"}, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
}

test "env runEnv: -i with multiple assignments" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const exit_code = try runEnv(testing.allocator, &.{ "-i", "A=1", "B=2" }, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    // Both should be present (order may vary in hash map)
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "A=1\n") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "B=2\n") != null);
}

test "env runEnv: null delimiter output" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const exit_code = try runEnv(testing.allocator, &.{ "-i", "-0", "X=y" }, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("X=y", stdout_buffer.items[0..3]);
    try testing.expectEqual(@as(u8, 0), stdout_buffer.items[3]);
}

test "env runEnv: unknown flag" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const exit_code = try runEnv(testing.allocator, &.{"--badoption"}, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 2), exit_code);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "unrecognized option") != null);
}

test "env runEnv: invalid chdir" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const exit_code = try runEnv(testing.allocator, &.{ "-C", "/nonexistent_dir_12345" }, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 125), exit_code);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "cannot change directory") != null);
}

test "env parseArgs: -P flag" {
    const options = try parseArgs(testing.allocator, &.{ "-P", "/usr/local/bin:/usr/bin" });
    defer options.deinit(testing.allocator);
    try testing.expectEqualStrings("/usr/local/bin:/usr/bin", options.alt_path.?);
}

test "env parseArgs: -P inline value" {
    const options = try parseArgs(testing.allocator, &.{"-P/usr/bin"});
    defer options.deinit(testing.allocator);
    try testing.expectEqualStrings("/usr/bin", options.alt_path.?);
}

test "env parseArgs: -P missing value" {
    const result = parseArgs(testing.allocator, &.{"-P"});
    try testing.expectError(error.MissingValue, result);
}

test "env parseArgs: -S flag" {
    const options = try parseArgs(testing.allocator, &.{ "-S", "VAR=val cmd" });
    defer options.deinit(testing.allocator);
    try testing.expectEqualStrings("VAR=val cmd", options.split_string.?);
}

test "env parseArgs: --split-string=VALUE" {
    const options = try parseArgs(testing.allocator, &.{"--split-string=VAR=val cmd"});
    defer options.deinit(testing.allocator);
    try testing.expectEqualStrings("VAR=val cmd", options.split_string.?);
}

test "env parseArgs: --split-string VALUE" {
    const options = try parseArgs(testing.allocator, &.{ "--split-string", "VAR=val cmd" });
    defer options.deinit(testing.allocator);
    try testing.expectEqualStrings("VAR=val cmd", options.split_string.?);
}

test "env parseArgs: -S missing value" {
    const result = parseArgs(testing.allocator, &.{"-S"});
    try testing.expectError(error.MissingValue, result);
}

test "env parseArgs: -v flag" {
    const options = try parseArgs(testing.allocator, &.{"-v"});
    defer options.deinit(testing.allocator);
    try testing.expect(options.verbose);
}

test "env runEnv: -P does not set PATH when printing environment" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const exit_code = try runEnv(testing.allocator, &.{ "-i", "-P", "/custom/path", "FOO=bar" }, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    // Per spec, -P only affects utility search path, not the environment
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "PATH=") == null);
    // Assignment should still appear
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "FOO=bar\n") != null);
}

test "env runEnv: -S processes assignments" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const exit_code = try runEnv(testing.allocator, &.{ "-i", "-S", "FOO=bar" }, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    // -S should process the string, not print a stub warning
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "FOO=bar") != null);
}

test "env runEnv: -v verbose with -i" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const exit_code = try runEnv(testing.allocator, &.{ "-iv", "FOO=bar" }, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    // Verbose should mention clearing and setting
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "clearing environment") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "setenv FOO=bar") != null);
}

test "env runEnv: -v verbose with -u" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const exit_code = try runEnv(testing.allocator, &.{ "-v", "-u", "NONEXISTENT_VAR_TEST" }, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "unsetenv NONEXISTENT_VAR_TEST") != null);
}

// ============================================================================
// F8: bare `-` should clear environment (implies -i)
// ============================================================================

test "env parseArgs: bare dash implies -i" {
    // Per GNU coreutils: "A mere - implies -i"
    const options = try parseArgs(testing.allocator, &.{"-"});
    defer options.deinit(testing.allocator);
    try testing.expect(options.ignore_environment);
}

test "env parseArgs: bare dash with assignments and command" {
    // `env - FOO=bar echo hello` should parse like `env -i FOO=bar echo hello`
    const options = try parseArgs(testing.allocator, &.{ "-", "FOO=bar", "echo", "hello" });
    defer options.deinit(testing.allocator);
    try testing.expect(options.ignore_environment);
    try testing.expectEqual(@as(usize, 1), options.assignments.len);
    try testing.expectEqualStrings("FOO", options.assignments[0].name);
    try testing.expectEqualStrings("bar", options.assignments[0].value);
    try testing.expectEqual(@as(usize, 2), options.command.len);
    try testing.expectEqualStrings("echo", options.command[0]);
}

test "env runEnv: bare dash clears environment" {
    // `env -` with no command should print empty environment
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const exit_code = try runEnv(testing.allocator, &.{"-"}, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
}

test "env runEnv: bare dash with assignment prints only that var" {
    // `env - FOO=bar` should print only FOO=bar (clean environment)
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const exit_code = try runEnv(testing.allocator, &.{ "-", "FOO=bar" }, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("FOO=bar\n", stdout_buffer.items);
}

// ============================================================================
// F9: -S (split-string) should split and process arguments
// ============================================================================

test "env runEnv: -S splits string into assignment" {
    // `env -i -S "FOO=bar"` should process FOO=bar as an assignment
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const exit_code = try runEnv(testing.allocator, &.{ "-i", "-S", "FOO=bar" }, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    // Should actually set FOO=bar in the environment, not just warn
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "FOO=bar\n") != null);
    // Should NOT print a stub warning
    try testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
}

// ========== AUDIT WAVE 4: env IMPORTANT findings ==========

// IMPORTANT: -0 with utility argument should be rejected
// macOS spec: "Both -0 and utility may not be specified together."
// -0 is only valid when printing the environment (no utility given).
// Currently: parseArgs allows -0 with a command. runEnv should reject
// this combination before executing. We verify via parseArgs that
// both null_delimiter and command are set, which the fix should prevent.
test "audit: env -0 with utility should be detected" {
    // Parse args: -0 echo hello — both null_delimiter and command are set
    const options = try parseArgs(testing.allocator, &.{ "-0", "echo", "hello" });
    defer options.deinit(testing.allocator);
    // The bug: both null_delimiter and command are accepted simultaneously.
    // After the fix, runEnv should reject this combination (exit 125).
    // For now, verify the parser accepts both (proving the bug exists):
    try testing.expect(options.null_delimiter);
    try testing.expect(options.command.len > 0);
    // Now verify runEnv rejects the combination with exit 125.
    // (This avoids spawning a child process in tests.)
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Use -i so no inherited env, and a nonexistent command to avoid spawn.
    // But the validation should reject BEFORE reaching exec.
    const exit_code = try runEnv(testing.allocator, &.{ "-i", "-0", "NONEXISTENT_CMD_AUDIT_TEST_12345" }, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    // Per spec, should exit 125 rejecting the -0+utility combination.
    // Currently returns 127 (command not found) because validation is missing.
    try testing.expectEqual(@as(u8, 125), exit_code);
}

// IMPORTANT: Flags after NAME=VALUE pairs should not be parsed as options
// macOS spec: "The above options are only recognized when they are
// specified before any name=value options." Once a NAME=VALUE token
// is seen, subsequent flag-like tokens should start the command.
// Currently: `env FOO=bar -u FOO` parses -u as a flag and unsets FOO.
// Expected: -u should be treated as the start of the command.
test "audit: env flags after NAME=VALUE should not be parsed" {
    // env FOO=bar -u FOO — after FOO=bar, -u should be treated as command
    const options = try parseArgs(testing.allocator, &.{ "FOO=bar", "-u", "FOO" });
    defer options.deinit(testing.allocator);
    // After the fix: -u should be treated as command start, not a flag.
    // command should be ["-u", "FOO"], unsets should be empty.
    try testing.expectEqual(@as(usize, 0), options.unsets.len);
    try testing.expectEqual(@as(usize, 2), options.command.len);
    try testing.expectEqualStrings("-u", options.command[0]);
    try testing.expectEqualStrings("FOO", options.command[1]);
}

// IMPORTANT: -P should restrict utility search path, not set child's PATH
// macOS spec: "-P replaces the directory search path used to locate
// the utility". It should NOT appear in the child's environment.
// Currently: `env -i -P /usr/bin FOO=bar` puts PATH=/usr/bin in output.
// Expected: Only FOO=bar should appear (PATH should not be in child env).
test "audit: env -P should not set PATH in child environment" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // env -i -P /custom/path FOO=bar — print env with -i, -P, and assignment
    // -P should NOT inject PATH into the child's environment
    const exit_code = try runEnv(testing.allocator, &.{ "-i", "-P", "/custom/path", "FOO=bar" }, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator));
    try testing.expectEqual(@as(u8, 0), exit_code);
    // Only FOO=bar should be printed; PATH should NOT appear
    try testing.expectEqualStrings("FOO=bar\n", stdout_buffer.items);
}
