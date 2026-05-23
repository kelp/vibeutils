//! Copy files and directories with POSIX-compatible behavior

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");

const Allocator = std.mem.Allocator;
const testing = std.testing;
const privilege_test = common.privilege_test;
const TestDir = common.test_dir.TestDir;

const COPY_BUFFER_SIZE = common.file_ops.COPY_BUFFER_SIZE;

/// Command-line configuration and runtime options for cp
const CpConfig = struct {
    // Command-line only options
    help: bool = false,
    version: bool = false,
    positionals: []const []const u8 = &.{},

    // Runtime operation options
    force: bool = false,
    interactive: bool = false,
    no_dereference: bool = false,
    preserve: bool = false,
    recursive: bool = false,
    R: bool = false,
    H: bool = false,
    L: bool = false,
    P: bool = false,
    archive: bool = false,
    no_clobber: bool = false,
    verbose: bool = false,

    // SHOULD flags
    backup: bool = false,
    clone: bool = false,
    hard_link: bool = false,
    N: bool = false,
    symbolic: bool = false,
    backup_suffix: ?[]const u8 = null,
    one_file_system: bool = false,
    X: bool = false,
    parents: bool = false,

    /// Extract runtime-only configuration
    pub fn runtime(self: CpConfig) RuntimeOptions {
        const is_archive = self.archive;
        const is_recursive = self.recursive or self.R or is_archive;
        const is_preserve = self.preserve or is_archive;

        // Resolve symlink mode from flags:
        // -L → follow_all, -H → follow_cmdline, -P or -d → follow_none
        // -a implies -P (follow_none)
        // -N suppresses BSD file flags with -p; does NOT affect symlink following
        // Default: follow_all without -R, follow_none with -R
        // Priority: -L > -H > -P/-d > default (resolveConflicts ensures last-wins)
        const symlink_mode: SymlinkMode = if (self.L)
            .follow_all
        else if (self.H)
            .follow_cmdline
        else if (self.P or self.no_dereference or is_archive)
            .follow_none
        else if (is_recursive)
            .follow_none
        else
            .follow_all;

        // Resolve backup suffix: -S value, or default "~"
        const suffix = self.backup_suffix orelse "~";

        return RuntimeOptions{
            .force = self.force,
            .interactive = self.interactive,
            .preserve = is_preserve,
            .recursive = is_recursive,
            .symlink_mode = symlink_mode,
            .no_clobber = self.no_clobber,
            .verbose = self.verbose,
            .hard_link = self.hard_link,
            .symbolic = self.symbolic,
            .one_file_system = self.one_file_system,
            .parents = self.parents,
            .backup = self.backup,
            .backup_suffix = suffix,
        };
    }

    pub const meta = .{
        .force = .{ .short = 'f', .desc = "Force overwrite without prompting" },
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .interactive = .{ .short = 'i', .desc = "Prompt before overwrite" },
        .no_dereference = .{ .short = 'd', .desc = "Never follow symbolic links in SOURCE" },
        .preserve = .{ .short = 'p', .desc = "Preserve mode, ownership, timestamps" },
        .recursive = .{ .short = 'r', .desc = "Copy directories recursively" },
        .R = .{ .short = 'R', .desc = "Copy directories recursively" },
        .H = .{ .short = 'H', .desc = "Follow symbolic links on the command line" },
        .L = .{ .short = 'L', .desc = "Follow all symbolic links" },
        .P = .{ .short = 'P', .desc = "Do not follow symbolic links" },
        .archive = .{ .short = 'a', .desc = "Archive mode (same as -RpP)" },
        .no_clobber = .{ .short = 'n', .desc = "Do not overwrite existing files" },
        .verbose = .{ .short = 'v', .desc = "Explain what is being done" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .backup = .{ .short = 'b', .desc = "Make backup of each existing destination file" },
        .clone = .{ .short = 'c', .desc = "Copy using clonefile (no-op)" },
        .hard_link = .{ .short = 'l', .desc = "Hard link files instead of copying" },
        .N = .{ .short = 'N', .desc = "Do not follow symbolic links in source" },
        .symbolic = .{ .short = 's', .desc = "Create symbolic links instead of copying" },
        .backup_suffix = .{ .short = 'S', .desc = "Override the backup suffix" },
        .one_file_system = .{ .short = 'x', .desc = "Stay on one file system" },
        .X = .{ .short = 'X', .desc = "Do not copy extended attributes (no-op)" },
    };
};

/// Runtime options for copy operations
const RuntimeOptions = struct {
    force: bool = false,
    interactive: bool = false,
    preserve: bool = false,
    recursive: bool = false,
    symlink_mode: SymlinkMode = .follow_all,
    no_clobber: bool = false,
    verbose: bool = false,
    hard_link: bool = false,
    symbolic: bool = false,
    one_file_system: bool = false,
    parents: bool = false,
    backup: bool = false,
    backup_suffix: []const u8 = "~",
};

/// File type enumeration for copy operations
const FileType = enum {
    directory,
    regular_file,
    special,
    symlink,
};

/// Symlink handling mode for copy operations
const SymlinkMode = enum {
    /// Follow all symbolic links (default without -R)
    follow_all,
    /// Follow only command-line symbolic links (with -H)
    follow_cmdline,
    /// Never follow symbolic links (with -P, default with -R)
    follow_none,
};

/// Main entry point for the cp command
pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, run);
}

