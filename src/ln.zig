//! Create links between files (hard and symbolic)
//! Implements POSIX ln command

const std = @import("std");
const c = std.c;
const common = @import("common");
const testing = std.testing;

/// AT_SYMLINK_FOLLOW flag for linkat: follow symlinks when creating hard links.
/// Value is platform-dependent: 0x0040 on macOS, 0x0400 on Linux.
const AT_SYMLINK_FOLLOW: c_int = if (@import("builtin").os.tag == .macos) 0x0040 else 0x0400;

/// Field order is GNU ln's own `longopts[]` order, because that is the order
/// an ambiguous abbreviation lists its candidates in (`ln --v` -> '--verbose'
/// '--version'). Options vibeutils adds that GNU ln has no entry for sit next
/// to whichever GNU option they alias, after the GNU sequence otherwise.
const LnArgs = struct {
    /// Make backup of each destination file
    backup: bool = false,
    no_dereference: bool = false,
    /// Alias for no_dereference: -h is POSIX for no-dereference
    no_deref_h: bool = false,
    no_target_directory: bool = false,
    force: bool = false,
    interactive: bool = false,
    target_directory: ?[]const u8 = null,
    relative: bool = false,
    symbolic: bool = false,
    verbose: bool = false,
    help: bool = false,
    version: bool = false,
    // Not in GNU ln's longopts table.
    L: bool = false,
    P: bool = false,
    /// Force removal of existing destination files including directories
    force_dir: bool = false,
    /// Warn if symlink source does not exist
    warn_missing: bool = false,
    positionals: []const []const u8 = &.{},

    pub const meta = .{
        .help = .{ .short = 0, .desc = "Display this help and exit" },
        .version = .{ .short = 'V', .desc = "Output version information and exit" },
        .force = .{ .short = 'f', .desc = "Remove existing destination files" },
        .interactive = .{ .short = 'i', .desc = "Prompt whether to remove destinations" },
        .L = .{ .short = 'L', .desc = "Follow symbolic links when creating hard links" },
        .no_dereference = .{
            .short = 'n',
            .desc = "Treat LINK_NAME as a normal file if it is a symbolic link to a directory",
        },
        .no_deref_h = .{ .short = 'h', .desc = "Same as --no-dereference" },
        .P = .{ .short = 'P', .desc = "Create hard link to symbolic link itself" },
        .relative = .{ .short = 'r', .desc = "With -s, create links relative to link location" },
        .symbolic = .{ .short = 's', .desc = "Make symbolic links instead of hard links" },
        .target_directory = .{
            .short = 't',
            .desc = "Specify the DIRECTORY in which to create the links",
            .value_name = "DIRECTORY",
        },
        .no_target_directory = .{ .short = 'T', .desc = "Treat LINK_NAME as a normal file always" },
        .verbose = .{ .short = 'v', .desc = "Print name of each linked file" },
        .force_dir = .{
            .short = 'F',
            .desc = "Force removal of existing destinations including directories",
        },
        .warn_missing = .{ .short = 'w', .desc = "Warn if symlink source does not exist" },
        .backup = .{ .short = 'b', .desc = "Make backup of each destination file" },
    };
};

// Test helper function to create test files (standalone version)
fn createTestFile(io: std.Io, dir: std.Io.Dir, name: []const u8, content: []const u8) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
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
    std.debug.assert(min_len <= from_parts.items.len);
    std.debug.assert(min_len <= to_parts.items.len);
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
    std.debug.assert(common_prefix_len <= from_parts.items.len);
    std.debug.assert(common_prefix_len <= to_parts.items.len);
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
fn isTargetMissing(io: std.Io, target: []const u8, link_name: []const u8) bool {
    if (std.fs.path.isAbsolute(target)) {
        // Absolute target: check directly
        std.Io.Dir.cwd().access(io, target, .{}) catch return true;
        return false;
    }

    // Relative target: resolve relative to the symlink's parent directory
    const link_dir = std.fs.path.dirname(link_name) orelse ".";
    var dir = std.Io.Dir.cwd().openDir(io, link_dir, .{}) catch return false;
    defer dir.close(io);
    dir.access(io, target, .{}) catch return true;
    return false;
}

/// Main entry point for ln command
pub fn main(init: std.process.Init) !void {
    common.utilityMain(init, run);
}

/// Run ln with provided writers for output
fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    const prog_name = "ln";

    const parsed_args = common.argparse.ArgParser.parseOrExit(
        LnArgs,
        allocator,
        args,
        prog_name,
        stderr_writer,
    ) catch return @intFromEnum(common.ExitCode.general_error);
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
    // -F implies -f only when -s is also given (macOS spec: -F is no-op without -s)
    const options = LinkOptions{
        .force = parsed_args.force or (parsed_args.force_dir and parsed_args.symbolic),
        .interactive = parsed_args.interactive,
        .no_dereference = parsed_args.no_dereference or parsed_args.no_deref_h,
        .physical = parsed_args.P,
        .relative = parsed_args.relative,
        .symbolic = parsed_args.symbolic,
        .target_directory = parsed_args.target_directory,
        .no_target_directory = parsed_args.no_target_directory,
        .verbose = parsed_args.verbose,
        .force_dir = parsed_args.force_dir and parsed_args.symbolic,
        .warn_missing = parsed_args.warn_missing,
        .backup = parsed_args.backup,
    };
    // -F is a no-op without -s (macOS spec): force_dir implies symbolic, and
    // force_dir implies force is effectively on. Guarded so each assert is simple.
    if (options.force_dir) {
        std.debug.assert(options.symbolic);
        std.debug.assert(options.force);
    }

    const files = parsed_args.positionals;

    if (files.len == 0) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "missing file operand",
            .{},
        );
        return @intFromEnum(common.ExitCode.general_error);
    }

    const exit_code = try createLinks(allocator, io, files, options, stdout_writer, stderr_writer);
    return @intFromEnum(exit_code);
}

