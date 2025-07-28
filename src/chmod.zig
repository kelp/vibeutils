const std = @import("std");
const common = @import("common");
const testing = std.testing;
const builtin = @import("builtin");

const ChmodArgs = struct {
    help: bool = false,
    version: bool = false,
    changes: bool = false,
    silent: bool = false,
    verbose: bool = false,
    recursive: bool = false,
    reference: ?[]const u8 = null,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .changes = .{ .short = 'c', .desc = "Like verbose but report only when a change is made" },
        .silent = .{ .short = 'f', .desc = "Suppress most error messages" },
        .verbose = .{ .short = 'v', .desc = "Output a diagnostic for every file processed" },
        .recursive = .{ .short = 'R', .desc = "Change files and directories recursively" },
        .reference = .{ .desc = "Use reference file's mode instead of MODE", .value_name = "RFILE" },
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // Parse arguments using new parser
    const args = common.argparse.ArgParser.parseProcess(ChmodArgs, allocator) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.fatal("invalid argument\nTry 'chmod --help' for more information.", .{});
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

    const positionals = args.positionals;

    // When using --reference, we only need file arguments (no mode)
    const using_reference = args.reference != null;
    if (using_reference) {
        if (positionals.len < 1) {
            common.fatal("missing file operand\nTry 'chmod --help' for more information.", .{});
        }
    } else {
        if (positionals.len < 2) {
            common.fatal("missing operand\nTry 'chmod --help' for more information.", .{});
        }
    }

    // When using --reference, all positionals are files; otherwise first is mode
    const mode_str = if (using_reference) "" else positionals[0];
    const files = if (using_reference) positionals else positionals[1..];

    // Create options
    const options = ChmodOptions{
        .changes_only = args.changes,
        .quiet = args.silent,
        .verbose = args.verbose,
        .recursive = args.recursive,
        .reference_file = args.reference,
    };

    const stdout = std.io.getStdOut().writer();
    try chmodFiles(allocator, mode_str, files, stdout, options);
}

fn printHelp() !void {
    const help_text =
        \\Usage: chmod [OPTION]... MODE[,MODE]... FILE...
        \\  or:  chmod [OPTION]... OCTAL-MODE FILE...
        \\  or:  chmod [OPTION]... --reference=RFILE FILE...
        \\Change the mode of each FILE to MODE.
        \\With --reference, change the mode of each FILE to that of RFILE.
        \\
        \\  -c, --changes          like verbose but report only when a change is made
        \\  -f, --silent           suppress most error messages
        \\  -v, --verbose          output a diagnostic for every file processed
        \\  -R, --recursive        change files and directories recursively
        \\      --reference=RFILE  use RFILE's mode instead of MODE values
        \\      --help             display this help and exit
        \\      --version          output version information and exit
        \\
        \\Each MODE is of the form '[ugoa]*[-+=]([rwxXst]*|[ugo])'.
        \\
        \\Examples:
        \\  chmod 755 file.txt               Set file permissions to rwxr-xr-x
        \\  chmod u+x script.sh              Add execute permission for owner
        \\  chmod -R go-w /path/to/dir       Recursively remove write for group/other
        \\
    ;
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(help_text);
}

fn printVersion() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("chmod ({s}) {s}\n", .{ common.name, common.version });
}

const ChmodOptions = struct {
    changes_only: bool = false,
    quiet: bool = false,
    verbose: bool = false,
    recursive: bool = false,
    reference_file: ?[]const u8 = null,
};

const Mode = struct {
    user: u3,
    group: u3,
    other: u3,
    setuid: bool = false,
    setgid: bool = false,
    sticky: bool = false,

    fn toOctal(self: Mode) u32 {
        var result = (@as(u32, self.user) << 6) | (@as(u32, self.group) << 3) | @as(u32, self.other);
        if (self.setuid) result |= 0o4000;
        if (self.setgid) result |= 0o2000;
        if (self.sticky) result |= 0o1000;
        return result;
    }

    fn fromOctal(octal: u32) Mode {
        return Mode{
            .user = @truncate((octal >> 6) & 0x7),
            .group = @truncate((octal >> 3) & 0x7),
            .other = @truncate(octal & 0x7),
            .setuid = (octal & 0o4000) != 0,
            .setgid = (octal & 0o2000) != 0,
            .sticky = (octal & 0o1000) != 0,
        };
    }
};

// Custom error types
const ChmodError = error{
    InvalidMode,
    InvalidOctalMode,
    ReferenceFileNotFound,
    PathTraversal,
    UserCancelled,
};