/// Run cp with provided writers for output
fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) !u8 {
    const prog_name = "cp";

    // Pre-filter args: strip --backup[=TYPE] and --preserve[=ATTRS]
    // before argparse because they are bool fields that optionally
    // accept a =VALUE suffix. Argparse returns TooManyValues for
    // bool fields with =VALUE. resolveConflicts handles setting
    // these flags from the original unfiltered args.
    var filtered_args = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer filtered_args.deinit(allocator);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--backup") or std.mem.startsWith(u8, arg, "--backup=")) {
            continue;
        } else if (std.mem.eql(u8, arg, "--preserve") or std.mem.startsWith(u8, arg, "--preserve=")) {
            continue;
        }
        try filtered_args.append(allocator, arg);
    }

    var config = common.argparse.ArgParser.parseOrExit(CpConfig, allocator, filtered_args.items, prog_name, stderr_writer) catch return @intFromEnum(common.ExitCode.misuse);
    defer allocator.free(config.positionals);

    resolveConflicts(&config, args);

    if (config.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }
    if (config.version) {
        try stdout_writer.print("cp ({s}) {s}\n", .{ common.name, common.version });
        return @intFromEnum(common.ExitCode.success);
    }

    // Validate argument count
    if (config.positionals.len < 2) {
        if (config.positionals.len == 0) {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "missing file operand", .{});
            return @intFromEnum(common.ExitCode.misuse);
        } else {
            common.printErrorWithProgram(allocator, stderr_writer, prog_name, "missing destination file operand after '{s}'", .{config.positionals[0]});
            return @intFromEnum(common.ExitCode.misuse);
        }
    }

    // Execute copy operations
    var hinted_overwrite = false;
    const success = try executeCopyOperations(allocator, io, stdout_writer, stderr_writer, config.positionals, config.runtime(), &hinted_overwrite);

    return if (success) @intFromEnum(common.ExitCode.success) else @intFromEnum(common.ExitCode.general_error);
}

/// Resolve POSIX "last flag wins" for mutually exclusive options.
/// Scans raw args to determine which flag was specified last.
/// Also handles --backup[=TYPE] and --preserve[=ATTRS] flags.
fn resolveConflicts(config: *CpConfig, args: []const []const u8) void {
    for (args) |arg| {
        if (arg.len < 2 or arg[0] != '-') continue;
        if (arg[1] == '-') {
            // Long flags
            if (std.mem.eql(u8, arg, "--no-clobber")) {
                config.no_clobber = true;
                config.interactive = false;
            } else if (std.mem.eql(u8, arg, "--interactive")) {
                config.interactive = true;
                config.no_clobber = false;
            } else if (std.mem.eql(u8, arg, "--no-dereference")) {
                config.no_dereference = true;
                config.H = false;
                config.L = false;
            } else if (std.mem.eql(u8, arg, "--backup") or std.mem.startsWith(u8, arg, "--backup=")) {
                // --backup or --backup=TYPE: enable backup mode
                config.backup = true;
            } else if (std.mem.eql(u8, arg, "--preserve") or std.mem.startsWith(u8, arg, "--preserve=")) {
                // --preserve or --preserve=ATTRS: enable preserve mode
                config.preserve = true;
            }
            continue;
        }
        // Short flags — process each character in the cluster
        for (arg[1..]) |c| {
            switch (c) {
                'H' => {
                    config.H = true;
                    config.L = false;
                    config.P = false;
                    config.N = false;
                },
                'L' => {
                    config.L = true;
                    config.H = false;
                    config.P = false;
                    config.N = false;
                },
                'P' => {
                    config.P = true;
                    config.H = false;
                    config.L = false;
                },
                'N' => {
                    config.N = true;
                    config.H = false;
                    config.L = false;
                },
                'd' => {
                    config.no_dereference = true;
                    config.H = false;
                    config.L = false;
                },
                'n' => {
                    config.no_clobber = true;
                    config.interactive = false;
                },
                'i' => {
                    config.interactive = true;
                    config.no_clobber = false;
                },
                else => {},
            }
        }
    }
}

/// Execute all copy operations
fn executeCopyOperations(allocator: Allocator, io: std.Io, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer, args: []const []const u8, options: RuntimeOptions, hinted_overwrite: *bool) !bool {
    const dest = args[args.len - 1];

    // --parents requires destination to be a directory
    if (options.parents) {
        const dest_type = getFileTypeAtomic(io, dest, false) catch {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "target '{s}' is not a directory", .{dest});
            return false;
        };
        if (dest_type != .directory) {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "target '{s}' is not a directory", .{dest});
            return false;
        }
    }

    // If multiple sources, destination must be a directory
    if (args.len > 2) {
        const dest_type = getFileTypeAtomic(io, dest, false) catch {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "target '{s}' is not a directory", .{dest});
            return false;
        };

        if (dest_type != .directory) {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "target '{s}' is not a directory", .{dest});
            return false;
        }
    }

    var success = true;

    // Process each source
    for (args[0 .. args.len - 1]) |source| {
        if (options.parents) {
            // --parents: construct dest path preserving full source path
            const parents_dest = std.fs.path.join(allocator, &.{ dest, source }) catch |err| {
                common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot construct path: {s}", .{common.posixErrorString(err)});
                success = false;
                continue;
            };
            defer allocator.free(parents_dest);

            // Create intermediate directories
            if (std.fs.path.dirname(parents_dest)) |parent_dir| {
                std.Io.Dir.cwd().createDirPath(io, parent_dir) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => {
                        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot create directory '{s}': {s}", .{ parent_dir, common.posixErrorString(err) });
                        success = false;
                        continue;
                    },
                };
            }

            // Copy source directly to the constructed destination path
            const result = copySingleFile(allocator, io, stdout_writer, stderr_writer, source, parents_dest, options, hinted_overwrite, true) catch false;
            if (!result) success = false;
        } else {
            const result = copySingleFile(allocator, io, stdout_writer, stderr_writer, source, dest, options, hinted_overwrite, true) catch false;
            if (!result) success = false;
        }
    }

    return success;
}