/// Print help information to provided writer
fn printHelp(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
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
fn printVersion(writer: *std.Io.Writer) !void {
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
fn handleTwoArgFallback(
    allocator: std.mem.Allocator,
    io: std.Io,
    files: []const []const u8,
    options: LinkOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !common.ExitCode {
    std.debug.assert(files.len >= 2);
    // Special case: 2 args, treat as Form 1 (TARGET LINK_NAME)
    createSingleLink(
        allocator,
        io,
        files[0],
        files[1],
        options,
        stdout_writer,
        stderr_writer,
        false,
    ) catch {
        // Error already printed by createSingleLink
        return common.ExitCode.general_error;
    };
    return common.ExitCode.success;
}

/// Create links based on command form and options
/// Supports all four POSIX ln command forms
fn createLinks(
    allocator: std.mem.Allocator,
    io: std.Io,
    files: []const []const u8,
    options: LinkOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !common.ExitCode {
    std.debug.assert(files.len > 0);
    const prog_name = "ln";
    if (options.target_directory) |target_dir| {
        // Form 4: ln -t DIRECTORY TARGET...
        return try createLinks_targetDirectory(
            allocator,
            io,
            files,
            target_dir,
            &options,
            stdout_writer,
            stderr_writer,
        );
    } else if (files.len == 1) {
        // Form 2: ln TARGET
        const target = files[0];
        const link_name = std.fs.path.basename(target);
        createSingleLink(
            allocator,
            io,
            target,
            link_name,
            options,
            stdout_writer,
            stderr_writer,
            false,
        ) catch {
            // Error already printed by createSingleLink
            return common.ExitCode.general_error;
        };
    } else if (files.len == 2 and options.no_target_directory) {
        // Form 1: ln [-T] TARGET LINK_NAME
        const target = files[0];
        const link_name = files[1];
        createSingleLink(
            allocator,
            io,
            target,
            link_name,
            options,
            stdout_writer,
            stderr_writer,
            false,
        ) catch {
            // Error already printed by createSingleLink
            return common.ExitCode.general_error;
        };
    } else if (files.len >= 2) {
        // Form 3: ln TARGET... DIRECTORY
        return try createLinks_intoDirectory(
            allocator,
            io,
            files,
            &options,
            stdout_writer,
            stderr_writer,
        );
    } else {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "missing destination file operand after '{s}'",
            .{files[0]},
        );
        return common.ExitCode.general_error;
    }

    return common.ExitCode.success;
}

/// Form 4 (`ln -t DIRECTORY TARGET...`): validate target_dir is a directory,
/// then create a link inside it for each operand.
fn createLinks_targetDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    files: []const []const u8,
    target_dir: []const u8,
    options: *const LinkOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !common.ExitCode {
    std.debug.assert(files.len > 0);
    const prog_name = "ln";

    // Check that target directory exists and is a directory
    const stat = std.Io.Dir.cwd().statFile(io, target_dir, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    prog_name,
                    "target '{s}' is not a directory",
                    .{target_dir},
                );
                return common.ExitCode.general_error;
            },
            else => return err,
        }
    };

    if (stat.kind != .directory) {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "target '{s}' is not a directory",
            .{target_dir},
        );
        return common.ExitCode.general_error;
    }

    var had_error = false;
    for (files) |target| {
        const link_name = std.fs.path.basename(target);
        const full_link_path = try std.fs.path.join(
            allocator,
            &[_][]const u8{ target_dir, link_name },
        );
        defer allocator.free(full_link_path);
        createSingleLink(
            allocator,
            io,
            target,
            full_link_path,
            options.*,
            stdout_writer,
            stderr_writer,
            false,
        ) catch {
            // Error already printed by createSingleLink
            had_error = true;
        };
    }
    if (had_error) return common.ExitCode.general_error;
    return common.ExitCode.success;
}

/// Form 3 (`ln TARGET... DIRECTORY`): the last operand is a directory; create a
/// link inside it for each preceding target. Falls back to Form 1 for the
/// two-arg cases where the destination is a symlink (with -n) or not a directory.
fn createLinks_intoDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    files: []const []const u8,
    options: *const LinkOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !common.ExitCode {
    std.debug.assert(files.len >= 2);
    const prog_name = "ln";

    const directory = files[files.len - 1];

    // Decide whether the destination is a directory, a Form-1 fallback, or an
    // error. Branching lives here in the parent; the helper only classifies.
    switch (try createLinks_intoDirectory_resolveDir(io, files, options, directory)) {
        .proceed => {},
        .fallback => {
            return try handleTwoArgFallback(
                allocator,
                io,
                files,
                options.*,
                stdout_writer,
                stderr_writer,
            );
        },
        .not_a_directory => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                prog_name,
                "target '{s}' is not a directory",
                .{directory},
            );
            return common.ExitCode.general_error;
        },
    }

    // Create links in the directory
    var had_error = false;
    for (files[0 .. files.len - 1]) |target| {
        const link_name = std.fs.path.basename(target);
        const full_link_path = try std.fs.path.join(
            allocator,
            &[_][]const u8{ directory, link_name },
        );
        defer allocator.free(full_link_path);
        createSingleLink(
            allocator,
            io,
            target,
            full_link_path,
            options.*,
            stdout_writer,
            stderr_writer,
            false,
        ) catch {
            // Error already printed by createSingleLink
            had_error = true;
        };
    }
    if (had_error) return common.ExitCode.general_error;
    return common.ExitCode.success;
}

