//! Create directories with optional parent directory creation and permission setting
const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const privilege_test = common.privilege_test;
const testing = std.testing;

/// Command-line arguments for mkdir
const MkdirArgs = struct {
    help: bool = false,
    version: bool = false,
    mode: ?[]const u8 = null,
    parents: bool = false,
    verbose: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .mode = .{ .short = 'm', .desc = "Set file mode (as in chmod)", .value_name = "MODE" },
        .parents = .{ .short = 'p', .desc = "Make parent directories as needed, no error if existing" },
        .verbose = .{ .short = 'v', .desc = "Print a message for each created directory" },
    };
};

/// Options controlling directory creation behavior
const MkdirOptions = struct {
    /// File mode for created directories
    mode: ?std.fs.File.Mode = null,

    /// Create parent directories as needed
    parents: bool = false,

    /// Print a message for each created directory
    verbose: bool = false,
};

/// Main entry point for mkdir command
pub fn main() !void {
    common.utilityMain(run);
}

/// Run mkdir with provided writers for output
fn run(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    const prog_name = "mkdir";

    const parsed_args = common.argparse.ArgParser.parseOrExit(MkdirArgs, allocator, args, prog_name, stderr_writer) catch return @intFromEnum(common.ExitCode.misuse);
    defer allocator.free(parsed_args.positionals);

    // Handle help
    if (parsed_args.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version
    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Check if we have directories to create
    const dirs = parsed_args.positionals;
    if (dirs.len == 0) {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "missing operand", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    // Create options
    var options = MkdirOptions{
        .parents = parsed_args.parents,
        .verbose = parsed_args.verbose,
    };

    // Parse mode if provided
    if (parsed_args.mode) |mode_str| {
        options.mode = parseMode(mode_str) catch {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "invalid mode '{s}'", .{mode_str});
            return @intFromEnum(common.ExitCode.general_error);
        };
    }

    // Process directories - continue processing even if some fail
    var exit_code = common.ExitCode.success;
    for (dirs) |dir_path| {
        createDirectory(dir_path, options, prog_name, stdout_writer, stderr_writer, allocator) catch {
            // Mark overall failure but continue with remaining directories
            exit_code = common.ExitCode.general_error;
            continue;
        };
    }

    return @intFromEnum(exit_code);
}

/// Print help message to provided writer
fn printHelp(allocator: std.mem.Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: mkdir [OPTION]... DIRECTORY...
        \\Create the DIRECTORY(ies), if they do not already exist.
        \\
        \\  -m, --mode=MODE   set file mode (as in chmod)
        \\  -p, --parents     make parent directories as needed, no error if existing
        \\  -v, --verbose     print a message for each created directory
        \\  -h, --help        display this help and exit
        \\  -V, --version     output version information and exit
        \\
        \\Examples:
        \\  mkdir dir1          Create directory 'dir1'
        \\  mkdir -p a/b/c      Create directory tree including parents
        \\  mkdir -m 755 bin    Create directory with permissions rwxr-xr-x
        \\
    );
}

/// Print version information to provided writer
fn printVersion(writer: anytype) !void {
    try writer.print("mkdir ({s}) {s}\n", .{ common.name, common.version });
}

/// Set directory permissions. No-op with warning on Windows.
fn setDirectoryMode(path: []const u8, mode: std.fs.File.Mode, prog_name: []const u8, stderr_writer: anytype, allocator: std.mem.Allocator) !void {
    if (builtin.os.tag == .windows) {
        // Print warning on Windows
        common.printWarningWithProgram(allocator, stderr_writer, prog_name, "mode flag (-m) is not supported on Windows", .{});
        return;
    }

    // Use C chmod function for directories on POSIX systems
    const path_z = std.posix.toPosixPath(path) catch {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "path too long: '{s}'", .{path});
        return error.ChmodFailed;
    };

    const result = std.c.chmod(&path_z, mode);
    if (result != 0) {
        const err = std.posix.errno(result); // Pass the result to errno
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, "cannot set mode on '{s}': {s}", .{ path, @tagName(err) });
        return error.ChmodFailed;
    }
}