fn chmodFiles(allocator: std.mem.Allocator, mode_str: []const u8, files: []const []const u8, writer: anytype, options: ChmodOptions) !void {
    // Handle reference file mode if specified
    var reference_mode: ?Mode = null;
    if (options.reference_file) |ref_file| {
        const ref_stat = std.fs.cwd().statFile(ref_file) catch |err| {
            if (!options.quiet) {
                common.printError("cannot access reference file '{s}': {s}", .{ ref_file, @errorName(err) });
            }
            std.process.exit(@intFromEnum(common.ExitCode.general_error));
        };
        reference_mode = Mode.fromOctal(@as(u32, @intCast(ref_stat.mode & 0o7777)));
    }

    // Determine mode to use - reference mode takes precedence
    const use_reference = reference_mode != null;

    // Check if this is a symbolic mode (contains letters) - only relevant if not using reference
    const is_symbolic = if (use_reference) false else blk: {
        for (mode_str) |c| {
            if (std.ascii.isAlphabetic(c) or c == '+' or c == '-' or c == '=' or c == ',') {
                break :blk true;
            }
        }
        break :blk false;
    };

    for (files) |file_path| {
        // Path traversal protection - normalize the path
        var normalized_buf: [std.fs.max_path_bytes]u8 = undefined;
        const normalized = if (std.fs.cwd().access(file_path, .{})) |_| blk: {
            break :blk std.fs.realpath(file_path, &normalized_buf) catch file_path;
        } else |_| blk: {
            // File doesn't exist, pass the original path for error handling
            break :blk file_path;
        };

        // Additional safety check for critical system paths
        if (isCriticalSystemPath(normalized)) {
            if (!options.quiet) {
                common.printError("cannot modify '{s}': Operation not permitted", .{file_path});
            }
            continue;
        }

        if (options.recursive) {
            // For recursive operations, check if path is a directory first
            const stat_result = std.fs.cwd().statFile(file_path) catch |err| {
                if (!options.quiet) {
                    common.printError("cannot access '{s}': {s}", .{ file_path, @errorName(err) });
                }
                continue;
            };

            if (stat_result.kind == .directory) {
                try chmodRecursive(allocator, file_path, mode_str, is_symbolic, use_reference, reference_mode, writer, options);
            } else {
                // Apply to single file
                if (use_reference) {
                    try applyModeToFile(file_path, reference_mode.?, writer, options);
                } else if (is_symbolic) {
                    try applySymbolicModeToFile(file_path, mode_str, writer, options);
                } else {
                    const mode = try parseMode(mode_str);
                    try applyModeToFile(file_path, mode, writer, options);
                }
            }
        } else {
            // Non-recursive processing
            if (use_reference) {
                applyModeToFile(file_path, reference_mode.?, writer, options) catch |err| {
                    if (!options.quiet) {
                        common.printError("cannot access '{s}': {s}", .{ file_path, @errorName(err) });
                    }
                };
            } else if (is_symbolic) {
                applySymbolicModeToFile(file_path, mode_str, writer, options) catch |err| {
                    if (!options.quiet) {
                        common.printError("cannot access '{s}': {s}", .{ file_path, @errorName(err) });
                    }
                };
            } else {
                const mode = parseMode(mode_str) catch |err| switch (err) {
                    ChmodError.InvalidMode, ChmodError.InvalidOctalMode => {
                        if (!options.quiet) {
                            common.printError("invalid mode: '{s}'", .{mode_str});
                        }
                        std.process.exit(@intFromEnum(common.ExitCode.general_error));
                    },
                    else => return err,
                };

                applyModeToFile(file_path, mode, writer, options) catch |err| {
                    if (!options.quiet) {
                        common.printError("cannot access '{s}': {s}", .{ file_path, @errorName(err) });
                    }
                };
            }
        }
    }
}

