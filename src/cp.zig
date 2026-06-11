//! Copy files and directories with POSIX-compatible behavior

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
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
        .directory => copyTree(allocator, io, stdout_writer, stderr_writer, source, final_dest_path, options),
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
        common.file_ops.copyFileWithAttributes(allocator, io, stderr_writer, "cp", source_path, dest_path, source_info) catch {
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

/// A (device, inode) pair identifying a filesystem object. Used for
/// ancestor-only cycle detection while following directory symlinks.
const NodeId = struct {
    dev: u64,
    inode: u64,
};

/// One unit of directory-tree work: copy the tree rooted at `source` into
/// `dest`. Generated for the command-line operand and for every directory
/// symlink the active symlink mode tells cp to follow. `ancestors` carries
/// the (dev, inode) chain that led here so a followed symlink resolving back
/// onto an ancestor is refused as a cycle (GNU semantics) rather than
/// re-walked. Paths and ancestors are arena-owned for the lifetime of the
/// enclosing copyTree call.
const TreeTask = struct {
    source: []const u8,
    dest: []const u8,
    ancestors: []const NodeId,
};

/// Hard upper bound on directory-symlink-follow tasks queued during one tree
/// copy. Ancestor-only cycle detection already terminates loops; this bound is
/// a Tiger Style backstop so a pathological tree cannot grow the queue without
/// limit.
const tree_task_max: usize = 1 << 20;

/// Copy a directory tree using the bounded common.walker.
///
/// Replaces the former self-recursive copyDirectory/copyDirectoryContents.
/// Each TreeTask drives one walk in order=.both over real directories with a
/// no_follow policy, so cp resolves symlinks itself per-entry (matching the
/// grep migration): a symlink-to-file is copied as a file under -L/-H, a
/// symlink-to-directory is enqueued as a new task. Directory mode and mtime are
/// preserved POST-order, after children are written, so writing a child cannot
/// re-bump the parent's mtime and a read-only (0o555) source dir does not block
/// its own population.
fn copyTree(
    allocator: Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    source_path: []const u8,
    dest_path: []const u8,
    options: RuntimeOptions,
) bool {
    assert(source_path.len > 0);
    assert(dest_path.len > 0);

    var tasks: std.ArrayList(TreeTask) = .empty;
    // Task 0 borrows the operand source/dest; follow-tasks (index > 0) own all
    // three fields. Every task's `ancestors` slice is owned here. Free them all
    // on exit so the per-tree allocations do not leak under a leak-checking
    // allocator (the CLI uses an arena, but the tests do not).
    defer {
        for (tasks.items, 0..) |task, i| {
            allocator.free(task.ancestors);
            if (i > 0) {
                allocator.free(task.source);
                allocator.free(task.dest);
            }
        }
        tasks.deinit(allocator);
    }

    const root_ancestors = allocator.alloc(NodeId, 0) catch {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "out of memory", .{});
        return false;
    };
    tasks.append(allocator, .{
        .source = source_path,
        .dest = dest_path,
        .ancestors = root_ancestors,
    }) catch {
        allocator.free(root_ancestors);
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "out of memory", .{});
        return false;
    };

    var success = true;
    var task_index: usize = 0;
    while (task_index < tasks.items.len) {
        assert(task_index < tree_task_max);
        const task = tasks.items[task_index];
        task_index += 1;
        if (!copyOneTree(allocator, io, stdout_writer, stderr_writer, task, options, &tasks)) {
            success = false;
        }
    }

    assert(task_index == tasks.items.len);
    return success;
}

/// State threaded through a single tree walk: parallel stacks of destination
/// paths and ancestor node IDs, keyed by walker depth.
const TreeWalk = struct {
    /// Destination path for the directory at each walker depth. dest_paths[0]
    /// is the task's dest root.
    dest_paths: std.ArrayList([]const u8),
    /// (dev, inode) of the directory at each walker depth, for ancestor-only
    /// cycle detection. Seeded with the task's inherited ancestors.
    ancestors: std.ArrayList(NodeId),
    /// Count of inherited ancestors (always kept at the front of `ancestors`).
    inherited_len: usize,
};

/// Walk one TreeTask's source tree and materialize it under the task's dest.
/// Returns true on full success, false if any entry failed.
fn copyOneTree(
    allocator: Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    task: TreeTask,
    options: RuntimeOptions,
    tasks: *std.ArrayList(TreeTask),
) bool {
    assert(task.source.len > 0);
    assert(task.dest.len > 0);

    var walker = common.walker.Walker.init(allocator, .{
        .order = .both,
        .symlinks = .no_follow,
        .stay_on_filesystem = options.one_file_system,
        .detect_cycles = false,
    }) catch {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "out of memory", .{});
        return false;
    };
    defer walker.deinit(io);
    walker.addRoot(task.source) catch {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "out of memory", .{});
        return false;
    };

    var state = TreeWalk{
        .dest_paths = .empty,
        .ancestors = .empty,
        .inherited_len = task.ancestors.len,
    };
    defer {
        for (state.dest_paths.items) |dp| allocator.free(dp);
        state.dest_paths.deinit(allocator);
        state.ancestors.deinit(allocator);
    }
    state.ancestors.appendSlice(allocator, task.ancestors) catch {};

    var success = true;
    while (true) {
        const maybe_entry = walker.next(io) catch |err| {
            reportTreeWalkError(allocator, io, stderr_writer, task.source, &state, err);
            success = false;
            continue;
        };
        const entry = maybe_entry orelse break;
        if (!handleTreeEntry(
            allocator,
            io,
            stdout_writer,
            stderr_writer,
            entry,
            task,
            options,
            &state,
            tasks,
        )) {
            success = false;
        }
    }
    return success;
}

