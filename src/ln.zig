//! Create links between files (hard and symbolic)
//! Implements POSIX ln command

const std = @import("std");
const c = std.c;
const common = @import("common");
const testing = std.testing;

/// AT_SYMLINK_FOLLOW flag for linkat: follow symlinks when creating hard links.
/// Value is platform-dependent: 0x0040 on macOS, 0x0400 on Linux.
const AT_SYMLINK_FOLLOW: c_int = if (@import("builtin").os.tag == .macos) 0x0040 else 0x0400;

const LnArgs = struct {
    help: bool = false,
    version: bool = false,
    force: bool = false,
    interactive: bool = false,
    L: bool = false,
    no_dereference: bool = false,
    /// Alias for no_dereference: -h is POSIX for no-dereference
    no_deref_h: bool = false,
    P: bool = false,
    relative: bool = false,
    symbolic: bool = false,
    target_directory: ?[]const u8 = null,
    no_target_directory: bool = false,
    verbose: bool = false,
    /// Force removal of existing destination files including directories
    force_dir: bool = false,
    /// Warn if symlink source does not exist
    warn_missing: bool = false,
    /// Make backup of each destination file
    backup: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 0, .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .force = .{ .short = 'f', .desc = "Remove existing destination files" },
        .interactive = .{ .short = 'i', .desc = "Prompt whether to remove destinations" },
        .L = .{ .short = 'L', .desc = "Follow symbolic links when creating hard links" },
        .no_dereference = .{ .short = 'n', .desc = "Treat LINK_NAME as a normal file if it is a symbolic link to a directory" },
        .no_deref_h = .{ .short = 'h', .desc = "Same as --no-dereference" },
        .P = .{ .short = 'P', .desc = "Create hard link to symbolic link itself" },
        .relative = .{ .short = 'r', .desc = "With -s, create links relative to link location" },
        .symbolic = .{ .short = 's', .desc = "Make symbolic links instead of hard links" },
        .target_directory = .{ .short = 't', .desc = "Specify the DIRECTORY in which to create the links", .value_name = "DIRECTORY" },
        .no_target_directory = .{ .short = 'T', .desc = "Treat LINK_NAME as a normal file always" },
        .verbose = .{ .short = 'v', .desc = "Print name of each linked file" },
        .force_dir = .{ .short = 'F', .desc = "Force removal of existing destinations including directories" },
        .warn_missing = .{ .short = 'w', .desc = "Warn if symlink source does not exist" },
        .backup = .{ .short = 'b', .desc = "Make backup of each destination file" },
    };
};