fn chmodRecursive(allocator: std.mem.Allocator, dir_path: []const u8, mode_str: []const u8, is_symbolic: bool, use_reference: bool, reference_mode: ?Mode, writer: anytype, options: ChmodOptions) !void {
    // Apply mode to the directory itself first
    if (use_reference) {
        try applyModeToFile(dir_path, reference_mode.?, writer, options);
    } else if (is_symbolic) {
        try applySymbolicModeToFile(dir_path, mode_str, writer, options);
    } else {
        const mode = try parseMode(mode_str);
        try applyModeToFile(dir_path, mode, writer, options);
    }

    // Path traversal protection for directory
    var normalized_buf: [std.fs.max_path_bytes]u8 = undefined;
    const normalized = std.fs.realpath(dir_path, &normalized_buf) catch dir_path;

    if (isCriticalSystemPath(normalized)) {
        if (!options.quiet) {
            common.printError("cannot modify '{s}': Operation not permitted", .{dir_path});
        }
        return;
    }

    // Open directory for iteration
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        if (!options.quiet) {
            common.printError("cannot access '{s}': {s}", .{ dir_path, @errorName(err) });
        }
        return;
    };
    defer dir.close();

    // Iterate through directory entries
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        // Skip . and .. entries
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
            continue;
        }

        // Build full path for the entry
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(full_path);

        switch (entry.kind) {
            .directory => {
                // Recursively process subdirectory
                try chmodRecursive(allocator, full_path, mode_str, is_symbolic, use_reference, reference_mode, writer, options);
            },
            .file, .sym_link => {
                // Apply mode to file or symlink
                if (use_reference) {
                    applyModeToFile(full_path, reference_mode.?, writer, options) catch |err| {
                        if (!options.quiet) {
                            common.printError("cannot access '{s}': {s}", .{ full_path, @errorName(err) });
                        }
                    };
                } else if (is_symbolic) {
                    applySymbolicModeToFile(full_path, mode_str, writer, options) catch |err| {
                        if (!options.quiet) {
                            common.printError("cannot access '{s}': {s}", .{ full_path, @errorName(err) });
                        }
                    };
                } else {
                    const mode = parseMode(mode_str) catch |err| {
                        if (!options.quiet) {
                            common.printError("invalid mode: '{s}'", .{mode_str});
                        }
                        return err;
                    };
                    applyModeToFile(full_path, mode, writer, options) catch |err| {
                        if (!options.quiet) {
                            common.printError("cannot access '{s}': {s}", .{ full_path, @errorName(err) });
                        }
                    };
                }
            },
            else => {
                // Handle other file types (block device, character device, etc.)
                if (use_reference) {
                    applyModeToFile(full_path, reference_mode.?, writer, options) catch |err| {
                        if (!options.quiet) {
                            common.printError("cannot access '{s}': {s}", .{ full_path, @errorName(err) });
                        }
                    };
                } else if (is_symbolic) {
                    applySymbolicModeToFile(full_path, mode_str, writer, options) catch |err| {
                        if (!options.quiet) {
                            common.printError("cannot access '{s}': {s}", .{ full_path, @errorName(err) });
                        }
                    };
                } else {
                    const mode = parseMode(mode_str) catch |err| {
                        if (!options.quiet) {
                            common.printError("invalid mode: '{s}'", .{mode_str});
                        }
                        return err;
                    };
                    applyModeToFile(full_path, mode, writer, options) catch |err| {
                        if (!options.quiet) {
                            common.printError("cannot access '{s}': {s}", .{ full_path, @errorName(err) });
                        }
                    };
                }
            },
        }
    }
}

fn parseMode(mode_str: []const u8) !Mode {
    // Try octal mode first (Phase 1)
    if (mode_str.len == 3 or mode_str.len == 4) {
        var is_octal = true;

        // Check if all characters are octal digits
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
                return ChmodError.InvalidOctalMode;
            }

            return Mode.fromOctal(octal);
        }
    }

    // Check for purely numeric strings that are not valid octal
    var all_numeric = true;
    for (mode_str) |c| {
        if (!std.ascii.isDigit(c)) {
            all_numeric = false;
            break;
        }
    }

    if (all_numeric) {
        // It's numeric but not valid octal (wrong length or invalid digits)
        return ChmodError.InvalidOctalMode;
    }

    // Try symbolic mode parsing (Phase 2)
    return parseSymbolicModeString(mode_str);
}

// Symbolic mode parsing structures and functions
const SymbolicMode = struct {
    who: u8, // Bitmask: 1=user, 2=group, 4=other, 8=all
    op: u8, // Operation: +, -, =
    perms: u8, // Permissions: r=4, w=2, x=1
};

fn parseSymbolicModeString(mode_str: []const u8) !Mode {
    // Start with a base mode of 0 - symbolic modes will be applied to current file mode in practice
    var base_mode = Mode.fromOctal(0o000); // Start with no permissions for symbolic parsing

    // Split by commas for multiple operations
    var iter = std.mem.splitScalar(u8, mode_str, ',');
    while (iter.next()) |clause| {
        try applySymbolicMode(&base_mode, std.mem.trim(u8, clause, " "));
    }

    return base_mode;
}