/// Dispatch one walker entry to the correct copy action and maintain the
/// destination/ancestor stacks. Returns true on success.
fn handleTreeEntry(
    allocator: Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    entry: common.walker.Entry,
    task: TreeTask,
    options: RuntimeOptions,
    state: *TreeWalk,
    tasks: *std.ArrayList(TreeTask),
) bool {
    assert(entry.path.len > 0);
    assert(entry.basename.len > 0);
    switch (entry.kind) {
        .directory => return handleTreeDir(
            allocator,
            io,
            stdout_writer,
            stderr_writer,
            entry,
            task,
            options,
            state,
        ),
        .sym_link => return handleTreeSymlink(
            allocator,
            io,
            stdout_writer,
            stderr_writer,
            entry,
            options,
            state,
            tasks,
        ),
        else => {
            const dest = treeEntryDest(allocator, stderr_writer, entry, task, state) orelse
                return false;
            defer allocator.free(dest);
            var hint = true; // Suppress the interactive overwrite hint inside trees.
            return copySingleFile(
                allocator,
                io,
                stdout_writer,
                stderr_writer,
                entry.path,
                dest,
                options,
                &hint,
                false,
            ) catch false;
        },
    }
}

/// Handle a directory entry (pre-order creation, post-order preservation).
fn handleTreeDir(
    allocator: Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    entry: common.walker.Entry,
    task: TreeTask,
    options: RuntimeOptions,
    state: *TreeWalk,
) bool {
    assert(entry.kind == .directory);
    if (entry.visit == .pre) {
        const dest = treeEntryDest(allocator, stderr_writer, entry, task, state) orelse
            return false;
        // Ownership of `dest` transfers to the dest_paths stack on success.
        if (!createTreeDir(allocator, io, stdout_writer, stderr_writer, entry, dest, options)) {
            allocator.free(dest);
            return false;
        }
        state.dest_paths.append(allocator, dest) catch {
            allocator.free(dest);
            return false;
        };
        const node = nodeIdForPath(io, entry.path) orelse NodeId{ .dev = 0, .inode = 0 };
        state.ancestors.append(allocator, node) catch {};
        return true;
    }
    // Post-order: preserve mode and mtime AFTER children are written, then pop.
    assert(entry.visit == .post);
    assert(state.dest_paths.items.len > 0);
    const dest = state.dest_paths.items[state.dest_paths.items.len - 1];
    var success = true;
    if (options.preserve) {
        success = preserveTreeDir(allocator, io, stderr_writer, entry.path, dest);
    }
    allocator.free(state.dest_paths.pop().?);
    assert(state.ancestors.items.len > state.inherited_len);
    _ = state.ancestors.pop();
    return success;
}

/// Compute the destination path for an entry from its parent's dest path.
/// Caller owns the returned slice. Returns null only on allocation failure.
fn treeEntryDest(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    entry: common.walker.Entry,
    task: TreeTask,
    state: *const TreeWalk,
) ?[]u8 {
    assert(entry.basename.len > 0);
    if (entry.depth == 0) {
        return allocator.dupe(u8, task.dest) catch {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "out of memory", .{});
            return null;
        };
    }
    const parent_index = entry.depth - 1;
    assert(parent_index < state.dest_paths.items.len);
    const parent_dest = state.dest_paths.items[parent_index];
    return std.fs.path.join(allocator, &.{ parent_dest, entry.basename }) catch {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "out of memory", .{});
        return null;
    };
}

/// Create a destination directory for a pre-order directory entry. Prints the
/// verbose line if requested. Returns false on a hard error.
fn createTreeDir(
    allocator: Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    entry: common.walker.Entry,
    dest: []const u8,
    options: RuntimeOptions,
) bool {
    assert(entry.kind == .directory);
    assert(dest.len > 0);
    std.Io.Dir.cwd().createDir(io, dest, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot create directory '{s}': {s}", .{ dest, common.posixErrorString(err) });
            return false;
        },
    };
    if (options.verbose) {
        stdout_writer.print("'{s}' -> '{s}'\n", .{ entry.path, dest }) catch {};
    }
    return true;
}

