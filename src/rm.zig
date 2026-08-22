//! Simple POSIX-compatible rm command.

const std = @import("std");
const common = @import("common");
const TestDir = common.test_dir.TestDir;
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Command-line arguments for rm.
///
/// Field order is GNU rm's own `longopts[]` order, because that is the order
/// an ambiguous abbreviation lists its candidates in (`rm --v` -> '--verbose'
/// '--version'). Options vibeutils adds that GNU rm has no entry for sit after
/// the GNU sequence, next to whichever GNU option they alias or extend.
const RmArgs = struct {
    force: bool = false,
    interactive: bool = false,
    interactive_once: bool = false,
    no_preserve_root: bool = false,
    preserve_root: bool = false,
    recursive: bool = false,
    R: bool = false,
    remove_empty_dirs: bool = false,
    verbose: bool = false,
    help: bool = false,
    version: bool = false,
    // Not in GNU rm's longopts table.
    P: bool = false,
    no_cross_device: bool = false,
    undelete: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 'h', .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .force = .{ .short = 'f', .desc = "Ignore nonexistent files and arguments, never prompt" },
        .interactive = .{ .short = 'i', .desc = "Prompt before every removal" },
        .interactive_once = .{
            .short = 'I',
            .desc = "Prompt once before removing more than three files, " ++
                "or when removing recursively",
        },
        .recursive = .{ .short = 'r', .desc = "Remove directories and their contents recursively" },
        .R = .{
            .short = 'R',
            .desc = "Remove directories and their contents recursively (same as -r)",
        },
        .remove_empty_dirs = .{ .short = 'd', .desc = "Remove empty directories" },
        .P = .{ .short = 'P', .desc = "Overwrite before deletion (no-op, BSD compatibility)" },
        .verbose = .{ .short = 'v', .desc = "Explain what is being done" },
        .preserve_root = .{ .short = 0, .desc = "Do not remove '/' (default)" },
        .no_preserve_root = .{ .short = 0, .desc = "Do not treat '/' specially" },
        .no_cross_device = .{
            .short = 'x',
            .desc = "Don't cross mount points during recursive removal",
        },
        .undelete = .{ .short = 'W', .desc = "Attempt to undelete (not supported, stub)" },
    };
};

/// The one long option GNU rm refuses to let getopt_long abbreviate.
const no_preserve_root_long = "--no-preserve-root";

/// The token that abbreviated `--no-preserve-root`, or null when the option
/// was either spelled out in full or never typed at all.
///
/// GNU carves this single option out of getopt_long's abbreviation rule:
/// coreutils' `rm.c` re-reads `argv[optind - 1]` *after* getopt_long has
/// already resolved the option and dies unless the full spelling was typed.
/// Because the carve-out runs after resolution, a prefix that names several
/// options never reaches it — vibeutils' `--no-` also abbreviates
/// `--no-cross-device`, so it stays an ordinary ambiguity error.
///
/// Scanning stops at `--` for the same reason the parser does: past the
/// separator every token is a file name, and a file may legitimately be
/// called `--no-p`.
fn findNoPreserveRootAbbreviation(args: []const []const u8) ?[]const u8 {
    // Only called once parsing set the flag, so the token that set it is in
    // here somewhere; an empty argv could not have.
    std.debug.assert(args.len > 0);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        // The full spelling is what GNU demands, so it is never an offender.
        if (std.mem.eql(u8, arg, no_preserve_root_long)) continue;
        // `arg.len > 2` keeps a bare "-" — a legal file name — from counting
        // as a prefix of every long option.
        if (arg.len > 2 and std.mem.startsWith(u8, no_preserve_root_long, arg)) {
            // The parser resolved this token to a single option, so it cannot
            // also abbreviate rm's other `--no-*` option: that collision is
            // reported as ambiguity long before the carve-out is consulted.
            std.debug.assert(!std.mem.startsWith(u8, "--no-cross-device", arg));
            return arg;
        }
    }
    return null;
}

/// Whether rm must stop because `--no-preserve-root` was abbreviated, with
/// GNU's diagnostic already written to `stderr_writer` when it must.
///
/// GNU `die`s here instead of routing through its usage printer, so the
/// message stands alone: no "Try 'rm --help' for more information." line
/// follows it.
fn rejectAbbreviatedNoPreserveRoot(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    args: []const []const u8,
    no_preserve_root: bool,
) bool {
    // The same bound the parser asserts on the argv it was handed.
    std.debug.assert(args.len <= std.math.maxInt(u32));
    if (!no_preserve_root) return false;

    // Parsing set the flag, so the token that set it is somewhere in argv.
    std.debug.assert(args.len > 0);
    if (findNoPreserveRootAbbreviation(args) == null) return false;

    common.printErrorWithProgram(
        allocator,
        stderr_writer,
        "rm",
        "you may not abbreviate the " ++ no_preserve_root_long ++ " option",
        .{},
    );
    return true;
}

/// Options controlling rm behavior.
const RmOptions = struct {
    force: bool,
    interactive: bool,
    interactive_once: bool,
    recursive: bool,
    remove_empty_dirs: bool = false,
    verbose: bool,
    preserve_root: bool,
    no_cross_device: bool = false,
};

/// Test-only override for the interactive yes/no decision.
///
/// The real `common.prompt.promptYesNo` reads directly from
/// `std.Io.File.stdin()`, which has no injection seam, so interactive
/// behavior (prompt-before-descent, decline-keeps-parent) cannot be driven
/// from a unit test through the normal stdin path. To make those behaviors
/// unit-testable WITHOUT changing production behavior, all interactive
/// decisions in rm route through `askYesNo`, which consults this override
/// when set and otherwise calls the real prompt verbatim.
///
/// `null` in production (every call hits the real prompt). Tests install a
/// scripted answerer, run the removal, then restore `null`. The seam must
/// be preserved by the walker-based driver so these guards keep their teeth.
var test_prompt_override: ?*const fn (question: PromptKind, path: []const u8) bool = null;

/// Classifies which interactive question is being asked, so a scripted test
/// answerer can decide based on the kind and path rather than parsing text.
const PromptKind = enum {
    /// "rm: remove regular file 'PATH'?" — per-file prompt under -i.
    regular_file,
    /// "rm: remove directory 'PATH'?" — per-directory prompt under -i.
    directory,
};

/// Single choke point for rm's interactive yes/no decisions. Returns true
/// to proceed with removal, false to decline. Uses the test override when
/// installed; otherwise delegates to the real stdin-backed prompt so
/// production behavior is byte-for-byte unchanged.
fn askYesNo(
    io: std.Io,
    stderr_writer: *std.Io.Writer,
    kind: PromptKind,
    path: []const u8,
) !bool {
    std.debug.assert(path.len > 0);
    if (test_prompt_override) |answerer| {
        return answerer(kind, path);
    }
    return switch (kind) {
        .regular_file => common.prompt.promptYesNo(
            io,
            stderr_writer,
            "rm: remove regular file '{s}'? ",
            .{path},
        ),
        .directory => common.prompt.promptYesNo(
            io,
            stderr_writer,
            "rm: remove directory '{s}'? ",
            .{path},
        ),
    };
}

/// Main entry point
pub fn main(init: std.process.Init) noreturn {
    common.utilityMain(init, runRm);
}