fn applySymbolicMode(mode: *Mode, clause: []const u8) !void {
    if (clause.len < 2) return ChmodError.InvalidMode;

    // Parse who (ugoa)
    var i: usize = 0;
    var who: u8 = 0;

    while (i < clause.len) {
        switch (clause[i]) {
            'u' => who |= 1,
            'g' => who |= 2,
            'o' => who |= 4,
            'a' => who |= 7, // all = user + group + other
            '+', '-', '=' => break,
            else => return ChmodError.InvalidMode,
        }
        i += 1;
    }

    // If no who specified, default to 'a' (all)
    if (who == 0) who = 7;

    if (i >= clause.len) return ChmodError.InvalidMode;

    // Parse operation
    const op = clause[i];
    if (op != '+' and op != '-' and op != '=') {
        return ChmodError.InvalidMode;
    }
    i += 1;

    // Parse permissions
    var perms: u8 = 0;
    while (i < clause.len) {
        switch (clause[i]) {
            'r' => perms |= 4,
            'w' => perms |= 2,
            'x' => perms |= 1,
            's' => perms |= 8, // Special bit (setuid/setgid)
            't' => perms |= 16, // Sticky bit
            'X' => perms |= 1, // Execute if directory or already executable
            else => return ChmodError.InvalidMode,
        }
        i += 1;
    }

    // Apply the changes
    applyPermissionChange(mode, who, op, perms);
}

fn applyPermissionChange(mode: *Mode, who: u8, op: u8, perms: u8) void {
    // Apply to user
    if (who & 1 != 0) {
        switch (op) {
            '+' => mode.user |= @as(u3, @truncate(perms)),
            '-' => mode.user &= ~@as(u3, @truncate(perms)),
            '=' => mode.user = @as(u3, @truncate(perms)),
            else => {},
        }
    }

    // Apply to group
    if (who & 2 != 0) {
        switch (op) {
            '+' => mode.group |= @as(u3, @truncate(perms)),
            '-' => mode.group &= ~@as(u3, @truncate(perms)),
            '=' => mode.group = @as(u3, @truncate(perms)),
            else => {},
        }
    }

    // Apply to other
    if (who & 4 != 0) {
        switch (op) {
            '+' => mode.other |= @as(u3, @truncate(perms)),
            '-' => mode.other &= ~@as(u3, @truncate(perms)),
            '=' => mode.other = @as(u3, @truncate(perms)),
            else => {},
        }
    }
}

fn applyModeToFile(file_path: []const u8, mode: Mode, writer: anytype, options: ChmodOptions) !void {
    // Get current file stats
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.PermissionDenied,
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    const old_mode = @as(u32, @intCast(stat.mode & 0o7777));
    const new_mode = mode.toOctal();

    // Apply the new mode using the file's chmod method
    try file.chmod(@as(std.fs.File.Mode, @intCast(new_mode)));

    // Report changes if requested
    if (options.verbose or (options.changes_only and old_mode != new_mode)) {
        try writer.print("mode of '{s}' changed from {o:0>3} ({s}) to {o:0>3} ({s})\n", .{
            file_path,
            old_mode,
            modeToString(old_mode),
            new_mode,
            modeToString(new_mode),
        });
    }
}

fn applySymbolicModeToFile(file_path: []const u8, mode_str: []const u8, writer: anytype, options: ChmodOptions) !void {
    // Get current file stats
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.PermissionDenied,
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    const old_mode = @as(u32, @intCast(stat.mode & 0o7777));

    // Start with current mode
    var new_mode_struct = Mode.fromOctal(old_mode);

    // Apply symbolic changes
    var iter = std.mem.splitScalar(u8, mode_str, ',');
    while (iter.next()) |clause| {
        try applySymbolicMode(&new_mode_struct, std.mem.trim(u8, clause, " "));
    }

    const new_mode = new_mode_struct.toOctal();

    // Apply the new mode using the file's chmod method
    try file.chmod(@as(std.fs.File.Mode, @intCast(new_mode)));

    // Report changes if requested
    if (options.verbose or (options.changes_only and old_mode != new_mode)) {
        try writer.print("mode of '{s}' changed from {o:0>3} ({s}) to {o:0>3} ({s})\n", .{
            file_path,
            old_mode,
            modeToString(old_mode),
            new_mode,
            modeToString(new_mode),
        });
    }
}

fn modeToString(mode: u32) [9]u8 {
    var result = [_]u8{'-'} ** 9;

    // User permissions
    if (mode & 0o400 != 0) result[0] = 'r';
    if (mode & 0o200 != 0) result[1] = 'w';
    if (mode & 0o100 != 0) result[2] = 'x';

    // Group permissions
    if (mode & 0o040 != 0) result[3] = 'r';
    if (mode & 0o020 != 0) result[4] = 'w';
    if (mode & 0o010 != 0) result[5] = 'x';

    // Other permissions
    if (mode & 0o004 != 0) result[6] = 'r';
    if (mode & 0o002 != 0) result[7] = 'w';
    if (mode & 0o001 != 0) result[8] = 'x';

    // Handle special permissions in execute positions
    if (mode & 0o4000 != 0) { // setuid
        result[2] = if (mode & 0o100 != 0) 's' else 'S';
    }
    if (mode & 0o2000 != 0) { // setgid
        result[5] = if (mode & 0o010 != 0) 's' else 'S';
    }
    if (mode & 0o1000 != 0) { // sticky
        result[8] = if (mode & 0o001 != 0) 't' else 'T';
    }

    return result;
}