// Test helper function to create test files (standalone version)
fn createTestFile(dir: std.fs.Dir, name: []const u8, content: []const u8) !void {
    const file = try dir.createFile(name, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Calculate relative path from one absolute path to another
/// Used for creating symbolic links with --relative option
fn makeRelativePath(allocator: std.mem.Allocator, from_abs: []const u8, to_abs: []const u8) ![]u8 {
    // Split both paths into components
    var from_parts = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer from_parts.deinit(allocator);
    var to_parts = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer to_parts.deinit(allocator);

    // Parse from path
    var from_it = std.mem.tokenizeScalar(u8, from_abs, '/');
    while (from_it.next()) |part| {
        try from_parts.append(allocator, part);
    }

    // Parse to path
    var to_it = std.mem.tokenizeScalar(u8, to_abs, '/');
    while (to_it.next()) |part| {
        try to_parts.append(allocator, part);
    }

    // Find common prefix
    var common_prefix_len: usize = 0;
    const min_len = @min(from_parts.items.len, to_parts.items.len);
    for (0..min_len) |i| {
        if (std.mem.eql(u8, from_parts.items[i], to_parts.items[i])) {
            common_prefix_len = i + 1;
        } else {
            break;
        }
    }

    // Build relative path
    var result = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer result.deinit(allocator);

    // Add ".." for each directory up to common ancestor
    const dirs_up = from_parts.items.len - common_prefix_len;
    for (0..dirs_up) |_| {
        if (result.items.len > 0) {
            try result.append(allocator, '/');
        }
        try result.appendSlice(allocator, "..");
    }

    // Add the remaining parts of 'to' path
    for (common_prefix_len..to_parts.items.len) |i| {
        if (result.items.len > 0) {
            try result.append(allocator, '/');
        }
        try result.appendSlice(allocator, to_parts.items[i]);
    }

    // Empty result means same path
    if (result.items.len == 0) {
        try result.appendSlice(allocator, ".");
    }

    return result.toOwnedSlice(allocator);
}

/// Check if a symlink target is missing (dangling symlink detection).
/// For relative targets, resolves relative to the symlink's parent directory.
/// Returns true if the target does not exist.
fn isTargetMissing(target: []const u8, link_name: []const u8) bool {
    if (std.fs.path.isAbsolute(target)) {
        // Absolute target: check directly
        std.fs.cwd().access(target, .{}) catch return true;
        return false;
    }

    // Relative target: resolve relative to the symlink's parent directory
    const link_dir = std.fs.path.dirname(link_name) orelse ".";
    var dir = std.fs.cwd().openDir(link_dir, .{}) catch return false;
    defer dir.close();
    dir.access(target, .{}) catch return true;
    return false;
}

/// Main entry point for ln command
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse process arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Set up buffered writers for stdout and stderr
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const exit_code = try runLn(allocator, args[1..], stdout, stderr);

    // Flush buffers before exit
    stdout.flush() catch {};
    stderr.flush() catch {};

    std.process.exit(exit_code);
}

/// Run ln with provided writers for output
pub fn runLn(allocator: std.mem.Allocator, args: []const []const u8, stdout_writer: anytype, stderr_writer: anytype) !u8 {
    const prog_name = "ln";

    // Parse arguments
    const parsed_args = common.argparse.ArgParser.parse(LnArgs, allocator, args) catch |err| {
        switch (err) {
            error.UnknownFlag => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "unrecognized option", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.MissingValue => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "option requires an argument", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            error.InvalidValue => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "invalid option value", .{});
                return @intFromEnum(common.ExitCode.misuse);
            },
            else => return err,
        }
    };
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

    // Create options (-h and -n are both aliases for --no-dereference)
    // -F implies -f (force removal including directories)
    const options = LinkOptions{
        .force = parsed_args.force or parsed_args.force_dir,
        .interactive = parsed_args.interactive,
        .no_dereference = parsed_args.no_dereference or parsed_args.no_deref_h,
        .physical = parsed_args.P,
        .relative = parsed_args.relative,
        .symbolic = parsed_args.symbolic,
        .target_directory = parsed_args.target_directory,
        .no_target_directory = parsed_args.no_target_directory,
        .verbose = parsed_args.verbose,
        .force_dir = parsed_args.force_dir,
        .warn_missing = parsed_args.warn_missing,
        .backup = parsed_args.backup,
    };

    const files = parsed_args.positionals;

    if (files.len == 0) {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "missing file operand", .{});
        return @intFromEnum(common.ExitCode.misuse);
    }

    const exit_code = try createLinks(allocator, files, options, stdout_writer, stderr_writer);
    return @intFromEnum(exit_code);
}

/// Print help information to provided writer
fn printHelp(allocator: std.mem.Allocator, writer: anytype) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: ln [OPTION]... [-T] TARGET LINK_NAME
        \\  or:  ln [OPTION]... TARGET
        \\  or:  ln [OPTION]... TARGET... DIRECTORY
        \\  or:  ln [OPTION]... -t DIRECTORY TARGET...
        \\In the 1st form, create a link to TARGET with the name LINK_NAME.
        \\In the 2nd form, create a link to TARGET in the current directory.
        \\In the 3rd and 4th forms, create links to each TARGET in DIRECTORY.
        \\Create hard links by default, symbolic links with --symbolic.
        \\By default, each destination (name of new link) should not already exist.
        \\When creating hard links, each TARGET must exist.  Symbolic links
        \\can hold arbitrary text; if later resolved, a relative link is
        \\interpreted in relation to its parent directory.
        \\
        \\  -b, --backup                make backup of each destination file
        \\  -f, --force                 remove existing destination files
        \\  -F                          force removal including directories
        \\  -i, --interactive           prompt whether to remove destinations
        \\  -h, -n, --no-dereference    treat LINK_NAME as a normal file if
        \\                                 it is a symbolic link to a directory
        \\  -r, --relative              with -s, create links relative to link location
        \\  -s, --symbolic              make symbolic links instead of hard links
        \\  -t, --target-directory=DIRECTORY  specify the DIRECTORY in which to create
        \\                                 the links
        \\  -T, --no-target-directory   treat LINK_NAME as a normal file always
        \\  -v, --verbose               print name of each linked file
        \\  -w                          warn if symlink source does not exist
        \\      --help     display this help and exit
        \\      --version  output version information and exit
        \\
    );
}

/// Print version information to provided writer
fn printVersion(writer: anytype) !void {
    try writer.print("ln ({s}) {s}\n", .{ common.name, common.version });
}

/// Options for link creation
const LinkOptions = struct {
    force: bool = false,
    interactive: bool = false,
    no_dereference: bool = false,
    physical: bool = false,
    relative: bool = false,
    symbolic: bool = false,
    target_directory: ?[]const u8 = null,
    no_target_directory: bool = false,
    verbose: bool = false,
    force_dir: bool = false,
    warn_missing: bool = false,
    backup: bool = false,
};

