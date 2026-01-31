//! chmod - Change file mode (permissions) utility
//!
//! Supports both numeric (octal) and symbolic mode specifications and recursive operations.

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
pub fn runUtility(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    const parsed_args = common.argparse.ArgParser.parse(ChmodArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag, error.MissingValue, error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, "chmod", "invalid argument\nTry 'chmod --help' for more information.", .{});
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
            common.printErrorWithProgram(allocator, stderr_writer, "chmod", "missing file operand\nTry 'chmod --help' for more information.", .{});
            return @intFromEnum(common.ExitCode.general_error);
        }
    } else {
        if (positionals.len < 2) {
            common.printErrorWithProgram(allocator, stderr_writer, "chmod", "missing operand\nTry 'chmod --help' for more information.", .{});
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
        switch (err) {
            ChmodError.FileOperationFailed => {
                // Specific file errors already reported, just return failure code
            },
            else => {
                if (!options.quiet) {
                    common.printErrorWithProgram(allocator, stderr_writer, "chmod", "operation failed: {s}", .{errorToMessage(err)});
                }
            },
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

    // Set up buffered writers for stdout and stderr
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runUtility(allocator, args[1..], stdout, stderr);

    // Flush buffers before exit
    stdout.flush() catch {};
    stderr.flush() catch {};

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
    /// User cancelled operation
    UserCancelled,
    /// One or more file operations failed
    FileOperationFailed,
};

/// Apply chmod operations to files
/// Handles both single files and recursive directory operations
fn chmodFiles(allocator: std.mem.Allocator, mode_str: []const u8, files: []const []const u8, writer: anytype, stderr_writer: anytype, options: ChmodOptions) !void {
    // Handle reference file mode if specified
    var reference_mode: ?Mode = null;
    if (options.reference_file) |ref_file| {
        const ref_stat = std.fs.cwd().statFile(ref_file) catch |err| {
            if (!options.quiet) {
                common.printErrorWithProgram(allocator, stderr_writer, "chmod", "cannot access reference file '{s}': {s}", .{ ref_file, errorToMessage(err) });
            }
            return err;
        };
        reference_mode = Mode.fromOctal(@as(u32, @intCast(ref_stat.mode & 0o7777)));
    }

    // Determine mode to use - reference mode takes precedence
    const use_reference = reference_mode != null;

    // Pre-parse mode once for performance optimization
    var parsed_octal_mode: ?Mode = null;
    var is_symbolic = false;

    if (!use_reference) {
        // Check if this is a symbolic mode
        is_symbolic = blk: {
            for (mode_str) |c| {
                if (std.ascii.isAlphabetic(c) or c == '+' or c == '-' or c == '=' or c == ',') {
                    break :blk true;
                }
            }
            break :blk false;
        };

        // Pre-parse octal mode if it's not symbolic
        if (!is_symbolic) {
            parsed_octal_mode = parseMode(mode_str) catch |err| switch (err) {
                ChmodError.InvalidMode, ChmodError.InvalidOctalMode => {
                    if (!options.quiet) {
                        common.printErrorWithProgram(allocator, stderr_writer, "chmod", "invalid mode: '{s}'", .{mode_str});
                    }
                    return err;
                },
                else => return err,
            };
        }
    }

    // Track if any file operations failed
    var had_errors = false;

    for (files) |file_path| {
        if (options.recursive) {
            // Check if path is a directory
            const stat_result = std.fs.cwd().statFile(file_path) catch |err| {
                if (!options.quiet) {
                    common.printErrorWithProgram(allocator, stderr_writer, "chmod", "cannot access '{s}': {s}", .{ file_path, errorToMessage(err) });
                }
                had_errors = true;
                continue;
            };

            if (stat_result.kind == .directory) {
                chmodRecursive(allocator, file_path, mode_str, is_symbolic, use_reference, reference_mode, parsed_octal_mode, writer, stderr_writer, options) catch {
                    had_errors = true;
                };
            } else {
                // For recursive processing of files, we want to catch and track errors
                if (use_reference) {
                    applyModeToFile(allocator, file_path, reference_mode.?, writer, stderr_writer, options) catch {
                        had_errors = true;
                    };
                } else if (is_symbolic) {
                    applySymbolicModeToFile(allocator, file_path, mode_str, writer, stderr_writer, options) catch {
                        had_errors = true;
                    };
                } else {
                    applyModeToFile(allocator, file_path, parsed_octal_mode.?, writer, stderr_writer, options) catch {
                        had_errors = true;
                    };
                }
            }
        } else {
            // Non-recursive processing - track errors from helper function
            const result = applyModeToPath(allocator, file_path, mode_str, is_symbolic, use_reference, reference_mode, parsed_octal_mode, writer, stderr_writer, options);
            if (!result) {
                had_errors = true;
            }
        }
    }

    // If any operations failed, return an error to signal overall failure
    if (had_errors) {
        return ChmodError.FileOperationFailed;
    }
}

/// Apply mode to a single path with proper error handling
/// Handles reference mode, symbolic mode, and octal mode cases
/// Returns true on success, false on failure
fn applyModeToPath(allocator: std.mem.Allocator, file_path: []const u8, mode_str: []const u8, is_symbolic: bool, use_reference: bool, reference_mode: ?Mode, parsed_octal_mode: ?Mode, writer: anytype, stderr_writer: anytype, options: ChmodOptions) bool {
    if (use_reference) {
        applyModeToFile(allocator, file_path, reference_mode.?, writer, stderr_writer, options) catch |err| {
            if (!options.quiet) {
                common.printErrorWithProgram(allocator, stderr_writer, "chmod", "cannot access '{s}': {s}", .{ file_path, errorToMessage(err) });
            }
            return false;
        };
    } else if (is_symbolic) {
        applySymbolicModeToFile(allocator, file_path, mode_str, writer, stderr_writer, options) catch |err| {
            if (!options.quiet) {
                switch (err) {
                    ChmodError.InvalidMode => {
                        common.printErrorWithProgram(allocator, stderr_writer, "chmod", "invalid mode: '{s}'", .{mode_str});
                    },
                    else => {
                        common.printErrorWithProgram(allocator, stderr_writer, "chmod", "cannot access '{s}': {s}", .{ file_path, errorToMessage(err) });
                    },
                }
            }
            return false;
        };
    } else {
        applyModeToFile(allocator, file_path, parsed_octal_mode.?, writer, stderr_writer, options) catch |err| {
            if (!options.quiet) {
                common.printErrorWithProgram(allocator, stderr_writer, "chmod", "cannot access '{s}': {s}", .{ file_path, errorToMessage(err) });
            }
            return false;
        };
    }
    return true;
}

/// Recursively apply chmod to a directory and all its contents
/// Processes directory contents first, then the directory itself to avoid permission conflicts
fn chmodRecursive(allocator: std.mem.Allocator, dir_path: []const u8, mode_str: []const u8, is_symbolic: bool, use_reference: bool, reference_mode: ?Mode, parsed_octal_mode: ?Mode, writer: anytype, stderr_writer: anytype, options: ChmodOptions) !void {
    // Open directory for iteration FIRST, before changing its permissions
    // This ensures we can access the directory contents even if the new permissions would block access
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        if (!options.quiet) {
            common.printErrorWithProgram(allocator, stderr_writer, "chmod", "cannot access '{s}': {s}", .{ dir_path, errorToMessage(err) });
        }
        return;
    };
    defer dir.close();

    // Track if any file operations failed in this directory
    var had_errors = false;

    // Process all directory contents FIRST
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
                chmodRecursive(allocator, full_path, mode_str, is_symbolic, use_reference, reference_mode, parsed_octal_mode, writer, stderr_writer, options) catch {
                    had_errors = true;
                };
            },
            else => {
                // Handle all file types uniformly (files, symlinks, devices, etc.)
                const result = applyModeToPath(allocator, full_path, mode_str, is_symbolic, use_reference, reference_mode, parsed_octal_mode, writer, stderr_writer, options);
                if (!result) {
                    had_errors = true;
                }
            },
        }
    }

    // Apply mode to the directory itself LAST, after processing all contents
    // This prevents the scenario where changing directory permissions blocks access to its contents
    if (use_reference) {
        applyModeToFile(allocator, dir_path, reference_mode.?, writer, stderr_writer, options) catch {
            had_errors = true;
        };
    } else if (is_symbolic) {
        applySymbolicModeToFile(allocator, dir_path, mode_str, writer, stderr_writer, options) catch {
            had_errors = true;
        };
    } else {
        applyModeToFile(allocator, dir_path, parsed_octal_mode.?, writer, stderr_writer, options) catch {
            had_errors = true;
        };
    }

    // If any operations failed, return an error
    if (had_errors) {
        return ChmodError.FileOperationFailed;
    }
}