/// Check if a path is a critical system path that should not be modified
fn isCriticalSystemPath(path: []const u8) bool {
    const critical_paths = [_][]const u8{
        "/bin",
        "/boot",
        "/dev",
        "/etc",
        "/lib",
        "/lib32",
        "/lib64",
        "/proc",
        "/root",
        "/sbin",
        "/sys",
        "/usr",
        "/var",
    };

    for (critical_paths) |critical| {
        if (std.mem.eql(u8, path, critical)) {
            return true;
        }
        // Check if path starts with critical path followed by /
        if (path.len > critical.len and path[critical.len] == '/' and std.mem.startsWith(u8, path, critical)) {
            return true;
        }
    }
    return false;
}

// Test helper function for Phase 1 tests
fn chmod(allocator: std.mem.Allocator, args: []const []const u8, writer: anytype) !void {
    if (args.len < 2) {
        return error.InvalidArguments;
    }

    const mode_str = args[0];
    const files = args[1..];
    const options = ChmodOptions{};

    try chmodFiles(allocator, mode_str, files, writer, options);
}

// ============================================================================
// TESTS - Phase 1: Basic numeric mode parsing and application
// ============================================================================

test "parseMode handles 3-digit octal modes" {
    const mode = try parseMode("755");
    try testing.expectEqual(@as(u3, 7), mode.user);
    try testing.expectEqual(@as(u3, 5), mode.group);
    try testing.expectEqual(@as(u3, 5), mode.other);
    try testing.expectEqual(@as(u32, 0o755), mode.toOctal());
}

test "parseMode handles 4-digit octal modes" {
    const mode = try parseMode("0644");
    try testing.expectEqual(@as(u3, 6), mode.user);
    try testing.expectEqual(@as(u3, 4), mode.group);
    try testing.expectEqual(@as(u3, 4), mode.other);
    try testing.expectEqual(@as(u32, 0o644), mode.toOctal());
}

test "parseMode rejects invalid octal digits" {
    try testing.expectError(ChmodError.InvalidOctalMode, parseMode("888"));
    try testing.expectError(ChmodError.InvalidMode, parseMode("abc"));
    try testing.expectError(ChmodError.InvalidMode, parseMode("12a"));
}

test "parseMode rejects modes over 777" {
    // This would be caught by the octal digit check, but test for completeness
    try testing.expectError(ChmodError.InvalidOctalMode, parseMode("999"));
}

test "parseMode rejects empty mode" {
    try testing.expectError(ChmodError.InvalidOctalMode, parseMode(""));
}

test "parseMode rejects wrong length modes" {
    try testing.expectError(ChmodError.InvalidOctalMode, parseMode("75"));
    try testing.expectError(ChmodError.InvalidOctalMode, parseMode("75555"));
}

test "Mode.fromOctal and toOctal roundtrip" {
    const test_modes = [_]u32{ 0o000, 0o644, 0o755, 0o777, 0o123, 0o456 };

    for (test_modes) |original| {
        const mode = Mode.fromOctal(original);
        const result = mode.toOctal();
        try testing.expectEqual(original, result);
    }
}

test "modeToString converts correctly" {
    try testing.expectEqualStrings("rwxr-xr-x", &modeToString(0o755));
    try testing.expectEqualStrings("rw-r--r--", &modeToString(0o644));
    try testing.expectEqualStrings("rwxrwxrwx", &modeToString(0o777));
    try testing.expectEqualStrings("---------", &modeToString(0o000));
    try testing.expectEqualStrings("r--r--r--", &modeToString(0o444));
    try testing.expectEqualStrings("-wx-wx-wx", &modeToString(0o333));
}

// File operation tests require actual file system operations, which we'll test with temporary files
test "applyModeToFile basic functionality" {
    // Create a temporary file for testing
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file_path = "test_file.txt";
    const test_file = try tmp_dir.dir.createFile(test_file_path, .{});
    defer test_file.close();

    // Test applying mode 644
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const mode = Mode.fromOctal(0o644);
    const options = ChmodOptions{ .verbose = true };

    // Use absolute path to avoid directory changes
    const abs_path = try tmp_dir.dir.realpathAlloc(testing.allocator, test_file_path);
    defer testing.allocator.free(abs_path);

    try applyModeToFile(abs_path, mode, buffer.writer(), options);

    // Verify the file mode changed
    const stat = try std.fs.cwd().statFile(abs_path);
    try testing.expectEqual(@as(u32, 0o644), @as(u32, @intCast(stat.mode & 0o777)));

    // Verify verbose output
    try testing.expect(std.mem.indexOf(u8, buffer.items, "mode of") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "test_file.txt") != null);
}