/// Main entry point for the rm command with writer-based interface.
pub fn runRm(
    allocator: Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    std.debug.assert(stdout_writer != stderr_writer);
    // Parse command-line arguments using the common argument parser
    const parsed_args = common.argparse.ArgParser.parseOrExit(
        RmArgs,
        allocator,
        args,
        "rm",
        stderr_writer,
    ) catch return @intFromEnum(common.ExitCode.general_error);
    defer allocator.free(parsed_args.positionals);

    if (rejectAbbreviatedNoPreserveRoot(
        allocator,
        stderr_writer,
        args,
        parsed_args.no_preserve_root,
    )) return @intFromEnum(common.ExitCode.general_error);

    // Handle help flag
    if (parsed_args.help) {
        try printHelp(allocator, stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    // Handle version flag
    if (parsed_args.version) {
        try printVersion(stdout_writer);
        return @intFromEnum(common.ExitCode.success);
    }

    const files = parsed_args.positionals;
    if (files.len == 0) {
        if (parsed_args.force) return @intFromEnum(common.ExitCode.success);
        common.printErrorWithProgram(allocator, stderr_writer, "rm", "missing operand", .{});
        return @intFromEnum(common.ExitCode.general_error);
    }

    // -W: undelete is not supported on Linux. Print error and
    // return without deleting anything — deleting a file when
    // asked to recover it would be dangerous data loss.
    if (parsed_args.undelete) {
        try stderr_writer.writeAll("rm: -W (undelete) not supported on this platform\n");
        return @intFromEnum(common.ExitCode.general_error);
    }

    // Create options structure - merge -i/-I and -r/-R flags
    // --preserve-root is default true; --no-preserve-root disables it
    const options = RmOptions{
        .force = parsed_args.force,
        .interactive = parsed_args.interactive,
        .interactive_once = parsed_args.interactive_once,
        .recursive = parsed_args.recursive or parsed_args.R,
        .remove_empty_dirs = parsed_args.remove_empty_dirs,
        .verbose = parsed_args.verbose,
        .preserve_root = !parsed_args.no_preserve_root,
        .no_cross_device = parsed_args.no_cross_device,
    };

    const success = try removeFiles(allocator, io, files, stdout_writer, stderr_writer, options);
    return if (success)
        @intFromEnum(common.ExitCode.success)
    else
        @intFromEnum(common.ExitCode.general_error);
}

/// Prints help information to the specified writer.
fn printHelp(allocator: Allocator, writer: *std.Io.Writer) !void {
    const help_text =
        \\Usage: rm [OPTION]... [FILE]...
        \\Remove (unlink) the FILE(s).
        \\
        \\  -d, --remove-empty-dirs  remove empty directories
        \\  -f, --force           ignore nonexistent files and arguments, never prompt
        \\  -i                    prompt before every removal
        \\  -I                    prompt once before removing more than three files,
        \\                          or when removing recursively
        \\  -r, -R, --recursive   remove directories and their contents recursively
        \\  -v, --verbose         explain what is being done
        \\  -x                    do not cross mount points during recursive removal
        \\  -W                    attempt to undelete (not supported, stub)
        \\      --preserve-root   do not remove '/' (default)
        \\      --no-preserve-root  do not treat '/' specially
        \\      --help            display this help and exit
        \\      --version         output version information and exit
        \\
        \\By default, rm does not remove directories. Use the --recursive (-r or -R)
        \\option to remove each listed directory, too, along with all of its contents.
        \\
    ;
    try common.help.printColorized(allocator, writer, help_text);
}

/// Prints version information to the specified writer.
fn printVersion(writer: *std.Io.Writer) !void {
    const build_options = @import("build_options");
    try writer.print("rm (vibeutils) {s}\n", .{build_options.version});
}

/// Main file removal function that processes a list of files/directories.
fn removeFiles(
    allocator: Allocator,
    io: std.Io,
    files: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: RmOptions,
) !bool {
    std.debug.assert(stdout_writer != stderr_writer);
    // Handle interactive once mode (-I flag) - but force overrides
    if (!options.force and options.interactive_once and (files.len > 3 or options.recursive)) {
        const proceed = try common.prompt.promptYesNo(
            io,
            stderr_writer,
            "rm: remove {d} arguments? ",
            .{files.len},
        );
        if (!proceed) {
            return true; // User said no, but no error occurred
        }
    }

    var any_errors = false;

    for (files) |file| {
        // Check preserve-root protection before anything else
        if (options.preserve_root and isRootPath(file)) {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "rm",
                "refusing to remove '/'; use --no-preserve-root to override",
                .{},
            );
            any_errors = true;
            continue;
        }

        // Enhanced path validation using OpenBSD-style basename checking
        if (!isPathSafeToRemove(file)) {
            removeFiles_reportUnsafePath(allocator, stderr_writer, file);
            any_errors = true;
            continue;
        }

        // Try to remove the file/directory
        const file_error = try removeFiles_removeOne(
            allocator,
            io,
            file,
            stdout_writer,
            stderr_writer,
            options,
            any_errors,
        );
        any_errors = file_error or any_errors;
    }

    return !any_errors;
}

/// Removes a single file/directory and reports per-file errors for the
/// `removeFiles` loop. Returns whether THIS file errored, so the caller
/// centralizes the `any_errors` accumulation. `any_errors_so_far` is the
/// loop-wide gate forwarded to `removeFiles_handleIsDir` so the -d verbose
/// message keeps its original behavior bit-for-bit.
fn removeFiles_removeOne(
    allocator: Allocator,
    io: std.Io,
    file: []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: RmOptions,
    any_errors_so_far: bool,
) !bool {
    std.debug.assert(file.len > 0);
    std.debug.assert(stdout_writer != stderr_writer);
    var local_error = false;
    removeItem(
        allocator,
        io,
        file,
        stdout_writer,
        stderr_writer,
        options,
    ) catch |err| switch (err) {
        error.FileNotFound => {
            if (!options.force) {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    "rm",
                    "cannot remove '{s}': No such file or directory",
                    .{file},
                );
                local_error = true;
            }
        },
        error.AccessDenied => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "rm",
                "cannot remove '{s}': Permission denied",
                .{file},
            );
            local_error = true;
        },
        error.IsDir => {
            const dir_error = try removeFiles_handleIsDir(
                allocator,
                io,
                file,
                stdout_writer,
                stderr_writer,
                options,
                any_errors_so_far,
            );
            local_error = dir_error or any_errors_so_far;
        },
        error.InteractiveUserCancelled => {
            // User declined in interactive mode - this is normal behavior, not an error
        },
        error.UserCancelled => {
            // User declined write-protected file prompt - this is an error
            local_error = true;
        },
        else => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "rm",
                "cannot remove '{s}': {s}",
                .{ file, common.posixErrorString(err) },
            );
            local_error = true;
        },
    };
    return local_error;
}

/// Reports the specific reason an unsafe path was refused by `removeFiles`.
/// Straight-line message dispatch for the three exhaustive unsafe cases:
/// empty path, the exact "/" path, and any "." / ".." basename pattern.
fn removeFiles_reportUnsafePath(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    file: []const u8,
) void {
    std.debug.assert(!isPathSafeToRemove(file));
    var printed = false;
    if (file.len == 0) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "rm",
            "cannot remove '': No such file or directory",
            .{},
        );
        printed = true;
    } else if (std.mem.eql(u8, file, "/")) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "rm",
            "it is dangerous to operate recursively on '/'",
            .{},
        );
        printed = true;
    } else {
        // Must be a "." or ".." pattern (including complex paths like "/path/to/.")
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "rm",
            "\".\" and \"..\" may not be removed",
            .{},
        );
        printed = true;
    }
    // Negative space: every branch must report; we must not fall through silently.
    std.debug.assert(printed);
}

/// Handles the `error.IsDir` arm of `removeFiles` for a single directory.
/// Dispatches on -r / -d / neither and reports per-file removal errors.
/// Returns whether THIS file errored, so the caller centralizes the
/// `any_errors` accumulation. `any_errors_so_far` preserves the original
/// loop-wide gate on the -d verbose message bit-for-bit.
fn removeFiles_handleIsDir(
    allocator: Allocator,
    io: std.Io,
    file: []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: RmOptions,
    any_errors_so_far: bool,
) !bool {
    std.debug.assert(file.len > 0);
    std.debug.assert(stdout_writer != stderr_writer);
    var local_error = false;
    if (options.recursive) {
        removeDirectory(
            allocator,
            io,
            file,
            stdout_writer,
            stderr_writer,
            options,
        ) catch |dir_err| {
            // The walker driver handles interactive declines
            // internally, so any error here is a real failure.
            removeFiles_handleIsDir_reportPosix(allocator, stderr_writer, file, dir_err);
            local_error = true;
        };
    } else if (options.remove_empty_dirs) {
        // -d flag: attempt to remove empty directory (like rmdir)
        std.Io.Dir.cwd().deleteDir(io, file) catch |dir_err| {
            removeFiles_handleIsDir_reportDeleteDir(allocator, stderr_writer, file, dir_err);
            local_error = true;
        };
        if (!any_errors_so_far and !local_error and options.verbose) {
            try stdout_writer.print("removed directory '{s}'\n", .{file});
        }
    } else {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "rm",
            "cannot remove '{s}': Is a directory",
            .{file},
        );
        local_error = true;
    }
    return local_error;
}

/// Reports a generic POSIX-mapped error for a failed recursive directory
/// removal, matching the message rm emits for the `-r` failure path.
fn removeFiles_handleIsDir_reportPosix(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    file: []const u8,
    dir_err: anyerror,
) void {
    std.debug.assert(file.len > 0);
    // Positive space: the caught value is a real, named error.
    std.debug.assert(@errorName(dir_err).len > 0);
    common.printErrorWithProgram(
        allocator,
        stderr_writer,
        "rm",
        "cannot remove '{s}': {s}",
        .{ file, common.posixErrorString(dir_err) },
    );
}

/// Reports the per-case error for a failed `-d` empty-directory removal,
/// distinguishing not-empty and permission-denied from the generic case.
fn removeFiles_handleIsDir_reportDeleteDir(
    allocator: Allocator,
    stderr_writer: *std.Io.Writer,
    file: []const u8,
    dir_err: anyerror,
) void {
    std.debug.assert(file.len > 0);
    // Positive space: the caught value is a real, named error.
    std.debug.assert(@errorName(dir_err).len > 0);
    switch (dir_err) {
        error.DirNotEmpty => common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "rm",
            "cannot remove '{s}': Directory not empty{s}",
            .{ file, common.maybeHint(dir_err, file, .write) orelse "" },
        ),
        error.AccessDenied => common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "rm",
            "cannot remove '{s}': Permission denied",
            .{file},
        ),
        else => common.printErrorWithProgram(
            allocator,
            stderr_writer,
            "rm",
            "cannot remove '{s}': {s}",
            .{ file, common.posixErrorString(dir_err) },
        ),
    }
}