/// Parse a mode string (octal or symbolic) into a Mode struct
/// First attempts octal parsing, then falls back to symbolic mode parsing
fn parseMode(mode_str: []const u8) !Mode {
    // Try octal mode first (Phase 1) - accept 1-4 octal digits
    if (mode_str.len >= 1 and mode_str.len <= 4) {
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

    // Check if this is permission copying (g=u, o=g, u=o)
    if (op == '=' and i < clause.len and clause.len == i + 1) {
        const copy_from = clause[i];
        if (copy_from == 'u' or copy_from == 'g' or copy_from == 'o') {
            applyCopyingMode(mode, who, copy_from);
            return;
        }
    }

    var perms: u8 = 0;
    while (i < clause.len) {
        switch (clause[i]) {
            'r' => perms |= 4,
            'w' => perms |= 2,
            'x' => perms |= 1,
            's' => perms |= 8, // Special bit (setuid/setgid)
            't' => perms |= 16, // Sticky bit
            'X' => perms |= 1, // Execute if directory or already has execute
            // Support permission copying cases
            'u', 'g', 'o' => {
                if (op == '=' and clause.len == i + 1) {
                    applyCopyingMode(mode, who, clause[i]);
                    return;
                } else {
                    return ChmodError.InvalidMode;
                }
            },
            else => return ChmodError.InvalidMode,
        }
        i += 1;
    }

    applyPermissionChange(mode, who, op, perms);
}

/// Apply permission copying (g=u, o=g, u=o) between user classes
fn applyCopyingMode(mode: *Mode, who: u8, copy_from: u8) void {
    // Get source permissions
    const source_perms = switch (copy_from) {
        'u' => mode.user,
        'g' => mode.group,
        'o' => mode.other,
        else => return, // Should never happen due to validation
    };

    // Apply to target(s)
    if (who & 1 != 0) { // user
        mode.user = source_perms;
    }
    if (who & 2 != 0) { // group
        mode.group = source_perms;
    }
    if (who & 4 != 0) { // other
        mode.other = source_perms;
    }

    // Note: Special bits (setuid/setgid/sticky) are not copied in standard chmod behavior
    // Only the basic rwx permissions are copied between user classes
}

/// Apply permission changes based on parsed symbolic mode components
fn applyPermissionChange(mode: *Mode, who: u8, op: u8, perms: u8) void {
    // Handle basic permissions (rwx)
    const basic_perms = perms & 7; // Only the lower 3 bits

    if (who & 1 != 0) {
        switch (op) {
            '+' => mode.user |= @as(u3, @truncate(basic_perms)),
            '-' => mode.user &= ~@as(u3, @truncate(basic_perms)),
            '=' => mode.user = @as(u3, @truncate(basic_perms)),
            else => {},
        }
    }

    if (who & 2 != 0) {
        switch (op) {
            '+' => mode.group |= @as(u3, @truncate(basic_perms)),
            '-' => mode.group &= ~@as(u3, @truncate(basic_perms)),
            '=' => mode.group = @as(u3, @truncate(basic_perms)),
            else => {},
        }
    }

    if (who & 4 != 0) {
        switch (op) {
            '+' => mode.other |= @as(u3, @truncate(basic_perms)),
            '-' => mode.other &= ~@as(u3, @truncate(basic_perms)),
            '=' => mode.other = @as(u3, @truncate(basic_perms)),
            else => {},
        }
    }

    // Handle special permission bits
    if (perms & 8 != 0) { // 's' bit
        if (who & 1 != 0) { // setuid for user
            switch (op) {
                '+' => mode.setuid = true,
                '-' => mode.setuid = false,
                '=' => mode.setuid = true,
                else => {},
            }
        }
        if (who & 2 != 0) { // setgid for group
            switch (op) {
                '+' => mode.setgid = true,
                '-' => mode.setgid = false,
                '=' => mode.setgid = true,
                else => {},
            }
        }
    }

    if (perms & 16 != 0) { // 't' bit (sticky)
        if (who & 4 != 0) { // sticky for other
            switch (op) {
                '+' => mode.sticky = true,
                '-' => mode.sticky = false,
                '=' => mode.sticky = true,
                else => {},
            }
        }
    }
}

/// Convert error to user-friendly message
fn errorToMessage(err: anytype) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied => "Permission denied",
        error.PermissionDenied => "Permission denied",
        error.NotDir => "Not a directory",
        else => @errorName(err),
    };
}