/// Copy a single file or directory
fn copySingleFile(allocator: Allocator, io: std.Io, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer, source: []const u8, dest: []const u8, options: RuntimeOptions, hinted_overwrite: *bool, is_toplevel: bool) !bool {
    // Determine whether to follow symlinks based on mode and position
    const follow_symlinks = switch (options.symlink_mode) {
        .follow_all => true,
        .follow_cmdline => is_toplevel,
        .follow_none => false,
    };

    // Get source file type
    const source_type = getFileTypeAtomic(io, source, !follow_symlinks) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot stat '{s}': {s}", .{ source, common.posixErrorString(err) });
        return false;
    };

    // Resolve final destination path
    const final_dest_path = resolveFinalDestination(allocator, io, source, dest) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "error resolving destination: {s}", .{common.posixErrorString(err)});
        return false;
    };
    defer allocator.free(final_dest_path);

    // Check for same file
    if (common.file_ops.isSameFile(io, source, final_dest_path)) {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "'{s}' and '{s}' are the same file", .{ source, final_dest_path });
        return false;
    }

    // Check if destination exists
    const dest_exists = fileExists(io, final_dest_path);

    // Handle no-clobber mode: skip if destination exists
    if (options.no_clobber and dest_exists) {
        return true; // Not an error, just skip
    }

    // Validate operation
    if (source_type == .directory and !options.recursive) {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "'{s}' is a directory (use -r to copy recursively)", .{source});
        return false;
    }

    // Handle interactive mode
    if (options.interactive and dest_exists) {
        const should_proceed = if (builtin.is_test)
            false
        else
            common.prompt.promptYesNo(io, stderr_writer, "cp: overwrite '{s}'? ", .{final_dest_path}) catch false;
        if (!should_proceed) {
            return true; // User cancelled, not an error
        }
    }

    // Print one-time overwrite hint only in interactive terminals
    if (dest_exists and !options.interactive and !options.force and !hinted_overwrite.* and
        std.c.isatty(std.Io.File.stderr().handle) != 0)
    {
        common.printHintWithProgram(allocator, stderr_writer, "cp", "use -i for interactive prompts before overwriting", .{});
        hinted_overwrite.* = true;
    }

    // Create backup of destination if it exists and backup mode is enabled
    if (options.backup and dest_exists) {
        const backup_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ final_dest_path, options.backup_suffix }) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot create backup path: {s}", .{common.posixErrorString(err)});
            return false;
        };
        defer allocator.free(backup_path);

        std.Io.Dir.rename(
            std.Io.Dir.cwd(),
            final_dest_path,
            std.Io.Dir.cwd(),
            backup_path,
            io,
        ) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot create backup of '{s}': {s}", .{ final_dest_path, common.posixErrorString(err) });
            return false;
        };
    }

    // Print verbose message if requested
    if (options.verbose) {
        stdout_writer.print("'{s}' -> '{s}'\n", .{ source, final_dest_path }) catch {};
    }

    // For regular files, handle hard link and symbolic link modes
    if (source_type == .regular_file or (source_type == .symlink and follow_symlinks)) {
        if (options.hard_link) {
            return createHardLink(allocator, io, stderr_writer, source, final_dest_path, options);
        }
        if (options.symbolic) {
            return createSymbolicLink(allocator, io, stderr_writer, source, final_dest_path);
        }
    }

    // Execute the copy based on source type
    return switch (source_type) {
        .regular_file => copyRegularFile(allocator, io, stderr_writer, source, final_dest_path, options),
        .symlink => if (!follow_symlinks)
            copySymlink(allocator, io, stderr_writer, source, final_dest_path, options)
        else
            copyRegularFile(allocator, io, stderr_writer, source, final_dest_path, options),
        .directory => copyDirectory(allocator, io, stdout_writer, stderr_writer, source, final_dest_path, options, hinted_overwrite),
        .special => blk: {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "'{s}': unsupported file type", .{source});
            break :blk false;
        },
    };
}

/// Copy a regular file
fn copyRegularFile(allocator: Allocator, io: std.Io, stderr_writer: *std.Io.Writer, source_path: []const u8, dest_path: []const u8, options: RuntimeOptions) bool {
    // Get source file stats
    const source_info = common.file.FileInfo.stat(io, source_path) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot stat '{s}': {s}", .{ source_path, common.posixErrorString(err) });
        return false;
    };

    // Handle force overwrite if needed.
    // GNU spec: "if an existing destination file cannot be opened, remove it
    // and try again."  Only unlink when the file cannot be opened for writing;
    // this preserves hard links to writable destinations.
    var dest_unlinked = false;
    if (fileExists(io, dest_path) and options.force) {
        if (std.Io.Dir.cwd().openFile(io, dest_path, .{ .mode = .write_only })) |f| {
            // Destination is writable — no need to unlink
            f.close(io);
        } else |_| {
            // Cannot open for writing — unlink and retry
            handleForceOverwrite(io, dest_path) catch |e| {
                common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot remove '{s}': {s}", .{ dest_path, common.posixErrorString(e) });
                return false;
            };
            dest_unlinked = true;
        }
    }

    if (options.preserve) {
        copyFileWithAttributes(allocator, io, stderr_writer, source_path, dest_path, source_info) catch {
            return false;
        };
    } else if (!dest_unlinked and fileExists(io, dest_path)) {
        // Destination exists and was not unlinked: overwrite in place to
        // preserve the inode (and thus hard links).
        copyInPlace(allocator, io, stderr_writer, source_path, dest_path) catch {
            return false;
        };
    } else {
        // Simple copy: open source, create dest, copy contents
        const source_file = std.Io.Dir.cwd().openFile(io, source_path, .{}) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot open '{s}': {s}", .{ source_path, common.posixErrorString(err) });
            return false;
        };
        defer source_file.close(io);

        const dest_file = std.Io.Dir.cwd().createFile(io, dest_path, .{}) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot create '{s}': {s}", .{ dest_path, common.posixErrorString(err) });
            return false;
        };
        defer dest_file.close(io);

        common.file_ops.copyFileContents(io, source_file, dest_file) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot copy '{s}' to '{s}': {s}", .{ source_path, dest_path, common.posixErrorString(err) });
            return false;
        };
    }

    return true;
}

/// Copy file contents in place, preserving the destination inode.
/// Opens both files, truncates the destination, and copies data.
fn copyInPlace(allocator: Allocator, io: std.Io, stderr_writer: *std.Io.Writer, source_path: []const u8, dest_path: []const u8) !void {
    const source_file = std.Io.Dir.cwd().openFile(io, source_path, .{}) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot open '{s}': {s}", .{ source_path, common.posixErrorString(err) });
        return error.SourceNotReadable;
    };
    defer source_file.close(io);

    const dest_file = std.Io.Dir.cwd().openFile(io, dest_path, .{ .mode = .write_only }) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot open '{s}' for writing: {s}", .{ dest_path, common.posixErrorString(err) });
        return error.DestinationNotWritable;
    };
    defer dest_file.close(io);

    // Truncate to zero before writing new content
    dest_file.setLength(io, 0) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot truncate '{s}': {s}", .{ dest_path, common.posixErrorString(err) });
        return error.DestinationNotWritable;
    };

    common.file_ops.copyFileContents(io, source_file, dest_file) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "error copying '{s}' to '{s}': {s}", .{ source_path, dest_path, common.posixErrorString(err) });
        return error.SourceNotReadable;
    };
}