/// Parse octal or symbolic mode string (e.g. "755" or "u=rwx,go=rx") into file mode
fn parseMode(mode_str: []const u8) !std.fs.File.Mode {
    if (mode_str.len == 0) {
        return error.InvalidMode;
    }

    // Try octal first: 1-4 octal digits
    if (mode_str.len >= 1 and mode_str.len <= 4) {
        var is_octal = true;
        for (mode_str) |c| {
            if (c < '0' or c > '7') {
                is_octal = false;
                break;
            }
        }
        if (is_octal) {
            var octal: u32 = 0;
            for (mode_str) |c| {
                octal = octal * 8 + (c - '0');
            }
            if (octal > 0o7777) {
                return error.InvalidMode;
            }
            return @intCast(octal);
        }
    }

    // Reject purely numeric strings that aren't valid octal
    var all_numeric = true;
    for (mode_str) |c| {
        if (!std.ascii.isDigit(c)) {
            all_numeric = false;
            break;
        }
    }
    if (all_numeric) {
        return error.InvalidMode;
    }

    // Try symbolic mode parsing (e.g. "u=rwx,go=rx", "a+rx", "go-w")
    return parseSymbolicMode(mode_str);
}

/// Parse a symbolic mode string into a file mode value.
/// Starts from mode 0 and applies each comma-separated clause.
fn parseSymbolicMode(mode_str: []const u8) !std.fs.File.Mode {
    // Accumulate permission bits: user(6..8), group(3..5), other(0..2)
    var result: u32 = 0;

    var iter = std.mem.splitScalar(u8, mode_str, ',');
    while (iter.next()) |clause| {
        result = try applySymbolicClause(result, clause);
    }

    return @intCast(result);
}

/// Apply a single symbolic mode clause (e.g. "u=rwx", "go-w", "a+rx")
fn applySymbolicClause(current: u32, clause: []const u8) !u32 {
    if (clause.len < 2) return error.InvalidMode;

    var i: usize = 0;
    var who: u8 = 0; // bitmask: 1=user, 2=group, 4=other

    // Parse who characters
    while (i < clause.len) {
        switch (clause[i]) {
            'u' => who |= 1,
            'g' => who |= 2,
            'o' => who |= 4,
            'a' => who |= 7,
            '+', '-', '=' => break,
            else => return error.InvalidMode,
        }
        i += 1;
    }

    // Default to 'a' (all) when no who specified
    if (who == 0) who = 7;

    if (i >= clause.len) return error.InvalidMode;

    const op = clause[i];
    i += 1;

    // Parse permission characters
    var perms: u3 = 0;
    while (i < clause.len) {
        switch (clause[i]) {
            'r' => perms |= 4,
            'w' => perms |= 2,
            'x' => perms |= 1,
            else => return error.InvalidMode,
        }
        i += 1;
    }

    var result = current;

    // Apply to each target
    if (who & 1 != 0) { // user
        switch (op) {
            '+' => result |= @as(u32, perms) << 6,
            '-' => result &= ~(@as(u32, perms) << 6),
            '=' => {
                result &= ~@as(u32, 0o700);
                result |= @as(u32, perms) << 6;
            },
            else => return error.InvalidMode,
        }
    }
    if (who & 2 != 0) { // group
        switch (op) {
            '+' => result |= @as(u32, perms) << 3,
            '-' => result &= ~(@as(u32, perms) << 3),
            '=' => {
                result &= ~@as(u32, 0o070);
                result |= @as(u32, perms) << 3;
            },
            else => return error.InvalidMode,
        }
    }
    if (who & 4 != 0) { // other
        switch (op) {
            '+' => result |= @as(u32, perms),
            '-' => result &= ~@as(u32, perms),
            '=' => {
                result &= ~@as(u32, 0o007);
                result |= @as(u32, perms);
            },
            else => return error.InvalidMode,
        }
    }

    return result;
}

/// Convert system error to user-friendly POSIX-style message
/// Create directory with specified options
fn createDirectory(path: []const u8, options: MkdirOptions, prog_name: []const u8, stdout_writer: anytype, stderr_writer: anytype, allocator: std.mem.Allocator) !void {
    if (options.parents) {
        try createPathComponents(path, options, prog_name, stdout_writer, stderr_writer, allocator);
    } else {
        std.fs.cwd().makeDir(path) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "cannot create directory '{s}': {s}", .{ path, common.posixErrorString(err) });
            return err;
        };

        // Set mode if specified
        if (options.mode) |mode| {
            try setDirectoryMode(path, mode, prog_name, stderr_writer, allocator);
        }

        if (options.verbose) {
            try stdout_writer.print("{s}: created directory '{s}'\n", .{ prog_name, path });
        }
    }
}