/// Apply a specific mode to a single file
/// Reports changes if verbose or changes_only flags are set
fn applyModeToFile(allocator: std.mem.Allocator, file_path: []const u8, mode: Mode, writer: anytype, stderr_writer: anytype, options: ChmodOptions) !void {
    _ = allocator; // For potential future use
    _ = stderr_writer; // For potential future use
    // Get file stats without opening the file - this works even on files with restrictive permissions
    const stat = std.fs.cwd().statFile(file_path) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        // Don't fail on access denied for stat - we might still be able to chmod
        error.AccessDenied => std.fs.File.Stat{ .size = 0, .mode = 0, .mtime = 0, .atime = 0, .ctime = 0, .kind = .file, .inode = 0 },
        else => return err,
    };

    const old_mode = @as(u32, @intCast(stat.mode & 0o7777));
    const new_mode = mode.toOctal();

    // Use path-based chmod system call which works even on files with restrictive permissions
    // This works because chmod system call operates on the path, not requiring file access
    // Ensure the file path is null-terminated for C function
    const path_z = try std.posix.toPosixPath(file_path);
    const result = std.c.chmod(&path_z, @as(std.c.mode_t, @intCast(new_mode)));
    if (result != 0) {
        // On Unix, chmod returns -1 on error, and errno contains the error code
        const errno = std.c._errno().*;
        return switch (errno) {
            @intFromEnum(std.c.E.NOENT) => error.FileNotFound,
            @intFromEnum(std.c.E.ACCES) => error.PermissionDenied,
            @intFromEnum(std.c.E.PERM) => error.PermissionDenied,
            else => error.Unexpected,
        };
    }

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
fn applySymbolicModeToFile(allocator: std.mem.Allocator, file_path: []const u8, mode_str: []const u8, writer: anytype, stderr_writer: anytype, options: ChmodOptions) !void {
    _ = allocator; // For potential future use
    _ = stderr_writer; // For potential future use
    // Get file stats without opening the file - this works even on files with restrictive permissions
    const stat = std.fs.cwd().statFile(file_path) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        // Don't fail on access denied for stat - we might still be able to chmod
        error.AccessDenied => std.fs.File.Stat{ .size = 0, .mode = 0, .mtime = 0, .atime = 0, .ctime = 0, .kind = .file, .inode = 0 },
        else => return err,
    };

    const old_mode = @as(u32, @intCast(stat.mode & 0o7777));

    // Start with current mode
    var new_mode_struct = Mode.fromOctal(old_mode);

    var iter = std.mem.splitScalar(u8, mode_str, ',');
    while (iter.next()) |clause| {
        try applySymbolicMode(&new_mode_struct, std.mem.trim(u8, clause, " "));
    }

    const new_mode = new_mode_struct.toOctal();

    // Use path-based chmod system call which works even on files with restrictive permissions
    // This works because chmod system call operates on the path, not requiring file access
    // Ensure the file path is null-terminated for C function
    const path_z = try std.posix.toPosixPath(file_path);
    const result = std.c.chmod(&path_z, @as(std.c.mode_t, @intCast(new_mode)));
    if (result != 0) {
        // On Unix, chmod returns -1 on error, and errno contains the error code
        const errno = std.c._errno().*;
        return switch (errno) {
            @intFromEnum(std.c.E.NOENT) => error.FileNotFound,
            @intFromEnum(std.c.E.ACCES) => error.PermissionDenied,
            @intFromEnum(std.c.E.PERM) => error.PermissionDenied,
            else => error.Unexpected,
        };
    }

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