/// Copy a symbolic link
fn copySymlink(allocator: Allocator, io: std.Io, stderr_writer: *std.Io.Writer, source_path: []const u8, dest_path: []const u8, options: RuntimeOptions) bool {
    // Read the symlink target
    const target = getSymlinkTarget(allocator, io, source_path) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot read link '{s}': {s}", .{ source_path, common.posixErrorString(err) });
        return false;
    };
    defer allocator.free(target);

    // Handle force overwrite if needed
    if (fileExists(io, dest_path) and options.force) {
        handleForceOverwrite(io, dest_path) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot remove '{s}': {s}", .{ dest_path, common.posixErrorString(err) });
            return false;
        };
    }

    // Create the symlink
    std.Io.Dir.cwd().symLink(io, target, dest_path, .{}) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot create symlink '{s}': {s}", .{ dest_path, common.posixErrorString(err) });
        return false;
    };

    return true;
}

/// Create a hard link instead of copying
fn createHardLink(allocator: Allocator, io: std.Io, stderr_writer: *std.Io.Writer, source_path: []const u8, dest_path: []const u8, options: RuntimeOptions) bool {
    // Handle force overwrite if needed
    if (fileExists(io, dest_path) and options.force) {
        handleForceOverwrite(io, dest_path) catch {};
    }

    std.Io.Dir.hardLink(
        std.Io.Dir.cwd(),
        source_path,
        std.Io.Dir.cwd(),
        dest_path,
        io,
        .{},
    ) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot create hard link '{s}' to '{s}': {s}", .{ dest_path, source_path, common.posixErrorString(err) });
        return false;
    };
    return true;
}

/// Create a symbolic link instead of copying
fn createSymbolicLink(allocator: Allocator, io: std.Io, stderr_writer: *std.Io.Writer, source_path: []const u8, dest_path: []const u8) bool {
    std.Io.Dir.cwd().symLink(io, source_path, dest_path, .{}) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot create symbolic link '{s}' to '{s}': {s}", .{ dest_path, source_path, common.posixErrorString(err) });
        return false;
    };
    return true;
}

/// Copy a directory recursively
fn copyDirectory(allocator: Allocator, io: std.Io, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer, source_path: []const u8, dest_path: []const u8, options: RuntimeOptions, hinted_overwrite: *bool) bool {
    // Create destination directory
    std.Io.Dir.cwd().createDir(io, dest_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Directory already exists, continue
        },
        else => {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot create directory '{s}': {s}", .{ dest_path, common.posixErrorString(err) });
            return false;
        },
    };

    // Preserve directory permissions when preserve option is set
    if (options.preserve) {
        if (common.file.FileInfo.stat(io, source_path)) |source_info| {
            var dest_dir = std.Io.Dir.cwd().openDir(io, dest_path, .{}) catch |err| {
                common.printWarningWithProgram(allocator, stderr_writer, "cp", "cannot open '{s}' for permission preservation: {s}", .{ dest_path, common.posixErrorString(err) });
                return copyDirectoryContents(allocator, io, stdout_writer, stderr_writer, source_path, dest_path, options, hinted_overwrite, null);
            };
            defer dest_dir.close(io);
            _ = common.file_ops.setPermissions(allocator, dest_dir, source_info.mode, dest_path, "cp", stderr_writer) catch {};
        } else |err| {
            common.printWarningWithProgram(allocator, stderr_writer, "cp", "cannot stat '{s}' for permission preservation: {s}", .{ source_path, common.posixErrorString(err) });
        }
    }

    // Get source directory device ID for one-file-system mode
    const source_dev: ?u64 = if (options.one_file_system) blk: {
        const info = common.file.FileInfo.stat(io, source_path) catch break :blk null;
        break :blk info.dev;
    } else null;

    return copyDirectoryContents(allocator, io, stdout_writer, stderr_writer, source_path, dest_path, options, hinted_overwrite, source_dev);
}

/// Copy the contents of a directory recursively
fn copyDirectoryContents(allocator: Allocator, io: std.Io, stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer, source_path: []const u8, dest_path: []const u8, options: RuntimeOptions, hinted_overwrite: *bool, source_dev: ?u64) bool {
    // Open source directory for iteration
    var source_dir = std.Io.Dir.cwd().openDir(io, source_path, .{ .iterate = true }) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot open directory '{s}': {s}", .{ source_path, common.posixErrorString(err) });
        return false;
    };
    defer source_dir.close(io);

    var success = true;

    // Iterate through directory entries
    var iterator = source_dir.iterate();
    while (iterator.next(io) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "error reading directory '{s}': {s}", .{ source_path, common.posixErrorString(err) });
        return false;
    }) |entry| {
        // Skip . and .. entries
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
            continue;
        }

        // Construct full paths
        const source_child_path = std.fs.path.join(allocator, &.{ source_path, entry.name }) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot allocate memory for path: {s}", .{common.posixErrorString(err)});
            success = false;
            continue;
        };
        defer allocator.free(source_child_path);

        // Check one-file-system: skip entries on different devices
        if (source_dev) |dev| {
            const child_info = common.file.FileInfo.stat(io, source_child_path) catch null;
            if (child_info) |info| {
                if (info.dev != dev) {
                    continue; // Different filesystem, skip
                }
            }
        }

        const dest_child_path = std.fs.path.join(allocator, &.{ dest_path, entry.name }) catch |err| {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot allocate memory for path: {s}", .{common.posixErrorString(err)});
            success = false;
            continue;
        };
        defer allocator.free(dest_child_path);

        // Recursively copy child
        const result = copySingleFile(allocator, io, stdout_writer, stderr_writer, source_child_path, dest_child_path, options, hinted_overwrite, false) catch false;
        if (!result) success = false;
    }

    return success;
}