/// Preserve a source directory's mode and mtime onto the destination directory.
/// Applied POST-order so writing children cannot re-bump the dest mtime and a
/// read-only source mode does not block populating the dest. Uses path-based
/// libc chmod (fchmod on a fresh dir handle returns EBADF). Returns true even
/// when preservation emits a warning, since the copy itself succeeded.
fn preserveTreeDir(
    allocator: Allocator,
    io: std.Io,
    stderr_writer: *std.Io.Writer,
    source_path: []const u8,
    dest_path: []const u8,
) bool {
    assert(source_path.len > 0);
    assert(dest_path.len > 0);
    const source_info = common.file.FileInfo.stat(io, source_path) catch |err| {
        common.printWarningWithProgram(allocator, stderr_writer, "cp", "cannot stat '{s}' for preservation: {s}", .{ source_path, common.posixErrorString(err) });
        return true;
    };
    // The post-order timing and path-based chmod rationale lives in the shared
    // leaf; cp owns only the source stat that feeds it.
    return common.file_ops.preserveDirAttributes(
        allocator,
        io,
        stderr_writer,
        "cp",
        dest_path,
        source_info.mode,
        source_info.atime,
        source_info.mtime,
    );
}

/// Resolve a symlink entry the no_follow walker left for cp. Under follow_none
/// (-P / default -R) the link is recreated verbatim. Under follow_all (-L) or
/// follow_cmdline at depth 0 (-H) the link is dereferenced: a file target is
/// copied as a regular file, a directory target is enqueued as a new task
/// unless it would close an ancestor cycle (refused with a "cyclic" diagnostic).
fn handleTreeSymlink(
    allocator: Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    entry: common.walker.Entry,
    options: RuntimeOptions,
    state: *TreeWalk,
    tasks: *std.ArrayList(TreeTask),
) bool {
    assert(entry.kind == .sym_link);
    const follow = switch (options.symlink_mode) {
        .follow_all => true,
        .follow_cmdline => entry.depth == 0,
        .follow_none => false,
    };
    const dest = treeEntryDestSymlink(allocator, stderr_writer, entry, state) orelse
        return false;
    defer allocator.free(dest);

    if (!follow) {
        return copySymlink(allocator, io, stderr_writer, entry.path, dest, options);
    }
    // Dereference the link to discover the real target kind.
    const target_info = common.file.FileInfo.stat(io, entry.path) catch |err| {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot stat '{s}': {s}", .{ entry.path, common.posixErrorString(err) });
        return false;
    };
    if (target_info.kind != .directory) {
        var hint = true;
        return copySingleFile(
            allocator,
            io,
            stdout_writer,
            stderr_writer,
            entry.path,
            dest,
            options,
            &hint,
            false,
        ) catch false;
    }
    return followTreeDirSymlink(
        allocator,
        io,
        stdout_writer,
        stderr_writer,
        entry,
        dest,
        target_info,
        options,
        state,
        tasks,
    );
}

/// Compute the destination path for a symlink entry. Symlinks are never the
/// walk root, so the parent dest is always on the stack.
fn treeEntryDestSymlink(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    entry: common.walker.Entry,
    state: *const TreeWalk,
) ?[]u8 {
    assert(entry.kind == .sym_link);
    assert(entry.depth >= 1);
    const parent_index = entry.depth - 1;
    assert(parent_index < state.dest_paths.items.len);
    const parent_dest = state.dest_paths.items[parent_index];
    return std.fs.path.join(allocator, &.{ parent_dest, entry.basename }) catch {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "out of memory", .{});
        return null;
    };
}

/// Enqueue a directory-symlink target as a new copy task, or refuse it when its
/// (dev, inode) is already an ancestor on the current descent path (GNU's
/// "cyclic symbolic link" case). The new task inherits the ancestor chain so
/// deeper cycles are caught too.
fn followTreeDirSymlink(
    allocator: Allocator,
    io: std.Io,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    entry: common.walker.Entry,
    dest: []const u8,
    target_info: common.file.FileInfo,
    options: RuntimeOptions,
    state: *TreeWalk,
    tasks: *std.ArrayList(TreeTask),
) bool {
    assert(entry.kind == .sym_link);
    assert(dest.len > 0);
    const target = NodeId{ .dev = target_info.dev, .inode = target_info.inode };
    for (state.ancestors.items) |ancestor| {
        if (ancestor.dev == target.dev and ancestor.inode == target.inode) {
            common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot copy cyclic symbolic link '{s}'", .{entry.path});
            return false;
        }
    }
    if (tasks.items.len >= tree_task_max) {
        common.printErrorWithProgram(allocator, stderr_writer, "cp", "too many symbolic links following '{s}'", .{entry.path});
        return false;
    }
    // The followed link becomes the dest directory's content root. Verbose line
    // mirrors the directory case so each copied path appears.
    if (options.verbose) {
        stdout_writer.print("'{s}' -> '{s}'\n", .{ entry.path, dest }) catch {};
    }
    _ = io;
    const source_copy = allocator.dupe(u8, entry.path) catch return false;
    const dest_copy = allocator.dupe(u8, dest) catch {
        allocator.free(source_copy);
        return false;
    };
    // Inherit the current ancestor chain plus this link's target so deeper
    // cycles through it are also refused.
    const inherited = allocator.alloc(NodeId, state.ancestors.items.len + 1) catch {
        allocator.free(source_copy);
        allocator.free(dest_copy);
        return false;
    };
    @memcpy(inherited[0..state.ancestors.items.len], state.ancestors.items);
    inherited[state.ancestors.items.len] = target;
    tasks.append(allocator, .{
        .source = source_copy,
        .dest = dest_copy,
        .ancestors = inherited,
    }) catch {
        allocator.free(source_copy);
        allocator.free(dest_copy);
        allocator.free(inherited);
        return false;
    };
    return true;
}