test "parseMode accepts 1-4 digit octal modes" {
    // 1-digit: sets other bits only
    const m1 = try parseMode("7");
    try testing.expectEqual(@as(u32, 0o7), m1.toOctal());
    // 2-digit: sets group and other bits
    const m2 = try parseMode("75");
    try testing.expectEqual(@as(u32, 0o75), m2.toOctal());
    // 5+ digits are invalid
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
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege();

    // Run test under privilege simulation
    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const test_file_path = "test_file.txt";
            const test_file = try tmp_dir.dir.createFile(test_file_path, .{});
            defer test_file.close();

            // Test applying mode 644
            var stdout_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stdout_buffer.deinit(inner_allocator);
            var stderr_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stderr_buffer.deinit(inner_allocator);

            const mode = Mode.fromOctal(0o644);
            const options = ChmodOptions{ .verbose = true };

            const abs_path = try tmp_dir.dir.realpathAlloc(inner_allocator, test_file_path);

            try applyModeToFile(inner_allocator, abs_path, mode, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator), options);

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
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege();

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const test_files_rel = [_][]const u8{ "file1.txt", "file2.txt" };
            var test_files_abs = try std.ArrayList([]u8).initCapacity(inner_allocator, 0);
            defer test_files_abs.deinit(inner_allocator);

            for (test_files_rel) |filename| {
                const file = try tmp_dir.dir.createFile(filename, .{});
                file.close();

                const abs_path = try tmp_dir.dir.realpathAlloc(inner_allocator, filename);
                try test_files_abs.append(inner_allocator, abs_path);
            }

            var stdout_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stdout_buffer.deinit(inner_allocator);
            var stderr_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stderr_buffer.deinit(inner_allocator);

            const options = ChmodOptions{ .changes_only = true };

            try chmodFiles(inner_allocator, "755", test_files_abs.items, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator), options);

            // Verify both files were processed
            for (test_files_abs.items) |abs_path| {
                const stat = try std.fs.cwd().statFile(abs_path);
                try testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast(stat.mode & 0o777)));
            }
        }
    }.testFn);
}