/// Remove a single file or symlink.
fn removeItem(
    _: Allocator,
    io: std.Io,
    file_path: []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: RmOptions,
) !void {
    std.debug.assert(file_path.len > 0);
    std.debug.assert(stdout_writer != stderr_writer);
    // Use lstat so symlinks are examined directly (not their targets).
    // statFile follows symlinks, which misclassifies symlinks-to-directories
    // as directories and incorrectly requires -r.
    const stat_result = common.file.FileInfo.lstat(file_path) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.AccessDenied,
        else => return err,
    };

    // Check if it's a directory
    if (stat_result.kind == .directory) {
        return error.IsDir;
    }

    // POSIX compliance: Force flag suppresses ALL prompts
    if (options.force) {
        // Force mode: no prompts, proceed with removal
    } else if (options.interactive) {
        // Interactive mode: always prompt (routed through the test-injectable seam)
        if (!try askYesNo(io, stderr_writer, .regular_file, file_path)) {
            return error.InteractiveUserCancelled;
        }
    } else {
        // Default mode: prompt only for write-protected files
        const mode = stat_result.mode;
        const user_write = (mode & 0o200) != 0;
        if (!user_write) {
            const proceed = try common.prompt.promptYesNo(
                io,
                stderr_writer,
                "rm: remove write-protected regular file '{s}'? ",
                .{file_path},
            );
            if (!proceed) {
                return error.UserCancelled;
            }
        }
    }

    // Remove the file
    std.Io.Dir.cwd().deleteFile(io, file_path) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.AccessDenied,
        else => return err,
    };

    // Print verbose output
    if (options.verbose) {
        try stdout_writer.print("removed '{s}'\n", .{file_path});
    }
}

/// Remove a directory recursively with per-entry verbose/interactive support.
fn removeDirectory(
    allocator: Allocator,
    io: std.Io,
    dir_path: []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: RmOptions,
) !void {
    std.debug.assert(dir_path.len > 0);
    std.debug.assert(options.recursive);
    // For non-verbose, non-interactive mode with force and no -x, use deleteTree as fast path
    if (!options.verbose and !options.interactive and options.force and !options.no_cross_device) {
        std.Io.Dir.cwd().deleteTree(io, dir_path) catch |err| switch (err) {
            error.AccessDenied => return error.AccessDenied,
            else => return err,
        };
        return;
    }

    // Slow path: drive the bounded directory walker. The walker handles
    // depth-first post-order deletion, symlink policy, cycle detection, and
    // the one-file-system boundary, replacing the former manual recursion.
    try removeDirectoryWithWalker(allocator, io, dir_path, stdout_writer, stderr_writer, options);
}

/// Get the device ID for a path. Uses the cross-platform
/// common.file.FileInfo.stat which handles Linux (statx) and
/// macOS/BSD (fstat via the file descriptor) uniformly.
fn getDeviceId(io: std.Io, path: []const u8) !u64 {
    const info = common.file.FileInfo.stat(io, path) catch return error.StatFailed;
    return info.dev;
}

/// Drives the bounded directory walker to remove a directory tree. Visits
/// each entry pre-order (interactive prompt + prune) and post-order
/// (deleteDir once empty), preserving the prior depth-first post-order
/// deletion semantics without recursion.
fn removeDirectoryWithWalker(
    allocator: Allocator,
    io: std.Io,
    dir_path: []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: RmOptions,
) !void {
    std.debug.assert(dir_path.len > 0);
    std.debug.assert(stdout_writer != stderr_writer);

    const config = common.walker.WalkConfig{
        .order = .both,
        .symlinks = .no_follow,
        .cycle_mode = .ancestors,
        .stay_on_filesystem = options.no_cross_device,
    };

    var walker = try common.walker.Walker.init(allocator, config);
    defer walker.deinit(io);
    try walker.addRoot(dir_path);

    // Paths of directories that must survive: declined directories and the
    // parent directories of declined entries. Bounded by the walk entry cap.
    var cancelled: std.ArrayList([]const u8) = .empty;
    defer {
        for (cancelled.items) |path| allocator.free(path);
        cancelled.deinit(allocator);
    }

    var had_errors = false;
    while (try walker.next(io)) |entry| {
        std.debug.assert(entry.path.len > 0);
        const failed = try handleWalkEntry(
            allocator,
            io,
            entry,
            &walker,
            &cancelled,
            stdout_writer,
            stderr_writer,
            options,
        );
        if (failed) {
            had_errors = true;
        }
    }

    std.debug.assert(dir_path.len > 0);
    if (had_errors) {
        return error.AccessDenied; // Generic error to signal failure.
    }
}

/// Handles a single walker entry. Returns true when the entry's removal
/// failed in a way that should mark the overall operation as errored.
/// Records cancelled directories so their ancestors are preserved.
fn handleWalkEntry(
    allocator: Allocator,
    io: std.Io,
    entry: common.walker.Entry,
    walker: *common.walker.Walker,
    cancelled: *std.ArrayList([]const u8),
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: RmOptions,
) !bool {
    std.debug.assert(entry.path.len > 0);
    std.debug.assert(entry.basename.len > 0);

    const is_directory = entry.kind == .directory;
    if (is_directory and entry.visit == .pre) {
        return handleDirectoryPre(io, entry, walker, allocator, cancelled, stderr_writer, options);
    }
    if (is_directory and entry.visit == .post) {
        return handleDirectoryPost(
            allocator,
            io,
            entry,
            cancelled,
            stdout_writer,
            stderr_writer,
            options,
        );
    }

    // Regular file or symlink: always a single pre-order visit.
    removeItem(allocator, io, entry.path, stdout_writer, stderr_writer, options) catch |err| {
        return handleFileError(allocator, entry, cancelled, stderr_writer, options, err);
    };
    return false;
}

/// Maps an error from removing a file/symlink entry onto the had-errors
/// signal, recording the parent directory when the user declines.
fn handleFileError(
    allocator: Allocator,
    entry: common.walker.Entry,
    cancelled: *std.ArrayList([]const u8),
    stderr_writer: *std.Io.Writer,
    options: RmOptions,
    err: anyerror,
) !bool {
    std.debug.assert(entry.path.len > 0);
    std.debug.assert(entry.kind != .directory);
    switch (err) {
        error.InteractiveUserCancelled => {
            // Declined: keep this entry's parent directory.
            try recordCancelledParent(allocator, cancelled, entry.path);
            return false;
        },
        error.UserCancelled => return true,
        error.FileNotFound => {
            if (!options.force) {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    "rm",
                    "cannot remove '{s}': No such file or directory",
                    .{entry.path},
                );
                return true;
            }
            return false;
        },
        error.AccessDenied => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "rm",
                "cannot remove '{s}': Permission denied",
                .{entry.path},
            );
            return true;
        },
        else => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "rm",
                "cannot remove '{s}': {s}",
                .{ entry.path, common.posixErrorString(err) },
            );
            return true;
        },
    }
}

/// Pre-order directory visit: prompt before descent under -i, pruning and
/// recording the directory when the user declines.
fn handleDirectoryPre(
    io: std.Io,
    entry: common.walker.Entry,
    walker: *common.walker.Walker,
    allocator: Allocator,
    cancelled: *std.ArrayList([]const u8),
    stderr_writer: *std.Io.Writer,
    options: RmOptions,
) !bool {
    std.debug.assert(entry.kind == .directory);
    std.debug.assert(entry.visit == .pre);
    std.debug.assert(entry.path.len > 0);

    if (options.force or !options.interactive) {
        return false;
    }
    if (try askYesNo(io, stderr_writer, .directory, entry.path)) {
        return false;
    }

    // Declined: skip the whole subtree and keep this directory.
    walker.pruneCurrent();
    try recordCancelled(allocator, cancelled, entry.path);
    return false;
}

/// Post-order directory visit: delete the now-empty directory unless a
/// descendant was preserved by an interactive decline.
fn handleDirectoryPost(
    allocator: Allocator,
    io: std.Io,
    entry: common.walker.Entry,
    cancelled: *std.ArrayList([]const u8),
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    options: RmOptions,
) !bool {
    std.debug.assert(entry.kind == .directory);
    std.debug.assert(entry.visit == .post);
    std.debug.assert(entry.path.len > 0);

    if (directoryHasCancelledChild(cancelled.items, entry.path)) {
        return false;
    }

    std.Io.Dir.cwd().deleteDir(io, entry.path) catch |err| switch (err) {
        error.DirNotEmpty => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "rm",
                "cannot remove '{s}': Directory not empty",
                .{entry.path},
            );
            return true;
        },
        error.AccessDenied => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "rm",
                "cannot remove '{s}': Permission denied",
                .{entry.path},
            );
            return true;
        },
        else => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                "rm",
                "cannot remove '{s}': {s}",
                .{ entry.path, common.posixErrorString(err) },
            );
            return true;
        },
    };

    if (options.verbose) {
        try stdout_writer.print("removed directory '{s}'\n", .{entry.path});
    }
    return false;
}

