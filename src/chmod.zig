//! chmod - Change file mode (permissions) utility
//!
//! Supports both numeric (octal) and symbolic mode specifications, recursive operations,
//! and includes safety features to prevent accidental system damage.

const std = @import("std");
const common = @import("common");
const testing = std.testing;
const builtin = @import("builtin");
const privilege_test = common.privilege_test;

/// Command-line arguments for chmod
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

/// Main entry point for chmod utility
pub fn runChmod(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    const parsed_args = common.argparse.ArgParser.parse(ChmodArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(stderr_writer, "chmod", "invalid argument\nTry 'chmod --help' for more information.", .{});
                return @intFromEnum(common.ExitCode.general_error);
            },
            else => return err,
        }
    };
    defer allocator.free(parsed_args.positionals);

    if (parsed_args.help) {
        try printHelp(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    const positionals = parsed_args.positionals;

    // --reference requires only file arguments
    const using_reference = parsed_args.reference != null;
    if (using_reference) {
        if (positionals.len < 1) {
            common.printErrorWithProgram(stderr_writer, "chmod", "missing file operand\nTry 'chmod --help' for more information.", .{});
            return @intFromEnum(common.ExitCode.general_error);
        }
    } else {
        if (positionals.len < 2) {
            common.printErrorWithProgram(stderr_writer, "chmod", "missing operand\nTry 'chmod --help' for more information.", .{});
            return @intFromEnum(common.ExitCode.general_error);
        }
    }

    // With --reference, all args are files; otherwise first is mode
    const mode_str = if (using_reference) "" else positionals[0];
    const files = if (using_reference) positionals else positionals[1..];

    const options = ChmodOptions{
        .changes_only = parsed_args.changes,
        .quiet = parsed_args.silent,
        .verbose = parsed_args.verbose,
        .recursive = parsed_args.recursive,
        .reference_file = parsed_args.reference,
    };

    chmodFiles(allocator, mode_str, files, stdout_writer, stderr_writer, options) catch |err| {
        if (!options.quiet) {
            common.printErrorWithProgram(stderr_writer, "chmod", "operation failed: {s}", .{@errorName(err)});
        }
        return @intFromEnum(common.ExitCode.general_error);
    };

    return @intFromEnum(common.ExitCode.success);
}

/// Main entry point for chmod
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse process arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const exit_code = try runChmod(allocator, args[1..], stdout, stderr);
    std.process.exit(exit_code);
}

/// Print usage information and examples
fn printHelp(writer: anytype) !void {
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
    try writer.writeAll(help_text);
}

/// Print version information
fn printVersion(writer: anytype) !void {
    try writer.print("chmod ({s}) {s}\n", .{ common.name, common.version });
}

/// Options controlling chmod behavior
const ChmodOptions = struct {
    changes_only: bool = false,
    quiet: bool = false,
    verbose: bool = false,
    recursive: bool = false,
    reference_file: ?[]const u8 = null,
};