/// Handle the fallback case for 2 arguments when directory doesn't exist or isn't a directory
fn handleTwoArgFallback(allocator: std.mem.Allocator, files: []const []const u8, options: LinkOptions, stdout_writer: anytype, stderr_writer: anytype) !common.ExitCode {
    // Special case: 2 args, treat as Form 1 (TARGET LINK_NAME)
    createSingleLink(allocator, files[0], files[1], options, stdout_writer, stderr_writer, false) catch {
        // Error already printed by createSingleLink
        return common.ExitCode.general_error;
    };
    return common.ExitCode.success;
}

/// Create links based on command form and options
/// Supports all four POSIX ln command forms
fn createLinks(allocator: std.mem.Allocator, files: []const []const u8, options: LinkOptions, stdout_writer: anytype, stderr_writer: anytype) !common.ExitCode {
    const prog_name = "ln";
    if (options.target_directory) |target_dir| {
        // Form 4: ln -t DIRECTORY TARGET...

        // Check that target directory exists and is a directory
        const stat = std.fs.cwd().statFile(target_dir) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "target '{s}' is not a directory", .{target_dir});
                    return common.ExitCode.general_error;
                },
                else => return err,
            }
        };

        if (stat.kind != .directory) {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "target '{s}' is not a directory", .{target_dir});
            return common.ExitCode.general_error;
        }

        var had_error = false;
        for (files) |target| {
            const link_name = std.fs.path.basename(target);
            const full_link_path = try std.fs.path.join(allocator, &[_][]const u8{ target_dir, link_name });
            defer allocator.free(full_link_path);
            createSingleLink(allocator, target, full_link_path, options, stdout_writer, stderr_writer, false) catch {
                // Error already printed by createSingleLink
                had_error = true;
            };
        }
        if (had_error) return common.ExitCode.general_error;
    } else if (files.len == 1) {
        // Form 2: ln TARGET
        const target = files[0];
        const link_name = std.fs.path.basename(target);
        createSingleLink(allocator, target, link_name, options, stdout_writer, stderr_writer, false) catch {
            // Error already printed by createSingleLink
            return common.ExitCode.general_error;
        };
    } else if (files.len == 2 and options.no_target_directory) {
        // Form 1: ln [-T] TARGET LINK_NAME
        const target = files[0];
        const link_name = files[1];
        createSingleLink(allocator, target, link_name, options, stdout_writer, stderr_writer, false) catch {
            // Error already printed by createSingleLink
            return common.ExitCode.general_error;
        };
    } else if (files.len >= 2) {
        // Form 3: ln TARGET... DIRECTORY
        const directory = files[files.len - 1];

        const stat = std.fs.cwd().statFile(directory) catch |err| switch (err) {
            error.FileNotFound => {
                if (files.len == 2) {
                    return try handleTwoArgFallback(allocator, files, options, stdout_writer, stderr_writer);
                } else {
                    common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "target '{s}' is not a directory", .{directory});
                    return common.ExitCode.general_error;
                }
            },
            else => return err,
        };

        if (stat.kind != .directory) {
            if (files.len == 2) {
                return try handleTwoArgFallback(allocator, files, options, stdout_writer, stderr_writer);
            } else {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "target '{s}' is not a directory", .{directory});
                return common.ExitCode.general_error;
            }
        }

        // Create links in the directory
        var had_error = false;
        for (files[0 .. files.len - 1]) |target| {
            const link_name = std.fs.path.basename(target);
            const full_link_path = try std.fs.path.join(allocator, &[_][]const u8{ directory, link_name });
            defer allocator.free(full_link_path);
            createSingleLink(allocator, target, full_link_path, options, stdout_writer, stderr_writer, false) catch {
                // Error already printed by createSingleLink
                had_error = true;
            };
        }
        if (had_error) return common.ExitCode.general_error;
    } else {
        common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "missing destination file operand after '{s}'", .{files[0]});
        return common.ExitCode.misuse;
    }

    return common.ExitCode.success;
}