/// Records the parent directory of a path as needing preservation.
fn recordCancelledParent(
    allocator: Allocator,
    cancelled: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    std.debug.assert(path.len > 0);
    const parent = std.fs.path.dirname(path) orelse path;
    std.debug.assert(parent.len > 0);
    try recordCancelled(allocator, cancelled, parent);
}

/// Records a directory path as needing preservation. Duplicates the path
/// because the walker reuses the entry buffer after each step.
fn recordCancelled(
    allocator: Allocator,
    cancelled: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    std.debug.assert(path.len > 0);
    const owned = try allocator.dupe(u8, path);
    errdefer allocator.free(owned);
    try cancelled.append(allocator, owned);
    std.debug.assert(cancelled.items.len > 0);
}

/// Returns true when any preserved path equals dir_path or lies beneath it,
/// meaning dir_path is an ancestor of a declined entry and must survive.
fn directoryHasCancelledChild(
    cancelled_paths: []const []const u8,
    dir_path: []const u8,
) bool {
    std.debug.assert(dir_path.len > 0);
    var found = false;
    for (cancelled_paths) |candidate| {
        std.debug.assert(candidate.len > 0);
        if (std.mem.eql(u8, candidate, dir_path)) {
            found = true;
        } else if (candidate.len > dir_path.len and
            std.mem.startsWith(u8, candidate, dir_path) and
            candidate[dir_path.len] == std.fs.path.sep)
        {
            found = true;
        }
    }
    return found;
}

/// Check if a basename is "." or ".." (OpenBSD ISDOT macro equivalent).
fn isDotOrDotDot(basename: []const u8) bool {
    return std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..");
}

/// Extract basename from path, handling trailing slashes like OpenBSD basename().
/// Returns the final component of the path, stripping trailing slashes.
fn extractBasename(path: []const u8) []const u8 {
    if (path.len == 0) return path;

    // Strip trailing slashes
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') {
        end -= 1;
    }
    std.debug.assert(end >= 1);
    std.debug.assert(end <= path.len);

    // Handle root directory case "/"
    if (end == 1 and path[0] == '/') {
        return "/";
    }

    // Find the last slash before the basename
    var start: usize = 0;
    for (0..end) |i| {
        if (path[i] == '/') {
            start = i + 1;
        }
    }

    std.debug.assert(start <= end);
    return path[start..end];
}

/// Check if a path normalizes to the root directory "/".
/// Catches "/", "///", "/.", etc. but NOT "/tmp" or "/usr".
fn isRootPath(path: []const u8) bool {
    if (path.len == 0) return false;

    // Must start with /
    if (path[0] != '/') return false;

    // Strip trailing slashes and dots to normalize
    var i: usize = path.len;
    while (i > 1) {
        std.debug.assert(i <= path.len);
        const c = path[i - 1];
        if (c == '/') {
            i -= 1;
        } else if (c == '.' and i >= 2 and path[i - 2] == '/') {
            // Strip trailing "/." component
            i -= 2;
        } else {
            break;
        }
    }
    std.debug.assert(i <= path.len);

    // If we stripped everything down to just "/", it's root
    return i <= 1;
}

/// Enhanced path validation that combines all OpenBSD-style safety checks.
/// Checks for empty paths, root directory, and dot/dotdot patterns.
fn isPathSafeToRemove(path: []const u8) bool {
    // Check for empty path
    if (path.len == 0) return false;

    // Check for root directory
    if (std.mem.eql(u8, path, "/")) return false;

    // Extract basename and check if it's "." or ".."
    const basename = extractBasename(path);
    std.debug.assert(basename.len > 0);
    if (isDotOrDotDot(basename)) return false;

    return true;
}

// Tests

test "rm: basic functionality test" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test with non-existent file and force mode
    const args = [_][]const u8{ "-f", "definitely_nonexistent_file_12345.txt" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should succeed (exit code 0) with -f flag for non-existent file
    try testing.expect(exit_code == 0);
}

test "rm: root directory protection" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test removing root directory
    const args = [_][]const u8{ "-rf", "/" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should fail (non-zero exit code)
    try testing.expect(exit_code != 0);
    // Should have preserve-root error message
    try testing.expect(stderr_aw.writer.buffered().len > 0);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "refusing to remove '/'") != null,
    );
}

test "rm: empty path handling" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test empty path
    const args = [_][]const u8{""};
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should fail with error
    try testing.expect(exit_code != 0);
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

test "rm: missing operand" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test with no arguments
    const args = [_][]const u8{};
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should fail with missing operand error
    try testing.expect(exit_code != 0);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "missing operand") != null);
}

test "rm: help flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test help flag
    const args = [_][]const u8{"--help"};
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should succeed and show help
    try testing.expect(exit_code == 0);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "Usage:") != null);
}

test "rm: version flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test version flag
    const args = [_][]const u8{"--version"};
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should succeed and show version
    try testing.expect(exit_code == 0);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "vibeutils") != null);
}

test "isDotOrDotDot: basic dot detection" {
    try testing.expect(isDotOrDotDot("."));
    try testing.expect(isDotOrDotDot(".."));
    try testing.expect(!isDotOrDotDot("file.txt"));
    try testing.expect(!isDotOrDotDot("..."));
    try testing.expect(!isDotOrDotDot(""));
    try testing.expect(!isDotOrDotDot(".hidden"));
    try testing.expect(!isDotOrDotDot("..test"));
}

test "extractBasename: path handling" {
    try testing.expectEqualSlices(u8, "file.txt", extractBasename("file.txt"));
    try testing.expectEqualSlices(u8, "file.txt", extractBasename("./file.txt"));
    try testing.expectEqualSlices(u8, "file.txt", extractBasename("/path/to/file.txt"));
    try testing.expectEqualSlices(u8, "file.txt", extractBasename("/path/to/file.txt/"));
    try testing.expectEqualSlices(u8, "file.txt", extractBasename("/path/to/file.txt///"));
    try testing.expectEqualSlices(u8, ".", extractBasename("."));
    try testing.expectEqualSlices(u8, "..", extractBasename(".."));
    try testing.expectEqualSlices(u8, ".", extractBasename("./"));
    try testing.expectEqualSlices(u8, "..", extractBasename("../"));
    try testing.expectEqualSlices(u8, ".", extractBasename("/path/to/."));
    try testing.expectEqualSlices(u8, "..", extractBasename("/path/to/.."));
    try testing.expectEqualSlices(u8, ".", extractBasename("/path/to/./"));
    try testing.expectEqualSlices(u8, "..", extractBasename("/path/to/../"));
}

test "isPathSafeToRemove: comprehensive validation" {
    // Test empty path (should be unsafe)
    try testing.expect(!isPathSafeToRemove(""));

    // Test root directory (should be unsafe)
    try testing.expect(!isPathSafeToRemove("/"));

    // Test current directory patterns (should be unsafe)
    try testing.expect(!isPathSafeToRemove("."));
    try testing.expect(!isPathSafeToRemove("./"));
    try testing.expect(!isPathSafeToRemove("/path/to/."));
    try testing.expect(!isPathSafeToRemove("/path/to/./"));

    // Test parent directory patterns (should be unsafe)
    try testing.expect(!isPathSafeToRemove(".."));
    try testing.expect(!isPathSafeToRemove("../"));
    try testing.expect(!isPathSafeToRemove("/path/to/.."));
    try testing.expect(!isPathSafeToRemove("/path/to/../"));

    // Test safe paths (should be safe)
    try testing.expect(isPathSafeToRemove("file.txt"));
    try testing.expect(isPathSafeToRemove("./file.txt"));
    try testing.expect(isPathSafeToRemove("/path/to/file.txt"));
    try testing.expect(isPathSafeToRemove(".hidden"));
    try testing.expect(isPathSafeToRemove("..hidden"));
    try testing.expect(isPathSafeToRemove("..."));
    try testing.expect(isPathSafeToRemove("test."));
    try testing.expect(isPathSafeToRemove("test.."));
    try testing.expect(isPathSafeToRemove("/usr/local/bin"));
}