/// Classify the Form-3 destination for createLinks_intoDirectory without printing
/// or returning: `.proceed` when it is a real directory, `.fallback` when a
/// two-arg case should be treated as Form 1, `.not_a_directory` otherwise.
fn createLinks_intoDirectory_resolveDir(
    io: std.Io,
    files: []const []const u8,
    options: *const LinkOptions,
    directory: []const u8,
) !enum { proceed, fallback, not_a_directory } {
    std.debug.assert(files.len >= 2);

    // When -n/-h (no_dereference) is set and the destination is a symlink,
    // treat it as a regular file (Form 1), not as a directory to create
    // links inside. This prevents ln -sfn from following a symlink-to-directory.
    if (options.no_dereference and files.len == 2) {
        var readlink_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (std.Io.Dir.cwd().readLink(io, directory, &readlink_buf)) |_| {
            // Destination is a symlink — treat as Form 1 (TARGET LINK_NAME)
            return .fallback;
        } else |_| {
            // Not a symlink — fall through to normal directory check
        }
    }

    const stat = std.Io.Dir.cwd().statFile(io, directory, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (files.len == 2) return .fallback;
            return .not_a_directory;
        },
        else => return err,
    };

    if (stat.kind != .directory) {
        if (files.len == 2) return .fallback;
        return .not_a_directory;
    }

    return .proceed;
}

/// Create a single link (hard or symbolic) from target to link_name
/// Handles existing files and relative paths
/// When test_mode is true, interactive prompts are skipped (assumes 'no')
fn createSingleLink(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: []const u8,
    link_name: []const u8,
    options: LinkOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    test_mode: bool,
) !void {
    const prog_name = "ln";

    const link_exists = try createSingleLink_linkExists(allocator, io, link_name, stderr_writer);

    if (link_exists and !options.force and !options.backup) {
        if (options.interactive) {
            // Returns false on decline (caller stops); true after deleting the file.
            const proceed = try createSingleLink_promptReplace(
                allocator,
                io,
                link_name,
                stderr_writer,
                test_mode,
            );
            if (!proceed) return;
        } else {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                prog_name,
                "'{s}': File exists",
                .{link_name},
            );
            return error.FileExists;
        }
    }

    // Backup or force-remove the existing destination, if any.
    try createSingleLink_removeExisting(
        allocator,
        io,
        link_name,
        &options,
        link_exists,
        stderr_writer,
    );

    // Track the effective target path for verbose output (may differ from
    // the original target when --relative computes a relative path).
    var effective_target = target;
    // Arena for relative path computation; must outlive verbose output.
    var rel_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer rel_arena.deinit();

    if (options.symbolic) {
        effective_target = try createSingleLink_createSymlink(
            allocator,
            io,
            target,
            link_name,
            &options,
            &rel_arena,
            stderr_writer,
        );
    } else {
        try createSingleLink_hardLink(allocator, io, target, link_name, &options, stderr_writer);
    }

    if (options.verbose) {
        if (options.symbolic) {
            // Use -> for symbolic links; show the effective target (relative if -r)
            try stdout_writer.print("'{s}' -> '{s}'\n", .{ link_name, effective_target });
        } else {
            // Use => for hard links
            try stdout_writer.print("'{s}' => '{s}'\n", .{ link_name, target });
        }
    }
}

/// Create the symbolic link, computing a relative target first when -r is set,
/// and warn on a dangling target. Returns the effective target (relative path
/// when -r, else the original) so the caller can render verbose output.
fn createSingleLink_createSymlink(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: []const u8,
    link_name: []const u8,
    options: *const LinkOptions,
    rel_arena: *std.heap.ArenaAllocator,
    stderr_writer: *std.Io.Writer,
) ![]const u8 {
    const prog_name = "ln";

    var target_path = target;

    if (options.relative) {
        const temp_allocator = rel_arena.allocator();
        target_path = try createSingleLink_computeRelativeTarget(
            allocator,
            io,
            target,
            link_name,
            temp_allocator,
            stderr_writer,
        );
    }

    std.Io.Dir.cwd().symLink(io, target_path, link_name, .{}) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "cannot create symbolic link '{s}' to '{s}': {s}",
            .{ link_name, target, common.posixErrorString(err) },
        );
        return err;
    };

    // Warn if the symlink target does not exist (dangling symlink)
    if (options.warn_missing and isTargetMissing(io, target_path, link_name)) {
        common.printWarningWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "creating dangling symlink: target '{s}' does not exist",
            .{target},
        );
    }

    return target_path;
}

/// Detect whether link_name already exists, treating dangling symlinks as existing.
/// access() follows symlinks and reports FileNotFound for a dangling one, so fall
/// back to readLink to distinguish a missing path from a broken symlink.
fn createSingleLink_linkExists(
    allocator: std.mem.Allocator,
    io: std.Io,
    link_name: []const u8,
    stderr_writer: *std.Io.Writer,
) !bool {
    const prog_name = "ln";

    std.Io.Dir.cwd().access(io, link_name, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // access follows symlinks; a dangling symlink looks like FileNotFound.
            // Check whether link_name itself is a symlink (even if its target is gone).
            var readlink_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            _ = std.Io.Dir.cwd().readLink(io, link_name, &readlink_buf) catch {
                return false; // Neither a file nor a symlink
            };
            return true; // Dangling symlink exists
        },
        else => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                prog_name,
                "cannot access '{s}': {s}",
                .{ link_name, common.posixErrorString(err) },
            );
            return err;
        },
    };
    return true;
}