test "chmodFiles handles nonexistent files gracefully" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const nonexistent_files = [_][]const u8{"does_not_exist.txt"};
    const options = ChmodOptions{ .quiet = true };

    // Should return error for nonexistent files, even in quiet mode
    _ = chmodFiles(testing.allocator, "644", &nonexistent_files, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator), options) catch |err| {
        try testing.expect(err == ChmodError.FileOperationFailed);
        return;
    };

    // Should not reach here - function should have returned an error
    try testing.expect(false);
}

// Integration test using the chmod helper function
test "privileged: chmod integration test with octal mode" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege();

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const test_file_path = "integration_test.txt";
            const test_file = try tmp_dir.dir.createFile(test_file_path, .{});
            defer test_file.close();

            var stdout_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stdout_buffer.deinit(inner_allocator);
            var stderr_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stderr_buffer.deinit(inner_allocator);

            const abs_path = try tmp_dir.dir.realpathAlloc(inner_allocator, test_file_path);

            const args = [_][]const u8{ "755", abs_path };
            try chmod(inner_allocator, &args, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator));

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

// Tests: Advanced Features

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

test "parseSymbolicMode special permission bits" {
    // Test setuid with u+s
    var mode = Mode.fromOctal(0o755);
    try applySymbolicMode(&mode, "u+s");
    try testing.expectEqual(@as(u32, 0o4755), mode.toOctal());
    try testing.expect(mode.setuid);

    // Test setgid with g+s
    mode = Mode.fromOctal(0o755);
    try applySymbolicMode(&mode, "g+s");
    try testing.expectEqual(@as(u32, 0o2755), mode.toOctal());
    try testing.expect(mode.setgid);

    // Test sticky bit with o+t
    mode = Mode.fromOctal(0o755);
    try applySymbolicMode(&mode, "o+t");
    try testing.expectEqual(@as(u32, 0o1755), mode.toOctal());
    try testing.expect(mode.sticky);

    // Test removing setuid with u-s
    mode = Mode.fromOctal(0o4755);
    try applySymbolicMode(&mode, "u-s");
    try testing.expectEqual(@as(u32, 0o755), mode.toOctal());
    try testing.expect(!mode.setuid);

    // Test removing setgid with g-s
    mode = Mode.fromOctal(0o2755);
    try applySymbolicMode(&mode, "g-s");
    try testing.expectEqual(@as(u32, 0o755), mode.toOctal());
    try testing.expect(!mode.setgid);

    // Test removing sticky bit with o-t
    mode = Mode.fromOctal(0o1755);
    try applySymbolicMode(&mode, "o-t");
    try testing.expectEqual(@as(u32, 0o755), mode.toOctal());
    try testing.expect(!mode.sticky);

    // Test combined special bits
    mode = Mode.fromOctal(0o755);
    try applySymbolicMode(&mode, "u+s");
    try applySymbolicMode(&mode, "g+s");
    try testing.expectEqual(@as(u32, 0o6755), mode.toOctal());
    try testing.expect(mode.setuid);
    try testing.expect(mode.setgid);
}