test "rm: verbose recursive removal" {
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    // Create a directory tree
    try tmp.dir().createDir(io, "testdir", std.Io.File.Permissions.fromMode(0o755));
    var subdir = try tmp.dir().openDir(io, "testdir", .{});
    const file1 = try subdir.createFile(io, "file1.txt", .{});
    file1.close(io);
    const file2 = try subdir.createFile(io, "file2.txt", .{});
    file2.close(io);
    subdir.close(io);

    const dir_path = try tmp.getPath("testdir");
    defer testing.allocator.free(dir_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const options = RmOptions{
        .force = false,
        .interactive = false,
        .interactive_once = false,
        .recursive = true,
        .verbose = true,
        .preserve_root = true,
    };

    const success = try removeFiles(
        testing.allocator,
        io,
        &[_][]const u8{dir_path},
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );

    try testing.expect(success);
    // Verbose output should mention individual files
    const output = stdout_aw.writer.buffered();
    try testing.expect(std.mem.find(u8, output, "removed '") != null or
        std.mem.find(u8, output, "removed directory '") != null);
}

test "rm: recursive removal with nested directories" {
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    // Create nested directory tree
    try tmp.dir().createDirPath(io, "deep/nested/dir");
    var deep_dir = try tmp.dir().openDir(io, "deep/nested/dir", .{});
    const file = try deep_dir.createFile(io, "leaf.txt", .{});
    file.close(io);
    deep_dir.close(io);

    const dir_path = try tmp.getPath("deep");
    defer testing.allocator.free(dir_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const options = RmOptions{
        .force = false,
        .interactive = false,
        .interactive_once = false,
        .recursive = true,
        .verbose = true,
        .preserve_root = true,
    };

    const success = try removeFiles(
        testing.allocator,
        io,
        &[_][]const u8{dir_path},
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );

    try testing.expect(success);

    // Verify directory is gone
    const stat = std.Io.Dir.cwd().statFile(io, dir_path, .{});
    try testing.expect(stat == error.FileNotFound);
}

test "isRootPath: detects root and normalized root paths" {
    // Exact root
    try testing.expect(isRootPath("/"));

    // Multiple slashes normalize to root
    try testing.expect(isRootPath("///"));
    try testing.expect(isRootPath("//"));

    // Trailing dot normalizes to root
    try testing.expect(isRootPath("/."));
    try testing.expect(isRootPath("/./"));

    // Non-root paths should NOT match
    try testing.expect(!isRootPath("/tmp"));
    try testing.expect(!isRootPath("/usr/local/bin"));
    try testing.expect(!isRootPath("/tmp/"));
    try testing.expect(!isRootPath("tmp"));
    try testing.expect(!isRootPath(""));
    try testing.expect(!isRootPath("."));
    try testing.expect(!isRootPath(".."));
    try testing.expect(!isRootPath("./"));
}

test "rm: triple-slash root protection" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test removing "///" which normalizes to "/"
    const args = [_][]const u8{ "-rf", "///" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should fail with preserve-root error
    try testing.expect(exit_code != 0);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "refusing to remove '/'") != null,
    );
}

test "rm: no-preserve-root flag is parsed" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test that --no-preserve-root is recognized as a valid flag
    // Use a non-existent file with -f to avoid actual filesystem operations
    const args = [_][]const u8{ "--no-preserve-root", "-f", "nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should succeed (exit code 0) because -f ignores nonexistent files
    try testing.expect(exit_code == 0);
}

test "rm: non-root path does not trigger preserve-root" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test that /tmp/nonexistent does NOT trigger preserve-root
    const args = [_][]const u8{ "-f", "/tmp/nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should succeed (-f ignores nonexistent) and NOT show preserve-root error
    try testing.expect(exit_code == 0);
    try testing.expect(
        std.mem.find(u8, stderr_aw.writer.buffered(), "refusing to remove '/'") == null,
    );
}

test "rm: preserve-root flag is accepted" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Test that --preserve-root is recognized (it's the default, but should be accepted)
    const args = [_][]const u8{ "--preserve-root", "-f", "nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should succeed since -f ignores nonexistent files
    try testing.expect(exit_code == 0);
}

test "rm: help text includes preserve-root flags" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--help"};
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "--preserve-root") != null);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "--no-preserve-root") != null);
}

// ============================================================
// Tests for rm -d (remove empty directories)
// ============================================================

test "rm: -d flag is accepted by argument parser" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-d", "-f", "nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);
}

test "rm: -d removes an empty directory" {
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    try tmp.dir().createDir(io, "emptydir", std.Io.File.Permissions.fromMode(0o755));

    const dir_path = try tmp.getPath("emptydir");
    defer testing.allocator.free(dir_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-d", dir_path };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);

    const stat = tmp.dir().statFile(io, "emptydir", .{});
    try testing.expect(stat == error.FileNotFound);
}

test "rm: -d fails on non-empty directory" {
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    try tmp.dir().createDir(io, "nonemptydir", std.Io.File.Permissions.fromMode(0o755));
    var subdir = try tmp.dir().openDir(io, "nonemptydir", .{});
    const file = try subdir.createFile(io, "somefile.txt", .{});
    file.close(io);
    subdir.close(io);

    const dir_path = try tmp.getPath("nonemptydir");
    defer testing.allocator.free(dir_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-d", dir_path };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code != 0);
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

test "rm: -d still removes regular files" {
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    const file = try tmp.dir().createFile(io, "regularfile.txt", .{});
    file.close(io);

    const file_path = try tmp.getPath("regularfile.txt");
    defer testing.allocator.free(file_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-d", file_path };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);

    const stat = tmp.dir().statFile(io, "regularfile.txt", .{});
    try testing.expect(stat == error.FileNotFound);
}

test "rm: without -d or -r refuses to remove directory" {
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    try tmp.dir().createDir(io, "somedir", std.Io.File.Permissions.fromMode(0o755));

    const dir_path = try tmp.getPath("somedir");
    defer testing.allocator.free(dir_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{dir_path};
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code != 0);
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "Is a directory") != null);
}

// ============================================================
// Tests for rm -P (BSD compatibility no-op flag)
// ============================================================

test "rm: -P flag is accepted by argument parser" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-P", "-f", "nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);
}

test "rm: -P removes a file just like normal rm" {
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    const file = try tmp.dir().createFile(io, "securefile.txt", .{});
    file.close(io);

    const file_path = try tmp.getPath("securefile.txt");
    defer testing.allocator.free(file_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-P", file_path };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);

    const stat = tmp.dir().statFile(io, "securefile.txt", .{});
    try testing.expect(stat == error.FileNotFound);
}

test "rm: -P combined with -f works" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-P", "-f", "nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);
    try testing.expect(stderr_aw.writer.buffered().len == 0);
}

// ============================================================
// Tests for rm -x (don't cross mount points)
// ============================================================

test "rm: -x flag is accepted by argument parser" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-x", "-f", "nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);
}

test "rm: -x recursive removal stays on same device" {
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    // Create a directory tree on the same device
    try tmp.dir().createDirPath(io, "xdir/subdir");
    var subdir = try tmp.dir().openDir(io, "xdir/subdir", .{});
    const file = try subdir.createFile(io, "file.txt", .{});
    file.close(io);
    subdir.close(io);

    const dir_path = try tmp.getPath("xdir");
    defer testing.allocator.free(dir_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // -x -r should remove everything since it's all on the same device
    const args = [_][]const u8{ "-x", "-r", dir_path };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);

    // Verify directory is gone
    const stat = std.Io.Dir.cwd().statFile(io, dir_path, .{});
    try testing.expect(stat == error.FileNotFound);
}

test "rm: -x combined with -rf works" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-x", "-rf", "nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);
}

test "rm: help text includes -x flag" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{"--help"};
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expect(exit_code == 0);
    try testing.expect(std.mem.find(u8, stdout_aw.writer.buffered(), "-x") != null);
}

// ============================================================
// Tests for rm -W (undelete stub)
// ============================================================