/// Copy file with preserved attributes
fn copyFileWithAttributes(allocator: Allocator, io: std.Io, stderr_writer: *std.Io.Writer, source_path: []const u8, dest_path: []const u8, source_info: common.file.FileInfo) !void {
    // Open source file
    const source_file = std.Io.Dir.cwd().openFile(io, source_path, .{}) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot open '{s}': {s}", .{ source_path, common.posixErrorString(err) });
        return error.SourceNotReadable;
    };
    defer source_file.close(io);

    // Create destination file with source mode
    const dest_file = std.Io.Dir.cwd().createFile(io, dest_path, .{
        .permissions = std.Io.File.Permissions.fromMode(source_info.mode),
    }) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot create '{s}': {s}", .{ dest_path, common.posixErrorString(err) });
        return error.DestinationNotWritable;
    };
    defer dest_file.close(io);

    // Copy file contents
    common.file_ops.copyFileContents(io, source_file, dest_file) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "error copying '{s}' to '{s}': {s}", .{ source_path, dest_path, common.posixErrorString(err) });
        return error.SourceNotReadable;
    };

    // Preserve timestamps
    dest_file.setTimestamps(io, .{
        .access_timestamp = .{ .new = .{ .nanoseconds = @intCast(source_info.atime) } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(source_info.mtime) } },
    }) catch |err| {
        common.printWarningWithProgram(allocator, stderr_writer, "cp", "cannot preserve timestamps for '{s}': {s}", .{ dest_path, common.posixErrorString(err) });
    };

    // Preserve ownership (uid/gid) — GNU cp -p is --preserve=mode,ownership,timestamps.
    // Silently ignore EPERM (non-root cannot chown to other users).
    const fchown_result = std.c.fchown(dest_file.handle, source_info.uid, source_info.gid);
    if (fchown_result != 0) {
        const errno = std.c._errno().*;
        switch (errno) {
            @intFromEnum(std.c.E.PERM) => {}, // Non-root; silently ignore
            else => {
                common.printWarningWithProgram(allocator, stderr_writer, "cp", "cannot preserve ownership for '{s}'", .{dest_path});
            },
        }
    }
}

/// Get file type atomically to avoid race conditions
fn getFileTypeAtomic(io: std.Io, path: []const u8, no_dereference: bool) !FileType {
    if (no_dereference) {
        // Check for symlinks first using lstat
        const info = common.file.FileInfo.lstat(path) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return err,
        };
        return switch (info.kind) {
            .sym_link => .symlink,
            .directory => .directory,
            .file => .regular_file,
            else => .special,
        };
    }

    // Get file stats to determine type (follows symlinks)
    const info = common.file.FileInfo.stat(io, path) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };

    return switch (info.kind) {
        .directory => .directory,
        .file => .regular_file,
        else => .special,
    };
}

/// Resolve the final destination path for a copy operation
fn resolveFinalDestination(allocator: Allocator, io: std.Io, source: []const u8, dest: []const u8) ![]u8 {
    // Check if destination exists and is a directory
    const dest_info = common.file.FileInfo.stat(io, dest) catch |err| switch (err) {
        error.FileNotFound => {
            // Destination doesn't exist, use as-is
            return try allocator.dupe(u8, dest);
        },
        else => return err,
    };

    if (dest_info.kind == .directory) {
        // Destination is a directory, append source basename
        const source_basename = std.fs.path.basename(source);
        return try std.fs.path.join(allocator, &[_][]const u8{ dest, source_basename });
    } else {
        // Destination is a file, use as-is
        return try allocator.dupe(u8, dest);
    }
}

/// Check if a file exists at the given path
fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Get the target of a symbolic link
fn getSymlinkTarget(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().readLink(io, path, &target_buf);
    return try allocator.dupe(u8, target_buf[0..len]);
}

/// Handle force removal of destination file
fn handleForceOverwrite(io: std.Io, dest_path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, dest_path) catch |err| switch (err) {
        error.FileNotFound => {}, // Already doesn't exist
        error.IsDir => return err, // Can't remove directory with deleteFile
        else => return err,
    };
}

/// Print help message for cp
fn printHelp(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    try common.help.printColorized(allocator, writer,
        \\Usage: cp [OPTION]... SOURCE DEST
        \\   or: cp [OPTION]... SOURCE... DIRECTORY
        \\Copy SOURCE to DEST, or multiple SOURCE(s) to DIRECTORY.
        \\
        \\  -a, --archive            same as -RpP
        \\  -b                       make backup of each existing destination file
        \\  -c                       copy using clonefile (no-op)
        \\  -d, --no-dereference     never follow symbolic links in SOURCE
        \\  -f, --force              force overwrite without prompting
        \\  -h, --help               display this help and exit
        \\  -H                       follow symlinks on the command line
        \\  -i, --interactive        prompt before overwrite
        \\  -l, --hard-link          hard link files instead of copying
        \\  -L                       follow all symbolic links
        \\  -n, --no-clobber         do not overwrite existing files
        \\  -N                       do not follow symbolic links in source
        \\  -p, --preserve           preserve mode, ownership, timestamps
        \\  -P                       do not follow symbolic links
        \\  -r, -R, --recursive      copy directories recursively
        \\  -s, --symbolic           create symbolic links instead of copying
        \\  -S, --backup-suffix      override the backup suffix
        \\  -v, --verbose            explain what is being done
        \\  -V, --version            output version information and exit
        \\  -x, --one-file-system    stay on one file system
        \\  -X                       do not copy extended attributes (no-op)
        \\      --backup[=TYPE]      like -b but accepts a backup type
        \\      --parents            use full source path under directory
        \\      --preserve[=ATTR]    preserve specified attributes
        \\
        \\Examples:
        \\  cp foo.txt bar.txt    Copy foo.txt to bar.txt
        \\  cp -R dir1 dir2       Copy dir1 and its contents to dir2
        \\  cp -a dir1 dir2       Archive copy (preserve all attributes)
        \\  cp file1 file2 dir/   Copy multiple files into dir/
        \\  cp -l file1 file2     Hard link file2 to file1
        \\  cp -b file1 file2     Copy with backup of file2 as file2~
        \\
    );
}

// Tests

test "cp: single file copy" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("source.txt", "Hello, World!", null);

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dest.txt", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try test_dir.expectFileContent("dest.txt", "Hello, World!");
}

test "cp: copy to existing directory" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("source.txt", "Test content", null);
    try test_dir.createDir("dest_dir");

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_dir_path = try test_dir.getPath("dest_dir");
    defer testing.allocator.free(dest_dir_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ source_path, dest_dir_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try test_dir.expectFileContent("dest_dir/source.txt", "Test content");
}