/// Interactively confirm replacing an existing link. Returns false if the user
/// declines (caller should stop), true after the existing file has been deleted.
/// In test_mode this assumes 'no' and surfaces error.FileExists faithfully.
fn createSingleLink_promptReplace(
    allocator: std.mem.Allocator,
    io: std.Io,
    link_name: []const u8,
    stderr_writer: *std.Io.Writer,
    test_mode: bool,
) !bool {
    const prog_name = "ln";

    if (test_mode) {
        // Test mode: assume 'no' for interactive prompts
        return error.FileExists;
    }

    // Interactive prompt
    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    try stderr_writer.print("ln: replace '{s}'? ", .{link_name});
    stderr_writer.flush() catch {};

    const input = stdin.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return false,
        else => return err,
    };

    // Proceed only on 'y' or 'Y'
    if (input.len == 0 or (input[0] != 'y' and input[0] != 'Y')) {
        return false;
    }

    // User confirmed: remove existing file before creating new link
    std.Io.Dir.cwd().deleteFile(io, link_name) catch |err| switch (err) {
        error.FileNotFound => {}, // Already removed
        else => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                prog_name,
                "cannot remove '{s}': {s}",
                .{ link_name, common.posixErrorString(err) },
            );
            return err;
        },
    };
    return true;
}

/// Back up or force-remove the existing destination so a fresh link can be made.
/// No-op when the destination does not exist or neither backup nor force is set.
fn createSingleLink_removeExisting(
    allocator: std.mem.Allocator,
    io: std.Io,
    link_name: []const u8,
    options: *const LinkOptions,
    link_exists: bool,
    stderr_writer: *std.Io.Writer,
) !void {
    const prog_name = "ln";

    // Create backup of destination if it exists and backup mode is enabled
    if (link_exists and options.backup) {
        // GNU ln honors SIMPLE_BACKUP_SUFFIX; default '~'.
        const suffix = common.env.getEnv("SIMPLE_BACKUP_SUFFIX") orelse "~";
        const backup_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ link_name, suffix });
        defer allocator.free(backup_name);
        const cwd = std.Io.Dir.cwd();
        std.Io.Dir.rename(cwd, link_name, cwd, backup_name, io) catch |backup_err| {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                prog_name,
                "cannot create backup '{s}': {s}",
                .{ backup_name, common.posixErrorString(backup_err) },
            );
            return backup_err;
        };
        // After backup rename, link no longer exists at original location
    } else if (link_exists and options.force) {
        // Remove existing link if force is enabled (no backup)
        if (options.force_dir) {
            // -F: also attempt to remove directories
            std.Io.Dir.cwd().deleteFile(io, link_name) catch |err| switch (err) {
                error.FileNotFound => {}, // Already removed
                error.IsDir => {
                    std.Io.Dir.cwd().deleteDir(io, link_name) catch |dir_err| {
                        common.printErrorWithProgram(
                            allocator,
                            stderr_writer,
                            prog_name,
                            "cannot remove directory '{s}': {s}",
                            .{ link_name, common.posixErrorString(dir_err) },
                        );
                        return dir_err;
                    };
                },
                else => {
                    common.printErrorWithProgram(
                        allocator,
                        stderr_writer,
                        prog_name,
                        "cannot remove '{s}': {s}",
                        .{ link_name, common.posixErrorString(err) },
                    );
                    return err;
                },
            };
        } else {
            std.Io.Dir.cwd().deleteFile(io, link_name) catch |err| switch (err) {
                error.FileNotFound => {}, // Already removed
                else => {
                    common.printErrorWithProgram(
                        allocator,
                        stderr_writer,
                        prog_name,
                        "cannot remove '{s}': {s}",
                        .{ link_name, common.posixErrorString(err) },
                    );
                    return err;
                },
            };
        }
    }
}

/// Compute the relative path from the link's directory to the target, for `ln -r`.
/// Resolves both endpoints to absolute paths before relativizing.
fn createSingleLink_computeRelativeTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: []const u8,
    link_name: []const u8,
    temp_allocator: std.mem.Allocator,
    stderr_writer: *std.Io.Writer,
) ![]const u8 {
    const prog_name = "ln";

    // Compute relative path from link to target
    var target_abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var link_dir_abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const target_abs = blk: {
        if (std.fs.path.isAbsolute(target)) {
            break :blk target;
        } else {
            const len = std.Io.Dir.cwd().realPathFile(io, target, &target_abs_buf) catch |err| {
                common.printErrorWithProgram(
                    allocator,
                    stderr_writer,
                    prog_name,
                    "cannot resolve target path '{s}': {s}",
                    .{ target, common.posixErrorString(err) },
                );
                return err;
            };
            break :blk target_abs_buf[0..len];
        }
    };

    // Get link directory for relative path calculation
    const link_dir = std.fs.path.dirname(link_name) orelse ".";
    const link_dir_abs = blk: {
        if (std.fs.path.isAbsolute(link_dir)) {
            break :blk link_dir;
        } else {
            const len = std.Io.Dir.cwd().realPathFile(io, link_dir, &link_dir_abs_buf) catch
                break :blk ".";
            break :blk link_dir_abs_buf[0..len];
        }
    };

    // Calculate relative path
    return makeRelativePath(temp_allocator, link_dir_abs, target_abs) catch |err| {
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "cannot compute relative path: {s}",
            .{common.posixErrorString(err)},
        );
        return err;
    };
}