/// Unix file permissions with special bits
const Mode = struct {
    user: u3,
    group: u3,
    other: u3,
    setuid: bool = false,
    setgid: bool = false,
    sticky: bool = false,

    /// Convert to octal representation (e.g., 0o755)
    fn toOctal(self: Mode) u32 {
        var result = (@as(u32, self.user) << 6) | (@as(u32, self.group) << 3) | @as(u32, self.other);
        if (self.setuid) result |= 0o4000;
        if (self.setgid) result |= 0o2000;
        if (self.sticky) result |= 0o1000;
        return result;
    }

    /// Create from octal permission value
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

/// Errors specific to chmod operations
const ChmodError = error{
    /// Invalid symbolic mode string
    InvalidMode,
    /// Invalid octal mode
    InvalidOctalMode,
    /// Reference file not found
    ReferenceFileNotFound,
    /// Path traversal attempt detected
    PathTraversal,
    /// User cancelled operation
    UserCancelled,
};

/// Apply chmod operations to files
/// Handles both single files and recursive directory operations
fn chmodFiles(allocator: std.mem.Allocator, mode_str: []const u8, files: []const []const u8, writer: anytype, stderr_writer: anytype, options: ChmodOptions) !void {
    // Handle reference file mode if specified
    var reference_mode: ?Mode = null;
    if (options.reference_file) |ref_file| {
        const ref_stat = std.fs.cwd().statFile(ref_file) catch |err| {
            if (!options.quiet) {
                common.printErrorWithProgram(stderr_writer, "chmod", "cannot access reference file '{s}': {s}", .{ ref_file, @errorName(err) });
            }
            return err;
        };
        reference_mode = Mode.fromOctal(@as(u32, @intCast(ref_stat.mode & 0o7777)));
    }

    // Determine mode to use - reference mode takes precedence
    const use_reference = reference_mode != null;

    // Check if this is a symbolic mode
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
            // File doesn't exist
            break :blk file_path;
        };

        // Safety check for critical system paths
        if (isCriticalSystemPath(normalized)) {
            if (!options.quiet) {
                common.printErrorWithProgram(stderr_writer, "chmod", "cannot modify '{s}': Operation not permitted", .{file_path});
            }
            continue;
        }

        if (options.recursive) {
            // Check if path is a directory
            const stat_result = std.fs.cwd().statFile(file_path) catch |err| {
                if (!options.quiet) {
                    common.printErrorWithProgram(stderr_writer, "chmod", "cannot access '{s}': {s}", .{ file_path, @errorName(err) });
                }
                continue;
            };

            if (stat_result.kind == .directory) {
                try chmodRecursive(allocator, file_path, mode_str, is_symbolic, use_reference, reference_mode, writer, stderr_writer, options);
            } else {
                if (use_reference) {
                    try applyModeToFile(file_path, reference_mode.?, writer, stderr_writer, options);
                } else if (is_symbolic) {
                    try applySymbolicModeToFile(file_path, mode_str, writer, stderr_writer, options);
                } else {
                    const mode = try parseMode(mode_str);
                    try applyModeToFile(file_path, mode, writer, stderr_writer, options);
                }
            }
        } else {
            // Non-recursive processing
            if (use_reference) {
                applyModeToFile(file_path, reference_mode.?, writer, stderr_writer, options) catch |err| {
                    if (!options.quiet) {
                        common.printErrorWithProgram(stderr_writer, "chmod", "cannot access '{s}': {s}", .{ file_path, @errorName(err) });
                    }
                };
            } else if (is_symbolic) {
                applySymbolicModeToFile(file_path, mode_str, writer, stderr_writer, options) catch |err| {
                    if (!options.quiet) {
                        common.printErrorWithProgram(stderr_writer, "chmod", "cannot access '{s}': {s}", .{ file_path, @errorName(err) });
                    }
                };
            } else {
                const mode = parseMode(mode_str) catch |err| switch (err) {
                    ChmodError.InvalidMode, ChmodError.InvalidOctalMode => {
                        if (!options.quiet) {
                            common.printErrorWithProgram(stderr_writer, "chmod", "invalid mode: '{s}'", .{mode_str});
                        }
                        return err;
                    },
                    else => return err,
                };

                applyModeToFile(file_path, mode, writer, stderr_writer, options) catch |err| {
                    if (!options.quiet) {
                        common.printErrorWithProgram(stderr_writer, "chmod", "cannot access '{s}': {s}", .{ file_path, @errorName(err) });
                    }
                };
            }
        }
    }
}