test "cp: error on directory without recursive flag" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createDir("source_dir");

    const source_path = try test_dir.getPath("source_dir");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dest_dir", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), exit_code);
}

test "cp: recursive directory copy" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create source directory structure
    try test_dir.createDir("source_dir");
    try test_dir.createDir("source_dir/subdir");
    try test_dir.createFile("source_dir/file1.txt", "File 1 content", null);
    try test_dir.createFile("source_dir/subdir/file2.txt", "File 2 content", null);

    const source_path = try test_dir.getPath("source_dir");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dest_dir", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-r", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try test_dir.expectFileContent("dest_dir/file1.txt", "File 1 content");
    try test_dir.expectFileContent("dest_dir/subdir/file2.txt", "File 2 content");
}

test "cp: preserve attributes" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("source.txt", "Test content", 0o644);

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dest.txt", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-p", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const source_stat = try test_dir.getFileStat("source.txt");
    const dest_stat = try test_dir.getFileStat("dest.txt");

    // Check user permissions (works without privileges)
    const source_user_perms = source_stat.permissions.toMode() & 0o700;
    const dest_user_perms = dest_stat.permissions.toMode() & 0o700;
    try testing.expectEqual(source_user_perms, dest_user_perms);
}

test "cp: symbolic link handling - follow by default" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("original.txt", "Original content", null);
    try test_dir.createSymlink("original.txt", "link.txt");

    // Use getBasePath + fmt instead of getPath to avoid resolving the symlink
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/link.txt", .{base_path});
    defer testing.allocator.free(link_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/copied.txt", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ link_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try test_dir.expectFileContent("copied.txt", "Original content");
    try testing.expect(!(try test_dir.isSymlink("copied.txt")));
}

test "cp: symbolic link handling - no dereference (-d)" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("original.txt", "Original content", null);
    try test_dir.createSymlink("original.txt", "link.txt");

    // Use getBasePath + fmt instead of getPath to avoid resolving the symlink
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/link.txt", .{base_path});
    defer testing.allocator.free(link_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/copied_link.txt", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-d", link_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(try test_dir.isSymlink("copied_link.txt"));
    const target = try test_dir.getSymlinkTarget("copied_link.txt");
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("original.txt", target);
}

test "cp: multiple sources to directory" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("file1.txt", "Content 1", null);
    try test_dir.createFile("file2.txt", "Content 2", null);
    try test_dir.createDir("dest_dir");

    const file1_path = try test_dir.getPath("file1.txt");
    defer testing.allocator.free(file1_path);
    const file2_path = try test_dir.getPath("file2.txt");
    defer testing.allocator.free(file2_path);
    const dest_dir_path = try test_dir.getPath("dest_dir");
    defer testing.allocator.free(dest_dir_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ file1_path, file2_path, dest_dir_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try test_dir.expectFileContent("dest_dir/file1.txt", "Content 1");
    try test_dir.expectFileContent("dest_dir/file2.txt", "Content 2");
}

test "cp: large file copy" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create a file larger than the copy buffer
    const large_size = COPY_BUFFER_SIZE + 1024;
    const content = try testing.allocator.alloc(u8, large_size);
    defer testing.allocator.free(content);

    // Fill with predictable pattern
    for (content, 0..) |*byte, i| {
        byte.* = @as(u8, @intCast(i % 256));
    }

    try test_dir.createFile("large_source.bin", content, null);

    const source_path = try test_dir.getPath("large_source.bin");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/large_dest.bin", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Verify the copied file has identical content
    const copied_content = try test_dir.readFileAlloc("large_dest.bin");
    defer testing.allocator.free(copied_content);

    try testing.expectEqual(large_size, copied_content.len);
    try testing.expectEqualSlices(u8, content, copied_content);
}

test "privileged: permission preservation with mode bits" {
    var arena = privilege_test.TestArena.init();
    defer arena.deinit();
    const allocator = arena.allocator();

    try privilege_test.requiresPrivilege(testing.io);

    var test_dir = TestDir.init(allocator);
    defer test_dir.deinit();

    // Create source file with specific permissions
    try test_dir.createFile("source.txt", "Test content", 0o755);

    const source_path = try test_dir.getPath("source.txt");
    defer allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(allocator, "{s}/dest.txt", .{base_path});
    defer allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-p", source_path, dest_path };
    const exit_code = try run(allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const source_stat = try test_dir.getFileStat("source.txt");
    const dest_stat = try test_dir.getFileStat("dest.txt");

    // With privilege, full mode bits should be preserved
    try testing.expectEqual(source_stat.permissions.toMode() & 0o777, dest_stat.permissions.toMode() & 0o777);
}

test "cp: same file detection across devices via hardlink" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("original.txt", "test content", null);

    const original_path = try test_dir.getPath("original.txt");
    defer testing.allocator.free(original_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const hardlink_path = try std.fmt.allocPrint(testing.allocator, "{s}/hardlink.txt", .{base_path});
    defer testing.allocator.free(hardlink_path);

    // Create hardlink (same inode+device)
    std.Io.Dir.hardLink(
        std.Io.Dir.cwd(),
        original_path,
        std.Io.Dir.cwd(),
        hardlink_path,
        testing.io,
        .{},
    ) catch {
        return error.SkipZigTest;
    };

    // Hardlinks share inode+device, so isSameFile must return true
    try testing.expect(common.file_ops.isSameFile(testing.io, original_path, hardlink_path));

    // Different files must return false
    try test_dir.createFile("different.txt", "other content", null);
    const different_path = try test_dir.getPath("different.txt");
    defer testing.allocator.free(different_path);
    try testing.expect(!common.file_ops.isSameFile(testing.io, original_path, different_path));

    // Nonexistent file must return false (not crash)
    const nonexistent_path = try std.fmt.allocPrint(testing.allocator, "{s}/nonexistent.txt", .{base_path});
    defer testing.allocator.free(nonexistent_path);
    try testing.expect(!common.file_ops.isSameFile(testing.io, original_path, nonexistent_path));

    // cp should refuse to copy same file (via hardlink) to itself
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ original_path, hardlink_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.find(u8, stderr_aw.written(), "same file") != null);
}