/// Look up a path's (dev, inode), following symlinks. Null on stat failure.
fn nodeIdForPath(io: std.Io, path: []const u8) ?NodeId {
    assert(path.len > 0);
    const info = common.file.FileInfo.stat(io, path) catch return null;
    return NodeId{ .dev = info.dev, .inode = info.inode };
}

/// Report a non-fatal per-entry walk error, naming the unreadable subdirectory.
/// The walker errors while opening a child directory and never emits its
/// pre-order entry, so we rescan the source root to name the precise failing
/// path, matching the grep migration's diagnostic. (cp's walks are shallow in
/// practice; a root rescan finds the unreadable child without per-frame source
/// tracking.)
fn reportTreeWalkError(
    allocator: Allocator,
    io: std.Io,
    stderr_writer: *std.Io.Writer,
    root_source: []const u8,
    state: *const TreeWalk,
    err: anyerror,
) void {
    assert(root_source.len > 0);
    _ = state;
    const failing = findUnreadableTreeChild(allocator, io, root_source);
    defer if (failing) |f| allocator.free(f);
    const name = failing orelse root_source;
    common.printErrorWithProgram(allocator, stderr_writer, "cp", "cannot access '{s}': {s}", .{ name, common.posixErrorString(err) });
}

/// Scan a source directory for the first subdirectory that cannot be opened,
/// returning its full path (caller-owned) or null if every subdirectory opens.
fn findUnreadableTreeChild(
    allocator: Allocator,
    io: std.Io,
    parent_path: []const u8,
) ?[]const u8 {
    assert(parent_path.len > 0);
    var parent_dir = std.Io.Dir.cwd().openDir(io, parent_path, .{ .iterate = true }) catch return null;
    defer parent_dir.close(io);
    var iterator = parent_dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        var child = parent_dir.openDir(io, entry.name, .{ .iterate = true }) catch {
            return std.fs.path.join(allocator, &.{ parent_path, entry.name }) catch null;
        };
        child.close(io);
    }
    return null;
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

// ===========================================================================
// Characterization tests for the walker migration (copyDirectory removal).
//
// These tests lock in the externally observable behavior the bounded-walker
// rewrite must preserve. They run against the current recursive code and must
// PASS today. A later step will sabotage the implementation to prove each test
// has teeth. Each assertion targets a value a wrong traversal would change
// (specific file content at depth, symlink target strings, mtime equality,
// nonzero exit on error) -- never a default falsy/zero value.
// ===========================================================================

test "cp -r replicates a multi-level tree with files at every depth and empty subdirs" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Build a three-level tree with a file at each depth and one empty leaf dir.
    // The walker must create every parent before any child it contains, and it
    // must copy content at depth 2 and reproduce the empty directory.
    try test_dir.createDir("src");
    try test_dir.createFile("src/top.txt", "depth0", null);
    try test_dir.createDir("src/mid");
    try test_dir.createFile("src/mid/middle.txt", "depth1", null);
    try test_dir.createDir("src/mid/deep");
    try test_dir.createFile("src/mid/deep/leaf.txt", "depth2", null);
    try test_dir.createDir("src/mid/empty");

    const source_path = try test_dir.getPath("src");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-r", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Files at every depth must arrive with exact content.
    try test_dir.expectFileContent("dst/top.txt", "depth0");
    try test_dir.expectFileContent("dst/mid/middle.txt", "depth1");
    try test_dir.expectFileContent("dst/mid/deep/leaf.txt", "depth2");

    // The empty subdirectory must be reproduced as a real directory.
    const empty_stat = try test_dir.getFileStat("dst/mid/empty");
    try testing.expectEqual(std.Io.File.Kind.directory, empty_stat.kind);
}

test "cp of a directory without -r fails naming the directory and nonzero exit" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createDir("a_directory");
    try test_dir.createFile("a_directory/inside.txt", "x", null);

    const source_path = try test_dir.getPath("a_directory");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/copy_target", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    // Nonzero exit and a diagnostic that names the directory operand.
    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.find(u8, stderr_aw.written(), "a_directory") != null);
    try testing.expect(std.mem.find(u8, stderr_aw.written(), "directory") != null);
    // The destination must not have been created.
    try testing.expect(!test_dir.fileExists("copy_target"));
}