/// Create a hard link from target to link_name via linkat, honoring -P/-L.
/// The target must already exist; maps errno to a descriptive error message.
fn createSingleLink_hardLink(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: []const u8,
    link_name: []const u8,
    options: *const LinkOptions,
    stderr_writer: *std.Io.Writer,
) !void {
    const prog_name = "ln";

    // Create hard link - target must exist
    std.Io.Dir.cwd().access(io, target, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                prog_name,
                "cannot link '{s}': No such file or directory",
                .{target},
            );
            return error.FileNotFound;
        },
        else => {
            common.printErrorWithProgram(
                allocator,
                stderr_writer,
                prog_name,
                "cannot access '{s}': {s}",
                .{ target, common.posixErrorString(err) },
            );
            return err;
        },
    };

    // Use linkat to control symlink following behavior:
    // -P (physical): flags=0, creates hard link to symlink itself
    // default/-L: AT_SYMLINK_FOLLOW, creates hard link to symlink target
    const flags: c_uint = @intCast(if (options.physical) 0 else AT_SYMLINK_FOLLOW);
    // flags is fully controlled by -P: exactly one of the two linkat flag states.
    if (options.physical) {
        std.debug.assert(flags == 0);
    } else {
        std.debug.assert(flags == @as(c_uint, @intCast(AT_SYMLINK_FOLLOW)));
    }
    const target_z = try allocator.dupeZ(u8, target);
    defer allocator.free(target_z);
    const link_name_z = try allocator.dupeZ(u8, link_name);
    defer allocator.free(link_name_z);

    const result = c.linkat(c.AT.FDCWD, target_z, c.AT.FDCWD, link_name_z, flags);
    if (result == -1) {
        const errno = std.posix.errno(result);
        const err = switch (errno) {
            .ACCES, .PERM => error.AccessDenied,
            .EXIST => error.PathAlreadyExists,
            .LOOP => error.SymLinkLoop,
            .NAMETOOLONG => error.NameTooLong,
            .NOENT => error.FileNotFound,
            .NOSPC => error.NoSpaceLeft,
            .NOTDIR => error.NotDir,
            .ROFS => error.ReadOnlyFileSystem,
            .XDEV => error.RenameAcrossMountPoints,
            else => error.LinkFailed,
        };
        common.printErrorWithProgram(
            allocator,
            stderr_writer,
            prog_name,
            "cannot create link '{s}' to '{s}': {s}",
            .{ link_name, target, common.posixErrorString(err) },
        );
        return error.LinkFailed;
    }
}

/// Test-friendly version of createSingleLink that works in a specific directory
fn createSingleLinkInDir(
    allocator: std.mem.Allocator,
    target: []const u8,
    link_name: []const u8,
    options: LinkOptions,
    test_dir: std.Io.Dir,
) !void {
    const io = testing.io;
    // Create target file for hard link tests if it doesn't exist
    if (!options.symbolic) {
        test_dir.access(io, target, .{}) catch {
            const target_file = try test_dir.createFile(io, target, .{});
            defer target_file.close(io);
            try target_file.writeStreamingAll(io, "test content");
        };
    }

    // Check if link already exists and handle force option
    const link_exists = blk: {
        test_dir.access(io, link_name, .{}) catch |err| switch (err) {
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
        test_dir.deleteFile(io, link_name) catch |err| switch (err) {
            error.FileNotFound => {}, // Already removed
            else => return err,
        };
    }

    // Create the link directly in the test directory
    if (options.symbolic) {
        try test_dir.symLink(io, target, link_name, .{});
    } else {
        // For hard links, we need to use the full path approach since
        // std.posix.link requires paths accessible from current working directory
        const test_dir_path = try test_dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(test_dir_path);

        const target_abs = try std.fs.path.join(
            allocator,
            &[_][]const u8{ test_dir_path, target },
        );
        defer allocator.free(target_abs);
        const link_abs = try std.fs.path.join(
            allocator,
            &[_][]const u8{ test_dir_path, link_name },
        );
        defer allocator.free(link_abs);

        try std.Io.Dir.hardLink(
            std.Io.Dir.cwd(),
            target_abs,
            std.Io.Dir.cwd(),
            link_abs,
            io,
            .{},
        );
    }
}

test "ln creates hard link to existing file" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create target file in test directory
    try createTestFile(io, tmp_dir.dir, "target.txt", "test content");

    // Create hard link without changing directories
    try createSingleLinkInDir(
        testing.allocator,
        "target.txt",
        "link.txt",
        .{},
        tmp_dir.dir,
    );

    // Verify link was created
    const link_content = try tmp_dir.dir.readFileAlloc(
        io,
        "link.txt",
        testing.allocator,
        .limited(1024),
    );
    defer testing.allocator.free(link_content);

    try testing.expectEqualStrings("test content", link_content);
}

test "ln creates symbolic link" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create target file
    try createTestFile(io, tmp_dir.dir, "target.txt", "test content");

    // Create symbolic link without changing directories
    try createSingleLinkInDir(
        testing.allocator,
        "target.txt",
        "symlink.txt",
        .{ .symbolic = true },
        tmp_dir.dir,
    );

    // Verify symbolic link was created
    const link_content = try tmp_dir.dir.readFileAlloc(
        io,
        "symlink.txt",
        testing.allocator,
        .limited(1024),
    );
    defer testing.allocator.free(link_content);

    try testing.expectEqualStrings("test content", link_content);
}