test "cp: overwrite hint suppressed when stderr is not a TTY" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("source.txt", "new content", null);
    try test_dir.createFile("dest.txt", "old content", null);

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath("dest.txt");
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Hint is only printed when stderr is a TTY; in tests it is not
    try testing.expect(std.mem.find(u8, stderr_aw.written(), "hint:") == null);
}

test "cp: overwrite hint NOT printed with -i flag" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("source.txt", "new content", null);
    try test_dir.createFile("dest.txt", "old content", null);

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath("dest.txt");
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-i", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stderr_aw.written(), "hint:") == null);
}

test "cp: overwrite hint NOT printed with -f flag" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("source.txt", "new content", null);
    try test_dir.createFile("dest.txt", "old content", null);

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath("dest.txt");
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-f", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stderr_aw.written(), "hint:") == null);
}

test "cp: overwrite hint suppressed for non-TTY with multiple files" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("src1.txt", "content 1", null);
    try test_dir.createFile("src2.txt", "content 2", null);
    try test_dir.createDir("dest_dir");
    try test_dir.createFile("dest_dir/src1.txt", "old 1", null);
    try test_dir.createFile("dest_dir/src2.txt", "old 2", null);

    const src1_path = try test_dir.getPath("src1.txt");
    defer testing.allocator.free(src1_path);
    const src2_path = try test_dir.getPath("src2.txt");
    defer testing.allocator.free(src2_path);
    const dest_dir_path = try test_dir.getPath("dest_dir");
    defer testing.allocator.free(dest_dir_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ src1_path, src2_path, dest_dir_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Hint is suppressed when stderr is not a TTY
    try testing.expect(std.mem.find(u8, stderr_aw.written(), "hint:") == null);
}

test "cp: no hint when destination does not exist" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("source.txt", "content", null);

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/new_dest.txt", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, stderr_aw.written(), "hint:") == null);
}

test "cp: -R flag triggers recursive copy" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createDir("source_dir");
    try test_dir.createFile("source_dir/file1.txt", "content", null);

    const source_path = try test_dir.getPath("source_dir");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dest_dir", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-R", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try test_dir.expectFileContent("dest_dir/file1.txt", "content");
}

test "cp: default symlink mode without -R is follow_all" {
    const args = [_][]const u8{ "/tmp/src", "/tmp/dst" };
    const config = try common.argparse.ArgParser.parse(CpConfig, testing.allocator, &args);
    defer testing.allocator.free(config.positionals);

    const rt = config.runtime();
    try testing.expectEqual(SymlinkMode.follow_all, rt.symlink_mode);
}

test "cp: default symlink mode with -R is follow_none" {
    const args = [_][]const u8{ "-R", "/tmp/src", "/tmp/dst" };
    const config = try common.argparse.ArgParser.parse(CpConfig, testing.allocator, &args);
    defer testing.allocator.free(config.positionals);

    const rt = config.runtime();
    try testing.expectEqual(SymlinkMode.follow_none, rt.symlink_mode);
}

test "cp: -P flag sets symlink mode to follow_none" {
    const args = [_][]const u8{ "-P", "/tmp/src", "/tmp/dst" };
    const config = try common.argparse.ArgParser.parse(CpConfig, testing.allocator, &args);
    defer testing.allocator.free(config.positionals);

    const rt = config.runtime();
    try testing.expectEqual(SymlinkMode.follow_none, rt.symlink_mode);
}

test "cp: -L flag sets symlink mode to follow_all" {
    const args = [_][]const u8{ "-R", "-L", "/tmp/src", "/tmp/dst" };
    const config = try common.argparse.ArgParser.parse(CpConfig, testing.allocator, &args);
    defer testing.allocator.free(config.positionals);

    const rt = config.runtime();
    try testing.expectEqual(SymlinkMode.follow_all, rt.symlink_mode);
}

test "cp: -H flag sets symlink mode to follow_cmdline" {
    const args = [_][]const u8{ "-R", "-H", "/tmp/src", "/tmp/dst" };
    const config = try common.argparse.ArgParser.parse(CpConfig, testing.allocator, &args);
    defer testing.allocator.free(config.positionals);

    const rt = config.runtime();
    try testing.expectEqual(SymlinkMode.follow_cmdline, rt.symlink_mode);
}

test "cp: -R -P preserves symlinks in directory tree" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create source directory with a file and a symlink to that file
    try test_dir.createDir("src_dir");
    try test_dir.createFile("src_dir/file.txt", "hello", null);
    try test_dir.createSymlink("file.txt", "src_dir/link.txt");

    const source_path = try test_dir.getPath("src_dir");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dest_dir", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-R", "-P", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // With -P, symlinks must be preserved as symlinks
    try testing.expect(try test_dir.isSymlink("dest_dir/link.txt"));
    const target = try test_dir.getSymlinkTarget("dest_dir/link.txt");
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("file.txt", target);
}

test "cp: -R -L follows all symlinks and copies as regular files" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create source directory with a file and a symlink to that file
    try test_dir.createDir("src_dir");
    try test_dir.createFile("src_dir/file.txt", "hello from file", null);
    try test_dir.createSymlink("file.txt", "src_dir/link.txt");

    const source_path = try test_dir.getPath("src_dir");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dest_dir", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-R", "-L", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // With -L, symlinks must be followed: dest should be a regular file
    try testing.expect(!(try test_dir.isSymlink("dest_dir/link.txt")));
    try test_dir.expectFileContent("dest_dir/link.txt", "hello from file");
}