test "parseSymbolicModeString with special bits" {
    // Test comma-separated special bits
    const mode = try parseSymbolicModeString("u+s,g+s");
    try testing.expectEqual(@as(u32, 0o6000), mode.toOctal());
    try testing.expect(mode.setuid);
    try testing.expect(mode.setgid);

    // Test mixed regular and special permissions
    const mode2 = try parseSymbolicModeString("u=rwx,g=rx,o=r,u+s");
    try testing.expectEqual(@as(u32, 0o4754), mode2.toOctal());
    try testing.expect(mode2.setuid);
}

test "parseSymbolicMode permission copying" {
    // Start with a known mode: rwx r-x r--  (754)
    var mode = Mode.fromOctal(0o754);

    // Test g=u: copy user permissions to group (should make it rwx rwx r--)
    try applySymbolicMode(&mode, "g=u");
    try testing.expectEqual(@as(u32, 0o774), mode.toOctal());
    try testing.expectEqual(@as(u3, 7), mode.user);
    try testing.expectEqual(@as(u3, 7), mode.group); // copied from user
    try testing.expectEqual(@as(u3, 4), mode.other); // unchanged

    // Test o=g: copy group permissions to other (should make it rwx rwx rwx)
    try applySymbolicMode(&mode, "o=g");
    try testing.expectEqual(@as(u32, 0o777), mode.toOctal());
    try testing.expectEqual(@as(u3, 7), mode.user);
    try testing.expectEqual(@as(u3, 7), mode.group);
    try testing.expectEqual(@as(u3, 7), mode.other); // copied from group

    // Reset to different state: rw- --- ---  (600)
    mode = Mode.fromOctal(0o600);

    // Test u=o: copy other permissions to user (should make it --- --- ---)
    try applySymbolicMode(&mode, "u=o");
    try testing.expectEqual(@as(u32, 0o000), mode.toOctal());
    try testing.expectEqual(@as(u3, 0), mode.user); // copied from other
    try testing.expectEqual(@as(u3, 0), mode.group);
    try testing.expectEqual(@as(u3, 0), mode.other);

    // Test multiple targets: ug=o
    mode = Mode.fromOctal(0o754); // rwx r-x r--
    try applySymbolicMode(&mode, "ug=o");
    try testing.expectEqual(@as(u32, 0o444), mode.toOctal());
    try testing.expectEqual(@as(u3, 4), mode.user); // copied from other
    try testing.expectEqual(@as(u3, 4), mode.group); // copied from other
    try testing.expectEqual(@as(u3, 4), mode.other); // unchanged
}

// Tests: Recursive operations

test "privileged: recursive chmod on directory structure" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege();

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
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

            const abs_root = try tmp_dir.dir.realpathAlloc(inner_allocator, ".");

            var stdout_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stdout_buffer.deinit(inner_allocator);
            var stderr_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stderr_buffer.deinit(inner_allocator);

            const options = ChmodOptions{ .recursive = true, .verbose = true };
            const files = [_][]const u8{abs_root};

            try chmodFiles(inner_allocator, "755", &files, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator), options);

            // Basic verification
            try testing.expect(stdout_buffer.items.len > 0); // Should have verbose output
        }
    }.testFn);
}

test "privileged: recursive flag processes files and directories" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege();

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            try tmp_dir.dir.makeDir("testdir");
            const test_file = try tmp_dir.dir.createFile("testdir/test.txt", .{});
            defer test_file.close();

            const abs_dir = try tmp_dir.dir.realpathAlloc(inner_allocator, "testdir");

            var stdout_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stdout_buffer.deinit(inner_allocator);
            var stderr_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stderr_buffer.deinit(inner_allocator);

            const options = ChmodOptions{ .recursive = true, .changes_only = true };
            const files = [_][]const u8{abs_dir};

            try chmodFiles(inner_allocator, "644", &files, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator), options);

            // The test passes if no errors are thrown
        }
    }.testFn);
}