test "cp -r default does not follow symlinks: file-link and dir-link recreated as symlinks" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // A directory containing a real file, a real subdir, a symlink to the file,
    // and a symlink to the subdir. The follow_none default must reproduce both
    // links as links, not materialize them.
    try test_dir.createDir("src");
    try test_dir.createFile("src/real.txt", "real file", null);
    try test_dir.createDir("src/realdir");
    try test_dir.createFile("src/realdir/nested.txt", "nested", null);
    try test_dir.createSymlink("real.txt", "src/file_link");
    try test_dir.createSymlink("realdir", "src/dir_link");

    const source_path = try test_dir.getPath("src");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-r", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Both symlinks must be preserved as symlinks pointing at the original targets.
    try testing.expect(try test_dir.isSymlink("dst/file_link"));
    const file_target = try test_dir.getSymlinkTarget("dst/file_link");
    defer testing.allocator.free(file_target);
    try testing.expectEqualStrings("real.txt", file_target);

    // isSymlink confirms the dest entry is itself a link (not a materialized
    // tree), and the target string proves it was reproduced verbatim rather
    // than followed.
    try testing.expect(try test_dir.isSymlink("dst/dir_link"));
    const dir_target = try test_dir.getSymlinkTarget("dst/dir_link");
    defer testing.allocator.free(dir_target);
    try testing.expectEqualStrings("realdir", dir_target);
}

test "cp -rL materializes file-link as a regular file and dir-link as a real directory" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createDir("src");
    try test_dir.createFile("src/real.txt", "materialize me", null);
    try test_dir.createDir("src/realdir");
    try test_dir.createFile("src/realdir/nested.txt", "through the link", null);
    try test_dir.createSymlink("real.txt", "src/file_link");
    try test_dir.createSymlink("realdir", "src/dir_link");

    const source_path = try test_dir.getPath("src");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-r", "-L", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // file_link becomes a regular file holding the target's content.
    try testing.expect(!(try test_dir.isSymlink("dst/file_link")));
    try test_dir.expectFileContent("dst/file_link", "materialize me");

    // dir_link becomes a real directory whose contents were copied through it.
    try testing.expect(!(try test_dir.isSymlink("dst/dir_link")));
    const dir_stat = try test_dir.getFileStat("dst/dir_link");
    try testing.expectEqual(std.Io.File.Kind.directory, dir_stat.kind);
    try test_dir.expectFileContent("dst/dir_link/nested.txt", "through the link");
}

test "cp -rL with two sibling links to the same dir copies its contents twice (no dedup)" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Two distinct symlinks both point at the same real directory. A legitimate
    // duplicate follow is NOT a cycle, so both must be materialized fully.
    try test_dir.createDir("src");
    try test_dir.createDir("src/shared");
    try test_dir.createFile("src/shared/payload.txt", "shared payload", null);
    try test_dir.createSymlink("shared", "src/link_a");
    try test_dir.createSymlink("shared", "src/link_b");

    const source_path = try test_dir.getPath("src");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-r", "-L", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Both follows must materialize the shared directory's content independently.
    try test_dir.expectFileContent("dst/link_a/payload.txt", "shared payload");
    try test_dir.expectFileContent("dst/link_b/payload.txt", "shared payload");
}

test "cp -rH follows the operand link but preserves inner links" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // A real directory with a file plus an inner symlink, reached via a
    // command-line symlink operand. -H follows only the operand.
    try test_dir.createFile("outside.txt", "outside target", null);
    try test_dir.createDir("real_dir");
    try test_dir.createFile("real_dir/data.txt", "inner data", null);
    try test_dir.createSymlink("../outside.txt", "real_dir/inner_link");
    try test_dir.createSymlink("real_dir", "operand_link");

    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/operand_link", .{base_path});
    defer testing.allocator.free(link_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-r", "-H", link_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Operand link was followed and MATERIALIZED: dst must be a real directory,
    // not a symlink recreating the operand. isSymlink does not dereference, so
    // this fails if -H regressed to follow_none and recreated dst as a link to
    // real_dir (in which case every dereferencing assertion below would still
    // pass through the link, hiding the regression).
    try testing.expect(!(try test_dir.isSymlink("dst")));
    const dst_stat = try test_dir.getFileStat("dst");
    try testing.expectEqual(std.Io.File.Kind.directory, dst_stat.kind);
    try test_dir.expectFileContent("dst/data.txt", "inner data");

    // The inner link must be preserved, not followed.
    try testing.expect(try test_dir.isSymlink("dst/inner_link"));
    const inner_target = try test_dir.getSymlinkTarget("dst/inner_link");
    defer testing.allocator.free(inner_target);
    try testing.expectEqualStrings("../outside.txt", inner_target);
}

test "cp -r reports an unreadable subdirectory, copies siblings, exits nonzero" {
    // Root bypasses read permissions, so the unreadable directory would be read
    // fine and the error path never triggers. Skip when effective uid is root.
    if (std.c.geteuid() == 0) return error.SkipZigTest;

    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createDir("src");
    try test_dir.createFile("src/readable.txt", "i am copyable", null);
    try test_dir.createDir("src/locked");
    try test_dir.createFile("src/locked/secret.txt", "unreachable", null);

    const source_path = try test_dir.getPath("src");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{base_path});
    defer testing.allocator.free(dest_path);

    // Remove all permissions on the locked subdir so opening it for iteration
    // fails. chmod by absolute path (via libc) reliably persists to the inode;
    // restore perms in defer so TmpDir cleanup can recurse into it. If the
    // platform refuses to make the directory unreadable (e.g. some CI sandboxes
    // ignore chmod), skip rather than assert a behavior we could not provoke.
    const locked_path_z = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/src/locked", .{base_path}, 0);
    defer testing.allocator.free(locked_path_z);
    if (std.c.chmod(locked_path_z, 0o000) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(locked_path_z, 0o755);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-r", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    // Overall exit code is nonzero because one subtree failed.
    try testing.expectEqual(@as(u8, 1), exit_code);
    // The sibling that was readable must still have been copied.
    try test_dir.expectFileContent("dst/readable.txt", "i am copyable");
    // The failure must be reported to stderr naming the locked directory.
    try testing.expect(std.mem.find(u8, stderr_aw.written(), "locked") != null);
}