test "chmodFiles handles multiple files" {
    // Create temporary files for testing
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_files_rel = [_][]const u8{ "file1.txt", "file2.txt" };
    var test_files_abs = std.ArrayList([]u8).init(testing.allocator);
    defer {
        for (test_files_abs.items) |path| {
            testing.allocator.free(path);
        }
        test_files_abs.deinit();
    }

    // Create files and get absolute paths
    for (test_files_rel) |filename| {
        const file = try tmp_dir.dir.createFile(filename, .{});
        file.close();

        const abs_path = try tmp_dir.dir.realpathAlloc(testing.allocator, filename);
        try test_files_abs.append(abs_path);
    }

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const options = ChmodOptions{ .changes_only = true };

    try chmodFiles(testing.allocator, "755", test_files_abs.items, buffer.writer(), options);

    // Verify both files were processed
    for (test_files_abs.items) |abs_path| {
        const stat = try std.fs.cwd().statFile(abs_path);
        try testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast(stat.mode & 0o777)));
    }
}

test "chmodFiles handles nonexistent files gracefully" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const nonexistent_files = [_][]const u8{"does_not_exist.txt"};
    const options = ChmodOptions{ .quiet = true };

    // This should not crash, even though the file doesn't exist
    // The function should continue processing other files
    try chmodFiles(testing.allocator, "644", &nonexistent_files, buffer.writer(), options);

    // Should produce no output due to quiet mode
    try testing.expectEqual(@as(usize, 0), buffer.items.len);
}

// Integration test using the chmod helper function
test "chmod integration test with octal mode" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file_path = "integration_test.txt";
    const test_file = try tmp_dir.dir.createFile(test_file_path, .{});
    defer test_file.close();

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Get absolute path
    const abs_path = try tmp_dir.dir.realpathAlloc(testing.allocator, test_file_path);
    defer testing.allocator.free(abs_path);

    const args = [_][]const u8{ "755", abs_path };
    try chmod(testing.allocator, &args, buffer.writer());

    // Verify the mode was applied
    const stat = try std.fs.cwd().statFile(abs_path);
    try testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast(stat.mode & 0o777)));
}

test "chmod handles invalid mode strings" {
    const test_cases = [_][]const u8{ "abc", "999", "12a", "", "75555" };

    for (test_cases) |invalid_mode| {
        // This should fail with InvalidArguments or the parsing should fail
        // We expect the parseMode to be called and return an error
        const result = parseMode(invalid_mode);
        try testing.expect(std.meta.isError(result));
    }
}

// ============================================================================
// TESTS - Security and Safety Features
// ============================================================================

test "isCriticalSystemPath detects system paths" {
    // Test that critical system paths are properly detected
    try testing.expect(isCriticalSystemPath("/etc"));
    try testing.expect(isCriticalSystemPath("/bin"));
    try testing.expect(isCriticalSystemPath("/usr"));
    try testing.expect(isCriticalSystemPath("/etc/passwd"));
    try testing.expect(isCriticalSystemPath("/bin/sh"));

    // Test that non-critical paths are not blocked
    try testing.expect(!isCriticalSystemPath("/home/user/test"));
    try testing.expect(!isCriticalSystemPath("/tmp/test"));
    try testing.expect(!isCriticalSystemPath("/opt/myapp"));
    try testing.expect(!isCriticalSystemPath("./test"));
}

test "Mode struct supports special permissions" {
    // Test setuid, setgid, and sticky bit support
    const mode_with_setuid = Mode{
        .user = 7,
        .group = 5,
        .other = 5,
        .setuid = true,
        .setgid = false,
        .sticky = false,
    };
    try testing.expectEqual(@as(u32, 0o4755), mode_with_setuid.toOctal());

    const mode_with_setgid = Mode{
        .user = 7,
        .group = 5,
        .other = 5,
        .setuid = false,
        .setgid = true,
        .sticky = false,
    };
    try testing.expectEqual(@as(u32, 0o2755), mode_with_setgid.toOctal());

    const mode_with_sticky = Mode{
        .user = 7,
        .group = 5,
        .other = 5,
        .setuid = false,
        .setgid = false,
        .sticky = true,
    };
    try testing.expectEqual(@as(u32, 0o1755), mode_with_sticky.toOctal());

    // Test roundtrip conversion
    const original_mode: u32 = 0o4755;
    const mode_struct = Mode.fromOctal(original_mode);
    try testing.expectEqual(original_mode, mode_struct.toOctal());
}