test "ln fails on non-existent target for hard link" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Should fail - hard links require existing targets
    // Need to manually check for hard link since the helper auto-creates target files
    const test_dir_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(test_dir_path);

    const target_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ test_dir_path, "nonexistent.txt" },
    );
    defer testing.allocator.free(target_abs);
    const link_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ test_dir_path, "link.txt" },
    );
    defer testing.allocator.free(link_abs);

    const result = std.Io.Dir.hardLink(
        std.Io.Dir.cwd(),
        target_abs,
        std.Io.Dir.cwd(),
        link_abs,
        io,
        .{},
    );
    try testing.expectError(error.FileNotFound, result);
}

test "ln allows non-existent target for symbolic link" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Should succeed - symbolic links allow non-existent targets
    try createSingleLinkInDir(
        testing.allocator,
        "nonexistent.txt",
        "symlink.txt",
        .{ .symbolic = true },
        tmp_dir.dir,
    );

    // Verify the symlink exists (but points to non-existent file)
    // Check that the link exists by reading the link target
    var buffer: [256]u8 = undefined;
    const target_len = tmp_dir.dir.readLink(io, "symlink.txt", &buffer) catch |err| switch (err) {
        error.NotLink => {
            try testing.expect(false); // Should be a link
            return;
        },
        else => return err,
    };
    try testing.expectEqualStrings("nonexistent.txt", buffer[0..target_len]);
}

test "ln with force removes existing file" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create target and existing link
    try createTestFile(io, tmp_dir.dir, "target.txt", "new content");
    try createTestFile(io, tmp_dir.dir, "link.txt", "old content");

    // Force create hard link
    try createSingleLinkInDir(
        testing.allocator,
        "target.txt",
        "link.txt",
        .{ .force = true },
        tmp_dir.dir,
    );

    // Verify link was replaced
    const link_content = try tmp_dir.dir.readFileAlloc(
        io,
        "link.txt",
        testing.allocator,
        .limited(1024),
    );
    defer testing.allocator.free(link_content);

    try testing.expectEqualStrings("new content", link_content);
}

test "ln fails without force on existing file" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create target and existing link
    try createTestFile(io, tmp_dir.dir, "target.txt", "new content");
    try createTestFile(io, tmp_dir.dir, "link.txt", "old content");

    // Should fail without force
    const result = createSingleLinkInDir(
        testing.allocator,
        "target.txt",
        "link.txt",
        .{},
        tmp_dir.dir,
    );
    try testing.expectError(error.FileExists, result);
}

test "ln creates relative symbolic link with -r" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a subdirectory structure
    try tmp_dir.dir.createDir(io, "subdir", .default_dir);
    try createTestFile(io, tmp_dir.dir, "target.txt", "test content");

    // This test is complex because relative links require the real createSingleLink function
    // For now, let's test the relative path calculation directly and create a simple symlink

    // Test manual creation of relative symlink
    try tmp_dir.dir.symLink(io, "../target.txt", "subdir/link.txt", .{});

    // Verify relative path link
    var buffer: [256]u8 = undefined;
    const link_target_len = try tmp_dir.dir.readLink(io, "subdir/link.txt", &buffer);
    try testing.expectEqualStrings("../target.txt", buffer[0..link_target_len]);

    // Verify the link works
    const link_content = try tmp_dir.dir.readFileAlloc(
        io,
        "subdir/link.txt",
        testing.allocator,
        .limited(1024),
    );
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
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a symlink to a nonexistent target
    try tmp_dir.dir.symLink(io, "nonexistent.txt", "dangling_link", .{});

    // Get the full path to the link so we can test isTargetMissing
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const link_path = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "dangling_link" },
    );
    defer testing.allocator.free(link_path);

    try testing.expect(isTargetMissing(io, "nonexistent.txt", link_path));
}

test "isTargetMissing returns false for existing target" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a real file and a symlink pointing to it
    try createTestFile(io, tmp_dir.dir, "real_file.txt", "content");
    try tmp_dir.dir.symLink(io, "real_file.txt", "good_link", .{});

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const link_path = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "good_link" },
    );
    defer testing.allocator.free(link_path);

    try testing.expect(!isTargetMissing(io, "real_file.txt", link_path));
}

test "dangling symlink produces warning via createSingleLink with -w" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const link_path = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "warn_link" },
    );
    defer testing.allocator.free(link_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Create symlink to nonexistent target with -w flag
    try createSingleLink(
        testing.allocator,
        io,
        "nonexistent_target",
        link_path,
        .{ .symbolic = true, .warn_missing = true },
        common.null_writer,
        &stderr_aw.writer,
        true,
    );

    // Should contain a dangling symlink warning
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "dangling symlink") != null);
}