/// Create path components one at a time, supporting -v per directory
/// and -m on the leaf directory only (GNU behavior).
fn createPathComponents(path: []const u8, options: MkdirOptions, prog_name: []const u8, stdout_writer: anytype, stderr_writer: anytype, allocator: std.mem.Allocator) !void {
    // Handle absolute paths - start with "/"
    const is_absolute = path.len > 0 and path[0] == '/';

    // Count non-empty components to identify the leaf
    var count_iter = std.mem.splitScalar(u8, path, '/');
    var total_components: usize = 0;
    while (count_iter.next()) |component| {
        if (component.len > 0) total_components += 1;
    }

    // Split path into components
    var iter = std.mem.splitScalar(u8, path, '/');

    // Build up the cumulative path
    var cumulative = std.ArrayListUnmanaged(u8){};
    defer cumulative.deinit(allocator);

    if (is_absolute) {
        try cumulative.append(allocator, '/');
    }

    var first = true;
    var component_index: usize = 0;
    while (iter.next()) |component| {
        // Skip empty components (from double slashes or trailing slashes)
        if (component.len == 0) continue;

        component_index += 1;
        const is_leaf = (component_index == total_components);

        // Add separator between components (not before first)
        if (!first and !(cumulative.items.len == 1 and cumulative.items[0] == '/')) {
            try cumulative.append(allocator, '/');
        }
        first = false;

        try cumulative.appendSlice(allocator, component);

        const current_path = cumulative.items;

        // Try to create this component
        std.fs.cwd().makeDir(current_path) catch |err| switch (err) {
            error.PathAlreadyExists => continue, // -p: silently skip existing
            else => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, "cannot create directory '{s}': {s}", .{ current_path, common.posixErrorString(err) });
                return err;
            },
        };

        // Directory was created successfully
        // GNU behavior: -m mode applies to the leaf directory only
        if (is_leaf) {
            if (options.mode) |mode| {
                try setDirectoryMode(current_path, mode, prog_name, stderr_writer, allocator);
            }
        }

        // Print verbose message for each directory created
        if (options.verbose) {
            try stdout_writer.print("{s}: created directory '{s}'\n", .{ prog_name, current_path });
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "mkdir creates single directory" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteDir("test_dir") catch {};

    const args = [_][]const u8{"test_dir"};
    const result = try run(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify directory was created
    var test_dir = std.fs.cwd().openDir("test_dir", .{}) catch |err| {
        return err;
    };
    test_dir.close();
}

test "mkdir with parents flag creates directory tree" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteTree("test_parent") catch {};

    const args = [_][]const u8{ "-p", "test_parent/test_child" };
    const result = try run(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify directories were created
    var parent_dir = std.fs.cwd().openDir("test_parent", .{}) catch |err| {
        return err;
    };
    defer parent_dir.close();

    var child_dir = parent_dir.openDir("test_child", .{}) catch |err| {
        return err;
    };
    child_dir.close();
}

test "mkdir with verbose flag prints creation messages" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteDir("test_verbose") catch {};

    const args = [_][]const u8{ "-v", "test_verbose" };
    const result = try run(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "mkdir: created directory 'test_verbose'") != null);
}

test "mkdir with mode flag sets permissions" {
    if (builtin.os.tag == .windows) {
        return;
    }

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteDir("test_mode") catch {};

    const args = [_][]const u8{ "-m", "755", "test_mode" };
    const result = try run(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify directory exists and has correct permissions
    const stat = try std.fs.cwd().statFile("test_mode");
    const mode = stat.mode & 0o777;
    try testing.expectEqual(@as(u32, 0o755), mode);
}

test "mkdir fails for existing directory without parents flag" {
    // Create directory first
    try std.fs.cwd().makeDir("test_existing");
    defer std.fs.cwd().deleteDir("test_existing") catch {};

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"test_existing"};
    const result = try run(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "File exists") != null);
}

test "mkdir with parents flag succeeds for existing directory" {
    // Create directory first
    try std.fs.cwd().makeDir("test_existing_p");
    defer std.fs.cwd().deleteDir("test_existing_p") catch {};

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-p", "test_existing_p" };
    const result = try run(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
}

test "mkdir fails with missing operand" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{};
    const result = try run(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 2), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "missing operand") != null);
}

test "mkdir shows help with -h flag" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-h"};
    const result = try run(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Usage: mkdir") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "Create the DIRECTORY") != null);
}