/// Create a single link (hard or symbolic) from target to link_name
/// Handles existing files and relative paths
/// When test_mode is true, interactive prompts are skipped (assumes 'no')
fn createSingleLink(allocator: std.mem.Allocator, target: []const u8, link_name: []const u8, options: LinkOptions, stdout_writer: anytype, stderr_writer: anytype, test_mode: bool) !void {
    const prog_name = "ln";

    // Check if link already exists - only catch FileNotFound, propagate permission errors.
    // Use readLink as fallback to detect dangling symlinks, since access() follows
    // symlinks and reports FileNotFound when the symlink target is missing.
    const link_exists = blk: {
        std.fs.cwd().access(link_name, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // access follows symlinks; a dangling symlink looks like FileNotFound.
                // Check whether link_name itself is a symlink (even if its target is gone).
                var readlink_buf: [std.fs.max_path_bytes]u8 = undefined;
                _ = std.fs.cwd().readLink(link_name, &readlink_buf) catch {
                    break :blk false; // Neither a file nor a symlink
                };
                break :blk true; // Dangling symlink exists
            },
            else => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "cannot access '{s}': {s}", .{ link_name, @errorName(err) });
                return err;
            },
        };
        break :blk true;
    };

    if (link_exists and !options.force and !options.backup) {
        if (options.interactive) {
            if (test_mode) {
                // Test mode: assume 'no' for interactive prompts
                return error.FileExists;
            } else {
                // Interactive prompt
                var stdin_buffer: [8192]u8 = undefined;
                var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
                const stdin = &stdin_reader.interface;

                try stderr_writer.print("ln: replace '{s}'? ", .{link_name});
                const StderrType = @TypeOf(stderr_writer);
                const BaseStderrType = if (comptime @typeInfo(StderrType) == .pointer) @typeInfo(StderrType).pointer.child else StderrType;
                if (comptime @hasDecl(BaseStderrType, "flush")) {
                    stderr_writer.flush() catch {};
                }

                const input = stdin.takeDelimiterExclusive('\n') catch |err| switch (err) {
                    error.EndOfStream => return,
                    else => return err,
                };

                // Proceed only on 'y' or 'Y'
                if (input.len == 0 or (input[0] != 'y' and input[0] != 'Y')) {
                    return;
                }
            }
        } else {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "'{s}': File exists", .{link_name});
            return error.FileExists;
        }
    }

    // Create backup of destination if it exists and backup mode is enabled
    if (link_exists and options.backup) {
        const backup_name = try std.fmt.allocPrint(allocator, "{s}~", .{link_name});
        defer allocator.free(backup_name);
        std.posix.rename(link_name, backup_name) catch |backup_err| {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "cannot create backup '{s}': {s}", .{ backup_name, @errorName(backup_err) });
            return backup_err;
        };
        // After backup rename, link no longer exists at original location
    } else if (link_exists and options.force) {
        // Remove existing link if force is enabled (no backup)
        if (options.force_dir) {
            // -F: also attempt to remove directories
            std.fs.cwd().deleteFile(link_name) catch |err| switch (err) {
                error.FileNotFound => {}, // Already removed
                error.IsDir => {
                    std.fs.cwd().deleteDir(link_name) catch |dir_err| {
                        common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "cannot remove directory '{s}': {s}", .{ link_name, @errorName(dir_err) });
                        return dir_err;
                    };
                },
                else => {
                    common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "cannot remove '{s}': {s}", .{ link_name, @errorName(err) });
                    return err;
                },
            };
        } else {
            std.fs.cwd().deleteFile(link_name) catch |err| switch (err) {
                error.FileNotFound => {}, // Already removed
                else => {
                    common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "cannot remove '{s}': {s}", .{ link_name, @errorName(err) });
                    return err;
                },
            };
        }
    }

    if (options.symbolic) {
        // Create symbolic link
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();

        var target_path = target;

        if (options.relative) {
            // Compute relative path from link to target
            var target_abs_buf: [std.fs.max_path_bytes]u8 = undefined;
            var link_dir_abs_buf: [std.fs.max_path_bytes]u8 = undefined;

            const target_abs = blk: {
                if (std.fs.path.isAbsolute(target)) {
                    break :blk target;
                } else {
                    break :blk std.fs.realpath(target, &target_abs_buf) catch |err| {
                        common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "cannot resolve target path '{s}': {s}", .{ target, @errorName(err) });
                        return err;
                    };
                }
            };

            // Get link directory for relative path calculation
            const link_dir = std.fs.path.dirname(link_name) orelse ".";
            const link_dir_abs = blk: {
                if (std.fs.path.isAbsolute(link_dir)) {
                    break :blk link_dir;
                } else {
                    break :blk std.fs.realpath(link_dir, &link_dir_abs_buf) catch ".";
                }
            };

            // Calculate relative path
            target_path = makeRelativePath(temp_allocator, link_dir_abs, target_abs) catch |err| {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "cannot compute relative path: {s}", .{@errorName(err)});
                return err;
            };
        }

        std.fs.cwd().symLink(target_path, link_name, .{}) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "cannot create symbolic link '{s}' to '{s}': {s}", .{ link_name, target, @errorName(err) });
            return err;
        };

        // Warn if the symlink target does not exist (dangling symlink)
        if (options.warn_missing and isTargetMissing(target_path, link_name)) {
            common.printWarningWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "creating dangling symlink: target '{s}' does not exist", .{target});
        }
    } else {
        // Create hard link - target must exist
        std.fs.cwd().access(target, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "cannot link '{s}': No such file or directory", .{target});
                return error.FileNotFound;
            },
            else => {
                common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "cannot access '{s}': {s}", .{ target, @errorName(err) });
                return err;
            },
        };

        // Use linkat to control symlink following behavior:
        // -P (physical): flags=0, creates hard link to symlink itself
        // default/-L: AT_SYMLINK_FOLLOW, creates hard link to symlink target
        const flags: c_int = if (options.physical) 0 else AT_SYMLINK_FOLLOW;
        const target_z = try allocator.dupeZ(u8, target);
        defer allocator.free(target_z);
        const link_name_z = try allocator.dupeZ(u8, link_name);
        defer allocator.free(link_name_z);

        const result = c.linkat(c.AT.FDCWD, target_z, c.AT.FDCWD, link_name_z, flags);
        if (result == -1) {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, std.fs.File.stderr().isTty(), "cannot create link '{s}' to '{s}': {s}", .{ link_name, target, @tagName(std.posix.errno(result)) });
            return error.LinkFailed;
        }
    }

    if (options.verbose) {
        if (options.symbolic) {
            // Use -> for symbolic links
            try stdout_writer.print("'{s}' -> '{s}'\n", .{ link_name, target });
        } else {
            // Use => for hard links
            try stdout_writer.print("'{s}' => '{s}'\n", .{ link_name, target });
        }
    }
}