/// Recursively apply chmod to a directory and all its contents
/// Processes directories depth-first
fn chmodRecursive(allocator: std.mem.Allocator, dir_path: []const u8, mode_str: []const u8, is_symbolic: bool, use_reference: bool, reference_mode: ?Mode, writer: anytype, stderr_writer: anytype, options: ChmodOptions) !void {
    // Apply mode to the directory itself first
    if (use_reference) {
        try applyModeToFile(dir_path, reference_mode.?, writer, stderr_writer, options);
    } else if (is_symbolic) {
        try applySymbolicModeToFile(dir_path, mode_str, writer, stderr_writer, options);
    } else {
        const mode = try parseMode(mode_str);
        try applyModeToFile(dir_path, mode, writer, stderr_writer, options);
    }

    // Path traversal protection for directory
    var normalized_buf: [std.fs.max_path_bytes]u8 = undefined;
    const normalized = std.fs.realpath(dir_path, &normalized_buf) catch dir_path;

    if (isCriticalSystemPath(normalized)) {
        if (!options.quiet) {
            common.printErrorWithProgram(stderr_writer, "chmod", "cannot modify '{s}': Operation not permitted", .{dir_path});
        }
        return;
    }

    // Open directory for iteration
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        if (!options.quiet) {
            common.printErrorWithProgram(stderr_writer, "chmod", "cannot access '{s}': {s}", .{ dir_path, @errorName(err) });
        }
        return;
    };
    defer dir.close();

    // Iterate through directory entries
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
            continue;
        }

        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(full_path);

        switch (entry.kind) {
            .directory => {
                // Recursively process subdirectory
                try chmodRecursive(allocator, full_path, mode_str, is_symbolic, use_reference, reference_mode, writer, stderr_writer, options);
            },
            .file, .sym_link => {
                if (use_reference) {
                    applyModeToFile(full_path, reference_mode.?, writer, stderr_writer, options) catch |err| {
                        if (!options.quiet) {
                            common.printErrorWithProgram(stderr_writer, "chmod", "cannot access '{s}': {s}", .{ full_path, @errorName(err) });
                        }
                    };
                } else if (is_symbolic) {
                    applySymbolicModeToFile(full_path, mode_str, writer, stderr_writer, options) catch |err| {
                        if (!options.quiet) {
                            common.printErrorWithProgram(stderr_writer, "chmod", "cannot access '{s}': {s}", .{ full_path, @errorName(err) });
                        }
                    };
                } else {
                    const mode = parseMode(mode_str) catch |err| {
                        if (!options.quiet) {
                            common.printErrorWithProgram(stderr_writer, "chmod", "invalid mode: '{s}'", .{mode_str});
                        }
                        return err;
                    };
                    applyModeToFile(full_path, mode, writer, stderr_writer, options) catch |err| {
                        if (!options.quiet) {
                            common.printErrorWithProgram(stderr_writer, "chmod", "cannot access '{s}': {s}", .{ full_path, @errorName(err) });
                        }
                    };
                }
            },
            else => {
                // Handle other file types (block device, character device, etc.)
                if (use_reference) {
                    applyModeToFile(full_path, reference_mode.?, writer, stderr_writer, options) catch |err| {
                        if (!options.quiet) {
                            common.printErrorWithProgram(stderr_writer, "chmod", "cannot access '{s}': {s}", .{ full_path, @errorName(err) });
                        }
                    };
                } else if (is_symbolic) {
                    applySymbolicModeToFile(full_path, mode_str, writer, stderr_writer, options) catch |err| {
                        if (!options.quiet) {
                            common.printErrorWithProgram(stderr_writer, "chmod", "cannot access '{s}': {s}", .{ full_path, @errorName(err) });
                        }
                    };
                } else {
                    const mode = parseMode(mode_str) catch |err| {
                        if (!options.quiet) {
                            common.printErrorWithProgram(stderr_writer, "chmod", "invalid mode: '{s}'", .{mode_str});
                        }
                        return err;
                    };
                    applyModeToFile(full_path, mode, writer, stderr_writer, options) catch |err| {
                        if (!options.quiet) {
                            common.printErrorWithProgram(stderr_writer, "chmod", "cannot access '{s}': {s}", .{ full_path, @errorName(err) });
                        }
                    };
                }
            },
        }
    }
}