test "mkdir shows version with -V flag" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"-V"};
    const result = try run(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "mkdir (vibeutils)") != null);
}

test "mkdir handles invalid mode" {
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{ "-m", "999", "test_invalid" };
    const result = try run(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));

    try testing.expectEqual(@as(u8, 1), result);
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "invalid mode") != null);
}

test "mkdir combines parents and verbose flags" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteTree("test_combo") catch {};

    const args = [_][]const u8{ "-pv", "test_combo/sub/deep" };
    const result = try run(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "created directory") != null);
}

test "mkdir handles multiple directories" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteDir("test_multi1") catch {};
    defer std.fs.cwd().deleteDir("test_multi2") catch {};
    defer std.fs.cwd().deleteDir("test_multi3") catch {};

    const args = [_][]const u8{ "test_multi1", "test_multi2", "test_multi3" };
    const result = try run(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify all directories were created
    var dir1 = std.fs.cwd().openDir("test_multi1", .{}) catch |err| {
        return err;
    };
    dir1.close();

    var dir2 = std.fs.cwd().openDir("test_multi2", .{}) catch |err| {
        return err;
    };
    dir2.close();

    var dir3 = std.fs.cwd().openDir("test_multi3", .{}) catch |err| {
        return err;
    };
    dir3.close();
}

test "parseMode handles valid octal modes" {
    try testing.expectEqual(@as(std.fs.File.Mode, 0o755), try parseMode("755"));
    try testing.expectEqual(@as(std.fs.File.Mode, 0o644), try parseMode("644"));
    try testing.expectEqual(@as(std.fs.File.Mode, 0o777), try parseMode("777"));
    try testing.expectEqual(@as(std.fs.File.Mode, 0o000), try parseMode("000"));
}

test "parseMode rejects invalid modes" {
    try testing.expectError(error.InvalidMode, parseMode(""));
    try testing.expectError(error.InvalidMode, parseMode("abc"));
    try testing.expectError(error.InvalidMode, parseMode("888"));
    try testing.expectError(error.InvalidMode, parseMode("1234567890")); // Too long/large
}

test "parseMode handles symbolic modes" {
    // u=rwx,go=rx -> 755
    try testing.expectEqual(@as(std.fs.File.Mode, 0o755), try parseMode("u=rwx,go=rx"));
    // a+rx -> 555 (from base 0)
    try testing.expectEqual(@as(std.fs.File.Mode, 0o555), try parseMode("a+rx"));
    // u=rwx -> 700
    try testing.expectEqual(@as(std.fs.File.Mode, 0o700), try parseMode("u=rwx"));
    // go-w from base 0 -> 0 (no change)
    try testing.expectEqual(@as(std.fs.File.Mode, 0o000), try parseMode("go-w"));
    // a=rwx -> 777
    try testing.expectEqual(@as(std.fs.File.Mode, 0o777), try parseMode("a=rwx"));
}

test "mkdir handles paths with double slashes" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteTree("test_slashes") catch {};

    const args = [_][]const u8{ "-p", "test_slashes//sub//deep" };
    const result = try run(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify directory was created
    var test_dir = std.fs.cwd().openDir("test_slashes/sub/deep", .{}) catch |err| {
        return err;
    };
    test_dir.close();
}

test "mkdir handles paths with dot components" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteTree("test_dots") catch {};

    const args = [_][]const u8{ "-p", "test_dots/../test_dots/./sub" };
    const result = try run(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify directory was created (note: filesystem normalizes the path)
    var test_dir = std.fs.cwd().openDir("test_dots/sub", .{}) catch |err| {
        return err;
    };
    test_dir.close();
}

test "mkdir verbose with parents shows directory creation" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteTree("test_verbose_parents") catch {};

    const args = [_][]const u8{ "-pv", "test_verbose_parents/new_child" };
    const result = try run(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);
    try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "created directory") != null);
}