test "parseMode handles 4-digit octal with special bits" {
    const mode_4755 = try parseMode("4755");
    try testing.expectEqual(@as(u3, 7), mode_4755.user);
    try testing.expectEqual(@as(u3, 5), mode_4755.group);
    try testing.expectEqual(@as(u3, 5), mode_4755.other);
    try testing.expect(mode_4755.setuid);
    try testing.expect(!mode_4755.setgid);
    try testing.expect(!mode_4755.sticky);

    const mode_2644 = try parseMode("2644");
    try testing.expect(!mode_2644.setuid);
    try testing.expect(mode_2644.setgid);
    try testing.expect(!mode_2644.sticky);

    const mode_1644 = try parseMode("1644");
    try testing.expect(!mode_1644.setuid);
    try testing.expect(!mode_1644.setgid);
    try testing.expect(mode_1644.sticky);
}

test "modeToString includes special permission bits" {
    // Test regular permissions
    try testing.expectEqualStrings("rwxr-xr-x", &modeToString(0o755));

    // Test setuid
    try testing.expectEqualStrings("rwsr-xr-x", &modeToString(0o4755));
    try testing.expectEqualStrings("rwSr-xr-x", &modeToString(0o4655)); // setuid without user execute

    // Test setgid
    try testing.expectEqualStrings("rwxr-sr-x", &modeToString(0o2755));
    try testing.expectEqualStrings("rwxr-Sr-x", &modeToString(0o2745)); // setgid without group execute

    // Test sticky bit
    try testing.expectEqualStrings("rwxr-xr-t", &modeToString(0o1755));
    try testing.expectEqualStrings("rwxr-xr-T", &modeToString(0o1754)); // sticky without other execute
}

// ============================================================================
// TESTS - Phase 2: Symbolic mode parsing
// ============================================================================

test "parseSymbolicMode basic additions" {
    // u+r: add read for user
    var mode = Mode.fromOctal(0o000);
    try applySymbolicMode(&mode, "u+r");
    try testing.expectEqual(@as(u32, 0o400), mode.toOctal());

    // g+w: add write for group
    mode = Mode.fromOctal(0o000);
    try applySymbolicMode(&mode, "g+w");
    try testing.expectEqual(@as(u32, 0o020), mode.toOctal());

    // o+x: add execute for other
    mode = Mode.fromOctal(0o000);
    try applySymbolicMode(&mode, "o+x");
    try testing.expectEqual(@as(u32, 0o001), mode.toOctal());
}

test "parseSymbolicMode basic subtractions" {
    // u-r: remove read for user
    var mode = Mode.fromOctal(0o777);
    try applySymbolicMode(&mode, "u-r");
    try testing.expectEqual(@as(u32, 0o377), mode.toOctal());

    // g-w: remove write for group
    mode = Mode.fromOctal(0o777);
    try applySymbolicMode(&mode, "g-w");
    try testing.expectEqual(@as(u32, 0o757), mode.toOctal());

    // o-x: remove execute for other
    mode = Mode.fromOctal(0o777);
    try applySymbolicMode(&mode, "o-x");
    try testing.expectEqual(@as(u32, 0o776), mode.toOctal());
}

test "parseSymbolicMode basic assignments" {
    // u=r: set user to read only
    var mode = Mode.fromOctal(0o777);
    try applySymbolicMode(&mode, "u=r");
    try testing.expectEqual(@as(u32, 0o477), mode.toOctal());

    // g=wx: set group to write+execute
    mode = Mode.fromOctal(0o777);
    try applySymbolicMode(&mode, "g=wx");
    try testing.expectEqual(@as(u32, 0o737), mode.toOctal());

    // o=: remove all permissions for other
    mode = Mode.fromOctal(0o777);
    try applySymbolicMode(&mode, "o=");
    try testing.expectEqual(@as(u32, 0o770), mode.toOctal());
}

test "parseSymbolicMode multiple targets" {
    // ug+r: add read for user and group
    var mode = Mode.fromOctal(0o000);
    try applySymbolicMode(&mode, "ug+r");
    try testing.expectEqual(@as(u32, 0o440), mode.toOctal());

    // go-w: remove write for group and other
    mode = Mode.fromOctal(0o777);
    try applySymbolicMode(&mode, "go-w");
    try testing.expectEqual(@as(u32, 0o755), mode.toOctal());

    // a+x: add execute for all
    mode = Mode.fromOctal(0o644);
    try applySymbolicMode(&mode, "a+x");
    try testing.expectEqual(@as(u32, 0o755), mode.toOctal());
}