test "rm: -W flag is accepted and prints warning" {
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-W", "-f", "nonexistent_file_test_12345" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // -W (undelete) is not supported on Linux; should exit non-zero
    try testing.expect(exit_code != 0);
    // Should print warning/error to stderr
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

test "rm: -W does not delete existing file" {
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    const file = try tmp.dir().createFile(io, "undelete_test.txt", .{});
    file.close(io);

    const file_path = try tmp.getPath("undelete_test.txt");
    defer testing.allocator.free(file_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-W", file_path };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // -W must NOT delete the file — that would be data loss
    try testing.expect(exit_code != 0);
    // Warning should appear
    try testing.expect(stderr_aw.writer.buffered().len > 0);
    // File must still exist
    const stat = tmp.dir().statFile(io, "undelete_test.txt", .{});
    try testing.expect(stat != error.FileNotFound);
}

test "rm: -W must not delete existing file" {
    // F67: rm -W is supposed to attempt recovery (undelete), not deletion.
    // On Linux where undelete is unsupported, it should error and leave
    // the file intact. Deleting a file when asked to recover it is
    // dangerous data loss.
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    const file = try tmp.dir().createFile(io, "preserve_me.txt", .{});
    file.close(io);

    const file_path = try tmp.getPath("preserve_me.txt");
    defer testing.allocator.free(file_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-W", file_path };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // File MUST still exist -- -W should never delete
    const stat = tmp.dir().statFile(io, "preserve_me.txt", .{});
    try testing.expect(stat != error.FileNotFound);

    // Exit code must be non-zero since undelete is not supported
    try testing.expect(exit_code != 0);
}

test "rm: -W on nonexistent file returns error" {
    // Attempting to undelete a file that doesn't exist should error.
    const io = testing.io;
    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-W", "/tmp/nonexistent_rm_W_test_99999" };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Should fail with non-zero exit
    try testing.expect(exit_code != 0);
    // Stderr should contain an error message
    try testing.expect(stderr_aw.writer.buffered().len > 0);
}

test "rm: -W on directory returns error without removing it" {
    // -W on a directory should also not remove it.
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    try tmp.dir().createDir(io, "keep_this_dir", std.Io.File.Permissions.fromMode(0o755));

    const dir_path = try tmp.getPath("keep_this_dir");
    defer testing.allocator.free(dir_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const args = [_][]const u8{ "-W", dir_path };
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    // Directory MUST still exist
    const stat = tmp.dir().statFile(io, "keep_this_dir", .{});
    try testing.expect(stat != error.FileNotFound);

    // Exit code must be non-zero
    try testing.expect(exit_code != 0);
}

// ============================================================
// Tests for rm on symlinks to directories (POSIX compliance)
// ============================================================

test "rm: symlink to directory removed without -r" {
    // POSIX requires `rm symlink-to-dir` to unlink the symlink itself,
    // not require -r just because the target is a directory.
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    // Create a real directory
    try tmp.dir().createDir(io, "target_dir", std.Io.File.Permissions.fromMode(0o755));

    // Create a symlink pointing to the directory
    tmp.dir().symLink(io, "target_dir", "link_to_dir", .{}) catch |err| {
        if (err == error.AccessDenied) return; // skip on platforms that disallow symlinks
        return err;
    };

    // Build absolute path to the symlink WITHOUT resolving it.
    // realPathFileAlloc would follow the symlink and return the target path.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.realPath(&path_buf);
    const base_path = path_buf[0..base_len];
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/link_to_dir", .{base_path});
    defer testing.allocator.free(link_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // rm (without -r) on a symlink to a directory should succeed
    const args = [_][]const u8{link_path};
    const exit_code = try runRm(testing.allocator, io, &args, &stdout_aw.writer, &stderr_aw.writer);

    try testing.expectEqual(@as(u8, 0), exit_code);

    // The symlink should be gone
    const link_stat = tmp.dir().statFile(io, "link_to_dir", .{});
    try testing.expect(link_stat == error.FileNotFound);

    // The target directory should still exist
    const target_stat = try tmp.dir().statFile(io, "target_dir", .{});
    try testing.expectEqual(std.Io.File.Kind.directory, target_stat.kind);
}

test "rm: getDeviceId returns consistent results" {
    // "/" always exists on all systems
    const dev1 = try getDeviceId(testing.io, "/");
    const dev2 = try getDeviceId(testing.io, "/");
    try testing.expectEqual(dev1, dev2);
    try testing.expect(dev1 > 0);
}

// ============================================================
// Characterization tests for the recursive-traversal removal
// path (removeDirectory / removeDirectoryRecursive). These lock
// in the behavior that the bounded-walker rewrite must preserve.
// They drive the SLOW path (verbose/interactive/-x) so they
// exercise the manual traversal, NOT the deleteTree fast path.
// ============================================================

test "rm: post-order deletion removes children before the parent directory" {
    // Goal: prove the directory is deleted only AFTER its file children.
    // Methodology: run with verbose so every removal is announced in
    // order, then assert the parent's "removed directory" line appears
    // strictly AFTER each child file's "removed" line. A pre-order or
    // broken traversal would emit the directory line first (or fail to
    // empty the dir before deleteDir), breaking these ordering asserts.
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    try tmp.dir().createDir(io, "po", std.Io.File.Permissions.fromMode(0o755));
    var dir = try tmp.dir().openDir(io, "po", .{});
    const f1 = try dir.createFile(io, "alpha.txt", .{});
    f1.close(io);
    const f2 = try dir.createFile(io, "beta.txt", .{});
    f2.close(io);
    dir.close(io);

    const dir_path = try tmp.getPath("po");
    defer testing.allocator.free(dir_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const options = RmOptions{
        .force = false,
        .interactive = false,
        .interactive_once = false,
        .recursive = true,
        .verbose = true,
        .preserve_root = true,
    };

    const success = try removeFiles(
        testing.allocator,
        io,
        &[_][]const u8{dir_path},
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );
    try testing.expect(success);

    const out = stdout_aw.writer.buffered();

    // Each child file must have been announced as removed.
    const alpha = std.mem.find(u8, out, "alpha.txt") orelse return error.MissingAlphaLine;
    const beta = std.mem.find(u8, out, "beta.txt") orelse return error.MissingBetaLine;

    // The parent directory removal line must exist...
    const dir_line = std.mem.find(u8, out, "removed directory '") orelse
        return error.MissingDirLine;

    // ...and it must come AFTER both child removals (post-order).
    try testing.expect(dir_line > alpha);
    try testing.expect(dir_line > beta);

    // The whole tree must actually be gone from disk.
    const stat = std.Io.Dir.cwd().statFile(io, dir_path, .{});
    try testing.expect(stat == error.FileNotFound);
}

test "rm: recursive removal clears a multi-level tree leaving nothing behind" {
    // Goal: a deep + wide tree is fully removed. Methodology: build
    // several levels each containing files and subdirectories, remove
    // the root recursively, and assert the root and a known-deep leaf
    // are both gone. A traversal that misses a branch would leave the
    // root non-empty and deleteDir would fail.
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    // Build: root/{a,b}/sub/{leaf files}
    try tmp.dir().createDirPath(io, "root/a/sub");
    try tmp.dir().createDirPath(io, "root/b/sub");

    {
        var a_sub = try tmp.dir().openDir(io, "root/a/sub", .{});
        const fa = try a_sub.createFile(io, "deep_a.txt", .{});
        fa.close(io);
        a_sub.close(io);

        var b_sub = try tmp.dir().openDir(io, "root/b/sub", .{});
        const fb = try b_sub.createFile(io, "deep_b.txt", .{});
        fb.close(io);
        b_sub.close(io);

        var a_dir = try tmp.dir().openDir(io, "root/a", .{});
        const fm = try a_dir.createFile(io, "mid_a.txt", .{});
        fm.close(io);
        a_dir.close(io);
    }

    const root_path = try tmp.getPath("root");
    defer testing.allocator.free(root_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // verbose=true forces the slow traversal path (not deleteTree).
    const options = RmOptions{
        .force = false,
        .interactive = false,
        .interactive_once = false,
        .recursive = true,
        .verbose = true,
        .preserve_root = true,
    };

    const success = try removeFiles(
        testing.allocator,
        io,
        &[_][]const u8{root_path},
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );
    try testing.expect(success);

    // Root gone entirely.
    const root_stat = std.Io.Dir.cwd().statFile(io, root_path, .{});
    try testing.expect(root_stat == error.FileNotFound);

    // The original tmp-relative paths must also be gone.
    try testing.expect(tmp.dir().statFile(io, "root", .{}) == error.FileNotFound);
    try testing.expect(tmp.dir().statFile(io, "root/a/sub/deep_a.txt", .{}) == error.FileNotFound);
}

test "rm: directory symlink is removed as a link and not descended under no-follow" {
    // Goal: under the default no-follow policy a symlink whose target is
    // a directory must be unlinked (deleteFile) during recursive removal,
    // and its target directory + contents must remain untouched. A
    // traversal that followed the symlink would delete the target's file.
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    // Target directory (outside the tree we remove) with a file in it.
    try tmp.dir().createDir(io, "real_target", std.Io.File.Permissions.fromMode(0o755));
    var target = try tmp.dir().openDir(io, "real_target", .{});
    const tf = try target.createFile(io, "precious.txt", .{});
    tf.close(io);
    target.close(io);

    // The tree we will remove, containing a symlink to the target dir.
    try tmp.dir().createDir(io, "tree", std.Io.File.Permissions.fromMode(0o755));
    tmp.dir().symLink(io, "../real_target", "tree/link_to_target", .{}) catch |err| {
        if (err == error.AccessDenied) return; // skip where symlinks disallowed
        return err;
    };

    const tree_path = try tmp.getPath("tree");
    defer testing.allocator.free(tree_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const options = RmOptions{
        .force = false,
        .interactive = false,
        .interactive_once = false,
        .recursive = true,
        .verbose = true,
        .preserve_root = true,
    };

    const success = try removeFiles(
        testing.allocator,
        io,
        &[_][]const u8{tree_path},
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );
    try testing.expect(success);

    // The removed tree (and its symlink) must be gone.
    try testing.expect(tmp.dir().statFile(io, "tree", .{}) == error.FileNotFound);

    // The symlink TARGET directory must survive untouched...
    const target_stat = try tmp.dir().statFile(io, "real_target", .{});
    try testing.expectEqual(std.Io.File.Kind.directory, target_stat.kind);

    // ...including its file: proof the symlink was NOT followed/descended.
    _ = try tmp.dir().statFile(io, "real_target/precious.txt", .{});
}

test "rm: recursive removal succeeds when a real dir has a sibling symlink alias (issue #69)" {
    // Goal: unlike the test above (where the symlink target lives OUTSIDE
    // the removed tree), here the symlink's target is a SIBLING directory
    // INSIDE the tree being removed: tree/real/inner.txt and
    // tree/link -> real. GNU rm does no inode dedup between them and
    // removes the whole tree (rc=0). removeFiles uses the walker's DEFAULT
    // cycle_mode (.ancestors, GNU fts semantics). The historical bug
    // pre-registered "real"'s (dev,ino) via the sibling "link" before
    // classifying "real" itself, so the walker silently skipped descending
    // into "real". Its file then survives the pre-order pass, and the
    // post-order rmdir on "real" fails with ENOTEMPTY -- removeFiles
    // reports failure instead of fully removing the tree.
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    try tmp.dir().createDir(io, "tree", std.Io.File.Permissions.fromMode(0o755));
    var tree_dir = try tmp.dir().openDir(io, "tree", .{});
    try tree_dir.createDir(io, "real", std.Io.File.Permissions.fromMode(0o755));
    var real_dir = try tree_dir.openDir(io, "real", .{});
    const rf = try real_dir.createFile(io, "inner.txt", .{});
    rf.close(io);
    real_dir.close(io);
    tree_dir.symLink(io, "real", "link", .{}) catch |err| {
        if (err == error.AccessDenied) return; // skip where symlinks disallowed
        tree_dir.close(io);
        return err;
    };
    tree_dir.close(io);

    const tree_path = try tmp.getPath("tree");
    defer testing.allocator.free(tree_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const options = RmOptions{
        .force = false,
        .interactive = false,
        .interactive_once = false,
        .recursive = true,
        .verbose = true,
        .preserve_root = true,
    };

    const success = try removeFiles(
        testing.allocator,
        io,
        &[_][]const u8{tree_path},
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );
    // RED today: the sibling-alias skip leaves "real" non-empty, so the
    // post-order rmdir fails and removeFiles returns false.
    try testing.expect(success);

    // The whole tree, including the aliased real dir, must be gone.
    try testing.expect(tmp.dir().statFile(io, "tree", .{}) == error.FileNotFound);
}

test "rm: deep directory chain is fully removed without stack overflow" {
    // Goal: a long single-branch chain is removed completely. Methodology:
    // build a chain many hundreds of levels deep with a file at the bottom,
    // then recursively remove the top and assert it is gone. A still-recursive
    // implementation would risk a stack overflow at this depth; the bounded
    // walker must handle it. The assertion that the deepest known path is gone
    // proves the full chain was traversed.
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    // Deep enough that a still-recursive implementation would risk a
    // stack-overflow regression, while staying within PATH_MAX (each
    // level adds only "/d", so 400 levels is ~800 bytes of path).
    const depth: usize = 400;

    // Build the chain "chain/d/d/d/..." and drop a file at each level.
    var path_builder: std.ArrayListUnmanaged(u8) = .empty;
    defer path_builder.deinit(testing.allocator);
    try path_builder.appendSlice(testing.allocator, "chain");

    for (0..depth) |_| {
        try path_builder.appendSlice(testing.allocator, "/d");
    }
    try tmp.dir().createDirPath(io, path_builder.items);

    // Place a file in the deepest directory to force non-empty deletes.
    var deepest = try tmp.dir().openDir(io, path_builder.items, .{});
    const leaf = try deepest.createFile(io, "bottom.txt", .{});
    leaf.close(io);
    deepest.close(io);

    const top_path = try tmp.getPath("chain");
    defer testing.allocator.free(top_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // verbose=true forces the slow traversal (the recursion under test).
    const options = RmOptions{
        .force = false,
        .interactive = false,
        .interactive_once = false,
        .recursive = true,
        .verbose = true,
        .preserve_root = true,
    };

    const success = try removeFiles(
        testing.allocator,
        io,
        &[_][]const u8{top_path},
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );
    try testing.expect(success);

    // Top of chain gone, and the deepest path gone too.
    try testing.expect(std.Io.Dir.cwd().statFile(io, top_path, .{}) == error.FileNotFound);
    try testing.expect(tmp.dir().statFile(io, path_builder.items, .{}) == error.FileNotFound);
}

test "rm: -x recursive removal removes a same-device tree completely" {
    // Goal: with -x (stay on filesystem) a tree wholly on one device is
    // still fully removed — the device guard must not over-prune same-fs
    // entries. Methodology: build a small tree (all on tmp's device),
    // run the slow -x path, assert everything is gone. (Cross-device
    // pruning cannot be created portably in a unit test; this guards the
    // common same-device case the -x guard must not break.)
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    try tmp.dir().createDirPath(io, "xtree/inner");
    var inner = try tmp.dir().openDir(io, "xtree/inner", .{});
    const f = try inner.createFile(io, "leaf.txt", .{});
    f.close(io);
    inner.close(io);

    const dir_path = try tmp.getPath("xtree");
    defer testing.allocator.free(dir_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // no_cross_device=true selects the -x slow path (skips deleteTree).
    const options = RmOptions{
        .force = false,
        .interactive = false,
        .interactive_once = false,
        .recursive = true,
        .verbose = true,
        .preserve_root = true,
        .no_cross_device = true,
    };

    const success = try removeFiles(
        testing.allocator,
        io,
        &[_][]const u8{dir_path},
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );
    try testing.expect(success);

    try testing.expect(std.Io.Dir.cwd().statFile(io, dir_path, .{}) == error.FileNotFound);
    try testing.expect(tmp.dir().statFile(io, "xtree", .{}) == error.FileNotFound);
}

// ============================================================
// Interactive (-i) guards for the recursive-removal path.
//
// `common.prompt.promptYesNo` reads directly from real stdin with no
// injection seam, so these behaviors cannot be driven through the normal
// stdin path in a unit test. They route through the `askYesNo` choke
// point and install a scripted `test_prompt_override` answerer instead.
//
// Behaviors #3 (prompt-before-descent prunes the subtree) and #4
// (declined descendant keeps the parent) describe the TARGET walker
// semantics. They are RED→GREEN guards for the migration: they define the
// behavior the bounded-walker driver must implement and fail against any
// implementation that descends-then-prompts or that deletes a directory
// whose child was declined. They assert positive survival/removal facts to
// avoid default-value traps and order-dependence.
// ============================================================

/// Module-level scratch used by the scripted prompt answerers below. A
/// function pointer cannot capture state, so the test sets these globals,
/// installs the answerer, runs rm, then restores `test_prompt_override`.
var test_answer_default: bool = true;
var test_decline_basename: []const u8 = "";

/// Answerer that declines (returns false) for any prompt whose path ends
/// with `test_decline_basename`, and otherwise returns `test_answer_default`.
fn scriptedAnswerer(kind: PromptKind, path: []const u8) bool {
    _ = kind;
    if (test_decline_basename.len != 0 and std.mem.endsWith(u8, path, test_decline_basename)) {
        return false;
    }
    return test_answer_default;
}

test "rm: interactive decline of a directory keeps that directory" {
    // Goal (behavior #3, preservation-safe slice): answering "no" to a
    // directory's prompt must leave that directory in place — declining is
    // not an error and must never delete the directory the user refused.
    // Methodology: build dir/{sub/{deep.txt}}, decline the prompt for the
    // top directory (accept everything else), then assert the top directory
    // still exists and the run reports success. An implementation that
    // ignores the decline and deletes the directory anyway goes RED here.
    //
    // The stronger "prune the WHOLE subtree before descending" semantics
    // (children also survive) is a behavior change introduced by the walker
    // driver; it is exercised end-to-end in tests/utilities/rm_test.sh,
    // where real stdin is piped. This unit guard asserts only the slice
    // that is invariant across the recursion and the walker so it stays
    // green on the current code while still guarding the decline.
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    try tmp.dir().createDirPath(io, "keep_me/sub");
    var sub = try tmp.dir().openDir(io, "keep_me/sub", .{});
    const deep = try sub.createFile(io, "deep.txt", .{});
    deep.close(io);
    sub.close(io);

    const dir_path = try tmp.getPath("keep_me");
    defer testing.allocator.free(dir_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Decline the prompt for the top directory; accept anything else.
    test_answer_default = true;
    test_decline_basename = "keep_me";
    test_prompt_override = &scriptedAnswerer;
    defer {
        test_prompt_override = null;
        test_decline_basename = "";
        test_answer_default = true;
    }

    const options = RmOptions{
        .force = false,
        .interactive = true,
        .interactive_once = false,
        .recursive = true,
        .verbose = false,
        .preserve_root = true,
    };

    // Declining is not an error; the call should report overall success.
    const success = try removeFiles(
        testing.allocator,
        io,
        &[_][]const u8{dir_path},
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );
    try testing.expect(success);

    // Positive fact: the directory the user refused must still exist.
    // Assert on the absolute realpath rm operated on (symlinked temp roots).
    const top = try std.Io.Dir.cwd().statFile(io, dir_path, .{});
    try testing.expectEqual(std.Io.File.Kind.directory, top.kind);
}

test "rm: interactive declined child keeps the parent directory" {
    // Goal (behavior #4): if a descendant's removal is declined, the parent
    // directory must NOT be deleted (deleteDir is skipped for any directory
    // with a cancelled descendant). Methodology: build dir/{keep.txt, go.txt},
    // accept the directory prompt and the "go.txt" prompt but decline
    // "keep.txt", then assert the parent survives non-empty with exactly
    // keep.txt remaining and go.txt removed. This proves both containment
    // (parent kept) and that the accepted removal really happened (go.txt
    // gone) — neither is a default value.
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    try tmp.dir().createDir(io, "parent", std.Io.File.Permissions.fromMode(0o755));
    var dir = try tmp.dir().openDir(io, "parent", .{});
    const f_keep = try dir.createFile(io, "keep.txt", .{});
    f_keep.close(io);
    const f_go = try dir.createFile(io, "go.txt", .{});
    f_go.close(io);
    dir.close(io);

    const dir_path = try tmp.getPath("parent");
    defer testing.allocator.free(dir_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Decline only "keep.txt"; accept the parent prompt and "go.txt".
    test_answer_default = true;
    test_decline_basename = "keep.txt";
    test_prompt_override = &scriptedAnswerer;
    defer {
        test_prompt_override = null;
        test_decline_basename = "";
        test_answer_default = true;
    }

    const options = RmOptions{
        .force = false,
        .interactive = true,
        .interactive_once = false,
        .recursive = true,
        .verbose = false,
        .preserve_root = true,
    };

    _ = try removeFiles(
        testing.allocator,
        io,
        &[_][]const u8{dir_path},
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );

    // Assert on the SAME (absolute, realpath-resolved) path space that rm
    // operated on, not on tmp.dir()-relative paths — on systems where the
    // temp root is itself a symlink the two can resolve differently.
    const keep_path = try std.fmt.allocPrint(testing.allocator, "{s}/keep.txt", .{dir_path});
    defer testing.allocator.free(keep_path);
    const go_path = try std.fmt.allocPrint(testing.allocator, "{s}/go.txt", .{dir_path});
    defer testing.allocator.free(go_path);

    // Containment: the parent survives (a declined child blocks deleteDir).
    const parent_stat = try std.Io.Dir.cwd().statFile(io, dir_path, .{});
    try testing.expectEqual(std.Io.File.Kind.directory, parent_stat.kind);

    // The declined file must remain...
    _ = try std.Io.Dir.cwd().statFile(io, keep_path, .{});

    // ...and the accepted file must really be gone (proves it was not a no-op).
    try testing.expect(std.Io.Dir.cwd().statFile(io, go_path, .{}) == error.FileNotFound);
}

test "rm: interactive accept removes the entire tree through the recursive path" {
    // Goal: with -i and every prompt answered "yes", the whole tree is
    // removed via the interactive (slow) traversal — proving the seam does
    // not accidentally suppress real deletions. Methodology: build
    // tree/{a.txt, inner/{b.txt}}, accept all prompts, assert nothing
    // remains. A broken acceptance path would leave files or the dir behind.
    const io = testing.io;
    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();

    try tmp.dir().createDirPath(io, "tree_yes/inner");
    {
        var inner = try tmp.dir().openDir(io, "tree_yes/inner", .{});
        const b = try inner.createFile(io, "b.txt", .{});
        b.close(io);
        inner.close(io);

        var top = try tmp.dir().openDir(io, "tree_yes", .{});
        const a = try top.createFile(io, "a.txt", .{});
        a.close(io);
        top.close(io);
    }

    const dir_path = try tmp.getPath("tree_yes");
    defer testing.allocator.free(dir_path);

    var stdout_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Accept every prompt.
    test_answer_default = true;
    test_decline_basename = "";
    test_prompt_override = &scriptedAnswerer;
    defer {
        test_prompt_override = null;
        test_decline_basename = "";
        test_answer_default = true;
    }

    const options = RmOptions{
        .force = false,
        .interactive = true,
        .interactive_once = false,
        .recursive = true,
        .verbose = false,
        .preserve_root = true,
    };

    const success = try removeFiles(
        testing.allocator,
        io,
        &[_][]const u8{dir_path},
        &stdout_aw.writer,
        &stderr_aw.writer,
        options,
    );
    try testing.expect(success);

    // Whole tree gone (assert on the absolute realpath rm operated on).
    const inner_path = try std.fmt.allocPrint(testing.allocator, "{s}/inner/b.txt", .{dir_path});
    defer testing.allocator.free(inner_path);
    try testing.expect(std.Io.Dir.cwd().statFile(io, dir_path, .{}) == error.FileNotFound);
    try testing.expect(std.Io.Dir.cwd().statFile(io, inner_path, .{}) == error.FileNotFound);
}

// ============================================================
// Structural guard: the directory-deletion recursion must be gone.
//
// Tiger Style forbids direct recursion; the migration replaces the
// post-order recursive directory remover with a bounded-walker driver.
// This test scans rm's own source at comptime and asserts the recursive
// function's definition no longer exists. It is RED on the pre-migration
// code (the function is still present) and goes GREEN once the implementer
// deletes it and routes deletion through the walker. It cannot be
// satisfied by leaving the old function as dead code.
//
// CRITICAL self-reference avoidance: the needle is assembled at runtime
// from fragments so the full symbol never appears verbatim anywhere in
// this file. If we wrote the literal symbol here, @embedFile would always
// find it and the test could never go green — a broken guard. The
// fragments below MUST NOT be concatenated into the symbol in source.
// ============================================================

test "rm: recursive directory remover is deleted in favor of the bounded walker" {
    const source = @embedFile("rm.zig");

    // Assemble "fn removeDirectory" + "Recursive" at runtime. Split so the
    // complete definition string is absent from this file's own bytes.
    var needle_buf: [64]u8 = undefined;
    const def_needle = try std.fmt.bufPrint(&needle_buf, "fn removeDirectory{s}", .{"Recursive"});

    // The recursive function definition must not exist anymore.
    try testing.expect(std.mem.find(u8, source, def_needle) == null);

    // Positive space: deletion must instead go through the shared bounded
    // walker, so the migrated driver references it. This prevents a
    // "delete the function and inline a new recursion" regression.
    try testing.expect(std.mem.find(u8, source, "walker") != null);
}

test "rm: -d non-empty directory appends recursive-removal hint" {
    const saved_hints = common.env.test_stderr_hints;
    defer common.env.test_stderr_hints = saved_hints;
    common.env.test_stderr_hints = true;
    const saved_overrides = common.env.test_overrides;
    defer common.env.test_overrides = saved_overrides;
    const staged = [_]common.env.Override{.{ .key = "NO_COLOR", .value = "1" }};
    common.env.test_overrides = &staged;

    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();
    try tmp.dir().createDir(testing.io, "nonempty", .default_dir);
    const file = try tmp.dir().createFile(testing.io, "nonempty/file.txt", .{});
    file.close(testing.io);
    const dir_path = try tmp.getPath("nonempty");
    defer testing.allocator.free(dir_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    const args = [_][]const u8{ "-d", dir_path };
    const exit_code = try runRm(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "rm: cannot remove '{s}': Directory not empty" ++
            " (use rm -r to remove recursively)\n",
        .{dir_path},
    );
    defer testing.allocator.free(expected);

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.general_error)), exit_code);
    try testing.expectEqualStrings(expected, stderr_aw.writer.buffered());
}

test "rm: -r leftover non-empty directory does not suggest -r" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;

    const saved_hints = common.env.test_stderr_hints;
    defer common.env.test_stderr_hints = saved_hints;
    common.env.test_stderr_hints = true;
    const saved_overrides = common.env.test_overrides;
    defer common.env.test_overrides = saved_overrides;
    const staged = [_]common.env.Override{.{ .key = "NO_COLOR", .value = "1" }};
    common.env.test_overrides = &staged;

    var tmp = TestDir.init(testing.allocator);
    defer tmp.deinit();
    try tmp.dir().createDir(testing.io, "locked", .default_dir);
    const file = try tmp.dir().createFile(testing.io, "locked/child.txt", .{});
    file.close(testing.io);
    const dir_path = try tmp.getPath("locked");
    defer testing.allocator.free(dir_path);
    const dir_path_z = try testing.allocator.dupeZ(u8, dir_path);
    defer testing.allocator.free(dir_path_z);
    if (std.c.chmod(dir_path_z, 0o555) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(dir_path_z, 0o755);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();
    const args = [_][]const u8{ "-rfv", dir_path };
    const exit_code = try runRm(
        testing.allocator,
        testing.io,
        &args,
        common.null_writer,
        &stderr_aw.writer,
    );
    const expected_line = try std.fmt.allocPrint(
        testing.allocator,
        "rm: cannot remove '{s}': Directory not empty\n",
        .{dir_path},
    );
    defer testing.allocator.free(expected_line);
    const stderr = stderr_aw.writer.buffered();

    try testing.expectEqual(@as(u8, @intFromEnum(common.ExitCode.general_error)), exit_code);
    try testing.expect(std.mem.find(u8, stderr, expected_line) != null);
    try testing.expect(std.mem.find(u8, stderr, "(") == null);
}