test "cp -rv prints each copied path to stdout" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    try test_dir.createDir("src");
    try test_dir.createFile("src/alpha.txt", "a", null);
    try test_dir.createDir("src/sub");
    try test_dir.createFile("src/sub/beta.txt", "b", null);

    const source_path = try test_dir.getPath("src");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{base_path});
    defer testing.allocator.free(dest_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();

    const args = [_][]const u8{ "-r", "-v", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, &stdout_aw.writer, common.null_writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Verbose output must mention the specific files copied at each depth.
    const out = stdout_aw.written();
    const alpha_index = std.mem.find(u8, out, "alpha.txt");
    const beta_index = std.mem.find(u8, out, "beta.txt");
    try testing.expect(alpha_index != null);
    try testing.expect(beta_index != null);

    // Pre-order creation is externally observable only through the verbose
    // stream: a parent directory's line must precede its children's lines. The
    // nested subdirectory "sub" is the destination parent of "beta.txt", so its
    // dest line ('.../dst/sub') must appear before the line for beta.txt. We
    // anchor on the dest path "/sub'" (trailing quote excludes "/sub/beta...")
    // rather than the source, since the source basename "sub" also appears
    // inside the source side of the beta.txt line. This fails if the walker
    // emits a child before creating its parent (post-order or unordered).
    const sub_dir_index = std.mem.find(u8, out, "/sub'");
    try testing.expect(sub_dir_index != null);
    try testing.expect(sub_dir_index.? < beta_index.?);
}

test "cp -r refuses to copy a directory onto itself (same-file guard)" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // Lay out src/sub with a child so a completed copy would be observable.
    try test_dir.createDir("src");
    try test_dir.createDir("src/sub");
    try test_dir.createFile("src/sub/file.txt", "content", null);

    // Copy src/sub INTO its own parent src. resolveFinalDestination sees that
    // dest (src) exists as a directory and appends the source basename "sub",
    // so the resolved destination is src/sub -- the source itself. This is the
    // canonical "directory into itself" case the current code refuses cleanly
    // via the isSameFile guard (src/cp.zig:367), which the walker migration
    // keeps in the per-entry action path. We pin the exact diagnostic so the
    // test fails if the guard is dropped and the copy silently proceeds.
    //
    // NOTE FOR GREEN PHASE: the OTHER into-itself shape -- dest strictly inside
    // source, e.g. `cp -r src src/sub` -- does NOT hit isSameFile today; the
    // current code runs away creating src/sub/src/sub/... until a path-length
    // error. The migration must refuse that case cleanly via
    // walker.pruneCurrent() on a pre-order dir whose (dev,inode) matches the
    // destination. That clean refusal is NEW behavior, so its test belongs with
    // the migrated code, not here -- characterizing the current runaway would be
    // slow and brittle (depends on PATH_MAX).
    const source_path = try test_dir.getPath("src/sub");
    defer testing.allocator.free(source_path);
    const dest_path = try test_dir.getPath("src");
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-r", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    // Refused with a nonzero exit and the specific same-file diagnostic naming
    // the directory. Asserting the exact message (not just stderr.len > 0)
    // distinguishes a real same-file refusal from any unrelated failure mode.
    try testing.expectEqual(@as(u8, 1), exit_code);
    const err = stderr_aw.written();
    try testing.expect(std.mem.find(u8, err, "are the same file") != null);
    try testing.expect(std.mem.find(u8, err, "src/sub") != null);
}