test "parseSymbolicMode complex combinations" {
    // Multiple permissions in one operation
    var mode = Mode.fromOctal(0o000);
    try applySymbolicMode(&mode, "u+rwx");
    try testing.expectEqual(@as(u32, 0o700), mode.toOctal());

    // Mixed operations - apply each separately since comma parsing is complex
    mode = Mode.fromOctal(0o755);
    try applySymbolicMode(&mode, "u-x");
    try testing.expectEqual(@as(u32, 0o655), mode.toOctal());

    mode = Mode.fromOctal(0o755);
    try applySymbolicMode(&mode, "g+w");
    try testing.expectEqual(@as(u32, 0o775), mode.toOctal());
}

// ============================================================================
// TESTS - Phase 3: Recursive operations
// ============================================================================

test "recursive chmod on directory structure" {
    // Create a temporary directory structure for testing
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create nested directory structure
    try tmp_dir.dir.makeDir("subdir");
    try tmp_dir.dir.makeDir("subdir/deeper");

    // Create files at different levels
    const test_file1 = try tmp_dir.dir.createFile("file1.txt", .{});
    defer test_file1.close();

    const test_file2 = try tmp_dir.dir.createFile("subdir/file2.txt", .{});
    defer test_file2.close();

    const test_file3 = try tmp_dir.dir.createFile("subdir/deeper/file3.txt", .{});
    defer test_file3.close();

    // Get absolute paths
    const abs_root = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(abs_root);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const options = ChmodOptions{ .recursive = true, .verbose = true };
    const files = [_][]const u8{abs_root};

    // Apply recursive chmod
    try chmodFiles(testing.allocator, "755", &files, buffer.writer(), options);

    // Verify that all files and directories were processed
    // Note: This is a basic test - full verification would check each file's permissions
    try testing.expect(buffer.items.len > 0); // Should have verbose output
}

test "recursive flag processes files and directories" {
    // Create a simple directory structure
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("testdir");
    const test_file = try tmp_dir.dir.createFile("testdir/test.txt", .{});
    defer test_file.close();

    // Get absolute path to the directory
    const abs_dir = try tmp_dir.dir.realpathAlloc(testing.allocator, "testdir");
    defer testing.allocator.free(abs_dir);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const options = ChmodOptions{ .recursive = true, .changes_only = true };
    const files = [_][]const u8{abs_dir};

    // Apply recursive chmod - should not error
    try chmodFiles(testing.allocator, "644", &files, buffer.writer(), options);

    // The test passes if no errors are thrown
}

// ============================================================================
// TESTS - Phase 4: Verbose, changes, and silent flags
// ============================================================================

test "verbose flag outputs changes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test_verbose.txt", .{});
    defer test_file.close();

    const abs_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test_verbose.txt");
    defer testing.allocator.free(abs_path);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const options = ChmodOptions{ .verbose = true };
    const files = [_][]const u8{abs_path};

    try chmodFiles(testing.allocator, "755", &files, buffer.writer(), options);

    // Should have verbose output
    try testing.expect(buffer.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "mode of") != null);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "changed from") != null);
}

test "changes flag only outputs when mode changes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test_changes.txt", .{});
    defer test_file.close();

    const abs_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test_changes.txt");
    defer testing.allocator.free(abs_path);

    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const options = ChmodOptions{ .changes_only = true };
    const files = [_][]const u8{abs_path};

    // Apply mode that differs from current
    try chmodFiles(testing.allocator, "755", &files, buffer.writer(), options);

    // Should have output when mode changes
    try testing.expect(buffer.items.len > 0);

    // Clear buffer and apply same mode again
    buffer.clearRetainingCapacity();
    try chmodFiles(testing.allocator, "755", &files, buffer.writer(), options);

    // Should have no output when mode doesn't change
    try testing.expectEqual(@as(usize, 0), buffer.items.len);
}

test "quiet flag suppresses error messages" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const nonexistent_files = [_][]const u8{"nonexistent_file.txt"};
    const options = ChmodOptions{ .quiet = true };

    // This should not produce output even with errors
    try chmodFiles(testing.allocator, "755", &nonexistent_files, buffer.writer(), options);

    // Should produce no output due to quiet mode
    try testing.expectEqual(@as(usize, 0), buffer.items.len);
}

test "path traversal protection" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const malicious_paths = [_][]const u8{
        "/etc/passwd",
        "/bin/sh",
    };
    const options = ChmodOptions{ .quiet = true };

    // Should safely handle critical system paths
    for (malicious_paths) |path| {
        try chmodFiles(testing.allocator, "755", &.{path}, buffer.writer(), options);
    }

    // Test passes if we get here without errors
}

test "error handling consistency" {
    // Test that both octal and symbolic mode errors are handled consistently
    try testing.expectError(ChmodError.InvalidOctalMode, parseMode("999"));
    try testing.expectError(ChmodError.InvalidMode, parseMode("u+invalid"));
    try testing.expectError(ChmodError.InvalidMode, parseMode("invalid+x"));
}