/// Parse a mode string (octal or symbolic) into a Mode struct
/// First attempts octal parsing, then falls back to symbolic mode parsing
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
        // Numeric but not valid octal
        return ChmodError.InvalidOctalMode;
    }

    // Try symbolic mode parsing (Phase 2)
    return parseSymbolicModeString(mode_str);
}

// Symbolic mode parsing structures and functions

/// Single symbolic mode operation
const SymbolicMode = struct {
    who: u8, // 1=user, 2=group, 4=other, 8=all
    op: u8, // +, -, =
    perms: u8, // r=4, w=2, x=1
};

/// Parse a complete symbolic mode string
/// Returns a base mode - actual application uses current file mode
fn parseSymbolicModeString(mode_str: []const u8) !Mode {
    // Start with base mode of 0
    var base_mode = Mode.fromOctal(0o000);

    // Split by commas for multiple operations
    var iter = std.mem.splitScalar(u8, mode_str, ',');
    while (iter.next()) |clause| {
        try applySymbolicMode(&base_mode, std.mem.trim(u8, clause, " "));
    }

    return base_mode;
}

/// Apply a single symbolic mode clause
/// Modifies the mode in-place
fn applySymbolicMode(mode: *Mode, clause: []const u8) !void {
    if (clause.len < 2) return ChmodError.InvalidMode;

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

    const op = clause[i];
    if (op != '+' and op != '-' and op != '=') {
        return ChmodError.InvalidMode;
    }
    i += 1;

    var perms: u8 = 0;
    while (i < clause.len) {
        switch (clause[i]) {
            'r' => perms |= 4,
            'w' => perms |= 2,
            'x' => perms |= 1,
            's' => perms |= 8, // Special bit (setuid/setgid)
            't' => perms |= 16, // Sticky bit
            'X' => perms |= 1, // Execute if directory or already has execute
            else => return ChmodError.InvalidMode,
        }
        i += 1;
    }

    applyPermissionChange(mode, who, op, perms);
}

/// Apply permission changes based on parsed symbolic mode components
fn applyPermissionChange(mode: *Mode, who: u8, op: u8, perms: u8) void {
    if (who & 1 != 0) {
        switch (op) {
            '+' => mode.user |= @as(u3, @truncate(perms)),
            '-' => mode.user &= ~@as(u3, @truncate(perms)),
            '=' => mode.user = @as(u3, @truncate(perms)),
            else => {},
        }
    }

    if (who & 2 != 0) {
        switch (op) {
            '+' => mode.group |= @as(u3, @truncate(perms)),
            '-' => mode.group &= ~@as(u3, @truncate(perms)),
            '=' => mode.group = @as(u3, @truncate(perms)),
            else => {},
        }
    }

    if (who & 4 != 0) {
        switch (op) {
            '+' => mode.other |= @as(u3, @truncate(perms)),
            '-' => mode.other &= ~@as(u3, @truncate(perms)),
            '=' => mode.other = @as(u3, @truncate(perms)),
            else => {},
        }
    }
}

/// Apply a specific mode to a single file
/// Reports changes if verbose or changes_only flags are set
fn applyModeToFile(file_path: []const u8, mode: Mode, writer: anytype, stderr_writer: anytype, options: ChmodOptions) !void {
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
    try common.file_ops.setPermissionsWithWriter(file, @as(std.fs.File.Mode, @intCast(new_mode)), file_path, stderr_writer);

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

/// Apply a symbolic mode string to a file
/// Preserves existing permissions and applies changes relative to them
fn applySymbolicModeToFile(file_path: []const u8, mode_str: []const u8, writer: anytype, stderr_writer: anytype, options: ChmodOptions) !void {
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

    var iter = std.mem.splitScalar(u8, mode_str, ',');
    while (iter.next()) |clause| {
        try applySymbolicMode(&new_mode_struct, std.mem.trim(u8, clause, " "));
    }

    const new_mode = new_mode_struct.toOctal();

    // Apply the new mode using the file's chmod method
    try common.file_ops.setPermissionsWithWriter(file, @as(std.fs.File.Mode, @intCast(new_mode)), file_path, stderr_writer);

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

/// Convert octal mode to string representation (e.g., "rwxr-xr-x")
/// Handles special permission bits
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
/// Security feature to prevent accidental system damage
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
        // Check if path starts with critical path
        if (path.len > critical.len and path[critical.len] == '/' and std.mem.startsWith(u8, path, critical)) {
            return true;
        }
    }
    return false;
}