test "cp -rp preserves regular file mode and mtime on copied files" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // The behavior under test is FILE attribute preservation, so the source is a
    // single regular file copied directly. Sourcing a directory here would route
    // through the directory-preserve path, which currently panics (fchmod EBADF on
    // a freshly-opened dir handle) and crashes the process before any assertion is
    // reached — making the test toothless. Directory-preserve is a SEPARATE broken
    // behavior fixed in the green phase; this test must isolate the working file
    // path so it can actually go red when file preservation regresses. The -r flag
    // is harmless for a single-file source and keeps the "cp -rp" scenario name.
    //
    // Mode 0o700 (not 0o600): a non-preserving copy produces a user triad of
    // 0o6xx (default_file 0o666 masked by umask), so 0o700 cannot be reproduced
    // by accident. This gives the mode-preservation assertion independent teeth.
    try test_dir.createFile("data.txt", "preserve me", 0o700);

    // Backdate the source file's mtime to a fixed point well in the past so a
    // non-preserving copy (which stamps "now") would visibly differ.
    const src_file_path = try test_dir.getPath("data.txt");
    defer testing.allocator.free(src_file_path);
    const past_ns: i128 = 1_000_000_000 * 1_000_000_000; // 2001-09-09T01:46:40Z.
    {
        const file = try std.Io.Dir.cwd().openFile(testing.io, src_file_path, .{ .mode = .read_write });
        defer file.close(testing.io);
        try file.setTimestamps(testing.io, .{
            .access_timestamp = .{ .new = .{ .nanoseconds = past_ns } },
            .modify_timestamp = .{ .new = .{ .nanoseconds = past_ns } },
        });
    }

    const source_path = src_file_path;
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dst.txt", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-r", "-p", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    const dst_file_path = dest_path;
    const source_info = try common.file.FileInfo.stat(testing.io, src_file_path);
    const dest_info = try common.file.FileInfo.stat(testing.io, dst_file_path);

    // User-mode bits must match (full bits need root; user bits suffice here).
    try testing.expectEqual(source_info.mode & 0o700, dest_info.mode & 0o700);
    // The mtime must be preserved: the destination must carry the SOURCE's mtime,
    // not the copy time. Comparing dest to the source's stat (rather than the
    // hardcoded past_ns) round-trips through the identical stat path, so the
    // assertion holds even on filesystems that truncate sub-second granularity.
    // The backdating above still gives the test teeth: a non-preserving copy
    // would stamp ~2026, far from the source's 2001 mtime.
    try testing.expectEqual(source_info.mtime, dest_info.mtime);
    // Sanity: the source really is backdated, so "preserved == now" cannot
    // sneak through. This keeps the teeth even if the FS coarsened past_ns.
    try testing.expect(source_info.mtime < past_ns + 1_000_000_000);
    try testing.expect(source_info.mtime > past_ns - 1_000_000_000);
}

// ===========================================================================
// Intended-RED behavior-fix tests for the walker migration.
//
// Unlike the characterization tests above, these pin GNU cp behavior the
// CURRENT recursive code gets WRONG. Each must FAIL today on its KEY assertion
// (not on a compile error or crash) and go GREEN after the bounded-walker
// rewrite. The bugs are verified against GNU cp and the built binary on Linux:
//   A. -rp on a read-only (0o555) source dir does not preserve the dir mode,
//      because preservation runs PRE-order via fchmod on a fresh dir handle
//      (EBADF, swallowed). The fix preserves POST-order, after children write.
//   B. -rp does not preserve directory mtimes (dest dirs get now-time); GNU
//      preserves them, applied post-order so writing children does not re-bump.
//   C. -rL on a symlink cycle runs away ~40 levels (kernel ELOOP) instead of
//      reporting "cyclic symbolic link", copying the rest, and stopping.
// ===========================================================================