test "cp: -R -H follows command-line symlinks but preserves inner symlinks" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create a real directory with a file and an inner symlink
    try test_dir.createFile("target_file.txt", "target content", null);
    try test_dir.createDir("real_dir");
    try test_dir.createFile("real_dir/file.txt", "hello", null);
    try test_dir.createSymlink("../target_file.txt", "real_dir/inner_link.txt");

    // Create a top-level symlink pointing to the real directory
    try test_dir.createSymlink("real_dir", "dir_link");

    // Use getBasePath to construct the symlink path without resolution
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/dir_link", .{base_path});
    defer testing.allocator.free(link_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dest_dir", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -H: follow the command-line symlink (dir_link -> real_dir),
    // but preserve symlinks encountered during traversal
    const args = [_][]const u8{ "-R", "-H", link_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // The top-level symlink was followed, so dest_dir should have
    // the contents of real_dir
    try test_dir.expectFileContent("dest_dir/file.txt", "hello");

    // Inner symlinks must be preserved (not followed) with -H
    try testing.expect(try test_dir.isSymlink("dest_dir/inner_link.txt"));
    const inner_target = try test_dir.getSymlinkTarget("dest_dir/inner_link.txt");
    defer testing.allocator.free(inner_target);
    try testing.expectEqualStrings("../target_file.txt", inner_target);
}

test "cp: -R alone defaults to -P behavior (preserve symlinks)" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create source directory with a file and a symlink
    try test_dir.createDir("src_dir");
    try test_dir.createFile("src_dir/file.txt", "content", null);
    try test_dir.createSymlink("file.txt", "src_dir/link.txt");

    const source_path = try test_dir.getPath("src_dir");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dest_dir", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -R without -H/-L/-P should default to -P (preserve symlinks)
    const args = [_][]const u8{ "-R", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Symlink must be preserved since -R defaults to -P behavior
    try testing.expect(try test_dir.isSymlink("dest_dir/link.txt"));
    const target = try test_dir.getSymlinkTarget("dest_dir/link.txt");
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("file.txt", target);
}

test "cp: without -R, symlinks are always followed" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Create a file and a symlink to it
    try test_dir.createFile("file.txt", "original content", null);
    try test_dir.createSymlink("file.txt", "link.txt");

    // Use getBasePath to construct the symlink path without resolution
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/link.txt", .{base_path});
    defer testing.allocator.free(link_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dest.txt", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // No -R flag: symlinks should always be followed
    const args = [_][]const u8{ link_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Destination must be a regular file, not a symlink
    try testing.expect(!(try test_dir.isSymlink("dest.txt")));
    try test_dir.expectFileContent("dest.txt", "original content");
}

test "cp: -a flag enables recursive, preserve, and follow_none" {
    const args = [_][]const u8{ "-a", "/tmp/src", "/tmp/dst" };
    const config = try common.argparse.ArgParser.parse(CpConfig, testing.allocator, &args);
    defer testing.allocator.free(config.positionals);
    const rt = config.runtime();
    try testing.expect(rt.recursive);
    try testing.expect(rt.preserve);
    try testing.expectEqual(SymlinkMode.follow_none, rt.symlink_mode);
}

test "cp: -n flag skips existing files" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("source.txt", "new content", null);
    try test_dir.createFile("dest.txt", "old content", null);

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath("dest.txt");
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-n", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Original content should be unchanged
    try test_dir.expectFileContent("dest.txt", "old content");
}

test "cp: -n flag creates file when destination does not exist" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("source.txt", "content", null);

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/new_dest.txt", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-n", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try test_dir.expectFileContent("new_dest.txt", "content");
}

test "cp: -v flag prints verbose output to stdout" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("source.txt", "content", null);

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dest.txt", .{base_path});
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-v", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Should contain 'source' -> 'dest' pattern
    try testing.expect(std.mem.find(u8, stdout_aw.written(), "->") != null);
}

test "cp: -v flag with recursive prints each copied file to stdout" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createDir("src_dir");
    try test_dir.createFile("src_dir/file1.txt", "content1", null);
    try test_dir.createFile("src_dir/file2.txt", "content2", null);

    const source_path = try test_dir.getPath("src_dir");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dest_dir", .{base_path});
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-Rv", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // Should have multiple -> entries (one per file)
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.findPos(u8, stdout_aw.written(), pos, "->")) |idx| {
        count += 1;
        pos = idx + 2;
    }
    try testing.expect(count >= 2);
}

test "cp: -L -P last flag wins (POSIX)" {
    const args = [_][]const u8{ "-L", "-P", "/tmp/src", "/tmp/dst" };
    var config = try common.argparse.ArgParser.parse(CpConfig, testing.allocator, &args);
    defer testing.allocator.free(config.positionals);
    resolveConflicts(&config, &args);
    const rt = config.runtime();
    // -P came last, so follow_none
    try testing.expectEqual(SymlinkMode.follow_none, rt.symlink_mode);
}

test "cp: -P -L last flag wins (POSIX)" {
    const args = [_][]const u8{ "-P", "-L", "/tmp/src", "/tmp/dst" };
    var config = try common.argparse.ArgParser.parse(CpConfig, testing.allocator, &args);
    defer testing.allocator.free(config.positionals);
    resolveConflicts(&config, &args);
    const rt = config.runtime();
    // -L came last, so follow_all
    try testing.expectEqual(SymlinkMode.follow_all, rt.symlink_mode);
}

test "cp: -n -i last flag wins" {
    const args = [_][]const u8{ "-n", "-i", "/tmp/src", "/tmp/dst" };
    var config = try common.argparse.ArgParser.parse(CpConfig, testing.allocator, &args);
    defer testing.allocator.free(config.positionals);
    resolveConflicts(&config, &args);
    const rt = config.runtime();
    // -i came last, should override -n
    try testing.expect(rt.interactive);
    try testing.expect(!rt.no_clobber);
}

// Tests for SHOULD flags

test "cp: -b creates backup of existing destination" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("source.txt", "new content", null);
    try test_dir.createFile("dest.txt", "old content", null);

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath("dest.txt");
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-b", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    // New content in destination
    try test_dir.expectFileContent("dest.txt", "new content");
    // Backup file exists with old content
    try test_dir.expectFileContent("dest.txt~", "old content");
}

test "cp: -b does nothing when destination does not exist" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("source.txt", "content", null);

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/new_dest.txt", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-b", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try test_dir.expectFileContent("new_dest.txt", "content");
}

test "cp: -S changes backup suffix" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("source.txt", "new content", null);
    try test_dir.createFile("dest.txt", "old content", null);

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath("dest.txt");
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-b", "-S", ".bak", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try test_dir.expectFileContent("dest.txt", "new content");
    try test_dir.expectFileContent("dest.txt.bak", "old content");
}

test "cp: -c flag accepted silently (no-op)" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createFile("source.txt", "content", null);

    const source_path = try test_dir.getPath("source.txt");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dest.txt", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-c", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);
    try test_dir.expectFileContent("dest.txt", "content");
}