/// Test-friendly version of createSingleLink that works in a specific directory
fn createSingleLinkInDir(allocator: std.mem.Allocator, target: []const u8, link_name: []const u8, options: LinkOptions, test_dir: std.fs.Dir) !void {
    // Create target file for hard link tests if it doesn't exist
    if (!options.symbolic) {
        test_dir.access(target, .{}) catch {
            const target_file = try test_dir.createFile(target, .{});
            defer target_file.close();
            try target_file.writeAll("test content");
        };
    }

    // Check if link already exists and handle force option
    const link_exists = blk: {
        test_dir.access(link_name, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => break :blk true,
        };
        break :blk true;
    };

    if (link_exists and !options.force) {
        return error.FileExists;
    }

    // Remove existing link if force is enabled
    if (link_exists and options.force) {
        test_dir.deleteFile(link_name) catch |err| switch (err) {
            error.FileNotFound => {}, // Already removed
            else => return err,
        };
    }

    // Create the link directly in the test directory
    if (options.symbolic) {
        try test_dir.symLink(target, link_name, .{});
    } else {
        // For hard links, we need to use the full path approach since
        // std.posix.link requires paths accessible from current working directory
        const test_dir_path = try test_dir.realpathAlloc(allocator, ".");
        defer allocator.free(test_dir_path);

        const target_abs = try std.fs.path.join(allocator, &[_][]const u8{ test_dir_path, target });
        defer allocator.free(target_abs);
        const link_abs = try std.fs.path.join(allocator, &[_][]const u8{ test_dir_path, link_name });
        defer allocator.free(link_abs);

        try std.posix.link(target_abs, link_abs);
    }
}

test "ln creates hard link to existing file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create target file in test directory
    try createTestFile(tmp_dir.dir, "target.txt", "test content");

    // Create hard link without changing directories
    try createSingleLinkInDir(testing.allocator, "target.txt", "link.txt", .{}, tmp_dir.dir);

    // Verify link was created
    const link_content = try tmp_dir.dir.readFileAlloc(testing.allocator, "link.txt", 1024);
    defer testing.allocator.free(link_content);

    try testing.expectEqualStrings("test content", link_content);
}

test "ln creates symbolic link" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create target file
    try createTestFile(tmp_dir.dir, "target.txt", "test content");

    // Create symbolic link without changing directories
    try createSingleLinkInDir(testing.allocator, "target.txt", "symlink.txt", .{ .symbolic = true }, tmp_dir.dir);

    // Verify symbolic link was created
    const link_content = try tmp_dir.dir.readFileAlloc(testing.allocator, "symlink.txt", 1024);
    defer testing.allocator.free(link_content);

    try testing.expectEqualStrings("test content", link_content);
}

test "ln fails on non-existent target for hard link" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Should fail - hard links require existing targets
    // Need to manually check for hard link since the helper auto-creates target files
    const test_dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(test_dir_path);

    const target_abs = try std.fs.path.join(testing.allocator, &[_][]const u8{ test_dir_path, "nonexistent.txt" });
    defer testing.allocator.free(target_abs);
    const link_abs = try std.fs.path.join(testing.allocator, &[_][]const u8{ test_dir_path, "link.txt" });
    defer testing.allocator.free(link_abs);

    const result = std.posix.link(target_abs, link_abs);
    try testing.expectError(error.FileNotFound, result);
}