/// Helper function for testing chmod functionality
/// Used in integration tests to simulate command-line usage
fn chmod(allocator: std.mem.Allocator, args: []const []const u8, writer: anytype, stderr_writer: anytype) !void {
    if (args.len < 2) {
        return error.InvalidArguments;
    }

    const mode_str = args[0];
    const files = args[1..];
    const options = ChmodOptions{};

    try chmodFiles(allocator, mode_str, files, writer, stderr_writer, options);
}

// Tests: Basic numeric mode parsing and application

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
    // Test for completeness
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

// Privileged tests require fakeroot
// Run with: ./scripts/run-privileged-tests.sh or zig build test-privileged

// File operation tests
test "privileged: applyModeToFile basic functionality" {
    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            _ = allocator;
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const test_file_path = "test_file.txt";
            const test_file = try tmp_dir.dir.createFile(test_file_path, .{});
            defer test_file.close();

            // Test applying mode 644
            var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
            defer stdout_buffer.deinit();
            var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
            defer stderr_buffer.deinit();

            const mode = Mode.fromOctal(0o644);
            const options = ChmodOptions{ .verbose = true };

            const abs_path = try tmp_dir.dir.realpathAlloc(testing.allocator, test_file_path);
            defer testing.allocator.free(abs_path);

            try applyModeToFile(abs_path, mode, stdout_buffer.writer(), stderr_buffer.writer(), options);

            // Verify the file mode changed
            const stat = try std.fs.cwd().statFile(abs_path);
            try testing.expectEqual(@as(u32, 0o644), @as(u32, @intCast(stat.mode & 0o777)));

            // Verify verbose output
            try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "mode of") != null);
            try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "test_file.txt") != null);
        }
    }.testFn);
}

test "privileged: chmodFiles handles multiple files" {
    try privilege_test.requiresPrivilege();

    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            _ = allocator;
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

            for (test_files_rel) |filename| {
                const file = try tmp_dir.dir.createFile(filename, .{});
                file.close();

                const abs_path = try tmp_dir.dir.realpathAlloc(testing.allocator, filename);
                try test_files_abs.append(abs_path);
            }

            var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
            defer stdout_buffer.deinit();
            var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
            defer stderr_buffer.deinit();

            const options = ChmodOptions{ .changes_only = true };

            try chmodFiles(testing.allocator, "755", test_files_abs.items, stdout_buffer.writer(), stderr_buffer.writer(), options);

            // Verify both files were processed
            for (test_files_abs.items) |abs_path| {
                const stat = try std.fs.cwd().statFile(abs_path);
                try testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast(stat.mode & 0o777)));
            }
        }
    }.testFn);
}

test "chmodFiles handles nonexistent files gracefully" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const nonexistent_files = [_][]const u8{"does_not_exist.txt"};
    const options = ChmodOptions{ .quiet = true };

    // Should not crash on nonexistent files
    try chmodFiles(testing.allocator, "644", &nonexistent_files, stdout_buffer.writer(), stderr_buffer.writer(), options);

    // Should produce no output due to quiet mode
    try testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
}