test "walker-migration: -rp preserves directory mode post-order (read-only source dir)" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // A source directory holding one regular file. The directory itself is made
    // read-only (0o555) AFTER the file exists, so the file is still copyable;
    // only the final dest-dir mode is under test. chmod by absolute path via
    // libc reliably persists to the inode (mirrors the unreadable-subdir test).
    try test_dir.createDir("src");
    try test_dir.createFile("src/inside.txt", "read only dir content", null);

    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const src_path_z = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/src", .{base_path}, 0);
    defer testing.allocator.free(src_path_z);

    // Make the source dir read-only. Restore 0o755 in defer so TmpDir cleanup
    // can recurse in and delete it. If the platform refuses the chmod, skip.
    if (std.c.chmod(src_path_z, 0o555) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(src_path_z, 0o755);

    const source_path = try std.fmt.allocPrint(testing.allocator, "{s}/src", .{base_path});
    defer testing.allocator.free(source_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-r", "-p", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    // The copy succeeds and the child arrives: post-order preservation makes the
    // dest dir read-only only AFTER its children are written, so this holds even
    // once the mode is 0o555. (Under fakeroot/root 0o555 would not block writes
    // anyway, so this test never depends on EACCES.)
    try testing.expectEqual(@as(u8, 0), exit_code);
    try test_dir.expectFileContent("dst/inside.txt", "read only dir content");

    // KEY RED ASSERTION: the destination directory must carry the source's
    // 0o555 permission bits. Today preservation runs pre-order via fchmod on a
    // freshly-opened directory handle (EBADF, swallowed), so the dest dir keeps
    // the default mode (0o775/0o755) -- this assertion fails on that default.
    const dest_info = try common.file.FileInfo.stat(testing.io, dest_path);
    try testing.expectEqual(@as(std.posix.mode_t, 0o555), dest_info.mode & 0o777);

    // No diagnostic should reach the captured stderr on success. (The current
    // pre-order failure dumps an "unexpected errno: 9" trace to the process's
    // debug stderr, NOT this captured writer, so this passes today; the mode
    // assertion above is the RED one.)
    try testing.expectEqualStrings("", stderr_aw.written());
}

test "walker-migration: -rp preserves directory mtime" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // A nested source directory with a child file. The behavior under test is
    // DIRECTORY mtime preservation, so we backdate src/sub specifically.
    try test_dir.createDir("src");
    try test_dir.createDir("src/sub");
    try test_dir.createFile("src/sub/leaf.txt", "leaf", null);

    // Backdate src/sub's mtime to a fixed past instant. We set it on the
    // directory entry by path through the TmpDir handle so it persists to the
    // inode; a non-preserving copy would stamp the dest dir with "now".
    const past_ns: i128 = 1_000_000_000 * 1_000_000_000; // 2001-09-09T01:46:40Z.
    try test_dir.tmp_dir.dir.setTimestamps(testing.io, "src/sub", .{
        .access_timestamp = .{ .new = .{ .nanoseconds = past_ns } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = past_ns } },
    });

    const source_path = try test_dir.getPath("src");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-r", "-p", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // The source dir's recorded mtime, round-tripped through the same stat path,
    // is the spec value (handles filesystems that coarsen sub-second precision).
    const sub_src_path = try test_dir.getPath("src/sub");
    defer testing.allocator.free(sub_src_path);
    const source_info = try common.file.FileInfo.stat(testing.io, sub_src_path);
    const dest_sub_path = try std.fmt.allocPrint(testing.allocator, "{s}/sub", .{dest_path});
    defer testing.allocator.free(dest_sub_path);
    const dest_info = try common.file.FileInfo.stat(testing.io, dest_sub_path);

    // Sanity: the source dir really is backdated (well before ~2026), so a
    // "preserved == now" copy cannot sneak past the assertion below.
    try testing.expect(source_info.mtime < past_ns + 1_000_000_000);
    try testing.expect(source_info.mtime > past_ns - 1_000_000_000);

    // KEY RED ASSERTION: the dest dir must carry the SOURCE's mtime, compared at
    // seconds granularity (the API stores ns; whole-second equality survives FS
    // truncation). Today the dest dir is stamped at copy time (~2026), so it
    // differs from the source's 2001 mtime by ~25 years and this fails.
    const source_mtime_s = @divFloor(source_info.mtime, std.time.ns_per_s);
    const dest_mtime_s = @divFloor(dest_info.mtime, std.time.ns_per_s);
    try testing.expectEqual(source_mtime_s, dest_mtime_s);
}

test "walker-migration: -rL reports symlink cycle without materializing junk" {
    var test_dir = TestDir.init(testing.allocator);
    defer test_dir.deinit();

    // src/sub holds a real file plus a symlink that points back up at src,
    // forming a cycle when -L follows it: src/sub/loop -> ../../src re-enters
    // src, then src/sub, then loop again. GNU detects the cycle, reports it,
    // copies the rest, and does NOT materialize the loop. Current code follows
    // until the kernel's ~40-deep ELOOP limit, materializing junk nesting.
    try test_dir.createDir("src");
    try test_dir.createDir("src/sub");
    try test_dir.createFile("src/sub/f.txt", "sibling content", null);
    try test_dir.createSymlink("../../src", "src/sub/loop");

    const source_path = try test_dir.getPath("src");
    defer testing.allocator.free(source_path);
    const base_path = try test_dir.getBasePath();
    defer testing.allocator.free(base_path);
    const dest_path = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{base_path});
    defer testing.allocator.free(dest_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -rL terminates in finite time today via kernel ELOOP after ~40 levels, so
    // there is no hang risk; it WILL create junk nesting under dst on current
    // code (TmpDir cleanup removes it).
    const args = [_][]const u8{ "-r", "-L", source_path, dest_path };
    const exit_code = try run(testing.allocator, testing.io, &args, common.null_writer, &stderr_aw.writer);

    // Nonzero exit: passes today via ELOOP, so this is NOT the RED assertion.
    try testing.expect(exit_code != 0);

    // KEY RED ASSERTION 1: the diagnostic must name the cycle ("cyclic"). Today
    // the kernel error surfaces as "Too many levels of symbolic links", which
    // does not contain "cyclic", so this fails.
    const err = stderr_aw.written();
    try testing.expect(std.mem.find(u8, err, "cyclic") != null);

    // KEY RED ASSERTION 2: the loop must not be materialized. After detecting
    // the cycle, no nesting below dst/sub/loop should exist. Today ~40 levels
    // (dst/sub/loop/sub/loop/...) are created, so dst/sub/loop/sub exists and
    // this fails. Probing via FileInfo.lstat avoids following any link.
    const junk_path = try std.fmt.allocPrint(testing.allocator, "{s}/sub/loop/sub", .{dest_path});
    defer testing.allocator.free(junk_path);
    try testing.expectError(error.FileNotFound, common.file.FileInfo.lstat(junk_path));

    // KEY RED ASSERTION 3: the sibling file is still copied (GNU copies the rest
    // of the tree even after refusing the cyclic link). If current code aborts
    // before copying f.txt due to iteration order, the summary notes it rather
    // than weakening this assertion -- GNU semantics is the spec.
    try test_dir.expectFileContent("dst/sub/f.txt", "sibling content");
}