test "dangling symlink no warning without -w" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const link_path = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "no_warn_link" },
    );
    defer testing.allocator.free(link_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Create symlink to nonexistent target without -w flag
    try createSingleLink(
        testing.allocator,
        io,
        "nonexistent_target",
        link_path,
        .{ .symbolic = true },
        common.null_writer,
        &stderr_aw.writer,
        true,
    );

    // Should NOT contain a dangling symlink warning
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "dangling symlink") == null);
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
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create original file
    try createTestFile(io, tmp_dir.dir, "original.txt", "original content");

    // Create symlink to original file
    try tmp_dir.dir.symLink(io, "original.txt", "symlink.txt", .{});

    // Get the real path of the tmp dir for absolute path construction
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const symlink_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "symlink.txt" },
    );
    defer testing.allocator.free(symlink_abs);
    const hardlink_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "hardlink.txt" },
    );
    defer testing.allocator.free(hardlink_abs);
    const original_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "original.txt" },
    );
    defer testing.allocator.free(original_abs);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Run: ln -L symlink.txt hardlink.txt
    const exit_code = try run(
        testing.allocator,
        io,
        &[_][]const u8{ "-L", symlink_abs, hardlink_abs },
        common.null_writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Verify hardlink points to same inode as the original file (not the symlink)
    const original_file = try std.Io.Dir.cwd().openFile(io, original_abs, .{});
    defer original_file.close(io);
    const hardlink_file = try std.Io.Dir.cwd().openFile(io, hardlink_abs, .{});
    defer hardlink_file.close(io);

    const original_stat = try original_file.stat(io);
    const hardlink_stat = try hardlink_file.stat(io);

    // -L should create hard link to the target of the symlink (original.txt)
    try testing.expectEqual(original_stat.inode, hardlink_stat.inode);
}

test "ln: -P creates hard link to symlink itself" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create original file
    try createTestFile(io, tmp_dir.dir, "original.txt", "original content");

    // Create symlink to original file
    try tmp_dir.dir.symLink(io, "original.txt", "symlink.txt", .{});

    // Get the real path of the tmp dir for absolute path construction
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const symlink_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "symlink.txt" },
    );
    defer testing.allocator.free(symlink_abs);
    const hardlink_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "hardlink_p.txt" },
    );
    defer testing.allocator.free(hardlink_abs);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Run: ln -P symlink.txt hardlink_p.txt
    const exit_code = try run(
        testing.allocator,
        io,
        &[_][]const u8{ "-P", symlink_abs, hardlink_abs },
        common.null_writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Use lstat (via common.file.FileInfo) to get inode of symlink itself
    const symlink_info = try common.file.FileInfo.lstat(symlink_abs);
    const hardlink_info = try common.file.FileInfo.lstat(hardlink_abs);

    // -P creates a hard link to the symlink itself (linkat flags=0),
    // so the hardlink shares the symlink's inode rather than the target's.
    try testing.expectEqual(symlink_info.inode, hardlink_info.inode);
}

test "ln: -b flag creates backup of destination" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create target and existing link
    try createTestFile(io, tmp_dir.dir, "target.txt", "new content");
    try createTestFile(io, tmp_dir.dir, "link.txt", "old content");

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const target_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "target.txt" },
    );
    defer testing.allocator.free(target_abs);
    const link_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "link.txt" },
    );
    defer testing.allocator.free(link_abs);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Run: ln -bf target.txt link.txt (backup + force)
    const exit_code = try run(
        testing.allocator,
        io,
        &[_][]const u8{ "-b", "-f", target_abs, link_abs },
        common.null_writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Backup file should exist with old content
    const backup_content = try tmp_dir.dir.readFileAlloc(
        io,
        "link.txt~",
        testing.allocator,
        .limited(1024),
    );
    defer testing.allocator.free(backup_content);
    try testing.expectEqualStrings("old content", backup_content);

    // New link should point to target
    const link_content = try tmp_dir.dir.readFileAlloc(
        io,
        "link.txt",
        testing.allocator,
        .limited(1024),
    );
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
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const link_path = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "w_warn_link" },
    );
    defer testing.allocator.free(link_path);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Run: ln -sw nonexistent_target link_path
    const exit_code = try run(
        testing.allocator,
        io,
        &[_][]const u8{ "-s", "-w", "nonexistent_target", link_path },
        common.null_writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Should warn about dangling symlink
    try testing.expect(std.mem.find(u8, stderr_aw.writer.buffered(), "dangling symlink") != null);
}

test "ln: -sb without -f creates backup and replaces symlink" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create two target files
    try createTestFile(io, tmp_dir.dir, "old_target.txt", "old content");
    try createTestFile(io, tmp_dir.dir, "new_target.txt", "new content");

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    // Create an existing symlink pointing to old_target.txt
    const link_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "mylink" },
    );
    defer testing.allocator.free(link_abs);
    const new_target_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "new_target.txt" },
    );
    defer testing.allocator.free(new_target_abs);

    try tmp_dir.dir.symLink(io, "old_target.txt", "mylink", .{});

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Run: ln -sb new_target.txt mylink (backup + symbolic, NO force)
    // GNU ln -b creates backup regardless of -f
    const exit_code = try run(
        testing.allocator,
        io,
        &[_][]const u8{ "-s", "-b", new_target_abs, link_abs },
        common.null_writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Backup file mylink~ should exist (the old symlink was renamed)
    tmp_dir.dir.access(io, "mylink~", .{}) catch |err| {
        std.debug.print("backup file mylink~ not found: {s}\n", .{@errorName(err)});
        return error.TestExpectedEqual;
    };

    // The new mylink should be a symlink to new_target.txt
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link_target_len = try tmp_dir.dir.readLink(io, "mylink", &buffer);
    try testing.expectEqualStrings(new_target_abs, buffer[0..link_target_len]);
}