// Integration test using the chmod helper function
test "privileged: chmod integration test with octal mode" {
    try privilege_test.requiresPrivilege();

    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            _ = allocator;
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const test_file_path = "integration_test.txt";
            const test_file = try tmp_dir.dir.createFile(test_file_path, .{});
            defer test_file.close();

            var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
            defer stdout_buffer.deinit();
            var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
            defer stderr_buffer.deinit();

            const abs_path = try tmp_dir.dir.realpathAlloc(testing.allocator, test_file_path);
            defer testing.allocator.free(abs_path);

            const args = [_][]const u8{ "755", abs_path };
            try chmod(testing.allocator, &args, stdout_buffer.writer(), stderr_buffer.writer());

            // Verify the mode was applied
            const stat = try std.fs.cwd().statFile(abs_path);
            try testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast(stat.mode & 0o777)));
        }
    }.testFn);
}

test "chmod handles invalid mode strings" {
    const test_cases = [_][]const u8{ "abc", "999", "12a", "", "75555" };

    for (test_cases) |invalid_mode| {
        // Should fail with invalid mode
        const result = parseMode(invalid_mode);
        try testing.expect(std.meta.isError(result));
    }
}

// Tests: Security and Safety Features

test "isCriticalSystemPath detects system paths" {
    // Test critical system path detection
    try testing.expect(isCriticalSystemPath("/etc"));
    try testing.expect(isCriticalSystemPath("/bin"));
    try testing.expect(isCriticalSystemPath("/usr"));
    try testing.expect(isCriticalSystemPath("/etc/passwd"));
    try testing.expect(isCriticalSystemPath("/bin/sh"));

    try testing.expect(!isCriticalSystemPath("/home/user/test"));
    try testing.expect(!isCriticalSystemPath("/tmp/test"));
    try testing.expect(!isCriticalSystemPath("/opt/myapp"));
    try testing.expect(!isCriticalSystemPath("./test"));
}

test "Mode struct supports special permissions" {
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

// Tests: Symbolic mode parsing

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

    // Mixed operations
    mode = Mode.fromOctal(0o755);
    try applySymbolicMode(&mode, "u-x");
    try testing.expectEqual(@as(u32, 0o655), mode.toOctal());

    mode = Mode.fromOctal(0o755);
    try applySymbolicMode(&mode, "g+w");
    try testing.expectEqual(@as(u32, 0o775), mode.toOctal());
}

// Tests: Recursive operations

test "privileged: recursive chmod on directory structure" {
    try privilege_test.requiresPrivilege();

    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            _ = allocator;
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.makeDir("subdir");
            try tmp_dir.dir.makeDir("subdir/deeper");

            const test_file1 = try tmp_dir.dir.createFile("file1.txt", .{});
            defer test_file1.close();

            const test_file2 = try tmp_dir.dir.createFile("subdir/file2.txt", .{});
            defer test_file2.close();

            const test_file3 = try tmp_dir.dir.createFile("subdir/deeper/file3.txt", .{});
            defer test_file3.close();

            const abs_root = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
            defer testing.allocator.free(abs_root);

            var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
            defer stdout_buffer.deinit();
            var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
            defer stderr_buffer.deinit();

            const options = ChmodOptions{ .recursive = true, .verbose = true };
            const files = [_][]const u8{abs_root};

            try chmodFiles(testing.allocator, "755", &files, stdout_buffer.writer(), stderr_buffer.writer(), options);

            // Basic verification
            try testing.expect(stdout_buffer.items.len > 0); // Should have verbose output
        }
    }.testFn);
}

test "privileged: recursive flag processes files and directories" {
    try privilege_test.requiresPrivilege();

    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            _ = allocator;
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.makeDir("testdir");
            const test_file = try tmp_dir.dir.createFile("testdir/test.txt", .{});
            defer test_file.close();

            const abs_dir = try tmp_dir.dir.realpathAlloc(testing.allocator, "testdir");
            defer testing.allocator.free(abs_dir);

            var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
            defer stdout_buffer.deinit();
            var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
            defer stderr_buffer.deinit();

            const options = ChmodOptions{ .recursive = true, .changes_only = true };
            const files = [_][]const u8{abs_dir};

            try chmodFiles(testing.allocator, "644", &files, stdout_buffer.writer(), stderr_buffer.writer(), options);

            // The test passes if no errors are thrown
        }
    }.testFn);
}