test "mkdir with mode applies to all created directories with -p" {
    if (builtin.os.tag == .windows) {
        // Skip on Windows - mode setting not supported
        return;
    }

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteTree("test_mode_parents") catch {};

    const args = [_][]const u8{ "-pm", "755", "test_mode_parents/sub/deep" };
    const result = try run(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify all directories were created (mode testing would require platform-specific code)
    var test_dir = std.fs.cwd().openDir("test_mode_parents/sub/deep", .{}) catch |err| {
        return err;
    };
    test_dir.close();
}

test "mkdir -pv prints each intermediate directory" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteTree("test_pv_each") catch {};

    const args = [_][]const u8{ "-pv", "test_pv_each/a/b" };
    const result = try run(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Should have verbose output for each created directory
    const output = stdout_buffer.items;
    try testing.expect(std.mem.indexOf(u8, output, "test_pv_each'") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test_pv_each/a'") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test_pv_each/a/b'") != null);
}

test "mkdir -pm sets mode on leaf only (GNU behavior)" {
    if (builtin.os.tag == .windows) return;

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteTree("test_pm_mode") catch {};

    const args = [_][]const u8{ "-pm", "700", "test_pm_mode/sub/deep" };
    const result = try run(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify mode on the leaf directory
    const stat = try std.fs.cwd().statFile("test_pm_mode/sub/deep");
    const mode = stat.mode & 0o777;
    try testing.expectEqual(@as(u32, 0o700), mode);

    // Intermediate directory should NOT have mode 700 (GNU behavior)
    const stat_mid = try std.fs.cwd().statFile("test_pm_mode/sub");
    const mode_mid = stat_mid.mode & 0o777;
    try testing.expect(mode_mid != 0o700);
}

test "mkdir -pm applies mode to leaf only, not parents (GNU behavior)" {
    if (builtin.os.tag == .windows) return;

    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteTree("test_pm_all_levels") catch {};

    const args = [_][]const u8{ "-pm", "700", "test_pm_all_levels/mid/leaf" };
    const result = try run(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // First parent should NOT have mode 700 (GNU: intermediates get default)
    const stat_root = try std.fs.cwd().statFile("test_pm_all_levels");
    const mode_root = stat_root.mode & 0o777;
    try testing.expect(mode_root != 0o700);

    // Middle intermediate should NOT have mode 700
    const stat_mid = try std.fs.cwd().statFile("test_pm_all_levels/mid");
    const mode_mid = stat_mid.mode & 0o777;
    try testing.expect(mode_mid != 0o700);

    // Leaf directory should have mode 700
    const stat_leaf = try std.fs.cwd().statFile("test_pm_all_levels/mid/leaf");
    const mode_leaf = stat_leaf.mode & 0o777;
    try testing.expectEqual(@as(u32, 0o700), mode_leaf);
}

test "mkdir -p handles absolute-like paths" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);

    // Create a temp dir and use it as base for an absolute-ish path
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const deep_path = try std.fmt.allocPrint(testing.allocator, "{s}/abs_test/sub/dir", .{tmp_path});
    defer testing.allocator.free(deep_path);

    const args = [_][]const u8{ "-p", deep_path };
    const result = try run(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify the directory was created
    var test_dir = std.fs.cwd().openDir(deep_path, .{}) catch |err| {
        return err;
    };
    test_dir.close();
}

test "mkdir -p with trailing slashes" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    defer std.fs.cwd().deleteTree("test_trailing") catch {};

    const args = [_][]const u8{ "-p", "test_trailing/sub/" };
    const result = try run(testing.allocator, &args, stdout_buffer.writer(testing.allocator), common.null_writer);

    try testing.expectEqual(@as(u8, 0), result);

    // Verify directory was created
    var test_dir = std.fs.cwd().openDir("test_trailing/sub", .{}) catch |err| {
        return err;
    };
    test_dir.close();
}

test "mkdir error for existing directory uses POSIX-style message" {
    // Create directory first
    try std.fs.cwd().makeDir("test_posix_err");
    defer std.fs.cwd().deleteDir("test_posix_err") catch {};

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const args = [_][]const u8{"test_posix_err"};
    const result = try run(testing.allocator, &args, common.null_writer, stderr_buffer.writer(testing.allocator));

    // Should fail with non-zero exit code
    try testing.expectEqual(@as(u8, 1), result);

    const stderr_output = stderr_buffer.items;

    // Error message should use POSIX-style "File exists" not Zig-style "PathAlreadyExists"
    try testing.expect(std.mem.indexOf(u8, stderr_output, "File exists") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_output, "PathAlreadyExists") == null);

    // Should follow project error format: "mkdir: cannot create directory 'test_posix_err': File exists"
    try testing.expect(std.mem.indexOf(u8, stderr_output, "cannot create directory 'test_posix_err'") != null);
}