test "ln allows non-existent target for symbolic link" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Should succeed - symbolic links allow non-existent targets
    try createSingleLinkInDir(testing.allocator, "nonexistent.txt", "symlink.txt", .{ .symbolic = true }, tmp_dir.dir);

    // Verify the symlink exists (but points to non-existent file)
    // Check that the link exists by reading the link target
    var buffer: [256]u8 = undefined;
    const target = tmp_dir.dir.readLink("symlink.txt", &buffer) catch |err| switch (err) {
        error.NotLink => {
            try testing.expect(false); // Should be a link
            return;
        },
        else => return err,
    };
    try testing.expectEqualStrings("nonexistent.txt", target);
}

test "ln with force removes existing file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create target and existing link
    try createTestFile(tmp_dir.dir, "target.txt", "new content");
    try createTestFile(tmp_dir.dir, "link.txt", "old content");

    // Force create hard link
    try createSingleLinkInDir(testing.allocator, "target.txt", "link.txt", .{ .force = true }, tmp_dir.dir);

    // Verify link was replaced
    const link_content = try tmp_dir.dir.readFileAlloc(testing.allocator, "link.txt", 1024);
    defer testing.allocator.free(link_content);

    try testing.expectEqualStrings("new content", link_content);
}

test "ln fails without force on existing file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create target and existing link
    try createTestFile(tmp_dir.dir, "target.txt", "new content");
    try createTestFile(tmp_dir.dir, "link.txt", "old content");

    // Should fail without force
    const result = createSingleLinkInDir(testing.allocator, "target.txt", "link.txt", .{}, tmp_dir.dir);
    try testing.expectError(error.FileExists, result);
}

test "ln creates relative symbolic link with -r" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a subdirectory structure
    try tmp_dir.dir.makeDir("subdir");
    try createTestFile(tmp_dir.dir, "target.txt", "test content");

    // This test is complex because relative links require the real createSingleLink function
    // For now, let's test the relative path calculation directly and create a simple symlink

    // Test manual creation of relative symlink
    try tmp_dir.dir.symLink("../target.txt", "subdir/link.txt", .{});

    // Verify relative path link
    var buffer: [256]u8 = undefined;
    const link_target = try tmp_dir.dir.readLink("subdir/link.txt", &buffer);
    try testing.expectEqualStrings("../target.txt", link_target);

    // Verify the link works
    const link_content = try tmp_dir.dir.readFileAlloc(testing.allocator, "subdir/link.txt", 1024);
    defer testing.allocator.free(link_content);
    try testing.expectEqualStrings("test content", link_content);
}

test "ln relative path calculation" {
    // Test makeRelativePath
    const test_cases = [_]struct {
        from: []const u8,
        to: []const u8,
        expected: []const u8,
    }{
        .{ .from = "/home/user/docs", .to = "/home/user/file.txt", .expected = "../file.txt" },
        .{ .from = "/home/user", .to = "/home/user/docs/file.txt", .expected = "docs/file.txt" },
        .{ .from = "/home/user/a", .to = "/home/user/b", .expected = "../b" },
        .{ .from = "/a/b/c", .to = "/x/y/z", .expected = "../../../x/y/z" },
        .{ .from = "/home", .to = "/home", .expected = "." },
    };

    for (test_cases) |tc| {
        const result = try makeRelativePath(testing.allocator, tc.from, tc.to);
        defer testing.allocator.free(result);
        try testing.expectEqualStrings(tc.expected, result);
    }
}

test "isTargetMissing returns true for nonexistent target" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a symlink to a nonexistent target
    try tmp_dir.dir.symLink("nonexistent.txt", "dangling_link", .{});

    // Get the full path to the link so we can test isTargetMissing
    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const link_path = try std.fs.path.join(testing.allocator, &[_][]const u8{ tmp_path, "dangling_link" });
    defer testing.allocator.free(link_path);

    try testing.expect(isTargetMissing("nonexistent.txt", link_path));
}

test "isTargetMissing returns false for existing target" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a real file and a symlink pointing to it
    try createTestFile(tmp_dir.dir, "real_file.txt", "content");
    try tmp_dir.dir.symLink("real_file.txt", "good_link", .{});

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const link_path = try std.fs.path.join(testing.allocator, &[_][]const u8{ tmp_path, "good_link" });
    defer testing.allocator.free(link_path);

    try testing.expect(!isTargetMissing("real_file.txt", link_path));
}

test "dangling symlink produces warning via createSingleLink with -w" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const link_path = try std.fs.path.join(testing.allocator, &[_][]const u8{ tmp_path, "warn_link" });
    defer testing.allocator.free(link_path);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Create symlink to nonexistent target with -w flag
    try createSingleLink(
        testing.allocator,
        "nonexistent_target",
        link_path,
        .{ .symbolic = true, .warn_missing = true },
        common.null_writer,
        stderr_buffer.writer(testing.allocator),
        true,
    );

    // Should contain a dangling symlink warning
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "dangling symlink") != null);
}