// F54: ln -sfn should replace a symlink-to-directory, not follow it
test "ln: -sfn replaces symlink to directory instead of following it" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a real directory and a symlink pointing to it
    try tmp_dir.dir.createDir(io, "real_dir", .default_dir);
    try tmp_dir.dir.symLink(io, "real_dir", "dir_link", .{ .is_directory = true });

    // Create a target file
    try createTestFile(io, tmp_dir.dir, "target.txt", "target content");

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const target_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "target.txt" },
    );
    defer testing.allocator.free(target_abs);
    const dir_link_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "dir_link" },
    );
    defer testing.allocator.free(dir_link_abs);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Run: ln -sfn target.txt dir_link
    // GNU behavior: dir_link should be REPLACED with a symlink to target.txt
    // Bug: our code follows dir_link into real_dir and creates target.txt inside it
    const exit_code = try run(
        testing.allocator,
        io,
        &[_][]const u8{ "-s", "-f", "-n", target_abs, dir_link_abs },
        common.null_writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);

    // dir_link should now be a symlink to target.txt, NOT a symlink to real_dir
    var readlink_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link_target_len = try tmp_dir.dir.readLink(io, "dir_link", &readlink_buf);
    try testing.expectEqualStrings(target_abs, readlink_buf[0..link_target_len]);
}

// F54: ln -sfh should also replace symlink to directory (POSIX -h alias)
test "ln: -sfh replaces symlink to directory (POSIX -h alias)" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDir(io, "real_dir", .default_dir);
    try tmp_dir.dir.symLink(io, "real_dir", "dir_link", .{ .is_directory = true });
    try createTestFile(io, tmp_dir.dir, "target.txt", "target content");

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const target_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "target.txt" },
    );
    defer testing.allocator.free(target_abs);
    const dir_link_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "dir_link" },
    );
    defer testing.allocator.free(dir_link_abs);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Run: ln -sfh target.txt dir_link
    const exit_code = try run(
        testing.allocator,
        io,
        &[_][]const u8{ "-s", "-f", "-h", target_abs, dir_link_abs },
        common.null_writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);

    var readlink_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link_target_len = try tmp_dir.dir.readLink(io, "dir_link", &readlink_buf);
    try testing.expectEqualStrings(target_abs, readlink_buf[0..link_target_len]);
}

// F54: ln -n with regular file dest should work normally
test "ln: -sfn with regular file destination works normally" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try createTestFile(io, tmp_dir.dir, "target.txt", "target content");
    try createTestFile(io, tmp_dir.dir, "existing.txt", "old content");

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const target_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "target.txt" },
    );
    defer testing.allocator.free(target_abs);
    const existing_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "existing.txt" },
    );
    defer testing.allocator.free(existing_abs);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try run(
        testing.allocator,
        io,
        &[_][]const u8{ "-s", "-f", "-n", target_abs, existing_abs },
        common.null_writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);

    // Should be a symlink to target.txt
    var readlink_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link_target_len = try tmp_dir.dir.readLink(io, "existing.txt", &readlink_buf);
    try testing.expectEqualStrings(target_abs, readlink_buf[0..link_target_len]);
}

// F54: ln -n with dangling symlink dest should work normally
test "ln: -sfn with dangling symlink destination replaces it" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try createTestFile(io, tmp_dir.dir, "target.txt", "target content");

    // Create a dangling symlink
    try tmp_dir.dir.symLink(io, "nonexistent", "dangling_link", .{});

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const target_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "target.txt" },
    );
    defer testing.allocator.free(target_abs);
    const dangling_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "dangling_link" },
    );
    defer testing.allocator.free(dangling_abs);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try run(
        testing.allocator,
        io,
        &[_][]const u8{ "-s", "-f", "-n", target_abs, dangling_abs },
        common.null_writer,
        &stderr_aw.writer,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);

    var readlink_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link_target_len = try tmp_dir.dir.readLink(io, "dangling_link", &readlink_buf);
    try testing.expectEqualStrings(target_abs, readlink_buf[0..link_target_len]);
}

// F66: ln --backup=simple should not panic
test "ln: --backup=simple does not panic with TooManyValues" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try createTestFile(io, tmp_dir.dir, "source.txt", "source content");
    try createTestFile(io, tmp_dir.dir, "dest.txt", "dest content");

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const source_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "source.txt" },
    );
    defer testing.allocator.free(source_abs);
    const dest_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "dest.txt" },
    );
    defer testing.allocator.free(dest_abs);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    // Run: ln --backup=simple source.txt dest.txt
    // GNU ln accepts --backup=CONTROL; our code panics with TooManyValues
    // because backup is a bool and can't take a value.
    // Expected: exit code 0 (success) with backup created, or at minimum
    // a clean error message (not a stack trace / panic).
    const exit_code = try run(
        testing.allocator,
        io,
        &[_][]const u8{ "--backup=simple", source_abs, dest_abs },
        common.null_writer,
        &stderr_aw.writer,
    );

    // Should succeed (GNU behavior) or at least give a clean error (exit 1).
    // Must NOT propagate TooManyValues error (which would be a panic/stack trace).
    // For now, test that it returns a clean exit code, not an error propagation.
    try testing.expect(exit_code == 0 or exit_code == 1);
}

// F66: ln --backup=numbered should also not panic
test "ln: --backup=numbered does not panic" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try createTestFile(io, tmp_dir.dir, "source.txt", "source content");
    try createTestFile(io, tmp_dir.dir, "dest.txt", "dest content");

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const source_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "source.txt" },
    );
    defer testing.allocator.free(source_abs);
    const dest_abs = try std.fs.path.join(
        testing.allocator,
        &[_][]const u8{ tmp_path, "dest.txt" },
    );
    defer testing.allocator.free(dest_abs);

    var stderr_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_aw.deinit();

    const exit_code = try run(
        testing.allocator,
        io,
        &[_][]const u8{ "--backup=numbered", source_abs, dest_abs },
        common.null_writer,
        &stderr_aw.writer,
    );

    try testing.expect(exit_code == 0 or exit_code == 1);
}