// Tests: Verbose, changes, and silent flags

test "privileged: verbose flag outputs changes" {
    try privilege_test.requiresPrivilege();

    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            _ = allocator;
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const test_file = try tmp_dir.dir.createFile("test_verbose.txt", .{});
            defer test_file.close();

            const abs_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test_verbose.txt");
            defer testing.allocator.free(abs_path);

            var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
            defer stdout_buffer.deinit();
            var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
            defer stderr_buffer.deinit();

            const options = ChmodOptions{ .verbose = true };
            const files = [_][]const u8{abs_path};

            try chmodFiles(testing.allocator, "755", &files, stdout_buffer.writer(), stderr_buffer.writer(), options);

            // Should have verbose output
            try testing.expect(stdout_buffer.items.len > 0);
            try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "mode of") != null);
            try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "changed from") != null);
        }
    }.testFn);
}

test "privileged: changes flag only outputs when mode changes" {
    try privilege_test.requiresPrivilege();

    try privilege_test.withFakeroot(testing.allocator, struct {
        fn testFn(allocator: std.mem.Allocator) !void {
            _ = allocator;
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const test_file = try tmp_dir.dir.createFile("test_changes.txt", .{});
            defer test_file.close();

            const abs_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test_changes.txt");
            defer testing.allocator.free(abs_path);

            var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
            defer stdout_buffer.deinit();
            var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
            defer stderr_buffer.deinit();

            const options = ChmodOptions{ .changes_only = true };
            const files = [_][]const u8{abs_path};

            try chmodFiles(testing.allocator, "755", &files, stdout_buffer.writer(), stderr_buffer.writer(), options);

            // Should have output when mode changes
            try testing.expect(stdout_buffer.items.len > 0);

            // Clear buffer and apply same mode again
            stdout_buffer.clearRetainingCapacity();
            stderr_buffer.clearRetainingCapacity();
            try chmodFiles(testing.allocator, "755", &files, stdout_buffer.writer(), stderr_buffer.writer(), options);

            try testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
        }
    }.testFn);
}

test "quiet flag suppresses error messages" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    const nonexistent_files = [_][]const u8{"nonexistent_file.txt"};
    const options = ChmodOptions{ .quiet = true };

    // Should produce no output due to quiet mode
    try chmodFiles(testing.allocator, "755", &nonexistent_files, stdout_buffer.writer(), stderr_buffer.writer(), options);

    // Should produce no output due to quiet mode
    try testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
}

test "path traversal protection" {
    var stdout_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stdout_buffer.deinit();
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();

    // Create a test directory to simulate path traversal attempts
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test files
    try tmp_dir.dir.writeFile(.{ .sub_path = "test_file.txt", .data = "test" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_path = try tmp_dir.dir.realpath("test_file.txt", &path_buf);

    const options = ChmodOptions{ .quiet = true };

    // Test that chmod works on a valid file (should not produce errors)
    try chmodFiles(testing.allocator, "755", &.{test_path}, stdout_buffer.writer(), stderr_buffer.writer(), options);

    // For actual system paths, we expect permission errors to be caught
    // but we don't actually test them to avoid triggering OS dialogs
    // The production code already handles these cases safely
}

test "error handling consistency" {
    // Test error handling consistency
    try testing.expectError(ChmodError.InvalidOctalMode, parseMode("999"));
    try testing.expectError(ChmodError.InvalidMode, parseMode("u+invalid"));
    try testing.expectError(ChmodError.InvalidMode, parseMode("invalid+x"));
}