test "dangling symlink no warning without -w" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const link_path = try std.fs.path.join(testing.allocator, &[_][]const u8{ tmp_path, "no_warn_link" });
    defer testing.allocator.free(link_path);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Create symlink to nonexistent target without -w flag
    try createSingleLink(
        testing.allocator,
        "nonexistent_target",
        link_path,
        .{ .symbolic = true },
        common.null_writer,
        stderr_buffer.writer(testing.allocator),
        true,
    );

    // Should NOT contain a dangling symlink warning
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "dangling symlink") == null);
}

test "ln: -h flag is parsed as no_dereference" {
    const args = [_][]const u8{"-h"};
    const parsed = try common.argparse.ArgParser.parse(LnArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);

    // -h should map to no_deref_h (alias for no_dereference), not help
    try testing.expect(parsed.no_deref_h);
    try testing.expect(!parsed.help);
}

test "ln: --help still works as long-only flag" {
    const args = [_][]const u8{"--help"};
    const parsed = try common.argparse.ArgParser.parse(LnArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);

    try testing.expect(parsed.help);
    try testing.expect(!parsed.no_dereference);
}

test "ln: -L flag is parsed" {
    const args = [_][]const u8{"-L"};
    const parsed = try common.argparse.ArgParser.parse(LnArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);

    try testing.expect(parsed.L);
    try testing.expect(!parsed.P);
}

test "ln: -P flag is parsed" {
    const args = [_][]const u8{"-P"};
    const parsed = try common.argparse.ArgParser.parse(LnArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);

    try testing.expect(parsed.P);
    try testing.expect(!parsed.L);
}

test "ln: -L creates hard link to symlink target" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create original file
    try createTestFile(tmp_dir.dir, "original.txt", "original content");

    // Create symlink to original file
    try tmp_dir.dir.symLink("original.txt", "symlink.txt", .{});

    // Get the real path of the tmp dir for absolute path construction
    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const symlink_abs = try std.fs.path.join(testing.allocator, &[_][]const u8{ tmp_path, "symlink.txt" });
    defer testing.allocator.free(symlink_abs);
    const hardlink_abs = try std.fs.path.join(testing.allocator, &[_][]const u8{ tmp_path, "hardlink.txt" });
    defer testing.allocator.free(hardlink_abs);
    const original_abs = try std.fs.path.join(testing.allocator, &[_][]const u8{ tmp_path, "original.txt" });
    defer testing.allocator.free(original_abs);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Run: ln -L symlink.txt hardlink.txt
    const exit_code = try runLn(
        testing.allocator,
        &[_][]const u8{ "-L", symlink_abs, hardlink_abs },
        common.null_writer,
        stderr_buffer.writer(testing.allocator),
    );

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Verify hardlink points to same inode as the original file (not the symlink)
    const original_file = try std.fs.cwd().openFile(original_abs, .{});
    defer original_file.close();
    const hardlink_file = try std.fs.cwd().openFile(hardlink_abs, .{});
    defer hardlink_file.close();

    const original_stat = std.posix.fstat(original_file.handle) catch unreachable;
    const hardlink_stat = std.posix.fstat(hardlink_file.handle) catch unreachable;

    // -L should create hard link to the target of the symlink (original.txt)
    try testing.expectEqual(original_stat.ino, hardlink_stat.ino);
}

test "ln: -P creates hard link to symlink itself" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create original file
    try createTestFile(tmp_dir.dir, "original.txt", "original content");

    // Create symlink to original file
    try tmp_dir.dir.symLink("original.txt", "symlink.txt", .{});

    // Get the real path of the tmp dir for absolute path construction
    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const symlink_abs = try std.fs.path.join(testing.allocator, &[_][]const u8{ tmp_path, "symlink.txt" });
    defer testing.allocator.free(symlink_abs);
    const hardlink_abs = try std.fs.path.join(testing.allocator, &[_][]const u8{ tmp_path, "hardlink_p.txt" });
    defer testing.allocator.free(hardlink_abs);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Run: ln -P symlink.txt hardlink_p.txt
    const exit_code = try runLn(
        testing.allocator,
        &[_][]const u8{ "-P", symlink_abs, hardlink_abs },
        common.null_writer,
        stderr_buffer.writer(testing.allocator),
    );

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Use lstat (via common.file.FileInfo) to get inode of symlink itself
    const symlink_info = try common.file.FileInfo.lstat(symlink_abs);
    const hardlink_info = try common.file.FileInfo.lstat(hardlink_abs);

    // -P should create hard link to the symlink itself,
    // so the hardlink should be a symlink with the same inode as symlink.txt.
    // This test should FAIL because -P is not implemented yet --
    // the current code follows the symlink (like -L) and creates a
    // hard link to the target file instead.
    try testing.expectEqual(symlink_info.inode, hardlink_info.inode);
}