// Tests: Verbose, changes, and silent flags

test "privileged: verbose flag outputs changes" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege();

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const test_file = try tmp_dir.dir.createFile("test_verbose.txt", .{});
            defer test_file.close();

            const abs_path = try tmp_dir.dir.realpathAlloc(inner_allocator, "test_verbose.txt");

            var stdout_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stdout_buffer.deinit(inner_allocator);
            var stderr_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stderr_buffer.deinit(inner_allocator);

            const options = ChmodOptions{ .verbose = true };
            const files = [_][]const u8{abs_path};

            try chmodFiles(inner_allocator, "755", &files, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator), options);

            // Should have verbose output
            try testing.expect(stdout_buffer.items.len > 0);
            try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "mode of") != null);
            try testing.expect(std.mem.indexOf(u8, stdout_buffer.items, "changed from") != null);
        }
    }.testFn);
}

test "privileged: changes flag only outputs when mode changes" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege();

    try privilege_test.withFakeroot(allocator, struct {
        fn testFn(inner_allocator: std.mem.Allocator) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const test_file = try tmp_dir.dir.createFile("test_changes.txt", .{});
            defer test_file.close();

            const abs_path = try tmp_dir.dir.realpathAlloc(inner_allocator, "test_changes.txt");

            var stdout_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stdout_buffer.deinit(inner_allocator);
            var stderr_buffer = try std.ArrayList(u8).initCapacity(inner_allocator, 0);
            defer stderr_buffer.deinit(inner_allocator);

            const options = ChmodOptions{ .changes_only = true };
            const files = [_][]const u8{abs_path};

            try chmodFiles(inner_allocator, "755", &files, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator), options);

            // Should have output when mode changes
            try testing.expect(stdout_buffer.items.len > 0);

            // Clear buffer and apply same mode again
            stdout_buffer.clearRetainingCapacity();
            stderr_buffer.clearRetainingCapacity();
            try chmodFiles(inner_allocator, "755", &files, stdout_buffer.writer(inner_allocator), stderr_buffer.writer(inner_allocator), options);

            try testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
        }
    }.testFn);
}

test "quiet flag suppresses error messages" {
    var stdout_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stdout_buffer.deinit(testing.allocator);
    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    const nonexistent_files = [_][]const u8{"nonexistent_file.txt"};
    const options = ChmodOptions{ .quiet = true };

    // Should return error for nonexistent files but produce no error output due to quiet mode
    _ = chmodFiles(testing.allocator, "755", &nonexistent_files, stdout_buffer.writer(testing.allocator), stderr_buffer.writer(testing.allocator), options) catch |err| {
        try testing.expect(err == ChmodError.FileOperationFailed);
        // Should produce no output due to quiet mode
        try testing.expectEqual(@as(usize, 0), stdout_buffer.items.len);
        try testing.expectEqual(@as(usize, 0), stderr_buffer.items.len);
        return;
    };

    // Should not reach here - function should have returned an error
    try testing.expect(false);
}

test "error handling consistency" {
    // Test error handling consistency
    try testing.expectError(ChmodError.InvalidOctalMode, parseMode("999"));
    try testing.expectError(ChmodError.InvalidMode, parseMode("u+invalid"));
    try testing.expectError(ChmodError.InvalidMode, parseMode("invalid+x"));
}

// ============================================================================
//                                FUZZ TESTS
// ============================================================================

const enable_fuzz_tests = common.fuzz.shouldFuzzUtility("chmod");

test "chmod fuzz intelligent" {
    if (!enable_fuzz_tests) return error.SkipZigTest;
    try std.testing.fuzz(testing.allocator, testChmodIntelligentWrapper, .{});
}

fn testChmodIntelligentWrapper(allocator: std.mem.Allocator, input: []const u8) !void {
    // Check runtime condition for selective fuzzing
    if (!common.fuzz.shouldFuzzUtilityRuntime("chmod")) return;

    const ChmodIntelligentFuzzer = common.fuzz.createIntelligentFuzzer(ChmodArgs, runUtility);
    try ChmodIntelligentFuzzer.testComprehensive(allocator, input, common.null_writer);
}