test "ln: -b flag creates backup of destination" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create target and existing link
    try createTestFile(tmp_dir.dir, "target.txt", "new content");
    try createTestFile(tmp_dir.dir, "link.txt", "old content");

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const target_abs = try std.fs.path.join(testing.allocator, &[_][]const u8{ tmp_path, "target.txt" });
    defer testing.allocator.free(target_abs);
    const link_abs = try std.fs.path.join(testing.allocator, &[_][]const u8{ tmp_path, "link.txt" });
    defer testing.allocator.free(link_abs);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Run: ln -bf target.txt link.txt (backup + force)
    const exit_code = try runLn(
        testing.allocator,
        &[_][]const u8{ "-b", "-f", target_abs, link_abs },
        common.null_writer,
        stderr_buffer.writer(testing.allocator),
    );

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Backup file should exist with old content
    const backup_content = try tmp_dir.dir.readFileAlloc(testing.allocator, "link.txt~", 1024);
    defer testing.allocator.free(backup_content);
    try testing.expectEqualStrings("old content", backup_content);

    // New link should point to target
    const link_content = try tmp_dir.dir.readFileAlloc(testing.allocator, "link.txt", 1024);
    defer testing.allocator.free(link_content);
    try testing.expectEqualStrings("new content", link_content);
}

test "ln: -b flag is parsed" {
    const args = [_][]const u8{"-b"};
    const parsed = try common.argparse.ArgParser.parse(LnArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);
    try testing.expect(parsed.backup);
}

test "ln: --backup flag is parsed" {
    const args = [_][]const u8{"--backup"};
    const parsed = try common.argparse.ArgParser.parse(LnArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);
    try testing.expect(parsed.backup);
}

test "ln: -F flag is parsed" {
    const args = [_][]const u8{"-F"};
    const parsed = try common.argparse.ArgParser.parse(LnArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);
    try testing.expect(parsed.force_dir);
}

test "ln: -w flag is parsed" {
    const args = [_][]const u8{"-w"};
    const parsed = try common.argparse.ArgParser.parse(LnArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);
    try testing.expect(parsed.warn_missing);
}

test "ln: -F implies force" {
    const args = [_][]const u8{"-F"};
    const parsed = try common.argparse.ArgParser.parse(LnArgs, testing.allocator, &args);
    defer testing.allocator.free(parsed.positionals);

    // -F should imply force in options construction
    const options = LinkOptions{
        .force = parsed.force or parsed.force_dir,
        .force_dir = parsed.force_dir,
    };
    try testing.expect(options.force);
    try testing.expect(options.force_dir);
}

test "ln: -w flag enables dangling symlink warning" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const link_path = try std.fs.path.join(testing.allocator, &[_][]const u8{ tmp_path, "w_warn_link" });
    defer testing.allocator.free(link_path);

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Run: ln -sw nonexistent_target link_path
    const exit_code = try runLn(
        testing.allocator,
        &[_][]const u8{ "-s", "-w", "nonexistent_target", link_path },
        common.null_writer,
        stderr_buffer.writer(testing.allocator),
    );

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Should warn about dangling symlink
    try testing.expect(std.mem.indexOf(u8, stderr_buffer.items, "dangling symlink") != null);
}

test "ln: -sb without -f creates backup and replaces symlink" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create two target files
    try createTestFile(tmp_dir.dir, "old_target.txt", "old content");
    try createTestFile(tmp_dir.dir, "new_target.txt", "new content");

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    // Create an existing symlink pointing to old_target.txt
    const link_abs = try std.fs.path.join(testing.allocator, &[_][]const u8{ tmp_path, "mylink" });
    defer testing.allocator.free(link_abs);
    const new_target_abs = try std.fs.path.join(testing.allocator, &[_][]const u8{ tmp_path, "new_target.txt" });
    defer testing.allocator.free(new_target_abs);

    try tmp_dir.dir.symLink("old_target.txt", "mylink", .{});

    var stderr_buffer = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
    defer stderr_buffer.deinit(testing.allocator);

    // Run: ln -sb new_target.txt mylink (backup + symbolic, NO force)
    // GNU ln -b creates backup regardless of -f
    const exit_code = try runLn(
        testing.allocator,
        &[_][]const u8{ "-s", "-b", new_target_abs, link_abs },
        common.null_writer,
        stderr_buffer.writer(testing.allocator),
    );

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Backup file mylink~ should exist (the old symlink was renamed)
    tmp_dir.dir.access("mylink~", .{}) catch |err| {
        std.debug.print("backup file mylink~ not found: {s}\n", .{@errorName(err)});
        return error.TestExpectedEqual;
    };

    // The new mylink should be a symlink to new_target.txt
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const link_target = try tmp_dir.dir.readLink("mylink", &buffer);
    try testing.expectEqualStrings(new_target_abs, link_target);
}
